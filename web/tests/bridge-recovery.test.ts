// 桥恢复链 —— 审计 2026-10-03 协议-P1-1 / P1-2 的回归锁。
//
// 钉四条：
// · Bridge.attach() 必须先 dispose 旧栈（旧 ChannelClient 的在途 call 立刻
//   报错，不再悬到超时；RpcFrames 的清理 interval 被释放）；
// · recoverOnce 成功 → onRecovered 监听器被广播（订阅层据此重订阅）；
// · Subscription 持**延迟取值**的 ChannelClient：换栈后 resubscribe 落到
//   新栈，而不是继续挂在死栈上（旧实现静默冻屏的根因）；
// · resync 单飞闸由整条重试链握着：attempt-0 失败但重试已排程时不放闸。
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Bridge } from '../src/protocol/remoteSession'
import { ChannelClient } from '../src/protocol/channelClient'
import { Subscription } from '../src/protocol/subscription'
import { ValueWriter } from '../src/protocol/valueCodec'
import { IPC_RES_INITIALIZE } from '../src/protocol/constants'

type Frame = Record<string, unknown>

function fakeSession(bridgeResponse?: () => Frame) {
  return {
    relay: { sendPayload: () => {} },
    onLog: () => {},
    request: async () => bridgeResponse?.() ?? { bridge: {} },
  } as unknown as Bridge['session']
}

const INFO = {
  bridgeSessionId: 'b1',
  workspaceKey: 'C:\\proj',
  workspacePath: 'C:\\proj',
}

function fakeChannel(markers: string[]) {
  return {
    call: async (channel: string, method: string) => {
      markers.push(method)
      if (method.startsWith('subscribe'))
        return { ack: { subscriptionId: `sub-${markers.length}` } }
      return {}
    },
    addEventListener: () => () => {},
  } as unknown as ChannelClient
}

describe('Bridge.attach / recoverOnce（协议-P1-1）', () => {
  it('attach 覆盖旧栈前先 dispose：旧 ChannelClient 的在途 call 立刻报错', async () => {
    const bridge = new Bridge(fakeSession(), INFO)
    const old = bridge.channels
    // 先把旧栈喂到 ready（initialize 帧），call 才会进入 pending 表——
    // 这正是真实在途调用的状态。
    const w = new ValueWriter()
    w.writeValue([IPC_RES_INITIALIZE])
    old.handleMessage(w.take())
    const pending = old.call('zcode-agent', 'resyncConversationV4', [])
    // call 挂在 waitForReady 的微任务上：先让宏任务把 pending 落表，
    // 再 dispose——这才对得上真实在途调用的时序。
    await new Promise((r) => setTimeout(r, 0))
    bridge.attach({ ...INFO, bridgeGeneration: 2 })
    await expect(pending).rejects.toThrow(/channel disposed/)
    // 新栈可用（引用已切换）。
    expect(bridge.channels).not.toBe(old)
    bridge.dispose()
  })

  it('recoverOnce 成功 → 换新栈 + 广播 onRecovered', async () => {
    let generation = 1
    const session = fakeSession(() => {
      generation += 1
      return { bridge: { ...INFO, bridgeGeneration: generation } }
    })
    const bridge = new Bridge(session, INFO)
    const old = bridge.channels
    const recovered = vi.fn()
    bridge.onRecovered(recovered)

    await bridge.recoverWithRetry()

    expect(recovered).toHaveBeenCalledTimes(1)
    expect(bridge.recoveredTick).toBe(1)
    expect(bridge.channels).not.toBe(old)
    await expect(old.call('c', 'm', [])).rejects.toThrow(/channel disposed/)
    bridge.dispose()
  })

  it('recoverOnce 一直失败 → 不广播不换栈（重试 8 轮后放弃）', async () => {
    vi.useFakeTimers()
    try {
      const session = fakeSession(() => ({ zcode_type: 'workspace-bridge-error' }))
      const bridge = new Bridge(session, INFO)
      const old = bridge.channels
      const recovered = vi.fn()
      bridge.onRecovered(recovered)
      const done = bridge.recoverWithRetry()
      // 8 轮 × 3s 退避全部跑完。
      await vi.advanceTimersByTimeAsync(30_000)
      await done
      expect(recovered).not.toHaveBeenCalled()
      expect(bridge.channels).toBe(old)
      bridge.dispose()
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('Subscription 换栈重订阅（协议-P1-1）', () => {
  it('ch 延迟取值：桥换栈后 resubscribe 挂到新 ChannelClient', async () => {
    const markersA: string[] = []
    const markersB: string[] = []
    let current = fakeChannel(markersA)
    const sub = new Subscription(
      () => current,
      {
        channel: 'zcode-agent',
        event: 'onDynamicConversationFrame',
        subscribeMethod: 'subscribeConversationV4',
        unsubscribeMethod: 'unsubscribeConversationV4',
        resyncMethod: 'resyncConversationV4',
        subscribeArgs: { sessionId: 's1' },
        unsubscribeArgs: {},
        resyncArgs: { forceSnapshot: true },
        tag: 'v4',
        scope: () => ({ workspacePath: 'C:\\proj' }),
        onFrame: () => {},
        getBase: () => ({ seq: 0, logEpoch: null }),
      },
    )
    await sub.start()
    expect(sub.ready).toBe(true)

    // 桥恢复：换新栈，重订阅。
    current = fakeChannel(markersB)
    sub.resubscribe()
    await vi.waitFor(() => expect(markersB).toContain('subscribeConversationV4'))
    // 新订阅拿到的是新 id；旧 id 的退订是 best-effort（可能发往死栈，忽略失败）。
    expect(sub.id).not.toBe(null)
    sub.cancel()
  })
})

describe('resync 单飞闸（协议-P1-2）', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  function gateHarness(markers: string[], failFirstResync: boolean) {
    let resyncCalls = 0
    const ch = {
      call: async (_c: string, method: string) => {
        markers.push(method)
        if (method.startsWith('subscribe'))
          return { ack: { subscriptionId: `sub-${markers.length}` } }
        if (method === 'resyncConversationV4') {
          resyncCalls += 1
          if (failFirstResync && resyncCalls === 1) throw new Error('first resync fails')
        }
        return {}
      },
      addEventListener: () => () => {},
    } as unknown as ChannelClient
    const sub = new Subscription(
      () => ch,
      {
        channel: 'zcode-agent',
        event: 'onDynamicConversationFrame',
        subscribeMethod: 'subscribeConversationV4',
        unsubscribeMethod: 'unsubscribeConversationV4',
        resyncMethod: 'resyncConversationV4',
        subscribeArgs: { sessionId: 's1' },
        unsubscribeArgs: {},
        resyncArgs: {},
        tag: 'v4',
        scope: () => ({}),
        onFrame: () => {},
        getBase: () => ({ seq: 0, logEpoch: null }),
      },
    )
    return sub
  }

  it('attempt-0 失败、重试已排程：闸不放，并发 resync 被合流', async () => {
    const markers: string[] = []
    const sub = gateHarness(markers, true)
    await sub.start()
    sub.resync()
    await Promise.resolve()
    // 重试排程在 1s 后；此刻闸应仍被握着——第二次 resync 必须被合流。
    sub.resync()
    await vi.advanceTimersByTimeAsync(1200)
    await vi.advanceTimersByTimeAsync(2500)
    // attempt-0 + 重试链各一次 = 2 次调用；并发那次被闸合流没有发。
    expect(markers.filter((m) => m === 'resyncConversationV4')).toHaveLength(2)
    // 链结束闸已放：新 resync 能正常发起。
    sub.resync()
    await vi.advanceTimersByTimeAsync(100)
    expect(markers.filter((m) => m === 'resyncConversationV4')).toHaveLength(3)
    sub.cancel()
  })

  it('链被 cancel 打断 → 闸释放，不会带进坟墓', async () => {
    const markers: string[] = []
    const sub = gateHarness(markers, true)
    await sub.start()
    sub.resync()
    await Promise.resolve()
    sub.cancel()
    // cancel 后闸已放——但 sub 已停，resync 不再发（行为锁定：不抛错即可）。
    expect(() => sub.resync()).not.toThrow()
  })
})
