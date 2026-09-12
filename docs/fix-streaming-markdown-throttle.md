# 变更说明：流式 Markdown 重排节流 200ms

> 分支：`fix/streaming-markdown-throttle` → `develop`　提交：`a45d04f`
> 日期：2026-09-06　关联诊断：《zremote-对话刷新与模型切换崩溃诊断.md》#4

## 问题

流式回复期间每 50ms 微批到达，`MemoMarkdown` 对正在增长的那条回复做**全量 markdown parse**：单次 O(n)、n 随回复增长线性变大，几千字回复尾部每秒约 20 次全量解析全部压在 UI 线程——"越流越卡、刷新慢"的大头。原有记忆化只对"文本没变"生效，流式行每批文本必变。

## 修复（lib/ui/rows.dart）

1. `MemoMarkdown` 新增 `streaming` 参数（默认 false）：流式期间重排节流到 **200ms/帧**——距上次实际重排不足 200ms 时沿用旧缓存，跳过本次 parse；显示延迟 ≤200ms，肉眼无感。
2. **流式结束保证终态**：`streaming` 翻 false（或最终文本到达）时绕过节流立即全量渲染，不丢尾字。
3. `AssistantBlock` 与 `SubagentCard` 两处调用点接线 `row['state'] == 'streaming'`。

## 验证

- `flutter analyze` 0 问题，66 测试全过
- 长回复（数千字）流式期间 UI 线程 parse 次数从 ~20/s 降到 ~5/s
- 流式结束后正文与逐字版本完全一致（终态渲染不受节流影响）
