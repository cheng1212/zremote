// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：遍历**所有** workspace，抓 pendingInteractions 的真实结构。
//
// 用法：
//   ZREMOTE_PROBE_LINK="<配对链接>" no_proxy=localhost,127.0.0.1,::1 \
//     flutter test test/manual_interaction_probe_test.dart
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
  test('pendingInteractions shape probe', () async {
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
      print('\n########## workspace 数量: ${workspaces.length} ##########');
      for (final w in workspaces) {
        print('  - ${w['workspaceKey'] ?? w['workspacePath']} '
            '(identity=${w['workspaceIdentity']})');
      }

      var found = 0;
      for (final ws in workspaces) {
        final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
        print('\n########## 打开 bridge: $key ##########');
        final bridge = await session.openBridge(key);
        final conv =
            ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));
        final index = await conv.subscribeSessionsIndex();
        try {
          await _wait(() => index.state.ready, 'index $key',
              timeout: const Duration(seconds: 20));
        } on Object catch (err) {
          print('[skip] index 未就绪: $err');
          await conv.dispose();
          continue;
        }
        print('会话数: ${index.state.list.length}');

        for (final e in index.state.list) {
          final sid = e.sessionId;
          final sub = await conv.subscribe(sid);
          try {
            await _wait(() => sub.state.ready, 'snapshot $sid',
                timeout: const Duration(seconds: 15));
          } on Object catch (err) {
            print('[skip] $sid 快照失败: $err');
            await sub.dispose();
            continue;
          }
          final st = sub.state;
          final pending = st.pendingInteractions;
          if (pending.isNotEmpty) {
            found++;
            print('\n@@@@@@@@@@ 命中! $sid (${e.phase}) ${e.title} @@@@@@@@@@');
            print('--- 原始 JSON ---');
            print(const JsonEncoder.withIndent('  ').convert(pending));
            print('--- 字段拆解 ---');
            for (final it in pending) {
              _dumpInteraction(it);
            }
          }
          await sub.dispose();
        }
        await conv.dispose();
      }
      print('\n########## 命中会话数: $found ##########');
      if (found == 0) {
        print('仍未找到等待输入的会话。请确认弹窗所属项目，或在弹窗挂着时重跑。');
      }
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

void _dumpInteraction(Map<String, dynamic> it) {
  for (final k in it.keys) {
    final v = it[k];
    var s = v is String ? v : jsonEncode(v);
    if (s.length > 1500) s = '${s.substring(0, 1500)}…(${s.length})';
    print('  [$k] $s');
  }
  final payload = it['payload'];
  if (payload is! Map) return;
  print('  → payload 字段 = ${payload.keys.toList()}');
  print('  → payload.kind = ${payload['kind']}');
  print('  → payload.freeText = ${payload['freeText']}');
  print('  → payload.prompt = ${payload['prompt']}');
  final qs = payload['questions'];
  if (qs is! List) {
    print('  → questions 非 List: $qs');
    return;
  }
  print('  → questions 数量 = ${qs.length}');
  for (var i = 0; i < qs.length; i++) {
    final q = qs[i];
    if (q is! Map) {
      print('    [q$i] 非 Map: $q');
      continue;
    }
    print('    [q$i] 字段 = ${q.keys.toList()}');
    for (final k in q.keys) {
      if (k == 'options') continue;
      print('      $k = ${q[k]}');
    }
    print('      ** multiSelect? ${q['multiSelect']} / multi? ${q['multi']}'
        ' / allowOther? ${q['allowOther']} / other? ${q['other']}'
        ' / required? ${q['required']} / id? ${q['id']}');
    final opts = q['options'];
    if (opts is List) {
      for (var j = 0; j < opts.length; j++) {
        print('      option[$j] = ${opts[j]}');
      }
    }
  }
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
