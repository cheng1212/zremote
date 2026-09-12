// 用量页 widget 冒烟：探针形状数据渲染不崩 + 无数据空态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/app_controller.dart';
import 'package:zremote/ui/usage_page.dart';

Map<String, dynamic> _snapshot() => {
  'range': '7d',
  'generatedAt': 1788732156649,
  'timeZone': 'Asia/Shanghai',
  'source': 'agent-db',
  'summary': {
    'totalTokens': 1508005569,
    'inputTokens': 1502908931,
    'outputTokens': 5096638,
    'reasoningTokens': 395122,
    'cacheCreationTokens': 35573,
    'cacheReadTokens': 1209278656,
    'cacheHitRate': 0.8046,
    'totalSessions': 203,
    'totalTurns': 987,
    'toolCallCount': 9828,
    'toolErrorRate': 0.017,
    'modelErrorRate': 0.0486,
    'avgTimeToFirstTokenMs': 9667.1,
    'avgTurnDurationMs': 398933.77,
    'activeDays': 8,
    'currentStreakDays': 8,
    'longestSessionMs': 32345416,
    'longestStreakDays': 8,
    'peakDayTokens': 297651040,
    'favoriteModel': {
      'modelId': 'GLM-5.3-Flash',
      'totalTokens': 900000000,
      'share': 0.6,
    },
  },
  'heatmap': {'startDate': null, 'endDate': null, 'maxTokens': 1, 'weeks': []},
  'dailyModelUsage': [
    {
      'date': '2026-09-03',
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 1413556},
        {'modelId': 'minimax-m3', 'totalTokens': 56534},
      ],
    },
    {
      'date': '2026-09-04',
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 97000000},
        {'modelId': 'qwen3.8-flash', 'totalTokens': 70007403},
        {'modelId': 'minimax-m3', 'totalTokens': 43608149},
        {'modelId': 'nemotron-3-ultra', 'totalTokens': 47421},
        {'modelId': 'other-model', 'totalTokens': 99123},
      ],
    },
    {
      'date': '2026-09-05',
      'models': [
        {'modelId': 'qwen3.8-flash', 'totalTokens': 70007403},
      ],
    },
  ],
  'models': [
    {
      'modelId': 'zhipu/GLM-5.3-Flash',
      'totalTokens': 900000000,
      'inputTokens': 899000000,
      'outputTokens': 1000000,
      'requestCount': 522,
      'share': 0.6,
    },
    {
      'modelId': 'minimax-m3',
      'totalTokens': 43608149,
      'inputTokens': 43000000,
      'outputTokens': 608149,
      'requestCount': 88,
      'share': 0.03,
    },
  ],
  'tools': [],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('UsagePage renders probe-shaped snapshot', (tester) async {
    final app = ZApp();
    app.usageStats = _snapshot();
    await tester.pumpWidget(MaterialApp(home: UsagePage(app: app)));
    await tester.pumpAndSettle();
    expect(find.text('用量信息'), findsOneWidget);
    expect(find.text('总览'), findsOneWidget);
    // 模型明细在长列表尾部，滚到底再断言。
    await tester.scrollUntilVisible(
      find.text('模型明细'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('模型明细'), findsOneWidget);
  });

  testWidgets('UsagePage empty state when snapshot unusable', (tester) async {
    final app = ZApp();
    await tester.pumpWidget(MaterialApp(home: UsagePage(app: app)));
    await tester.pumpAndSettle();
    expect(find.text('暂时拿不到用量数据'), findsOneWidget);
  });
}
