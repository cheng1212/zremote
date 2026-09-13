import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/channel_client.dart';

import 'package:zremote/state/activity_view.dart';
import 'package:zremote/state/notification_logic.dart';
import 'package:zremote/ui/composer_logic.dart';

void main() {
  group('modeLabel', () {
    test('build/plan 译成中文，空串给默认，未知值原样返回', () {
      expect(modeLabel('build'), '构建');
      expect(modeLabel('plan'), '计划');
      expect(modeLabel(''), '构建');
      expect(modeLabel('chat'), 'chat');
    });
  });

  group('contextUsageRatio', () {
    test('正常比例、缺数据、max 为 0、超界钳制到 1', () {
      expect(contextUsageRatio(null), isNull);
      expect(contextUsageRatio({}), isNull);
      expect(
        contextUsageRatio({
          'contextWindow': {'maxTokens': 0, 'usedTokens': 100},
        }),
        isNull,
      );
      expect(
        contextUsageRatio({
          'contextWindow': {'maxTokens': 1000, 'usedTokens': 320},
        }),
        closeTo(0.32, 1e-9),
      );
      expect(
        contextUsageRatio({
          'contextWindow': {'maxTokens': 1000, 'usedTokens': 5000},
        }),
        1.0,
      );
      // usedTokens 缺失按 0 算，不算缺数据。
      expect(
        contextUsageRatio({
          'contextWindow': {'maxTokens': 1000},
        }),
        0.0,
      );
    });
  });

  group('splitModelValue', () {
    test('provider/model 拆开；多段斜杠只切最后一个；无斜杠两边同值', () {
      expect(splitModelValue('zhipu/GLM-5'), ('zhipu', 'GLM-5'));
      expect(splitModelValue('a/b/c'), ('a/b', 'c'));
      expect(splitModelValue('glm-5.3'), ('glm-5.3', 'glm-5.3'));
      expect(splitModelValue(''), ('', ''));
    });
  });

  group('fileSizeLabel', () {
    test('MB 保留一位小数，KB 取整，非正数给空', () {
      expect(fileSizeLabel(512), '1 KB'); // 0.5KB 四舍五入
      expect(fileSizeLabel(2048), '2 KB');
      expect(fileSizeLabel(1536 * 1024), '1.5 MB');
      expect(fileSizeLabel(0), '');
      expect(fileSizeLabel(-5), '');
    });
  });

  group('isImageExt', () {
    test('常见图片扩展名（已转小写）', () {
      for (final ext in ['png', 'jpg', 'jpeg', 'gif', 'webp']) {
        expect(isImageExt(ext), isTrue, reason: ext);
      }
      expect(isImageExt('PNG'), isTrue);
      expect(isImageExt('pdf'), isFalse);
      expect(isImageExt(''), isFalse);
    });
  });

  Uint8List bytesOf(List<int> l) => Uint8List.fromList(l);

  group('sniffImageMime（魔数嗅探图片 mime）', () {
    test('PNG/JPEG/GIF/WEBP 魔数各识别为对应 mime', () {
      // PNG: 89 50 4E 47 0D 0A 1A 0A
      expect(
        sniffImageMime(
          bytesOf([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        'image/png',
      );
      // JPEG: FF D8 FF
      expect(sniffImageMime(bytesOf([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      // GIF87a / GIF89a
      expect(
        sniffImageMime(bytesOf([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        'image/gif',
      );
      // WEBP: RIFF....WEBP
      expect(
        sniffImageMime(
          bytesOf([
            0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, //
            0x57, 0x45, 0x42, 0x50, 0x00, 0x00,
          ]),
        ),
        'image/webp',
      );
    });
    test('非图片字节/空/null 给 null；PDF 魔数不算图', () {
      expect(sniffImageMime(null), isNull);
      expect(sniffImageMime(bytesOf([])), isNull);
      expect(sniffImageMime(bytesOf([0x25, 0x50, 0x44, 0x46])), isNull); // %PDF
      expect(sniffImageMime(bytesOf([0x01, 0x02, 0x03, 0x04])), isNull);
    });
    test('RIFF 但不是 WEBP（wav/avi 前缀）给 null', () {
      expect(
        sniffImageMime(
          bytesOf([
            0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, //
            0x57, 0x41, 0x56, 0x45, 0x00, 0x00,
          ]),
        ),
        isNull,
      );
    });
  });

  group('attachmentIsImage（附件按图片渲染的口径）', () {
    test('mime 前缀 image/ 优先（三种字段名都认）', () {
      expect(attachmentIsImage({'mime': 'image/png'}), isTrue);
      expect(attachmentIsImage({'mediaType': 'image/jpeg'}), isTrue);
      expect(attachmentIsImage({'mimeType': 'image/webp'}), isTrue);
      expect(attachmentIsImage({'mime': 'application/pdf'}), isFalse);
    });
    test('mime 缺失时按文件名扩展名兜底', () {
      expect(attachmentIsImage({'fileName': 'IMG_001.JPG'}), isTrue);
      expect(attachmentIsImage({'name': 'shot.webp'}), isTrue);
      expect(attachmentIsImage({'fileName': 'doc.pdf'}), isFalse);
      expect(attachmentIsImage({'fileName': 'noext'}), isFalse);
      expect(attachmentIsImage({}), isFalse);
    });
  });

  group('followupLabel', () {
    test('guide 译「引导」，其余（含缺省）按「排队」', () {
      expect(followupLabel('guide'), '引导');
      expect(followupLabel('queue'), '排队');
      expect(followupLabel(''), '排队');
      expect(followupLabel('unknown'), '排队');
    });
  });

  group('permissionOptionLabel', () {
    test('label 优先，其次 kind 兜底，最后 optionId', () {
      expect(permissionOptionLabel({'label': '只此一次'}), '只此一次');
      expect(permissionOptionLabel({'kind': 'allowOnce'}), '允许一次');
      expect(permissionOptionLabel({'kind': 'allowAlways'}), '总是允许');
      expect(permissionOptionLabel({'kind': 'deny'}), '拒绝');
      expect(permissionOptionLabel({'kind': 'custom'}), '自定义');
      expect(permissionOptionLabel({'optionId': 'opt-9'}), 'opt-9');
      expect(permissionOptionLabel({}), '选择');
    });
  });

  group('describeFileChange', () {
    test('路径多字段兜底，动作译中文，增删统计拼接；无路径给 null', () {
      expect(
        describeFileChange({
          'path': 'lib/a.dart',
          'changeType': 'created',
          'additions': 12,
          'deletions': 3,
        }),
        ('lib/a.dart', '新建', '+12 -3'),
      );
      expect(describeFileChange({'file': 'b.txt', 'status': 'deleted'}), (
        'b.txt',
        '删除',
        '',
      ));
      expect(describeFileChange({'filePath': 'c.md'}), ('c.md', '修改', ''));
      expect(describeFileChange({'additions': 5}), isNull);
      expect(
        describeFileChange({'path': '', 'changeType': 'modified'}),
        isNull,
      );
    });
  });

  group('visibleEchoes', () {
    List<Map<String, dynamic>> rowsOf(List<String> texts) => [
      for (final t in texts) {'kind': 'userInput', 'text': t, 'rowId': 1},
    ];

    test('文本被服务端行确认后回显同帧移除，未确认的保留', () {
      final echoes = [
        {'text': '你好', 'status': 'sent'},
        {'text': '在吗', 'status': 'sending'},
      ];
      final out = visibleEchoes(echoes, rowsOf(['你好']));
      expect(out, hasLength(1));
      expect(out.first['text'], '在吗');
    });

    test('同文多发：按次数对账，不误删第二条', () {
      final echoes = [
        {'text': 'ok', 'status': 'sent'},
        {'text': 'ok', 'status': 'sent'},
      ];
      final out = visibleEchoes(echoes, rowsOf(['ok']));
      expect(out, hasLength(1));
    });

    test('失败的回显永远保留（供重试）', () {
      final echoes = [
        {'text': '你好', 'status': 'failed', 'error': '超时'},
      ];
      final out = visibleEchoes(echoes, rowsOf(['你好']));
      expect(out, hasLength(1));
    });

    test('带附件回显：全部 ref 都在服务端行里才算送达；纯图无文字也按 ref 对', () {
      final echoes = [
        {
          'text': '',
          'status': 'sent',
          'attachments': [
            {'ref': 'att-1'},
            {'ref': 'att-2'},
          ],
        },
      ];
      final partial = visibleEchoes(echoes, [
        {
          'kind': 'userInput',
          'text': '',
          'attachments': [
            {'ref': 'att-1'},
          ],
        },
      ]);
      expect(partial, hasLength(1)); // att-2 没确认 → 保留
      final done = visibleEchoes(echoes, [
        {
          'kind': 'userInput',
          'text': '',
          'attachments': [
            {'ref': 'att-1'},
            {'ref': 'att-2'},
          ],
        },
      ]);
      expect(done, isEmpty);
    });
  });

  group('friendlySendError', () {
    test('超时类 → 网络超时', () {
      expect(friendlySendError('TimeoutException: bridge 恢复超时'), '网络超时，点击重试');
      expect(friendlySendError('等待响应超时'), '网络超时，点击重试');
    });

    test('SocketException 类 → 网络连接失败', () {
      expect(
        friendlySendError('SocketException: Connection refused (os error)'),
        '网络连接失败，点击重试',
      );
    });

    test('服务端拒绝（ChannelRpcError）→ 统一主文案，详情另示', () {
      expect(
        friendlySendError('ChannelRpcError: {"message":"busy"}'),
        '服务端拒绝了这次发送',
      );
    });

    test('已是人话的错误原样透传，其余兜底通用文案', () {
      expect(friendlySendError('桥未就绪，请返回重进'), '桥未就绪，请返回重进');
      expect(friendlySendError('xx.png: 文件不可读'), '发送失败，点击重试');
      expect(friendlySendError(''), '发送失败，点击重试');
    });
  });

  group('friendlySwitchError（项目切换失败人话化）', () {
    test('运行时未启动（本次事故原文）→ 指路到桌面端', () {
      expect(
        friendlySwitchError(
          'ChannelRpcError: ZCode Agent runtime is not running.',
        ),
        '这个项目在桌面端还没启动，先去桌面端打开它一次再切回来',
      );
    });

    test('桥错误 / 超时 / 断线各有说法', () {
      expect(
        friendlySwitchError('StateError: workspace-bridge-error: closed'),
        '桌面端没打开这个项目，先去桌面端打开它',
      );
      expect(friendlySwitchError('TimeoutException: 30s'), '切换超时了，再试一次');
      expect(
        friendlySwitchError('SocketException: Connection refused'),
        '连接已断开，重新连接后再切项目',
      );
    });

    test('其余 ChannelRpcError 与未知错误兜底', () {
      expect(
        friendlySwitchError('ChannelRpcError: {"message":"busy"}'),
        '服务端拒绝了这次切换',
      );
      expect(friendlySwitchError(''), '切换失败，再试一次');
    });

    test('原始异常不再原样透出（回归护栏）', () {
      final msg = friendlySwitchError(
        'ChannelRpcError: ZCode Agent runtime is not running.',
      );
      expect(msg.contains('ChannelRpcError'), isFalse);
      expect(msg.contains('runtime is not running'), isFalse);
    });
  });

  group('codeBlockPreview', () {
    test('短代码原样返回，不加提示', () {
      expect(codeBlockPreview('print(1)'), 'print(1)');
      expect(codeBlockPreview(''), '');
      expect(
        codeBlockPreview('a' * maxCodeBlockChars),
        'a' * maxCodeBlockChars,
      );
    });

    test('超长载荷截断到阈值并附提示行，复制语义不受影响', () {
      final huge = 'x' * (maxCodeBlockChars + 5000);
      final preview = codeBlockPreview(huge);
      expect(preview.length, lessThan(huge.length));
      expect(preview.startsWith('x' * maxCodeBlockChars), isTrue);
      expect(preview.contains('共 ${huge.length} 字符'), isTrue);
      expect(preview.contains('已截断展示'), isTrue);
    });
  });

  group('sessionModelMatches（新会话模型放行闸门）', () {
    test('模型一致即通过，provider 请求为空时只看 model', () {
      expect(
        sessionModelMatches(
          curProvider: 'p1',
          curModel: 'nv-nemotron-ultra',
          wantProvider: '',
          wantModel: 'nv-nemotron-ultra',
        ),
        isTrue,
      );
    });

    test('请求了 provider 时必须一致，防止被回退到别的供应商', () {
      expect(
        sessionModelMatches(
          curProvider: 'other-provider',
          curModel: 'nv-nemotron-ultra',
          wantProvider: '7f3a9c21',
          wantModel: 'nv-nemotron-ultra',
        ),
        isFalse,
      );
      expect(
        sessionModelMatches(
          curProvider: '7f3a9c21',
          curModel: 'nv-nemotron-ultra',
          wantProvider: '7f3a9c21',
          wantModel: 'nv-nemotron-ultra',
        ),
        isTrue,
      );
    });

    test('模型不一致或请求模型为空一律不通过', () {
      expect(
        sessionModelMatches(
          curProvider: 'p',
          curModel: 'qwen3.8-flash',
          wantProvider: 'p',
          wantModel: 'nv-nemotron-ultra',
        ),
        isFalse,
      );
      expect(
        sessionModelMatches(
          curProvider: 'p',
          curModel: 'nv-nemotron-ultra',
          wantProvider: 'p',
          wantModel: '',
        ),
        isFalse,
      );
    });
  });

  group('thoughtLevelLabel（思考等级中文标签）', () {
    test('已知 id 全覆盖', () {
      expect(thoughtLevelLabel('max'), '最高');
      expect(thoughtLevelLabel('high'), '高');
      expect(thoughtLevelLabel('medium'), '中');
      expect(thoughtLevelLabel('low'), '低');
      expect(thoughtLevelLabel('nothink'), '不思考');
      expect(thoughtLevelLabel('enabled'), '开启思考');
      expect(thoughtLevelLabel('disabled'), '关闭思考');
      expect(thoughtLevelLabel('off'), '关闭思考');
    });

    test('未知 id 原样返回', () {
      expect(thoughtLevelLabel('turbo'), 'turbo');
      expect(thoughtLevelLabel(''), '');
    });
  });

  group('usageCacheSummary（缓存命中率摘要）', () {
    test('服务端字段直出，非法/缺失给 null', () {
      final s = usageCacheSummary({
        'latestHitRate': 0.9966,
        'hitRate': 0.5487,
        'hitRateRequestCount': 522,
        'totalInputTokens': 140336498,
      })!;
      expect(s.latest, closeTo(0.9966, 1e-9));
      expect(s.average, closeTo(0.5487, 1e-9));
      expect(s.requests, 522);
      expect(usageCacheSummary({}), isNull);
      expect(usageCacheSummary(null), isNull);
      expect(usageCacheSummary({'latestHitRate': 1.5})?.latest, isNull);
    });

    test('全空字段返回 null（调用方整卡隐藏）', () {
      expect(usageCacheSummary({'inputTokens': 100}), isNull);
    });
  });

  group('contextBreakdownRows（上下文构成）', () {
    test('按字符数降序，占比以合计为分母，来源转中文标签', () {
      final rows = contextBreakdownRows([
        {'source': 'messages', 'chars': 1716591},
        {'source': 'mcp_tool_schemas', 'chars': 120837},
        {'source': 'system_prompt', 'chars': 7808},
      ]);
      expect(rows, hasLength(3));
      expect(rows[0].$1, '对话内容');
      expect(rows[0].$2, 1716591);
      expect(rows[0].$3, closeTo(1716591 / 1845236, 1e-9));
      expect(rows[1].$1, 'MCP 工具定义');
      expect(rows[2].$1, '系统提示');
    });

    test('非列表/空/非法项安全兜底', () {
      expect(contextBreakdownRows(null), isEmpty);
      expect(contextBreakdownRows([]), isEmpty);
      expect(
        contextBreakdownRows([
          {'source': 'messages', 'chars': 0},
          'junk',
          {'chars': 100},
        ]),
        isEmpty,
      );
    });
  });

  group('briefRpcError（RPC 错误人话化）', () {
    test('zod 校验错误数组提取 message', () {
      final e = ChannelRpcError(
        '[{"expected":"object","code":"invalid_type","path":["target"],'
        '"message":"Invalid input: expected object, received undefined"},'
        '{"message":"second"}]',
      );
      expect(
        briefRpcError(e),
        'Invalid input: expected object, received undefined；second',
      );
    });

    test('普通错误截断 140 字符，短错误原样', () {
      expect(briefRpcError(StateError('boom')), 'Bad state: boom');
      final long = StateError('x' * 300);
      final out = briefRpcError(long);
      expect(out.length, lessThan(160));
      expect(out.endsWith('…'), isTrue);
      expect(briefRpcError(null), '未知错误');
    });
  });

  group('detectPollTaskEvent（全局轮询变迁判定，跨项目通知）', () {
    test('running → completed / error 报 完成/报错', () {
      expect(
        detectPollTaskEvent('running', 'completed')!.title,
        '任务完成',
      );
      expect(detectPollTaskEvent('running', 'error')!.title, '任务报错');
      // 终结类共用去重键（end）
      expect(
        detectPollTaskEvent('running', 'completed')!.dedupeKey,
        detectPollTaskEvent('running', 'error')!.dedupeKey,
      );
    });

    test('首帧（prev=null）与静止态变迁一律不响', () {
      expect(detectPollTaskEvent(null, 'completed'), isNull);
      expect(detectPollTaskEvent('completed', 'error'), isNull);
      expect(detectPollTaskEvent('error', 'completed'), isNull);
      expect(detectPollTaskEvent('running', 'running'), isNull);
      expect(detectPollTaskEvent('completed', 'completed'), isNull);
    });
  });

  group('detectTaskEvent（通知变迁判定）', () {    test('活跃态离开才报完成/中断/报错', () {
      expect(
        detectTaskEvent(
          'running',
          'completedSuccess',
          prevWaiting: false,
          nextWaiting: false,
        )!.kind,
        TaskEventKind.completed,
      );
      expect(
        detectTaskEvent(
          'prewarming',
          'completedInterrupted',
          prevWaiting: false,
          nextWaiting: false,
        )!.kind,
        TaskEventKind.interrupted,
      );
      expect(
        detectTaskEvent(
          'running',
          'error',
          prevWaiting: false,
          nextWaiting: false,
        )!.kind,
        TaskEventKind.error,
      );
    });

    test('首帧(prev=null)与静止态之间不响', () {
      expect(
        detectTaskEvent(
          null,
          'completedSuccess',
          prevWaiting: false,
          nextWaiting: false,
        ),
        isNull,
      );
      expect(
        detectTaskEvent(
          'completedSuccess',
          'error',
          prevWaiting: false,
          nextWaiting: false,
        ),
        isNull,
      );
    });

    test('等待确认：新出现才响，持续挂着不重复响', () {
      expect(
        detectTaskEvent(
          'running',
          'running',
          prevWaiting: false,
          nextWaiting: true,
        )!.kind,
        TaskEventKind.waitingInput,
      );
      expect(
        detectTaskEvent(
          'running',
          'running',
          prevWaiting: true,
          nextWaiting: true,
        ),
        isNull,
      );
    });

    test('hint 文案全覆盖', () {
      for (final k in TaskEventKind.values) {
        expect(taskEventHint(k), isNotEmpty);
      }
    });
  });

  group('parseBackgroundWorks（后台任务解析）', () {
    test('workId 必填：缺失整条丢弃；标签多字段兜底；cancellable 直通', () {
      final rows = parseBackgroundWorks([
        {
          'workId': 'w1',
          'title': 'vite',
          'status': 'running',
          'cancellable': true,
          'startedAt': 1000,
        },
        {
          'workId': 'w2',
          'kind': 'shell',
          'command': 'flutter run',
          'startedAt': 2000,
        },
        'junk',
        {'startedAt': 3000}, // 无 workId → 丢弃
      ]);
      expect(rows, hasLength(2));
      expect(rows[0].workId, 'w1');
      expect(rows[0].label, 'vite');
      expect(rows[0].startedAt, 1000);
      expect(rows[0].running, isTrue);
      expect(rows[0].cancellable, isTrue);
      expect(rows[1].workId, 'w2');
      expect(rows[1].label, 'shell');
    });

    test('resultPending = 已完成（服务端无 completed 态，App 推导）', () {
      final rows = parseBackgroundWorks([
        {
          'workId': 'w1',
          'title': 'build',
          'status': 'resultPending',
          'startedAt': 1000,
          'endedAt': 61000,
        },
      ]);
      expect(rows, hasLength(1));
      expect(rows[0].running, isFalse); // 不再亮运行边框/取消按钮
      expect(rows[0].done, isTrue);
      expect(rows[0].statusLabel, '已完成');
      expect(rows[0].endedAt, 61000);
    });

    test('workElapsed：有 endedAt 停表算总用时，否则按 now 计', () {
      expect(
        workElapsed(1000, endedAt: 61000, nowMs: 999000),
        '1 分 0 秒',
      ); // 用时停表，不受 now 影响
      expect(workElapsed(1000, nowMs: 31000), '30 秒');
    });

    test('非列表/空安全', () {
      expect(parseBackgroundWorks(null), isEmpty);
      expect(parseBackgroundWorks([]), isEmpty);
    });
  });

  group('AnchorThresholds（底部态滞回）', () {
    test('未完成首帧布局时恒为在底部', () {
      expect(
        AnchorThresholds.resolve(
          pixels: 9999,
          maxScrollExtent: 0,
          wasAtBottom: false,
        ),
        isTrue,
      );
    });

    test('已在底部：要滚过退出阈值才离开（滞回）', () {
      // 100~180 之间是带状区：保持在底部，不翻转
      expect(
        AnchorThresholds.resolve(
          pixels: 120,
          maxScrollExtent: 1000,
          wasAtBottom: true,
        ),
        isTrue,
      );
      expect(
        AnchorThresholds.resolve(
          pixels: 181,
          maxScrollExtent: 1000,
          wasAtBottom: true,
        ),
        isFalse,
      );
    });

    test('不在底部：要回到进入阈值内才回去（滞回）', () {
      expect(
        AnchorThresholds.resolve(
          pixels: 120,
          maxScrollExtent: 1000,
          wasAtBottom: false,
        ),
        isFalse,
      );
      expect(
        AnchorThresholds.resolve(
          pixels: 100,
          maxScrollExtent: 1000,
          wasAtBottom: false,
        ),
        isTrue,
      );
    });

    test('滞回消除临界带抖动：同一位置上状态不翻转', () {
      // 停在 140（带状区中间）：无论当前是哪态，结果都维持当前态
      for (final was in [true, false]) {
        expect(
          AnchorThresholds.resolve(
            pixels: 140,
            maxScrollExtent: 1000,
            wasAtBottom: was,
          ),
          was,
        );
      }
    });
  });

  group('AnchorMath（补偿规划）', () {
    test('小于最小步长不补偿（避免每帧都产生位移）', () {
      expect(AnchorMath.plan(0.5).isNoop, isTrue);
      expect(AnchorMath.plan(-1.0).isNoop, isTrue);
      expect(AnchorMath.plan(AnchorMath.minStepPx).isNoop, isFalse);
    });

    test('超上限截断，余量作为 leftover 留下', () {
      final step = AnchorMath.plan(1500);
      expect(step.delta, AnchorMath.maxStepPx);
      expect(step.leftover, 900);
    });

    test('负方向同样截断', () {
      final step = AnchorMath.plan(-1500);
      expect(step.delta, -AnchorMath.maxStepPx);
      expect(step.leftover, -900);
    });

    test('余量小于最小步长时归零（不必为看不见的量再跑一轮）', () {
      final step = AnchorMath.plan(AnchorMath.maxStepPx + 1);
      expect(step.leftover, 0);
    });

    test('时长随位移缩放且夹在区间内', () {
      final small = AnchorMath.plan(2);
      final big = AnchorMath.plan(500);
      final huge = AnchorMath.plan(100000);
      expect(small.duration.inMilliseconds, AnchorMath.minDurationMs);
      expect(big.duration.inMilliseconds, greaterThan(small.duration.inMilliseconds));
      expect(huge.duration.inMilliseconds, AnchorMath.maxDurationMs);
      // 区间内
      for (final s in [small, big, huge]) {
        expect(
          s.duration.inMilliseconds,
          inInclusiveRange(
            AnchorMath.minDurationMs,
            AnchorMath.maxDurationMs,
          ),
        );
      }
    });
  });

  group('FollowLock 翻历史锁存', () {
    test('未锁 + 超过 exitPx → 上锁', () {
      expect(
        FollowLock.shouldLock(
          pixels: AnchorThresholds.exitPx + 1,
          maxScrollExtent: 5000,
          lockFollow: false,
        ),
        isTrue,
      );
    });

    test('未锁 + 在临界带内 → 不上锁（避免误判成看历史）', () {
      expect(
        FollowLock.shouldLock(
          pixels: AnchorThresholds.enterPx,
          maxScrollExtent: 5000,
          lockFollow: false,
        ),
        isFalse,
      );
    });

    test('已锁时不再重复上锁（避免每次通知都 setState）', () {
      expect(
        FollowLock.shouldLock(
          pixels: 999,
          maxScrollExtent: 5000,
          lockFollow: true,
        ),
        isFalse,
      );
    });

    test('未完成布局（maxScrollExtent<=0）不上锁', () {
      expect(
        FollowLock.shouldLock(
          pixels: 999,
          maxScrollExtent: 0,
          lockFollow: false,
        ),
        isFalse,
      );
    });

    test('锁存解除门槛比进入门槛严：死区内保持锁住', () {
      expect(FollowLock.releasePx, lessThan(AnchorThresholds.enterPx));
      expect(
        FollowLock.shouldRelease(pixels: 80, maxScrollExtent: 5000),
        isFalse,
      );
    });

    test('贴到最新端附近才解锁', () {
      expect(FollowLock.shouldRelease(pixels: 0, maxScrollExtent: 5000), isTrue);
      expect(
        FollowLock.shouldRelease(pixels: FollowLock.releasePx, maxScrollExtent: 5000),
        isTrue,
      );
    });

    test('未完成布局默认解锁（首帧不该被锁住）', () {
      expect(FollowLock.shouldRelease(pixels: 999, maxScrollExtent: 0), isTrue);
    });
  });

  group('AutoFollowMath 自动回底规划', () {
    test('在底部（distance 0）不动作', () {
      expect(AutoFollowMath.plan(distance: 0, viewportDimension: 800).act, isFalse);
    });

    test('视口未量出时不动作（首帧保守）', () {
      expect(AutoFollowMath.plan(distance: 10, viewportDimension: 0).act, isFalse);
    });

    test('一屏内回底：linear + 固定时长（不拽）', () {
      final step = AutoFollowMath.plan(distance: 300, viewportDimension: 800);
      expect(step.act, isTrue);
      expect(step.target, 0);
      expect(step.curve, AutoFollowCurve.linear);
      expect(step.duration.inMilliseconds, AutoFollowMath.directMs);
    });

    test('恰好一屏仍回底', () {
      expect(
        AutoFollowMath.plan(distance: 800, viewportDimension: 800).act,
        isTrue,
      );
    });

    test('超过一屏不直接回底（交给锚定通道慢慢追）', () {
      expect(
        AutoFollowMath.plan(distance: 801, viewportDimension: 800).act,
        isFalse,
      );
    });

    test('回底曲线不是 easeOut（easeOut 出门太快 = 被拽手感）', () {
      final step = AutoFollowMath.plan(distance: 100, viewportDimension: 800);
      expect(step.curve, isNot(AutoFollowCurve.easeOut));
    });
  });

  group('AskQuestion 解析（实测契约）', () {
    Map<String, Object?> sampleQ() => {
          'question': '这是一个多选弹窗演示，你想让我接下来做哪些事？（可多选）',
          'header': '多选演示',
          'multiSelect': true,
          'options': [
            {'value': '写个自动化脚本', 'label': '写个自动化脚本', 'description': '写一个脚本'},
            {'value': '检查本地服务状态', 'label': '检查本地服务状态', 'description': '检查端口'},
          ],
        };

    test('读 multiSelect —— 旧实现漏读导致多选变单选', () {
      final q = AskQuestion.fromMap(sampleQ());
      expect(q.multiSelect, isTrue);
    });

    test('options 用 value 做标识，label 展示，description 保留', () {
      final q = AskQuestion.fromMap(sampleQ());
      expect(q.options.length, 2);
      expect(q.options.first.value, '写个自动化脚本');
      expect(q.options.first.label, '写个自动化脚本');
      expect(q.options.first.description, '写一个脚本');
    });

    test('header 缺失时退回题干', () {
      final q = AskQuestion.fromMap({
        'question': '只有题干',
        'options': const [],
      });
      expect(q.header, '只有题干');
      expect(q.multiSelect, isFalse);
    });

    test('选项缺 value 时退回 label（实测两者常相同）', () {
      final o = AskOption.fromMap({'label': '只有label'});
      expect(o.value, '只有label');
      expect(o.label, '只有label');
    });

    test('题干为空时 key 用占位符，避免多题塌到同一键', () {
      final q = AskQuestion.fromMap(const {});
      expect(q.key(0), '#q0');
      expect(q.key(1), '#q1');
      expect(q.key(0), isNot(q.key(1)));
    });

    test('题干非空时 key 就是题干', () {
      final q = AskQuestion.fromMap({'question': '题目A'});
      expect(q.key(0), '题目A');
    });
  });

  group('AskAnswer 作答状态', () {
    test('多选累加：点两个都在', () {
      var a = const AskAnswer().toggle('x', multiSelect: true);
      a = a.toggle('y', multiSelect: true);
      expect(a.selected, {'x', 'y'});
    });

    test('多选再点一次取消', () {
      var a = const AskAnswer().toggle('x', multiSelect: true);
      a = a.toggle('x', multiSelect: true);
      expect(a.selected, isEmpty);
    });

    test('单选换选：点新的替换旧的（旧实现这里是覆盖但 UI 不敢点多）', () {
      var a = const AskAnswer().toggle('x', multiSelect: false);
      a = a.toggle('y', multiSelect: false);
      expect(a.selected, {'y'});
    });

    test('单选点已选中的可取消（允许反悔）', () {
      var a = const AskAnswer().toggle('x', multiSelect: false);
      a = a.toggle('x', multiSelect: false);
      expect(a.selected, isEmpty);
    });

    test('自由文本计入 isEmpty 判定', () {
      expect(const AskAnswer(other: '  ').isEmpty, isTrue);
      expect(const AskAnswer(other: '自定义答案').isNotEmpty, isTrue);
    });

    test('toSelected 把自由文本追加在选项之后', () {
      const a = AskAnswer(selected: {'x'}, other: '自己填的');
      expect(a.toSelected(), ['x', '自己填的']);
    });

    test('toSelected 忽略空白自由文本', () {
      const a = AskAnswer(selected: {'x'}, other: '   ');
      expect(a.toSelected(), ['x']);
    });
  });

  group('buildAskAnswersPayload（实测确认的服务端形状）', () {
    test('产出 answers 数组，元素是 {question, selected}', () {
      final qs = [
        AskQuestion.fromMap({
          'question': '题目A',
          'multiSelect': true,
          'options': const [],
        }),
      ];
      final payload = buildAskAnswersPayload(
        questions: qs,
        answers: const [
          AskAnswer(selected: {'x', 'y'}),
        ],
      );
      expect(payload['action'], 'accept');
      final content = payload['content'] as Map;
      final answers = content['answers'] as List;
      expect(answers.length, 1);
      final first = answers.first as Map;
      expect(first['question'], '题目A');
      expect((first['selected'] as List).toSet(), {'x', 'y'});
    });

    test('多题按顺序产出，题干做键', () {
      final qs = [
        AskQuestion.fromMap({'question': 'Q1'}),
        AskQuestion.fromMap({'question': 'Q2'}),
      ];
      final payload = buildAskAnswersPayload(
        questions: qs,
        answers: const [AskAnswer(selected: {'a'}), AskAnswer(other: 'b')],
      );
      final answers = (payload['content'] as Map)['answers'] as List;
      expect(answers.length, 2);
      expect((answers[0] as Map)['question'], 'Q1');
      expect((answers[1] as Map)['selected'], ['b']);
    });

    test('answers 少于 questions 时缺的题给空 selected（不崩）', () {
      final qs = [
        AskQuestion.fromMap({'question': 'Q1'}),
        AskQuestion.fromMap({'question': 'Q2'}),
      ];
      final payload = buildAskAnswersPayload(
        questions: qs,
        answers: const [AskAnswer(selected: {'a'})],
      );
      final answers = (payload['content'] as Map)['answers'] as List;
      expect(answers.length, 2);
      expect((answers[1] as Map)['selected'], isEmpty);
    });

    test('空题干用占位键，与 UI 的 key() 一致', () {
      final qs = [AskQuestion.fromMap(const {})];
      final payload = buildAskAnswersPayload(
        questions: qs,
        answers: const [AskAnswer(selected: {'x'})],
      );
      final answers = (payload['content'] as Map)['answers'] as List;
      expect((answers.first as Map)['question'], '#q0');
    });
  });

  group('提交门槛与 freeText 开关', () {
    test('全部题都答了才可提交', () {
      expect(allAnswered(const [AskAnswer(selected: {'a'})]), isTrue);
      expect(
        allAnswered(const [AskAnswer(selected: {'a'}), AskAnswer()]),
        isFalse,
      );
    });

    test('空列表不算答完（防止零题直接提交）', () {
      expect(allAnswered(const []), isFalse);
    });

    test('自由文本算作已答', () {
      expect(allAnswered(const [AskAnswer(other: '自定义')]), isTrue);
    });

    test('payloadAllowsFreeText 只认顶层 freeText == true', () {
      expect(payloadAllowsFreeText(const {'freeText': true}), isTrue);
      expect(payloadAllowsFreeText(const {'freeText': false}), isFalse);
      expect(payloadAllowsFreeText(const {}), isFalse);
    });
  });
  group('breakdownSourceLabel 来源中文标签', () {
    test('已知来源映射中文', () {
      expect(breakdownSourceLabel('system_prompt'), '系统提示');
      expect(breakdownSourceLabel('meta_user_context'), '环境上下文');
      expect(breakdownSourceLabel('skills'), '技能说明');
      expect(breakdownSourceLabel('system_tool_schemas'), '内置工具定义');
      expect(breakdownSourceLabel('mcp_tool_schemas'), 'MCP 工具定义');
      expect(breakdownSourceLabel('messages'), '对话内容');
    });

    test('未知来源原样返回', () {
      expect(breakdownSourceLabel('user_avatar'), 'user_avatar');
      expect(breakdownSourceLabel(''), '');
    });
  });

  group('cumulativeKeyLabel 累计用量键中文标签', () {
    test('已知键映射中文', () {
      expect(cumulativeKeyLabel('inputTokens'), '输入 tokens');
      expect(cumulativeKeyLabel('cacheReadTokens'), '缓存读取');
      expect(cumulativeKeyLabel('totalTurns'), '总回合');
    });

    test('未知键原样透传（动态结构兜底）', () {
      expect(cumulativeKeyLabel('someNewField'), 'someNewField');
      expect(cumulativeKeyLabel(''), '');
    });
  });

  group('queueHasDuplicate 排队重复判定', () {
    final queue = [
      {'queueItemId': 'q1', 'text': '提醒：不要停'},
      {'queueItemId': 'q2', 'text': '  带空白  '},
    ];

    test('与队列中任一条 trim 后相同 → true', () {
      expect(queueHasDuplicate(queue, '提醒：不要停'), isTrue);
      expect(queueHasDuplicate(queue, '  提醒：不要停 '), isTrue);
      expect(queueHasDuplicate(queue, '带空白'), isTrue);
    });

    test('不同文本/空文本 → false', () {
      expect(queueHasDuplicate(queue, '别的消息'), isFalse);
      expect(queueHasDuplicate(queue, ''), isFalse);
      expect(queueHasDuplicate(queue, '   '), isFalse);
      expect(queueHasDuplicate(const [], ''), isFalse);
    });
  });

  group('attachUploadPlan（静默预上传的复用判定）', () {
    test('同会话已有 ref → 复用，不再传', () {
      expect(
        attachUploadPlan(refMatchesSession: true, inflightMatchesSession: false),
        AttachUploadPlan.reuse,
      );
      // 有 ref 且还有一条在飞（用户又选了一次同一张）也照样复用。
      expect(
        attachUploadPlan(refMatchesSession: true, inflightMatchesSession: true),
        AttachUploadPlan.reuse,
      );
    });

    test('ref 属于别的会话 → 不复用，现场重传', () {
      // 附件 ref 是会话域的：A 会话的 ref 拿去 B 会话发是无效引用。
      expect(
        attachUploadPlan(
          refMatchesSession: false,
          inflightMatchesSession: false,
        ),
        AttachUploadPlan.fresh,
      );
    });

    test('没 ref 但有一条发往同会话的在飞 → 等它落地', () {
      expect(
        attachUploadPlan(
          refMatchesSession: false,
          inflightMatchesSession: true,
        ),
        AttachUploadPlan.inflight,
      );
    });
  });
}
