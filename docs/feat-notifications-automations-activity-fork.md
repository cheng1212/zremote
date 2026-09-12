# 变更说明：新增功能五连（通知/定时任务/抽屉/活动面板/会话分叉）

> 分支：`feat/task-notifications` → `develop`（850a795 / f33cf0a / 8bb641f / 9bfa2b0 / e92c44e）
> 日期：2026-09-06　UI 全程延续「柑橘晨光」主题规范
> 均经真实桌面端探针实测接口形状后实现

---

## N1 通知（`850a795`）

- **触发**：sessions-index 帧驱动的 phase 变迁检测（`_watchTaskEvents`）：
  活跃态（running/prewarming）离开 → **完成 / 中断 / 报错**；`pendingInteraction` 新出现 → **等待你的确认**。
- **防轰炸**：首帧快照不响（prev==null 跳过）；静止态之间变化不响；等待确认持续挂着不重复响（`detectTaskEvent` 纯函数，4 单测）。
- 依赖 `flutter_local_notifications`；Manifest 加 `POST_NOTIFICATIONS`/`VIBRATE`；高优先级渠道 `task_events`；通知失败静默不挡主流程。
- 我的页加开关（`NotificationService.enabled`，默认开）。
- 边界：App 被杀后收不到（无推送服务）；Android 13+ 首启请求通知权限。

## N2 定时任务页（`f33cf0a`）

- **探针全链路实测**（真实桌面端）：`listAllAutomations` / `createAutomation` / `setAutomationEnabled` / `runAutomationNow`（返回 `{status:queued}`）/ `deleteAutomation` 全部走通；**`nextRunAt`（毫秒）存在 → 倒计时可行**。测试自动化已删除无残留。
- `automation_view.dart` 纯逻辑：AutomationView / parseAutomations / automationCountdown（秒→分→时→天梯度）。
- `AutomationsPage`：启用中优先 + 下次执行升序；每秒倒计时徽章（「下次 X 分 Y 秒」）；生命周期状态色（active=橘/completed=青/failed=玫红/paused=柠黄）；启用开关、立即运行、删除确认。
- 我的页入口（显示「N 个启用中」角标）；会话页汉堡抽屉同样可进。
- 定位说明：**创建**定时任务的正确方式是在对话里让 ZCode 建（agent 工具）；移动端负责查看/控制/倒计时。

## N3 汉堡抽屉（`8bb641f`）

- 会话页 AppBar 收敛：只留 relay 徽章 + ☰。
- 抽屉：刷新会话列表 / 批量管理 / 定时任务 / 重新连接 / 断开连接（danger 色）。
- 断开连接保留原语义（popUntil 回配对页）。

## N4 活动面板（`9bfa2b0`）

- `activity_view.dart` 纯逻辑：`parseActiveWorks`（snapshot.control.activeWorks，桌面 schema kind 枚举：主回合/前台子代理/压缩/目标校验/目标续跑/插话转向）+ `streamingSubagents`（rows 中 state=streaming 的 subagent 行）+ 运行时长。
- 聊天页 AppBar 活动按钮：有活跃工作时亮葡萄紫 Badge 显示数量；底部弹层实时刷新（工作=葡萄紫，子代理=青，PulseDot 动画）。

## N5 复制会话 ID + 分叉（`e92c44e`）

- **复制会话 ID**：任务卡长按菜单新项（Clipboard + flash 提示）。
- **从此分叉新会话**：assistant 行长按菜单新项。`ZApp.forkAssistant` 走 CAS 命令 `forkAssistant`（target=rowId+entityId），解析 `result.sessionId`（探针实测 accepted，测试分叉已删除无残留）；分叉成功直接打开新会话（标题=原标题·分叉）。
- **明确边界**：跨会话「凭 ID 读记忆」协议无此接口，未实现；`forkAssistant` 是官方继承上下文的正解，已接 UI。

---

## 验证

- `flutter analyze` 0 问题；`flutter test` 86 全过（+5：detectTaskEvent 4 个 + 既有回归）。
- 探针工具入库：`manual_automations_probe_test.dart`、`manual_automation_roundtrip_test.dart`（create→list→enable→delete 往返，无残留）、`manual_fork_probe_test.dart`（fork→delete 清理）。

## 审核提示

- 通知依赖新增（flutter_local_notifications ^18），release 构建首次需要完整 pub get。
- automations 倒计时依赖桌面端时钟与手机时钟基本同步（绝对时间戳比较）；时差大的设备显示会偏。
- 活动面板的 activeWorks 字段为桌面端内部 schema 逆向所得（zcode.cjs），若桌面端升级改字段，面板降级为空列表（安全）。
