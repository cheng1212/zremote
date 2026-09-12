/// 任务事件通知纯逻辑：phase 变迁 → 事件分类。无 Flutter 依赖，可单测。
library;

/// 会话级事件（通知的触发来源）。
enum TaskEventKind { completed, interrupted, error, waitingInput }

/// 变迁判定：上一帧 phase + 下一帧 phase（+ 等待交互出现）→ 事件或 null。
/// 规则：
/// - 只有从活跃态（running/prewarming）离开才报 完成/中断/报错——
///   首帧快照（prev==null）与静止态之间的变化一律不响，防开页轰炸；
/// - waitingInput：prev 已知且本次新出现 pendingInteraction 即响
///   （不要求活跃态，排队中的会话也可能来一次确认）。
({TaskEventKind kind, String title})? detectTaskEvent(
  String? prevPhase,
  String nextPhase, {
  required bool prevWaiting,
  required bool nextWaiting,
}) {
  if (prevPhase == null) return null;
  if (!prevWaiting && nextWaiting) {
    return (kind: TaskEventKind.waitingInput, title: '等待你的确认');
  }
  final wasActive = prevPhase == 'running' || prevPhase == 'prewarming';
  if (!wasActive) return null;
  return switch (nextPhase) {
    'completedSuccess' => (kind: TaskEventKind.completed, title: '任务完成'),
    'completedInterrupted' => (
      kind: TaskEventKind.interrupted,
      title: '任务中断',
    ),
    'error' => (kind: TaskEventKind.error, title: '任务报错'),
    _ => null,
  };
}

/// 事件 → 通知正文的后缀提示（标题在调用方拼会话名）。
String taskEventHint(TaskEventKind kind) => switch (kind) {
  TaskEventKind.completed => '跑完了，点开看结果',
  TaskEventKind.interrupted => '被中断了，可能需要你接手',
  TaskEventKind.error => '出错了，点开看详情',
  TaskEventKind.waitingInput => 'Agent 有问题要问你',
};

/// 全局轮询（跨项目）用的变迁判定：任务 meta.status 词汇
/// running/completed/error（桌面 tasks-index 实测）。
/// 轮询是慢通道（20s 一拍、全项目覆盖），实时索引是快通道（当前项目、
/// 毫秒级、还能看到"中断"）——两路可能报同一事件，调用方用 [dedupeKey]
/// 落去重账（end 类事件互斥：一个会话 90s 内只提醒一次终结）。
({String title, String body, String dedupeKey})? detectPollTaskEvent(
  String? prev,
  String next,
) {
  if (prev == null || prev != 'running') return null;
  return switch (next) {
    'completed' => (
      title: '任务完成',
      body: '跑完了，点开看结果',
      dedupeKey: 'end',
    ),
    'error' => (
      title: '任务报错',
      body: '出错了，点开看详情',
      dedupeKey: 'end',
    ),
    _ => null,
  };
}
