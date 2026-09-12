import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';
import 'crc32.dart';
import 'fragment_assembler.dart';

/// rpc-frame fragmentation transport over relay payloads.
///
/// Logical messages are split so each JSON envelope stays below 1 MiB; each
/// message carries a crc32 checksum; the peer acknowledges assembled
/// messages with `rpc-frame-ack`.
class RpcFrames {
  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;
  final void Function(Map<String, dynamic> payload) send;
  final void Function(Uint8List message) onMessage;
  final void Function(String line)? onLog;

  int _seq = 0;
  int _messageSeq = 0;

  final _assemblies = <int, _Assembly>{};
  Timer? _cleanup;

  RpcFrames({
    required this.bridgeSessionId,
    required this.send,
    required this.onMessage,
    this.bridgeGeneration,
    this.recoveryId,
    this.onLog,
  }) {
    _cleanup = Timer.periodic(const Duration(seconds: 30), (_) => _purge());
  }

  Map<String, dynamic> get _identity => {
        'bridgeSessionId': bridgeSessionId,
        if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
        if (recoveryId != null) 'recoveryId': recoveryId,
      };

  void sendMessage(Uint8List bytes) {
    if (bytes.isEmpty) throw StateError('empty rpc message');
    if (bytes.length > rpcFrameMaxMessageBytes) {
      throw StateError('rpc message too large');
    }
    final messageSeq = ++_messageSeq;
    final checksum = Crc32.hexOf(bytes);
    final fragmentCount = (bytes.length + rpcFrameMaxFragmentPayloadBytes - 1) ~/
        rpcFrameMaxFragmentPayloadBytes;
    if (fragmentCount > rpcFrameMaxFragments) {
      throw StateError('fragment limit exceeded');
    }
    for (var i = 0; i < fragmentCount; i++) {
      final start = i * rpcFrameMaxFragmentPayloadBytes;
      final end = (start + rpcFrameMaxFragmentPayloadBytes) > bytes.length
          ? bytes.length
          : start + rpcFrameMaxFragmentPayloadBytes;
      final chunk = Uint8List.sublistView(bytes, start, end);
      _seq += 1;
      send({
        'zcode_type': 'rpc-frame',
        ..._identity,
        'seq': _seq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': fragmentCount,
        'messageBytes': bytes.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64.encode(chunk),
      });
    }
  }

  /// Feed a relay payload (rpc-frame(-ack) only; others are ignored).
  void accept(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type != 'rpc-frame' && type != 'rpc-frame-ack') return;
    if (payload['bridgeSessionId'] != bridgeSessionId) return;

    final messageSeq = (payload['messageSeq'] as num?)?.toInt();
    final fragmentIndex = (payload['fragmentIndex'] as num?)?.toInt();
    final fragmentCount = (payload['fragmentCount'] as num?)?.toInt();
    final messageBytes = (payload['messageBytes'] as num?)?.toInt();
    final dataBase64 = payload['dataBase64'] as String?;
    final checksum = (payload['checksum'] as Map?)?['value'] as String?;
    if (messageSeq == null ||
        fragmentIndex == null ||
        fragmentCount == null ||
        messageBytes == null ||
        dataBase64 == null) {
      return;
    }
    if (messageSeq < 0 ||
        fragmentCount < 1 ||
        fragmentCount > rpcFrameMaxFragments ||
        fragmentIndex < 0 ||
        fragmentIndex >= fragmentCount ||
        messageBytes < 1 ||
        messageBytes > rpcFrameMaxMessageBytes) {
      return;
    }

    Uint8List chunk;
    try {
      chunk = base64.decode(dataBase64);
    } catch (_) {
      return;
    }
    if (chunk.length > rpcFrameMaxFragmentPayloadBytes) return;

    final existing = _assemblies[messageSeq];
    if (existing != null &&
        (existing.fragmentCount != fragmentCount ||
            existing.messageBytes != messageBytes ||
            existing.checksum != checksum)) {
      _assemblies.remove(messageSeq);
      return;
    }
    final assembly = _assemblies.putIfAbsent(
      messageSeq,
      () => _Assembly(fragmentCount, messageBytes, checksum),
    );
    assembly.add(fragmentIndex, chunk);
    if (assembly.isComplete) {
      _assemblies.remove(messageSeq);
      final message = assembly.assemble();
      if (message.length != assembly.messageBytes) {
        onLog?.call('[rpc] message $messageSeq size mismatch');
      } else if (checksum == null || Crc32.hexOf(message) == checksum) {
        send({
          'zcode_type': 'rpc-frame-ack',
          ..._identity,
          'ackMessageSeq': messageSeq,
        });
        onMessage(message);
      } else {
        onLog?.call('[rpc] message $messageSeq checksum mismatch');
      }
    }
    return;
  }

  void _purge() {
    final now = DateTime.now();
    final stale = <int>[];
    _assemblies.forEach((seq, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(seq);
    });
    for (final seq in stale) {
      _assemblies.remove(seq);
      onLog?.call('[rpc] purged stale assembly $seq');
    }
  }

  void dispose() {
    _cleanup?.cancel();
    _assemblies.clear();
  }
}

/// rpc 重组元数据 + 共享分片核心（缓冲/计数/拼装都在 FragmentAssembler）。
class _Assembly {
  final FragmentAssembler core;
  final int messageBytes;
  final String? checksum;

  _Assembly(int fragmentCount, this.messageBytes, this.checksum)
      : core = FragmentAssembler(fragmentCount);

  int get fragmentCount => core.fragmentCount;
  DateTime get createdAt => core.createdAt;
  void add(int index, Uint8List data) => core.add(index, data);
  bool get isComplete => core.isComplete;
  Uint8List assemble() => core.assemble();
}
