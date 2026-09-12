import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/task_sort.dart' show tokenCountLabel;
import '../state/usage_stats.dart';
import '../theme.dart';

/// 用量信息页：总览卡 + 每日堆叠柱状图 + 模型明细列表。
/// 数据：usage-stats.getAppUsageSnapshot（探针实测，参数 {range, timeZone?}，
/// 整机级无 scope）；时间范围切换（全部/近 7 天/近 30 天）时重新拉取。
class UsagePage extends StatefulWidget {
  final ZApp app;

  const UsagePage({super.key, required this.app});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  UsageRangeChoiceKind _choice = UsageRangeChoiceKind.sevenDays;
  UsageDayWindow? _customWindow;

  /// 点图表柱子下钻的按日过滤（yyyy-MM-dd）；再点同一天=取消下钻。
  String? _dayDrill;
  final _selectedModels = <String>{};
  bool _timeExpanded = true;

  @override
  void initState() {
    super.initState();
    // 默认选项跟随上次的服务端 range。
    _choice = switch (widget.app.usageStatsRange) {
      'all' => UsageRangeChoiceKind.all,
      '30d' => UsageRangeChoiceKind.thirtyDays,
      _ => UsageRangeChoiceKind.sevenDays,
    };
    unawaited(widget.app.loadUsageStats(range: widget.app.usageStatsRange));
  }

  UsageDayWindow get _window {
    if (_dayDrill != null) return UsageDayWindow(startDay: _dayDrill!, endDay: _dayDrill!);
    if (_choice == UsageRangeChoiceKind.custom && _customWindow != null) {
      return _customWindow!;
    }
    return usageWindowForChoice(_choice, today: DateTime.now()).window;
  }

  String get _neededServerRange {
    if (_choice == UsageRangeChoiceKind.custom && _customWindow != null) {
      final w = _customWindow!;
      final days =
          DateTime.parse(
            w.endDay,
          ).difference(DateTime.parse(w.startDay)).inDays +
          1;
      return days > 30 ? 'all' : '30d';
    }
    return usageWindowForChoice(_choice, today: DateTime.now()).serverRange;
  }


  /// 图表柱子点按下钻/取消：同一天再点=取消下钻。
  void _toggleDayDrill(String day) {
    setState(() {
      if (_dayDrill == day) {
        _dayDrill = null;
      } else {
        _dayDrill = day;
      }
    });
  }

  Future<void> _applyChoice(UsageRangeChoiceKind kind) async {
    if (kind == UsageRangeChoiceKind.custom) {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024, 1, 1),
        lastDate: now,
        initialDateRange: DateTimeRange(
          start: now.subtract(const Duration(days: 6)),
          end: now,
        ),
        builder: (ctx, child) => Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: ZT.primary,
              secondary: ZT.primaryDeep,
              surface: ZT.surface,
            ),
          ),
          child: child!,
        ),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _choice = UsageRangeChoiceKind.custom;
        _customWindow = UsageDayWindow(
          startDay: dayKey(picked.start),
          endDay: dayKey(picked.end),
        );
      });
    } else {
      if (_choice == kind && _dayDrill == null) return;
      setState(() {
        _choice = kind;
        _customWindow = null;
        _dayDrill = null;
      });
    }
    final needed = _neededServerRange;
    if (widget.app.usageStatsRange != needed) {
      await widget.app.loadUsageStats(range: needed);
    }
  }

  void _toggleModel(String id) {
    setState(() {
      if (!_selectedModels.remove(id)) _selectedModels.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final view = parseUsageStats(app.usageStats);
        final window = _window;
        final derived = usageChoiceIsDerived(_choice);
        final modelFiltered = _selectedModels.isNotEmpty;
        final slice = view == null || (!derived && !modelFiltered)
            ? null
            : sliceUsage(view, window, selectedModels: _selectedModels);
        return Scaffold(
          appBar: AppBar(
            title: const Text('用量信息'),
            actions: [
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded, color: ZT.ink),
                onPressed: () => app.loadUsageStats(range: _neededServerRange),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: app.usageStatsLoading && view == null
              ? const Center(
                  child: CircularProgressIndicator(color: ZT.primary),
                )
              : view == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: ShapeDecoration(
                          color: ZT.aqua.withValues(alpha: 0.25),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: ZT.inkSide(w: 1.8),
                          ),
                          shadows: ZT.hard(dx: 4, dy: 4),
                        ),
                        child: const Icon(
                          Icons.insights_rounded,
                          color: ZT.ink,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '暂时拿不到用量数据',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '确认桌面端在线后点右上角刷新',
                        style: TextStyle(fontSize: 12, color: ZT.inkFaint),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: ZT.primaryDeep,
                  onRefresh: () =>
                      app.loadUsageStats(range: _neededServerRange),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _filterCard(view, window),
                      const SizedBox(height: 12),
                      if (slice != null) ...[
                        _SliceOverviewCard(slice: slice, window: window),
                        const SizedBox(height: 12),
                        _TrendCard(
                          daily: slice.daily,
                          onDayTap: _toggleDayDrill,
                        ),
                        if (_dayDrill != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.filter_alt_rounded,
                                size: 13,
                                color: ZT.primaryDeep,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '已按下钻过滤：$_dayDrill（再点同一天取消）',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: ZT.primaryDeep,
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        _ModelsCard(models: slice.models, showBreakdown: false),
                      ] else ...[
                        _OverviewCard(view: view, range: _neededServerRange),
                        const SizedBox(height: 12),
                        _TrendCard(daily: view.daily),
                        const SizedBox(height: 12),
                        _ModelsCard(models: view.models, showBreakdown: true),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
  }

  static const _timeChoices = [
    (UsageRangeChoiceKind.today, '今天'),
    (UsageRangeChoiceKind.threeDays, '近 3 天'),
    (UsageRangeChoiceKind.sevenDays, '近 7 天'),
    (UsageRangeChoiceKind.thirtyDays, '近 30 天'),
    (UsageRangeChoiceKind.all, '全部'),
  ];

  /// 筛选卡片：时间范围（可折叠 chips + 自定义日历）/ 模型类型（下拉多选）。
  Widget _filterCard(UsageStatsView view, UsageDayWindow window) {
    final ids = _windowModelIds(view, window);
    final modelLabel = _selectedModels.isEmpty
        ? '全部模型（${ids.length}个）'
        : '已选 ${_selectedModels.length} 个模型';
    return HardCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _timeExpanded = !_timeExpanded),
            child: Row(
              children: [
                const Icon(
                  Icons.calendar_month_rounded,
                  size: 16,
                  color: ZT.ink,
                ),
                const SizedBox(width: 8),
                const Text(
                  '时间范围',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _timeExpanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(
                    Icons.expand_more,
                    size: 19,
                    color: ZT.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _timeExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final (kind, label) in _timeChoices)
                          _timeChip(kind, label),
                        _customChip(),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 12),
          Divider(color: ZT.line, thickness: 1, height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.category_rounded, size: 16, color: ZT.ink),
              const SizedBox(width: 8),
              const Text(
                '模型类型',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: ids.isEmpty ? null : () => _openModelPicker(ids),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: ShapeDecoration(
                      color: ZT.bg,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: ZT.inkSide(w: 1.2, color: ZT.line),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            modelLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: ZT.inkSoft,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: ZT.inkFaint,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeChip(UsageRangeChoiceKind kind, String label) {
    final selected = _choice == kind;
    return GestureDetector(
      onTap: () => _applyChoice(kind),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: selected ? ZT.lemon.withValues(alpha: 0.55) : ZT.surface,
          shape: StadiumBorder(side: ZT.inkSide(w: selected ? 1.6 : 1.2)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? ZT.ink : ZT.inkSoft,
          ),
        ),
      ),
    );
  }

  Widget _customChip() {
    final selected = _choice == UsageRangeChoiceKind.custom;
    return GestureDetector(
      onTap: () => _applyChoice(UsageRangeChoiceKind.custom),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: ShapeDecoration(
          color: selected ? ZT.lemon.withValues(alpha: 0.55) : ZT.surface,
          shape: StadiumBorder(side: ZT.inkSide(w: selected ? 1.6 : 1.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_month_rounded,
              size: 13,
              color: selected ? ZT.ink : ZT.inkSoft,
            ),
            const SizedBox(width: 4),
            Text(
              selected && _customWindow != null
                  ? '${_shortDay(_customWindow!.startDay)}-'
                        '${_shortDay(_customWindow!.endDay)}'
                  : '自定义',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: selected ? ZT.ink : ZT.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 窗口内出现的模型 id（按用量降序）。
  List<String> _windowModelIds(UsageStatsView view, UsageDayWindow window) {
    final totals = <String, int>{};
    for (final d in view.daily) {
      if (!window.contains(d.date)) continue;
      for (final (id, n) in d.models) {
        if (id.isEmpty || n <= 0) continue;
        totals[id] = (totals[id] ?? 0) + n;
      }
    }
    final ids = totals.keys.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    return ids;
  }

  /// 模型多选下拉（底部弹层）：全部模型 + 逐个勾选。
  Future<void> _openModelPicker(List<String> ids) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.6,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ZT.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.category_rounded, size: 17, color: ZT.grape),
                  const SizedBox(width: 8),
                  const Text(
                    '选择模型',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _selectedModels.isEmpty
                        ? null
                        : () {
                            setState(_selectedModels.clear);
                            Navigator.pop(sheetCtx);
                          },
                    child: const Text(
                      '全部模型',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: ZT.primaryDeep,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final id in ids)
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _toggleModel(id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                _selectedModels.contains(id)
                                    ? Icons.check_box_rounded
                                    : Icons.check_box_outline_blank_rounded,
                                size: 19,
                                color: _selectedModels.contains(id)
                                    ? ZT.primaryDeep
                                    : ZT.inkFaint,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  id.contains('/')
                                      ? id.substring(id.lastIndexOf('/') + 1)
                                      : id,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortDay(String day) {
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(day.trim());
    if (m == null) return day;
    return '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日';
  }

}

/// 柱状图系列色板（柑橘晨光轮换），legend 与明细占比条共用。
const _seriesColors = [
  ZT.primary,
  ZT.aqua,
  ZT.grape,
  ZT.lemon,
  ZT.inkFaint, // 「其他」
];

String _pct(double? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';

String _fmtInt(int n) {
  final s = '$n';
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    buf.write(s[i]);
    final left = s.length - 1 - i;
    if (left > 0 && left % 3 == 0) buf.write(',');
  }
  return buf.toString();
}

/// 派生窗口总览卡（今天/3天/自定义）：总量/模型数/覆盖天数来自 daily
/// 重算；输入/输出/命中率服务端不按自定义区间聚合，如实标注。
class _SliceOverviewCard extends StatelessWidget {
  final UsageWindowSlice slice;
  final UsageDayWindow window;

  const _SliceOverviewCard({required this.slice, required this.window});

  @override
  Widget build(BuildContext context) {
    final windowDays =
        DateTime.parse(
          window.endDay,
        ).difference(DateTime.parse(window.startDay)).inDays +
        1;
    final note = window.startDay == '0000-01-01'
        ? ''
        : '窗口 ${window.startDay} ~ ${window.endDay}';
    return HardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.insights_rounded, size: 15, color: ZT.primary),
              SizedBox(width: 6),
              Text(
                '总览（按所选范围重算）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tokenCountLabel(slice.totalTokens),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: ZT.primaryDeep,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'tokens',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: ZT.inkFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _cell('活跃天数', '${slice.activeDays} / $windowDays'),
              ),
              const SizedBox(width: 8),
              Expanded(child: _cell('模型数', '${slice.models.length}')),
              const SizedBox(width: 8),
              Expanded(
                child: _cell('输入/输出/缓存', '见近 7 天/30 天/全部', color: ZT.inkFaint),
              ),
            ],
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '$note · 输入/输出/缓存命中率按服务端区间聚合，自定义范围暂不提供',
              style: const TextStyle(fontSize: 11, color: ZT.inkFaint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(String label, String value, {Color color = ZT.primaryDeep}) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: ZT.inkSide(w: 1.1, color: ZT.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 总览卡：大数字总 token + 输入/输出/缓存命中率单元格 + 统计小字行。
/// 缓存卡样式照 feat-usage-sheet-cache-breakdown.md（单元格 = bg 底 + 线框）。
class _OverviewCard extends StatelessWidget {
  final UsageStatsView view;
  final String range;

  const _OverviewCard({required this.view, required this.range});

  @override
  Widget build(BuildContext context) {
    final s = view.summary;
    final generated = view.generatedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(view.generatedAt)
        : null;
    return HardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded, size: 15, color: ZT.primary),
              const SizedBox(width: 6),
              const Text(
                '总览',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (generated != null)
                Text(
                  '${usageRangeLabel(range)} · 更新于 '
                  '${generated.hour.toString().padLeft(2, '0')}:'
                  '${generated.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                tokenCountLabel(s.totalTokens),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: ZT.primaryDeep,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'tokens',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: ZT.inkFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _cell('输入', tokenCountLabel(s.inputTokens))),
              const SizedBox(width: 8),
              Expanded(child: _cell('输出', tokenCountLabel(s.outputTokens))),
              const SizedBox(width: 8),
              Expanded(
                child: _cell('缓存命中率', _pct(s.cacheHitRate), color: ZT.aqua),
              ),
            ],
          ),
          if (s.cacheReadTokens > 0) ...[
            const SizedBox(height: 6),
            Text(
              '缓存读取 ${tokenCountLabel(s.cacheReadTokens)} · 缓存写入 '
              '${tokenCountLabel(s.cacheCreationTokens)}（命中越高越省）',
              style: const TextStyle(fontSize: 11, color: ZT.inkFaint),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _statChip('${_fmtInt(s.totalSessions)} 会话'),
              _statChip('${_fmtInt(s.totalTurns)} 回合'),
              _statChip('${_fmtInt(s.toolCallCount)} 次工具调用'),
              _statChip('活跃 ${s.activeDays} 天'),
              if (s.currentStreakDays > 0)
                _statChip('连续 ${s.currentStreakDays} 天'),
            ],
          ),
          if (s.favoriteModelId.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '常用模型 ${s.favoriteModelId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                color: ZT.inkSoft,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(String label, String value, {Color color = ZT.primaryDeep}) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: ZT.inkSide(w: 1.1, color: ZT.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: value == '—' ? ZT.inkFaint : color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: StadiumBorder(side: ZT.inkSide(w: 1, color: ZT.line)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: ZT.inkSoft,
        ),
      ),
    );
  }
}

/// 每日用量堆叠柱状图：dailyModelUsage → 前 4 个模型 + 「其他」，
/// 色板 _seriesColors 轮换；y 轴 token 短标签，x 轴抽样日期。
class _TrendCard extends StatelessWidget {
  final List<UsageDailyView> daily;

  /// 点某天柱子 → 回传该天日期键（yyyy-MM-dd）；再次点同一天=取消。
  final ValueChanged<String>? onDayTap;

  const _TrendCard({required this.daily, this.onDayTap});

  @override
  Widget build(BuildContext context) {
    final chart = buildUsageTrendChart(daily);
    if (chart.dayLabels.isEmpty || chart.stacks.isEmpty) {
      return const SizedBox.shrink();
    }
    final seriesNames = [
      for (final id in chart.modelIds) id == '__other__' ? '其他' : id,
    ];
    return HardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bar_chart_rounded, size: 15, color: ZT.grape),
              SizedBox(width: 6),
              Text(
                '每日用量（tokens）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (var i = 0; i < seriesNames.length; i++)
                if (i < _seriesColors.length)
                  _legend(seriesNames[i], _seriesColors[i]),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(height: 180, child: _barChart(chart)),
        ],
      ),
    );
  }

  Widget _legend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(width: 1, color: ZT.ink.withValues(alpha: 0.4)),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: ZT.inkSoft,
          ),
        ),
      ],
    );
  }

  Widget _barChart(UsageTrendChart chart) {
    final totals = [
      for (final row in chart.stacks) row.fold<double>(0, (s, v) => s + v),
    ];
    final maxY = totals.fold<double>(0, (m, v) => m > v ? m : v) * 1.15;
    // x 轴标签抽样：柱子多时隔段显示，首尾必显。
    final step = (chart.dayLabels.length / 6).ceil();
    Widget bottomTitles(double value, TitleMeta meta) {
      final i = value.toInt();
      if (i < 0 || i >= chart.dayLabels.length) return const SizedBox.shrink();
      final show = i == 0 || i == chart.dayLabels.length - 1 || i % step == 0;
      if (!show) return const SizedBox.shrink();
      return SideTitleWidget(
        meta: meta,
        child: Text(
          chart.dayLabels[i],
          style: const TextStyle(fontSize: 9.5, color: ZT.inkFaint),
        ),
      );
    }

    Widget leftTitles(double value, TitleMeta meta) {
      if (value <= 0) return const SizedBox.shrink();
      return SideTitleWidget(
        meta: meta,
        child: Text(
          tokenCountLabel(value),
          style: const TextStyle(fontSize: 9.5, color: ZT.inkFaint),
        ),
      );
    }

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY,
        barTouchData: BarTouchData(
          enabled: onDayTap != null,
          touchCallback: (event, response) {
            final tap = onDayTap;
            if (tap == null) return;
            final spot = response?.spot;
            if (event is FlTapUpEvent &&
                spot != null &&
                spot.touchedBarGroupIndex >= 0) {
              final g = spot.touchedBarGroupIndex;
              final labels = chart.dayLabels;
              if (g < labels.length) tap(labels[g]);
            }
          },
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (v) =>
              const FlLine(color: ZT.line, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: maxY / 4,
              getTitlesWidget: leftTitles,
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 20,
              interval: 1,
              getTitlesWidget: bottomTitles,
            ),
          ),
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
        ),
        barGroups: [
          for (var i = 0; i < chart.stacks.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: totals[i],
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                  rodStackItems: [
                    for (var j = 0; j < chart.stacks[i].length; j++)
                      if (chart.stacks[i][j] > 0)
                        BarChartRodStackItem(
                          // 起点 = 前几段之和（中间被 0 断开时仍按累计值，堆叠不重叠）
                          chart.stacks[i]
                              .take(j)
                              .fold<double>(0, (s, v) => s + v),
                          chart.stacks[i]
                              .take(j + 1)
                              .fold<double>(0, (s, v) => s + v),
                          _seriesColors[j < _seriesColors.length
                              ? j
                              : _seriesColors.length - 1],
                        ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 模型明细：mono 模型名 + token 数 + 请求次数，占比条与图表同色轮换。
class _ModelsCard extends StatelessWidget {
  final List<UsageModelView> models;
  final bool showBreakdown; // 服务端精确区间才展示输入/输出/请求数

  const _ModelsCard({required this.models, this.showBreakdown = false});

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final m in models)
        if (m.totalTokens > 0) m,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    final maxShare = rows.fold<double>(0, (m, x) => x.share > m ? x.share : m);
    // share 缺失/畸变时退回按 token 量现算。
    final total = rows.fold<int>(0, (s, m) => s + m.totalTokens);
    return HardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory_rounded, size: 15, color: ZT.aqua),
              const SizedBox(width: 6),
              const Text(
                '模型明细',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                '${rows.length} 个模型',
                style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _row(rows[i], i, maxShare, total),
            ),
        ],
      ),
    );
  }

  Widget _row(UsageModelView m, int i, double maxShare, int total) {
    final share = m.share > 0 && m.share <= 1 ? m.share : m.totalTokens / total;
    final barW = maxShare > 0 ? (share / maxShare).clamp(0.04, 1.0) : 0.0;
    final color =
        _seriesColors[i < _seriesColors.length ? i : _seriesColors.length - 1];
    final shortName = m.modelId.contains('/')
        ? m.modelId.substring(m.modelId.lastIndexOf('/') + 1)
        : m.modelId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  width: 1,
                  color: ZT.ink.withValues(alpha: 0.4),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shortName.isEmpty ? '（未知模型）' : shortName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (showBreakdown &&
                      (m.inputTokens > 0 ||
                          m.outputTokens > 0 ||
                          m.requestCount > 0))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '输入 ${tokenCountLabel(m.inputTokens)} · 输出 '
                        '${tokenCountLabel(m.outputTokens)} · '
                        '${_fmtInt(m.requestCount)} 次请求',
                        style: const TextStyle(
                          fontSize: 10,
                          color: ZT.inkFaint,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              tokenCountLabel(m.totalTokens),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: ZT.ink,
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 42,
              child: Text(
                '${(share * 100).toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: ZT.inkFaint,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        // 占比条：轨道线色，填充段同系列色。
        ClipRRect(
          borderRadius: BorderRadius.circular(2.5),
          child: SizedBox(
            height: 5,
            child: Stack(
              children: [
                Container(color: ZT.line),
                FractionallySizedBox(
                  widthFactor: barW,
                  child: Container(color: color),
                ),
              ],
            ),
          ),
        ),
        if (m.requestCount > 0 || m.inputTokens > 0 || m.outputTokens > 0) ...[
          const SizedBox(height: 3),
          Text(
            [
              if (m.inputTokens > 0) '输入 ${tokenCountLabel(m.inputTokens)}',
              if (m.outputTokens > 0) '输出 ${tokenCountLabel(m.outputTokens)}',
              if (m.requestCount > 0) '${_fmtInt(m.requestCount)} 次请求',
            ].join(' · '),
            style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
          ),
        ],
      ],
    );
  }
}
