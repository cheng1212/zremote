# HANDOVER-Z — zremote 班次交接手册

> **这份文档的定位**：zremote 项目的**班次交接运行手册**，由 Z 维护，随班次滚动更新。
> 与 `docs/` 里其他交接文档的分工：
> - `HANDOVER.md` —— 项目总览 + 修 bug 标准流程（长期有效，结构性的）
> - `HANDOVER-TESTING.md` —— **任务书**：某一班的测试循环该测什么（换班即作废重写）
> - **`HANDOVER-Z.md`（本文）** —— **账本 + 交接仪式**：本班干了什么、验证到哪一步、下班的入场动作（滚动维护）
>
> **给接手者的第一句话**：本文「零、三分钟上手」读完就能干活，不用读别的。
>
> **最后更新**：2026-09-18 02:10（Z）— ⚠️ **本班发生方向性变更，请先读「零」和「一」**

---

## 零、三分钟上手（只读这三节就够开工）

**你是谁**：接手 zremote 的 agent。项目唯一所有者是用户（他操作手机 + 桌面两端，真机验收）。单智能体模式，**用户直接指挥**，不走协作看板（`COLLAB.md` 已冻结，**不要**续写其任务队列/锁机制）。

### ⚠️ 方向性变更（2026-09-18，用户决定，违反必错）

**Flutter 弃用，Web 端成为主战场。**

- 用户原话：「**我的意思是 flutter 我不要了 太麻烦了 web 要适配移动端 或者你可以做两套**」
- **`lib/`（Flutter，24,021 行）冻结，不再投入开发**。但**不要删**——它是 Web 重写的
  唯一参照（含大量踩坑后的正确实现），删了就没图纸了。
- 主战场是 **`web/`（Vue 3 + Pinia + Vite + TS）**，目标是**移动端优先**。
- 桌面端形态：**一套代码 + 两套布局**（移动：单列全屏；桌面：侧栏 + 主区）。
  **不要开两个代码库**——协议与业务逻辑是价值主体，两份必然漂移
  （`AUDIT-2026-09-13.md` 的 A1 已经证实这类漂移真实存在）。

**项目是什么**：`D:\tools\zremote-new`，远程操控桌面端 ZCode 的**客户端**（原 Flutter Android，现转 Web）。
Git 单分支 `master`，remote 有两个：`origin`（GitHub，日常用）+ `backup`（本地 bare）。

**开工前必须先跑的两个命令**（不过不许提交任何东西）：
```bash
cd D:/tools/zremote-new/web
npm run typecheck        # 期望 0 错误
npm test                 # 期望 122 全过（只许增不许减）
```

> Flutter 侧（仅在需要查参照实现时跑）：
> ```bash
> cd D:/tools/zremote-new
> flutter analyze
> no_proxy='localhost,127.0.0.1,::1' NO_PROXY='localhost,127.0.0.1,::1' flutter test
> ```
> ⚠️ **`flutter test` 必须带 `no_proxy`**：本机 WorkBuddy 会话会注入
> `http_proxy/https_proxy=http://127.0.0.1:54135`，不绕过会让 flutter_tester 回连被拦，
> 全线报 `WebSocketException: Invalid WebSocket upgrade request`。**这不是代码问题。**
> `git fetch/push` 到本地 bare remote 同理加 `no_proxy='*'`。

**三分钟上手后干什么**：看「一、当前主线状态」，那就是当前主线。

**长期规约（用户 2026-09-14 定，违反必错）**：**每次打 APK 分发前必须升 `pubspec.yaml` 版本号**——`version: x.y.z+N` 的 z 和 N 各 +1。抽屉里显示「版本 x.y.z+N」，用户靠它核对手机上跑的是不是新包；不升版本不许打包分发。
（注：Web 转正后这条对 Web 的对应物是——**改了行为要能一眼看出是哪版**，别让用户对着一模一样的界面猜。）

---

## 一、当前主线状态（本节随班次覆盖，永远写最新的）

**状态：Web 端第一批可用功能已落地 —— 从「加载不出来」修到「能用」**

| 环节 | 状态 | 证据 |
|---|---|---|
| 方向：Flutter → Web | ✅ 已定 | 用户 2026-09-18 明确 |
| Web 功能拆分（112 交互点） | ✅ 已建 | `docs/WEB-FEATURE-MAP.md` |
| **信封解包修复（聊天记录加载不出来）** | ✅ 已修 + 已提交 | commit `c8f020f` |
| **deltas 五态修复（流式不增长）** | ✅ 已修 + 已提交 | commit `170d6d6` |
| 会话加载 / 刷新 | ✅ 已实现 | `SessionsView.vue` + `stores/app.ts` |
| 会话列表 | ✅ 已实现 | 同上 |
| 聊天记录（7 种行类型） | ✅ 已实现 | `ChatView.vue` |
| 发送 / 停止输出 | ✅ 已实现 | 同上 |
| 询问 / 审批面板 | ✅ 已实现 | `components/AskPanel.vue` |
| 附件上传（相册/相机/文件） | ✅ 已实现 | `lib/upload.ts` + `attachmentPut` |
| 双绿（typecheck + test） | ✅ 通过 | 122 全过、0 类型错误 |
| **真机复测** | ⬜ **未做 —— 当前卡点** | 需用户手机连局域网验证 |
| Markdown 渲染 | ⬜ 未做 | 体感落差最大的一块 |
| 模型/模式弹层 | ⬜ 未做 | 依赖 `getTaskConfigOptions({taskId})` |
| 用量页 / 自动化页 / 我的页 | ⬜ 未做 | 独立域，整域为零 |
| 通知 / PWA | ⬜ 未做 | **受 HTTPS 硬约束**（见「四」第 13 条） |

### 本班两个根因级修复（都值得记住）

**① 信封解包 —— 「聊天记录和电脑不同步，加载不了」**

服务端推来的**不是逻辑帧本身**，而是**信封**：
```
{kind:"complete", topic, subscriptionId, frame:{ payload:{kind:"snapshot"|"deltas",…} }}
                                                        ↑ 真正的帧在下一层
{kind:"fragment", logicalFrameId, fragmentIndex, fragmentCount, dataBase64}
```
原实现把信封当帧、直接读 `data.payload` → **每一帧都被静默丢弃**。
长会话快照还会被切成 ≤64 片 base64，原实现**完全没有组装逻辑**。
修复见 `web/src/protocol/subscription.ts`（对齐 Flutter 的 `_SubBase`）。

**② deltas 形状 —— 流式回复永远不增长**

原实现按 `deltas[].upsert` / `deltas[].delete` 取值，而真实协议是 **`op` 五态**：
`row.appended` / `row.upserted` / `row.removed` / `row.delta` / `state.updated`。
键名对不上 → 每个 delta 被静默忽略 → 只有重进会话（整份快照）才看得到内容。
修复见 `web/src/lib/convRows.ts`（有回归测试钉死形状）。

**教训（对 Web 端尤其重要）**：用户那句「**很多功能要看后台接口后台数据改变才是真的改变**」是对的——
这两个 bug 都是**界面看起来写完了、数据根本没进来**。判断一个功能是否真的实现，
要能回答「调哪个后台方法」「改了后台什么数据」，不能只看 UI 有没有渲染。

### 复测点（用户真机验证用）

1. 打开 Web → 配对 → 应能看见**会话列表**（不是空列表）
2. 点进任意会话 → **聊天记录应该完整出现**（不是空白）
3. 发一条消息 → 应看到**流式逐字增长**（不是发完没反应）
4. 回复中 → 「停止」按钮应出现并能中断
5. 点 ＋ → 选图片/文件 → 应看到上传进度 → 发出后消息带附件

---

## 二、本班台账（滚动追加，倒序，最新在最上）

> 格式：`时间 | 动作 | 结果 | 证据/提交`
> **只记有跨会话价值的事**，不记临时路径与工具报错。

| 时间 | 动作 | 结果 | 证据/提交 |
|---|---|---|---|
| 09-18 02:07 | 修「聊天记录加载不出来」（信封解包）+ 附件上传 | 122 测试全过，已推 | `c8f020f` |
| 09-18 01:54 | 补询问/审批面板（不渲染会话永久卡死） | 94 测试全过，已推 | `33eb89e` |
| 09-18 01:49 | Web 第一批：会话加载/刷新/列表/聊天记录/发送/停止 | 66 测试全过，已推 | `170d6d6` |
| 09-18 01:36 | 建 Web 功能地图（13 域 112 交互点，锚定后台接口+数据变化） | 完成，已推 | `5f650cd` |
| 09-18 01:30 | 用户定方向：Flutter 弃用、Web 为主、适配移动端 | 记录在案 | 本文「零」 |
| 09-18 01:20 | 用户交办：全权接手 + 三步法拆解全部功能按钮 | 已复述待确认 | `memory/2026-09-18.md` |
| 09-12 20:47 | 第四次 `.git` 损坏事故 → 重建仓库 + 首次接上 remote | 恢复完成 | 见「四」第 14 条 |
| 09-12 17:58 | 修复「翻页触发 resync 风暴」（聊天记录自己翻回最开头） | 双绿（213 测试） | `5c18032`（**已随事故丢失**） |

**【遗留未验证项 —— 接手者必测】**
- Web 端真机复测（上面 5 个复测点，**最高优先**）
- Flutter 侧的 8 项真机验收清单仍在 `docs/ROADMAP.md` 末尾 ——
  **但 Flutter 已弃用，这些项转为「Web 端对应功能是否达标」的检查表**

---

## 三、环境硬信息（接手者照抄即用）

| 项 | 值 |
|---|---|
| 主战场 | `D:\tools\zremote-new\web`（Vue 3 + Pinia + Vite + TS） |
| Flutter 参照（冻结） | `D:\tools\zremote-new\lib`（**不要删，不要开发**） |
| 参考实现（**协议不同**） | `D:\workspace\zcode-dev\web`（React；跑的是 zcode-server 的 REST 协议，**协议层不可复用**，UI/交互模式可参考） |
| 旧仓库 | `D:\tools\zremote`（**已封存，禁止读写**） |
| 本机 IP | **192.168.31.194**（WLAN；网络变动需重新确认） |
| Web 启动 | 双击 `web\启动.bat`（`npm run dev -- --host`，手机用 Network 地址） |
| 真机 | Redmi Turbo 3，adb id `4b2a7996`，分辨率 1220x2712 @480dpi |
| adb 路径 | `D:/Android/platform-tools/adb.exe` |
| 桌面日志 | `C:\Users\chengge\.zcode\v2\logs\YYYY-MM-DD.log`（grep 加 `-a`） |
| 桌面 DB | `C:\Users\chengge\.zcode\v2\tasks-index.sqlite`（**必须拷临时副本查**） |
| 桌面反解 | `D:/Users/chengge/AppData/Local/Programs/ZCode/resources/app.asar`（node 读 buffer，indexOf 找上下文） |

**探针**：`test/manual_*_probe_test.dart`，环境变量 `ZREMOTE_PROBE_LINK` 门控。
⚠️ **配对链接是单终端的** —— 手机连着时探针配不上（TimeoutException），**需让用户断开手机**再跑。

---

## 四、高危坑（踩过至少一次，血泪）

1. **`flutter test` 不绕过代理 = 全线假失败**。`no_proxy` 是硬要求。
2. **禁 `git push --force`**；单分支 `master` 小步提交，中文 message。
3. **双绿才提交**：Web 端 = `npm run typecheck` 0 错误 **且** `npm test` 全过；Flutter 端 = `flutter analyze` 0 **且** `flutter test` 全过。不过不提交。
4. **高频提交**（用户 2026-09-18 明确要求「高频构建提交」）：每完成一个可验证的小块就提交 + push。
5. **给用户的链接必须是纯文本代码框** —— 用户强调过多次「链接要直接可以复制」。
6. **修任何东西先取证再动手**：桌面端行为反解 app.asar；DB 拷副本查；日志 `grep -a`。
   **禁止凭印象写协议代码** —— 新接口第一次接入就实测（BUG-35 教训）。
7. **`workspaceScopes` 必须是对象数组，不是字符串数组**（BUG-35，发字符串会让桌面
   `normalizeWorkspaceKeys` 对 `undefined` 调 `.trim` 崩）。
8. **同一工作区禁止多 Agent 并发 git 操作**（旧仓库 `.git` 损坏的最大嫌疑）。
9. **`patch` 写文档后必读回校验**：曾出现写入内容被环境改写/截断。
10. **手机装机用 `install -r` 保留数据** —— 配对信息不丢，省一次重新配对。
11. **`build-flutter-apk.ps1` 在 WorkBuddy 会话里跑不通**：脚本内用 `Start-Process` 调
    flutter，被会话安全策略拦。可用解：`& "D:\flutter\bin\flutter.bat" build apk --release *> log`。
    （Flutter 已弃用，此条仅存档。）
12. **release 包拿不到首异常明细**：logcat 只会打
    `Another exception was thrown: Instance of 'DiagnosticsProperty<void>'`。
    要定位必须加全局 `FlutterError.onError` 写日志。（Flutter 已弃用，此条仅存档。）
13. **⚠️ 非安全上下文（局域网 http）能力被砍**（2026-09-18 实证，**影响移动端主要用法**）：
    `crypto.subtle` 与 `crypto.randomUUID` **只在 https / localhost 可用**，
    手机连 `http://192.168.x.x:5173` 时两者都是 `undefined`。
    连带影响：
    - `crypto.randomUUID()` 直接抛 → 已用 `getRandomValues` 自拼 v4 降级
    - 附件 SHA-256 校验算不出 → 已用纯 JS 实现降级（NIST 向量测试钉住）
    - **`Notification` API 与 `Service Worker` 直接不可用** → 通知、PWA 安装**做不了**
    对策：要通知能力必须走 https（自签证书 / mkcert / 公网部署），
    或者接受「Web 端无后台通知」。**这是硬约束，不是能绕的 bug。**
14. **`.git` 事故已发生四次**（09-11 三次 + 09-12 一次），模式一致：
    写操作 → `.git/refs/` 整目录被删 + 对象库被裁。真凶未定位。
    **硬规矩**：任何 `.git` 写操作前先把工作区快照到仓库外，并校验；
    发现仓库无 remote 立刻停下来处理（09-12 就是无 remote 裸奔 7 小时，丢了 6 个提交）。
    详见 `~/.workbuddy-ai/MEMORY.md` 的「.git 写操作前先做工作区快照」。
15. **桌面端会自动升级并删接口**（2026-09-17 实证）：`prepareWorkspace(scope)` 已被移除
    （调用即 `Method not found`），改调 `getTaskConfigOptions({taskId})`。
    **客户端必须对每个方法都能优雅降级**，且每接一个接口都要实测。

---

## 五、风险与待办（接手者需知晓，勿自作主张处理）

| # | 风险/待办 | 说明 | 建议 |
|---|---|---|---|
| 1 | **Web 端真机未复测** | 代码层全绿，但用户还没在手机上验证过 | 最高优先，先推给用户复测 |
| 2 | **通知能力缺失** | 见「四」第 13 条，受 https 硬约束 | 等用户拍板：自签证书 / 公网部署 / 接受无通知 |
| 3 | **Flutter 24,021 行的去留** | 已冻结但未删，占仓库体积 | **不要擅自删**——它是重写图纸。等 Web 功能对齐后再议 |
| 4 | **Web 端无 CI** | `origin` 已配 GitHub，但 `.github/workflows/` 不存在 | 可补（优化方案 T2 有 Flutter 版现成经验） |
| 5 | **1 分钟提醒 automation** | 桌面端可能仍在跑，会往会话里塞消息 | 测试流式时是天然素材；**用户没让删就别删** |
| 6 | **协议双端一致性测试** | TS/Dart 的 CAS 集合有共享 fixture 锁（`protocol-commands.test.ts`），但仅此一项 | 其余集合（ROW_TARGET 已有）可继续补 |

---

## 六、协作规约（用户长期偏好，务必遵守）

- **先复述需求再动手**，不确认不开工（用户着急时会授权直接做，但复述不可免）
- **只读排查在前**；根因 + 方案报给用户，**点头才改代码**
- 用户说 **「继续 / 不要停 / 直接不停」就是字面意思**，别停下来问；
  他说「不在电脑边」时更不要问，做完留报告等他看
- **产出型任务（写作、提示词、设计、方案）一律先访谈收敛再交付**，不许自己拍板
- 需要用户配合的（点手机弹窗、给配对码、断开手机占用）**直接说清楚要他做什么**
- 用户报障多为截图/录屏/一句话，**根因常在桌面端或协议层**，App/Web 层只是症状 —— 别急着改 UI
- **对用户汇报：先结论，再证据；不确定就说不确定，不许编**
- 每个 bug/改进在 `docs/BUGFIXES.md` 登记一条（现象/取证/根因/修复/验证/教训）
- 活文档改相关处要同步：`BUGFIXES.md`、`SCAN-MATRIX.md`、`FEATURE-INVENTORY.md`、
  `WEB-FEATURE-MAP.md`、`KNOWN-LIMITS.md`、`AGENTS.md`

---

## 七、常用命令速查

```bash
# —— Web 端（主战场）——
cd D:/tools/zremote-new/web
npm run typecheck                 # 必须 0 错误
npm test                          # 必须全过（当前 122）
npm run build                     # vue-tsc + vite build
npm run dev -- --host             # 手机可用局域网 IP 访问（或双击 启动.bat）

# —— Flutter 端（仅查参照实现时）——
cd D:/tools/zremote-new
flutter analyze
no_proxy='localhost,127.0.0.1,::1' NO_PROXY='localhost,127.0.0.1,::1' flutter test

# —— git（高频提交 + 立刻推）——
git add -A && git commit -m "中文消息"
git push origin master            # 需要网络；本地 bare 用 no_proxy='*'

# —— 真机 ——
D:/Android/platform-tools/adb.exe -s 4b2a7996 shell am start -n com.example.zremote/.MainActivity
D:/Android/platform-tools/adb.exe -s 4b2a7996 logcat -v time | grep flutter

# —— 取证 ——
grep -a "zcode-task\." C:/Users/chengge/.zcode/v2/logs/2026-09-18.log | grep -av "OK ("
```

---

## 八、交班仪式（下班前必做，缺一不可）

离班前完成以下六项，接手者才不用考古：

1. **更新本文「一、当前主线状态」** —— 写清卡点、下一步、验证到哪一步
2. **追加本文「二、本班台账」** —— 一行一条，含提交号
3. **提交台账** —— 每个改动双绿后立刻提交 + push（中文 message）
4. **登记 `docs/BUGFIXES.md`** —— 本班每个 bug/改进一条，格式照已有条目
5. **同步 `docs/WEB-FEATURE-MAP.md`** —— Web 端功能完成度变化就更新
6. **同步 `AGENTS.md`** —— 项目行为有变化就更新，并更新验证日期

> **交接的验收标准**：接手者读完「零、三分钟上手」+「一、当前主线状态」就能直接开工，
> **不需要问你任何问题**。做不到就说明交班没写完整。

---

_本文由 Z 维护。改了本文记得告诉用户 —— 这是班次之间的接力棒。_
