import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'constants.dart';
import 'fragment_assembler.dart';
import 'remote_session.dart';

/// setApprovalMode 的正式词汇表 id → 服务端各 agent 方言同义词。
/// 不同 agent（Claude/Codex/GLM）config 里回显的模式名不一致，
/// 逐字比较会全部 miss，导致权限面板看不出当前选中项。
const _approvalModeAliases = <String, String>{
  'askbeforechange': 'askBeforeChange',
  'default': 'askBeforeChange',
  'ask': 'askBeforeChange',
  'confirm': 'askBeforeChange',
  'autoedit': 'autoEdit',
  'acceptedits': 'autoEdit',
  'edit': 'autoEdit',
  'planmode': 'planMode',
  'plan': 'planMode',
  'fullaccess': 'fullAccess',
  'bypasspermissions': 'fullAccess',
  'bypass': 'fullAccess',
  'yolo': 'fullAccess',
  'never': 'fullAccess',
  'dangerfullaccess': 'fullAccess',
};

/// 归一服务端/本地的权限模式名到正式 id；空或词汇表外返回 null。
String? canonicalApprovalMode(String? raw) {
  if (raw == null) return null;
  final key = raw.trim().toLowerCase();
  if (key.isEmpty) return null;
  return _approvalModeAliases[key];
}

/// phase 是否代表"在忙"（含排队）。
///
/// `queued` 是排队中——消息还没执行但用户不该再叠队列，界面上要表现为忙。
/// 旧实现在 `ConversationState.isRunning` 里漏了它，导致排队态被当空闲。
bool isBusyPhase(String phase) =>
    phase == 'running' || phase == 'prewarming' || phase == 'queued';

/// phase 是否代表"真的在产出"（可以停止）。
/// 排队中还没开始跑，给「停止」是错的——停了也没东西可停。
bool isProducingPhase(String phase) =>
    phase == 'running' || phase == 'prewarming';

/// 「离开会话后，phase 覆盖能不能撤」的判定。
///
/// 撤回条件：index 的权威值已经追平覆盖值——此时覆盖不再承担信息，留着
/// 反而会挡住 index 的后续更新。没追平就继续留着（否则状态会倒退：
/// 刚在聊天页看到"运行中"，退回列表变"空闲"）。
bool canReleaseLivePhase({
  required String? overridePhase,
  required String? indexPhase,
}) {
  if (overridePhase == null) return true; // 本来就没覆盖
  if (indexPhase == null) return false; // index 还没这个会话，撤了就没了
  return overridePhase == indexPhase;
}

/// 发送异常文案 → 是否该在列表卡上打标。空白 = 无异常（清除标记）。
bool shouldFlagSendIssue(String issue) => issue.trim().isNotEmpty;

/// 两个发送异常文案是否等价（用于去重，免得同值反复 notifyListeners）。
bool sameSendIssue(String? a, String? b) =>
    (a ?? '').trim() == (b ?? '').trim();

/// 会话级出错 phase（与任务卡 phaseStyle 同词汇）。
///
/// 模型调用前的失败（上游 4xx/5xx、代理断连）服务端不建任何助手行，
/// 只把 control.phase 标成 error——时间线什么都不渲染，用户只看到空白。
bool isErrorPhase(String phase) =>
    phase == 'error' || phase == 'completedError';

/// 错误值 → 人话。桌面端错误有两种形态（schema 反解实证）：
/// 纯字符串，或结构体 {code, message, recoverable, source,
/// statusCode?, providerErrorCode?, detail?}——余额不足这类 provider
/// 业务错误就是结构体。只认字符串会把具体原因全丢掉（BUG-33）。
String? errorValueText(Object? v) {
  if (v is String) return v.trim().isEmpty ? null : v.trim();
  if (v is! Map) return null;
  final m = v.cast<String, dynamic>();
  // message → detail → code 三级兜底；code 是内部分类（provider_business
  // 之类），当正文对用户是噪音，只在没有更可读的字段时顶上。
  final msg = '${m['message'] ?? m['detail'] ?? m['code'] ?? ''}'.trim();
  if (msg.isEmpty) return null;
  final bits = <String>[];
  final status = m['statusCode'];
  if (status is num && status >= 100 && status <= 599) {
    bits.add('HTTP $status');
  }
  final pCode = '${m['providerErrorCode'] ?? ''}'.trim();
  if (pCode.isNotEmpty && pCode != msg) bits.add(pCode);
  return bits.isEmpty ? msg : '$msg（${bits.join(' · ')}）';
}

/// 从会话快照捞错误信息：control 优先，快照顶层兜底。
/// 服务端把错误详情放在哪个键没完全实测，多认几个；值可以是字符串
/// 或结构体（lastError 就是结构体）。
String? extractConversationError(Map<String, dynamic>? snapshot) {
  if (snapshot == null) return null;
  final control = (snapshot['control'] as Map?)?.cast<String, dynamic>();
  for (final m in [control, snapshot]) {
    if (m == null) continue;
    for (final k in const [
      'error',
      'errorMessage',
      'errorText',
      'lastError',
      'statusMessage',
      'message',
      'detail',
    ]) {
      final text = errorValueText(m[k]);
      if (text != null) return text;
    }
  }
  return null;
}

/// 队列自动去重判定：同一文本（trim 后）出现多次时，除队首外全部视为
/// 重复，返回要删除的 queueItemId 列表（保持队列顺序）。
/// 空文本/缺 id 的条目不参与（宁放过不误删）。
List<String> duplicateQueueItemIds(List<Map<String, dynamic>> items) {
  final seen = <String>{};
  final dupIds = <String>[];
  for (final q in items) {
    final id = '${q['queueItemId'] ?? ''}';
    final text = '${q['text'] ?? ''}'.trim();
    if (id.isEmpty || text.isEmpty) continue;
    if (!seen.add(text)) dupIds.add(id);
  }
  return dupIds;
}

/// Conversation V4 protocol over the `zcode-agent` channel.
///
/// Flow: hello → initialize(clientHello) → subscribe(scope+sessionId) →
/// frames via dynamic event → commands via sendConversationCommandV4.
class ConversationV4 {
  final Bridge bridge;
  final void Function(String line)? onLog;

  final String clientId = genId('zr');

  bool _handshaken = false;
  Future<void>? _handshakeFuture;

  /// From the server hello — required for attachment uploads.
  String? connectionId;

  /// Current bridge scope: `{workspacePath, workspaceIdentity?}`.
  Map<String, dynamic> get scope => bridge.scope;

  ConversationV4({required this.bridge, this.onLog});

  ChannelClient get _ch => bridge.channels;

  void _log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??=
        () async {
          final hello = await _ch.call(convChannel, mHello, []);
          _log('[v4] hello: $hello');
          if (hello is Map) connectionId = hello['connectionId'] as String?;
          await _ch.call(convChannel, mInitialize, [
            {
              'kind': 'clientHello',
              'protocolVersion': convProtocolVersion,
              'clientId': clientId,
              'clientKind': convClientKind,
              'appVersion': convProtocolAppVersion,
            },
          ]);
          _handshaken = true;
        }().catchError((Object e) {
          _handshakeFuture = null;
          throw e;
        });
  }

  /// Resets handshake state when the bridge stack is swapped; all active
  /// subscriptions resubscribe (server state died with the old bridge).
  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    for (final sub in _convSubs.values) {
      sub._resubscribe();
    }
    _indexSub?._resubscribe();
  }

  final _convSubs = <String, ConvSubscription>{};
  IndexSubscription? _indexSub;

  Future<ConvSubscription> subscribe(String sessionId) async {
    final existing = _convSubs[sessionId];
    if (existing != null) return existing;
    bridge.recovered.removeListener(_onBridgeRecovered);
    bridge.recovered.addListener(_onBridgeRecovered);
    final sub = ConvSubscription._(this, sessionId);
    try {
      await sub._start();
    } on Object {
      await sub.dispose();
      rethrow;
    }
    _convSubs[sessionId] = sub;
    return sub;
  }

  Future<IndexSubscription> subscribeSessionsIndex() async {
    _indexSub ??= IndexSubscription._(this);
    final sub = _indexSub!;
    bridge.recovered.removeListener(_onBridgeRecovered);
    bridge.recovered.addListener(_onBridgeRecovered);
    if (!sub.state.ready) {
      await sub._start();
    }
    return sub;
  }

  void _untrackConv(String sessionId) => _convSubs.remove(sessionId);

  /// Highest revision seen from command acks — acks land before the
  /// follow-up state.updated frame, so the next CAS base must not go stale.
  final _ackedRevisions = <String, int>{};

  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await handshake();
    // Gate on a healthy bridge so a send during a reconnect window goes
    // through on the fresh transport instead of timing out.
    await bridge.waitHealthy(timeout: const Duration(seconds: 45));
    final sub = sessionId == null ? null : _convSubs[sessionId];
    final baseRevision = sessionId == null
        ? null
        : [
            sub?.state.revision ?? 0,
            _ackedRevisions[sessionId] ?? 0,
          ].reduce((a, b) => a > b ? a : b);
    final envelope = {
      'commandId': genId('cmd'),
      'clientId': clientId,
      'sessionId': sessionId,
      if (casCommands.contains(type)) 'baseRevision': baseRevision,
      if (rowTargetCommands.contains(type) && sub?.state.logEpoch != null)
        'baseLogEpoch': sub!.state.logEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _log('[v4] command $type');
    var res = await _sendWithRetry(envelope, timeout);
    // Stale CAS: retry once with the server's revision from the ack.
    if (sessionId != null &&
        res is Map &&
        res['status'] == 'stale' &&
        res['revisionAtDecision'] is num) {
      final serverRevision = (res['revisionAtDecision'] as num).toInt();
      _log('[v4] command $type stale, retry at rev $serverRevision');
      if (serverRevision > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = serverRevision;
      }
      final retry = {
        ...envelope,
        'commandId': genId('cmd'),
        'baseRevision': serverRevision,
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      res = await _sendWithRetry(retry, timeout);
    }
    if (sessionId != null && res is Map && res['revisionAtDecision'] is num) {
      final rev = (res['revisionAtDecision'] as num).toInt();
      final status = res['status'];
      // 地板只在真正落盘（accepted）时 +1：noop（如 config.unchanged）和
      // duplicate 不产生新 revision，抬地板会让下一条 CAS 命令必然
      // stale 一次（真实探针实测：noop@1385 → 下一命令 base 1386 被拒）。
      final floor = status == 'accepted' ? rev + 1 : rev;
      if (floor > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = floor;
      }
    }
    return res;
  }

  Future<dynamic> _sendWithRetry(Map envelope, Duration timeout) async {
    try {
      return await _ch.call(convChannel, mSendCommand, [
        {...scope, 'envelope': envelope},
      ], timeout: timeout);
    } on TimeoutException {
      // Retry only when the relay dropped mid-flight; otherwise a retry
      // would double-deliver (e.g. sendText).
      if (bridge.degraded.value == null) rethrow;
      _log('[v4] command timed out during drop, waiting for recovery');
      await bridge.waitHealthy(timeout: const Duration(seconds: 45));
      return _ch.call(convChannel, mSendCommand, [
        {...scope, 'envelope': envelope},
      ], timeout: timeout);
    }
  }

  // ------------------------------------------------------------- commands

  /// Creates a session; returns the new sessionId on `accepted`.
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<Map<String, dynamic>>? attachments,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final res = await sendCommand(null, 'createSession', {
      'workspaceId': workspaceId,
      if (firstText != null)
        'firstInput': {
          'text': firstText,
          if (attachments != null && attachments.isNotEmpty)
            'attachments': attachments,
        },
      'config': ?config,
      'runtimeModel': ?runtimeModel,
    }, timeout: timeout);
    final map = res is Map ? res.cast<String, dynamic>() : null;
    if (map?['status'] != 'accepted') {
      throw StateError(
        'createSession rejected: ${map?['reasonCode'] ?? map?['status']} ${map?['message'] ?? ''}',
      );
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('createSession: missing sessionId');
    }
    return sessionId;
  }

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    List<Map<String, dynamic>>? attachments,
  }) => sendCommand(sessionId, 'sendText', {
    'text': text,
    'heldQueueDisposition': ?heldQueueDisposition,
    if (expectedHeldQueueItemIds != null && expectedHeldQueueItemIds.isNotEmpty)
      'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
    if (attachments != null && attachments.isNotEmpty)
      'attachments': attachments,
  });

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      sendCommand(sessionId, 'setAutoDrain', {'autoDrain': autoDrain});

  Future<dynamic> stop(String sessionId) => sendCommand(sessionId, 'stop', {});

  /// 编辑已发用户消息并重发（CAS+行级，同 retryTurn 的 target 形状）：
  /// 服务端截断该回合的后续行，以新文本重跑这一轮。
  Future<dynamic> editUserQuery(
    String sessionId, {
    required int rowId,
    required String entityId,
    required String newText,
  }) => sendCommand(sessionId, 'editUserQuery', {
    // 桌面端行级 target（Ty）为 strict：rowId + entityId 必填。
    'target': {'rowId': rowId, 'entityId': entityId},
    'newText': newText,
  });

  Future<dynamic> compact(String sessionId) =>
      sendCommand(sessionId, 'compact', {});

  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    var res = await sendCommand(sessionId, 'switchModelConfig', {
      'provider': provider,
      'model': model,
      'thought': thought,
    });
    final message = res is Map ? '${res['message'] ?? ''}' : '';
    if (message.contains('Unsupported reasoning effort')) {
      // GLM family: max/high/nothink; Turbo: enabled/off.
      final fallback = (thought == 'enabled' || thought == 'off')
          ? 'max'
          : 'enabled';
      _log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  Future<dynamic> setApprovalMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setApprovalMode', {'mode': mode});

  /// 追问模式：queue（排队，跑完自动执行）/ guide（引导，立即插话转向）。
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setFollowupMode', {'mode': mode});

  /// 暂停/继续当前目标（比 stop 温和：保留现场，随时接上）。
  Future<dynamic> pauseGoal(String sessionId) =>
      sendCommand(sessionId, 'pauseGoal', {});

  Future<dynamic> resumeGoal(String sessionId) =>
      sendCommand(sessionId, 'resumeGoal', {});

  // ------------------------------------------------------------ attachments

  /// Uploads a file (begin/chunk/commit, mirrors zemote `attachmentPut`).
  /// Returns `{ref, fileName, mime, bytes}` for sendText/createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await handshake();
    final connId = connectionId;
    if (connId == null) {
      throw StateError('attachmentPut: 缺少 connectionId（桥未完成握手）');
    }
    final uploadId = 'upload-${genUuid()}';
    final base = {
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
    final chunkBytes = attachmentChunkBytes;
    final totalChunks = (bytes.length + chunkBytes - 1) ~/ chunkBytes;
    final checksum = 'sha256:${crypto.sha256.convert(bytes).toString()}';

    final beginRes = await _ch.call(convChannel, mAttachmentBegin, [
      {
        ...scope,
        ...base,
        'fileName': fileName,
        'mime': mime,
        'totalBytes': bytes.length,
        'totalChunks': totalChunks,
        'checksum': checksum,
      },
    ]);
    if (beginRes is Map && beginRes['state'] == 'committed') {
      // 服务器已存过同校验文件（秒传）。
      onProgress?.call(1);
      return {
        'ref': beginRes['ref'],
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    var nextChunk = beginRes is Map
        ? (beginRes['nextChunkIndex'] as num?)?.toInt() ?? 0
        : 0;
    for (var n = nextChunk; n < totalChunks; n++) {
      // 分片边界是唯一的取消窗口：每个 chunk 一个网络往返，延迟天然限频。
      if (isCancelled?.call() == true) {
        throw StateError('上传已取消');
      }
      final start = n * chunkBytes;
      final end = start + chunkBytes > bytes.length
          ? bytes.length
          : start + chunkBytes;
      final chunkRes = await _ch.call(convChannel, mAttachmentChunk, [
        {
          ...scope,
          ...base,
          'chunkIndex': n,
          'dataBase64': base64.encode(Uint8List.sublistView(bytes, start, end)),
        },
      ]);
      nextChunk = chunkRes is Map
          ? (chunkRes['nextChunkIndex'] as num?)?.toInt() ?? n + 1
          : n + 1;
      if (nextChunk != n + 1) {
        throw StateError('attachmentPut: 服务器分片进度异常 ($nextChunk)');
      }
      onProgress?.call(nextChunk / totalChunks);
    }
    onProgress?.call(1);
    final commitRes = await _ch.call(convChannel, mAttachmentCommit, [
      {...scope, ...base},
    ]);
    final ref = commitRes is Map ? commitRes['ref'] : null;
    if (ref is! String || ref.isEmpty) {
      throw StateError('attachmentPut: commit 未返回 ref');
    }
    return {
      'ref': ref,
      'fileName': fileName,
      'mime': mime,
      'bytes': bytes.length,
    };
  }

  /// Reads an attachment back (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async {
    await handshake();
    // 64 MB ceiling: a wedged/lying server reporting a huge totalBytes (or
    // an endless data stream) must not balloon memory into an OOM kill.
    const maxTotalBytes = 64 * 1024 * 1024;
    final chunks = BytesBuilder();
    var offset = 0;
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await _ch.call(convChannel, mAttachmentRead, [
        {
          ...scope,
          'sessionId': sessionId,
          'ref': ref,
          'offset': offset,
          'limit': attachmentChunkBytes,
        },
      ]);
      if (res is! Map) break;
      mediaType ??= res['mediaType'] as String?;
      final data = res['dataBase64'] as String?;
      if (data != null && data.isNotEmpty) {
        chunks.add(base64.decode(data));
      }
      if (chunks.length > maxTotalBytes) {
        _log('[v4] attachmentRead aborted: exceeds $maxTotalBytes bytes');
        break;
      }
      final next = (res['nextOffset'] as num?)?.toInt();
      final total = (res['totalBytes'] as num?)?.toInt();
      if (next == null || next <= offset) break;
      offset = next;
      if (total != null && offset >= total) break;
    }
    return (bytes: chunks.toBytes(), mediaType: mediaType);
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => sendCommand(sessionId, 'resolveInteraction', {
    'interactionId': interactionId,
    'answer': {
      'optionId': ?optionId,
      'freeText': ?freeText,
      'action': ?action,
      'content': ?content,
    },
  });

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'retryTurn', {'target': target});

  /// 回复点赞/点踩；feedback: 'like' / 'dislike' / null（撤销）。
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => sendCommand(sessionId, 'setAssistantFeedback', {
    'target': target,
    'feedback': ?feedback,
  });

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'sendQueuedNow', {'queueItemId': queueItemId});

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'deleteQueueItem', {'queueItemId': queueItemId});

  /// 编辑排队中的消息（payload 形状取自桌面端 zod：{queueItemId, newText}）。
  Future<dynamic> editQueueItem(
    String sessionId, {
    required String queueItemId,
    required String newText,
  }) => sendCommand(sessionId, 'editQueueItem', {
    'queueItemId': queueItemId,
    'newText': newText,
  });

  /// 队列重排：把 queueItemId 移到 beforeQueueItemId 之前
  /// （beforeQueueItemId 为 null 的语义未实测，UI 只用"移到前一项之前"）。
  Future<dynamic> reorderQueueItem(
    String sessionId, {
    required String queueItemId,
    String? beforeQueueItemId,
  }) => sendCommand(sessionId, 'reorderQueueItem', {
    'queueItemId': queueItemId,
    'beforeQueueItemId': ?beforeQueueItemId,
  });

  /// 删除会话本体（zcode-agent 通道，协议参考文档 2026-09-11 实测）。
  /// task 通道的 deleteTask 只摘任务列表条目，会话本体还活着、
  /// sessions-index 会把它送回无墓碑的设备——删除必须两通道都调。
  Future<dynamic> deleteSession(String sessionId) =>
      sendCommand(sessionId, 'deleteSession', {});

  // --------------------------------------------------------------- queries

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    await handshake();
    return _ch.call(convChannel, mRowsRange, [
      {
        ...scope,
        'sessionId': sessionId,
        'beforeRowId': ?beforeRowId,
        'limit': limit,
      },
    ]);
  }

  Future<dynamic> plans(String sessionId) async {
    await handshake();
    return _ch.call(convChannel, mPlans, [
      {...scope, 'sessionId': sessionId},
    ]);
  }

  /// conversationFileChangesV4 — 会话文件变更清单。
  /// 桌面端 3.10.1 起请求必须带行级 target + CAS（zod strict 校验，
  /// 缺了直接拒）：target = 最后一个 turnHeader 行的 {rowId, entityId}，
  /// baseRevision/baseLogEpoch 取当前快照。响应 {files, additions,
  /// deletions, items:[{path, additions, deletions, …}]}，按回合统计。
  Future<List<Map<String, dynamic>>> fileChanges(String sessionId) async {
    await handshake();
    final bundle = _lastTurnTarget(sessionId);
    final target = bundle?.target;
    if (target == null || bundle == null) return const []; // 无目标回合行，无从查询
    final res = await _ch.call(convChannel, mFileChanges, [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        'baseRevision': bundle.revision,
        'baseLogEpoch': bundle.logEpoch,
      },
    ]);
    Object? list;
    if (res is Map) {
      list = res['items'] ?? res['changes'] ?? res['files'] ?? res['result'];
      if (list == null && res['change'] is Map) list = [res['change']];
    }
    return castMapList(list);
  }

  /// conversationFileRewindPreviewV4 — 回滚预览：回滚最近回合会动哪些文件。
  /// 参数与 fileChanges 完全一致（行级 target + CAS）。
  Future<List<Map<String, dynamic>>> fileRewindPreview(String sessionId) async {
    await handshake();
    final bundle = _lastTurnTarget(sessionId);
    final target = bundle?.target;
    if (target == null || bundle == null) return const [];
    final res = await _ch.call(convChannel, mFileRewindPreview, [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        'baseRevision': bundle.revision,
        'baseLogEpoch': bundle.logEpoch,
      },
    ]);
    Object? list;
    if (res is Map) {
      list = res['items'] ?? res['changes'] ?? res['files'] ?? res['result'];
    }
    return castMapList(list);
  }

  /// applyFileRewind — 把 target 回合的文件改动回滚（CAS+行级命令）。
  /// target 自动解析为最近一个 turnHeader（与查询/预览同一回合）。
  /// 服务端按预览结果恢复文件；成功后靠 deltas/快照刷新 UI。
  Future<dynamic> applyFileRewind(String sessionId) async {
    await handshake();
    final bundle = _lastTurnTarget(sessionId);
    if (bundle == null) {
      throw StateError('applyFileRewind: 无 turnHeader，无从回滚');
    }
    return sendCommand(sessionId, 'applyFileRewind', {
      'target': bundle.target,
    });
  }

  /// 最近一个 turnHeader 行 → 行级 target + CAS 基准（三个文件接口共用，
  /// 保证查询/预览/回滚打的必须是同一个回合）。
  ({Map<String, dynamic> target, int revision, String logEpoch})?
  _lastTurnTarget(String sessionId) {
    final sub = _convSubs[sessionId];
    final st = sub?.state;
    if (st == null) return null;
    for (final r in st.rows.reversed) {
      if (r['kind'] != 'turnHeader' || r['rowId'] == null) continue;
      final entityId = '${r['entityId'] ?? r['turnId'] ?? ''}';
      if (entityId.isEmpty) continue;
      return (
        target: {'rowId': (r['rowId'] as num).toInt(), 'entityId': entityId},
        revision: st.revision,
        logEpoch: st.logEpoch ?? '',
      );
    }
    return null;
  }

  /// `zcode-task.prepareWorkspace` — 模型/思考等级/模式选项 + 斜杠命令。
  /// 返回原始结果（可能非 Map——形状变化时由上层诊断，不静默吞掉）。
  Future<Object?> prepareWorkspace() async {
    final res = await _ch.call(Chan.task, mPrepareWorkspace, [scope]);
    return res;
  }

  /// `skills.list` — 当前工作区已启用的技能。
  Future<List<Map<String, dynamic>>> skills() async {
    try {
      final res = await _ch.call(Chan.skills, 'list', [
        {
          'workspacePath': scope['workspacePath'],
          if (scope['workspaceIdentity'] != null)
            'workspaceIdentity': scope['workspaceIdentity'],
          'provider': 'glm',
        },
      ], timeout: const Duration(seconds: 20));
      final raw = res is List ? res : (res is Map ? res['skills'] : null);
      return castMapList(raw).where((s) => '${s['name']}'.isNotEmpty).toList();
    } on Object {
      return const [];
    }
  }

  Future<void> dispose() {
    // 快照副本再遍历：sub.dispose() 会同步 _untrackConv 从 _convSubs 移除，
    // 直接迭代 values 会触发 Concurrent modification during iteration
    //（切工作区时若聊天页订阅在场必现，报 _Map len:0）。
    for (final sub in _convSubs.values.toList()) {
      unawaited(sub.dispose());
    }
    _convSubs.clear();
    final index = _indexSub;
    _indexSub = null;
    bridge.recovered.removeListener(_onBridgeRecovered);
    return index?.dispose() ?? Future.value();
  }
}

// ------------------------------------------------------------ subscriptions

/// JSON 列表 → Map 列表（过滤非 Map 元素）。服务端列表字段消费的统一入口。
List<Map<String, dynamic>> castMapList(Object? raw) => raw is List
    ? [
        for (final e in raw)
          if (e is Map) e.cast<String, dynamic>(),
      ]
    : const [];

/// rowsRange 结果解析：List 直通；Map 取 rows/window/items。
/// 服务器字段名未实测，这里多形状兼容，认不出的给空列表。
List<Map<String, dynamic>> parseRowsRangeResult(Object? res) {
  Object? list = res;
  if (res is Map) {
    list = res['rows'] ?? res['window'] ?? res['items'];
    if (list == null && res['row'] is Map) list = [res['row']];
  }
  return castMapList(list);
}

/// 命令结果必须 accepted/noop/duplicate，否则抛错（UI 捕获后直接提示）。
/// createSession 内部同样用这套判定。
void requireAccepted(dynamic res) {
  if (res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate') {
    throw StateError('${res['reasonCode'] ?? res['message'] ?? res['status']}');
  }
}

/// conversationPlansV4 结果 → 最新一份计划载荷（直接喂 derivePlanSteps）。
/// 形状未实测：List 直取；Map 取 plans/result/items；逐项找 plan/value/todos。
Object? latestPlanPayload(Object? res) {
  List? plans;
  if (res is List) {
    plans = res;
  } else if (res is Map) {
    final inner = res['plans'] ?? res['result'] ?? res['items'];
    if (inner is List) {
      plans = inner;
    } else if (res['plan'] != null) {
      return res['plan'];
    } else {
      return null;
    }
  }
  if (plans == null) return null;
  for (final item in plans.reversed) {
    if (item is! Map) continue;
    if (item['plan'] is Map || item['plan'] is List) return item['plan'];
    if (item['value'] is Map || item['value'] is List) return item['value'];
    if (item['todos'] is List || item['steps'] is List) return item;
  }
  return null;
}

/// 断档重同步的单飞闸。
///
/// 为什么必须有：服务端翻页/批量重发时，40ms 微批窗口里积压的帧会**逐帧**
/// 走 gap 判定（fromSeq != seq）。无闸时每一帧都真发一次 resync——2026-09-12
/// 真机实测同一批并发 12 次 `resyncSessionsIndexV4`（耗时 650~678ms 整齐
/// 一致 = 同时起跑），每次带 `forceSnapshot` 整份替换列表并重置视口，
/// 用户看到的就是「聊天记录自己快速翻回最开头」。
///
/// 合流成一次即可：resync 是「把本地对齐到服务端」的全量操作，重复执行
/// 没有额外信息量，只放大抖动。
///
/// 抽成纯逻辑类是为了可单测（同 `FollowLock` 的做法，不依赖 Flutter）。
class ResyncGate {
  bool _inFlight = false;

  /// 是否还有一次重同步在途。
  bool get inFlight => _inFlight;

  /// 尝试占用闸门。返回 true 表示本次调用应当真发 resync；
  /// false 表示已有一次在途，本次合流掉（调用方直接返回）。
  bool tryAcquire() {
    if (_inFlight) return false;
    _inFlight = true;
    return true;
  }

  /// 释放闸门。必须在本次重同步结束时调用（含自身重试链的终点）。
  void release() {
    _inFlight = false;
  }
}

abstract class _SubBase<S extends ChangeNotifier> {
  final ConversationV4 transport;
  final S state;
  final String _logTag;

  String? _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  bool _resubscribing = false;
  Timer? _resubTimer;

  /// 断档重同步单飞闸（见 ResyncGate 注释）。
  final _resyncGate = ResyncGate();

  final _staged = <Map<String, dynamic>>[];
  final _fragments = <String, FragmentAssembler>{};
  Timer? _fragmentCleanup;

  _SubBase(this.transport, this.state, this._logTag) {
    _fragmentCleanup = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _purgeFragments(),
    );
  }

  String get _frameEventName;
  String get _subscribeMethod;
  String get _unsubscribeMethod;
  String get _resyncMethod;
  Map<String, dynamic> get _subscribeArgs;
  Map<String, dynamic> get _unsubscribeArgs;
  Map<String, dynamic> get _resyncArgs;
  String get topic;
  int get _resyncSeq;
  String? get _resyncEpoch;

  void _acceptLogicalFrame(Map<String, dynamic> frame);
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  void _purgeFragments() {
    if (_disposed) return;
    final now = DateTime.now();
    final stale = <String>[];
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      _fragments.remove(id);
    }
  }

  Future<void> _start() async {
    try {
      await transport.handshake();
      _cancelFrameListener = transport._ch.addEventListener(
        convChannel,
        _frameEventName,
        _handleWireFrame,
        arg: transport.scope,
      );
      final res = await transport._ch.call(
        convChannel,
        _subscribeMethod,
        [
          {...transport.scope, ..._subscribeArgs},
        ],
        // The desktop may need to warm the session runtime first.
        timeout: const Duration(seconds: 60),
      );
      final ack = (res as Map?)?['ack'] as Map?;
      _subscriptionId = ack?['subscriptionId'] as String?;
      transport._log('[$_logTag] subscribed id=$_subscriptionId');
      if (_subscriptionId == null) {
        throw StateError('$_subscribeMethod: missing ack.subscriptionId');
      }
      _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
      final staged = List<Map<String, dynamic>>.from(_staged);
      _staged.clear();
      for (final frame in staged) {
        _acceptLogicalFrame(frame);
      }
    } on Object {
      _cancelFrameListener?.call();
      _cancelFrameListener = null;
      _subscriptionId = null;
      _staged.clear();
      _fragments.clear();
      rethrow;
    }
  }

  void _resubscribe() {
    if (_disposed || _resubscribing) return;
    _resubscribing = true;
    unawaited(() async {
      try {
        await transport.handshake();
        _cancelFrameListener?.call();
        _cancelFrameListener = null;
        final oldId = _subscriptionId;
        _subscriptionId = null;
        _staged.clear();
        _fragments.clear();
        if (oldId != null) {
          try {
            await transport._ch.call(
              convChannel,
              _unsubscribeMethod,
              [
                {
                  ...transport.scope,
                  'subscriptionId': oldId,
                  ..._unsubscribeArgs,
                },
              ],
              // 同上：旧桥已死时这次退订本来就会失败，用短超时尽快放行，
              // 别让它在默认 30s 里干等——重连后的恢复速度全靠这一步。
              timeout: ipcUnsubscribeTimeout,
            );
          } on Object {
            // 旧桥已死时 unsubscribe 必然失败——直接换新订阅即可。
          }
        }
        await _start();
      } on Object catch (e) {
        transport._log('[$_logTag] resubscribe failed: $e');
        _resubTimer?.cancel();
        _resubTimer = Timer(const Duration(seconds: 3), () {
          if (!_disposed && _subscriptionId == null) _resubscribe();
        });
      } finally {
        _resubscribing = false;
      }
    }());
  }

  void _handleWireFrame(Object? data) {
    if (_disposed || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) _acceptOrStage(inner.cast<String, dynamic>());
      case 'fragment':
        _acceptFragment(frame);
    }
  }

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      _staged.add(frame);
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    final id = frame['logicalFrameId'] as String?;
    final index = (frame['fragmentIndex'] as num?)?.toInt();
    final count = (frame['fragmentCount'] as num?)?.toInt();
    final dataBase64 = frame['dataBase64'] as String?;
    if (id == null || index == null || count == null || dataBase64 == null) {
      return;
    }
    if (count < 1 || count > 64 || index < 0 || index >= count) return;
    final assembly = _fragments.putIfAbsent(id, () => FragmentAssembler(count));
    if (assembly.fragmentCount != count) {
      _fragments.remove(id);
      return;
    }
    try {
      assembly.add(index, base64.decode(dataBase64));
    } on FormatException {
      _fragments.remove(id);
      return;
    }
    if (assembly.isComplete) {
      _fragments.remove(id);
      try {
        final decoded = jsonDecode(utf8.decode(assembly.assemble()));
        if (decoded is Map) _acceptOrStage(decoded.cast<String, dynamic>());
      } on Object catch (e) {
        transport._log('[$_logTag] bad logical frame: $e');
      }
    }
  }

  /// 断档重同步。失败自动重试 2 次（1s/2s 退避）——resync 是断档后
  /// 唯一的恢复通道，失败即冻屏（空闲时看门狗也不兜底），必须重试。
  ///
  /// 单飞：在途时后续调用直接返回（attempt>0 的自身重试除外——重试是
  /// 同一次重同步的续命，不该被自己的闸挡住）。
  Future<void> _resync({int attempt = 0}) async {
    final id = _subscriptionId;
    if (id == null || _disposed) return;
    if (attempt == 0) {
      // 单飞：已有一次在途就合流掉，避免同批帧各发一次（见 ResyncGate）。
      if (!_resyncGate.tryAcquire()) return;
      transport._log('[$_logTag] resync (gap detected)');
    }
    try {
      await transport._ch.call(convChannel, _resyncMethod, [
        {
          ...transport.scope,
          'subscriptionId': id,
          ..._resyncArgs,
          'base': {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
        },
      ]);
    } on Object catch (e) {
      transport._log('[$_logTag] resync failed (attempt ${attempt + 1}): $e');
      if (attempt < 2 && !_disposed) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        if (!_disposed) await _resync(attempt: attempt + 1);
      }
    } finally {
      // 只有拿到闸的那次（attempt==0 的入口）负责放闸；
      // 自身重试链（attempt>0）不碰闸，避免把闸放跑。
      if (attempt == 0) _resyncGate.release();
    }
  }

  /// 幂等：ZApp._disposeBridgeStack 与 ConversationV4.dispose 会经由
  /// 不同入口对同一个 IndexSubscription 各调一次 dispose（探针实测
  /// 二次进入时 ChangeNotifier 崩 "used after being disposed"）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _resubTimer?.cancel();
    _fragmentCleanup?.cancel();
    _cancelFrameListener?.call();
    // 不在这里 dispose state：state 的所有权由持方（ZApp/ConversationV4）
    // 管理，订阅层重复释放会触发 ChangeNotifier 的 dispose 断言。
    final id = _subscriptionId;
    if (id != null) {
      try {
        await transport._ch.call(
          convChannel,
          _unsubscribeMethod,
          [
            {...transport.scope, 'subscriptionId': id, ..._unsubscribeArgs},
          ],
          // 短超时：退订是收尾动作，别让它把拆栈（进而把切项目的 UI）卡住。
          timeout: ipcUnsubscribeTimeout,
        );
      } on Object {
        // dispose 路径尽力而为：桥已断时无需清理服务端状态。
      }
    }
    _fragments.clear();
  }
}

// ------------------------------------------------------------------- state

/// Live conversation state: snapshot + rows with delta application.
class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> rows = [];
  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;

  /// 上滑翻页进行中（rowsRange 在途）。
  bool loadingOlder = false;

  /// loadOlder 合并次数（每次成功并入新历史行 +1）。
  /// 视图层靠它识别「历史端增长」：翻页插入的是旧端内容，用户看得见的
  /// 内容纹丝不动，**不需要锚定补偿**——补偿它反而把视口往历史里拽
  /// （拽近新翻页区 → 再翻页 → 再拽 = 自动回拖循环，BUG-32）。
  int olderMergeEpoch = 0;

  /// 外部（ConvSubscription）驱动 loadingOlder 并刷新。
  void setOlderLoading(bool v) {
    loadingOlder = v;
    notifyListeners();
  }

  /// 微批合并：把短时间内到达的多个 applyFrame 合并一次 notifyListeners。
  /// 流式输出时服务端可能每秒推几十帧，每帧都 notify 会导致严重掉帧。
  Timer? _batchTimer;
  final List<Map<String, dynamic>> _pendingFrames = [];
  bool _batchScheduled = false;

  void _scheduleBatchNotify(void Function() onGap) {
    if (_batchScheduled) return;
    _batchScheduled = true;
    _batchTimer?.cancel();
    _batchTimer = Timer(const Duration(milliseconds: 40), () {
      _batchScheduled = false;
      if (_pendingFrames.isNotEmpty) {
        for (final frame in _pendingFrames) {
          _applyFrameImmediate(frame, onGap: onGap);
        }
        _pendingFrames.clear();
        notifyListeners();
      }
    });
  }

  /// 立即同步刷新所有待处理帧（供测试/调试用）。
  void flushPendingFrames({required void Function() onGap}) {
    if (_pendingFrames.isEmpty) return;
    _batchTimer?.cancel();
    _batchScheduled = false;
    for (final frame in _pendingFrames) {
      _applyFrameImmediate(frame, onGap: onGap);
    }
    _pendingFrames.clear();
    notifyListeners();
  }

  /// 立即应用单帧（不触发 notify），供微批内部调用。
  void _applyFrameImmediate(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      snapshot = snap;
      if (_pendingPatch != null) {
        snapshot = {...snap, ..._pendingPatch!};
        _pendingPatch = null;
      }
      seq = toSeq;
      logEpoch = snap['logEpoch'] as String?;
      final rowsObj = snap['rows'];
      if (rowsObj is Map) {
        final window = rowsObj['window'];
        if (window is List) {
          final windowRows = castMapList(window);
          for (final r in windowRows) {
            _stampLocalTs(r);
          }
          final head = windowRows.isEmpty
              ? null
              : (windowRows.first['rowId'] as num?)?.toInt();
          final older = head == null
              ? <Map<String, dynamic>>[]
              : rows.where((r) {
                  final id = (r['rowId'] as num?)?.toInt();
                  return id != null && id < head;
                }).toList();
          rows = [...older, ...windowRows];
        } else {
          rows = [];
        }
        totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? rows.length;
        firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
      } else {
        rows = [];
        totalCount = 0;
        firstRowId = null;
      }
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        // 断档：本地 seq 对不上帧的 fromSeq，本帧 delta 不能应用（会错位），
        // 交给 resync 拉全量对齐。
        //
        // 注意：这里**故意不推进 seq**——seq 语义是「已成功应用到本地的
        // 序号」，本帧没应用就不该推进；推进了反而会把后续合法帧也误判成
        // gap（protocol_test 有专测锁定这个语义）。
        //
        // 防重复触发不靠 seq，靠 _resync 的单飞闸：40ms 微批窗口里积压的
        // 帧会逐帧调到这里，单飞闸保证这一批只真发一次 resync
        //（2026-09-12 真机实测：无闸时 12 次并发 forceSnapshot 重置视口，
        // 观感是「聊天记录自己快速翻回最开头」）。
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
      }
      seq = toSeq;
    }
    ready = true;
    // 不 notify，等微批统一触发
  }

  @override
  void dispose() {
    _batchTimer?.cancel();
    super.dispose();
  }

  /// conversationPlansV4 拉回的权威历史计划（快照 plan 为空时兜底）。
  Object? historicalPlan;

  /// 外部（ZApp）注入历史计划并刷新。
  void setHistoricalPlan(Object? plan) {
    historicalPlan = plan;
    notifyListeners();
  }

  bool get hasMoreOlder => firstRowId != null && rows.length < totalCount;

  /// 本端首次见到该行的毫秒时刻（消息时间戳显示用）。
  /// 服务端行不带时间字段，本端时钟是唯一可得来源；快照跨重启后没有
  /// 此字段 → UI 不显示时间（诚实降级，宁缺毋错）。
  void _stampLocalTs(Map<String, dynamic> row) {
    row['localTs'] ??= DateTime.now().millisecondsSinceEpoch;
  }

  /// rowsRange 拉回的更早行：去重、升序、前置合并。
  void mergeOlder(List<Map<String, dynamic>> older) {
    final known = {for (final r in rows) (r['rowId'] as num?)?.toInt(): true};
    final fresh =
        [
          for (final r in older)
            if (r['rowId'] != null &&
                !known.containsKey((r['rowId'] as num?)?.toInt()))
              r,
        ]..sort(
          (a, b) => ((a['rowId'] as num?)?.toInt() ?? 0).compareTo(
            (b['rowId'] as num?)?.toInt() ?? 0,
          ),
        );
    if (fresh.isNotEmpty) {
      for (final r in fresh) {
        _stampLocalTs(r);
      }
      rows = [...fresh, ...rows];
      firstRowId = (rows.first['rowId'] as num?)?.toInt();
      olderMergeEpoch++;
    }
    loadingOlder = false;
    notifyListeners();
  }

  Map<String, dynamic>? _pendingPatch;

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    // 快照类帧立即应用（会重置状态，不能批处理）
    final payload = frame['payload'];
    if (payload is Map && payload['kind'] == 'snapshot') {
      _pendingFrames.clear();
      _batchTimer?.cancel();
      _batchScheduled = false;
      _applyFrameImmediate(frame, onGap: onGap);
      notifyListeners();
      return;
    }
    // deltas 类帧进入微批队列
    _pendingFrames.add(frame);
    _scheduleBatchNotify(onGap);
  }

  /// 流式 delta 打在最新的行上（窗口尾部），从尾部反着找省掉全列表扫描。
  int _lastIndexOfRow(int? rowId) {
    if (rowId == null) return -1;
    for (var i = rows.length - 1; i >= 0; i--) {
      if ((rows[i]['rowId'] as num?)?.toInt() == rowId) return i;
    }
    return -1;
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        _stampLocalTs(row);
        rows = [...rows, row];
        totalCount += 1;
        firstRowId ??= (row['rowId'] as num?)?.toInt();
      case 'row.upserted':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final index = _lastIndexOfRow((row['rowId'] as num?)?.toInt());
        if (index != -1) {
          // 服务端新拷贝不带本端时间：原行的 localTs 是首次接收时刻，
          // 必须搬过来，否则每次行更新时间戳都会跳成"刚刚"。
          final prevTs = rows[index]['localTs'];
          if (prevTs != null) row['localTs'] = prevTs;
          rows = [...rows]..[index] = row;
        }
      case 'row.removed':
        // Keep rows with rowId < fromRowId (remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        rows = kept;
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
      case 'row.delta':
        final path = delta['path'] as String?;
        final append = delta['append'] as String? ?? '';
        final index = _lastIndexOfRow((delta['rowId'] as num?)?.toInt());
        if (index != -1) {
          rows = [...rows]..[index] = _appendToRow(rows[index], path, append);
        }
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          if (snapshot != null) {
            // config 只该被更新不该被替换：服务端 patch 常只带 provider/model，
            // 整包替换会把 approvalMode/followupMode 这类没变的键抹掉。
            final oldConfig = snapshot!['config'];
            snapshot = {...snapshot!, ...patch.cast<String, dynamic>()};
            final newConfig = snapshot!['config'];
            if (oldConfig is Map && newConfig is Map) {
              snapshot!['config'] = {
                ...oldConfig.cast<String, dynamic>(),
                ...newConfig.cast<String, dynamic>(),
              };
            }
          } else {
            _pendingPatch = {
              ...?_pendingPatch,
              ...patch.cast<String, dynamic>(),
            };
          }
        }
    }
  }

  Map<String, dynamic> _appendToRow(
    Map<String, dynamic> row,
    String? path,
    String append,
  ) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
        }
        return row;
      default:
        return row;
    }
  }

  // Convenience getters over the snapshot.

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  int get revision => (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  /// 会话级出错（时间线可能没有任何错误行，UI 需在回复位补错误卡）。
  bool get hasErrorPhase => isErrorPhase(phase);

  /// 快照里捞得到的错误详情；服务端没带时为 null，UI 给人话兜底。
  String? get conversationError => extractConversationError(snapshot);

  bool get canStop => control?['canStop'] == true;

  /// 会话是否"在忙"（含排队）。
  ///
  /// `queued` 必须算进来：排队中的消息还没被执行，用户此时再发就是叠队列，
  /// 界面上也该表现为"忙"。旧定义漏了它，导致排队态被当成空闲——列表角标
  /// 和输入区状态都会误导。
  bool get isRunning => isBusyPhase(phase);

  /// 是否真的在产出（可以停止）。排队中还没开始跑，不该给「停止」。
  bool get isProducing => isProducingPhase(phase);

  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  String get currentModel => config?['model'] as String? ?? '';
  String get currentProvider => config?['provider'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';

  /// 服务端回显的原始 approvalMode（可能不在词汇表内，如 Codex 的 on-failure）。
  String get rawApprovalMode => config?['approvalMode'] as String? ?? '';

  /// 归一后的 approvalMode；服务端不上报或词汇表外时给 ''，由 UI 用本地记录兜底。
  String get currentApprovalMode =>
      canonicalApprovalMode(rawApprovalMode) ?? '';

  String get currentFollowupMode =>
      config?['followupMode'] as String? ?? 'queue';

  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems => castMapList(queue?['items']);

  bool get autoDrain => queue?['autoDrain'] != false;

  Map<String, dynamic>? get usage =>
      (snapshot?['usage'] as Map?)?.cast<String, dynamic>();

  /// 上下文窗口 used / max（缺失或 maxTokens 非法给 null，UI 据此隐藏）。
  /// 解析只在这一处，进度条/表头/弹层共用。
  ({num used, num max})? get contextWindowUsage {
    final cw = usage?['contextWindow'];
    if (cw is! Map) return null;
    final max = cw['maxTokens'];
    if (max is! num || max <= 0) return null;
    return (used: (cw['usedTokens'] as num?) ?? 0, max: max);
  }

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  /// 目标是否处于暂停（goal 形状未实测：paused 布尔 / state·status 字符串都认）。
  bool get goalPaused {
    final g = goal;
    if (g == null) return false;
    if (g['paused'] == true) return true;
    return '${g['state'] ?? g['status'] ?? ''}' == 'paused';
  }

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get pendingInteractions =>
      castMapList(snapshot?['pendingInteractions']);

  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    notifyListeners();
  }
}

/// One session row entry in the chat list rendering order.
class SessionEntry {
  final Map<String, dynamic> raw;
  SessionEntry(this.raw);

  String get sessionId => '${raw['sessionId'] ?? ''}';
  String get title => '${raw['title'] ?? ''}';
  String get phase => '${raw['phase'] ?? ''}';
  String? get lastAssistantPreview => raw['lastAssistantPreview'] as String?;
  int get lastActivityAt => (raw['lastActivityAt'] as num?)?.toInt() ?? 0;
  Map<String, dynamic>? get pendingInteraction =>
      (raw['pendingInteraction'] as Map?)?.cast<String, dynamic>();
}

/// Live sessions-index (workspace task list).
class SessionsIndexState extends ChangeNotifier {
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  /// 排好序的快照：每次 applyFrame 重建一次，读取方（合并任务卡）不再各自排序。
  List<SessionEntry> _sorted = const [];
  List<SessionEntry> get list => _sorted;

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry = SessionEntry(s.cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        // 同 ConversationState：不推进 seq（seq 只记「已应用」的序号），
        // 防重复发起 resync 交给 _resync 的单飞闸。
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.removed') {
            sessions.remove('${d['sessionId']}');
          } else if (d['session'] is Map) {
            // session.upserted 及其它携带全量 session 的 op 一律按
            // upsert 收——只认一种 op 名会把 phase 更新静默丢掉，
            // 外面任务列表就冻结成旧状态（里跑外闲）。
            final entry = SessionEntry(
              (d['session'] as Map).cast<String, dynamic>(),
            );
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
    }
    _sorted = sessions.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    ready = true;
    notifyListeners();
  }
}

class ConvSubscription extends _SubBase<ConversationState> {
  final String sessionId;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  ConvSubscription._(ConversationV4 transport, this.sessionId)
    : super(transport, ConversationState(), 'v4');

  @override
  String get _frameEventName => evConvFrame;
  @override
  String get _subscribeMethod => mSubscribeConv;
  @override
  String get _unsubscribeMethod => mUnsubscribeConv;
  @override
  String get _resyncMethod => mResyncConv;
  @override
  Map<String, dynamic> get _subscribeArgs => {'sessionId': sessionId};
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  String get topic => 'conversation/$sessionId';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    if (ack['logEpoch'] is String) state.logEpoch = ack['logEpoch'] as String;
    _startWatchdog();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = _subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _lastFrameAt = DateTime.now();
    state.applyFrame(frame, onGap: _resync);
    _scheduleQueueDedup();
  }

  // ---- 队列自动去重（定时消息防堆积） ------------------------------
  //
  // 定时任务/自动化由桌面端直接把文本塞进服务端队列，绕过手机端
  // 「重复不入队」的发送守卫——1 分钟级提醒在忙会话上会堆出十几条
  // 一模一样的排队项（2026-09-12 用户截图实证 13 条）。客户端拦不住
  // 入队，只能在队列里看到重复时删掉多余的：同一文本（trim 后）出现
  // 多次只保留队首一条，删除走 deleteQueueItem，全设备同步生效。

  bool _queueDedupScheduled = false;
  bool _queueDedupBusy = false;

  void _scheduleQueueDedup() {
    if (_queueDedupScheduled || _queueDedupBusy || _disposed) return;
    _queueDedupScheduled = true;
    scheduleMicrotask(() {
      _queueDedupScheduled = false;
      if (!_disposed) _pruneDuplicateQueueItems();
    });
  }

  Future<void> _pruneDuplicateQueueItems() async {
    if (_queueDedupBusy) return;
    final dupIds = duplicateQueueItemIds(state.queueItems);
    if (dupIds.isEmpty) return;
    _queueDedupBusy = true;
    try {
      for (final id in dupIds) {
        try {
          await transport.deleteQueueItem(sessionId, id);
          transport._log('[queue] 自动去重: 删除重复排队项 $id');
        } on Object catch (e) {
          transport._log('[queue] 自动去重删除失败 $id: $e');
        }
      }
    } finally {
      _queueDedupBusy = false;
    }
    // 删完后的快照帧会再次触发 _scheduleQueueDedup，残余重复自然收敛。
  }

  /// Streaming can stall silently after a network blip; a quiet period
  /// while the session is supposed to be active triggers a resync.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      final quiet = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (quiet < 20) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        transport._log('[v4] watchdog: no frames for ${quiet}s, resync');
        _resync();
        return;
      }
      // 空闲兜底：长时间（5 分钟）无任何帧，疑似断档漏更新——低频重同步。
      // resync 成功后快照帧会刷新 _lastFrameAt，自动节流到每 5 分钟一次。
      if (quiet >= 300) {
        transport._log('[v4] watchdog: idle ${quiet}s, periodic resync');
        _resync();
      }
    });
  }

  /// 上滑翻页：拉更早的行前置合并（hasMoreOlder 才发请求）。
  Future<void> loadOlder({int limit = 60}) async {
    // 翻页游标 = **窗口内最小 rowId**（不是服务端快照的 firstRowId——
    // 那是会话首行 id，恒为 1，拿它当游标会请求"row 1 之前"=空集，
    // 翻页永久卡死；BUG-28 源头）。
    var head = 0;
    var have = false;
    for (final r in state.rows) {
      final id = (r['rowId'] as num?)?.toInt();
      if (id == null) continue;
      if (!have || id < head) {
        head = id;
        have = true;
      }
    }
    if (!have) return;
    if (state.loadingOlder || !state.hasMoreOlder) return;
    state.setOlderLoading(true);
    try {
      final res = await transport.rowsRange(
        sessionId,
        beforeRowId: head,
        limit: limit,
      );
      final older = [
        for (final r in parseRowsRangeResult(res))
          if (((r['rowId'] as num?)?.toInt() ?? head) < head) r,
      ];
      state.mergeOlder(older);
    } on Object catch (e) {
      state.setOlderLoading(false);
      transport._log('[v4] rowsRange failed: $e');
    }
  }

  /// 下拉强制重同步：让服务端按 forceSnapshot 重发全量快照（观感卡住时自救）。
  Future<void> forceResync() => _resync();

  @override
  Future<void> dispose() async {
    _watchdog?.cancel();
    transport._untrackConv(sessionId);
    await super.dispose();
  }
}

class IndexSubscription extends _SubBase<SessionsIndexState> {
  IndexSubscription._(ConversationV4 transport)
    : super(transport, SessionsIndexState(), 'v4-si');

  @override
  String get _frameEventName => evIndexFrame;
  @override
  String get _subscribeMethod => mSubscribeIndex;
  @override
  String get _unsubscribeMethod => mUnsubscribeIndex;
  @override
  String get _resyncMethod => mResyncIndex;
  // 订阅**不能**带 existing-only：该策略的语义是"只准挂到已经在跑的运行时上"，
  // 目标工作区的 agent 运行时没在跑时，桌面端会在 1ms 内直接拒绝
  // （ZCode Agent runtime is not running.）——切项目必然报错。
  // 不传这个字段时桌面端默认走 start-if-needed，会按需把运行时拉起来。
  @override
  Map<String, dynamic> get _subscribeArgs => const {};
  // 退订 / 重订阅保持 existing-only：清理与断线恢复路径不该顺手启动运行时。
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {
    'runtimePolicy': 'existing-only',
  };
  @override
  Map<String, dynamic> get _resyncArgs => const {
    'runtimePolicy': 'existing-only',
  };

  /// 断线重连后的对账入口（同 ConvSubscription.forceResync）。
  Future<void> forceResync() => _resync();
  @override
  String get topic =>
      'sessions-index/${transport.scope['workspaceIdentity'] ?? transport.scope['workspacePath']}';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = _subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    state.applyFrame(frame, onGap: _resync);
  }
}
