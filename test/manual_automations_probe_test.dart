// ignore_for_file: avoid_print
// 手动诊断：自动化（定时任务）接口形状探测。只读。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('automations shape probe', () async {
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
      Future<dynamic> call(String method, List<Object?> args) =>
          bridge.channels.call('zcode-agent', method, args,
              timeout: const Duration(seconds: 20));

      final res = await call('listAllAutomations', []);
      print('===== listAllAutomations =====');
      var s = const JsonEncoder.withIndent('  ').convert(res);
      print(s.length > 4000 ? '${s.substring(0, 4000)}…(total ${s.length})' : s);
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
