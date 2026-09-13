import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/state/task_filters.dart';
import 'package:zremote/state/task_sort.dart';

void main() {
  group('taskActivityTs', () {
    test('优先 lastActivityAt，缺了退 updatedAt / createdAt', () {
      expect(taskActivityTs({'lastActivityAt': 30, 'updatedAt': 20}), 30);
      expect(taskActivityTs({'updatedAt': 20, 'createdAt': 10}), 20);
      expect(taskActivityTs({'createdAt': 10}), 10);
      expect(taskActivityTs({}), 0);
      expect(taskActivityTs({'lastActivityAt': 0, 'createdAt': 5}), 5);
      expect(taskActivityTs({'lastActivityAt': 'x'}), 0);
    });
  });

  group('sortTaskCards', () {
    test('置顶在前且组内按活跃时间倒序，其余同规则', () {
      final out = sortTaskCards([
        {'id': 'a', 'lastActivityAt': 100},
        {'id': 'p1', 'pinned': true, 'lastActivityAt': 1},
        {'id': 'b', 'lastActivityAt': 300},
        {'id': 'p2', 'pinned': true, 'lastActivityAt': 500},
        {'id': 'c'}, // 无时间戳 → 沉底
        {'id': 'd', 'lastActivityAt': 200},
      ]);
      // p2(500) > p1(1)：置顶组内也按活跃时间倒序。
      expect(out.map((t) => t['id']), ['p2', 'p1', 'b', 'd', 'a', 'c']);
    });

    test('updatedAt / createdAt 兜底参与排序', () {
      final out = sortTaskCards([
        {'id': 'a', 'createdAt': 100},
        {'id': 'b', 'updatedAt': 900},
        {'id': 'c', 'createdAt': 500},
      ]);
      expect(out.map((t) => t['id']), ['b', 'c', 'a']);
    });
  });

  group('parseTaskTokenUsage', () {
    test('num 直通；Map 取 totalTokens，cumulative/usage 兜底', () {
      expect(parseTaskTokenUsage(12345), 12345);
      expect(parseTaskTokenUsage({'totalTokens': 99}), 99);
      expect(parseTaskTokenUsage({'total': 88}), 88);
      expect(
        parseTaskTokenUsage({
          'cumulative': {'totalTokens': 77},
        }),
        77,
      );
      expect(
        parseTaskTokenUsage({
          'usage': {'total': 66},
        }),
        66,
      );
      expect(parseTaskTokenUsage({'totalTokens': 'x'}), isNull);
      expect(parseTaskTokenUsage({}), isNull);
      expect(parseTaskTokenUsage(null), isNull);
      expect(parseTaskTokenUsage('garbage'), isNull);
    });
  });

  group('tokenCountLabel', () {
    test('过万 x.x万、过亿 x.x亿，小数原样，空值给空', () {
      expect(tokenCountLabel(null), '');
      expect(tokenCountLabel(0), '');
      expect(tokenCountLabel(987), '987');
      expect(tokenCountLabel(9999), '9999');
      expect(tokenCountLabel(12345), '1.2万');
      expect(tokenCountLabel(123456789), '1.2亿');
    });
  });

  group('tokenFetchDue', () {
    final now = DateTime(2026, 9, 5, 14, 30);
    test('没拉过 → 必须拉', () {
      expect(tokenFetchDue(null, 'idle', now), isTrue);
    });

    test('运行中 30 秒过期，空闲 5 分钟过期', () {
      final s29 = now.subtract(const Duration(seconds: 29));
      final s31 = now.subtract(const Duration(seconds: 31));
      expect(tokenFetchDue(s29, 'running', now), isFalse);
      expect(tokenFetchDue(s31, 'running', now), isTrue);
      expect(tokenFetchDue(s31, 'prewarming', now), isTrue);

      final m4 = now.subtract(const Duration(minutes: 4));
      final m6 = now.subtract(const Duration(minutes: 6));
      expect(tokenFetchDue(m4, 'idle', now), isFalse);
      expect(tokenFetchDue(m6, 'idle', now), isTrue);
      expect(tokenFetchDue(m6, '', now), isTrue);
    });
  });

  group('taskTimeLabel', () {
    // 固定「现在」= 2026-09-05（周六）20:00，全部判定走本地日历日。
    final nowMs = DateTime(2026, 9, 5, 20, 0).millisecondsSinceEpoch;
    int ts(int y, int m, int d, [int h = 12, int min = 0]) =>
        DateTime(y, m, d, h, min).millisecondsSinceEpoch;

    test('今天给 HH:mm，昨天给「昨天」', () {
      expect(
        taskTimeLabel({'lastActivityAt': ts(2026, 9, 5, 9, 30)}, nowMs: nowMs),
        '09:30',
      );
      expect(
        taskTimeLabel({'lastActivityAt': ts(2026, 9, 4)}, nowMs: nowMs),
        '昨天',
      );
    });

    test('一周内给「周x」，更早同年给「M月d日」', () {
      expect(
        taskTimeLabel({'lastActivityAt': ts(2026, 9, 3)}, nowMs: nowMs),
        '周四',
      );
      expect(
        taskTimeLabel({'lastActivityAt': ts(2026, 8, 20)}, nowMs: nowMs),
        '8月20日',
      );
    });

    test('跨年给 yyyy/M/d', () {
      expect(
        taskTimeLabel({'lastActivityAt': ts(2025, 12, 31)}, nowMs: nowMs),
        '2025/12/31',
      );
    });

    test('缺时间戳给空；未来时间（时钟偏差）给空', () {
      expect(taskTimeLabel({}, nowMs: nowMs), '');
      expect(taskTimeLabel({'lastActivityAt': 0}, nowMs: nowMs), '');
      expect(
        taskTimeLabel({'lastActivityAt': ts(2026, 9, 5, 23, 0)}, nowMs: nowMs),
        '',
      );
    });
  });

  group('visibleTaskCards（筛选/查询/排序一站式）', () {
    final now = DateTime(2026, 9, 6, 20).millisecondsSinceEpoch;
    final tasks = [
      {'taskId': 'a', 'title': 'Banana', 'pinned': true, 'lastActivityAt': now - 3600 * 1000},
      {'taskId': 'b', 'title': 'apple', 'lastActivityAt': now - 1000},
      {'taskId': 'c', 'title': 'Cherry', 'createdAt': now - 100, 'lastActivityAt': now - 8 * 24 * 3600 * 1000},
      {'taskId': 'd', 'title': 'durian', 'lastActivityAt': now - 2 * 24 * 3600 * 1000},
    ];

    test('all + 最近更新排序', () {
      final out = visibleTaskCards(
        tasks,
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.lastActive,
        nowMs: now,
      );
      expect(out.map((t) => t['taskId']), ['a', 'b', 'd', 'c']);
    });

    test('pinned 只剩置顶；recent 只留 7 天内', () {
      final pinned = visibleTaskCards(
        tasks,
        filter: TaskFilter.pinned,
        query: '',
        sortKey: TaskSortKey.lastActive,
        nowMs: now,
      );
      expect(pinned.map((t) => t['taskId']), ['a']);
      final recent = visibleTaskCards(
        tasks,
        filter: TaskFilter.recent,
        query: '',
        sortKey: TaskSortKey.lastActive,
        nowMs: now,
      );
      expect(recent.map((t) => t['taskId']), ['a', 'b', 'd']);
    });

    test('query 大小写不敏感匹配标题/预览', () {
      final out = visibleTaskCards(
        tasks,
        filter: TaskFilter.all,
        query: 'APPL',
        sortKey: TaskSortKey.lastActive,
        nowMs: now,
      );
      expect(out.map((t) => t['taskId']), ['b']);
    });

    test('created / title 排序键', () {
      final byCreated = visibleTaskCards(
        tasks,
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.created,
        nowMs: now,
      );
      // 置顶恒最前：created/title 键也一样（a 置顶压过一切）。
      expect(byCreated.first['taskId'], 'a');
      final byTitle = visibleTaskCards(
        tasks,
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.title,
        nowMs: now,
      );
      expect(byTitle.map((t) => t['taskId']), ['a', 'b', 'c', 'd']);
    });

    test('archived 集合独立参与筛选', () {
      final out = visibleTaskCards(
        tasks,
        filter: TaskFilter.archived,
        query: '',
        sortKey: TaskSortKey.lastActive,
        archived: [
          {'taskId': 'z', 'title': 'arch', 'lastActivityAt': now - 500},
        ],
        nowMs: now,
      );
      expect(out.map((t) => t['taskId']), ['z']);
    });

    test('statusFilter=running 命中 running 与 prewarming', () {
      final out = visibleTaskCards(
        [
          {'taskId': 'r', 'title': 'R', 'phase': 'running'},
          {'taskId': 'w', 'title': 'W', 'phase': 'prewarming'},
          {'taskId': 'i', 'title': 'I', 'phase': 'idle'},
        ],
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.lastActive,
        statusFilter: TaskStatusFilter.running,
      );
      expect(out.map((t) => t['taskId']), ['r', 'w']);
    });

    test('statusFilter=error 命中 error 与 completedError', () {
      final out = visibleTaskCards(
        [
          {'taskId': 'e', 'title': 'E', 'phase': 'error'},
          {'taskId': 'ce', 'title': 'CE', 'phase': 'completedError'},
          {'taskId': 'ok', 'title': 'OK', 'phase': 'completedSuccess'},
        ],
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.lastActive,
        statusFilter: TaskStatusFilter.error,
      );
      expect(out.map((t) => t['taskId']), ['e', 'ce']);
    });

    test('statusFilter=waitingInput 只命中等输入；all 恒真', () {
      final pool = [
        {'taskId': 'wi', 'title': 'WI', 'phase': 'waitingInput'},
        {'taskId': 'i', 'title': 'I', 'phase': 'idle'},
      ];
      final waiting = visibleTaskCards(
        pool,
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.lastActive,
        statusFilter: TaskStatusFilter.waitingInput,
      );
      expect(waiting.map((t) => t['taskId']), ['wi']);
      final all = visibleTaskCards(
        pool,
        filter: TaskFilter.all,
        query: '',
        sortKey: TaskSortKey.lastActive,
        statusFilter: TaskStatusFilter.all,
      );
      expect(all.length, 2);
    });

    test('statusFilter 与 query 叠加生效', () {
      final out = visibleTaskCards(
        [
          {'taskId': 'r1', 'title': 'deploy web', 'phase': 'running'},
          {'taskId': 'r2', 'title': 'deploy api', 'phase': 'running'},
          {'taskId': 'r3', 'title': 'build web', 'phase': 'idle'},
        ],
        filter: TaskFilter.all,
        query: 'web',
        sortKey: TaskSortKey.lastActive,
        statusFilter: TaskStatusFilter.running,
      );
      expect(out.map((t) => t['taskId']), ['r1']);
    });
  });

  group('parseBootstrapTasks（bootstrap tasks[] → 跨项目任务卡）', () {
    test('直给任务对象：认 taskId，保留工作区字段', () {
      final out = parseBootstrapTasks([
        {'taskId': 'a', 'title': 'A', 'workspacePath': r'D:\w\one'},
        {'taskId': 'b', 'title': 'B', 'workspacePath': r'D:\w\two'},
      ]);
      expect(out, hasLength(2));
      expect(out[0]['taskId'], 'a');
      expect(taskProjectKey(out[0]), r'D:\w\one');
    });

    test('包装形态 {task:{...}, workspacePath}：外层工作区补进内层', () {
      final out = parseBootstrapTasks([
        {
          'task': {'taskId': 'a', 'title': 'A'},
          'workspacePath': r'D:\w\one',
        },
      ]);
      expect(out, hasLength(1));
      expect(out.first['title'], 'A');
      expect(taskProjectKey(out.first), r'D:\w\one');
    });

    test('id 别名 id / sessionId 也认，统一归一化成 taskId', () {
      final out = parseBootstrapTasks([
        {'id': 7, 'title': 'A'},
        {'sessionId': 's9', 'title': 'B'},
      ]);
      expect(out.map((t) => t['taskId']), ['7', 's9']);
    });

    test('认不出 id 的丢弃；非列表 / 脏元素安全', () {
      expect(parseBootstrapTasks(null), isEmpty);
      expect(parseBootstrapTasks('nope'), isEmpty);
      expect(
        parseBootstrapTasks([
          {'title': '没有 id'},
          'junk',
          {'taskId': 'ok'},
        ]).map((t) => t['taskId']),
        ['ok'],
      );
    });
  });

  group('taskProjectKey / taskProjectLabel（跨项目归属）', () {
    test('标识优先级 workspacePath > workspaceIdentity > workspaceKey', () {
      expect(
        taskProjectKey({
          'workspacePath': r'D:\a',
          'workspaceIdentity': 'id-1',
          'workspaceKey': 'k',
        }),
        r'D:\a',
      );
      expect(taskProjectKey({'workspaceIdentity': 'id-1'}), 'id-1');
      expect(taskProjectKey({'workspaceKey': 'k'}), 'k');
      expect(taskProjectKey({'workspacePath': '   '}), isNull);
      expect(taskProjectKey({}), isNull);
    });

    test('短标签取路径尾段，两种分隔符都认；对不出路径就原样返回', () {
      expect(taskProjectLabel(r'D:\tools\zremote-new'), 'zremote-new');
      expect(taskProjectLabel('/home/me/proj'), 'proj');
      expect(taskProjectLabel('plain-key'), 'plain-key');
      expect(taskProjectLabel(r'D:\tools\'), 'tools');
      expect(taskProjectLabel(''), '');
    });
  });

  group('BatchRenameSpec（批量重命名规则）', () {
    test('查找替换：全部替换，按字面量不当正则', () {
      const spec = BatchRenameSpec(find: '写', replace: '编');
      expect(spec.apply('z写'), 'z编');
      expect(spec.apply('写写读'), '编编读');
      // 正则元字符按字面量：. 只匹配真正的点
      const dot = BatchRenameSpec(find: '.', replace: '_');
      expect(dot.apply('a.b.c'), 'a_b_c');
      // * 同理，不是量词
      const star = BatchRenameSpec(find: '*', replace: 'x');
      expect(star.apply('a*'), 'ax');
    });

    test('替换为空串 = 删除；find==replace 不算规则', () {
      // apply 末尾 trim，所以删掉后缀留下的尾空格会被裁掉。
      expect(const BatchRenameSpec(find: 'test', replace: '').apply('a test'), 'a');
      expect(const BatchRenameSpec(find: 'test', replace: '').apply('test b'), 'b');
      expect(const BatchRenameSpec(find: 'a', replace: 'a').isNoop, isTrue);
    });

    test('前后缀：拼上且不重复加', () {
      const spec = BatchRenameSpec(prefix: '[P]', suffix: '[S]');
      expect(spec.apply('z写'), '[P]z写[S]');
      // 已有前缀/后缀不重复
      expect(spec.apply('[P]z写'), '[P]z写[S]');
      expect(spec.apply('z写[S]'), '[P]z写[S]');
    });

    test('组合应用顺序：先替换再拼前后缀', () {
      const spec = BatchRenameSpec(
        find: '旧',
        replace: '新',
        prefix: '#',
        suffix: '!',
      );
      expect(spec.apply('旧会话'), '#新会话!');
    });

    test('isNoop：空规则 / 无实际作用时为真', () {
      expect(const BatchRenameSpec().isNoop, isTrue);
      expect(const BatchRenameSpec(find: 'x', replace: 'x').isNoop, isTrue);
      expect(const BatchRenameSpec(find: 'x', replace: 'y').isNoop, isFalse);
      expect(const BatchRenameSpec(prefix: 'a').isNoop, isFalse);
    });

    test('结果两端空白被裁掉', () {
      expect(const BatchRenameSpec(find: 'x', replace: '').apply('x a x'), 'a');
    });
  });

  group('sweepDeletions（删除进行中 · 服务端对账）', () {
    final t0 = DateTime(2026, 9, 13, 12);
    late Map<String, DateTime> deleting;
    setUp(() {
      deleting = {
        'gone': t0.subtract(const Duration(minutes: 5)),
        'kept': t0.subtract(const Duration(minutes: 5)),
        'fresh': t0.subtract(const Duration(seconds: 2)),
      };
    });

    test('服务端没有 → 立即确认（不限宽限）；服务端还有且过宽限 → 恢复显示', () {
      final sweep = sweepDeletions(
        serverIds: ['kept'],
        deleting: deleting,
        now: t0,
      );
      // 'fresh' 虽刚发起，但服务端已经没有它 = 删得够快，直接确认。
      expect(sweep.confirmed, {'gone', 'fresh'});
      expect(sweep.restore, {'kept'});
    });

    test('未过宽限期的不裁决（RPC 还在路上，继续隐藏）', () {
      final sweep = sweepDeletions(
        serverIds: ['kept', 'fresh'],
        deleting: deleting,
        now: t0,
      );
      expect(sweep.confirmed.contains('fresh'), isFalse);
      expect(sweep.restore.contains('fresh'), isFalse);
    });

    test('服务端列表为空 = 全部确认删除（含刚发起的）', () {
      final sweep = sweepDeletions(
        serverIds: const <String>[],
        deleting: deleting,
        now: t0,
      );
      expect(sweep.confirmed, {'gone', 'kept', 'fresh'});
      expect(sweep.restore, isEmpty);
    });

    test('不改入参，由调用方按结果自行摘除', () {
      sweepDeletions(serverIds: const <String>[], deleting: deleting, now: t0);
      expect(deleting.length, 3);
    });
  });

  group('cardsSignature（索引帧微批的变化检测）', () {
    Map<String, dynamic> card(String id, {String phase = 'idle'}) => {
      'taskId': id,
      'title': '会话 $id',
      'phase': phase,
      'pinned': false,
      'lastActivityAt': 1000,
      'lastAssistantPreview': '预览',
    };

    test('内容相同 → 签名相同（不同 map 实例也算相同）', () {
      final a = [card('a'), card('b')];
      final b = [card('a'), card('b')];
      expect(cardsSignature(a), cardsSignature(b));
      expect(identical(a[0], b[0]), isFalse); // 确认是比值不是比引用
    });

    test('可见字段一变 → 签名就变（相位/标题/置顶/活跃时间/预览长度）', () {
      final base = cardsSignature([card('a')]);
      expect(cardsSignature([card('a', phase: 'running')]), isNot(base));
      expect(
        cardsSignature([
          {...card('a'), 'title': '改过名'},
        ]),
        isNot(base),
      );
      expect(
        cardsSignature([
          {...card('a'), 'pinned': true},
        ]),
        isNot(base),
      );
      expect(
        cardsSignature([
          {...card('a'), 'lastActivityAt': 2000},
        ]),
        isNot(base),
      );
      expect(
        cardsSignature([
          {...card('a'), 'pendingInteraction': {'x': 1}},
        ]),
        isNot(base),
      );
      expect(
        cardsSignature([
          {...card('a'), 'lastAssistantPreview': '更长的预览内容'},
        ]),
        isNot(base),
      );
    });

    test('成员增删 → 签名就变（列表本身要通知）', () {
      expect(
        cardsSignature([card('a'), card('b')]),
        isNot(cardsSignature([card('a')])),
      );
    });
  });

  group('tokenFetchTargets（首灌限流）', () {
    List<Map<String, dynamic>> cards(int n) => [
      for (var i = 0; i < n; i++)
        {'taskId': 't$i', 'phase': 'idle'},
    ];
    final now = DateTime(2026, 9, 13, 20);

    test('从没拉过的按预算限流，只补列表最前（= 最活跃）的那几张', () {
      final out = tokenFetchTargets(cards(41), {}, now: now, freshBudget: 12);
      expect(out.length, 12);
      expect(out.first['taskId'], 't0');
      expect(out.last['taskId'], 't11');
    });

    test('老卡片过期重拉不受预算限制（那是刷新不是首灌）', () {
      final fetched = <String, DateTime>{
        for (var i = 0; i < 41; i++) 't$i': now.subtract(const Duration(minutes: 6)),
      };
      final out = tokenFetchTargets(cards(41), fetched, now: now);
      expect(out.length, 41);
    });

    test('没过期的一个都不拉；运行中 30s 快档照旧', () {
      final fresh = <String, DateTime>{'t0': now.subtract(const Duration(seconds: 5))};
      expect(tokenFetchTargets(cards(1), fresh, now: now), isEmpty);
      final stale = <String, DateTime>{'t0': now.subtract(const Duration(seconds: 31))};
      expect(
        tokenFetchTargets([
          {'taskId': 't0', 'phase': 'running'},
        ], stale, now: now).length,
        1,
      );
    });

    test('没 id 的卡片跳过（不污染计数）', () {
      final out = tokenFetchTargets([
        {'phase': 'idle'},
        {'taskId': 'ok', 'phase': 'idle'},
      ], {}, now: now, freshBudget: 1);
      expect(out.length, 1);
      expect(out.single['taskId'], 'ok');
    });
  });
}
