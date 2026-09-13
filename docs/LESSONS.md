# zremote 踩坑日志（坑层·只追加）

> **规则**（项目记忆规约 §四）：
> - 只追加，永不修改、永不删除；记错了就追加一条 `[更正]` 简条，标题加前缀并指向原条目。
> - 追加前先按关键词查重：同一问题已有条目时，只追加一条 `[确认]` 简条（日期＋新证据）指向原条目。
> - 条目累计超过 15 条时，在下方「索引」建一行式索引（日期＋标题＋关键词）。
> - 每条必含「教训」；密钥/密码/token 明文禁止入档。
>
> **Agent 消费协议**：改动涉及环境、依赖、端口、构建、部署之前，先按关键词检索本文件。

## 索引

- 2026-09-13 锚定断补标记要盖住所有非流式增长——修了翻页漏了快照重同步 ｜关键词：锚定 快照 resync 重同步 oldestRowId 结构性变化 hasClients 滑向历史端
- 2026-09-11 删除会话复活——deleteTask 只摘任务条目，会话本体要调 deleteSession ｜关键词：删除 复活 deleteSession sessions-index 多设备
- 2026-09-11 仓库迁移后状态层文档未同步——文档命令指向封存目录 ｜关键词：迁移 状态层 封存目录 develop 分支 文档对账 AGENTS.md
- 2026-09-11 订阅带了 existing-only——冷项目运行时未启动必失败 ｜关键词：existing-only start-if-needed runtimePolicy 项目切换 runtime is not running app.asar 日志取证
- 2026-09-11 收尾动作（退订）用默认 30s 超时——拆桥栈被卡成串行 60s ｜关键词：退订 拆栈 超时 30s ipcUnsubscribeTimeout ChannelClient dispose fail-fast 切项目 白屏 openingWorkspace
- 2026-09-11 后台补拉和用户操作挤同一个队——用户点开会话排在自家 token 补拉后面 ｜关键词：后台让路 前台优先 _backgroundGate _asForeground 排队 getTaskTokenUsage subscribeConversationV4 打开会话慢 有的快有的慢
- 2026-09-11 判"已断开"不能用 session==null——语义是"还没连过"，会误伤裸 ZApp ｜关键词：已断开 session null 判据 只读快照 isReadOnlySnapshot 回归锁 widget_test 重连 就地断开
- 2026-09-11 判"卡顿"要用"排空暴发"判据，不能用"静默时长"——静默大半只是空闲 ｜关键词：排空暴发 drain burst 静默时长 空闲 off-peak-task 同刻完成 耗时完全相同 日志取证

---

## 条目

### [2026-09-13] 锚定断补标记要盖住所有「非流式增长」——修了翻页漏了快照重同步
- 现象：例行审计发现 BUG-32 的断环只盖了 loadOlder 翻页；resync 快照整体
  重置 rows 时不带任何标记，行集合被换过照样被当成视口漂移去补——停在
  历史区遇重同步（下拉刷新/降级恢复/看门狗）就持续往历史端滑。
- 根因：「按总高增量补偿」分不清增长来源，每一种非流式变化（翻页/快照/
  窗口迁移）都需要自己的断补标记；只给当时报障的那条链路立标记，同族
  链路漏网。
- 解决：`_anchorAgainstGrowth` 记最旧行 rowId（`_anchorOldestRowId`），
  变化即结构性变化，重定基线不补（BUG-37）。顺带补齐全链
  `hasClients`/`mounted` 防护。
- 教训：①断补标记的覆盖面要按「变化来源」枚举，不能按「报障来源」打
  补丁——与"同族写操作必须成族排查"是同一条纪律；②`_scroll.position`
  在 controller 未附加时直接抛，`hasClients` 防护必须放在取 position
  **之前**，放在 `hasContentDimensions` 判断后面为时已晚。
- 关联：lib/ui/chat_page.dart `_anchorAgainstGrowth`/`_oldestRowId`、
  docs/BUGFIXES.md BUG-32/37

### [2026-09-11] 删除会话"复活"——task 通道删除不删会话本体
- 现象：手机上删除会话成功（列表消失），平板上刷新后又出现；手机因本地墓碑永远看不到复活，掩盖了服务端没删干净的事实。
- 根因：`deleteTask`（task 通道）只摘任务列表条目；会话本体仍活着，desktop 的 sessions-index 流照常携带它，而客户端任务列表会把「index 里有、listTasks 里没有」的会话重建为卡片——无墓碑的设备（平板）就复活了它。
- 解决：删除时双通道都调——task 通道 `deleteTask` + zcode-agent 通道 `deleteSession`（协议参考文档证实该命令存在，不在 CAS 清单）。commit cba77df。
- 教训：①同一资源在两个通道各有一个删除入口时，只调一个不等于删干净；②本机墓碑类补偿机制会掩盖服务端语义缺陷，排查跨设备问题先怀疑"服务端到底删没删"，再看客户端隐藏逻辑；③协议是逆向的，新增能力前先查 `docs/协议接口参考.md` 的通道方法表（deleteSession 一直都在，只是没人知道）。
- 关联：lib/state/app_controller.dart `deleteTask`、lib/protocol/conversation.dart `deleteSession`、`docs/协议接口参考.md`、COLLAB.md 任务#5

### [2026-09-11] 收尾动作（退订）用默认 30s 超时——拆桥栈被卡成串行 60s
- 现象：切项目、或在「全部对话」里点别的项目的会话时，界面停在「正在打开工作区桥…」能卡几十秒（用户报"会话加载有时候有点卡"）。标题已经是「全部对话」却还在转圈——`viewingAllProjects` 与 `openingWorkspace` 同时为真，只有"全部对话→点别项目会话→openWorkspace"这一条路径会这样。
- 根因：`_disposeBridgeStack` 里 `await chat?.dispose()` 与 `await indexSub?.dispose()` 各自要 `await` 一次退订往返，而 `ChannelClient.call` 的**默认超时是 30s**，这两处都没覆盖；真正做 fail-fast 的 `Bridge.dispose()` 排在**最后**。链路僵死时就是 30s+30s 串行干等，之后才轮到开新桥。反直觉的是订阅本身只要 3ms——**慢的不是加载，是收尾**。
- 解决：①加 `ipcUnsubscribeTimeout = 1500ms`，两处退订（`dispose` / `_resubscribe`）都传它；②`ChannelClient` 加 `_disposed`，桥拆后新发起的调用立刻抛错，不再各自等满超时；③`_disposeBridgeStack` 改为两个订阅**并行**退订 + 收尾异常一律吞掉（`_bestEffort`）。链路僵死时拆栈从最坏 60s 降到 ≤1.5s。commit 见 BUGFIXES BUG-10。
- 教训：①**收尾动作绝不能放在用户可感知的关键路径上等满超时**——退订/清理一律给短超时或 fire-and-forget，"发出去就行"；②**fail-fast 的位置很重要**：做 fail-fast 的那个调用（`Bridge.dispose`）排在需要 fail-fast 的等待之后，等于没做；③排查"卡"要先量各段耗时再猜——本次实测订阅 1.9ms、列表 2ms，**凭直觉会去优化错的地方**；④日志里"默认超时"这种隐含值要去 `ChannelClient.call` 的签名里确认，调用点不写 timeout 不等于它没有超时。
- 关联：lib/state/app_controller.dart `_disposeBridgeStack`、lib/protocol/channel_client.dart `call`/`dispose`、lib/protocol/conversation.dart `_SubBase.dispose`/`_resubscribe`、lib/protocol/constants.dart `ipcUnsubscribeTimeout`

### [2026-09-11] 后台补拉和用户操作挤同一个队——用户点开会话排在自家 token 补拉后面
- 现象：用户报"有些会话很快，还有些有点慢"。量化后是双峰：1322 次 `subscribeConversationV4` 中位 4ms、92% <200ms，但 73 次落在 1s~22.6s。
- 根因：桌面端 channel RPC 走**同一个队**，慢的是排队受害者。铁证是"排空暴发"——57 次里 ≥3 个互不相关的调用耗时**完全相同**且同刻返回，典型如 4×`getTaskTokenUsage` + 2×`subscribeConversationV4` 全部恰好 5.1s。而 `getTaskTokenUsage` 是**我们自己的**后台补拉（1005 次/天）——用户的开会话排在自家补拉后面。
- 解决：加前台/后台优先级闸门——`openWorkspace`/`openSession` 算前台（`_asForeground`），期间 token 补拉/模型对账/prep/skills/归档一律不发并记账，前台空闲后补跑（`_backgroundGate`/`_runDeferredBackground`）；长循环在循环内也查闸门，用户一动手就停后续批次。
- 教训：①**当你的后台流量和用户操作共享一条队列时，"多发一点"就是"让用户多等一点"**——后台任务必须能感知前台并让路，这是客户端唯一能实际缩短等待的手段；②**"后台"不等于"免费"**：token 角标、模型对账这类装饰性/维护性流量，多数时候 4ms，但偶尔 11s，撞上就毁掉一次点击；③修之前先量——这次慢的根本不是打开会话的逻辑，我们自己的代码一行没慢；④**不要承诺"秒开"**：共享阻塞点在桌面端内部，我们只能让路，不能消除。
- 关联：lib/state/app_controller.dart `_asForeground`/`_backgroundGate`/`_runDeferredBackground`、`openWorkspace`、`openSession`、`_fetchTaskTokens`、`reconcileTaskModels`、`loadPrep`/`loadSkills`/`loadArchivedTasks`

### [2026-09-11] 判"卡顿"要用"排空暴发"判据，不能用"静默时长"
- 现象：想从桌面日志证明"某一刻整体卡住了"，先按"host 日志静默 ≥3s"去数，得到 2629 次、总时长 47157s——数字大得离谱，但**结论是错的**。
- 根因：日志空闲时段天然有大段静默（`off-peak-task.list` 每 60s 一跳，夜间无人时整分钟无日志）。静默只说明"没事发生"，不说明"卡住了"。
- 解决：换成**排空暴发**判据——同一时刻（±300ms）内 ≥3 个**互不相关**的调用耗时**完全相同**且都很长。耗时相同=它们不是各自慢，是被同一个阻塞点一起挡住；这比单看某条耗时有用得多（本次据此定位到"用户开会话与自家 token 补拉同队"）。
- 教训：①**"没有日志"≠"卡住了"**，判卡顿要抓"本该快的事变慢了"，不是抓"安静"；②**多个不相关调用的耗时完全相同**是排队/串行化的强指纹，看到就该怀疑共享阻塞点而不是各自慢；③写取证脚本注意：日志行内有**两个**时间戳（外层主进程 + 内层 host），取**最后一个**才是 host 的。
- 关联：`C:\Users\chengge\.zcode\v2\logs\YYYY-MM-DD.log`（含 NUL 字节须 `grep -a`）、BUGFIXES BUG-11

### [2026-09-11] 判"已断开"不能用 `session == null`
- 现象：给「断开连接 / 重新连接」改成"就地操作不跳页"时，用 `app.session == null` 判断"已断开"并挡掉卡片点击，`test/widget_test.dart` 的回归锁「tapping a task card opens the chat page route」立刻挂掉。
- 根因：该测试用**裸 `ZApp()`**（没连过、也没 session），但它的目的是锁住"任务卡点击必须真能导航进 ChatPage"这个曾经的 Navigator 崩溃。所以 `session == null` 的真实语义是**"还没连过"**，不是"已经断开"——两者在状态机里是同一处 null，但业务含义相反。
- 解决：单独记一个状态标记 `_disconnectedKeptShell`（只在"用户主动断开且保留列表"时置位），判据改成 `_disconnectedKeptShell || _inPlaceReconnect`。语义变成"确实是我们断开的 / 正在重连"，测试不再被误伤。顺带发现另一个坑：**重连失败后 `session` 对象仍然在**（`connect()` 里先建 `RemoteSession` 再连），所以必须在 `reconnect()` 的 catch 里显式置位，否则露出"看着能点其实点不开"的假活态。
- 教训：①**用 `x == null` 表达业务状态前，先问"还有谁也是 null"**——状态机的同一处 null 往往对应多种业务含义，用一个显式标记区分开；②**测试挂了先别急着改测试**：它可能是回归锁，在告诉你判据写宽了；③给"只读/降级"类状态起个专门的 getter（如 `isReadOnlySnapshot`），别在各处散落底层判据。
- 关联：lib/state/app_controller.dart `_disconnectedKeptShell`/`isReadOnlySnapshot`/`reconnect`、lib/ui/tasks_page.dart `_connBanner`、`test/widget_test.dart`

<!-- 模板（追加时复制）：
### [YYYY-MM-DD] 一句话标题
- 现象：报错/异常表现（保留报错关键字，便于日后搜索）
- 根因：为什么会发生
- 解决：当时怎么处理的
- 教训：以后什么情况下要警惕；这个结论在什么新情况下会失效
- 关联：涉及的文件/命令/配置
-->

（2026-09-11 初始化。按项目记忆规约：坑层从当下开始记录，不伪造历史条目。
历史上已知的构建注意事项——gradlew 单独打包跳过 Dart 编译——已记入 `AGENTS.md`
环境备忘，不重复立坑条目。）

### [2026-09-11] 仓库迁移后状态层文档没同步——文档里的命令把人指向封存目录
- 现象：接手时读 `AGENTS.md`（状态层，每次会话自动加载），其「新会话必读」与「环境备忘」把
  项目根写成 `D:\tools\zremote`，还写着「日常工作在 `develop` 分支」。照做就会 cd 进
  **已封存、禁止读写**的旧仓库，并切到一个不存在的分支。实际是 `D:\tools\zremote-new`、单分支 `master`。
- 根因：2026-09-11 从损坏仓库抢救代码时，`AGENTS.md` 只迁移了「目录结构」「如何运行/验证/打包」
  两段（改到一半），「新会话必读」「环境备忘」「交接摘要」三段仍留在旧世界；`develop` 分支在
  新仓库 `git init` 时也没重建。状态层是覆盖式快照，缺一张"迁移检查清单"就必漏。
- 解决：修正 `AGENTS.md` 四处——项目根统一 `D:\tools\zremote-new`；分支纪律改单分支 `master`；
  新增「封存目录严禁读写」条目；交接摘要改按单智能体模式叙述。顺带把 `no_proxy` 要求写进
  验证命令段（不设则 flutter_tester 回连被会话代理拦截、测试假失败）。
- 教训：①**状态层文档里的路径/分支就是可执行指令**——迁移仓库时它属于第一批必改项，
  "改一半"比"完全不改"更危险，半对的信息最难识破；②接手别人项目时，文档与实际仓库
  第一件事是**对账**（`git branch`、路径是否存在、分支是否存在），别默认文档是对的；
  ③"项目根"这类唯一事实只允许存在一处定义，其余位置一律引用它，避免多点漂移。
- 关联：`AGENTS.md`、`docs/HANDOVER.md` 第二/四节、`D:\tools\zremote`（封存目录）

### [2026-09-11] 订阅带了 `existing-only`——冷项目运行时没启动就必失败
- 现象：项目切换弹层点另一个项目，弹「切换失败：ChannelRpcError: ZCode Agent runtime
  is not running.」。**不是每次**——只在该项目运行时当时没在跑时发生（约 12%）。
- 根因：`IndexSubscription` 把 sessions-index **订阅**也写死成
  `runtimePolicy: 'existing-only'`。该策略语义是"只准挂到已经在跑的运行时上，不许启动"，
  目标工作区的 agent 运行时不在跑时桌面端 1ms 内直接拒绝。桌面端默认策略其实是
  `start-if-needed`（不传该字段即按需拉起运行时），且该字段是**可选**的。
- 解决：订阅不传 `runtimePolicy`；退订 / 重订阅保持 `existing-only`。另修了同一函数里
  "切换失败后 `workspace` 已改、`tasks` 还是旧项目"的状态不一致（改成成功后才认工作区 +
  失败回滚并静默重挂旧桥）。commit `ea86bb9`。
- 教训：①**"只准用已有资源"类策略（existing-only / getExistingXxx）绝不能放在冷启动
  路径上**——写订阅、连接、打开类代码前先问一句"这个资源此刻一定存在吗？不存在时谁来
  创建它？"；②**注释和参数自相矛盾的地方是 bug 高发区**——`_start()` 注释写"桌面端可能
  需要先预热运行时"、参数却是禁止预热的 `existing-only`，两者只能有一个对；③"有时候报错"
  优先怀疑**条件性前置状态**（某资源在不在跑），而不是网络抖动；④排查服务端行为的三段式
  取证法：客户端原始异常 → 桌面日志 `C:\Users\chengge\.zcode\v2\logs\`（含 NUL 字节，
  grep 要加 `-a`）→ 桌面运行时 `app.asar` 源码（未压缩，`grep -ao` 直接挖，只读）。
  日志里带 `[web-remote-control]` 的事件就是移动端发来的，可用来区分"客户端调用"与
  "桌面自身调用"。
- 关联：`lib/protocol/conversation.dart` `IndexSubscription`、`lib/state/app_controller.dart`
  `openWorkspace`、`docs/BUGFIXES.md` BUG-09、`docs/协议接口参考.md`

### [2026-09-11] 「跨项目」操作只在数据层对了 scope，RPC 还是打在别人家的桥上
- 现象：会话置顶只在 default 项目生效，在「全部对话」里给别的项目的会话置顶，图钉
  亮了、切回去看没置上；同一个「全部」视图里归档 / 删除 / 批量操作完，列表纹丝不动。
- 根因：两个独立的坑，共同点是**只处理了"数据该长什么样"，没处理"请求该走哪条路"**。
  ① `_taskScope(t)` 正确拼出了目标项目的 `workspacePath` / `workspaceIdentity`，
     注释还写着「跨项目也成立」——但 `_taskCall` 是经 **`this.bridge`（当前项目）** 发出去的。
     **scope 指向 A、请求来自 B**，服务端要么拒要么打错项目。注释的断言掩盖了这个断层。
  ② 失败是**软失败**（返回 `{ok:false}` 之类，不抛异常），而回滚写在 `catch` 里 →
     `_pinOverrides` 永久留着脏记录，**本地乐观层和真实状态永久分叉**，两个视图各说各话。
  ③ 「全部对话」的数据源是 `allProjectTasks`，但增删路径只改了 `tasks` / `archivedTasks`。
     这是一个**三份副本没人统一维护**的问题，`_runBatch` 收尾"只刷 loadTasks()"是同类。
  ④ 取消归档把会话 push 进 `tasks`（当前项目），跨项目操作就塞错了列表。
- 解决：`setTaskPinned` / `archiveTask` / `unarchiveTask` 一律**先 `ensureTaskProject`
  切到任务所属项目的桥**、发完再 `_restoreProjectView` 还原视图；新增 `_isSoftFailure`
  识别不抛异常的拒绝；三个集合同步；`_runBatch` / `_renameTask` 收尾跟随数据源。
  commit `67285d3` / `387867b` / `6bac671`。
- 教训：①**"scope 对了"不等于"能成"**——带项目/租户身份的 RPC，必须同时确认①参数里的
  身份 ②这条请求是从哪条连接发出的，两者不一致时服务端行为未定义。看到注释写
  「跨项目也成立」这类断言，**先找反例再信**；②**乐观更新必须能识别软失败**——
  把回滚只挂在 `catch` 上，等于假设"服务端拒绝一定抛异常"，这是未经证实的假设。
  凡是"本地先改、再同步"的地方都要问：服务端说"不"时，是抛异常还是返回一个 falsy 字段？
  ③**同一个业务对象有多份列表副本时，增删改必须列出所有副本逐一对齐**——
  漏一份的表现是"操作成功了但界面不动"，用户会重复操作，比直接报错更糟。
- 关联：`lib/state/app_controller.dart` `_taskScope` / `setTaskPinned` /
  `loadAllProjectTasks` / `_isSoftFailure` / `_restoreProjectView`、
  `lib/ui/tasks_page.dart` `_runBatch`、`docs/BUGFIXES.md` BUG-14

### [2026-09-11] 「修正量算对了」不等于「修正不动声色」——jumpTo 每帧一跳就是闪
- 现象：流式输出时往上翻历史，视口不再被拽回底部（BUG-01 已修），但画面**一闪一闪**，
  大段输出（带动画/代码块）时最明显。
- 根因：BUG-01 的锚定思路（按内容总高增量反向补偿）是对的，**落点错了**。
  ① 补偿挂在 `addPostFrameCallback`，而流式期间"这一帧量到的高度"和"下一帧实际的高度"
     经常不一致 → 每帧算一次增量、每帧落一次，每次落都是一次可见位移；
  ② 落的方式是 `jumpTo`（瞬时），没有动画缓冲，且阈值只有 0.5px，必然每帧越过；
  ③ 同一帧里 `_onScroll` / post-frame / 状态更新三处各算各的，跳两次以上；
  ④ `_atBottom` 单阈值在临界带随 `maxScrollExtent` 增长反复翻转，每次翻转 `setState`
     重建整页。
- 解决：`jumpTo` → 60~110ms 微动画（核心）；同帧补偿合并成一桶、帧末落一次；
  阈值 0.5→1.5px + 单步上限 600px（欠账分帧还，把"弹跳"变"追上去"）；
  `_atBottom` 双阈值滞回；`_anchorAnimating` 防并发 animateTo。
  纯计算抽成 `AnchorThresholds` / `AnchorMath` 便于单测。commit `c07b63b`。
- 教训：①**"位置算对了"只解决了漂移，"怎么落"才决定闪不闪**——凡是每帧都在修位置
  的机制（锚定、跟随、吸附），落点一律用短时长动画而不是 `jumpTo`，
  瞬时跳变在人眼里就是闪烁；②**修正在哪一帧量、哪一帧落，比修正量本身更容易出错**：
  量到"未来会变的值"就落，等于每帧都在追一个移动靶，观感是抖；③**同帧多源触发必须
  合并**——一个帧内被多路各修一次，比修一次糟得多；④**布尔态用双阈值滞回**，
  单阈值在"输入持续变化"的场景（流式、滚动、进度）一定会反复翻转，
  而每次翻转常常连着一次整页重建；⑤判"闪"要区分**位置抖动**与**重绘闪烁**，
  两者的排查方向完全不同，先问清用户"是内容在挪还是画面在闪"能省一大圈。
- 附：本版 Flutter `ScrollPosition.animateTo` 返回普通 `Future<void>`（非 `TickerFuture`），
  没有 `whenCompleteOrCancel`；想做"动画结束"回调得用定时器——别照抄网上基于
  `controller.animateTo` 的写法。
- 关联：`lib/ui/chat_page.dart` `_anchorAgainstGrowth` / `_applyAnchorGrowth` /
  `_scheduleAnchorFlush` / `_onScroll`、`lib/ui/composer_logic.dart` `AnchorMath`、
  `docs/BUGFIXES.md` BUG-15、BUG-01

## L-16 意图判定不能用连续位置量去猜（BUG-16）

- 现象：BUG-15 把"闪"治好了，"看历史被拉回去"还在——同一区域、不同链路：
  前者是**高频小幅**位置抖动（锚定补偿落点），后者是**低频大幅**强制滚动（自动回底）。
- 根因：`_maybeAutoScroll` 用 `_atBottom`（由 `pixels ≤ 180` 实时算出）当"用户想跟新内容"
  的判据。但流式期间内容每 tick 长高，用户盯着的那一行对应的 `pixels` **每帧都在变**，
  临界带内必然误判；再加上 `easeOut` 出门快（前 30ms 走完 60% 距离），
  观感就是"被一只手拽回去"。
- 解决：引入 `FollowLock` 状态锁——**用户主动滚离底部**这个"行为事件"才上锁，
  锁住期间一律不回底；只有用户**主动**滚回 `pixels ≤ 40` 或点「回到最新」才解锁。
  程序性滚动（发送消息、点按钮）显式解锁，不走锁。
  回底动作再按距离分流：一屏内 `linear` 200ms 匀速回，超过一屏不动手（交给锚定通道）。
- 教训：①**连续量 ≠ 意图**。凡是"用户想不想跟下去"这类意图判定，别用实时位置/速度去猜，
  要用**离散行为事件**（开始拖动、点了按钮、发了消息）去记状态；
  ②**同一区域可能有两条独立链路**——"闪"和"拽"都在消息列表上，但一个在补偿层、
  一个在自动回底层，修好一个不代表另一个好了，用户说"还有"时必须重新枚举**所有**
  修改滚动位置的地方（本例 `grep` 出 5 处，逐个过一遍才找到漏网的）；
  ③**手感差异会暴露曲线不一致**：修 A 处时把 `easeOut` 换成 `linear`，而 B 处仍是
  `easeOut`——用户能感觉到"还是不对"却说不清，检查时要**统一曲线语汇**；
  ④`ScrollEndNotification` 只表示"滚轮停了"，不表示"用户看完了"——别用它做浏览结束信号。
- 关联：`lib/ui/chat_page.dart` `_maybeAutoScroll` / `_onScroll` / `_onFocusChange` /
  `_send`、`lib/ui/composer_logic.dart` `FollowLock` / `AutoFollowMath`、
  `docs/BUGFIXES.md` BUG-16

## L-17 逆向协议要先抓真实数据、再实测回传，别猜（BUG-17）

- 场景：`AskUserQuestion` 询问弹窗的多选/其他输入"总感觉有问题"。第一反应
  是照着 UI 症状猜字段名（`multiSelect`? `allowOther`? `required`?），
  但**字段名和回传形状都无从确认**——猜错就是白改。
- 做法：项目里有配对链接 → 写探针（`test/manual_*_probe_test.dart` 那套模式：
  `RemoteSession` + `LinkParams.parse` + `ConversationV4`）直连桌面端，
  **两步走**：
  ① 先遍历 workspace 抓 `pendingInteractions` 的原始 JSON，看清进来什么字段；
  ② 再构造多种候选回传形状逐个发给服务端，用 `{status:accepted}` +
  `pending 是否清空` 判定哪种对。实测形状 A（`answers:[{question,selected}]`）
  一次就中，弹窗立刻关闭。
- 关键发现（都是猜不出来的）：`freeText` 是 **payload 顶层**开关而不是选项级
  `allowOther`；题目**没有 id**，回传键只能用题干原文；选项标识是 `value`；
  `description` 一直在传但 UI 从没渲染。
- 教训：①**逆向协议的第一生产力是"能连上真机"**——有通道就先抓原始数据，
  抓不到再退回到读产物/文档；②**回传形状必须实测**，光看进来的数据结构推不出
  出去的结构（本例进来 questions 用 `question` 做键，出去 answers 也用
  `question`，但元素裹了 `selected` 数组，这个层次关系猜不到）；
  ③**探针要能"试错"**：候选形状列表 + 逐个发送 + 判成败，比盯着文档读半天快；
  ④遍历所有 workspace 会踩到"某个项目 99 个会话"把测试拖超时——探针要
  设短超时 + 命中即停，别追求全量。
- 关联：`lib/ui/chat_page.dart` `_QuestionsView`、
  `lib/ui/composer_logic.dart` `AskQuestion`/`AskAnswer`/`buildAskAnswersPayload`、
  `test/manual_interaction_*_probe_test.dart`、`docs/API.md` resolveInteraction
  行、`docs/BUGFIXES.md` BUG-17

## L-18 状态一致性要靠"对账"，不能只靠推送（BUG-18）

- 场景：用户要求"会话列表的显示和会话状态保持一致，特别是消息报错要及时反馈"。
- 根因：整个列表状态建立在**一条推送流**（sessions-index）上，而推送会丢更新。
  代码里 `_livePhase` 覆盖机制的存在本身就是作者知道这件事——但覆盖只覆盖
  "打开过的会话"，剩下的靠裸流。
- 教训：①**推送流只能做"加速"，不能做"唯一真相源"**——凡是关键状态，
  都要有一条定时/事件驱动的对账路径兜底（本项目 BUG-07 给模型做过
  `reconcileTaskModels`，同理 phase 也要）；②**"离开时清理"是个危险动作**：
  清理本地说法上的缓存，如果上游还没同步过来，用户就会看到状态倒退——
  正确做法是"延迟释放 + 追平即撤 + 超时兜底"，三步缺一不可；
  ③**页面级状态上浮到 controller** 要挑真正需要跨页可见的：发送失败属于
  这一类（用户切走了还想知道），stage 文字不属于（只在当前页有意义）；
  ④**分层方向不能倒**：`protocol/` 不能 import `ui/`——即便 `ui/composer_logic.dart`
  自称"无 Flutter 依赖"，它仍然是 ui 层。共用逻辑该下沉到 protocol 或独立 util。
- 关联：`lib/state/app_controller.dart` `reportSendIssue` / `clearLivePhase` /
  `_tryReleaseLivePhase`、`lib/ui/tasks_page.dart` `_reconcileTimer`、
  `lib/protocol/conversation.dart` `isBusyPhase` / `canReleaseLivePhase`、
  `docs/BUGFIXES.md` BUG-18

### [2026-09-12] 同族写操作必须成族排查——修了置顶/归档漏了删除/重命名
- 现象：跨项目会话管理里，置顶/归档/取消归档在「全部对话」视图工作正常，删除/重命名却静默失败（本地生效服务端没生效）。
- 根因：夜班修复时给"scope 带项目身份的写操作"族只补了三个成员的 `ensureTaskProject`，同族成员 deleteTask/renameTask 漏网——而墓碑/标题覆盖机制恰好把失败症状盖住。
- 解决：两处补齐（deleteTask 的 deleteSession 还要等切换后再捕获 conv）。BUG-19。
- 教训：修"某类操作在某条件下失败"时，先枚举**整个操作族**（同 scope 结构、同通道、同写语义的全部成员），逐个核对是否同修；只修报障的那一个，等于把 bug 按成员分摊。掩盖层（墓碑/乐观覆盖）越强的功能，越要主动核对服务端真实效果。
- 关联：lib/state/app_controller.dart deleteTask/renameTask、docs/BUGFIXES.md BUG-14/19
