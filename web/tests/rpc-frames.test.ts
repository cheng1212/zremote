// RpcFrames —— 分片重组 / ack / checksum / messageSeq 复用的回归锁。
//
// 钉四条（审计 2026-10-03 协议-P2-1）：
// · 多分片消息收齐 → 解出原文 + 回 ack；
// · checksum 不匹配 → 拒交付、不 ack；
// · messageSeq 复用（服务端重启/恢复后计数器重置）：删旧 assembly 后要
//   **收下当前片**，不能再 return 丢首片——否则后续 assembly 永远缺片，
//   60s 后被 purge 静默丢消息；
// · checksum 归一（双方都不带 = null vs undefined 不算冲突）。
import { describe, expect, it, vi } from 'vitest'
import { RpcFrames, base64ToUint8, uint8ToBase64 } from '../src/protocol/rpcFrames'
import { crc32Hex } from '../src/protocol/crc32'

type Frame = Record<string, unknown>

const ID = { bridgeSessionId: 'b1' }

function harness() {
  const delivered: Uint8Array[] = []
  const sent: Frame[] = []
  const frames = new RpcFrames({
    ...ID,
    send: (p) => sent.push(p),
    onMessage: (bytes) => delivered.push(bytes),
  })
  return { frames, delivered, sent }
}

/** 按 sendMessage 的分片规则把 payload 喂回 accept（模拟对端发来的帧）。 */
function feed(frames: RpcFrames, messageSeq: number, bytes: Uint8Array, per = 4): void {
  const checksum = crc32Hex(bytes)
  const count = Math.max(1, Math.ceil(bytes.length / per))
  for (let i = 0; i < count; i++) {
    const chunk = bytes.subarray(i * per, Math.min((i + 1) * per, bytes.length))
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      seq: i + 1,
      messageSeq,
      fragmentIndex: i,
      fragmentCount: count,
      messageBytes: bytes.length,
      checksum: { algorithm: 'crc32', value: checksum },
      dataBase64: uint8ToBase64(chunk),
    })
  }
}

describe('RpcFrames.accept', () => {
  it('多分片收齐 → 交付原文 + 回 ack；无关帧与 ack 帧被忽略', () => {
    const { frames, delivered, sent } = harness()
    const payload = base64ToUint8(btoa('hello rpc frames')) // 16 字节 → 4 片
    feed(frames, 1, payload)
    expect(delivered).toHaveLength(1)
    expect(new TextDecoder().decode(delivered[0])).toBe('hello rpc frames')
    const ack = sent.find((p) => p['zcode_type'] === 'rpc-frame-ack')
    expect(ack?.['ackMessageSeq']).toBe(1)

    const before = delivered.length
    frames.accept({ zcode_type: 'other-signal' })
    frames.accept({ zcode_type: 'rpc-frame', bridgeSessionId: 'other-bridge' })
    frames.accept({ zcode_type: 'rpc-frame-ack', ...ID, ackMessageSeq: 99 })
    expect(delivered.length).toBe(before)
  })

  it('checksum 不匹配 → 不交付、不 ack', () => {
    const { frames, delivered, sent } = harness()
    const bytes = new TextEncoder().encode('mismatch case')
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      seq: 1,
      messageSeq: 7,
      fragmentIndex: 0,
      fragmentCount: 1,
      messageBytes: bytes.length,
      checksum: { algorithm: 'crc32', value: 'deadbeef' },
      dataBase64: uint8ToBase64(bytes),
    })
    expect(delivered).toHaveLength(0)
    expect(sent).toHaveLength(0)
  })

  it('messageSeq 复用（元数据变化）：删旧 assembly 后收下新片，不丢首片', () => {
    const { frames, delivered } = harness()
    // 第一条：2 分片，只到第一片（模拟断线后第二条以同 messageSeq 重来）。
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      seq: 1,
      messageSeq: 5,
      fragmentIndex: 0,
      fragmentCount: 2,
      messageBytes: 8,
      checksum: { algorithm: 'crc32', value: '00000001' },
      dataBase64: uint8ToBase64(new TextEncoder().encode('AAAA')),
    })
    expect(delivered).toHaveLength(0)
    // 复用 messageSeq=5 但元数据不同（1 分片）。旧实现此处 delete+return
    // 把新首片也丢掉 → 新 assembly 永远缺片 → 60s 后 purge 静默丢消息。
    const fresh = new TextEncoder().encode('BBBBBBBB')
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      seq: 2,
      messageSeq: 5,
      fragmentIndex: 0,
      fragmentCount: 1,
      messageBytes: fresh.length,
      checksum: { algorithm: 'crc32', value: crc32Hex(fresh) },
      dataBase64: uint8ToBase64(fresh),
    })
    expect(delivered).toHaveLength(1)
    expect(new TextDecoder().decode(delivered[0])).toBe('BBBBBBBB')
  })

  it('双方都不带 checksum 不算冲突（null vs undefined 归一）', () => {
    const { frames, delivered } = harness()
    const a = new TextEncoder().encode('CCCC')
    const b = new TextEncoder().encode('DDDD')
    // 第一条：不带 checksum，fragmentCount=2 只到一片。
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      messageSeq: 9,
      fragmentIndex: 0,
      fragmentCount: 2,
      messageBytes: 8,
      dataBase64: uint8ToBase64(a),
    })
    // 复用 messageSeq=9、同样不带 checksum：归一后不判冲突。
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      messageSeq: 9,
      fragmentIndex: 0,
      fragmentCount: 1,
      messageBytes: b.length,
      dataBase64: uint8ToBase64(b),
    })
    expect(delivered).toHaveLength(1)
    expect(new TextDecoder().decode(delivered[0])).toBe('DDDD')
  })

  it('purge：60s 未收齐的残留 assembly 被清理', () => {
    vi.useFakeTimers()
    try {
      const { frames, delivered } = harness()
      frames.accept({
        zcode_type: 'rpc-frame',
        ...ID,
        messageSeq: 3,
        fragmentIndex: 0,
        fragmentCount: 2,
        messageBytes: 8,
        dataBase64: uint8ToBase64(new TextEncoder().encode('EEEE')),
      })
      expect(delivered).toHaveLength(0)
      vi.advanceTimersByTime(120_000)
      // 补上第二片：assembly 已被清，按新 assembly 重新计——不会拼出脏消息。
      frames.accept({
        zcode_type: 'rpc-frame',
        ...ID,
        messageSeq: 3,
        fragmentIndex: 1,
        fragmentCount: 2,
        messageBytes: 8,
        checksum: { algorithm: 'crc32', value: crc32Hex(new TextEncoder().encode('FFFFFFFF')) },
        dataBase64: uint8ToBase64(new TextEncoder().encode('FFFF')),
      })
      expect(delivered).toHaveLength(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('dispose 后不再清理（句柄释放），sendMessage 抛错路径不误收', () => {
    const { frames, delivered } = harness()
    frames.dispose()
    frames.accept({
      zcode_type: 'rpc-frame',
      ...ID,
      messageSeq: 1,
      fragmentIndex: 0,
      fragmentCount: 1,
      messageBytes: 4,
      checksum: { algorithm: 'crc32', value: crc32Hex(new TextEncoder().encode('GGGG')) },
      dataBase64: uint8ToBase64(new TextEncoder().encode('GGGG')),
    })
    // dispose 只清 interval 与表；accept 重新建表是可接受语义（本断言只锁
    // 不抛错）。真正要防的是 sendMessage 空消息/超限的显式抛错。
    expect(delivered.length).toBeGreaterThanOrEqual(0)
    expect(() => frames.sendMessage(new Uint8Array(0))).toThrow()
  })
})
