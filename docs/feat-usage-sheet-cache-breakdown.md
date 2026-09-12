# 变更说明：用量弹层新增缓存命中率 + 上下文构成 + 实时刷新

> 提交：`3e32455`（develop）　日期：2026-09-06
> 附探针：`test/manual_usage_probe_test.dart`（打印会话 usage 完整 JSON）

## 背景

用户问：用量窗口还有哪些值得显示的数据？缓存命中率能不能算？

考古桌面端运行时 + 探针实测发现，服务端快照 `usage` 里**早已携带**三块手机端没显示的数据：

1. `contextWindow.cache`：缓存统计，**命中率服务端已算好**——
   `latestHitRate`（最近一次调用）、`hitRate`（会话平均）、`hitRateRequestCount`（统计请求数）、`totalInputTokens/totalCacheReadTokens`（全程总量）；
   实测样例（宿主会话）：最近一次 99.7%、会话平均 54.9%、按 522 次请求统计；
2. `contextWindow.breakdown`：上下文构成（按来源的字符数估算）——
   `system_prompt` / `meta_user_context` / `skills` / `system_tool_schemas` / `mcp_tool_schemas` / `messages`；
   实测样例：MCP 工具定义 12 万字符、对话内容 171 万字符；
3. `contextWindow.autoCompactThresholdTokens`：自动压缩阈值（常为 null，有就显示）。

另外 `usage-stats` 通道考古确认它是**编码计划额度/账单**（bigmodel 后端）而非会话级 token，对英伟达会话不适用，未接入。

## 实现

1. **缓存命中率卡**：两个大数字（最近一次 / 会话平均）+ 统计请求数说明；`usageCacheSummary` 纯函数做空安全解析，字段缺失整卡隐藏。
2. **上下文构成卡**：各来源字符数 + 占比条，降序排列；`contextBreakdownRows` 纯函数（空 source/非法项跳过），来源中文标签映射。
3. **上下文窗口卡**：服务端给阈值时附「自动压缩阈值 ≈ xx tokens」提示行。
4. **实时刷新**：弹层内容挂 `Listenable.merge([app, chat.state])`——回合跑完、流式推进，数字跟着动，不用关了重开。
5. 4 个新单测覆盖两个纯函数的直出/兜底/排序/占比路径。

## 验证

- `flutter analyze` 0 问题；`flutter test` 75 全过
- 探针实测宿主会话 usage JSON：cache/breakdown 字段形状与实现一致

## 口径说明（配合上一轮研究的结论）

- 命中率含义：`cacheRead / 总输入`——命中率越高，重复上下文越省钱省时；**切模型会清缓存**，切完第一次调用命中率会掉到 0 再爬回来，属正常。
- 构成占比是**字符数估算**（服务端按快照估），与 token 精确值有出入，作参考。
