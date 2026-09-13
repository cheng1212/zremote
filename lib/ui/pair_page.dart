import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/relay_client.dart';
import '../state/app_controller.dart';
import '../theme.dart';

/// 首屏：粘贴远端链接 → 连接。 citrus 晨光开场。
/// 是否切到任务页由 main.dart 按状态推导，这里只管连接本身。
class PairPage extends StatefulWidget {
  final ZApp app;

  const PairPage({super.key, required this.app});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  bool _autoTried = false;

  @override
  void initState() {
    super.initState();
    _loadSavedLink();
    widget.app.addListener(_onApp);
  }

  Future<void> _loadSavedLink() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('zremote_link');
    if (saved != null && mounted && _controller.text.isEmpty) {
      setState(() => _controller.text = saved);
    }
    // 冷启动自动重连：上次连过就直接连，不用再手动点。
    unawaited(_autoConnect());
  }

  Future<void> _autoConnect() async {
    if (_autoTried || _busy) return;
    if (widget.app.relayState != RelayState.idle) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    _autoTried = true;
    widget.app.log('[app] 自动重连上次的链接…');
    await _connect();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final raw = _controller.text.trim();
    if (raw.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.app.connect(raw);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('zremote_link', raw);
    } on Object {
      // failure 已写入 app 状态，界面自会显示
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final state = app.relayState;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SunLogo(),
                const SizedBox(height: 18),
                const Text(
                  'zremote',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.5,
                    color: ZT.ink,
                  ),
                ),
                Text(
                  '柑橘晨光 · ZCode 远程聊天',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: ZT.inkSoft,
                  ),
                ),
                const SizedBox(height: 30),
                HardCard(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                  shadowDx: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '远端链接',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 18,
                              color: ZT.inkSoft,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _controller,
                        obscureText: _obscure,
                        maxLines: _obscure ? 1 : 3,
                        minLines: _obscure ? 1 : 3,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          hintText: 'https://zcode.z.ai/remote/v4?sid=…&hash=…',
                        ),
                      ),
                      const SizedBox(height: 14),
                      BigButton(
                        label: _busy ? '连接中…' : '连接桌面端',
                        icon: Icons.bolt,
                        expand: true,
                        onPressed: _busy ? null : _connect,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _StateStrip(state: state, failure: app.failure),
                if (app.failure != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    app.failure!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: ZT.rose,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 26),
                _LogPeek(app: app),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SunLogo extends StatelessWidget {
  const _SunLogo();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 84,
        height: 84,
        decoration: ShapeDecoration(
          color: ZT.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: ZT.inkSide(w: 2.2),
          ),
          shadows: ZT.hard(dx: 5, dy: 5),
        ),
        child: const Icon(
          Icons.wb_sunny_rounded,
          color: Colors.white,
          size: 44,
        ),
      ),
    );
  }
}

class _StateStrip extends StatelessWidget {
  final RelayState state;
  final String? failure;

  const _StateStrip({required this.state, this.failure});

  @override
  Widget build(BuildContext context) {
    // 词汇与任务页角标同一套（relayStateStyle）；
    // 配对现场对 waiting/kicked 给更具体的引导。
    var (color, label) = relayStateStyle(state);
    label = switch (state) {
      RelayState.idle => '等待链接',
      RelayState.connecting ||
      RelayState.authenticating ||
      RelayState.reconnecting => '$label…',
      RelayState.waiting => '等待桌面端确认配对…',
      RelayState.kicked => '被踢下线（桌面端可能被占用）',
      RelayState.error => failure ?? label,
      _ => label,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: StadiumBorder(side: ZT.inkSide(w: 1.4, color: color)),
      ),
      child: Row(
        children: [
          PulseDot(
            color: color,
            animate:
                state == RelayState.connecting ||
                state == RelayState.authenticating ||
                state == RelayState.waiting ||
                state == RelayState.reconnecting,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogPeek extends StatelessWidget {
  final ZApp app;

  const _LogPeek({required this.app});

  @override
  Widget build(BuildContext context) {
    // 只挂在日志版本号上：log() 不再整页 notify，这里自己刷新。
    return ValueListenableBuilder<int>(
      valueListenable: app.logsRevision,
      builder: (context, _, _) {
        final logs = app.logs.reversed.take(6).toList();
        if (logs.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: ZT.ink,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in logs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: ZT.onInk,
                      fontFamily: 'monospace',
                      height: 1.35,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
