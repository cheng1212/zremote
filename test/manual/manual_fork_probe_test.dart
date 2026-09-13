// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：forkAssistant 响应形状探测（分叉后立即删除，不留残留）。
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
  test('forkAssistant shape probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    String? forkedId;
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
      final idle = index.state.list
          .where((e) => e.phase == 'completedSuccess')
          .toList();
      if (idle.isEmpty) {
        print('no idle session');
        return;
      }
      final sid = idle.first.sessionId;
      final sub = await conv.subscribe(sid);
      await _wait(() => sub.state.ready, 'snapshot');
      final st = sub.state;
      // 挑最后一条 assistantText 行做 target
      Map<String, dynamic>? target;
      for (final r in st.rows.reversed) {
        if (r['kind'] != 'assistantText' || r['rowId'] == null) continue;
        final entityId = '${r['entityId'] ?? r['turnId'] ?? ''}';
        if (entityId.isEmpty) continue;
        target = {'rowId': (r['rowId'] as num).toInt(), 'entityId': entityId};
        break;
      }
      if (target == null) {
        print('no assistant row to fork from');
        return;
      }
      print('fork from row ${target['rowId']}');
      final res = await conv.sendCommand(sid, 'forkAssistant', {'target': target});
      print('===== fork response =====');
      print(const JsonEncoder.withIndent('  ').convert(res));
      final result = res is Map ? res['result'] : null;
      forkedId = result is Map ? '${result['sessionId'] ?? ''}' : '';
      if (forkedId.isEmpty && res is Map) {
        forkedId = '${res['sessionId'] ?? ''}';
      }
      print('forked sessionId: $forkedId');
      await sub.dispose();

      // 删除分叉（不残留）
      if (forkedId.isNotEmpty && forkedId != 'null') {
        final scope = bridge.scope;
        await bridge.channels.call(
          'zcode-task',
          'deleteTask',
          [
            {
              ...scope,
              'taskId': forkedId,
            },
          ],
          timeout: const Duration(seconds: 15),
        );
        print('forked session deleted');
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
