// ignore_for_file: avoid_print
// 手动诊断：自动化运行历史形状探测（create→runNow→listRuns→delete+清理）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('automation runs probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    var createdId = '';
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final ws = (bootstrap['workspaces'] as List? ?? []).whereType<Map>().first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final scope = {
        'workspacePath': bridge.scope['workspacePath'],
        if (bridge.scope['workspaceIdentity'] != null)
          'workspaceIdentity': bridge.scope['workspaceIdentity'],
      };
      Future<dynamic> call(String method, List<Object?> args) =>
          bridge.channels.call('zcode-agent', method, args,
              timeout: const Duration(seconds: 20));

      final created = await call('createAutomation', [
        {
          ...scope,
          'title': 'zremote-runs-probe',
          'cronExpr': '0 0 1 1 *',
          'prompt': '回复两个字：正常',
          'recurring': false,
          'maxRuns': 1,
          'enabled': false,
        },
      ]);
      final createdMap = created is Map
          ? (created['automation'] as Map? ?? created)
          : <String, dynamic>{};
      createdId = '${createdMap['automationId'] ?? ''}';
      print('created: $createdId');
      if (createdId.isEmpty) return;

      print('runNow → ${await call('runAutomationNow', [
        {...scope, 'automationId': createdId},
      ])}');

      // 轮询运行历史（执行需要时间，最多等 60s）
      Object? runs;
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        runs = await call('listAutomationRuns', [
          {...scope, 'automationId': createdId},
        ]);
        final n = runs is List ? runs.length : -1;
        print('poll ${i + 1}: runs=$n');
        if (n > 0) break;
      }
      print('===== listAutomationRuns =====');
      var s = const JsonEncoder.withIndent('  ').convert(runs);
      print(s.length > 3500 ? '${s.substring(0, 3500)}…' : s);

      // deleteAutomationRun 也验一下参数（拿第一个 runId 删除）
      if (runs is List && runs.isNotEmpty && runs.first is Map) {
        final runId = '${(runs.first as Map)['runId'] ?? ''}';
        if (runId.isNotEmpty) {
          print(
            'deleteRun → ${await call('deleteAutomationRun', [
              {...scope, 'runId': runId},
            ])}',
          );
        }
      }

      print('delete automation → ${await call('deleteAutomation', [
        {...scope, 'automationId': createdId},
      ])}');

      // 清理 automation 注入的垃圾会话（sourceCommandId 带 automationId 前缀）
      final boot2 = await session.bootstrap();
      final list = boot2['workspaces'] is List &&
              (boot2['workspaces'] as List).isNotEmpty
          ? ((boot2['workspaces'] as List).first as Map)['tasks'] as List?
          : null;
      for (final t in (list ?? const []).whereType<Map>()) {
        final srcId = '${t['sourceCommandId'] ?? ''}';
        if (srcId.contains(createdId)) {
          final junkId = '${t['taskId'] ?? t['sessionId'] ?? ''}';
          if (junkId.isEmpty) continue;
          await bridge.channels.call('zcode-task', 'deleteTask', [
            {...scope, 'taskId': junkId},
          ], timeout: const Duration(seconds: 15));
          print('junk session deleted: $junkId');
        }
      }
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
