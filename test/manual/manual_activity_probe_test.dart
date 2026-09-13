// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：抓活动会话的 backgroundWorks / subagents / activeWorks 原始 JSON。
@Tags(['manual'])
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('activity fields probe', () async {
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
      // 优先 running 会话（有活动数据），否则第一个
      final e = index.state.list.first;
      print('===== session ${e.sessionId.substring(0, 16)} (${e.phase}) =====');
      final sub = await conv.subscribe(e.sessionId);
      await _wait(() => sub.state.ready, 'snapshot');
      final snap = sub.state.snapshot ?? const {};
      print('--- control.activeWorks ---');
      print(const JsonEncoder.withIndent('  ').convert(snap['control']?['activeWorks']));
      print('--- backgroundWorks ---');
      print(const JsonEncoder.withIndent('  ').convert(snap['backgroundWorks']));
      print('--- subagents ---');
      final sa = snap['subagents'];
      var s = const JsonEncoder.withIndent('  ').convert(sa);
      print(s.length > 3000 ? '${s.substring(0, 3000)}…' : s);
      await sub.dispose();
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
