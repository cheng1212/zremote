// ignore_for_file: avoid_print
// 手动诊断：全局任务通知链路实测——listTaskList(workspaceScopes) 是否
// 在桥通道上可用、返回什么、status 词汇是否如预期（BUG-34 后新增的
// 跨项目通知轮询押在这个接口上）。ZREMOTE_PROBE_LINK 门控。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/constants.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('listTaskList(workspaceScopes) 全项目任务列表探针', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final boot = await session.bootstrap();
      final workspaces = (boot['workspaces'] as List? ?? [])
          .whereType<Map>()
          .toList();
      // workspaceScopes 要工作区对象（字符串会炸 normalizeWorkspaceKeys）
      final scopes = [
        for (final w in workspaces)
          if (w['workspacePath'] != null)
            {
              'workspacePath': w['workspacePath'],
              if (w['workspaceIdentity'] != null)
                'workspaceIdentity': w['workspaceIdentity'],
            },
      ];
      print('scopes: $scopes');
      if (scopes.isEmpty) return;
      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final res = await bridge.channels.call(Chan.task, 'listTaskList', [
        {'workspaceScopes': scopes},
      ], timeout: const Duration(seconds: 15));
      final map = res is Map ? res : const {};
      print('顶层键: ${map.keys.toList()}');
      final items = (map['items'] as List? ?? const []);
      print('items: ${items.length} 条, total=${map['total']}');
      // 状态词汇统计
      final statusCount = <String, int>{};
      for (final it in items.whereType<Map>()) {
        final s = '${it['status'] ?? '<null>'}';
        statusCount[s] = (statusCount[s] ?? 0) + 1;
      }
      print('status 分布: $statusCount');
      final enc = const JsonEncoder.withIndent('  ');
      for (final it in items.whereType<Map>().take(4)) {
        final s = enc.convert(it);
        print(s.length > 1200 ? '${s.substring(0, 1200)}…' : s);
        print('---');
      }
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
