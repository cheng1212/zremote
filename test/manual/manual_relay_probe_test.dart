// 手动诊断探针：print 就是它的输出方式，忽略 avoid_print。
// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
@Tags(['manual'])
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

/// 手动协议探针：连上真实桌面端，只读侦查 + 受控实验。
/// 凭证从环境变量读，不落仓库：
///   ZREMOTE_PROBE_LINK='https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…&mid=…' \
///     flutter test test/manual_relay_probe_test.dart -r expanded
/// 未设置环境变量时直接跳过（普通 flutter test 全量跑不受影响）。
void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test(
    'relay probe: bootstrap → index → prepareWorkspace → session snapshot → switch experiments',
    () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
      final params = LinkParams.parse(raw.trim());
      expect(params, isNotNull, reason: 'link should parse');
      final session = RemoteSession(params!, onLog: (l) => print('[log] $l'));
      try {
        await session.connect();
        await session.waitPaired(timeout: const Duration(seconds: 45));
        print('\n===== PAIRED =====');

        final bootstrap = await session.bootstrap();
        final workspaces = (bootstrap['workspaces'] as List? ?? [])
            .whereType<Map>()
            .toList();
        print('workspaces: ${workspaces.length}');
        for (final w in workspaces) {
          print('  - ${w['workspaceKey']} | ${w['workspacePath']}');
        }
        expect(workspaces, isNotEmpty);
        final ws = workspaces.first;
        final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;

        final bridge = await session.openBridge(key);
        final conv = ConversationV4(bridge: bridge, onLog: (l) => print('[log] $l'));

        // ---- 1. sessions index：会话列表与 phase
        final index = await conv.subscribeSessionsIndex();
        await _waitUntil(
          () => index.state.ready,
          timeout: const Duration(seconds: 20),
          what: 'sessions-index ready',
        );
        print('\n===== SESSIONS (${index.state.list.length}) =====');
        for (final e in index.state.list.take(10)) {
          print(
            '  ${e.sessionId.substring(0, e.sessionId.length > 12 ? 12 : e.sessionId.length)}… '
            '| ${e.phase.padRight(9)} | ${e.title.isEmpty ? "(untitled)" : e.title}',
          );
        }

        // ---- 2. prepareWorkspace：模型选项 + 当前值（关键！）
        final prep = await conv.prepareWorkspace();
        print('\n===== PREPARE WORKSPACE =====');
        print('slashCommands: ${(prep['slashCommands'] as List? ?? []).length}');
        final options = prep['configOptions'] as List? ?? [];
        for (final o in options.whereType<Map>()) {
          print('  group: ${o['id']}  currentValue=${o['currentValue']}');
          for (final opt in (o['options'] as List? ?? []).whereType<Map>()) {
            print(
              '    - ${opt['value']}  (${opt['name'] ?? ''}${opt['modelProviderName'] != null ? ' / provider=${opt['modelProviderName']}' : ''})',
            );
          }
        }

        // ---- 3. 挑一个 idle（completedSuccess）会话读快照 + 做切换实验，
        //         避开 running 的会话（可能正是发探测时正在跑的那个）。
        final sessions = index.state.list;
        if (sessions.isEmpty) {
          print('no sessions; skip snapshot/switch experiments');
          return;
        }
        final idle = sessions.where((e) => e.phase == 'completedSuccess').toList();
        if (idle.isEmpty) {
          print('no idle session; skip switch experiments');
          return;
        }
        final sid = idle.first.sessionId;
        final sub = await conv.subscribe(sid);
        await _waitUntil(
          () => sub.state.ready,
          timeout: const Duration(seconds: 30),
          what: 'conv ready',
        );
        final st = sub.state;
        print('\n===== SESSION SNAPSHOT ($sid) =====');
        print('phase=${st.phase} revision=${st.revision}');
        print(
          'config: provider=${st.currentProvider} model=${st.currentModel} '
          'thought=${st.currentThought} mode=${st.currentMode} '
          'approval=${st.currentApprovalMode}',
        );

        // ---- 4. 实验 A：同配置切换（预期 noop / config.unchanged）
        print('\n===== EXP A: same-config switchModelConfig =====');
        try {
          final res = await conv.sendCommand(sid, 'switchModelConfig', {
            'provider': st.currentProvider,
            'model': st.currentModel,
            'thought': st.currentThought,
          });
          print('unexpected success: $res');
        } on Object catch (e) {
          print('RESULT A: $e');
        }

        // ---- 5. 实验 B：切 NVIDIA（首选默认）再切回（仅 idle 时执行）
        if (st.phase == 'idle' || st.phase == 'completedSuccess') {
          final nvidiaProvider = const String.fromEnvironment(
            'PROBE_NVIDIA_PROVIDER',
            defaultValue: '7f3a9c21-5b48-4d6e-9a0f-2c1e8d4b6a55',
          );
          final nvidiaModel = const String.fromEnvironment(
            'PROBE_NVIDIA_MODEL',
            defaultValue: 'nv-nemotron-ultra',
          );
          final origProvider = st.currentProvider;
          final origModel = st.currentModel;
          final origThought =
              st.currentThought.isEmpty ? 'enabled' : st.currentThought;

          print('\n===== EXP B: switch → NVIDIA ($nvidiaModel) =====');
          Object? bError;
          try {
            final res = await conv.sendCommand(sid, 'switchModelConfig', {
              'provider': nvidiaProvider,
              'model': nvidiaModel,
              'thought': 'high',
            });
            print('RESULT B success: ${jsonEncode(res)}');
          } on Object catch (e) {
            bError = e;
            print('RESULT B error: $e');
          }
          // 给桌面端一点时间广播 state.updated，再看回读的实际模型
          await Future<void>.delayed(const Duration(seconds: 2));
          print(
            'after B, session config: provider=${st.currentProvider} '
            'model=${st.currentModel} thought=${st.currentThought}',
          );

          print('\n===== EXP B2: switch back ($origModel) =====');
          try {
            await conv.sendCommand(sid, 'switchModelConfig', {
              'provider': origProvider,
              'model': origModel,
              'thought': origThought,
            });
            print('RESULT B2 success (restored)');
          } on Object catch (e) {
            print('RESULT B2 error: $e');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
          print(
            'after B2, session config: provider=${st.currentProvider} '
            'model=${st.currentModel} thought=${st.currentThought}',
          );
          if (bError != null) {
            print('\n>>> NVIDIA switch FAILED with: $bError');
          }
        } else {
          print('\n(skip EXP B: session phase=${st.phase} not idle)');
        }

        await sub.dispose();
        await conv.dispose(); // index 由 conv 统一释放（幂等已保证）
        print('\n===== DONE =====');
      } finally {
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _waitUntil(
  bool Function() cond, {
  required Duration timeout,
  required String what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('wait $what timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
