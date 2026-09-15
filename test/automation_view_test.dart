// 定时任务会话标记（路线A）纯逻辑单测。
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/automation_view.dart';

AutomationView mk(String title) => AutomationView.fromMap({
  'automationId': 'a-${title.hashCode}',
  'title': title,
  'cronExpr': '*/3 * * * *',
  'prompt': '继续',
  'enabled': true,
  'lifecycleStatus': 'active',
  'recurring': true,
  'runCount': 0,
});

void main() {
  group('tagOfSession', () {
    test('sess_ 前缀取前 4 位 hex', () {
      expect(
        AutomationView.tagOfSession('sess_685ebfd2-511e-45d8-a5bd-30586a2e02fc'),
        '685e',
      );
    });
    test('大写 hex 归一小写', () {
      expect(AutomationView.tagOfSession('SESS_AB12CD34'), 'ab12');
    });
    test('非 sess_ 前缀取 id 前 4 位兜底', () {
      expect(AutomationView.tagOfSession('weird-id'), 'weir');
    });
    test('过短 id 不越界', () {
      expect(AutomationView.tagOfSession('ab'), 'ab');
      expect(AutomationView.tagOfSession(''), '');
    });
  });

  group('sessionTag 解析', () {
    test('标题尾带标记', () {
      expect(mk('每3分钟继续 @s685e').sessionTag, '685e');
    });
    test('标题中段带标记也能取到', () {
      expect(mk('每3分钟 @s12ab 继续').sessionTag, '12ab');
    });
    test('无标记返回 null', () {
      expect(mk('每3分钟提醒继续主线任务').sessionTag, isNull);
    });
    test('5 位 hex 不误吞（词边界）', () {
      expect(mk('任务 @s685e1').sessionTag, isNull);
    });
  });

  group('filterAutomationsBySession', () {
    final mine = mk('每3分钟继续 @s685e');
    final other = mk('10分钟后示例提醒 @s9abc');
    final legacy = mk('每3分钟提醒继续主线任务'); // 无标记旧任务
    final list = [mine, other, legacy];

    test('默认只留当前会话的（无标记旧任务被滤掉）', () {
      final out = filterAutomationsBySession(list, '685e');
      expect(out, [mine]);
    });
    test('showAll 返回全量', () {
      expect(filterAutomationsBySession(list, '685e', showAll: true), list);
    });
    test('curTag 为空退化为全量', () {
      expect(filterAutomationsBySession(list, null), list);
      expect(filterAutomationsBySession(list, ''), list);
    });
  });

  group('sessionIdsWithActiveAutomation', () {
    final autos = [
      {
        'automationId': 'a1',
        'title': '每3分钟继续 @s685e',
        'enabled': true,
        'targetTaskId': 'sess_685ebfd2-x',
      },
      {'automationId': 'a2', 'title': '旧任务无标记', 'enabled': true},
      {
        'automationId': 'a3',
        'title': '已暂停 @s9abc',
        'enabled': false,
        'targetTaskId': 'sess_9abc1111-x',
      },
      {
        'automationId': 'a4',
        'title': '按目标会话匹配',
        'enabled': true,
        'targetTaskId': 'sess_dead2222-x',
      },
    ];
    test('targetTaskId 命中即点亮（无标记也行）', () {
      expect(
        sessionIdsWithActiveAutomation(autos, [
          'sess_685ebfd2-x',
          'sess_dead2222-x',
        ]),
        {'sess_685ebfd2-x', 'sess_dead2222-x'},
      );
    });
    test('标记兜底仍然生效', () {
      expect(
        sessionIdsWithActiveAutomation(autos, ['sess_9abc1111-x']),
        isEmpty, // a3 暂停，标记命中但未启用不点亮
      );
      expect(
        sessionIdsWithActiveAutomation([
          {'automationId': 'a5', 'title': '老任务 @sab12', 'enabled': true},
        ], ['sess_ab123456-x']),
        {'sess_ab123456-x'},
      );
    });
    test('暂停的不点亮、无标记且无 target 的不点亮', () {
      expect(sessionIdsWithActiveAutomation(autos, ['sess_9abc1111-x']), isEmpty);
      expect(sessionIdsWithActiveAutomation(autos, ['sess_ffff0000-x']), isEmpty);
    });
    test('空任务列表返回空', () {
      expect(sessionIdsWithActiveAutomation(const [], ['sess_685e']), isEmpty);
    });
  });

  group('cronPresets', () {
    test('预设非空且 cron 均为 5 段', () {
      expect(cronPresets, isNotEmpty);
      cronPresets.forEach((label, expr) {
        expect(expr.split(' ').length, 5, reason: label);
      });
      expect(cronPresets['每3分钟'], '*/3 * * * *');
    });
  });
}
