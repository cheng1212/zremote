# 变更说明：抽屉新增「用量信息」页（模型级 Token 用量统计与图表）

> 分支：`feat/usage-stats-page`（探针 `b105567` → 协议层 `8afb543` → UI `de063c8`，`--no-ff` 合入 develop）
> 日期：2026-09-07　附探针：`test/manual_usage_stats_probe_test.dart`（ZREMOTE_PROBE_LINK 门控，只读）

## 背景

会话页汉堡抽屉此前只有「定时任务」一个功能入口；桌面端设置里有一页很完整的用量统计（按日/按模型的 token 图表），移动端没有任何入口看到这些数据。本次把整机级用量统计搬上手机。

## 接口形状来源（三重实锤，非猜测）

1. **桌面端 asar 考古**（`app.asar` 内 zod schema，与 UI 消费代码对齐）：
   `summary`（20 字段：totalTokens/inputTokens/outputTokens/reasoningTokens/
   cacheCreationTokens/cacheReadTokens/cacheHitRate/totalSessions/totalTurns/
   toolCallCount/toolErrorRate/modelErrorRate/avgTimeToFirstTokenMs?/
   avgTurnDurationMs?/activeDays/currentStreakDays/longestSessionMs/
   longestStreakDays/peakDayTokens/favoriteModel?）+ `heatmap`（周×日 level 0-4）+
   `dailyModelUsage`（日×模型）+ `models`（含 share）+ `tools`；
   `range` 枚举 `all|7d|30d`；`source` 固定 `agent-db`。
2. **bridge 探针实测**（真实配对桌面端）：
   - 任务给的四个候选（`getUsageStats`/`usageStats`/`usageStatsV4`…）**全部
     Method not found**，通道存在但方法名没猜中；
   - 回到 asar 找到 `usageStatsService` 的服务方法名，实测通过：
     **`usage-stats.getAppUsageSnapshot`，参数 `[{range, timeZone?}]`**（整机级，无 scope）；
   - `zcode-agent.getAppUsageStats` 同形可用（同一服务的另一暴露面，未采用）；
   - 参数语义实测：`range` 必填（缺省报 zod 错并列出 all|7d|30d）；`timeZone`
     可选、缺省服务端按 UTC 分桶，**接受 `GMT+08:00` 这类偏移串**——移动端拿不到
     IANA 时区名，`deviceTimeZoneLabel()` 用本地 `timeZoneOffset` 拼 `GMT±HH:MM`。
   - 报错语义校准：unknown channel 报「timed out」，unknown method 报
     「Method not found: X」——通道存在性可据此判定。
3. **数据闭环验证**：实测拿到真实快照（7 天 15 亿 token、22 个模型、8 天日明细），
   页面即按此渲染；widget 冒烟用同形状数据。

另注：`docs/feat-usage-sheet-cache-breakdown.md` 曾记「usage-stats 是编码计划额度/账单」——
本轮考古确认该通道**同时**承载两块：`getSnapshot`/`getCodingPlanUsageSnapshot` 等是
bigmodel 额度（无 key 时报 `no_bigmodel_api_key`，未接入），`getAppUsageSnapshot`
才是本地 agent-db 的会话统计，本次接的是后者。

## 页面结构（lib/ui/usage_page.dart）

1. **AppBar**：「用量信息」+ 刷新按钮；下拉刷新同样支持。
2. **时间范围切换**：全部 / 近 7 天 / 近 30 天三个 chip，切换即重拉
   （`ZApp.loadUsageStats(range)`，默认 7d，与桌面端一致）。
3. **总览卡**：大数字总 token + 输入/输出/缓存命中率三单元格（缓存卡样式照
   `feat-usage-sheet-cache-breakdown.md` 的命中率卡）+ 缓存读/写说明行 +
   会话/回合/工具调用/活跃天数/连续天数 chips + 常用模型。
4. **每日用量堆叠柱状图**（fl_chart ^1.2.0）：`dailyModelUsage` → 前 4 个模型 +
   「其他」共 5 段堆叠，色板用 ZT 色板轮换（primary/aqua/grape/lemon/inkFaint），
   legend 与模型明细占比条同色对应；y 轴 token 短标签，x 轴日期抽样（首尾必显）。
5. **模型明细列表**：mono 模型名 + `tokenCountLabel` 格式化 token 数 + 百分比 +
   占比条 + 输入/输出/请求次数小字。

## 兜底策略（形状未知字段一律不崩）

- `parseUsageStats`：非 Map / 缺 `summary` → null（页面显示空态引导刷新）；
  数值字段非法/缺失 → 0；schema 标 nullable 的（首 token 均时、回合均时）→ null；
  `share` 超界（>1 或 <0）不采信，明细列表占比回退按 token 量现算。
- 模型/日明细条目字段缺失逐项兜底；0-token 模型解析层保留、展示层过滤；
  全 0 的日期不占柱位；图表/明细无数据整卡隐藏。
- `loadUsageStats` 失败静默 + log（照 loadAutomations 模式），页面保旧数据展示；
  断线清空快照。

## 验证

- `flutter analyze` 0 问题；`flutter test` 100 过 12 skip（skip 全是无
  ZREMOTE_PROBE_LINK 的手动探针门控）。
- 新增测试：`test/usage_stats_test.dart` 11 用例（探针形状还原/字段兜底/范围与
  日期标签/时区偏移串/趋势分桶含「其他」与全 0 日剔除）+
  `test/usage_page_test.dart` 2 个 widget 冒烟（真实形状渲染 + 空态）。
- 探针在本机真实配对桌面端实测通过（read-only，只调 getAppUsageSnapshot）。

## 审核提示

1. **方法名来源是 asar 考古而非官方文档**：`getAppUsageSnapshot` 来自桌面端
   usageStatsService 的方法名；桌面端更新若重命名该方法，用量页会静默退到空态
   （log 里有「Method not found」可查）。
2. **timeZone 用偏移串**（GMT±HH:MM）而非 IANA 名：服务端实测接受并用于按日分桶；
   若未来服务端收紧为 IANA 校验，需要引入 `timezone` 包（已是传递依赖）取真名。
3. **git 历史说明**：曾有一版 commit 把 tasks_page/app_controller 全文件 dart format
   （本仓库存量代码与当前 dart format 规则不一致，全量 format 会带出 29 个文件的
   无关 diff），已 reset 重做，最终 diff 只含本任务改动；「format 全量」仅对
   本任务新增/修改文件执行。
4. 图表只做了「每日×模型堆叠柱」，桌面端的 heatmap（GitHub 风格活跃热图）和
   tools 明细未搬，schema 已在解析层留好位（UsageStatsView 未含 heatmap/tools 字段，
   原始 map 仍在 `app.usageStats`，后续要加不用改协议层）。
