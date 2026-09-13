// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：读会话 config.thoughtLevels（GLM vs NVIDIA 词表对比）。
@Tags(['manual'])
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('thoughtLevels per model: read → switch nv → read → switch back', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final ws = (bootstrap['workspaces'] as List? ?? []).whereType<Map>().first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));

      final index = await conv.subscribeSessionsIndex();
      await _waitUntil(() => index.state.ready, 'index ready');
      final idle = index.state.list
          .where((e) => e.phase == 'completedSuccess')
          .toList();
      if (idle.isEmpty) {
        print('no idle session');
        return;
      }
      final sid = idle.first.sessionId;
      final sub = await conv.subscribe(sid);
      await _waitUntil(() => sub.state.ready, 'snapshot ready');
      final st = sub.state;
      Map<String, dynamic> cfg() => (st.snapshot?['config'] as Map? ?? {})
          .cast<String, dynamic>();
      print('\n=== ${st.currentProvider}/${st.currentModel} ===');
      print('thought=${st.currentThought}  thoughtLevels=${jsonEncode(cfg()['thoughtLevels'])}');

      // 切到 NVIDIA，等服务端把 config 更新推回来，再读词表
      print('\n=== switch → nv-nemotron-ultra ===');
      await conv.sendCommand(sid, 'switchModelConfig', {
        'provider': '7f3a9c21-5b48-4d6e-9a0f-2c1e8d4b6a55',
        'model': 'nv-nemotron-ultra',
        'thought': 'enabled',
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline) && st.currentModel != 'nv-nemotron-ultra') {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      print('model now=${st.currentModel} thought=${st.currentThought}');
      print('thoughtLevels=${jsonEncode(cfg()['thoughtLevels'])}');
      // 再读一次（可能有第二帧）
      await Future<void>.delayed(const Duration(seconds: 2));
      print('thoughtLevels(+2s)=${jsonEncode(cfg()['thoughtLevels'])}');

      // 切回
      print('\n=== switch back ===');
      await conv.sendCommand(sid, 'switchModelConfig', {
        'provider': 'builtin:bigmodel-start-plan',
        'model': 'GLM-5.3-Flash',
        'thought': 'high',
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      print('model now=${st.currentModel} thought=${st.currentThought}');
      print('thoughtLevels=${jsonEncode(cfg()['thoughtLevels'])}');

      await sub.dispose();
      await conv.dispose();
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _waitUntil(
  bool Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('wait $what timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
