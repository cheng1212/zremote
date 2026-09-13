// ignore_for_file: avoid_print
// 手动诊断：会话历史到底能拉多少。
//   阶段一：扫全部工作区全部会话，打印 rows/totalCount，找出最大的那个；
//   阶段二：对最大的会话按 App 的真实姿势（loadOlder 默认 limit=60）循环抽干，
//          打印每轮进账 —— 用来复现"拉不出来 / 停在某处"。
// ZREMOTE_PROBE_LINK 门控；ZREMOTE_PROBE_MAX 限制阶段一扫描数（默认 60）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  final maxSessions =
      int.tryParse(Platform.environment['ZREMOTE_PROBE_MAX'] ?? '') ?? 60;

  test('history window probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    final found = <({String sid, String key, int total, String title})>[];
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final workspaces = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .toList();
      print('==== 阶段一：工作区 ${workspaces.length} 个 ====');
      for (final ws in workspaces) {
        if (found.length >= maxSessions) break;
        final k = '${ws['workspaceKey'] ?? ws['workspacePath']}';
        final bridge = await session.openBridge(k);
        final conv = ConversationV4(bridge: bridge, onLog: (_) {});
        final index = await conv.subscribeSessionsIndex();
        await Future.delayed(const Duration(seconds: 2));
        for (final e in index.state.list) {
          if (found.length >= maxSessions) break;
          ConvSubscription? sub;
          try {
            sub = await conv.subscribe(e.sessionId);
            await Future.delayed(const Duration(milliseconds: 800));
            final st = sub.state;
            found.add((
              sid: e.sessionId,
              key: k,
              total: st.totalCount,
              title: e.title,
            ));
            print(
              '  rows=${st.rows.length} totalCount=${st.totalCount} '
              'title=${e.title}',
            );
          } on Object catch (err) {
            print('  订阅失败 ${e.sessionId}: $err');
          } finally {
            await sub?.dispose();
          }
        }
        await index.dispose();
        await conv.dispose();
        bridge.dispose();
      }
      found.sort((a, b) => b.total.compareTo(a.total));
      if (found.isEmpty) {
        print('没有会话');
        return;
      }
      final big = found.first;
      print('==== 阶段二：最大会话 totalCount=${big.total} (${big.title}) ====');
      final bridge = await session.openBridge(big.key);
      final conv = ConversationV4(
        bridge: bridge,
        onLog: (l) => print('    [log] $l'),
      );
      final sub = await conv.subscribe(big.sid);
      try {
        await Future.delayed(const Duration(seconds: 2));
        final st = sub.state;
        print(
          '入口: rows=${st.rows.length} totalCount=${st.totalCount} '
          'firstRowId=${st.firstRowId} hasMore=${st.hasMoreOlder}',
        );
        // 一轮上限能要多少：桌面端认多大的 limit？（决定"全部拉取"的轮数）
        for (final lim in const [100, 200, 300, 500]) {
          if (!st.hasMoreOlder) break;
          final before = st.rows.length;
          await sub.loadOlder(limit: lim);
          print(
            '  limit=$lim → ${st.rows.length} (+${st.rows.length - before}) '
            'hasMore=${st.hasMoreOlder}',
          );
        }
        print(
          '==== 结束: rows=${st.rows.length} totalCount=${st.totalCount} '
          'hasMore=${st.hasMoreOlder} ====',
        );
      } finally {
        await sub.dispose();
        await conv.dispose();
        bridge.dispose();
      }
    } finally {
      session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
