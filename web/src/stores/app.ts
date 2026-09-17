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
import type { Subscription } from '../protocol/subscription'
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
import {
  buildAskAnswersPayload,
  type AskAnswer,
  type AskQuestion,
} from '../lib/ask'
import {
  MAX_FILE_BYTES,
  exceedsLimit,
  formatBytes,
  guessMime,
} from '../lib/upload'
import { attachmentBlobs } from '../lib/blobCache'
import { sniffImageMime } from '../lib/attachments'

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
let chatSub: Subscription | null = null
let indexSub: Subscription | null = null

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
    indexLogEpoch: null as string | null,
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

    // —— 附件上传 ——
    /** 上传进度 0~1；null = 没有在传。 */
    uploadPct: null as number | null,
    uploadName: '',
    uploadErr: '',
    /** 已上传待发送的附件（{ref,fileName,mime,bytes}）。 */
    pendingAttachments: [] as { ref: string; fileName: string; mime: string; bytes: number }[],

    // —— 附件读取（网页端唯一的「读文件」途径） ——
    /** ref → blob URL（已取回并解码的附件）。 */
    attachmentUrls: {} as Record<string, string>,
    attachmentLoading: {} as Record<string, boolean>,
    attachmentErrors: {} as Record<string, string>,

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

    /**
     * 待回答的交互（询问 / 审批）。
     * **非空时服务端在等回答、回合不会继续**——不渲染面板会话就永久卡住。
     */
    pendingInteractions(state): Record<string, unknown>[] {
      const list = state.chat?.snapshot?.['pendingInteractions']
      return Array.isArray(list) ? (list as Record<string, unknown>[]) : []
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
      // 传 getBase 让断档 resync 能带上正确的 seq/logEpoch——不带会退化成
      // 「从头重放」，服务端可能直接拒绝或推回一大坨。
      indexSub?.cancel()
      indexSub = conv.subscribeIndex(
        (frame) => this.applyIndexFrame(frame),
        () => ({ seq: this.indexSeq, logEpoch: this.indexLogEpoch }),
      )

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
        const snapObj = snap as Record<string, unknown>
        const sessions = snapObj['sessions']
        const next: Record<string, SessionCard> = {}
        for (const c of cardsFromIndex(sessions)) next[c.sessionId] = c
        this.indexCards = next
        this.indexLogEpoch =
          typeof snapObj['logEpoch'] === 'string' ? (snapObj['logEpoch'] as string) : null
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
      // 传 getBase：断档 resync 要带当前 seq/logEpoch，服务端据此决定
      // 「补发缺口」还是「重发整份快照」。
      chatSub = conv.subscribeSession(sessionId, applyFrame, () => ({
        seq: state.seq,
        logEpoch: state.logEpoch,
      }))
      this.chatLoading = false
    },

    closeSession(): void {
      chatSub?.cancel()
      chatSub = null
      this.chat = null
      this.chatMeta = null
      this.sendError = ''
      this.loadingOlder = false
      this.clearAttachmentState()
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

    /** 发送文本（带已上传的附件）。失败时把服务端给的具体原因解出来。 */
    async sendText(text: string): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid) return
      const attachments = this.pendingAttachments
      if (!text.trim() && attachments.length === 0) return
      this.sendError = ''
      try {
        await conv.sendText(sid, text, {
          attachments: attachments.length
            ? attachments.map((a) => ({
                ref: a.ref,
                fileName: a.fileName,
                mime: a.mime,
                bytes: a.bytes,
              }))
            : undefined,
        })
        // 只有发送成功才清附件——失败要留着让用户重发，不能让他重传一遍。
        if (attachments.length) this.pendingAttachments = []
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

    // ────────────────────── 询问 / 审批（不回传会话会卡死） ──────────────────────

    /**
     * 回答 questions 类交互。
     * 形状：`{action:'accept', content:{answers:[{question:题干原文, selected:[…]}]}}`
     * —— answers 是数组、键是**题干原文**（服务端没有 id）。
     */
    async resolveQuestions(
      interactionId: string,
      questions: AskQuestion[],
      answers: AskAnswer[],
    ): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid || !interactionId) return
      const payload = buildAskAnswersPayload(questions, answers)
      try {
        await conv.resolveInteraction(sid, interactionId, {
          action: payload.action,
          content: payload.content,
        })
        this.log(`[conv] resolveInteraction(questions) ${interactionId}`)
      } catch (e) {
        this.sendError = errorValueText(e) ?? String(e)
        this.log(`[conv] resolveInteraction 失败: ${this.sendError}`)
      }
    },

    /** 回答 permission 类交互（用 optionId 回传）。 */
    async resolvePermission(
      interactionId: string,
      optionId: string,
      freeText?: string,
    ): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid || !interactionId) return
      try {
        await conv.resolveInteraction(sid, interactionId, {
          optionId,
          ...(freeText ? { freeText } : {}),
        })
        this.log(`[conv] resolveInteraction(permission) ${interactionId} → ${optionId}`)
      } catch (e) {
        this.sendError = errorValueText(e) ?? String(e)
        this.log(`[conv] resolveInteraction 失败: ${this.sendError}`)
      }
    },

    // ────────────────────── 附件上传 ──────────────────────

    /**
     * 上传一个文件到当前会话。
     *
     * 走 Channel IPC 的 `attachmentBeginV4 → ChunkV4 → CommitV4`（**不是 HTTP**），
     * 所以拿不到浏览器原生字节进度，进度只能按「已发片数 / 总片数」本地计数。
     * 服务端把文件落到**会话 cwd 的 `uploads/`**，返回的 ref 随消息发出去。
     */
    async uploadAttachment(file: File): Promise<boolean> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid) return false

      if (exceedsLimit(file.size)) {
        this.uploadErr = `${file.name} 超过 ${formatBytes(MAX_FILE_BYTES)}，暂不支持发送`
        return false
      }
      const mime = guessMime(file.name, file.type)
      this.uploadErr = ''
      this.uploadName = file.name
      this.uploadPct = 0
      let cancelled = false
      this._cancelUpload = () => {
        cancelled = true
      }
      try {
        const bytes = new Uint8Array(await file.arrayBuffer())
        const res = await conv.attachmentPut(sid, {
          fileName: file.name,
          mime,
          bytes,
          onProgress: (p) => {
            this.uploadPct = p
          },
          isCancelled: () => cancelled,
        })
        this.pendingAttachments = [...this.pendingAttachments, res]
        this.log(`[upload] ${file.name} → ${res.ref}`)
        return true
      } catch (e) {
        const msg = errorValueText(e) ?? String(e)
        this.uploadErr = `${file.name} 上传失败：${msg}`
        this.log(`[upload] 失败: ${msg}`)
        return false
      } finally {
        this.uploadPct = null
        this.uploadName = ''
        this._cancelUpload = null
      }
    },

    /** 取消在途上传（分片边界生效——每片一个网络往返，边界是唯一的取消窗口）。 */
    cancelUpload(): void {
      this._cancelUpload?.()
    },

    removeAttachment(ref: string): void {
      this.pendingAttachments = this.pendingAttachments.filter((a) => a.ref !== ref)
    },

    clearAttachments(): void {
      this.pendingAttachments = []
    },

    /** 上传取消旗标（模块级资源，不进 state）。 */
    _cancelUpload: null as (() => void) | null,

    // ────────────── 附件读取（浏览器不能读本地路径，只能走协议） ──────────────

    /**
     * 取回附件内容并返回可显示的 blob URL。
     *
     * **为什么必须走协议**：浏览器安全沙箱不允许网页读本地文件路径
     * （`D:\…` 读不到、`file://` 加载不了）。Flutter 是原生 App 才有文件系统
     * 权限，所以它能 `file.readAsBytes()`；Web 只能按 ref 让服务端把字节送回来。
     * 这不是权限配置问题，是浏览器设计。
     *
     * 已取回的走 blob 缓存（命中即返回，不重复拉）。
     */
    async loadAttachment(ref: string): Promise<string | null> {
      if (!ref) return null
      const cached = attachmentBlobs.get(ref)
      if (cached) {
        if (this.attachmentUrls[ref] !== cached) {
          this.attachmentUrls = { ...this.attachmentUrls, [ref]: cached }
        }
        return cached
      }
      const conv = this.conv
      const sid = this.chatMeta?.sessionId
      if (!conv || !sid) return null
      if (this.attachmentLoading[ref]) return null

      this.attachmentLoading = { ...this.attachmentLoading, [ref]: true }
      try {
        const { bytes, mediaType } = await conv.attachmentRead(sid, ref)
        if (bytes.length === 0) throw new Error('附件内容为空')
        // mime 认不出时按魔数补判——相册选的无后缀图常见这种情况，
        // 不补判就会被当成普通文件显示成 chip。
        const mime = mediaType || sniffImageMime(bytes) || 'application/octet-stream'
        const url = attachmentBlobs.put(ref, bytes, mime)
        this.attachmentUrls = { ...this.attachmentUrls, [ref]: url }
        return url
      } catch (e) {
        const msg = errorValueText(e) ?? String(e)
        this.attachmentErrors = { ...this.attachmentErrors, [ref]: msg }
        this.log(`[attach] 读取失败 ${ref}: ${msg}`)
        return null
      } finally {
        const nextLoading = { ...this.attachmentLoading }
        delete nextLoading[ref]
        this.attachmentLoading = nextLoading
      }
    },

    /** 清掉读取态（切会话时调用——blob 缓存保留，跨会话复用）。 */
    clearAttachmentState(): void {
      this.attachmentUrls = {}
      this.attachmentLoading = {}
      this.attachmentErrors = {}
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
