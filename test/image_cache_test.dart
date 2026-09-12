import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/ui/image_cache.dart';

Uint8List bytes(int size, [int fill = 1]) =>
    Uint8List(size)..fillRange(0, size, fill);

void main() {
  group('RefImageCache', () {
    test('命中返回字节，未命中返回 null', () {
      final c = RefImageCache();
      expect(c.get('a'), isNull);
      c.put('a', bytes(10));
      expect(c.get('a')!.length, 10);
    });

    test('超预算淘汰最旧：先放的先走', () {
      final c = RefImageCache(maxBytes: 100);
      c.put('a', bytes(40));
      c.put('b', bytes(40));
      c.put('c', bytes(40)); // 120 > 100 → a 被淘汰
      expect(c.get('a'), isNull);
      expect(c.get('b'), isNotNull);
      expect(c.get('c'), isNotNull);
    });

    test('get 触碰续命：刚读过的不算最旧', () {
      final c = RefImageCache(maxBytes: 100);
      c.put('a', bytes(40));
      c.put('b', bytes(40));
      c.get('a'); // a 变最新
      c.put('c', bytes(40)); // 淘汰 b
      expect(c.get('a'), isNotNull);
      expect(c.get('b'), isNull);
    });

    test('同 ref 覆盖不重复计费', () {
      final c = RefImageCache(maxBytes: 100);
      c.put('a', bytes(60));
      c.put('a', bytes(30));
      c.put('b', bytes(60)); // 90 ≤ 100，a 不需要被挤走
      expect(c.get('a'), isNotNull);
      expect(c.get('b'), isNotNull);
    });

    test('单张超预算的直接不缓存', () {
      final c = RefImageCache(maxBytes: 100);
      c.put('big', bytes(200));
      c.put('a', bytes(40));
      expect(c.get('big'), isNull);
      expect(c.get('a'), isNotNull);
    });
  });
}
