// ignore_for_file: avoid_print
// 探针标签：dart_test.yaml 按此排除，默认 flutter test 不跑本目录。
// 手动诊断：服务端清单审计——逐项目点数（活跃/归档）+ bootstrap 整机表比对，
// 定位「本地会话列表和服务端对不上」的真实数据源差异。只读，无任何写操作。
@Tags(['manual'])
library;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('server list audit: per-project active/archived counts', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final wsList = (bootstrap['workspaces'] as List? ?? [])
          .whereType<Map>()
          .toList();
      final bootTasks = (bootstrap['tasks'] as List? ?? [])
          .whereType<Map>()
          .toList();
      print('===== bootstrap: workspaces=${wsList.length} '
          'tasks=${bootTasks.length} =====');

      // bootstrap 表按项目分组 + 归档标记统计 + 形状
      final bootByPath = <String, int>{};
      var bootArchived = 0;
      for (final t in bootTasks) {
        final p = '${t['workspacePath'] ?? t['workspaceKey'] ?? '?'}';
        bootByPath[p] = (bootByPath[p] ?? 0) + 1;
        if (t['archived'] == true) bootArchived++;
      }
      bootByPath.forEach((p, n) => print('bootstrap [$p] = $n 条'));
      print('bootstrap 带 archived==true 标记: $bootArchived 条');
      if (bootTasks.isNotEmpty) {
        print('bootstrap task[0] 字段: ${bootTasks.first.keys.toList()}');
      }

      // 开一个桥（任一项目即可）——task 通道是 host 级服务，按参数里的
      // workspacePath 路由，跨项目直发（置顶跨项目收集已实证同一模式）。
      final ws0 = wsList.first;
      final key0 = '${ws0['workspaceKey'] ?? ws0['workspacePath']}';
      final bridge = await session.openBridge(key0);
      Future<dynamic> call(String method, List<Object?> args) =>
          bridge.channels.call('zcode-task', method, args,
              timeout: const Duration(seconds: 20));

      var totalActive = 0;
      var totalArchived = 0;
      for (final w in wsList) {
        final path = '${w['workspacePath'] ?? ''}';
        final identity = w['workspaceIdentity'];
        final scope = <String, dynamic>{
          'workspacePath': path,
          'workspaceIdentity': ?identity,
        };
        final label = '${w['label'] ?? w['name'] ?? path}';
        List list(Object? res) => res is List ? res : const <Object?>[];
        final tasks = list(await call('listTasks', [scope]));
        final archived = list(await call('listArchivedTasks', [scope]));
        final flagged = tasks
            .where(
              (e) => e is Map && (e['archived'] == true || e['deleted'] == true),
            )
            .length;
        totalActive += tasks.length - flagged;
        totalArchived += archived.length;
        print('[$label] listTasks=${tasks.length}（带归档/删除标记 $flagged） '
            'listArchivedTasks=${archived.length}');
        for (final e in archived.take(3)) {
          if (e is Map) print('   归档示例: ${e['title'] ?? e['taskId']}');
        }
      }
      print('===== 汇总: 活跃=$totalActive 归档=$totalArchived =====');
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
