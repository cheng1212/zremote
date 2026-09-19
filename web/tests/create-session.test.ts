// createSession 与 CAS 本地闸 —— 协议层回归锁。
//
// 钉的是「手机上开不出新会话」这块补齐后的行为，以及两条血泪结论：
// · createSession 的 `sessionId` 在信封里是 **null**，工作区走 payload.workspaceId；
// · 远端拒绝（provider 不在册等）也是 RPC 成功，只有 `status` 能分辨——
//   只看 promise 通不通会把失败当成功（Flutter conversation.dart:341 同结论）。
import { describe, expect, it } from 'vitest'
import { ConversationV4 } from '../src/protocol/conversation'
import type { Bridge } from '../src/protocol/remoteSession'
import type { ChannelClient } from '../src/protocol/channelClient'

interface Sent {
  method: string
  args: unknown[]
  timeoutMs?: number
}

function stub(responder: (method: string, args: unknown[]) => unknown) {
  const sent: Sent[] = []
  const ch = {
    call: async (channel: string, method: string, args: unknown[], timeoutMs?: number) => {
      sent.push({ method, args, timeoutMs })
      return responder(method, args)
    },
    addEventListener: () => () => {},
  } as unknown as ChannelClient
  const bridge = { channels: ch, scope: { workspacePath: 'C:\\proj' } } as unknown as Bridge
  return { conv: new ConversationV4(bridge, () => {}), sent }
}

const ok = (): unknown => undefined

describe('createSession', () => {
  it('accepted 时回 sessionId，信封 sessionId 为 null，且不塞 firstInput', async () => {
    const { conv, sent } = stub((m) =>
      m === 'sendConversationCommandV4'
        ? { status: 'accepted', result: { sessionId: 'sess_new_1' } }
        : { connectionId: 'c1' },
    )
    const id = await conv.createSession('C:\\proj')
    expect(id).toBe('sess_new_1')

    const cmd = sent.find((s) => s.method === 'sendConversationCommandV4')
    expect(cmd).toBeTruthy()
    const env = cmd?.args[0] as Record<string, unknown>
    expect(env['sessionId']).toBe(null)
    expect(env['type']).toBe('createSession')
    expect(env['payload']).toEqual({ workspaceId: 'C:\\proj' })
    // 冷启动 agent 运行时可能很久：必须用 90s，不能用默认 30s
    expect(cmd?.timeoutMs).toBe(90_000)
  })

  it('带 config 时随建会话下发（模型闸门的前置条件）', async () => {
    const { conv, sent } = stub(() => ({ status: 'accepted', result: { sessionId: 's2' } }))
    await conv.createSession('k', { config: { provider: 'p', model: 'p/m' } })
    const env = sent[sent.length - 1].args[0] as Record<string, unknown>
    expect(env['payload']).toEqual({ workspaceId: 'k', config: { provider: 'p', model: 'p/m' } })
  })

  it('result 直接是字符串也能认（服务端形状兜底）', async () => {
    const { conv } = stub(() => ({ status: 'accepted', result: 's3' }))
    await expect(conv.createSession('k')).resolves.toBe('s3')
  })

  it('status 非 accepted 一律当失败，并把 reasonCode 带进文案', async () => {
    const { conv } = stub(() => ({
      status: 'rejected',
      reasonCode: 'provider_not_registered',
      message: 'provider 不在册',
    }))
    await expect(conv.createSession('k')).rejects.toThrow(/provider_not_registered/)
  })

  it('accepted 但没回 sessionId → 明确报错，不返回空串', async () => {
    const { conv } = stub(() => ({ status: 'accepted', result: {} }))
    await expect(conv.createSession('k')).rejects.toThrow(/sessionId/)
  })
})

describe('CAS 本地闸（桌面分派层强制，先本地拦）', () => {
  it('CAS 命令缺 baseRevision 不发网络请求', async () => {
    const { conv, sent } = stub(ok)
    await expect(
      conv.sendCommand('s1', 'applyFileRewind', {}, { baseRevision: null, logEpoch: 'e1' }),
    ).rejects.toThrow(/baseRevision/)
    expect(sent.some((s) => s.method === 'sendConversationCommandV4')).toBe(false)
  })

  it('行级 target 命令缺 baseLogEpoch 同样本地拦', async () => {
    const { conv, sent } = stub(ok)
    await expect(
      conv.sendCommand('s1', 'retryTurn', {}, { baseRevision: 7, logEpoch: null }),
    ).rejects.toThrow(/baseLogEpoch/)
    expect(sent.some((s) => s.method === 'sendConversationCommandV4')).toBe(false)
  })

  it('两个都带齐 → 信封里出现 baseRevision / baseLogEpoch', async () => {
    const { conv, sent } = stub(ok)
    await conv.sendCommand('s1', 'retryTurn', { target: { rowId: 3 } }, {
      baseRevision: 7,
      logEpoch: 'ep1',
    })
    const env = sent[sent.length - 1].args[0] as Record<string, unknown>
    expect(env['baseRevision']).toBe(7)
    expect(env['baseLogEpoch']).toBe('ep1')
  })

  it('非 CAS 命令不带这两个字段（带了服务端可能拒）', async () => {
    const { conv, sent } = stub(ok)
    await conv.sendCommand('s1', 'sendText', { text: 'hi' }, { baseRevision: 3, logEpoch: 'ep' })
    const env = sent[sent.length - 1].args[0] as Record<string, unknown>
    expect('baseRevision' in env).toBe(false)
    expect('baseLogEpoch' in env).toBe(false)
  })
})
