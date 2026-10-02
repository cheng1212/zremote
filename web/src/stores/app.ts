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
import { checkModelGate } from '../lib/modelGate'
import {
  buildModelSelection,
  modelLabel,
  parseConfigGroups,
  type ConfigGroup,
} from '../lib/configOptions'
import {
  parseFileChanges,
  parseRewindPreview,
  rewindTargetOf,
  type FileChangeRow,
  type RewindPreview,
} from '../lib/fileChanges'
import { resetStreamingMarkdown } from '../lib/markdown'
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
/** 首帧兜底计时器：订阅失败时不能让「正在加载」永远挂着。 */
let chatLoadTimer: ReturnType<typeof setTimeout> | null = null
/**
 * 在途 `openSession` 的落地回调。
 * closeSession / 切工作区会把它要等的会话扔掉——不结掉的话
 * 草稿发送流程（await openSession）就永久挂在那个 promise 上。
 */
let chatFirstFrameSettle: ((v: boolean) => void) | null = null
/** 在途上传的取消旗标（模块级资源，不进 state、也不进 actions）。 */
let uploadCancel: (() => void) | null = null
/** 模型选项请求代际：会话切换后迟到的响应按代次丢弃（审计 Web-P2-3）。 */
let configOptionsGen = 0
/**
 * 当前工作区桥。同 chatSub 的理由放模块作用域：它是不可序列化的资源句柄，
 * 放进 state 会被 Pinia 响应式包装（reactive 代理还会丢掉类的私有字段
 * 类型，往协议层传参过不了 TS 的名义检查）。
 */
let bridge: Bridge | null = null

/** 工作区主键：`workspaceKey` 优先，退化到 `workspacePath`（对齐 Flutter `workspaceKeyOf`）。 */
function workspaceKeyOf(w: Workspace | null | undefined): string {
  if (!w) return ''
  return String(w['workspaceKey'] ?? w['workspacePath'] ?? '')
}

export const useAppStore = defineStore('app', {
  state: () => ({
    // —— 连接 ——
    relayState: 'idle' as RelayUiState,
    failure: '' as string,
    params: null as LinkParams | null,
    session: null as RemoteSession | null,
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
    /** 归档视图（`listArchivedTasks`）——独立于 taskCards，不并入主列表。 */
    archivedCards: [] as SessionCard[],
    showArchived: false,
    archivedLoading: false,
    archivedFailed: false,
    /** 列表行操作（置顶/重命名/归档/删除）的失败提示，人话。 */
    listNotice: '',
    listBusy: false,

    // —— 当前会话 ——
    chat: null as ConvState | null,
    chatMeta: null as ChatMeta | null,
    chatLoading: false,
    loadingOlder: false,
    /** 发送失败的人话原因（errorValueText 解出的）。 */
    sendError: '',
    /**
     * 草稿会话（`chatMeta.sessionId === ''`）要用的模型配置。
     * 首条消息时才 `createSession`，config 随建会话下发，再由闸门校验落位。
     */
    draftConfig: null as Record<string, unknown> | null,

    // —— 模型 / 模式选项（`getTaskConfigOptions`）——
    /** 选项组缓存。⚠️ 是**会话域**的：`getTaskConfigOptions` 要 taskId。 */
    configGroups: [] as ConfigGroup[],
    /** 这批选项属于哪个会话——不记就会把上一个会话的模型列表串到下一个。 */
    configTaskId: '',
    configLoading: false,
    configError: '',

    // —— 本回合文件变更 / 回滚 ——
    changes: [] as FileChangeRow[],
    changesLoading: false,
    changesError: '',
    /** 回滚预览（服务端算好的 canApply 与安全/不安全文件计数）。 */
    rewindPreview: null as RewindPreview | null,
    /** 待回滚的回合目标（预览与执行必须同一个，否则可能滚到别的回合）。 */
    rewindTarget: null as { rowId: number; entityId: string } | null,
    rewinding: false,

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

    /** 归档列表（同一条搜索过滤规则，别让两个视图行为不一致）。 */
    archived(): SessionCard[] {
      return filterCards(sortCards(this.archivedCards), this.sessionsQuery)
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

    /** 顶栏当前模型短名。拿不到选项组就是空串，UI 自己降级显示。 */
    modelTag(state): string {
      // 草稿没有会话域选项组：亮出**将要用的**模型（手选过 draftConfig 用
      // 它，否则是工作区默认），不能拿上一个会话的 modelTag 冒充
      //（审计 Web-P2-4）。
      if (state.chatMeta && !state.chatMeta.sessionId) {
        const m = state.draftConfig?.['model']
        return typeof m === 'string' && m ? m : '默认模型'
      }
      return modelLabel(state.configGroups)
    },

    /** 会话级出错（服务端不建助手行时，时间线什么都不渲染——要自己提示）。 */
    chatError(): string {
      return isErrorPhase(this.phase) ? '本轮回复中断' : ''
    },

    canLoadOlder(state): boolean {
      return state.chat != null && hasMoreOlder(state.chat) && !state.loadingOlder
    },

    /** 草稿态：进了聊天页但还没有 sessionId，首条消息才建会话。 */
    isDraft(state): boolean {
      return state.chatMeta != null && !state.chatMeta.sessionId
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
      let session: RemoteSession | null = null
      try {
        session = new RemoteSession(params, (l) => this.log(l))
        this.session = session
        let wasReconnecting = false
        session.relay.onState(() => {
          const s = session!.relay.state as RelayUiState
          const recovered = wasReconnecting && s === 'paired'
          wasReconnecting = s === 'reconnecting'
          this.relayState = s
          if (recovered) {
            // 订阅本身的重建在协议层（Bridge.onRecovered → resubscribe），
            // 这里只留痕：重连成功 ≠ 界面已恢复，得等快照重放回来。
            this.log('[relay] 重连成功，等待桥恢复与快照重放')
          }
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
        // 失败必须拆干净：孤儿 session 的重连定时器/心跳继续跑，旧 onState
        // 闭包还会往 store 写状态，relayState 卡死在 connecting（审计 Web-P2-1）。
        session?.dispose()
        if (this.session === session) {
          this.session = null
          this.relayState = 'error'
        }
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
      const key = workspaceKeyOf(w)
      if (!key) throw new Error('工作区缺少 key')
      this.closeSession()
      // 旧桥先拆（连带旧 index 订阅）：Bridge 底下的 RpcFrames 有 30s 清理
      // 定时器、ChannelClient 挂着 IPC handlers，只覆盖引用旧的永不回收，
      // activeBridges 只增不减，重连恢复还会对废弃桥跑 recoverWithRetry
      //（审计 Web-P2-2）。
      indexSub?.cancel()
      indexSub = null
      if (bridge) session.closeBridge(bridge)
      bridge = null
      this.conv = null
      this.task = null
      this.indexCards = {}
      this.indexSeq = 0
      this.taskCards = []
      // 归档集合是**工作区域**的：换项目不清就会把上个项目的归档列表留在屏上。
      this.archivedCards = []
      this.archivedFailed = false
      this.showArchived = false
      this.listNotice = ''
      bridge = await session.openBridge(key)
      this.workspace = w
      localStorage.setItem('lastWorkspaceKey', key)

      const conv = new ConversationV4(bridge, (l) => this.log(l))
      this.conv = conv
      this.task = new TaskChannel(bridge, (l) => this.log(l))

      // 实时帧：会话列表增量（phase 变化、新会话、删除）
      // 传 getBase 让断档 resync 能带上正确的 seq/logEpoch——不带会退化成
      // 「从头重放」，服务端可能直接拒绝或推回一大坨。
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

    /** 行操作后的重拉：主列表 + （已看过归档时）归档列表。 */
    async reloadLists(): Promise<void> {
      const jobs: Promise<unknown>[] = [this.loadSessions()]
      if (this.showArchived || this.archivedCards.length > 0) jobs.push(this.loadArchived())
      await Promise.allSettled(jobs)
    },

    clearListNotice(): void {
      this.listNotice = ''
    },

    /**
     * 加载归档列表。失败标 `archivedFailed`——不吞成空列表，
     * 那在用户眼里等于「我一个都没归档过」，是会骗人的空态。
     */
    async loadArchived(): Promise<void> {
      const task = this.task
      if (!task) return
      this.archivedLoading = true
      try {
        const res = await task.listArchivedTasks()
        this.archivedFailed = false
        // keepArchived：归档项每条都带 archived:true，按主列表的过滤器会被清空。
        this.archivedCards = cardsFromTasks(res, new Set<string>(), { keepArchived: true })
        this.log(`[task] listArchivedTasks → ${this.archivedCards.length} 条`)
      } catch (e) {
        this.archivedFailed = true
        this.log(`[task] listArchivedTasks 失败: ${String(e)}`)
      } finally {
        this.archivedLoading = false
      }
    },

    async toggleArchivedView(): Promise<void> {
      this.showArchived = !this.showArchived
      if (this.showArchived && this.archivedCards.length === 0 && !this.archivedLoading) {
        await this.loadArchived()
      }
    },

    /**
     * 统一执行一次列表行操作：调用 → 失败落 `listNotice` → 成功由调用方重拉。
     *
     * 刻意**不做乐观更新**：Flutter 端为置顶维护了 `_pinOverrides` + 软失败回滚，
     * 那是三类"两端不一致"bug 的源头；Web 端成功后重拉一次就是权威状态
     * （用户 2026-09-13 裁定：所有会话操作都写通服务端，下次加载两端必一致）。
     */
    async runTaskOp(label: string, fn: () => Promise<unknown>): Promise<boolean> {
      const task = this.task
      if (!task) return false
      this.listBusy = true
      this.listNotice = ''
      try {
        await fn()
        return true
      } catch (e) {
        this.listNotice = `${label}失败：${errorValueText(e) ?? String(e)}`
        this.log(`[task] ${label} 失败: ${this.listNotice}`)
        return false
      } finally {
        this.listBusy = false
      }
    },

    async pinTask(sessionId: string, pinned: boolean): Promise<void> {
      const task = this.task
      if (!task) return
      const verb = pinned ? '置顶' : '取消置顶'
      if (await this.runTaskOp(verb, () => task.setTaskPinned(sessionId, pinned))) {
        await this.reloadLists()
      }
    },

    async renameTask(sessionId: string, title: string): Promise<void> {
      const task = this.task
      const next = title.trim()
      if (!task || !next) return
      if (await this.runTaskOp('重命名', () => task.renameTask(sessionId, next))) {
        await this.reloadLists()
      }
    },

    async archiveTask(sessionId: string): Promise<void> {
      const task = this.task
      if (!task) return
      if (await this.runTaskOp('归档', () => task.archiveTask(sessionId))) {
        // 归档正在看的会话：聊天页留着就是指向一条已经从列表消失的记录。
        if (this.chatMeta?.sessionId === sessionId) this.closeSession()
        await this.reloadLists()
      }
    },

    async unarchiveTask(sessionId: string): Promise<void> {
      const task = this.task
      if (!task) return
      if (await this.runTaskOp('取消归档', () => task.unarchiveTask(sessionId))) {
        await this.reloadLists()
      }
    },

    /**
     * 删除会话。**先 best-effort stop**：运行中的会话直接删，agent 会继续跑完，
     * 白烧 token（BUG-23，用户点名）。stop 失败不拦删除——删才是用户要的结果。
     */
    async removeTask(sessionId: string): Promise<void> {
      const task = this.task
      if (!task) return
      const card = this.allSessions.find((c) => c.sessionId === sessionId)
      if (card && isBusyPhase(card.phase)) {
        try {
          await this.conv?.stop(sessionId)
        } catch (e) {
          this.log(`[task] 删除前 stop 失败（继续删）: ${String(e)}`)
        }
      }
      if (await this.runTaskOp('删除', () => task.deleteTask(sessionId))) {
        if (this.chatMeta?.sessionId === sessionId) this.closeSession()
        await this.reloadLists()
      }
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

    /**
     * 打开会话：订阅帧 → 快照 / 增量应用。
     *
     * resolve(true) = 首帧到了；resolve(false) = 12s 没等到（订阅可能没建立）。
     * 草稿发送流程要在 `createSession` 之后 await 它，才能拿快照做模型闸门。
     */
    async openSession(sessionId: string, title?: string): Promise<boolean> {
      const conv = this.conv
      if (!conv) return false
      this.chatLoading = true
      this.sendError = ''
      this.chat = createConvState()
      this.chatMeta = { sessionId, title: title ?? sessionId.slice(0, 18) }
      const state = this.chat
      this.loadingOlder = false

      // chatLoading 必须真的覆盖到**第一帧**，不能在函数末尾顺手置 false：
      // 订阅是异步的，快照到达前 rows 是空的，此时 ChatView 会显示
      // 「还没有消息，发一条开…」——把「还没到」谎报成「真的没有」。
      let firstFrameArrived = false
      let resolveFirst: (v: boolean) => void = () => {}
      const firstFrame = new Promise<boolean>((resolve) => {
        resolveFirst = resolve
      })
      let settled = false
      const finish = (v: boolean): void => {
        if (settled) return
        settled = true
        if (chatFirstFrameSettle === finish) chatFirstFrameSettle = null
        resolveFirst(v)
      }
      // 并发打开（双击两个会话）：上一场在途的首帧等待先落地（false），
      // 否则它的 promise 永久悬挂、闭包链也挂着（审计 P3-1）。
      chatFirstFrameSettle?.(false)
      chatFirstFrameSettle = finish
      const clearLoadTimer = () => {
        if (chatLoadTimer) {
          clearTimeout(chatLoadTimer)
          chatLoadTimer = null
        }
      }
      clearLoadTimer()
      chatLoadTimer = setTimeout(() => {
        chatLoadTimer = null
        if (this.chat !== state || firstFrameArrived) return
        this.chatLoading = false
        this.log('[conv] 首帧超时（12s）——订阅可能没建立')
        finish(false)
      }, 12_000)

      const applyFrame = (frame: Record<string, unknown>) => {
        // 会话已切换：迟到的帧直接丢（否则会把旧会话的行灌进新会话）。
        if (this.chat !== state) return
        const payload = frame['payload']
        if (!payload || typeof payload !== 'object') return
        if (!firstFrameArrived) {
          firstFrameArrived = true
          this.chatLoading = false
          clearLoadTimer()
          finish(true)
          // 模型/模式选项要 1.7~3.3s，且只认 taskId —— 首帧到了再后台拉，
          // 既不阻塞进会话，也保证拉的时候 sessionId 是有效的。
          void this.loadConfigOptions()
        }
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
      return firstFrame
    },

    /**
     * 进草稿聊天页：此时**还没有** sessionId。
     *
     * 建会话的时机照抄 Flutter（`chat_page.dart:746`）——**首条消息**才
     * `createSession`，且**不**把首条消息塞进 `firstInput`：模型被服务端回退时
     * 消息已经进了错模型，重试还会重复发。空会话 + 闸门 + sendText 才是安全顺序。
     */
    openDraft(): void {
      const conv = this.conv
      if (!conv) return
      this.closeSession()
      this.chat = createConvState()
      this.chatMeta = { sessionId: '', title: '新会话' }
      this.draftConfig = null
      // 选项组是**会话域**的，草稿没有 taskId 拉不了：不清就会把上一个
      // 会话的模型列表和「当前模型」高亮原样带进草稿页，用户以为还在用
      // 刚才那个模型，首条消息可能进错（审计 Web-P2-4）。
      this.configGroups = []
      this.configTaskId = ''
      this.configError = ''
      this.chatLoading = false
      this.sendError = ''
      this.loadingOlder = false
    },

    /** 草稿要用的模型配置（接上模型弹层后由它填；null = 用工作区默认）。 */
    setDraftConfig(config: Record<string, unknown> | null): void {
      this.draftConfig = config
    },

    closeSession(): void {
      chatSub?.cancel()
      chatSub = null
      if (chatLoadTimer) {
        clearTimeout(chatLoadTimer)
        chatLoadTimer = null
      }
      // 结掉在途的 openSession 等待，否则草稿发送流程会挂在拿不到的首帧上。
      const settle = chatFirstFrameSettle
      chatFirstFrameSettle = null
      settle?.(false)
      // 上传是**会话域**的：离开会话先取消在途上传、清空待发列表——否则
      // A 会话传完的 ref 会被追加进 B 会话的待发送，在 B 发送把 A 的附件
      // 带出去（审计 Web-P1-2）。
      uploadCancel?.()
      uploadCancel = null
      this.pendingAttachments = []
      this.uploadErr = ''
      this.uploadPct = null
      this.uploadName = ''
      this.chat = null
      this.chatMeta = null
      this.sendError = ''
      this.loadingOlder = false
      this.clearAttachmentState()
      // 文件变更清单与回滚预览都是**会话级**的：留着会把上个会话的清单
      // 显示在新会话里，更危险的是 rewindTarget 还指着上个回合的行。
      this.clearChanges()
      // 流式渲染的节流态按 rowId 存，行离开列表不会自己消失——切会话时清掉。
      resetStreamingMarkdown()
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

    /** CAS 上下文：`revision` 与 `logEpoch` 都取当前快照，缺了由协议层本地闸拦下。 */
    casCtx(): { baseRevision: number | null; logEpoch: string | null } {
      const snap = this.chat?.snapshot
      const rev = snap && typeof snap['revision'] === 'number' ? (snap['revision'] as number) : null
      return { baseRevision: rev, logEpoch: this.chat?.logEpoch ?? null }
    },

    /**
     * 拉模型 / 思考等级 / 模式选项。
     *
     * 三条实测约束（都来自 Flutter 端 `app_controller.loadPrep`）：
     * · 接口只认 **taskId**，草稿没有 taskId ⇒ 草稿沿用上一次缓存的选项组，不重拉；
     * · 老方法 `prepareWorkspace` 已被桌面端升级**删除**（调它 Method not found），
     *   所以这里**不留回退路径**——回退只会在用户面前多失败一次；
     * · 这一步本身要 1.7~3.3s，是最该给用户"加载中"反馈的一个。
     */
    async loadConfigOptions(force = false): Promise<void> {
      const conv = this.conv
      const task = this.task
      const sid = this.chatMeta?.sessionId ?? ''
      if (!conv || !task) {
        this.configError = '桥未就绪（未连接桌面端），稍后重试'
        return
      }
      if (!sid) return
      if (!force && this.configTaskId === sid && this.configGroups.length > 0) return
      // 代际守卫：A 会话的响应晚于 B 的到达时，不能让 A 落盘——否则顶栏
      // 显示 A 的模型、切模型拿 A 的选项去切 B 的会话（审计 Web-P2-3）。
      const gen = ++configOptionsGen
      this.configLoading = true
      this.configError = ''
      try {
        const groups = parseConfigGroups(await task.getTaskConfigOptions(sid))
        if (gen !== configOptionsGen) {
          this.log('[cfg] 选项响应迟到（会话已切换），丢弃')
          return
        }
        this.configGroups = groups
        this.configTaskId = sid
        if (groups.length === 0) {
          this.configError = '桌面端没返回可选项'
          this.log('[cfg] getTaskConfigOptions 空选项组')
        }
      } catch (e) {
        if (gen !== configOptionsGen) return
        // 不清空已有缓存：拿不到新选项时，让用户至少还能看到上一次的结果。
        this.configError = errorValueText(e) ?? String(e)
        this.log(`[cfg] getTaskConfigOptions 失败: ${this.configError}`)
      } finally {
        if (gen === configOptionsGen) this.configLoading = false
      }
    },

    /** 切模型。草稿态没有会话可切 ⇒ 记成 `draftConfig`，首条消息随建会话下发。 */
    async applyModel(modelValue: string): Promise<boolean> {
      const conv = this.conv
      const sel = buildModelSelection(this.configGroups, modelValue)
      if (!conv) return false
      if (!sel) {
        // 静默 return false 会让按钮点了没反应还查不到原因（审计 P3-8）。
        this.configError = `选项里没有「${modelValue}」（列表可能还没加载好）`
        return false
      }
      if (this.isDraft) {
        this.draftConfig = { ...sel }
        this.configError = ''
        return true
      }
      const sid = this.chatMeta?.sessionId ?? ''
      if (!sid) return false
      this.configError = ''
      try {
        await conv.switchModelConfig(sid, sel, this.casCtx())
        // 以服务端为准：切完重取快照 + 重拉选项，界面显示的永远是落位后的值。
        this.forceResync()
        await this.loadConfigOptions(true)
        return true
      } catch (e) {
        this.configError = errorValueText(e) ?? String(e)
        this.log(`[cfg] 切模型失败: ${this.configError}`)
        return false
      }
    },

    /** 切协作模式（build / edit / plan / yolo）。草稿态同 applyModel：记进 draftConfig。 */
    async applyMode(mode: string): Promise<boolean> {
      const conv = this.conv
      if (!conv) return false
      if (this.isDraft) {
        this.draftConfig = { ...(this.draftConfig ?? {}), mode }
        return true
      }
      const sid = this.chatMeta?.sessionId ?? ''
      if (!sid) return false
      this.configError = ''
      try {
        await conv.switchCollaborationMode(sid, mode, this.casCtx())
        this.forceResync()
        await this.loadConfigOptions(true)
        return true
      } catch (e) {
        this.configError = errorValueText(e) ?? String(e)
        this.log(`[cfg] 切模式失败: ${this.configError}`)
        return false
      }
    },

    // ────────────────────── 文件变更 / 回滚 ──────────────────────

    clearChanges(): void {
      this.changes = []
      this.changesError = ''
      this.changesLoading = false
      this.rewindPreview = null
      this.rewindTarget = null
      this.rewinding = false
    },

    /** 本回合文件变更清单（`conversationFileChangesV4`）。 */
    async loadChanges(): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId ?? ''
      // 预览态按"回合"清，不按"会话"清：对 A 回合预览过回滚后换 B 回合
      // 打开面板，残留的 rewindTarget 会 B 面板滚 A 回合（破坏性，审计
      // 2026-10-03 Web-P1-1）。applyRewind 已先把 target 捕获到局部变量，
      // 这里提前清不影响在途回滚。
      this.rewindPreview = null
      this.rewindTarget = null
      if (!conv || !sid) {
        this.changesError = this.isDraft ? '新会话还没有文件变更' : '桥未就绪'
        return
      }
      this.changesLoading = true
      this.changesError = ''
      try {
        const ctx = this.casCtx()
        const parsed = parseFileChanges(await conv.fileChanges(sid, ctx))
        this.changes = parsed.items
        if (parsed.items.length === 0) this.changesError = '最近回合没有文件变更'
      } catch (e) {
        this.changesError = errorValueText(e) ?? String(e)
        this.log(`[file] fileChanges 失败: ${this.changesError}`)
      } finally {
        this.changesLoading = false
      }
    },

    /**
     * 回滚前必须先预览：`canApply` 与安全/不安全计数是**服务端算的**
     * （它会判断哪些文件被用户自己改过）。客户端不数一遍就滚 = 覆盖用户改动。
     */
    async previewRewind(row: Record<string, unknown>): Promise<void> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId ?? ''
      const target = rewindTargetOf(row)
      if (!conv || !sid) return
      if (!target) {
        this.changesError = '这一回合服务端没给 entityId，滚不回（需要桌面端同一版本的数据）'
        return
      }
      this.changesError = ''
      try {
        this.rewindPreview = parseRewindPreview(
          await conv.fileRewindPreview(sid, target, this.casCtx()),
        )
        this.rewindTarget = target
      } catch (e) {
        this.changesError = errorValueText(e) ?? String(e)
        this.log(`[file] rewindPreview 失败: ${this.changesError}`)
      }
    },

    /** 执行回滚（CAS 行级命令）。调用方必须已经拿到 preview 且 `canApply`。 */
    async applyRewind(): Promise<boolean> {
      const conv = this.conv
      const sid = this.chatMeta?.sessionId ?? ''
      const target = this.rewindTarget
      if (!conv || !sid || !target || !this.rewindPreview?.canApply) return false
      this.rewinding = true
      this.changesError = ''
      try {
        await conv.sendCommand(sid, 'applyFileRewind', { target }, this.casCtx())
        this.forceResync()
        await this.loadChanges()
        this.rewindPreview = null
        this.rewindTarget = null
        return true
      } catch (e) {
        this.changesError = errorValueText(e) ?? String(e)
        this.log(`[file] applyFileRewind 失败: ${this.changesError}`)
        return false
      } finally {
        this.rewinding = false
      }
    },

    // ────────────────────── 发送 / 停止 ──────────────────────

    /** 发送文本（带已上传的附件）。失败时把服务端给的具体原因解出来。 */
    async sendText(text: string): Promise<void> {
      const conv = this.conv
      if (!conv) return
      const attachments = this.pendingAttachments
      if (!text.trim() && attachments.length === 0) return
      this.sendError = ''
      let sid = this.chatMeta?.sessionId ?? ''
      try {
        // 草稿：先建**空**会话 → 订阅拿快照 → 模型闸门放行 → 才发首条。
        // 顺序反了（把首条塞进 firstInput）就没有闸门位置：模型被服务端回退时
        // 消息已经进了错模型，用户重试还会重复发（见 docs/feat-draft-model-ready-gate.md）。
        if (this.isDraft) {
          const key = workspaceKeyOf(this.workspace)
          if (!key) throw new Error('还没选工作区，开不了新会话')
          const created = await conv.createSession(key, {
            config: this.draftConfig ?? undefined,
          })
          // 建会话在途时用户可能已按返回（closeSession 清了 chatMeta）：
          // 不该再把人拽进刚建的会话——卡片已在列表里，用户自己点
          //（审计 Web-P1-4）。
          if (!this.isDraft) {
            this.log('[conv] 草稿发送期间已离开，会话已建但不跳转')
            this.draftConfig = null
            void this.loadSessions()
            return
          }
          const gotFrame = await this.openSession(created, this.chatMeta?.title || '新会话')
          // 首帧超时 snapshot 为 null，checkModelGate 会 ok:false 拦下——
          // 行为是"保守拦截"，不是"跳过"（旧日志写反了，照注释改就会放行
          // 错模型，审计 2026-10-03 Web-P2-7）。
          if (!gotFrame) this.log('[conv] 新会话首帧未到，模型闸门将保守拦截本次发送')
          const gate = checkModelGate(this.chat?.snapshot ?? null, this.draftConfig)
          if (!gate.ok) {
            this.sendError = gate.reason
            throw new Error(gate.reason)
          }
          this.draftConfig = null
          // 新会话本机及时可见：索引流不再复活幽灵卡，卡片由服务端列表承担
          // （Flutter 09-13 多端一致性批次的裁定），建完立刻拉一次。
          void this.loadSessions()
          sid = created
        }
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
      // 上传发起时的会话：完成时校验——中途切了会话，ref 属于旧会话，
      // 追加进新会话的待发列表就是把 A 的附件带进 B（审计 Web-P1-2）。
      const startedSid = sid
      let cancelled = false
      const myCancel = () => {
        cancelled = true
      }
      uploadCancel = myCancel
      try {
        const bytes = new Uint8Array(await file.arrayBuffer())
        const res = await conv.attachmentPut(sid, {
          fileName: file.name,
          mime,
          bytes,
          onProgress: (p) => {
            // 进度条也跟着会话走：离开原会话就别再刷新（残留进度条）。
            if (this.chatMeta?.sessionId === startedSid) this.uploadPct = p
          },
          isCancelled: () => cancelled,
        })
        if (this.chatMeta?.sessionId !== startedSid) {
          this.log(`[upload] ${file.name} 上传完成但已离开原会话，附件丢弃`)
          return false
        }
        this.pendingAttachments = [...this.pendingAttachments, res]
        this.log(`[upload] ${file.name} → ${res.ref}`)
        return true
      } catch (e) {
        const msg = errorValueText(e) ?? String(e)
        if (this.chatMeta?.sessionId === startedSid) {
          this.uploadErr = `${file.name} 上传失败：${msg}`
        }
        this.log(`[upload] 失败: ${msg}`)
        return false
      } finally {
        this.uploadPct = null
        this.uploadName = ''
        // 只清自己的取消旗标：并发上传时后者已覆盖 uploadCancel，
        // 前者的 finally 抢先置 null 会让后者的「取消」失效（审计 Web-P2-5）。
        if (uploadCancel === myCancel) uploadCancel = null
      }
    },

    /** 取消在途上传（分片边界生效——每片一个网络往返，边界是唯一的取消窗口）。 */
    cancelUpload(): void {
      uploadCancel?.()
    },

    removeAttachment(ref: string): void {
      this.pendingAttachments = this.pendingAttachments.filter((a) => a.ref !== ref)
    },

    clearAttachments(): void {
      this.pendingAttachments = []
    },

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
      // 指数订阅也要显式拆掉：Subscription 构造时起了 30s 的分片清理
      // setInterval，只有 cancel() 会清它。只 dispose 桥不取消订阅，
      // 每断开重连一次就留下一个永不销毁的定时器 + 一张分片表。
      indexSub?.cancel()
      indexSub = null
      this.session?.dispose()
      this.session = null
      bridge = null
      this.conv = null
      this.task = null
      this.workspace = null
      this.workspaces = []
      this.taskCards = []
      this.indexCards = {}
      this.archivedCards = []
      this.showArchived = false
      this.archivedFailed = false
      this.listNotice = ''
      this.relayState = 'idle'
    },
  },
})
