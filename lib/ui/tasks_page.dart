import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/relay_client.dart';
import '../state/app_controller.dart';
import '../state/task_filters.dart';
import '../state/task_sort.dart';
import '../theme.dart';
import 'automations_page.dart';
import 'composer_logic.dart';
import 'usage_page.dart';

/// 任务（会话）列表页：常驻搜索 + 筛选 tab + 排序 + 富信息卡片。
/// 长按卡片弹出单会话操作（置顶/重命名/删除）；工具栏进入批量管理。
class TasksPage extends StatefulWidget {
  final ZApp app;
  final void Function(String sessionId, String title) onOpenTask;
  final VoidCallback onNewChat;

  const TasksPage({
    super.key,
    required this.app,
    required this.onOpenTask,
    required this.onNewChat,
  });

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool _manage = false;
  final _selected = <String>{};
  final _searchCtl = TextEditingController();
  String _query = '';
  TaskFilter _filter = TaskFilter.all;
  TaskSortKey _sortKey = TaskSortKey.lastActive;

  /// 列表可见时的状态对账定时器。
  ///
  /// 为什么需要：任务卡 phase 主要靠 sessions-index 流推送，而这个流会
  /// **丢更新**（`_livePhase` 覆盖机制的存在本身就是为它兜底）。没被打开
  /// 过的会话没有覆盖，流一丢就永久停在旧状态——用户看到"运行中"其实早
  /// 跑完了。定时轻量对账把漏掉的 phase 纠回来。
  Timer? _reconcileTimer;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onApp);
    // 12s 一次够及时（人眼对状态变化的容忍度在十几秒），又不会打爆服务端。
    _reconcileTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _reconcilePhase(),
    );
  }

  /// 轻量对账：只刷 index（本地内存态合并），不发起网络往返。
  ///
  /// 真正的"拉新数据"由下拉刷新与已有的 token 定时器承担；这里的职责
  /// 是把**已经到达但没合并进 tasks 的** index 更新落下去。所以只调
  /// refreshFromIndex，不调 loadTasks——避免每 12 秒一次 RPC。
  void _reconcilePhase() {
    if (!mounted) return;
    widget.app.refreshFromIndex();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _reconcileTimer?.cancel();
    widget.app.removeListener(_onApp);
    _searchCtl.dispose();
    super.dispose();
  }

  String _taskTitle(Map<String, dynamic> t) {
    final title = t['title'];
    if (title is String && title.trim().isNotEmpty) return title;
    final id = '${t['taskId'] ?? ''}';
    return '新对话 ${id.length > 8 ? id.substring(0, 8) : id}…';
  }

  // ----------------------------------------------------------- manage mode

  void _toggleManage() => setState(() {
    _manage = !_manage;
    _selected.clear();
  });

  void _toggleSelect(String id) => setState(() {
    if (_selected.contains(id)) {
      _selected.remove(id);
    } else {
      _selected.add(id);
    }
  });

  void _selectAll(List<Map<String, dynamic>> tasks) => setState(() {
    if (tasks.isNotEmpty && _selected.length == tasks.length) {
      _selected.clear();
    } else {
      _selected
        ..clear()
        ..addAll([for (final t in tasks) '${t['taskId']}']);
    }
  });

  /// 批量执行：逐个调用并计失败数，结束统一刷新；只在有失败时红条报错。
  Future<void> _runBatch(
    List<String> ids,
    Future<void> Function(String id) op,
    String errorPrefix,
  ) async {
    var failed = 0;
    for (final id in ids) {
      try {
        await op(id);
      } on Object catch (e) {
        failed++;
        widget.app.log('[$errorPrefix] $id: $e');
      }
    }
    try {
      // 跟着当前数据源刷新：在「全部对话」里批量完刷当前项目列表是白刷，
      // 用户看到的还是没动过的「全部」列表（和 _setPinned 一个道理）。
      if (widget.app.viewingAllProjects) {
        await widget.app.loadAllProjectTasks();
      } else {
        await widget.app.loadTasks();
      }
      await widget.app.loadArchivedTasks();
    } on Object {
      // 刷新失败不打断流程；下次进入页面再同步。
    }
    if (!mounted) return;
    setState(_selected.clear);
    if (failed > 0) {
      flashMessage(
        context,
        '$errorPrefix：$failed/${ids.length} 个失败',
        error: true,
      );
    }
  }

  // ------------------------------------------------------------ single ops

  Future<void> _setPinned(Map<String, dynamic> t, bool pinned) async {
    final app = widget.app;
    try {
      await app.setTaskPinned('${t['taskId']}', pinned);
      // **不再**跟一次整机刷新：setTaskPinned 是乐观的——`_pinOverrides`
      // 已经写进两张列表（`_resortLists`），失败会回滚并抛异常。
      // 而这里的刷新在「全部对话」里等于 1 次 bootstrap + 7 次
      // listPinnedTasks（置顶缓存刚被作废），点一下图钉的代价大得离谱。
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, pinned ? '置顶失败：$e' : '取消置顶失败：$e', error: true);
    }
  }

  Future<void> _archiveTask(Map<String, dynamic> t) async {
    try {
      await widget.app.archiveTask('${t['taskId']}');
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '归档失败：$e', error: true);
    }
  }

  Future<void> _unarchiveTask(Map<String, dynamic> t) async {
    try {
      await widget.app.unarchiveTask('${t['taskId']}');
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '取消归档失败：$e', error: true);
    }
  }

  Future<void> _renameTask(Map<String, dynamic> t) async {
    final id = '${t['taskId']}';
    final current = _taskTitle(t);
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '重命名会话',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
          ),
          BigButton(
            label: '保存',
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty || result == current) return;
    try {
      await widget.app.renameTask(id, result);
      // 跟着当前数据源刷新：在「全部」里改完名字，刷当前项目列表看不到变化。
      if (widget.app.viewingAllProjects) {
        await widget.app.loadAllProjectTasks();
      } else {
        await widget.app.loadTasks();
      }
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '重命名失败：$e', error: true);
    }
  }

  /// 批量重命名：查找替换 + 统一前缀/后缀两种模式。
  /// 不做序号——序号语义依赖排序，用户看到的名字会随列表顺序变，容易误伤。
  /// 预览区实时显示改名结果，避免"改完才发现规则写错"（批量操作不可逆）。
  Future<void> _batchRename(List<Map<String, dynamic>> targets) async {
    final result = await showDialog<BatchRenameSpec>(
      context: context,
      builder: (dialogCtx) => _BatchRenameDialog(
        titles: [for (final t in targets) _taskTitle(t)],
      ),
    );
    if (result == null) return;
    // 逐个算出新名字（对话框已经保证规范非空）。
    final plan = <String, String>{};
    for (final t in targets) {
      final old = _taskTitle(t);
      final next = result.apply(old);
      if (next.isEmpty || next == old) continue;
      plan['${t['taskId']}'] = next;
    }
    if (plan.isEmpty) {
      if (mounted) flashMessage(context, '改完和原来一样，没有变化');
      return;
    }
    await _runBatch(
      plan.keys.toList(),
      (id) => widget.app.renameTask(id, plan[id]!),
      '重命名失败',
    );
    if (mounted) flashMessage(context, '已重命名 ${plan.length} 个会话');
  }

  Future<void> _deleteTasks(List<Map<String, dynamic>> targets) async {
    final label = targets.length == 1
        ? '「${_taskTitle(targets.first)}」'
        : '${targets.length} 个会话';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: Text(
          targets.length == 1 ? '删除会话？' : '删除 ${targets.length} 个会话？',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '将删除$label，此操作不可恢复。',
          style: const TextStyle(fontSize: 13, color: ZT.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: TextButton.styleFrom(foregroundColor: ZT.rose),
            child: const Text(
              '删除',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runBatch(
      [for (final t in targets) '${t['taskId']}'],
      (id) => widget.app.deleteTask(id),
      '删除失败',
    );
  }

  void _openTaskActions(Map<String, dynamic> t) {
    final pinned = widget.app.isTaskPinned(t);
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
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
              Text(
                _taskTitle(t),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              for (final row in [
                (
                  id: 'pin',
                  icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
                  label: pinned ? '取消置顶' : '置顶',
                  color: ZT.primary,
                ),
                (
                  id: 'rename',
                  icon: Icons.edit_outlined,
                  label: '重命名',
                  color: ZT.ink,
                ),
                (
                  id: 'copyId',
                  icon: Icons.copy_rounded,
                  label: '复制会话 ID',
                  color: ZT.inkSoft,
                ),
                (
                  id: 'archive',
                  icon: _filter == TaskFilter.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  label: _filter == TaskFilter.archived ? '取消归档' : '归档',
                  color: ZT.inkSoft,
                ),
                (
                  id: 'delete',
                  icon: Icons.delete_outline_rounded,
                  label: '删除',
                  color: ZT.rose,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: Ink(
                      decoration: ShapeDecoration(
                        color: ZT.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(ZT.radius),
                          side: ZT.inkSide(w: 1.2),
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(ZT.radius),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          switch (row.id) {
                            case 'pin':
                              _setPinned(t, !pinned);
                            case 'copyId':
                              Clipboard.setData(
                                ClipboardData(text: '${t['taskId']}'),
                              );
                              flashMessage(context, '会话 ID 已复制');
                            case 'rename':
                              _renameTask(t);
                            case 'archive':
                              _filter == TaskFilter.archived
                                  ? _unarchiveTask(t)
                                  : _archiveTask(t);
                            case 'delete':
                              _deleteTasks([t]);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(11),
                          child: Row(
                            children: [
                              Icon(row.icon, size: 18, color: row.color),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  row.label,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    color: row.color,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- refresh

  /// 顶栏刷新：拉一次任务列表，成功报数量，失败红条。
  Future<void> _refreshTasks() async {
    try {
      await widget.app.loadTasks();
      if (!mounted) return;
      flashMessage(context, '已刷新 · ${widget.app.tasks.length} 个对话');
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '刷新失败: $e', error: true);
    }
  }

  /// 多工作区且还没选时给选择列表。connect 只在单工作区时自动开桥，
  /// 多于一个就得在这里点一下，否则永远没有桥可用。
  Widget _workspacePicker() {
    final app = widget.app;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            '有 ${app.workspaces.length} 个工作区，点一个打开',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: ZT.inkSoft,
            ),
          ),
        ),
        for (final w in app.workspaces)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HardCard(
              onTap: () => app.openWorkspace(w),
              child: Row(
                children: [
                  const Icon(Icons.folder_rounded, size: 20, color: ZT.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.workspaceTitle(w),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if ('${w['workspacePath'] ?? ''}'.isNotEmpty)
                          Text(
                            '${w['workspacePath']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: ZT.inkFaint,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: ZT.inkFaint,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- build

  Widget _manageBar(List<Map<String, dynamic>> tasks) {
    final selTasks = [
      for (final t in tasks)
        if (_selected.contains('${t['taskId']}')) t,
    ];
    final allPinned =
        selTasks.isNotEmpty && selTasks.every((t) => widget.app.isTaskPinned(t));
    final enabled = selTasks.isNotEmpty;
    // 归档 tab 里批量操作的是"取消归档"，其它 tab 是"归档"——
    // 同一个按钮按当前 tab 换语义，和单卡菜单里的做法一致。
    final inArchiveTab = _filter == TaskFilter.archived;
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: ZT.surface,
          border: Border(top: BorderSide(width: 1.4, color: ZT.line)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selTasks.isEmpty ? '选择会话进行管理' : '已选 ${selTasks.length} 个会话',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selTasks.isEmpty ? ZT.inkFaint : ZT.ink,
                ),
              ),
            ),
            _BarAction(
              icon: allPinned ? Icons.push_pin_outlined : Icons.push_pin,
              label: allPinned ? '取消置顶' : '置顶',
              enabled: enabled,
              onTap: enabled
                  ? () => _runBatch(
                      [for (final t in selTasks) '${t['taskId']}'],
                      (id) => widget.app.setTaskPinned(id, !allPinned),
                      allPinned ? '取消置顶失败' : '置顶失败',
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            _BarAction(
              icon: inArchiveTab
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: inArchiveTab ? '取消归档' : '归档',
              enabled: enabled,
              onTap: enabled
                  ? () => _runBatch(
                      [for (final t in selTasks) '${t['taskId']}'],
                      (id) => inArchiveTab
                          ? widget.app.unarchiveTask(id)
                          : widget.app.archiveTask(id),
                      inArchiveTab ? '取消归档失败' : '归档失败',
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            _BarAction(
              icon: Icons.drive_file_rename_outline_rounded,
              label: '重命名',
              enabled: enabled,
              onTap: enabled ? () => _batchRename(selTasks) : null,
            ),
            const SizedBox(width: 8),
            _BarAction(
              icon: Icons.delete_outline_rounded,
              label: '删除',
              enabled: enabled,
              danger: true,
              onTap: enabled ? () => _deleteTasks(selTasks) : null,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    // 数据层（sortTaskCards）已收敛置顶+活跃序；这里只做展示层筛选/排序。
    // 管理模式同样作用于当前筛选集（对可见集合批量操作更直觉）。
    // 数据源由 app.listedTasks 分岔：单项目视图 / 「全部对话」跨项目视图。
    final tasks = visibleTaskCards(
      app.listedTasks,
      filter: _filter,
      query: _query,
      sortKey: _sortKey,
      archived: app.archivedTasks,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final (relayColor, relayLabel) = relayStateStyle(app.relayState);

    return Scaffold(
      drawer: _buildDrawer(context),
      appBar: AppBar(
        title: _manage
            ? Text('已选 ${_selected.length} / ${tasks.length}')
            : InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _openWorkspaceSwitcher,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        app.viewingAllProjects
                            ? '全部对话'
                            : app.workspace != null
                            ? app.workspaceTitle(app.workspace!)
                            : '任务',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: ZT.inkSoft,
                    ),
                  ],
                ),
              ),
        actions: [
          if (!_manage)
            IconButton(
              tooltip: '刷新会话列表',
              // 刷新有可见反馈：拉取中图标换成转圈，完成后弹条报数量。
              onPressed: _refreshTasks,
              icon: ListenableBuilder(
                listenable: widget.app,
                builder: (context, _) => SizedBox(
                  width: 22,
                  height: 22,
                  child: widget.app.tasksLoading
                      ? const Padding(
                          padding: EdgeInsets.all(3),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: ZT.ink,
                          ),
                        )
                      : const Icon(Icons.refresh_rounded, color: ZT.ink),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: ShapeDecoration(
                  color: ZT.surface,
                  shape: StadiumBorder(
                    side: ZT.inkSide(w: 1.2, color: relayColor),
                  ),
                ),
                child: Row(
                  children: [
                    PulseDot(
                      color: relayColor,
                      animate: app.relayState != RelayState.paired,
                      size: 6,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      relayLabel,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: relayColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_manage)
            TextButton(
              onPressed: () => _selectAll(tasks),
              child: Text(
                tasks.isNotEmpty && _selected.length == tasks.length
                    ? '全不选'
                    : '全选',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          if (_manage)
            TextButton(
              onPressed: _toggleManage,
              child: const Text(
                '完成',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: ZT.primaryDeep,
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton:
          _manage ||
                  app.isReadOnlySnapshot ||
                  (app.workspace == null && app.workspaces.length > 1)
          ? null
          : FloatingActionButton(
              onPressed: _newChatWithProject,
              mini: true,
              backgroundColor: ZT.primary,
              foregroundColor: Colors.white,
              shape: const CircleBorder(
                side: BorderSide(width: 1.8, color: ZT.ink),
              ),
              elevation: 0,
              highlightElevation: 0,
              child: const Icon(Icons.add_rounded, size: 26),
            ),
      bottomNavigationBar: _manage ? _manageBar(tasks) : null,
      body: app.openingWorkspace
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: ZT.primary),
                  SizedBox(height: 14),
                  Text(
                    '正在打开工作区桥…',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZT.inkSoft,
                    ),
                  ),
                ],
              ),
            )
          : app.workspace == null && app.workspaces.length > 1
          ? _workspacePicker()
          : Column(
              children: [
                _connBanner(app),
                // 服务端列表拉取失败 → 本地缓存降级中。缓存可用但要诚实：
                // 明确告诉用户"现在看的可能滞后"，正在自动重试。
                if (app.tasksStale)
                  Container(
                    width: double.infinity,
                    color: ZT.surface,
                    padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.sync_problem_rounded,
                          size: 13,
                          color: ZT.inkSoft,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '同步中断，列表为本机缓存，正在自动重试',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: ZT.inkSoft,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                _searchBar(),
                _filterRow(),
                Expanded(
                  child: RefreshIndicator(
                    color: ZT.primaryDeep,
                    // 下拉刷新跟着当前数据源走，别在「全部对话」里刷当前项目的列表。
                    onRefresh: app.viewingAllProjects
                        ? app.loadAllProjectTasks
                        : app.loadTasks,
                    child: tasks.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.of(context).size.height * 0.6,
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 64,
                                        height: 64,
                                        decoration: ShapeDecoration(
                                          color: ZT.lemon,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                            side: ZT.inkSide(w: 1.8),
                                          ),
                                          shadows: ZT.hard(dx: 4, dy: 4),
                                        ),
                                        child: const Icon(
                                          Icons.chat_bubble_rounded,
                                          color: ZT.ink,
                                          size: 30,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        app.tasksLoading
                                            ? '加载任务中…'
                                            : _query.trim().isNotEmpty ||
                                                  _filter != TaskFilter.all
                                            ? '没有匹配的会话'
                                            : '还没有对话',
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '点右下角「新对话」开始',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: ZT.inkFaint,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(
                              16,
                              12,
                              16,
                              _manage ? 16 : 96,
                            ),
                            itemCount: tasks.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, i) {
                              final t = tasks[i];
                              final id = '${t['taskId'] ?? ''}';
                              final pinned = app.isTaskPinned(t);
                              final selected = _selected.contains(id);
                              final phase = '${t['phase'] ?? ''}';
                              final preview =
                                  '${t['lastAssistantPreview'] ?? ''}';
                              final hasAsk = t['pendingInteraction'] != null;
                              // 聊天页上报的发送异常：不点进会话也能看到
                              // "那条消息没发出去"。
                              final sendIssue = app.sendIssue(id);
                              final tokenLabel = tokenCountLabel(
                                app.taskToken(id),
                              );
                              final timeLabel = taskTimeLabel(t);
                              // 「全部对话」里卡片来自不同项目，标出所属项目，
                              // 否则同名会话根本分不清是谁的。
                              final projectLabel = app.viewingAllProjects
                                  ? app.taskProjectName(t)
                                  : '';
                              // 模型 chip：服务端任务对象自带 model 字段
                              // （探针实测 providerId/modelId）；缺失退回本地意图记录。
                              final serverModel = '${t['model'] ?? ''}';
                              final modelLabel = serverModel.contains('/')
                                  ? serverModel.substring(
                                      serverModel.lastIndexOf('/') + 1,
                                    )
                                  : (serverModel.isNotEmpty
                                        ? serverModel
                                        : '${(app.sessionModels[id] ?? const {})['model'] ?? ''}');
                              return HardCard(
                                color: selected
                                    ? ZT.lemon.withValues(alpha: 0.4)
                                    : ZT.surface,
                                onTap: () async {
                                  if (_manage) {
                                    _toggleSelect(id);
                                    return;
                                  }
                                  // 只读快照期（断开后 / 重连中）：别点了没反应，说清楚原因。
                                  if (app.isReadOnlySnapshot) {
                                    flashMessage(
                                      context,
                                      '已断开，先在抽屉里重新连接',
                                      error: true,
                                    );
                                    return;
                                  }
                                  // 「全部对话」里点别的项目的会话：先把桥切过去，
                                  // 否则会拿当前项目的桥去开别人的会话。
                                  final aligned = await app.ensureTaskProject(t);
                                  if (!context.mounted) return;
                                  if (!aligned) {
                                    flashMessage(
                                      context,
                                      '打不开：这个会话所属的项目现在连不上',
                                      error: true,
                                    );
                                    return;
                                  }
                                  widget.onOpenTask(id, _taskTitle(t));
                                },
                                onLongPress: _manage
                                    ? null
                                    : () => _openTaskActions(t),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_manage) ...[
                                      _SelectBox(selected: selected),
                                      const SizedBox(width: 10),
                                    ],
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _taskTitle(t),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 14.5,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                              if (pinned) ...[
                                                const SizedBox(width: 6),
                                                const Icon(
                                                  Icons.push_pin,
                                                  size: 13,
                                                  color: ZT.primary,
                                                ),
                                              ],
                                            ],
                                          ),
                                          if (preview.isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                              preview,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                color: ZT.inkSoft,
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 7),
                                          // 信息 chips 行：状态 / 模型 / token / 时间
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 4,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              if (projectLabel.isNotEmpty)
                                                _CardChip(
                                                  projectLabel,
                                                  color: ZT.inkSoft,
                                                ),
                                              StatusChip(
                                                phase: phase,
                                                compact: true,
                                              ),
                                              if (modelLabel.isNotEmpty)
                                                _CardChip(
                                                  modelLabel,
                                                  color: ZT.primaryDeep,
                                                  mono: true,
                                                ),
                                              if (tokenLabel.isNotEmpty)
                                                Text(
                                                  '⚡$tokenLabel',
                                                  style: const TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: ZT.inkFaint,
                                                  ),
                                                ),
                                              if (timeLabel.isNotEmpty)
                                                Text(
                                                  timeLabel,
                                                  style: const TextStyle(
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: ZT.inkFaint,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          if (hasAsk) ...[
                                            const SizedBox(height: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                                  ),
                                              decoration: ShapeDecoration(
                                                color: ZT.lemon,
                                                shape: StadiumBorder(
                                                  side: ZT.inkSide(w: 1.2),
                                                ),
                                              ),
                                              child: const Text(
                                                '⏸ 等待你的确认',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                          ],
                                          // 发送异常优先于等待确认展示：一条
                                          // 没发出去的消息比一个待答弹窗更急。
                                          if (sendIssue != null) ...[
                                            const SizedBox(height: 8),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                                  ),
                                              decoration: ShapeDecoration(
                                                color: ZT.rose.withValues(
                                                  alpha: 0.14,
                                                ),
                                                shape: StadiumBorder(
                                                  side: ZT.inkSide(
                                                    w: 1.2,
                                                    color: ZT.rose,
                                                  ),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.error_outline_rounded,
                                                    size: 12,
                                                    color: ZT.rose,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    sendIssue,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: ZT.rose,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  /// 链路状态就地提示条：重连与断开都留在本页，得让人知道当前链路发生了什么。
  /// 一切正常时返回零高度占位，不占位置。
  Widget _connBanner(ZApp app) {
    if (app.reconnectingInPlace) {
      return _statusStrip(
        color: ZT.lemon,
        icon: Icons.sync_rounded,
        text: '重连中…当前列表是断线前的快照，连上后自动刷新',
      );
    }
    if (app.isReadOnlySnapshot) {
      return _statusStrip(
        color: ZT.rose,
        icon: Icons.link_off_rounded,
        text: '已断开 —— 抽屉里可「重新连接」或「去连接」',
      );
    }
    return const SizedBox.shrink();
  }

  Widget _statusStrip({
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 15, color: ZT.ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: ZT.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 汉堡抽屉：低频操作收拢（刷新/批量管理/定时任务/重连/断开）。
  Widget _buildDrawer(BuildContext context) {
    final app = widget.app;
    final (relayColor, relayLabel) = relayStateStyle(app.relayState);
    return Drawer(
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(0)),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
              child: Row(
                children: [
                  const Icon(Icons.forum_rounded, size: 18, color: ZT.primary),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text(
                      'zremote',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: ShapeDecoration(
                      color: ZT.bg,
                      shape: StadiumBorder(
                        side: ZT.inkSide(w: 1.2, color: relayColor),
                      ),
                    ),
                    child: Text(
                      relayLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: relayColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: ZT.line, thickness: 1.2),
            _drawerItem(
              icon: Icons.refresh_rounded,
              label: '刷新会话列表',
              onTap: () {
                Navigator.pop(context);
                _refreshTasks();
              },
            ),
            _drawerItem(
              icon: Icons.cloud_download_rounded,
              label: '从服务端拉取最新',
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await app.pullLatest();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        '已按服务端对齐 · ${app.tasks.length} 个对话',
                      ),
                    ),
                  );
                } on Object catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      backgroundColor: ZT.rose,
                      content: Text('拉取失败: $e'),
                    ),
                  );
                }
              },
            ),
            _drawerItem(
              icon: Icons.schedule_rounded,
              label: '定时任务',
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => AutomationsPage(app: app)),
                );
              },
            ),
            _drawerItem(
              icon: Icons.insights_rounded,
              label: '用量信息',
              onTap: () {
                Navigator.pop(context);
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => UsagePage(app: app)));
              },
            ),
            const Divider(color: ZT.line, thickness: 1.2),
            _drawerItem(
              icon: Icons.link_rounded,
              label: '重新连接',
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await app.reconnect();
                  messenger.showSnackBar(const SnackBar(content: Text('重连成功')));
                } on Object catch (e) {
                  messenger.showSnackBar(
                    SnackBar(
                      backgroundColor: ZT.rose,
                      content: Text('重连失败: $e'),
                    ),
                  );
                }
              },
            ),
            _drawerItem(
              icon: Icons.link_off_rounded,
              label: '断开连接',
              danger: true,
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(context);
                // 就地断开：只拆连接，留在会话页（列表变只读快照），
                // 不再 popUntil + 清空工作区把人甩回配对页。
                try {
                  await app.disconnect(keepShell: true);
                  messenger.showSnackBar(const SnackBar(content: Text('已断开')));
                } on Object catch (e) {
                  messenger.showSnackBar(
                    SnackBar(backgroundColor: ZT.rose, content: Text('断开失败: $e')),
                  );
                }
              },
            ),
            _drawerItem(
              icon: Icons.swap_horiz_rounded,
              label: app.session == null ? '去连接' : '换链接',
              onTap: () {
                Navigator.pop(context);
                // 断开后不再自动跳配对页，换链接全靠这个入口。
                app.openPairPage();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? ZT.rose : ZT.ink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: ShapeDecoration(
            color: ZT.bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: ZT.inkSide(w: 1.1, color: ZT.line),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Icon(icon, size: 17, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------- workspace projects

  /// 项目（工作区）切换器：列出桌面端已打开的全部文件夹工作区，
  /// 当前打勾；行内笔改本地别名；点行切换。
  void _openWorkspaceSwitcher() {
    final app = widget.app;
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => AnimatedBuilder(
        animation: app,
        builder: (sheetCtx, _) {
          final currentKey = app.workspace != null
              ? app.workspaceKeyOf(app.workspace!)
              : null;
          return SafeArea(
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
                  const Row(
                    children: [
                      Icon(
                        Icons.folder_open_rounded,
                        size: 17,
                        color: ZT.primary,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '按项目筛选（工作区）',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '项目 = 桌面端打开的文件夹。要新增项目，在桌面端 '
                    'ZCode 标题栏 → 文件 → 打开工作区，这里会自动出现',
                    style: TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        // 「全部对话」与项目并列排在最上面。
                        _allProjectsRow(sheetCtx, app),
                        const SizedBox(height: 4),
                        for (final w in app.workspaces)
                          // 「全部对话」视图下不给任何项目打勾——那时并不在某个项目里。
                          _workspaceRow(
                            sheetCtx,
                            app,
                            w,
                            app.viewingAllProjects ? null : currentKey,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 「全部对话」条目：与项目并列排在最上面。
  /// 它只换列表数据源（bootstrap 的整机任务），**不动当前项目的桥**，
  /// 所以切回项目时不用重新开桥。
  Widget _allProjectsRow(BuildContext sheetCtx, ZApp app) {
    final active = app.viewingAllProjects;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: ShapeDecoration(
          color: active ? ZT.lemon.withValues(alpha: 0.25) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(
              w: active ? 1.5 : 1.2,
              color: active ? ZT.primaryDeep : ZT.line,
            ),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: active
              ? null
              : () async {
                  Navigator.pop(sheetCtx);
                  await app.showAllProjects();
                },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.forum_outlined,
                  size: 16,
                  color: ZT.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '全部对话',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '跨 ${app.workspaces.length} 个项目',
                  style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
                ),
                if (active) ...[
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 15,
                    color: ZT.primaryDeep,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _workspaceRow(
    BuildContext sheetCtx,
    ZApp app,
    Map<String, dynamic> w,
    String? currentKey,
  ) {
    final key = app.workspaceKeyOf(w) ?? '';
    final isCurrent = key == currentKey;
    final name = app.workspaceTitle(w);
    final path = '${w['workspacePath'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: ShapeDecoration(
          color: isCurrent ? ZT.lemon.withValues(alpha: 0.25) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(
              w: isCurrent ? 1.5 : 1.2,
              color: isCurrent ? ZT.primaryDeep : ZT.line,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: isCurrent
                    ? null
                    : () async {
                        Navigator.pop(sheetCtx);
                        await _switchWorkspace(w);
                      },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (isCurrent) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.check_circle_rounded,
                              size: 15,
                              color: ZT.primaryDeep,
                            ),
                          ],
                        ],
                      ),
                      if (path.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: ZT.inkFaint,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // 重命名（本地别名）
            IconButton(
              tooltip: '重命名',
              icon: const Icon(
                Icons.edit_outlined,
                size: 17,
                color: ZT.inkSoft,
              ),
              onPressed: () => _renameWorkspace(sheetCtx, key, name),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameWorkspace(
    BuildContext sheetCtx,
    String key,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final alias = await showDialog<String>(
      context: sheetCtx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '重命名项目',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(hintText: '只影响本机显示，不改电脑文件夹名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
          ),
          BigButton(
            label: '保存',
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (alias == null) return;
    await widget.app.renameWorkspace(key, alias);
    if (mounted) {
      flashMessage(context, alias.isEmpty ? '已恢复默认名' : '已重命名为「$alias」');
    }
  }

  /// 切换工作区：开目标桥 + 退出已推入的聊天页 + 刷新。
  Future<void> _switchWorkspace(Map<String, dynamic> w) async {
    final name = widget.app.workspaceTitle(w);
    try {
      await widget.app.openWorkspace(w);
      if (!mounted) return;
      // 旧工作区的聊天页订阅已被释放，退回列表根。
      Navigator.of(context).popUntil((r) => r.isFirst);
      flashMessage(context, '已切换到「$name」');
    } on Object catch (e) {
      if (!mounted) return;
      // 原始异常（ChannelRpcError 等）对用户没有意义，换成能照着做的说法。
      flashMessage(context, friendlySwitchError('$e'), error: true);
    }
  }

  /// 新建会话：多工作区时先选项目（当前项目直接进，其他先切换）。
  Future<void> _newChatWithProject() async {
    final app = widget.app;
    if (app.workspaces.isNotEmpty) {
      final picked = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        backgroundColor: ZT.bg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetCtx) => SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.5,
            ),
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '在新项目里新建会话',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                const Text(
                  '当前项目会话不切换直接进入；其他项目会先切换',
                  style: TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final w in app.workspaces)
                        ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.folder_rounded,
                            size: 19,
                            color: ZT.primary,
                          ),
                          title: Text(
                            app.workspaceTitle(w),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          trailing:
                              app.workspace != null &&
                                  app.workspaceKeyOf(app.workspace!) ==
                                      app.workspaceKeyOf(w)
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 17,
                                  color: ZT.primaryDeep,
                                )
                              : null,
                          onTap: () => Navigator.pop(sheetCtx, w),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked == null) return;
      final currentKey = app.workspace != null
          ? app.workspaceKeyOf(app.workspace!)
          : null;
      if (app.workspaceKeyOf(picked) != currentKey) {
        await app.openWorkspace(picked);
      }
    }
    if (!mounted) return;
    widget.onNewChat();
  }

  /// 常驻搜索栏（参考图：AppBar 下独立一行）。
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: TextField(
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          hintText: '搜索会话…',
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    _searchCtl.clear();
                    setState(() => _query = '');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
    );
  }

  /// 筛选 tab + 排序菜单一行（参考图：全部/置顶/最近/归档 + 最近更新▼）。
  ///
  /// 「最近」chip 有意不接（2026-09-11 用户决定：右侧「最近更新」排序已覆盖该需求）。
  /// `TaskFilter.recent` 的枚举、7 天窗口逻辑、标签与单测都还在，只是没渲染——
  /// **这是有意的，不是漏了**，别当 bug 补回来。
  Widget _filterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _filterChip(TaskFilter.all),
                _filterChip(TaskFilter.pinned),
                _filterChip(TaskFilter.archived),
                // 批量与筛选 chips 同组靠左（排序单独靠右）。
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () {
                    if (widget.app.listedTasks.isEmpty) {
                      flashMessage(context, '没有会话可批量管理');
                      return;
                    }
                    _toggleManage();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 6,
                    ),
                    decoration: ShapeDecoration(
                      color: ZT.surface,
                      shape: StadiumBorder(side: ZT.inkSide(w: 1.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.checklist_rounded,
                          size: 15,
                          color: ZT.inkSoft,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _manage ? '退出' : '批量',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: ZT.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<TaskSortKey>(
            tooltip: '排序方式',
            initialValue: _sortKey,
            onSelected: (k) => setState(() => _sortKey = k),
            color: ZT.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.radius),
              side: ZT.inkSide(w: 1.2),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: TaskSortKey.lastActive,
                child: Text('最近更新', style: TextStyle(fontSize: 13)),
              ),
              PopupMenuItem(
                value: TaskSortKey.created,
                child: Text('最近创建', style: TextStyle(fontSize: 13)),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: ShapeDecoration(
                color: ZT.surface,
                shape: StadiumBorder(side: ZT.inkSide(w: 1.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.swap_vert_rounded,
                    size: 14,
                    color: ZT.inkSoft,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _sortLabel(_sortKey),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: ZT.inkSoft,
                    ),
                  ),
                  const Icon(
                    Icons.expand_more_rounded,
                    size: 14,
                    color: ZT.inkSoft,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(TaskFilter f) {
    final label = switch (f) {
      TaskFilter.all => '全部',
      TaskFilter.pinned => '置顶',
      TaskFilter.recent => '最近',
      TaskFilter.archived => '归档',
    };
    final selected = _filter == f;
    return GestureDetector(
      onTap: () {
        setState(() => _filter = f);
        if (f == TaskFilter.archived) {
          // 用户显式点开归档 tab：绕过后台闸门（被闸门静默吞掉=空列表）。
          unawaited(widget.app.loadArchivedTasks(force: true));
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: ShapeDecoration(
          color: selected ? ZT.lemon.withValues(alpha: 0.55) : ZT.surface,
          shape: StadiumBorder(side: ZT.inkSide(w: selected ? 1.6 : 1.2)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: selected ? ZT.ink : ZT.inkSoft,
          ),
        ),
      ),
    );
  }

  static String _sortLabel(TaskSortKey k) => switch (k) {
    TaskSortKey.lastActive => '最近更新',
    TaskSortKey.created => '最近创建',
    TaskSortKey.title => '标题',
  };
}

/// 卡片信息 chip：等宽小字 + 淡底描边（模型名用）。
class _CardChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool mono;

  const _CardChip(this.label, {required this.color, this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.08),
        shape: StadiumBorder(side: ZT.inkSide(w: 1, color: ZT.line)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
          fontFamily: mono ? 'monospace' : null,
        ),
      ),
    );
  }
}

/// 批量管理的选择框（自绘，配主题硬边风格）。
class _SelectBox extends StatelessWidget {
  final bool selected;

  const _SelectBox({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: ShapeDecoration(
        color: selected ? ZT.primaryDeep : ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: ZT.inkSide(w: selected ? 1.6 : 1.2),
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}

/// 批量管理底栏的动作按钮。
class _BarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool danger;
  final VoidCallback? onTap;

  const _BarAction({
    required this.icon,
    required this.label,
    required this.enabled,
    this.danger = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = !enabled ? ZT.inkFaint : (danger ? ZT.rose : ZT.ink);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: enabled && danger ? ZT.rose.withValues(alpha: 0.1) : ZT.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(
              w: 1.2,
              color: enabled ? (danger ? ZT.rose : ZT.ink) : ZT.line,
            ),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 批量重命名对话框：两种模式 + 实时预览。
/// 预览用的是**真实前几条标题**，用户能立刻看出规则对不对——
/// 批量改名没有撤销，让人"改完才发现写错规则"是不可接受的。
class _BatchRenameDialog extends StatefulWidget {
  final List<String> titles;

  const _BatchRenameDialog({required this.titles});

  @override
  State<_BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<_BatchRenameDialog> {
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _prefix = TextEditingController();
  final _suffix = TextEditingController();

  // 模式：查找替换 / 前后缀。两者可以同时用，但分开展示更清楚。
  bool _replaceMode = true;

  @override
  void initState() {
    super.initState();
    for (final c in [_find, _replace, _prefix, _suffix]) {
      c.addListener(_onChanged);
    }
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in [_find, _replace, _prefix, _suffix]) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  BatchRenameSpec get _spec => BatchRenameSpec(
    find: _replaceMode ? _find.text : '',
    replace: _replaceMode ? _replace.text : '',
    prefix: _replaceMode ? '' : _prefix.text,
    suffix: _replaceMode ? '' : _suffix.text,
  );

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final changed = [
      for (final t in widget.titles)
        if (spec.apply(t) != t && spec.apply(t).isNotEmpty) spec.apply(t),
    ];
    return AlertDialog(
      backgroundColor: ZT.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZT.radius),
        side: ZT.inkSide(w: 1.6),
      ),
      title: Text(
        '批量重命名 ${widget.titles.length} 个会话',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 模式切换（两个药丸）
            Row(
              children: [
                _modeChip('查找替换', _replaceMode, () {
                  setState(() => _replaceMode = true);
                }),
                const SizedBox(width: 8),
                _modeChip('加前后缀', !_replaceMode, () {
                  setState(() => _replaceMode = false);
                }),
              ],
            ),
            const SizedBox(height: 12),
            if (_replaceMode) ...[
              _field(_find, '查找', '要替换掉的文字'),
              const SizedBox(height: 8),
              _field(_replace, '替换为', '留空表示删除'),
            ] else ...[
              _field(_prefix, '前缀', '加在标题前面'),
              const SizedBox(height: 8),
              _field(_suffix, '后缀', '加在标题后面'),
            ],
            const SizedBox(height: 12),
            Text(
              changed.isEmpty
                  ? '（还没有变化）'
                  : '预览：${widget.titles.length - changed.length} 个不变 · '
                        '${changed.length} 个将被改名',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: changed.isEmpty ? ZT.inkFaint : ZT.aqua,
              ),
            ),
            if (changed.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 120),
                padding: const EdgeInsets.all(9),
                decoration: ShapeDecoration(
                  color: ZT.bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: ZT.inkSide(w: 1, color: ZT.line),
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final name in changed.take(5))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: ZT.ink,
                            ),
                          ),
                        ),
                      if (changed.length > 5)
                        Text(
                          '…另 ${changed.length - 5} 个',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: ZT.inkFaint,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
        ),
        BigButton(
          label: '重命名',
          onPressed: spec.isNoop || changed.isEmpty
              ? null
              : () => Navigator.pop(context, spec),
        ),
      ],
    );
  }

  Widget _modeChip(String label, bool active, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: active ? ZT.primary.withValues(alpha: 0.14) : ZT.bg,
          shape: StadiumBorder(
            side: ZT.inkSide(
              w: active ? 1.6 : 1.2,
              color: active ? ZT.primaryDeep : ZT.line,
            ),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 34, minWidth: ZT.tapMin),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: active ? ZT.primaryDeep : ZT.inkSoft,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    return TextField(
      controller: c,
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
      ),
    );
  }
}
