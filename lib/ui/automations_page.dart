import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/automation_view.dart';
import 'chat_page.dart';
import '../theme.dart';

/// 定时任务页：列表 + 下次执行倒计时 + 启用开关 + 立即运行 + 删除。
/// 数据：zcode-agent.listAllAutomations（探针实测形状）；
/// 倒计时基于 nextRunAt（毫秒），每秒本地 tick。
class AutomationsPage extends StatefulWidget {
  final ZApp app;

  const AutomationsPage({super.key, required this.app});

  @override
  State<AutomationsPage> createState() => _AutomationsPageState();
}

class _AutomationsPageState extends State<AutomationsPage> {
  Timer? _ticker;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    unawaited(widget.app.loadAutomations());
    // 倒计时每秒走一格；空列表时 tick 也无害。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _reload() async => widget.app.loadAutomations();

  Future<void> _toggle(AutomationView a, bool v) async {
    try {
      await widget.app.setAutomationEnabled(a.id, v);
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '切换失败：$e', error: true);
      await _reload();
    }
  }

  Future<void> _runNow(AutomationView a) async {
    try {
      await widget.app.runAutomationNow(a.id);
      if (!mounted) return;
      flashMessage(context, '已触发立即运行（由桌面端调度执行）');
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '触发失败：$e', error: true);
    }
  }

  /// 重启自动化：重置调度状态重新排程——不触发/重复触发时的自救。
  Future<void> _restart(AutomationView a) async {
    try {
      await widget.app.restartAutomation(a.id);
      if (!mounted) return;
      flashMessage(context, '已重启「${a.title}」，调度已重置');
      await _reload();
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '重启失败：$e', error: true);
    }
  }

  Future<void> _delete(AutomationView a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '删除定时任务？',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '将删除「${a.title.isEmpty ? a.id : a.title}」，此操作不可恢复。',
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
            child: const Text('删除', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.app.deleteAutomation(a.id);
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '删除失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final views = [
          for (final m in app.automations) AutomationView.fromMap(m),
        ]..sort((a, b) {
          // 启用中的在前，其后再按下次执行时间升序（快到的在前）。
          if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
          final an = a.nextRunAt ?? 1 << 62;
          final bn = b.nextRunAt ?? 1 << 62;
          return an.compareTo(bn);
        });
        return Scaffold(
          appBar: AppBar(
            title: const Text('定时任务'),
            // 触控目标由 ZT.theme() 的 iconButtonTheme 统一撑到 48dp，
            // 这里不再压缩密度，也不再需要额外的间隙。
            actions: [
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded, color: ZT.ink),
                onPressed: _reload,
              ),
            ],
          ),
          body: app.automationsLoading && views.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: ZT.primary),
                )
              : views.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: ShapeDecoration(
                          color: ZT.lemon,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: ZT.inkSide(w: 1.8),
                          ),
                          shadows: ZT.hard(dx: 4, dy: 4),
                        ),
                        child: const Icon(
                          Icons.schedule_rounded,
                          color: ZT.ink,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '还没有定时任务',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '在对话里让 ZCode 建立轮询/定时后，这里能看到',
                        style: TextStyle(fontSize: 12, color: ZT.inkFaint),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  color: ZT.primaryDeep,
                  onRefresh: _reload,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: views.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) =>
_AutomationCard(
                            app: widget.app,
                            view: views[i],
                            onToggle: _toggle,
                            onRun: _runNow,
                            onRestart: _restart,
                            onDelete: _delete,
                            nowMs: _nowMs,
                          ),
                  ),
                ),
        );
      },
    );
  }
}

class _AutomationCard extends StatefulWidget {
  final ZApp app;
  final AutomationView view;
  final Future<void> Function(AutomationView, bool) onToggle;
  final Future<void> Function(AutomationView) onRun;
  final Future<void> Function(AutomationView) onRestart;
  final Future<void> Function(AutomationView) onDelete;
  final int nowMs;

  const _AutomationCard({
    required this.app,
    required this.view,
    required this.onToggle,
    required this.onRun,
    required this.onRestart,
    required this.onDelete,
    required this.nowMs,
  });

  @override
  State<_AutomationCard> createState() => _AutomationCardState();
}

class _AutomationCardState extends State<_AutomationCard> {
  bool _runsExpanded = false;
  bool _runsLoading = false;
  List<AutomationRunView>? _runs;
  String? _runsError;

  AutomationView get view => widget.view;

  Future<void> _loadRuns() async {
    if (_runsLoading) return;
    setState(() {
      _runsLoading = true;
      _runsError = null;
    });
    try {
      final runs = await widget.app.loadAutomationRuns(view.id);
      if (!mounted) return;
      setState(() => _runs = runs);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _runsError = '$e');
    } finally {
      if (mounted) setState(() => _runsLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = view;
    final countdown = automationCountdown(a.nextRunAt, nowMs: widget.nowMs);
    return HardCard(
      color: a.enabled ? ZT.surface : ZT.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  a.title.isEmpty ? a.id : a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Switch(
                value: a.enabled,
                activeThumbColor: ZT.primaryDeep,
                onChanged: (v) => widget.onToggle(a, v),
              ),
            ],
          ),
          if (a.prompt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                a.prompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: ZT.inkSoft, height: 1.35),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _badge(a.lifecycleLabel, _lifecycleColor(a.lifecycleStatus)),
              if (a.enabled && countdown.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: ShapeDecoration(
                    color: ZT.lemon.withValues(alpha: 0.4),
                    shape: StadiumBorder(side: ZT.inkSide(w: 1.2)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        size: 12,
                        color: ZT.ink,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '下次 $countdown',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: ZT.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                a.scheduleLabel,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: ZT.inkFaint,
                ),
              ),
              Text(
                '已跑 ${a.runCount}${a.maxRuns != null ? '/${a.maxRuns}' : ''} 次',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: ZT.inkFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _action(
                icon: Icons.flash_on_rounded,
                label: '立即运行',
                color: ZT.primaryDeep,
                onTap: () => widget.onRun(a),
              ),
              const SizedBox(width: 10),
              _action(
                icon: Icons.restart_alt_rounded,
                label: '重启',
                color: ZT.ink,
                onTap: () => widget.onRestart(a),
              ),
              const SizedBox(width: 10),
              _action(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                color: ZT.rose,
                onTap: () => widget.onDelete(a),
              ),
              const Spacer(),
              _action(
                icon: _runsExpanded
                    ? Icons.expand_less_rounded
                    : Icons.history_rounded,
                label: _runsExpanded ? '收起历史' : '执行历史',
                color: ZT.inkSoft,
                onTap: () {
                  setState(() => _runsExpanded = !_runsExpanded);
                  if (_runsExpanded && _runs == null && !_runsLoading) {
                    _loadRuns();
                  }
                },
              ),
            ],
          ),
          if (_runsExpanded) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(9),
              decoration: ShapeDecoration(
                color: ZT.bg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: ZT.inkSide(w: 1, color: ZT.line),
                ),
              ),
              child: _runsBody(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _runsBody() {
    if (_runsLoading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ZT.primary,
            ),
          ),
        ),
      );
    }
    if (_runsError != null) {
      return Text(
        '加载失败：$_runsError',
        style: const TextStyle(fontSize: 11, color: ZT.rose),
      );
    }
    final runs = _runs ?? const <AutomationRunView>[];
    if (runs.isEmpty) {
      return const Text(
        '还没有执行记录',
        style: TextStyle(fontSize: 11, color: ZT.inkFaint),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in runs.take(5))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: ShapeDecoration(
                    color: r.failed
                        ? ZT.rose.withValues(alpha: 0.12)
                        : ZT.aqua.withValues(alpha: 0.12),
                    shape: StadiumBorder(
                      side: ZT.inkSide(
                        w: 1,
                        color: r.failed ? ZT.rose : ZT.aqua,
                      ),
                    ),
                  ),
                  child: Text(
                    r.outcomeLabel,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: r.failed ? ZT.rose : ZT.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${r.triggerLabel} · ${automationRunTime(r.scheduledAt)}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: ZT.inkSoft,
                  ),
                ),
                const Spacer(),
                if (r.sessionId != null)
                  // 纯文字链接热区只有文字高（约 14px），撑到 48dp。
                  // 行内不加底/边，避免执行历史列表变得花。
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatPage(
                            app: widget.app,
                            sessionId: r.sessionId!,
                            title: '自动化运行 · ${view.title}',
                          ),
                        ),
                      );
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: ZT.tapMin),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: const Text(
                        '查看会话',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: ZT.primaryDeep,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (runs.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '仅显示最近 5 次（共 ${runs.length} 次）',
              style: const TextStyle(fontSize: 10, color: ZT.inkFaint),
            ),
          ),
      ],
    );
  }

  Color _lifecycleColor(String s) => switch (s) {
    'active' => ZT.primary,
    'completed' => ZT.aqua,
    'failed' => ZT.rose,
    'paused' => ZT.lemon,
    _ => ZT.inkFaint,
  };

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: StadiumBorder(side: ZT.inkSide(w: 1.2, color: color)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  /// 卡片内动作键：撑到 48dp 热区 + 淡底墨线，让它明确"像个按钮"。
  /// 此前是纯文字 + 14px 图标、无底无边，热区高约 20px——手机上按不准，
  /// 而且看不出可点。视觉不加重（淡底 + 1.2 细边），只解决"小"和"不像按钮"。
  Widget _action({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: color.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: ZT.inkSide(w: 1.2, color: color.withValues(alpha: 0.45)),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ZT.tapMin,
              minWidth: ZT.tapMin,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: color),
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
      ),
    );
  }
}
