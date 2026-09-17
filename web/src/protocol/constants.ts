/// ZCode Remote v4 协议常量 — TS 移植自 lib/protocol/constants.dart（唯一蓝本）。

import { randomUuid } from '../lib/crypto'

export const RELAY_HEARTBEAT_INTERVAL_MS = 10_000
export const RELAY_HEARTBEAT_ACK_TIMEOUT_MS = 30_000
export const RELAY_WAITING_TIMEOUT_MS = 30_000
export const RELAY_RECONNECT_MAX_BACKOFF_MS = 15_000

// --- L2 signaling -----------------------------------------------------
export const SIG_BOOTSTRAP = 'bootstrap-request'
export const SIG_BOOTSTRAP_RESPONSE = 'bootstrap-response'
export const SIG_WORKSPACE_LIST = 'workspace-list-request'
export const SIG_WORKSPACE_LIST_RESPONSE = 'workspace-list-response'
export const SIG_BRIDGE_OPEN = 'workspace-bridge-open'
export const SIG_BRIDGE_READY = 'workspace-bridge-ready'
export const SIG_BRIDGE_ERROR = 'workspace-bridge-error'
export const SIG_BRIDGE_RECONNECT = 'workspace-reconnect-request'
export const SIG_BRIDGE_RECONNECT_RESPONSE = 'workspace-reconnect-response'
export const SIG_VIEW_STATE_UPDATE = 'mobile-view-state-update'
export const PUSH_WORKSPACE_LIST_UPDATED = 'workspace-list-updated'
export const PUSH_BRIDGE_DEGRADED = 'bridge-degraded'

// --- L3 rpc-frame -----------------------------------------------------
export const RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES = 512 * 1024
export const RPC_FRAME_MAX_MESSAGE_BYTES = 16 * 1024 * 1024
export const RPC_FRAME_MAX_FRAGMENTS = 64

// --- L4 channel IPC ---------------------------------------------------
export const IPC_REQ_PROMISE = 100
export const IPC_REQ_PROMISE_CANCEL = 101
export const IPC_REQ_EVENT_LISTEN = 102
export const IPC_REQ_EVENT_DISPOSE = 103

export const IPC_RES_INITIALIZE = 200
export const IPC_RES_PROMISE_SUCCESS = 201
export const IPC_RES_PROMISE_ERROR = 202
export const IPC_RES_PROMISE_ERROR_OBJ = 203
export const IPC_RES_EVENT_FIRE = 204

/** 退订（unsubscribe）短超时：尽力而为的收尾，不等满默认超时。 */
export const IPC_UNSUBSCRIBE_TIMEOUT_MS = 1500

// --- L5 channels ------------------------------------------------------
export const Chan = {
  agent: 'zcode-agent',
  task: 'zcode-task',
  session: 'zcode-session',
  file: 'file',
  system: 'system',
  terminal: 'terminal',
  git: 'git',
  gitCheckpoint: 'git-checkpoint',
  setting: 'setting',
  credential: 'credential',
  broadcast: 'broadcast',
  fileWatcher: 'file-watcher',
  oauth: 'oauth',
  modelProvider: 'model-provider',
  usageStats: 'usage-stats',
  codingPlanSubscription: 'coding-plan-subscription',
  skills: 'skills',
  skillSync: 'skill-sync',
  mcpSync: 'mcp-sync',
  pluginSync: 'plugin-sync',
  plugins: 'plugins',
  pluginManagement: 'plugin-management',
  subagents: 'subagents',
  commands: 'commands',
  hooks: 'hooks',
  memory: 'memory',
  outputStyle: 'output-style',
  settingsSync: 'settings-sync',
  bots: 'bots',
  feedback: 'feedback',
  repoWiki: 'repo-wiki',
  promptAttachmentTransfer: 'prompt-attachment-transfer',
  offPeakTask: 'off-peak-task',
} as const

// --- Conversation V4 --------------------------------------------------
export const CONV_CHANNEL = Chan.agent
export const CONV_PROTOCOL_VERSION = 3
export const CONV_PROTOCOL_APP_VERSION = '3.6.5'
export const CONV_CLIENT_KIND = 'mobileApp'

export const M_HELLO = 'helloConversationV4'
export const M_INITIALIZE = 'initializeConversationV4'
export const M_SEND_COMMAND = 'sendConversationCommandV4'
export const M_SUBSCRIBE_CONV = 'subscribeConversationV4'
export const M_UNSUBSCRIBE_CONV = 'unsubscribeConversationV4'
export const M_RESYNC_CONV = 'resyncConversationV4'
export const M_SUBSCRIBE_INDEX = 'subscribeSessionsIndexV4'
export const M_UNSUBSCRIBE_INDEX = 'unsubscribeSessionsIndexV4'
export const M_RESYNC_INDEX = 'resyncSessionsIndexV4'
export const EV_CONV_FRAME = 'onDynamicConversationFrame'
export const EV_INDEX_FRAME = 'onDynamicSessionsIndexFrame'
export const M_ROWS_RANGE = 'conversationRowsRangeV4'
export const M_PLANS = 'conversationPlansV4'
export const M_FILE_CHANGES = 'conversationFileChangesV4'
export const M_ATTACHMENT_BEGIN = 'attachmentBeginV4'
export const M_ATTACHMENT_CHUNK = 'attachmentChunkV4'
export const M_ATTACHMENT_COMMIT = 'attachmentCommitV4'
export const M_ATTACHMENT_READ = 'attachmentReadV4'
export const M_PREPARE_WORKSPACE = 'prepareWorkspace'

/** 需要 baseRevision（乐观并发）的命令。 */
export const CAS_COMMANDS = new Set([
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
  'sendQueuedNow',
  'editQueueItem',
  'reorderQueueItem',
  'deleteQueueItem',
  'setAutoDrain',
  'switchModelConfig',
  'switchCollaborationMode',
  'setFollowupMode',
  'pauseGoal',
  'resumeGoal',
])

/** CAS 命令中还需要 baseLogEpoch 的（行级 target）。 */
export const ROW_TARGET_COMMANDS = new Set([
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
])

export const ATTACHMENT_CHUNK_BYTES = 384 * 1024

let genIdCounter = 0

/** 本地唯一 id：前缀-毫秒-进程内序号（clientId / commandId / requestId 用）。 */
export function genId(prefix: string): string {
  return `${prefix}-${Date.now()}-${genIdCounter++}`
}

/**
 * RFC4122-ish v4 uuid（附件 uploadId 等本地标识）。
 *
 * ⚠️ **不能直接用 `crypto.randomUUID()`**——它只在安全上下文（https/localhost）
 * 可用，局域网 http 访问时是 `undefined`，调用直接抛 TypeError。
 * 而「手机连局域网 IP」正是本项目主要使用方式。降级实现在 `lib/crypto.ts`。
 */
export function genUuid(): string {
  return randomUuid()
}
