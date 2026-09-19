// ChannelClient 的 ready 握手回归锁。
//
// 钉三件踩过的现实：
// 1. **多等待者**：`ready` 早先每次访问都新建 Promise 并覆盖 `readyResolve`，
//    于是只最后一个 await 者会被 initialize 唤醒。`loadSessions()` 用
//    `Promise.allSettled([listTasks, listPinnedTasks])` 并发拉两路——冷桥面上
//    先发起的那一路永远拿不到唤醒，白等满 30s 超时才失败。
// 2. **计时器必须清**：`waitForReady` 的 30s 超时原先不 clear，race 胜出后
//    仍留一个定时器 + 闭包；在手机上每次调用都留一个。
// 3. **dispose 之后不能再发**：`addEventListener` 的 `ready.then` 可能在桥拆了
//    之后才落地，那条浮动 promise 里的 send 会变成 unhandled rejection。
import { describe, expect, it, vi } from 'vitest'
import { ChannelClient } from '../src/protocol/channelClient'
import { ValueReader, ValueWriter } from '../src/protocol/valueCodec'

function encode(header: unknown[], data?: unknown): Uint8Array {
  const w = new ValueWriter()
  w.writeValue(header)
  if (data !== undefined) w.writeValue(data)
  return w.take()
}

function decodeRequest(body: Uint8Array): { reqType: number; id: number; method: string } {
  const r = new ValueReader(body)
  const header = r.readValue() as [number, number, string, string]
  return { reqType: header[0], id: header[1], method: header[3] }
}

function harness() {
  const sent: Uint8Array[] = []
  const ch = new ChannelClient((b) => sent.push(b))
  return { ch, sent }
}

describe('ChannelClient ready 握手', () => {
  it('initialize 之前并发的两路调用都能拿到唤醒并各自回执', async () => {
    vi.useFakeTimers()
    try {
      const { ch, sent } = harness()
      const a = ch.call('zcode-task', 'listTasks', [{}])
      const b = ch.call('zcode-task', 'listPinnedTasks', [{}])

      // 握手前不该把请求发出去
      expect(sent.length).toBe(0)
      ch.handleMessage(encode([200]))
      await vi.advanceTimersByTimeAsync(0)

      // 原实现：只有一路能等到 initialize，另一路挂在 30s 超时上
      expect(sent.length).toBe(2)
      const reqs = sent.map(decodeRequest)
      expect(reqs.map((r) => r.method)).toEqual(['listTasks', 'listPinnedTasks'])
      expect(new Set(reqs.map((r) => r.id)).size).toBe(2)

      for (const r of reqs) ch.handleMessage(encode([201, r.id], { ok: r.method }))
      expect(await Promise.all([a, b])).toEqual([
        { ok: 'listTasks' },
        { ok: 'listPinnedTasks' },
      ])
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('initialize 永不到达时按 30s 报错，且不留悬空计时器', async () => {
    vi.useFakeTimers()
    try {
      const { ch, sent } = harness()
      const p = ch.call('zcode-task', 'listTasks', [{}])
      const settled = expect(p).rejects.toThrow('channel init timeout')
      await vi.advanceTimersByTimeAsync(30_000)
      await settled
      expect(sent.length).toBe(0)
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('在途调用超时后 handler 与 pending 一起清掉（不漏表项）', async () => {
    vi.useFakeTimers()
    try {
      const { ch, sent } = harness()
      const p = ch.call('zcode-task', 'listTasks', [{}], 5_000)
      ch.handleMessage(encode([200]))
      await vi.advanceTimersByTimeAsync(0)
      expect(sent.length).toBe(1)
      const settled = expect(p).rejects.toThrow('listTasks timed out')
      await vi.advanceTimersByTimeAsync(5_000)
      await settled
      expect(vi.getTimerCount()).toBe(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('dispose 后取消事件监听不再触碰已死的 sendBody', async () => {
    const sends: Uint8Array[] = []
    const ch = new ChannelClient((b) => sends.push(b))
    ch.handleMessage(encode([200]))
    const off = ch.addEventListener('zcode-agent', 'onDynamicConversationFrame', () => {})
    await Promise.resolve()
    await Promise.resolve()
    ch.dispose()
    // 原实现：这里会 send(EVENT_DISPOSE) → sendBody 抛出，
    // 而它通常在 onUnmounted 里被调用，异常直接冒到生命周期钩子上。
    expect(() => off()).not.toThrow()
  })

  it('dispose 之后的调用立刻失败（不再排队等握手）', async () => {
    const { ch } = harness()
    ch.dispose()
    await expect(ch.call('zcode-task', 'listTasks', [{}])).rejects.toThrow('channel disposed')
  })
})
