// 会话列表合并 / 排序 / 过滤 —— 回归锁。
//
// 锁住的坑：置顶状态只认 listPinnedTasks（listTasks 不带置顶）；
// 排序不能信服务端给的顺序（来源顺序经多次洗牌不可预期，BUG-24 用户点名）；
// 合并时空值不覆盖（index 帧常只带 phase，不该冲掉已拿到的 title）。
import { describe, expect, it } from 'vitest'
import {
  cardsFromIndex,
  cardsFromTasks,
  filterCards,
  mergeCards,
  pinnedIdsFrom,
  sortCards,
  timeLabel,
  type SessionCard,
} from '../src/lib/sessions'

function card(p: Partial<SessionCard>): SessionCard {
  return {
    sessionId: 's',
    title: 't',
    phase: '',
    pinned: false,
    lastActivityAt: 0,
    preview: '',
    hasPendingInteraction: false,
    ...p,
  }
}

describe('cardsFromTasks', () => {
  it('抽 taskId/title/phase，并打上置顶标记', () => {
    const cards = cardsFromTasks(
      [{ taskId: 'a', title: '会话A', phase: 'running', updatedAt: 100 }],
      new Set(['a']),
    )
    expect(cards).toHaveLength(1)
    expect(cards[0]).toMatchObject({ sessionId: 'a', title: '会话A', phase: 'running', pinned: true })
  })

  it('过滤 archived / deleted（服务端会把归档项也放进来）', () => {
    const cards = cardsFromTasks(
      [
        { taskId: 'a', title: '留' },
        { taskId: 'b', title: '归档', archived: true },
        { taskId: 'c', title: '删除', deleted: true },
      ],
      new Set(),
    )
    expect(cards.map((c) => c.sessionId)).toEqual(['a'])
  })

  it('缺 title 时用 id 前缀兜底（不要显示空白行）', () => {
    const cards = cardsFromTasks([{ taskId: 'abcdefghijklmnopqrst' }], new Set())
    expect(cards[0].title).toBe('abcdefghijklmnopqr')
  })

  it('非数组输入返回空（防御服务端形状变化）', () => {
    expect(cardsFromTasks(null, new Set())).toEqual([])
    expect(cardsFromTasks({ oops: 1 }, new Set())).toEqual([])
  })

  it('时间字段名漂移时逐个试（lastActivityAt/updatedAt/lastActiveAt/createdAt）', () => {
    const cards = cardsFromTasks([{ taskId: 'a', lastActiveAt: 777 }], new Set())
    expect(cards[0].lastActivityAt).toBe(777)
  })
})

describe('pinnedIdsFrom', () => {
  it('只收 taskId 非空的项', () => {
    expect([...pinnedIdsFrom([{ taskId: 'a' }, {}, { taskId: '' }])]).toEqual(['a'])
  })
})

describe('cardsFromIndex', () => {
  it('从 sessions-index 快照抽 sessionId/phase/活跃时间', () => {
    const cards = cardsFromIndex([
      { sessionId: 'a', title: 'A', phase: 'running', lastActivityAt: 5, lastAssistantPreview: 'p' },
    ])
    expect(cards[0]).toMatchObject({ sessionId: 'a', phase: 'running', preview: 'p' })
  })
})

describe('mergeCards', () => {
  it('index 覆盖 phase/活跃时间，但空值不冲掉已有 title', () => {
    const base = [card({ sessionId: 'a', title: '标题', phase: 'idle', lastActivityAt: 1 })]
    const idx = [card({ sessionId: 'a', title: '', phase: 'running', lastActivityAt: 9 })]
    const merged = mergeCards(base, idx)
    expect(merged).toHaveLength(1)
    expect(merged[0].title).toBe('标题')
    expect(merged[0].phase).toBe('running')
    expect(merged[0].lastActivityAt).toBe(9)
  })

  it('index 里多出来的会话也补进来（本地还没拉到任务列表时不丢）', () => {
    const merged = mergeCards([card({ sessionId: 'a' })], [card({ sessionId: 'b' })])
    expect(merged.map((c) => c.sessionId).sort()).toEqual(['a', 'b'])
  })

  it('置顶状态以任务列表为准（index 不带置顶）', () => {
    const merged = mergeCards(
      [card({ sessionId: 'a', pinned: true })],
      [card({ sessionId: 'a', pinned: false, phase: 'running' })],
    )
    expect(merged[0].pinned).toBe(true)
  })
})

describe('sortCards', () => {
  it('置顶组在前，组内按活跃时间倒序', () => {
    const sorted = sortCards([
      card({ sessionId: 'old', lastActivityAt: 1 }),
      card({ sessionId: 'new', lastActivityAt: 9 }),
      card({ sessionId: 'pin-old', pinned: true, lastActivityAt: 2 }),
      card({ sessionId: 'pin-new', pinned: true, lastActivityAt: 8 }),
    ])
    expect(sorted.map((c) => c.sessionId)).toEqual(['pin-new', 'pin-old', 'new', 'old'])
  })

  it('活跃时间缺失（0）排最后，不顶到用户眼前', () => {
    const sorted = sortCards([card({ sessionId: 'zero' }), card({ sessionId: 'has', lastActivityAt: 5 })])
    expect(sorted.map((c) => c.sessionId)).toEqual(['has', 'zero'])
  })

  it('不改原数组（纯函数）', () => {
    const input = [card({ sessionId: 'a', lastActivityAt: 1 }), card({ sessionId: 'b', lastActivityAt: 2 })]
    const copy = [...input]
    sortCards(input)
    expect(input).toEqual(copy)
  })
})

describe('filterCards / timeLabel', () => {
  it('标题大小写无关匹配，空查询原样返回', () => {
    const cards = [card({ sessionId: 'a', title: 'Fix Bug' }), card({ sessionId: 'b', title: '别的' })]
    expect(filterCards(cards, '').length).toBe(2)
    expect(filterCards(cards, 'fix').map((c) => c.sessionId)).toEqual(['a'])
    expect(filterCards(cards, 'zzz')).toEqual([])
  })

  it('相对时间文案分级', () => {
    const now = 1_700_000_000_000
    expect(timeLabel(0, now)).toBe('')
    expect(timeLabel(now - 10_000, now)).toBe('刚刚')
    expect(timeLabel(now - 5 * 60_000, now)).toBe('5 分钟前')
    expect(timeLabel(now - 3 * 3_600_000, now)).toBe('3 小时前')
    expect(timeLabel(now - 2 * 86_400_000, now)).toBe('2 天前')
  })
})
