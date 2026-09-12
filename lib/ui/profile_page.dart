import 'package:flutter/material.dart';

import '../protocol/relay_client.dart';
import '../services/notification_service.dart';
import 'automations_page.dart';
import '../state/app_controller.dart';
import '../theme.dart';

/// 我的页：连接管理（状态/重连/断开）+ 运行日志 + 关于。
/// 参考图改造的第三个 tab（「项目」无对应接口，裁掉）。
class ProfilePage extends StatefulWidget {
  final ZApp app;

  const ProfilePage({super.key, required this.app});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _busy = false;

  ZApp get _app => widget.app;

  @override
  Widget build(BuildContext context) {
    final (relayColor, relayLabel) = relayStateStyle(_app.relayState);
    final link = _app.params?.source.toString() ?? '';
    final device = _app.params?.deviceName ?? '桌面端';
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // —— 连接卡片
          HardCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.lan_rounded, size: 17, color: ZT.primary),
                    SizedBox(width: 7),
                    Text(
                      '连接',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: ShapeDecoration(
                        color: ZT.surface,
                        shape: StadiumBorder(
                          side: ZT.inkSide(w: 1.2, color: relayColor),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PulseDot(
                            color: relayColor,
                            animate: _app.relayState != RelayState.paired,
                            size: 6,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            relayLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: relayColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        device,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: ZT.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ),
                if (link.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    link,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: ZT.inkFaint,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: BigButton(
                        label: _busy ? '处理中…' : '重新连接',
                        icon: Icons.refresh_rounded,
                        onPressed: _busy ? null : _reconnect,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BigButton(
                        label: '断开连接',
                        icon: Icons.link_off_rounded,
                        onPressed: _busy ? null : _disconnect,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // —— 通知开关
          HardCard(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Row(
              children: [
                const Icon(
                  Icons.notifications_active_rounded,
                  size: 17,
                  color: ZT.lemon,
                ),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text(
                    '任务事件通知',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Switch(
                  value: NotificationService.enabled,
                  activeThumbColor: ZT.primaryDeep,
                  onChanged: (v) =>
                      setState(() => NotificationService.enabled = v),
                ),
              ],
            ),
          ),
          // —— 通知类型：铃声 / 震动（通知开着才有意义）
          if (NotificationService.enabled) ...[
            const SizedBox(height: 10),
            HardCard(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(
                children: [
                  Icon(
                    NotificationService.soundOn
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded,
                    size: 17,
                    color: NotificationService.soundOn
                        ? ZT.aqua
                        : ZT.inkFaint,
                  ),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text(
                      '提示音',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    NotificationService.soundOn ? '铃声' : '静音',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: NotificationService.soundOn
                          ? ZT.inkSoft
                          : ZT.inkFaint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: NotificationService.soundOn,
                    activeThumbColor: ZT.primaryDeep,
                    onChanged: (v) =>
                        setState(() => NotificationService.soundOn = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            HardCard(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(
                children: [
                  Icon(
                    NotificationService.vibrateOn
                        ? Icons.vibration_rounded
                        : Icons.mobile_off_rounded,
                    size: 17,
                    color: NotificationService.vibrateOn
                        ? ZT.aqua
                        : ZT.inkFaint,
                  ),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text(
                      '震动',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    NotificationService.vibrateOn ? '开' : '关',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: NotificationService.vibrateOn
                          ? ZT.inkSoft
                          : ZT.inkFaint,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: NotificationService.vibrateOn,
                    activeThumbColor: ZT.primaryDeep,
                    onChanged: (v) =>
                        setState(() => NotificationService.vibrateOn = v),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          // —— 定时任务入口
          HardCard(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AutomationsPage(app: _app),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            child: Row(
              children: [
                const Icon(Icons.schedule_rounded, size: 17, color: ZT.grape),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text(
                    '定时任务',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                  ),
                ),
                AnimatedBuilder(
                  animation: _app,
                  builder: (context, _) {
                    final active = _app.automations
                        .where((a) => a['enabled'] == true)
                        .length;
                    if (active == 0) {
                      return const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: ZT.inkFaint,
                      );
                    }
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: ShapeDecoration(
                        color: ZT.lemon.withValues(alpha: 0.4),
                        shape: StadiumBorder(side: ZT.inkSide(w: 1.2)),
                      ),
                      child: Text(
                        '$active 个启用中',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // —— 日志卡片
          HardCard(
            color: ZT.ink,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 15, color: ZT.onInk),
                    SizedBox(width: 6),
                    Text(
                      '运行日志（最近 8 条）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: ZT.onInk,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<int>(
                  valueListenable: _app.logsRevision,
                  builder: (context, _, _) {
                    final logs = _app.logs.reversed.take(8).toList();
                    if (logs.isEmpty) {
                      return const Text(
                        '（暂无日志）',
                        style: TextStyle(fontSize: 11, color: ZT.onInk),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in logs)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: const TextStyle(
                                fontSize: 10,
                                height: 1.4,
                                fontFamily: 'monospace',
                                color: ZT.onInk,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // —— 关于
          HardCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const _SunMark(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'zremote',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '柑橘晨光 Citrus Morning · v0.1.0',
                        style: TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _app.reconnect();
      if (!mounted) return;
      flashMessage(context, '重连成功');
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '重连失败: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 就地断开：和抽屉一致，只拆连接、保留列表，不再把人甩回配对页。
      await _app.disconnect(keepShell: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 我的页太阳标（配对页同款缩小版）。
class _SunMark extends StatelessWidget {
  const _SunMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: ShapeDecoration(
        color: ZT.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: ZT.inkSide(w: 1.8),
        ),
        shadows: ZT.hard(dx: 2.5, dy: 2.5),
      ),
      child: const Icon(Icons.wb_sunny_rounded, color: Colors.white, size: 22),
    );
  }
}
