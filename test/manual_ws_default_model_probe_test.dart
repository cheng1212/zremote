// 手动诊断探针：验证 workspace/readState 与 workspace/setDefaultModel 形状。
// print 就是它的输出方式，忽略 avoid_print。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/constants.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

/// 环境变量 ZREMOTE_PROBE_LINK 门控；未设置直接 skip。
/// 目标模型可用 ZREMOTE_PROBE_SET_MODEL='providerId|modelId' 打开写入实验，
/// 不设则只读（readState 只探形状不动任何设置）。
void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  final setModel = Platform.environment['ZREMOTE_PROBE_SET_MODEL'];
  test('workspace default model probe: readState → (optional) setDefaultModel', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final params = LinkParams.parse(raw.trim());
    expect(params, isNotNull, reason: 'link should parse');
    final session = RemoteSession(params!, onLog: (l) => print('[log] $l'));
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
      for (final w in workspaces) {
        print('ws: ${w['workspaceKey']} | ${w['workspacePath']}');
      }

      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      // ignore: unused_local_variable
      final conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));

      Map<String, dynamic> scope(Map<String, dynamic> w) => {
        'workspacePath': w['workspacePath'],
        if (w['workspaceIdentity'] != null) 'workspaceIdentity': w['workspaceIdentity'],
      };

      Future<void> readState(String tag, Map<String, dynamic> w) async {
        const channels = [Chan.task, Chan.agent, 'zcode-session', 'workspace', 'setting'];
        const methods = ['workspace/readState', 'readState'];
        for (final ch in channels) {
          for (final m in methods) {
            try {
              final res = await bridge.channels.call(
                ch,
                m,
                [scope(w)],
                timeout: const Duration(seconds: 8),
              );
              print('\n===== FOUND $ch.$m [$tag] =====');
              print(const JsonEncoder.withIndent('  ').convert(res));
              return;
            } on Object catch (e) {
              print('miss: $ch.$m → ${e.toString().split('\n').first}');
            }
          }
        }
        print('readState[$tag]: no channel/method combo found');
      }

      for (final w in workspaces.take(3)) {
        await readState('${w['workspaceKey']}', w);
      }

      if (setModel != null && setModel.isNotEmpty) {
        final parts = setModel.split('|');
        expect(parts.length, 2, reason: 'ZREMOTE_PROBE_SET_MODEL=provider|model');
        final target = <String, dynamic>{
          'provider': parts[0],
          'model': parts[1],
        };
        for (final w in workspaces.take(3)) {
          final tag = '${w['workspaceKey']}';
          for (final attempt in [
            {'workspacePath': w['workspacePath'], ...target},
            {'scope': scope(w), ...target},
            {...scope(w), ...target},
          ]) {
            try {
              print('\n--- setDefaultModel[$tag] args: ${jsonEncode(attempt)}');
              final res = await bridge.channels.call(
                Chan.agent,
                'workspace/setDefaultModel',
                [attempt],
                timeout: const Duration(seconds: 15),
              );
              print('setDefaultModel[$tag] OK: ${jsonEncode(res)}');
              break;
            } on Object catch (e) {
              print('setDefaultModel[$tag] shape failed: $e');
            }
          }
        }
        for (final w in workspaces.take(3)) {
          await readState('after-set:${w['workspaceKey']}', w);
        }
      } else {
        print('\n(read-only run; set ZREMOTE_PROBE_SET_MODEL=provider|model to write)');
      }
    } finally {
      unawaited(session.dispose());
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
