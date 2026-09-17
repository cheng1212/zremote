/// 会话列表纯逻辑 — 合并 `zcode-task` 的 `listTasks`/`listPinnedTasks`
/// 与 `sessions-index` 实时帧。
///
/// 抽成纯函数可单测：多端一致性全靠这里的合并规则。Flutter 端踩过的坑：
/// · 置顶状态以 `listPinnedTasks` 为准，不能信 `listTasks` 里的字段
///   （两个方法语义不同，后者不带置顶）；
/// · **排序不能信服务端给的顺序**——来源顺序经多次洗牌不可预期，
///   必须置顶组在前、组内按活跃时间倒序（BUG-24，用户点名）；
/// · `listTasks` 失败时**不能吞成空列表**——那在用户眼里就是「会话全没了」，
///   要按缓存降级并标陈旧。

export interface SessionCard {
  sessionId: string
  title: string
  phase: string
  pinned: boolean
  lastActivityAt: number
  preview: string
  hasPendingInteraction: boolean
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

/** 时间字段在不同来源叫法不一，逐个试（服务端字段名会随版本漂移）。 */
function activityOf(o: Record<string, unknown>): number {
  for (const k of ['lastActivityAt', 'updatedAt', 'lastActiveAt', 'createdAt']) {
    const v = o[k]
    if (v != null) {
      const n = typeof v === 'string' ? Date.parse(v) : num(v)
      if (Number.isFinite(n) && n > 0) return n
    }
  }
  return 0
}

/**
 * `listTasks` 结果 → 卡片。
 * 过滤 `archived` / `deleted`（服务端会把归档项也放在 listTasks 里）。
 * @param pinnedIds 来自 `listPinnedTasks`，是置顶状态的唯一权威。
 */
export function cardsFromTasks(list: unknown, pinnedIds: Set<string>): SessionCard[] {
  if (!Array.isArray(list)) return []
  const out: SessionCard[] = []
  for (const t of list) {
    if (!t || typeof t !== 'object') continue
    const o = t as Record<string, unknown>
    const id = str(o['taskId'] ?? o['sessionId'] ?? o['id'])
    if (!id) continue
    if (o['archived'] === true || o['deleted'] === true) continue
    out.push({
      sessionId: id,
      title: str(o['title']) || id.slice(0, 18),
      phase: str(o['phase'] ?? o['status']),
      pinned: pinnedIds.has(id),
      lastActivityAt: activityOf(o),
      preview: str(o['lastAssistantPreview']),
      hasPendingInteraction: o['pendingInteraction'] != null,
    })
  }
  return out
}

/** 从 `listPinnedTasks` 结果抽置顶 id 集合。 */
export function pinnedIdsFrom(list: unknown): Set<string> {
  const ids = new Set<string>()
  if (!Array.isArray(list)) return ids
  for (const t of list) {
    if (!t || typeof t !== 'object') continue
    const id = str((t as Record<string, unknown>)['taskId'])
    if (id) ids.add(id)
  }
  return ids
}

/** `sessions-index` 快照里的 `sessions[]` → 卡片。 */
export function cardsFromIndex(sessions: unknown): SessionCard[] {
  if (!Array.isArray(sessions)) return []
  const out: SessionCard[] = []
  for (const s of sessions) {
    if (!s || typeof s !== 'object') continue
    const o = s as Record<string, unknown>
    const id = str(o['sessionId'])
    if (!id) continue
    out.push({
      sessionId: id,
      title: str(o['title']),
      phase: str(o['phase']),
      pinned: false,
      lastActivityAt: activityOf(o),
      preview: str(o['lastAssistantPreview']),
      hasPendingInteraction: o['pendingInteraction'] != null,
    })
  }
  return out
}

/**
 * 合并：任务列表为骨架，index 数据覆盖实时字段（phase / 活跃时间 / 预览）。
 * index 里多出来的会话（本地还没拉到任务列表）也补进来，不丢。
 */
export function mergeCards(base: SessionCard[], index: SessionCard[]): SessionCard[] {
  const byId = new Map<string, SessionCard>()
  for (const c of base) byId.set(c.sessionId, c)
  for (const c of index) {
    const prev = byId.get(c.sessionId)
    if (!prev) {
      byId.set(c.sessionId, c)
      continue
    }
    byId.set(c.sessionId, {
      ...prev,
      // 空值不覆盖：index 帧可能只带 phase，不该把已拿到的 title 冲掉。
      title: c.title || prev.title,
      phase: c.phase || prev.phase,
      preview: c.preview || prev.preview,
      lastActivityAt: c.lastActivityAt || prev.lastActivityAt,
      hasPendingInteraction: c.hasPendingInteraction || prev.hasPendingInteraction,
    })
  }
  return [...byId.values()]
}

/**
 * 排序：置顶组在前；组内按活跃时间倒序。
 * 活跃时间缺失（0）排最后——宁可在底部，也不要顶到用户眼前。
 */
export function sortCards(cards: SessionCard[]): SessionCard[] {
  return [...cards].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    return b.lastActivityAt - a.lastActivityAt
  })
}

/** 标题搜索（本地过滤，不发请求）。 */
export function filterCards(cards: SessionCard[], query: string): SessionCard[] {
  const q = query.trim().toLowerCase()
  if (!q) return cards
  return cards.filter((c) => c.title.toLowerCase().includes(q))
}

/** 相对时间文案（列表卡右侧）。 */
export function timeLabel(at: number, now = Date.now()): string {
  if (!at) return ''
  const d = now - at
  if (d < 0) return '刚刚'
  const min = Math.floor(d / 60_000)
  if (min < 1) return '刚刚'
  if (min < 60) return `${min} 分钟前`
  const h = Math.floor(min / 60)
  if (h < 24) return `${h} 小时前`
  const day = Math.floor(h / 24)
  if (day < 30) return `${day} 天前`
  const t = new Date(at)
  const mm = String(t.getMonth() + 1).padStart(2, '0')
  const dd = String(t.getDate()).padStart(2, '0')
  return `${t.getFullYear()}-${mm}-${dd}`
}
