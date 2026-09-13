import 'package:flutter_test/flutter_test.dart';

import 'package:zremote/app_info.dart';

void main() {
  group('formatVersionLabel（抽屉里的版本标签）', () {
    test('version + build → x.y.z+N', () {
      // 用户要的就是这个形式：能一眼看出是第几个包（build 号每打一次 +1）。
      expect(formatVersionLabel('0.1.1', '2'), '0.1.1+2');
    });

    test('buildNumber 缺失 → 只给 version（别显示成 "0.1.1+"）', () {
      expect(formatVersionLabel('0.1.1', ''), '0.1.1');
      expect(formatVersionLabel('0.1.1', '   '), '0.1.1');
    });

    test('两端空白先 trim（平台返回偶尔带空白）', () {
      expect(formatVersionLabel(' 0.1.1 ', ' 2 '), '0.1.1+2');
    });

    test('version 为空 → 空串（调用方整行隐藏）', () {
      expect(formatVersionLabel('', '2'), '');
      expect(formatVersionLabel('   ', ''), '');
    });
  });
}
