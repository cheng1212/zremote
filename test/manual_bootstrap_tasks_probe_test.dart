// ignore_for_file: avoid_print
// 手动诊断：bootstrap 的整机任务列表（tasks[]）真实形状 + 跨项目 setTaskPinned 能否走通。
// 「全部对话」与「跨项目置顶」两个功能都押在这两个答案上；形状未实测前代码按多形态
// 兜底实现（parseBootstrapTasks），本探针用来在拿到配对链接时把兜底收成实测结论。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/constants.dart';
import 'package:zremote/protocol/link_params.dart';
import 'package:zremote/protocol/remote_session.dart';
import 'package:zremote/state/task_sort.dart';

void main() {
  final raw = Platform.environment['ZREMOTE_PROBE_LINK'];
  test('bootstrap tasks shape + cross-project pin probe', () async {
    if (raw == null || raw.isEmpty) {
      markTestSkipped('ZREMOTE_PROBE_LINK not set');
      return;
    }
    final session = RemoteSession(LinkParams.parse(raw.trim())!);
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final boot = await session.bootstrap();

      print('\n===== bootstrap 顶层键 =====');
      print(boot.keys.toList());
      print('workspaces: ${(boot['workspaces'] as List?)?.length ?? 0}');
      final tasks = boot['tasks'];
      print('tasks 类型: ${tasks.runtimeType}');
      final enc = const JsonEncoder.withIndent('  ');
      if (tasks is List) {
        print('tasks 数量: ${tasks.length}');
        for (final t in tasks.take(3)) {
          final s = enc.convert(t);
          print(s.length > 2500 ? '${s.substring(0, 2500)}…' : s);
          print('---');
        }
      }

      final parsed = parseBootstrapTasks(tasks);
      print('\n===== parseBootstrapTasks 解析结果 =====');
      print('解析出 ${parsed.length} 条');
      for (final t in parsed.take(6)) {
        print(
          '  taskId=${t['taskId']} | 项目=${taskProjectKey(t)} | '
          '标题=${t['title']} | pinned=${t['pinned']}',
        );
      }

      final workspaces = (boot['workspaces'] as List? ?? [])
          .whereType<Map>()
          .toList();
      if (workspaces.isEmpty || parsed.isEmpty) return;
      final ws = workspaces.first;
      final key = (ws['workspaceKey'] ?? ws['workspacePath']) as String;
      final bridge = await session.openBridge(key);
      final ownPath = '${ws['workspacePath'] ?? ''}';
      final foreign = parsed
          .where((t) => taskProjectKey(t) != ownPath)
          .toList();

      print('\n===== 跨项目 setTaskPinned 实验 =====');
      print('当前桥项目: $ownPath');
      if (foreign.isEmpty) {
        print('没有别的项目的任务可试（只有一个项目有会话）——结论待补');
      } else {
        final t = foreign.first;
        final wasPinned = t['pinned'] == true;
        final scope = <String, dynamic>{
          'taskId': t['taskId'],
          'workspacePath': t['workspacePath'],
          'workspaceIdentity': ?t['workspaceIdentity'],
        };
        print('目标: ${t['taskId']} @ ${taskProjectKey(t)}（原 pinned=$wasPinned）');
        try {
          final res = await bridge.channels.call(
            Chan.task,
            'setTaskPinned',
            [
              {...scope, 'pinned': !wasPinned},
            ],
            timeout: const Duration(seconds: 12),
          );
          print('跨项目置顶返回: $res');
          // 立刻还原，别给用户留痕。
          await bridge.channels.call(
            Chan.task,
            'setTaskPinned',
            [
              {...scope, 'pinned': wasPinned},
            ],
            timeout: const Duration(seconds: 12),
          );
          print('已还原 pinned=$wasPinned');
        } on Object catch (e) {
          print('跨项目置顶失败: $e');
        }
      }
      bridge.dispose();
    } finally {
      await session.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
