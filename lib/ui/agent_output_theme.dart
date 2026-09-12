import 'package:flutter/material.dart';

/// Agent 输出区设计令牌（内容渲染层专用）。
///
/// 依据 docs/UI-SPEC.md §5/§6/§26：Agent UI 是开发者工具，不是文章阅读器——
/// 标题克制（600 而非 800）、层级紧凑（headingHeight 1.3）、bold 降级为
/// 600（模型输出的 **强调** 不该糊成整段粗体）。
/// 色彩仍复用全局 ZT（品牌层），这里只管「输出内容层」的排版与间距。
abstract final class AgentType {
  // ---- Typography -------------------------------------------------------
  static const double bodySize = 14;
  static const double bodyHeight = 1.5;

  static const double bodySmallSize = 12.5;
  static const double bodySmallHeight = 1.4;

  static const double h1Size = 18;
  static const double h2Size = 16;
  static const double h3Size = 15;
  static const FontWeight headingWeight = FontWeight.w600;
  static const double headingHeight = 1.3;

  /// **强调** 在 Agent UI 里降为 600：模型爱整句加粗，w800+ 会糊成粗体文章。
  static const FontWeight emphasisWeight = FontWeight.w600;

  // ---- Spacing（4/8/12/16/20/24 体系，禁 32+ 随机空白）--------------------
  static const double spInline = 4;
  static const double spListItem = 6;
  static const double spParagraph = 8;
  static const double spHeading = 16;
  static const double spCodeBlock = 12;
  static const double spMessage = 12;

  /// h1~h3 的上下留白（紧凑：标题上 16 下 6）。
  static const EdgeInsets headingPadding = EdgeInsets.fromLTRB(0, 16, 0, 6);

  /// 段落间距。
  static const EdgeInsets paragraphPadding = EdgeInsets.symmetric(vertical: 4);

  /// 行内 code 的水平内边距。
  static const EdgeInsets codeInlinePadding = EdgeInsets.symmetric(
    horizontal: 4,
  );

  static TextStyle heading1(Color color) => TextStyle(
    fontSize: h1Size,
    fontWeight: headingWeight,
    height: headingHeight,
    color: color,
  );

  static TextStyle heading2(Color color) => TextStyle(
    fontSize: h2Size,
    fontWeight: headingWeight,
    height: headingHeight,
    color: color,
  );

  static TextStyle heading3(Color color) => TextStyle(
    fontSize: h3Size,
    fontWeight: headingWeight,
    height: headingHeight,
    color: color,
  );

  static TextStyle body(Color color) => TextStyle(
    fontSize: bodySize,
    fontWeight: FontWeight.w400,
    height: bodyHeight,
    color: color,
  );

  static TextStyle bodySmall(Color color) => TextStyle(
    fontSize: bodySmallSize,
    fontWeight: FontWeight.w400,
    height: bodySmallHeight,
    color: color,
  );
}
