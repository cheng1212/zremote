# ZCode Remote v4 业务接口清单

> 逆向自官方客户端实现 + 生产环境实测验证（2026-09-04）。
> 五层：Relay → 信令 → rpc-frame 分片 → Channel IPC → 业务方法。
> 协议常量集中在 `lib/protocol/constants.dart`，更新时只改这一个文件。

## L1 Relay 层（`wss://zcode.z.ai/ws?mid=<mid>`，JSON 文本帧）

| 帧 | 方向 | 说明 |
|---|---|---|
| `auth_init` | C→S | `{type, role:"terminal", device_sid, meta:{platform,version,name}, client_ts}` |
| `auth_challenge` | S→C | `{type, server_ts, nonce}` |
| `auth_response` | C→S | `{type, device_sid, proof, client_ts}`；`proof = base64url_nopad(HMAC-SHA256(key=utf8(hash), msg="<nonce>|<role>|<sid>"))` |
| `auth_ack` | S→C | `{type, device_sid, terminal_sid, pair_status:"matched"}` |
| `pair_status_query` | C→S | 心跳，10s 一次 |
| `pair_status_ack` | S→C | `{pair_status: waiting/matched}` |
| `data` | 双向 | `{type:"data", payload:{...}, client_ts}` — 业务都走这里 |
| `error` | S→C | `{code:"KICKED", message}` |

关闭码：4004 session-not-found / 4009 session-conflict / 4010 desktop-disconnected / 4011 session-expired / 4012 workspace-closed / 4013 invalid-mobile-connection。

## L2 信令层（`data.payload`，`zcode_type` + `requestId` 回显匹配）

| zcode_type | 方向 | 说明 |
|---|---|---|
| `bootstrap-request` / `bootstrap-response` | C→S / S→C | 整机概览：`result.tasks[]`、`result.mobileViewState` |
| `workspace-list-request` / `workspace-list-response` | C→S / S→C | 工作区列表 `result.tasks[]`、`activeWorkspaceKey` |
| `workspace-bridge-open` / `workspace-bridge-ready` / `workspace-bridge-error` | C→S / S→C | 开桥：`{bridgeSessionId, bridgeGeneration, workspaceKey, taskId?, recoveryId?}` → ready 带 `{bridge:{bridgeSessionId, bridgeGeneration, recoveryId, workspaceKey, workspacePath, workspaceIdentity?, initialTaskId}}` |
| `workspace-reconnect-request` / `workspace-reconnect-response` | C→S / S→C | 断线快速恢复 `{workspaceKey}` |
| `mobile-view-state-update` | C→S | `{viewState:{activeWorkspaceKey, activeTaskId?, updatedAt}, deviceInfo}` |
| `workspace-list-updated` | S→C 推送 | 任务列表变化 |
| `bridge-degraded` | S→C 推送 | `{bridgeSessionId, reason:"rpc-transport-fault"...}` |

## L3 rpc-frame 分片（大消息走 `data.payload`，信封 <1MiB）

`{zcode_type:"rpc-frame", bridgeSessionId, bridgeGeneration?, recoveryId?, seq, messageSeq, fragmentIndex, fragmentCount, messageBytes, checksum:{algorithm:"crc32", value}, dataBase64}`
- 每片原文 ≤512KiB（base64 后 <1MiB）；消息 ≤16MiB；≤64 片
- 收齐后回 `{zcode_type:"rpc-frame-ack", bridgeSessionId, ackMessageSeq}`
- **bridge 路径上每条组装后的消息就是一个 Channel IPC body（无 13 字节头）**

## L4 Channel IPC（value-stream 编码）

- 值编码 tag：0=Undefined 1=String 2=Buffer 3=VSBuffer 4=Array 5=Object(JSON) 6=Int(0..0x7FFFFFFF)；长度/计数 7-bit LE varint
- 请求头 `[reqType, reqId, channelName, methodName]` + arg（调用=参数数组，事件=自由值）
- reqType：100 Promise / 101 PromiseCancel / 102 EventListen / 103 EventDispose
- resType：200 Initialize / 201 PromiseSuccess / 202 PromiseError / 203 PromiseErrorObj / 204 EventFire

## L5 业务通道 × 方法（全部爬取）

### `zcode-agent` — 会话/对话核心（Conversation V4，protocolVersion=3，appVersion="3.6.5"）

**生命周期**：`helloConversationV4` → `initializeConversationV4([{kind:"clientHello", protocolVersion:3, clientId, clientKind:"mobileApp", appVersion}])`（hello 返回 `connectionId`，附件上传要用）

**订阅**（订阅 ack 带 `ack.subscriptionId`、`ack.logEpoch`；帧走 EventFire）：
| 方法 | 事件 | topic |
|---|---|---|
| `subscribeConversationV4({scope, sessionId})` | `onDynamicConversationFrame` | `conversation/<sessionId>` |
| `unsubscribeConversationV4` / `resyncConversationV4({forceSnapshot:true})` | | |
| `subscribeSessionsIndexV4({scope, runtimePolicy:"existing-only"})` | `onDynamicSessionsIndexFrame` | `sessions-index/<workspaceIdentity\|\|workspacePath>` |
| `unsubscribeSessionsIndexV4` / `resyncSessionsIndexV4` | | |

帧结构：`{wireVersion:3, kind:"complete"|"fragment", topic, subscriptionId, frame|logicalFrameId+fragmentIndex+fragmentCount+dataBase64}`；frame.payload = `{kind:"snapshot", snapshot}` 或 `{kind:"deltas", deltas, fromSeq, toSeq}`。

**命令** `sendConversationCommandV4({scope, envelope})`，envelope=`{commandId, clientId, sessionId, type, payload, issuedAt, baseRevision?(CAS), baseLogEpoch?(行级)}`：

| 命令 | payload | CAS |
|---|---|---|
| `createSession` | `{workspaceId, firstInput?:{text, attachments?}, config?, runtimeModel?, mcpServers?}`（sessionId=null） | |
| `sendText` | `{text, attachments?, heldQueueDisposition?, toolDisallowlist?...}` | |
| `sendGoalCommand` | `{text, displayText?}` | |
| `stop` / `compact` | `{}` | |
| `pauseGoal` / `resumeGoal` | `{}` | ✓ |
| `switchModelConfig` | `{provider, model, thought}`（三者必填；GLM 家族 thought: max/high/nothink，Turbo: enabled/off） | ✓ |
| `switchCollaborationMode` | `{mode: build/edit/plan/yolo}` | ✓ |
| `setFollowupMode` | `{mode: queue/guide}` | ✓ |
| `setApprovalMode` | `{mode: askBeforeChange/autoEdit/planMode/fullAccess}` | ✓ |
| `resolveInteraction` | `{interactionId, answer:{optionId? \| action? \| freeText? \| content?}}`（permission 用 optionId；questions 用 `{action:"accept", content:{answers:[...]}}`） | |
| ↳ questions 精确形状（2026-09-11 实测） | 进来：`pendingInteractions[].payload = {kind:'userInput', freeText:bool, prompt, questions:[{question, header, multiSelect, options:[{value,label,description}]}]}`；**无 id / 无 required / 无 allowOther**，选项标识是 `value`。<br>回传：`{action:'accept', content:{answers:[{question:'题干原文', selected:['value',…]}]}}` —— **answers 是数组**，元素键是题干原文（服务端无 id）。实测返回 `{status:accepted}` 且 pending 立刻清空。 | ✓ |
| `retryTurn` / `forkAssistant` / `editUserQuery` / `applyFileRewind` | `{target:{rowId, entityId?}, newText?}` | ✓+行级 |
| `setAssistantFeedback` | `{target, feedback: like/dislike/null}` | ✓+行级 |
| `sendQueuedNow` / `deleteQueueItem` / `editQueueItem` / `setAutoDrain` | `{queueItemId...}` / `{autoDrain}` | ✓ |
| `createSelectionSideSession` | `{}` | |

**查询**（channel 调用，非命令）：`conversationPlansV4`、`conversationFileChangesV4`、`conversationFileRewindPreviewV4`、`conversationRowsRangeV4({sessionId, beforeRowId?, limit:60})`

**附件**：`attachmentBeginV4` → `attachmentChunkV4`(384KiB/片 base64) → `attachmentCommitV4`；读 `attachmentReadV4({ref, offset, limit})`

**快照 snapshot 关键字段**：`control.phase`(running/idle/prewarming…)、`config.{provider,model,thought,thoughtLevels,mode,approvalMode,followupMode}`、`revision`、`usage.{contextWindow.{usedTokens,maxTokens}, cumulative}`、`queue.{items,autoDrain}`、`plan`、`goal`、`pendingInteractions[]`、`inputRouting.mode`、`backgroundWorks[]`、`rows.window[]+totalCount+firstRowId`

**deltas op**：`row.appended` / `row.upserted` / `row.removed({fromRowId})` / `row.delta({rowId, path: text|inputText|output.text|summaryText, append})` / `state.updated({patch})`

**行类型**：`userInput` / `assistantText` / `reasoning` / `toolCall` / `subagent` / `turnHeader` / `timelineMarker`；行内 `state: streaming|...`

### `zcode-task`
`prepareWorkspace(scope)` → `{configOptions:[{id: model|thought_level|mode, options:[{value,name,modelProviderName?}], currentValue}], slashCommands[]}`；
`getTaskTokenUsage(scope)`、`getTaskSnapshotWithEtag(...)`；
`listTasks` / `listPinnedTasks` / `listArchivedTasks` / `setTaskUnread` / `setTaskPinned` / `archiveTask` / `unarchiveTask` / `renameTask` / `deleteTask`

### `skills`：`list({workspacePath, workspaceIdentity?, provider:"glm"})` → 技能列表（composer `$name` 触发）
### `commands`：`list(scope)` → 斜杠命令
### `zcode-agent`（自动化）：`listAllAutomations` / `createAutomation` / `setAutomationEnabled` / `deleteAutomation` / `runAutomationNow` / `restartAutomation`
### `zcode-agent`（插件）：`listPlugins(scope)`
### `model-provider`：`getAll` / `save` / `delete`

### 其余通道（探索页注册，方法待按需逆向）
`file` `system` `terminal` `git` `git-checkpoint` `setting` `credential` `broadcast` `zcode-session` `file-watcher` `oauth` `usage-stats` `coding-plan-subscription` `skill-sync` `mcp-sync` `plugin-sync` `plugins` `plugin-management` `subagents` `hooks` `memory` `output-style` `settings-sync` `bots` `feedback` `repo-wiki` `prompt-attachment-transfer` `off-peak-task`

## scope 约定
`{workspacePath: String, workspaceIdentity?: String}`，来自 workspace 对象 / bridge 返回。
