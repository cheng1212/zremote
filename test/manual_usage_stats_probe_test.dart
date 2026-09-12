// ignore_for_file: avoid_print
// 手动诊断：用量统计（usage-stats）bridge 通道形状探测。只读。
// 链接从 ZREMOTE_PROBE_LINK 环境变量读，严禁写进代码。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('usage stats shape probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final ws = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);

      // 假通道校准：unknown channel 的报错语义长什么样。
      try {
        await bridge.channels.call(
          'no-such-channel',
          'noSuchMethod',
          const [],
          timeout: const Duration(seconds: 8),
        );
        print('!! bogus channel succeeded?!');
      } on Object catch (e) {
        print('-- bogus channel → $e');
      }

      // 桌面端 usageStatsService 的方法名（asar 实锤）逐个试。
      const candidates = [
        ('usage-stats', 'getAppUsageSnapshot'),
        ('usage-stats', 'getSnapshot'),
        ('usage-stats', 'getEntitlementSnapshot'),
        ('usage-stats', 'getCodingPlanUsageSnapshot'),
        ('usage-stats', 'getUsageStatsSnapshot'),
        ('zcode-agent', 'getAppUsageStats'),
      ];
      const argVariants = <List<Object?>>[
        [
          {'range': '7d', 'timeZone': 'Asia/Shanghai'},
        ],
        [
          {'range': '7d'},
        ],
        [],
      ];

      var found = 0;
      for (final (channel, method) in candidates) {
        for (final args in argVariants) {
          try {
            final res = await bridge.channels.call(
              channel,
              method,
              args,
              timeout: const Duration(seconds: 15),
            );
            found++;
            print('\n===== OK $channel.$method args=$args =====');
            var s = const JsonEncoder.withIndent('  ').convert(res);
            print(
              s.length > 7000
                  ? '${s.substring(0, 7000)}…(total ${s.length})'
                  : s,
            );
            break; // 该 method 通了就不用再换参数
          } on Object catch (e) {
            final msg = '$e';
            print(
              '-- fail $channel.$method args=$args → '
              '${msg.length > 400 ? '${msg.substring(0, 400)}…' : msg}',
            );
          }
        }
      }
      print('\n===== probe done: $found 个组合成功 =====');
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
