// 信封解包与分片组装 —— 回归锁（**这是「聊天记录加载不出来」的根因所在**）。
//
// 服务端推来的不是逻辑帧本身，而是信封：
//   {kind:"complete", topic, subscriptionId, frame:{payload:{kind:"snapshot",…}}}
//   {kind:"fragment", logicalFrameId, fragmentIndex, fragmentCount, dataBase64}
// 原实现把信封当帧直接读 `payload`——`payload` 在信封的下一层，所以每一帧
// 都被静默丢弃：会话列表永远空、聊天记录永远加载不出来。这里把两种信封
// 的正确解包钉死。
import { describe, expect, it } from 'vitest'
import {
  FragmentAssembler,
  FragmentTable,
  base64ToBytes,
  bytesToBase64,
  unwrapEnvelope,
} from '../src/lib/fragments'

function b64(s: string): string {
  return bytesToBase64(new TextEncoder().encode(s))
}

describe('FragmentAssembler', () => {
  it('收齐才算完整', () => {
    const a = new FragmentAssembler(3)
    expect(a.isComplete).toBe(false)
    a.add(0, new Uint8Array([1]))
    a.add(1, new Uint8Array([2]))
    expect(a.isComplete).toBe(false)
    a.add(2, new Uint8Array([3]))
    expect(a.isComplete).toBe(true)
  })

  it('乱序到达也能按索引拼对', () => {
    const a = new FragmentAssembler(3)
    a.add(2, new Uint8Array([30]))
    a.add(0, new Uint8Array([10]))
    a.add(1, new Uint8Array([20]))
    expect([...a.assemble()]).toEqual([10, 20, 30])
  })

  it('重复片不重复计数（否则会提前判完成、拼出坏数据）', () => {
    const a = new FragmentAssembler(2)
    a.add(0, new Uint8Array([1]))
    a.add(0, new Uint8Array([1]))
    expect(a.isComplete).toBe(false)
    a.add(1, new Uint8Array([2]))
    expect(a.isComplete).toBe(true)
  })

  it('越界索引被忽略', () => {
    const a = new FragmentAssembler(2)
    a.add(-1, new Uint8Array([9]))
    a.add(5, new Uint8Array([9]))
    expect(a.isComplete).toBe(false)
  })
})

describe('FragmentTable', () => {
  it('单片即收齐时直接返回字节', () => {
    const t = new FragmentTable()
    const out = t.accept({
      logicalFrameId: 'f1',
      fragmentIndex: 0,
      fragmentCount: 1,
      dataBase64: b64('hello'),
    })
    expect(out).not.toBeNull()
    expect(new TextDecoder().decode(out!)).toBe('hello')
    expect(t.size).toBe(0)
  })

  it('多片按序收齐后返回拼接结果', () => {
    const t = new FragmentTable()
    const part0 = b64('{"a":')
    const part1 = b64('1}')
    expect(
      t.accept({ logicalFrameId: 'f2', fragmentIndex: 0, fragmentCount: 2, dataBase64: part0 }),
    ).toBeNull()
    expect(t.size).toBe(1)
    const out = t.accept({
      logicalFrameId: 'f2',
      fragmentIndex: 1,
      fragmentCount: 2,
      dataBase64: part1,
    })
    expect(new TextDecoder().decode(out!)).toBe('{"a":1}')
    expect(t.size).toBe(0)
  })

  it('缺字段 / 越界 / 片数非法 一律返回 null 且不建表', () => {
    const t = new FragmentTable()
    expect(t.accept({})).toBeNull()
    expect(t.accept({ logicalFrameId: 'x', fragmentIndex: 0, fragmentCount: 0, dataBase64: 'a' })).toBeNull()
    expect(t.accept({ logicalFrameId: 'x', fragmentIndex: 5, fragmentCount: 2, dataBase64: 'a' })).toBeNull()
    expect(t.accept({ logicalFrameId: 'x', fragmentIndex: 0, fragmentCount: 65, dataBase64: 'a' })).toBeNull()
    expect(t.size).toBe(0)
  })

  it('同一 logicalFrameId 的片数变了 → 丢弃重来（状态错乱不硬拼）', () => {
    const t = new FragmentTable()
    t.accept({ logicalFrameId: 'f3', fragmentIndex: 0, fragmentCount: 3, dataBase64: b64('a') })
    expect(t.size).toBe(1)
    t.accept({ logicalFrameId: 'f3', fragmentIndex: 0, fragmentCount: 2, dataBase64: b64('a') })
    expect(t.size).toBe(0)
  })

  it('不同 logicalFrameId 互不干扰（并发多帧）', () => {
    const t = new FragmentTable()
    t.accept({ logicalFrameId: 'a', fragmentIndex: 0, fragmentCount: 2, dataBase64: b64('A') })
    t.accept({ logicalFrameId: 'b', fragmentIndex: 0, fragmentCount: 2, dataBase64: b64('B') })
    expect(t.size).toBe(2)
    const a = t.accept({ logicalFrameId: 'a', fragmentIndex: 1, fragmentCount: 2, dataBase64: b64('1') })
    expect(new TextDecoder().decode(a!)).toBe('A1')
    expect(t.size).toBe(1)
  })

  it('过期片被清理（收不齐的帧不能一直占内存）', () => {
    const t = new FragmentTable(1000)
    t.accept({ logicalFrameId: 'f4', fragmentIndex: 0, fragmentCount: 2, dataBase64: b64('a') })
    expect(t.size).toBe(1)
    expect(t.purge(Date.now() + 2000)).toBe(1)
    expect(t.size).toBe(0)
  })

  it('非法 base64 丢弃该组而不是抛', () => {
    const t = new FragmentTable()
    expect(
      t.accept({ logicalFrameId: 'f5', fragmentIndex: 0, fragmentCount: 1, dataBase64: '!!!not-base64!!!' }),
    ).toBeNull()
    expect(t.size).toBe(0)
  })
})

describe('unwrapEnvelope', () => {
  it('kind=complete → 取内层 frame（**这是关键的一层**）', () => {
    const t = new FragmentTable()
    const inner = { payload: { kind: 'snapshot', snapshot: { rows: {} } } }
    const out = unwrapEnvelope({ kind: 'complete', subscriptionId: 's1', frame: inner }, t)
    expect(out).toBe(inner)
    expect(out!['payload']).toBeDefined()
  })

  it('kind=complete 但缺 frame → null（不猜）', () => {
    const t = new FragmentTable()
    expect(unwrapEnvelope({ kind: 'complete', subscriptionId: 's1' }, t)).toBeNull()
  })

  it('kind=fragment → 收齐后 JSON 解析出逻辑帧', () => {
    const t = new FragmentTable()
    const logical = { payload: { kind: 'deltas', deltas: [], fromSeq: 1, toSeq: 2 } }
    const raw = new TextEncoder().encode(JSON.stringify(logical))
    const half = Math.floor(raw.length / 2)
    expect(
      unwrapEnvelope(
        {
          kind: 'fragment',
          logicalFrameId: 'lf1',
          fragmentIndex: 0,
          fragmentCount: 2,
          dataBase64: bytesToBase64(raw.subarray(0, half)),
        },
        t,
      ),
    ).toBeNull()
    const out = unwrapEnvelope(
      {
        kind: 'fragment',
        logicalFrameId: 'lf1',
        fragmentIndex: 1,
        fragmentCount: 2,
        dataBase64: bytesToBase64(raw.subarray(half)),
      },
      t,
    )
    expect(out).toEqual(logical)
  })

  it('分片内容不是合法 JSON → null（不抛）', () => {
    const t = new FragmentTable()
    const out = unwrapEnvelope(
      {
        kind: 'fragment',
        logicalFrameId: 'lf2',
        fragmentIndex: 0,
        fragmentCount: 1,
        dataBase64: b64('not json at all'),
      },
      t,
    )
    expect(out).toBeNull()
  })

  it('未知 kind / 缺 kind → null（不认识的信封不猜）', () => {
    const t = new FragmentTable()
    expect(unwrapEnvelope({ kind: 'weird' }, t)).toBeNull()
    expect(unwrapEnvelope({}, t)).toBeNull()
  })
})

describe('base64 往返', () => {
  it('中文与二进制都能无损往返', () => {
    const bytes = new TextEncoder().encode('中文测试 · emoji 🎯')
    const round = base64ToBytes(bytesToBase64(bytes))
    expect(new TextDecoder().decode(round)).toBe('中文测试 · emoji 🎯')
  })

  it('大块（>32KiB 分块边界）也能正确编码', () => {
    const big = new Uint8Array(70_000)
    for (let i = 0; i < big.length; i++) big[i] = i % 256
    const round = base64ToBytes(bytesToBase64(big))
    expect(round.length).toBe(big.length)
    expect(round[0]).toBe(0)
    expect(round[69_999]).toBe(69_999 % 256)
  })
})
