import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';

/// Value-stream codec (VS Code IPC lineage).
///
/// Tags: Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4,
/// Object=5 (JSON bytes), Int=6 (0..0x7FFFFFFF varint).
/// Lengths/counts are 7-bit little-endian varints.
class ValueWriter {
  final BytesBuilder _builder = BytesBuilder();

  void _byte(int v) => _builder.addByte(v & 0xFF);
  void _varint(int value) => Varint.write(_builder, value);
  void _bytes(List<int> bytes) => _builder.add(bytes);

  Uint8List take() => _builder.toBytes();

  void writeValue(Object? value) {
    if (value == null) {
      _byte(0);
    } else if (value is String) {
      final bytes = utf8.encode(value);
      _byte(1);
      _varint(bytes.length);
      _bytes(bytes);
    } else if (value is Uint8List) {
      _byte(3);
      _varint(value.length);
      _bytes(value);
    } else if (value is List) {
      _byte(4);
      _varint(value.length);
      for (final item in value) {
        writeValue(item);
      }
    } else if (value is int && value >= 0 && value <= 0x7FFFFFFF) {
      _byte(6);
      _varint(value);
    } else {
      final bytes = utf8.encode(jsonEncode(value));
      _byte(5);
      _varint(bytes.length);
      _bytes(bytes);
    }
  }
}

class ValueReader {
  static const maxContainerItems = 100000;
  static const maxValueBytes = 16 * 1024 * 1024;

  final Uint8List data;
  int pos = 0;

  ValueReader(this.data);

  Uint8List _read(int n) {
    if (pos + n > data.length) {
      throw FormatException(
          'ValueReader: need $n bytes, only ${data.length - pos} left');
    }
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return out;
  }

  int _varint() {
    final (value, consumed) = Varint.read(data, pos);
    pos += consumed;
    return value;
  }

  Object? readValue() {
    final tag = _read(1)[0];
    switch (tag) {
      case 0:
        return null;
      case 1:
        final length = _varint();
        if (length > maxValueBytes) throw FormatException('string too large');
        return utf8.decode(_read(length));
      case 2:
      case 3:
        final length = _varint();
        if (length > maxValueBytes) throw FormatException('bytes too large');
        return _read(length);
      case 4:
        final count = _varint();
        if (count > maxContainerItems) throw FormatException('list too large');
        return List<Object?>.generate(count, (_) => readValue());
      case 5:
        final length = _varint();
        if (length > maxValueBytes) throw FormatException('object too large');
        return jsonDecode(utf8.decode(_read(length)));
      case 6:
        return _varint();
      default:
        throw FormatException('unknown value tag $tag');
    }
  }
}
