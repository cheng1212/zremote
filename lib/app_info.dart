/// 安装包版本信息（纯逻辑 + 一处平台读取），可单测那部分是拼装函数。
library;

import 'package:package_info_plus/package_info_plus.dart';

/// 版本标签拼装：`1.2.3+4`；buildNumber 为空就给 `1.2.3`；version 为空给空串
/// （调用方据此整行隐藏）。
String formatVersionLabel(String version, String buildNumber) {
  final v = version.trim();
  if (v.isEmpty) return '';
  final b = buildNumber.trim();
  return b.isEmpty ? v : '$v+$b';
}

/// 当前安装包的版本标签。
///
/// 直接读**安装包**的信息，不是写死的 Dart 常量——版本号只有 `pubspec.yaml`
/// 一处来源，不会出现"代码里写着 A、手机上装的是 B"的漂移（这一点正是用户
/// 要它显示出来的原因：打了好几个包全挂着同一个版本，分不清装的是哪个）。
///
/// 读取失败给空串（抽屉里那一行整行隐藏），不让它影响别的功能。
Future<String> appVersionLabel() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return formatVersionLabel(info.version, info.buildNumber);
  } on Object {
    return '';
  }
}
