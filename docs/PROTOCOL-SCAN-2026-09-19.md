# 协议扫描差集：ZCode 桌面端 3.12.3.7463（2026-09-19）

> **来源与效力档**：全部结论来自**静态读码** —— 解包 `D:\Users\chengge\AppData\Local\Programs\ZCode\resources\app.asar`
> （用 asar 索引取 `out/main/index.js`、`out/main/chunk-6XM33EZR.js`、`out/host/chunk-3CQYXRMM.js`、
> `out/host/chunk-ZH56ETHO.js`、`out/scheduler/index.js`），外加本机 `~/.zcode/v2/logs/` 与 `setting.json` 实测。
> **没有任何一条是活体打 relay 打出来的**。与 `docs/API.md` / `docs/协议接口参考.md` 重复的内容一律不抄，
> 本文只记**差集**（本项目文档里 0 命中的项）与**冲突点**。
> 标记约定：`[实测]`=读到的代码原文；`[推断]`=我的判断，别当事实；`[冲突]`=与本项目既有文档不一致，需裁定。

## 1. 桌面侧入向路由的权威 switch [实测]

`out/main/index.js` → `routePayload(f, w)`（按 `w.zcode_type` 分派）。**手机能发给桌面的就这 9 类**，
其余走 `default: break` 静默丢弃：

```
bootstrap-request → 回 bootstrap-response
workspace-list-request → 回 workspace-list-response
platform-request → G(f,w)            ← 本项目文档未记
mobile-view-state-update → Ln(viewState, deviceInfo)
workspace-bridge-open
workspace-reconnect-request
rpc-frame / rpc-frame-ack
mobile-diagnostic → Pa(f,w) 写桌面日志   ← 本项目文档未记
```

### 1.1 `platform-request`：本项目文档完全没有的一条通道 [实测]

schema：`{zcode_type:"platform-request", requestId, method: <7 枚举>, args: unknown()}`；
`platform-response` 为 `{requestId, method, success:true, result:unknown}` 或 `{success:false, error:string}`。

处理函数（`out/main/index.js`，命名 `respondToPlatformRequest`）原文：

```js
async function G(f,w){ let I;
  try { let O = await e.platformHandlers[w.method](w.args);
        I = {zcode_type:"platform-response", requestId:w.requestId, method:w.method, success:true, result:O} }
  catch(O){ ... I = {..., success:false, error:String(O.message)} }
  ke(f,I) }
```

**读码结论**：路由处**没有**任何来源/角色/确认校验，`args` 原样透传给服务实现。方法枚举与主进程注册表
实测同为 7 条：

| method | 注册表实现符号 | 语义 |
|---|---|---|
| `isDockerAvailable` | `isDockerDaemonAvailable` | 读 |
| `listWSLDistros` | `listAvailableWSLDistros` | 读 |
| `listDockerContainers` | `listAvailableDockerContainers` | 读 |
| `listSSHConfigAliases` | `listSSHConfigAliases` | **读 `~/.ssh/config` 的别名列表** |
| `loadMcpFromUserDirectory` | — | 读用户级 MCP 配置 |
| `saveMcpToUserDirectory` | `MQe` | **写用户级 MCP 配置**：`action:"upsert"` 则 `config[name]=cfg`，否则 `delete config[name]`，随后落盘 |
| `migrateLegacyCommonMcp` | — | 迁移旧 MCP 配置 |

`[推断]` 危害定级：MCP server 配置是"能拉起任意本地命令"的入口，所以 `saveMcpToUserDirectory` 一旦可达
= 持久化代码执行，而不只是读信息。`[实测]` 但**端到端未验证**：没跑过真实 `platform-request`，
`[未定位]` 也没排除服务实现更上层还有 gate。

**对客户端的价值**：这 7 条是可白拿的设备信息面板（WSL / Docker / SSH 别名 / MCP 配置读写）。
本项目 `web/` 若要接，注意 `listSSHConfigAliases` 会暴露 `~/.ssh/config` 内容摘要。

### 1.2 `mobile-diagnostic`：桌面会把你上报的东西写进它的日志 [实测]

字段全集：`event, state, previousState, pairStatus, closeCode, closeReason, wasClean, wasPaired,
failureReason, failureMessage, visibilityState, online, hiddenDurationMs, timestamp`。
即"页面可见性 + 在线状态 + 关闭码"三样会被桌面记盘。做重连诊断时这是免费的对账数据源
（桌面侧 `~/.zcode/v2/logs/<日期>.log` 能看到自己上报了什么）。

## 2. 命令表：全集 31 条，CAS 子集 15 条 [实测]

`out/host/chunk-3CQYXRMM.js`：`fn = {命令名 → payload schema}`，且 **`Cn = enum(Object.keys(fn))`**
⇒ 命令词表就是 `fn` 的 31 个键。另有 `pc = new Set([15 条])`（导出别名 `pa`），**它是 CAS 子集，不是"远程可用子集"**：

```js
function Yc(e){ if(dte.has(e.type) && e.baseRevision===void 0)
    throw new Error(`command ${e.type} 是 CAS 命令，必须携带 baseRevision（10-protocol-spec §6.4）`);
  if(ute.has(e.type) && !e.baseLogEpoch) throw new Error(`command ${e.type} 是 row target 命令，必须…`); }
```

⇒ `[实测]` 桌面/宿主侧**自己强制** CAS：15 条少 `baseRevision` 直接抛，row-target 那批少 `baseLogEpoch` 直接抛。
⇒ `[推断]` 这条与本项目"信封里 `baseRevision?` 可选"的写法要对齐：**可选是 schema 层的可选，分派层是强制的**。
⇒ `[附带发现]` 存在一份 `10-protocol-spec` 文档（错误文案引用其 §6.4），但**未随包发布**
（asar 内非 node_modules 的 `.md`/`.json` 文档计数 = 0），所以拿不到原文。

**CAS 的 15 条**：`applyFileRewind, forkAssistant, editUserQuery, retryTurn, setAssistantFeedback,
sendQueuedNow, editQueueItem, reorderQueueItem, deleteQueueItem, setAutoDrain, switchModelConfig,
switchCollaborationMode, setFollowupMode, pauseGoal, resumeGoal`

**本项目文档 0 命中、值得评估接入的 6 条**（载荷为实测 schema）：

| 命令 | payload | 用途 |
|---|---|---|
| `respondWorkspaceHookReview` | `{...bridgeSessionId 类字段, decision}` | 回应 workspace hook 审查 |
| `toggleWorkspaceHookReviewItem` | `{reviewItemId, enabled}` | 逐条启停 hook |
| `revokeWorkspaceHookTrust` | `{reviewItemIds: string[] (min 1)}` 或 单对象 | **撤销 hook 信任** |
| `requestWorkspaceHookReview` | （schema 见 `Jt`） | 主动发起审查 |
| `snoozeInteractionAutoResolution` | `{interactionId}` | **推迟交互的自动决议**（和 `resolveInteraction` 配对，审批体验的最后一块） |
| `discardSharedContext` | `{contextId}` strict | 丢弃共享上下文 |

## 3. 与本项目文档的冲突点（需要裁定，我没有改任何一份旧文档）

1. `[冲突]` **`setApprovalMode` 不在 3.12.3 的 `fn` 表里**，但 `docs/API.md`、`docs/协议接口参考.md`、
   `docs/INTERFACE-MATRIX.md` 都记了它（且标了实测）。两种解释：它属于另一层（快照 `config.approvalMode`
   可见，改法可能已迁到 `platform`/`setting` 通道），或它是 **3.6.5 时代存在、3.12.3 移除**。
   我倾向前者，但**没证据**。这条会直接影响你们"审批模式能不能切"，建议排一次实测。
2. `[差异，非冲突]` `docs/API.md` 写 rowsRange `limit:60`，协议上限实测是 **`rowsRangeMaxLimit = 200`**；
   每片 ≤512KiB 是客户端选择，协议侧上限是 `maxMessageBytes = 16*1024*1024`、`maxFragments = 64`、
   `assemblyTimeoutMs = 30000`。
3. `[补全]` L2 表缺 `platform-request` / `mobile-diagnostic` 两行（见 §1）。
4. `[补全]` relay 错误码本项目记了 `KICKED`；全集实测为 9 个：`AUTH_FAILED, KICKED, INTERNAL, WRONG_PARAM,
   DESKTOP_HOST_MISSING, REMOTE_SESSION_MISSING, REMOTE_SESSION_WINDOW_MISMATCH,
   REMOTE_WORKSPACE_IDENTITY_MISMATCH, REMOTE_WORKSPACE_IDENTITY_MISSING`。
   桌面侧移动错误枚举（`Ep`）11 个：`session-not-found, session-expired, session-conflict, workspace-closed,
   desktop-disconnected, invalid-mobile-connection, desktop-bootstrap-timeout, connection-recovery-timeout,
   relay-unavailable, unsupported-action, unexpected-error`。
   `[实测]` 映射关系：`transportState==="kicked"` → 向渲染层报 `session-conflict`
   （文案 "Web remote control connection was kicked by relay."）。
5. `[补全]` **存在按方法级的来源闸门**（本项目文档未记）：`cuaPermissionObservation` 仅接受
   `!remoteSessionId && !(workspaceIdentity && …)` 的会话 ⇒ 远程会话被显式排除。
   `[推断]` 所以"远程 == 本地同等权限"不成立，且**必须逐 handler 判断**，别按通道整体推定。

## 4. 两套方法名的关系（我没打通，标为待办）[实测]

本项目 `API.md` 用的是 **channel 方法名**（`sendConversationCommandV4` / `subscribeConversationV4` …）；
`out/host/chunk-3CQYXRMM.js` 里另有一套 **`v4/<域>/<名>` 字符串注册表**（23 条请求面 + 3 条推流）：

```
v4/connection/flow · v4/controller/{subscribe,resync,unsubscribe} · v4/conversation/{subscribe,resync,
unsubscribe,rowsRange,plans,fileChanges,fileRewindPreview,usage,attachmentRead,attachmentStat} ·
v4/attachment/{begin,chunk,commit,abort=read,previewSource} · v4/usage/stats · v4/commands/query · v4/command
推流：v4/conversation/frame · v4/telemetry/event · v4/cua/permission-observation
```

`[实测]` 两套同名域并存于同一版本包内；`[未打通]` 我没确认它们是一层之内的两种寻址（v4 名 = 服务描述符）
还是两条独立入口。**在没验之前别按"新接口"去改 `web/src/protocol/`** —— 本项目现在跑通的是 channel 那条。

## 5. 链接参数与凭据（供配对页与安全判断复核）[实测]

配对 URL 由 `buildWebRemoteControlExternalQrUrl({baseUrl, deviceSid, passHash, timestamp, deviceMid,
deviceName, appVersion, theme})` 生成，参数集合就是本项目配对页在吃的那几个；两点新事实：

- `[实测]` `hash` **不是随机 token**，是 `passHash = sha256(password).digest("base64")`，
  而 `password = randomBytes(24)` 的 base64url（192 bit）。它同时**就是 HMAC 的 key**
  （`proof = HMAC_SHA256(key=passHash, "<nonce>|<role>|<sid>")`）⇒ 拿到 URL == 拿到密钥，
  与 `AGENTS.md`「绝对别做：别把配对凭据当普通数据」一致，此处补齐密码学依据。
  `[实测]` 但 `docs/API.md` 里 `role:"terminal"` 是对的（设备侧写的是 `"device"`，两端同 key）。
- `[实测]` **`theme` 形参没被写进 URL**（函数体内无对应 `set`）。桌面传的界面主题不会进链接。
- `[实测]` sid 落盘 `~/.zcode/v2/setting.json → webRemoteControlExternalRelayDevice.deviceSid`；
  passHash 落盘 `~/.zcode/v2/credentials.json → web-remote-control:external-relay:pass_hash`
  （值为 106 字符、`enc` 前缀的封装形态，**与 URL 里那串字节级不同**，不是"每次重新生成"）。
- `[实测]` **撤销语义**：storage provider 有 `load/save/clear/rotate`，但 re-register 分支写的是
  `activeAuth={mode:"register", passHash: 旧值}` ⇒ **换 sid 不换 passHash**。
  `[推断]` 结论：泄露后必须走 `rotate`（或关掉再开 Web 遥控），只在设备列表里看到 sid 变了不等于堵住了。
  判定 sid 是否换过的方法：全量日志里 `state":"registering"` 的出现日期（本机仅 2026-09-12 出现过）。

## 6. 本轮明确没做 / 待验

- 无活体：`platform-request` 端到端可达性、`setApprovalMode` 归属、v4 名与 channel 名的关系，都需要探针。
  只读探针可仿 `test/manual_server_list_audit_test.dart`（链接门控）。
- 未展开的 5 条命令载荷字段：`createSelectionSideSession`、`cancelBackgroundWork`、`requestWorkspaceHookReview`、
  `respondWorkspaceHookReview` 的 `decision` 细节、`sendText` 的部分子对象。
- `platformHandlers` 里 4 个列表方法的**返回值形状**未展开（对做面板必需）。
- `v4/telemetry/event` 载荷字段未展开。
- `credentials.json` 的 `enc` 封装算法未查。
- 桌面 relay 连接本机今天 86 次重连（`paired` 92 / `waiting_terminal` 91 / `connecting` 86），
  根因未查 —— 若本项目遇到"莫名掉线重连"，这是同一条链路的现成线索。
