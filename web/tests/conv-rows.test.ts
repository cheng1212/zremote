// 会话行状态与 deltas 应用 —— 回归锁。
//
// 这一组测试锁住的是**服务端真实协议形状**（docs/API.md L5「deltas op」五态）。
// 背景：Web 端原实现按 `upsert` / `delete` 两个键取值，与真实协议对不上，
// 导致每个 delta 都被静默忽略——**流式回复永远不增长**，只有重进会话
// （整份快照）才看得到内容。这里把形状钉死，防止再漂移。
import { describe, expect, it } from 'vitest'
import {
  applyDelta,
  applyDeltasFrame,
  applySnapshot,
  createConvState,
  hasMoreOlder,
  mergeOlder,
  olderCursor,
  type ConvState,
} from '../src/lib/convRows'

function snapState(rows: Record<string, unknown>[], totalCount?: number): ConvState {
  const s = createConvState()
  applySnapshot(s, {
    logEpoch: 'e1',
    rows: { window: rows, totalCount: totalCount ?? rows.length, firstRowId: rows[0]?.['rowId'] },
  })
  return s
}

describe('applySnapshot', () => {
  it('取 rows.window 并记 firstRowId / totalCount', () => {
    const s = snapState([{ rowId: 5, kind: 'userInput', text: 'a' }], 40)
    expect(s.rows).toHaveLength(1)
    expect(s.firstRowId).toBe(5)
    expect(s.totalCount).toBe(40)
    expect(s.logEpoch).toBe('e1')
    expect(s.ready).toBe(true)
  })

  it('保留已翻页拉回的更早行（否则 resync 会丢掉用户翻出来的历史）', () => {
    const s = snapState([{ rowId: 100 }, { rowId: 101 }])
    // 模拟用户已往前翻了 3 条
    mergeOlder(s, [{ rowId: 97 }, { rowId: 98 }, { rowId: 99 }])
    expect(s.rows.map((r) => r['rowId'])).toEqual([97, 98, 99, 100, 101])
    // 服务端重发快照（窗口仍是 100/101）——更早的 97~99 必须还在
    applySnapshot(s, {
      logEpoch: 'e1',
      rows: { window: [{ rowId: 100 }, { rowId: 101 }], totalCount: 40, firstRowId: 100 },
    })
    expect(s.rows.map((r) => r['rowId'])).toEqual([97, 98, 99, 100, 101])
  })
})

describe('applyDelta —— 五态 op（形状来自服务端实测）', () => {
  it('row.appended 追加并抬 totalCount', () => {
    const s = snapState([{ rowId: 1, kind: 'userInput' }])
    applyDelta(s, { op: 'row.appended', row: { rowId: 2, kind: 'assistantText', text: 'hi' } })
    expect(s.rows).toHaveLength(2)
    expect(s.totalCount).toBe(2)
    expect(s.rows[1]['text']).toBe('hi')
  })

  it('row.delta 按 path 追加文本 —— 这就是流式增长的路径', () => {
    const s = snapState([{ rowId: 1, kind: 'assistantText', text: '你' }])
    applyDelta(s, { op: 'row.delta', rowId: 1, path: 'text', append: '好' })
    applyDelta(s, { op: 'row.delta', rowId: 1, path: 'text', append: '呀' })
    expect(s.rows[0]['text']).toBe('你好呀')
  })

  it('row.delta 的 path 与 kind 不匹配时不串字段', () => {
    const s = snapState([{ rowId: 1, kind: 'userInput', text: 'x' }])
    // inputText 只该打在 toolCall 上
    applyDelta(s, { op: 'row.delta', rowId: 1, path: 'inputText', append: 'ZZZ' })
    expect(s.rows[0]['inputText']).toBeUndefined()
    expect(s.rows[0]['text']).toBe('x')
  })

  it('row.delta output.text 落在 output.text 上（工具卡输出）', () => {
    const s = snapState([{ rowId: 1, kind: 'toolCall', output: { text: 'line1\n' } }])
    applyDelta(s, { op: 'row.delta', rowId: 1, path: 'output.text', append: 'line2\n' })
    expect((s.rows[0]['output'] as Record<string, unknown>)['text']).toBe('line1\nline2\n')
  })

  it('row.upserted 替换整行但保留 localTs（否则时间戳每次更新都跳成「刚刚」）', () => {
    const s = snapState([{ rowId: 1, kind: 'assistantText', text: 'a' }])
    const firstTs = s.rows[0]['localTs']
    expect(firstTs).toBeTypeOf('number')
    applyDelta(s, { op: 'row.upserted', row: { rowId: 1, kind: 'assistantText', text: 'ab' } })
    expect(s.rows[0]['text']).toBe('ab')
    expect(s.rows[0]['localTs']).toBe(firstTs)
  })

  it('row.removed 用 fromRowId 截断（保留更小的），不是删单个 rowId', () => {
    const s = snapState([{ rowId: 1 }, { rowId: 2 }, { rowId: 3 }], 3)
    applyDelta(s, { op: 'row.removed', fromRowId: 3 })
    expect(s.rows.map((r) => r['rowId'])).toEqual([1, 2])
    expect(s.totalCount).toBe(2)
  })

  it('row.removed 从窗口头开始删 → 列表清空、firstRowId 归零', () => {
    const s = snapState([{ rowId: 1 }, { rowId: 2 }], 2)
    applyDelta(s, { op: 'row.removed', fromRowId: 1 })
    expect(s.rows).toHaveLength(0)
    expect(s.firstRowId).toBeNull()
    expect(s.totalCount).toBe(0)
  })

  it('state.updated 的 config 只合不替（防抹掉没变的 approvalMode/followupMode）', () => {
    const s = createConvState()
    applySnapshot(s, {
      control: { phase: 'idle' },
      config: { provider: 'glm', model: 'a', approvalMode: 'autoEdit', followupMode: 'queue' },
    })
    applyDelta(s, {
      op: 'state.updated',
      patch: { config: { provider: 'glm', model: 'b' } },
    })
    const cfg = (s.snapshot?.['config'] ?? {}) as Record<string, unknown>
    expect(cfg['model']).toBe('b')
    expect(cfg['approvalMode']).toBe('autoEdit')
    expect(cfg['followupMode']).toBe('queue')
  })

  it('快照未到时 state.updated 暂存，快照到达后合并生效', () => {
    const s = createConvState()
    applyDelta(s, { op: 'state.updated', patch: { control: { phase: 'running' } } })
    expect(s.pendingPatch).not.toBeNull()
    applySnapshot(s, { control: { phase: 'idle' }, rows: { window: [] } })
    expect((s.snapshot?.['control'] as Record<string, unknown>)['phase']).toBe('running')
    expect(s.pendingPatch).toBeNull()
  })

  it('未知 op 静默忽略，不影响同一批其它 delta', () => {
    const s = snapState([{ rowId: 1, kind: 'assistantText', text: 'a' }])
    applyDelta(s, { op: 'future.thing', whatever: 1 })
    applyDelta(s, { op: 'row.delta', rowId: 1, path: 'text', append: 'b' })
    expect(s.rows[0]['text']).toBe('ab')
  })
})

describe('applyDeltasFrame —— seq 连续性', () => {
  it('seq 对齐时应用并推进', () => {
    const s = snapState([{ rowId: 1, kind: 'assistantText', text: 'a' }])
    s.seq = 7
    const r = applyDeltasFrame(
      s,
      { fromSeq: 7, toSeq: 8 },
      { kind: 'deltas', deltas: [{ op: 'row.delta', rowId: 1, path: 'text', append: 'b' }] },
    )
    expect(r).toBe('ok')
    expect(s.seq).toBe(8)
    expect(s.rows[0]['text']).toBe('ab')
  })

  it('断档时返回 gap 且**不推进 seq**、不应用 delta', () => {
    const s = snapState([{ rowId: 1, kind: 'assistantText', text: 'a' }])
    s.seq = 7
    const r = applyDeltasFrame(
      s,
      { fromSeq: 9, toSeq: 10 },
      { kind: 'deltas', deltas: [{ op: 'row.delta', rowId: 1, path: 'text', append: 'b' }] },
    )
    expect(r).toBe('gap')
    // seq 语义是「已应用的序号」——本帧没应用就不该推进；
    // 推进了会把后续合法帧也误判成 gap（这正是 protocol_test 锁住的语义）。
    expect(s.seq).toBe(7)
    expect(s.rows[0]['text']).toBe('a')
  })
})

describe('翻页', () => {
  it('olderCursor 取窗口最小 rowId（不是 firstRowId 字段——BUG-28）', () => {
    const s = snapState([{ rowId: 50 }, { rowId: 51 }], 100)
    expect(olderCursor(s)).toBe(50)
    mergeOlder(s, [{ rowId: 48 }, { rowId: 49 }])
    expect(olderCursor(s)).toBe(48)
  })

  it('mergeOlder 去重、升序、前置，返回新增数', () => {
    const s = snapState([{ rowId: 10 }, { rowId: 11 }])
    const added = mergeOlder(s, [{ rowId: 11 }, { rowId: 9 }, { rowId: 8 }])
    expect(added).toBe(2)
    expect(s.rows.map((r) => r['rowId'])).toEqual([8, 9, 10, 11])
  })

  it('重复拉同一批返回 0（调用方据此停翻页）', () => {
    const s = snapState([{ rowId: 10 }])
    mergeOlder(s, [{ rowId: 9 }])
    expect(mergeOlder(s, [{ rowId: 9 }])).toBe(0)
  })

  it('hasMoreOlder：窗口条数 < totalCount 才算还有更早', () => {
    const s = snapState([{ rowId: 50 }, { rowId: 51 }], 40)
    expect(hasMoreOlder(s)).toBe(true)
    // 拉满到 totalCount 后就没有了
    const full = snapState(
      Array.from({ length: 40 }, (_, i) => ({ rowId: i + 1 })),
      40,
    )
    expect(hasMoreOlder(full)).toBe(false)
    // firstRowId 为 null（空列表）时也没有更早
    expect(hasMoreOlder(createConvState())).toBe(false)
  })
})
