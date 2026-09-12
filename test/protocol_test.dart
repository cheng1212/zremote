import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/protocol/crc32.dart';
import 'package:zremote/protocol/proof.dart';
import 'package:zremote/protocol/rpc_frames.dart';
import 'package:zremote/protocol/value_codec.dart';

void main() {
  test('CRC32 known vector', () {
    expect(Crc32.hexOf(utf8.encode('123456789')), 'cbf43926');
    expect(Crc32.hexOf(Uint8List(0)), '00000000');
  });

  test('varint round-trip', () {
    for (final value in [0, 1, 127, 128, 300, 16383, 16384, 0x7FFFFFFF]) {
      final builder = BytesBuilder();
      Varint.write(builder, value);
      final data = builder.toBytes();
      final (decoded, consumed) = Varint.read(data, 0);
      expect(decoded, value, reason: 'value $value');
      expect(consumed, data.length);
    }
  });

  test('value codec round-trip', () {
    final payload = <Object?>[
      100,
      'hello 中文',
      Uint8List.fromList([1, 2, 3, 255]),
      <String, Object?>{'kind': 'snapshot', 'n': 42},
      [true, 1.5, null],
    ];
    final writer = ValueWriter();
    writer.writeValue([100, 201, 'zcode-agent', 'promise']);
    writer.writeValue(payload);
    final bytes = writer.take();
    final reader = ValueReader(bytes);
    final header = reader.readValue() as List;
    expect(header, [100, 201, 'zcode-agent', 'promise']);
    final decoded = reader.readValue() as List;
    expect(decoded[0], 100);
    expect(decoded[1], 'hello 中文');
    expect((decoded[2] as Uint8List).toList(), [1, 2, 3, 255]);
    expect((decoded[3] as Map)['n'], 42);
    expect((decoded[4] as List)[1], 1.5);
  });

  test('proof is unpadded base64url of HMAC', () {
    final proof = calculateProof(
      passHash: 'key',
      nonce: 'nonce',
      role: 'terminal',
      deviceSid: 'sid',
    );
    // 独立重算期望值：HMAC-SHA256(key=utf8('key'), msg='nonce|terminal|sid')
    final digest = Hmac(
      sha256,
      utf8.encode('key'),
    ).convert(utf8.encode('nonce|terminal|sid')).bytes;
    final expected = base64Url.encode(digest).replaceAll('=', '');
    expect(proof, expected);
    expect(proof.contains('='), isFalse);
    expect(proof.contains('+'), isFalse);
    expect(proof.contains('/'), isFalse);
  });

  test('rpc-frame fragmentation round-trip', () {
    final sent = <Map<String, dynamic>>[];
    final acks = <int>[];
    final received = <Uint8List>[];
    final frames = RpcFrames(
      bridgeSessionId: 'b1',
      send: sent.add,
      onMessage: received.add,
    );
    final peer = RpcFrames(
      bridgeSessionId: 'b1',
      send: (p) {
        if (p['zcode_type'] == 'rpc-frame-ack') {
          acks.add(p['ackMessageSeq'] as int);
        }
      },
      onMessage: received.add,
    );
    final message = Uint8List.fromList(
      List.generate(rpcFragmentTestSize, (i) => i & 0xFF),
    );
    frames.sendMessage(message);
    expect(sent.length, greaterThan(1), reason: '应当分片');
    for (final fragment in sent) {
      peer.accept(fragment);
    }
    expect(acks, [1]);
    expect(received, hasLength(1));
    expect(received.first.length, rpcFragmentTestSize);
  });

  test('rpc-frame rejects corrupted checksum', () {
    final sent = <Map<String, dynamic>>[];
    final received = <Uint8List>[];
    final frames = RpcFrames(
      bridgeSessionId: 'b',
      send: sent.add,
      onMessage: received.add,
    );
    final peer = RpcFrames(
      bridgeSessionId: 'b',
      send: (_) {},
      onMessage: received.add,
    );
    frames.sendMessage(Uint8List.fromList(utf8.encode('hello')));
    final tampered = {
      ...sent.first,
      'dataBase64': base64.encode(utf8.encode('hellx')),
    };
    peer.accept(tampered);
    expect(received, isEmpty);
  });

  test('ConversationState applies snapshot + deltas', () {
    final state = ConversationState();
    var gaps = 0;
    state.applyFrame({
      'fromSeq': 0,
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'revision': 5,
          'logEpoch': 'e1',
          'control': {'phase': 'idle', 'canStop': false},
          'config': {'model': 'GLM', 'provider': 'p', 'thought': 'max'},
          'rows': {'window': [], 'totalCount': 0},
        },
      },
    }, onGap: () => gaps++);
    expect(state.revision, 5);
    expect(state.phase, 'idle');
    expect(state.currentThought, 'max');
    expect(gaps, 0);

    state.applyFrame({
      'fromSeq': 1,
      'toSeq': 2,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'row.appended',
            'row': {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
          },
          {
            'op': 'row.appended',
            'row': {
              'rowId': 2,
              'kind': 'assistantText',
              'text': '',
              'state': 'streaming',
            },
          },
          {'op': 'row.delta', 'rowId': 2, 'path': 'text', 'append': '你好'},
          {'op': 'row.delta', 'rowId': 2, 'path': 'text', 'append': '世界'},
          {
            'op': 'state.updated',
            'patch': {
              'control': {'phase': 'running', 'canStop': true},
            },
          },
        ],
      },
    }, onGap: () => gaps++);
    state.flushPendingFrames(onGap: () => gaps++);
    expect(state.rows, hasLength(2));
    expect(state.rows[1]['text'], '你好世界');
    expect(state.phase, 'running');
    expect(state.canStop, isTrue);
    expect(state.totalCount, 2);
    expect(gaps, 0);

    // 断流：seq 不连续 → onGap
    state.applyFrame({
      'fromSeq': 9,
      'toSeq': 10,
      'payload': {'kind': 'deltas', 'deltas': []},
    }, onGap: () => gaps++);
    state.flushPendingFrames(onGap: () => gaps++);
    expect(gaps, 1);

    // row.removed：保留 rowId < fromRowId
    state.applyFrame({
      'fromSeq': 2,
      'toSeq': 3,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'row.removed', 'fromRowId': 2},
        ],
      },
    }, onGap: () => gaps++);
    state.flushPendingFrames(onGap: () => gaps++);
    expect(state.rows, hasLength(1));
    expect(state.rows.first['rowId'], 1);
    expect(state.totalCount, 1);
  });

  test('ConversationState out-of-order row.delta is a no-op', () {
    final state = ConversationState();
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'revision': 1,
          'rows': {'window': [], 'totalCount': 0},
        },
      },
    }, onGap: () {});
    state.applyFrame({
      'fromSeq': 1,
      'toSeq': 2,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {'op': 'row.delta', 'rowId': 999, 'path': 'text', 'append': 'x'},
        ],
      },
    }, onGap: () {});
    expect(state.rows, isEmpty);
  });

  test('canonicalApprovalMode 四个正式 id 原样归一', () {
    for (final id in [
      'askBeforeChange',
      'autoEdit',
      'planMode',
      'fullAccess',
    ]) {
      expect(canonicalApprovalMode(id), id, reason: 'id $id');
    }
  });

  test('canonicalApprovalMode 服务端同义词归一到正式 id（大小写不敏感）', () {
    expect(canonicalApprovalMode('default'), 'askBeforeChange');
    expect(canonicalApprovalMode('ask'), 'askBeforeChange');
    expect(canonicalApprovalMode('AcceptEdits'), 'autoEdit');
    expect(canonicalApprovalMode('autoedit'), 'autoEdit');
    expect(canonicalApprovalMode('plan'), 'planMode');
    expect(canonicalApprovalMode('bypassPermissions'), 'fullAccess');
    expect(canonicalApprovalMode('yolo'), 'fullAccess');
    expect(canonicalApprovalMode(' never '), 'fullAccess');
  });

  test('canonicalApprovalMode 空与未知给 null', () {
    expect(canonicalApprovalMode(null), isNull);
    expect(canonicalApprovalMode(''), isNull);
    expect(canonicalApprovalMode('on-failure'), isNull);
  });

  test('isErrorPhase 认会话级错误态', () {
    expect(isErrorPhase('error'), isTrue);
    expect(isErrorPhase('completedError'), isTrue);
    expect(isErrorPhase('running'), isFalse);
    expect(isErrorPhase('idle'), isFalse);
    expect(isErrorPhase(''), isFalse);
  });

  test('extractConversationError 从 control 捞错误信息', () {
    expect(
      extractConversationError({
        'control': {'phase': 'error', 'error': 'qwen3-max 上游 401'},
      }),
      'qwen3-max 上游 401',
    );
  });

  test('extractConversationError control 没带时看快照顶层', () {
    expect(
      extractConversationError({
        'control': {'phase': 'error'},
        'errorMessage': '模型调用失败',
      }),
      '模型调用失败',
    );
  });

  test('extractConversationError 空串纯空白跳过，全空给 null', () {
    expect(
      extractConversationError({
        'control': {'error': '  '},
        'message': '',
      }),
      isNull,
    );
    expect(extractConversationError(null), isNull);
  });

  test('BUG-33：lastError 结构体 → 取 message 并附 HTTP 状态/错误码', () {
    expect(
      extractConversationError({
        'control': {
          'lastError': {
            'code': 'provider_business',
            'message': '余额不足',
            'recoverable': false,
            'source': 'provider',
            'statusCode': 402,
            'providerErrorCode': '1113',
          },
        },
      }),
      '余额不足（HTTP 402 · 1113）',
    );
    // 无状态码时只出 message；message 缺失退 detail
    expect(
      extractConversationError({
        'lastError': {
          'code': 'x',
          'message': '模型调用超时',
        },
      }),
      '模型调用超时',
    );
    expect(
      extractConversationError({
        'lastError': {'code': 'x', 'detail': '只有详情'},
      }),
      '只有详情',
    );
    // message/detail 全缺 → code 兜底顶上
    expect(
      extractConversationError({
        'lastError': {'code': 'provider_business'},
      }),
      'provider_business',
    );
  });

  test('ConversationState 出错态 getter：phase + 错误信息', () {
    final state = ConversationState();
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'control': {'phase': 'error', 'statusMessage': '上游代理 500'},
        },
      },
    }, onGap: () {});
    expect(state.hasErrorPhase, isTrue);
    expect(state.conversationError, '上游代理 500');

    final ok = ConversationState();
    ok.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'control': {'phase': 'idle'},
        },
      },
    }, onGap: () {});
    expect(ok.hasErrorPhase, isFalse);
    expect(ok.conversationError, isNull);
  });

  test('state.updated 携带 config 时与旧 config 深合并，不整包替换', () {
    final state = ConversationState();
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'config': {
            'provider': 'deepseek',
            'model': 'v4',
            'approvalMode': 'planMode',
          },
        },
      },
    }, onGap: () {});
    state.applyFrame({
      'fromSeq': 1,
      'toSeq': 2,
      'payload': {
        'kind': 'deltas',
        'deltas': [
          {
            'op': 'state.updated',
            'patch': {
              'config': {'provider': 'glm', 'model': '4.6'},
            },
          },
        ],
      },
    }, onGap: () {});
    state.flushPendingFrames(onGap: () {});
    expect(state.currentProvider, 'glm');
    expect(state.currentModel, '4.6');
    // 只提到 provider/model 的 config 更新不该抹掉 approvalMode。
    expect(state.currentApprovalMode, 'planMode');
  });

  group('会话状态一致性（phase 判定）', () {
    test('isBusyPhase 把 queued 算作忙——旧实现漏了它', () {
      expect(isBusyPhase('running'), isTrue);
      expect(isBusyPhase('prewarming'), isTrue);
      expect(isBusyPhase('queued'), isTrue);
      expect(isBusyPhase('idle'), isFalse);
      expect(isBusyPhase('completedSuccess'), isFalse);
      expect(isBusyPhase('error'), isFalse);
    });

    test('isProducingPhase 不含 queued——排队中不该给停止', () {
      expect(isProducingPhase('running'), isTrue);
      expect(isProducingPhase('prewarming'), isTrue);
      expect(isProducingPhase('queued'), isFalse);
    });

    test('ConversationState.isRunning 与 isProducing 语义分离', () {
      expect(isBusyPhase('queued') && !isProducingPhase('queued'), isTrue);
    });
  });

  group('phase 覆盖释放判定', () {
    test('没有覆盖时可以直接放行', () {
      expect(
        canReleaseLivePhase(overridePhase: null, indexPhase: 'running'),
        isTrue,
      );
    });

    test('index 还没这个会话 → 不能撤（撤了就没了）', () {
      expect(
        canReleaseLivePhase(overridePhase: 'running', indexPhase: null),
        isFalse,
      );
    });

    test('index 未追平 → 不能撤（否则状态倒退）', () {
      expect(
        canReleaseLivePhase(overridePhase: 'running', indexPhase: 'idle'),
        isFalse,
      );
    });

    test('index 已追平 → 可以撤，交还给 index 权威', () {
      expect(
        canReleaseLivePhase(overridePhase: 'idle', indexPhase: 'idle'),
        isTrue,
      );
    });
  });

  group('发送异常标记判定', () {
    test('非空文案要打标', () {
      expect(shouldFlagSendIssue('消息未送达'), isTrue);
    });

    test('空 / 纯空白 = 恢复（清除标记）', () {
      expect(shouldFlagSendIssue(''), isFalse);
      expect(shouldFlagSendIssue('   '), isFalse);
    });

    test('同值判定忽略首尾空白——避免反复 notifyListeners', () {
      expect(sameSendIssue('消息未送达', ' 消息未送达 '), isTrue);
      expect(sameSendIssue(null, ''), isTrue);
      expect(sameSendIssue('消息未送达', '消息发送较慢'), isFalse);
    });
  });

  group('命令安全闸门 requireAccepted', () {
    test('accepted / noop / duplicate 三种放行', () {
      for (final s in ['accepted', 'noop', 'duplicate']) {
        expect(() => requireAccepted({'status': s}), returnsNormally,
            reason: s);
      }
    });

    test('非 accepted 状态抛 reasonCode 优先的人话', () {
      expect(
        () => requireAccepted({
          'status': 'rejected',
          'reasonCode': 'provider.notInRegistry',
          'message': '详细消息',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'provider.notInRegistry',
          ),
        ),
      );
      expect(
        () => requireAccepted({'status': 'failed', 'message': '网络中断'}),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '网络中断'),
        ),
      );
    });

    test('非 Map / 无 status 字段放行——闸门只拦带状态的拒绝帧', () {
      expect(() => requireAccepted(null), returnsNormally);
      expect(() => requireAccepted('ok'), returnsNormally);
      expect(() => requireAccepted(<String, dynamic>{}), returnsNormally);
    });
  });

  group('castMapList 服务端列表统一入口', () {
    test('List 直通且过滤非 Map 元素', () {
      final out = castMapList([
        {'a': 1},
        'junk',
        42,
        {'b': 2},
      ]);
      expect(out, [
        {'a': 1},
        {'b': 2},
      ]);
    });

    test('非 List 输入给空列表（不给 null，调用方免判空）', () {
      expect(castMapList(null), isEmpty);
      expect(castMapList('nope'), isEmpty);
    });
  });

  group('ResyncGate 单飞闸（BUG：gap 风暴并发 resync 重置视口）', () {
    test('首次 tryAcquire 放行，在途期间后续调用全部合流', () {
      final gate = ResyncGate();
      expect(gate.tryAcquire(), isTrue, reason: '首次应放行');
      expect(gate.inFlight, isTrue);
      // 模拟 40ms 微批窗口里同批多帧逐帧调 onGap：全部应被合流。
      for (var i = 0; i < 12; i++) {
        expect(gate.tryAcquire(), isFalse, reason: '第 $i 次重复应被合流');
      }
    });

    test('release 后闸门重新可用（下一次 gap 能真发）', () {
      final gate = ResyncGate();
      expect(gate.tryAcquire(), isTrue);
      gate.release();
      expect(gate.inFlight, isFalse);
      expect(gate.tryAcquire(), isTrue, reason: '释放后应能再次放行');
    });

    test('release 幂等：重复释放不会让闸门失效', () {
      final gate = ResyncGate();
      gate.tryAcquire();
      gate.release();
      gate.release();
      expect(gate.tryAcquire(), isTrue);
    });
  });

  group('gap 判定不推进 seq（防止后续合法帧被误判）', () {
    test('断档帧不推进 seq，后续 fromSeq 对得上的帧正常应用', () {
      final state = ConversationState();
      var gaps = 0;
      // 先建基线：seq 收到 5
      state.applyFrame({
        'toSeq': 5,
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'revision': 1,
            'rows': {'window': [], 'totalCount': 0},
          },
        },
      }, onGap: () => gaps++);
      state.flushPendingFrames(onGap: () => gaps++);
      expect(gaps, 0);

      // 断档帧（fromSeq=99 对不上 seq=5）→ 报 gap，但不该把 seq 推到 100
      state.applyFrame({
        'fromSeq': 99,
        'toSeq': 100,
        'payload': {'kind': 'deltas', 'deltas': []},
      }, onGap: () => gaps++);
      state.flushPendingFrames(onGap: () => gaps++);
      expect(gaps, 1);

      // 关键：seq 仍是 5，所以 fromSeq=5 的合法帧还能正常落地
      state.applyFrame({
        'fromSeq': 5,
        'toSeq': 6,
        'payload': {
          'kind': 'deltas',
          'deltas': [
            {
              'op': 'row.appended',
              'row': {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
            },
          ],
        },
      }, onGap: () => gaps++);
      state.flushPendingFrames(onGap: () => gaps++);
      expect(gaps, 1, reason: '合法帧不该再报 gap');
      expect(state.rows, hasLength(1), reason: '合法帧的 delta 应被应用');
    });
  });
}


const rpcFragmentTestSize = 512 * 1024 + 1024; // 必然切成 2 片
