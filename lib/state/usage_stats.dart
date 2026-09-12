/// 用量统计展示纯逻辑：usage-stats 通道快照 → 页面视图。无 Flutter 依赖，可单测。
/// 形状来源：桌面端 asar zod schema（summary/heatmap/dailyModelUsage/models/tools）
/// + 真实桌面端探针实测（usage-stats.getAppUsageSnapshot，2026-09-07）。
library;

/// 总览汇总（summary 对象）。
class UsageSummaryView {
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int cacheCreationTokens;
  final int cacheReadTokens;
  final double? cacheHitRate; // 0~1，服务端算好
  final int totalSessions;
  final int totalTurns;
  final int toolCallCount;
  final double? toolErrorRate;
  final double? modelErrorRate;
  final int? avgTimeToFirstTokenMs; // schema nullable
  final int? avgTurnDurationMs; // schema nullable
  final int activeDays;
  final int currentStreakDays;
  final int peakDayTokens;
  final String favoriteModelId;

  UsageSummaryView({
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.reasoningTokens,
    required this.cacheCreationTokens,
    required this.cacheReadTokens,
    required this.cacheHitRate,
    required this.totalSessions,
    required this.totalTurns,
    required this.toolCallCount,
    required this.toolErrorRate,
    required this.modelErrorRate,
    required this.avgTimeToFirstTokenMs,
    required this.avgTurnDurationMs,
    required this.activeDays,
    required this.currentStreakDays,
    required this.peakDayTokens,
    required this.favoriteModelId,
  });

  factory UsageSummaryView.fromMap(Map<String, dynamic> m) {
    int i(Object? v) => v is num && v > 0 ? v.toInt() : 0;
    double? d(Object? v) => v is num && v >= 0 && v <= 1 ? v.toDouble() : null;
    int? ms(Object? v) => v is num && v >= 0 ? v.toInt() : null;
    final fav = m['favoriteModel'];
    return UsageSummaryView(
      totalTokens: i(m['totalTokens']),
      inputTokens: i(m['inputTokens']),
      outputTokens: i(m['outputTokens']),
      reasoningTokens: i(m['reasoningTokens']),
      cacheCreationTokens: i(m['cacheCreationTokens']),
      cacheReadTokens: i(m['cacheReadTokens']),
      cacheHitRate: d(m['cacheHitRate']),
      totalSessions: i(m['totalSessions']),
      totalTurns: i(m['totalTurns']),
      toolCallCount: i(m['toolCallCount']),
      toolErrorRate: d(m['toolErrorRate']),
      modelErrorRate: d(m['modelErrorRate']),
      avgTimeToFirstTokenMs: ms(m['avgTimeToFirstTokenMs']),
      avgTurnDurationMs: ms(m['avgTurnDurationMs']),
      activeDays: i(m['activeDays']),
      currentStreakDays: i(m['currentStreakDays']),
      peakDayTokens: i(m['peakDayTokens']),
      favoriteModelId: fav is Map ? '${fav['modelId'] ?? ''}' : '',
    );
  }
}

/// 各模型聚合用量（models[] 一行，已含 share）。
class UsageModelView {
  final String modelId;
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int requestCount;
  final double share; // 0~1

  UsageModelView({
    required this.modelId,
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.requestCount,
    required this.share,
  });

  factory UsageModelView.fromMap(Map<String, dynamic> m) {
    int i(Object? v) => v is num && v > 0 ? v.toInt() : 0;
    return UsageModelView(
      modelId: '${m['modelId'] ?? ''}',
      totalTokens: i(m['totalTokens']),
      inputTokens: i(m['inputTokens']),
      outputTokens: i(m['outputTokens']),
      requestCount: i(m['requestCount']),
      share:
          m['share'] is num &&
              (m['share'] as num) >= 0 &&
              (m['share'] as num) <= 1
          ? (m['share'] as num).toDouble()
          : 0,
    );
  }
}

/// 每日×模型用量（dailyModelUsage[] 一行），趋势图数据源。
class UsageDailyView {
  final String date; // yyyy-MM-dd
  final List<(String, int)> models; // (modelId, totalTokens)

  UsageDailyView({required this.date, required this.models});

  int get totalTokens => models.fold(0, (s, m) => s + (m.$2 > 0 ? m.$2 : 0));

  factory UsageDailyView.fromMap(Map<String, dynamic> m) {
    final list = m['models'];
    return UsageDailyView(
      date: '${m['date'] ?? ''}',
      models: list is List
          ? [
              for (final e in list)
                if (e is Map)
                  (
                    '${e['modelId'] ?? ''}',
                    e['totalTokens'] is num && (e['totalTokens'] as num) > 0
                        ? (e['totalTokens'] as num).toInt()
                        : 0,
                  ),
            ]
          : const [],
    );
  }
}

/// 用量统计快照视图。
class UsageStatsView {
  final String range; // all / 7d / 30d
  final int generatedAt; // 毫秒
  final String timeZone;
  final UsageSummaryView summary;
  final List<UsageModelView> models;
  final List<UsageDailyView> daily;

  UsageStatsView({
    required this.range,
    required this.generatedAt,
    required this.timeZone,
    required this.summary,
    required this.models,
    required this.daily,
  });

  factory UsageStatsView.fromMap(Map<String, dynamic> m) {
    return UsageStatsView(
      range: '${m['range'] ?? ''}',
      generatedAt: m['generatedAt'] is num
          ? (m['generatedAt'] as num).toInt()
          : 0,
      timeZone: '${m['timeZone'] ?? ''}',
      summary: UsageSummaryView.fromMap(
        m['summary'] is Map
            ? (m['summary'] as Map).cast<String, dynamic>()
            : const {},
      ),
      models: [
        for (final e in m['models'] as List? ?? const [])
          if (e is Map) UsageModelView.fromMap(e.cast<String, dynamic>()),
      ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens)),
      daily: [
        for (final e in m['dailyModelUsage'] as List? ?? const [])
          if (e is Map) UsageDailyView.fromMap(e.cast<String, dynamic>()),
      ]..sort((a, b) => a.date.compareTo(b.date)),
    );
  }
}

/// getAppUsageSnapshot 响应 → 视图；不是 Map / 缺 summary 给 null（页面空态）。
UsageStatsView? parseUsageStats(Object? res) {
  if (res is! Map) return null;
  if (res['summary'] is! Map) return null;
  return UsageStatsView.fromMap(res.cast<String, dynamic>());
}

/// 时间范围 → 中文短标签（范围切换 chip 用）。
String usageRangeLabel(String range) => switch (range) {
  'all' => '全部',
  '30d' => '近 30 天',
  '7d' => '近 7 天',
  _ => range,
};

/// yyyy-MM-dd → M/d 短标签（图表 x 轴用）；解析失败原样返回。
String usageDayLabel(String date) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date.trim());
  if (m == null) return date;
  return '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日';
}

/// 本机 UTC 偏移 → 服务端可读的时区串（GMT+08:00 / GMT-05:30）。
/// 服务端拿它做按日分桶；拿不到 IANA 名的移动端用偏移串实测被接受。
/// [now] / [offset] 供测试注入。
String deviceTimeZoneLabel({DateTime? now, Duration? offset}) {
  final o = offset ?? (now ?? DateTime.now()).timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final h = o.inHours.abs().toString().padLeft(2, '0');
  final mm = (o.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return 'GMT$sign$h:$mm';
}

/// 趋势图数据：每日 token 堆叠柱（前 topN 个模型 + 其余归「其他」）。
/// 纯函数——modelIds 对齐 legend，rows 对齐 x 轴。
class UsageTrendChart {
  final List<String> modelIds; // 前 topN + '其他'（若存在溢出）
  final List<String> dayLabels; // x 轴
  final List<List<double>> stacks; // [day][series] token 数

  UsageTrendChart({
    required this.modelIds,
    required this.dayLabels,
    required this.stacks,
  });
}

UsageTrendChart buildUsageTrendChart(
  List<UsageDailyView> daily, {
  int topN = 4,
}) {
  // 全期各模型总量 → 前 topN。
  final totals = <String, int>{};
  for (final d in daily) {
    for (final (id, n) in d.models) {
      if (id.isEmpty) continue;
      totals[id] = (totals[id] ?? 0) + n;
    }
  }
  final ranked = totals.keys.toList()
    ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
  final top = ranked.take(topN).toSet();
  final modelIds = [...top, if (ranked.length > topN) '__other__'];

  final dayLabels = <String>[];
  final stacks = <List<double>>[];
  for (final d in daily) {
    if (d.totalTokens <= 0) continue; // 全 0 的日子不占柱位
    final values = List<double>.filled(modelIds.length, 0);
    for (final (id, n) in d.models) {
      final idx = top.contains(id)
          ? modelIds.indexOf(id)
          : modelIds.indexOf('__other__');
      if (idx >= 0 && n > 0) values[idx] += n;
    }
    dayLabels.add(usageDayLabel(d.date));
    stacks.add(values);
  }
  return UsageTrendChart(
    modelIds: modelIds,
    dayLabels: dayLabels,
    stacks: stacks,
  );
}

// ------------------------------------------------------ 时间窗口 / 模型筛选

/// 服务端 range 枚举（zod 只认这三个）。
const usageServerRanges = ['all', '30d', '7d'];

/// 预设时间选项（自定义走日历，不在此列）。
enum UsageRangeChoiceKind { today, threeDays, sevenDays, thirtyDays, all, custom }

/// 一个时间窗口（闭区间，yyyy-MM-dd 字符串键）。
class UsageDayWindow {
  final String startDay;
  final String endDay;

  const UsageDayWindow({required this.startDay, required this.endDay});

  bool contains(String day) => day.compareTo(startDay) >= 0 && day.compareTo(endDay) <= 0;
}

/// DateTime → yyyy-MM-dd 键（窗口过滤/自定义区间共用，格式两处曾重复易漂移）。
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 预设选项 → (日期窗口, 应拉取的服务端 range)。
/// 今天/3 天拉 7d、30 天拉 30d——服务端覆盖即可，精确范围客户端筛。
({UsageDayWindow window, String serverRange}) usageWindowForChoice(
  UsageRangeChoiceKind kind, {
  DateTime? today,
}) {
  final now = _dayStart(today ?? DateTime.now());
  switch (kind) {
    case UsageRangeChoiceKind.today:
      final k = dayKey(now);
      return (window: UsageDayWindow(startDay: k, endDay: k), serverRange: '7d');
    case UsageRangeChoiceKind.threeDays:
      return (
        window: UsageDayWindow(startDay: dayKey(now.subtract(const Duration(days: 2))), endDay: dayKey(now)),
        serverRange: '7d',
      );
    case UsageRangeChoiceKind.sevenDays:
      return (
        window: UsageDayWindow(startDay: dayKey(now.subtract(const Duration(days: 6))), endDay: dayKey(now)),
        serverRange: '7d',
      );
    case UsageRangeChoiceKind.thirtyDays:
      return (
        window: UsageDayWindow(startDay: dayKey(now.subtract(const Duration(days: 29))), endDay: dayKey(now)),
        serverRange: '30d',
      );
    case UsageRangeChoiceKind.all:
      return (
        window: UsageDayWindow(startDay: '0000-01-01', endDay: '9999-12-31'),
        serverRange: 'all',
      );
    case UsageRangeChoiceKind.custom:
      return (
        window: UsageDayWindow(startDay: dayKey(now), endDay: dayKey(now)),
        serverRange: 'all',
      ); // 自定义由调用方给窗口；拉 all 覆盖任意区间
  }
}

DateTime _dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

/// 日期切片 + 模型筛选后的派生结果。
/// summary 的输入/输出/缓存命中率依赖服务端按 range 聚合，切片后拿不到
/// 精确值——这里只给可从 daily 重算的字段（总量/模型占比）。
class UsageWindowSlice {
  final List<UsageDailyView> daily; // 已按日期+模型过滤
  final List<UsageModelView> models; // 由 daily 重算，总量降序
  final int totalTokens;
  final int activeDays; // 有用量的天数

  UsageWindowSlice({
    required this.daily,
    required this.models,
    required this.totalTokens,
    required this.activeDays,
  });
}

/// 按 [window] 切日期、再按 [selectedModels]（空集=全部）筛模型，
/// 重算模型总量与占比。纯函数。
UsageWindowSlice sliceUsage(
  UsageStatsView view,
  UsageDayWindow window, {
  Set<String> selectedModels = const {},
}) {
  final daily = [
    for (final d in view.daily)
      if (window.contains(d.date))
        UsageDailyView(
          date: d.date,
          models: selectedModels.isEmpty
              ? d.models
              : [
                  for (final (id, n) in d.models)
                    if (selectedModels.contains(id)) (id, n),
                ],
        ),
  ];
  return _aggregateSlice(daily);
}

/// 仅按模型过滤（不切日期）。
UsageWindowSlice filterUsageModels(
  UsageStatsView view,
  Set<String> selectedModels,
) {
  if (selectedModels.isEmpty) {
    return UsageWindowSlice(
      daily: view.daily,
      models: view.models,
      totalTokens: view.summary.totalTokens,
      activeDays: view.summary.activeDays,
    );
  }
  return _aggregateSlice(
    [
      for (final d in view.daily)
        UsageDailyView(
          date: d.date,
          models: [
            for (final (id, n) in d.models)
              if (selectedModels.contains(id)) (id, n),
          ],
        ),
    ],
  );
}

UsageWindowSlice _aggregateSlice(List<UsageDailyView> daily) {
  final totals = <String, int>{};
  var total = 0;
  var activeDays = 0;
  for (final d in daily) {
    var dayTotal = 0;
    for (final (id, n) in d.models) {
      if (id.isEmpty || n <= 0) continue;
      totals[id] = (totals[id] ?? 0) + n;
      dayTotal += n;
    }
    if (dayTotal > 0) activeDays++;
    total += dayTotal;
  }
  final models = [
    for (final e in totals.entries)
      UsageModelView(
        modelId: e.key,
        totalTokens: e.value,
        inputTokens: 0, // daily 无输入/输出拆分
        outputTokens: 0,
        requestCount: 0,
        share: total > 0 ? e.value / total : 0,
      ),
  ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
  return UsageWindowSlice(
    daily: daily,
    models: models,
    totalTokens: total,
    activeDays: activeDays,
  );
}

/// 当前选择是否走客户端派生（而非服务端原样数据）。
bool usageChoiceIsDerived(UsageRangeChoiceKind kind) =>
    kind == UsageRangeChoiceKind.today ||
    kind == UsageRangeChoiceKind.threeDays ||
    kind == UsageRangeChoiceKind.custom;
