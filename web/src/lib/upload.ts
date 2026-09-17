/// 附件上传的纯逻辑（分片规划、类型判定、限额）——可单测。
///
/// 上传走的是 Channel IPC 的 `attachmentBeginV4 → ChunkV4 → CommitV4`，
/// **不是 HTTP**——所以拿不到浏览器原生的 `upload.onprogress`，
/// 进度只能按「已发片数 / 总片数」本地计数。
///
/// 服务端落地行为：文件写入**会话 cwd 的 `uploads/` 目录**（无 cwd 时自动建
/// `uploads-<sid8>` 并回填），消息以**电脑本地路径**引用它，CLI 可直接读。
/// 这是真改变（文件系统级），不是 UI 效果。

/** 分片大小，对齐 `lib/protocol/constants.dart` 的 `attachmentChunkBytes`。 */
export const ATTACHMENT_CHUNK_BYTES = 384 * 1024

/** 单文件上限，对齐移动端拦截阈值（`100 << 20`）。 */
export const MAX_FILE_BYTES = 100 << 20

/** 一次最多选几个附件（对齐移动端相册多选上限）。 */
export const MAX_FILES_PER_PICK = 9

export interface UploadPlan {
  uploadId: string
  totalChunks: number
  chunkBytes: number
  totalBytes: number
}

/** 规划分片。空文件也算 1 片（服务端要 begin/chunk/commit 三段走完）。 */
export function planUpload(totalBytes: number, uploadId: string): UploadPlan {
  const totalChunks = Math.max(1, Math.ceil(totalBytes / ATTACHMENT_CHUNK_BYTES))
  return {
    uploadId,
    totalChunks,
    chunkBytes: ATTACHMENT_CHUNK_BYTES,
    totalBytes,
  }
}

/** 第 i 片的字节区间 [start, end)。 */
export function chunkRange(index: number, totalBytes: number): [number, number] {
  const start = index * ATTACHMENT_CHUNK_BYTES
  const end = Math.min(start + ATTACHMENT_CHUNK_BYTES, totalBytes)
  return [start, end]
}

/** 是否超限。 */
export function exceedsLimit(bytes: number, limit = MAX_FILE_BYTES): boolean {
  return bytes > limit
}

/** 人话体积。 */
export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

const MIME_BY_EXT: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  bmp: 'image/bmp',
  svg: 'image/svg+xml',
  heic: 'image/heic',
  pdf: 'application/pdf',
  txt: 'text/plain',
  md: 'text/markdown',
  json: 'application/json',
  csv: 'text/csv',
  zip: 'application/zip',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ppt: 'application/vnd.ms-powerpoint',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
}

/**
 * 猜 MIME。优先用浏览器给的 `file.type`，为空时按扩展名兜底
 * （移动端相册选出来的文件 `type` 经常是空串）。
 */
export function guessMime(fileName: string, browserType = ''): string {
  if (browserType) return browserType
  const ext = fileName.split('.').pop()?.toLowerCase() ?? ''
  return MIME_BY_EXT[ext] ?? 'application/octet-stream'
}

export function isImageMime(mime: string): boolean {
  return mime.startsWith('image/')
}

/** 附件在消息里的引用文案（服务端认电脑本地路径）。 */
export function attachmentRefLine(fileName: string, path: string): string {
  return `[附件] ${fileName} → ${path}`
}

/**
 * 分片进度异常判定：服务端回的 `nextChunkIndex` 必须是 n+1。
 * 不吻合说明服务端分片进度乱了，**必须报错而不是继续**——继续会写出坏文件。
 */
export function chunkProgressOk(serverNext: number | null, sentIndex: number): boolean {
  if (serverNext == null) return true // 服务端没回就按本地推进
  return serverNext === sentIndex + 1
}
