/// 任务列表筛选/排序纯逻辑（参考图改造）。无 Flutter 依赖，可单测。
/// @fileoverview 与 task_sort.dart 互补：那边是「数据收敛排序」（ZApp 写入
/// tasks 前统一置顶+活跃倒序），这边是「展示层筛选/排序」（页面 tab 与
/// 排序菜单，只影响显示不改数据源）。
library;

/// 筛选 tab。归档集合由调用方单独加载（listArchivedTasks），不与主列表混存。
enum TaskFilter { all, pinned, recent, archived }

/// 排序键。lastActive=最近更新（默认），created=创建时间，title=标题。
enum TaskSortKey { lastActive, created, title }

/// 会话状态筛选（用户 2026-09-14：「按运行中/出错等状态找会话」）。
/// 分组是有意收敛的：9 种 phase 归并成 3 个用户视角组，chips 才放得下。
enum TaskStatusFilter { all, running, error, waitingInput }

/// 会话 map 是否命中状态筛选。
/// 组→phase 口径与 `phaseStyle`（theme.dart）一致：
/// running 组含预热中（prewarming 也是"在跑"），error 组含已完成但出错
/// （completedError 对用户的语义就是"这个会话出错了"）。
bool taskMatchesStatusFilter(Map<String, dynamic> t, TaskStatusFilter f) {
  if (f == TaskStatusFilter.all) return true;
  final phase = '${t['phase'] ?? ''}';
  return switch (f) {
    TaskStatusFilter.running => phase == 'running' || phase == 'prewarming',
    TaskStatusFilter.error => phase == 'error' || phase == 'completedError',
    TaskStatusFilter.waitingInput => phase == 'waitingInput',
    TaskStatusFilter.all => true,
  };
}

/// 查询串 → 匹配判定：标题 + 预览包含（大小写不敏感）；空串恒真。
bool taskMatchesQuery(Map<String, dynamic> t, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final title = '${t['title'] ?? ''}'.toLowerCase();
  final preview = '${t['lastAssistantPreview'] ?? ''}'.toLowerCase();
  return title.contains(q) || preview.contains(q);
}

/// 卡片创建时间戳（仅 createdAt，非法给 0 沉底）。
int taskCreatedTs(Map<String, dynamic> t) {
  final v = t['createdAt'];
  return v is num && v > 0 ? v.toInt() : 0;
}

/// 按排序键排序，**置顶组恒在最前**（组内按所选键排）。
///
/// 这里必须在展示层再保一次置顶优先：数据层 sortTaskCards 虽然排好了，
/// 但本函数是平铺重排——不先比置顶位，lastActive 一排序就把置顶卡
/// 沉回活跃序列里（BUG-29：图钉亮着、位置不对）。
List<Map<String, dynamic>> sortTaskCardsBy(
  List<Map<String, dynamic>> tasks,
  TaskSortKey key,
) {
  int pinRank(Map<String, dynamic> t) => t['pinned'] == true ? 0 : 1;
  final sorted = [...tasks];
  switch (key) {
    case TaskSortKey.lastActive:
      sorted.sort((a, b) {
        final p = pinRank(a).compareTo(pinRank(b));
        if (p != 0) return p;
        return _activity(b).compareTo(_activity(a));
      });
    case TaskSortKey.created:
      sorted.sort((a, b) {
        final p = pinRank(a).compareTo(pinRank(b));
        if (p != 0) return p;
        return taskCreatedTs(b).compareTo(taskCreatedTs(a));
      });
    case TaskSortKey.title:
      int cmp(Map<String, dynamic> a, Map<String, dynamic> b) {
        final p = pinRank(a).compareTo(pinRank(b));
        if (p != 0) return p;
        final at = '${a['title'] ?? ''}';
        final bt = '${b['title'] ?? ''}';
        final c = at.toLowerCase().compareTo(bt.toLowerCase());
        if (c != 0) return c;
        return _activity(b).compareTo(_activity(a)); // 同名按活跃，稳定
      }

      sorted.sort(cmp);
  }
  return sorted;
}

int _activity(Map<String, dynamic> t) {
  // 复用 task_sort 的活跃时间口径（同库引入会循环？独立小实现避免耦合）。
  for (final key in const ['lastActivityAt', 'updatedAt', 'createdAt']) {
    final v = t[key];
    if (v is num && v > 0) return v.toInt();
  }
  return 0;
}

/// 筛选 + 查询 + 排序的一站式入口（页面 build 直接用）。
/// [archived] 仅在 [TaskFilter.archived] 时参与；[recentDays] 默认 7 天。
List<Map<String, dynamic>> visibleTaskCards(
  List<Map<String, dynamic>> tasks, {
  required TaskFilter filter,
  required String query,
  required TaskSortKey sortKey,
  TaskStatusFilter statusFilter = TaskStatusFilter.all,
  List<Map<String, dynamic>> archived = const [],
  int? nowMs,
  int recentDays = 7,
}) {
  Iterable<Map<String, dynamic>> pool = switch (filter) {
    TaskFilter.all => tasks,
    TaskFilter.pinned => tasks.where((t) => t['pinned'] == true),
    TaskFilter.recent => _recentOf(tasks, nowMs, recentDays),
    TaskFilter.archived => archived,
  };
  final out = [
    for (final t in pool)
      if (taskMatchesQuery(t, query) &&
          taskMatchesStatusFilter(t, statusFilter))
        t,
  ];
  return sortTaskCardsBy(out, sortKey);
}

Iterable<Map<String, dynamic>> _recentOf(
  List<Map<String, dynamic>> tasks,
  int? nowMs,
  int days,
) {
  final nowMs0 = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final floor = nowMs0 - days * 24 * 3600 * 1000;
  return tasks.where((t) => _activity(t) >= floor);
}

/// 批量重命名规则：查找替换 + 统一前缀/后缀。
///
/// 按顺序应用（每种只在对应输入非空时生效）：
/// 1. 查找替换：`find` 全部替换成 `replace`；
/// 2. 前缀：拼在结果前面（已有则不重复加）；3. 后缀：同理。
///
/// **不做正则**：用户输入里的 `.`/`*` 应当按字面量处理——批量改名没有撤销，
/// 让一个 `.` 变成"任意字符"是灾难。
class BatchRenameSpec {
  final String find;
  final String replace;
  final String prefix;
  final String suffix;

  const BatchRenameSpec({
    this.find = '',
    this.replace = '',
    this.prefix = '',
    this.suffix = '',
  });

  /// 任何规则都没实际作用（对话框据此禁用确认键）。
  bool get isNoop =>
      (find.isEmpty || find == replace) && prefix.isEmpty && suffix.isEmpty;

  String apply(String title) {
    var out = title;
    if (find.isNotEmpty && find != replace) {
      out = out.replaceAll(find, replace);
    }
    if (prefix.isNotEmpty && !out.startsWith(prefix)) out = '$prefix$out';
    if (suffix.isNotEmpty && !out.endsWith(suffix)) out = '$out$suffix';
    return out.trim();
  }
}
