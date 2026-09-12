import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';

/// BUG-31：定时消息（桌面端直接入队）在忙会话上堆出十几条一模一样的
/// 排队项。手机端拦不住入队，靠 ConvSubscription 的队列自动去重兜底；
/// 这里锁住判定纯函数的行为。
void main() {
  test('同一文本多条 → 保留队首，其余全部要删', () {
    final dup = duplicateQueueItemIds([
      {'queueItemId': 'q1', 'text': '提醒：不要停'},
      {'queueItemId': 'q2', 'text': '提醒：不要停'},
      {'queueItemId': 'q3', 'text': '提醒：不要停'},
      {'queueItemId': 'q4', 'text': '换个活干'},
    ]);
    expect(dup, ['q2', 'q3']);
  });

  test('trim 后相同也算重复（首尾空白不豁免）', () {
    final dup = duplicateQueueItemIds([
      {'queueItemId': 'a', 'text': '继续'},
      {'queueItemId': 'b', 'text': ' 继续 \n'},
    ]);
    expect(dup, ['b']);
  });

  test('不同文本互不干扰', () {
    expect(
      duplicateQueueItemIds([
        {'queueItemId': 'a', 'text': '继续'},
        {'queueItemId': 'b', 'text': '接着做'},
        {'queueItemId': 'c', 'text': '继续任务'},
      ]),
      isEmpty,
    );
  });

  test('空文本/缺 id 不参与去重（宁放过不误删）', () {
    expect(
      duplicateQueueItemIds([
        {'queueItemId': 'a', 'text': ''},
        {'queueItemId': 'b', 'text': '   '},
        {'text': '继续'},
        {'queueItemId': 'c', 'text': '继续'},
      ]),
      isEmpty,
    );
  });

  test('空队列 / 空列表恒空', () {
    expect(duplicateQueueItemIds(const []), isEmpty);
  });
}
