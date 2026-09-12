import 'package:flutter_test/flutter_test.dart';
import 'package:zremote/state/model_defaults.dart';

void main() {
  test('首选默认是 GLM 5.3 Flash（BigModel Coding Plan，2026-09-11 起）', () {
    expect(preferredDefaultModelProvider, 'builtin:bigmodel-coding-plan');
    expect(preferredDefaultModelId, 'GLM-5.3-Flash');
    expect(preferredDefaultModelThought, 'high');
  });

  test('坏 provider（start-plan，不在注册表）的记录一律视同未选择', () {
    // 新版运行期间自动登记（含 chosen:true）的可能带坏 provider。
    expect(
      shouldApplyPreferredDefaultModel({
        'provider': 'builtin:bigmodel-start-plan',
        'model': 'GLM-5.3-Flash',
      }),
      isTrue,
    );
    expect(
      shouldApplyPreferredDefaultModel({
        'provider': 'builtin:bigmodel-start-plan',
        'model': 'GLM-5.3-Flash',
        'chosen': true,
      }),
      isTrue,
    );
    // 正确 provider 的 GLM 记录是用户真实选择，不动。
    expect(
      shouldApplyPreferredDefaultModel({
        'provider': 'builtin:bigmodel-coding-plan',
        'model': 'GLM-5.3-Flash',
        'chosen': true,
      }),
      isFalse,
    );
  });

  test('没记录过/服务端基线（千问 Max）/历史默认模型名 → 套用首选默认', () {
    expect(shouldApplyPreferredDefaultModel(null), isTrue);
    expect(shouldApplyPreferredDefaultModel({}), isTrue);
    expect(
      shouldApplyPreferredDefaultModel({'model': '   '}),
      isTrue,
    );
    expect(
      shouldApplyPreferredDefaultModel({'model': 'qwen3-max'}),
      isTrue,
    );
    // 2026-09-11 夜间实测的批量回退值（欠费）。
    expect(
      shouldApplyPreferredDefaultModel({'model': 'qwen3.8-flash'}),
      isTrue,
    );
    expect(
      shouldApplyPreferredDefaultModel({'model': 'nemotron-3-ultra'}),
      isTrue,
    );
    // 英伟达曾是默认（09-05~09-11），守恒器自动写入的记录（无 chosen）
    // 跟着默认迁移到 GLM。
    expect(
      shouldApplyPreferredDefaultModel({'model': 'nv-nemotron-ultra'}),
      isTrue,
    );
  });

  test('isServerFallbackModel：服务端报告值判定（对账/批量纠正共用）', () {
    expect(isServerFallbackModel('qwen3.8-flash'), isTrue);
    expect(isServerFallbackModel('qwen3-max'), isTrue);
    expect(isServerFallbackModel(''), isTrue);
    expect(isServerFallbackModel('nv-nemotron-ultra'), isTrue);
    expect(isServerFallbackModel('GLM-5.3-Flash'), isFalse);
    expect(isServerFallbackModel('GLM-5.3'), isFalse);
    expect(isServerFallbackModel('deepseek-v4-flash'), isFalse);
    expect(isServerFallbackModel('nv-nemotron-super'), isFalse);
  });

  test('chosen 标记 = 用户显式选过，连千问 Max 都不迁移', () {
    expect(
      shouldApplyPreferredDefaultModel({
        'model': 'qwen3-max',
        'chosen': true,
      }),
      isFalse,
    );
    expect(
      shouldApplyPreferredDefaultModel({
        'model': 'GLM-5.3',
        'chosen': true,
      }),
      isFalse,
    );
    // 显式选过英伟达的（chosen）不随默认迁移。
    expect(
      shouldApplyPreferredDefaultModel({
        'model': 'nv-nemotron-ultra',
        'chosen': true,
      }),
      isFalse,
    );
  });

  test('用户显式选过的模型不动（无标记但非基线值也尊重）', () {
    expect(
      shouldApplyPreferredDefaultModel({'model': 'nv-nemotron-super'}),
      isFalse,
    );
    expect(
      shouldApplyPreferredDefaultModel({'model': 'GLM-5.3'}),
      isFalse,
    );
    expect(
      shouldApplyPreferredDefaultModel({'model': 'deepseek-v4-flash'}),
      isFalse,
    );
  });
}
