import 'dart:async';
import 'dart:typed_data';

import 'constants.dart';
import 'value_codec.dart';

class ChannelRpcError implements Exception {
  final String message;
  ChannelRpcError(this.message);

  @override
  String toString() => 'ChannelRpcError: $message';
}

/// Channel RPC over the bridge: request header
/// `[reqType, reqId, channelName, name]` + argument value.
class ChannelClient {
  final void Function(Uint8List body) sendBody;
  final void Function(String line)? onLog;

  int _lastRequestId = 0;
  final _ready = Completer<void>();
  final _handlers = <int, void Function(int type, Object? data)>{};
  final _pending = <int, Completer<dynamic>>{};
  bool _disposed = false;

  ChannelClient({required this.sendBody, this.onLog});

  Future<void> get ready => _ready.future;

  void handleMessage(Uint8List body) {
    try {
      final reader = ValueReader(body);
      final header = reader.readValue();
      if (header is! List || header.isEmpty || header[0] is! num) return;
      final type = (header[0] as num).toInt();
      if (type == ipcResInitialize) {
        onLog?.call('[ipc] initialized');
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      if (header.length < 2 || header[1] is! num) return;
      final id = (header[1] as num).toInt();
      final data = reader.readValue();
      _handlers[id]?.call(type, data);
    } on Object catch (e) {
      onLog?.call('[ipc] invalid frame: $e');
    }
  }

  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // 桥已拆：调用方还在排队的收尾动作要立刻知道，别干等满超时。
    if (_disposed) throw StateError('channel disposed');
    await ready.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw TimeoutException('channel init timeout');
      },
    );
    final id = _lastRequestId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _handlers[id] = (type, data) {
      switch (type) {
        case ipcResPromiseSuccess:
          _handlers.remove(id);
          _pending.remove(id);
          completer.complete(data);
        case ipcResPromiseError:
          _handlers.remove(id);
          _pending.remove(id);
          final message = data is Map
              ? (data['message'] ?? data).toString()
              : '$data';
          completer.completeError(ChannelRpcError(message));
        case ipcResPromiseErrorObj:
          _handlers.remove(id);
          _pending.remove(id);
          completer.completeError(ChannelRpcError('$data'));
      }
    };
    onLog?.call('[ipc] call $channel.$method id=$id');
    _send(ipcReqPromise, id, channel, method, args);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _handlers.remove(id);
        _pending.remove(id);
        throw TimeoutException('$channel.$method timed out', timeout);
      },
    );
  }

  /// Subscribe to a channel event; returns a cancel function.
  void Function() addEventListener(
    String channel,
    String event,
    void Function(Object? event) onEvent, {
    Object? arg,
  }) {
    final id = _lastRequestId++;
    var sent = false;
    var cancelled = false;
    _handlers[id] = (type, data) {
      if (type == ipcResEventFire) onEvent(data);
    };
    ready.then((_) {
      if (cancelled) return;
      sent = true;
      onLog?.call('[ipc] listen $channel.$event id=$id');
      _send(ipcReqEventListen, id, channel, event, arg);
    });
    return () {
      cancelled = true;
      _handlers.remove(id);
      if (sent) _send(ipcReqEventDispose, id, channel, event, null);
    };
  }

  void _send(int reqType, int id, String channel, String name, Object? arg) {
    final writer = ValueWriter();
    writer.writeValue([reqType, id, channel, name]);
    writer.writeValue(arg);
    sendBody(writer.take());
  }

  /// 桥栈切换时在途调用立即报错，别让调用方干等满超时（表现为"点了没反应"）。
  /// 置 `_disposed` 后**后续**调用也会立刻报错——拆栈期间还有收尾动作在排队
  /// 时，它们不该各自再等一次完整超时。
  void dispose() {
    _disposed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('channel disposed'));
      }
    }
    _pending.clear();
    _handlers.clear();
  }
}
