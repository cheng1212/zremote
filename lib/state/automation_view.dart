/// 定时任务（自动化）展示纯逻辑。无 Flutter 依赖，可单测。
/// 形状来源：真实桌面端探针实测（automation-…/nextRunAt 等）。
library;

/// 单条自动化的展示视图。
class AutomationView {
  final String id;
  final String title;
  final String cronExpr;
  final String prompt;
  final bool enabled;
  final String lifecycleStatus; // active/completed/failed/paused
  final int? nextRunAt; // 毫秒时间戳
  final int? lastRunAt;
  final int runCount;
  final bool recurring;
  final int? maxRuns;
  final String? intervalUnit; // minute/hourly/daily/weekly/monthly/yearly
  final int? interval;
  final String? targetTaskId;

  AutomationView({
    required this.id,
    required this.title,
    required this.cronExpr,
    required this.prompt,
    required this.enabled,
    required this.lifecycleStatus,
    required this.nextRunAt,
    required this.lastRunAt,
    required this.runCount,
    required this.recurring,
    required this.maxRuns,
    required this.intervalUnit,
    required this.interval,
    required this.targetTaskId,
  });

  factory AutomationView.fromMap(Map<String, dynamic> m) {
    String s(Object? v) => '$v';
    int? ts(Object? v) => v is num && v > 0 ? v.toInt() : null;
    return AutomationView(
      id: s(m['automationId'] ?? m['id']),
      title: s(m['title'] ?? ''),
      cronExpr: s(m['cronExpr'] ?? ''),
      prompt: s(m['prompt'] ?? ''),
      enabled: m['enabled'] == true,
      lifecycleStatus: s(m['lifecycleStatus'] ?? ''),
      nextRunAt: ts(m['nextRunAt']),
      lastRunAt: ts(m['lastRunAt']),
      runCount: m['runCount'] is num ? (m['runCount'] as num).toInt() : 0,
      recurring: m['recurring'] == true,
      maxRuns: m['maxRuns'] is num ? (m['maxRuns'] as num).toInt() : null,
      intervalUnit: m['intervalUnit'] != null ? s(m['intervalUnit']) : null,
      interval: m['interval'] is num ? (m['interval'] as num).toInt() : null,
      targetTaskId: m['targetTaskId'] != null ? s(m['targetTaskId']) : null,
    );
  }

  /// 调度描述：间隔规则优先（每 N 单位），否则 cron 原文。
  String get scheduleLabel {
    final unit = intervalUnit;
    final n = interval;
    if (unit != null && n != null && n > 0) {
      return '每 $n ${_unitLabel(unit)}';
    }
    return cronExpr;
  }

  static String _unitLabel(String unit) => switch (unit) {
    'minute' => '分钟',
    'hourly' => '小时',
    'daily' => '天',
    'weekly' => '周',
    'monthly' => '月',
    'yearly' => '年',
    _ => unit,
  };

  /// 生命周期 → 主题状态色语义（柑橘晨光）：
  /// active=橘（跑） / completed=青（done） / failed=玫红 / paused=柠黄。
  String get lifecycleLabel => switch (lifecycleStatus) {
    'active' => '启用中',
    'completed' => '已完成',
    'failed' => '失败',
    'paused' => '已暂停',
    _ => lifecycleStatus,
  };

  /// 一次性任务（recurring=false 且有 maxRuns）标记。
  bool get oneShot => !recurring;
}

/// listAllAutomations 响应 → List<Map>（List 直通；Map 多字段兜底）。
List<Map<String, dynamic>> parseAutomations(Object? res) {
  Object? list = res;
  if (res is Map) {
    list = res['automations'] ?? res['items'] ?? res['list'] ?? res['result'];
  }
  if (list is! List) return const [];
  return [
    for (final e in list)
      if (e is Map) e.cast<String, dynamic>(),
  ];
}

/// 距下次执行的倒计时文案。[nowMs] 供测试注入。
/// null/已过期给空（调用方隐藏或显示「待触发」）。
String automationCountdown(int? nextRunAt, {int? nowMs}) {
  if (nextRunAt == null) return '';
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final delta = nextRunAt - now;
  if (delta <= 0) return '待触发';
  final d = Duration(milliseconds: delta);
  if (d.inDays >= 1) return '${d.inDays} 天 ${(d.inHours % 24)} 小时';
  if (d.inHours >= 1) return '${d.inHours} 小时 ${d.inMinutes % 60} 分';
  if (d.inMinutes >= 1) return '${d.inMinutes} 分 ${(d.inSeconds % 60)} 秒';
  return '${d.inSeconds} 秒';
}

/// 一次运行记录的展示视图。形状探针实测：
/// {runId, automationId, scheduledAt, trigger: manual|cron,
///  dispatchStatus, outcome: failed|completed|…, sessionId?, attempts, …}
class AutomationRunView {
  final String runId;
  final String trigger;
  final String outcome;
  final int? scheduledAt;
  final String? sessionId;
  final int attempts;

  AutomationRunView({
    required this.runId,
    required this.trigger,
    required this.outcome,
    required this.scheduledAt,
    required this.sessionId,
    required this.attempts,
  });

  String get triggerLabel => switch (trigger) {
    'manual' => '手动',
    'cron' => '定时',
    _ => trigger,
  };

  String get outcomeLabel => switch (outcome) {
    'completed' => '完成',
    'failed' => '失败',
    'running' => '运行中',
    'dispatched' => '已派发',
    _ => outcome,
  };

  bool get failed => outcome == 'failed';
}

/// listAutomationRuns 响应 → 按时间倒序的运行记录列表。
List<AutomationRunView> parseAutomationRuns(Object? res) {
  Object? list = res;
  if (res is Map) {
    list = res['runs'] ?? res['items'] ?? res['result'];
  }
  if (list is! List) return const [];
  final out = <AutomationRunView>[];
  for (final e in list) {
    if (e is! Map) continue;
    final runId = '${e['runId'] ?? ''}';
    if (runId.isEmpty) continue;
    out.add(AutomationRunView(
      runId: runId,
      trigger: '${e['trigger'] ?? ''}',
      outcome: '${e['outcome'] ?? ''}',
      scheduledAt: e['scheduledAt'] is num ? (e['scheduledAt'] as num).toInt() : null,
      sessionId: e['sessionId'] != null ? '${e['sessionId']}' : null,
      attempts: e['attempts'] is num ? (e['attempts'] as num).toInt() : 0,
    ));
  }
  out.sort((a, b) => (b.scheduledAt ?? 0).compareTo(a.scheduledAt ?? 0));
  return out;
}

/// 运行记录时间 → 短文案（今天 HH:mm，其余 M/d HH:mm）。
String automationRunTime(int? ts, {int? nowMs}) {
  if (ts == null || ts <= 0) return '';
  final now = DateTime.fromMillisecondsSinceEpoch(
    nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final hh = '${d.hour}'.padLeft(2, '0');
  final mm = '${d.minute}'.padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '$hh:$mm';
  }
  return '${d.month}/${d.day} $hh:mm';
}
