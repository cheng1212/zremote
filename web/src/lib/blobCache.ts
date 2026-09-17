/// 附件字节缓存（Blob URL + LRU 淘汰）——移植 Flutter 端 `lib/ui/image_cache.dart`
/// 的 64MB LRU 思路，但 Web 端多一层必须做的事：**revokeObjectURL**。
///
/// 浏览器里 `URL.createObjectURL` 创建的 blob URL 会**一直持有那份字节**
/// 直到显式 revoke。不 revoke 就是内存泄漏——长会话翻历史会把几十张图
/// 全钉在内存里。所以淘汰时必须 revoke。
///
/// 工厂可注入（单测在 Node 里没有 URL.createObjectURL）。

export interface BlobUrlFactory {
  create(blob: Blob): string
  revoke(url: string): void
}

const defaultFactory: BlobUrlFactory = {
  create: (blob) => URL.createObjectURL(blob),
  revoke: (url) => URL.revokeObjectURL(url),
}

interface Entry {
  url: string
  bytes: number
}

export class BlobUrlCache {
  private map = new Map<string, Entry>()
  private total = 0

  constructor(
    private maxBytes: number = 64 << 20,
    private factory: BlobUrlFactory = defaultFactory,
  ) {}

  has(key: string): boolean {
    return this.map.has(key)
  }

  /** 命中即刷新 LRU 次序（Map 保持插入序，删了再塞就是「最近使用」）。 */
  get(key: string): string | null {
    const e = this.map.get(key)
    if (!e) return null
    this.map.delete(key)
    this.map.set(key, e)
    return e.url
  }

  /** 放入字节；超上限按 LRU 淘汰并 revoke。 */
  put(key: string, bytes: Uint8Array, mime: string): string {
    const existing = this.map.get(key)
    if (existing) {
      // 已有同 ref 的内容：先撤旧的，避免留下孤儿 URL
      this.map.delete(key)
      this.total -= existing.bytes
      this.factory.revoke(existing.url)
    }
    const blob = new Blob([bytes.slice()], mime ? { type: mime } : undefined)
    const url = this.factory.create(blob)
    const size = bytes.byteLength
    this.map.set(key, { url, bytes: size })
    this.total += size
    this.evict()
    return url
  }

  /** 单个大文件也可能超上限——从最旧的开始撤，但**保留刚放进去的那一个**。 */
  private evict(): void {
    while (this.total > this.maxBytes && this.map.size > 1) {
      const oldestKey = this.map.keys().next().value
      if (oldestKey == null) break
      const e = this.map.get(oldestKey)
      if (!e) break
      this.map.delete(oldestKey)
      this.total -= e.bytes
      this.factory.revoke(e.url)
    }
  }

  /** 全清（切会话/断开时调用）。 */
  clear(): void {
    for (const e of this.map.values()) this.factory.revoke(e.url)
    this.map.clear()
    this.total = 0
  }

  get size(): number {
    return this.map.size
  }

  get bytes(): number {
    return this.total
  }
}

/** 全局单例：图片在会话间复用（同 ref 换会话仍有效——ref 是会话域的，
 *  但缓存按 ref 键控不会串台，因为不同会话的 ref 不会相同）。 */
export const attachmentBlobs = new BlobUrlCache()
