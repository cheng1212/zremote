import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'agent_output_theme.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../protocol/conversation.dart';
import '../theme.dart';
import 'composer_logic.dart'
    show attachmentIsImage, closeStreamingMarkdown, codeBlockPreview, sniffImageMime;
import 'image_cache.dart';

/// 全屏看图：黑底、双指缩放、点一下关闭。附件缩略图/回显气泡/附件条共用。
/// 支持三种来源（优先级）：bytes > attachment ref > file。
/// 优先用全局缓存，缓存未命中再走传入参数。
void openImageViewer(
  BuildContext context, {
  Uint8List? bytes,
  File? file,
  String? attachmentRef,
}) async {
  Uint8List? imageBytes = bytes;

  // 1) 附件 ref → 优先查缓存
  if (imageBytes == null && attachmentRef != null) {
    imageBytes = globalImageCache.get(attachmentRef);
  }

  // 2) 本地文件路径 → 尝试按路径查缓存
  if (imageBytes == null && file != null) {
    imageBytes = globalImageCache.getByPath(file.path);
  }

  // 3) 还没有字节：若有 file 尝试读文件并入缓存
  if (imageBytes == null && file != null) {
    try {
      imageBytes = await file.readAsBytes();
      if (imageBytes.isNotEmpty) {
        globalImageCache.putByPath(file.path, imageBytes);
      }
    } on Object {
      // 读失败就放弃，下面 image 为 null 会直接返回
    }
  }

  if (imageBytes == null) return;

  // 入缓存（若有 ref）
  if (attachmentRef != null) {
    globalImageCache.put(attachmentRef, imageBytes);
  }

  final image = Image.memory(
    imageBytes,
    fit: BoxFit.contain,
    gaplessPlayback: true,
  );
  if (!context.mounted) return;
  unawaited(showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (dialogCtx) => GestureDetector(
      onTap: () => Navigator.pop(dialogCtx),
      child: InteractiveViewer(maxScale: 5, child: Center(child: image)),
    ),
  ));
}

/// 多图画廊：左右滑动逐张预览（参考主流 IM 的图片消息查看器）。
void openImageGallery(
  BuildContext context,
  List<Uint8List> images, {
  int initialIndex = 0,
}) {
  if (images.isEmpty) return;
  showDialog(
    context: context,
    barrierColor: Colors.black,
    barrierDismissible: false,
    builder: (_) => _ImageGalleryPager(
      images: images,
      initialIndex: initialIndex.clamp(0, images.length - 1),
    ),
  );
}

class _ImageGalleryPager extends StatefulWidget {
  final List<Uint8List> images;
  final int initialIndex;

  const _ImageGalleryPager({required this.images, required this.initialIndex});

  @override
  State<_ImageGalleryPager> createState() => _ImageGalleryPagerState();
}

class _ImageGalleryPagerState extends State<_ImageGalleryPager> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _page = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          PageView(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              for (final bytes in widget.images)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Center(
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
            ],
          ),
          Positioned(
            top: 18,
            right: 18,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 26,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                '${_page + 1} / ${widget.images.length}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 每行按 kind 渲染；统一入口。userInput 行的附件需要 transport 回显图片。
Widget buildRowCard(
  Map<String, dynamic> row, {
  ConversationV4? transport,
  String sessionId = '',
  ValueChanged<String>? onRowAction,
  bool entrance = false,
}) {
  // 入场动画（渐显+微上滑 180ms）只给调用方显式指定的行播——
  // 反向列表里滚动进入视口的旧行也播的话，动画方向会逆着滚动，
  // 观感就是"滑不动"（2026-09-12 真机反馈后收窄）。
  Widget card = _buildRowCardInner(
    row,
    transport: transport,
    sessionId: sessionId,
    onRowAction: onRowAction,
  );
  final rowId = row['rowId'];
  if (rowId == null || !entrance) return card;
  return _RowEntrance(key: ValueKey<String>('entrance-$rowId'), child: card);
}

class _RowEntrance extends StatefulWidget {
  final Widget child;
  const _RowEntrance({super.key, required this.child});
  @override
  State<_RowEntrance> createState() => _RowEntranceState();
}

class _RowEntranceState extends State<_RowEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

Widget _buildRowCardInner(
  Map<String, dynamic> row, {
  required ConversationV4? transport,
  required String sessionId,
  ValueChanged<String>? onRowAction,
}) {
  switch (row['kind']) {
    case 'userInput':
      return UserBubble(
        text: '${row['text'] ?? row['inputText'] ?? ''}',
        attachments: row['attachments'],
        transport: transport,
        sessionId: sessionId,
      );
    case 'assistantText':
      return AssistantBlock(
        text: '${row['text'] ?? ''}',
        state: '${row['state'] ?? ''}',
        errorText: extractRowError(row),
        row: row,
        onAction: onRowAction,
      );
    case 'reasoning':
      return ReasoningCard(
        text: '${row['text'] ?? ''}',
        streaming: row['state'] == 'streaming',
      );
    case 'toolCall':
      return ToolCallCard(row: row);
    case 'subagent':
      return SubagentCard(row: row);
    case 'error':
    case 'systemError':
      final text = '${row['text'] ?? ''}'.trim();
      return ErrorCard(
        title: '执行出错',
        detail: text.isNotEmpty ? text : extractRowError(row),
      );
    case 'turnHeader':
      return const TurnDivider(icon: Icons.turn_right_rounded, label: '新回合');
    case 'timelineMarker':
      // marker 行是有语义的系统事件（桌面端渲染成带文案的分隔提示条），
      // 不能一律给空标签——压缩上下文这种关键事件隐形了用户会以为消息丢
      // 了（BUG-30）。形状实证（桌面反解）：row.marker = {type, status,
      // origin?}；type ∈ compact/goalVerify/forkNotice。
      final marker = row['marker'];
      if (marker is Map) {
        final label = _markerLabel(marker);
        if (label != null) {
          return TurnDivider(
            icon: '${marker['type']}' == 'compact'
                ? Icons.compress_rounded
                : Icons.more_horiz,
            label: label,
          );
        }
      }
      return const TurnDivider(icon: Icons.more_horiz, label: '');
    default:
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '· ${row['kind'] ?? '?'} ·',
          style: TextStyle(fontSize: 10, color: ZT.inkFaint),
        ),
      );
  }
}

/// timelineMarker 行 → 中文提示文案。返回 null = 无语义，走空白分隔线。
/// status 全集实证自桌面端渲染器（chat.contextCompaction.* 消息键）。
String? _markerLabel(Map marker) {
  switch ('${marker['type']}') {
    case 'compact':
      switch ('${marker['status']}') {
        case 'running':
          return '正在压缩上下文…';
        case 'completed':
          return '${marker['origin']}' == 'auto' ? '上下文已满，已自动压缩' : '已压缩上下文';
        case 'noop':
          return '上下文无需压缩';
        case 'cancelled':
          return '压缩已中断';
        case 'failed':
          return '压缩失败';
        default:
          return '已压缩上下文';
      }
    case 'forkNotice':
      return '已分叉新会话';
    default:
      return null; // goalVerify 等：保持原空白分隔线
  }
}

// ------------------------------------------------------------- memoized md

/// MarkdownBody 的记忆化包装：文本没变就不重排（流式 append 只重排本行）。
/// 流式期间（[streaming] = true）重排节流到 200ms 一帧——长回复尾部
/// 全量 parse 是 O(n)，每 50ms 批次都重排会把 UI 线程打满；流式结束后
/// 立即做最终渲染，不丢尾字。
class MemoMarkdown extends StatefulWidget {
  final String text;
  final TextStyle? baseStyle;
  final bool streaming;

  const MemoMarkdown({
    super.key,
    required this.text,
    this.baseStyle,
    this.streaming = false,
  });

  @override
  State<MemoMarkdown> createState() => _MemoMarkdownState();
}

class _MemoMarkdownState extends State<MemoMarkdown> {
  String? _built;
  Widget? _cached;
  int _lastBuildAtMs = 0;

  static const _throttleMs = 120;

  @override
  void didUpdateWidget(covariant MemoMarkdown old) {
    super.didUpdateWidget(old);
    if (_built != null && _built == widget.text) return;
    // 流式节流：距上次重排不足 200ms 就先沿用旧缓存，等下一个批次。
    if (widget.streaming &&
        _built != null &&
        DateTime.now().millisecondsSinceEpoch - _lastBuildAtMs < _throttleMs) {
      return;
    }
    _built = null;
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) return _cached!;
    _built = widget.text;
    _lastBuildAtMs = DateTime.now().millisecondsSinceEpoch;
    // 流式期间未闭合的 ``` 围栏先补全再解析，防代码块高度震荡
    //（标准工程方案 §5.3-(2)）。非流式的定稿文本不处理。
    _cached = MarkdownBody(
      data: widget.streaming
          ? closeStreamingMarkdown(widget.text)
          : widget.text,
      selectable: true,
      softLineBreak: true,
      onTapLink: (text, href, title) {
        if (href != null) _launchHref(href);
      },
      builders: {'pre': _CodeBlockBuilder()},
      imageBuilder: (uri, _, _) => _MarkdownImage(uri: uri),
      styleSheet: MarkdownStyleSheet(
        p:
            widget.baseStyle ??
            const TextStyle(
              fontSize: AgentType.bodySize,
              height: AgentType.bodyHeight,
              color: ZT.ink,
            ),
        h1: const TextStyle(
          fontSize: AgentType.h1Size,
          fontWeight: AgentType.headingWeight,
          height: AgentType.headingHeight,
          color: ZT.ink,
        ),
        h2: const TextStyle(
          fontSize: AgentType.h2Size,
          fontWeight: AgentType.headingWeight,
          height: AgentType.headingHeight,
          color: ZT.ink,
        ),
        h3: const TextStyle(
          fontSize: AgentType.h3Size,
          fontWeight: AgentType.headingWeight,
          height: AgentType.headingHeight,
          color: ZT.ink,
        ),
        strong: const TextStyle(
          fontWeight: AgentType.emphasisWeight,
          color: ZT.ink,
        ),
        em: const TextStyle(fontStyle: FontStyle.italic),
        code: TextStyle(
          fontSize: 12.5,
          fontFamily: 'monospace',
          backgroundColor: ZT.bg,
          color: ZT.primaryDeep,
        ),
        codeblockDecoration: BoxDecoration(
          color: ZT.ink,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(width: 1.4, color: ZT.ink),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(width: 3, color: ZT.primary)),
          color: ZT.surface,
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        listBullet: const TextStyle(fontSize: 14, height: 1.5, color: ZT.ink),
        tableBorder: TableBorder.all(width: 1, color: ZT.line),
        a: const TextStyle(color: ZT.primaryDeep, fontWeight: FontWeight.w700),
      ),
    );
    return _cached!;
  }
}

/// Markdown 图片统一限高：模型回贴的 data-URI 截图按原始尺寸渲染，
/// 一张竖版截图就能糊满整屏（"黑布"的另一个来源），也压不住解码内存。
class _MarkdownImage extends StatelessWidget {
  final Uri uri;

  const _MarkdownImage({required this.uri});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final Uint8List? bytes = uri.scheme == 'data'
        ? uri.data?.contentAsBytes()
        : null;
    final Widget image;
    if (bytes != null) {
      image = Image.memory(
        bytes,
        fit: BoxFit.contain,
        cacheWidth: (420 * dpr).round(),
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      image = Image.network(
        uri.toString(),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onTap: bytes == null
            ? null
            : () => openImageViewer(context, bytes: bytes),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 420),
            width: double.infinity,
            color: ZT.bg,
            child: image,
          ),
        ),
      ),
    );
  }
}

/// Markdown 链接 → 系统浏览器。打不开就静默（链接文字还在，别为它打断阅读）。
Future<void> _launchHref(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null || !uri.hasScheme) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    // ignore
  }
}

/// 代码块 builder，挂在 'pre' 标签上：顶部语言标签 + 复制按钮，
/// 正文完整铺开（软换行，无内滚）。visitText 返回 null 避免默认路径
/// 重复渲染正文；文本从 element.textContent 取，外层仍由 codeblockDecoration 包住。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => null;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final classValue = element.attributes['class'] ?? '';
    final lang =
        RegExp(r'language-([\w+#.-]+)').firstMatch(classValue)?.group(1) ?? '';
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return _CodeBlock(code: code, language: lang);
  }
}

class _CodeBlock extends StatefulWidget {
  final String code;
  final String language;

  const _CodeBlock({required this.code, required this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  Timer? _resetTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: Colors.white12)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 0, 2, 0),
          child: Row(
            children: [
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.language.isEmpty ? '代码' : widget.language,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: ZT.onInk.withValues(alpha: 0.55),
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _copy,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                    size: 15,
                    color: _copied ? ZT.aqua : ZT.onInk.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          // 完整铺开不内滚：长代码全部显示（多长都画出来），超长行软换行，
          // 上下左右滚动全部交给聊天列表——代码块不再吞掉滑动手势。
          child: SelectableText(
            codeBlockPreview(widget.code),
            style: const TextStyle(
              fontSize: 12,
              height: 1.55,
              fontFamily: 'monospace',
              color: ZT.onInk,
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- rows

/// 一键复制小图标：点击复制全文，1.2s 后回落（对勾=已复制）。
/// 48dp 触控热区，视觉只有 30dp——不挤版面也要好按。
class _MiniCopyButton extends StatefulWidget {
  final String text;
  const _MiniCopyButton({required this.text});

  @override
  State<_MiniCopyButton> createState() => _MiniCopyButtonState();
}

class _MiniCopyButtonState extends State<_MiniCopyButton> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        setState(() => _copied = true);
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _copied = false);
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SizedBox(
          width: 48,
          height: 30,
          child: Icon(
            _copied ? Icons.check_rounded : Icons.copy_rounded,
            size: 15,
            color: _copied ? ZT.aqua : ZT.inkFaint,
          ),
        ),
      ),
    );
  }
}

class UserBubble extends StatelessWidget {  final String text;
  final Object? attachments;
  final ConversationV4? transport;
  final String sessionId;

  const UserBubble({
    super.key,
    required this.text,
    this.attachments,
    this.transport,
    this.sessionId = '',
  });

  @override
  Widget build(BuildContext context) {
    final atts = _attItems(attachments);
    // 微信式：图片一张一张独立排（无底色），文字与文件 chip 才进气泡。
    final hasBubble = text.isNotEmpty || atts.any((a) => !attachmentIsImage(a));
    return Padding(
      padding: const EdgeInsets.only(left: 44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ...imageBlocks(
            attachments,
            transport: transport,
            sessionId: sessionId,
            maxW: MediaQuery.of(context).size.width * 0.82,
          ),
          if (hasBubble)
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.82,
              ),
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
              decoration: ShapeDecoration(
                color: ZT.ink,
                shadows: ZT.hard(
                  dx: 2.5,
                  dy: 2.5,
                  color: ZT.ink.withValues(alpha: 0.28),
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(ZT.radius),
                    topRight: Radius.circular(4),
                    bottomLeft: Radius.circular(ZT.radius),
                    bottomRight: Radius.circular(ZT.radius),
                  ),
                  side: BorderSide(width: 1.6, color: ZT.ink),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ...bubbleAttachments(
                    attachments,
                    transport: transport,
                    sessionId: sessionId,
                  ),
                  if (text.isNotEmpty)
                    SelectableText(
                      text,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: ZT.onInk,
                      ),
                    ),
                ],
              ),
            ),
          // 一键复制自己发的消息：ChatGPT 式小图标，点了变对勾即完成。
          if (text.isNotEmpty)
            _MiniCopyButton(text: text),
        ],
      ),
    );
  }
}

/// 附件条目解析：cast 成 String→dynamic map 列表。
List<Map<String, dynamic>> _attItems(Object? attachments) {
  if (attachments is! List) return const [];
  return [
    for (final a in attachments)
      if (a is Map) a.cast<String, dynamic>(),
  ];
}

/// 图片独立块（微信式）：每张图一个右对齐块，无边框无底色、按原始比例
/// 等比显示，纵向一张一张排开、互不相关。给用户消息与发送中回显共用；
/// 点任意一张进画廊，左右滑动看整条消息的图。
List<Widget> imageBlocks(
  Object? attachments, {
  required ConversationV4? transport,
  required String sessionId,
  double? maxW,
}) {
  final images = _attItems(attachments).where(attachmentIsImage).toList();
  if (images.isEmpty) return const [];
  return [
    for (var i = 0; i < images.length; i++)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: AttachmentView(
            attachment: images[i],
            transport: transport,
            sessionId: sessionId,
            maxW: maxW,
            gallery: images,
            galleryIndex: i,
          ),
        ),
      ),
  ];
}

/// 气泡内的文件 chip（非图片附件）；图片走 imageBlocks 独立排。
List<Widget> bubbleAttachments(
  Object? attachments, {
  required ConversationV4? transport,
  required String sessionId,
}) {
  final others = _attItems(attachments).where((a) => !attachmentIsImage(a));
  if (others.isEmpty) return const [];
  return [
    for (final a in others)
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: AttachmentView(
          attachment: a,
          transport: transport,
          sessionId: sessionId,
        ),
      ),
  ];
}

/// 竖图按这个高度封顶收窄，横图随气泡宽等比。
const double _maxImageH = 300.0;

/// 解出的宽高比按 ref 全局缓存：重进聊天页/画廊翻看不重复解码。
final Map<String, double> _aspectCache = {};

/// 聊天记录里的附件：图片拉字节回显，其他文件显示名称 chip。
/// [maxW] 是可用的显示宽度（一张一张排时为气泡宽度）；图片按原始比例
/// 等比显示，无边框无底色。 [gallery] 传入整条消息的图片组：
/// 点任意一张可左右滑动看全部。
class AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ConversationV4? transport;
  final String sessionId;
  final double? maxW;
  final List<Map<String, dynamic>>? gallery;
  final int galleryIndex;

  const AttachmentView({
    super.key,
    required this.attachment,
    this.transport,
    required this.sessionId,
    this.maxW,
    this.gallery,
    this.galleryIndex = 0,
  });

  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  Uint8List? _bytes;
  bool _failed = false;
  // mime/扩展名都认不出的图（相册无后缀图常见），字节到手后按魔数补判。
  bool _sniffedImage = false;
  // 原始宽高比（w/h），等比显示用；解出来前先用默认比例占位。
  double? _aspect;

  bool get _isImage {
    if (_sniffedImage) return true;
    return attachmentIsImage(widget.attachment);
  }

  String get _fileName =>
      '${widget.attachment['fileName'] ?? widget.attachment['name'] ?? '附件'}';

  // 本地直显：发送中的回显气泡带原始字节（上传完成前就能看图）。
  Uint8List? get _localBytes {
    final b = widget.attachment['bytes'];
    return b is Uint8List && b.isNotEmpty ? b : null;
  }

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  @override
  void didUpdateWidget(covariant AttachmentView old) {
    super.didUpdateWidget(old);
    if (old.attachment['ref'] != widget.attachment['ref'] &&
        _isImage &&
        _bytes == null &&
        !_failed) {
      _load();
    }
  }

  Future<void> _load() async {
    final local = _localBytes;
    if (local != null) {
      _applyBytes(local);
      unawaited(_resolveAspect(local));
      return;
    }
    final ref = widget.attachment['ref'] as String?;
    final transport = widget.transport;
    if (ref == null || ref.isEmpty || transport == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final cached = globalImageCache.get(ref);
    if (cached != null) {
      _applyBytes(cached);
      unawaited(_resolveAspect(cached));
      return;
    }
    try {
      final res = await transport.attachmentRead(widget.sessionId, ref: ref);
      if (mounted && res.bytes.isNotEmpty) {
        _applyBytes(res.bytes);
        globalImageCache.put(ref, res.bytes);
        unawaited(_resolveAspect(res.bytes));
      } else if (mounted) {
        setState(() => _failed = true);
      }
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _applyBytes(Uint8List bytes) {
    setState(() {
      _bytes = bytes;
      _failed = false;
      if (!_sniffedImage && sniffImageMime(bytes) != null) {
        _sniffedImage = true;
      }
    });
  }

  /// 解宽高比：只解码 24px 宽的缩略（保持比例），不按原尺寸吃内存。
  /// 结果按 ref 进全局缓存，重进聊天页不用再解。
  Future<void> _resolveAspect(Uint8List bytes) async {
    final refKey = widget.attachment['ref'] as String?;
    final key = (refKey == null || refKey.isEmpty) ? null : refKey;
    final cached = key == null ? null : _aspectCache[key];
    if (cached != null) {
      if (mounted) setState(() => _aspect = cached);
      return;
    }
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (h > 0 && w > 0) {
        final natural = w / h;
        if (key != null) _aspectCache[key] = natural;
        if (mounted) setState(() => _aspect = natural);
      }
    } on Object {
      // 解不出来就保持默认比例占位，不挡查看。
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = _fileName;
    if (_isImage) {
      final maxW = widget.maxW ?? 240;
      final bytes = _bytes;
      if (bytes != null) {
        return GestureDetector(
          onTap: () => _openViewer(context, bytes),
          child: _imageBox(maxW, bytes, context),
        );
      }
      // 占位/失败：素色圆角块（无边框），失败可点重试。
      return _imagePlaceholder(maxW, failed: _failed);
    }
    final bytes = widget.attachment['bytes'];
    final sizeLabel = bytes is num && bytes > 0
        ? (bytes > 1024 * 1024
              ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
              : '${(bytes / 1024).toStringAsFixed(0)} KB')
        : '';
    return _chip(
      icon: const Icon(
        Icons.insert_drive_file_rounded,
        size: 15,
        color: ZT.aqua,
      ),
      label: sizeLabel.isEmpty ? fileName : '$fileName · $sizeLabel',
    );
  }

  /// 图片显示盒：宽随气泡（竖图按 300 高封顶收窄），比例未知时先用
  /// 默认比例占位，解出来后无缝切换。无边框无底色，只有 12px 圆角。
  Widget _imageBox(double maxW, Uint8List bytes, BuildContext context) {
    final aspect = _aspect;
    double w;
    double h;
    if (aspect != null && aspect.isFinite && aspect > 0) {
      w = maxW;
      h = w / aspect;
      if (h > _maxImageH) {
        h = _maxImageH;
        w = h * aspect;
      }
    } else {
      w = maxW <= 240 ? maxW : 240;
      h = w * 0.66;
    }
    final cacheW = (w * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: w,
        height: h,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: cacheW,
          errorBuilder: (_, _, _) => _imagePlaceholder(maxW, failed: true),
        ),
      ),
    );
  }

  /// 加载占位：素色圆角块；失败时给断裂图标 + 点击重试。
  Widget _imagePlaceholder(double maxW, {required bool failed}) {
    final w = maxW <= 240 ? maxW : 240.0;
    return Container(
      width: w,
      height: w * 0.66,
      decoration: ShapeDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      alignment: Alignment.center,
      child: failed
          ? GestureDetector(
              onTap: _load,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.broken_image_rounded,
                    size: 22,
                    color: ZT.rose,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '加载失败 · 点击重试',
                    style: TextStyle(
                      fontSize: 11,
                      color: ZT.onInk.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: ZT.onInk,
              ),
            ),
    );
  }

  /// 点缩略图看图：单图直接全屏；多图进画廊左右滑动看整条消息。
  Future<void> _openViewer(BuildContext context, Uint8List bytes) async {
    final gal = widget.gallery;
    if (gal == null || gal.length < 2) {
      final ref = widget.attachment['ref'] as String?;
      openImageViewer(context, bytes: bytes, attachmentRef: ref);
      return;
    }
    // 收集整条消息的图片字节（本地直显 > 缓存 > attachmentRead），
    // 个别加载失败的跳过，不阻塞其他张。
    final images = <Uint8List>[];
    var tappedIndex = 0;
    for (final m in gal) {
      final b = m['bytes'];
      if (b is Uint8List && b.isNotEmpty) {
        if (identical(m, widget.attachment)) tappedIndex = images.length;
        images.add(b);
        continue;
      }
      final ref = m['ref'] as String?;
      if (ref == null || ref.isEmpty) continue;
      var cached = globalImageCache.get(ref);
      if (cached == null) {
        try {
          final res = await widget.transport?.attachmentRead(
            widget.sessionId,
            ref: ref,
          );
          final rb = res?.bytes;
          if (rb != null && rb.isNotEmpty) {
            globalImageCache.put(ref, rb);
            cached = rb;
          }
        } on Object {
          continue; // 这张拿不到就跳过
        }
      }
      if (cached != null) {
        if (identical(m, widget.attachment)) tappedIndex = images.length;
        images.add(cached);
      }
    }
    if (!context.mounted) return;
    if (images.isEmpty) {
      openImageViewer(context, bytes: bytes);
      return;
    }
    openImageGallery(
      context,
      images,
      initialIndex: tappedIndex.clamp(0, images.length - 1),
    );
  }

  Widget _chip({required Widget icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: ShapeDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            width: 1,
            color: Colors.white.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: ZT.onInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AssistantBlock extends StatelessWidget {
  final String text;
  final String state;

  /// 行上捞到的错误信息（buildRowCard 用 extractRowError 取）。
  final String? errorText;

  /// 原行数据（feedback/entityId/rowId）：完成后渲染 ChatGPT 式常驻操作条。
  final Map<String, dynamic>? row;

  /// 操作条动作：copy / like / dislike / clearFeedback / regenerate / fork。
  final ValueChanged<String>? onAction;

  const AssistantBlock({
    super.key,
    required this.text,
    required this.state,
    this.errorText,
    this.row,
    this.onAction,
  });

  static bool _failed(String state) =>
      state == 'completedError' || state == 'error';

  @override
  Widget build(BuildContext context) {
    final r = row; // 字段不提升，先落局部
    final failed = _failed(state);
    if (text.trim().isEmpty) {
      // 报错行哪怕空文本也必须可见——以前这里 shrink 成空气，
      // 服务端报错在手机端就"什么都没有"了。
      if (failed) return ErrorCard(title: '本轮回复中断', detail: errorText);
      return state == 'streaming'
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  PulseDot(color: ZT.primary, animate: true),
                  SizedBox(width: 8),
                  Text(
                    '思考中…',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ZT.inkFaint,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failed) ErrorCard(title: '本轮回复中断', detail: errorText),
          if (state == 'streaming')
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  PulseDot(color: ZT.primary, animate: true, size: 6),
                  const SizedBox(width: 6),
                  Text(
                    '正在回复',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: ZT.primaryDeep,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          // SelectionArea：长按进入选择，拖拽扩展选区，系统菜单（中文）
          // 一键复制。普通拖动仍滚动列表，不抢手势。
          SelectionArea(child: MemoMarkdown(text: text, streaming: state == 'streaming')),
          if (state == 'streaming') ...[
            const SizedBox(height: 2),
            const _BlinkingCaret(),
          ],
          if (r != null && r['rowId'] != null && state != 'streaming')
            _AssistantActionBar(row: r, onAction: onAction),
        ],
      ),
    );
  }
}

/// 助手消息下的常驻操作条（ChatGPT 式）：复制/赞/踩/重新生成/分叉。
/// 当前反馈态高亮；点已高亮的=撤销。流式/无身份行不渲染。
class _AssistantActionBar extends StatelessWidget {
  final Map<String, dynamic> row;
  final ValueChanged<String>? onAction;

  const _AssistantActionBar({required this.row, this.onAction});

  @override
  Widget build(BuildContext context) {
    final r = row;
    final onAction = this.onAction;
    final feedback = '${r['feedback'] ?? ''}';
    final entityId = '${r['entityId'] ?? r['turnId'] ?? ''}';
    final canRowTarget = entityId.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _barIcon(
            icon: Icons.copy_rounded,
            tip: '复制全文',
            onTap: () => Clipboard.setData(
              ClipboardData(text: '${r['text'] ?? ''}'),
            ),
          ),
          const SizedBox(width: 16),
          _barIcon(
            icon: feedback == 'like'
                ? Icons.thumb_up
                : Icons.thumb_up_off_alt,
            tip: '赞',
            color: feedback == 'like' ? ZT.primaryDeep : null,
            onTap: onAction == null ? null : () => onAction('like'),
          ),
          const SizedBox(width: 16),
          _barIcon(
            icon: feedback == 'dislike'
                ? Icons.thumb_down
                : Icons.thumb_down_off_alt,
            tip: '踩',
            color: feedback == 'dislike' ? ZT.rose : null,
            onTap: onAction == null ? null : () => onAction('dislike'),
          ),
          if (canRowTarget) ...[
            const SizedBox(width: 16),
            _barIcon(
              icon: Icons.refresh_rounded,
              tip: '重新生成本轮',
              onTap: onAction == null ? null : () => onAction('regenerate'),
            ),
            const SizedBox(width: 16),
            _barIcon(
              icon: Icons.call_split_rounded,
              tip: '从此分叉新会话',
              onTap: onAction == null ? null : () => onAction('fork'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _barIcon({
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
    Color? color,
  }) {
    return IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(5),
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      icon: Icon(icon, size: 16, color: color ?? ZT.inkFaint),
      onPressed: onTap,
    );
  }
}

/// 流式尾部光标：独立闪烁 Widget（600ms repeat reverse），绝不把光标
/// 字符拼进文本（参与重排会引发整体 reflow——标准工程方案 §5.3-(3)）。
class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(
        width: 2.5,
        height: 14,
        color: ZT.primary,
      ),
    );
  }
}

/// 从行上捞错误信息字段（服务端形状未完全实测，多兜底几个键）。
String? extractRowError(Map<String, dynamic> row) {
  for (final k in [
    'error',
    'errorMessage',
    'errorText',
    'statusMessage',
    'message',
  ]) {
    // 行级错误同样可能是结构体（同 lastError 形态），共用解析。
    final text = errorValueText(row[k]);
    if (text != null) return text;
  }
  return null;
}

/// 服务端/模型报错卡：显眼 rose 样式——报错必须可见，不许静默。
class ErrorCard extends StatelessWidget {
  final String title;
  final String? detail;

  const ErrorCard({super.key, required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    final detail = this.detail?.trim() ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 10),
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: ZT.rose.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(width: 1.2, color: ZT.rose.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, size: 13, color: ZT.rose),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: ZT.rose,
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                detail,
                maxLines: 12,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: ZT.rose.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ReasoningCard extends StatefulWidget {
  final String text;
  final bool streaming;

  const ReasoningCard({super.key, required this.text, required this.streaming});

  @override
  State<ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<ReasoningCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty && !widget.streaming) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 24),
      decoration: BoxDecoration(
        color: ZT.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(width: 1.2, color: ZT.grape.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PulseDot(
                      color: ZT.grape,
                      animate: widget.streaming,
                      size: widget.streaming ? 6 : 5,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.streaming ? '深度思考中' : '思考过程',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: ZT.grape,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: ZT.inkFaint,
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_open && text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SelectableText(
                            text,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: ZT.inkSoft,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      else if (!_open && text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: ZT.inkFaint,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具调用 → 紧凑 Activity Row（单行：状态 + 动作图标 + 目标 + 折叠箭头）。
/// AI Coding Agent 的执行过程不属于正文内容——不占卡片，不抢视觉；
/// 展开才看输入/输出（240px 内滚）。图标按工具族映射（读/写/跑/搜）。
/// 工具调用 → 紧凑 Activity Row（单行：状态 + 动作图标 + 目标 + 折叠箭头）。
/// AI Coding Agent 的执行过程不属于正文内容——不占卡片不抢视觉；
/// 展开才看输入/输出（mono、240px 内滚）。
class ToolCallCard extends StatefulWidget {
  final Map<String, dynamic> row;

  const ToolCallCard({super.key, required this.row});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _open = false;

  static IconData _familyIcon(String name) {
    final n = name.toLowerCase();
    if (n.contains('read') || n.contains('view')) {
      return Icons.description_outlined;
    }
    if (n.contains('edit') || n.contains('write') || n.contains('replace')) {
      return Icons.edit_outlined;
    }
    if (n.contains('search') || n.contains('grep') || n.contains('glob')) {
      return Icons.search_rounded;
    }
    if (n.contains('bash') ||
        n.contains('command') ||
        n.contains('terminal')) {
      return Icons.terminal_rounded;
    }
    if (n.contains('task') || n.contains('agent')) {
      return Icons.groups_outlined;
    }
    if (n.contains('web') || n.contains('fetch')) {
      return Icons.public_rounded;
    }
    return Icons.handyman_outlined;
  }

  Widget _monoBlock(String label, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: ZT.inkFaint,
            ),
          ),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                  color: ZT.inkSoft,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final name = '${row['toolName'] ?? row['name'] ?? '工具'}';
    final state = '${row['state'] ?? ''}';
    final streaming = state == 'streaming';
    final failed = state == 'completedError' || state == 'error';
    final input = '${row['inputText'] ?? ''}';
    final output = row['output'];
    final outputText = output is Map
        ? '${output['text'] ?? ''}'
        : (output is String ? output : '');
    final hasDetail = input.trim().isNotEmpty || outputText.trim().isNotEmpty;
    final summary = input.trim().split('\n').first.trim();
    final target = summary.isNotEmpty ? summary : name;

    return Padding(
      padding: const EdgeInsets.only(top: 3, right: 20),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: hasDetail ? () => setState(() => _open = !_open) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (streaming)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: ZT.primary,
                      ),
                    )
                  else
                    Icon(
                      failed ? Icons.close_rounded : Icons.check_rounded,
                      size: 13,
                      color: failed ? ZT.rose : ZT.aqua,
                    ),
                  const SizedBox(width: 7),
                  Icon(_familyIcon(name), size: 13, color: ZT.inkFaint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      target,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: failed ? ZT.rose : ZT.inkSoft,
                      ),
                    ),
                  ),
                  if (hasDetail)
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 14,
                      color: ZT.inkFaint,
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                child: _open
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4, left: 25),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (input.trim().isNotEmpty)
                              _monoBlock('输入', input),
                            if (outputText.trim().isNotEmpty)
                              _monoBlock('输出', outputText),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SubagentCard extends StatefulWidget {
  final Map<String, dynamic> row;

  const SubagentCard({super.key, required this.row});

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final streaming = row['state'] == 'streaming';
    final summary = '${row['summaryText'] ?? ''}';
    final text = '${row['text'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 20),
      decoration: ShapeDecoration(
        color: ZT.aqua.withValues(alpha: 0.09),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: ZT.inkSide(w: 1.3, color: ZT.aqua),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PulseDot(color: ZT.aqua, animate: streaming, size: 6),
                    const SizedBox(width: 6),
                    const Text(
                      '子代理',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: ZT.aqua,
                      ),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!_open && summary.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: ZT.inkSoft),
                          ),
                        ),
                      if (_open && text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: MemoMarkdown(
                            text: text,
                            streaming: row['state'] == 'streaming',
                            baseStyle: TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: ZT.inkSoft,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TurnDivider extends StatelessWidget {
  final IconData icon;
  final String label;

  const TurnDivider({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: ZT.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(icon, size: 12, color: ZT.inkFaint),
                if (label.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: ZT.inkFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: Divider(color: ZT.line)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- plan

class PlanStep {
  final String content;
  final String status;
  PlanStep({required this.content, this.status = 'pending'});
  // 服务端实测用驼峰 "inProgress"（快照 plan.items[].status），词形归一后比对。
  bool get completed =>
      status.toLowerCase() == 'completed' || status.toLowerCase() == 'done';
  bool get inProgress {
    final s = status.toLowerCase();
    return s == 'in_progress' ||
        s == 'inprogress' ||
        s == 'active' ||
        s == 'running';
  }
}

/// 从快照 plan + todowrite/update_plan 工具行推导计划步骤。
List<PlanStep>? derivePlanSteps({
  required List<Map<String, dynamic>> rows,
  Object? snapshotPlan,
}) {
  final candidates = <Object?>[
    snapshotPlan,
    for (final row in rows.reversed)
      if (_isPlanTool(row)) ...[
        row['input'],
        row['inputText'],
        row['arguments'],
        row['output'],
      ],
  ];
  for (final candidate in candidates) {
    final parsed = _parsePlanValue(candidate);
    if (parsed != null && parsed.isNotEmpty) return parsed;
  }
  return null;
}

bool _isPlanTool(Map<String, dynamic> row) {
  final name = '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase();
  return name.contains('todowrite') ||
      name.contains('todo_write') ||
      name.contains('update_plan') ||
      name.contains('update-plan');
}

List<PlanStep>? _parsePlanValue(Object? value) {
  Object? decoded = value;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  if (decoded is Map) {
    for (final key in const ['todos', 'plan', 'plans', 'steps', 'items']) {
      final result = _parsePlanValue(decoded[key]);
      if (result != null) return result;
    }
    return null;
  }
  if (decoded is! List) return null;
  for (final item in decoded.reversed) {
    if (item is Map) {
      for (final key in const ['todos', 'plan', 'steps', 'items']) {
        final nested = _parsePlanValue(item[key]);
        if (nested != null) return nested;
      }
    }
  }
  final steps = <PlanStep>[];
  for (final item in decoded) {
    if (item is String && item.trim().isNotEmpty) {
      steps.add(PlanStep(content: item.trim()));
    } else if (item is Map) {
      final content =
          '${item['content'] ?? item['step'] ?? item['title'] ?? item['text'] ?? item['activeForm'] ?? item['label'] ?? ''}'
              .trim();
      if (content.isEmpty) continue;
      final status =
          '${item['status'] ?? (item['completed'] == true || item['done'] == true ? 'completed' : 'pending')}';
      steps.add(PlanStep(content: content, status: status));
    }
  }
  return steps.isEmpty ? null : steps;
}

/// 执行计划面板（可折叠）。
class PlanPanel extends StatefulWidget {
  final List<PlanStep> steps;

  const PlanPanel({super.key, required this.steps});

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final completed = widget.steps.where((s) => s.completed).length;
    final progress = widget.steps.isEmpty
        ? 0.0
        : completed / widget.steps.length;
    final current = widget.steps.where((s) => s.inProgress).toList();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shadows: ZT.hard(dx: 3, dy: 3, color: ZT.ink.withValues(alpha: 0.2)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.account_tree_rounded,
                      size: 16,
                      color: ZT.primary,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '执行计划 · $completed/${widget.steps.length}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 17,
                      color: ZT.inkFaint,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: ZT.line,
                    color: ZT.aqua,
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!_open && current.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(
                            '▶ ${current.first.content}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: ZT.primary,
                            ),
                          ),
                        ),
                      if (_open)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            children: [
                              for (final step in widget.steps)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 18,
                                        child: step.completed
                                            ? const Icon(
                                                Icons.check_box_rounded,
                                                size: 15,
                                                color: ZT.aqua,
                                              )
                                            : step.inProgress
                                            ? const Icon(
                                                Icons
                                                    .indeterminate_check_box_rounded,
                                                size: 15,
                                                color: ZT.primary,
                                              )
                                            : Icon(
                                                Icons
                                                    .check_box_outline_blank_rounded,
                                                size: 15,
                                                color: ZT.inkFaint.withValues(
                                                  alpha: 0.6,
                                                ),
                                              ),
                                      ),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Text(
                                          step.content,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            height: 1.4,
                                            color: step.completed
                                                ? ZT.inkFaint
                                                : ZT.ink,
                                            decoration: step.completed
                                                ? TextDecoration.lineThrough
                                                : null,
                                            fontWeight: step.inProgress
                                                ? FontWeight.w700
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
