/// 默认模型偏好（纯逻辑，可单测）。
library;

/// 首选默认模型：进入"用户从没选过模型"的会话时自动切过去。
/// 用户 2026-09-11 指定 GLM 5.3 Flash（BigModel Coding Plan），
/// 取代此前 2026-09-05 指定的英伟达系列（NVIDIA 轮询本地代理）。
/// provider id 必须与服务端模型注册表一致（prepareWorkspace
/// configOptions 实测）：GLM 走 builtin:bigmodel-coding-plan；
/// bigmodel-start-plan 不在注册表，用了会 provider.notInRegistry。
const preferredDefaultModelProvider = 'builtin:bigmodel-coding-plan';

/// 2026-09-11 曾误写 preferredDefaultModelProvider = bigmodel-start-plan
///（不在注册表，切换必失败），新版运行期间自动登记的 GLM 记录可能带此
/// 坏 provider——一律视同未选择，迁移到正确默认（即便带 chosen 标记，
/// 那也是系统按坏常量写的，不是用户在面板手选的）。
const brokenPreferredModelProvider = 'builtin:bigmodel-start-plan';

/// 桌面端实际模型 id（provider 内写作 GLM-5.3-Flash，thought 支持
/// high/max，见桌面日志 431 处 GLM-5.3-Flash$high）。
const preferredDefaultModelId = 'GLM-5.3-Flash';
const preferredDefaultModelThought = 'high';

/// 服务端历史/回退默认（会话被服务端机制刷到这些值 = 真回退）：
/// - qwen3-max：2026-09 之前的服务端历史默认；
/// - qwen3.8-flash：2026-09-11 夜间实测的批量回退值（欠费，桌面库 5 个
///   会话中招）——发消息必死，必须识别为基线并纠正。
const serverFallbackModelIds = <String>{'qwen3-max', 'qwen3.8-flash'};

/// 历史首选 id：这些值是"当时的默认"被守恒器自动写入本地记录的
/// （无 chosen 标记），默认换了就该跟着迁走，视同未选择。
/// - nemotron-3-ultra：2026-09-05 改名前的英伟达 id；
/// - nv-nemotron-ultra：2026-09-05 ~ 09-11 的英伟达默认。
/// 用户在面板显式选过的英伟达带 chosen:true，不走这里，仍被尊重。
const legacyPreferredModelIds = <String>{'nemotron-3-ultra', 'nv-nemotron-ultra'};

/// 该会话是否套用首选默认。
///
/// - 记录带 `chosen: true`（用户在模型面板里显式选的）→ 永远尊重，
///   哪怕选的是千问 Max 也不迁移；
/// - 没记录过（新会话）、记录还是服务端基线、或历史首选 id
///   → 都算没选过，套用首选默认。
bool shouldApplyPreferredDefaultModel(Map<String, dynamic>? record) {
  if (record == null) return true;
  if ('${record['provider'] ?? ''}'.trim() == brokenPreferredModelProvider) {
    return true;
  }
  if (record['chosen'] == true) return false;
  final m = '${record['model'] ?? ''}'.trim();
  return m.isEmpty ||
      serverFallbackModelIds.contains(m) ||
      legacyPreferredModelIds.contains(m);
}

/// 服务端报告的模型 id 是否属于回退基线（含历史默认）——
/// 判定"这个会话被服务端刷回去了"的单一来源，对账/批量纠正共用。
bool isServerFallbackModel(String modelId) =>
    shouldApplyPreferredDefaultModel({'model': modelId.trim()});
