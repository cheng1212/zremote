// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：自动化 create→list→setEnabled→delete 安全往返。
// cron 定在 1 月 1 日且 maxRuns=1，测试期间不会触发执行。
@Tags(['manual'])
library;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('automation roundtrip probe', () async {
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

      // 1) create（不会触发：明年 1/1 + maxRuns 1）
      final created = await call('createAutomation', [
        {
          ...scope,
          'title': 'zremote-probe-test',
          'cronExpr': '0 0 1 1 *',
          'prompt': '这是一条测试自动化，请忽略',
          'recurring': false,
          'maxRuns': 1,
          'enabled': false,
        },
      ]);
      print('===== create =====');
      print(const JsonEncoder.withIndent('  ').convert(created));
      final createdMap = created is Map
          ? (created['automation'] as Map? ?? created)
          : <String, dynamic>{};
      createdId = '${createdMap['automationId'] ?? ''}';
      if (createdId.isEmpty) {
        print('no automationId; skip rest');
        return;
      }

      // 2) list 含它 + 字段确认（nextRunAt）
      final list = await call('listAllAutomations', []);
      print('===== list contains: ${_has(list, createdId)} =====');
      for (final a in (list as List? ?? [])) {
        if (a is Map && '${a['automationId']}' == createdId) {
          print(
            'nextRunAt=${a['nextRunAt']} lastRunAt=${a['lastRunAt']} '
            'enabled=${a['enabled']} lifecycle=${a['lifecycleStatus']} '
            'runCount=${a['runCount']}',
          );
        }
      }

      // 3) setEnabled true → false
      print('enable → ${await call('setAutomationEnabled', [
        {...scope, 'automationId': createdId, 'enabled': true},
      ])}');
      print('disable → ${await call('setAutomationEnabled', [
        {...scope, 'automationId': createdId, 'enabled': false},
      ])}');

      // 4) runAutomationNow（disabled 状态下大概率拒绝/或直接跑一次——
      //    prompt 是"请忽略"，无害；若方法不存在会抛错，记录即可）
      try {
        final r = await call('runAutomationNow', [
          {...scope, 'automationId': createdId},
        ]);
        print('runNow → $r');
      } on Object catch (e) {
        print('runNow failed (记录): $e');
      }

      // 5) delete 收尾
      print('delete → ${await call('deleteAutomation', [
        {...scope, 'automationId': createdId},
      ])}');
      final list2 = await call('listAllAutomations', []);
      print('list contains after delete: ${_has(list2, createdId)}');
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

bool _has(Object? list, String id) {
  if (list is! List) return false;
  for (final e in list) {
    if (e is Map && '${e['automationId']}' == id) return true;
  }
  return false;
}
