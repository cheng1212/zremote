// 手动诊断探针：两条设模路径的生效性与持久性。
// A) V4 switchModelConfig（不带 runtimeModel）
// B) zcode-task 通道 setModel {taskId, modelRef|modelId}
// 一次性测试会话，结束自删。ZREMOTE_PROBE_LINK 门控。
// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
@Tags(['manual'])
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/constants.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('setModel paths experiment (disposable session)', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final params = LinkParams.parse(raw.trim());
    expect(params, isNotNull);
    final session = RemoteSession(params!, onLog: (l) => print('[log] $l'));
    ConversationV4? conv;
    String? sid;
    ConvSubscription? sub;
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final workspaces = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      expect(workspaces, isNotEmpty);
      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final workspaceId = '${bridge.info['workspaceKey'] ?? key}';
      conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));

      sid = await conv.createSession(workspaceId);
      print('\n===== created: $sid =====');
      sub = await conv.subscribe(sid);

      Future<void> snap(String tag) async {
        final st = sub!.state;
        print('[$tag] ${st.currentProvider}/${st.currentModel}');
      }

      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('initial');

      const glmProvider = 'builtin:bigmodel-coding-plan';
      const glmModel = 'GLM-5.3-Flash';

      // ---- A) 普通 switchModelConfig
      print('\n===== A) switchModelConfig (plain) =====');
      try {
        final res = await conv.sendCommand(
          sid,
          'switchModelConfig',
          {'provider': glmProvider, 'model': glmModel, 'thought': 'high'},
          timeout: const Duration(seconds: 15),
        );
        print('A ack: ${jsonEncode(res)}');
      } on Object catch (e) {
        print('A failed: ${e.toString().split('\n').first}');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('A+3s');
      await Future<void>.delayed(const Duration(seconds: 60));
      await snap('A+63s');

      // ---- B) zcode-task setModel
      print('\n===== B) zcode-task.setModel =====');
      for (final arg in [
        {'taskId': sid, 'modelRef': '$glmProvider/$glmModel'},
        {'taskId': sid, 'modelId': '$glmProvider/$glmModel'},
      ]) {
        try {
          final res = await bridge.channels.call(
            Chan.task,
            'setModel',
            [arg],
            timeout: const Duration(seconds: 15),
          );
          print('B ${arg.keys.last} ack: '
              '${jsonEncode(res).substring(0, 300.clamp(0, jsonEncode(res).length))}');
          break;
        } on Object catch (e) {
          print('B ${arg.keys.last} failed: ${e.toString().split('\n').first}');
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('B+3s');
      await Future<void>.delayed(const Duration(seconds: 60));
      await snap('B+63s');
    } finally {
      if (conv != null && sid != null && sid.isNotEmpty) {
        try {
          await conv.deleteSession(sid);
          print('\n[cleanup] deleteSession OK');
        } on Object catch (e) {
          print('[cleanup] deleteSession failed: $e');
        }
        try {
          await sub?.dispose();
        } on Object {
          // ignore
        }
      }
      unawaited(session.dispose());
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
