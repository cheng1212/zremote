import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'constants.dart';
import 'link_params.dart';
import 'proof.dart';

enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

/// Close-code mapping from the relay server.
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// Relay terminal socket: JSON text frames over `wss://<host>/ws`.
class RelayClient {
  final LinkParams params;
  final void Function(String line)? onLog;

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  int _generation = 0;
  bool _connectInFlight = false;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  ValueListenable<RelayState> get stateListenable => _state;
  RelayState get state => _state.value;

  final _payloads = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _heartbeatTick = 0;
  DateTime _lastPairAckAt = DateTime.now();
  DateTime _lastInboundAt = DateTime.now();

  Timer? _heartbeat;
  Timer? _waitingTimer;
  Timer? _reconnectTimer;
  Timer? _rewaitTimer;

  /// Outbound payloads queued while unpaired, flushed once matched.
  final _outbound = <Map<String, dynamic>>[];

  RelayClient(this.params, {this.onLog});

  void _log(String line) => onLog?.call(line);

  void _setState(RelayState s) {
    _state.value = s;
    _log('[relay] state -> $s');
  }

  Future<void> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _setState(RelayState.connecting);
    await _connect();
  }

  Future<void> _connect() async {
    if (_connectInFlight || _disposed) return;
    _connectInFlight = true;
    final generation = ++_generation;
    await _socketSub?.cancel();
    _socketSub = null;
    unawaited(_socket?.sink.close());
    _socket = null;
    _lastPairAckAt = DateTime.now();
    _lastInboundAt = DateTime.now();
    final uri = params.relayWsUri;
    _log('[relay] connecting ${uri.host}/ws');
    WebSocketChannel socket;
    try {
      socket = WebSocketChannel.connect(uri);
      await socket.ready;
    } catch (e) {
      _connectInFlight = false;
      _log('[relay] connect failed: $e');
      if (generation == _generation) _handleClosed(1006, '$e');
      return;
    }
    if (_disposed || generation != _generation) {
      unawaited(socket.sink.close());
      _connectInFlight = false;
      return;
    }
    _socket = socket;
    _socketSub = socket.stream.listen(
      (data) => _handleRaw(data, generation: generation),
      onError: (Object e) => _log('[relay] socket error: $e'),
      onDone: () => _handleClosed(socket.closeCode ?? 1006, socket.closeReason),
    );
    _connectInFlight = false;
    _setState(RelayState.authenticating);
    _sendFrame({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': platformName,
        'version': params.appVersion ?? 'zremote',
        'name': 'zremote',
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _sendFrame(Map<String, dynamic> frame) {
    _socket?.sink.add(jsonEncode(frame));
  }

  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outbound.length < 100) {
        _log('[relay] queued (state=$state): ${payload['zcode_type']}');
        _outbound.add(payload);
      }
      return;
    }
    _sendFrame({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _flushOutbound() {
    if (_outbound.isEmpty) return;
    _log('[relay] flushing ${_outbound.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outbound);
    _outbound.clear();
    for (final payload in queued) {
      _sendFrame({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _handleRaw(dynamic data, {required int generation}) {
    if (generation != _generation || _disposed) return;
    _lastInboundAt = DateTime.now();
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay] bad frame: $e');
      return;
    }
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_challenge':
        _sendFrame({
          'type': 'auth_response',
          'device_sid': params.deviceSid,
          'proof': calculateProof(
            passHash: params.passHash,
            nonce: frame['nonce'] as String? ?? '',
            role: 'terminal',
            deviceSid: params.deviceSid,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
      case 'auth_ack':
      case 'pair_status_ack':
        _applyPairStatus(frame['pair_status'] as String?);
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) _payloads.add(payload);
      case 'error':
        _handleError(frame['code'] as String?, frame['message'] as String?);
    }
  }

  void _applyPairStatus(String? status) {
    _lastPairAckAt = DateTime.now();
    if (status == 'waiting') {
      if (_wasPaired) {
        _waitingTimer?.cancel();
        _setState(RelayState.waiting);
        _startHeartbeat();
        // An already-paired client should be matched immediately after a
        // reconnect; if the server keeps saying "waiting", rebuild.
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(relayWaitingTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay] re-pair stuck in waiting, reconnecting');
            _reconnect();
          }
        });
      } else {
        _setState(RelayState.waiting);
        _waitingTimer?.cancel();
        _waitingTimer = Timer(relayWaitingTimeout, () {
          if (state == RelayState.waiting && !_wasPaired) {
            _setState(RelayState.error);
          }
        });
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _waitingTimer?.cancel();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutbound();
    }
  }

  void _handleError(String? code, String? message) {
    _log('[relay] error frame: $code $message');
    if (code == 'KICKED') {
      _setState(RelayState.kicked);
      _intentionallyClosed = true;
      _socket?.sink.close();
    }
  }

  void _handleClosed(int code, String? reason) {
    if (_disposed) return;
    _heartbeat?.cancel();
    _waitingTimer?.cancel();
    final mapped = relayCloseReason(code);
    _log('[relay] closed code=$code reason=$reason mapped=$mapped');
    if (_intentionallyClosed) return;
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(relayHeartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      _heartbeatTick++;
      if (state == RelayState.waiting && _heartbeatTick.isOdd) return;
      if (DateTime.now().difference(_lastPairAckAt) >
          relayHeartbeatAckTimeout) {
        _log('[relay] heartbeat ack timeout, reconnecting');
        _reconnect();
        return;
      }
      _sendFrame({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// Probe immediately (app resume): reconnect when the link looks dead.
  void poke() {
    if (_disposed || _intentionallyClosed) return;
    if (state == RelayState.paired) {
      if (DateTime.now().difference(_lastInboundAt) > const Duration(seconds: 25)) {
        _log('[relay] poke: stale link, reconnecting');
        _reconnect();
        return;
      }
      _sendFrame({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (state != RelayState.idle &&
        state != RelayState.closed &&
        state != RelayState.kicked) {
      _reconnectTimer?.cancel();
      _connect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final baseDelayMs =
        (1000 * (1 << _reconnectAttempt.clamp(0, 4))).clamp(1000, relayReconnectMaxBackoffMs);
    // ±25% 抖动，防多设备同时重连撞车
    final jitter = (baseDelayMs * 0.25 * (Random().nextDouble() * 2 - 1)).round();
    final delayMs = (baseDelayMs + jitter).clamp(1000, relayReconnectMaxBackoffMs);
    _reconnectAttempt += 1;
    _log('[relay] reconnect in ${delayMs}ms (base ${baseDelayMs}ms, jitter ${jitter}ms)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  Future<void> _reconnect() async {
    if (_disposed || _intentionallyClosed || _connectInFlight) return;
    _reconnectTimer?.cancel();
    _setState(RelayState.reconnecting);
    await _connect();
  }

  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _heartbeat?.cancel();
    _waitingTimer?.cancel();
    _reconnectTimer?.cancel();
    _rewaitTimer?.cancel();
    await _socketSub?.cancel();
    unawaited(_socket?.sink.close());
    _setState(RelayState.closed);
    await _payloads.close();
  }
}
