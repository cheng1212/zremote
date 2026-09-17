/// 会话行状态与 deltas 应用 — 纯函数，移植自 `lib/protocol/conversation.dart`。
///
/// ⚠️ **本文件修掉了 Web 端一个真实缺陷**：原 `stores/app.ts` 按
/// `deltas[].upsert` / `deltas[].delete` 两个键取值，而服务端真实协议是
/// **`op` 五态**（见 `docs/API.md` L5「deltas op」）：
/// `row.appended` / `row.upserted` / `row.removed` / `row.delta` / `state.updated`。
/// 键名对不上 → 每个 delta 都被静默忽略 → **流式回复永远不增长**，
/// 只有整份快照（重进会话）才看得到内容。
///
/// 抽成纯函数是为了可单测：这套语义是 Flutter 端反复踩坑定下来的，
/// Web 端不许重新猜——
/// · `row.removed` 用 `fromRowId`（保留更小的），不是用 rowId 删单个；
/// · `row.upserted` 必须把旧行的 `localTs` 搬过来，否则时间戳每次更新都跳成「刚刚」；
/// · `state.updated` 的 `config` **只能合不能替**，整包替换会抹掉没变的
///   `approvalMode` / `followupMode`。

export type ConvRow = Record<string, unknown>

export interface ConvState {
  snapshot: Record<string, unknown> | null
  rows: ConvRow[]
  seq: number
  logEpoch: string | null
  firstRowId: number | null
  totalCount: number
  ready: boolean
  /** 快照未到时收到的 `state.updated` 暂存，等快照到达再合并。 */
  pendingPatch: Record<string, unknown> | null
}

export function createConvState(): ConvState {
  return {
    snapshot: null,
    rows: [],
    seq: 0,
    logEpoch: null,
    firstRowId: null,
    totalCount: 0,
    ready: false,
    pendingPatch: null,
  }
}

/** 本端首次见到该行的毫秒时刻（消息时间戳显示用）。服务端行不带时间字段。 */
function stampLocalTs(row: ConvRow): void {
  if (row['localTs'] == null) row['localTs'] = Date.now()
}

function rowIdOf(row: ConvRow): number | null {
  const v = row['rowId']
  return typeof v === 'number' ? v : null
}

function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

/** 从尾部反着找：流式 delta 永远打在窗口尾部，省掉全列表扫描。 */
function lastIndexOfRow(rows: ConvRow[], rowId: number | null): number {
  if (rowId == null) return -1
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rowIdOf(rows[i]) === rowId) return i
  }
  return -1
}

/**
 * 应用整份快照。**会保留已翻页拉回的更早行**（它们在窗口头之前），
 * 否则每次 resync 都会把用户翻了半天的历史丢掉。
 */
export function applySnapshot(state: ConvState, snap: Record<string, unknown>): void {
  state.snapshot = state.pendingPatch ? { ...snap, ...state.pendingPatch } : snap
  state.pendingPatch = null
  state.logEpoch = typeof snap['logEpoch'] === 'string' ? snap['logEpoch'] : state.logEpoch

  const rowsObj = snap['rows']
  if (isMap(rowsObj)) {
    const window = Array.isArray(rowsObj['window']) ? (rowsObj['window'] as ConvRow[]) : null
    if (window) {
      const windowRows = window.filter(isMap)
      for (const r of windowRows) stampLocalTs(r)
      const head = windowRows.length ? rowIdOf(windowRows[0]) : null
      const older =
        head == null
          ? []
          : state.rows.filter((r) => {
              const id = rowIdOf(r)
              return id != null && id < head
            })
      state.rows = [...older, ...windowRows]
      state.firstRowId = state.rows.length ? rowIdOf(state.rows[0]) : null
      const tc = rowsObj['totalCount']
      state.totalCount = typeof tc === 'number' ? tc : state.rows.length
    } else if (Array.isArray(rowsObj)) {
      // 兼容形态：rows 直接是数组
      const windowRows = (rowsObj as ConvRow[]).filter(isMap)
      for (const r of windowRows) stampLocalTs(r)
      state.rows = windowRows
      state.firstRowId = state.rows.length ? rowIdOf(state.rows[0]) : null
      state.totalCount = state.rows.length
    }
  }
  state.ready = true
}

/** 单条 delta。 */
export function applyDelta(state: ConvState, delta: Record<string, unknown>): void {
  switch (delta['op']) {
    case 'row.appended': {
      const row = delta['row']
      if (!isMap(row)) return
      stampLocalTs(row)
      state.rows = [...state.rows, row]
      state.totalCount += 1
      state.firstRowId ??= rowIdOf(row)
      return
    }
    case 'row.upserted': {
      const row = delta['row']
      if (!isMap(row)) return
      const idx = lastIndexOfRow(state.rows, rowIdOf(row))
      if (idx === -1) return
      // 服务端新拷贝不带本端时间：原行的 localTs 是首次接收时刻，
      // 必须搬过来，否则每次行更新时间戳都会跳成「刚刚」。
      const prevTs = state.rows[idx]['localTs']
      if (prevTs != null) row['localTs'] = prevTs
      const next = [...state.rows]
      next[idx] = row
      state.rows = next
      return
    }
    case 'row.removed': {
      // 保留 rowId < fromRowId 的行（删掉 >= fromRowId 的）。
      const fromRowId = typeof delta['fromRowId'] === 'number' ? delta['fromRowId'] : 0
      const kept = state.rows.filter((r) => (rowIdOf(r) ?? 0) < fromRowId)
      const removed = state.rows.length - kept.length
      state.rows = kept
      if (state.firstRowId != null && fromRowId <= state.firstRowId) {
        state.totalCount = 0
        state.firstRowId = null
      } else {
        state.totalCount = Math.max(0, state.totalCount - removed)
      }
      return
    }
    case 'row.delta': {
      const idx = lastIndexOfRow(state.rows, typeof delta['rowId'] === 'number' ? (delta['rowId'] as number) : null)
      if (idx === -1) return
      const append = typeof delta['append'] === 'string' ? delta['append'] : ''
      const next = [...state.rows]
      next[idx] = appendToRow(state.rows[idx], delta['path'] as string | undefined, append)
      state.rows = next
      return
    }
    case 'state.updated': {
      const patch = delta['patch']
      if (!isMap(patch)) return
      if (!state.snapshot) {
        state.pendingPatch = { ...(state.pendingPatch ?? {}), ...patch }
        return
      }
      // config 只该被更新不该被替换：服务端 patch 常只带 provider/model，
      // 整包替换会把 approvalMode/followupMode 这类没变的键抹掉。
      const oldConfig = state.snapshot['config']
      state.snapshot = { ...state.snapshot, ...patch }
      const newConfig = state.snapshot['config']
      if (isMap(oldConfig) && isMap(newConfig)) {
        state.snapshot['config'] = { ...oldConfig, ...newConfig }
      }
      return
    }
    default:
      // 未知 op 静默忽略（服务端可能加新 op；不要因为不认识的 op 打断整批）。
      return
  }
}

/** `row.delta` 的 path → 落在行的哪个字段。kind 不匹配就不动（防串字段）。 */
function appendToRow(row: ConvRow, path: string | undefined, append: string): ConvRow {
  const kind = row['kind']
  switch (path) {
    case 'text':
      if (kind === 'assistantText' || kind === 'reasoning') {
        return { ...row, text: `${row['text'] ?? ''}${append}` }
      }
      return row
    case 'inputText':
      if (kind === 'toolCall') {
        return { ...row, inputText: `${row['inputText'] ?? ''}${append}` }
      }
      return row
    case 'output.text':
      if (kind === 'toolCall' && isMap(row['output'])) {
        const output = row['output'] as Record<string, unknown>
        return { ...row, output: { ...output, text: `${output['text'] ?? ''}${append}` } }
      }
      return row
    case 'summaryText':
      if (kind === 'subagent') {
        return { ...row, summaryText: `${row['summaryText'] ?? ''}${append}` }
      }
      return row
    default:
      return row
  }
}

/**
 * deltas 帧：先校验 seq 连续性再应用。
 * 返回 `'gap'` 表示断档（本帧不能应用，调用方应触发 resync）。
 *
 * **gap 时刻意不推进 seq**——seq 的语义是「已成功应用到本地的序号」，
 * 本帧没应用就不该推进；推进了反而会把后续合法帧也误判成 gap。
 * 防重复触发不靠 seq，靠 `ResyncGate` 单飞闸。
 */
export function applyDeltasFrame(
  state: ConvState,
  frame: Record<string, unknown>,
  payload: Record<string, unknown>,
): 'ok' | 'gap' {
  const fromSeq = typeof frame['fromSeq'] === 'number' ? (frame['fromSeq'] as number) : state.seq
  if (fromSeq !== state.seq) return 'gap'
  const deltas = payload['deltas']
  if (Array.isArray(deltas)) {
    for (const d of deltas) {
      if (isMap(d)) applyDelta(state, d)
    }
  }
  const toSeq = typeof frame['toSeq'] === 'number' ? (frame['toSeq'] as number) : state.seq
  state.seq = toSeq
  return 'ok'
}

/**
 * 并入 rowsRange 拉回的更早行：按 rowId 去重、升序、前置。
 * 返回新增行数（0 = 没有新内容，调用方据此停止翻页）。
 */
export function mergeOlder(state: ConvState, older: ConvRow[]): number {
  const known = new Set<number>()
  for (const r of state.rows) {
    const id = rowIdOf(r)
    if (id != null) known.add(id)
  }
  const fresh = older
    .filter((r) => isMap(r))
    .filter((r) => {
      const id = rowIdOf(r)
      return id != null && !known.has(id)
    })
    .sort((a, b) => (rowIdOf(a) ?? 0) - (rowIdOf(b) ?? 0))
  if (fresh.length) {
    for (const r of fresh) stampLocalTs(r)
    state.rows = [...fresh, ...state.rows]
    state.firstRowId = rowIdOf(state.rows[0])
  }
  return fresh.length
}

/** 是否还有更早的历史可翻。 */
export function hasMoreOlder(state: ConvState): boolean {
  return state.firstRowId != null && state.rows.length < state.totalCount
}

/** 翻页游标：**窗口最小 rowId**（不是 firstRowId 字段——BUG-28 实证，
 *  firstRowId 恒为 1 会让翻页死锁）。 */
export function olderCursor(state: ConvState): number | null {
  let min: number | null = null
  for (const r of state.rows) {
    const id = rowIdOf(r)
    if (id != null && (min == null || id < min)) min = id
  }
  return min
}
