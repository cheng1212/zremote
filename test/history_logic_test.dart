import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/state/history_logic.dart';

void main() {
  group('olderRemaining（还有多少条更早）', () {
    test('总数减已加载；已抽干给 0', () {
      // 探针实测的真实数字：某会话 4083 行，快照给 60。
      expect(olderRemaining(loaded: 60, total: 4083), 4023);
      expect(olderRemaining(loaded: 4083, total: 4083), 0);
      // 已加载比总数还多（服务端计数滞后）不能变负数。
      expect(olderRemaining(loaded: 5000, total: 4083), 0);
    });
  });

  group('historyPullLabel（列表顶部入口文案）', () {
    test('还有更早的 → 报数并给入口', () {
      expect(
        historyPullLabel(loaded: 100, total: 4083),
        '还有 3983 条更早 · 点这里拉取全部',
      );
    });

    test('拉取中 → 换成进度', () {
      expect(
        historyPullLabel(loaded: 2400, total: 4083, pulling: true),
        '正在拉取 2400/4083…',
      );
    });

    test('已抽干 → 空串（入口整段隐藏）', () {
      expect(historyPullLabel(loaded: 4083, total: 4083), '');
      expect(
        historyPullLabel(loaded: 4083, total: 4083, pulling: true),
        '',
      );
    });
  });

  group('shouldKeepPulling（批量拉取的收手条件）', () {
    test('还有更早且这轮有进展 → 继续', () {
      expect(
        shouldKeepPulling(
          hasMoreOlder: true,
          loaded: 260,
          lastLoaded: 200,
          stallRounds: 0,
        ),
        isTrue,
      );
    });

    test('没有更早的了 → 停', () {
      expect(
        shouldKeepPulling(
          hasMoreOlder: false,
          loaded: 4083,
          lastLoaded: 4083,
          stallRounds: 0,
        ),
        isFalse,
      );
    });

    test('一轮 0 进账先再试一次（大页可能不被认），连丢两轮才收手', () {
      // 第一轮 0 进账：stall=1，还继续（下一轮会退回小页重试）
      expect(
        shouldKeepPulling(
          hasMoreOlder: true,
          loaded: 60,
          lastLoaded: 60,
          stallRounds: 1,
        ),
        isTrue,
      );
      // 第二轮还是 0：停，别死循环
      expect(
        shouldKeepPulling(
          hasMoreOlder: true,
          loaded: 60,
          lastLoaded: 60,
          stallRounds: 2,
        ),
        isFalse,
      );
    });

    test('这轮有进展就重置 stall 计数（不会因为历史卡顿误停）', () {
      expect(
        shouldKeepPulling(
          hasMoreOlder: true,
          loaded: 120,
          lastLoaded: 60,
          stallRounds: 1,
        ),
        isTrue,
      );
    });
  });
}
