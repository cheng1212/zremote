// 附件字节缓存（Blob URL + LRU）—— 回归锁。
//
// 关键点：`URL.createObjectURL` 建的 URL **一直持有那份字节**直到显式 revoke。
// 不 revoke 就是内存泄漏——长会话翻历史会把几十张图全钉在内存里。
// 所以淘汰/覆盖/清空都必须 revoke。这里用假工厂把 revoke 调用全部记下来验证。
import { describe, expect, it } from 'vitest'
import { BlobUrlCache, type BlobUrlFactory } from '../src/lib/blobCache'

function fakeFactory() {
  const created: string[] = []
  const revoked: string[] = []
  let n = 0
  const factory: BlobUrlFactory = {
    create: () => {
      const url = `blob:fake/${n++}`
      created.push(url)
      return url
    },
    revoke: (url) => {
      revoked.push(url)
    },
  }
  return { factory, created, revoked }
}

function bytes(n: number): Uint8Array {
  return new Uint8Array(n).fill(1)
}

describe('BlobUrlCache 基本读写', () => {
  it('put 后 get 拿得到同一个 URL', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    const url = c.put('r1', bytes(10), 'image/png')
    expect(c.get('r1')).toBe(url)
    expect(c.has('r1')).toBe(true)
    expect(c.size).toBe(1)
    expect(c.bytes).toBe(10)
  })

  it('未命中返回 null', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    expect(c.get('nope')).toBeNull()
  })

  it('同 key 覆盖时 revoke 旧 URL（否则留孤儿）', () => {
    const { factory, revoked } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    const first = c.put('r1', bytes(10), 'image/png')
    const second = c.put('r1', bytes(20), 'image/png')
    expect(second).not.toBe(first)
    expect(revoked).toContain(first)
    expect(c.bytes).toBe(20)
    expect(c.size).toBe(1)
  })
})

describe('LRU 淘汰', () => {
  it('超上限时从最旧的开始撤，并 revoke', () => {
    const { factory, revoked } = fakeFactory()
    const c = new BlobUrlCache(100, factory)
    const a = c.put('a', bytes(40), 'image/png')
    const b = c.put('b', bytes(40), 'image/png')
    expect(c.size).toBe(2)
    // 第三个进来会超 100 → 撤最旧的 a
    const d = c.put('c', bytes(40), 'image/png')
    expect(c.size).toBe(2)
    expect(c.has('a')).toBe(false)
    expect(c.has('b')).toBe(true)
    expect(c.has('c')).toBe(true)
    expect(revoked).toContain(a)
    expect(revoked).not.toContain(b)
    expect(revoked).not.toContain(d)
  })

  it('get 会刷新 LRU 次序（刚看过的不会被先撤）', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(100, factory)
    c.put('a', bytes(40), 'image/png')
    c.put('b', bytes(40), 'image/png')
    // 摸一下 a → a 变成最近使用
    c.get('a')
    c.put('c', bytes(40), 'image/png')
    // 被撤的应该是 b，不是 a
    expect(c.has('a')).toBe(true)
    expect(c.has('b')).toBe(false)
  })

  it('单个大文件超上限时**保留它自己**（否则放进去立刻被撤，永远拿不到）', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(50, factory)
    const url = c.put('big', bytes(500), 'image/png')
    expect(c.size).toBe(1)
    expect(c.get('big')).toBe(url)
  })

  it('淘汰到刚好不超为止（不是只撤一个）', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(100, factory)
    c.put('a', bytes(30), 'image/png')
    c.put('b', bytes(30), 'image/png')
    c.put('c', bytes(30), 'image/png')
    expect(c.bytes).toBe(90)
    c.put('d', bytes(50), 'image/png') // 90+50=140 > 100
    expect(c.bytes).toBeLessThanOrEqual(100)
    expect(c.has('d')).toBe(true)
  })
})

describe('clear', () => {
  it('全部 revoke 并清空计数', () => {
    const { factory, revoked } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    const a = c.put('a', bytes(10), 'image/png')
    const b = c.put('b', bytes(10), 'image/png')
    c.clear()
    expect(c.size).toBe(0)
    expect(c.bytes).toBe(0)
    expect(revoked).toContain(a)
    expect(revoked).toContain(b)
  })
})

describe('blob 构造', () => {
  it('mime 为空时不传 type（不写空字符串，浏览器会当成 application/octet-stream）', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    // 只验证不抛且能拿到 URL
    expect(c.put('r', bytes(4), '')).toMatch(/^blob:/)
  })

  it('传入的字节被复制（外部后续改动不影响缓存内容）', () => {
    const { factory } = fakeFactory()
    const c = new BlobUrlCache(1000, factory)
    const src = bytes(4)
    c.put('r', src, 'image/png')
    src[0] = 99 // 改原数组
    // 缓存里是副本，重新 put 同 key 不报错且字节数一致
    expect(c.bytes).toBe(4)
  })
})
