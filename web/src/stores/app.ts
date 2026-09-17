/// App 级 store：连接生命周期 + 会话列表 + 当前会话状态（Pinia）。
/// 对齐 Flutter 端 ZApp（`lib/state/app_controller.dart`）的核心状态机。
///
/// 分层原则（别倒过来）：
///   纯逻辑（deltas 应用 / 合并 / 排序 / 滚动判定）在 `lib/*.ts`，可单测；
///   本文件只做编排与状态持有。
/// 状态一致性靠**对账**（服务端为准），不靠本地猜——Flutter 端 BUG-18/L-18
/// 定下来的方向。

import { defineStore } from 'pinia'
import { RemoteSession, Bridge, type Workspace } from '../protocol/remoteSession'
import { ConversationV4 } from '../protocol/conversation'
import { TaskChannel } from '../protocol/task'
import { parseLinkParams, type LinkParams } from '../protocol/linkParams'
import {
  createConvState,
  applySnapshot,
  applyDeltasFrame,
  mergeOlder,
  hasMoreOlder,
  olderCursor,
  type ConvState,
  type ConvRow,
} from '../lib/convRows'
import {
  cardsFromTasks,
  pinnedIdsFrom,
  cardsFromIndex,
  mergeCards,
  sortCards,
  filterCards,
  type SessionCard,
} from '../lib/sessions'
import { isBusyPhase, isProducingPhase, isErrorPhase, errorValueText } from '../lib/phase'

export type RelayUiState =
  | 'idle'
  | 'connecting'
  | 'authenticating'
  | 'waiting'
  | 'paired'
  | 'reconnecting'
  | 'error'
  | 'kicked'
  | 'closed'

/** 打开会话时带的标题（从列表点进来时已知，省一次查询）。 */
export interface ChatMeta {
  sessionId: string
  title: string
}

/**
 * 当前会话的订阅句柄。
 * **放模块作用域而不是 store state**：它是不可序列化的资源句柄，
 * 放进 state 会被 Pinia/Vue 做响应式包装（并且 devtools 里很脏）。
 */
let chatSub: { cancel: () => void; resubscribe: () => void } | null = null

export const useAppStore = defineStore('app', {
  state: () => ({
    // —— 连接 ——
    relayState: 'idle' as RelayUiState,
    failure: '' as string,
    params: null as LinkParams | null,
    session: null as RemoteSession | null,
    bridge: null as Bridge | null,
    conv: null as ConversationV4 | null,
    task: null as TaskChannel | null,
    workspaces: [] as Workspace[],
    workspace: null as Workspace | null,
    connecting: false,

    // —— 会话列表 ——
    /** 来自 `listTasks`（服务端权威骨架）。 */
    taskCards: [] as SessionCard[],
    /** 来自 `sessions-index` 实时帧，按 id 索引，覆盖 phase/活跃时间。 */
    indexCards: {} as Record<string, SessionCard>,
    indexSeq: 0,
    sessionsLoading: false,
    /** 列表是缓存降级态（listTasks 失败）——UI 要诚实提示，不能假装新鲜。 */
    sessionsStale: false,
    sessionsError: '',
    sessionsQuery: '',

    // —— 当前会话 ——
    chat: null as ConvState | null,
    chatMeta: null as ChatMeta | null,
    chatLoading: false,
    loadingOlder: false,
    /** 发送失败的人话原因（errorValueText 解出的）。 */
    sendError: '',

    logs: [] as string[],
  }),

  getters: {
    showMainShell(state): boolean {
      return state.workspace != null || state.workspaces.length > 0
    },

    workspaceTitle(state): string {
      const w = state.workspace as Workspace | null
      if (!w) return ''
      return String(
        (w['label'] as string | undefined) ??
          String(w['workspacePath'] ?? '')
            .split(/[\\/]/)
            .filter(Boolean)
            .pop() ??
          '',
      )
    },

    /** 合并后的完整列表（未过滤）——空态判定用。 */
    allSessions(state): SessionCard[] {
      return sortCards(mergeCards(state.taskCards, Object.values(state.indexCards)))
    },

    /** 列表（合并 + 排序 + 搜索过滤后的最终展示序列）。 */
    sessions(): SessionCard[] {
      return filterCards(this.allSessions, this.sessionsQuery)
    },

    /** 服务端原始总数（搜索前）。搜索无结果 ≠ 没有会话。 */
    sessionsTotal(): number {
      return this.allSessions.length
    },

    rows(state): ConvRow[] {
      return state.chat?.rows ?? []
    },

    phase(state): string {
      const snap = state.chat?.snapshot
      const control = snap?.['control']
      if (!control || typeof control !== 'object') return ''
      const p = (control as Record<string, unknown>)['phase']
      return typeof p === 'string' ? p : ''
    },

    /** 忙（含排队）——决定能不能再发、要不要显示忙碌态。 */
    busy(): boolean {
      return isBusyPhase(this.phase)
    },

    /** 真在产出——决定「停止」按钮出不出现（排队中给停止是错的）。 */
    running(): boolean {
      return isProducingPhase(this.phase)
    },

    /** 会话级出错（服务端不建助手行时，时间线什么都不渲染——要自己提示）。 */
    chatError(): string {
      return isErrorPhase(this.phase) ? '本轮回复中断' : ''
    },

    canLoadOlder(state): boolean {
      return state.chat != null && hasMoreOlder(state.chat) && !state.loadingOlder
    },
  },

  actions: {
    log(line: string): void {
      this.logs.push(`${new Date().toLocaleTimeString()} ${line}`)
      if (this.logs.length > 500) this.logs.splice(0, this.logs.length - 500)
    },

    // ────────────────────────── 连接 ──────────────────────────

    /** 连接：解析链接 → relay 握手 → bootstrap → 开当前工作区桥。 */
    async connect(rawLink: string): Promise<void> {
      const params = parseLinkParams(rawLink)
      if (!params) {
        this.failure = '链接无法解析：需要 zcode.z.ai/remote/v4?sid=…&hash=… 的完整链接'
        throw new Error(this.failure)
      }
      this.failure = ''
      this.params = params
      this.connecting = true
      this.relayState = 'connecting'
      try {
        const session = new RemoteSession(params, (l) => this.log(l))
        this.session = session
        session.relay.onState(() => {
          this.relayState = session.relay.state as RelayUiState
        })
        session.onWorkspaceList((result) => {
          const r = result as Record<string, unknown> | null
          const list = (r?.['workspaces'] as Workspace[] | undefined) ?? []
          if (list.length > 0) this.workspaces = list
        })
        await session.connect()
        await session.waitPaired(45_000)
        const boot = await session.bootstrap()
        const list = (boot['workspaces'] as Workspace[] | undefined) ?? []
        if (list.length > 0) this.workspaces = list
        // 工作区选择：记住上次的优先；只有一个就直接进；多个留给用户切。
        const stored = localStorage.getItem('lastWorkspaceKey')
        let picked: Workspace | null = null
        if (stored) {
          picked =
            list.find(
              (w) =>
                (w['workspaceKey'] ?? w['workspacePath']) === stored ||
                w['workspacePath'] === stored,
            ) ?? null
        }
        if (!picked && list.length === 1) picked = list[0]
        if (picked) await this.openWorkspace(picked)
      } catch (e) {
        this.failure = String(e)
        throw e
      } finally {
        this.connecting = false
      }
    },

    /** 打开工作区：开桥 → 订阅 sessions-index → 拉会话列表。 */
    async openWorkspace(w: Workspace): Promise<void> {
      const session = this.session
      if (!session) throw new Error('未连接')
      const key = String(w['workspaceKey'] ?? w['workspacePath'] ?? '')
      if (!key) throw new Error('工作区缺少 key')
      this.closeSession()
      this.conv = null
      this.task = null
      this.indexCards = {}
      this.indexSeq = 0
      this.taskCards = []
      const bridge = await session.openBridge(key)
      this.bridge = bridge
      this.workspace = w
      localStorage.setItem('lastWorkspaceKey', key)

      const conv = new ConversationV4(bridge, (l) => this.log(l))
      this.conv = conv
      this.task = new TaskChannel(bridge, (l) => this.log(l))

      // 实时帧：会话列表增量（phase 变化、新会话、删除）
      conv.subscribeIndex((frame) => this.applyIndexFrame(frame))

      // 先订阅、后拉全量：订阅期间的变更由 index 帧带来，拉取完成后再合并；
      // 顺序反过来会丢掉「订阅建立前」那一段窗口的变更。
      await this.loadSessions()
    },

    // ────────────────────── 会话列表（加载 / 刷新） ──────────────────────

    /**
     * 加载会话列表：`listTasks` + `listPinnedTasks` 并发拉，合并成卡片。
     *
     * `listPinnedTasks` 是置顶状态的**唯一权威**（`listTasks` 不带置顶）。
     * 置顶列表失败时沿用上次的置顶状态（缓存语义），成功则以服务端为准。
     * `listTasks` 失败**不吞成空列表**——那在用户眼里就是「会话全没了」，
     * 改为保留现有列表并标陈旧（`sessionsStale`）。
     */
    async loadSessions(): Promise<void> {
      const task = this.task
      if (!task) return
      this.sessionsLoading = true
      this.sessionsError = ''
      try {
        const [listRes, pinRes] = await Promise.allSettled([
          task.listTasks(),
          task.listPinnedTasks(),
        ])

        if (listRes.status === 'rejected') {
          this.sessionsStale = true
          this.sessionsError = errorValueText(listRes.reason) ?? String(listRes.reason)
          this.log(`[task] listTasks 失败，保留本地缓存: ${this.sessionsError}`)
          return
        }
        this.sessionsStale = false

        let pinnedIds: Set<string>
        if (pinRes.status === 'fulfilled') {
          pinnedIds = pinnedIdsFrom(pinRes.value)
        } else {
          // 置顶列表失败 → 沿用上次的置顶状态，别把已置顶的会话掉下去。
          pinnedIds = new Set(this.taskCards.filter((c) => c.pinned).map((c) => c.sessionId))
          this.log('[task] listPinnedTasks 失败，沿用上次置顶状态')
        }

        this.taskCards = cardsFromTasks(listRes.value, pinnedIds)
        this.log(`[task] listTasks → ${this.taskCards.length} 条`)
      } catch (e) {
        this.sessionsStale = true
        this.sessionsError = errorValueText(e) ?? String(e)
      } finally {
        this.sessionsLoading = false
      }
    },

    /**
     * 刷新：重拉任务列表 + 让 sessions-index 重发快照。
     * 两条腿都要——只重拉 `listTasks` 拿不到 index 里的实时 phase；
     * 只 resync index 拿不到任务元数据（标题 / 归档态）。
     */
    async refreshSessions(): Promise<void> {
      this.conv?.resyncIndex()
      await this.loadSessions()
    },

    /** sessions-index 帧：快照全量替换，deltas 增量 upsert/remove（带断档检测）。 */
    applyIndexFrame(frame: Record<string, unknown>): void {
      const payload = frame['payload']
      if (!payload || typeof payload !== 'object') return
      const p = payload as Record<string, unknown>
      const kind = p['kind']

      if (kind === 'snapshot') {
        const snap = p['snapshot']
        if (!snap || typeof snap !== 'object') return
        const sessions = (snap as Record<string, unknown>)['sessions']
        const next: Record<string, SessionCard> = {}
        for (const c of cardsFromIndex(sessions)) next[c.sessionId] = c
        this.indexCards = next
        this.indexSeq = typeof frame['toSeq'] === 'number' ? (frame['toSeq'] as number) : 0
        return
      }

      if (kind === 'deltas') {
        const fromSeq =
          typeof frame['fromSeq'] === 'number' ? (frame['fromSeq'] as number) : this.indexSeq
        if (fromSeq !== this.indexSeq) {
          // 断档：本帧不能应用（会错位），交给单飞闸 resync 拉全量。
          // 刻意**不推进 indexSeq**——推进了会把后续合法帧也误判成断档。
          this.log(`[index] gap fromSeq=${fromSeq} seq=${this.indexSeq} → resync`)
          this.conv?.resyncIndex()
          return
        }
        const deltas = p['deltas']
        if (Array.isArray(deltas)) {
          for (const d of deltas) {
            if (!d || typeof d !== 'object') continue
            const dd = d as Record<string, unknown>
            if (dd['op'] === 'session.removed') {
              const id = String(dd['sessionId'] ?? '')
              if (id) delete this.indexCards[id]
              continue
            }
            // 只认一种 op 名会把 phase 更新静默丢掉，外面列表就冻结成旧状态
            // （「里跑外闲」）——凡是携带全量 session 的 op 一律按 upsert 收。
            const s = dd['session']
            if (s && typeof s === 'object') {
              for (const c of cardsFromIndex([s])) {
                this.indexCards[c.sessionId] = c
              }
            }
          }
        }
        this.indexSeq =
          typeof frame['toSeq'] === 'number' ? (frame['toSeq'] as number) : this.indexSeq
      }
    },

    setSessionsQuery(q: string): void {
      this.sessionsQuery = q
    },

    // ────────────────────── 会话（聊天记录） ──────────────────────

    /** 打开会话：订阅帧 → 快照 / 增量应用。 */
    async openSession(sessionId: string, title?: string): Promise<void> {
      const conv = this.conv
      if (!conv) return
      this.chatLoading = true
      this.sendError = ''
      this.chat = createConvState()
      this.chatMeta = { sessionId, title: title ?? sessionId.slice(0, 18) }
      const state = this.chat
      this.loadingOlder = false

      const applyFrame = (frame: Record<string, unknown>) => {
        // 会话已切换：迟到的帧直接丢（否则会把旧会话的行灌进新会话）。
        if (this.chat !== state) return
        const payload = frame['payload']
        if (!payload || typeof payload !== 'object') return
        const p = payload as Record<string, unknown>

        if (p['kind'] === 'snapshot') {
          const snap = p['snapshot']
          if (!snap || typeof snap !== 'object') return
          applySnapshot(state, snap as Record<string, unknown>)
          state.seq = typeof frame['toSeq'] === 'number' ? (frame['toSeq'] as number) : state.seq
          return
        }
        if (p['kind'] === 'deltas') {
          const result = applyDeltasFrame(state, frame, p)
          if (result === 'gap') {
            this.log(`[conv] gap → resync (seq=${state.seq})`)
            conv.resync(sessionId)
          }
        }
      }

      chatSub?.cancel()
      chatSub = conv.subscribeSession(sessionId, applyFrame)
      this.chatLoading = false
    },

    closeSession(): void {
      chatSub?.cancel()
      chatSub = null
      this.chat = null
      this.chatMeta = null
      this.sendError = ''
      this.loadingOlder = false
    },

    /** 上滑翻页：拉更早 60 条，去重前置合并。 */
    async loadOlder(): Promise<void> {
      const conv = this.conv
      const state = this.chat
      const sid = this.chatMeta?.sessionId
      if (!conv || !state || !sid || this.loadingOlder) return
      // 游标用**窗口最小 rowId**，不是 firstRowId 字段——BUG-28 实证：
      // firstRowId 恒为 1 会让翻页死锁（每次拉回同一批）。
      const cursor = olderCursor(state)
      if (cursor == null || !hasMoreOlder(state)) return
      this.loadingOlder = true
      try {
        const older = (await conv.rowsRange(sid, cursor, 60)) as ConvRow[]
        const added = mergeOlder(state, older)
        this.log(`[conv] rowsRange before=${cursor} → +${added} 行`)
      } catch (e) {
        this.log(`[conv] rowsRange 失败: ${e}`)
      } finally {
        this.loadingOlder = false
      }
    },

    /** 手动强制重同步（整份快照）——观感卡住时的自救入口。 */
    forceResync(): void {
      const sid = this.chatMeta?.sessionId
      if (sid) this.conv?.resync(sid)
    },

    // ────────────────────── 发送 / 停止 ──────────────────────

    /** 发送文本。失败时把服务端给的具体原因解出来（别只说「发送失败」）。 */
    async sendText(text: string): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid || !text.trim()) return
      this.sendError = ''
      try {
        await conv.sendText(sid, text)
      } catch (e) {
        this.sendError = errorValueText(e) ?? String(e)
        this.log(`[conv] sendText 失败: ${this.sendError}`)
        throw e
      }
    },

    /** 停止输出。 */
    async stop(): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid) return
      try {
        await conv.stop(sid)
      } catch (e) {
        this.sendError = errorValueText(e) ?? String(e)
        this.log(`[conv] stop 失败: ${this.sendError}`)
      }
    },

    // ────────────────────────── 断开 ──────────────────────────

    disconnect(): void {
      this.closeSession()
      this.session?.dispose()
      this.session = null
      this.bridge = null
      this.conv = null
      this.task = null
      this.workspace = null
      this.workspaces = []
      this.taskCards = []
      this.indexCards = {}
      this.relayState = 'idle'
    },
  },
})
