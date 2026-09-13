// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断探针：App 真正发的**扁平形状** switchModelConfig {provider, model, thought}
// 桌面端认不认？挨个试 provider 变体，每次打印 ack + 之后的 config。
// （前一个探针只试了 runtimeModel 对象形状，全被 proto.invalidPayload 拒了，
//   没覆盖 App 实际发的那条路。）一次性会话，结束自删。
// ZREMOTE_PROBE_LINK 门控。
@Tags(['manual'])
library;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];

  test('createSession 带 config 能不能落到 GLM-5.3-Flash', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final params = LinkParams.parse(raw.trim())!;
    final session = RemoteSession(params, onLog: (_) {});
    ConversationV4? conv;
    String? sid;
    ConvSubscription? sub;
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final ws = (bootstrap['workspaces'] as List).whereType<Map>().first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      conv = ConversationV4(bridge: bridge, onLog: (_) {});
      // App 的 _draftConfig() 就发这个形状
      sid = await conv.createSession(
        '${bridge.info['workspaceKey'] ?? key}',
        config: const {
          'provider': 'builtin:bigmodel-coding-plan',
          'model': 'GLM-5.3-Flash',
          'thought': 'high',
        },
      );
      sub = await conv.subscribe(sid);
      await Future<void>.delayed(const Duration(seconds: 3));
      final st = sub.state;
      print('[create+config] ${st.currentProvider}/${st.currentModel} '
          'thought=${st.config?['thought']}');
      print(
        st.currentModel == 'GLM-5.3-Flash'
            ? '结论：createSession 的 config 生效 ✓'
            : '结论：**没生效** —— 被置成 ${st.currentProvider}/${st.currentModel}',
      );
    } finally {
      try {
        if (conv != null && sid != null) await conv.deleteSession(sid);
      } on Object catch (_) {}
      await sub?.dispose();
      await conv?.dispose();
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('flat switchModelConfig probe (disposable session)', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final params = LinkParams.parse(raw.trim())!;
    final session = RemoteSession(params, onLog: (l) => print('[log] $l'));
    ConversationV4? conv;
    String? sid;
    ConvSubscription? sub;
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final workspaces = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      conv = ConversationV4(bridge: bridge, onLog: (_) {});
      sid = await conv.createSession('${bridge.info['workspaceKey'] ?? key}');
      sub = await conv.subscribe(sid);
      await Future<void>.delayed(const Duration(seconds: 2));

      void snap(String tag) {
        final st = sub!.state;
        print('[$tag] ${st.currentProvider}/${st.currentModel} '
            'thought=${st.config?['thought']}');
      }

      snap('初始');
      final uuidProvider = sub.state.currentProvider;
      const glm = 'GLM-5.3-Flash';

      final tries = <String, (String, String)>{
        'coding-plan + GLM-5.3-Flash + high': ('builtin:bigmodel-coding-plan', 'high'),
        'coding-plan + GLM-5.3-Flash + max': ('builtin:bigmodel-coding-plan', 'max'),
        'start-plan + GLM-5.3-Flash + high': ('builtin:bigmodel-start-plan', 'high'),
        'UUID(现provider) + GLM-5.3-Flash + high': (uuidProvider, 'high'),
        'UUID + 原模型 + high（对照组）': (uuidProvider, sub.state.currentModel),
      };
      for (final e in tries.entries) {
        final (prov, thought) = e.value;
        print('\n--- ${e.key}');
        try {
          final res = await conv.sendCommand(sid, 'switchModelConfig', {
            'provider': prov,
            'model': glm == 'GLM-5.3-Flash' && e.key.startsWith('UUID + 原模型')
                ? sub.state.currentModel
                : glm,
            'thought': thought,
          });
          print('  ack: ${jsonEncode(res).length > 300 ? jsonEncode(res).substring(0, 300) : jsonEncode(res)}');
        } on Object catch (err) {
          print('  异常: ${err.toString().split('\n').first}');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        snap('  之后');
      }
    } finally {
      try {
        if (conv != null && sid != null) await conv.deleteSession(sid);
        print('[cleanup] deleted $sid');
      } on Object catch (e) {
        print('[cleanup] 失败: $e');
      }
      await sub?.dispose();
      await conv?.dispose();
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
