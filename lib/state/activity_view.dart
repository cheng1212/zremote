/// 聊天页活动面板纯逻辑：activeWorks + 流式子代理聚合。无 Flutter 依赖。
/// 数据来源：snapshot.control.activeWorks（桌面端 schema 实测）+ rows。
library;

/// 一个活动工作单元。
class WorkView {
  final String kind; // primaryTurn/foregroundSubagent/compact/goalVerifier/goalContinuation/turnSteer
  final int? startedAt; // 毫秒

  WorkView({required this.kind, required this.startedAt});

  String get label => switch (kind) {
    'primaryTurn' => '主回合',
    'foregroundSubagent' => '前台子代理',
    'compact' => '上下文压缩',
    'goalVerifier' => '目标校验',
    'goalContinuation' => '目标续跑',
    'turnSteer' => '插话转向',
    _ => kind,
  };
}

/// control.activeWorks → WorkView 列表（非 Map/缺 kind 项跳过）。
List<WorkView> parseActiveWorks(Object? control) {
  if (control is! Map) return const [];
  final works = control['activeWorks'];
  if (works is! List) return const [];
  final out = <WorkView>[];
  for (final w in works) {
    if (w is! Map) continue;
    final kind = '${w['kind'] ?? ''}';
    if (kind.isEmpty) continue;
    final startedAt = w['startedAt'] is num ? (w['startedAt'] as num).toInt() : null;
    out.add(WorkView(kind: kind, startedAt: startedAt));
  }
  return out;
}

/// 流式中的子代理行视图。
class SubagentActivity {
  final int? rowId;
  final String summary;

  SubagentActivity({required this.rowId, required this.summary});
}

/// rows 里 state=streaming 的子代理行 → 摘要列表。
List<SubagentActivity> streamingSubagents(List<Map<String, dynamic>> rows) {
  final out = <SubagentActivity>[];
  for (final r in rows) {
    if (r['kind'] != 'subagent') continue;
    if (r['state'] != 'streaming') continue;
    final summary = '${r['summaryText'] ?? r['text'] ?? ''}'.trim();
    out.add(SubagentActivity(
      rowId: (r['rowId'] as num?)?.toInt(),
      summary: summary.isEmpty ? '运行中…' : summary,
    ));
  }
  return out;
}

/// 已运行时长文案。有 endedAt（进程已结束）时显示总用时并停表，
/// 否则按当前时间计。nowMs 供测试注入。
String workElapsed(int? startedAt, {int? endedAt, int? nowMs}) {
  if (startedAt == null || startedAt <= 0) return '';
  final now =
      endedAt ??
      nowMs ??
      DateTime.now().millisecondsSinceEpoch;
  final s = ((now - startedAt) / 1000).floor();
  if (s <= 0) return '刚刚';
  if (s < 60) return '$s 秒';
  if (s < 3600) return '${s ~/ 60} 分 ${s % 60} 秒';
  return '${s ~/ 3600} 时 ${(s % 3600) ~/ 60} 分';
}

/// 一个后台任务视图。字段来源：桌面端 zod schema（app.asar 反解实测）：
/// {workId, kind: bash|subagent, title, status: running|resultPending|
/// failed|cancelled, startedAt, endedAt?, cancellable?, blocked?,
/// anchorRowId?, childSessionId?}。
/// 注意：服务端**没有「完成」态**——进程正常结束停在 resultPending，
/// 结果被取走后整条从列表消失。「已完成」由 App 依 resultPending 推导。
class BackgroundWorkView {
  final String workId;
  final String kind; // bash / subagent
  final String label;
  final String status; // running / resultPending / failed / cancelled
  final int? startedAt;
  final int? endedAt;
  final bool cancellable;
  final String? childSessionId;

  BackgroundWorkView({
    required this.workId,
    required this.kind,
    required this.label,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.cancellable,
    required this.childSessionId,
  });

  /// 只有真在跑的才算运行中。resultPending 是「进程已结束、结果待收」
  /// ——不该再给取消按钮，也不该亮黄色运行边框。
  bool get running => status == 'running';

  /// 进程正常结束（服务端无 completed 态，resultPending 即完成待收）。
  bool get done => status == 'resultPending';

  /// 状态中文（主题状态色映射在 UI 层）。
  String get statusLabel => switch (status) {
    'running' => '运行中',
    'resultPending' => '已完成',
    'failed' => '失败',
    'cancelled' => '已取消',
    _ => status,
  };
}

/// snapshot.backgroundWorks → BackgroundWorkView 列表；非 List/空项跳过。
/// workId 缺失的项丢弃（没有 workId 就无法取消/追踪）。
List<BackgroundWorkView> parseBackgroundWorks(Object? works) {
  if (works is! List) return const [];
  final out = <BackgroundWorkView>[];
  for (final w in works) {
    if (w is! Map) continue;
    final workId = '${w['workId'] ?? w['id'] ?? ''}';
    if (workId.isEmpty) continue;
    final label = [
      if (w['title'] != null) '${w['title']}',
      if (w['name'] != null) '${w['name']}',
      if (w['kind'] != null) '${w['kind']}',
      if (w['command'] != null) '${w['command']}',
    ].firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    final startedAt = w['startedAt'] is num ? (w['startedAt'] as num).toInt() : null;
    out.add(BackgroundWorkView(
      workId: workId,
      kind: '${w['kind'] ?? ''}',
      label: label.isEmpty ? '后台任务 ${workId.length > 8 ? workId.substring(0, 8) : workId}' : label,
      status: '${w['status'] ?? 'running'}',
      startedAt: startedAt,
      endedAt: w['endedAt'] is num ? (w['endedAt'] as num).toInt() : null,
      cancellable: w['cancellable'] == true,
      childSessionId: w['childSessionId'] != null ? '${w['childSessionId']}' : null,
    ));
  }
  return out;
}

/// 快照 subagents.running[] 的实时子代理（桌面端 dje/awn schema 实测）。
class SubagentLiveView {
  final String childSessionId;
  final String type; // subagentType
  final String title;
  final String summary;
  final String status; // running / waiting / blocked
  final int? startedAt;

  SubagentLiveView({
    required this.childSessionId,
    required this.type,
    required this.title,
    required this.summary,
    required this.status,
    required this.startedAt,
  });

  /// waiting/blocked 是"卡住等输入"，用警示色在 UI 区分。
  bool get stuck => status != 'running';

  String get statusLabel => switch (status) {
    'running' => '运行中',
    'waiting' => '等待输入',
    'blocked' => '被阻塞',
    _ => status,
  };
}

/// snapshot.subagents → running 列表解析；非 Map/缺 running 安全兜底。
List<SubagentLiveView> parseSubagents(Object? field) {
  if (field is! Map) return const [];
  final running = field['running'];
  if (running is! List) return const [];
  final out = <SubagentLiveView>[];
  for (final e in running) {
    if (e is! Map) continue;
    final child = '${e['childSessionId'] ?? ''}';
    final type = '${e['subagentType'] ?? ''}';
    if (child.isEmpty && type.isEmpty) continue;
    final startedAt = e['startedAt'] is num ? (e['startedAt'] as num).toInt() : null;
    out.add(SubagentLiveView(
      childSessionId: child,
      type: type,
      title: '${e['title'] ?? ''}',
      summary: '${e['summary'] ?? ''}',
      status: '${e['status'] ?? 'running'}',
      startedAt: startedAt,
    ));
  }
  return out;
}

/// 以 Agent/Task 工具调用形式运行的子代理行（timeline 上是 toolCall
/// 而非 subagent 行）——运行中的算作子代理活动。
List<SubagentActivity> streamingAgentToolCalls(
  List<Map<String, dynamic>> rows,
) {
  final out = <SubagentActivity>[];
  for (final r in rows) {
    if (r['kind'] != 'toolCall') continue;
    if (r['state'] != 'streaming') continue;
    final name = '${r['toolName'] ?? r['name'] ?? ''}'.toLowerCase();
    if (name != 'agent' && name != 'task') continue;
    var summary = '${r['inputText'] ?? ''}'.trim();
    if (summary.isEmpty) {
      final input = r['input'];
      if (input is Map) {
        summary =
            '${input['description'] ?? input['prompt'] ?? ''}'.trim();
      }
    }
    out.add(SubagentActivity(
      rowId: (r['rowId'] as num?)?.toInt(),
      summary: summary.isEmpty ? '运行中…' : summary,
    ));
  }
  return out;
}
