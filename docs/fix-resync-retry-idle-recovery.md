# 变更说明：resync 重试 + 空闲丢帧恢复 + state 释放

> 分支：`fix/resync-retry-idle-recovery` → `develop`　提交：`9158c28`
> 日期：2026-09-06　关联诊断：《zremote-对话刷新与模型切换崩溃诊断.md》#3、1.3

## 问题

1. **resync 是断档唯一恢复通道且失败即放弃**：delta 断档（fromSeq≠seq）触发 `_resync`，失败只记日志无重试；看门狗只在 running/streaming 时兜底——**空闲时丢帧界面永久冻结**，只能手动下拉刷新。
2. **`_SubBase.dispose()` 从不调用 `state.dispose()`**：ConversationState（ChangeNotifier + 微批定时器）、SessionsIndexState 从不被释放，离开会话页后定时器残留。

## 修复（lib/protocol/conversation.dart）

1. `_resync` 失败自动重试 2 次，退避 1s/2s；`_disposed` 时立即中止。
2. 看门狗新增空闲兜底：连续 5 分钟无任何帧也触发一次 resync；resync 成功后快照帧刷新 `_lastFrameAt`，自动节流（每个静默期最多一次，约 12 次/小时 RPC 上限）。
3. `_SubBase.dispose()` 增加 `state.dispose()`，订阅释放时级联释放状态对象上的定时器与 ChangeNotifier。

## 验证

- `flutter analyze` 0 问题，66 测试全过
- 弱网断档 → resync 失败自动重试两次后恢复，界面不再冻屏
- 空开会话 5 分钟 → 日志出现 `idle xxxs, periodic resync` 一次，随后静默
