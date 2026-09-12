# zremote 交接文档（HANDOVER）

> 交接对象：接手 bug 修改的外部 Agent（DeepSeek）。零上下文自包含，读完即可开工。
> 交接日期：2026-09-11　交接方：ZCode 写手会话
> **工作模式（用户指定）：单智能体 + 用户直接指挥，按标准流程修 bug。**
> 不使用双智能体协作流程；`COLLAB.md` 是历史档案已冻结，**不要**续写它的任务队列/锁机制。

---

## 一、项目是什么

**zremote**：ZCode 远程会话的 Android 客户端（Flutter）。手机/平板通过中继连上桌面端
ZCode：任务列表、聊天（含图片/代码块/Markdown）、计划、权限审批、用量统计、自动化管理。

五层协议栈（自底向上）：Relay WebSocket（wss+HMAC proof）→ 信令配对（sid+hash）→
rpc-frame 分片（CRC）→ Channel IPC → 业务方法（ConversationV4/workspace/task/…）。
协议是逆向产物，**改协议层前必读协议文档**。

## 二、路径与环境（硬信息）

- **项目根**：`D:\tools\zremote-new`（唯一工作目录，Git 已重建，单分支 `master`）。
- **旧仓库** `D:\tools\zremote`：.git 对象库损坏，**已封存，禁止读写**（代码已全部抢救）。
- **桌面端数据**（只读取证用）：`C:\Users\chengge\.zcode\v2\`——`tasks-index.sqlite`
  （tasks/automations/automation_runs 表）、`logs\YYYY-MM-DD.log`（含全部 RPC 调用记录）。
- **APK 局域网发布**：构建后起 `python -m http.server 8777 --bind 0.0.0.0`
  （在 `build\app\outputs\flutter-apk\` 下），下载地址
  `http://192.168.31.194:8777/app-release.apk`（本机 IP 可能变化，用 ipconfig 确认）。
- **配对链接**（连真实桌面端跑探针用）：用户会提供，形如
  `https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…&mid=…`。
  **它就是凭据**：只走环境变量 `ZREMOTE_PROBE_LINK`，永不落盘、不入 Git、不入文档。

## 三、怎么验证 / 构建（每轮改动必做）

```powershell
cd D:\tools\zremote-new
flutter analyze        # 必须 0 issues
flutter test           # 必须全过（manual_* 前缀是无凭据自动 skip 的真实环境探针）
powershell -File build-flutter-apk.ps1   # 完整打包（后台跑，flutter-build.done 出现 EXIT=0 即成功）
```

- **红线**：`build-apk.ps1`（gradlew 直连）会跳过 Dart 编译，只可用于原生层增量验证，
  交付一律用 `build-flutter-apk.ps1`。
- 用户新机验收流程：APK → 局域网地址 → 手机安装 → 用户回报现象。

## 四、记忆体系（开工先读，收尾必写）

| 文件 | 性质 | 规则 |
|---|---|---|
| `AGENTS.md` | 状态层（快照） | 先读；改了项目行为**立即同步**并更新验证日期 |
| `docs/BUGFIXES.md` | bug 修复台账 | 每修一个 bug **当下**登记：现象/根因/修复/提交/验证状态 |
| `docs/LESSONS.md` | 踩坑日志 | 只追加不修改；每条必含「教训」；追加前查重 |
| `docs/API.md` + `docs/协议接口参考.md` | 协议双源 | 新增能力前先查参考文档的方法表（内含大量未接入能力） |
| `docs/ROADMAP.md` | 老排期 | 批次一~三已实现；仅当用户提及相关功能时对照 |

## 五、修 bug 标准流程（用户指定的节奏）

1. **领任务**：用户一句话描述问题 → 先**复述需求**给用户确认（这一步不能省）。
2. **只读排查**：读代码定位；涉及服务端行为时，可直接查桌面库/日志取证
   （sqlite3 / grep 日志，全是只读）；需要真实链路实验时向用户要配对链接跑探针
   （`test/manual_*_probe_test.dart` 是现成模式：环境变量门控、无凭据自动 skip）。
3. **报告根因 + 方案**：给用户确认后再动手（用户着急时会授权直接做，但复述不可免）。
4. **实现 + 自检**：`flutter analyze` 0 问题 + `flutter test` 全过，不过不提交。
5. **提交**：一行中文 message「类型(范围): 做了什么——为什么」，单分支 `master` 小步提交。
6. **登记**：BUGFIXES.md 当下记条目；行为变化同步 AGENTS.md；有普适教训追加 LESSONS.md。
7. **交付回执**：构建 → 发局域网 → 给用户「真机验收点」清单。

## 六、当前状态快照（2026-09-11 交接时）

**已交付并验证（代码在 baseline `5e4e8af` 内，详见 docs/BUGFIXES.md）**：
BUG-01 流式视口锚定；BUG-02 代码块完整铺开；BUG-03 切模型乐观更新；BUG-04 模型对账
以服务端为准；BUG-05 默认 GLM 5.3 Flash；BUG-06 删除补调 deleteSession；BUG-07 三重
护栏（qwen3.8-flash 基线+reconcileTaskModels 批量对账+失败一键切 GLM）；BUG-08 provider
id 修正（bigmodel-coding-plan）；另有工作区项目化三件套。

**待真机验收**（用户持有最新 APK）：模型切换秒切/重启保持、流式锚定手感、代码块铺开、
删除跨设备不复活、新会话默认 GLM。

**已知未解决 / 候选**（用户提了再做，勿自作主张）：
- 夜间批量回退的元凶确认为桌面端 `registryFallback`（provider 健康表变化→自动切
  `listModels()[0]`=欠费 qwen3.8-flash）；客户端护栏已挡，桌面端根治不在本项目范围。
- `workspace/setDefaultModel` 未暴露给移动端（探针实证通道全 miss）——跨设备默认的
  正解暂时做不了。
- `setTaskUnread`、`model-provider` 管理页：ROADMAP 里的低优残留。
- 桌面端曾有多个定时 automation（已停/删）+ 多会话并发 git 操作——这是旧仓库 .git
  损坏的最大嫌疑。**新纪律：绝不多个 Agent 同时在一个工作区跑 git。**

## 七、高危坑 TOP6（详细版在 docs/LESSONS.md）

1. **provider id 必须以 `prepareWorkspace` 返回为准**，不要信本地 config.json
   （BUG-08：start-plan vs coding-plan 之差 → notInRegistry 静默失败）。
2. **gradlew 单独打包跳过 Dart 编译**——交付必走 build-flutter-apk.ps1。
3. **删除会话要双通道**：task 通道 deleteTask + agent 通道 deleteSession，少一个就跨设备复活。
4. **qwen3.8-flash 是欠费回退基线**（在 `serverFallbackModelIds`），新基线出现要补进集合。
5. **配对链接就是凭据**，只走环境变量，用完可让用户重置。
6. **同一工作区禁止多 Agent 并发 git 操作**（损坏旧仓库的元凶）。

## 八、风格与语言

- 代码注释、提交信息、看板/文档全部中文；注释只写代码看不出来的 why。
- 提交前 `git status` 确认只提交本改动相关文件；文档与代码同步提交。
- 对用户汇报：先结论，再证据；不确定就说不确定，不许编。
