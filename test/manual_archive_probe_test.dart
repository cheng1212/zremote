// ignore_for_file: avoid_print
// 手动诊断：归档接口形状探测（listArchivedTasks → archive → unarchive 恢复）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('archive api probe: list → archive last → verify → unarchive', () async {
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
      final scope = bridge.scope;
      Future<dynamic> call(String method, List<Object?> args) =>
          bridge.channels.call('zcode-task', method, args,
              timeout: const Duration(seconds: 15));

      // 1) 列表形状
      final archived = await call('listArchivedTasks', [scope]);
      print('===== listArchivedTasks =====');
      var s = const JsonEncoder.withIndent('  ').convert(archived);
      print(s.length > 1500 ? '${s.substring(0, 1500)}…' : s);

      // 2) 挑主列表最后一个非置顶会话做 archive→unarchive 往返
      final list = await call('listTasks', [scope]);
      if (list is! List || list.isEmpty) {
        print('no tasks to test archive roundtrip');
        return;
      }
      final targets = [
        for (final t in list.whereType<Map>())
          if (t['pinned'] != true && t['archived'] != true && t['deleted'] != true)
            t,
      ];
      if (targets.isEmpty) {
        print('no un-pinned task for roundtrip');
        return;
      }
      final t = targets.last;
      final taskId = '${t['taskId']}';
      print('===== roundtrip on $taskId (${t['title'] ?? ''}) =====');
      final taskScope = {
        'taskId': t['taskId'],
        'workspacePath': t['workspacePath'] ?? scope['workspacePath'],
        if ((t['workspaceIdentity'] ?? scope['workspaceIdentity']) != null)
          'workspaceIdentity': t['workspaceIdentity'] ?? scope['workspaceIdentity'],
      };
      print('archive → ${await call('archiveTask', [taskScope])}');
      final afterArchive = await call('listArchivedTasks', [scope]);
      print('archived list contains it: ${_listContains(afterArchive, taskId)}');
      print('unarchive → ${await call('unarchiveTask', [taskScope])}');
      final afterRestore = await call('listArchivedTasks', [scope]);
      print(
        'archived list contains it after restore: '
        '${_listContains(afterRestore, taskId)}',
      );
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

bool _listContains(Object? list, String taskId) {
  if (list is! List) return false;
  for (final e in list) {
    if (e is Map && '${e['taskId']}' == taskId) return true;
  }
  return false;
}
