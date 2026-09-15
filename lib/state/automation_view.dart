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

  /// 记录自带的工作区（listAllAutomations 为全工作区列表；删除/启停
  /// RPC 却按 scope 找任务——跨工作区操作必须带上记录自己的工作区）。
  /// 旧桌面端记录可能没有此字段（null），此时退回当前桥接 scope。
  final String? workspacePath;

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
    required this.workspacePath,
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
      workspacePath: (m['workspaceKey'] ?? m['workspacePath'] ?? m['workspace'])
          != null
          ? s(m['workspaceKey'] ?? m['workspacePath'] ?? m['workspace'])
          : null,
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

  /// 标题中的会话标记（@s685e → '685e'）；无标记为 null。
  /// 约定：agent 建任务时在标题尾加 ` @s` + 创建会话 sess_ id 前 4 位。
  String? get sessionTag {
    final m = _autoTagRe.firstMatch(title);
    return m?.group(1);
  }

  /// 由完整会话 id 提取标记位：sess_685ebfd2-… → '685e'；
  /// 非 sess_ 前缀取 id 前 4 位兜底（小写）。
  static String tagOfSession(String sessionId) {
    final s = sessionId.toLowerCase();
    final m = RegExp(r'sess_([0-9a-f]{4})').firstMatch(s);
    final hex = m?.group(1) ?? s;
    return hex.length > 4 ? hex.substring(0, 4) : hex;
  }
}

/// 会话标记正则：@s + 4 位 hex，后随词边界（不吞更长 hex 串）。
final RegExp _autoTagRe = RegExp(r'@s([0-9a-f]{4})\b', caseSensitive: false);

/// 面板过滤：默认只显示带当前会话标记的任务；[showAll] 时返回全量。
/// [curTag] 为空（拿不到当前会话）时退化为全量，避免面板空掉。
List<AutomationView> filterAutomationsBySession(
  List<AutomationView> autos,
  String? curTag, {
  bool showAll = false,
}) {
  if (showAll || curTag == null || curTag.isEmpty) return autos;
  return [for (final a in autos) if (a.sessionTag == curTag) a];
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

/// 创建面板的频率预设 → cron 表达式（Dart map 字面量保序，chips 按此顺序）。
const Map<String, String> cronPresets = <String, String>{
  '每1分钟': '* * * * *',
  '每3分钟': '*/3 * * * *',
  '每5分钟': '*/5 * * * *',
  '每10分钟': '*/10 * * * *',
  '每30分钟': '*/30 * * * *',
  '每小时': '0 * * * *',
  '每天早上9点': '0 9 * * *',
};

/// 会话列表小时钟：有「启用中」定时任务的会话 id 集合。
/// 匹配双通道：① 任务记录自带的 targetTaskId（桌面端任务服务触发时按它
/// 投递，最可靠）；② 标题 @sXXXX 标记（历史约定，兜底老任务）。
Set<String> sessionIdsWithActiveAutomation(
  List<Map<String, dynamic>> automations,
  Iterable<String> sessionIds,
) {
  final ids = sessionIds.toSet();
  if (ids.isEmpty || automations.isEmpty) return const {};
  final active = [
    for (final m in automations)
      if (m['enabled'] == true) AutomationView.fromMap(m),
  ];
  if (active.isEmpty) return const {};
  bool hits(AutomationView a, String sid) {
    if (a.targetTaskId != null && a.targetTaskId == sid) return true;
    final tag = a.sessionTag;
    return tag != null && tag == AutomationView.tagOfSession(sid);
  }

  return {
    for (final sid in ids)
      if (active.any((a) => hits(a, sid))) sid,
  };
}
