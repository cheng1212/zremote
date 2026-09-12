import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/app_controller.dart';
import 'package:zremote/theme.dart';
import 'package:zremote/ui/chat_page.dart';
import 'package:zremote/ui/tasks_page.dart';

/// 回归锁：任务卡点击必须真的导航进 ChatPage。
/// （曾经 main.dart 用 MaterialApp 之上的 context 调 Navigator.of →
/// 每次点击抛 "does not include a Navigator"，表现为"点了没反应"。）
void main() {
  test('Citrus Morning theme builds with cream background', () {
    final theme = ZT.theme();
    expect(theme.scaffoldBackgroundColor, ZT.bg);
    expect(theme.appBarTheme.backgroundColor, ZT.bg);
  });

  testWidgets('tapping a task card opens the chat page route', (tester) async {
    final app = ZApp();
    addTearDown(app.dispose);
    app.tasks = [
      {'taskId': 'abc12345-xxxx', 'title': '测试会话', 'phase': 'idle'},
    ];

    String? openedId;
    await tester.pumpWidget(MaterialApp(
      home: TasksPage(
        app: app,
        onOpenTask: (sessionId, title) => openedId = sessionId,
        onNewChat: () {},
      ),
    ));
    // PulseDot 有无限呼吸动画，不能用 pumpAndSettle（永不 settle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('测试会话'), findsOneWidget);
    await tester.tap(find.text('测试会话'));
    expect(openedId, 'abc12345-xxxx');
  });

  /// 回归锁：空会话（无行/无回显/无思考/无错误卡）时 ListView 不得越界。
  /// 真机 2026-09-12 实证：进入会话首帧必现
  /// `RangeError (length): Only valid value is 0: 1` —— 空会话引导槽位与
  /// headerCells 的偏移错位，末尾 index 落到 headerCells[1] 上越界，
  /// 表现为列表里多出一块灰色 ErrorWidget。
  testWidgets('empty chat list lays out without RangeError',
      (tester) async {
    final app = ZApp();
    addTearDown(app.dispose);

    await tester.pumpWidget(MaterialApp(
      home: ChatPage(app: app, sessionId: null, title: '空会话'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 空会话引导文案必须渲染出来，且全程没有异常。
    expect(tester.takeException(), isNull);
    expect(find.text('发第一条消息，开始这个会话'), findsOneWidget);
  });
}
