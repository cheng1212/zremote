// T10（收编审计 A1）：Dart 侧协议命令集合与快照锁的一致性。
// web 端（web/tests/protocol-commands.test.ts）读**同一个** fixture 比对
// TS 集合——任一端改集合而不同步另一端/快照，测试即红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/protocol/constants.dart';

void main() {
  final fixturePath =
      '${Directory.current.path}/test/fixtures/protocol_commands.json';
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture =
        jsonDecode(File(fixturePath).readAsStringSync()) as Map<String, dynamic>;
  });

  test('casCommands 与快照一致', () {
    final actual = casCommands.toList()..sort();
    expect(
      actual,
      equals((fixture['casCommands'] as List).cast<String>()..sort()),
    );
  });

  test('rowTargetCommands 与快照一致', () {
    final actual = rowTargetCommands.toList()..sort();
    expect(
      actual,
      equals((fixture['rowTargetCommands'] as List).cast<String>()..sort()),
    );
  });

  test('rowTargetCommands 是 casCommands 的子集（口径自检）', () {
    expect(casCommands.containsAll(rowTargetCommands), isTrue);
  });
}
