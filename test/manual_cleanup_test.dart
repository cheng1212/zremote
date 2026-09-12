// ignore_for_file: avoid_print
// 一次性清理：删除 watch 探针残留的测试会话。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  final sid = Platform.environment['ZREMOTE_DELETE_SID'];
  test('cleanup leftover probe session', () async {
    if (raw == null || sid == null || sid.isEmpty) {
      markTestSkipped('env not set');
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
      await bridge.channels.call('zcode-task', 'deleteTask', [
        {
          'workspacePath': bridge.scope['workspacePath'],
          if (bridge.scope['workspaceIdentity'] != null)
            'workspaceIdentity': bridge.scope['workspaceIdentity'],
          'taskId': sid,
        },
      ], timeout: const Duration(seconds: 20));
      print('deleted: $sid');
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
