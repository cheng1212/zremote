# 双智能体协作看板
（每次改动看板，顺手更新本行：最后更新：写手 · 2026-09-11 14:45）

## 角色登记
- 写手：ZCode 会话（本会话）· 2026-09-11 02:05
- 审核者：ZCode 会话（另一会话）· 2026-09-11 01:58

## 本轮目标
（用户原话）继续打磨现有功能
（用户 04:10 追加，最高优先）模型切换黏性修复：会话切过模型后重启永远保持；切换卡顿要查

## 项目档案
- 路径：D:\tools\zremote ｜ Git：有 ｜ 主分支：master ｜ 怎么跑：flutter analyze + flutter test 验证；build-apk.ps1 / build-flutter-apk.ps1 打 APK
- 现有开发分支：develop（写手已确认沿用，不另建 collab/dev · 2026-09-11 02:05）

## 当前状态
- 持锁方：无
- 当前任务：任务#6 完成（①②已办结）；#9（provider id 修正）待审核；新 APK（14:38，含 #7/#8/修复）已投局域网 http://192.168.31.194:8777/app-release.apk 待用户真机验收。探针归属答复：探针为写手所建（用户供链接授权），已随 594ecab 提交入库
## 任务队列
（粒度约定：一个任务 = 一个可独立验证的小改动，不把整轮目标拆成一个巨型任务。）
| # | 任务 | 状态（待办/进行中/待审核/通过/返工） | 备注 |
| 6 | 模型切换专项收尾（对应 BUG-07 与用户三点需求）：①查桌面日志确证夜间批量回退成千问的机制；②真实环境探针验证"移动端切换传导+不被刷回"；③按结果补护栏（已由 #7/#8 承接） | **通过（①②办结，探针实证）** | ①桌面日志确证：registryFallback 是夜间批量回退机制（provider 健康列表变化→自动切 listModels()[0]=欠费 qwen3.8-flash；桌面「同步当前模型」1056 次/天以工作区 modelCurrent 为源推送）。②探针实证（test/manual_setmodel_probe_test.dart，一次性会话自删）：普通 switchModelConfig 用**正确 provider id**（builtin:bigmodel-coding-plan）→ accepted 且 63s 不被刷回——移动端切换链路通畅，新包 #3 逻辑有效；runtimeModel 参数是 host 内部完整运行时描述（provider/model/revision/generatedAt object），移动端不可自拼；workspace/setDefaultModel 未暴露给移动端（通道枚举全 miss）。③已由 #7/#8 承接。意外收获：发现并修复 BUG-08（#9） |
| 9 | BUG-08 修复：默认 GLM 的 provider id 写错——start-plan 不在服务端注册表，新包上"套默认/守恒纠正"必 notInRegistry 静默失败（写手引入） | **待审核** · commit `594ecab`+`11d117e`（develop） | 探针实测发现（zod 报 provider.notInRegistry；prepareWorkspace configOptions 实证 GLM=builtin:bigmodel-coding-plan）。修复：常量改 coding-plan；坏 provider 的自动记录（含 chosen:true，系统按坏常量写的）视同未选择迁移。附 3 个探针入库（ZREMOTE_PROBE_LINK 门控）。自检：analyze 0 问题 + 114 测试全过。教训：provider id 以 prepareWorkspace 返回为准，不信本地 config.json |
| 7 | 会话功能差集盘点（ROADMAP 批次一~四 vs 代码）：批次一~三已全实现（retryTurn/compact/plans/技能/斜杠命令/反馈/编辑重发/分叉/暂停/fileChanges），真差集=模型基线漏防 qwen3.8-flash + 无人值守漂移窗口 | **通过（已合并 master · merge 1ac751c）** | 修复：①model_defaults 基线集合加入 qwen3.8-flash（2026-09-11 夜间实测回退值，桌面库 5 会话中招；此前只防 qwen3-max），serverFallbackModelId→serverFallbackModelIds 集合 + isServerFallbackModel 单一判定助手；②app_controller 新增 reconcileTaskModels：loadTasks 后按 listTasks 自带的每会话 model 字段批量对账，基线值即纠正（本机意图记录优先，无记录用首选默认），真实模型不发 RPC。桌面库取证：SELECT model FROM tasks GROUP BY → 5 个会话在 qwen3.8-flash。自检：analyze 0 问题 + 113 测试全过（2026-09-11） |
| 8 | 发送失败一键切回 GLM 重试（欠费基线死亡护栏，BUG-07 退路） | **通过（已合并 master · merge 1ac751c，与#7 同 commit）** | _EchoBubble 加 onRetryWithDefault 按钮「切 GLM 重试」：switchModel 到首选默认 + recordSessionModel(chosen:true)（显式点按算用户选择）+ _retryEcho；草稿态（无会话）直接改 draft 模型值。失败提示文案不变 |
| 3 | 模型切换两问题：①切换卡顿 ②切过的模型重启后回退英伟达（应永远保持用户切换值） | **通过（已合并 master · merge 0903b42）** | 改动：lib/ui/chat_page.dart +38/-3。①`_applyModel` 乐观更新：先 _patchConfig 再发 RPC，失败回滚+提示；②`_reconcileSessionModel` 记录≠服务端时分支处理：服务端=空/千问Max/英伟达系 → 真回退按本地补发（原逻辑），服务端=别的真实模型 → 采纳为新意图并 recordSessionModel（`serverIsFallback` 判定复用 model_defaults 常量）。用户已确认只在移动端切换。自检：analyze 0 问题 + 112 测试全过（2026-09-11）。局限：两台设备都显式切过同一会话时以服务端最后一次为准；同一会话勿两台同时开着切 |
| 5 | 会话删除复活修复：手机删掉的会话在平板复活。用户供《协议接口参考》文档解开悬案：`deleteTask`（task 通道）只摘任务列表条目，会话本体要调 zcode-agent 通道 `deleteSession`——此前没调，sessions-index 流里会话还活着，无墓碑的设备就把它重建出来 | **待审核** · commit `1766677`（docs）+ `cba77df`（fix）（develop） | 改动：docs/协议接口参考.md 新增归档（+151）；lib/protocol/conversation.dart `deleteSession()` 新增；lib/state/app_controller.dart deleteTask 补调（best-effort，失败只记日志）。坑已按规约记入 docs/LESSONS.md（建板以来第一条）。自检：analyze 0 问题 + 112 测试全过（2026-09-11）。真机验证项：手机删→平板刷新不再复活 |
| 4 | 默认模型从英伟达 nv-nemotron-ultra 改为 GLM 5.3 Flash（用户 04:20 直接下单） | **通过（已合并 master · merge 8c79938）** | 改动：lib/state/model_defaults.dart、test/model_defaults_test.dart。provider→`builtin:bigmodel-start-plan`，model→`GLM-5.3-Flash`（id 取自桌面 config.json，thought=high 经桌面日志 431 处 `GLM-5.3-Flash$high` 证实合法）；`nv-nemotron-ultra` 加入 legacyPreferredModelIds——守恒器自动写入的旧默认记录（无 chosen）迁移到新默认，显式选过英伟达的（chosen:true）不动。自检：analyze 0 问题 + 112 测试全过（2026-09-11） |
| 1 | 流式输出时用户已滚离底部 → 位置锚定：内容继续更新但视口绝不漂移（无论手指是否在屏上）；滚回底部才恢复自动跟随 | **通过（已合并 master · merge 5dd7512）** | 改动：lib/ui/chat_page.dart +62/-1。实现：`_anchorAgainstGrowth` 挂在既有 post-frame `_maybeAutoScroll` 里，按「内容总高增量（maxScrollExtent+viewportDimension）」反向 jumpTo 抵消（键盘弹收自动抵消不误判）；拖动中攒 `_pendingAnchorDelta` 欠账，`_onScrollGestureEnd` 停稳 post-frame 一次补；jumpTo 前 clamp 收敛；换会话重建基线。自检：flutter analyze 0 问题 + flutter test 112 全过（2026-09-11）。计划审核建议 1/2/3 均已落实 |
| 2 | 聊天记录代码块：去掉内部滚动完整铺开（多长都全显示），超长行软换行，解决「看不全」和「代码块吞掉上下滑手势」两个问题 | **通过（已合并 master · merge a86e67e）** | 改动：lib/ui/rows.dart +9/-16、lib/ui/composer_logic.dart +4/-4。实现：`_CodeBlock` 正文删掉 ConstrainedBox(maxHeight:360)+垂直/横向双层 SingleChildScrollView，改 SelectableText 软换行完整铺开（代码块零拦截手势）；`maxCodeBlockChars` 2万→10万（防 MB 级载荷卡列表的保险丝，复制仍拿全文）。自检：flutter analyze 0 问题 + flutter test 112 全过（2026-09-11）。用户授权免计划审，代码照常送审 |
## 审核记录
（格式：### [YYYY-MM-DD] 任务#N · 第R轮 · commit <hash>，下附结论与问题清单）

### [2026-09-11] 任务#7 + #8 · 第1轮 · commit ad9b8cd（含 docs 6cda3ca / db43ad1）
- 结论：**通过，已合并**（merge 1ac751c 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 113 全过（探针文件 env 门控自动 skip，2026-09-11 13:58）。
- 四件事：① 达成目标——qwen3.8-flash 入基线集合（serverFallbackModelId→Ids 集合 + isServerFallbackModel 单一判定，chat 页对账同步复用）；reconcileTaskModels 列表级批量对账（基线值按本机意图纠正/无记录套 GLM，真实模型不发 RPC，纠正不写意图记录保持迁移语义）；#8 一键切回 GLM（switchModel+recordSessionModel(chosen:true)+重试，草稿态改 draft 值）；② 副作用评估——conv 判空/空 model 跳过/逐任务 try-catch 齐全；批量对账纠正失败时本地 t['model'] 已改而服务端未改（建议级：下次打开会话由 chat 页对账兜底，可接受）；AGENTS.md/BUGFIXES.md 为纯文档；探针文件 env 门控无凭据落盘；③ 提交信息清楚（docs 与 fix 分离、BUG-07 编号贯穿台账）；④ 实跑通过。
- 建议（不阻塞）：①reconcileTaskModels 纠正失败时本地列表值与服务端暂不一致，可在 catch 里回滚 t['model']（或留待 chat 对账兜底即可）；②批量对账在会话数多时会连发 RPC，个人用可接受，量级上来再考虑节流。

### [2026-09-11] 任务#5 · 第1轮 · commit 1766677 + cba77df
- 结论：**通过，已合并**（merge d4268eb 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 112 全过（2026-09-11 03:52）。
- 四件事：① 达成目标——删除根因补全：ConversationV4 新增 `deleteSession`（普通命令，注释引用协议文档），`deleteTask` 在 task 通道删除后 best-effort 补调，失败仅记日志并在日志文案写明风险（他端索引可能复活）；文档归档 151 行为用户提供的实测参考，只有 URL/帧格式模板、无真实 sid/hash，不触「密钥不入 Git」红线；② 副作用评估——`conv` 判空护栏有；deleteTask 被服务端拒绝时仍会尝试删会话本体，但用户意图就是删除且失败路径本就照常隐藏，方向一致；③ 两条提交信息清楚（docs 与 fix 分离）；④ 实跑通过。
- 建议（不阻塞）：真机验证「手机删→平板刷新不再复活」是本任务唯一的运行时验收项，请用户在两台设备上实测。

### [2026-09-11] 任务#3 · 第1轮 · commit e84e7cf
- 结论：**通过，已合并**（merge 0903b42 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 112 全过（2026-09-11 03:40）。
- 四件事：① 达成目标——卡顿根因（await 往返后才 patch）已消除，改乐观更新+失败回滚；回退误判根因已消除，`serverIsFallback` 复用 model_defaults 常量（空/千问基线/nv 历史默认）判定，其余服务端模型采纳并回写本地记录，多设备 ping-pong 闭环；② 副作用评估——采纳分支写记录不带 chosen，与任务#4 迁移语义一致（后换新默认时可正常迁移）；回滚只回填非空旧值，极端情况下原值为空时新值保留（可接受，均有 _flash 提示）；③ 提交信息清楚；④ 实跑通过。
- 遗留（写手已留档）：两台设备都显式切过同一会话时以服务端最后一次为准；同一会话勿两台同时开着切。真机验证项：切换模型立即生效无卡顿、桌面端切换后手机端重启不再被打回。

### [2026-09-11] 任务#4 · 第1轮 · commit d09a777
- 结论：**通过，已合并**（merge 8c79938 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 112 全过（2026-09-11 03:26）。
- 四件事：① 达成目标——默认换 GLM 5.3 Flash；迁移策略正确：`nv-nemotron-ultra` 进 legacyPreferredModelIds 只迁移守恒器自动写入的记录（无 chosen），显式选过英伟达的（chosen:true）新增测试明确保护；② 副作用评估——thought=high 有桌面日志佐证合法，`nemotron-3-ultra` 旧迁移项保留，改动收敛在 model_defaults 一处 + 测试同步；③ 提交信息清楚（做了什么+迁移语义）；④ 实跑通过。
- 无问题清单。

### [2026-09-11] 任务#2 · 第1轮 · commit a38cf2f
- 结论：**通过，已合并**（merge a86e67e 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 112 全过（2026-09-11 03:47）。
- 四件事：① 达成目标——删 360 封顶 + 双层内滚，`SelectableText` 软换行完整铺开，手势全交聊天列表；② 副作用评估——截断保险丝 2万→10万 字符仍在（复制拿全文不受影响），换会话/换行逻辑未触碰；③ 提交信息清楚；④ 实跑通过。
- 建议（不阻塞，已随合并交付）：10 万字符全铺开的单块布局开销不小，真机上遇到超大代码载荷时留意聊天列表滚动是否卡顿；若卡顿明显，回板写明再议（降阈值或分块渲染）。

### [2026-09-11] 任务#1 · 第1轮 · commit 1aed45d
- 结论：**通过，已合并**（merge 5dd7512 进 master，--no-ff；已切回 develop）。审核者实跑：flutter analyze 0 问题、flutter test 112 全过（+112，跳过 13，2026-09-11 03:10）。
- 四件事：① 达成目标——锚定逻辑与计划一致，三条建议全部落实（jumpTo 仅经 post-frame 调用点 2540 执行；clamp 收敛 + 0.5px 阈值防抖；拖动攒 `_pendingAnchorDelta` 停稳一次补、在底部作废）；② 无副作用——基线按会话隔离（`_anchorSid`），键盘弹收因用「总高增量」自动抵消，shrink（growth≤0）忽略，`hasContentDimensions/hasPixels` 有护栏；③ 提交信息清楚（[writer] 前缀 + 做了什么为什么）；④ 实跑通过。
- 遗留（移交用户）：「手指按住时视口绝不漂移」的真机手感需人工验证（拖动期间是先漂移、松手停稳后一次性补偿回去的折中实现）——真机上流式输出时按住列表试试，跳动明显再回板找用户裁决。

### [2026-09-11] 任务#1 · 计划审核（动工前）
- 结论：**通过，可动工**。根因判断与代码事实相符（`reverse: true` 列表，index 0 在最新端；`_maybeAutoScroll` 已有 `_atBottom`/`_scrollingByUser` 护栏，漂移确非 animateTo 所致）；maxScrollExtent 增量补偿是反向列表锚定的标准做法；粒度合适（一个可独立验证的小改动）。
- 问题清单（均为建议级，不阻塞动工）：
  1.（建议）`jumpTo` 不得在布局阶段同步调用——Δ 检测若发生在 build/layout 中，须用 `addPostFrameCallback` 延后执行，否则可能抛「jumpTo during layout」类异常。
  2.（建议）`jumpTo(pixels+Δ)` 前按 `[0, maxScrollExtent]` 收敛（clamp），防止极端时序下越界。
  3.（建议）手指按住拖动期间做 `jumpTo` 会与拖拽手势抢控制权，可能出现轻微跳动——实现后请在真机上验证「手指在屏上锚定」的手感；若跳动明显，可在看板写明理由找用户裁决折中（如拖动中先记忆锚、松手后一次性补偿）。
