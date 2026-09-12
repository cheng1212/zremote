import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/protocol/fragment_assembler.dart';

void main() {
  group('FragmentAssembler', () {
    test('按槽位拼装（顺序跟 index，不是插入顺序）', () {
      final a = FragmentAssembler(3);
      a.add(2, Uint8List.fromList([3]));
      a.add(0, Uint8List.fromList([1]));
      expect(a.isComplete, false);
      a.add(1, Uint8List.fromList([2]));
      expect(a.isComplete, true);
      expect(a.assemble(), Uint8List.fromList([1, 2, 3]));
    });

    test('重复投递不重复计数，越界忽略（重复覆盖内容，同旧实现）', () {
      final a = FragmentAssembler(2);
      a.add(0, Uint8List.fromList([1]));
      a.add(0, Uint8List.fromList([9])); // 重复：覆盖但不重复计数
      a.add(5, Uint8List.fromList([9])); // 越界
      expect(a.isComplete, false);
      a.add(1, Uint8List.fromList([2]));
      expect(a.isComplete, true);
      expect(a.assemble(), Uint8List.fromList([9, 2]));
    });
  });
}
