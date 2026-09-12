import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/ui/rows.dart';

/// BUG-30 回归锁：timelineMarker 行必须按 marker.type/status/origin 渲染
/// 出可读中文提示——压缩上下文曾渲染成空白分隔线（提示隐形）。
void main() {
  // 行渲染依赖主题取色（ZT 静态令牌不依赖），直接 Material 包裹即可。
  Future<String> labelOf(WidgetTester tester, Map<String, dynamic> row) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [buildRowCard(row)]),
        ),
      ),
    );
    final text = tester.widgetList<Text>(find.byType(Text));
    return text.map((t) => t.data ?? '').join('|');
  }

  testWidgets('compact completed + origin auto → 自动压缩提示', (tester) async {
    final label = await labelOf(tester, {
      'rowId': 1,
      'kind': 'timelineMarker',
      'marker': {'type': 'compact', 'status': 'completed', 'origin': 'auto'},
    });
    expect(label, contains('自动压缩'));
  });

  testWidgets('compact completed（手动）→ 已压缩上下文', (tester) async {
    final label = await labelOf(tester, {
      'rowId': 2,
      'kind': 'timelineMarker',
      'marker': {'type': 'compact', 'status': 'completed'},
    });
    expect(label, contains('已压缩上下文'));
    expect(label, isNot(contains('自动')));
  });

  testWidgets('compact running → 正在压缩', (tester) async {
    final label = await labelOf(tester, {
      'rowId': 3,
      'kind': 'timelineMarker',
      'marker': {'type': 'compact', 'status': 'running'},
    });
    expect(label, contains('正在压缩'));
  });

  testWidgets('compact failed / cancelled / noop 都有文案', (tester) async {
    for (final entry in {
      'failed': '压缩失败',
      'cancelled': '中断',
      'noop': '无需压缩',
    }.entries) {
      final label = await labelOf(tester, {
        'rowId': 4,
        'kind': 'timelineMarker',
        'marker': {'type': 'compact', 'status': entry.key},
      });
      expect(label, contains(entry.value), reason: 'status=${entry.key}');
    }
  });

  testWidgets('forkNotice → 分叉提示；无 marker → 空白分隔线', (tester) async {
    final fork = await labelOf(tester, {
      'rowId': 5,
      'kind': 'timelineMarker',
      'marker': {'type': 'forkNotice'},
    });
    expect(fork, contains('分叉'));
    final blank = await labelOf(tester, {
      'rowId': 6,
      'kind': 'timelineMarker',
      'marker': {'type': 'goalVerify', 'outcome': 'running'},
    });
    expect(blank, isNot(contains('压缩')));
  });
}
