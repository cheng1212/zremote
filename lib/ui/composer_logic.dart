/// 底部栏的纯展示逻辑：无 Flutter 依赖，可单测。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 协作模式 id → 中文短标签（药丸空间小，两个字最理想）。
String modeLabel(String mode) => switch (mode) {
  'build' => '构建',
  'plan' => '计划',
  '' => '构建',
  _ => mode,
};

/// usage 快照 → 上下文窗口占用比例（0~1）。
/// 缺数据 / maxTokens 非法时返回 null（药丸隐藏）。
double? contextUsageRatio(Map<String, dynamic>? usage) {
  final cw = usage?['contextWindow'];
  if (cw is! Map) return null;
  final max = cw['maxTokens'];
  if (max is! num || max <= 0) return null;
  final used = (cw['usedTokens'] as num?) ?? 0;
  return (used / max).clamp(0.0, 1.0);
}

/// `provider/model` 拆分（与 zemote 对齐）：无斜杠时两边同值，
/// 调用方不必再判空——空串进出都是空串。
(String, String) splitModelValue(String value) {
  final idx = value.lastIndexOf('/');
  if (idx <= 0) return (value, value);
  return (value.substring(0, idx), value.substring(idx + 1));
}

/// 会话快照模型是否已落到请求值（新会话首条消息放行判定）。
/// provider 请求值为空时不校验 provider（服务端可能回填同义 id）；
/// 请求了 provider 则要求一致——防止被服务端回退到别的供应商。
bool sessionModelMatches({
  required String curProvider,
  required String curModel,
  required String wantProvider,
  required String wantModel,
}) {
  if (wantModel.isEmpty || curModel != wantModel) return false;
  return wantProvider.isEmpty || curProvider == wantProvider;
}

/// 思考等级原始 id → 中文短标签（词表随模型家族不同，见
/// config.thoughtLevels：GLM low/high/max，NVIDIA low/medium/high，
/// qwen enabled/disabled）。未知 id 原样返回。
String thoughtLevelLabel(String id) => switch (id) {
  'max' => '最高',
  'high' => '高',
  'medium' => '中',
  'low' => '低',
  'nothink' => '不思考',
  'enabled' => '开启思考',
  'disabled' || 'off' => '关闭思考',
  _ => id,
};

/// contextWindow.cache → 缓存命中率摘要。命中率由服务端算好直出：
/// latestHitRate=最近一次调用、hitRate=会话平均、hitRateRequestCount=
/// 参与统计的请求数。全部缺字段时返回 null（调用方隐藏整卡）。
({double? latest, double? average, int? requests})? usageCacheSummary(
  Map<String, dynamic>? cache,
) {
  if (cache == null || cache.isEmpty) return null;
  double? pick(Object? v) => v is num && v >= 0 && v <= 1 ? v.toDouble() : null;
  final latest = pick(cache['latestHitRate']);
  final average = pick(cache['hitRate']);
  final requests = cache['hitRateRequestCount'] is num
      ? (cache['hitRateRequestCount'] as num).toInt()
      : null;
  if (latest == null && average == null && requests == null) return null;
  return (latest: latest, average: average, requests: requests);
}

/// 上下文构成 breakdown → (标签, 字符数, 占比 0~1) 行，按字符数降序。
/// 服务端只给各来源的字符数，占比以各项之和为分母；来源标签未知原样。
List<(String, int, double)> contextBreakdownRows(Object? breakdown) {
  if (breakdown is! List) return const [];
  final rows = <(String, int)>[];
  for (final e in breakdown) {
    if (e is! Map) continue;
    final source = '${e['source'] ?? ''}'.trim();
    final chars = e['chars'];
    if (source.isEmpty || chars is! num || chars <= 0) continue;
    rows.add((breakdownSourceLabel(source), chars.toInt()));
  }
  final total = rows.fold<int>(0, (s, r) => s + r.$2);
  if (total <= 0) return const [];
  final sorted = [...rows]..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final r in sorted) (r.$1, r.$2, r.$2 / total)];
}

/// breakdown source → 中文标签，未知原样返回。
String breakdownSourceLabel(String source) => switch (source) {
  'system_prompt' => '系统提示',
  'meta_user_context' => '环境上下文',
  'skills' => '技能说明',
  'system_tool_schemas' => '内置工具定义',
  'mcp_tool_schemas' => 'MCP 工具定义',
  'messages' => '对话内容',
  _ => source,
};

/// 流式 Markdown 兜底：未闭合围栏/显示公式自动补全，
/// 防止代码块高度震荡（渲染高度单调不减）。参照标准工程方案 §5.3。
String closeStreamingMarkdown(String src) {
  var inFence = false;
  var fenceMark = '```';
  for (final line in const LineSplitter().convert(src)) {
    final m = RegExp(r'^\s{0,3}(```|~~~)').firstMatch(line);
    if (m == null) continue;
    final mark = m.group(1)!;
    if (!inFence) {
      inFence = true;
      fenceMark = mark;
    } else if (mark == fenceMark) {
      inFence = false;
    }
  }
  if (inFence) return '$src\n$fenceMark';
  if ('""'.allMatches(src).length.isOdd) {
    return '$src\n""';
  }
  return src;
}

/// 累计用量键 → 中文标签；未知键原样返回（动态结构兜底）。
String cumulativeKeyLabel(String key) => switch (key) {
  'totalTokens' => '总 tokens',
  'inputTokens' => '输入 tokens',
  'outputTokens' => '输出 tokens',
  'reasoningTokens' => '推理 tokens',
  'cacheReadTokens' => '缓存读取',
  'cacheCreationTokens' => '缓存写入',
  'cacheHitRate' => '缓存命中率',
  'totalTurns' => '总回合',
  'totalSessions' => '总会话',
  'toolCallCount' => '工具调用次数',
  _ => key,
};

/// 字节数 → 短标签：≥1MB 一位小数，否则 KB 取整；非正数给空（调用方隐藏）。
String fileSizeLabel(num bytes) {
  if (bytes <= 0) return '';
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).round()} KB';
}

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

/// 是否按图片渲染（缩略图/图标选择共用一套口径）。
bool isImageExt(String ext) => _imageExts.contains(ext.toLowerCase());

/// 魔数嗅探图片 mime：相册选出的图常见没有扩展名（Android content uri），
/// 上传 mime 与「按图片渲染」的判定都靠它兜底。认不出给 null。
String? sniffImageMime(Uint8List? bytes) {
  if (bytes == null) return null;
  final n = bytes.length;
  // PNG: 89 50 4E 47
  if (n >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  // JPEG: FF D8 FF
  if (n >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  // GIF87a/89a: GIF8
  if (n >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  // WEBP: RIFF + 偏移 8..11 为 WEBP
  if (n >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// 附件（服务端行 / 本地回显通用形状）是否按图片渲染：
/// mime 前缀优先，扩展名兜底；与 AttachmentView 的渲染口径一致。
bool attachmentIsImage(Map<String, dynamic> a) {
  final mime = '${a['mime'] ?? a['mediaType'] ?? a['mimeType'] ?? ''}';
  if (mime.startsWith('image/')) return true;
  final name = '${a['fileName'] ?? a['name'] ?? ''}';
  final ext = name.contains('.') ? name.split('.').last : '';
  return isImageExt(ext);
}

/// 追问模式 → 短标签：unknown/缺省一律按「排队」兜底。
String followupLabel(String mode) => mode == 'guide' ? '引导' : '排队';

/// 权限选项 → 展示名：label 优先，kind 兜底，最后 optionId。
String permissionOptionLabel(Map option) {
  final label = option['label'] as String?;
  if (label != null && label.isNotEmpty) return label;
  return switch (option['kind']) {
    'allowOnce' => '允许一次',
    'allowAlways' => '总是允许',
    'deny' => '拒绝',
    'custom' => '自定义',
    _ => '${option['optionId'] ?? '选择'}',
  };
}

/// 文件变更行 → (路径, 动作中文, 增删统计)。形状未实测多兜底；
/// 路径缺失给 null（调用方整行丢弃）。
(String, String, String)? describeFileChange(Map change) {
  final path =
      '${change['path'] ?? change['file'] ?? change['filePath'] ?? change['relPath'] ?? ''}';
  if (path.isEmpty) return null;
  final rawKind =
      '${change['changeType'] ?? change['kind'] ?? change['status'] ?? change['type'] ?? ''}';
  final action = switch (rawKind) {
    'created' || 'added' || 'create' || 'add' => '新建',
    'deleted' || 'removed' || 'delete' || 'remove' => '删除',
    'renamed' || 'rename' || 'move' => '重命名',
    'modified' || 'edit' || 'change' || 'update' || '' => '修改',
    _ => rawKind,
  };
  final add = change['additions'];
  final del = change['deletions'];
  final stats = [
    if (add is num && add > 0) '+$add',
    if (del is num && del > 0) '-$del',
  ].join(' ');
  return (path, action, stats);
}

/// 已被 rows 确认的回显消息移除——回显消失的那一帧，服务端正式行已在
/// 同一位置接上（同文本无缝交接，不闪不重复）；失败的保留供重试。
/// 带附件的回显按附件 ref 匹配（纯图片没有文字可对）。
List<Map<String, Object?>> visibleEchoes(
  List<Map<String, Object?>> echoes,
  List<Map<String, dynamic>> rows,
) {
  final confirmed = <String, int>{};
  final confirmedRefs = <String>{};
  for (final row in rows) {
    if (row['kind'] != 'userInput') continue;
    final text = '${row['text'] ?? ''}'.trim();
    if (text.isNotEmpty) confirmed[text] = (confirmed[text] ?? 0) + 1;
    final atts = row['attachments'];
    if (atts is List) {
      for (final a in atts) {
        final ref = a is Map ? a['ref'] : null;
        if (ref is String && ref.isNotEmpty) confirmedRefs.add(ref);
      }
    }
  }
  return echoes.where((echo) {
    if (echo['status'] == 'failed') return true;
    final atts = echo['attachments'] as List?;
    if (atts != null && atts.isNotEmpty) {
      // 所有 ref 都出现在服务端行里才算送达。
      for (final a in atts) {
        final ref = a is Map ? a['ref'] : null;
        if (ref is! String || !confirmedRefs.contains(ref)) return true;
      }
      return false;
    }
    final text = '${echo['text']}'.trim();
    final left = confirmed[text] ?? 0;
    if (left > 0) {
      confirmed[text] = left - 1;
      return false;
    }
    return true;
  }).toList();
}

/// 发送失败原文 → 用户能看懂的主文案（原始异常在气泡里以小字降级展示）。
String friendlySendError(String raw) {
  if (raw.contains('桥未就绪')) return raw; // 已是人话，原样透传
  if (raw.contains('TimeoutException') || raw.contains('超时')) {
    return '网络超时，点击重试';
  }
  if (raw.contains('SocketException')) return '网络连接失败，点击重试';
  if (raw.contains('ChannelRpcError')) return '服务端拒绝了这次发送';
  return '发送失败，点击重试';
}

/// 项目切换失败原文 → 用户能看懂的主文案。
/// 和 friendlySendError 同一条规矩：原始异常不该整段糊到用户脸上，
/// 更不该让用户看完还不知道下一步该干什么。
String friendlySwitchError(String raw) {
  if (raw.contains('runtime is not running')) {
    return '这个项目在桌面端还没启动，先去桌面端打开它一次再切回来';
  }
  if (raw.contains('workspace-bridge-error')) {
    return '桌面端没打开这个项目，先去桌面端打开它';
  }
  if (raw.contains('TimeoutException') || raw.contains('超时')) {
    return '切换超时了，再试一次';
  }
  if (raw.contains('SocketException') || raw.contains('未连接')) {
    return '连接已断开，重新连接后再切项目';
  }
  if (raw.contains('ChannelRpcError')) return '服务端拒绝了这次切换';
  return '切换失败，再试一次';
}

/// 代码块展示截断阈值：代码块已完整铺开（无内滚），仅保留防模型回出
/// 上 MB 级载荷卡死列表的保险丝（10 万字符 ≈ 两三千行）；复制仍拿全文。
const maxCodeBlockChars = 100000;

/// 代码块展示文本：短代码原样；超长截断并附提示行。
String codeBlockPreview(String code) {
  if (code.length <= maxCodeBlockChars) return code;
  return '${code.substring(0, maxCodeBlockChars)}\n\n'
      '…… 内容过长（共 ${code.length} 字符），已截断展示，点右上复制可拿全文';
}

/// RPC 错误 → 一句话人话：服务端 zod 校验错误（JSON 数组）提取首条
/// message 拼接；其余截断到 140 字符，避免把整段 JSON 糊进 UI。
String briefRpcError(Object? error) {
  if (error == null) return '未知错误';
  final s = error.toString();
  final i = s.indexOf('[');
  if (i >= 0 && s.contains('"message"')) {
    try {
      final arr = jsonDecode(s.substring(i, s.lastIndexOf(']') + 1));
      if (arr is List && arr.isNotEmpty) {
        final msgs = [
          for (final e in arr)
            if (e is Map && e['message'] is String) e['message'] as String,
        ];
        if (msgs.isNotEmpty) return msgs.join('；');
      }
    } on FormatException {
      // 落到截断
    }
  }
  return s.length <= 140 ? s : '${s.substring(0, 140)}…';
}

// ------------------------------------------------------ 视口锚定（可单测）

/// 底部态判定阈值（reverse 列表：pixels ≈ 0 是最新端）。
/// 双阈值滞回：进入比退出更严，中间带状区保持原状态。
/// 单阈值在流式期间会反复翻转——maxScrollExtent 一直在变，
/// 用户停在临界带附近时判定会横跳，每次翻转都 setState 重建整页。
class AnchorThresholds {
  /// 进入「在底部」的门槛：距最新端 ≤ 此值才算到位。
  static const double enterPx = 100;

  /// 离开「在底部」的门槛：超过它才认为用户滑走了。
  static const double exitPx = 180;

  /// 给定当前位置与当前状态，返回新的底部态。
  /// 未完成首帧布局（maxScrollExtent <= 0）时恒视为在底部。
  static bool resolve({
    required double pixels,
    required double maxScrollExtent,
    required bool wasAtBottom,
  }) {
    if (maxScrollExtent <= 0) return true;
    return wasAtBottom ? pixels <= exitPx : pixels <= enterPx;
  }
}

/// 一次锚定补偿的规划结果：动画时长 + 本步走的位移 + 剩余欠账。
class AnchorStep {
  final double delta;
  final Duration duration;
  final double leftover;

  const AnchorStep(this.delta, this.duration, this.leftover);

  bool get isNoop => delta.abs() < AnchorMath.minStepPx;
}

/// 锚定补偿的纯计算：阈值过滤 + 单步上限 + 时长缩放。
///
/// 这些数字是"闪不闪"的关键，单拎出来便于回归——都不做 IO 也不碰
/// ScrollPosition，可以直接断言。
abstract final class AnchorMath {
  /// 小于此位移不补偿：流式文本每 tick 长十几像素是常态，
  /// 阈值太小（原实现 0.5）会让每帧都产生一次位移，合成肉眼可见的闪。
  static const double minStepPx = 1.5;

  /// 单步补偿上限：欠账动辄几百像素（拖动期间攒的），
  /// 一次跳完是"弹跳"，分步走完是"追上去"。
  static const double maxStepPx = 600;

  /// 动画时长区间。够短到看不出一段动画，又够长到把瞬时跳变
  /// 糊成连续移动——这是修复"一闪一闪"的核心。
  static const int minDurationMs = 60;
  static const int maxDurationMs = 110;

  /// 规划一步：|delta| 超上限就截断，剩下的作为 leftover 留给下一帧。
  static AnchorStep plan(double delta) {
    if (delta.abs() < minStepPx) {
      return const AnchorStep(0, Duration.zero, 0);
    }
    final capped = delta.abs() > maxStepPx
        ? (delta.isNegative ? -maxStepPx : maxStepPx)
        : delta;
    final leftover = delta - capped;
    final ms = (minDurationMs + capped.abs() * 0.15)
        .clamp(minDurationMs.toDouble(), maxDurationMs.toDouble())
        .round();
    return AnchorStep(
      capped,
      Duration(milliseconds: ms),
      leftover.abs() < minStepPx ? 0 : leftover,
    );
  }
}

/// 「用户正在看历史」的跟随锁存。
///
/// 为什么需要状态锁而不是每次用位置判定：`pixels` 是连续量，而「要不要
/// 自动回底」是意图判定。位置判定在流式期间必然误判——内容每 tick 长高，
/// 用户看的那个位置对应的 pixels 每帧都在变；只要他停得离底部近一点
/// （< exitPx），新行一到就被拽走。
///
/// 语义：用户**主动**滚离底部 → 锁定关闭跟随；直到他**主动**滚回底部
/// 附近才解锁。锁存期间无论内容怎么长都不动他。程序性滚动（发送消息、
/// 点「回到最新」按钮）不走这里，不受锁影响。
abstract final class FollowLock {
  /// 锁存的解除门槛。比 `AnchorThresholds.enterPx`(100) 更严，
  /// 目的是制造一段"死区"：用户滚回 100~40 这个带里不会突然解锁，
  /// 必须真的贴到最新端附近才算"我要跟了"。
  static const double releasePx = 40;

  /// 是否需要（重新）上锁。
  /// 上锁条件：pixels 超过 exitPx——即 `AnchorThresholds` 已判定
  /// 离开底部，此时用户意图明确是"在看历史"。
  ///
  /// 只在 `lockFollow` 为 false 时评估，避免反复赋值（每次赋值都
  /// 可能触发 setState，是闪的来源之一）。
  static bool shouldLock({
    required double pixels,
    required double maxScrollExtent,
    required bool lockFollow,
  }) {
    if (lockFollow) return false;
    if (maxScrollExtent <= 0) return false;
    return pixels > AnchorThresholds.exitPx;
  }

  /// 是否满足解锁条件（用户主动滚回最新端附近）。
  static bool shouldRelease({required double pixels, required double maxScrollExtent}) {
    if (maxScrollExtent <= 0) return true;
    return pixels <= releasePx;
  }
}

/// 自动回底的曲线意图。本文件不依赖 Flutter，所以用枚举表达，
/// 由调用方翻译成 `Curve`。
enum AutoFollowCurve {
  /// 匀速——回底时用，避免 easeOut 出门太快产生的"被拽"手感。
  linear,

  /// 缓出——只在明确的用户主动动作（点按钮）里用。
  easeOut,
}

/// 自动回底的规划：位移越大越"拽"，所以按距离决定用哪种手段。
///
/// 直接 `animateTo(0)` 的问题在于：无论用户在多远，都走同一套
/// 时长+曲线。离得近时短距快curve = 手感正常；离得远时同样是 120ms
/// 走完几百像素 = 一记猛拽，用户明确感觉到"被拉回去"。
class AutoFollowStep {
  /// 是否值得执行。
  final bool act;

  /// 目标位置：贴着底部（0）还是停在半途。
  final double target;

  final Duration duration;
  final AutoFollowCurve curve;

  const AutoFollowStep({
    required this.act,
    required this.target,
    required this.duration,
    required this.curve,
  });

  static const AutoFollowStep none = AutoFollowStep(
    act: false,
    target: 0,
    duration: Duration.zero,
    curve: AutoFollowCurve.linear,
  );
}

/// 自动回底的纯计算。
abstract final class AutoFollowMath {
  /// 距离超过这个倍数的一屏，就不再"回底"，而是当作锚定欠账慢慢追。
  /// 一屏以内：正常回底（用户确实就在底部附近，回去是预期的）。
  static const double maxDirectScreens = 1.0;

  /// 回底动画时长。比原来的 120ms 长一些、曲线改 linear：
  /// easeOut 出门太快，前 30ms 就走完大半，观感是"被拽"；
  /// linear 全程匀速，像内容自己在动。200ms 足以糊掉突变又不拖沓。
  static const int directMs = 200;

  /// 规划一次自动回底。`distance` = 当前距最新端的像素数。
  static AutoFollowStep plan({
    required double distance,
    required double viewportDimension,
  }) {
    if (distance <= 0) return AutoFollowStep.none;
    // 视口还没量出来（首帧/刚进页）：保守起见不回底，等下一帧。
    if (viewportDimension <= 0) return AutoFollowStep.none;
    if (distance > viewportDimension * maxDirectScreens) {
      // 离得太远：不做"回底"，交给锚定通道慢慢追（不抢用户视线）。
      return AutoFollowStep.none;
    }
    return const AutoFollowStep(
      act: true,
      target: 0,
      duration: Duration(milliseconds: directMs),
      curve: AutoFollowCurve.linear,
    );
  }
}

// ------------------------------------------------ AskUserQuestion 问答（可单测）
//
// 契约来源：2026-09-11 探针直连桌面端实测（sess_681356e6 / perm_723f9c9a）。
// 进来的 payload：
//   {kind:'userInput', freeText:true, prompt:'…', questions:[
//      {question:'长题干', header:'短标题', multiSelect:true,
//       options:[{value, label, description}]}]}
// 回传（实测 status:accepted 且弹窗关闭）：
//   {action:'accept', content:{answers:[{question:'题干原文', selected:['value',…]}]}}
// 注意：题目**没有 id**，靠题干原文做键；option 靠 `value` 做标识。

/// 一道问题的解析结果：把服务端 payload 里的松散 Map 收敛成有默认值的结构。
class AskQuestion {
  /// 题干原文。既是展示内容，也是回传 answers 的键（服务端没有 id）。
  final String question;

  /// 短标题（header）。缺省时退回题干。
  final String header;

  final bool multiSelect;

  /// 选项：value 是回传用的标识，label 是展示文字，description 是副标题。
  final List<AskOption> options;

  const AskQuestion({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  /// 从服务端 Map 解析。缺字段一律给安全默认，绝不抛。
  factory AskQuestion.fromMap(Map raw) {
    final opts = <AskOption>[];
    for (final o in (raw['options'] as List? ?? const [])) {
      if (o is Map) opts.add(AskOption.fromMap(o));
    }
    final question = '${raw['question'] ?? raw['prompt'] ?? ''}';
    final header = '${raw['header'] ?? ''}';
    return AskQuestion(
      question: question,
      header: header.isEmpty ? question : header,
      multiSelect: raw['multiSelect'] == true,
      options: opts,
    );
  }

  /// 该题的回传键。没有 id，只能用题干；题干也空时给个稳定占位，
  /// 避免多道空题干题全部塌到同一个键上互相覆盖。
  String key(int index) => question.isEmpty ? '#q$index' : question;
}

/// 一个选项。`value` 缺失时退回 label —— 实测两者通常相同。
class AskOption {
  final String value;
  final String label;
  final String description;

  const AskOption({
    required this.value,
    required this.label,
    required this.description,
  });

  factory AskOption.fromMap(Map raw) {
    final label = '${raw['label'] ?? ''}';
    final value = '${raw['value'] ?? ''}';
    return AskOption(
      value: value.isEmpty ? label : value,
      label: label.isEmpty ? value : label,
      description: '${raw['description'] ?? ''}',
    );
  }
}

/// 单题作答状态：选中的选项 value 集合 + 自由文本。
class AskAnswer {
  final Set<String> selected;
  final String other;

  const AskAnswer({this.selected = const {}, this.other = ''});

  bool get isEmpty => selected.isEmpty && other.trim().isEmpty;
  bool get isNotEmpty => !isEmpty;

  AskAnswer copyWith({Set<String>? selected, String? other}) => AskAnswer(
        selected: selected ?? this.selected,
        other: other ?? this.other,
      );

  /// 点一个选项。
  /// 多选：toggle（已选则取消）。单选：替换（点已选中的则清空，允许反悔）。
  AskAnswer toggle(String value, {required bool multiSelect}) {
    if (multiSelect) {
      final next = {...selected};
      if (!next.remove(value)) next.add(value);
      return copyWith(selected: next);
    }
    if (selected.length == 1 && selected.contains(value)) {
      return copyWith(selected: const {});
    }
    return copyWith(selected: {value});
  }

  /// 该题最终要回传的 selected 列表（选项值 + 非空自由文本）。
  ///
  /// 契约里 `selected` 是唯一出口，没有独立的 other 字段；所以自由文本
  /// 拼进 selected。调用方同时会把原文放进顶层 freeText 兜底 —— 服务端
  /// 认哪个用哪个。
  List<String> toSelected() {
    final out = <String>[...selected];
    final t = other.trim();
    if (t.isNotEmpty) out.add(t);
    return out;
  }
}

/// 组装回传载荷。返回 `{action, content}`，直接交给 resolveInteraction。
///
/// 实测形状：`content.answers = [{question, selected:[…]}]`。
/// 全部题都答了才该调用（门槛由 `allAnswered` 把关，这里不做校验）。
Map<String, dynamic> buildAskAnswersPayload({
  required List<AskQuestion> questions,
  required List<AskAnswer> answers,
}) {
  final list = <Map<String, dynamic>>[];
  for (var i = 0; i < questions.length; i++) {
    final a = i < answers.length ? answers[i] : const AskAnswer();
    list.add({'question': questions[i].key(i), 'selected': a.toSelected()});
  }
  return {
    'action': 'accept',
    'content': {'answers': list},
  };
}

/// 是否所有题都有答案（选项或自由文本至少一个）。用于把关「提交」按钮。
bool allAnswered(List<AskAnswer> answers) =>
    answers.isNotEmpty && answers.every((a) => a.isNotEmpty);

/// 排队追加的重复判定：新文本（trim 后）与队列中任一条（trim 后）相同。
/// queueItems 元素形状来自快照 queue.items（{queueItemId, text}）。
bool queueHasDuplicate(List<Map<String, dynamic>> queueItems, String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  for (final q in queueItems) {
    if ('${q['text'] ?? ''}'.trim() == t) return true;
  }
  return false;
}

/// payload 是否带顶层 freeText 开关（控制"其他…"入口是否出现）。
bool payloadAllowsFreeText(Map payload) => payload['freeText'] == true;

/// 待发附件的上传决策（静默预上传用）。
enum AttachUploadPlan {
  /// 已有**同会话**的上传结果：直接引用 ref，不再传一次。
  reuse,

  /// 正有一条发往同会话的上传在飞：等它落地，别重复传。
  inflight,

  /// 没传过 / 结果属于别的会话 / 传失败：现在传。
  fresh,
}

/// 附件该不该复用已有上传结果。
///
/// 附件 ref 是**会话域**的：在 A 会话传的 ref 拿去 B 会话发是无效引用，
/// 所以「有结果」必须同时「是同一个会话」才能复用；否则退回现场上传。
AttachUploadPlan attachUploadPlan({
  required bool refMatchesSession,
  required bool inflightMatchesSession,
}) {
  if (refMatchesSession) return AttachUploadPlan.reuse;
  if (inflightMatchesSession) return AttachUploadPlan.inflight;
  return AttachUploadPlan.fresh;
}
