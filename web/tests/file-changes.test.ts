// 文件变更清单与回滚目标的解析回归锁（移植 Flutter describeFileChange 的行为）。
import { describe, expect, it } from 'vitest'
import {
  describeFileChange,
  fileChangeAction,
  parseFileChanges,
  parseRewindPreview,
  rewindTargetOf,
  rowFileChangeBadge,
} from '../src/lib/fileChanges'

describe('describeFileChange', () => {
  it('路径有四种叫法', () => {
    for (const key of ['path', 'file', 'filePath', 'relPath']) {
      const row = describeFileChange({ [key]: 'a/b.ts', changeType: 'modified' })
      expect(row?.path).toBe('a/b.ts')
    }
  })

  it('没有路径整行丢弃（"某文件被改了"对用户没有价值）', () => {
    expect(describeFileChange({ changeType: 'modified' })).toBe(null)
    expect(describeFileChange(null)).toBe(null)
    expect(describeFileChange([])).toBe(null)
  })

  it('动作标签：认得的翻中文，认不出的原样显示，不谎报成"修改"', () => {
    expect(fileChangeAction('created')).toBe('新建')
    expect(fileChangeAction('removed')).toBe('删除')
    expect(fileChangeAction('rename')).toBe('重命名')
    expect(fileChangeAction('')).toBe('修改')
    expect(fileChangeAction('cherry_picked')).toBe('cherry_picked')
  })

  it('增删统计只报非零项', () => {
    expect(describeFileChange({ path: 'x', additions: 12, deletions: 0 })?.stats).toBe('+12')
    expect(describeFileChange({ path: 'x', additions: 12, deletions: 3 })?.stats).toBe('+12 -3')
    expect(describeFileChange({ path: 'x' })?.stats).toBe('')
  })
})

describe('parseFileChanges', () => {
  const items = [
    { path: 'a.ts', changeType: 'added', additions: 10 },
    { path: 'b.ts', changeType: 'modified', deletions: 2, additions: 1 },
  ]

  it('裸数组 / {items} / {files} / {changes} 四种包装都认', () => {
    for (const raw of [items, { items }, { files: items }, { changes: items }]) {
      expect(parseFileChanges(raw).items.length).toBe(2)
    }
  })

  it('汇总优先用服务端给的，缺了才自己加', () => {
    expect(parseFileChanges({ items, files: 9, additions: 40, deletions: 7 })).toEqual({
      items: expect.any(Array),
      files: 9,
      additions: 40,
      deletions: 7,
    })
    const self = parseFileChanges(items)
    expect(self.files).toBe(2)
    expect(self.additions).toBe(11)
    expect(self.deletions).toBe(2)
  })

  it('认不出的一律空清单，不抛', () => {
    expect(parseFileChanges(null).items).toEqual([])
    expect(parseFileChanges('x').files).toBe(0)
  })
})

describe('回合摘要与回滚目标', () => {
  it('turnHeader 自带的 fileChanges 生成入口文案', () => {
    expect(rowFileChangeBadge({ fileChanges: { files: 3, additions: 12, deletions: 1 } })).toBe(
      '改动 3 个文件 · +12 -1',
    )
    expect(rowFileChangeBadge({ fileChanges: { files: 0 } })).toBe('')
    expect(rowFileChangeBadge({})).toBe('')
  })

  it('entityId 缺失就不给回滚目标（服务端 schema 要求 min(1)）', () => {
    expect(rewindTargetOf({ rowId: 5, entityId: 'e1' })).toEqual({ rowId: 5, entityId: 'e1' })
    expect(rewindTargetOf({ rowId: 5 })).toBe(null)
    expect(rewindTargetOf({ rowId: 5, entityId: '' })).toBe(null)
    expect(rewindTargetOf({ rowId: '5', entityId: 'e1' })).toBe(null)
  })

  it('预览：canApply 只在明确 true 时为真；文件计数认数组也认数字', () => {
    const p = parseRewindPreview({
      canApply: true,
      safeFiles: ['a', 'b'],
      unsafeFiles: 1,
      ignoredFiles: [],
    })
    expect(p).toEqual({ canApply: true, safe: 2, unsafe: 1, ignored: 0, reason: '' })
    expect(parseRewindPreview({ canApply: 'yes' }).canApply).toBe(false)
    expect(parseRewindPreview(null)).toEqual({
      canApply: false,
      safe: 0,
      unsafe: 0,
      ignored: 0,
      reason: '意外形状',
    })
  })

  it('失败原因取 message，退化取 reason', () => {
    expect(parseRewindPreview({ message: 'm' }).reason).toBe('m')
    expect(parseRewindPreview({ reason: 'r' }).reason).toBe('r')
  })
})
