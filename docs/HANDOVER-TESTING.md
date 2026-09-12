# zremote 交接文档（写手 → 测试修改 agent）

> 2026-09-12 17:30 交接。你是接手者：项目唯一所有者是用户（手机+桌面端操作者），写代码的 agent 换成了你。
> 读完本文即可开工，所有背景都在这里和 docs/ 里。

## 一、项目与环境（硬信息）

- **代码库**：`D:\tools\zremote-new`（Git 单分支 master，中文 message，禁 force push）
- **是什么**：Flutter Android 客户端，远程操控桌面端 ZCode（电脑上那个 Electron 应用）
- **五层协议**：Relay WebSocket(wss+HMAC proof) → 信令配对(sid+hash) → rpc-frame 分片(CRC) → Channel IPC(zcode-task/zcode-agent 通道) → 业务方法
- **验证命令**：`flutter analyze`（0 问题）+ `flutter test`（当前 209 全过）。**每次提交前必须双绿**
- **打包发布**：`flutter build apk --release` → APK 在 `build\app\outputs\flutter-apk\app-release.apk`
- **局域网服务器**：`http://192.168.31.194:8777/app-release.apk`（python http.server，cwd=flutter-apk 目录；给用户链接必须给**纯文本代码框**，用户强调过多次"链接要直接可以复制"）
- **真机**：Redmi Turbo 3，USB 已连，adb id `4b2a7996`（`D:/Android/platform-tools/adb.exe`）
  - 分辨率 1220x2712 @480dpi（截图会被工具缩放，input 坐标按 1220x2712 算）
  - 手机上有 zremote 且已配对（数据保留，重装 -r 不丢配对）
- **模拟器**：AVD `gilded_test`（用户曾说过排除模拟器，但后来自动化时用过；真机优先）
- **桌面端**：`C:\Users\chengge\.zcode\v2\logs\YYYY-MM-DD.log`（grep 加 `-a`）；tasks-index.sqlite 只读要用临时副本
- **桌面端反解**：`D:/Users/chengge/AppData/Local/Programs/ZCode/resources/app.asar`（node 读 buffer indexOf 找字符串上下文，协议问题先反解取证）
- **参考项目**：`D:/zcode-dev/app`（Flutter，滚动方案的上游参照，见下文架构节）
- **探针**：test/manual_*_probe_test.dart，环境变量 `ZREMOTE_PROBE_LINK` 传配对链接门控；**注意配对链接是单终端的，手机连着时探针配不上（TimeoutException 配对超时），让用户断开手机再用**

## 二、当前进行到哪（最重要）

### 正在做：真机滑动回归测试（用户主动提出"我滑动你抓日志"）

**上一轮修了什么**：真机首测抓到 `RangeError (length): Invalid value: Only valid value is 0: 1` @ chat_page.dart `_buildList` itemBuilder——itemCount 与 itemBuilder 闭包读的 `rows` 不同步（流式区出列表改造后，翻页/摘行时序缝隙里 rows 变短，老 index 越界），**整个列表滑动失效的直接原因**。

**已修**（commit 待你在 log 确认，最新一条）：itemCount 改用 build 局部 `rowCount`；itemBuilder 加 `i<0||i>=rows.length` 越界保护（兜底空卡片）。已构建、已装机、已启动。

**你要做的测试**（手机现在应该停在那个 JavaStudy 长会话里；不在就：会话页 → 学习项目 → 点"创建 JavaStudy 项目整理…"卡）：

1. **基本滑动**：上下快滑/慢滑/轻甩——应跟手、惯性自然衰减、无跳动无回弹
2. **翻历史**：滑到接近历史尽头会自动翻页（600px 阈值）——**重点**：翻页时视口不应跳动、不应被"拽走"
3. **静置稳定性**：滑到历史某处停住 30s——视野应纹丝不动（BUG-32 自动回拖回归）
4. **流式期间**（需要活会话）：发条消息让模型回复，流式输出时上下滑——应完全跟手；翻到历史处停留，回复流式时视野不动（这是"流式区出列表"架构的主收益）
5. **logcat 监控**：`adb -s 4b2a7996 logcat -v time | grep flutter`，重点抓 `RangeError`/`EXCEPTION CAUGHT`/`Another exception`
6. 用户自己滑时你同步抓日志（他明确说过愿意配合"我滑动你抓日志"）

发现崩 → 定位 → 修 → analyze+test 双绿 → 中文 message 提交 → 重打 APK → adb 装机 → 继续测。循环。

### 同批在手机上待验证的（顺手全测）

- 流式回复落定瞬间是否平滑（流式面板→列表回插）
- 消息长按选择/复制按钮（自己消息右下小复制图标，点了变对勾）
- 助手输出长按拖拽选择、系统菜单是否中文（flutter_localizations zh）
- 排队消息：底部折叠栏（点标题展开）、重复消息不入队、队列消息不回显聊天流
- 通知：我的页 → 通知开关/铃声/震动；跨项目任务完成/报错弹通知（**上轮 BUG-35 已修 workspaceScopes 形状**，验证方法：A 项目发任务 → B 项目会话跑完 → 20s 内手机应弹通知）；锁屏可见
- 右上角活动按钮已删（用户点单），底部「任务」槽是唯一入口

## 三、架构关键点（改代码前必读）

1. **流式区出列表**（刚做的架构改造，借鉴 zcode-dev）：最后一条 streaming 的 assistantText 行从列表摘出，渲染在列表下方 `_StreamingPanel`（列表和队列栏之间），落定后回列表。理由：流式行在 reverse 列表内逐帧长高 = 历史被顶动 = BUG-27/28/32 家族共同根因。`_buildList(state, streamingRow:)` 的 `extracted` 逻辑和 `rows0`/`rows` 分工别动坏。
2. **reverse ListView**：index 0 = 最新端。offset≈0 是底部。
3. **锚定补偿**（_anchorAgainstGrowth/_queueAnchorGrowth/_applyAnchorGrowth）保留，但现在只服务离散扰动（面板出现/消失、翻页）。`olderMergeEpoch`（loadOlder 计数）让翻页增长不补偿——BUG-32 断环机制，别删。
4. **casCommands/rowTargetCommands**（protocol/constants.dart）：发会话命令要不要带 baseRevision/baseLogEpoch 按集合走，新命令先对桌面 zod schema（反解 app.asar）。
5. **桌面端 task 通道按参数里的 workspacePath 路由**，与桥无关（BUG-29 实证）——跨项目操作直发 RPC，**不要**为对齐 scope 切桥（桌面单桥架构，切桥=顶掉重连风暴）。
6. **通知**：NotificationService 双通道变四通道（铃声×震动），Android 渠道属性建后不可变。通知总开关关掉时全局轮询也停（_pollGlobalTaskEvents 首行）。
7. **全局轮询**：20s 一次 listTaskList(workspaceScopes=[工作区对象数组])，不受前台门控。**workspaceScopes 必须是对象数组不是字符串**（BUG-35，发字符串桌面端 normalizeWorkspaceKeys 会崩）。失败日志 5 分钟节流。
8. **状态对账**：RemoteSession.onRePaired → _reconcileAfterRePair（清 _livePhase、订阅 resync、列表重拉、4s 兜底重订阅）。突发事件后服务端为准。

## 四、协作规约（用户长期偏好，务必遵守）

- **修任何东西先取证再动手**：桌面端行为反解 app.asar；数据库 sqlite 拷临时副本查；日志 grep -a。禁止凭印象写协议代码——新接口第一次接入就实测（BUG-35 教训）
- **Git**：双绿（analyze+test）才提交；中文 message；不 force push
- **交付**：改完必重打 APK 上 8777，给用户纯代码框链接；先说结论再说细节
- **沟通**：用户说"继续/不要停"就是字面意思，别停下来问；但遇到需要用户配合的（点手机弹窗、给配对码、断开占用）直接说清楚要他做什么
- **用户报障多为截图/录屏/一句话**，根因常在桌面端或协议层，App 层只是症状——别急着改 UI
- **BUGFIXES.md**：每个 bug/改进登记一条（现象/取证/根因/修复/验证/教训），格式照已有条目
- **docs/** 里 BUGFIXES.md（30+ 条历史）、SCAN-MATRIX.md、FEATURE-INVENTORY.md、KNOWN-LIMITS.md、HANDOVER.md 都是活文档，改相关的要同步

## 五、已知遗留（按优先级）

1. **本测试循环**（上面第二节）——当前主线
2. 1 分钟提醒 automation（automation-1c46e0cb 之类）可能还在桌面端跑，会往会话里塞消息——测试流式时它反而是天然素材；用户没让删就别删
3. thinking/reasoning 行与工具卡仍在列表内（增长小、可接受）；极端长文流式面板会占大半屏（与参考实现一致）
4. 通知冷启动点击不跳转（无后台 isolate，平台限制，KNOWN-LIMITS 有记）
5. 历史探针需要 ZREMOTE_PROBE_LINK 时注意配对占用问题（见环境节）

## 六、常用命令速查

```bash
# 装机（保留数据）
D:/Android/platform-tools/adb.exe -s 4b2a7996 install -r D:/tools/zremote-new/build/app/outputs/flutter-apk/app-release.apk
# 启动
D:/Android/platform-tools/adb.exe -s 4b2a7996 shell am start -n com.example.zremote/.MainActivity
# 截图（分辨率 1220x2712，勿用缩放图算坐标）
D:/Android/platform-tools/adb.exe -s 4b2a7996 exec-out screencap -p > shot.png
# 滑动示例（上滑翻历史）
D:/Android/platform-tools/adb.exe -s 4b2a7996 shell input swipe 610 2200 610 700 250
# 桌面日志查手机调用
grep -a "zcode-task\." C:/Users/chengge/.zcode/v2/logs/2026-09-12.log | grep -av "OK ("
# 8777 服务器若卡死（单线程 http.server 会挂）：杀 pid 重启（cwd 必须是 flutter-apk 目录）
powershell -NoProfile -Command "Start-Process -FilePath 'D:/anaconda3/python.exe' -ArgumentList '-m','http.server','8777','--bind','0.0.0.0' -WorkingDirectory 'D:/tools/zremote-new/build/app/outputs/flutter-apk' -WindowStyle Hidden"
```

**开测吧。** 先复测滑动（第二节第 1-3 条，几钟就有结论），通过后把 4-6 条也过一遍。用户在旁边，有需要他配合的直说。
