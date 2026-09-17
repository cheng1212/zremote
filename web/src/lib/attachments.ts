/// 附件条目解析与判定 —— 纯逻辑，移植自 `lib/ui/composer_logic.dart` +
/// `lib/ui/rows.dart`。
///
/// 附件条目形状（快照行 `row.attachments[]` / 发送时的 `attachments[]`）：
/// `{ref, mime|mediaType|mimeType, fileName|name, bytes}`
/// —— 字段名有多个历史叫法，**逐个试**，别只认一个（服务端与本地拼装
/// 来源不同，字段名会漂）。
///
/// ⚠️ **为什么网页端「读不了文件」**：浏览器有安全沙箱，
/// **网页不能读本地文件路径**（`D:\…` 读不到，`file://` URL 也加载不了，
/// Chrome 直接报 "Not allowed to load local resource"）。Flutter 是原生 App
/// 才有文件系统权限。所以客户端的正解是**走协议取字节**——
/// `attachmentReadV4` 按 ref 拉回 base64 分片，本地拼成 Blob 再显示。
/// 这条路 Web 完全走得通，前提是**实现了读取通道**。

export interface AttItem {
  ref: string
  mime: string
  fileName: string
  size: number
  raw: Record<string, unknown>
}

function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v)
}

const IMAGE_EXTS = new Set([
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'heif', 'avif', 'ico',
])

export function isImageExt(ext: string): boolean {
  return IMAGE_EXTS.has(ext.toLowerCase())
}

/** 归一化附件列表（非列表/非对象项一律丢）。 */
export function attItems(attachments: unknown): AttItem[] {
  if (!Array.isArray(attachments)) return []
  const out: AttItem[] = []
  for (const a of attachments) {
    if (!isMap(a)) continue
    const sizeRaw = a['bytes'] ?? a['size'] ?? a['totalBytes']
    out.push({
      ref: str(a['ref']),
      mime: str(a['mime'] ?? a['mediaType'] ?? a['mimeType']),
      fileName: str(a['fileName'] ?? a['name']),
      size: typeof sizeRaw === 'number' ? sizeRaw : 0,
      raw: a,
    })
  }
  return out
}

/**
 * 是否图片。mime 优先，扩展名兜底——**相册选出来的图经常没有 mime**
 * （尤其无后缀或 HEIC），只认 mime 会把它们当普通文件显示成 chip。
 */
export function isImageAttachment(a: AttItem): boolean {
  if (a.mime.startsWith('image/')) return true
  const ext = a.fileName.includes('.') ? a.fileName.split('.').pop() ?? '' : ''
  return isImageExt(ext)
}

/** 魔数嗅探：mime 与扩展名都认不出时，靠字节头补判（PNG/JPEG/GIF/WebP/BMP）。 */
export function sniffImageMime(bytes: Uint8Array): string | null {
  if (bytes.length < 12) return null
  // PNG: 89 50 4E 47
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return 'image/png'
  }
  // JPEG: FF D8 FF
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
  // GIF: "GIF8"
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) {
    return 'image/gif'
  }
  // WebP: "RIFF"…"WEBP"
  if (
    bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
    bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50
  ) {
    return 'image/webp'
  }
  // BMP: "BM"
  if (bytes[0] === 0x42 && bytes[1] === 0x4d) return 'image/bmp'
  return null
}

/** 展示名：文件名 → ref 尾段 → 「附件」兜底。 */
export function attachmentLabel(a: AttItem): string {
  if (a.fileName) return a.fileName
  if (a.ref) {
    const tail = a.ref.split(/[/\\]/).pop() ?? ''
    if (tail) return tail
  }
  return '附件'
}

/** 附件在消息里的引用文案（服务端认电脑本地路径）。 */
export function attachmentRefLine(a: AttItem, path: string): string {
  return `[附件] ${attachmentLabel(a)} → ${path}`
}

/** 从行里取附件列表（用户消息在 `row.attachments`）。 */
export function rowAttachments(row: Record<string, unknown>): AttItem[] {
  return attItems(row['attachments'])
}
