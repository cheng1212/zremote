import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/usage_stats.dart';

/// 探针实测响应的最小还原（usage-stats.getAppUsageSnapshot, range=7d）。
Map<String, dynamic> _probeShape() => {
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
    'cacheHitRate': 0.8046253708768466,
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
  'heatmap': {
    'startDate': '2026-08-31',
    'endDate': '2026-09-07',
    'maxTokens': 297651040,
    'weeks': [],
  },
  'dailyModelUsage': [
    {
      'date': '2026-09-03',
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 1413556},
        {'modelId': 'minimax-m3', 'totalTokens': 56534},
      ],
    },
    {
      'date': '2026-09-01',
      'models': [
        {'modelId': 'qwen3.8-flash', 'totalTokens': 70007403},
      ],
    },
    {
      'date': '2026-09-02',
      'models': [
        {'modelId': 'minimax-m3', 'totalTokens': 0},
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
      'modelId': 'nemotron-3-ultra',
      'totalTokens': 0,
      'inputTokens': 0,
      'outputTokens': 0,
      'requestCount': 0,
      'share': 0,
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
  'tools': [
    {
      'toolName': 'bash',
      'callCount': 120,
      'errorCount': 2,
      'errorRate': 0.0167,
      'avgDurationMs': 1500,
    },
  ],
};

void main() {
  group('parseUsageStats', () {
    test('探针还原形状完整解析', () {
      final v = parseUsageStats(_probeShape());
      expect(v, isNotNull);
      expect(v!.range, '7d');
      expect(v.timeZone, 'Asia/Shanghai');
      expect(v.generatedAt, 1788732156649);
      expect(v.summary.totalTokens, 1508005569);
      expect(v.summary.cacheHitRate, closeTo(0.8046, 1e-3));
      expect(v.summary.totalSessions, 203);
      expect(v.summary.avgTimeToFirstTokenMs, 9667);
      expect(v.summary.favoriteModelId, 'GLM-5.3-Flash');
    });

    test('非 Map / 缺 summary / summary 非法给 null', () {
      expect(parseUsageStats(null), isNull);
      expect(parseUsageStats('nope'), isNull);
      expect(parseUsageStats([1, 2]), isNull);
      expect(parseUsageStats({'range': '7d'}), isNull);
      expect(parseUsageStats({'summary': 'bad'}), isNull);
    });

    test('空 summary 各数值兜底为 0 / null，不崩', () {
      final v = parseUsageStats({'summary': <String, dynamic>{}});
      expect(v, isNotNull);
      expect(v!.summary.totalTokens, 0);
      expect(v.summary.cacheHitRate, isNull);
      expect(v.summary.avgTurnDurationMs, isNull);
      expect(v.summary.favoriteModelId, '');
      expect(v.models, isEmpty);
      expect(v.daily, isEmpty);
    });
  });

  group('UsageStatsView.fromMap', () {
    test('models 按 token 量降序，daily 按日期升序', () {
      final v = parseUsageStats(_probeShape())!;
      expect(v.models.first.modelId, 'zhipu/GLM-5.3-Flash');
      expect(v.models.map((m) => m.modelId).toList(), [
        'zhipu/GLM-5.3-Flash',
        'minimax-m3',
        'nemotron-3-ultra', // 0 token 也保留（解析层不丢，展示层过滤）
      ]);
      expect(v.daily.map((d) => d.date).toList(), [
        '2026-09-01',
        '2026-09-02',
        '2026-09-03',
      ]);
    });

    test('modelId 为 null 时兜底空串，字段非法兜底 0', () {
      final v = parseUsageStats({
        'summary': {'totalTokens': 5},
        'models': [
          {
            'modelId': null,
            'totalTokens': 'bad',
            'requestCount': -3,
            'share': 1.5,
          },
        ],
        'dailyModelUsage': [
          {
            'date': '2026-09-01',
            'models': [
              {'modelId': null, 'totalTokens': 100},
            ],
          },
          {'date': 'bad', 'models': 'not-a-list'},
        ],
      })!;
      expect(v.models.single.modelId, '');
      expect(v.models.single.totalTokens, 0);
      expect(v.models.single.requestCount, 0);
      expect(v.models.single.share, 0); // 超界 share 不采信
      expect(v.daily.first.totalTokens, 100);
      expect(v.daily.last.models, isEmpty);
    });
  });

  group('usageRangeLabel', () {
    test('all/7d/30d 译中文，未知原样', () {
      expect(usageRangeLabel('all'), '全部');
      expect(usageRangeLabel('7d'), '近 7 天');
      expect(usageRangeLabel('30d'), '近 30 天');
      expect(usageRangeLabel('90d'), '90d');
    });
  });

  group('usageDayLabel', () {
    test('yyyy-MM-dd → M月d日，坏格式原样', () {
      expect(usageDayLabel('2026-09-07'), '9月7日');
      expect(usageDayLabel('2026-12-25'), '12月25日');
      expect(usageDayLabel('bad'), 'bad');
      expect(usageDayLabel(''), '');
    });
  });

  group('deviceTimeZoneLabel', () {
    test('正负偏移与零偏移', () {
      expect(
        deviceTimeZoneLabel(offset: const Duration(hours: 8)),
        'GMT+08:00',
      );
      expect(
        deviceTimeZoneLabel(offset: const Duration(hours: -5, minutes: -30)),
        'GMT-05:30',
      );
      expect(deviceTimeZoneLabel(offset: Duration.zero), 'GMT+00:00');
      // UTC 时间恒为 0 偏移，跨时区机器测试也稳定。
      expect(deviceTimeZoneLabel(now: DateTime.utc(2026, 9, 7)), 'GMT+00:00');
    });
  });

  group('buildUsageTrendChart', () {
    test('前 topN 模型 + 其他桶，全 0 日剔除，stacks 累计衔接', () {
      final v = parseUsageStats(_probeShape())!;
      final chart = buildUsageTrendChart(v.daily, topN: 1);
      // 全期总量第一是 qwen3.8-flash（7000万 > 141万+5.6万）。
      expect(chart.modelIds, ['qwen3.8-flash', '__other__']);
      // 2026-09-02 全 0 日不占柱位。
      expect(chart.dayLabels, ['9月1日', '9月3日']);
      expect(chart.stacks.length, 2);
      // 9月1日：单系列值即总量。
      expect(chart.stacks[0][0], 70007403);
      expect(chart.stacks[0][1], 0);
      // 9月3日：glm+minimax 归入「其他」。
      expect(chart.stacks[1][0], 0);
      expect(chart.stacks[1][1], closeTo(1413556 + 56534, 1e-6));
    });

    test('空数据 / 空 daily 不给柱', () {
      expect(buildUsageTrendChart(const []).dayLabels, isEmpty);
      final empty = parseUsageStats({
        'summary': {'totalTokens': 1},
        'dailyModelUsage': [
          {
            'date': '2026-09-01',
            'models': [
              {'modelId': 'a', 'totalTokens': 0},
            ],
          },
        ],
      })!;
      expect(buildUsageTrendChart(empty.daily).dayLabels, isEmpty);
    });
  });
  group('usageWindowForChoice（预设→窗口+服务端range）', () {
    final tue = DateTime(2026, 9, 8); // 周二
    test('今天：单日窗口，拉 7d 覆盖', () {
      final r = usageWindowForChoice(UsageRangeChoiceKind.today, today: tue);
      expect(r.window.startDay, '2026-09-08');
      expect(r.window.endDay, '2026-09-08');
      expect(r.serverRange, '7d');
    });

    test('近 3 天：含今天共 3 天，拉 7d', () {
      final r = usageWindowForChoice(
        UsageRangeChoiceKind.threeDays,
        today: tue,
      );
      expect(r.window.startDay, '2026-09-06');
      expect(r.window.endDay, '2026-09-08');
      expect(r.serverRange, '7d');
    });

    test('近 30 天拉 30d；全部拉 all', () {
      expect(
        usageWindowForChoice(UsageRangeChoiceKind.thirtyDays, today: tue).serverRange,
        '30d',
      );
      expect(
        usageWindowForChoice(UsageRangeChoiceKind.all, today: tue).serverRange,
        'all',
      );
    });
  });

  group('sliceUsage（日期切片+模型筛选+占比重算）', () {
    late UsageStatsView view;
    setUp(() {
      view = parseUsageStats({
        'range': 'all',
        'summary': {'totalTokens': 900},
        'models': [],
        'dailyModelUsage': [
          {
            'date': '2026-09-06',
            'models': [
              {'modelId': 'glm', 'totalTokens': 100},
              {'modelId': 'nv', 'totalTokens': 200},
            ],
          },
          {
            'date': '2026-09-07',
            'models': [
              {'modelId': 'glm', 'totalTokens': 300},
            ],
          },
          {
            'date': '2026-09-08',
            'models': [
              {'modelId': 'nv', 'totalTokens': 350},
              {'modelId': 'qwen', 'totalTokens': 50},
            ],
          },
        ],
      })!;
    });

    test('日期切片只保留窗口内天，总量/占比重算', () {
      final slice = sliceUsage(
        view,
        const UsageDayWindow(startDay: '2026-09-07', endDay: '2026-09-08'),
      );
      expect(slice.daily, hasLength(2));
      expect(slice.totalTokens, 700);
      expect(slice.models.first.modelId, 'nv');
      expect(slice.models.first.share, closeTo(350 / 700, 1e-9));
      expect(slice.activeDays, 2);
    });

    test('模型筛选独立生效（可叠加日期）', () {
      final slice = sliceUsage(
        view,
        const UsageDayWindow(startDay: '2026-09-06', endDay: '2026-09-08'),
        selectedModels: {'glm'},
      );
      expect(slice.totalTokens, 400);
      expect(slice.models, hasLength(1));
      expect(slice.models.first.modelId, 'glm');
    });

    test('窗口外/空筛选安全兜底', () {
      expect(
        sliceUsage(
          view,
          const UsageDayWindow(startDay: '2020-01-01', endDay: '2020-01-02'),
        ).totalTokens,
        0,
      );
      expect(
        sliceUsage(
          view,
          const UsageDayWindow(startDay: '2026-09-06', endDay: '2026-09-08'),
          selectedModels: {'nonexistent'},
        ).models,
        isEmpty,
      );
    });
  });

  group('filterUsageModels（仅模型维度）', () {
    test('空集=原样全量（保留服务端 summary 字段）', () {
      final view = parseUsageStats({
        'range': '7d',
        'summary': {'totalTokens': 500, 'activeDays': 3},
        'models': [
          {'modelId': 'glm', 'totalTokens': 500},
        ],
        'dailyModelUsage': [],
      })!;
      final slice = filterUsageModels(view, {});
      expect(slice.totalTokens, 500);
      expect(slice.activeDays, 3);
    });
  });
}
