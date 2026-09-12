# zremote 全量扫描矩阵（SCAN-MATRIX）

> 目标：每个功能 × 每个按钮 × 每个状态，逐一验证。发现即修，修必留痕。
> 状态图例：✅已验证正常 ｜⚠️有隐患（记录，暂不动）｜🐛有bug（已修/待修）｜⬜未扫到
> 每完成一格就更新本文件并随代码提交。

---

## 一、聊天页（chat_page.dart，5588 行）

### 1. 发送链 ✅ 已扫
- 回显生命周期（sending→sent/failed、慢达标记、列表上浮）✅
- 新会话模型就绪闸门+意图登记 ✅；重试复用已建会话不留孤儿 ✅
- 备注：失败后正文保存在气泡里（重试带回输入框），属设计决定，OK

### 2. 停止/暂停链 ✅ 本轮已审
- `_SendOrStop`/`_PauseOrResume` widget：与交付版逐行一致，未被动过 ✅
- `_stop()`/`_pauseResume()` 调用链：直发 RPC 无排队，`_backgroundGate` 只挡后台补拉 ✅
- `canStop` 来源：服务端快照 `control.canStop`，夜班 BUG-18 只动任务卡显示不动此处 ✅
- **结论：用户报的"停止/暂停不灵敏"不存在代码层回归**（用户已确认看错）

### 3. 滚动链（锚定/回底/翻历史/回到底）✅ 本轮已审 + GitHub 对照
当前实现：意图锁存（FollowLock，40/100px 滞回）+ 同帧合并 + 微动画补偿
（AnchorMath 1.5px 阈值/600px 上限）+ AutoFollowMath 回底限一屏。

与业界对照（stream_chat / flyerchat / zulip / shadcn message-scroller，
检索于 2026-09-12）：
- 底部检测+阈值 ✅（我们有，且滞回死区比常见实现更细）
- reverse:true 列表 ✅
- 用户滚动意图识别 ✅（锁存式，比常用 UserScrollNotification 更强）
- 追加用位移不用重建 ✅（合并桶+微动画，超过常见实现）
- **差距一条**：flyerchat 用「消息尺寸控制器」做内容锚定，能区分"高度变化发生在
  哪一条"；我们的像素增量法分不清位置——若**旧消息里的图片**加载导致历史区
  长高，会被误当流式增长补偿，视口会多移一段。影响面小（图片都在新消息近端），
  记录为 ⚠️ 已知局限，暂不重写（内容锚定改造风险大于收益）。
- 参照 enhancement（可选）：「回到最新」按钮加未读条数徽标（stream_chat 有）。

### 4. 弹窗链 ✅ 已扫（排队三选项/追问模式表/模式权限二段弹层/询问面板多选）
### 5. 附件链 ✅ 已扫
- 选图→读取→魔数嗅探 mime→本地预览→分片上传→进度→缓存直挂 ✅
- 备注：进度 setState 频率被网络 RTT 天然限频，不构成卡顿 ⚠️无碍
- 备注：大文件整读内存是已知限制（选择时 100MB 拦截）

## 二、任务页（tasks_page.dart，约 2100 行）
- 单条操作面板（置顶/重命名/复制ID/归档/删除）✅；批量框架（失败计数+双源刷新+清选）✅
- 跨项目数据源（bootstrap tasks + 逐项目置顶收集+缓存+空守卫）✅；形状已探针实测 ✅
- 🐛→✅ **BUG-19 已修**：全视图跨项目删除/重命名漏 ensureTaskProject（打错桥被墓碑掩盖）
- 工作区选择器/重命名别名/切换/新会话选项目 ✅（controller dispose 齐全、友好错误文案）
## 三、其余页面（profile/pair/usage/automations）✅ 主体已扫
### rows.dart 扫描中（1786 行）：1~380 ✅（MemoMarkdown 节流/MarkdownImage 限高/buildRowCard 全分支）
### rows.dart 380~760 ✅（launchHref 静默/代码块 BUG-02 终态/UserBubble 微信式/imageBlocks 画廊索引）
### rows.dart 760~1200 ✅（AttachmentView 加载链三层/宽高比 24px 缩略缓存/画廊 identical 定位/gaplessPlayback）
### rows.dart 1200~1786 ✅（ToolCallCard 展开态/SubagentCard/PlanPanel/计划解析多形状递归+词形归一）
### **rows.dart 全文（1786 行）✅ 覆盖完毕，零缺陷**
## 四、协议层
- crc32/link_params/value_codec/rpc_frames ✅ 逐行过（varint 越界防护、分片校验、僵尸重组 60s 清理都对）
- relay_client ✅（退避+抖动重连、心跳 ack 超时、poke 探活、KICKED、dispose 全清）
- remote_session ✅（request 超时清理、bridge generation 防错配、早到帧缓冲、viewState 上报）
- conversation.dart（1484 行）⬜ 精读中
- app_controller.dart 状态层：reconcileTaskModels/跨项目桥/phase 缓冲 ✅（BUG-19 修复时已深读相关路径）
### usage_page ✅（图表纯展示无触摸处理=设计选择；可选增强：柱状图点按按日过滤）
### 模式/权限应用链 ✅（草稿分支/乐观补丁/recordApprovalMode 持久化/错误反馈）
### 探针决策：manual_interaction_resolve_probe 会抢答真实弹窗——不盲跑；BUG-17 形状已有夜班实测证据，探针留作用户授权后的复验工具
### 模型选择器弹层 ✅（全部模型清除钮空态禁用/checkbox/前缀剥离显示）
### 自定义日期区间 ✅（showDateRangePicker+主题适配+取消保底+按需拉取 all）
### 交互面板提交链 ✅（buildAskAnswersPayload 纯函数有测试；busy/allAnswered 双门；_others 控制器 dispose）
### usage_stats 解析核心 ✅（parseUsageStats 守卫/topN+其他分桶/空日跳过/时区偏移串/17 单测）
### pair_page ✅（连接失败走 app 状态展示、成功才持久化链接、busy 守卫、_SunLogo 品牌页）
### suggestions.dart ✅（纯 Dart 前缀匹配，无状态）
### notification_logic ✅（首帧不响/活跃态守卫/等待交互独立判定）

### 任务面板三 Tab ✅（子代理/后台任务/定时任务；开面板自动 loadAutomations）
### 后台任务取消 ✅（cancellable 门控+错误反馈；模型二段弹层=点选不关层+完成按钮，见 feat-model-sheet-stay-open）
### image_cache.dart ✅ 全文（LRU 续命 remove+put 技巧正确/超预算拒入/逐出循环无误）
### 📝 文档漂移修正：图片缓存预算实为 64MB（代码默认），README/AGENTS/KNOWN-LIMITS 三处 32MB 已同步
### 通知触发链接线 ✅（index 帧驱动 detectTaskEvent→showTaskEvent；首帧只记录防轰炸/标题缓存/会话稳定 ID）
### chat_page scaffold 态 ✅（degraded 横幅重连/订阅失败重试/回底按钮解锁跟随）
### notification_service ✅ 全文（64 行；🐛→✅ BUG-22 已修：BigTextStyleInformation 空串致展开空白）
### theme.dart ✅ 全文（391 行零缺陷：对比度修正有记录/tapMin 全局化/PulseDot 断言规避/Semantics）
### 已知局限与可选增强 → docs/KNOWN-LIMITS.md（4 局限+4 增强+4 不可达+3 观察）
### 聊天页全文（5588 行）✅ 已全部覆盖
### composer_logic.dart ✅ 全文（AskAnswer 单/多选反悔语义/other 拼接契约/friendlySendError+friendlySwitchError 人话映射）
### 第一轮全量精读 + 第二轮反推复查 ✅ 完成（2026-09-12）
### breakdownSourceLabel ✅ 补测（已知映射+未知透传，+89 文件全过）
### automation_view.dart ✅ 全文（AutomationView/parseAutomations/AutomationRunView/倒计时——多形状兜底+可注入测试，零缺陷）
### activity_view.dart ✅ 全文（parseActiveWorks/streamingSubagents/BackgroundWorkView/parseSubagents——守卫齐全零缺陷，zod 字段来源注释详实）
### 桥栈生命周期 ✅（置空先行防半活/并行销毁 bestEffort 包裹/失败自清新桥）
### _UsageBreakdown/_UsageCumulative ✅ + 🆕 cumulativeKeyLabel 中文标签映射 + 键名弹性省略（未知长键不溢出）
### _UsageContext/_UsageCache ✅（max<=0 在 contextWindowUsage getter 源头守卫——候选假警报解除）
### usage 四件套 widget ✅（解析走 usageCacheSummary 纯 helper，null 收缩不渲染）
### usage 弹层 ✅（窗口条/缓存/分类/累计+压缩按钮会话门控）
### _ModelSheet ✅ 全组件（手风琴/词表快照优先/草稿回退/防连点/切换中提示/空态/完成按钮门控）
### 深水区·弹层族 ✅ 二段弹层/usage/任务面板/询问面板全数通过
### 🐛→✅ 两处小修：模式弹层降级词表补 edit/yolo（原缺两项）；任务面板自动化 Tab 补「重启」动作（与 automations 页一致）
### _ModelSheet ✅（手风琴分组/快照实时高亮/草稿回退/防连点/词表快照优先）（observer/监听对称、resume poke、IndexedStack 保活、showMainShell 推导）
### 插入弹层 ✅（文件/技能 $/斜杠 / 三区，空态文案齐全）
### 助手行菜单 ✅（复制/赞/踩/取消反馈/分叉/重新生成；分叉后直接开新会话）
### token TTL 字段 🐛→✅：全视图任务只带 status 不带 phase，TTL 分档失效落 5min 慢档——已双字段兼容（运行中恢复 30s 快档）
### token 角标 🐛→✅ BUG-20 已修：全视图取数源参数化（BUGFIXES 详录）
### 抽屉 ✅（6 项；🐛断开连接补了错误反馈；重连就地+只读快照降级路径审过）
### theme ✅（15 常量单一来源；Colors.white 均为彩底对比色非异味）
### openWorkspace ✅（前台门+防重入+失败全量回滚+静默重挂旧桥+await 防并发建栈）
### profile_page ✅（重连/断开 busy 守卫对称；断开成功不提示=列表转只读有横幅，合理）
### 通知开关 🐛→✅ BUG-26 已修：enabled 持久化（重启不再回默认开）
### 通知开关 ✅（NotificationService.enabled 单一写者=本开关，静态读无同步问题）
### casCommands ↔ 桌面端必带集合 🐛→✅ BUG-21 已修：补 reorderQueueItem（zcode.cjs 枚举对齐）
### reconnect/openPairPage ✅（就地重连+假活状态兜底 _disconnectedKeptShell）

## 五、接口差集矩阵 ✅ 已建 docs/INTERFACE-MATRIX.md
- 修正：此前"批次三全实现"结论有误——editUserQuery/applyFileRewind/editQueueItem/
  setTaskUnread/fileRewindPreview 只在常量表，**实际未接入**（grep 数到常量文件）
- 补齐排序：editUserQuery > applyFileRewind(+Preview) > ~~restartAutomation~~ > editQueueItem
- ✅ **restartAutomation 已接入**（app_controller + 自动化卡片「重启」按钮，重启后重载列表）
- ✅ **editUserQuery 已接入**（长按用户消息→「编辑重发」：预填原文→行级 CAS 提交→截断重跑→自动回底）
- ✅ **applyFileRewind + fileRewindPreview 已接入**（文件变更弹层底部「回滚本回合文件」：
  预览数量→确认→行级 CAS 提交→强制重同步；_lastTurnTarget 统一三接口目标回合）
- ✅ **editQueueItem + reorderQueueItem 已接入**（排队条每项加「编辑」「上移」；
  payload 形状取自桌面端 zod 源码，顺带挖到文档没写的 reorderQueueItem）
- setTaskUnread 🔴 否决：桌面端无此方法+客户端无未读 UI 面（INTERFACE-MATRIX）
- workspace/* 族与 session/setModel 确认不可达（探针+源码双证）

---

## 深水区·发送链深审（2026-09-12）

- 深审1 输入与草稿 ✅：多行(1~5行+newline键) ✅；草稿原先仅内存 → **已持久化**
  （stashDraft/takeDraft + SharedPreferences，单条 64KB 封顶，App 被杀不丢）🆕 7032b3c
- 深审2 回显气泡生命周期 ✅：sending→sent/failed、慢达 20s、取消🆕（上传阶段）；
  与正式行无缝交接 = visibleEchoes 按「文本计数 + 附件 ref 全匹配」双路确认，失败态常显
- 深审3 模型就绪闸门 ✅：10s 轮询快照、不符即失败不送死、超时抛错；重试复用已建会话
- 深审4 附件上传 ✅：读取→魔数 mime→本地预览→分片上传→进度→缓存直挂；
  🆕 上传取消（isCancelled 分片边界轮询，d120967）

### 深水区·深审5 ✅ 排队弹窗与 heldQueueDisposition（桌面 zod 枚举仅两值，客户端弹窗一一对应；点外部取消=中止发送也合理）

---

## 深水区·维度3/9 专项结论（2026-09-12）

### 维度9 多端一致性 ✅（判定+记录）
- 任务完成通知：每台设备各自弹一份——平台标准行为（同 WhatsApp/Telegram），**不修**。
- 墓碑范围：BUG-06 修复后服务端真删，他端自然消失，本地墓碑降级为"服务端异常时的保险"，✅设计闭环。
- 双端同开同会话：模型/状态后写者赢（对账闭环）；同时编辑重发等行级操作以服务端 CAS 裁决。KNOWN-LIMITS 已留档。

### 维度3 竞态专项 ✅（四路核对全有守卫）
- 切项目连点：openingWorkspace 门控 + await 串行（openWorkspace 取证 ✓）
- 重连窗口发送：sendCommand 先 waitHealthy(45s)，超时且降级才重试一次（conversation.dart:210/273 ✓）
- autoDrain 赛跑：编辑已消化队列项 → 服务端拒绝 → flash 提示（不静默）✓
- 守恒器 vs 批量对账同时纠正同一会话：双方目标一致（都指向意图模型），服务端 CAS 裁决，收敛无害 ✓

---

## 深水区·维度4 收官（2026-09-12）

- 工作区偏好读写容错 ✅（类型守卫+非空键+整体 try/catch）
- 持久化盘点收官：SP 持久化=草稿🆕/模型意图/墓碑/别名/上次工作区/通知开关🆕；
  内存合理=token(重取)/usage(重取)/livePhase(瞬态)/titleOverrides(服务端权威)

### UI轨2 ✅ 落地：消息行入场动画（_RowEntrance 渐显+微上滑 180ms，按 rowId 一次）——flyerchat/gen_ai 参照模式

---

## UI/逻辑轨收官批次（2026-09-12）

- 深审28 ✅ 行卡片 rowId 稳定 key（状态错位修复，90bdaea+68b75f8）
- UI轨3 输入区 ✅：附件条（删除钮/缩略图）、联想条（token 时上方 chips、点击插入）、图片/文件双入口（busy 守卫+48dp）
- UI轨4 弹层族 ✅：统一 20 圆角顶/SafeArea/高度 0.5~0.7 封顶/点外部关闭（画廊除外=黑底防误触）/拖拽关闭默认可用
- UI轨5 任务卡片 ✅：信息密度合理（标题/预览2行/chips行/角标）；滑动操作无=可选增强（长按菜单替代）
- UI轨6 三态 ✅：聊天（同步中/订阅失败重试/空会话引导🆕）、任务（加载/空/断线只读横幅）、automations（加载/空态引导）、usage（加载/错误重试/空）
- UI轨7 触觉 ✅ 基本一致（发送=selectionClick、停止/长按=mediumImpact）；可选：删除确认/模型选择补触觉
- UI轨8 深色模式 ⏳ 评估：ZT 为浅色硬编码调色板，深色=全调色板翻新+语义色分层，大工程；KNOWN-LIMITS 记录，等需求
- 维度4 持久化盘点 ✅ 收官（落盘 7 项/内存合理 4 项）

### 深水区·深审7+ ✅ 助手消息操作条落地（ChatGPT 式，源码 zod 实证驱动）
- 发现：桌面 Ty schema 要求行级 target 必带 entityId(strict)——客户端 4 个行级命令
  只发 rowId 全被 zod 拒（BUG-25，全族修复 be45fee + 5b2e…）。
- 新增：完成的助手消息下方常驻操作条（复制/赞/踩/重新生成/分叉），反馈态高亮；
  长按菜单保留（含撤销反馈入口）。
- 教训：行级 target 的唯一权威是桌面 zod（Ty），新行级命令接入前先对 schema。

### 深水区·BUG-27 ✅ 轻滑后视口飞行+卡住——根因两层（拖动欠账回放+弹道期补偿抢滚动），已修：拖动不记账+弹道保护
### 深水区·深审11 二轮 ✅ 参照实现对照（用户供 useChatScroll Vue 版）
- 三核心原则全部已体现：token≠必滚（锁存+阈值）、用户滚动最高优先（意图锁存）、
  历史加载保位（reverse 列表头部插入天然不位移——Flutter 优势）
- 🐛→✅ 吸收修复：回底按钮出现阈值 400→200px 且增加「距真实底部>100px」校验——
  原先 100~400px 中段翻历史两头空（无按钮也无跟随）
- 参照里其余项已天然覆盖：rAF 合并=post-frame 合并桶、bottom anchor=reverse 列表、
  overscroll contain=Flutter 默认、历史加载=mergeOlder 前插不位移
