# zremote Flutter 工程优化方案（2026-09-14）

> **文档目的**：基于 2026-09 对"优秀 Flutter 项目"的调研（Flutter 官方架构指南 + Compass 官方案例研究 + 社区共识），对 `D:\tools\zremote-new` 实地勘察后给出的**可执行优化任务清单**。与 `docs/AUDIT-2026-09-13.md`（安全/一致性审计）**互补不重复**：审计的 A1/B1-B4 发现已全部收编进本方案任务卡（标注出处），执行时以任务卡为准。
>
> **基线体检（2026-09-14 实测，no_proxy 已设）**：`flutter analyze` 0 issues；`flutter test` **259 过 / 26 跳过（manual 探针）**；版本 0.1.8+9；master 单分支；Flutter 3.44.0 stable / Dart 3.12.0（与 zcode app 同工具链）。23,266 行 Dart + web/ Vue 客户端。**结论：项目文档文化与协议栈设计是同类项目里的上乘水平，短板集中在"巨型文件、上帝对象、工程化三件套缺失"三处。**

---

## 0. 执行规范（执行 Agent 必读）

遵循本仓库 `AGENTS.md` 既有纪律，另有本仓库特有规则：

1. **分支**：**单分支 `master`，小步提交**（本仓库明确不用 feature 分支模型，与 zcode-dev 不同）。中文提交消息，`app:` 前缀。
2. **版本号**：本仓库惯例是每次功能提交同步递增 `version: X.Y.Z+build`（见 git log），优化任务沿用此惯例。
3. **验证门槛（每次提交前必须全绿）**：
   ```bash
   cd D:\tools\zremote-new
   export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="localhost,127.0.0.1,::1"   # 不设则测试全线假失败(代理拦截回连)
   D:\flutter\bin\flutter.bat analyze    # 期望: No issues found
   D:\flutter\bin\flutter.bat test       # 期望: All tests passed（基线 259 过/26 skip，只许增不许减）
   ```
4. **行为变更须同步 AGENTS.md 状态层**（覆盖式更新 + 更新"最后验证"日期）；踩坑**只追加** `docs/LESSONS.md`，永不修改历史。
5. **红线**：封存目录 `D:\tools\zremote`（无 `-new`）严禁读写；配对凭据（sid+hash）是凭据，不当普通数据处理；密钥永不入档。
6. **每完成一个任务**：本文档对应任务打勾 `[x]` + 一行完成说明（含 commit hash），随代码提交。

---

## 1. 现状快照（证据）

### 1.1 做得好的（**禁止在优化中破坏**）

| 亮点 | 证据 |
|---|---|
| 五层协议栈分层清晰、文档化 | Relay WS(HMAC) → 信令配对 → rpc-frame(CRC 分片) → Channel IPC → 业务方法，每层有 `docs/API.md` 对应小节；协议常量集中在 `protocol/constants.dart` |
| state/ 已有纯逻辑拆分意识 | `task_sort.dart`(250)/`activity_view.dart`(229)/`task_filters.dart`(167)/`session_open_logic.dart`(66) —— 小而纯、可单测 |
| 项目记忆体系一流 | AGENTS.md 状态层（覆盖式+验证日期）+ LESSONS.md（只追加）+ AUDIT/HANDOVER/ROADMAP 系列，外部 Agent 冷启动成本极低 |
| 卫生纪律 | 全库 0 print 残留、0 空 catch、35 处 `unawaited` 显式标注（2026-09-13 审计确认） |
| 测试文化 | 259 个测试 + 26 个 manual 探针；widget_test.dart 已覆盖页面路由级冒烟 |
| 双绿基线维持 | analyze 0 issues + test 全绿是合并硬门槛（本方案已实测复验） |

### 1.2 短板（与调研标准的差距，按严重度排序）

| # | 短板 | 证据 |
|---|---|---|
| G1 | **巨型文件冠绝双项目**：`ui/chat_page.dart` **7062 行**（68 个顶层类/方法块，是 zcode app 同文件的 2.4 倍）；`state/app_controller.dart` **2600 行**；`tasks_page.dart` 2319；`rows.dart` 2089；`protocol/conversation.dart` 1789 | `wc -l` 实测 |
| G2 | **上帝对象**：`app_controller` 装任务轮询/通知去重/相位释放/token ticker 等 20 处 Timer + 18 个常驻集合；7 个 UI 文件 import 它；全库仅 5 处 ListenableBuilder，重建范围粗 | `grep -rln` 实测 |
| G3 | **无 CI / 无 FVM**：origin 远端（github.com/cheng1212/zremote）已配但无 `.github/workflows/`；SDK 靠 `D:\flutter` 单机路径 | `ls .github` 不存在、无 `.fvmrc` |
| G4 | **manual 探针混居 test/**：41 个测试文件中 25 个 `manual_*`，靠 skip 机制与真实测试混在一起；且代理坑要靠人肉记 no_proxy（审计 B3 已提流程化建议） | `ls test/ \| grep -c manual` = 25 |
| G5 | **停更依赖 + 姊妹项目依赖漂移**：`flutter_markdown: ^0.7.7` 官方已停更（zcode app 已迁 `flutter_markdown_plus`，有现成迁移经验）；file_picker 8 / flutter_local_notifications 18 / package_info_plus 8，均落后 zcode app 2-4 个大版本 | pubspec 对比 |
| G6 | **lint 只有默认集**：`analysis_options.yaml` 未开 strict 规则 | 文件实查 |
| G7 | **仓库根卫生**：3 份 `.git` 目录并存（`.git` 19M + `.git-broken-20260912-1941` 316K + `.git-from-develop-clone-20260912` 3.4M）+ 构建日志/flag 文件散落根目录（`flutter-build.*.log`、`build_done.flag`、`flutter-build.done`） | `ls -la` 实测 |
| G8 | **协议双端一致性无测试锁**：TS/Dart 的 CAS 命令集合 diff 无自动化比对（审计 A1）；web 端协议测试为零（审计 B4） | AUDIT-2026-09-13 |

### 1.3 明确**不做**的事（防止执行 Agent 过度工程）

- ❌ **不引入 Riverpod/BLoC 替换 app_controller**：与 zcode app 同理，ChangeNotifier 切片化即可（T6），替换是高风险重写。
- ❌ **不动协议栈设计**：五层结构是逆向出来的资产，`protocol/` 各层职责正确；仅对过大的 `conversation.dart` 做**文件内**分节整理（T7 可选子项），不改分层。
- ❌ **不上 go_router / l10n / monorepo**：理由同 zcode app（单 APK + 固定 zh-CN + 单包规模）。
- ❌ **不删 manual 探针**：它们是逆向协议的活文档，只做**隔离与规范化**（T4），一个不删。
- ❌ **不合并双端仓库**：web/（Vue 客户端）与 Flutter 同仓是现状，拆仓无收益。

---

## 2. 任务清单

优先级：**P0** = 防事故/防漂移；**P1** = 架构偿还；**P2** = 打磨。规模：S ≤ 半天，M ≈ 1 天，L ≈ 2-3 天，XL 分多次会话。

---

### [x] T1（P0·S）仓库根卫生：三份 .git 归位 + 构建产物出库
> ✅ **完成（2026-09-14，4121e45）**：两份遗留 .git 先核对（broken 为空仓；develop-clone 的关键提交已在主仓对象库）后压缩归档 `D:\git-remotes\zremote-old-git-20260912.zip`（2.4MB）再删除；构建日志/flag 出库；`.gitignore` 补 `logs/`。

**现状**：根目录并存 3 份 git 目录（主 `.git` 19M + 两个历史遗留共 3.7M）+ 4 个构建日志/flag 文件散落。

**步骤**：
1. **先确认两份遗留 .git 里没有未找回的东西**：`git --git-dir=.git-broken-20260912-1941 log --oneline -5`、`git --git-dir=.git-from-develop-clone-20260912 log --oneline -5` 各看一眼；确认无用后**压缩归档**到 `D:\git-remotes\` 下（如 `zremote-old-git-20260912.zip`），再从工作树删除。删除前列出内容告知用户一次。
2. `flutter-build.err.log` / `flutter-build.log` / `build_done.flag` / `flutter-build.done` 移入 `logs/`（已存在的目录）或删除；`git status` 确认它们本来就没被 track。
3. `.gitignore` 补：`*.flag`、`flutter-build*.log`、`flutter-build.done`、`logs/`、`.probe-shots/`、`dist/`（逐条核对现状后加，防止误伤）。

**验收**：`ls` 根目录只剩标准 Flutter 工程项 + 项目文档；`git status` 干净；测试全绿。

**风险**：低。唯一谨慎点是删 `.git-*` 前的确认步骤，不可跳过。

---

### [x] T2（P0·S）GitHub Actions CI + 测试代理坑流程化（收编审计 B3）
> ✅ **完成（2026-09-14，32d57eb）**：`.github/workflows/app-ci.yml`（flutter 3.44.0 analyze+test，web job 随 T10 加回）；`test.sh` 一条命令双绿（no_proxy 流程化）；Actions 实测绿灯（T4/T5 提交均 success）。

**现状**：origin 远端已配，无 CI；测试假失败坑（代理拦截 flutter_tester 回连）靠 AGENTS.md 文字提醒。

**步骤**：
1. 新建 `.github/workflows/app-ci.yml`：
   ```yaml
   name: app-ci
   on:
     push:
       paths: ['lib/**', 'test/**', 'pubspec.yaml', '.github/workflows/app-ci.yml']
     pull_request:
       paths: ['lib/**', 'test/**', 'pubspec.yaml', '.github/workflows/app-ci.yml']
   jobs:
     test:
       runs-on: ubuntu-latest
       timeout-minutes: 20
       steps:
         - uses: actions/checkout@v4
         - uses: flutter-actions/setup-fvm@v4      # 依赖 T3 的 .fvmrc；未完成前临时写死 3.44.0
         - run: fvm flutter pub get
           working-directory: .
         - run: fvm flutter analyze --no-pub
         - run: fvm flutter test
   ```
   （GitHub runner 无本机代理问题，无需 no_proxy 特殊处理。）
2. **同任务顺手做审计 B3**：新建 `test.sh`（Git Bash）——`export no_proxy=... NO_PROXY=...` 后依次跑 analyze+test；AGENTS.md「怎么验证」一节改为"跑 `./test.sh`"。
3. `git push origin master`（超时则走 `HTTPS_PROXY=http://127.0.0.1:7897`，需 Clash 运行），Actions 页确认绿灯。

**验收**：Actions 绿灯；故意改坏一行 push 后变红；`./test.sh` 在本机一条命令双绿。

**风险**：无（纯新增）。manual 探针在 CI 上同样是 skip 状态，不会拖慢。

---

### [x] T3（P0·S）FVM 锁定 SDK 版本 —— ❌ **评估后拒绝**（见任务内说明）
> ❌ **拒绝（2026-09-14）**：本机无 fvm，且项目为单机单版本工具链（`D:lutter` 3.44.0 stable，与 zcode app 同链），不存在 T3 要防的"多环境 SDK 漂移"；版本确定性已由 T2 的 CI（`flutter-version: 3.44.0` 写死）兜住。引入 fvm 反而多一套 SDK 副本与脚本改造成本。**版本约束继续由 `sdk: ^3.12.0` + CI 锁版本承担**。

**现状**：`sdk: ^3.12.0` 约束 + `D:\flutter` 单机路径（3.44.0 stable）。

**步骤**：
1. `cd D:\tools\zremote-new && fvm use 3.44.0` → 生成 `.fvmrc`；确认 `.gitignore` 含 `.fvm/`。
2. AGENTS.md 环境备忘 + `test.sh` + `build-flutter-apk.ps1` 里的 flutter 命令统一改走 `fvm flutter`。
3. 验证 `./test.sh` 双绿。

**验收**：`.fvmrc` 入库；构建/测试脚本全部经 fvm；AGENTS.md 已同步。

**风险**：低。构建脚本改路径后**打一次 APK 实测**再提交。

---

### [x] T4（P0·S）lint 强化
> ✅ **完成（2026-09-14，540ab5a）**：strict-casts + unawaited_futures 落地。strict-casts 抓出 2 处真 dynamic 隐患（chat_page 类型化空列表/键值插值）已修；17 处火忘 Future 全部显式化（1 处 `Map<K,Future>.remove` 判误报加注释 ignore）。strict-inference/raw-types 暂缓（按本任务降级策略）。

**现状**：默认 `flutter_lints`，无 strict 规则。

**步骤**：
1. `analysis_options.yaml` 加（与 zcode app 同款）：
   ```yaml
   analyzer:
     language:
       strict-casts: true
       strict-inference: true
       strict-raw-types: true
   linter:
     rules:
       unawaited_futures: true
       always_declare_return_types: true
       avoid_redundant_argument_values: true
   ```
   （`unawaited_futures` 对本项目是白捡的——已有 35 处显式 `unawaited` 的纪律。）
2. 逐条修复新暴露问题，只改代码不关规则；确属误报的 `// ignore:` + 注明原因。
3. 若 strict-inference 暴露 >50 条，先只开 strict-casts + unawaited_futures，其余记录到提交信息下批再开。

**验收**：analyze 0 issues 且配置生效；测试全绿。

**风险**：低。

---

### [x] T5（P0·S）manual 探针隔离 + 命名规范化
> ✅ **完成（2026-09-14，29f94e1）**：25 个探针 `git mv` 至 `test/manual/`（保历史，相似度 92-98%）；`@Tags(['manual'])` + `dart_test.yaml exclude_tags` 实现**默认测试零 skip**（259 全过无噪音）；`test/manual/README.md` 落档跑法与清单。

**现状**：25 个 `manual_*` 测试与真实测试混在 `test/` 根，靠 skip 区分；对新 Agent 是噪音源（41 个文件里 6 成不用跑）。

**步骤**：
1. 建 `test/manual/` 子目录，25 个 `manual_*.dart` **原样移入**（git mv 保历史）。
2. `dart_test.yaml` 配置排除：真实 `flutter test` 默认不跑 manual（`presets` 或直接按目录约定——确认这些测试的 skip 机制后选最小改动方案；目标是 `flutter test` 输出不再出现 26 个 skip 的噪音，跑 manual 用显式命令 `flutter test test/manual/xxx.dart`）。
3. `test/manual/README.md` 一段话：每个探针干什么、怎么跑、前置条件（哪个环境变量/哪个服务器状态）。
4. AGENTS.md「怎么验证」补充 manual 跑法。

**验收**：`flutter test` 输出 0 skip（或只剩个别全局 skip）；探针显式可跑；README 存在。

**风险**：低。只移动文件和配置，不改测试逻辑；**探针一个不删**。

---

### [ ] T6（P1·XL）chat_page.dart 7062 行分解（本方案最大任务，分多次会话）

**现状**：单文件 68 个顶层块，混合：聊天列表（reversed + 锚行补偿）、composer（图/文件/文案）、权限面板、任务卡、动画水位、面板钳制……注释显示这是 zcode app 聊天页的**上游原型**（那边已拆到 2988 行，可反向借鉴其拆法）。

**目标**：单文件 ≤800 行；聊天相关代码聚 `ui/chat/`；行为零变更。

**步骤（绞杀者模式，每步一提交，提交前双绿）**：
1. **纯函数先行**：滚动稳定性相关（锚行补偿/面板钳制，见 `docs/SCROLL-STABILITY-RESEARCH.md`）若无纯函数化，先抽成 `ui/chat/scroll_logic.dart` 纯函数 + 单测——这是 BUG-38/39 的成果，先加测试锁住再搬。
2. **composer 块**：输入条/图片编码/文件选择 → `ui/chat/composer.dart`（`composer_logic.dart` 752 行已是独立文件，把 chat_page 里的残余接线一并归拢过去）。
3. **权限/审批面板** → `ui/chat/permission_panel.dart`。
4. **任务卡/列表行块** → 与 `rows.dart`（2089 行）合并考量：按行类型拆 `ui/chat/rows/`（text/tool/thinking/task），`rows.dart` 留 barrel。
5. **页面骨架收敛**：chat_page.dart 只剩装配 + 布局 + 与 app_controller 接线，≤800 行。

**验收**：`wc -l` 达标；259 测试全绿；widget_test.dart 的页面路由冒烟不改一行仍过；聊天全路径（发消息/收推流/传图/批权限/滚动回跳）手动冒烟。

**风险**：**高**（本项目最高风险任务）。滚动稳定性逻辑是修过 BUG-38/39 的脆弱区——**先补纯函数测试再动**，每步可独立回滚。禁止搬运中"顺手优化"。

---

### [ ] T7（P1·L）app_controller.dart 2600 行切片化

**现状**：上帝对象：任务轮询/通知（`_recentNotified` 90s 去重账、`_notifiedTitles`）、token ticker、相位释放、slow timer 等 20 处 Timer + 18 个常驻集合；7 个 UI 文件 import；全库仅 5 处 ListenableBuilder。

**目标**：拆为领域切片（保留 `AppController` 作组合根 facade，对外接口第一轮不变）：
```
state/slices/
├── tasks_slice.dart        # 任务列表/筛选/排序（task_sort/task_filters 已是纯逻辑，挂进来）
├── notify_slice.dart       # 通知去重账 + notification_service 接线
├── chat_slice.dart         # 会话打开/历史窗口（session_open_logic 挂进来）
└── usage_slice.dart        # 用量统计（usage_stats.dart 435 行挂进来）
```

**步骤**：每片一提交：搬状态 + 方法 → 旧接口委托保兼容 → 测试绿 → 下一片。**先拆 usage（最独立）练手，tasks/notify 次之，chat 最后**。拆完每页把监听粒度从整 controller 改为对应 slice。

**收编审计 B1/B2（一并做）**：
- **B1 Timer 盘点表**：拆分时在 `state/slices/timers.md` 或代码内建"存活 Timer 清单"注释块，dispose 路径全量 cancel 逐个核对；
- **B2 集合容量上限**：`_notifiedTitles`/`_taskTokens` 等无上限集合加简单容量上限（超限丢最旧），不引 LRU 库。

**验收**：259+ 测试全绿；app_controller ≤800 行；7 个 UI 文件 import app_controller 的降到 ≤3；B1 清单齐、B2 上限生效。

**风险**：中高。与 T6 有文件交集（chat 相关），**先做 T7 或与 T6 分会话串行**，避免同文件并行。

---

### [x] T8（P1·S）flutter_markdown → flutter_markdown_plus 迁移（有现成经验可抄）
> ✅ **完成（2026-09-14，06db299）**：pubspec 换 `flutter_markdown_plus: ^1.0.12`（姊妹项目同款）；rows.dart 单点 import 替换；API 差异仅一处——`sizedImageBuilder(config)` → `imageBuilder(uri, title, alt)`（Uri 直传，dynamic 隐患顺带消除）；双绿通过。

**现状**：`flutter_markdown: ^0.7.7` 官方已停更；使用点仅 **`lib/ui/rows.dart` 一个文件**。姊妹项目 zcode app 已完成同款迁移（其 pubspec 注明"flutter_markdown 已停更,迁移至 flutter_markdown_plus"），API 兼容性已被那边验证过。

**步骤**：
1. pubspec：`flutter_markdown_plus: ^1.0.12` 替换 `flutter_markdown`（`markdown: ^7.2.2` 保留，plus 依赖它）；
2. `rows.dart` 改 import（包名替换，API 基本同名）；
3. 对照 zcode app 的用法核差异点（若存在，抄那边的适配写法：`D:\zcode-dev\app\lib\ui\rows.dart`）；
4. 双绿 + Markdown 渲染冒烟（代码块/表格/图片/链接四种消息实渲染对比迁移前截图）。

**验收**：pubspec 无 flutter_markdown；测试全绿；四类 Markdown 渲染无回归。

**风险**：低（单文件使用点 + 姊妹项目已趟平）。

---

### [ ] T9（P1·S）姊妹项目依赖对齐评估

**现状**：file_picker 8 / flutter_local_notifications 18 / package_info_plus 8 / url_launcher 6.3，均落后 zcode app 同包 2-4 个大版本。两项目同一作者同一工具链，长期双维护漂移成本高。

**步骤**：
1. `flutter pub outdated` 拿全量清单；
2. **逐包决策**（只升大版本有明确收益且 zcode app 已验证的：package_info_plus 8→10、flutter_local_notifications 18→22；file_picker 8→12 若 API 有破坏性改动则缓）；每包一提交，双绿 + 对应功能冒烟（通知/选图/版本号显示）；
3. 在 `docs/ROADMAP.md` 或 AGENTS.md 加一节"依赖基线"：记录两项目约定对齐的版本，以后升级两边同步。

**验收**：目标包版本与 zcode app 对齐；双绿；通知/选图/版本显示冒烟通过。

**风险**：中。大版本升级可能有 Android 平台侧变更（gradle/manifest），**每次升完必须实打一次 APK**；不确定的包宁可不升，评估结论写进提交信息。

---

### [x] T10（P1·S）协议双端一致性测试（收编审计 A1 + B4）
> ✅ **完成（2026-09-14）**：**A1 确证为非问题**——两端集合逐项完全一致（CAS 15 项/ROW_TARGET 5 项），"applyFileRewind 重复"实为设计使然（rowTarget 是 casCommands 需 baseLogEpoch 的子集，允许交集）。快照锁落地：`test/fixtures/protocol_commands.json` + Dart 测试 3 项 + web vitest 测试 3 项（web 端测试从零起步首块，`npm test` = vitest run），CI web job 已启用。任一端改集合不同步 → CI 红。

**现状**：TS（web/src/protocol/constants.ts）与 Dart（lib/protocol/constants.dart）的 CAS_COMMANDS / ROW_TARGET_COMMANDS 集合无比对测试，漂移只能靠人眼（审计 A1 疑似已发现一处重复，未确认真重复）。

**步骤**：
1. **先做 A1 的确证**：按审计建议人工 diff 两端集合，确认 `applyFileRewind` 是否真重复，结果写进 `docs/BUGFIXES.md`；
2. Dart 侧写一个测试：从 `constants.dart` 生成集合 JSON 快照入 `test/fixtures/cas_commands.json`；
3. web 侧写 Node 单测（vitest 已在用）：import TS 集合 deepEqual 该快照。任一端改协议集合而不同步另一端 → CI 红（T2 的 workflow 加 `paths: ['web/src/protocol/**']` 触发 web 测试，或并入现有 web 测试任务）；
4. web 端协议测试从零起步（审计 B4）：本测试即第一块基石，够用不铺开。

**验收**：两端集合有自动化锁；故意在 Dart 侧加一个 CAS 命令不同步 TS → 测试红。

**风险**：低。若 A1 确证为真重复，修复是一个独立小提交（协议变更须同步 AGENTS.md 状态层 + `docs/API.md`）。

---

### [ ] T11（P2·S）动效与重建范围打磨

**现状**：滚动/动画逻辑成熟（锚行补偿、水位机制），但动画时长/曲线魔法数散落；ListenableBuilder 仅 5 处（T7 拆片后自然收窄重建范围）。

**步骤**：
1. 新建 `lib/motion.dart`（同 zcode app 方案）：`kDurFast=150ms / kDurNormal=220ms / kDurPage=300ms / kCurveOut / kCurveInOut`，全库字面量等值替换；
2. 重建范围收窄**合并进 T7 各步**（拆一片收窄一片），本任务不单独做。

**验收**：动画参数唯一出处；测试全绿。

**风险**：低。纯等值替换，不调手感。

---

## 3. 执行顺序与依赖

```
T1(卫生) → T2(CI+test.sh) → T3(FVM) → T4(lint) → T5(探针隔离)     # P0 五连,约 1-1.5 天
T8(markdown迁移, 独立) / T10(协议一致性, 独立)                      # 可穿插,与谁都无冲突
T7(app_controller 切片) ─→ T11(动效/重建收窄尾巴)
T6(chat_page 分解, XL, 最后)   # 与 T7 串行,避免 rows/chat 区双改
T9(依赖对齐) 独立,建议在 T8 后(同碰 pubspec)
```

- P0 五连无相互依赖外的约束，一个会话可清 2-3 个。
- **T6 与 T7 串行**是唯一硬约束（都动 chat/rows 区）；建议先 T7（收益立现：重建范围收窄）后 T6（纯搬运，工作量大但风险已被 T7 摊薄）。
- 每任务合入后 CI 绿灯再开下一个（T2 完成后自动成立）。

## 4. 完成后的目标形态（对照调研标准）

| 调研标准 | 本项目落点 |
|---|---|
| 分层与依赖方向 | app_controller 薄组合根 + 4 切片，页面只听自己的 slice（T7） |
| 巨文件治理 | chat_page 7062→≤800，rows 按行类型归位（T6） |
| 工程化门禁 | CI + FVM + 严格 lint + test.sh（T2/T3/T4） |
| 测试卫生 | 真实测试/探针分居，探针有 README（T5）；协议双端有锁（T10） |
| 依赖健康 | 停更包迁走 + 姊妹项目基线对齐（T8/T9） |
| 与审计闭环 | A1→T10、B1/B2→T7、B3→T2、B4→T10，审计发现全部落地 |
| 架构克制 | 不上 Riverpod/go_router/l10n/monorepo、不动五层协议栈、不删探针（1.3 节） |
