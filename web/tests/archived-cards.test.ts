// 归档列表的解析回归锁。
//
// 钉的是一个必踩的坑：服务端归档项**每一条都带 `archived:true`**，
// 而主列表的解析器就是要按这个字段把它们过滤掉。归档视图若直接复用
// 主列表解析器，结果永远是空列表——看起来像「用户从没归档过任何东西」。
import { describe, expect, it } from 'vitest'
import { cardsFromTasks } from '../src/lib/sessions'

const archivedList = [
  { taskId: 's1', title: '旧的', archived: true, updatedAt: 1000 },
  { taskId: 's2', title: '更旧的', archived: true, updatedAt: 2000 },
  { taskId: '', title: '没有 id，丢掉', archived: true },
  { notATaskId: true },
]

describe('cardsFromTasks 的归档语义', () => {
  it('默认过滤 archived 与 deleted（主列表用）', () => {
    expect(cardsFromTasks(archivedList, new Set<string>())).toEqual([])
    expect(
      cardsFromTasks([{ taskId: 'x', deleted: true }], new Set<string>()).length,
    ).toBe(0)
  })

  it('keepArchived 时保留全部归档项，且仍丢掉无 id 的行', () => {
    const cards = cardsFromTasks(archivedList, new Set<string>(), { keepArchived: true })
    expect(cards.map((c) => c.sessionId)).toEqual(['s1', 's2'])
  })

  it('标题缺失时回退到 id 前缀（归档项也可能不带 title）', () => {
    const cards = cardsFromTasks([{ taskId: 'sess_abcdefghijklmnop', archived: true }], new Set(), {
      keepArchived: true,
    })
    expect(cards[0].title).toBe('sess_abcdefghijklm')
    expect(cards[0].pinned).toBe(false)
  })
})
