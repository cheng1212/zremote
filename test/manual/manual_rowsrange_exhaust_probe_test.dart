// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：会话历史翻页链端到端取证（用户报障"加载不完整"）。
// 循环 loadOlder 直到抽干，核对 rows.length vs totalCount，
// 记录每轮 firstRowId/返回行数，验证翻页链是否丢失内容。
// ZREMOTE_PROBE_LINK 门控；ZREMOTE_PROBE_SID 可选指定会话 id，
// 不指定则取 index 首个（最近活跃）会话。
@Tags(['manual'])
library;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  final sidEnv = Platform.environment['ZREMOTE_PROBE_SID'];

  test('history pagination exhaust probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final workspaces = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .toList();
      // 目标会话：环境变量优先（在所有工作区的 index 里找），
      // 否则取第一个工作区最近活跃的第一个。
      String targetSid = sidEnv ?? '';
      String? targetKey;
      for (final ws in workspaces) {
        final k = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
        final b = await session.openBridge(k);
        final c = ConversationV4(bridge: b, onLog: (_) {});
        final idx = await c.subscribeSessionsIndex();
        await Future.delayed(const Duration(seconds: 2));
        final hit = idx.state.list.any((e) => e.sessionId == targetSid);
        final first = idx.state.list.isNotEmpty
            ? idx.state.list.first.sessionId
            : '';
        await idx.dispose();
        await c.dispose();
        b.dispose();
        if (targetSid.isEmpty && first.isNotEmpty) {
          targetSid = first;
          targetKey = k;
          break;
        }
        if (hit) {
          targetKey = k;
          break;
        }
      }
      if (targetKey == null) {
        print('未找到目标会话所在工作区');
        return;
      }
      final key = targetKey;
      final bridge = await session.openBridge(key);
      final conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));
      final index = await conv.subscribeSessionsIndex();
      await Future.delayed(const Duration(seconds: 2));
      final sid = targetSid;
      print('==== 目标会话: $sid (index ${index.state.list.length} 条) ====');
      if (sid.isEmpty) {
        print('该工作区无会话');
        return;
      }
      final sub = await conv.subscribe(sid);
      try {
        await Future.delayed(const Duration(seconds: 2));
        final st = sub.state;
        print('snapshot: rows=${st.rows.length} '
            'totalCount=${st.totalCount} firstRowId=${st.firstRowId} '
            'hasMoreOlder=${st.hasMoreOlder}');

        var rounds = 0;
        var stalled = false;
        while (st.hasMoreOlder && rounds < 80) {
          rounds++;
          final before = st.rows.length;
          await sub.loadOlder(limit: 60);
          final after = st.rows.length;
          print('round $rounds: $before → $after '
              '(firstRowId=${st.firstRowId} hasMore=${st.hasMoreOlder})');
          if (after == before) {
            // 连续 3 轮无进展则停（防死循环）
            var s2 = 1;
            while (s2 < 3 && st.hasMoreOlder) {
              await sub.loadOlder(limit: 60);
              if (st.rows.length > after) break;
              s2++;
            }
            if (st.rows.length == after) {
              stalled = true;
              break;
            }
          }
        }
        print('==== 最终 ====');
        print('rows=${st.rows.length} totalCount=${st.totalCount} '
            'hasMoreOlder=${st.hasMoreOlder} rounds=$rounds stalled=$stalled');
        print(st.rows.length >= st.totalCount
            ? '结论：可抽干（加载行数达 totalCount）'
            : '结论：抽干后仍 < totalCount → 有内容不可达（BUG 证实）');
      } finally {
        await sub.dispose();
      }
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
