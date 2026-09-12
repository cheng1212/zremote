// ignore_for_file: avoid_print
// 手动诊断：抓计划与文件变更的真实数据形状。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('plan & fileChanges shape probe', () async {
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

      // 找最近 3 个会话（completedSuccess 优先，避开 running 宿主）
      final targets = index.state.list
          .where((e) => e.phase != 'running')
          .take(3)
          .toList();
      for (final e in targets) {
        final sid = e.sessionId;
        print('\n########## $sid (${e.phase}) ${e.title} ##########');
        final sub = await conv.subscribe(sid);
        await _wait(() => sub.state.ready, 'snapshot $sid');
        final st = sub.state;

        // 1) 快照 plan
        print('--- snapshot.plan ---');
        print(const JsonEncoder.withIndent('  ').convert(st.plan));

        // 2) plans 查询的最新载荷
        try {
          final plans = latestPlanPayload(await conv.plans(sid));
          print('--- latestPlanPayload(conv.plans) ---');
          print(const JsonEncoder.withIndent('  ').convert(plans));
        } on Object catch (err) {
          print('plans query failed: $err');
        }

        // 3) todowrite / update_plan 行的原始形状（截断展示）
        print('--- plan-ish rows ---');
        for (final r in st.rows) {
          final name = '${r['toolName'] ?? r['name'] ?? ''}'.toLowerCase();
          if (!name.contains('todo') && !name.contains('plan')) continue;
          print('row kind=${r['kind']} tool=$name state=${r['state']}');
          for (final k in ['input', 'inputText', 'arguments', 'output']) {
            final v = r[k];
            if (v == null) continue;
            var s = v is String ? v : jsonEncode(v);
            if (s.length > 500) s = '${s.substring(0, 500)}…(${s.length})';
            print('  $k: $s');
          }
        }

        // 4) turnHeader 行形状 + 新版 fileChanges 请求（target+CAS）
        final turnRows = st.rows.where((r) => r['kind'] == 'turnHeader').toList();
        print('--- turnHeader rows: ${turnRows.length} ---');
        for (final r in turnRows.take(2)) {
          final s = jsonEncode(r);
          print(s.length > 800 ? '${s.substring(0, 800)}…' : s);
        }
        try {
          final t = turnRows.isEmpty ? null : turnRows.last;
          if (t == null) {
            print('no turnHeader row to target');
          } else {
            final target = {
              'rowId': (t['rowId'] as num).toInt(),
              'entityId': '${t['entityId'] ?? t['turnId'] ?? ''}',
            };
            final res = await bridge.channels.call(
              'zcode-agent',
              'conversationFileChangesV4',
              [
                {
                  ...conv.scope,
                  'sessionId': sid,
                  'target': target,
                  'baseRevision': st.revision,
                  'baseLogEpoch': st.logEpoch ?? '',
                },
              ],
              timeout: const Duration(seconds: 20),
            );
            print('--- fileChanges(correct shape) ---');
            final s = const JsonEncoder.withIndent('  ').convert(res);
            print(s.length > 2500 ? '${s.substring(0, 2500)}…' : s);
          }
        } on Object catch (err) {
          print('fileChanges(correct) failed: $err');
        }
        await sub.dispose();
      }
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
