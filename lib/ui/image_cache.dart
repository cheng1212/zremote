import 'dart:typed_data';

/// 进程内图片字节缓存：按附件 ref/本地路径键，LRU + 总字节上限。
/// 只图"翻历史/切页面不重复走协议/解码"，不落盘——杀掉 App 即清。
/// 无 Flutter 依赖，可单测。
class RefImageCache {
  RefImageCache({this.maxBytes = 64 << 20}); // 64MB，覆盖 attachmentRead 单图 64MB 上限

  /// 总字节预算（默认 64MB，与 attachmentRead 的 64MB 单图上限对齐）。
  final int maxBytes;

  /// Dart Map 保持插入序：命中的先 remove 再 put 回来即完成"续命"。
  final _map = <String, Uint8List>{};
  int _bytes = 0;

  /// 生成缓存键：优先 ref，其次本地文件路径。
  static String keyForRef(String ref) => 'ref:$ref';
  static String keyForPath(String path) => 'path:$path';

  Uint8List? get(String ref) {
    final k = RefImageCache.keyForRef(ref);
    final v = _map.remove(k);
    if (v == null) return null;
    _map[k] = v;
    return v;
  }

  Uint8List? getByPath(String path) {
    final k = RefImageCache.keyForPath(path);
    final v = _map.remove(k);
    if (v == null) return null;
    _map[k] = v;
    return v;
  }

  void put(String ref, Uint8List bytes) {
    final k = RefImageCache.keyForRef(ref);
    if (bytes.length > maxBytes) return;
    final old = _map.remove(k);
    if (old != null) _bytes -= old.length;
    _map[k] = bytes;
    _bytes += bytes.length;
    while (_bytes > maxBytes && _map.isNotEmpty) {
      final oldest = _map.keys.first;
      _bytes -= _map.remove(oldest)!.length;
    }
  }

  void putByPath(String path, Uint8List bytes) {
    final k = RefImageCache.keyForPath(path);
    if (bytes.length > maxBytes) return;
    final old = _map.remove(k);
    if (old != null) _bytes -= old.length;
    _map[k] = bytes;
    _bytes += bytes.length;
    while (_bytes > maxBytes && _map.isNotEmpty) {
      final oldest = _map.keys.first;
      _bytes -= _map.remove(oldest)!.length;
    }
  }

  /// 清空缓存（测试/调试用）。
  void clear() {
    _map.clear();
    _bytes = 0;
  }
}

/// 全局单例，供 openImageViewer / AttachmentView / _EchoThumb 共用。
final globalImageCache = RefImageCache();
