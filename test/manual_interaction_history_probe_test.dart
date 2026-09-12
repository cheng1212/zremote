// ignore_for_file: avoid_print
// 手动诊断：从历史 rows 里挖 interaction 相关的真实结构（不发起新任务，只读）。
//
// 用法：
//   ZREMOTE_PROBE_LINK="<配对链接>" no_proxy=localhost,127.0.0.1,::1 \
//     flutter test test/manual_interaction_history_probe_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('interaction history shape probe', () async {
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

      // 关键词：命中就打印整行，看服务端到底用什么 kind / 字段。
      const keys = [
        'interaction',
        'question',
        'askuser',
        'askeuser',
        'prompt',
        'optionid',
        'multiselect',
      ];
      print('\n########## 扫描 ${index.state.list.length} 个会话的 rows ##########');
      for (final e in index.state.list) {
        final sub = await conv.subscribe(e.sessionId);
        try {
          await _wait(() => sub.state.ready, 'snapshot ${e.sessionId}',
              timeout: const Duration(seconds: 15));
        } on Object catch (err) {
          print('[skip] ${e.sessionId}: $err');
          await sub.dispose();
          continue;
        }
        final rows = sub.state.rows;
        for (final r in rows) {
          final blob = jsonEncode(r).toLowerCase();
          if (!keys.any(blob.contains)) continue;
          print('\n--- ${e.sessionId} kind=${r['kind']} ---');
          final s = const JsonEncoder.withIndent('  ').convert(r);
          print(s.length > 3000 ? '${s.substring(0, 3000)}…(${s.length})' : s);
        }
        await sub.dispose();
      }
      print('\n########## 扫描结束 ##########');
      await conv.dispose();
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
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
