import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/ui/suggestions.dart';

void main() {
  group('parseRowsRangeResult', () {
    test('List 直通 / Map.rows / Map.window / 垃圾值', () {
      final row = {'rowId': 1, 'kind': 'userInput'};
      expect(parseRowsRangeResult([row]), [row]);
      expect(parseRowsRangeResult({'rows': [row]}), [row]);
      expect(parseRowsRangeResult({'window': [row]}), [row]);
      expect(parseRowsRangeResult('junk'), isEmpty);
      expect(parseRowsRangeResult({'rows': ['x', row]}), [row]);
    });
  });

  group('ConversationState.mergeOlder / hasMoreOlder', () {
    test('mergeOlder: 去重、按 rowId 升序前置、更新 firstRowId', () {
      final st = ConversationState();
      st.rows = [
        {'rowId': 5, 'kind': 'userInput'},
        {'rowId': 6, 'kind': 'assistantText'},
      ];
      st.firstRowId = 5;
      st.totalCount = 8;
      st.loadingOlder = true;
      st.mergeOlder([
        {'rowId': 6, 'kind': 'dup'},
        {'rowId': 4, 'kind': 'a'},
        {'rowId': 3, 'kind': 'b'},
      ]);
      expect(st.rows.map((r) => r['rowId']).toList(), [3, 4, 5, 6]);
      expect(st.firstRowId, 3);
      expect(st.loadingOlder, false);
    });

    test('hasMoreOlder: rows.length < totalCount 且 firstRowId 非空', () {
      final st = ConversationState();
      expect(st.hasMoreOlder, false);
      st.firstRowId = 10;
      st.rows = [
        for (var i = 10; i < 15; i++) {'rowId': i},
      ];
      st.totalCount = 20;
      expect(st.hasMoreOlder, true);
      st.totalCount = 5;
      expect(st.hasMoreOlder, false);
    });
  });

  group('latestPlanPayload', () {
    test('plans 列表取最新一份 plan 载荷', () {
      final plan = {
        'todos': [
          {'content': 'a'},
        ],
      };
      expect(
        latestPlanPayload([
          {'planId': 'p1'},
          {'planId': 'p2', 'plan': plan},
        ]),
        plan,
      );
      expect(latestPlanPayload({'plans': [
        {'value': plan},
      ]}), plan);
      expect(latestPlanPayload({'plans': [
        {'todos': <String>[]},
      ]}), isNotNull);
      expect(latestPlanPayload(null), isNull);
      expect(latestPlanPayload({'plans': []}), isNull);
    });
  });

  group('buildSuggestions', () {
    test('/ 命令前缀过滤、\$ 技能、句中不提示、上限 8', () {
      final skills = [
        {'name': 'review'},
        {'name': 'deep-think', 'description': '慢思考'},
      ];
      final cmds = [
        {'command': 'fix'},
        {'name': 'init'},
      ];
      expect(buildSuggestions('/f', skills, cmds).single.token, '/fix');
      expect(buildSuggestions(r'$de', skills, cmds).single.token,
          r'$deep-think');
      expect(buildSuggestions(r'$de', skills, cmds).single.description,
          '慢思考');
      expect(buildSuggestions('hi /f', skills, cmds), isEmpty);
      expect(buildSuggestions('/', skills, cmds), isEmpty);
      expect(buildSuggestions('fix', skills, cmds), isEmpty);
      expect(
        buildSuggestions(r'$s', [
          for (var i = 0; i < 20; i++) {'name': 's$i'},
        ], const []).length,
        8,
      );
    });
  });
}
