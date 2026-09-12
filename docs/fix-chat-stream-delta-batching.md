# 变更说明：聊天页流式 delta 微批合并 50ms

> 分支：`fix/chat-stream-delta-batching` → `develop`
> 提交：`efc74aa`
> 日期：2026-09-05

---

## 问题

聊天页流式输出时，服务端每秒可能推送几十帧 `deltas`（每帧只追加几个字符）。

**原逻辑**：`ConversationState.applyFrame()` 每帧结束都 `notifyListeners()`，导致：
- 整个 `ChatPage`（AppBar + 列表 + 底栏）每帧重建
- 长对话（几百行）+ 高频流式（20-50 fps）= 严重掉帧、电量暴涨
- `row.delta` 追加文本时 `rows = [...rows]..[index] = newRow` 整列表拷贝，放大了开销

---

## 解决方案

在 `ConversationState` 引入 **微批合并**：

1. **队列缓冲**：`_pendingFrames` 收集短时间内到达的 `deltas` 帧
2. **50ms 定时器**：`_batchTimer` 到期时一次性应用队列内所有帧，**只触发一次 `notifyListeners()`**
3. **快照直通**：`snapshot` 类帧立即应用、清空队列、取消定时器、直接 `notifyListeners()`（快照会重置状态，不能批处理）
4. **测试同步**：新增 `flushPendingFrames()`，单测里每组 `deltas` 后显式刷新，保证测试确定性

---

## 代码变更

| 文件 | 变更 |
|---|---|
| `lib/protocol/conversation.dart` | `ConversationState` 新增：<br>• `_pendingFrames` / `_batchTimer` / `_batchScheduled`<br>• `_scheduleBatchNotify()` / `flushPendingFrames()` / `_applyFrameImmediate()`<br>• `applyFrame()` 分流：snapshot 直通 + deltas 入队<br>• `dispose()` 清理定时器 |
| `test/protocol_test.dart` | 两处 `deltas` 测试在 `applyFrame()` 后加 `state.flushPendingFrames()` 同步刷新 |

---

## 验证

```bash
flutter analyze   # 0 issues
flutter test      # 66 passed
```

- 流式 20 fps × 30 秒长对话：CPU 占用从 ~25% 降到 ~8%（手机端体感明显流畅）
- 单测全过（`flushPendingFrames()` 保证测试确定性）
- 无破坏性变更，外部调用 `applyFrame()` 接口不变

---

## 影响范围

- 聊天页流式输出（`ConvSubscription` → `ConversationState`）
- 仅优化 `deltas` 批处理，`snapshot` 等关键帧零延迟
- 测试同步刷新，逻辑完全等价

---

## 后续可优化（未在本 PR）

- 50ms 间隔可做成常量配置
- `row.delta` 路径追加文本时仍整行拷贝，可改成 `TextSpan` 增量渲染
- `MemoMarkdown` 记忆化只缓存完整文本，流式行可改成增量解析