// ignore_for_file: avoid_print
// 手动诊断：打印会话 snapshot.usage 完整 JSON（看 cache/breakdown 是否存在）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('usage snapshot probe', () async {
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
      await _wait(() => index.state.ready, 'index');
      for (final e in index.state.list.take(4)) {
        final sub = await conv.subscribe(e.sessionId);
        await _wait(() => sub.state.ready, 'snapshot ${e.sessionId}');
        final usage = sub.state.snapshot?['usage'];
        print('\n===== ${e.sessionId.substring(0, 16)} (${e.phase}) =====');
        print(const JsonEncoder.withIndent('  ').convert(usage));
        await sub.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await conv.dispose();
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

Future<void> _wait(bool Function() cond, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('wait $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
