// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：新建 NVIDIA 会话并监视其模型字段 150 秒，记录每一次变化。
// ZREMOTE_PROBE_LINK='<链接>' flutter test test/manual_model_watch_test.dart -r expanded
@Tags(['manual'])
library;
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test(
    'model watch: createSession(nv) → watch config 150s → delete',
    () async {
      if (raw == null || raw.isEmpty) {
        markTestSkipped('ZREMOTE_PROBE_LINK not set');
        return;
      }
      final params = LinkParams.parse(raw.trim())!;
      final session = RemoteSession(params, onLog: (l) => print('[log] $l'));
      String? createdSid;
      Bridge? bridge;
      try {
        await session.connect();
        await session.waitPaired(timeout: const Duration(seconds: 45));
        final bootstrap = await session.bootstrap();
        final ws = (bootstrap['workspaces'] as List? ?? [])
            .whereType<Map>()
            .first;
        final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
        bridge = await session.openBridge(key);
        final conv = ConversationV4(
          bridge: bridge,
          onLog: (l) => print('[log] $l'),
        );

        const wantProvider = '7f3a9c21-5b48-4d6e-9a0f-2c1e8d4b6a55';
        const wantModel = 'nv-nemotron-ultra';
        createdSid = await conv.createSession(
          key,
          config: const {
            'provider': wantProvider,
            'model': wantModel,
            'thought': 'high',
          },
        );
        print('\n===== CREATED $createdSid =====');

        final sub = await conv.subscribe(createdSid);
        await _waitUntil(() => sub.state.ready, 'snapshot ready');
        print(
          't+0s   config=${sub.state.currentProvider}/${sub.state.currentModel}'
          ' thought=${sub.state.currentThought} phase=${sub.state.phase}',
        );

        // 触发一个真实回合：发一条消息（NVIDIA 免费），观察运行中/结束后的模型翻转
        print('===== SENDING first message =====');
        await conv.sendText(createdSid, '你好，请只回复两个字：正常');
        print('sent.');

        var last =
            '${sub.state.currentProvider}/${sub.state.currentModel}/${sub.state.currentThought}';
        final timeline = <String>[];
        final start = DateTime.now();
        final timer = Timer.periodic(const Duration(seconds: 2), (_) {
          if (!sub.state.ready) return;
          final now =
              '${sub.state.currentProvider}/${sub.state.currentModel}/${sub.state.currentThought}';
          if (now != last) {
            final t = DateTime.now().difference(start).inSeconds;
            final line = 't+${t}s  $last → $now  (phase=${sub.state.phase})';
            print(line);
            timeline.add(line);
            last = now;
          }
        });

        // 监视 180 秒：桌面端同步周期实测 ~10-35s，足够抓到。
        await Future<void>.delayed(const Duration(seconds: 180));
        timer.cancel();
        print('\n===== FLIPS: ${timeline.length} =====');
        for (final l in timeline) {
          print(l);
        }

        await sub.dispose();
      } finally {
        if (createdSid != null) {
          try {
            final b = bridge;
            if (b != null) {
              await b.channels.call(
                'zcode-task',
                'deleteTask',
                [
                  {
                    'workspacePath': b.scope['workspacePath'],
                    if (b.scope['workspaceIdentity'] != null)
                      'workspaceIdentity': b.scope['workspaceIdentity'],
                    'taskId': createdSid,
                  },
                ],
                timeout: const Duration(seconds: 15),
              );
              print('test session deleted: $createdSid');
            }
          } on Object catch (e) {
            print('delete failed (手动删即可): $e');
          }
        }
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

Future<void> _waitUntil(
  bool Function() cond,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('wait $what timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
