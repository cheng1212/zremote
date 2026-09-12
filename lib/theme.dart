import 'package:flutter/material.dart';

import 'protocol/relay_client.dart';

/// 柑橘晨光 Citrus Morning — neo-brutalist light theme.
///
/// 奶油底 + 墨线硬阴影 + 蜜橘主色；状态色：running=橘 / done=青 / error=玫红 /
/// queued=柠黄 / thinking=葡萄紫。
abstract final class ZT {
  static const bg = Color(0xFFFFF6E9);
  static const surface = Color(0xFFFFFCF5);
  static const ink = Color(0xFF241C15);
  static const inkSoft = Color(0xFF5C5044);
  // 微标签专用灰棕。原 #98897A 对比度仅 ~2.8:1，加深到 ~4.6:1 保住 10px 小字可读。
  static const inkFaint = Color(0xFF7A6853);
  static const line = Color(0xFFE8DCC8);
  static const primary = Color(0xFFFF6B1A);
  static const primaryDeep = Color(0xFFE05500);
  static const aqua = Color(0xFF0FB5A3);
  static const lemon = Color(0xFFFFC93C);
  static const rose = Color(0xFFE5484D);
  static const grape = Color(0xFF7C5CFF);
  static const onInk = Color(0xFFFFF6E9);

  static const radius = 14.0;

  /// 最小触控目标 48dp（Material / Android 无障碍建议值）。
  /// 自绘的小按钮（_action / 圆键 / 图标入口）一律按这个撑热区，
  /// 视觉可以小，但**能按到的范围不能小**——手指没有 1px 精度。
  static const tapMin = 48.0;

  static List<BoxShadow> hard({double dx = 3, double dy = 3, Color? color}) => [
    BoxShadow(offset: Offset(dx, dy), color: color ?? ink, blurRadius: 0),
  ];

  static BorderSide inkSide({double w = 1.6, Color color = ink}) =>
      BorderSide(width: w, color: color);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        surface: bg,
      ).copyWith(surface: bg, primary: primary, secondary: aqua, error: rose),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
        ),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1),
      // 全 App 的 IconButton 统一到 48dp 热区：Material 默认 40（视觉 24 图标）
      // 在手机上偏小，尤其 AppBar 右上角那种无底无边的纯图标按钮。
      // 图标本身仍是 24，只把可点范围撑开。
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(tapMin, tapMin),
          padding: const EdgeInsets.all(12),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: inkSide(),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: inkSide(),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: inkSide(w: 2.2, color: primaryDeep),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: const TextStyle(color: onInk, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: inkSide(w: 1.4),
        ),
      ),
      splashFactory: InkRipple.splashFactory,
    );
  }
}

/// 带墨线 + 硬阴影的卡片容器。
class HardCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final double radius;
  final double shadowDx;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const HardCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.color = ZT.surface,
    this.radius = ZT.radius,
    this.shadowDx = 3,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return Container(
        padding: padding,
        decoration: ShapeDecoration(
          color: color,
          shadows: ZT.hard(dx: shadowDx),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: ZT.inkSide(),
          ),
        ),
        child: child,
      );
    }
    // Ink 把装饰画到 Material 上层，InkWell 的涟漪才能盖在卡片上面
    // （Material 在 Container 外面的写法会把水波纹藏进不透明背景里）。
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: color,
          shadows: ZT.hard(dx: shadowDx),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: ZT.inkSide(),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// phase / 状态 → (颜色, 中文标签)。
(bool, Color, String) phaseStyle(String phase) => switch (phase) {
  'running' => (true, ZT.primary, '运行中'),
  'prewarming' => (true, ZT.lemon, '预热中'),
  'queued' => (false, ZT.lemon, '排队中'),
  'waitingInput' => (true, ZT.grape, '等待输入'),
  'idle' => (false, ZT.inkFaint, '空闲'),
  'completed' || 'completedSuccess' => (false, ZT.aqua, '已完成'),
  'error' || 'completedError' => (false, ZT.rose, '出错'),
  'paused' => (false, ZT.lemon, '已暂停'),
  _ => (false, ZT.inkFaint, phase.isEmpty ? '空闲' : phase),
};

/// 链路状态 → (颜色, 短标签)。任务页角标与配对页共用一套词汇；
/// 配对页对 waiting/kicked 另行覆盖更详细的引导文案。
(Color, String) relayStateStyle(RelayState s) => switch (s) {
  RelayState.idle => (ZT.inkFaint, '未连接'),
  RelayState.connecting => (ZT.lemon, '连接中'),
  RelayState.authenticating => (ZT.lemon, '认证中'),
  RelayState.waiting => (ZT.lemon, '等待配对'),
  RelayState.paired => (ZT.aqua, '已连接'),
  RelayState.reconnecting => (ZT.lemon, '重连中'),
  RelayState.kicked => (ZT.rose, '已踢下线'),
  RelayState.closed => (ZT.inkFaint, '已断开'),
  RelayState.error => (ZT.rose, '连接失败'),
};

/// 轻提示：普通 2s 墨色，错误 4s 玫红。
void flashMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? ZT.rose : ZT.ink,
      duration: Duration(seconds: error ? 4 : 2),
    ),
  );
}

/// 状态徽章：圆点 + 文字；运行态圆点会呼吸。
class StatusChip extends StatelessWidget {
  final String phase;
  final bool compact;

  const StatusChip({super.key, required this.phase, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final (pulse, color, label) = phaseStyle(phase);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 9,
        vertical: compact ? 2 : 3.5,
      ),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: StadiumBorder(side: ZT.inkSide(w: 1.2, color: color)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulseDot(color: color, animate: pulse, size: compact ? 6 : 7),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10.5 : 11.5,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class PulseDot extends StatefulWidget {
  final Color color;
  final bool animate;
  final double size;

  const PulseDot({
    super.key,
    required this.color,
    required this.animate,
    this.size = 7,
  });

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  // initState 里创建（不要用 late 懒初始化——unmount 时才首次创建
  // 会在 deactivated 树上查 TickerMode，触发 "deactivated ancestor" 断言）。
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.animate == old.animate) return;
    widget.animate ? _c.repeat(reverse: true) : _c.animateTo(0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        border: Border.all(width: 1, color: ZT.ink.withValues(alpha: 0.55)),
      ),
      child: !widget.animate
          ? null
          : FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            ),
    );
  }
}

/// 主按钮：蜜橘底 + 墨线 + 硬阴影；按下按钮沉进阴影里（位移 + 阴影消失）。
class BigButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color textColor;
  final IconData? icon;
  final bool expand;

  const BigButton({
    super.key,
    required this.label,
    this.onPressed,
    this.color = ZT.primary,
    this.textColor = Colors.white,
    this.icon,
    this.expand = false,
  });

  @override
  State<BigButton> createState() => _BigButtonState();
}

class _BigButtonState extends State<BigButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final sink = _pressed && enabled;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          transform: Matrix4.translationValues(
            sink ? 2.5 : 0,
            sink ? 2.5 : 0,
            0,
          ),
          decoration: ShapeDecoration(
            color: enabled ? widget.color : ZT.line,
            shadows: enabled && !sink ? ZT.hard(dx: 2.5, dy: 2.5) : const [],
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.radius),
              side: ZT.inkSide(w: 1.8, color: enabled ? ZT.ink : ZT.inkFaint),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 17, color: widget.textColor),
                  const SizedBox(width: 7),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    color: enabled ? widget.textColor : ZT.inkFaint,
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
