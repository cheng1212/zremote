// 附件条目解析与图片判定 —— 回归锁。
//
// 锁住的坑：附件字段名有多个历史叫法（mime/mediaType/mimeType、
// fileName/name），只认一个会漏；相册选出来的图经常没有 mime 也常无后缀，
// 只认 mime 会把图当普通文件显示成 chip。
import { describe, expect, it } from 'vitest'
import {
  attachmentLabel,
  attItems,
  isImageAttachment,
  isImageExt,
  rowAttachments,
  sniffImageMime,
} from '../src/lib/attachments'

describe('attItems —— 归一化', () => {
  it('三种 mime 字段名都认', () => {
    expect(attItems([{ mime: 'image/png' }])[0].mime).toBe('image/png')
    expect(attItems([{ mediaType: 'image/jpeg' }])[0].mime).toBe('image/jpeg')
    expect(attItems([{ mimeType: 'image/webp' }])[0].mime).toBe('image/webp')
  })

  it('fileName / name 都认', () => {
    expect(attItems([{ fileName: 'a.png' }])[0].fileName).toBe('a.png')
    expect(attItems([{ name: 'b.txt' }])[0].fileName).toBe('b.txt')
  })

  it('bytes / size / totalBytes 都认', () => {
    expect(attItems([{ bytes: 100 }])[0].size).toBe(100)
    expect(attItems([{ size: 200 }])[0].size).toBe(200)
    expect(attItems([{ totalBytes: 300 }])[0].size).toBe(300)
  })

  it('非列表 / 列表里的非对象项一律丢掉', () => {
    expect(attItems(null)).toEqual([])
    expect(attItems('oops')).toEqual([])
    expect(attItems([{ ref: 'r1' }, 'x', 42, null])).toHaveLength(1)
  })

  it('ref 缺失时给空串而不是 undefined（下游拼 key 不会崩）', () => {
    expect(attItems([{ fileName: 'x' }])[0].ref).toBe('')
  })
})

describe('isImageAttachment —— 图片判定', () => {
  it('mime 以 image/ 开头即图', () => {
    expect(isImageAttachment(attItems([{ mime: 'image/png' }])[0])).toBe(true)
    expect(isImageAttachment(attItems([{ mime: 'application/pdf' }])[0])).toBe(false)
  })

  it('mime 缺失时靠扩展名兜底（相册常见）', () => {
    expect(isImageAttachment(attItems([{ fileName: 'photo.JPG' }])[0])).toBe(true)
    expect(isImageAttachment(attItems([{ fileName: 'doc.pdf' }])[0])).toBe(false)
  })

  it('mime 与扩展名都没有 → 不算图（后面靠魔数补判）', () => {
    expect(isImageAttachment(attItems([{ ref: 'r' }])[0])).toBe(false)
  })

  it('扩展名判定大小写无关', () => {
    expect(isImageExt('PNG')).toBe(true)
    expect(isImageExt('Heic')).toBe(true)
    expect(isImageExt('txt')).toBe(false)
  })
})

describe('sniffImageMime —— 魔数补判', () => {
  it('PNG', () => {
    expect(sniffImageMime(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]))).toBe(
      'image/png',
    )
  })

  it('JPEG', () => {
    expect(sniffImageMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]))).toBe(
      'image/jpeg',
    )
  })

  it('GIF', () => {
    expect(sniffImageMime(new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0, 0, 0, 0, 0]))).toBe(
      'image/gif',
    )
  })

  it('WebP（RIFF…WEBP）', () => {
    const b = new Uint8Array(12)
    b.set([0x52, 0x49, 0x46, 0x46], 0)
    b.set([0x57, 0x45, 0x42, 0x50], 8)
    expect(sniffImageMime(b)).toBe('image/webp')
  })

  it('BMP', () => {
    expect(sniffImageMime(new Uint8Array([0x42, 0x4d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))).toBe('image/bmp')
  })

  it('不是图 / 太短 → null（不猜）', () => {
    expect(sniffImageMime(new TextEncoder().encode('hello world!'))).toBeNull()
    expect(sniffImageMime(new Uint8Array([0x89, 0x50]))).toBeNull()
    expect(sniffImageMime(new Uint8Array(0))).toBeNull()
  })

  it('RIFF 但不是 WEBP → null（避免误判 wav/avi）', () => {
    const b = new Uint8Array(12)
    b.set([0x52, 0x49, 0x46, 0x46], 0)
    b.set([0x57, 0x41, 0x56, 0x45], 8) // "WAVE"
    expect(sniffImageMime(b)).toBeNull()
  })
})

describe('attachmentLabel', () => {
  it('文件名优先', () => {
    expect(attachmentLabel(attItems([{ fileName: 'a.png', ref: 'r' }])[0])).toBe('a.png')
  })

  it('没文件名时取 ref 尾段', () => {
    expect(attachmentLabel(attItems([{ ref: 'sess/uploads/b.png' }])[0])).toBe('b.png')
    expect(attachmentLabel(attItems([{ ref: 'x\\y\\c.txt' }])[0])).toBe('c.txt')
  })

  it('都没有 → 「附件」兜底（不显示空白）', () => {
    expect(attachmentLabel(attItems([{}])[0])).toBe('附件')
  })
})

describe('rowAttachments', () => {
  it('从行里取 attachments', () => {
    const row = { kind: 'userInput', attachments: [{ ref: 'r1', fileName: 'a.png' }] }
    expect(rowAttachments(row)).toHaveLength(1)
    expect(rowAttachments(row)[0].fileName).toBe('a.png')
  })

  it('没有 attachments 字段 → 空数组', () => {
    expect(rowAttachments({ kind: 'assistantText' })).toEqual([])
  })
})
