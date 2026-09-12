/// App 级 store：连接生命周期 + 当前会话状态（Pinia）。
/// 对齐 Flutter 端 ZApp（state/app_controller.dart）的核心状态机。
import { defineStore } from 'pinia'
import {
  RemoteSession,
  Bridge,
  type Workspace,
} from '../protocol/remoteSession'
import { ConversationV4, type ConvRow } from '../protocol/conversation'
import { parseLinkParams, type LinkParams } from '../protocol/linkParams'

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

interface ChatState {
  sessionId: string
  rows: ConvRow[]
  seq: number
  logEpoch: string | null
  ready: boolean
}

export const useAppStore = defineStore('app', {
  state: () => ({
    relayState: 'idle' as RelayUiState,
    failure: '' as string,
    params: null as LinkParams | null,
    session: null as RemoteSession | null,
    bridge: null as Bridge | null,
    conv: null as ConversationV4 | null,
    workspaces: [] as Workspace[],
    workspace: null as Workspace | null,
    connecting: false,
    chatLoading: false,
    chat: null as ChatState | null,
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
          String(w['workspacePath'] ?? '').split(/[\\/]/).filter(Boolean).pop() ??
          '',
      )
    },
  },

  actions: {
    log(line: string): void {
      this.logs.push(`${new Date().toLocaleTimeString()} ${line}`)
      if (this.logs.length > 500) this.logs.splice(0, this.logs.length - 500)
    },

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
        // 工作区选择：记住上次的优先；多个且没用过留给用户切。
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

    /** 打开工作区：开桥 + 订阅 sessions-index。 */
    async openWorkspace(w: Workspace): Promise<void> {
      const session = this.session
      if (!session) throw new Error('未连接')
      const key = String(w['workspaceKey'] ?? w['workspacePath'] ?? '')
      if (!key) throw new Error('工作区缺少 key')
      this.chat = null
      this.conv = null
      const bridge = await session.openBridge(key)
      this.bridge = bridge
      this.workspace = w
      localStorage.setItem('lastWorkspaceKey', key)
      const conv = new ConversationV4(bridge, (l) => this.log(l))
      this.conv = conv
      // sessions-index 实时帧 → 任务列表（后续接 tasks store）
      conv.subscribeIndex((frame) => {
        this.log(`[index] seq=${frame['toSeq']} sessions=${Object.keys((frame['snapshot'] as object) ?? {}).length}`)
      })
    },

    /** 打开会话：订阅 conv 帧 → rows 快照/增量。 */
    async openSession(sessionId: string): Promise<void> {
      const conv = this.conv
      if (!conv) return
      this.chatLoading = true
      this.chat = { sessionId, rows: [], seq: 0, logEpoch: null, ready: false }
      const state = this.chat
      const applyFrame = (frame: Record<string, unknown>) => {
        const payload = frame['payload'] as Record<string, unknown> | undefined
        if (!payload) return
        const kind = payload['kind']
        if (kind === 'snapshot') {
          const snap = payload['snapshot'] as Record<string, unknown> | undefined
          if (!snap) return
          state.logEpoch = (snap['logEpoch'] as string | undefined) ?? state.logEpoch
          const window = snap['rows'] as ConvRow[] | undefined
          state.rows = window ? [...window] : []
          state.seq = (snap['seq'] as number | undefined) ?? state.seq
          state.ready = true
        } else if (kind === 'deltas') {
          for (const d of (payload['deltas'] as Record<string, unknown>[] | undefined) ?? []) {
            state.seq = (d['toSeq'] as number | undefined) ?? state.seq
            const upsert = d['upsert'] as ConvRow | undefined
            const del = d['delete'] as Record<string, unknown> | undefined
            if (upsert && upsert['rowId'] != null) {
              const i = state.rows.findIndex((r) => r.rowId === upsert.rowId)
              if (i >= 0) state.rows.splice(i, 1, upsert)
              else state.rows.push(upsert)
            } else if (del && del['rowId'] != null) {
              const rid = del['rowId'] as number
              const i = state.rows.findIndex((r) => r.rowId === rid)
              if (i >= 0) state.rows.splice(i, 1)
            }
          }
        }
      }
      conv.subscribeSession(sessionId, (frame) => {
        if (this.chat !== state) return
        applyFrame(frame)
      })
      this.chatLoading = false
    },

    async sendText(text: string): Promise<void> {
      const conv = this.conv
      const sid = this.chat?.sessionId
      if (!conv || !sid) return
      await conv.sendText(sid, text)
    },

    disconnect(): void {
      this.session?.dispose()
      this.session = null
      this.bridge = null
      this.conv = null
      this.workspace = null
      this.workspaces = []
      this.chat = null
      this.relayState = 'idle'
    },
  },
})
