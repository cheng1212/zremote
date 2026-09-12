# 变更说明：任务列表 Token 角标定时器仅在前台运行

> 分支：`fix/task-token-ticker-background` → `develop`
> 提交：`75eb237`
> 日期：2026-09-05

---

## 问题

`TasksPage` 在 `initState` 里启动了一个 `Timer.periodic(const Duration(seconds: 30))`，每 30 秒调用 `app.refreshTaskTokens()` 拉取任务卡的 token 角标。

**缺陷**：
- 定时器**无视 App 生命周期**，后台/锁屏/杀进程前依然在跑
- 用户不在任务页、甚至 App 在后台时，依然每 30 秒发一批 RPC 请求（最多 4 并发 × 任务数）
- 浪费电量、流量、服务端资源；手机待机时也会被唤醒

---

## 解决方案

将定时器**上移到 `ZApp`（全局状态单例）**，并接入 `WidgetsBindingObserver` 生命周期：

1. **只在前台刷新**：`_appInForeground` 标记跟随 `AppLifecycleState.resumed`/`paused`/`inactive`/`detached`
2. **回前台立即刷一次**：`didChangeAppLifecycleState` 里检测到 `resumed` 时直接 `refreshTaskTokens()`
3. **测试友好**：构造函数不直接注册 observer，改为 `_ensureTokenTicker()` 延迟初始化，避免测试环境无 `WidgetsBinding` 报错

---

## 代码变更

| 文件 | 变更 |
|---|---|
| `lib/state/app_controller.dart` | + `with WidgetsBindingObserver`<br>+ `_tokenTicker` / `_appInForeground` / `_tickerInited`<br>+ `_ensureTokenTicker()` / `_maybeStartTokenTicker()` / `didChangeAppLifecycleState()`<br>+ `connect()` 里调用 `_maybeStartTokenTicker()`<br>+ `dispose()` 里 `cancel()` + `removeObserver()` |
| `lib/ui/tasks_page.dart` | - 移除 `_tokenTicker` 字段<br>- 移除 `initState` 里的 `Timer.periodic`<br>- `dispose()` 里不再 cancel ticker |

---

## 验证

```bash
flutter analyze   # 0 issues
flutter test      # 66 passed
```

- 单测 `widget_test.dart` 仍通过（测试环境无 binding 时不注册 observer）
- 后台待机 5 分钟 → 无网络请求 → 回前台 → 立即刷新 token 角标

---

## 影响范围

- 任务列表页（TasksPage）token 角标刷新逻辑
- 全局 ZApp 生命周期行为
- 无破坏性变更，现有调用 `app.refreshTaskTokens()` 的地方不变（仍可手动触发）

---

## 后续可优化（未在本 PR）

- `_fetchTaskTokens()` 已有 4 并发限流，可考虑把 30s 间隔改成可配置
- `tokenFetchDue` 的 TTL（运行中 30s、空闲 5min）已在 `task_sort.dart` 定义，逻辑复用良好