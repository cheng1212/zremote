import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'constants.dart';
import 'link_params.dart';
import 'relay_client.dart';
import 'rpc_frames.dart';

/// High-level facade: relay connect -> pair -> bootstrap -> workspace bridge.
class RemoteSession {
  final LinkParams params;
  final void Function(String line)? onLog;

  late final RelayClient relay;
  final _matchers = <String, bool Function(Map<String, dynamic>)>{};
  final _completers = <String, Completer<Map<String, dynamic>>>{};
  StreamSubscription? _payloadSub;

  final _workspaceListUpdated = StreamController<dynamic>.broadcast();
  Stream<dynamic> get workspaceListUpdated => _workspaceListUpdated.stream;

  RemoteSession(this.params, {this.onLog}) {
    relay = RelayClient(params, onLog: onLog);
    _payloadSub = relay.payloads.listen(_dispatch);
    relay.stateListenable.addListener(_onRelayState);
  }

  void _log(String line) => onLog?.call(line);

  Future<void> connect() => relay.start();

  final _activeBridges = <Bridge>[];
  bool _needsBridgeRecovery = false;

  /// 断线后重新配对成功的回调（每次真实重连恰好触发一次）。
  /// 上层（ZApp）在这里做状态对账：清本地相位覆盖、强制重同步订阅、
  /// 重拉任务列表——桌面端可能已崩溃重启，一切以服务端为准（BUG-34）。
  void Function()? onRePaired;

  void _onRelayState() {
    final s = relay.state;
    if (s == RelayState.reconnecting || s == RelayState.error) {
      if (_activeBridges.isNotEmpty) {
        _needsBridgeRecovery = true;
        for (final b in _activeBridges) {
          b.degraded.value ??= 'reconnecting';
        }
      }
      return;
    }
    if (s == RelayState.paired && _needsBridgeRecovery) {
      _needsBridgeRecovery = false;
      for (final b in List<Bridge>.from(_activeBridges)) {
        unawaited(b.recoverWithRetry());
      }
      // 桥恢复只是链路层；数据层的对账交给上层（清覆盖/重同步/重拉列表）。
      unawaited(Future.sync(() => onRePaired?.call()));
    }
  }

  /// Waits until the relay is paired with the desktop.
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) {
    if (relay.state == RelayState.paired) return Future.value();
    final completer = Completer<void>();
    Timer? timer;
    void listener() {
      if (relay.state == RelayState.paired && !completer.isCompleted) {
        timer?.cancel();
        completer.complete();
      }
    }

    relay.stateListenable.addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.completeError(TimeoutException('配对超时'));
    });
    return completer.future.whenComplete(() {
      timer?.cancel();
      relay.stateListenable.removeListener(listener);
    });
  }

  void _dispatch(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type == pushWorkspaceListUpdated) {
      _workspaceListUpdated.add(payload['result']);
      return;
    }
    if (type == pushBridgeDegraded) {
      final id = payload['bridgeSessionId'] as String?;
      final reason = '${payload['reason'] ?? 'unknown'}';
      _log('[bridge] degraded: $id reason=$reason');
      for (final b in _activeBridges) {
        if (b.info['bridgeSessionId'] == id) {
          b.degraded.value = reason;
          unawaited(b.recoverWithRetry());
        }
      }
      return;
    }
    if (type == 'rpc-frame' || type == 'rpc-frame-ack') {
      final id = payload['bridgeSessionId'] as String?;
      final bridge = id == null ? null : _frameRouters[id];
      if (bridge != null) {
        bridge.frames.accept(payload);
      } else if (id != null) {
        (_pendingBridgePayloads[id] ??= []).add(payload);
      }
      return;
    }
    // Signaling request/response: matchers keyed by requestId. Responses are
    // not guaranteed to echo the id, so every matcher gets a chance.
    final done = <String>[];
    _matchers.forEach((requestId, match) {
      final completer = _completers[requestId];
      if (completer != null && !completer.isCompleted && match(payload)) {
        done.add(requestId);
        completer.complete(payload);
      }
    });
    for (final id in done) {
      _matchers.remove(id);
      _completers.remove(id);
    }
  }

  Future<Map<String, dynamic>> request(
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final requestId = payload['requestId'] as String;
    final completer = Completer<Map<String, dynamic>>();
    _matchers[requestId] = match;
    _completers[requestId] = completer;
    relay.sendPayload(payload);
    return completer.future.timeout(timeout, onTimeout: () {
      _matchers.remove(requestId);
      _completers.remove(requestId);
      throw TimeoutException('request $requestId timed out');
    });
  }

  /// bootstrap-request → bootstrap-response（任务列表总览）。
  Future<Map<String, dynamic>> bootstrap() async {
    final res = await request(
      {'zcode_type': sigBootstrap, 'requestId': genId('boot')},
      (p) => p['zcode_type'] == sigBootstrapResponse,
    );
    return (res['result'] as Map?)?.cast<String, dynamic>() ?? res;
  }

  Future<void> sendViewState({
    required String workspaceKey,
    String? taskId,
  }) {
    relay.sendPayload({
      'zcode_type': sigViewStateUpdate,
      'viewState': {
        'activeWorkspaceKey': workspaceKey,
        'activeTaskId': ?taskId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': {
        'platform': platformName,
        'version': params.appVersion ?? 'zremote',
        'name': 'zremote',
      },
    });
    return Future.value();
  }

  final _frameRouters = <String, Bridge>{};
  final _pendingBridgePayloads = <String, List<Map<String, dynamic>>>{};
  int _bridgeGeneration = 0;

  /// workspace-bridge-open → workspace-bridge-ready → rpc-frame/IPC stack.
  Future<Bridge> openBridge(
    String workspaceKey, {
    String? taskId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final requestedId = genId('bridge');
    final generation = ++_bridgeGeneration;
    final res = await request(
      {
        'zcode_type': sigBridgeOpen,
        'requestId': genId('open'),
        'bridgeSessionId': requestedId,
        'bridgeGeneration': generation,
        'workspaceKey': workspaceKey,
        'taskId': ?taskId,
      },
      (p) =>
          (p['zcode_type'] == sigBridgeReady ||
              p['zcode_type'] == sigBridgeError) &&
          p['bridgeSessionId'] == requestedId,
      timeout: timeout,
    );
    if (res['zcode_type'] == sigBridgeError) {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final info =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('[bridge] ready: $info');
    final bridge = Bridge._(session: this, info: info);
    _attachStack(bridge, info);
    _activeBridges.add(bridge);
    final key = (info['workspaceKey'] as String?) ?? workspaceKey;
    unawaited(
        sendViewState(workspaceKey: key, taskId: bridge.initialTaskId ?? taskId));
    return bridge;
  }

  void _attachStack(Bridge bridge, Map<String, dynamic> info) {
    bridge._swapStack(info, _buildFrames(bridge, info));
    final id = info['bridgeSessionId'] as String? ?? '';
    _frameRouters[id] = bridge;
    final pending = _pendingBridgePayloads.remove(id);
    if (pending != null) {
      for (final payload in pending) {
        bridge.frames.accept(payload);
      }
    }
  }

  RpcFrames _buildFrames(Bridge bridge, Map<String, dynamic> info) {
    return RpcFrames(
      bridgeSessionId: '${info['bridgeSessionId'] ?? ''}',
      bridgeGeneration: (info['bridgeGeneration'] as num?)?.toInt(),
      recoveryId: info['recoveryId'] as String?,
      send: relay.sendPayload,
      onMessage: (bytes) => bridge.channels.handleMessage(bytes),
      onLog: onLog,
    );
  }

  Future<void> pokeRelay() async {
    relay.poke();
  }

  Future<void> dispose() async {
    relay.stateListenable.removeListener(_onRelayState);
    await _payloadSub?.cancel();
    for (final b in List<Bridge>.from(_activeBridges)) {
      b.dispose();
    }
    await relay.dispose();
    await _workspaceListUpdated.close();
  }
}

/// One workspace bridge: rpc-frame transport + channel client.
class Bridge {
  final RemoteSession session;
  Map<String, dynamic> info;
  late RpcFrames _frames;
  late ChannelClient channels;

  /// 转发 rpc-frame 分片入口（信令层按 bridgeSessionId 路由用）。
  RpcFrames get frames => _frames;

  /// Non-null while degraded (reconnecting / rpc-transport-fault).
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  /// Bumped when the stack is swapped after recovery; subscriptions must
  /// resubscribe since server-side state died with the old bridge.
  final ValueNotifier<int> recovered = ValueNotifier(0);

  bool _disposed = false;

  Bridge._({required this.session, required this.info}) {
    _frames = RpcFrames(
      bridgeSessionId: '${info['bridgeSessionId'] ?? ''}',
      send: session.relay.sendPayload,
      onMessage: (bytes) => channels.handleMessage(bytes),
      onLog: session.onLog,
    );
    channels = ChannelClient(sendBody: _frames.sendMessage, onLog: session.onLog);
  }

  void _swapStack(Map<String, dynamic> newInfo, RpcFrames frames) {
    final old = _frames;
    _frames = frames;
    info = newInfo;
    channels = ChannelClient(sendBody: frames.sendMessage, onLog: session.onLog);
    old.dispose();
  }

  String? get workspaceKey => info['workspaceKey'] as String?;
  String? get initialTaskId => info['initialTaskId'] as String?;

  Map<String, dynamic> get scope => {
        'workspacePath': info['workspacePath'] ?? workspaceKey,
        if (info['workspaceIdentity'] != null)
          'workspaceIdentity': info['workspaceIdentity'],
      };

  /// Resolves once healthy, or throws [TimeoutException].
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) {
    if (_disposed || degraded.value == null) return Future.value();
    final completer = Completer<void>();
    void check() {
      if (degraded.value == null && !completer.isCompleted) completer.complete();
    }

    degraded.addListener(check);
    check();
    return completer.future.timeout(timeout, onTimeout: () {
      degraded.removeListener(check);
      throw TimeoutException('bridge 恢复超时: ${degraded.value}');
    }).whenComplete(() => degraded.removeListener(check));
  }

  /// Retries recovery until the bridge is healthy again.
  Future<void> recoverWithRetry() async {
    if (_disposed) return;
    for (var attempt = 1; attempt <= 8; attempt++) {
      if (_disposed) return;
      if (await _recoverOnce()) return;
      if (_disposed) return;
      session.onLog?.call('[bridge] recovery attempt $attempt failed');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<bool> _recoverOnce() async {
    final key = workspaceKey;
    if (key == null) {
      degraded.value = null;
      return true;
    }
    degraded.value = 'recovering';
    // 1) cheap path: workspace-reconnect-request
    try {
      final res = await session.request(
        {
          'zcode_type': sigBridgeReconnect,
          'requestId': genId('reconn'),
          'workspaceKey': key,
        },
        (p) =>
            p['zcode_type'] == sigBridgeReconnectResponse &&
            p['workspaceKey'] == key,
        timeout: const Duration(seconds: 15),
      );
      if (res['success'] == true) {
        degraded.value = null;
        recovered.value += 1;
        return true;
      }
    } on Object {
      // fall through to reopen
    }
    // 2) full reopen with recoveryId
    final requestedId = genId('bridge');
    final generation = ++session._bridgeGeneration;
    try {
      final res = await session.request(
        {
          'zcode_type': sigBridgeOpen,
          'requestId': genId('reopen'),
          'bridgeSessionId': requestedId,
          'bridgeGeneration': generation,
          if (info['recoveryId'] != null) 'recoveryId': info['recoveryId'],
          'workspaceKey': key,
        },
        (p) =>
            (p['zcode_type'] == sigBridgeReady ||
                p['zcode_type'] == sigBridgeError) &&
            p['bridgeSessionId'] == requestedId,
        timeout: const Duration(seconds: 30),
      );
      if (res['zcode_type'] == sigBridgeError) {
        throw StateError('${res['error'] ?? res}');
      }
      final newInfo =
          (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final oldRouterId = '${info['bridgeSessionId'] ?? ''}';
      session._frameRouters.remove(oldRouterId);
      session._attachStack(this, newInfo);
      degraded.value = null;
      recovered.value += 1;
      session.onLog?.call('[bridge] reopened $key');
      return true;
    } on Object catch (e) {
      degraded.value = 'reopen-failed: $e';
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    degraded.dispose();
    recovered.dispose();
    channels.dispose();
    _frames.dispose();
    session._activeBridges.remove(this);
    session._frameRouters.remove('${info['bridgeSessionId'] ?? ''}');
  }
}
