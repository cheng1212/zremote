import 'dart:typed_data';

/// 通用分片重组器：定长槽位 + 已收计数 + 顺序拼装。
/// rpc-frame 传输与 conversation 订阅两路共用；
/// [createdAt] 供各层的过期清理定时器读取。
class FragmentAssembler {
  final int fragmentCount;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int _received = 0;

  FragmentAssembler(this.fragmentCount) : parts = List.filled(fragmentCount, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= fragmentCount) return;
    if (parts[index] == null) _received += 1;
    parts[index] = data;
  }

  bool get isComplete => _received == fragmentCount;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}
