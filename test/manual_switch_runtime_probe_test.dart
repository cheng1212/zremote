// 手动诊断探针：switchModelConfig 携带 runtimeModel(String) 的形状与持久性实验。
// 一次性测试会话，结束自删。ZREMOTE_PROBE_LINK 门控，未设置直接 skip。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('switchModelConfig runtimeModel experiment (disposable session)', () async {
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
      print('\n===== PAIRED =====');
      final bootstrap = await session.bootstrap();
      final workspaces = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      expect(workspaces, isNotEmpty);
      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final workspaceId =
          '${bridge.info['workspaceKey'] ?? key}';
      conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));

      sid = await conv.createSession(workspaceId);
      print('\n===== created session: $sid =====');
      sub = await conv.subscribe(sid);

      Future<void> snap(String tag) async {
        final st = sub!.state;
        print('[$tag] config=${jsonEncode(st.config)} '
            'cur=${st.currentProvider}/${st.currentModel}');
      }

      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('initial');

      const glmProvider = 'builtin:bigmodel-start-plan';
      const glmModel = 'GLM-5.3-Flash';

      print('\n--- switchModelConfig with runtimeModel object variants');
      final variants = <String, Map<String, dynamic>>{
        'obj-providerId+model': {
          'runtimeModel': {'providerId': glmProvider, 'model': glmModel},
        },
        'obj-providerId+model+thought': {
          'runtimeModel': {
            'providerId': glmProvider,
            'model': glmModel,
            'thoughtLevel': 'high',
          },
        },
        'obj-model-slash': {
          'runtimeModel': {'model': '$glmProvider/$glmModel'},
        },
      };
      String? workingShape;
      for (final e in variants.entries) {
        try {
          print('\n--- trying ${e.key}: ${jsonEncode(e.value)}');
          final res = await conv.sendCommand(
            sid,
            'switchModelConfig',
            {
              'provider': glmProvider,
              'model': glmModel,
              'thought': 'high',
              ...e.value,
            },
            timeout: const Duration(seconds: 15),
          );
          print('${e.key} ack: ${jsonEncode(res)}');
          final status = res is Map ? '${res['status'] ?? ''}' : '';
          if (status == 'accepted' || status == 'noop') {
            workingShape = e.key;
            break;
          }
        } on Object catch (err) {
          print('${e.key} rejected: ${err.toString().split('\n').first}');
        }
      }
      print('\n===== working shape: $workingShape =====');

      await Future<void>.delayed(const Duration(seconds: 3));
      await snap('after-switch+3s');

      // 持久性观察：120s，每 30s 读一次，看是否被桌面同步刷回
      for (var i = 1; i <= 4; i++) {
        await Future<void>.delayed(const Duration(seconds: 30));
        await snap('observe+${
            i * 30}s');
      }
    } finally {
      // 清理：删除测试会话（本体+任务条目），失败不阻塞
      if (conv != null && sid != null && sid.isNotEmpty) {
        try {
          await conv.deleteSession(sid);
          print('\n[cleanup] deleteSession($sid) OK');
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
