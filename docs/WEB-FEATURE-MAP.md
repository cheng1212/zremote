# zremote Web 客户端功能地图（WEB-FEATURE-MAP）

> **目的**：Flutter 客户端弃用后，把「客户端该有的全部功能与按钮」按 Web 视角重新拆分，
> 每项锚定**后台接口**与**后台数据变化**——因为只有后台数据真的变了，功能才算真的实现。
>
> **方法**（用户 2026-09-18 定）：每个功能走两步深度调研
> ① 现状怎么样 ② 应该怎么做 → 差距即行动项。
>
> **判定口径**：每项必须能回答「调哪个后台方法」「改了后台什么数据」。
> 只改本地 UI 状态、不触达后台的，标 `[纯UI]`，不计入功能实现。
>
> **建立时间**：2026-09-18 | 建立者：Z | 状态：待用户复核

---

## 〇、现状基线（2026-09-18 实测）

| 项 | 移动端（Flutter，**弃用**） | Web 端（**新主战场**） |
|---|---|---|
| 规模 | `lib/` 24,021 行 | `web/src/` 2,329 行 |
| 协议层 | 3,352 行（完整） | **1,738 行（已完整移植）** |
| 状态层 | 4,359 行 | 197 行 |
| UI 层 | 15,507 行 | **394 行** |
| 页面 | 7 个（聊天/任务/自动化/用量/我的/配对/抽屉） | **3 个**（配对/会话/聊天） |
| 会话列表 | 完整（筛选/排序/批量/置顶/归档/搜索） | **无**（要求手输会话 ID） |
| 聊天渲染 | 完整（7 种行类型 + 卡片） | 4 种行类型（纯文本，**无 markdown**） |
| 通知 | Android 原生 4 渠道 + 锁屏全显 | **零** |
| 附件上传 | 完整（图片/文件/进度/取消） | **零** |

**结论：协议层白捡（1,738 行可用），UI + 状态 + 服务约 21,700 行需按 Web 重写。**

---

## 〇之二、后台接口全貌（判断"是否真改变"的基准）

### 可用方法（已实测，`docs/API.md` + `docs/INTERFACE-MATRIX.md`）

**`zcode-agent` 通道 — 会话核心**

| 类别 | 方法 |
|---|---|
| 生命周期 | `helloConversationV4` → `initializeConversationV4([{kind:"clientHello",protocolVersion:3,clientId,clientKind,appVersion}])`（hello 返回 `connectionId`，**附件上传必需**） |
| 订阅 | `subscribeConversationV4` / `unsubscribeConversationV4` / `resyncConversationV4({forceSnapshot:true})` |
| 索引订阅 | `subscribeSessionsIndexV4` / `unsubscribeSessionsIndexV4` / `resyncSessionsIndexV4` |
| 命令 | `sendConversationCommandV4({scope, envelope})` — envelope 带 `commandId/clientId/sessionId/type/payload/issuedAt`，CAS 命令另带 `baseRevision`，行级命令另带 `baseLogEpoch` |
| 查询 | `conversationRowsRangeV4({sessionId,beforeRowId,limit:60})` / `conversationPlansV4` / `conversationFileChangesV4` / `conversationFileRewindPreviewV4` |
| 附件 | `attachmentBeginV4` → `attachmentChunkV4`(384KiB/片 base64) → `attachmentCommitV4` / `attachmentReadV4` |
| 自动化 | `listAllAutomations` / `createAutomation` / `setAutomationEnabled` / `deleteAutomation` / `runAutomationNow` / `restartAutomation` / `listAutomationRuns` |

**命令类型全表**（走 `sendConversationCommandV4` 的 `type`）

| type | payload | CAS | 后台数据变化 |
|---|---|---|---|
| `createSession` | `{workspaceId, firstInput?:{text,attachments?}, config?, runtimeModel?, mcpServers?}`（sessionId=null） | | 新建会话记录；tasks-index 新增一行 |
| `sendText` | `{text, attachments?, heldQueueDisposition?, toolDisallowlist?}` | | rows 追加 userInput 行；`control.phase→running`；忙时进 `queue.items` |
| `sendGoalCommand` | `{text, displayText?}` | | 同上，走 goal 语义 |
| `stop` | `{}` | | `phase→idle`；流式行定稿 |
| `compact` | `{}` | | 上下文压缩；`usage.contextWindow.usedTokens` 下降 |
| `pauseGoal` / `resumeGoal` | `{}` | ✓ | `goal` 状态变更 |
| `switchModelConfig` | `{provider, model, thought}` **三者必填** | ✓ | `config.provider/model/thought` |
| `switchCollaborationMode` | `{mode: build/edit/plan/yolo}` | ✓ | `config.mode` |
| `setFollowupMode` | `{mode: queue/guide}` | ✓ | `config.followupMode` |
| `setApprovalMode` | `{mode: askBeforeChange/autoEdit/planMode/fullAccess}` | ✓ | `config.approvalMode` |
| `resolveInteraction` | `{interactionId, answer}`（permission 用 `optionId`；questions 用 `{action:"accept",content:{answers:[{question,selected:[value]}]}}`） | ✓ | `pendingInteractions` 清空；回合继续 |
| `retryTurn` | `{target:{rowId,entityId?}}` | ✓+行级 | 新增一轮 rowId 段；`revision++` |
| `forkAssistant` | `{target}` | ✓+行级 | **新建会话** |
| `editUserQuery` | `{target, newText}` | ✓+行级 | userInput 行文本变更 + 重跑 |
| `applyFileRewind` | `{target}` | ✓+行级 | **回滚文件系统** + rows 变更 |
| `setAssistantFeedback` | `{target, feedback: like/dislike/null}` | ✓+行级 | 行的 feedback 字段 |
| `sendQueuedNow` / `deleteQueueItem` / `editQueueItem` / `setAutoDrain` | `{queueItemId...}` / `{autoDrain}` | ✓ | `queue.items` / `queue.autoDrain` |
| `deleteSession` / `cancelBackgroundWork` | — | | 会话删除 / `backgroundWorks[]` 移除 |
| `createSelectionSideSession` | `{}` | | 新建侧会话 |

**`zcode-task` 通道 — 任务管理**

`getTaskConfigOptions({taskId})` → 选项组数组 `[{id:'model'|'mode'|'thought_level', currentValue, options:[{value,name,description,modelProviderName?}]}]`（timeout 20s）
`getTaskTokenUsage` / `getTaskSnapshotWithEtag`
`listTasks` / `listPinnedTasks` / `listArchivedTasks` / `setTaskPinned` / `archiveTask` / `unarchiveTask` / `renameTask` / `deleteTask`
（`setTaskUnread` 🔴 桌面端无此方法，双证否决）

> ⚠️ **版本敏感（2026-09-17 实证）**：桌面端**自动升级**后 `prepareWorkspace(scope)` **已被移除**
> （调用即 `Method not found`），客户端改调 `getTaskConfigOptions({taskId})`，旧方法仅留作回退。
> 同时原 `prepareWorkspace` 返回的 `slashCommands[]` 被拆到别的方法，客户端**暂降级为空**。
> **教训**：桌面端会自动升级，接口会消失——客户端必须对每个方法都能优雅降级，
> 且**每接一个接口都要实测**（BUG-35 同款教训）。这条对 Web 端同样适用。

**其余通道**：`skills.list` / `commands.list` / `usage-stats.getAppUsageSnapshot` / `model-provider.{getAll,save,delete}` / `plugins.listPlugins`

**🔴 不可达**（桌面端未挂移动端通道）：`workspace/readState`、`setDefaultModel`、`setDefaultThoughtLevel`、`setDefaultMode`、`upsertModelProvider`、`removeModelProvider`、`generateText`、`session/setModel`、`session/updateRuntimeModelConfig`

**快照关键字段**（判定的数据源）：`control.phase` / `config.{provider,model,thought,thoughtLevels,mode,approvalMode,followupMode}` / `revision` / `usage.{contextWindow,cumulative}` / `queue.{items,autoDrain}` / `plan` / `goal` / `pendingInteractions[]` / `inputRouting.mode` / `backgroundWorks[]` / `rows.window[]+totalCount+firstRowId`

**deltas op**：`row.appended` / `row.upserted` / `row.removed` / `row.delta({path: text|inputText|output.text|summaryText})` / `state.updated({patch})`

**行类型**：`userInput` / `assistantText` / `reasoning` / `toolCall` / `subagent` / `turnHeader` / `timelineMarker`

---

## 一、连接与配对

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 | Flutter 参照 |
|---|---|---|---|---|---|
| 1.1 | 配对链接输入 + 粘贴 | `parseLinkParams`（本地解析，无 RPC） | 无（本地） | ✅ 有 | `pair_page.dart` |
| 1.2 | 连接按钮（busy 守卫） | relay `auth_init`→`auth_challenge`→`auth_response`(HMAC) → `auth_ack` | 服务端 terminal_sid 绑定 | ✅ 有 | `relay_client.dart` |
| 1.3 | 10s 心跳 `pair_status_query` | relay 心跳帧 | 无 | ✅ 有 | 同左 |
| 1.4 | 断线重连（退避 + 状态机） | relay 重连 | 无 | ✅ 有 | 同左 |
| 1.5 | 整机概览 | `bootstrap-request` | 只读 | ✅ 有 | `remote_session.dart` |
| 1.6 | 工作区列表 | `workspace-list-request` | 只读 | ✅ 有 | 同左 |
| 1.7 | 开桥 | `workspace-bridge-open` → `ready` | 服务端建桥会话 | ✅ 有 | 同左 |
| 1.8 | 断线快速恢复 | `workspace-reconnect-request` | 恢复桥 | ⬜ **无** | `remote_session.dart` |
| 1.9 | 视图状态上报 | `mobile-view-state-update` | **服务端记录 activeWorkspaceKey/activeTaskId** | ⬜ **无** | `app_controller` |
| 1.10 | 桥降级提示 | `bridge-degraded` 推送 | 无 | ⬜ **无** | `app_controller` |
| 1.11 | 关闭码人话映射（4004/4009/4010/4011/4012/4013） | — | 无 | ✅ 有 | `relay_client.dart` |

**判定**：1.1~1.7、1.11 已对。**1.8/1.9/1.10 缺**——1.9 尤其重要（多端同步"我在看哪个会话"，缺了会导致手机与桌面视图状态互相打架）。

---

## 二、会话列表（任务页）

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 | Flutter 参照 |
|---|---|---|---|---|---|
| 2.1 | 会话列表（实时） | `subscribeSessionsIndexV4` + `resyncSessionsIndexV4` | 只读（帧推送） | ⚠️ **订阅了但没渲染** | `tasks_page.dart` |
| 2.2 | 列表数据源 | `listTasks` / `listPinnedTasks` / `listArchivedTasks` | 只读 | ⬜ **无** | 同左 |
| 2.3 | 卡片点击进会话 | `subscribeConversationV4` | 无（但触发 1.9） | ⚠️ 要手输 ID | 同左 |
| 2.4 | 置顶 / 取消置顶 | `setTaskPinned` | tasks-index 置顶位 | ⬜ 无 | 同左 |
| 2.5 | 归档 / 取消归档 | `archiveTask` / `unarchiveTask` | 归档状态 | ⬜ 无 | 同左 |
| 2.6 | 重命名 | `renameTask` | 标题 | ⬜ 无 | 同左 |
| 2.7 | 删除 | `deleteTask`（+ 先 `stop` best-effort） | 删除记录 | ⬜ 无 | 同左 |
| 2.8 | 新建会话 | `createSession` | **新建会话记录** | ⬜ 无 | 同左 |
| 2.9 | 每会话 token 角标 | `getTaskTokenUsage` | 只读 | ⬜ 无 | 同左 |
| 2.10 | 搜索（本地过滤） | — | 无 | ⬜ 无 | `task_filters.dart` |
| 2.11 | 筛选 chips（全部/置顶/归档） | — | 无 | ⬜ 无 | 同左 |
| 2.12 | 排序（最近更新） | — | 无 | ⬜ 无 | `task_sort.dart` |
| 2.13 | 置顶组内按活跃时间倒序 | — | 无 | ⬜ 无 | `task_sort.dart` |
| 2.14 | 批量模式（全选/置顶/重命名/归档/删除） | 循环调 2.4~2.7 | 批量变更 | ⬜ 无 | `tasks_page.dart` |
| 2.15 | 状态 chip（呼吸点 / 发送异常标记） | 帧内 `phase` 字段 | 只读 | ⬜ 无 | 同左 |
| 2.16 | 工作区切换器 / 重命名别名 | 本地 + `openWorkspace` | 本地存储 | ⚠️ 半（切换有，别名无） | 同左 |
| 2.17 | 「全部对话」跨项目视图 | 多工作区 `listTasks` 聚合 | 只读 | ⬜ 无 | `app_controller` |
| 2.18 | 下拉刷新 | `resyncSessionsIndexV4` | 无 | ⬜ 无 | 同左 |

**判定**：**整域基本为零**（只有订阅接通、没渲染）。这是 Web 端第一优先——没有列表，客户端等于不能用。
2.7 的「先 stop 再删」是 Flutter 踩过的坑（BUG-23：删运行中会话会白烧 token），必须继承。

---

## 三、聊天页 — 骨架

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 | Flutter 参照 |
|---|---|---|---|---|---|
| 3.1 | 会话订阅（快照 + 增量） | `subscribeConversationV4` | 只读 | ✅ 有（但见 3.5） | `conversation.dart` |
| 3.2 | 标题栏状态 chip | 帧内 `control.phase` | 只读 | ⚠️ 只显示 relayState | `chat_page.dart` |
| 3.3 | 强制重同步（下拉刷新） | `resyncConversationV4({forceSnapshot:true})` | 无（重发快照） | ⚠️ 有方法，UI 未接 | 同左 |
| 3.4 | 回到底部按钮 | — | 无 | ⚠️ 半（有 atBottom 判定，无按钮） | 同左 |
| 3.5 | **断档检测（gap）→ 触发 resync** | `resyncConversationV4` | 无 | ⬜ **缺** ⚠️ 关键 | `conversation.dart` |
| 3.6 | 40ms 微批 | — | 无 | ✅ 有（`BatchQueue`） | 同左 |
| 3.7 | ResyncGate 单飞闸 | — | 无 | ✅ 有 | 同左 |
| 3.8 | 桥降级横幅 + 重连 | 1.8 / 1.10 | 无 | ⬜ 无 | 同左 |
| 3.9 | 订阅失败重试 | `subscribeConversationV4` 重试 | 无 | ⬜ 无 | 同左 |

**判定**：**3.5 是真实缺陷**。Web 的 `BatchQueue` 只转发帧，**没有 `fromSeq != seq` 的 gap 判定**，所以 `resync()` 永远不会被触发——断档后会话内容会**静默缺失**且无人修复。
这是 Flutter 端 BUG-27/28/32 家族修复的核心机制，移植时漏了。**必须补**。

---

## 四、聊天页 — 发送链

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 | Flutter 参照 |
|---|---|---|---|---|---|
| 4.1 | 输入框 | — | 无 | ✅ 有 | `composer_logic.dart` |
| 4.2 | 草稿持久化 | —（localStorage） | 无 | ⬜ 无 | 同左 |
| 4.3 | 发送文本 | `sendText` | rows 追加 userInput；phase→running | ✅ 有 | 同左 |
| 4.4 | 停止 | `stop` | phase→idle | ✅ 有 | 同左 |
| 4.5 | 暂停 / 继续 | `pauseGoal` / `resumeGoal` (CAS) | goal 状态 | ⬜ 无 | 同左 |
| 4.6 | 追问模式（queue/guide） | `setFollowupMode` (CAS) | `config.followupMode` | ⬜ 无 | 同左 |
| 4.7 | 自动消化开关 | `setAutoDrain` (CAS) | `queue.autoDrain` | ⬜ 无 | 同左 |
| 4.8 | 排队条（编辑/上移/立即发送/删除） | `editQueueItem` / `reorderQueueItem` / `sendQueuedNow` / `deleteQueueItem` | `queue.items` | ⬜ 无 | 同左 |
| 4.9 | 排队弹窗（排队/立即发送） | `sendText` + `heldQueueDisposition` | queue / rows | ⬜ 无 | 同左 |
| 4.10 | 回显气泡（重试/切 GLM 重试/慢达/阶段文案） | 重发 `sendText` | rows | ⬜ 无 | 同左 |
| 4.11 | **图片上传（相册多选 / 9 上限）** | `attachmentBeginV4`→`Chunk`→`Commit` | **文件落盘到会话 cwd/uploads/** | ⬜ **无** | `chat_page.dart` |
| 4.12 | **文件上传（单选 / 100MB 拦截）** | 同 4.11 | 同左 | ⬜ **无** | 同左 |
| 4.13 | 上传进度（逐文件逐块百分比） | 分片计数（本地） | 无 | ⬜ 无 | 同左 |
| 4.14 | 上传取消（分片边界） | 停止发片 | 无（或半截文件） | ⬜ 无 | 同左 |
| 4.15 | `+` 插入弹层（图片/文件/技能/斜杠命令） | `skills.list` ✅ / `commands.list` ✅；**斜杠命令旧路径 `prepareWorkspace.slashCommands[]` 已随桌面端升级失效，暂降级为空** | 只读 | ⬜ 无 | `suggestions.dart` |
| 4.16 | 技能 `$` / 命令 `/` 联想 | 同 4.15 | 只读 | ⬜ 无 | 同左 |
| 4.17 | 发送/停止二态按钮 | 4.3 / 4.4 | — | ✅ 有（两按钮分列） | 同左 |

**判定**：只有"发文本 + 停止"可用。**4.11/4.12 是用户点名的例子**——见第六节专项。

---

## 五、聊天页 — 消息行渲染

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 | Flutter 参照 |
|---|---|---|---|---|---|
| 5.1 | 用户气泡 | 帧 `row.userInput` | 只读 | ✅ 有（纯文本） | `rows.dart` |
| 5.2 | 助手块 + **Markdown 渲染** | 帧 `row.assistantText` | 只读 | ⚠️ **纯文本，无 md** | 同左 |
| 5.3 | 代码块 + 复制按钮 | — | 无 | ⬜ 无 | 同左 |
| 5.4 | Markdown 链接外跳 | — | 无 | ⬜ 无 | 同左 |
| 5.5 | Markdown 图片（限高/点击全屏） | `attachmentReadV4` 取图 | 只读 | ⬜ 无 | 同左 |
| 5.6 | 用户消息图片（点击看图/画廊/失败重试） | 同 5.5 | 只读 | ⬜ 无 | 同左 |
| 5.7 | 文件 chip（大小标签） | 同 5.5 | 只读 | ⬜ 无 | 同左 |
| 5.8 | 工具卡（展开输入输出/流态/失败态） | 帧 `row.toolCall` | 只读 | ⚠️ 仅一行 chip | 同左 |
| 5.9 | 子代理卡（展开/打开子会话） | 帧 `row.subagent` | 只读 | ⬜ 无 | 同左 |
| 5.10 | 计划面板（折叠/进度） | `conversationPlansV4` + 快照 `plan` | 只读 | ⬜ 无 | 同左 |
| 5.11 | 错误卡 + 回滚本回合文件 | `conversationFileChangesV4` / `fileRewindPreviewV4` / `applyFileRewind` | **回滚文件系统** | ⬜ 无 | 同左 |
| 5.12 | 思考指示器 / reasoning 行 | 帧 `row.reasoning` | 只读 | ⬜ 无 | 同左 |
| 5.13 | 行入场动画（按 rowId 只播一次） | — | 无 | ⬜ 无 | 同左 |
| 5.14 | 长按菜单 — 复制全文 | — | 无 | ⬜ 无 | 同左 |
| 5.15 | 长按菜单 — 赞 / 踩 | `setAssistantFeedback` (CAS+行级) | 行 feedback 字段 | ⬜ 无 | 同左 |
| 5.16 | 长按菜单 — 重新生成本轮 | `retryTurn` (CAS+行级) | 新增一轮；revision++ | ⬜ 无 | 同左 |
| 5.17 | 长按菜单 — 分叉新会话 | `forkAssistant` (CAS+行级) | **新建会话** | ⬜ 无 | 同左 |
| 5.18 | 长按菜单 — 编辑重发 | `editUserQuery` (CAS+行级) | 行文本变更 + 重跑 | ⬜ 无 | 同左 |
| 5.19 | 文本选择 / 拖拽选择 / 中文菜单 | — | 无 | ⚠️ 浏览器原生 | 同左 |
| 5.20 | 时间戳显示 | 行内 `createdAt` | 只读 | ⬜ 无 | 同左 |
| 5.21 | turnHeader / timelineMarker 行 | 帧 | 只读 | ⚠️ 落到"其他"占位 | 同左 |

**判定**：**渲染层是最大工作量**（Flutter 端 `rows.dart` 2,089 + `chat_page.dart` 里渲染部分约 3,000 行）。
Web 现状只到"能看见字"，Markdown 都没有——**这是体感落差最大的一块**。

---

## 六、专项：图片上传（用户点名的例子）

### ① 现状深度调研

**后台接口已具备**（`docs/API.md` L5）：
```
attachmentBeginV4   → 开始，返回 uploadId / connectionId 关联
attachmentChunkV4   → 384KiB/片，base64
attachmentCommitV4  → 提交，落盘
attachmentReadV4    → 读取（{ref, offset, limit}）
```
**后台数据变化**：文件实际写入**会话 cwd 的 `uploads/` 目录**（无 cwd 时自动建 `uploads-<sid8>` 并回填）；消息以**电脑本地路径**引用该文件，CLI 可直接读。
→ 这是**真改变**（文件系统级），不是 UI 效果。

**移动端现状（Flutter）**：完整实现并迭代 5 轮
- `feat-image-upload-preview` 预览 → `feat-image-gallery-polish` 画廊 → `feat-image-one-by-one` 逐张 → `feat-image-standalone-blocks` 独立块 → `feat-chat-image-memory-cache` 内存缓存
- 能力：相册多选（9 上限）、文件单选（100MB 拦截）、逐文件逐块进度、分片边界取消、失败重试、图片 LRU 64MB 缓存

**Web 端现状**：**零**。`web/src/` 全文只有 `constants.ts:142` 一句注释提到 `uploadId`；
`ATTACHMENT_CHUNK_BYTES` 常量已声明但**无任何调用点**；`M_ATTACHMENT_*` 四个方法名已声明但未实现。

### ② 目标深度调研（应该怎么做）

**参照物一：桌面端 ZCode 本身**（行为真源头）——移动端 Web 端都只是它的远程客户端，附件语义以它为准。

**参照物二：业界成熟做法**
- **Web 端上传的通用最优解是 `FormData` + `fetch`**（浏览器原生流式、自动分块、`upload.onprogress` 给进度）。
  但本项目的上传**不走 HTTP，走 Channel IPC 的 `attachmentChunkV4`**（base64 分片）——这是协议约束，不能换成 FormData。
- 因此 Web 端的进度只能**本地按片计数**（发了几片 / 共几片），不是浏览器原生字节进度。
- 取消：Flutter 用"分片边界轮询取消旗标"。Web 端更简单——**每片前检查 flag，或直接中断 Promise 链**。
- 移动端 Web 的文件选择：`<input type="file" accept="image/*" multiple capture>` 在 iOS/Android 都能唤起相册/相机。

**参照物三：本项目 `docs/UI-SPEC.md`**（柑橘晨光设计系统）——附件条、进度条、失败态的视觉规格。

### ③ 差距与行动项

| 差距 | 行动项 | 优先级 |
|---|---|---|
| 无 `attachmentBegin/Chunk/Commit/Read` 实现 | 在 `web/src/protocol/conversation.ts` 补 4 个方法（对齐 Flutter 语义） | **P0** |
| 无文件选择入口 | `+` 弹层 + `<input type="file">` | P1 |
| 无进度 / 取消 | 本地分片计数 + flag 取消 | P1 |
| 无附件预览条 | 按 UI-SPEC 做 | P2 |
| 无图片渲染（上传了也看不见） | 依赖 5.5/5.6（`attachmentReadV4` + 显示） | **P0（与上传同批）** |

**关键提醒**：**上传和渲染必须同批做**。只做上传、不做渲染，用户传完看不到图 = 功能不成立。

---

## 七、聊天页 — 配置弹层

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 |
|---|---|---|---|---|
| 7.1 | 模型二段弹层 | `getTaskConfigOptions({taskId})` 取 `model` 选项组 → `switchModelConfig` | `config.provider/model/thought` | ⬜ 无 |
| 7.2 | 思考等级 | 同上取 `thought_level` 选项组（GLM: max/high/nothink；Turbo: enabled/off）；**实时词表优先读快照 `config.thoughtLevels`**，缺失才退回缓存 | `config.thought` | ⬜ 无 |
| 7.3 | 模式选择（build/edit/plan/yolo） | 同上取 `mode` 选项组 → `switchCollaborationMode` | `config.mode` | ⬜ 无 |
| 7.4 | 权限模式（4 档） | `setApprovalMode` | `config.approvalMode` | ⬜ 无 |
| 7.5 | 追问模式表 | `setFollowupMode` | `config.followupMode` | ⬜ 无 |
| 7.6 | usage 弹层（窗口条/缓存/构成/累计/压缩） | 快照 `usage` + `compact` | `usage.contextWindow.usedTokens` | ⬜ 无 |
| 7.7 | 任务面板三 Tab（子代理/后台取消/自动化） | 快照 `backgroundWorks[]` + `cancelBackgroundWork` + 自动化接口 | `backgroundWorks[]` 移除 | ⬜ 无 |

**判定**：整域为零。
**7.1 是踩坑重灾区**（三个已修 BUG 都在这）：① provider id **必须以服务端返回为准**，不能信桌面 config.json（BUGFIXES 有实证）；
② 思考词表必须**实时**读（缓存过陈旧会显示错词表，用户看到"某些模型没有思考等级"）；
③ 选项为空时要**区分**「缓存空 / 桥未就绪 / 服务端真无选项」并给重试入口，不能只显示"暂无可用模型"。
→ Web 端实现时**直接继承这三条**，别重新踩。

---

## 八、聊天页 — 询问交互

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 |
|---|---|---|---|---|
| 8.1 | 询问面板（单选/多选/其他自由文本/全答才可提交） | `resolveInteraction` | `pendingInteractions` 清空；回合继续 | ⬜ 无 |

**判定**：**高危缺口**。`pendingInteractions` 非空时服务端在等回答，Web 端不渲染面板 → **会话永久卡住**。
Flutter 端踩过形状坑（BUG-17）：answers 是数组、元素键是**题干原文**（服务端无 id）、选项标识是 `value` 不是 `label`。移植时照抄这个形状，别重新猜。

---

## 九、聊天页 — 滚动

| # | 功能 / 按钮 | 后台接口 | Web 现状 |
|---|---|---|---|
| 9.1 | 流式锚定（微动画/同帧合并/滞回） | — | ⚠️ 极简（只在贴底时滚到底） |
| 9.2 | 新消息跟随（锁存翻历史意图） | — | ⬜ 无（`atBottom` 阈值 80px，无锁存） |
| 9.3 | 上滑翻页（60 条） | `conversationRowsRangeV4` | ⚠️ 方法有，UI 未接 |
| 9.4 | 回底按钮 + 未读徽标 | — | ⬜ 无 |

**判定**：滚动是 Flutter 端**投入最大、踩坑最多**的域（BUG-27/28/32 + `SCROLL-STABILITY-RESEARCH.md` 18KB）。
Web 端**不需要照搬**——Flutter 的补偿方案是为"流式行在列表内增长"这个 Flutter 特有问题设计的。
**Web 端有更简单的正解**：`flex-direction: column-reverse` + 流式区独立元素，或直接用 `overflow-anchor`。
→ 建议：**先按最简方案做，只在真机实测有问题时才引入补偿**。不要预先移植复杂机制。

---

## 十、用量页

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 |
|---|---|---|---|---|
| 10.1 | 时间 chips（今天/3天/7天/30天/全部） | `getAppUsageSnapshot` | 只读 | ⬜ 无 |
| 10.2 | 自定义日期区间 | 同左 | 只读 | ⬜ 无 |
| 10.3 | 模型多选筛选 | 同左 | 只读 | ⬜ 无 |
| 10.4 | 刷新 | 同左 | 只读 | ⬜ 无 |
| 10.5 | 图表（柱状 + 点按下钻） | 同左 | 只读 | ⬜ 无 |
| 10.6 | 累计用量 / 键名中文化 | 同左 | 只读 | ⬜ 无 |

**判定**：整域为零（`usage-stats` 通道在 Web 未声明）。

---

## 十一、自动化页

| # | 功能 / 按钮 | 后台接口 | 后台数据变化 | Web 现状 |
|---|---|---|---|---|
| 11.1 | 列表 | `listAllAutomations` | 只读 | ⬜ 无 |
| 11.2 | 启用/停用 | `setAutomationEnabled` | 启用状态 | ⬜ 无 |
| 11.3 | 立即运行 | `runAutomationNow` | **触发一次会话运行** | ⬜ 无 |
| 11.4 | 重启 | `restartAutomation` | 调度状态重置 | ⬜ 无 |
| 11.5 | 删除（带确认） | `deleteAutomation` | 删除记录 | ⬜ 无 |
| 11.6 | 执行历史展开 | `listAutomationRuns` | 只读 | ⬜ 无 |
| 11.7 | 新建 | `createAutomation` | **新建记录** | ⬜ 无 |

---

## 十二、我的页 / 设置

| # | 功能 / 按钮 | 后台接口 | Web 现状 |
|---|---|---|---|
| 12.1 | 重连 / 断开 | relay | ⬜ 无（store 有 `disconnect`，无 UI） |
| 12.2 | 通知开关（总开关 + 铃声/震动/静音） | 本地 | ⬜ 无 |
| 12.3 | 定时任务入口 | — | ⬜ 无 |
| 12.4 | 版本显示 | — | ⬜ 无 |

---

## 十三、横切能力

| # | 能力 | 后台接口 | Web 现状 | 说明 |
|---|---|---|---|---|
| 13.1 | **通知链**（任务落定 / 审批 / 报错） | 客户端轮询帧 + 本地通知 | ⬜ **零** | 见「迁移方案」硬约束 |
| 13.2 | 错误人话映射（余额不足等） | — | ⚠️ 只有 `String(e)` | Flutter 有 `friendlySendError` |
| 13.3 | 图片缓存（LRU） | — | ⬜ 无 | Web 可用浏览器 HTTP 缓存替代 |
| 13.4 | 草稿持久化 | localStorage | ⬜ 无 | |
| 13.5 | 主题（柑橘晨光） | — | ✅ `styles/theme.css` 有 | 需核对与 UI-SPEC 一致 |
| 13.6 | 中文本地化 | — | ✅ 硬编码中文 | |
| 13.7 | **双端 CAS 集合一致性测试** | — | ⬜ 无 | AUDIT A1：TS/Dart 集合无测试锁 |

---

## 十四、统计与优先级

**功能域完成度**（按交互点计）

| 功能域 | 交互点 | Web 已实现 | 完成度 |
|---|---|---|---|
| 连接与配对 | 11 | 8 | 73% |
| 会话列表 | 18 | 0.5 | 3% |
| 聊天骨架 | 9 | 4 | 44% |
| 发送链 | 17 | 3 | 18% |
| 消息行渲染 | 21 | 2 | 10% |
| 配置弹层 | 7 | 0 | 0% |
| 询问交互 | 1 | 0 | 0% |
| 滚动 | 4 | 1 | 25% |
| 用量页 | 6 | 0 | 0% |
| 自动化页 | 7 | 0 | 0% |
| 我的页 | 4 | 0 | 0% |
| 横切 | 7 | 1.5 | 21% |
| **合计** | **112** | **20** | **≈18%** |

**建议实施顺序**（按「阻塞程度 × 用户可感知」）

| 批次 | 内容 | 理由 |
|---|---|---|
| **B0 · 地基** | 3.5 断档检测、1.9 视图状态上报、13.7 CAS 一致性测试 | 缺了会静默出错，且成本低 |
| **B1 · 能用** | 二（会话列表）、三（骨架）、八（询问面板） | 没列表 + 卡住会话 = 不能用 |
| **B2 · 好聊** | 五（渲染，含 Markdown/代码块/工具卡）、四（发送链） | 体感落差最大 |
| **B3 · 上传** | 六（图片/文件上传 + 渲染） | 用户点名 |
| **B4 · 控制** | 七（模型/模式/权限）、5.14~5.18（长按菜单） | 日常高频 |
| **B5 · 其余页** | 十、十一、十二 | 独立域 |
| **B6 · 通知** | 13.1 | 受 HTTPS 约束，见迁移方案 |

---
_本文由 Z 维护。改了就告诉用户。_
