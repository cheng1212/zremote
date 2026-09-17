# zremote — 项目记忆（AGENTS.md）

> 本文件是项目记忆的**状态层**（覆盖式更新：永远只保留当前真相，改了代码行为必须同步本文件并更新验证日期）。
> 踩坑日志在 `docs/LESSONS.md`（只追加，永不修改/删除）。
> 状态层与代码实际行为不一致时，**以代码为准**，并当场修正本文件。
> 带 `（最后验证：YYYY-MM-DD）` 的信息超期后应默认存疑、先核实再信。

## 项目记忆配置单

- 受众：D —— 主要是外部 Agent（机器消费）：标题固定、关键词明确、路径与命令完整可复制执行
- 记什么：状态快照 ★ / 踩坑日志 ★ / 环境备忘 / 交接摘要（未启用：决策记录）
- 记多久：A —— 项目全程累积，永不删除，交付时随项目整体归档
- 怎么读：A + B —— 本文件每次会话自动加载；改动涉及环境/依赖/端口/构建/部署**之前**，先按关键词检索 `docs/LESSONS.md`
- 初始化日期：2026-09-11
- 硬性纪律：踩坑解决当下追加坑层；改动项目行为立即同步状态层；密钥永不入档（只记存放位置）

## 新会话必读（冷启动 ≤10 行）

- **先看交接**：`docs/HANDOVER-Z.md`（班次交接运行手册：当前主线、台账、环境硬信息、
  高危坑、交班仪式）。**接手先读它，再读本节。**
- **⚠️ 方向（2026-09-18 用户决定）**：**Flutter 已弃用，Web 端为主，目标适配移动端**。
  `lib/`（Flutter 24,021 行）**冻结不再开发，但不要删**——它是 Web 重写的唯一参照。
  主战场是 `web/`（Vue 3 + Pinia + Vite + TS）。详见 `docs/HANDOVER-Z.md`「零」。
- **这是什么**：ZCode 远程会话客户端（原 Flutter Android，现转 Web）。手机/浏览器连
  桌面端 ZCode：看任务、聊天、传图、管计划、批权限。
- **协议是逆向出来的**：改协议层前必读 `docs/API.md` 对应小节；协议常量只改
  `lib/protocol/constants.dart`（Flutter 蓝本）与 `web/src/protocol/constants.ts`（TS 移植）。
  ⚠️ **订阅帧是信封结构**（`{kind:"complete", frame:{payload:…}}`），不是帧本身——
  详见 `web/src/protocol/subscription.ts` 的说明，别再把信封当帧读 `payload`。
- **怎么验证（Web 主战场）**：`cd web && npm run typecheck`（0 错误）+ `npm test`（全过）。
  加 `npm run build` 确认能构建。
- **怎么验证（Flutter，仅查参照时）**：跑 `./test.sh`（Git Bash，一条命令双绿：自动设
  `no_proxy` + analyze + test）。手动等价：`flutter analyze` + `flutter test`（项目根
  `D:\tools\zremote-new` 下），跑 test 前必须设 `no_proxy`/`NO_PROXY`=`localhost,127.0.0.1,::1`
  ——本机会话注入 `http(s)_proxy`，否则 flutter_tester 回连本机 WebSocket 被代理拦截，
  测试**全线假失败**（报 WebSocketException）。
- **manual 探针**：已隔离至 `test/manual/`（@Tags(manual) 默认排除），跑法见 `test/manual/README.md`。
- **怎么打包**：Web 端双击 `web\启动.bat`（`npm run dev -- --host`，手机用 Network 地址）。
  Flutter 打包（已弃用，仅存档）：`build-flutter-apk.ps1`；**别只用 `build-apk.ps1`/gradlew——
  gradlew 不编译 Dart**。
- **绝对别做**：别把配对凭据（sid+hash）当普通数据处理——它就是凭据，可冒充终端会话；
  别把密钥写进任何记忆文件；别伪造坑层历史条目；**别擅自删 Flutter 代码**。
- **分支纪律**：**单分支 `master`**，小步提交，**高频提交 + 立刻 push**（用户 2026-09-18 明确要求）。
- **封存目录**：`D:\tools\zremote`（无 `-new`）是 .git 对象库损坏的旧仓库，**严禁读写**；
  一切命令只在 `D:\tools\zremote-new` 下执行。

---

## 状态快照

### 项目是什么

zremote：**浏览器 / 手机上的 ZCode 远程会话客户端**。通过中继（Relay）连上桌面端 ZCode，
实现任务列表、聊天（含图片/文件/Markdown 渲染）、计划管理、权限审批、用量统计、
通知/自动化等能力。

**⚠️ 形态变更（2026-09-18，用户决定）**：原为 Flutter Android 客户端（`lib/`，24,021 行），
现**转 Web**（`web/`，Vue 3 + Pinia + Vite + TS），目标移动端优先。
Flutter 侧**冻结不再开发但不删除**——它是 Web 重写的参照实现（含大量踩坑后的正确解法）。
形态：**一套代码 + 两套布局**（移动单列 / 桌面侧栏），不开两个代码库。

五层协议栈自底向上（**两端共用同一套协议**）：

```
Relay WebSocket (wss + HMAC proof)
  └─ 信令配对（sid + hash）
      └─ rpc-frame 分片（CRC 校验，超限切块）
          └─ Channel IPC（initialize / promise / event）
              └─ 业务方法（ConversationV4 / workspace / task …）
```

每层的帧格式、方法表、CAS（baseRevision 乐观锁）语义见 `docs/API.md`。

### 目录结构（最后验证：2026-09-11）

```
D:\tools\zremote-new\
├── AGENTS.md                  # 本文件：状态层 + 配置单 + 新会话必读
├── docs\
│   ├── API.md                 # 逆向出的协议文档（改协议层前必读）
│   ├── ROADMAP.md             # 接口排期计划（批次一~四；状态需对照代码核实）
│   ├── feat-*.md / fix-*.md   # 各功能/修复的设计文档
│   └── LESSONS.md             # 坑层：只追加的踩坑日志（动手前先检索）
├── lib\
│   ├── main.dart              # 入口 ZRemoteApp；启动时初始化 NotificationService
│   ├── protocol\              # 协议层：relay_client / channel_client / rpc_frames /
│   │                          #   fragment_assembler / crc32 / proof / link_params /
│   │                          #   value_codec / conversation / remote_session / constants
│   ├── state\                 # 逻辑层：app_controller / task_filters / task_sort /
│   │                          #   usage_stats / model_defaults / notification_logic /
│   │                          #   activity_view / automation_view
│   ├── services\              # notification_service
│   ├── ui\                    # 页面：pair / tasks / chat / usage / automations / profile
│   │                          #   + composer_logic / image_cache / rows / suggestions
│   └── theme.dart             # Citrus Morning 主题；ZT.tapMin=48 最小触控目标
│                              #   （iconButtonTheme 已统一撑到 48dp，别再压 compact/shrinkWrap）
├── test\                      # flutter test 全量单测（manual 探针已隔离至 test/manual/，默认不跑）
├── build-apk.ps1              # gradlew assembleRelease 直连打包（跳过 Dart 编译，慎用）
├── build-flutter-apk.ps1      # 完整 flutter build apk --release（推荐）
├── pubspec.yaml               # 依赖：web_socket_channel / crypto / flutter_markdown /
│                              #   markdown / shared_preferences / file_picker /
│                              #   flutter_local_notifications / url_launcher / fl_chart
└── android\app\build.gradle*  # applicationId / 签名配置（见环境备忘）
```

- 关键库文件数：`lib/` 下 32 个 `.dart` 文件（最后验证：2026-09-11）。
- 服务端返回形状未实测的一律做多形态兜底解析（参考 `parseTaskTokenUsage` /
  `describeFileChange` 的写法）。

### 如何运行 / 验证 / 打包（最后验证：2026-09-11）

```powershell
# 日常验证（在 D:\tools\zremote-new 下）
$env:no_proxy='localhost,127.0.0.1,::1'; $env:NO_PROXY='localhost,127.0.0.1,::1'
flutter analyze
flutter test

# 打包（完整构建，产物在 build\app\outputs\flutter-apk\）
powershell -File build-flutter-apk.ps1   # 后台执行，日志 flutter-build.log，完成标记 flutter-build.done
```

`test/` 下 `manual_*` 前缀文件为手动探测脚本（需真实环境，按需单独跑），
其余为自动化单测，`flutter test` 全量执行。

### 关键技术选型及理由

- **协议常量单文件集中**：`lib/protocol/constants.dart` 是协议参数唯一修改点（防锈设计：协议更新只改这一个文件）。
- **协议逆向 + 兜底解析**：协议文档是逆向产物，形状未实测的返回值做多形态解析，避免服务端变体导致崩溃。
- **SharedPreferences 明文存凭据**：`sid + hash` 目前明文存储，仅自用可接受；对外分发前必须迁移 `flutter_secure_storage`，并处理 applicationId / 正式签名 / 混淆。
- **纯逻辑层全量单测**：协议/状态层与 UI 解耦，保证 `flutter test` 可全量跑。
- **CAS 乐观锁**：会话行编辑用 baseRevision 乐观锁（见 `docs/API.md`）。
- **会话索引订阅不带运行时策略**（BUG-09）：`IndexSubscription` 订阅 sessions-index 时
  **不传** `runtimePolicy`——桌面端默认 `start-if-needed`，冷工作区会按需拉起运行时；
  只有退订 / 重订阅才用 `existing-only`。传错成 `existing-only` 会让"切到没启动过的项目"
  必失败（`ZCode Agent runtime is not running.`）。**新增任何"订阅/连接"类调用前先问一句：
  这个资源此刻一定存在吗？**
- **「全部对话」= 换数据源不换桥**：`viewingAllProjects` 只把列表数据源从 `tasks`
  （当前项目）换成 `allProjectTasks`（bootstrap 的整机 `tasks[]`），桥始终是当前项目的。
  所以在「全部对话」里点别的项目的会话，要先 `ensureTaskProject` 把桥切过去再打开。
  设计文档 `docs/feat-all-conversations-cross-project-pin.md`。
- **跨项目置顶靠 scope 里的 `workspacePath`**：`_taskScope` 以任务自带的工作区路径为准，
  只有确实是当前项目才补当前项目的 `workspaceIdentity`（拼错会打错项目）。
  置顶走乐观更新 + 本地 `_pinOverrides`（**不持久化**，服务端跟上即撤）。

---

## 环境备忘（最后验证：2026-09-11）

- **项目根**：`D:\tools\zremote-new`（Flutter 项目，Dart SDK ^3.12.0，版本 0.1.0+1）。旧仓库 `D:\tools\zremote` 已封存，**禁止读写**。
- **Android 包名**：`com.example.zremote`（占位包名）；签名：debug 签名（`signingConfigs.getByName("debug")`）；minSdk/targetSdk 用 Flutter 默认值。
- **打包脚本**：
  - `build-flutter-apk.ps1` = 完整 `flutter build apk --release`，脱离会话后台跑（Start-Process），日志 `flutter-build.log` / `flutter-build.err.log`，完成标记 `flutter-build.done`（内容 `EXIT=0` 为成功）。
  - `build-apk.ps1` = 直接 `android\gradlew.bat assembleRelease`，**注意：gradlew 单独跑会跳过 Dart 编译**，只适合增量验证原生层；日志 `gradle-direct.log` / `gradle-err.log`，标记 `gradle-direct.done`。
- **凭据存放**：配对凭据（sid+hash）明文存于应用内 SharedPreferences；仓库内不存任何密钥。
- **git**：**单分支 `master`**（Git 已重建，无 `develop`）；提交信息风格为 `类型(范围): 中文描述`（如 `fix(chat): …` / `ui(tasks): …` / `feat(chat): …`）。
- **节奏约定**（来自 docs/ROADMAP.md）：每批 = 实现 → `flutter analyze` + `flutter test` → git 提交 →（用户下令）构建部署。

---

## 交接摘要（最后核对：2026-09-11）

- **排期总纲**：`docs/ROADMAP.md`（批次一~四 + 未探索通道清单）。该文档写于 2026-09-04，
  近期提交集中在任务列表 UI 与聊天图片体验，**批次完成状态需对照代码与提交历史核实后再续排**。
- **2026-09-11 修复批次（全部已并入 baseline `5e4e8af`）**：`1aed45d` 流式输出视口锚定；
  `a38cf2f` 聊天代码块完整铺开去内滚；`d09a777` 默认模型改 GLM 5.3 Flash；`e84e7cf` 模型
  对账以服务端为准+切换乐观更新；`1766677`+`cba77df` 删除会话补调 deleteSession 修跨设备
  复活；`ad9b8cd`+`594ecab` 模型护栏（BUG-07 基线集合补 qwen3.8-flash / BUG-08 provider id
  改 `builtin:bigmodel-coding-plan`）。坑见 `docs/LESSONS.md`。
  **工作模式已改**：单智能体直接对用户负责，`COLLAB.md` 为历史档案已冻结，
  **勿**续写它的任务队列/锁机制（约定见 `docs/HANDOVER.md` 第五节）。
- **2026-09-11 接手批次（单智能体，用户直接指挥）**：`ea86bb9` 修项目切换报错（BUG-09）；
  `b749dbc` 项目切换器加「全部对话」跨项目视图；`ee3acb2` 置顶跨项目生效。
  设计与边界见 `docs/feat-all-conversations-cross-project-pin.md`。
- **2026-09-13 多端一致性批次（用户裁定：会话列表以服务端为准，本地只做缓存）**：
  持久化删除墓碑（`removedTaskIds`）废弃，降级为「进行中 + 对账」乐观层
  `_deletingTasks`（仅内存，`task_sort.dart sweepDeletions` 裁决：服务端没有=确认
  删除；服务端还有且过 8s 宽限=恢复显示），启动即清旧墓碑库；`loadTasks` 失败不再
  吞成空列表——缓存降级 + `tasksStale` 标记 + 3s~30s 退避重试 + 列表页「同步中断」
  横幅；归档集合在断开/换工作区时清空。模型意图（sessionModels）不属会话存在性，
  守恒器机制保留不动。**第二批（同日，用户补裁定"所有会话操作都写通服务端，下次
  加载两端必一致"）**：索引流只增补已有卡片、不再把「索引有、列表没有」的会话
  重建成卡（幽灵复活口子关闭）；createSession 成功后主动 loadTasks（新会话本机
  及时可见）；抽屉新增「从服务端拉取最新」硬同步按钮（`ZApp.pullLatest`：整表
  重拉列表+归档+全部对话视图+索引重同步）。**第三批（同日）**：冷启动默认进
  「全部对话」（`_openAllProjectsOnConnect`，配对页全新连接消费一次；用户手动
  进项目/就地重连不强制；彻底断开复位）。**第四批（同日，用户报障三连）**：
  「全部对话」视图补齐与服务端的对等纪律——`_composeVisibleAllTasks`（归档/
  已删排重+删除进行中过滤+`_enrichFromIndex` 索引实时增补+livePhase 覆盖），
  修「运行中显示空闲久不恢复」（原视图吃连接时刻 bootstrap 快照）与归档重复；
  跨项目开会话的切桥改 `openWorkspace(preserveView:true)`——只切桥不动用户列表
  视图，不再被拽进项目分类。**第五批（同日，探针实测裁定归档语义）**：桌面端
  的 `archived` 是「会话已关闭」生命周期标记（41 条里 36 条带，运行中的也带），
  不是「用户收起」——「全部对话」不再过滤 archived；归档 tab 改跨项目聚合
  （逐项目并发 listArchivedTasks，原只查当前桥项目导致 36 vs 个位数的差）。
  探针：test/manual_server_list_audit_test.dart（只读，链接门控）。
- **2026-09-13 图片流程重构（用户裁定：对齐 D:\zcode-dev 参考端的图片体验）**：
  ①弹层三入口对齐——「拍照 / 从相册选择图片 / 上传文件(PDF/文档/任意)」（原只有
  「添加图片（相册）/添加文件」，无拍照；`_OptionRow` 补可选前导图标）；②相册选图从
  `FilePicker(type: image)`（文件管理器）换成 `image_picker.pickMultiImage`（**系统
  相册**，照片/影集多选），拍照走 `pickImage(source: camera)`，两者同一落地路径
  `_addPicked`（XFile → PlatformFile 带字节）；③**去掉上传阶段文案**——原 `_setStage`
  往回显气泡里写「读取 xx…」「上传 xx 45%」并带「取消」入口，用户明确不要；改为
  **静默预上传**：选中即 `_kickPreUpload` 传（`_attachRefs` 缓存 ref + `_attachInflight`
  去重），发送时命中 ref 直接引用、没命中才补传，失败只在发送时如实回显。回显形式
  （一张一张缩略图）保持不变。复用判定抽纯函数 `attachUploadPlan`（`composer_logic.dart`，
  ref 是**会话域**的：换会话不复用，必须重传）+3 测试，共 221 全绿。
  注：`attachmentPut` 的 `isCancelled` 取消钩子保留在协议层（已无 UI 入口）。
- **待真机验证（接手批次新增）**：⑤切到桌面端没启动过的项目也能正常打开（不再报
  runtime is not running）；⑥切换失败时界面留在原项目而不是"标题新项目 + 旧列表"；
  ⑦「全部对话」能列出所有项目的会话且卡片带所属项目标签、点别的项目的会话能打开；
  ⑧在「全部对话」里置顶某会话，切到它所属项目单独看仍是置顶。
- **待真机验证**（用户手持设备验收）：①流式输出时按住列表的锚定手感；②超大代码块处
  列表滚动流畅度；③切模型秒切不卡、重启后模型保持；④手机删会话→平板刷新不再复活；
  ⑨（多端一致性批次）删除在服务端被拒时，两端设备列表一致（都还能看到，不再一边
  永久隐身）；⑩断开服务端时列表页出现「同步中断」横幅、恢复后自动消失。
- **协议文档双源**：`docs/API.md`（逆向主文档）+ `docs/协议接口参考.md`（2026-09-11
  实测参考：L5 通道方法表、快照字段表、关键行为事实——新增能力前先查它的方法表，
  如 `deleteSession`、`workspace/setDefaultModel` 等未接入能力都在里面）。
- **默认模型**：`lib/state/model_defaults.dart` 单一来源——首选默认 GLM 5.3 Flash
  （2026-09-11 起）；「不切=默认、切了=实际模型」由模型守恒器 `_keepSessionModel` 承载
  （设计文档 `docs/feat-model-keeper.md`）。已知局限：意图模型按设备本地持久化
  （SharedPreferences），多设备无服务端同步；对账已改为「服务端真实模型优先」收敛，
  仅当服务端掉回基线/历史默认才按本地补发。
- **接口差集与补齐（2026-09-12）**：全量矩阵见 `docs/INTERFACE-MATRIX.md`。
  已补齐接入：`restartAutomation`（自动化卡片重启）、`editUserQuery`（长按用户消息
  编辑重发）、`applyFileRewind`+`fileRewindPreview`（文件变更弹层回滚本回合文件）、
  `editQueueItem`+`reorderQueueItem`（排队条编辑/上移）。`setTaskUnread` 双证否决
  （桌面无此方法+无未读 UI）。`workspace/*` 族与 `session/setModel` 不可达（源码+探针双证）。
- **持续扫描**：`docs/SCAN-MATRIX.md` 为功能×按钮×状态扫描台账，新会话续扫前先读，
  扫完一格更新一格；bug 修复登记 `docs/BUGFIXES.md`（BUG-01~19）。
- **工作模式（2026-09-11 起）**：单智能体 + 用户直接指挥（协作看板 COLLAB.md 已冻结
  为历史档案）。接手先读 `docs/HANDOVER.md`。
- **模型护栏（BUG-07，2026-09-11 交付）**：基线集合 `serverFallbackModelIds`（含 qwen3.8-flash）
  + `isServerFallbackModel` 单一判定；`reconcileTaskModels` 每次 loadTasks 后批量纠正被刷回
  基线的会话；发送失败卡片有「切 GLM 重试」一键退路。bug 台账见 `docs/BUGFIXES.md`。
- **跨项目操作纪律（BUG-14，2026-09-11 交付）**：带项目身份的 RPC（`setTaskPinned` /
  `archiveTask` / `unarchiveTask` / 重命名）**必须走任务所属项目的桥**——`_taskCall` 用的是
  `this.bridge`，scope 对了但请求来自别的项目时服务端会静默拒绝。统一走
  `ensureTaskProject(t)` 切桥 + `_restoreProjectView` 还原视图（用户在「全部对话」里点的，
  不能因此被甩进那个项目）。乐观更新一律用 `_isSoftFailure(res)` 认软失败后回滚。
  同一任务有三份列表副本（`tasks` / `allProjectTasks` / `archivedTasks`），
  增删改**必须逐一对齐**；收尾刷新跟随数据源（`viewingAllProjects` 时刷
  `loadAllProjectTasks()`）。批量重命名走 `BatchRenameSpec`（字面量替换，不做正则/序号）。
- **未解决的问题**：
  - 配对凭据明文存储（见上「关键技术选型」），对外分发前必须迁移。
  - 附件上传整文件读进内存，>100MB 在选择时拦截。
  - 图片附件缓存仅进程内（64MB LRU），冷启动后首屏重新拉取。
  - 桌面端只支持「链接配对」，未实现扫码。
  - ROADMAP 中标注的「未探索通道」（`file` `git` `terminal` `memory` `bots` 等约 30 个）暂不做，有需要再抓包分析。
