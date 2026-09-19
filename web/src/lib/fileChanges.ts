/// 文件变更清单的解析 —— 移植 Flutter `composer_logic.describeFileChange`
/// （唯一蓝本，第 227 行）。
///
/// 为什么要这么多兜底：这个返回值**形状未实测**，而且桌面端会自动升级改接口
/// （`prepareWorkspace` 就被整个删过）。路径拿不到就整行丢弃——没有路径的
/// "某文件被改了"对用户没有任何价值，留着还是骗人的信息。

export interface FileChangeRow {
  path: string
  action: string
  stats: string
}

export interface FileChangeSummary {
  items: FileChangeRow[]
  files: number
  additions: number
  deletions: number
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v)
}

function num(v: unknown): number {
  if (typeof v === 'number' && Number.isFinite(v)) return v
  if (typeof v === 'string') {
    const n = Number(v)
    if (Number.isFinite(n)) return n
  }
  return 0
}

function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

/** 动作中文标签。认不出的原样显示——别把未知动作谎报成"修改"。 */
export function fileChangeAction(rawKind: string): string {
  switch (rawKind) {
    case 'created':
    case 'added':
    case 'create':
    case 'add':
      return '新建'
    case 'deleted':
    case 'removed':
    case 'delete':
    case 'remove':
      return '删除'
    case 'renamed':
    case 'rename':
    case 'move':
      return '重命名'
    case 'modified':
    case 'edit':
    case 'change':
    case 'update':
      return '修改'
    case '':
      return '修改'
    default:
      return rawKind
  }
}

/** 单条变更 → 展示三元组；路径缺失返回 null（调用方丢整行）。 */
export function describeFileChange(change: unknown): FileChangeRow | null {
  if (!isMap(change)) return null
  const path = str(change['path'] ?? change['file'] ?? change['filePath'] ?? change['relPath'])
  if (!path) return null
  const rawKind = str(change['changeType'] ?? change['kind'] ?? change['status'] ?? change['type'])
  const add = num(change['additions'])
  const del = num(change['deletions'])
  const stats = [add > 0 ? `+${add}` : '', del > 0 ? `-${del}` : ''].filter(Boolean).join(' ')
  return { path, action: fileChangeAction(rawKind), stats }
}

/**
 * 解析 `conversationFileChangesV4` 的返回：裸数组 / `{items}` / `{files}` /
 * `{changes}` 都认；一个都不认时给空清单（面板显示"没有文件变更"）。
 */
export function parseFileChanges(raw: unknown): FileChangeSummary {
  const src = Array.isArray(raw)
    ? raw
    : isMap(raw)
      ? (raw['items'] ?? raw['files'] ?? raw['changes'] ?? [])
      : []
  const items = (Array.isArray(src) ? src : []).map(describeFileChange).filter(
    (r): r is FileChangeRow => r != null,
  )
  const wrap = isMap(raw) ? raw : {}
  const files = num(wrap['files']) || items.length
  const additions = num(wrap['additions']) || items.reduce((n, r) => n + numOf(r.stats, '+'), 0)
  const deletions = num(wrap['deletions']) || items.reduce((n, r) => n + numOf(r.stats, '-'), 0)
  return { items, files, additions, deletions }
}

/** 从 `+12 -3` 这类统计串里取一边的数字。 */
function numOf(stats: string, sign: '+' | '-'): number {
  for (const tok of stats.split(' ')) {
    if (tok.startsWith(sign)) return Math.abs(Number(tok.slice(1)) || 0)
  }
  return 0
}

/** turnHeader 行自带的变更摘要（有它就能不额外发一次查询直接显示入口）。 */
export function rowFileChangeBadge(row: Record<string, unknown>): string {
  const fc = row['fileChanges']
  if (!isMap(fc)) return ''
  const files = num(fc['files'])
  if (!files) return ''
  const add = num(fc['additions'])
  const del = num(fc['deletions'])
  const stats = [add > 0 ? `+${add}` : '', del > 0 ? `-${del}` : ''].filter(Boolean).join(' ')
  return `改动 ${files} 个文件${stats ? ` · ${stats}` : ''}`
}

/**
 * 回滚预览（`conversationFileRewindPreviewV4`）。
 * 桌面端算好"能不能滚、哪些文件安全、哪些会覆盖用户自己的改动"——
 * **这个判断只能在服务端做**，客户端绝不自己数一遍就滚。
 */
export interface RewindPreview {
  canApply: boolean
  safe: number
  unsafe: number
  ignored: number
  reason: string
}

export function parseRewindPreview(raw: unknown): RewindPreview {
  if (!isMap(raw)) return { canApply: false, safe: 0, unsafe: 0, ignored: 0, reason: '意外形状' }
  const len = (v: unknown): number => (Array.isArray(v) ? v.length : num(v))
  return {
    canApply: raw['canApply'] === true,
    safe: len(raw['safeFiles']),
    unsafe: len(raw['unsafeFiles']),
    ignored: len(raw['ignoredFiles']),
    reason: str(raw['message'] ?? raw['reason'] ?? ''),
  }
}

/** 回滚目标：`target` 里 `entityId` 是必填（服务端 schema 是 min(1) 的 string）。 */
export function rewindTargetOf(
  row: Record<string, unknown>,
): { rowId: number; entityId: string } | null {
  const rowId = row['rowId']
  const entityId = row['entityId']
  if (typeof rowId !== 'number' || typeof entityId !== 'string' || !entityId) return null
  return { rowId, entityId }
}
