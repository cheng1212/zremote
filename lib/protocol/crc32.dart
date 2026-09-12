import 'dart:typed_data';

/// CRC-32 (IEEE 802.3), hex string output without 0x prefix.
class Crc32 {
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c;
    }
    return table;
  }

  static int of(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  static String hexOf(List<int> bytes) =>
      of(bytes).toRadixString(16).padLeft(8, '0');
}

/// 7-bit little-endian varint helpers over growable byte lists.
class Varint {
  static void write(BytesBuilder out, int value) {
    var v = value;
    do {
      var byte = v & 0x7F;
      v >>= 7;
      if (v > 0) byte |= 0x80;
      out.addByte(byte & 0xFF);
    } while (v > 0);
  }

  /// Returns (value, bytesRead).
  static (int, int) read(Uint8List data, int offset) {
    var value = 0;
    var shift = 0;
    var pos = offset;
    while (pos < data.length) {
      final b = data[pos++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return (value, pos - offset);
      shift += 7;
      if (shift >= 35) break;
    }
    throw FormatException('invalid varint at offset $offset');
  }
}
