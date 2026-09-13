// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：对当前 pending 的 userInput 交互尝试多种 answers 载荷形状，
// 用服务端返回/accepted 与否反推正确结构。
//
// 用法：
//   ZREMOTE_PROBE_LINK="<配对链接>" no_proxy=localhost,127.0.0.1,::1 \
//     flutter test test/manual_interaction_resolve_probe_test.dart
//
// 注意：本探针会**真的回答**掉桌面端挂着的那个弹窗（只答第一个命中的）。
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
  test('interaction resolve shape probe', () async {
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

      Map<String, dynamic>? hit;
      String? hitSid;
      ConversationV4? hitConv;
      for (final ws in workspaces) {
        final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
        print('\n### 扫 $key');
        final bridge = await session.openBridge(key);
        final conv =
            ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));
        final index = await conv.subscribeSessionsIndex();
        try {
          await _wait(() => index.state.ready, 'index',
              timeout: const Duration(seconds: 20));
        } on Object {
          await conv.dispose();
          continue;
        }
        for (final e in index.state.list) {
          final sub = await conv.subscribe(e.sessionId);
          try {
            await _wait(() => sub.state.ready, 'snap',
                timeout: const Duration(seconds: 8));
          } on Object {
            await sub.dispose();
            continue;
          }
          final pending = sub.state.pendingInteractions;
          await sub.dispose();
          if (pending.isNotEmpty) {
            hit = pending.first;
            hitSid = e.sessionId;
            hitConv = conv;
            print('@@@ 命中 $hitSid → ${hit['interactionId']}');
            break;
          }
        }
        if (hit != null) break;
        await conv.dispose();
      }

      if (hit == null) {
        print('没有 pending 交互可实验。');
        return;
      }
      final conv = hitConv!;
      final sid = hitSid!;
      final iid = '${hit['interactionId']}';
      final payload = hit['payload'] as Map;
      final qs = (payload['questions'] as List? ?? []).whereType<Map>().toList();
      final q0 = qs.isEmpty ? <String, Object?>{} : qs.first;
      final opts =
          (q0['options'] as List? ?? []).whereType<Map>().toList();
      print('题目: ${q0['question']}  multiSelect=${q0['multiSelect']}');
      print('选项: ${opts.map((o) => o['value']).toList()}');

      // 只选第一项，试探服务端接受的形状。
      final first = opts.isEmpty ? null : '${opts.first['value']}';
      if (first == null) {
        print('无选项，退出。');
        return;
      }

      // 候选载荷：从最可能的形状开始试。每个只试一次，成功即停。
      final candidates = <String, Object?>{
        // A: answers 为数组，元素 {question, selected:[...]}
        'A_array_selected':
            {'answers': [{'question': q0['question'], 'selected': [first]}]},
        // B: answers 为数组，元素 {questionId, answers:[...]}
        'B_array_questionId':
            {'answers': [{'questionId': q0['question'], 'answers': [first]}]},
        // C: answers 为数组，元素 {question, value}
        'C_array_value': {'answers': [{'question': q0['question'], 'value': first}]},
        // D: answers 为数组，元素 {value:[...]} 无题目
        'D_array_bare': {'answers': [first]},
        // E: 数组，元素 {selectedOptions:[...]}
        'E_selectedOptions': {
          'answers': [
            {'question': q0['question'], 'selectedOptions': [first]}
          ]
        },
        // F: map 形状（当前实现的形状）
        'F_map': {'answers': {'${q0['question']}': [first]}},
      };

      for (final entry in candidates.entries) {
        print('\n=== 试 ${entry.key} ===');
        print(const JsonEncoder.withIndent('  ').convert(entry.value));
        try {
          final res = await conv.resolveInteraction(
            sid,
            iid,
            action: 'accept',
            content: (entry.value as Map).cast<String, dynamic>(),
          );
          print('→ 返回: $res');
          print('→ 该形状被接受（无异常）。');
          // 检查 pending 是否消失
          await Future<void>.delayed(const Duration(milliseconds: 800));
          final sub = await conv.subscribe(sid);
          await _wait(() => sub.state.ready, 'snap2',
              timeout: const Duration(seconds: 8));
          final still = sub.state.pendingInteractions
              .any((p) => '${p['interactionId']}' == iid);
          print('→ pending 是否仍在: $still');
          await sub.dispose();
          if (!still) {
            print('\n*** 形状 ${entry.key} 生效，弹窗已关闭 ***');
            break;
          }
        } on Object catch (err) {
          print('→ 异常: $err');
        }
      }
      print('\n实验结束。');
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
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
