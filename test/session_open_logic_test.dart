import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/state/session_open_logic.dart';

void main() {
  group('sessionOpenPlan（并发打开去重）', () {
    test('同一个会话正在打开 → 复用那条在飞的，不再发第二条订阅', () {
      // 这正是历史 bug：列表点卡片发一次、聊天页 initState 又发一次，
      // 两条 subscribeConversationV4 并发，后者覆盖前者且前者订阅泄漏。
      expect(
        sessionOpenPlan(sessionId: 's1', openingSid: 's1'),
        SessionOpenPlan.awaitInflight,
      );
    });

    test('没有在飞的 → 发起打开', () {
      expect(
        sessionOpenPlan(sessionId: 's1', openingSid: null),
        SessionOpenPlan.open,
      );
    });

    test('在飞的是**别的**会话 → 仍然发起（用户换了目标）', () {
      expect(
        sessionOpenPlan(sessionId: 's2', openingSid: 's1'),
        SessionOpenPlan.open,
      );
    });
  });

  group('shouldShowChatOpenFailure（失败卡的判据）', () {
    test('真失败且没内容可顶 → 亮卡', () {
      expect(
        shouldShowChatOpenFailure(
          chatError: '订阅超时',
          sessionId: 's1',
          hasSnapshot: false,
        ),
        isTrue,
      );
    });

    test('**没失败就不亮** —— 乐观切换期间 chat 也是 null，不能当失败', () {
      // 这正是用户报的"刚进去就一屏订阅失败"：切桥还没走完，chatError 为空。
      expect(
        shouldShowChatOpenFailure(
          chatError: null,
          sessionId: 's1',
          hasSnapshot: false,
        ),
        isFalse,
      );
    });

    test('有本机历史顶着 → 不亮卡（顶部另给可点的重试提示）', () {
      expect(
        shouldShowChatOpenFailure(
          chatError: '订阅超时',
          sessionId: 's1',
          hasSnapshot: true,
        ),
        isFalse,
      );
    });

    test('草稿会话（没有 sessionId）→ 不亮卡', () {
      expect(
        shouldShowChatOpenFailure(
          chatError: 'x',
          sessionId: null,
          hasSnapshot: false,
        ),
        isFalse,
      );
    });
  });

  group('sessionReadyPlan（发送前的就绪闸门）', () {
    test('已经订上当前会话 → 立刻发，一秒不等', () {
      expect(
        sessionReadyPlan(sessionId: 's1', chatSid: 's1', openingSid: null),
        SessionReadyPlan.sendNow,
      );
      // 即便另有一次别的会话在打开，也不影响"当前这个能发"。
      expect(
        sessionReadyPlan(sessionId: 's1', chatSid: 's1', openingSid: 's2'),
        SessionReadyPlan.sendNow,
      );
    });

    test('正在打开同一个会话 → 等它落地（切桥/订阅在后台跑）', () {
      expect(
        sessionReadyPlan(sessionId: 's1', chatSid: null, openingSid: 's1'),
        SessionReadyPlan.awaitInflight,
      );
    });

    test('没订上也没在开 → 先开再发', () {
      expect(
        sessionReadyPlan(sessionId: 's1', chatSid: null, openingSid: null),
        SessionReadyPlan.openThenSend,
      );
      expect(
        sessionReadyPlan(sessionId: 's1', chatSid: 's0', openingSid: null),
        SessionReadyPlan.openThenSend,
      );
    });
  });
}
