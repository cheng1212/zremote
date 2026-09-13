# zremote Bug 修复台账

> 写手侧维护：每修一个 bug 记一条（现象/根因/修复/提交/验证状态）。
> 只追加新条目、旧条目状态更新就地改「验证状态」字段；教训类内容同步 `docs/LESSONS.md`。
> 坐标：协作背景看 `COLLAB.md`，协议背景看 `docs/协议接口参考.md`。

---

## 2026-09-11 批次（写手/审核者协作，全部合并 master）

### BUG-01 流式输出时往上滑看历史，视口被往下拽
- 现象：回复很长时往上滑，流式推流持续把消息列表往下拉，手离开屏幕照样拽。
- 根因：reverse 列表中视口下方内容（流式长高的最新行）每长高 Δ，视口就向最新端漂移 Δ，与自动滚底 animateTo 无关，旧护栏只挡了手势期。
- 修复：滚离底部后按「内容总高增量（maxScrollExtent+viewportDimension）」反向 jumpTo 抵消锚定；拖动中攒欠账停稳一次补。lib/ui/chat_page.dart `_anchorAgainstGrowth`。
- 提交：`1aed45d`（merge 5dd7512）。验证：测试全过；**真机手感待用户验收**（按住列表时应钉死）。

### BUG-02 代码块看不全 + 吞掉聊天滑动手势
- 现象：长代码关在 360px 高的小窗里内部滚动看不全；手指落在代码块上滑聊天记录滑不动。
- 根因：`_CodeBlock` 正文套 maxHeight:360 + 垂直/横向双层 SingleChildScrollView，拦截手势且截断视野。
- 修复：删高度封顶和双层内滚，SelectableText 软换行完整铺开；截断保险丝 2 万→10 万字符防 MB 级载荷卡列表。lib/ui/rows.dart、lib/ui/composer_logic.dart。
- 提交：`a38cf2f`（merge a86e67e）。验证：测试全过；**超大代码块滚动流畅度待真机观察**。

### BUG-03 切换模型卡顿
- 现象：模型面板点选后 UI 等一个服务端往返才生效，网络慢时像卡死。
- 根因：`_applyModel` 先 await switchModel RPC 再 _patchConfig。
- 修复：乐观更新——先 patch 本地高亮再后台发 RPC，失败回滚原值+提示。lib/ui/chat_page.dart。
- 提交：`e84e7cf`（merge 0903b42）。验证：测试全过；**真机秒切待验收**。

### BUG-04 切过的模型重启后回退英伟达（多设备互踩 ping-pong）
- 现象：会话里切到 GLM 后重启 App 变回英伟达默认；手机切的模型平板不认。
- 根因：`_reconcileSessionModel` 把「本机记录≠服务端」一律判为"服务端回退"并无条件补发本地记录——服务端的真实模型（他端新选择）被打回，多设备互相覆盖。
- 修复：对账以服务端为准——服务端值为空/千问基线/历史默认（nv 系）才判真回退按本地补发；其余采纳为新意图并回写本地记录。`serverIsFallback` 判定复用 model_defaults 常量。
- 提交：`e84e7cf`（与 BUG-03 同 commit）。验证：测试全过；**真机「切完重启保持」待验收**。
- 已知边界：两台移动端都显式切过同一会话时以服务端最后一次为准；同一会话别两台同时开着切。

### BUG-05 默认模型不是想要的 GLM
- 现象：用户要求新会话默认 GLM 5.3 Flash（此前默认英伟达 nv-nemotron-ultra）。
- 根因：`model_defaults.dart` 首选默认常量还是英伟达（2026-09-05 设置）。
- 修复：provider→`builtin:bigmodel-start-plan`，model→`GLM-5.3-Flash`（id 经桌面 config.json+日志双重核实），thought=high；`nv-nemotron-ultra` 入 legacyPreferredModelIds——守恒器自动写入的旧默认记录随默认迁移，显式手选（chosen）不动。lib/state/model_defaults.dart、test/model_defaults_test.dart。
- 提交：`d09a777`（merge 8c79938）。验证：测试全过；**新会话默认待真机验收**。

### BUG-06 删除会话在别的设备复活
- 现象：手机上删除会话成功（本地墓碑隐藏），平板刷新列表又出现。
- 根因：`deleteTask`（task 通道）只摘任务列表条目，会话本体没删；sessions-index 流照常携带它，客户端把「index 有、listTasks 无」的会话重建卡片——无墓碑设备复活。
- 修复：删除时补调 zcode-agent 通道 `deleteSession`（协议参考文档证实存在），双通道都删。lib/protocol/conversation.dart、lib/state/app_controller.dart。
- 提交：`1766677`（docs 归档）+ `cba77df`（fix），merge d4268eb。验证：测试全过；**手机删→平板刷新不再复活，待真机验收**。
- 教训已入 docs/LESSONS.md（双通道删除入口只调一个≠删干净；本机墓碑会掩盖服务端语义缺陷）。

---

## 2026-09-11 白天新报（旧包事故，修复已合并待真机验证）

### BUG-07 夜间所有会话被刷成欠费千问 3.8 Flash，消息全部发不出去且切不动
- 现象（用户报告）：旧版 APK 过夜后所有任务报错；服务端会话模型全部变千问 3.8 Flash（欠费，消息必死）；移动端怎么切都切不动服务端模型。
- 根因（已确证，桌面日志+探针实测）：桌面端 registryFallback 机制——provider 健康列表
  变化后会话模型若不在列表，自动切 `listModels()[0]`（= qwen3.8-flash，欠费）；旧包守卫
  5 次上限失活后无纠正能力，移动端切换（旧包）无法对抗。
- 修复现状：BUG-03/04/05 的合并修复针对此链（守恒器无上限纠正+对账以服务端为准+默认改 GLM）。
  **2026-09-11 下午追加护栏（commit `ad9b8cd`）**：①基线集合补 `qwen3.8-flash`（此前只防
  qwen3-max，夜间回退值漏防——桌面库取证 5 会话中招）；②`reconcileTaskModels` 列表级批量
  对账：loadTasks 后即纠正被刷回基线的会话（本机意图记录优先，无记录用首选默认），消灭
  无人值守窗口；③发送失败卡片新增「切 GLM 重试」一键退路（记 chosen）。
  **2026-09-11 傍晚探针确证（594ecab）**：真实环境验证普通 switchModelConfig（正确
  provider id）accepted 且 63s 不被刷回——移动端切换链路本身通畅；夜间回退确证为
  registryFallback。**待办：新包真机复验。**
- 状态：**修复已交付（ad9b8cd + 594ecab），待真机验证**。

### BUG-08 默认 GLM 的 provider id 写错（start-plan 不在注册表）【写手引入，已修正】
- 现象：任务 #4 把默认 provider 写成 `builtin:bigmodel-start-plan`；探针实测
  switchModelConfig 返回 `provider.notInRegistry`——新包上"套默认 GLM/守恒器纠正"会全部静默失败。
- 根因：从桌面 config.json 抄 provider id，未与**服务端模型注册表**（prepareWorkspace
  configOptions 实测）核对——注册表里 GLM 是 `builtin:bigmodel-coding-plan`。
- 修复（594ecab）：常量改 `builtin:bigmodel-coding-plan`；坏 provider 的自动记录（即便
  chosen:true，那是系统按坏常量写的）视同未选择迁移到正确默认。附三个探针入库
  （ws_default_model / switch_runtime / setmodel）。
- 验证：探针实测 coding-plan 切换 accepted 且 63s 不被刷回；114 测试全过。
- 教训：provider id 必须以 prepareWorkspace 返回为准，不能信本地配置文件
  （config.json 里的 provider ≠ 注册表里的 provider）。

---

## 2026-09-11 接手批次（单智能体模式，ZCode 写手会话之后）

### BUG-09 切换项目必报「ZCode Agent runtime is not running.」
- 现象（用户报告 + 截图）：项目切换弹层点另一个项目，弹红条
  「切换失败：ChannelRpcError: ZCode Agent runtime is not running.」。
  **不是每次都报**——用户原话"有时候会报错"。
- 根因（客户端侧，已确证）：`IndexSubscription` 把 **sessions-index 订阅**也写死成
  `runtimePolicy: 'existing-only'`（lib/protocol/conversation.dart）。该策略语义是
  "只准挂到已经在跑的运行时上，不许启动"——目标项目的 agent 运行时当时没在跑，
  桌面端就 1ms 内直接拒绝。桌面端 app.asar 源码坐实：
  `getReadOnlyClient(m, M="start-if-needed")` 的 `existing-only` 分支只取
  `getExistingClient`，取不到即 `throw createRuntimeUnavailableError`；**不传该字段**
  则走 `(await Zr(m)).client`，**按需把运行时拉起来**。`subscribeSessionsIndexV4`
  把 `m.runtimePolicy` 原样透传，且该字段是**可选**的。
- 证据（桌面日志，只读取证）：
  - 2026-09-11 16:45 三步与 `openWorkspace` 代码顺序严丝合缝：
    `unsubscribeSessionsIndexV4 OK`(03.964，旧项目退订)
    → `[web-remote-control] mobile-view-state-update`(04.688，新桥 sendViewState)
    → `subscribeSessionsIndexV4 FAIL (0.4ms)`(05.687)。
  - 全天 163 次订阅 **143 OK / 20 FAIL（~12%）**，失败时刻 01:10 / 01:17 / 01:41 /
    13:02 / 13:26 / 15:37 / 16:07 / 16:45——全部落在"目标项目运行时不在跑"的时刻。
  - 旁证：`ConvSubscription`（进聊天页的订阅）**没传** runtimePolicy，所以进聊天页
    从不撞此错——问题精确锁定在项目切换这一步。`_start()` 注释写着 "The desktop may
    need to warm the session runtime first" 却同时传了禁止预热的 `existing-only`，
    自相矛盾，判断为疏忽而非设计。引入者不可考（旧仓库 .git 损坏，只剩 baseline 快照）。
- 修复（`ea86bb9`）：
  ① `IndexSubscription._subscribeArgs` 不再传 `runtimePolicy`（用桌面默认
     `start-if-needed`），冷项目切过去时由桌面按需拉起运行时；
     `_unsubscribeArgs` / `_resyncArgs` **保持 `existing-only` 不变**——清理与断线恢复
     路径不该顺手启动运行时。
  ② 顺带修同一函数里的第二个缺陷：**切换失败后状态不一致**。原来 `workspace` /
     `_lastWorkspaceKey` 在切换前就被改成目标项目、旧桥栈已销毁，但 `tasks` 还是旧项目的
     会话——界面变成"标题是失败的目标项目、列表却是上一个项目的数据"，且重启后还会
     自动跳回这个打不开的项目。现改为：桥栈立起来之后才认工作区；失败则回滚
     `workspace` / `_lastWorkspaceKey`，并**静默把旧工作区的桥重新挂上**（失败只记日志）。
  ③ 切换失败提示人话化：新增 `friendlySwitchError`（lib/ui/composer_logic.dart），
     不再把 `ChannelRpcError: ...` 原文糊给用户。
- 验证：`flutter analyze` 0 问题；`flutter test` **118 全过**（新增 4 个
  `friendlySwitchError` 用例，其中一条就是本次事故原文的回归护栏）。
- 待办：**真机验证**——①切到桌面端没启动过的项目应能正常打开（桌面端会拉起运行时）；
  ②切换失败时界面应留在原项目，而不是"标题新项目 + 旧列表"。
- 教训已入 docs/LESSONS.md。

### BUG-10 切项目/跨项目开会话时「正在打开工作区桥…」白屏几十秒
- 现象：在「全部对话」里点属于别的项目的会话（或直接切项目）时，界面停在
  「正在打开工作区桥…」，链路不好时能卡几十秒。用户报"会话加载有时候有点卡"。
- 定位线索：截图里标题已经是「全部对话」却还在转"打开工作区桥"——说明
  `viewingAllProjects==true` 与 `openingWorkspace==true` 同时成立。只有
  「全部对话 → 点别的项目的会话 → `ensureTaskProject` → `openWorkspace`」这一条路径会这样
  （`showAllProjects()` 不置 `openingWorkspace`；`openWorkspace` 成功后才清 `viewingAllProjects`）。
- 根因：**拆旧桥栈是"串行等超时"**。`_disposeBridgeStack` 里 `await chat?.dispose()` 与
  `await indexSub?.dispose()` 各自会 `await` 一次退订往返，而 `ChannelClient.call` 的
  **默认超时是 30s**（lib/protocol/channel_client.dart），这两处都没覆盖；真正做
  fail-fast 的 `Bridge.dispose()`（→ `channels.dispose()`）却排在**最后**。
  中继链路僵死时（心跳 ack 超时前那段窗口）就是 30s + 30s 串行干等，之后才轮到开新桥。
  整段期间 UI 被 `openingWorkspace` 全屏遮挡（lib/ui/tasks_page.dart），用户只能看转圈。
- 证据（桌面日志 2026-09-11，只读取证）：
  - `subscribeSessionsIndexV4` **1.9 / 3.1 ms**、`listTasks` 2~5ms、`listPinnedTasks` 0.3ms
    → **订阅与列表从来不是瓶颈**，瓶颈在拆栈等待。
  - 中继抖动：`heartbeat ack timeout` **3 次**（`staleMs: 30005`）、`state:"connecting"` **60 次**，
    17:25:26 / 17:26:25 / 17:26:57 连续三次重连——用户截图时刻 17:26 正夹在中间。
  - 同批实测（另有开销，非本次修复范围）：`subscribeConversationV4` 4069ms、
    `prepareWorkspace` 1750~2715ms、`getTaskTokenUsage` 1560~2569ms。
- 修复（本次提交）：
  ① 新增 `ipcUnsubscribeTimeout = 1500ms`（lib/protocol/constants.dart）：退订是尽力而为的
     收尾动作，发出去即可，不该为它等满默认 30s。
  ② `_SubBase.dispose()` 与 `_SubBase._resubscribe()` 的退订都传该短超时
     （lib/protocol/conversation.dart）——后者顺带加快中继重连后的恢复。
  ③ `ChannelClient` 增加 `_disposed` 标志：桥拆掉之后**新发起**的调用立刻抛
     `StateError('channel disposed')`，不再各自等满一次完整超时（原实现只 fail 在途的）。
  ④ `_disposeBridgeStack` 重写（lib/state/app_controller.dart）：两个互不相干的订阅
     **并行**退订；收尾异常一律吞掉（新增 `_bestEffort` 包装），拆栈不再抛——
     拆到一半抛出去会让 `workspace` / `bridge` 停在半截状态。
  → 链路僵死时拆栈耗时从**最坏 60s 降到 ≤1.5s**。
- 验证：`flutter analyze` 0 问题；`flutter test` **124 全过**（17 个 `manual_*` 探针无凭据自动 skip）。
- 残留（未修，下一步候选）：`openBridge` 仍是 30s 超时，链路僵死时那一步仍可能等满 30s。
  不能简单地在掉线时 fail 在途请求——relay 的 `_outbound` 队列让请求能在重连后补发，
  直接 fail 会退化掉"短暂抖动后自动完成"的能力，需要单独设计。
- 另发现（未修）：当天 68 条 `mobile-view-state-update` 被桌面以 "invalid external relay
  payload dropped" 丢弃（占挂桥 141 次的一半）；桌面端 zod schema 已挖出且与客户端出参
  形状兼容，差异待探针实测收口。

### BUG-11 打开会话"有的快有的慢"——用户操作被自家后台补拉挤在同一个队里
- 现象：用户报"有些会话很快，还有些有点慢"。量化后是**双峰**：全天 1322 次
  `subscribeConversationV4`，中位 **4ms**、92% 在 200ms 内，但有 73 次落在 1s~**22.6s**。
  即慢的不是"某些会话"，是**某些时刻**。
- 根因：桌面端 channel RPC 走同一个队，慢的那些是**排队受害者**而非自身慢。
  证据：全天 **57 次"排空暴发"**——≥3 个互不相关的调用耗时**完全相同**且在同一瞬间返回。
  典型样本（03:37:22.194，6 个调用同时返回，全部恰好 5.1s）：
  `getTaskTokenUsage` ×4 + `subscribeConversationV4` ×2。紧接着同一批操作变成
  6.1ms / 5.5ms / 3.1ms。而 `getTaskTokenUsage` 正是**我们自己**的后台补拉
  （`_fetchTaskTokens`，全天 1005 次，中位 4ms 但 66 次 >1s、最长 11.5s）——
  用户点开会话时，可能正排在我们自己的补拉后面。
- 修复（本提交，lib/state/app_controller.dart）：加前台/后台优先级闸门。
  ① `_foregroundOps` 计数 + `_asForeground()` 包装；`openWorkspace`（切项目）与
     `openSession`（开会话）整段算前台。
  ② `_backgroundGate(key)`：前台忙时后台任务**不发**并记账；`_runDeferredBackground()`
     在前台计数归零时补跑被挡下的那些。
  ③ 接入 5 个后台/预取入口：`_fetchTaskTokens`(tokens)、`reconcileTaskModels`(models)、
     `loadPrep`(prep)、`loadSkills`(skills)、`loadArchivedTasks`(archived)。
  ④ `_fetchTaskTokens` 与 `reconcileTaskModels` 是分批/串行长循环，额外在**循环内**查闸门，
     用户一动手就停掉后续批次，不再把整批发完。
  - 只控制"什么时候发"，不改服务端行为、不取消已发出的请求；补跑最多晚一次前台操作的时长。
- 验证：`flutter analyze` 0 问题；`flutter test` **124 全过**（17 个 `manual_*` 探针 skip）。
- **诚实边界**：桌面端那个共享阻塞点我们改不了，所以这次**不承诺"秒开"**；
  它只保证用户的操作不再被自家后台流量挤队。
- 未修（下一步候选）：桌面端 `onAgentRuntimeRestarted` 一天 **34 次**，是最像的阻塞源，
  但相关性弱（57 次暴发里只有 **2** 次落在重启 ±2s 内、13 次在 ±15s 内），
  真正的共享阻塞点仍未定位。

### BUG-12 「重新连接 / 断开连接」把用户甩回配对页——改成就地操作
- 现象：汉堡菜单点「重新连接」或「断开连接」，界面会跳到连接页；重连要等
  （中继连接 + 配对最多 45s + bootstrap）完才跳回来，观感是被甩出去。
- 根因：`lib/main.dart` 把**整个 App 的根 widget** 由连接状态推导——
  `home: _app.workspace != null || _app.workspaces.isNotEmpty ? HomeShell : PairPage`。
  ① `reconnect()` → `connect()` 第一件事 `await disconnect(silent: true)` 清掉
  `workspaces` / `workspace`，到 `bootstrap()` 填回之前有两次 `notifyListeners()`，
  整段重连都停在 `PairPage`；② `disconnect()` 清空状态后根 widget 变 `PairPage`（按老设计）。
- 修复（本提交）：
  - `ZApp` 新增 `_inPlaceReconnect` / `_pairPageRequested` / `_disconnectedKeptShell`，
    并收敛出两个判定：`showMainShell`（根 widget 用）与 `isReadOnlySnapshot`（UI 用）。
  - `disconnect({keepShell})`：只拆连接、保留工作区与列表内容；`connect({keepShell})` 透传。
  - `reconnect()`：置 `_inPlaceReconnect` + `keepShell: true`，全程留在会话页；
    **失败时**显式置 `_disconnectedKeptShell = true`（否则 `session` 对象还在，
    光判 `session == null` 会露出"看着能点其实点不开"的假活态）。
  - `openPairPage()` + 抽屉新增「去连接 / 换链接」——**断开后不再自动跳配对页，
    必须留这个入口，否则用户换不了链接**（配对页此前只能靠"状态为空"出现）。
  - `tasks_page` 新增就地提示条（重连中 / 已断开）；只读快照期卡片点击改为
    `flashMessage('已断开，先在抽屉里重新连接')`，FAB 隐藏。
  - `profile_page` 的断开同步改成 `keepShell: true`，去掉 `popUntil`。
  - 防御：`_openWorkspace` 加 `|| session == null`，防止残留点击命中 `session!`。
- 验证：`flutter analyze` 0 问题；`flutter test` **124 全过**（17 探针 skip）。
- 踩坑：**判"已断开"不能用 `session == null`**。最初这么写直接挂掉了
  `widget_test.dart` 的回归锁「tapping a task card opens the chat page route」——
  该测试用裸 `ZApp()`，本来就没 session，但期望卡片能点开。
  改用 `_disconnectedKeptShell || _inPlaceReconnect`（语义：确实是我们断开的 / 正在重连）才对。

### BUG-13 定时任务页 / 会话页的小按钮按不准（触控热区偏小）
- 现象（用户原话）：「优化下定时任务和追加消息的UI 上面的按钮太小 不方便按」。
- 实测热区（改前）：
  | 位置 | 热区 |
  |---|---|
  | 定时任务 AppBar 刷新 `IconButton` | 40×40（Material 默认） |
  | 定时任务卡内「立即运行 / 删除 / 执行历史」`_action()` | **高约 20**（纯文字，无底无边） |
  | 定时任务卡内 `Switch` | `shrinkWrap` 压到开关本体 |
  | 执行历史行「查看会话」 | ≈ 文字高（10.5px） |
  | 会话页排队条「⚡立即发送 / 🗑删除」 | 40（`VisualDensity.compact`） |
  | 会话页输入框左侧「图片 / 附件」 | ≈34~36（padding 5 + icon 24/26） |
  | 会话页发送/停止圆键 | 46×46 |
  | 会话页排队条「追问·xx」入口 | ≈ 文字高（GestureDetector 包 10.5px 文字） |
- 根因：各处热区各自为政——Material 默认 40、`compact` 再压到 40、
  `shrinkWrap` 去掉触摸内边距、自绘按钮只给文字留 padding。**没有统一的最小触控目标**。
  这不是"看起来小"，是**真的按不准**（手指没有 1px 精度）。
- 修复：
  - `lib/theme.dart`：新增 `ZT.tapMin = 48`（Material/Android 无障碍建议值），
    并在 `ZT.theme()` 加 `iconButtonTheme`（`minimumSize: 48×48`、`padding: 12`、
    `tapTargetSize: padded`）——**一处改完全 App 的 IconButton**。
  - `automations_page.dart`：AppBar 刷新走主题（去掉末尾多余 `SizedBox`）；
    卡内 `Switch` 去掉 `shrinkWrap`；`_action()` 重写为 48dp 热区 + 淡底墨线
    （原来"无底无边纯文字"既小又不像按钮）；「查看会话」撑到 48dp 行高。
  - `chat_page.dart`：排队条两个 IconButton 去掉 `compact`、icon 16→19；
    「追问·xx」入口由 `GestureDetector` 改为带描边的药丸键（48dp 宽 × 34 高）；
    排队条 `Switch` 去掉 `shrinkWrap`；图片/附件入口 `Padding(5)` → 48dp 约束；
    发送/停止圆键 46 → 48。
  - 未改：`「X 条」队列气泡行`（非交互）；`_QuickSlot` 六槽已是 44+文字，未动。
- 验证：`flutter analyze` 0 问题；`flutter test` **124 全过**（17 探针 skip）。
  两次提交：`97873c0`（主题 + 定时任务页）、`af6b6e1`（会话页追加消息链）。
- 设计原则（写进 `theme.dart` 注释）：**视觉可以小，能按到的范围不能小**。

### BUG-14 置顶只在当前项目生效 / 归档与批量操作在「全部」视图不动
- 现象（用户原话）：「会话置顶只在 default 项目有效 在全部会话和其他的项目里面似乎无效，
  还有就是检查会话管理功能 包括归档 删除 批量处理重命名」。
- 根因（**四个独立问题，同一个"跨项目/跨数据源"主题**）：

  ① **`setTaskPinned` 打在错误的桥上**——`_taskCall` 走**当前项目**的桥，而 scope 指向
     别的项目。注释原写「跨项目也成立，scope 用任务自带的工作区路径」，**这个前提是错的**：
     服务端拿到 scope≠来源 要么拒、要么打错项目。且失败若**不抛异常**（软失败 `{ok:false}`），
     `_pinOverrides` 会**永久留着脏记录** → 图钉只在本地亮，切回原项目没有。

  ② **「全部对话」视图拿不到 `pinned`**——`loadAllProjectTasks` 走 `bootstrap().tasks[]`，
     而 `parseBootstrapTasks` **不合成 `pinned`**、也没调 `listPinnedTasks`（单项目视图有）。
     后果：图钉全灭 + `TaskFilter.pinned` 永远筛不出东西。

  ③ **`allProjectTasks` 没人同步**——`deleteTask` / `archiveTask` / `unarchiveTask` 只动
     `tasks` 与 `archivedTasks`，在「全部」里操作完那张卡还在。`_runBatch` 收尾也**只**
     `loadTasks()`，在「全部」里批量完刷的是当前项目列表。

  ④ **`unarchiveTask` 把会话塞进当前项目**——从归档 tab 取消归档一个别的项目的会话，
     会被 push 进 `tasks`（当前项目），看起来像换了项目。

  另修：`_taskScope` 判"是不是当前项目"**只看路径不看 identity**。同路径不同 identity 是
  不同工作区（identity 才是服务端真身份），会拼出 path=X + identity=Y 的错 scope。

- 修复：
  - `setTaskPinned` / `archiveTask` / `unarchiveTask`：**先 `ensureTaskProject` 切到
    任务所属项目的桥**，发 RPC，再 `_restoreProjectView` 还原视图（用户在「全部」里点的，
    不能因此被甩进那个项目）。
  - 新增 `_isSoftFailure(res)`：识别 `{ok:false}` / `{accepted:false}` / `{success:false}`
    这类**不抛异常的拒绝**，同样回滚乐观层。之前只判异常会漏。
  - `loadAllProjectTasks`：逐项目问 `listPinnedTasks` 补齐 `pinned`；结果按项目缓存进
    `_pinnedIdsCache`（开桥有 BUG-10 那套开销，不做则会每次进「全部」都开一遍桥）。
    一个项目都没问成时返回 null，调用方**保留原样**而不是把 pinned 刷成全 false
    （那会把图钉全灭，比不显示更糟）。
  - 三个集合（`tasks` / `allProjectTasks` / `archivedTasks`）在所有增删路径上同步。
  - `_runBatch` / `_renameTask` 收尾**跟随数据源**：`viewingAllProjects` 时刷
    `loadAllProjectTasks()`。
  - 批量栏补 **「归档」（归档 tab 里自动变「取消归档」）** 与 **「重命名」**。
- 新增功能：**批量重命名**。规则 = 查找替换 + 统一前缀/后缀（`BatchRenameSpec`，
  放在 `task_filters.dart` 便于单测）。
  - **不做正则**：用户输入里的 `.`/`*` 按字面量——批量改名没有撤销，让 `.` 变成
    "任意字符"是灾难。
  - 不做序号：序号语义依赖排序，用户看到的名字会随列表顺序变。
  - 对话框**实时预览**前 5 条真实结果 + 「N 个不变 · M 个改名」，无变化时确认键禁用。
- 验证：`flutter analyze` 0 问题；`flutter test` **130 全过**（新增 6 条 `BatchRenameSpec`
  单测，覆盖字面量替换、前后缀幂等、组合顺序、isNoop、trim）。
  三次提交：`67285d3`（置顶）、`387867b`（会话管理同步）、`6bac671`（批量归档+重命名）。
- **诚实边界**：跨项目置顶会**拆建一次桥栈**（BUG-10 那套开销，慢几百毫秒）。这是正确的
  代价——之前"乐观层盖住 + 发一条注定失败的 RPC"让用户看到图钉亮了、切回去没有，更糟。
  另：`manual_bootstrap_tasks_probe_test.dart` 里跨项目 `setTaskPinned` 的探针**仍未跑过**
  （缺配对链接）；本修复按"必须走目标项目桥"实现，不依赖该探针结论。

### BUG-15 流式输出时翻看历史「一闪一闪」（视口抖动）
- 现象（用户原话）：「消息推流的时候，查看历史记录，现在似乎不会因为消息推流把消息拉下去，
  但是好像会一闪一闪的」。追问后确认：**所有流式场景都有**，大段输出（尤其带动画/代码块）
  时最明显。
- 定位：不是 BUG-01 失效——**视口确实不再被拽回底部了**（锚定在起作用），
  但**锚定补偿本身**成了新的抖动源。
- 根因（四层，全在"什么时候量、怎么落"上）：
  ① **补偿在布局未定时就落**（主因）。`_maybeAutoScroll` 挂在 `build` 的
     `addPostFrameCallback` 上；流式期间"这一帧量到的高度"和"下一帧实际的高度"经常
     不一致，于是每帧算一次增量、每帧跳一次 → 每次跳都是一次可见位移。
  ② **`jumpTo` 是瞬时跳变**（`_applyAnchorGrowth` 原实现）。没有动画缓冲，
     一帧跳一次就是闪烁；阈值只有 `0.5px`，流式文本每 tick 长十几像素必然每帧越过。
  ③ **同帧多次补偿各跳各的**。`_onScroll`（内容变化触发滚动通知）、post-frame 的
     `_anchorAgainstGrowth`、状态更新三处都可能在同一帧算到增量。
  ④ **`_atBottom` 单阈值在临界带反复翻转**。流式期间 `maxScrollExtent` 持续变大，
     用户停在距底部约 100px 处时判定在 true/false 间横跳，每跳一次 `setState`
     重建整页，既闪又连锁切换锚定分支。另：手势结束时把攒下的欠账（动辄几百像素）
     一次性补掉，是"弹跳"。
- 修复（对应四层）：
  - **`jumpTo` → 短时长微动画**（`animateTo` + `Curves.linear`，60~110ms 随位移缩放）。
    这是修复核心：同样的修正量被摊成连续移动，看不出修正动作，只觉得内容被钉住。
  - **同帧合并**：新增 `_coalescedAnchorDelta` 桶 + `_scheduleAnchorFlush()`，
    一帧内所有补偿量先累加、帧末只落一次。
  - **补偿阈值 0.5 → 1.5px**，并加**单步上限 600px**：超出的部分留回桶里分帧还，
    把"弹跳"变成"追上去"。
  - **`_atBottom` 双阈值滞回**：进入 `pixels <= 100`，退出 `pixels > 180`，
    中间带状区保持原状态。
  - **动画互斥**：`_anchorAnimating` + 定时器门控，避免两个 `animateTo` 并发抢
    同一个 `ScrollPosition`（那本身就会抖）。
  - 纯计算抽到 `composer_logic.dart` 的 `AnchorThresholds` / `AnchorMath`
    （无 Flutter 依赖，可单测）——这些数字是"闪不闪"的关键，值得锁住。
- 验证：`flutter analyze` 0 问题；`flutter test` **139 全过**
  （新增 9 条：`AnchorThresholds` 滞回 4 条 + `AnchorMath` 规划 5 条）。
  提交 `c07b63b`。
- **踩坑**：本版 Flutter 的 `ScrollPosition.animateTo` 返回**普通 `Future<void>`**
  （不是 `TickerFuture`），没有 `whenCompleteOrCancel`——用它做"动画完成回调"编译不过。
  改用定时器在名义时长后放开标记（最坏情况只是少补偿一小段，不会永久卡住）。
- **待真机确认**：真机上流式手感（尤其代码块折叠展开、图片加载）可能还有别的抖动源；
  本次只修了"锚定补偿"这一条链。

---

## BUG-16 流式追加仍把看历史的用户拉回去（BUG-15 残留）

- 现象：BUG-15 修完后抖动没了，但"看历史时被拉回去"**仍在**。用户原话：
  "还是会被拉回去——这个 bug 上一个提交没修好，还在……其实已经修的差不多了"。
  → 症状从"闪"（高频小幅）变成"拽"（低频大幅），是不同链路。
- 根因（`lib/ui/chat_page.dart` 第 170 行 `_maybeAutoScroll`）：
  1. **`Curves.easeOut` 出门太快**：120ms 里前 30ms 走完约 60% 距离。
     `_applyAnchorGrowth` 已改 `linear`（所以那条链不闪了），但这条自动回底
     路径还是 `easeOut`——手指刚离屏、惯性在减速时被覆盖，观感就是"被一只手拽回去"。
  2. **意图判定用了位置而非行为**：`AnchorThresholds.exitPx = 180`，
     只要离最新端 ≤180px 就算"在底部"。流式期间内容每 tick 长高，用户看的
     那个位置对应 `pixels` 每帧都在变，临界带内必然误判 → 新行一到就被拽。
  3. **`_scrollingByUser` 释放过早**：`ScrollEndNotification` 一到就清，
     但"惯性停止"≠"用户放弃浏览"。人还停在离底部几百像素处，`_atBottom`
     尚未翻转，此时流式追加一行 → 立刻开火。
- 修复（三层，纯逻辑抽到 `composer_logic.dart` 可单测）：
  - **`FollowLock` 意图锁存**：用户**主动**滚离底部（`pixels > exitPx`）→
    本次会话内锁死自动回底，直到他**主动**滚回 `pixels <= releasePx(40)`
    或点「回到最新」。`releasePx(40) < enterPx(100)` 制造一段死区，
    防止在临界带回滚时突然解锁。锁存期间 `_anchorAgainstGrowth` 的
    `_atBottom` 短路分支也被旁路——否则内容照样漂。
  - **`AutoFollowMath` 分距离处置**：一屏内才直接回底，且曲线从 `easeOut`
    改 `linear`、时长 120 → 200ms（匀速看不出"拽"）；超过一屏直接不动手，
    交给锚定通道慢慢追，不抢用户视线。
  - **程序性滚动不入锁**：`_send()` 里显式 `_followLocked = false` +
    `_atBottom = true` + post-frame `animateTo(0, 220ms)`（不走一屏上限）——
    用户刚点发送，无论之前翻多深都必须把最新内容带到眼前。
    「回到最新」按钮的 `onTap` 同样先解锁再滚。
- 验证：`flutter analyze` 0 问题；`flutter test` **152 全过**
  （新增 13 条：`FollowLock` 7 条 + `AutoFollowMath` 6 条）。
  提交 `98f34f5`。
- **设计取舍**：`FollowLock` 是状态锁而非位置判定。位置是连续量、意图是离散的，
  用连续量猜离散意图在流式场景必然误判——这条值得记住，见 `LESSONS.md`。
- **待真机确认**：真机上是否还有别的"抢滚动"来源（如 `RefreshIndicator`、
  键盘 `_onFocusChange`）。本次已给 `_onFocusChange` 也加了锁判定。

---

## BUG-17 AskUserQuestion 询问弹窗三处失效（多选 / 其他输入 / 回传形状）

- 现象（用户）："多选"、"用户填其他信息"、"总感觉有问题"。
- 排查手段：写探针（`test/manual_interaction_probe_test.dart` +
  `manual_interaction_resolve_probe_test.dart`）直连桌面端，**先抓真实结构、
  再实测回传形状**，不靠猜。实测样本 `sess_681356e6 / perm_723f9c9a`。
- 实测契约：
  - 进来：`payload = {kind:'userInput', freeText:bool, prompt, questions:[
    {question, header, multiSelect, options:[{value,label,description}]}]}`
  - **没有 `id` / `required` / `allowOther`**；选项标识是 `value`。
  - 回传（实测 accepted + 弹窗关闭）：`{action:'accept',
    content:{answers:[{question:'题干原文', selected:['value',…]}]}}` —— **数组**。
- 根因（四处，旧 `_QuestionsView`）：
  1. **回传形状错**：发的是 `{answers: {题目: [值]}}`（Map），协议要数组
     → 服务端收不到，答案等于没提交。
  2. **`multiSelect` 没读**：`onTap` 里整体赋值 `= ['值']`，点第二个覆盖第一个
     → 多选题只能生效一个。这就是用户说的"多选"失效。
  3. **"其他"输入无入口**：`freeText` 是 **payload 顶层**开关，旧实现只在
     "无 questions" 分支渲染全局输入框，题目下没有入口 → 想填其他填不了。
  4. **`description` 没渲染**（实测每个 option 都带说明）+ 题干用了不存在的
     `title` 字段 + 键用 `id ?? question`（无 id，等于永远用题干）。
  另：选项 chip 垂直 padding 仅 5px（高约 21dp），远低于 48dp 触控标准，
  且无点击反馈。
- 修复：
  - 纯逻辑抽到 `composer_logic.dart`：`AskQuestion` / `AskOption` /
    `AskAnswer`（多选 toggle、单选换选、自由文本）+ `buildAskAnswersPayload`
    （产出实测形状）+ `allAnswered`（提交门槛）+ `payloadAllowsFreeText`。
  - UI 重写：每题顶部标「多选/单选」；选项整行 ≥48dp + `InkWell` 水波纹；
    多选框用方框、单选用圆圈（形状即提示）；渲染 `description`；
    `freeText` 为真时每题加「其他…」可展开输入框。
  - 提交门槛从"答过任意一题"改为"每题都有答案（选项或自由文本）"。
  - 「其他」文本拼进该题 `selected`（契约里 selected 是唯一出口）。
- 验证：`flutter analyze` 0 问题；`flutter test` **173 全过**
  （新增 21 条：解析 6 + 作答状态 4 + 载荷 4 + 门槛/开关 4 …）。
  提交 `97e7cc4`。探针三个一并入库（无环境变量自动 skip）。
- **待真机确认**：自由文本拼进 `selected` 的写法服务端是否认（本次未单独验
  freeText 回传路径）。若真机上"其他"填了没生效，改走顶层 `answer.freeText`。

---

## BUG-18 会话列表状态与真实状态不一致 + 消息报错不上浮

- 现象（用户）："会话列表的显示和会话状态要保持一致 要给用户及时的反馈
  特别是消息报错"。
- 排查发现四处不一致：
  1. **列表 phase 靠 sessions-index 流，而流会丢更新**：`_livePhase` 覆盖机制
     的存在本身就是为它兜底——只有**打开过**的会话才有权威覆盖，没点进去的
     会话流一丢就永久停在旧状态（服务端跑完了列表还显示"运行中"）。
  2. **退出聊天页立刻清覆盖 → 状态倒退**：`clearLivePhase` 在 dispose 同步执行，
     index 若滞后，刚在聊天页看到"运行中"，退回列表变"空闲"。
  3. **消息发送失败只在聊天页可见**：`failed` / `slow` / `queued` 只活在
     页面级 `_echoes` 里，列表卡片没有任何标记——切回列表不知道消息没发出去。
  4. **`isRunning` 不含 `queued`**：排队中的会话被判定为不活跃。
- 修复：
  - **列表可见时定时对账**（`tasks_page` 12s `Timer.periodic` → `refreshFromIndex`）：
    只做本地 index 合并，不发起 RPC（拉新数据仍由下拉刷新 + token 定时器承担）。
  - **`clearLivePhase` 延迟释放**：进入待释放缓冲，index 追平（两边 phase 相等）
    即释放，否则 20s 超时兜底；重新打开会话会取消待释放。
  - **发送异常上浮**：controller 新增 `_sendIssues` + `reportSendIssue`；
    聊天页在失败时上报「消息未送达」、20s 超慢时报「消息发送较慢」、
    成功送达时清除。任务卡在 chips 下方渲染玫红标记（优先级高于「等待你的确认」）。
  - **`isRunning` 含 `queued`**，并新增语义更严的 `isProducing`
    （不含 queued，留给需要"能否停止"的判断）。
  - 纯逻辑落 `conversation.dart`（protocol 层，controller/UI 共用）：
    `isBusyPhase` / `isProducingPhase` / `canReleaseLivePhase` /
    `shouldFlagSendIssue` / `sameSendIssue`。
    **分层注意**：一开始放进了 `ui/composer_logic.dart`，但 `protocol/conversation.dart`
    要用它就成了 ui→protocol 反向依赖——挪回 protocol 层。
- 验证：`flutter analyze` 0 问题；`flutter test` **183 全过**（新增 10 条）。
  提交 `36d2d21`。
- **待真机确认**：12s 对账频率是否合适（太频繁会多耗电，太慢则不"及时"）。

---

## 排查结论存档（BUG-07 桌面机制考古，zcode.cjs + 探针）

- 桌面端 `workspace/readState`、`workspace/setDefaultModel`、`session/setModel`（带
  `persistAsWorkspaceLastUsed`）存在于 zcode.cjs 的 ZCode Protocol 服务（`rr.*`
  dispatcher），**未通过 Channel IPC 暴露给移动端**（通道枚举全 miss）；移动端可用写入口
  是 V4 `switchModelConfig`（实测 accepted 且持久）与 zcode-task `setModel`。
- `switchModelConfig` 可选 `runtimeModel` 参数的 zod schema 要求
  `{provider: object, model: object, revision: string, generatedAt: number}`——host 内部
  构造的完整运行时描述，移动端无法自拼（revision 是指纹）；不带它普通切换即可生效持久。
- 桌面端工作区"当前模型"（modelCurrent）曾为欠费 qwen3.8-flash，高频「同步当前模型
  runtime config」机制（1056 次/天）以它为源推送。
- 新会话 createSession 服务端初始模型=桌面工作区当前模型（实测落 qwen3.8-flash），
  客户端默认套用（#4 + 本修复）是纠正它的唯一手段。

---

## 待办候选（未立项，等用户下令）

- `workspace/setDefaultModel` 接入：服务端工作区默认模型，跨设备默认的正解（协议参考文档 L111）。
- 发送失败识别模型类错误时提供「一键切回 GLM」按钮。
- 打开会话列表/App 启动时批量模型对账，消灭无人值守漂移窗口。

---

## 2026-09-12 全量扫描批次（写手接手后持续扫描）

### BUG-19 「全部对话」里删除/重命名别的项目的会话静默失败
- 现象：在「全部对话」视图对**别的项目**的会话点删除或重命名，本地立刻生效（墓碑/标题覆盖），但服务端没删/没改——其他设备上删除的会话复活、重命名打回原形。
- 根因：夜班 BUG-14 给 setTaskPinned/archiveTask/unarchiveTask 补了 `ensureTaskProject`（切到任务所属项目的桥再发 RPC），但 **deleteTask 和 renameTask 漏了**——同属"scope 对但桥错就静默失败"的操作族，且本地墓碑/标题覆盖恰好掩盖失败。
- 修复：两处补 `ensureTaskProject`（rename 失败抛错提示；delete 切换失败也照常隐藏——删除意图优先）；deleteTask 的 `deleteSession` 改为**切换后**再捕获 conv，确保会话本体删除也走目标桥。
- 验证：analyze 0 问题 + 183 测试全过；待真机在「全部对话」里跨项目删除/重命名验收。
- 教训：同一类"scope 带项目身份的写操作"必须成族排查，修一个漏同族其余等于没修（补进 LESSONS）。

### BUG-20 「全部对话」视图的 token 角标永远空白
- 现象：全视图跨项目卡片没有 ⚡token 角标（当前项目卡片有）。
- 根因：`_fetchTaskTokens` 只遍历 `tasks`（当前项目列表），`loadAllProjectTasks` 不触发取数——`_taskTokens` 对外项目会话永远无值，卡片 `tokenCountLabel` 拿到 null 不渲染。
- 修复：`_fetchTaskTokens({List? from})` 参数化数据源；`loadAllProjectTasks` 末尾 `unawaited(_fetchTaskTokens(from: allProjectTasks))`。取数仍走 `_backgroundGate` 限流 + TTL 去重。
- 验证：analyze 0 问题 + 188 测试全过；待真机在全部视图看角标出现。
- 备注：排查中曾误判 _taskTokens 是"只写死数据"——实际 UI 走 `app.taskToken(id)` 读取，grep 私有字段名漏掉了 getter 调用。

### BUG-21 reorderQueueItem 缺 CAS 标记（接入首日自查发现）
- 现象（潜在）：新接入的队列重排在真实环境会被 zod 以缺 baseRevision 拒绝——桌面端 baseRevision 必带集合含 reorderQueueItem（zcode.cjs 与客户端 casCommands 同源枚举对比坐实）。
- 根因：接入新方法时只加了调用，没核对桌面端 baseRevision 必带集合（客户端 casCommands 的镜像完整性）。
- 修复：casCommands 补 'reorderQueueItem'（commit 见 git log）。stale 自愈逻辑已在 sendCommand 通用路径。
- 验证：analyze 0 问题 + 188 测试全过；待真实队列（≥2 条排队）重排实测。
- 教训：接入桌面端命令前，把桌面端 baseRevision 必带集合与客户端 casCommands 做一次 diff——这是第二起同源枚举不一致（第一起是 casCommands 本身缺 reorderQueueItem 的历史成因）。

### BUG-22 任务通知展开后正文空白
- 现象：任务完成/报错的通知，收起态能看到一行 body，**下拉展开后内容区一片空白**。
- 根因：`showTaskEvent` 里 `styleInformation: BigTextStyleInformation('')` 用空串构造——flutter_local_notifications 一旦设置了 styleInformation，展开布局只读它的 content，`show()` 的 body 参数只进收起态。
- 修复：`BigTextStyleInformation(body)` 挂真实正文（details 因此从 const 改 final）。lib/services/notification_service.dart。
- 验证：analyze 0 问题 + 190 测试全过；待真机收一条任务完成通知验证展开内容。
- 教训：flutter_local_notifications 的 body 参数与 styleInformation.content 是两条渲染路径——设置了 style 就必须把正文也放进 style。

### BUG-23 删除运行中的会话不先停止——agent 可能跑完本轮白烧 token
- 现象（潜在）：删除一个 status=running 的会话，桌面端 agent 可能继续跑完本轮（token 白烧），旧版桌面端还可能因「任务在跑」拒绝删除。
- 根因：deleteTask 直接发删除 RPC，没有先 stop。桌面库实证：90 个已删任务无 running 状态（68 completed+20 error+2 空状态）→ 桌面端会清状态，但旧版本行为未知。
- 修复：删除前对 running 会话 best-effort 发一个 stop（失败照常删，删除意图优先）。GitHub/UX 共识即"先停后删"（stop generation first, then delete）。
- 验证：analyze 0 问题；真机删一个运行中的会话验证。

### BUG-24 置顶会话组内乱序（用户点名）
- 现象：置顶的多条会话排列顺序不可预期（用户判定"没按顺序排"）。按钮本身（RPC/状态）正常。
- 根因：`sortTaskCards` 置顶组**有意**保持来源相对顺序（注释写明"保持原相对顺序"）——但来源顺序经过 channel 列表/index 流/缓存多次洗牌后实际不可预期，"有意"变成了"乱序"。
- 修复：置顶组内同样按活跃时间倒序（与未置顶组一致，最近动的置顶在最上）。回归测试改为断言组内排序（p2/p1 顺序翻转验证）。
- 验证：analyze 0 问题 + 190 测试全过。
- 教训：被注释"合法化"的怪行为要在真实使用反馈下重审——"当初故意这么写"不等于"应该继续这样"。

### FEATURE 上传中途取消（理想对照法补齐的第 1 个缺失功能）
- 方法论：按用户授意的「先问理想再对照」——理想上传体验（Filestack/Uploadcare/assistant-ui
  参照：进度/预览/取消/重试/限额提示）逐条对照，发现上传中途无法取消是头号缺口。
- 实现：conversation.attachmentPut 增加 isCancelled 回调（分片边界轮询，每 chunk 一个
  网络往返=天然取消窗口）；chat_page 发送中回显亮「取消」（仅上传阶段），置位后抛
  「上传已取消」→ echo 转失败（错误文案映射成人话），可重试可删除。
- 验证：analyze 0 问题 + 190 测试全过；待真机传大文件时点取消验证。

### BUG-25 行级命令族缺 entityId——重新生成/编辑重发/文件回滚/赞踩全被 zod 拒
- 现象（源码考古坐实）：桌面端 3.11.2 所有行级命令共用 Ty schema：
  {rowId: int, entityId: string trim min(1)} **strict**——entityId 必填。
  客户端除 forkAssistant 外全部只发 {rowId}（retryTurn/editUserQuery/
  applyFileRewind/setAssistantFeedback 四处）→ zod 拒绝。
- 根因：与 BUG-21 同源——客户端 casCommands/行级 target 从未与桌面端 zod 逐字段对齐；forkAssistant 能用纯因它恰好发了 entityId。
- 修复：retryTurn/editUserQuery/setAssistantFeedback 调用链全族补 entityId（行数据里
  entityId ?? turnId）；applyFileRewind 的 _lastTurnTarget 本就带 entityId ✓。
  editUserQuery 同步修正编辑重发预填的 text/inputText 双形态。
- 验证：analyze 0 问题 + 190 测试全过；zod schema 为桌面源码实证。
- 教训：行级命令 target 的唯一权威是桌面 zod（Ty），任何新行级命令接入前先对 schema。

### BUG-26 通知开关未持久化——重启后回默认开启
- 现象（维度4 持久化盘点发现）：用户在「我的」页关掉任务通知，App 重启后开关自动回到开启。
- 根因：`NotificationService.enabled` 是内存静态字段，无任何落盘。
- 修复：开关改私有字段+getter/setter，init 时读 SharedPreferences（notificationsEnabled），赋值即落盘。
- 验证：analyze 0 问题 + 190 测试全过；待真机关闭通知→重启验证保持关闭。
- 关联发现：_titleOverrides 不持久化是**合理**的（renameTask 已落服务端，重启后标题由服务端权威回供）。

### FEATURE 排队追加重复不入队（用户看图报障：13 条重复排队项）
- 现象：提醒类来源每分钟追加同文本消息，会话忙时全部入队——截图实证 13 条"提醒：不要停"排队。
- 修复：keepQueueAndSend 分支加重复守卫（queueHasDuplicate 纯函数+单测）：新文本 trim 后与队列任一条相同 → 不入队并提示「排队中已有相同消息，未重复入队」。clearQueueAndSend（清队重发的明确意图）不拦。
- 验证：analyze 0 问题 + 192 测试全过（含 5 个新判定单测）。

### BUG-27 轻滑后视口"飞"到计划面板且滑不动（用户点名）
- 现象：轻轻滑动 → 视口快速自动飞到执行计划面板处；惯性被打断滑不动；输入/图片发送后也会快速滑掠过内容。
- 根因（两层）：①**拖动欠账回放**——拖动期间流式内容持续长高被记成"锚定欠账"（几百px），松手停稳后一次性 animateTo 回放 = 视口飞行；②**弹道期补偿**——惯性滚动中锚定补偿动画继续跑，与惯性抢滚动（旧版 _scrollingByUser 不覆盖弹道期）。
- 修复：拖动期间不再记欠账（直接跳过补偿，规范 §4.3 同款取舍）；补偿加 userScrollDirection != idle 弹道保护；删除 _onScrollGestureEnd 的欠账回放死逻辑。
- 验证：analyze 0 问题 + 194 测试全过；待真机轻滑验证（不再飞、惯性自然衰减）。
- 教训：补偿类机制"记录缺口事后补"在持续增长场景=把缺口滚成雪球；对高频增长源应即期跳过而非记账。

### BUG-28 会话历史翻页死锁——只能看到最近窗口（用户报障"加载不完整"）
- 现象：打开长会话只有最近约 60 行，向上翻页无反应，历史永远加载不全。
- 根因：loadOlder 用服务端快照的 `firstRowId`（会话首行 id，恒为 1）当翻页游标，
  请求"row 1 之前"= 空集 → 每轮 0 行，hasMoreOlder 永真 → 死锁。探针实证：
  修复前 60→60 卡死；修复后游标=窗口最小 rowId（2724），46 轮抽干 2783 行全量。
- 修复：游标改为窗口内最小 rowId（合并去重后自然推进）。
- 验证：探针 round1 60→120(2724)、round2 120→180(2612)…round46 抽干 2791 行 ✅。
- 教训：服务端快照字段的语义要实测（firstRowId 是"会话首行"不是"窗口首行"）；
  探针 test/manual_rowsrange_exhaust_probe_test.dart 留库可复跑。

### BUG-29 全视图置顶不生效 + 项目反复自动切换（用户点名，截图实证）
- 现象：①「全部对话」里图钉亮着但置顶卡不排最前；②全视图下反复弹"正在打开工作区桥…"、"已切换到「写项目」/「零时项目」"，列表闪烁重建。
- 取证（桌面反解 app.asar + tasks-index.sqlite + host 日志）：
  - 桌面 task 通道是 **host 级服务，按参数里的 workspacePath 路由**，与桥绑定哪个项目无关（`listPinnedTasks(y)` 直读 `y.workspacePath`；token 角标跨项目直发早已实证）。
  - sqlite 里三个项目的置顶**全部落库成功**（pinned=1）——RPC 链路本来就通。
  - host 日志实证：全视图每次刷新逐项目 `openBridge`（写项目→零时项目→学习 1 秒内连环 attach），而**桌面端一个 relay 会话只保一个活动工作区桥**，每开一个新桥把当前桥顶掉（`bridge degraded: replayGraceExceeded/physicalGap` → 重连风暴）。
- 根因（三层）：①展示层 `sortTaskCardsBy` 平铺按活跃重排，把数据层排好的置顶优先冲掉；②`_collectPinnedIdsAcrossProjects` 逐项目开桥+dispose，制造桥顶掉/重连循环；③pin/rename/archive/unarchive/delete 走 `ensureTaskProject`→`openWorkspace` 真实切换 + `_restoreProjectView` 切回，每次操作两次全量切换（"已切换到"连环弹）。
- 修复：①`sortTaskCardsBy` 全部排序键置顶组恒最前（组内按所选键）；②置顶收集改当前桥直发 RPC（合成 `{workspacePath, workspaceIdentity?}` scope），零开桥；③五个写操作全部去掉切桥/切回，直发跨项目 RPC。`ensureTaskProject` 仅保留给"点开跨项目会话"（打开聊天确实需要目标桥，属用户真实意图的切换）。
- 验证：analyze 0 问题 + 194 测试全过（task_sort_test 三处断言按新语义更新）。
- 教训：跨"scope"操作前先实测服务端路由机制——按参数路由的服务不需要客户端迁就桥位置；为"对齐 scope"做的切桥在单桥架构的桌面端是自毁动作。

### BUG-30 压缩上下文无提示（用户报障"压缩上下文没有通知"）
- 现象：桌面端压缩上下文（含满窗自动压缩）时，手机对话流里什么都不显示——用户以为消息丢了/会话异常。
- 取证（桌面反解）：压缩是一条 `kind: 'timelineMarker'` 行，`marker = {type: 'compact', status: running/completed/noop/cancelled/failed, origin: auto/...}`；桌面端渲染成带图标+文案的提示条（chat.contextCompaction.* 消息族）。另有 goalVerify/forkNotice 两种 marker。
- 根因：zremote 认识 timelineMarker 但渲染成 `TurnDivider(label: '')`——空标签分隔线，一切 marker 语义全部隐形。
- 修复：`_markerLabel` 按 type/status/origin 映射中文文案（正在压缩…/已压缩上下文/上下文已满，已自动压缩/无需压缩/压缩已中断/压缩失败；forkNotice→已分叉新会话），compact 用 compress 图标；未知 marker 维持原空白分隔线。
- 验证：analyze 0 问题 + 199 测试全过（新增 test/rows_marker_test.dart 5 个 widget 测试锁行为）。
- 教训：客户端对"不认识的行"给空白渲染，等于把服务端的系统事件静默吞掉——每种行 kind 接入时先枚举桌面端的渲染语义。

### 改进 压缩上下文按钮交互（用户点评"按钮交互也很差"，BUG-30 追问）
- 功能核实：compact 命令桌面端合法（反解实证：与 sendText 同类的输入型命令，payload 消毒、baseRevision 可选）——按钮**有效**，坏的是交互。
- 交互问题：①点了之后零反馈（成功只写日志）；②压缩进行中可无限连点（桌面端 compact 是排队输入，连点=排队多个压缩回合）；③看不到压缩状态。
- 修复：①成功后 flash「已发出压缩请求，完成后会在对话里提示」；②按 rows 里的 compact/running marker 判定进行中——按钮变禁用态「正在压缩上下文…」，再点提示"不用重复发起"；③完成感知走两条路：对话流「已压缩上下文」提示条（BUG-30）+ 用量面板窗口占用回落。
- 验证：analyze 0 问题 + 199 测试全过。

### 改进 排队消息列表可折叠（用户点单"排队消息可以折叠"）
- 现状：队列条目连同编辑/立即发送/上移/删除按钮全部常驻展开，十几条排队时把输入框顶出半屏。
- 修复：标题行（图标+「排队中 N 条」+箭头）整体可点折叠/展开，箭头 150ms 旋转；默认折叠只显示队首（下一条要发的），底下补「… 还有 N 条，点开展开」；折叠态队首自然隐藏「上移」按钮（无处可移）。「追问」「自动消化」控件不受折叠影响。
- 验证：analyze 0 问题 + 199 测试全过。

### BUG-31 定时消息重复堆积——队列自动去重（用户点名"队列重复就不再添加，主要是定时消息"）
- 关键事实：此前「重复不入队」守卫只拦**手机端手动发送**路径；定时任务/自动化由桌面端直接把文本塞进服务端队列，根本不经过手机——1 分钟级提醒在忙会话上照样堆出十几条一模一样的排队项。
- 修复：手机端拦不住入队，就在队列侧兜底——`ConvSubscription` 收到任何会话帧后跑去重判定（`duplicateQueueItemIds` 纯函数：同文本 trim 后多条，保留队首、删多余），多余的经 `deleteQueueItem` 删除，全设备同步生效；删除期间防重入，失败记日志等下一帧快照收敛。
- 边界：空文本/缺 id 的条目不参与（宁放过不误删）；手动发送路径的既有守卫不变（意图一致：重复本来就不该入队）。
- 验证：analyze 0 问题 + 204 测试全过（新增 test/queue_dedup_test.dart 5 个判定单测）。

### BUG-32 聊天记录自动回拖——翻页×锚定补偿正反馈循环（用户视频报障"莫名其妙一直往回拖"，且发生在无消息无输出阶段）
- 关键线索（用户澄清）：拖动发生时**没有发消息、系统没有输出**——排除流式增长，锁定一个不依赖新内容的循环。
- 根因（正反馈环）：①用户读历史=锁存态，恰在锚定补偿的活跃区；②接近历史尽头 600px 触发 loadOlder，在**历史端**并入 60 行；③锚定系统把总高增长一律当成"新内容增长"，动画把视口往上拽一个该批高度；④拽进新翻页区→再翻页→再拽——直到整个历史被拖完。而语义上历史端插入**根本不需要补偿**：插入点以下的用户可见内容纹丝不动。
- 修复：`ConversationState.olderMergeEpoch`（每次 mergeOlder +1）作为翻页标记；`_anchorAgainstGrowth` 见到纪元变化直接同步基线、一分不补——断环。新端流式增长的正常锚定不受影响。
- 验证：analyze 0 问题 + 204 测试全过。真机复现场景：打开 z 长会话→滚到历史区停留→不再被自动拖走。
- 教训：锚定补偿的语义是"钉住新端增长挤动的视口"，对增长来源不加区分就会把"加载历史"也当敌人；任何"接近阈值→加载→补偿"的链路都要检查是否构成闭环。

### 改进 后台任务显示「已完成」（用户点单"后台任务完成 显示完成可以"）
- 取证（桌面反解）：后台任务 schema 状态只有 running/resultPending/failed/cancelled，**服务端没有 completed 态**——进程正常结束停在 resultPending（"待收结果"），结果被取走后整条卡直接消失。用户永远看不到"完成"。
- 修复：App 推导语义——resultPending = 已完成（青绿徽章+边框）；resultPending 不再算运行中（黄框/取消按钮只在真 running 时给）；失败改玫红可辨识；用时在结束态停表（endedAt-startedAt，前缀"用时"）。
- 验证：analyze 0 问题 + 206 测试全过（新增 resultPending 推导与停表单测）。

### 改进 排队消息不回显聊天流（用户点单"排队消息不要第一时间回显到聊天框"）
- 现状：选「排队发送」后，消息既出现在底部队列栏、又在聊天流里飘一个回显气泡直到队列消化——同一消息两处显示，聊天流被占满。
- 修复：echo 标记 inQueue（仅 keepQueueAndSend 路径），_visibleEchoes 过滤掉未失败的 inQueue 气泡——聊天流干净，队列栏是唯一展示位；队列消化后服务端 userInput 行正常出现。失败例外：inQueue 气泡失败时仍显示错误并可重试（requireAccepted 拒绝→failed→过滤放行）。
- 验证：analyze 0 问题 + 206 测试全过。

### 改进 通知提示音可配置（用户点单"任务状态变化弹窗通知……可以选择配置消息提示音"）
- 实现：NotificationService 增 soundMode（system/silent，SharedPreferences 持久化）。Android 渠道建后声音属性不可改 → 双渠道方案：task_events（默认音）/ task_events_silent（无声+振动），init 时都注册，show 时按模式选渠道。
- UI：我的页通知开关下新增「通知提示音」行（仅通知开启时显示）：系统默认/静音 切换开关+当前值文案，图标随状态换。
- 验证：analyze 0 问题 + 206 测试全过。

### BUG-33 具体报错原因不显示（用户问"余额不足等具体原因反馈不出来了吗"）
- 取证（桌面 schema 反解）：桌面端错误信息非常全——control.lastError 是结构体 {code, message, recoverable, source, statusCode?, providerErrorCode?, detail?}，余额不足这类 provider 业务错误带 HTTP 状态码和业务错误码。**App 的解析只认字符串，lastError 是 Map 时直接跳过**——具体原因在这一环被丢掉，用户只能看到"本轮回复中断"。
- 修复：errorValueText 统一解析（字符串直通；结构体取 message→detail→code 三级兜底，附 HTTP 状态码与 providerErrorCode），extractConversationError（会话级错误卡）与 extractRowError（行级错误卡）共用。
- 效果：「本轮回复中断」下方现在会显示「余额不足（HTTP 402 · 1113）」这类完整原因。
- 验证：analyze 0 问题 + 207 测试全过（新增结构体解析单测）。
- 教训：schema 里 J_ 的形态（结构体 vs 字符串）要实测，"多认几个键"的兜底若只认一种形态等于没兜底。

### BUG-34 突发事件后状态流转错乱（用户报障：桌面端崩溃等突发事件后状态有问题，要及时跟服务端更新）
- 审计结论：relay 重连成功后只做**链路层**恢复（桥重建），**数据层不做任何对账**——桌面端崩溃重启后，App 拿着崩溃前的旧账继续跑：
  ① `_livePhase` 相位覆盖：任务卡相位/运行徽章卡死在旧值（服务端已全新）；
  ② 会话/索引订阅随桌面崩溃消失，只剩 watchdog 兜底——运行中 20s、**空闲最长 5 分钟**才重同步；
  ③ 任务列表是崩溃前的本地快照，不重拉。
- 修复：RemoteSession 增 `onRePaired` 回调（每次真实重连恰好一次）；ZApp `_reconcileAfterRePair`：
  ① 清 `_livePhase` + 通知基线（`_lastPhases/_lastWaiting/_phaseWatchPrimed` 重录，防误报通知）；
  ② chat/index 订阅强制 resync（forceSnapshot 重放）；
  ③ 任务列表全量重拉（含全视图）；
  ④ 兜底：4s 后会话仍无任何行 = resync 没救活 → 整条重订阅（openSession）。
- 验证：analyze 0 问题 + 207 测试全过。真机验证路径：开着会话 → 杀掉桌面端 ZCode → 重开 → App 应在数秒内恢复正确相位与列表。
- 教训：断线恢复只修链路是半套——"重连成功"必须同时触发数据对账，本地一切覆盖类状态（相位/乐观补丁/基线）在重连时都应让位于服务端权威。

### 改进 移除聊天页右上角「当前活动」按钮（用户点单"右上角那个按钮不要了"）
- 理由：与 Composer 底部栏「任务」槽完全重复（同一个 子代理/后台任务/定时任务 三 Tab 面板），双入口冗余。
- 改动：AppBar actions 仅保留刷新（强制重同步）；删除 _activityAction。活动入口统一走底部「任务」槽。
- 验证：analyze 0 问题 + 全部测试通过。

### 改进 会话状态变化通知带具体原因+点击跳转（用户点单"会话状态变化发送通知，比如报错、完成"）
- 现状：完成/中断/报错/等待确认四类通知框架已有（sessions-index 相位变迁驱动），但报错只说"出错了"不带原因，且点通知不会跳到对应会话。
- 修复：①报错通知正文追加 lastError 具体原因（BUG-33 同源 errorValueText 解析，如"余额不足（HTTP 402 · 1113）"）；②通知 payload 带 sessionId，点通知复用任务卡导航跳进对应会话（未配对时不跳，防空页）。
- 已知限：App 进程被杀后的冷启动点击不触发跳转（无后台 isolate，flutter_local_notifications 平台限制）。
- 验证：analyze 0 问题 + 207 测试全过。

### 改进 全项目任务事件通知（用户场景点单：提交任务去玩手机，任何一个会话报错/完成/意外终止都要弹窗）
- 缺口：原通知由 sessions-index 实时订阅驱动，只覆盖**当前项目**——人在 A 项目时，B 项目会话的报错/完成收不到。
- 取证（桌面反解+DB 实测）：zcode-task.listTaskList 接 workspaceScopes **数组**，host 级一次调用查全部项目（不切桥）；meta.status 词汇 = running/completed/error。
- 实现：20s 全局轮询（listTaskList 全 scopes）驱动 detectPollTaskEvent 变迁判定；**不受前台门控**（切后台正是它的工作时间）；报错通知带 lastError 具体原因；payload 可点跳会话。与实时索引通知共用 90s 去重账（end 类终结事件一个会话只提醒一次，两通道不双响）。
- 意外终止：relay 从 paired 掉到 reconnecting/error 且有任务在跑 → 弹「连接中断，恢复后自动对账」（90s 去重）。
- 已知限：App 进程被 Android 挂起后轮询暂停（无推送服务的平台级限制，与既有通知一致）。
- 验证：analyze 0 问题 + 209 测试全过（新增轮询判定单测）。

### 改进 消息文本交互三件套（用户点单：自己消息要复制按钮/输出大片文本要拖拽选择/文本菜单中文化）
- 用户气泡（userInput）：右下新增一键复制小图标（点击复制全文，1.2s 对勾反馈；48dp 热区 30dp 视觉）。原有长按选择保留。
- 助手输出（AssistantBlock）：Markdown 包 SelectionArea——长按进入选择、拖拽扩展选区、系统菜单一键复制；普通拖动仍滚动列表不抢手势。流式期间同样可用。
- 中文化：MaterialApp 挂 GlobalMaterial/Cupertino localizations + locale zh（新增 flutter_localizations SDK 依赖）——复制/全选/粘贴等系统文本菜单从英文变中文，全 App 生效。
- 验证：analyze 0 问题 + 209 测试全过。

### 改进 设置里通知开关+通知类型（铃声/震动）可配置（用户点单"加通知开关和类型，类型可以是铃声、震动之类"）
- 通知总开关已有；本次把单一"提示音（默认/静音）"升级为**铃声、震动两个独立开关**（我的页，通知开启时显示）。
- 技术四渠道：Android 渠道属性建后不可变 → 预建 铃声+震动/仅铃声/仅震动/静默 四渠道，发通知按当前组合选，切换即时生效；重要性全部 high（横幅弹窗始终有，配置的只是响/震）。
- 旧 notificationSoundMode 自动迁移（'silent' → 铃声关）；通知方式持久化。
- 验证：analyze 0 问题 + 209 测试全过。

### 改进 通知锁屏可见（用户晒锁屏通知截图："这种通知也要"）
- zremote 任务通知本来就是系统通知（同一通知栏/锁屏机制，样式一致：图标+标题+正文+时间）；本次显式声明锁屏完整显示（visibility: public），避免默认 private 在锁屏上被 conceal。
- MIUI 提示：若锁屏仍看不到，需系统设置→通知管理→zremote→开锁屏通知/横幅；省电策略改无限制（后台被杀是收不到的根因之一）。
- 验证：analyze 0 问题 + 209 测试全过。

### BUG-35 全项目通知轮询全部被桌面端拒绝（用户实测"没有通知"，桌面日志取证）
- 现象：装新包后无任何通知；桌面日志显示手机每 20s 一次 `zcode-task.listTaskList` **全部 FAIL**——`normalizeWorkspaceKeys` 对 undefined 调 `.trim`（TypeError）。
- 根因：`workspaceScopes` 要的是**工作区对象数组**（{workspaceKey, workspacePath, workspaceIdentity}，桌面 SY 同款形状；key 的口径是 workspaceIdentity?.trim()||workspacePath），我发了纯字符串数组——`ie()` 对字符串取属性得 undefined。
- 修复：scopes 改为按 workspaces 构造对象数组；轮询失败加 5 分钟节流日志（App 内可诊断）；探针 test/manual_global_notify_probe_test.dart 同步修正（配对被手机占用时跳过，空闲时可复跑）。
- 验证：analyze 0 问题 + 209 测试全过；装新包后桌面日志应出现每 20s 一条 `zcode-task.listTaskList OK`。
- 教训：新接口第一次接入就要实测（这次桌面 UI 自己不用这个方法，没有现成调用可参照；早跑探针就能在上线前抓住）。

### 架构改进 流式区出列表（用户指路：参考 D:/zcode-dev 的 Flutter 项目，它的滑动没问题）
- 借鉴点（zcode-dev app/lib/chat_scroll_facade.dart + chat_page 注释原文）："reverse 列表锚点钉底，流式区在列表内长高会把历史内容顶走=「滚来滚去」的根因；搬出来后长高吃自己的固定空间，列表纹丝不动"。
- zremote 的对应改造：最后一条 streaming 的 assistantText 行**摘出列表**，渲染在列表与队列栏之间的独立流式面板（_StreamingPanel）；落定后回列表。效果：①流式期间列表内容零变化，逐帧锚定补偿退出主战场（BUG-27/28/32 家族的共同根因被拆除）；②阅读位置稳定（面板长高只压缩列表视口顶边，offset 不动=读的东西不挪）；③与 zcode-dev 同一渲染管线（MemoMarkdown streaming→落定），落定瞬间不跳变。
- 保留：翻页加载、出错卡、回显交接、回底按钮、未读徽标全部原位；锚定补偿机制保留服务离散扰动（面板出现/消失/翻页），不再承担逐帧流式。
- 已知边界：thinking/reasoning 行与工具卡的状态更新仍在列表内（增长幅度小、折叠可控）；极端长文的流式面板会占用大半屏（与参考实现一致，落定即恢复）。
- 验证：analyze 0 问题 + 209 测试全过。真机重点回归：①流式期间上下滑动是否跟手不飞；②翻历史停留时新回复流式是否不再拉动视野；③落定瞬间是否平滑。

### 修复 断档重同步并发风暴——聊天记录自己快速翻回最开头（用户真机报障）
- 现象：长会话里滑到历史尽头（触发翻页）后，聊天记录**自己快速翻回最上方**，视口像被连拽十几次。用户初步观感是「滑动没问题」，实际是翻页后瞬间的视口重置。
- 取证：桌面日志 `2026-09-12.log` 17:49:21 —— 同一批**并发 12 次** `resyncSessionsIndexV4`（耗时 650~678ms 整齐一致 = 同时起跑）+ 1 次 `resyncConversationV4`，全部带 `forceSnapshot: true`。同时 `17:49:19.372 conversationRowsRangeV4 OK (31.9ms)` 是翻页请求，时序上紧邻风暴 = 翻页是触发源。
- 根因：`_SubBase._resync()` **无并发保护**。服务端翻页/批量重发时，帧先进入 40ms 微批队列（`_scheduleBatchNotify`），定时器回调里 `for (final frame in _pendingFrames) _applyFrameImmediate(frame, onGap: onGap)` **逐帧应用**；每帧的 `fromSeq` 都对不上本地 `seq`（gap 分支只 `return` 不推进 seq）→ 每帧真发一次 resync。**级联重试风暴**：不是丢数据（重同步最终会正确对齐），是重复执行把视口抖动放大成「自己翻到最开头」。
- 修复（`5c18032`）：① 新增 `ResyncGate` 单飞闸（纯逻辑类，仿 `FollowLock` 便于单测）——一次重同步在途时后续 `onGap` 直接合流；自身重试链（`attempt>0`）不碰闸，避免把闸放跑。② gap 分支**保持不推进 seq**：seq 语义是「已应用」的序号，推进会把后续合法帧误判成 gap（这一点先按「推进 seq」改过一版，被 `protocol_test.dart:205` 当场拦住，遂回退）。
- 验证：flutter analyze 0 问题 + 213 测试全过（新增 4 个：`ResyncGate` 三态 + gap 不推进 seq 的语义锁定）。真机复测点：滑到历史尽头记录不应跳回顶部、桌面日志同一时刻不应出现并发多条 resync、翻页本身仍能正常加载更早内容。
- 教训：① **批量路径 + 无闸的重试**是最容易出并发风暴的组合——凡「一批事件各自可能触发同一个恢复动作」的地方，恢复动作必须有单飞/去重。② 用户在真机上给的症状描述（「自己翻到最开头」）比日志更早指出方向：**视口被重置 ≠ 滚动代码有 bug**，先查「谁在整份替换数据」。③ 改语义前先跑测试——`protocol_test.dart` 当场拦住了一个看似合理实则错误的「优化」。

### BUG-36 交互审批面板完全无法交互（用户真机报障：选项选不了、文字输不了、提交按不了）
- 现象：AskUserQuestion 面板（"ZCode 需要你的输入"，ExitPlanMode 单选）整张卡无响应——点选项不亮、其他…输入被清、提交恒灰。
- 根因：`state.pendingInteractions` getter 每次读取经 `castMapList` 生成**新拷贝**；`_QuestionsView.didUpdateWidget` 用**列表实例身份**判断"交互是否变了"——会话运行中任何一次页面刷新（流式帧/定时器/键盘）都让新拷贝 ≠ 旧实例 → `_rebuild()` 清空已选/已填/展开态 → 点选即被重置、输入框销毁重建失焦、`allAnswered` 恒 false 提交恒灰。面板不是死了，是每次交互后立刻被重置。
- 修复：①didUpdateWidget 改按**内容**比较（jsonEncode(questions)+allowFreeText），同一交互不重置；②面板循环给 InteractionCard 加 interactionId 稳定 ValueKey。
- 验证：analyze 0 问题 + 214 测试全过；待真机复测（点选项应亮、其他…可输入、提交可回传且会话继续）。
- 教训：**getter 每次返回新拷贝的地方，下游一律禁止用实例身份做"是否变化"的判定**——身份恒变，任何依赖"没变"的优化/状态保持都会被打穿。

### 滚动稳定性收尾：发送不再拽视口 + 弹道期自动跟随禁手（用户"发送/连续滑动后乱划"）
- 扰动源 1：`_send()` 写死"发送=解锁跟随+animateTo(0)"——翻历史时发消息被强行甩到最新端。改为**发送不改变视口**：人在底部自然跟随；人在历史处停原地，新回复走未读徽标。
- 扰动源 2：`_maybeAutoScroll` 无弹道保护——惯性滑动中被 AutoFollowMath 的 animateTo 抢驱动。补 `userScrollDirection != idle` 禁手（对齐锚定通道既有保护）。
- 滚动 doctrine 收敛为一句话：**程序化滚动只允许发生在 (a) 用户在底部跟随新内容，(b) 用户明确点了回底按钮；其余一切情况（发送/弹道/手势/翻页）一律不动视口。**
- 验证：analyze 0 问题 + 214 测试全过；待真机滑动回归（连滑/急停/发送/翻页四场景）。

### BUG-37 滚动锚定两处残留：快照重同步未断补 + 全链缺 hasClients 防护（例行审计发现）
- 根因 1（滑向历史端的残留口子）：BUG-32 只给「翻页」立了纪元标记，但
  **resync 快照不走翻页**——快照类帧整体重置 rows，服务端重发的窗口可能
  和原来完全不同；总高增量分不清「最新端长高」和「行集合被换过」，后者
  照样按步长去「追」＝用户停在历史区时列表持续往历史端滑。深读历史时
  恰逢下拉重同步/降级恢复/看门狗重同步即触发。
- 修复 1：`_anchorAgainstGrowth` 记最旧行 rowId（`_anchorOldestRowId`），
  最旧行变化 = 结构性变化，只重定基线、清欠账、不补偿；翻页纪元分支
  同步翻篇最旧行基线。
- 根因 2（崩溃隐患）：`_maybeAutoScroll`/`_anchorAgainstGrowth`/
  `_applyAnchorGrowth`/键盘延迟回底四处直接摸 `_scroll.position`，
  controller 未附加（页面收尾/列表暂时不在树上）时直接抛 StateError；
  `_maybeAutoScroll` 的 postFrame 从 build 无条件排，连 `mounted` 都没查。
- 修复 2：四处补 `hasClients` 防护 + `_maybeAutoScroll` 补 `mounted`。
- 验证：analyze 0 问题 + 214 测试全过（2026-09-13）。待真机回归：长会话
  读历史时触发下拉重同步/断线恢复，视口应钉住不动。
- 教训：「按增量补偿」的方案，每一种**不经流式增长**的内容变化（翻页、
  快照、行集合替换）都得有断补标记——BUG-32 断了翻页这个环，resync 这个
  环还开着；防护断言（hasClients/mounted）要放在**拿 position 之前**，
  放在 hasContentDimensions 判断后面已经晚了。

### 改进 多端一致性：会话列表以服务端为准（用户裁定，2026-09-13）
- 背景：用户多端（手机/平板/PC）操作，发现列表互不一致。根源是三个**本地层
  在冒充事实源**：①持久化删除墓碑（`removedTaskIds` 进 SharedPreferences，
  断线不清）——本机永久隐藏服务端还活着的会话，各端各存一份必然各说各话；
  ②`loadTasks` 失败被吞成空列表——一次网络抖动看起来像"会话全没了"；
  ③归档集合跨工作区/重连不清——旧项目的会话被误判已归档。
- 修复：①墓碑降级为「进行中 + 对账」乐观层 `_deletingTasks`（仅内存）：
  删除时乐观隐藏，`sweepDeletions`（纯函数，task_sort.dart）对账——服务端
  没有=确认删干净；服务端还有且过 8s 宽限=删除未生效（如旧版桌面拒删），
  **恢复显示**；启动即清旧墓碑库。②listTasks 失败 → 保留缓存 + `tasksStale`
  标记 + 3s~30s 退避重试 + 列表页「同步中断，列表为本机缓存」横幅；置顶列表
  失败沿用上次置顶态。③归档集合在断开/换工作区/回滚挂载时清空。
- 边界：模型意图（sessionModels/守恒器）不属"会话存在性"，保留——它防的是
  服务端被 PC 端 registryFallback 污染，属另一条线（BUG-07）。
- 验证：analyze 0 问题 + 218 测试全过（新增 sweepDeletions 4 测）。
  待真机验证⑨⑩（见 AGENTS.md 交接摘要）。
- 教训：缓存与事实源的边界要用**退出机制**守——乐观补偿层必须带"待确认"
  状态和对账出口，否则补偿本身会变成新的不一致源；「吞错成空」是最伪装成
  bug 的 bug，失败时保留缓存并标记陈旧，比清空诚实。
- **第二批（同日，用户补裁定"所有会话操作写通服务端，下次加载两端必一致"）**：
  ①`_mergeIndexIntoTasks` 只增补已有卡片，不再把「索引有、列表没有」的会话
  重建成卡——那是幽灵复活的口子（跨项目删除只摘了列表条目时，别端下次加载
  会变回来）；新会话的及时可见改由 createSession 成功后主动 loadTasks 承担。
  ②抽屉新增「从服务端拉取最新」：`ZApp.pullLatest()` 整表重拉会话列表+归档+
  「全部对话」视图（若在）+ 索引流强制重同步。其余操作（置顶/重命名/归档/发
  消息/切模型等）核查确认均已写通服务端，置顶已带失败回滚、重命名先服务端后
  覆盖，无需改动。验证：analyze 0 问题 + 218 测试全过。
- **第四批（同日，用户报障三连，裁定"状态也要跟随服务器"）**：①「全部对话」
  视图原来吃的是**连接时刻的 bootstrap 快照**——索引推流只增补单项目列表，
  相位永远停在打开 App 那一刻（运行中显示空闲久不恢复），归档会话也混进
  主列表与归档 tab 重复。新增 `_composeVisibleAllTasks` + `_enrichFromIndex`：
  该视图同样吃索引实时增补 + livePhase 覆盖 + 归档/已删排重 + 删除进行中
  过滤，与单项目视图同一条纪律。②「全部对话」里点开别的项目的会话会把
  用户拽进那个项目分类——`openWorkspace` 加 `preserveView` 参数，切桥只为
  订阅会话，列表视图原地不动。③删除被拒恢复显示时，「全部对话」也补回
  该卡。验证：analyze 0 问题 + 218 测试全过。
- **评审修复（同日，会话列表整块复审）**：①索引增补会踩掉重命名覆盖——
  索引里还是旧标题（非空）时每帧合并都把新名踩回旧名，`_titleOverrides`
  形同虚设；两处增补表达式（`_mergeIndexIntoTasks`/`_enrichFromIndex`）
  改为本地覆盖优先。②「全部对话」每帧全量重组——索引流无微批、每帧都
  通知，整机卡片集合在单项目视图里也跟着白烧；改为主仅 `viewingAllProjects`
  时重组（切回该视图由 `loadAllProjectTasks` 兜底）。复审确认无恙的：任务
  查找三集合兜底、取消归档跨项目归位、置顶失败回滚、删除对账跨项目语义。
  已知边界：其他项目的归档会话在「全部对话」仍可能显示（本地无法得知
  别的项目归档状态，随 bootstrap 带归档标记时会被滤掉）。验证：analyze
  0 问题 + 218 测试全过。
- **第五批（同日，探针实测推翻第四批的归档语义假设）**：用户报「服务端
  归档比本地多很多、全部对话也比本地多」。只读探针（逐项目直发
  listTasks/listArchivedTasks + bootstrap 比对）实测：整机 41 条会话，
  **36 条带 archived==true**（连正在运行的会话都带）——桌面端的 archived
  是「会话已关闭」的生命周期标记，**不是「用户收起要隐藏」**，桌面主列表
  照样显示它们。第四批把 archived 从「全部对话」滤掉的方向反了。修正：
  ①「全部对话」不再过滤 archived（服务端有什么显示什么，deleted 仍滤）；
  ②归档 tab 改**跨项目聚合**——原实现只查当前桥一个项目（36 vs 本地几个
  的差值就在这），现逐项目并发直发 listArchivedTasks 合并，与桌面端全局
  归档对齐。单项目主列表的 listTasks 服务端本就只回活跃会话，不用动。
  验证：analyze 0 问题 + 218 测试全过。探针入库
  test/manual_server_list_audit_test.dart（ZREMOTE_PROBE_LINK 门控，只读）。

### 改进 图片流程对齐参考端：系统相册 + 静默预上传（用户裁定，2026-09-13）
- 背景：用户拿 `D:\zcode-dev`（com.zcode.app）的图片流程做参照，指出三项差距：
  ①入口弹层缺「拍照」（本端只有「添加图片（相册）/添加文件」）；②选图走的是
  `FilePicker(type: image)` = **文件管理器**，参考端是系统相册（照片/影集多选）；
  ③**回显里不该出现上传过程**——本端 `_setStage` 会往气泡里写「读取 xx…」
  「上传 xx 45%」还挂一个「取消」入口，参考端从弹窗到选图到回显全程无提示。
  用户同时明确：**最终回显形式（一张一张缩略图）保持不变**。
- 修复：①弹层三入口对齐（拍照/从相册选择图片/上传文件(PDF/文档/任意)，
  `_OptionRow` 补可选前导图标）；②相册走 `image_picker.pickMultiImage`、
  拍照走 `pickImage(source: camera)`，两者汇入 `_addPicked`（XFile → PlatformFile
  带字节，沿用 9 个 / 100MB 上限与超量提示）；③**静默预上传**：选中即
  `_kickPreUpload` 传（`_attachRefs` 存 ref、`_attachInflight` 去重），发送时
  命中 ref 直接引用、没命中才现场补传；回显气泡上传期间只显示「发送中」。
- 关键约束：附件 ref 是**会话域**的——A 会话传的 ref 拿去 B 会话发是无效引用，
  所以复用必须同时满足「有结果」+「同一个会话」，判定抽纯函数
  `attachUploadPlan`（composer_logic.dart）并 +3 测试。
- 边界：草稿会话（`_sid == null`）选图时不预上传（还没有会话可挂），发送建会话
  后走现场上传；预上传失败不打扰用户（只记 ZLog），发送时会重试并如实回显失败。
  `attachmentPut` 的 `isCancelled` 取消钩子保留在协议层（已无 UI 入口）。
- 验证：analyze 0 问题 + 221 测试全过（新增 attachUploadPlan 3 测）。
  待真机验证：拍照/相册两条入口、多发几张图时发送是否顺畅。

### 性能 会话加载变慢：四条默认路径上的重复开销（用户报障，2026-09-13）
- 背景：用户反馈「会话加载又变慢了」。机制在代码里早有实测记载
  （`app_controller` `_foregroundBusy` 注释）：桌面端 channel RPC 走**同一个
  队列**，后台补拉会排在用户操作前面（曾实测「4 个 getTaskTokenUsage 和
  用户的 subscribeConversationV4 一起等了 5.1s」）。所以「变慢」= 后台 RPC
  变多了，而今天「服务端为准」那几批新增的开销**全落在默认路径上**
  （冷启动现在默认进「全部对话」= 最贵的视图）。
- 四处根因与修法：
  ① **索引帧逐帧全量重组**（`refreshFromIndex` → `_mergeIndexIntoTasks` →
     `notifyListeners`）：流式期间索引每帧都来，每帧把整机卡片重建一遍
     + 整页 setState。修为 **200ms 微批 + `cardsSignature` 变化检测**
     （可见字段没变不通知）；通知用的相位变迁检测拆出来**仍然逐帧**跑，
     免得一闪而过的相位被合并掉漏报。
  ② **token 角标首灌打 41 次 RPC**（`loadAllProjectTasks` →
     `_fetchTaskTokens(from: allProjectTasks)`）：整机 41 张卡首次全 due
     （`tokenFetchDue` 没拉过必拉），4 个一批 = 11 批串行。修为
     `tokenFetchTargets` 纯函数：**没拉过的按预算限流（默认 12 张）**，
     列表已按置顶+活跃倒序 → 先补第一屏看得见的；过期重拉不受限。
  ③ **归档在每次开工作区全量扇出**：`_openWorkspace` 无条件
     `loadArchivedTasks()`，而它是跨项目聚合 = **每个项目一次** RPC（7 条），
     主列表根本不用它（服务端 listTasks 本就只回活跃会话）。改为**懒加载**：
     只在用户点归档 tab / 硬同步时 force 拉。
  ④ **点一下图钉 = 1 次 bootstrap + 7 次 listPinnedTasks**：`_setPinned`
     在动作后又整机刷一次；而 `setTaskPinned` 本就是乐观的（`_pinOverrides`
     已写进两张列表 + 失败回滚），这次刷新纯属白烧。删掉。
- 附带发现（未改，记在这）：`_archivedTaskIds` 是**只写不读**的死状态
  （7 处写、0 处读）——归档排重实际靠服务端 listTasks 不返归档。
- 验证：analyze 0 问题 + 228 测试全过（新增 cardsSignature 3 测 +
  tokenFetchTargets 4 测）。
