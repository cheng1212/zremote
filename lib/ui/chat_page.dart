import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../protocol/conversation.dart';
import '../protocol/relay_client.dart' show RelayState;
import '../state/activity_view.dart';
import '../state/automation_view.dart';
import 'automations_page.dart';
import '../state/app_controller.dart';
import '../state/history_logic.dart';
import '../state/model_defaults.dart';
import '../state/session_open_logic.dart';
import '../theme.dart';
import 'composer_logic.dart';
import 'image_cache.dart';
import 'rows.dart';
import 'suggestions.dart';

/// 单会话聊天页。sessionId == null 时为草稿模式（首条消息 createSession）。
class ChatPage extends StatefulWidget {
  final ZApp app;
  final String? sessionId;
  final String title;

  const ChatPage({
    super.key,
    required this.app,
    required this.sessionId,
    required this.title,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// 流式面板：流式中的助手行渲染在列表【外】（借鉴 zcode-dev）。
/// 长高吃自己的固定空间、列表内容零变化——reverse 列表的逐帧锚定
/// 补偿因此退出流式主战场。落定后行回列表，面板消失（两次单次
/// 离散变化，无需逐帧补偿）。
///
/// 高度封顶（Telegram「流式槽位」思想的 Flutter 化）：面板曾无约束，
/// 内容每长一寸就把 Expanded 列表压矮一寸——用户停在历史区时视口被
/// 持续顶向最新端（「正在回复的框越来越长」「人被往回拉」的共同根源）。
/// 封顶后列表空间恒定，流式推再久也压不到视口。
///
/// 内容超出上限后内部滚动：未回看时每个 token tick 跟到最新输出
/// （LLM UI 惯例，ChatGPT/Open WebUI 同款）；用户在面板内上滑回看
/// 则停住（离底 >60px 视为回看，贴底恢复跟随——主列表 FollowLock 的
/// 面板内简化版）。
class _StreamingPanel extends StatefulWidget {
  final Map<String, dynamic> row;
  final ConversationV4? transport;
  final String sessionId;

  const _StreamingPanel({
    required this.row,
    this.transport,
    this.sessionId = '',
  });

  @override
  State<_StreamingPanel> createState() => _StreamingPanelState();
}

class _StreamingPanelState extends State<_StreamingPanel> {
  final _scrollCtrl = ScrollController();

  /// false = 用户在面板内回看已输出内容，停止跟尾。
  bool _followTail = true;

  /// 同帧去重：一个 token tick 最多排一次跟尾（调研原则 6：跟尾要节流）。
  bool _tailScheduled = false;

  @override
  void didUpdateWidget(covariant _StreamingPanel old) {
    super.didUpdateWidget(old);
    // 每个 token tick 都会走到这里。post-frame 里量（布局后才有新
    // maxScrollExtent），未回看就跳到内容尾部（最新输出）。
    if (_tailScheduled) return;
    _tailScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tailScheduled = false;
      if (!mounted || !_followTail || !_scrollCtrl.hasClients) return;
      // 滚动进行中（手指拖拽/惯性）绝不 jump——调研原则 5/6：
      // 跟随滚动与用户手势对打是「滑不动」的直接来源。
      // jumpTo 本身走 IdleScrollActivity，不会误置 isScrolling。
      if (_scrollCtrl.position.isScrollingNotifier.value) return;
      final pos = _scrollCtrl.position;
      if (pos.maxScrollExtent - pos.pixels > 1) {
        _scrollCtrl.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && _scrollCtrl.hasClients) {
      final pos = _scrollCtrl.position;
      // 离底 >48px 视为回看（调研原则 4：业界阈值 5~56px），贴底恢复跟随。
      final away = pos.maxScrollExtent - pos.pixels > 48;
      if (away != _followTail) setState(() => _followTail = away);
    }
    return false;
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      constraints: BoxConstraints(
        // 用户裁定（2026-09-14）：最高只占 1/10 屏——基本当一行「正在
        // 回复」的进度条用，长输出全靠点开看；绝不能挤压历史阅读。
        maxHeight: MediaQuery.sizeOf(context).height * 0.10,
      ),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: SingleChildScrollView(
          controller: _scrollCtrl,
          child: buildRowCard(
            widget.row,
            transport: widget.transport,
            sessionId: widget.sessionId,
          ),
        ),
      ),
    );
  }
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focusNode = FocusNode();
  bool _sending = false;
  final _echoes =
      <Map<String, Object?>>[]; // {text,status,stage,error,files,attachments}

  /// 发送超 20s 仍在途 → 气泡里追加「网络较慢」提示。
  Timer? _slowTimer;

  /// 回显增删时自增：回显派生缓存的失效钥匙之一。
  int _echoesVersion = 0;
  final _picked = <PlatformFile>[]; // 待发送附件
  final _picker = ImagePicker(); // 系统相册 / 拍照（对齐参考端的图片流程）

  /// 附件**静默预上传**结果：选中就传，发送时直接引用 ref。key 见 [_attachKey]。
  /// ref 是会话域的，所以连同 sid 一起存，换会话后不复用（见 attachUploadPlan）。
  final _attachRefs = <String, ({String sid, Map<String, dynamic> desc})>{};

  /// 在飞的预上传：key = 'sid|附件key'，同会话同附件只会有一条。
  final _attachInflight = <String, Future<Map<String, dynamic>?>>{};

  /// 草稿模式下暂存的模型/思考/模式选择。
  String? _draftModelValue; // provider/model
  String? _draftThought;
  String? _draftMode;

  /// 是否在底部（或接近底部，逆序列表中 pixels ≈ 0 表示在最新端）。
  /// 仅在此时收到新消息才自动滚到底，避免用户看历史时被强制跳转。
  ///
  /// **带滞回**：判定逻辑在 `AnchorThresholds.resolve`（纯函数，可单测）。
  /// 单阈值在流式期间会反复翻转——内容持续变高，用户在临界带附近时
  /// `_atBottom` 横跳，每跳一次就 setState 重建整页，既闪又连锁影响锚定分支。
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _focusNode.addListener(_onFocusChange);
    // 恢复上次没发完的草稿（离开页面时暂存，进来就取走）。
    _input.text = widget.app.takeDraft(widget.sessionId ?? 'draft');
    if (widget.sessionId != null && widget.app.chat == null) {
      // 订阅失败自动重试一次
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.app.openSession(widget.sessionId!).catchError((Object e) {
          widget.app.log('[chat] 订阅失败: $e');
        });
      });
    }
  }

  /// 活订阅的状态：**行为**（运行中/队列/压缩/发送键）一律以它为准，
  /// 没有就是不运行——宁可先给发送键，也不要拿旧状态把按钮变成「停止」。
  ConversationState? get _state => widget.app.chat?.state;

  /// 渲染用的状态：活订阅优先，其次**本机历史快照**（用户裁定 2026-09-13：
  /// 切进来立刻要有内容，不要等服务端；允许与别的端不一致，要准就刷新）。
  /// 只喂给列表/行查找这类"画出来"的地方，不参与上面的行为判定。
  ConversationState? get _viewState =>
      _state ?? widget.app.chatSnapshot(widget.sessionId ?? '');

  /// 正在拿本机历史顶着（活订阅还没落地）：列表顶上给一行诚实提示。
  bool get _onLocalSnapshot => _state == null && _viewState != null;

  /// 当前会话 id：订阅成功后以 app 为准，草稿期落到构造参数。
  String? get _sid => widget.app.chat?.sessionId ?? widget.sessionId;

  /// reverse 列表：滚得越深内容越旧；接近最旧端 600px 内翻页。
  /// 离最新端超过一屏时浮出「回到最新」。
  void _onScroll() {
    final pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < 400) {
      widget.app.chat?.loadOlder();
    }
    // 参照主流实现把阈值压到 200px：锚定出口(40)+滞回(100)之外就给
    // 「回到底部」按钮，别让用户在 100~400px 的中间地带两头空。
    final away =
        pos.pixels > 200 &&
        pos.maxScrollExtent - pos.pixels > 100;
    if (away != _showJump) setState(() => _showJump = away);

    // 更新底部状态：reverse 列表中，pixels ≈ 0 表示在最新端（底部）。
    // 用双阈值滞回代替单阈值——流式期间 maxScrollExtent 持续变大，
    // 单阈值会让判定在临界带反复翻转（每次 setState 整页重建 = 闪）。
    final next = AnchorThresholds.resolve(
      pixels: pos.pixels,
      maxScrollExtent: pos.maxScrollExtent,
      wasAtBottom: _atBottom,
    );
    // 翻历史锁存：用户主动滚离底部 → 关掉自动回底；滚回最新端附近 →
    // 解锁恢复跟随。这是"看历史时不被拉回去"的关键——只靠位置判定
    // 挡不住流式追加（临界带内 pixels 每帧都在变）。
    var locked = _followLocked;
    if (FollowLock.shouldLock(
      pixels: pos.pixels,
      maxScrollExtent: pos.maxScrollExtent,
      lockFollow: locked,
    )) {
      locked = true;
    } else if (locked &&
        FollowLock.shouldRelease(
          pixels: pos.pixels,
          maxScrollExtent: pos.maxScrollExtent,
        )) {
      locked = false;
    }
    if (next != _atBottom || locked != _followLocked) {
      setState(() {
        _atBottom = next;
        _followLocked = locked;
      });
    }
    // 锚行基线随滚动实时刷新（注释见 _trackAnchorBaseline）。
    _trackAnchorBaseline();
  }

  bool _showJump = false;

  /// 用户主动滚离底部后置位：本次会话内**不再自动回底**，直到他主动
  /// 滚回最新端附近或点「回到最新」。
  ///
  /// 为什么非要状态锁：位置判定在流式期间必然误判——内容每 tick 长高，
  /// 用户看的那个位置对应 pixels 每帧都在变，只要他停得离底部近一点就
  /// 会被新行拽走。意图只能靠"用户是否主动滚离过"来记，不能靠实时位置猜。
  bool _followLocked = false;

  /// 键盘弹起/收起时的处理：弹起且在底部时滚到底，防止输入框被遮挡。
  void _onFocusChange() {
    if (_focusNode.hasFocus && _atBottom && !_followLocked) {
      // 键盘弹起且在底部 → 稍微延迟滚到底，等键盘动画结束
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && _focusNode.hasFocus && _scroll.hasClients) {
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  /// 记录上一帧的消息总数，用于检测新消息到达。
  int _prevTotalCount = 0;

  /// 翻历史锁存期间错过的新消息数：回底按钮徽标数据源。
  /// 解锁跟随/回到底时清零。
  int _unreadWhileLocked = 0;

  /// 用户正在拖动列表（手指按住）或惯性滚动中：期间不执行自动回底，
  /// 流式新行别再拽手——松手惯性结束且仍停在底部才恢复自动滚动。
  bool _scrollingByUser = false;

  /// 位置锚定基线：用户滚离底部后，最新端内容（新追加的行、图片解码
  /// 完成撑高的行）每变一寸，视口就跟着视觉平移——这是 reverse 列表的
  /// 视口漂移，与自动回底无关。对策：以**视口顶可见历史行**为锚
  /// （AnchorSample），内容变化前后锚行的视口 y 差就是该补的位移，
  /// 把锚行钉在原地。业界同构：Telegram scrollToMessageObject、
  /// tdesktop ScrollTopState、浏览器 scroll anchoring。
  /// 拖动期间不抢手势，基线跟随滚动实时刷新，欠账只对静止期变化生效。
  String? _anchorSid; // 基线所属会话；换会话即重建基线
  AnchorSample? _anchorSample;

  /// 锚定检查三重护栏（纯函数化便于单测）：
  /// - 翻历史锁存（FollowLock）决定「要不要补」；
  /// - 锚行身份（ViewportAnchor）决定「补多少/要不要重定基线」；
  /// - AnchorMath 决定「这一步走多远」。
  /// 旧方案的「总高增量 + 最旧行 rowId + olderMergeEpoch」三套基线已
  /// 统一收敛到锚行身份一处：翻页/快照重同步会让视口顶行换人，锚定
  /// 采样天然识别为「身份变了 → 重定基线不补」（BUG-32/37 同效）。

  /// 同帧内待补偿的位移。多个触发源（状态更新、post-frame、滚动回调）
  /// 在同一帧里各算一次增量的话会跳两次——这就是"闪"的直接来源。
  /// 全部先累加到这里，帧末只跳一次。
  double _coalescedAnchorDelta = 0;
  bool _anchorFlushScheduled = false;

  /// 锚定动画进行中。同一时刻只允许一个——并发 animateTo 会互相抢
  /// 目标值，观感是抖动（比不补偿还糟）。
  bool _anchorAnimating = false;
  Timer? _anchorAnimTimer;

  /// 补偿的阈值 / 上限 / 动画时长全在 `AnchorMath`（纯计算，可单测）。
  /// 这里只剩调度：什么时候量、什么时候合并、什么时候落。

  /// 监听会话状态变化，在底部时自动滚到底。
  void _maybeAutoScroll() {
    final state = _state;
    // postFrame 是从 build 里无条件排的：页面可能在收尾、或列表暂时不在
    // 树上——controller 未附加时摸 position 直接抛，mounted/hasClients 都要挡。
    if (state == null || !mounted || !_scroll.hasClients) return;
    _anchorAgainstGrowth();
    final total = state.rows.length + _visibleEchoes(state.rows).length;
    if (_scrollingByUser) {
      _prevTotalCount = total;
      return; // 手势中绝不 animateTo（会顶手指）
    }
    // 弹道保护：惯性滚动进行中同样绝不动手——程序化动画与惯性抢驱动
    // 就是"转来转去"的又一来源（对齐 _applyAnchorGrowth 的保护）。
    final pos = _scroll.position;
    if (pos.hasPixels && pos.userScrollDirection != ScrollDirection.idle) {
      _prevTotalCount = total;
      return;
    }
    if (_followLocked && total > _prevTotalCount && !_scrollingByUser) {
      // 锁存期间错过的新行计数（回底徽标）。
      _unreadWhileLocked += total - _prevTotalCount;
    }
    if (total > _prevTotalCount && _atBottom && !_followLocked) {
      // 有新消息、用户在底部、且没有翻历史锁 → 回到底部（index 0）。
      // 位移规划交给 AutoFollowMath：一屏内 linear 慢回（不拽），
      // 超过一屏直接不动手（交给锚定通道，别抢用户视线）。
      if (!pos.hasPixels) {
        _prevTotalCount = total;
        return;
      }
      final step = AutoFollowMath.plan(
        distance: pos.pixels,
        viewportDimension: pos.viewportDimension,
      );
      if (step.act) {
        _scroll.animateTo(
          step.target,
          duration: step.duration,
          curve: step.curve == AutoFollowCurve.linear
              ? Curves.linear
              : Curves.easeOut,
        );
      }
    }
    _prevTotalCount = total;
  }

  /// 锚定检查：只在 post-frame 回调里调用（jumpTo 不能在布局期跑，
  /// 见 _maybeAutoScroll 的调用点）。
  ///
  /// 2026-09-14 重构：补偿依据从「内容总高增量」换成「视口顶锚行的
  /// 位置差」（ViewportAnchor.compensate）。旧算法把 maxScrollExtent 的
  /// 每一寸增长都当成新端增长全量补进 pixels——历史端行变高（旧消息
  /// 图片解码完成、markdown/代码块二次排版）时视口明明纹丝没动，却把
  /// 用户往历史端推整个增量；配合欠账回放，观感就是「停稳之后页面自己
  /// 飘走，一下飘老远」。锚行方案下这个场景增量为 0，一分不补。
  void _anchorAgainstGrowth() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) return;
    final next = _sampleTopRow();
    if (next == null) return; // 顶部不是历史行/找不到列表：基线不动
    final prevSample = _anchorSample;
    _anchorSample = next;
    if (_anchorSid != _sid) {
      _anchorSid = _sid; // 换会话：重定基线
      return;
    }
    final delta = ViewportAnchor.compensate(prev: prevSample, next: next);
    if (delta == null || delta.abs() < AnchorMath.minStepPx) return;
    if (_atBottom && !_followLocked) {
      return; // 在底部跟随新内容是既有行为，无需锚定
    }
    if (_scrollingByUser) {
      // 拖动期间不补也不记欠账——欠账回放会在松手后拉着视口
      // 飞一段（用户实测"轻轻一滑就飞到计划处"）。规范 §4.3 同款取舍：
      // 每帧几像素漂移不可感知，松手后补偿只对新增长生效。
      return;
    }
    _queueAnchorGrowth(delta);
  }

  /// 采样视口顶（最旧端）第一条可见历史行。头部槽（思考指示/回显/错误卡）
  /// 与尾部槽不锚：头部槽身份不稳（回显发送成功即清场），锚它会引入抖动。
  /// 找不到可锚行时返回 null，基线保持原样。
  AnchorSample? _sampleTopRow() {
    if (!mounted || !_scroll.hasClients) return null;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) return null;
    final ctx = pos.context.notificationContext;
    final viewport = RenderAbstractViewport.of(ctx?.findRenderObject());
    if (viewport is! RenderBox) return null;
    RenderSliverMultiBoxAdaptor? sliver;
    viewport.visitChildren((child) {
      if (sliver == null && child is RenderSliverMultiBoxAdaptor) {
        sliver = child;
      }
    });
    final box0 = sliver;
    if (box0 == null) return null;
    RenderBox? topChild;
    var topY = double.infinity;
    box0.visitChildren((child) {
      final box = child as RenderBox;
      final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (y < topY) {
        topY = y;
        topChild = box;
      }
    });
    final tc = topChild;
    if (tc == null || !tc.hasSize) return null;
    final idx = (tc.parentData as SliverMultiBoxAdaptorParentData).index;
    if (idx == null) return null;
    final snap = _layoutIndexSnapshot(_viewState);
    if (snap == null) return null;
    final i = idx - snap.headCount;
    if (i < 0 || i >= snap.rows.length) return null;
    final rowId = (snap.rows[i]['rowId'] as num?)?.toInt();
    if (rowId == null) return null;
    return AnchorSample(rowId, topY);
  }

  /// 消息行的时间标签（用户裁定 2026-09-14：消息上加时间戳）。
  /// 只给用户消息/助手回复显示；行没有本端接收时间（localTs，跨重启的
  /// 历史快照行）就不显示——宁缺毋错。当天只显示时刻，跨天带日期。
  String? _rowTimeLabel(Map<String, dynamic> row) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return null;
    final ts = row['localTs'];
    if (ts is! num) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    final now = DateTime.now();
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? hm : '${t.month}/${t.day} $hm';
  }

  /// 列表索引里该会话的预览文本（无记录/无预览给空串）。
  /// 用于「伪空」判定：索引有货但行窗口刷不出 → 空态要说真相别误导。
  String _listedPreviewFor(String sid) {
    if (sid.isEmpty) return '';
    for (final t in widget.app.listedTasks) {
      if ('${t['taskId'] ?? ''}' == sid || '${t['sessionId'] ?? ''}' == sid) {
        return '${t['lastAssistantPreview'] ?? ''}';
      }
    }
    return '';
  }

  /// 与 `_buildList` 的布局 index 语义**完全同源**的快照：
  /// 流式行摘除后的历史行集合 + 头部槽数量。
  /// itemBuilder 的 `index - headCount → rows[i]` 映射必须与这里一致，
  /// 否则锚行身份会错位到别的消息。
  ({List<Map<String, dynamic>> rows, int headCount})? _layoutIndexSnapshot(
    ConversationState? state,
  ) {
    if (state == null) return null;
    final rows0 = state.rows;
    final streaming = _trailingStreamingRow(state);
    final extracted = streaming != null &&
        rows0.isNotEmpty &&
        identical(rows0.last, streaming);
    final rows = extracted ? rows0.sublist(0, rows0.length - 1) : rows0;
    final head = (_thinkingLabel(state, rows0) != null ? 1 : 0) +
        _visibleEchoes(rows0).length +
        (state.hasErrorPhase ? 1 : 0);
    return (rows: rows, headCount: head);
  }

  /// 滚动期间基线实时跟随：手指/惯性/程序化动画引起的锚行 y 变化全部
  /// 在这里吞进基线，绝不让它们进补偿——否则停稳后的第一帧会把整个
  /// 滚动距离当成「内容增量」回放一遍，视口被拽回滚动前。
  void _trackAnchorBaseline() {
    final next = _sampleTopRow();
    if (next != null) _anchorSample = next;
  }

  /// 把补偿量累加进本帧的合并桶，帧末统一补一次。
  /// 为什么不在算到的时候就跳：同一帧里 `_onScroll`（内容变化会触发滚动
  /// 通知）、post-frame 的 `_anchorAgainstGrowth`、状态更新三处都可能算到
  /// 增量，各跳一次就是肉眼可见的抖动。合并成一次位移才稳。
  void _queueAnchorGrowth(double growth) {
    if (growth <= 0) return;
    _coalescedAnchorDelta += growth;
    if (_anchorFlushScheduled) return;
    _anchorFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorFlushScheduled = false;
      final delta = _coalescedAnchorDelta;
      _coalescedAnchorDelta = 0;
      // 锁存期间即使 _atBottom 为真也必须补偿，否则最新端长高的内容
      // 会把视口拖走——用户就是要停在原地看历史。
      if (!mounted || _scrollingByUser) return;
      if (_atBottom && !_followLocked) return;
      _applyAnchorGrowth(delta);
    });
  }

  /// 把增量补进滚动位置：带阈值过滤 + 微动画 + 单步上限。
  ///
  /// 这里是闪烁问题的**修复核心**。原实现用 `jumpTo` 直接改 pixels，
  /// 而流式期间"量到的高度"和"下一帧实际的高度"经常不一致——于是每帧
  /// 跳一次、每跳一次就露一次位置突变，合成"一闪一闪"。
  /// 改成短时长动画后，同样的修正量被摊成连续移动，视觉上只是内容被
  /// 稳稳钉住，看不出修正动作。
  void _applyAnchorGrowth(double growth) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) return;
    // 弹道保护：用户松手后的惯性滚动中不做补偿动画，否则会打断惯性
    //（表现就是"滑到某处就卡住"）。等惯性停稳后只对新增长补偿。
    if (pos.userScrollDirection != ScrollDirection.idle) return;
    final step = AnchorMath.plan(growth);
    if (step.isNoop) return;
    // 已有锚定动画在跑：把这一步整个并进桶里，别开第二个 animateTo。
    // 两个 animateTo 同时驱动同一个 ScrollPosition 会互相抢目标值——
    // 观感就是"抖动"，正是我们要消灭的东西。等当前动画结束再走。
    if (_anchorAnimating) {
      _coalescedAnchorDelta += growth;
      _scheduleAnchorFlush();
      return;
    }
    // 超出单步上限的欠账留回桶里，下一帧继续走（欠账慢慢还，不瞬移）。
    if (step.leftover.abs() > 0) {
      _coalescedAnchorDelta += step.leftover;
      _scheduleAnchorFlush();
    }
    final target = (pos.pixels + step.delta).clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < AnchorMath.minStepPx) return;
    _anchorAnimating = true;
    // 本版 Flutter 的 ScrollPosition.animateTo 返回普通 Future<void>
    // （不是 TickerFuture），拿不到可靠的"被打断"回调。所以用定时器
    // 在动画名义时长后放开标记：既挡住整段动画期间的重复启动，
    // 又不会因为动画被 cancel 而永久卡死锚定（最坏只是少补偿一小段）。
    _anchorAnimTimer?.cancel();
    _anchorAnimTimer = Timer(step.duration, () {
      _anchorAnimTimer = null;
      _anchorAnimating = false;
      // 动画期间攒下的欠账，结束后立刻补上，别等到下次内容增长。
      if (_coalescedAnchorDelta.abs() >= AnchorMath.minStepPx) {
        _scheduleAnchorFlush();
      }
    });
    pos.animateTo(target, duration: step.duration, curve: Curves.linear);
  }

  /// 帧末统一落一次合并桶里的欠账。
  void _scheduleAnchorFlush() {
    if (_anchorFlushScheduled) return;
    _anchorFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorFlushScheduled = false;
      final delta = _coalescedAnchorDelta;
      _coalescedAnchorDelta = 0;
      // 锁存期间即使 _atBottom 为真也必须补偿，否则最新端长高的内容
      // 会把视口拖走——用户就是要停在原地看历史。
      if (!mounted || _scrollingByUser) return;
      if (_atBottom && !_followLocked) return;
      _applyAnchorGrowth(delta);
    });
  }

  /// 手势结束（惯性停稳）：解除拖动标记。拖动期间不做补偿也不记欠账
  ///（欠账回放会在松手后拉着视口飞一段——用户实测"轻轻一滑就飞出去"，
  /// 已移除），松手后补偿只对新增长生效。
  void _onScrollGestureEnd() {
    _scrollingByUser = false;
  }

  // ----------------------------------------------------------------- send

  Future<String?> _askQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '有排队中的消息',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          '发送方式：排队追加，或清空队列立即执行。',
          style: TextStyle(fontSize: 13, color: ZT.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            // 与「立即发送」的 BigButton 对齐高度：对话框里两个选项
            // 一高一矮、一个纯文字一个实心块，很容易点错。
            style: TextButton.styleFrom(
              minimumSize: const Size(0, ZT.tapMin),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ZT.radius),
                side: ZT.inkSide(w: 1.6, color: ZT.inkSoft),
              ),
            ),
            child: const Text(
              '排队发送',
              style: TextStyle(
                color: ZT.inkSoft,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          BigButton(
            label: '立即发送',
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final app = widget.app;
    if ((text.isEmpty && _picked.isEmpty) || _sending) return;
    // 乐观切换：点进来时切桥/订阅还在后台跑（切桥中途 `conv` 甚至是 null），
    // 直接发会拿旧桥把消息发到别的项目去、或撞「桥未就绪」。先等它就绪。
    final want = _sid;
    if (want != null && widget.sessionId != null) {
      try {
        await app.ensureSessionReady(want);
      } on Object catch (e) {
        if (!mounted) return;
        setState(() {
          _echoes.add({
            'text': text,
            'status': 'failed',
            'error': '打开会话失败：$e',
          });
          _echoesVersion++;
        });
        return;
      }
      if (!mounted) return;
    }
    if (app.conv == null) {
      setState(() {
        _echoes.add({'text': text, 'status': 'failed', 'error': '桥未就绪，请返回重进'});
      });
      return;
    }
    var sessionId = _sid;
    final files = List<PlatformFile>.from(_picked);
    String? disposition;
    if (sessionId != null && (_state?.queueItems.isNotEmpty ?? false)) {
      disposition = await _askQueueDisposition();
      if (disposition == null) return;
      // 重复不入队：排队追加时，队列里已有同文本的消息就不再排队一条
      //（防止外部提醒类来源在会话忙时刷出成串重复排队项）。
      // 「立即发送」（clearQueueAndSend）是清队重发的明确意图，不拦。
      if (disposition == 'keepQueueAndSend' &&
          text.isNotEmpty &&
          files.isEmpty) {
        if (queueHasDuplicate(_state!.queueItems, text)) {
          _flash('排队中已有相同消息，未重复入队');
          return;
        }
      }
    }
    // 「立即发送」要清掉的持队项 id：客户端按 id 核对后才真的清队，
    // 只传 disposition 不传 id 会被静默降级为排队（假清队 bug 根因）。
    final heldIds = disposition == 'clearQueueAndSend'
        ? [
            for (final q in _state!.queueItems)
              if ('${q['queueItemId'] ?? ''}'.isNotEmpty)
                '${q['queueItemId']}',
          ]
        : const <String>[];
    // 排队快照：relay 未配对或桥降级时，消息其实先落本地队列等恢复。
    // 只在发送瞬间取一次（_outbound 会自动补发，不需要持续追踪）。
    final queued =
        app.relayState != RelayState.paired ||
        (app.bridge?.degraded.value != null);
    final echo = <String, Object?>{
      'text': text,
      'status': 'sending',
      'stage': '',
      'error': '',
      'files': files,
      if (queued) 'queued': true,
      // 排队追加：不回显到聊天流（队列栏已展示），失败时仍可见。
      if (disposition == 'keepQueueAndSend') 'inQueue': true,
    };
    setState(() {
      _echoes.add(echo);
      _echoesVersion++;
      _sending = true;
      _input.clear();
      // 发送**不再**改变视口位置（2026-09-13 用户"发送后乱划"定位）：
      // 人在底部 → 自然跟随新内容；人在翻历史 → 停在原地，新回复走
      // 未读徽标（回底按钮 99+）。强行解锁+拽底会把读历史的用户甩走。
    });
    // 20s 仍未送达 → 气泡里亮出「网络较慢」，给个心理预期。
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || echo['status'] != 'sending') return;
      setState(() {
        echo['slow'] = true;
        _echoesVersion++;
      });
      // 上浮：切到列表页也能看到这条还在飘。
      final sid = sessionId ?? _sid;
      if (sid != null) widget.app.reportSendIssue(sid, '消息发送较慢');
    });
    try {
      // 草稿：一律先建空会话（不随 createSession 带 firstInput），等模型闸门
      // 通过后再 sendText。这样模型被服务端回退/闸门失败时消息确实还没发出，
      // echo 标记 failed 是诚实的，重试不会重复发送（首条消息已随建会话
      // 提交过的话，闸门失败会让用户重发一条，造成重复消息）。
      Map<String, dynamic>? requestedConfig;
      if (sessionId == null) {
        _setStage(echo, '正在创建会话…');
        requestedConfig = _draftConfig();
        final newId = await app.createSession(null, requestedConfig);
        sessionId = newId;
        await app.openSession(newId);
        // 首条消息放行闸门：等订阅快照回读、确认会话模型真的落到请求值。
        // 桌面端 registryFallback（如本地代理下线）会把新会话悄悄回退到
        // 默认模型（欠费跑不通）——不验证就发，等于把消息送进死胡同。
        _setStage(echo, '等待模型就绪…');
        await _waitForSessionModel(requestedConfig, echo);
        // 闸门通过后登记意图模型（chosen）：此后「不切就是英伟达」由
        // _keepSessionModel 长期守恒；用户在手机上改选走 _applyModel 记录。
        if (requestedConfig != null &&
            '${requestedConfig['model'] ?? ''}'.isNotEmpty) {
          unawaited(
            app.recordSessionModel(sessionId, {
              ...requestedConfig,
              'chosen': true,
            }),
          );
        }
      } else {
        // 已有会话：发送前以本端模型为准（后写者赢），失败不阻塞发送。
        await _assertLocalModel(sessionId);
      }
      if (files.isNotEmpty) {
        // 选中时已静默预上传，这里通常直接命中 ref；没命中的当场补传。
        final uploads = await _prefetchUploads(files, echo);
        final attachments = await _uploadFiles(sessionId, uploads);
        echo['attachments'] = attachments;
        requireAccepted(
          await app.sendText(
            sessionId,
            text,
            heldQueueDisposition: disposition,
            expectedHeldQueueItemIds: heldIds,
            attachments: attachments,
          ),
        );
      } else if (text.isNotEmpty) {
        requireAccepted(
          await app.sendText(
            sessionId,
            text,
            heldQueueDisposition: disposition,
            expectedHeldQueueItemIds: heldIds,
          ),
        );
      }
      echo['status'] = 'sent';
      // 附件已随消息发出，ref 用完即弃（再选同一张图重新传一次）。
      for (final f in files) {
        _attachRefs.remove(_attachKey(f));
      }
      _picked.clear();
      // 送达即清异常标记——列表卡上的"没发出去"要跟着消失。
      widget.app.reportSendIssue(sessionId, '');
    } on Object catch (e) {
      echo['status'] = 'failed';
      final rawMsg = '$e';
      echo['error'] = rawMsg.contains('取消') ? '上传已取消' : rawMsg;
      widget.app.log('[chat] 发送失败: $e');
      // 上浮到列表卡：用户切回列表页也能看到这条没发出去。
      final sid = sessionId ?? _sid;
      if (sid != null) {
        widget.app.reportSendIssue(sid, '消息未送达');
      }
    } finally {
      _slowTimer?.cancel();
      _slowTimer = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 首条消息放行闸门：轮询订阅快照，直到会话模型落到 createSession
  /// 请求值。快照就绪但模型不符（被服务端回退）→ 立即失败，不把消息
  /// 送给欠费/不可用的默认模型；快照迟迟不来 → 超时失败。
  Future<void> _waitForSessionModel(
    Map<String, dynamic>? requested,
    Map<String, Object?> echo,
  ) async {
    final wantProvider = '${requested?['provider'] ?? ''}';
    final wantModel = '${requested?['model'] ?? ''}';
    if (wantModel.isEmpty) return;
    final wantLabel = wantProvider.isEmpty
        ? wantModel
        : '$wantProvider/$wantModel';
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final st = widget.app.chat?.state;
      if (st != null && st.ready) {
        final ok = sessionModelMatches(
          curProvider: st.currentProvider,
          curModel: st.currentModel,
          wantProvider: wantProvider,
          wantModel: wantModel,
        );
        if (ok) {
          widget.app.log('[chat] 模型已就绪 $wantLabel');
          return;
        }
        throw StateError(
          '会话模型被服务端置为 ${st.currentProvider}/${st.currentModel}，'
          '未落到请求的 $wantLabel（大概率本地模型代理未启动或不可用）。'
          '消息未发送，请检查代理后重试。',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('等待模型就绪超时（$wantLabel）');
  }

  /// 更新回显气泡里的阶段文案（发送中状态行的内容），并刷新列表。
  void _setStage(Map<String, Object?> echo, String stage) {
    if (!mounted) return;
    setState(() {
      echo['stage'] = stage;
      _echoesVersion++;
    });
  }

  /// 发送前把本端记录的模型重新落到会话配置：PC 端聚焦会话会把它的
  /// 模型覆盖写入服务端（后写者赢），哪边发送就以哪边的模型为主。
  /// 没有本地记录（从未选过模型）则不动。
  Future<void> _assertLocalModel(String sessionId) async {
    final rec = widget.app.sessionModels[sessionId];
    final model = '${rec?['model'] ?? ''}';
    if (model.isEmpty) return;
    final provider = '${rec?['provider'] ?? ''}';
    final thought = '${rec?['thought'] ?? ''}';
    final fallbackThought = _state?.currentThought ?? '';
    try {
      await widget.app.switchModel(
        sessionId,
        provider: provider,
        model: model,
        thought: thought.isNotEmpty
            ? thought
            : (fallbackThought.isNotEmpty ? fallbackThought : 'enabled'),
      );
      widget.app.log('[config] 发送前对齐模型 $provider/$model');
    } on Object catch (e) {
      widget.app.log('[config] 发送前模型对齐失败（继续发送）: $e');
    }
  }

  /// 读取选中文件并生成本地预览描述：发送中的回显气泡立刻带上字节，
  /// 上传还没拿到 ref 时也能看到缩略图（不再有「上传中」阶段文案）。
  Future<List<(PlatformFile, Uint8List)>> _prefetchUploads(
    List<PlatformFile> files,
    Map<String, Object?> echo,
  ) async {
    final out = <(PlatformFile, Uint8List)>[];
    for (final f in files) {
      final bytes = await _bytesOf(f);
      // 本地预览也要 mime：无后缀相册图靠魔数，否则网格分区会把它当文件。
      echo['attachments'] = <Map<String, dynamic>>[
        ...?echo['attachments'] as List<Map<String, dynamic>>?,
        {'fileName': f.name, 'mime': _mimeOf(f, bytes), 'bytes': bytes},
      ];
      out.add((f, bytes));
    }
    return out;
  }

  /// 附件身份 key：有路径用路径，否则用「名字:大小」（相机来源可能无路径）。
  static String _attachKey(PlatformFile f) => f.path ?? '${f.name}:${f.size}';

  Future<Uint8List> _bytesOf(PlatformFile f) async {
    final p = f.path;
    if (p != null) return File(p).readAsBytes();
    final b = f.bytes;
    if (b == null) throw StateError('${f.name}: 文件不可读');
    return b;
  }

  /// 扩展名定不出 mime（相册图常见）→ 魔数嗅探兜底，别让图片按
  /// octet-stream 上传（服务端和回显都会认不出是图）。
  String _mimeOf(PlatformFile f, Uint8List bytes) {
    final base = _mimeFor(f.extension ?? '');
    return base == 'application/octet-stream'
        ? (sniffImageMime(bytes) ?? base)
        : base;
  }

  /// 真传一个附件并记下 ref（含刚上传的图进缓存：回显零等待，不用再
  /// attachmentRead 拉一遍）。抛异常由调用方决定是静默还是回显。
  Future<Map<String, dynamic>> _putAttachment(
    String sid,
    PlatformFile f,
    Uint8List bytes,
  ) async {
    final desc = await widget.app.attachmentPut(
      sid,
      fileName: f.name,
      mime: _mimeOf(f, bytes),
      bytes: bytes,
    );
    final ref = '${desc['ref'] ?? ''}';
    if (ref.isNotEmpty) globalImageCache.put(ref, bytes);
    _attachRefs[_attachKey(f)] = (sid: sid, desc: desc);
    return desc;
  }

  /// 选中即传的**静默预上传**：用户看到的就是缩略图直接出现，没有
  /// 「正在上传 xx%」这类阶段文案（对齐参考端）；发送时直接引用 ref，
  /// 省掉等待。失败只记日志——发送时会重试一次并走正常失败提示。
  void _kickPreUpload() {
    final sid = _sid;
    if (sid == null) return; // 草稿会话：等 _send 建好会话再传
    for (final f in _picked) {
      final key = _attachKey(f);
      final plan = attachUploadPlan(
        refMatchesSession: _attachRefs[key]?.sid == sid,
        inflightMatchesSession: _attachInflight.containsKey('$sid|$key'),
      );
      if (plan != AttachUploadPlan.fresh) continue;
      _attachInflight['$sid|$key'] = _preUploadQuiet(sid, f, key);
    }
  }

  Future<Map<String, dynamic>?> _preUploadQuiet(
    String sid,
    PlatformFile f,
    String key,
  ) async {
    try {
      return await _putAttachment(sid, f, await _bytesOf(f));
    } on Object catch (e) {
      widget.app.log('[chat] 预上传失败 ${f.name}: $e');
      return null;
    } finally {
      // Map<K,Future>.remove 返回被摘除的 future 本体——它已在上面的
      // await 链路里被消费过，这里只是从在飞表摘除，属 lint 误伤。
      // ignore: unawaited_futures
      _attachInflight.remove('$sid|$key');
    }
  }

  /// 附件从待发条移除：连同预上传结果一起忘掉（在飞的那条拦不住，落地即废）。
  void _forgetAttachment(PlatformFile f) {
    _attachRefs.remove(_attachKey(f));
    _picked.remove(f);
  }

  Future<List<Map<String, dynamic>>> _uploadFiles(
    String sessionId,
    List<(PlatformFile, Uint8List)> uploads,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final (f, bytes) in uploads) {
      final key = _attachKey(f);
      final hit = _attachRefs[key];
      final inflightKey = '$sessionId|$key';
      final plan = attachUploadPlan(
        refMatchesSession: hit != null && hit.sid == sessionId,
        inflightMatchesSession: _attachInflight.containsKey(inflightKey),
      );
      if (plan == AttachUploadPlan.reuse) {
        out.add(hit!.desc);
        continue;
      }
      // 预上传在飞就等它；它失败了（null）当场补一次，失败要如实回显。
      final pre = plan == AttachUploadPlan.inflight
          ? await _attachInflight[inflightKey]
          : null;
      out.add(pre ?? await _putAttachment(sessionId, f, bytes));
    }
    return out;
  }

  static String _mimeFor(String ext) {
    final e = ext.toLowerCase();
    return switch (e) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'txt' || 'md' || 'log' || 'yaml' || 'yml' => 'text/plain',
      'mp4' => 'video/mp4',
      'mp3' => 'audio/mpeg',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickFile() async {
    if (_sending) return;
    // withData 保证图片在 path 不可用时也有 bytes 可画缩略图/全屏预览。
    final res = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    final f = res?.files.single;
    if (f == null) return;
    // 上传走整文件 readAsBytes，超大的直接拦截，别等 OOM。
    if (f.size > 100 << 20) {
      _flash('文件超过 100 MB，暂不支持发送', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _picked.add(f));
    _kickPreUpload();
  }

  /// 拍照（系统相机）→ 待发条。与相册同一条落地路径。
  Future<void> _pickCamera() async {
    if (_sending) return;
    try {
      final shot = await _picker.pickImage(source: ImageSource.camera);
      if (shot == null) return;
      await _addPicked([shot]);
    } on Object catch (e) {
      if (mounted) _flash('拍照失败：$e', error: true);
    }
  }

  /// 相册选图（系统相册，多选）：与「上传文件」分开——图片走系统相册的
  /// 体验远好过文件管理器（对齐参考端的图片流程）。
  Future<void> _pickImage() async {
    if (_sending) return;
    try {
      await _addPicked(await _picker.pickMultiImage());
    } on Object catch (e) {
      if (mounted) _flash('选图失败：$e', error: true);
    }
  }

  /// XFile → 待发条（带字节：缩略图、预上传、失败重试都要用）。
  /// 同时**立即**静默预上传：选中就传，发送时直接引用 ref。
  Future<void> _addPicked(List<XFile> picked) async {
    if (picked.isEmpty) return;
    final room = 9 - _picked.length;
    if (room <= 0) {
      _flash('一次最多带 9 个图片/文件', error: true);
      return;
    }
    final accepted = <PlatformFile>[];
    for (final x in picked) {
      final size = await x.length();
      if (size > 100 << 20) continue; // 超大的拦在门外，别等 OOM
      if (accepted.length >= room) break;
      accepted.add(
        PlatformFile(
          name: x.name,
          path: x.path,
          size: size,
          bytes: await x.readAsBytes(),
        ),
      );
    }
    if (accepted.isEmpty) {
      _flash('图片超过 100 MB，暂不支持发送', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _picked.addAll(accepted));
    if (accepted.length < picked.length) {
      _flash('已加入 ${accepted.length} 张（超限/超量的已跳过）');
    }
    _kickPreUpload();
  }

  Map<String, dynamic>? _draftConfig() {
    final config = <String, dynamic>{};
    // 没手动选过模型的草稿：直接带上首选默认（英伟达）。新会话第一条
    // 消息别再撞服务端默认（千问 Max，欠费直接报错）。
    final mv = (_draftModelValue == null || _draftModelValue!.isEmpty)
        ? '$preferredDefaultModelProvider/$preferredDefaultModelId'
        : _draftModelValue!;
    final idx = mv.lastIndexOf('/');
    if (idx > 0) {
      config['provider'] = mv.substring(0, idx);
      config['model'] = mv.substring(idx + 1);
    }
    // thought 只在有把握时才带：首选默认配 high（合法变体）；其余草稿
    // 模型不动，避免 createSession 吃到不支持的变体名。
    if (_draftThought != null) {
      config['thought'] = _draftThought;
    } else if (config['model'] == preferredDefaultModelId) {
      config['thought'] = preferredDefaultModelThought;
    }
    if (_draftMode != null) config['mode'] = _draftMode;
    return config;
  }

  Future<void> _stop() async {
    final sessionId = _sid;
    if (sessionId == null) return;
    try {
      await widget.app.stop(sessionId);
      widget.app.log('[chat] 已请求停止');
    } on Object catch (e) {
      widget.app.log('[chat] 停止失败: $e');
      if (!mounted) return;
      _flash('停止失败：$e', error: true);
      // 停止失败常伴随状态漂移：强制重同步一次，解除按钮卡死。
      unawaited(_forceResync());
    }
  }

  /// 暂停/继续当前目标（比停止温和：保留现场，随时接上）。
  /// 乐观翻面 paused，服务端快照随后权威化。
  Future<void> _pauseResume() async {
    final sessionId = _sid;
    final st = _state;
    if (sessionId == null || st == null || _sending) return;
    final resume = st.goalPaused;
    try {
      requireAccepted(
        resume
            ? await widget.app.resumeGoal(sessionId)
            : await widget.app.pauseGoal(sessionId),
      );
      st.optimisticPatch({
        'goal': {...?st.goal, 'paused': !resume},
      });
      widget.app.log('[chat] ${resume ? '已继续' : '已暂停'}');
    } on Object catch (e) {
      widget.app.log('[chat] ${resume ? '继续' : '暂停'}失败: $e');
      if (mounted) _flash('${resume ? '继续' : '暂停'}失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------- queue ops

  /// 排队列表折叠状态：默认折叠——长队列（十几条排队项）常驻展开会把
  /// 输入框顶出半屏；折叠时只显示下一条要发的，其余收进标题行点开。
  bool _queueExpanded = false;

  Widget _queueBar(ConversationState state) {
    final app = widget.app;
    final sessionId = _sid;
    if (sessionId == null || state.queueItems.isEmpty) {
      return const SizedBox.shrink();
    }
    // 折叠时只露出队首（下一条要发的）；展开看全部。
    final visibleItems = _queueExpanded
        ? state.queueItems
        : state.queueItems.take(1).toList();
    final hidden = state.queueItems.length - visibleItems.length;
    return Container(
      decoration: BoxDecoration(
        color: ZT.lemon.withValues(alpha: 0.25),
        border: Border(top: BorderSide(width: 1.2, color: ZT.line)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 标题行整体可点：折叠/展开排队列表（箭头随状态旋转）。
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _queueExpanded = !_queueExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.low_priority_rounded,
                        size: 14,
                        color: ZT.inkSoft,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        state.queueItems.isEmpty
                            ? '运行中'
                            : '排队中 ${state.queueItems.length} 条',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: ZT.inkSoft,
                        ),
                      ),
                      AnimatedRotation(
                        turns: _queueExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: const Icon(
                          Icons.expand_more_rounded,
                          size: 16,
                          color: ZT.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // 追问模式入口：原来是 10.5px 纯文字，热区只有文字高，
              // 撑到 48dp 并加淡底描边——它是「追加消息怎么发」的开关，
              // 用户要按得到、也要看得出能按。
              Material(
                color: Colors.transparent,
                child: Ink(
                  decoration: ShapeDecoration(
                    color: ZT.surface,
                    shape: StadiumBorder(
                      side: ZT.inkSide(w: 1.2, color: ZT.inkSoft),
                    ),
                  ),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: _openFollowupSheet,
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: 34,
                        minWidth: ZT.tapMin,
                      ),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '追问·${followupLabel(state.currentFollowupMode)}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: ZT.ink,
                            ),
                          ),
                          const Icon(
                            Icons.expand_more,
                            size: 14,
                            color: ZT.inkSoft,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '自动消化',
                style: TextStyle(fontSize: 10.5, color: ZT.inkFaint),
              ),
              Switch(
                value: state.autoDrain,
                activeThumbColor: ZT.primaryDeep,
                onChanged: (v) =>
                    app.setAutoDrain(sessionId, v).catchError((Object e) {
                      app.log('[queue] setAutoDrain: $e');
                      return null;
                    }),
              ),
            ],
          ),
          for (final (i, item) in visibleItems.indexed) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item['text'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: ZT.ink),
                    ),
                  ),
                  // 序号/上移按钮要对着全队列的绝对位置算：折叠时只显示
                  // 队首，i>0 恒假正好把「上移」藏掉（队首本就无处可移）。
                  if (i > 0)
                    IconButton(
                      tooltip: '上移',
                      icon: const Icon(
                        Icons.arrow_upward_rounded,
                        size: 19,
                        color: ZT.inkSoft,
                      ),
                      onPressed: () {
                        final beforeId =
                            '${state.queueItems[i - 1]['queueItemId'] ?? ''}';
                        app
                            .reorderQueueItem(
                              sessionId,
                              queueItemId:
                                  '${item['queueItemId'] ?? ''}',
                              beforeQueueItemId: beforeId,
                            )
                            .catchError((Object e) {
                              app.log('[queue] reorderQueueItem: $e');
                              return null;
                            });
                      },
                    ),
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 19,
                      color: ZT.inkSoft,
                    ),
                    onPressed: () =>
                        _editQueueItem(sessionId, item),
                  ),
                  IconButton(
                    tooltip: '立即发送',
                    icon: const Icon(
                      Icons.flash_on_rounded,
                      size: 19,
                      color: ZT.primaryDeep,
                    ),
                    onPressed: () {
                      app
                          .sendQueuedNow(
                            sessionId,
                            '${item['queueItemId'] ?? ''}',
                          )
                          .catchError((Object e) {
                            app.log('[queue] sendQueuedNow: $e');
                            return null;
                          });
                    },
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 19,
                      color: ZT.rose,
                    ),
                    onPressed: () {
                      app
                          .deleteQueueItem(
                            sessionId,
                            '${item['queueItemId'] ?? ''}',
                          )
                          .catchError((Object e) {
                            app.log('[queue] deleteQueueItem: $e');
                            return null;
                          });
                    },
                  ),
                ],
              ),
            ),
            // 折叠时在队首条目下补一条「还有 N 条」提示，点它也能展开。
            if (hidden > 0 && i == 0)
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _queueExpanded = true),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 1, 2, 4),
                  child: Text(
                    '… 还有 $hidden 条，点开展开',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ZT.inkSoft,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 编辑排队中的消息：预填原文，保存后服务端改队列条目。
  Future<void> _editQueueItem(
    String sessionId,
    Map<String, Object?> item,
  ) async {
    final queueItemId = '${item['queueItemId'] ?? ''}';
    if (queueItemId.isEmpty) return;
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '编辑排队消息',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
          ),
          BigButton(
            label: '保存',
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newText == null || newText.isEmpty) return;
    await widget.app
        .editQueueItem(sessionId, queueItemId: queueItemId, newText: newText)
        .catchError((Object e) {
          widget.app.log('[queue] editQueueItem: $e');
          if (mounted) _flash('编辑失败：$e', error: true);
          return null;
        });
  }

  // --------------------------------------------------------------- config

  String get _curModel {
    final m = _state?.currentModel ?? '';
    if (m.isNotEmpty) return m;
    if (_draftModelValue?.isNotEmpty == true) {
      return _draftModelValue!.split('/').last;
    }
    return '';
  }

  String get _curProvider {
    final p = _state?.currentProvider ?? '';
    if (p.isNotEmpty) return p;
    if (_draftModelValue?.contains('/') == true) {
      return _draftModelValue!.substring(0, _draftModelValue!.lastIndexOf('/'));
    }
    return '';
  }

  String get _curThought {
    final t = _state?.currentThought ?? '';
    if (t.isNotEmpty) return t;
    return _draftThought ?? '';
  }

  String get _curMode {
    final m = _state?.currentMode ?? '';
    if (m.isNotEmpty) return m;
    return _draftMode ?? '';
  }

  /// 乐观刷新本地高亮；服务器状态帧随后覆盖为权威值。
  void _patchConfig(Map<String, dynamic> patch) {
    final st = _state;
    if (st == null) return;
    st.optimisticPatch({
      'config': {...?st.config, ...patch},
    });
  }

  String? _reconciledSid;

  /// 会话模型对账（每会话一次）：快照 config 落一行日志（观察服务端
  /// 持久化行为）；本地记录与服务端不一致 → 按本地显示并补发落库。
  Future<void> _reconcileSessionModel(String sid) async {
    final st = _state;
    final app = widget.app;
    if (st == null || !mounted) return;
    final cfg = st.config;
    if (cfg != null && cfg.isNotEmpty) {
      app.log('[v4] snapshot config=${jsonEncode(cfg)}');
    }
    final rec = app.sessionModels[sid];
    final recModel = '${rec?['model'] ?? ''}';
    final recProvider = '${rec?['provider'] ?? ''}';
    if (shouldApplyPreferredDefaultModel(rec)) {
      // 新会话（无记录）或记录还是服务端基线（千问 Max）——都算用户
      // 没选过模型：默认切英伟达 nemotron-3-ultra 并落库。
      _patchConfig({
        'provider': preferredDefaultModelProvider,
        'model': preferredDefaultModelId,
        'thought': preferredDefaultModelThought,
      });
      try {
        await app.switchModel(
          sid,
          provider: preferredDefaultModelProvider,
          model: preferredDefaultModelId,
          thought: preferredDefaultModelThought,
        );
        await app.recordSessionModel(sid, {
          'provider': preferredDefaultModelProvider,
          'model': preferredDefaultModelId,
          'thought': preferredDefaultModelThought,
        });
        app.log('[config] 默认模型 → nemotron-3-ultra（英伟达）');
      } on Object catch (e) {
        app.log('[config] 默认模型切换失败: $e');
      }
      return;
    }
    final curModel = '${cfg?['model'] ?? ''}'.trim();
    final curProvider = '${cfg?['provider'] ?? ''}'.trim();
    if (curModel == recModel &&
        (curProvider.isEmpty || curProvider == recProvider)) {
      return;
    }
    // 记录 ≠ 服务端时分两种（切换只发生在移动端，切换即写服务端，
    // 所以服务端的真实模型 = 我在某台设备上最新切的选择）：
    // - 服务端掉回基线（千问 Max）/历史默认（英伟达系）/空 → 真回退，
    //   按本地记录补发；
    // - 服务端是别的真实模型 → 接受它并更新本地记录。否则各设备的
    //   旧记录互相打回，谁重启谁翻车。
    final serverIsFallback = isServerFallbackModel(curModel);
    if (!serverIsFallback) {
      final curThought = '${cfg?['thought'] ?? ''}';
      _patchConfig({
        'provider': curProvider,
        'model': curModel,
        if (curThought.isNotEmpty) 'thought': curThought,
      });
      await app.recordSessionModel(sid, {
        'provider': curProvider,
        'model': curModel,
        if (curThought.isNotEmpty) 'thought': curThought,
      });
      app.log('[config] 采纳服务端模型 $curProvider/$curModel（他端新选择）');
      return;
    }
    // 服务端回退成默认了：按本地记录显示并补发落库。
    _patchConfig({
      'provider': recProvider,
      'model': recModel,
      if ('${rec?['thought'] ?? ''}'.isNotEmpty) 'thought': rec?['thought'],
    });
    try {
      final thought = '${rec?['thought'] ?? ''}';
      await app.switchModel(
        sid,
        provider: recProvider,
        model: recModel,
        thought: thought.isEmpty ? 'enabled' : thought,
      );
      app.log('[config] 已按本地记录补发模型 $recProvider/$recModel');
    } on Object catch (e) {
      app.log('[config] 模型补发失败: $e');
    }
  }

  /// 守恒器退避：5s 起步，每次纠正翻倍封顶 60s；发现对齐即复位。
  /// 无次数上限——用户需求「不切就是英伟达，切了就按实际模型」，
  /// 会话的意图模型（sessionModels 记录）必须长期成立，5 次上限
  /// 会让守卫过期后模型被桌面端静默改走（实测发生过）。
  Duration _keeperBackoff = const Duration(seconds: 5);
  DateTime _lastKeeperAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 常驻守恒：会话有意图模型（显式选择或新会话默认 nv）后，服务端
  /// 模型被外部改写（PC 聚焦写入/registryFallback）→ 纠正回意图模型。
  /// 运行中/流式不打断，等回 idle 再补；持续漂移时按退避节奏纠正。
  Future<void> _keepSessionModel(String sid) async {
    if (!mounted) return;
    final st = _state;
    final app = widget.app;
    if (st == null || !st.ready) return;
    final rec = app.sessionModels[sid];
    if (shouldApplyPreferredDefaultModel(rec)) return;
    final recModel = '${rec?['model'] ?? ''}'.trim();
    if (recModel.isEmpty) return;
    final recProvider = '${rec?['provider'] ?? ''}'.trim();
    final curModel = st.currentModel.trim();
    if (curModel.isEmpty) return;
    final curProvider = st.currentProvider.trim();
    if (recModel == curModel &&
        (recProvider.isEmpty ||
            curProvider.isEmpty ||
            curProvider == recProvider)) {
      _keeperBackoff = const Duration(seconds: 5);
      return;
    }
    // 运行中的回合不换马：等 idle 再纠正。
    if (st.isRunning || st.rows.any((r) => r['state'] == 'streaming')) return;
    final now = DateTime.now();
    if (now.difference(_lastKeeperAt) < _keeperBackoff) return;
    _lastKeeperAt = now;
    _keeperBackoff = _keeperBackoff * 2 > const Duration(seconds: 60)
        ? const Duration(seconds: 60)
        : _keeperBackoff * 2;
    app.log(
      '[config] 模型被外部改成 $curProvider/$curModel，纠正回 $recProvider/$recModel',
    );
    _patchConfig({
      'provider': recProvider,
      'model': recModel,
      if ('${rec?['thought'] ?? ''}'.isNotEmpty) 'thought': rec?['thought'],
    });
    final thought = '${rec?['thought'] ?? ''}';
    try {
      await app.switchModel(
        sid,
        provider: recProvider,
        model: recModel,
        thought: thought.isNotEmpty ? thought : 'enabled',
      );
      app.log('[config] 已纠正回 $recProvider/$recModel');
    } on Object catch (e) {
      app.log('[config] 模型纠正失败: $e');
    }
  }

  Future<void> _applyModel(Map option) async {
    final app = widget.app;
    final sid = _sid;
    final value = '${option['value'] ?? ''}';
    final (provider, model) = splitModelValue(value);
    // thought 必须对目标模型合法：当前值在选项里就保留，否则用选项
    // currentValue（Turbo: enabled/off），再不行 enabled。
    final thoughtOpt = app.configOption('thought_level');
    // 词表优先取快照 config.thoughtLevels（所选模型的实时词表，
    // 服务端切完模型就推送）；缺失退回 prepareWorkspace 缓存。
    final snapshotLevels = _state?.snapshot?['config'] is Map
        ? (_state!.snapshot!['config']['thoughtLevels'] as List? ?? const [])
        : const [];
    final thoughtValues = [
      for (final lv in snapshotLevels) '$lv',
      if (snapshotLevels.isEmpty)
        for (final o in app.configOptionList('thought_level'))
          '${o['value'] ?? ''}',
    ];
    final curThought = _curThought;
    final thought = curThought.isNotEmpty && thoughtValues.contains(curThought)
        ? curThought
        : '${thoughtOpt?['currentValue'] ?? (curThought.isNotEmpty ? curThought : 'enabled')}';
    if (sid == null) {
      setState(() {
        _draftModelValue = value;
        _draftThought = thought;
      });
      app.log('[config] 草稿模型 → ${option['name'] ?? model}');
      return;
    }
    // 乐观更新：先亮出所选模型再发 RPC——UI 不等一个服务端往返
    //（此前先 await 再 patch，网络一慢就像卡死）。失败回滚到原值。
    final prevProvider = _curProvider;
    final prevModel = _curModel;
    final prevThought = _curThought;
    _patchConfig({'provider': provider, 'model': model, 'thought': thought});
    try {
      await app.switchModel(
        sid,
        provider: provider,
        model: model,
        thought: thought,
      );
      unawaited(
        app.recordSessionModel(sid, {
          'provider': provider,
          'model': model,
          'thought': thought,
          // 用户显式选的：即使选的是千问 Max 也不被默认迁移拉走。
          'chosen': true,
        }),
      );
      app.log('[config] 模型 → ${option['name'] ?? model}');
    } on Object catch (e) {
      _patchConfig({
        if (prevProvider.isNotEmpty) 'provider': prevProvider,
        if (prevModel.isNotEmpty) 'model': prevModel,
        if (prevThought.isNotEmpty) 'thought': prevThought,
      });
      if (!mounted) return;
      _flash('切换模型失败：$e', error: true);
      app.log('[config] 切换失败: $e');
    }
  }

  Future<void> _applyThought(Map option) async {
    final app = widget.app;
    final sid = _sid;
    final value = '${option['value'] ?? option['name'] ?? ''}';
    var provider = _curProvider;
    var model = _curModel;
    if (provider.isEmpty && model.isEmpty) {
      final mv = '${app.configOption('model')?['currentValue'] ?? ''}';
      if (mv.isNotEmpty) (provider, model) = splitModelValue(mv);
    }
    if (sid == null) {
      setState(() => _draftThought = value);
      app.log('[config] 草稿思考等级 → ${option['name'] ?? value}');
      return;
    }
    try {
      await app.switchModel(
        sid,
        provider: provider,
        model: model,
        thought: value,
      );
      _patchConfig({'thought': value});
      app.log('[config] 思考等级 → ${option['name'] ?? value}');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('切换思考等级失败：$e', error: true);
      app.log('[config] 切换失败: $e');
    }
  }

  Future<void> _applyMode(Map option) async {
    final app = widget.app;
    final sid = _sid;
    final value = '${option['value'] ?? option['name'] ?? ''}';
    if (sid == null) {
      setState(() => _draftMode = value);
      app.log('[config] 草稿协作模式 → ${option['name'] ?? value}');
      return;
    }
    try {
      await app.switchMode(sid, value);
      _patchConfig({'mode': value});
      app.log('[config] 协作模式 → ${option['name'] ?? value}');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('切换模式失败：$e', error: true);
      app.log('[config] 切换失败: $e');
    }
  }

  // -------------------------------------------------------- quick sheets

  /// 思考等级 / 协作模式 / 追问模式共用：单组药丸选择，点选即关。
  /// [options] 直接给选项组；不给时按 [optionId] 从 prepareWorkspace 取。
  void _openOptionSheet({
    required String title,
    required IconData icon,
    required Color accent,
    String? optionId,
    List<Map>? options,
    required String current,
    required Future<void> Function(Map option) onApply,
  }) {
    final rows = options ?? widget.app.configOptionList(optionId ?? '');
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.6,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ZT.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(icon, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    '（暂无可用选项）',
                    style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final option in rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: _OptionRow(
                            option: option,
                            selected: _optionIsCurrent(option, current),
                            accent: accent,
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              onApply(option);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- followup

  String get _curFollowup {
    final m = _state?.currentFollowupMode ?? '';
    return m.isEmpty ? 'queue' : m;
  }

  Future<void> _applyFollowup(Map option) async {
    final app = widget.app;
    final sid = _sid;
    final value = '${option['value']}';
    if (sid == null) {
      app.log('[followup] 会话未创建，暂不能切换追问模式');
      return;
    }
    try {
      await app.setFollowupMode(sid, value);
      _patchConfig({'followupMode': value});
      app.log('[followup] 追问模式 → ${option['name'] ?? value}');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('切换追问模式失败：$e', error: true);
    }
  }

  void _openFollowupSheet() => _openOptionSheet(
    title: '追问模式',
    icon: Icons.low_priority_rounded,
    accent: ZT.primaryDeep,
    options: const [
      {'value': 'queue', 'name': '排队 · 跑完自动执行'},
      {'value': 'guide', 'name': '引导 · 立即插话转向'},
    ],
    current: _curFollowup,
    onApply: _applyFollowup,
  );

  /// 模式 + 权限二段弹层（同模型+思考等级编排）：上半选协作模式，
  /// 下半选 Agent 权限，点选即生效不关弹层。
  void _openModePermissionSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => AnimatedBuilder(
        animation: Listenable.merge([widget.app, widget.app.chat?.state]),
        builder: (sheetCtx, _) {
          final modeOptions = widget.app.configOptionList('mode');
          final modes = modeOptions.isNotEmpty
              ? modeOptions
              : const [
                  // prepareWorkspace 缺失时的降级词表，与协议四模式对齐。
                  {'value': 'build', 'name': '构建'},
                  {'value': 'edit', 'name': '编辑'},
                  {'value': 'plan', 'name': '计划'},
                  {'value': 'yolo', 'name': '全权'},
                ];
          final approval = _state?.currentApprovalMode ?? '';
          return SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7,
              ),
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: ListView(
                shrinkWrap: true,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZT.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      Icon(Icons.tune_rounded, size: 18, color: ZT.grape),
                      SizedBox(width: 8),
                      Text(
                        '模式与权限',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '点选即生效，选完点空白处或下拉关闭',
                    style: TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                  ),
                  const SizedBox(height: 12),
                  const _SectionLabel(
                    icon: Icons.route_rounded,
                    label: '协作模式',
                    color: ZT.grape,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final o in modes)
                        _ModePill(
                          label:
                              '${o['name'] ?? modeLabel('${o['value'] ?? ''}')} ',
                          value: '${o['value'] ?? ''}',
                          selected: '${o['value'] ?? ''}' == _curMode,
                          accent: ZT.grape,
                          onTap: () => _applyMode(o),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const _SectionLabel(
                    icon: Icons.shield_outlined,
                    label: 'Agent 权限',
                    color: ZT.aqua,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final m in _approvalModes)
                        _ModePill(
                          label: m.label,
                          value: m.id,
                          selected: approval == m.id,
                          accent: m.color,
                          onTap: () => _applyApproval(m.id, m.label),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '权限控制改文件/执行命令前要不要先问你；完全访问请谨慎。',
                    style: TextStyle(fontSize: 11, color: ZT.inkFaint),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- retry

  /// 用户消息长按 → 本轮操作。
  void _openRowActions(int rowId, Map<String, dynamic> row) {
    final sid = _sid;
    if (sid == null) return;
    // 取这条用户消息的原文，给编辑重发预填。
    Map<String, dynamic>? row;
    for (final r in _viewState?.rows ?? const <Map<String, dynamic>>[]) {
      if ((r['rowId'] as num?)?.toInt() == rowId) {
        row = r;
        break;
      }
    }
    // userInput 行字段双形态（text/inputText），与 buildRowCard 渲染口径一致。
    final entityId = '${row?['entityId'] ?? row?['turnId'] ?? ''}';
    final originalText = '${row?['text'] ?? row?['inputText'] ?? ''}';
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ZT.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _OptionRow(
                option: const {'name': '编辑重发'},
                selected: false,
                accent: ZT.ink,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _editUserQuery(
      sid,
      rowId: rowId,
      entityId: entityId,
      original: originalText,
    );
                },
              ),
              _OptionRow(
                option: const {'name': '重新生成本轮'},
                selected: false,
                accent: ZT.primaryDeep,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _retryTurn(sid, rowId, entityId);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _retryTurn(String sid, int rowId, String entityId) async {
    try {
      requireAccepted(
        await widget.app.retryTurn(sid, {'rowId': rowId, 'entityId': entityId}),
      );
      widget.app.log('[chat] 已请求重新生成');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('重新生成失败：$e', error: true);
    }
  }

  /// 编辑已发用户消息并重发：预填原文 → 确认后行级 CAS 提交，
  /// 服务端截断本回合后续行并重跑（rows 由 delta 流自动更新）。
  Future<void> _editUserQuery(
    String sid, {
    required int rowId,
    required String entityId,
    required String original,
  }) async {
    final controller = TextEditingController(text: original);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
        title: const Text(
          '编辑并重发',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
          ),
          BigButton(
            label: '重发',
            onPressed: () {
              final v = controller.text.trim();
              Navigator.pop(dialogCtx, v.isEmpty || v == original ? null : v);
            },
          ),
        ],
      ),
    );
    controller.dispose();
    if (newText == null || newText.isEmpty) return;
    try {
      requireAccepted(
        await widget.app.editUserQuery(
          sid,
          rowId: rowId,
          entityId: entityId,
          newText: newText,
        ),
      );
      widget.app.log('[chat] 已提交编辑重发');
      _followLocked = false;
      _atBottom = true;
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      _flash('编辑重发失败：$e', error: true);
    }
  }

  /// assistant 行长按 → 反馈（赞/踩）/ 重新生成本轮。
  /// 当前反馈态读 row['feedback']（服务端有则高亮，没有就都不选）。
  void _openAssistantActions(int rowId, Map<String, dynamic> row) {
    final sid = _sid;
    if (sid == null) return;
    HapticFeedback.mediumImpact();
    final current = '${row['feedback'] ?? ''}';
    final entityId = '${row['entityId'] ?? row['turnId'] ?? ''}';
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: ZT.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _OptionRow(
                option: const {'name': '复制全文'},
                selected: false,
                accent: ZT.ink,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  // Android 13+ 系统自带剪贴板确认气泡，这里不再额外提示。
                  Clipboard.setData(
                    ClipboardData(text: '${row['text'] ?? ''}'),
                  );
                },
              ),
              const SizedBox(height: 6),
              _OptionRow(
                option: const {'name': '👍 赞 — 回答有帮助'},
                selected: current == 'like',
                accent: ZT.aqua,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _sendFeedback(sid, rowId, entityId, 'like');
                },
              ),
              const SizedBox(height: 6),
              _OptionRow(
                option: const {'name': '👎 踩 — 回答有问题'},
                selected: current == 'dislike',
                accent: ZT.rose,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _sendFeedback(sid, rowId, entityId, 'dislike');
                },
              ),
              if (current.isNotEmpty) ...[
                const SizedBox(height: 6),
                _OptionRow(
                  option: const {'name': '取消反馈'},
                  selected: false,
                  accent: ZT.inkSoft,
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _sendFeedback(sid, rowId, entityId, null);
                  },
                ),
              ],
              const SizedBox(height: 6),
              _OptionRow(
                option: const {'name': '🎬 从此分叉新会话（继承上文）'},
                selected: false,
                accent: ZT.grape,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _forkFromHere(sid, rowId, entityId);
                },
              ),
              const SizedBox(height: 6),
              _OptionRow(
                option: const {'name': '重新生成本轮'},
                selected: false,
                accent: ZT.primaryDeep,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _retryTurn(sid, rowId, entityId);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分叉：从该条回复创建继承上文的新会话并直接打开。
  Future<void> _forkFromHere(String sid, int rowId, String entityId) async {
    if (entityId.isEmpty) {
      _flash('该行缺少实体标识，无法分叉', error: true);
      return;
    }
    try {
      final newId = await widget.app.forkAssistant(
        sid,
        rowId: rowId,
        entityId: entityId,
      );
      widget.app.log('[chat] 已分叉新会话 $newId');
      if (!mounted) return;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatPage(
              app: widget.app,
              sessionId: newId,
              title: '${widget.title} · 分叉',
            ),
          ),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      _flash('分叉失败：$e', error: true);
    }
  }

  Future<void> _sendFeedback(
    String sid,
    int rowId,
    String entityId,
    String? feedback,
  ) async {
    try {
      requireAccepted(
        await widget.app.setAssistantFeedback(
          sid,
          {'rowId': rowId, 'entityId': entityId},
          feedback,
        ),
      );
      widget.app.log('[chat] 反馈已提交${feedback == null ? '（撤销）' : ''}');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('反馈失败：$e', error: true);
    }
  }

  /// 失败回显重试：文本与附件塞回输入区，走完整发送路径（含草稿建会话）。
  void _retryEcho(Map<String, Object?> echo) {
    final text = '${echo['text'] ?? ''}';
    final files =
        (echo['files'] as List?)?.whereType<PlatformFile>().toList() ??
        const <PlatformFile>[];
    setState(() {
      _echoes.remove(echo);
      _echoesVersion++;
      if (text.isNotEmpty) _input.text = text;
      // 失败路径不回清 _picked（成功才清），残留附件会在这里被重复添加——
      // 先清空再回填 echo 里保存的那一份，避免附件条出现重复项。
      _picked.clear();
      _picked.addAll(files);
    });
    _send();
  }

  /// 失败一键切回 GLM 再重试：服务端被刷到欠费基线（千问系）时的最后
  /// 退路（BUG-07）——显式点按算用户选择，记 chosen。
  Future<void> _retryEchoWithDefault(Map<String, Object?> echo) async {
    final app = widget.app;
    final sid = _sid;
    if (sid == null) {
      setState(() {
        _draftModelValue =
            '$preferredDefaultModelProvider/$preferredDefaultModelId';
        _draftThought = preferredDefaultModelThought;
      });
    } else {
      try {
        await app.switchModel(
          sid,
          provider: preferredDefaultModelProvider,
          model: preferredDefaultModelId,
          thought: preferredDefaultModelThought,
        );
        _patchConfig({
          'provider': preferredDefaultModelProvider,
          'model': preferredDefaultModelId,
          'thought': preferredDefaultModelThought,
        });
        unawaited(
          app.recordSessionModel(sid, {
            'provider': preferredDefaultModelProvider,
            'model': preferredDefaultModelId,
            'thought': preferredDefaultModelThought,
            'chosen': true,
          }),
        );
      } on Object catch (e) {
        if (!mounted) return;
        _flash('切回 GLM 失败：$e', error: true);
        return;
      }
    }
    _retryEcho(echo);
  }

  // ------------------------------------------------------------- insert

  /// 输入区弹层：默认为插入（拍照/相册/文件）；asTools 为工具弹层（技能与斜杠命令）。
  void _openInsertSheet({bool asTools = false}) {
    final app = widget.app;
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.65,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: AnimatedBuilder(
            animation: app,
            builder: (sheetCtx, _) {
              final skills = app.skills;
              final commands = app.slashCommands;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZT.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        asTools
                            ? Icons.handyman_rounded
                            : Icons.add_circle_outline_rounded,
                        size: 18,
                        color: ZT.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        asTools ? '技能与命令' : '插入',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (!asTools) ...[
                          _OptionRow(
                            option: const {'name': '拍照'},
                            icon: Icons.photo_camera_outlined,
                            selected: false,
                            accent: ZT.primary,
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              _pickCamera();
                            },
                          ),
                          const SizedBox(height: 6),
                          _OptionRow(
                            option: const {'name': '从相册选择图片'},
                            icon: Icons.photo_library_outlined,
                            selected: false,
                            accent: ZT.primary,
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              _pickImage();
                            },
                          ),
                          const SizedBox(height: 6),
                          _OptionRow(
                            option: const {'name': '上传文件(PDF/文档/任意)'},
                            icon: Icons.folder_outlined,
                            selected: false,
                            accent: ZT.primary,
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              _pickFile();
                            },
                          ),
                        ],
                        if (asTools && skills.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.only(top: 12, bottom: 7),
                            child: Text(
                              '技能 · 输入 \$ 触发',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: ZT.inkFaint,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s in skills)
                                _TokenChip(
                                  prefix: r'$',
                                  label: tokenName(s),
                                  description: tokenDesc(s),
                                  accent: ZT.grape,
                                  onTap: () {
                                    Navigator.pop(sheetCtx);
                                    _insertToken('\$${tokenName(s)} ');
                                  },
                                ),
                            ],
                          ),
                        ],
                        if (asTools && commands.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.only(top: 12, bottom: 7),
                            child: Text(
                              '斜杠命令 · 输入 / 触发',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: ZT.inkFaint,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final c in commands)
                                _TokenChip(
                                  prefix: '/',
                                  label: tokenName(c),
                                  description: tokenDesc(c),
                                  accent: ZT.aqua,
                                  onTap: () {
                                    Navigator.pop(sheetCtx);
                                    _insertToken('/${tokenName(c)} ');
                                  },
                                ),
                            ],
                          ),
                        ],
                        if (asTools && skills.isEmpty && commands.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '（工作区暂无技能和斜杠命令）',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: ZT.inkFaint,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 把 token 填进输入框（联想/插入共用），光标落在末尾。
  void _insertToken(String token) {
    _input.text = token;
    _input.selection = TextSelection.collapsed(offset: token.length);
  }

  // ------------------------------------------------------------- compact

  /// 会话里是否有进行中的压缩（timelineMarker: compact/running）。
  /// 桌面端把 compact 当输入型命令排队——重复发只会排队多个压缩回合，
  /// 按钮必须用它挡住连点；同时它就是「正在压缩」状态的权威来源。
  bool get _compactRunning {
    final rows = _state?.rows ?? const <Map<String, dynamic>>[];
    return rows.any((r) {
      if (r['kind'] != 'timelineMarker') return false;
      final m = r['marker'];
      return m is Map &&
          '${m['type']}' == 'compact' &&
          '${m['status']}' == 'running';
    });
  }

  Future<void> _compact() async {
    final app = widget.app;
    final sid = _sid;
    if (sid == null) return;
    if (_compactRunning) {
      _flash('正在压缩中，不用重复发起');
      return;
    }
    try {
      await app.compact(sid);
      // 命令发出≠压缩完成：完成后对话流里会出现「已压缩上下文」提示条
      // （BUG-30 修复），用量面板里窗口占用同步回落——两条路都可感知。
      if (!mounted) return;
      _flash('已发出压缩请求，完成后会在对话里提示');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('压缩失败：$e', error: true);
    }
  }

  /// 模型二级选择：一级供应商（手风琴展开），二级该供应商下的模型。
  void _openModelSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _ModelSheet(
        app: widget.app,
        currentProvider: _curProvider,
        currentModel: _curModel,
        currentThought: _curThought,
        // 点模型不关弹层：先选模型再选思考等级，由「完成」/空白处关闭。
        onPick: _applyModel,
        onPickThought: _applyThought,
      ),
    );
  }

  // ----------------------------------------------------------------- usage

  static String _fmtTokens(num v) {
    final s = v.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final left = s.length - i;
      b.write(s[i]);
      if (left > 1 && left % 3 == 1) b.write(',');
    }
    return b.toString();
  }

  /// 右上角「新建定时任务」：选频率 + 内容自输，任务名=会话名，直建不经转述。
  Future<void> _showCreateCronSheet() async {
    final sid = _sid;
    if (sid == null || widget.title.isEmpty) {
      flashMessage(context, '会话未就绪，稍后再试', error: true);
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => CreateCronSheet(
        app: widget.app,
        sessionId: sid,
        sessionTitle: widget.title,
      ),
    );
  }

  /// 任务面板：子代理活动 / 后台任务 / 定时任务 三 Tab 集合。
  /// Composer「任务」槽与 AppBar 活动按钮共用此入口。
  void _openTasksPanelSheet() {
    unawaited(widget.app.loadAutomations());
    final autoShowAll = ValueNotifier<bool>(false);
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => DefaultTabController(
        length: 3,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.app,
            widget.app.chat?.state,
            autoShowAll,
          ]),
          builder: (sheetCtx, _) {
            final st = _state;
            final works = parseActiveWorks(st?.control);
            final subs = streamingSubagents(st?.rows ?? const []);
            final bg = parseBackgroundWorks(st?.snapshot?["backgroundWorks"]);
            final curTag = AutomationView.tagOfSession(
              widget.app.chat?.sessionId ?? '',
            );
            final autosAll = [
              for (final m in widget.app.automations) AutomationView.fromMap(m),
            ];
            final autos = filterAutomationsBySession(
              autosAll,
              curTag,
              showAll: autoShowAll.value,
            );
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(sheetCtx).size.height * 0.7,
                child: Column(
                  children: [
                    TabBar(
                      labelColor: ZT.primaryDeep,
                      unselectedLabelColor: ZT.inkFaint,
                      indicatorColor: ZT.primary,
                      dividerColor: ZT.line,
                      labelStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                      tabs: const [
                        Tab(text: '子代理'),
                        Tab(text: '后台任务'),
                        Tab(text: '定时任务'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _activityTab(
                            works,
                            subs,
                            parseSubagents(st?.snapshot?['subagents']),
                          ),
                          _backgroundTab(bg),
                          _automationsTab(autos, autoShowAll, autosAll.length),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _activityTab(
    List<WorkView> works,
    List<SubagentActivity> subs,
    List<SubagentLiveView> live,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        if (works.where((w) => w.kind != 'primaryTurn').isEmpty &&
            subs.isEmpty &&
            live.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '当前没有运行中的子代理',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
            ),
          ),
        // 快照 subagents.running[]：桌面端专门上报的实时子代理
        for (final s in live)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: s.stuck
                    ? ZT.lemon.withValues(alpha: 0.15)
                    : ZT.aqua.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1.3, color: s.stuck ? ZT.lemon : ZT.aqua),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PulseDot(
                        color: s.stuck ? ZT.lemon : ZT.aqua,
                        animate: !s.stuck,
                        size: 7,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.type.isEmpty
                              ? (s.title.isEmpty ? '子代理' : s.title)
                              : '子代理 · ${s.type}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: s.stuck ? ZT.ink : ZT.aqua,
                          ),
                        ),
                      ),
                      Text(
                        s.statusLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: s.stuck ? ZT.lemon : ZT.inkFaint,
                        ),
                      ),
                    ],
                  ),
                  if (s.title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (s.summary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        s.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: ZT.inkSoft,
                          height: 1.4,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        workElapsed(s.startedAt),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: ZT.inkFaint,
                        ),
                      ),
                      const Spacer(),
                      if (s.childSessionId.isNotEmpty)
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ChatPage(
                                  app: widget.app,
                                  sessionId: s.childSessionId,
                                  title: '子代理 · ${s.type}',
                                ),
                              ),
                            );
                          },
                          child: const Text(
                            '打开子代理会话',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: ZT.primaryDeep,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        // Agent/Task 工具调用形式的运行中子代理
        for (final s in streamingAgentToolCalls(_state?.rows ?? const []))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: ZT.aqua.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1.3, color: ZT.aqua),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PulseDot(color: ZT.aqua, animate: true, size: 7),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ZT.inkSoft,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final w in works)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: ZT.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1.3, color: ZT.grape),
                ),
              ),
              child: Row(
                children: [
                  const PulseDot(color: ZT.grape, animate: true, size: 7),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      w.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    workElapsed(w.startedAt),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ZT.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final s in subs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: ZT.aqua.withValues(alpha: 0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1.3, color: ZT.aqua),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const PulseDot(color: ZT.aqua, animate: true, size: 7),
                      const SizedBox(width: 8),
                      const Text(
                        '子代理',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: ZT.aqua,
                        ),
                      ),
                    ],
                  ),
                  if (s.summary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        s.summary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: ZT.inkSoft,
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 后台任务 Tab：状态徽章 + 运行时长 + 可取消任务带取消按钮
  /// （cancelBackgroundWork {workId}，服务端 cancellable 才显示）。
  Widget _backgroundTab(List<BackgroundWorkView> works) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        if (works.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '当前没有后台任务',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
            ),
          ),
        for (final w in works)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: ZT.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(
                    w: 1.3,
                    color: _bgStatusColor(w),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        w.kind == 'subagent'
                            ? Icons.groups_rounded
                            : Icons.dns_rounded,
                        size: 15,
                        color: _bgStatusColor(w),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          w.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _bgStatusBadge(w),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        w.done ? '用时 ${workElapsed(w.startedAt, endedAt: w.endedAt)}' : workElapsed(w.startedAt),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: ZT.inkFaint,
                        ),
                      ),
                      const Spacer(),
                      if (w.running && w.cancellable)
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _cancelBackgroundWork(w),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 3,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.close_rounded,
                                  size: 13,
                                  color: ZT.rose,
                                ),
                                SizedBox(width: 3),
                                Text(
                                  '取消',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: ZT.rose,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 后台任务状态色：运行=柠檬黄、完成=青绿、失败=玫红、取消/未知=灰。
  Color _bgStatusColor(BackgroundWorkView w) => switch (w.status) {
    'running' => ZT.lemon,
    'resultPending' => ZT.aqua,
    'failed' => ZT.rose,
    _ => ZT.inkFaint,
  };

  Widget _bgStatusBadge(BackgroundWorkView w) {
    final color = _bgStatusColor(w);
    final filled = w.running;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: filled ? ZT.lemon.withValues(alpha: 0.35) : ZT.bg,
        shape: StadiumBorder(side: ZT.inkSide(w: 1.1, color: color)),
      ),
      child: Text(
        w.statusLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: filled ? ZT.ink : color,
        ),
      ),
    );
  }

  Future<void> _cancelBackgroundWork(BackgroundWorkView w) async {
    try {
      await widget.app.cancelBackgroundWork(w.workId);
      widget.app.log('[activity] 已请求取消后台任务 ${w.workId}');
      if (!mounted) return;
      _flash('已请求取消（${w.label}）');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('取消失败：$e', error: true);
    }
  }

  Widget _automationsTab(
    List<AutomationView> autos,
    ValueNotifier<bool> showAll,
    int total,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const Text(
                '只看本会话',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: ZT.inkSoft,
                ),
              ),
              Switch(
                value: !showAll.value,
                activeThumbColor: ZT.primaryDeep,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => showAll.value = !v,
              ),
              const Spacer(),
              Text(
                total > autos.length ? '${autos.length}/$total 条' : '${autos.length} 条',
                style: const TextStyle(fontSize: 11, color: ZT.inkFaint),
              ),
            ],
          ),
        ),
        if (autos.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                Text(
                  total > 0
                      ? '本会话暂无定时任务（共 $total 条，可关「只看本会话」查看）'
                      : '还没有定时任务',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: ZT.inkFaint),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AutomationsPage(app: widget.app),
                      ),
                    );
                  },
                  child: const Text(
                    '打开定时任务页',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: ZT.primaryDeep,
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final a in autos)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(11),
              decoration: ShapeDecoration(
                color: ZT.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          a.title.isEmpty ? a.id : a.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Switch(
                        value: a.enabled,
                        activeThumbColor: ZT.primaryDeep,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) => widget.app.setAutomationEnabled(
                            a.id, v, workspacePath: a.workspacePath),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        a.scheduleLabel,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          color: ZT.inkFaint,
                        ),
                      ),
                      if (a.enabled)
                        Text(
                          '下次 ${automationCountdown(a.nextRunAt)}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: ZT.primaryDeep,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          await widget.app.restartAutomation(a.id);
                          unawaited(widget.app.loadAutomations());
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.restart_alt_rounded, size: 13, color: ZT.ink),
                              SizedBox(width: 3),
                              Text('重启', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: ZT.ink)),
                            ],
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => widget.app.runAutomationNow(a.id),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.flash_on_rounded,
                                size: 13,
                                color: ZT.primaryDeep,
                              ),
                              SizedBox(width: 3),
                              Text(
                                '立即运行',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: ZT.primaryDeep,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            widget.app.deleteAutomation(
                              a.id,
                              workspacePath: a.workspacePath,
                            ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.delete_outline_rounded,
                                size: 13,
                                color: ZT.rose,
                              ),
                              SizedBox(width: 3),
                              Text(
                                '删除',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: ZT.rose,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// AppBar「当前活动」按钮已移除（与底部「任务」槽重复）。
  /// 入口统一走 Composer 底部栏的「任务」槽 → _openTasksPanelSheet。

  void _openUsageSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => AnimatedBuilder(
        // 弹层开着时数字也要动：回合跑完/流式推进都会推 usage 补丁。
        animation: Listenable.merge([widget.app, widget.app.chat?.state]),
        builder: (sheetCtx, _) {
          final usage = _state?.usage;
          final contextWindow = usage?['contextWindow'] is Map
              ? (usage!['contextWindow'] as Map).cast<String, dynamic>()
              : null;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZT.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      Icon(Icons.data_usage_rounded, size: 18, color: ZT.aqua),
                      SizedBox(width: 8),
                      Text(
                        '本次会话用量',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (usage == null)
                    const Text(
                      '暂无数据 —— 会话跑过一轮后这里会显示上下文窗口和累计 Token。',
                      style: TextStyle(fontSize: 12.5, color: ZT.inkSoft),
                    )
                  else ...[
                    _UsageContext(
                      window: _state?.contextWindowUsage,
                      threshold:
                          contextWindow?['autoCompactThresholdTokens'] is num
                          ? (contextWindow!['autoCompactThresholdTokens']
                                    as num)
                                .toInt()
                          : null,
                      fmt: _fmtTokens,
                    ),
                    const SizedBox(height: 14),
                    _UsageCache(
                      cache: contextWindow?['cache'] is Map
                          ? (contextWindow!['cache'] as Map)
                                .cast<String, dynamic>()
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _UsageBreakdown(
                      breakdown: contextWindow?['breakdown'],
                      fmt: _fmtTokens,
                    ),
                    const SizedBox(height: 14),
                    _UsageCumulative(usage: usage, fmt: _fmtTokens),
                  ],
                  if (widget.sessionId != null ||
                      widget.app.chat?.sessionId != null) ...[
                    const SizedBox(height: 14),
                    // 压缩进行中按钮转禁用态：桌面端 compact 是排队输入，
                    // 连点只会排队多个压缩回合。
                    BigButton(
                      label: _compactRunning
                          ? '正在压缩上下文…'
                          : '压缩上下文 · 保留要点释放窗口',
                      icon: _compactRunning ? null : Icons.compress_rounded,
                      expand: true,
                      onPressed: _compactRunning
                          ? null
                          : () {
                              Navigator.pop(sheetCtx);
                              _compact();
                            },
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------ approvals

  static const _approvalModes = [
    (
      id: 'askBeforeChange',
      label: '变更前确认',
      desc: '改文件前先问我。',
      icon: Icons.touch_app_outlined,
      color: ZT.aqua,
    ),
    (
      id: 'autoEdit',
      label: '自动编辑',
      desc: '自动编辑文件。',
      icon: Icons.edit_outlined,
      color: ZT.primary,
    ),
    (
      id: 'planMode',
      label: '计划模式',
      desc: '编辑前先出计划。',
      icon: Icons.assignment_outlined,
      color: ZT.grape,
    ),
    (
      id: 'fullAccess',
      label: '完全访问',
      desc: '减少确认次数，谨慎使用。',
      icon: Icons.shield_outlined,
      color: ZT.rose,
    ),
  ];

  void _flash(String message, {bool error = false}) =>
      flashMessage(context, message, error: error);

  Future<void> _applyApproval(String id, String label) async {
    final app = widget.app;
    final sessionId = _sid;
    if (sessionId == null) {
      app.log('[approval] 会话未创建，暂不能切换权限');
      _flash('会话还没创建，先发第一条消息', error: true);
      return;
    }
    try {
      await app.setApprovalMode(sessionId, id);
      final st = app.chat?.state;
      st?.optimisticPatch({
        'config': {...?st.config, 'approvalMode': id},
      });
      unawaited(app.recordApprovalMode(sessionId, id));
      app.log('[approval] → $label');
    } on Object catch (e) {
      if (!mounted) return;
      _flash('切换权限失败：$e', error: true);
      app.log('[approval] 切换失败: $e');
    }
  }

  // ---------------------------------------------------------------- build

  /// build 每帧都跑：app / 会话没换就复用同一个合并监听，
  /// 不再每帧 Listenable.merge 新建一挂一摘。
  Listenable? _pageListenable;
  ZApp? _listenApp;
  ConversationState? _listenState;

  Listenable _pageAnimations() {
    final st = _state;
    if (_pageListenable != null &&
        identical(_listenApp, widget.app) &&
        identical(_listenState, st)) {
      return _pageListenable!;
    }
    _listenApp = widget.app;
    _listenState = st;
    _pageListenable = Listenable.merge([widget.app, ?st]);
    return _pageListenable!;
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: _pageAnimations(),
      builder: (context, _) {
        final state = _state;
        final streamingRow = _trailingStreamingRow(state);
        final degraded = app.bridge?.degraded.value;
        // 自动滚到底检测：必须在 post-frame 做——animateTo 在 build 期
        // 执行属于未定义行为（曾经的红屏崩溃源）。
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoScroll());
        // 打开中的会话以 conv 通道 phase 为权威同步到任务卡；
        // setLivePhase 会 notifyListeners，不能在 build 期发。
        final sid = _sid;
        if (sid != null) {
          final phase = state?.phase ?? '';
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => app.setLivePhase(sid, phase),
          );
        }
        // 模型选择对账（每会话一次）：本地记录 ≠ 服务端快照 → 按本地
        // 显示并补发落库。
        if (sid != null && state?.ready == true && _reconciledSid != sid) {
          _reconciledSid = sid;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _reconcileSessionModel(sid),
          );
        }
        // 模型漂移纠正（常驻）：PC 端聚焦会话窗口会把它的模型覆盖写入
        // 服务端（后写者赢），手机切完就被抹掉——发现服务端模型和本地
        // 显式记录不符就纠正回来。
        if (sid != null && state?.ready == true) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _keepSessionModel(sid),
          );
        }
        return Scaffold(
          appBar: AppBar(
            leading: BackButton(
              onPressed: () {
                app.newDraft();
                Navigator.of(context).pop();
              },
            ),
            titleSpacing: 0,
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (state != null && state.phase.isNotEmpty)
                  StatusChip(phase: state.phase, compact: true),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '新建定时任务',
                icon: const Icon(Icons.alarm_add_rounded, color: ZT.ink),
                onPressed: _showCreateCronSheet,
              ),
              IconButton(
                tooltip: '刷新（强制重同步）',
                icon: const Icon(Icons.refresh_rounded, color: ZT.ink),
                onPressed: _forceResync,
              ),
              // 右上角「当前活动」按钮已移除：与 Composer 底部栏的「任务」
              // 槽完全重复（同一个三 Tab 面板），留一个入口就够。
            ],
          ),
          body: Column(
            children: [
              if (degraded != null)
                _DegradedBanner(
                  reason: degraded,
                  onReconnect: () async {
                    try {
                      await app.reconnect();
                      final sid = _sid;
                      if (sid != null) await app.openSession(sid);
                    } on Object catch (e) {
                      app.log('[reconnect] 失败: $e');
                    }
                  },
                ),
              // 有本机历史顶着就先画内容，别拿转圈挡住用户——切进来能立刻
              // 看到记录、能马上打字发消息是第一需求（用户裁定 2026-09-13）。
              if (app.chatLoading && !_onLocalSnapshot)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: ZT.primary),
                        SizedBox(height: 12),
                        Text(
                          '正在同步会话…',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: ZT.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              // 只有**真失败**才亮这张卡（判据见 shouldShowChatOpenFailure）。
              else if (shouldShowChatOpenFailure(
                chatError: app.chatError,
                sessionId: widget.sessionId,
                hasSnapshot: _onLocalSnapshot,
              ))
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '会话订阅失败',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        BigButton(
                          label: '重试',
                          icon: Icons.refresh_rounded,
                          onPressed: () => app.openSession(widget.sessionId!),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: Stack(
                    children: [
                      _buildList(_viewState, streamingRow: streamingRow),
                      if (_showJump)
                        Positioned(
                          right: 14,
                          bottom: 14,
                          child: GestureDetector(
                            onTap: () {
                              // 用户明确要求回到底部：解锁跟随，
                              // 否则回去之后仍被判为"翻历史中"，新消息不再跟。
                              if (_followLocked) {
                                setState(() => _followLocked = false);
                              }
                              if (_unreadWhileLocked != 0) {
                                setState(() => _unreadWhileLocked = 0);
                              }
                              _scroll.animateTo(
                                0,
                                duration: const Duration(milliseconds: 250),
                                curve: Curves.easeOut,
                              );
                            },
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: ShapeDecoration(
                                color: ZT.primary,
                                shape: CircleBorder(side: ZT.inkSide(w: 1.8)),
                                shadows: ZT.hard(dx: 2.5, dy: 2.5),
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  const Center(
                                    child: Icon(
                                      Icons.arrow_downward_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  if (_unreadWhileLocked > 0)
                                    Positioned(
                                      top: -2,
                                      right: -2,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: ShapeDecoration(
                                          color: ZT.rose,
                                          shape: const StadiumBorder(
                                            side: BorderSide(
                                              width: 1.2,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        constraints: const BoxConstraints(
                                          minHeight: 16,
                                        ),
                                        child: Text(
                                          _unreadWhileLocked > 99
                                              ? '99+'
                                              : '$_unreadWhileLocked',
                                          style: const TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w900,
                                            color: Colors.white,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              // 流式面板（借鉴 zcode-dev）：流式行渲染在列表外——长高吃
              // 自己的空间，列表内容零变化，历史不被顶动。
              if (!app.chatLoading && streamingRow != null)
                _StreamingPanel(
                  row: streamingRow,
                  transport: app.conv,
                  sessionId: _sid ?? '',
                ),
              // 运行中也要能设置追问模式，不只是有排队时。
              if (state != null &&
                  (state.queueItems.isNotEmpty || state.isRunning))
                _queueBar(state),
              if (state != null && state.pendingInteractions.isNotEmpty)
                _InteractionsPanel(state: state, app: app),
              _buildComposer(state),
            ],
          ),
        );
      },
    );
  }

  /// 粘性计划缓存：todowrite 行滑出消息窗口后面板不丢，
  /// 直到出现新的 todowrite（或快照 plan）才更新。
  List<PlanStep>? _stickyPlan;

  /// 派生计划按 (rows, plan, historicalPlan) 实例身份做钥匙缓存，
  /// 消息列表和计划弹层共用这一份（快照 plan 优先，历史计划兜底）。
  Object? _planRowsKey;
  Object? _planSnapKey;
  Object? _planHistKey;
  List<PlanStep>? _planCache;

  List<PlanStep>? _resolvePlan(ConversationState? state) {
    if (state == null) return _stickyPlan;
    if (!identical(state.rows, _planRowsKey) ||
        !identical(state.plan, _planSnapKey) ||
        !identical(state.historicalPlan, _planHistKey)) {
      _planRowsKey = state.rows;
      _planSnapKey = state.plan;
      _planHistKey = state.historicalPlan;
      final derived = derivePlanSteps(
        rows: state.rows,
        snapshotPlan: (state.plan?.isNotEmpty ?? false)
            ? state.plan
            : state.historicalPlan,
      );
      if (derived != null && derived.isNotEmpty) _stickyPlan = derived;
      _planCache = _stickyPlan;
    }
    return _planCache;
  }

  /// 「{模型} 正在思考」指示条件：会话在跑、还没有任何流式内容、
  /// 最后一条行是用户消息（服务端还没建助手行）——填住发出消息到
  /// 第一个字之间的空白期。
  /// 思考指示文案。两层判定：
  /// 1) 服务端权威：phase 运行中 + 无流式行 + 尾行是用户消息；
  /// 2) 本地兜底：消息已送达但服务端还没落 userInput 行（死区A，服务端
  ///    预热/排队慢时界面会空好几秒），也显示等待——仅在「网络较慢」
  ///    提示尚未点亮时生效，避免无限转圈掩盖真实故障。
  String? _thinkingLabel(
    ConversationState? state,
    List<Map<String, dynamic>> rows,
  ) {
    if (state == null) return null;
    if (rows.any((r) => r['state'] == 'streaming')) return null;
    final model = state.currentModel;
    final label = model.isEmpty ? '正在思考' : '$model 正在思考';
    final serverReady =
        state.isRunning &&
        (rows.isEmpty || '${rows.last['kind']}' == 'userInput');
    if (serverReady) return label;
    final waitingEcho = _visibleEchoes(
      rows,
    ).any((e) => e['status'] == 'sent' && e['slow'] != true);
    return waitingEcho ? label : null;
  }

  /// 流式中的行（借鉴 zcode-dev 的「流式区出列表」架构）：
  /// 列表内容在流式期间保持不变，逐帧锚定补偿退出主战场——
  /// BUG-27/28/32 家族的根因就是流式行在列表内逐帧长高。
  Map<String, dynamic>? _trailingStreamingRow(ConversationState? state) {
    final rows = state?.rows ?? const <Map<String, dynamic>>[];
    if (rows.isEmpty) return null;
    final last = rows.last;
    if (last['kind'] == 'assistantText' && last['state'] == 'streaming') {
      return last;
    }
    return null;
  }

  Widget _buildList(
    ConversationState? state, {
    Map<String, dynamic>? streamingRow,
  }) {
    // 在 build 期一次性取出 widget 依赖，供 itemBuilder 闭包捕获。
    //
    // 为什么必须缓存：ListView 的 itemBuilder 闭包会在**这一帧之后**被
    // SliverChildBuilderDelegate 异步回调（布局期懒构建）。若闭包内直接写
    // `widget.app.conv`，就是在回调时刻访问 `State.widget`——而那个时刻
    // 本 State 可能已经因为路由切换/会话切换被 dispose，框架内部校验会抛
    // RangeError（真机 2026-09-12 实证：每次进入会话必现
    // `RangeError (length): Only valid value is 0: 1`，堆栈指到
    // `transport: widget.app.conv` 这一行，但 try/catch 抓不到——因为抛错
    // 发生在 `widget` getter 的框架内部路径上，不是我们的表达式）。
    // 缓存后闭包只读局部变量，不再触碰 State 生命周期。
    final transport = widget.app.conv;
    // 同理缓存 sessionId：闭包回调时 State 可能已 dispose，读普通字段虽然
    // 不抛错，但闭包语义上应只依赖 build 时刻的快照。
    final sessionId = _sid ?? '';
    final rows0 = state?.rows ?? const <Map<String, dynamic>>[];
    // 流式行摘出列表（渲染在列表下方的 _StreamingPanel）：
    // 列表内容流式期间零变化，历史内容不再被逐帧顶动。
    final bool extracted = streamingRow != null &&
        rows0.isNotEmpty &&
        identical(rows0.last, streamingRow);
    final rows = extracted
        ? rows0.sublist(0, rows0.length - 1)
        : rows0;
    final echoes = _visibleEchoes(rows0);
    final thinking = _thinkingLabel(state, rows0);

    // 会话级出错：失败发生在模型调用前时服务端不建助手行，
    // 时间线什么都不渲染——在回复位补一张错误卡，错误不再隐形。
    final failedCard = (state != null && state.hasErrorPhase)
        ? ErrorCard(
            title: '本轮回复中断',
            detail:
                state.conversationError ?? '服务端把会话标记为出错，但没有带回错误详情。可下拉刷新或重发消息。',
          )
        : null;

    // 「还有 N 条更早 · 拉取全部」文案（空 = 已抽干，不显示入口）。
    final historyLabel = state == null
        ? ''
        : historyPullLabel(
            loaded: state.rows.length,
            total: state.totalCount,
            pulling: widget.app.historyPulling,
          );

    final headerCells = <Widget>[
      // 本机历史顶着的时候说清楚：内容可能比别的端旧（用户认可这个代价），
      // 服务端订阅一落地这行就自己消失。
      if (_onLocalSnapshot)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Center(
            child: GestureDetector(
              // 真连不上时点一下重试：有本机记录就不弹失败卡，出口留在这里。
              onTap: widget.app.chatError == null || widget.sessionId == null
                  ? null
                  : () => unawaited(widget.app.openSession(widget.sessionId!)),
              child: Text(
                widget.app.chatError == null
                    ? (widget.app.chatLoading ? '本机记录 · 正在同步…' : '本机记录')
                    : '本机记录 · 连不上服务端，点这里重试',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: widget.app.chatError == null ? ZT.inkFaint : ZT.rose,
                ),
              ),
            ),
          ),
        ),
      // 还有更早的没拉进来：给一个**显式**入口（用户裁定：一个会话几千条，
      // 不要一进来就全拉，要看全部自己点）。上滑翻页照旧一页一页来。
      if (historyLabel.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Center(
            child: GestureDetector(
              onTap: widget.app.historyPulling
                  ? null
                  : () => unawaited(widget.app.pullAllHistory()),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: ShapeDecoration(
                  color: ZT.bg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                    side: ZT.inkSide(w: 1, color: ZT.line),
                  ),
                ),
                child: Text(
                  historyLabel,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: ZT.inkSoft,
                  ),
                ),
              ),
            ),
          ),
        ),
      if (state?.loadingOlder == true)
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ZT.primary,
              ),
            ),
          ),
        ),
      _SessionHeader(state: state),
    ];

    final echoStart = thinking != null ? 1 : 0;
    final headCount = echoStart + echoes.length + (failedCard != null ? 1 : 0);
    // 全空（无行/无回显/无思考/无错误卡）：区分两种空（2026-09-14 用户报障
    // 「列表里明明有内容，打开却让我发第一条消息」）。取证结论：桌面端对该
    // 会话的行窗口返回空（订阅/拉行/重同步全部成功但 0 行），而列表索引里
    // 预览/总数明明有货——典型于会话正被桌面端占用（另一 agent 在跑）或由
    // CLI 创建、行流不归远端会话服务。此时"发第一条消息"是误导，改说真相。
    final showEmptyGuide =
        rows0.isEmpty && echoes.isEmpty && thinking == null && failedCard == null;
    final listedPreview = _listedPreviewFor(_sid ?? sessionId);
    final phantomEmpty = showEmptyGuide &&
        ((state?.totalCount ?? 0) > 0 || listedPreview.isNotEmpty);
    // itemCount 与 itemBuilder 闭包必须用**同一份** rows（本 build 的局部
    // 值）。此前闭包里重读 `rows` 字段：翻页/流式摘行让列表在 build 之后
    // 变短，老 itemCount 的 index 就越界（RangeError → 整个滑动失效）。
    final rowCount = rows.length;
    // 尾部槽位（历史行之后）统一收敛到一个列表：4px 空隙 + 头部格 + 空会话引导。
    // 这样 itemCount 与 itemBuilder 共用**同一个** tailCells.length，不会再
    // 出现"公式加了 +1、分支却按另一套偏移匹配"的错位。
    // 真机 2026-09-12 实证：空会话 + headerCells 只有 1 项时，末尾 index 落到
    // headerCells[1] 越界，抛 `RangeError (length): Only valid value is 0: 1`。
    final tailCells = <Widget>[
      const SizedBox(height: 4),
      ...headerCells,
      if (showEmptyGuide)
        Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Column(
              children: [
                Icon(
                  phantomEmpty
                      ? Icons.cloud_off_rounded
                      : Icons.waving_hand_rounded,
                  size: 30,
                  color: ZT.inkFaint,
                ),
                const SizedBox(height: 10),
                Text(
                  phantomEmpty
                      ? '这个会话的内容暂时刷不出来——它可能正被桌面端使用中。\n点右上角 ↻ 重试，或到桌面端查看。'
                      : '发第一条消息，开始这个会话',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: ZT.inkSoft),
                ),
              ],
            ),
          ),
        ),
    ];
    final itemCount = headCount + rowCount + tailCells.length;
    return RefreshIndicator(
      color: ZT.primaryDeep,
      onRefresh: _forceResync,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          // 手指按住/惯性滚动期间关掉自动回底；彻底停稳（end，且不再
          // 弹道滚动）再恢复。Click drivenScroll/ ballistic 也算用户态，
          // 避免动画刚结束又被新行拽回去。
          if (n is ScrollStartNotification && n.dragDetails != null) {
            _scrollingByUser = true;
          } else if (n is ScrollEndNotification) {
            _onScrollGestureEnd();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          reverse: true,
          // 默认 250px 的缓存区在几千条历史的会话里频繁 GC/重建，
          // maxScrollExtent 全靠 dead-reckoning 估算、每修正一次视口就
          // 跳一下（框架 RenderSliverList 的固有行为，无 scroll anchoring）。
          // 放大到 ~2.5 屏让翻页往复命中已布局区，估算修正大幅减少。
          scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // index 0 = 最底部（最新）。布局顺序（自底向上）：
            //   思考指示 → 回显 → 出错卡 → 历史行 → 4px 空隙 → 头部格
            // 空会话引导已并入 headerCells（见上方构建处），尾部只有
            // 一个统一的 tailCells 列表，index 与 itemCount 严格同源。
            if (index < headCount) {
              if (thinking != null && index == 0) {
                return _ThinkingIndicator(label: thinking);
              }
              if (index < echoStart + echoes.length) {
                final echo = echoes[echoes.length - 1 - (index - echoStart)];
                return _EchoBubble(
                  key: ValueKey(echo),
                  echo: echo,
                  transport: transport,
                  sessionId: sessionId,
                  onRetry: echo['status'] == 'failed'
                      ? () => _retryEcho(echo)
                      : null,
                  onRetryWithDefault: echo['status'] == 'failed'
                      ? () => unawaited(_retryEchoWithDefault(echo))
                      : null,
                );
              }
              return failedCard!;
            }
            var i = index - headCount;
            if (i < rowCount) {
              // 越界保护：itemCount 与 rows 理论上同帧，但翻页摘行的时序
              // 缝隙里可能出现 index 越界——给空卡片比 RangeError 好。
              if (i < 0 || i >= rows.length) {
                return const SizedBox.shrink();
              }
              final row = rows[rows.length - 1 - i];
              // 行级稳定 key：reverse 列表头部插入会让索引整体位移，
              // 无 key 时 Stateful 卡片（工具卡展开态/复制反馈）会跟着
              // 位置错位——key 按 rowId 让状态跟着内容走。
              final rowKey = row['rowId'] == null
                  ? null
                  : ValueKey<String>('row-${row['rowId']}');
              Widget card = buildRowCard(
                row,
                transport: transport,
                sessionId: sessionId,
                // 入场动画只给最新一行：旧行滚进视口时播动画会逆着
                // 滚动方向，观感就是"滑不动"（真机反馈后收窄）。
                entrance: i == rows.length - 1,
                onRowAction: (action) {
                  if (sessionId.isEmpty) return;
                  final rid = (row['rowId'] as num?)?.toInt() ?? 0;
                  final eid = '${row['entityId'] ?? row['turnId'] ?? ''}';
                  switch (action) {
                    case 'like':
                      _sendFeedback(sessionId, rid, eid, 'like');
                    case 'dislike':
                      _sendFeedback(sessionId, rid, eid, 'dislike');
                    case 'regenerate':
                      _retryTurn(sessionId, rid, eid);
                    case 'fork':
                      _forkFromHere(sessionId, rid, eid);
                  }
                },
              );
              if (rowKey != null) card = KeyedSubtree(key: rowKey, child: card);
              // 用户消息长按 → 本轮操作（重新生成）；
              // 助手回复长按 → 反馈（赞/踩）/ 重新生成本轮。
              final rowId = (row['rowId'] as num?)?.toInt();
              if (row['kind'] == 'userInput' && rowId != null) {
                card = GestureDetector(
                  onLongPress: () => _openRowActions(rowId, row),
                  child: card,
                );
              } else if (row['kind'] == 'assistantText' && rowId != null) {
                card = GestureDetector(
                  onLongPress: () => _openAssistantActions(rowId, row),
                  child: card,
                );
              }
              // 消息时间戳：跟随气泡对齐（用户右/助手左），淡色小字。
              final timeLabel = _rowTimeLabel(row);
              if (timeLabel != null) {
                final isUser = row['kind'] == 'userInput';
                card = Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    card,
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
                      child: Text(
                        timeLabel,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: ZT.inkFaint,
                        ),
                      ),
                    ),
                  ],
                );
              }
              return card;
            }
            i -= rows.length;
            if (i < 0 || i >= tailCells.length) {
              return const SizedBox.shrink();
            }
            return tailCells[i];
          },
        ),
      ),
    );
  }

  /// 下拉强制重同步：服务端按 forceSnapshot 重发全量（观感卡住时自救）。
  Future<void> _forceResync() async {    final chat = widget.app.chat;
    if (chat == null) return;
    try {
      await chat.forceResync();
      widget.app.log('[chat] 已请求重同步');
    } on Object {
      widget.app.log('[chat] 重同步失败');
    }
  }

  /// 已被 rows 确认的回显同帧移除（正式行同位置接上，无缝交接）；
  /// 失败的保留供重试（判定在 composer_logic）。派生按 (rows 实例,
  /// 回显版本) 缓存：流式期间每帧 build 不重算。
  List<Map<String, Object?>>? _echoCache;
  List<Map<String, dynamic>>? _echoCacheRows;
  int _echoCacheVersion = -1;

  List<Map<String, Object?>> _visibleEchoes(List<Map<String, dynamic>> rows) {
    if (_echoCache == null ||
        !identical(rows, _echoCacheRows) ||
        _echoCacheVersion != _echoesVersion) {
      _echoCacheRows = rows;
      _echoCacheVersion = _echoesVersion;
      _echoCache = visibleEchoes(_echoes, rows);
    }
    // 排队追加的消息不回显到聊天流：它已经在底部「排队中 N 条」栏里
    // 落座了，聊天里再飘一个气泡是重复信息（用户点单）。
    // 失败的例外：发送失败要能看到错误气泡并重试。
    return _echoCache!
        .where((e) => !(e['inQueue'] == true && e['status'] != 'failed'))
        .toList();
  }

  /// 底部栏：五槽位（模型 / 模式+权限 / 工具 / 计划 / 用量）+ 第 6 槽「任务」。
  /// 模式与权限合一个二段弹层（同模型+思考等级的编排）；
  /// 「任务」= 子代理活动 / 后台任务 / 定时任务 三 Tab 集合入口。
  Widget _composerBar(ConversationState? state) {
    final ratio = contextUsageRatio(state?.usage);
    final hasPlan = _stickyPlan?.isNotEmpty ?? false;
    final activityCount = _activityCount(state);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          _QuickSlot(
            icon: Icons.smart_toy_rounded,
            label: _curModel.isEmpty ? '模型' : _curModel,
            accent: ZT.primary,
            onTap: _openModelSheet,
          ),
          _QuickSlot(
            icon: Icons.tune_rounded,
            label: modeLabel(_curMode),
            accent: ZT.grape,
            onTap: _openModePermissionSheet,
          ),
          _QuickSlot(
            icon: Icons.handyman_rounded,
            label: '工具',
            accent: ZT.aqua,
            onTap: _sending ? null : () => _openInsertSheet(asTools: true),
          ),
          _QuickSlot(
            icon: Icons.account_tree_rounded,
            label: '计划',
            accent: hasPlan ? ZT.primary : ZT.inkSoft,
            onTap: _openPlanSheet,
          ),
          _QuickSlot(
            icon: Icons.data_usage_rounded,
            label: ratio == null ? '用量' : '${(ratio * 100).round()}%',
            accent: ratio == null
                ? ZT.inkFaint
                : ratio > 0.9
                ? ZT.rose
                : ratio > 0.7
                ? ZT.lemon
                : ZT.aqua,
            onTap: _openUsageSheet,
          ),
          _QuickSlot(
            icon: Icons.hub_rounded,
            label: '任务',
            accent: activityCount > 0 ? ZT.grape : ZT.inkSoft,
            badge: activityCount > 0 ? '$activityCount' : null,
            onTap: _openTasksPanelSheet,
          ),
        ],
      ),
    );
  }

  /// 活跃工作数（子代理活动 + 流式子代理）——「任务」槽角标。
  int _activityCount(ConversationState? state) {
    if (state == null) return 0;
    final live = parseSubagents(
      state.snapshot?['subagents'],
    ).where((s) => !s.stuck).length;
    return live +
        streamingAgentToolCalls(state.rows).length +
        parseActiveWorks(
          state.control,
        ).where((w) => w.kind != 'primaryTurn').length +
        streamingSubagents(state.rows).length;
  }

  /// 文件变更弹层：本会话 agent 改动过的文件（conversationFileChangesV4）。
  bool _rewindBusy = false;

  /// 回滚最近回合的文件改动：先预览数量 → 确认 → 行级 CAS 提交。
  Future<void> _rewindLastTurn(BuildContext sheetCtx, String sid) async {
    if (_rewindBusy) return;
    _rewindBusy = true;
    try {
      final preview = await widget.app.fileRewindPreview(sid);
      if (!mounted) return;
      final count = preview.length;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: 1.6),
          ),
          title: const Text(
            '回滚文件',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          content: Text(
            count == 0
                ? '预览为空：该回合的改动可能已回滚过。仍要提交回滚吗？'
                : '将把最近回合的 $count 个文件改动恢复为回合前状态。继续？',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消', style: TextStyle(color: ZT.inkSoft)),
            ),
            BigButton(
              label: '回滚',
              onPressed: () => Navigator.pop(dialogCtx, true),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      requireAccepted(await widget.app.applyFileRewind(sid));
      if (!mounted) return;
      if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
      flashMessage(context, '文件已回滚到回合前状态');
      // 时间线与文件状态都可能变了：强制重同步一次。
      unawaited(_forceResync());
    } on Object catch (e) {
      if (!mounted) return;
      flashMessage(context, '回滚失败：$e', error: true);
    } finally {
      _rewindBusy = false;
    }
  }

  void _openFileChangesSheet() {
    final sid = _sid;
    if (sid == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: widget.app.fileChanges(sid),
            builder: (context, snap) {
              final Widget body;
              if (snap.connectionState != ConnectionState.done) {
                body = const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                    child: CircularProgressIndicator(color: ZT.primary),
                  ),
                );
              } else if (snap.hasError) {
                body = Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '加载失败：${briefRpcError(snap.error)}',
                    style: const TextStyle(fontSize: 12.5, color: ZT.rose),
                  ),
                );
              } else {
                final changes = [
                  for (final c in snap.data ?? const <Map<String, dynamic>>[])
                    if (describeFileChange(c) case (final row?)) row,
                ];
                if (changes.isEmpty) {
                  body = const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      '最近回合没有文件变更',
                      style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
                    ),
                  );
                } else {
                  body = Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: changes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, i) {
                        final (path, action, stats) = changes[i];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 9,
                          ),
                          decoration: ShapeDecoration(
                            color: ZT.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: ZT.inkSide(w: 1.2),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: ShapeDecoration(
                                  color: action == '删除'
                                      ? ZT.rose.withValues(alpha: 0.12)
                                      : action == '新建'
                                      ? ZT.aqua.withValues(alpha: 0.12)
                                      : ZT.lemon.withValues(alpha: 0.2),
                                  shape: const StadiumBorder(),
                                ),
                                child: Text(
                                  action,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: action == '删除'
                                        ? ZT.rose
                                        : action == '新建'
                                        ? ZT.aqua
                                        : ZT.primaryDeep,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  path,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (stats.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  stats,
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: ZT.inkFaint,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  );
                }
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZT.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '文件变更（最近回合）',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  body,
                  if (sid.isNotEmpty && (snap.data?.isNotEmpty ?? false)) ...[
                    const SizedBox(height: 12),
                    BigButton(
                      label: '回滚本回合文件',
                      icon: Icons.history_rounded,
                      onPressed: () => unawaited(_rewindLastTurn(sheetCtx, sid)),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 执行计划弹层：列表一滑就看不见了，这里随时能看。
  void _openPlanSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: ZT.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7,
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.app, widget.app.chat?.state]),
            builder: (sheetCtx, _) {
              // 和消息列表同一套粘性缓存：滑走了计划也不丢。
              final plan = _resolvePlan(_state);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ZT.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (plan == null || plan.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        '还没有执行计划 —— agent 接到任务后会列出步骤',
                        style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
                      ),
                    )
                  else
                    Flexible(
                      child: SingleChildScrollView(
                        child: PlanPanel(steps: plan),
                      ),
                    ),
                  if (_sid != null) ...[
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _openFileChangesSheet();
                        },
                        icon: const Icon(
                          Icons.history_edu_rounded,
                          size: 16,
                          color: ZT.aqua,
                        ),
                        label: const Text(
                          '查看本会话文件变更',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: ZT.aqua,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildComposer(ConversationState? state) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: ZT.surface,
          border: Border(top: BorderSide(width: 1.4, color: ZT.line)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_picked.isNotEmpty)
              _AttachmentBar(
                files: _picked,
                onRemove: (f) => setState(() => _forgetAttachment(f)),
              ),
            // `/` `$` 联想条：整段输入是 token 时出现。
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (context, value, _) {
                final suggestions = buildSuggestions(
                  value.text,
                  widget.app.skills,
                  widget.app.slashCommands,
                );
                if (suggestions.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in suggestions)
                        _TokenChip(
                          prefix: s.isSkill ? r'$' : '/',
                          label: s.label,
                          description: s.description,
                          accent: s.isSkill ? ZT.grape : ZT.aqua,
                          onTap: () => _insertToken('${s.token} '),
                        ),
                    ],
                  ),
                );
              },
            ),
            // 第一行：图片 · 附件 · 输入框 · 圆形发送键（对齐官方布局）。
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _sending ? null : _openInsertSheet,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: ZT.tapMin,
                      minHeight: ZT.tapMin,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.add_rounded,
                      size: 26,
                      color: _sending ? ZT.inkFaint : ZT.ink,
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 14, height: 1.4),
                    decoration: InputDecoration(
                      hintText: '给 ZCode 发送消息…',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      filled: true,
                      fillColor: ZT.bg,
                    ),
                  ),
                ),
                if (state?.canStop == true) ...[
                  _PauseOrResume(
                    paused: state!.goalPaused,
                    onTap: _pauseResume,
                  ),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 8),
                // 按钮亮灭跟输入逐字刷新；不挂在页面重建上——
                // 空闲时服务器不推状态，打字点不亮按钮。
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, _) => _SendOrStop(
                    canStop: state?.canStop == true,
                    busy: _sending,
                    hasText: value.text.trim().isNotEmpty || _picked.isNotEmpty,
                    onSend: () {
                      HapticFeedback.selectionClick();
                      _send();
                    },
                    onStop: () {
                      HapticFeedback.mediumImpact();
                      _stop();
                    },
                  ),
                ),
              ],
            ),
            _composerBar(state),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _anchorAnimTimer?.cancel();
    // 解除本会话的 phase 权威覆盖，任务卡回到 index 权威。
    final sid = _sid ?? widget.sessionId;
    if (sid != null) widget.app.clearLivePhase(sid);
    // 没发完的话暂存草稿，回来不丢；发空了就清掉。
    final key = _sid ?? 'draft';
    widget.app.stashDraft(key, _input.text.trim());
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }
}

/// 待发送附件条（缩略图/文件名 + 移除）。
class _AttachmentBar extends StatelessWidget {
  final List<PlatformFile> files;
  final void Function(PlatformFile) onRemove;

  const _AttachmentBar({required this.files, required this.onRemove});

  /// 点缩略图预览：收集当前选中的所有图片进画廊，左右滑动翻上一张/
  /// 下一张，定位到点的那张；只有一张时退回单图查看。
  Future<void> _openPreview(BuildContext context, PlatformFile tapped) async {
    final images = <Uint8List>[];
    var idx = 0;
    for (final f in files) {
      final isImg =
          isImageExt(f.extension ?? '') || sniffImageMime(f.bytes) != null;
      if (!isImg) continue;
      Uint8List? b = f.bytes;
      if (b == null && f.path != null) {
        try {
          b = await File(f.path!).readAsBytes();
        } on Object {
          continue; // 这张读不出来就跳过
        }
      }
      if (b == null || b.isEmpty) continue;
      if (identical(f, tapped)) idx = images.length;
      images.add(b);
    }
    if (!context.mounted) return;
    if (images.length > 1) {
      openImageGallery(
        context,
        images,
        initialIndex: idx.clamp(0, images.length - 1),
      );
    } else if (images.isNotEmpty) {
      openImageViewer(context, bytes: images.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: ZT.inkSide(w: 1, color: ZT.line),
        ),
      ),
      child: SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          // 图再多也能横向滑（AlwaysScrollable：内容不满一屏也有滚动反馈）。
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          itemCount: files.length,
          separatorBuilder: (_, _) => const SizedBox(width: 7),
          itemBuilder: (context, i) {
            final f = files[i];
            // 扩展名定不出的相册图靠魔数嗅探兜底，缩略图/图标二选一不误判。
            final isImage =
                isImageExt(f.extension ?? '') ||
                sniffImageMime(f.bytes) != null;
            final path = f.path;
            // 图片只给缩略图（不带名字）：选图阶段一眼核对内容就够了。
            if (isImage && (path != null || f.bytes != null)) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  GestureDetector(
                    onTap: () => _openPreview(context, f),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: path != null
                          ? Image.file(
                              File(path),
                              width: 52,
                              height: 52,
                              fit: BoxFit.cover,
                              cacheWidth: (52 * dpr).round(),
                              errorBuilder: (_, _, _) => Container(
                                width: 52,
                                height: 52,
                                color: ZT.surface,
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.image_rounded,
                                  size: 24,
                                  color: ZT.primary,
                                ),
                              ),
                            )
                          : Image.memory(
                              f.bytes!,
                              width: 52,
                              height: 52,
                              fit: BoxFit.cover,
                              cacheWidth: (52 * dpr).round(),
                              errorBuilder: (_, _, _) => Container(
                                width: 52,
                                height: 52,
                                color: ZT.surface,
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.image_rounded,
                                  size: 24,
                                  color: ZT.primary,
                                ),
                              ),
                            ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onRemove(f),
                      child: Container(
                        padding: const EdgeInsets.all(2.5),
                        decoration: const ShapeDecoration(
                          color: ZT.ink,
                          shape: CircleBorder(
                            side: BorderSide(width: 1.2, color: ZT.bg),
                          ),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 11,
                          color: ZT.onInk,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }
            return Container(
              padding: const EdgeInsets.all(5),
              decoration: ShapeDecoration(
                color: ZT.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: ZT.inkSide(w: 1, color: ZT.line),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isImage
                        ? Icons.image_rounded
                        : Icons.insert_drive_file_rounded,
                    size: 26,
                    color: isImage ? ZT.primary : ZT.aqua,
                  ),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (f.size > 0)
                          Text(
                            fileSizeLabel(f.size),
                            style: TextStyle(fontSize: 10, color: ZT.inkFaint),
                          ),
                      ],
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onRemove(f),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: ZT.rose,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets

/// 上下文窗口：进度条 + used / max（解析已在协议层 contextWindowUsage）。
/// 服务端给 autoCompactThresholdTokens 时附阈值提示（常为 null，隐藏）。
class _UsageContext extends StatelessWidget {
  final ({num used, num max})? window;
  final String Function(num) fmt;
  final int? threshold;

  const _UsageContext({
    required this.window,
    required this.fmt,
    this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    final w = window;
    if (w == null) return const SizedBox.shrink();
    final max = w.max;
    final used = w.used;
    final threshold = this.threshold;
    final ratio = (used / max).clamp(0.0, 1.0);
    final color = ratio > 0.9
        ? ZT.rose
        : ratio > 0.7
        ? ZT.lemon
        : ZT.aqua;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '上下文窗口',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                '${(ratio * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: ZT.line,
              color: color,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '${fmt(used)} / ${fmt(max)} tokens',
            style: const TextStyle(fontSize: 12, color: ZT.inkSoft),
          ),
          if (threshold != null) ...[
            const SizedBox(height: 4),
            Text(
              '自动压缩阈值 ≈ ${fmt(threshold)} tokens',
              style: const TextStyle(fontSize: 11, color: ZT.inkFaint),
            ),
          ],
        ],
      ),
    );
  }
}

/// 缓存命中率卡：服务端已算好 latestHitRate（最近一次调用）与
/// hitRate（会话平均，含统计请求数）；字段缺失整卡隐藏。
class _UsageCache extends StatelessWidget {
  final Map<String, dynamic>? cache;

  const _UsageCache({required this.cache});

  @override
  Widget build(BuildContext context) {
    final summary = usageCacheSummary(cache);
    if (summary == null) return const SizedBox.shrink();
    String? pct(double? v) =>
        v == null ? null : '${(v * 100).toStringAsFixed(1)}%';
    final latest = pct(summary.latest);
    final average = pct(summary.average);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bolt_rounded, size: 15, color: ZT.aqua),
              SizedBox(width: 6),
              Text(
                '缓存命中率',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(child: _hitCell('最近一次调用', latest, ZT.aqua)),
              const SizedBox(width: 10),
              Expanded(child: _hitCell('会话平均', average, ZT.primaryDeep)),
            ],
          ),
          if (summary.requests != null) ...[
            const SizedBox(height: 7),
            Text(
              '按 ${summary.requests} 次请求统计 · 命中越高，重复上下文越省',
              style: const TextStyle(fontSize: 11, color: ZT.inkFaint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hitCell(String label, String? pct, Color color) {
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: ZT.inkSide(w: 1.1, color: ZT.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint),
          ),
          const SizedBox(height: 3),
          Text(
            pct ?? '—',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: pct == null ? ZT.inkFaint : color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 上下文构成卡：breakdown 各来源字符数 + 占比条（服务端按快照估算）。
/// 空列表整卡隐藏。
class _UsageBreakdown extends StatelessWidget {
  final Object? breakdown;
  final String Function(num) fmt;

  const _UsageBreakdown({required this.breakdown, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final rows = contextBreakdownRows(breakdown);
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.donut_small_rounded, size: 15, color: ZT.grape),
              SizedBox(width: 6),
              Text(
                '上下文构成（估算）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 9),
          for (final (label, chars, share) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: ZT.inkSoft,
                          ),
                        ),
                      ),
                      Text(
                        '${fmt(chars)} 字符 · ${(share * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: ZT.inkFaint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: share.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: ZT.line,
                      color: ZT.grape,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 累计用量：cumulative 是动态结构，逐键展示。
class _UsageCumulative extends StatelessWidget {
  final Map<String, dynamic> usage;
  final String Function(num) fmt;

  const _UsageCumulative({required this.usage, required this.fmt});

  String _pretty(Object? v) {
    if (v is num) return fmt(v);
    if (v is Map) {
      return v.entries
          .map(
            (e) =>
                '${e.key}: ${e.value is num ? fmt(e.value as num) : e.value}',
          )
          .join('  ·  ');
    }
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final cumulative = usage['cumulative'];
    final rows = <MapEntry<String, String>>[];
    if (cumulative is Map) {
      cumulative.forEach((k, v) {
        if (v is Map) {
          v.forEach((k2, v2) => rows.add(
            MapEntry(cumulativeKeyLabel('$k.$k2'), _pretty(v2)),
          ));
        } else {
          rows.add(MapEntry(cumulativeKeyLabel('$k'), _pretty(v)));
        }
      });
    } else if (cumulative != null) {
      rows.add(MapEntry('cumulative', _pretty(cumulative)));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '累计 Token',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 7),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 键名给弹性（未知键可能很长），值恒短给右对齐。
                  Expanded(
                    child: Text(
                      r.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    r.value,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets

class _DegradedBanner extends StatelessWidget {
  final String reason;
  final VoidCallback? onReconnect;

  const _DegradedBanner({required this.reason, this.onReconnect});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ZT.lemon,
      child: InkWell(
        onTap: onReconnect,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              const PulseDot(color: ZT.rose, animate: true, size: 7),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '连接不稳（$reason）—— 点此重连',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: ZT.ink,
                  ),
                ),
              ),
              if (onReconnect != null)
                const Icon(Icons.refresh_rounded, size: 16, color: ZT.ink),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  final ConversationState? state;

  const _SessionHeader({required this.state});

  @override
  Widget build(BuildContext context) {
    final window = state?.contextWindowUsage;
    String? usageLine;
    if (window != null) {
      usageLine = '上下文 ${window.used.toInt()} / ${window.max.toInt()} tokens';
    }
    final model = state?.currentModel;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: ShapeDecoration(
              color: ZT.bg,
              shape: StadiumBorder(side: ZT.inkSide(w: 1.1, color: ZT.line)),
            ),
            child: Text(
              [
                if (model != null && model.isNotEmpty) model,
                ?usageLine,
              ].join(' · '),
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: ZT.inkFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EchoBubble extends StatelessWidget {
  final Map<String, Object?> echo;
  final VoidCallback? onRetry;

  /// 失败时的退路动作：切回首选默认（GLM）再重试。null 不显示。
  final VoidCallback? onRetryWithDefault;

  final ConversationV4? transport;
  final String sessionId;

  const _EchoBubble({
    super.key,
    required this.echo,
    this.onRetry,
    this.onRetryWithDefault,
    this.transport,
    this.sessionId = '',
  });

  @override
  Widget build(BuildContext context) {
    final status = '${echo['status']}';
    final failed = status == 'failed';
    final delivered = status == 'sent';
    final text = '${echo['text'] ?? ''}';
    final files =
        (echo['files'] as List?)?.whereType<PlatformFile>().toList() ??
        const <PlatformFile>[];
    final rawError = '${echo['error'] ?? ''}';
    final friendlyError = failed ? friendlySendError(rawError) : '';
    final stage = '${echo['stage'] ?? ''}';
    final queued = echo['queued'] == true;
    final slow = echo['slow'] == true;
    return Padding(
      padding: const EdgeInsets.only(left: 44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 图片独立块（与正式消息同款微信式编排）：本地字节直显，
          // 上传阶段就能预览，无底色。
          ...imageBlocks(
            echo['attachments'],
            transport: transport,
            sessionId: sessionId,
            maxW: MediaQuery.of(context).size.width * 0.82,
          ),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
            decoration: ShapeDecoration(
              color: failed
                  ? ZT.rose.withValues(alpha: 0.14)
                  : ZT.ink.withValues(alpha: 0.72),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(ZT.radius),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(ZT.radius),
                  bottomRight: Radius.circular(ZT.radius),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 图片拿不到编排（早期失败）时退回 64px 本地缩略图。
                if ((echo['attachments'] as List?)?.isEmpty ??
                    true && files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [for (final f in files) _EchoThumb(file: f)],
                    ),
                  ),
                if (text.isNotEmpty)
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: failed ? ZT.rose : ZT.onInk,
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status == 'sending') ...[
                      const SizedBox(
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: ZT.onInk,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          queued
                              ? '连接恢复中，消息已排队'
                              : (stage.isEmpty ? '发送中' : stage),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: ZT.onInk),
                        ),
                      ),
                      if (slow) ...[
                        const SizedBox(width: 6),
                        const Flexible(
                          child: Text(
                            '响应较慢',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: ZT.onInk,
                            ),
                          ),
                        ),
                      ],
                    ],
                    if (delivered) ...[
                      const Icon(Icons.check, size: 12, color: ZT.onInk),
                      const SizedBox(width: 3),
                      const Text(
                        '已送达',
                        style: TextStyle(fontSize: 10, color: ZT.onInk),
                      ),
                    ],
                    if (failed) ...[
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              friendlyError,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: ZT.rose,
                              ),
                            ),
                            if (rawError.isNotEmpty &&
                                rawError != friendlyError)
                              Text(
                                rawError,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: ZT.rose.withValues(alpha: 0.7),
                                ),
                              ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: onRetry,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: const Text(
                          '重试',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (onRetryWithDefault != null)
                        TextButton(
                          onPressed: onRetryWithDefault,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          child: const Text(
                            '切 GLM 重试',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: ZT.aqua,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 消息已受理但服务端还没建任何助手行时的「思考中」占位。
class _ThinkingIndicator extends StatelessWidget {
  final String label;

  const _ThinkingIndicator({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, right: 10),
      child: Row(
        children: [
          const PulseDot(color: ZT.primary, animate: true),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: ZT.inkFaint,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 回显气泡里的本地附件缩略图（发送中预览）。
class _EchoThumb extends StatelessWidget {
  final PlatformFile file;

  const _EchoThumb({required this.file});

  @override
  Widget build(BuildContext context) {
    final ext = (file.extension ?? '').toLowerCase();
    // 无后缀相册图靠魔数兜底，别退化成灰色图标。
    final isImage = isImageExt(ext) || sniffImageMime(file.bytes) != null;
    final Widget content;
    if (isImage && file.path != null) {
      content = Image.file(
        File(file.path!),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.image_rounded, size: 26, color: ZT.primary),
      );
    } else if (isImage && file.bytes != null) {
      content = Image.memory(
        file.bytes!,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.image_rounded, size: 26, color: ZT.primary),
      );
    } else {
      content = const Icon(
        Icons.insert_drive_file_rounded,
        size: 26,
        color: ZT.aqua,
      );
    }
    final viewable = isImage && (file.path != null || file.bytes != null);
    return GestureDetector(
      onTap: viewable ? () => _openLocalViewer(context) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 64,
          height: 64,
          color: ZT.bg,
          alignment: Alignment.center,
          child: content,
        ),
      ),
    );
  }

  /// 点本地图片缩略图看原图（本地文件路径入缓存）。
  void _openLocalViewer(BuildContext context) {
    final filePath = file.path;
    openImageViewer(
      context,
      file: filePath != null ? File(filePath) : null,
      bytes: file.bytes,
      attachmentRef: filePath != null ? 'local:$filePath' : null,
    );
  }
}

/// 暂停/继续按钮：运行中亮柠檬（暂停），已暂停亮青（继续）。圆形小一号，次于停止键。
class _PauseOrResume extends StatelessWidget {
  final bool paused;
  final VoidCallback onTap;

  const _PauseOrResume({required this.paused, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: ShapeDecoration(
          color: paused ? ZT.aqua : ZT.lemon,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(21)),
            side: BorderSide(width: 1.8, color: ZT.ink),
          ),
          shadows: ZT.hard(dx: 2.5, dy: 2.5),
        ),
        child: Icon(
          paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          color: ZT.ink,
          size: 24,
        ),
      ),
    );
  }
}

/// 发送 / 停止按钮；按下沉进阴影里，松手弹回。
class _SendOrStop extends StatefulWidget {
  final bool canStop;
  final bool busy;
  final bool hasText;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendOrStop({
    required this.canStop,
    required this.busy,
    required this.hasText,
    required this.onSend,
    required this.onStop,
  });

  @override
  State<_SendOrStop> createState() => _SendOrStopState();
}

class _SendOrStopState extends State<_SendOrStop> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // 跑动中：空手 → 停止；打了字/选了附件 → 发送（走排队/插队弹窗），
    // 否则 agent 一跑起来就没法追加消息了。
    if (widget.canStop && !widget.hasText) {
      return GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onStop,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: ZT.tapMin,
          height: ZT.tapMin,
          transform: Matrix4.translationValues(
            _pressed ? 2.5 : 0,
            _pressed ? 2.5 : 0,
            0,
          ),
          decoration: ShapeDecoration(
            color: ZT.rose,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.tapMin / 2),
              side: ZT.inkSide(w: 1.8),
            ),
            shadows: _pressed ? const [] : ZT.hard(dx: 2.5, dy: 2.5),
          ),
          child: const Icon(Icons.stop_rounded, color: Colors.white, size: 26),
        ),
      );
    }
    final enabled = widget.hasText && !widget.busy;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: enabled ? widget.onSend : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        width: ZT.tapMin,
        height: ZT.tapMin,
        transform: Matrix4.translationValues(
          enabled && _pressed ? 2.5 : 0,
          enabled && _pressed ? 2.5 : 0,
          0,
        ),
        decoration: ShapeDecoration(
          color: enabled ? ZT.primary : ZT.line,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.tapMin / 2),
            side: ZT.inkSide(w: 1.8, color: enabled ? ZT.ink : ZT.inkFaint),
          ),
          shadows: enabled && !_pressed ? ZT.hard(dx: 2.5, dy: 2.5) : const [],
        ),
        child: widget.busy
            ? const Padding(
                padding: EdgeInsets.all(13),
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: ZT.inkSoft,
                ),
              )
            : Icon(
                Icons.arrow_upward_rounded,
                color: enabled ? Colors.white : ZT.inkFaint,
                size: 24,
              ),
      ),
    );
  }
}

// ---------------------------------------------------------- interactions

class _InteractionsPanel extends StatelessWidget {
  final ConversationState state;
  final ZApp app;

  const _InteractionsPanel({required this.state, required this.app});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: ZT.bg,
        border: Border(top: BorderSide(width: 1.4, color: ZT.lemon)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      // 封顶 + 内部滚动：多条交互堆叠时不再无限挤压列表视口
      //（与流式面板同款治理，BUG-38 家族）。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final interaction in state.pendingInteractions)
              InteractionCard(
                // 稳定 key：pendingInteractions 每帧都是新拷贝，无 key 时
                // 同一交互的 State 会在刷新中被误判换卡。
                key: ValueKey<String>('ia-${interaction['interactionId'] ?? ''}'),
                interaction: interaction,
                onResolve: ({optionId, freeText, action, content}) {
                  final sessionId = app.chat?.sessionId;
                  if (sessionId == null) return Future.value(null);
                  return app
                      .resolveInteraction(
                        sessionId,
                        '${interaction['interactionId'] ?? ''}',
                        optionId: optionId,
                        freeText: freeText,
                        action: action,
                        content: content,
                      )
                      .then((value) => null);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<void> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  })
  onResolve;

  const InteractionCard({
    super.key,
    required this.interaction,
    required this.onResolve,
  });

  @override
  State<InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<InteractionCard> {
  bool _busy = false;
  final _freeTextController = TextEditingController();

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } on Object catch (e) {
      if (mounted) {
        flashMessage(context, '操作失败: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;
    final isPermission = kind == 'permission';
    final accent = isPermission ? ZT.primary : ZT.grape;

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 6),
      padding: const EdgeInsets.all(11),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shadows: ZT.hard(dx: 3, dy: 3, color: accent.withValues(alpha: 0.45)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6, color: accent),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPermission ? Icons.verified_user_rounded : Icons.help_rounded,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  isPermission
                      ? '权限请求 · ${payload['toolName'] ?? ''}'
                      : 'ZCode 需要你的输入',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (isPermission && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '${payload['summary']}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: ZT.inkSoft,
                ),
              ),
            ),
          if (!isPermission && payload['prompt'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '${payload['prompt']}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: ZT.inkSoft,
                ),
              ),
            ),
          const SizedBox(height: 9),
          if (options is List && options.isNotEmpty)
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final option in options)
                  if (option is Map)
                    _OptionChip(
                      label: permissionOptionLabel(option),
                      accent: accent,
                      busy: _busy,
                      onTap: () => isPermission
                          ? _resolve(optionId: '${option['optionId']}')
                          : _resolve(action: 'accept', content: const {}),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _QuestionsView(
              questions: questions.whereType<Map>().toList(),
              // 有题目时，"其他"入口下放到每题内部；无题目才用底部整块输入框。
              allowFreeText: freeText,
              busy: _busy,
              onResolve: (payload) => _resolve(
                action: '${payload['action'] ?? 'accept'}',
                content: (payload['content'] as Map?)?.cast<String, dynamic>(),
              ),
            ),
          // 顶层 freeText 且没有 questions 时才用整块输入框——有题目时
          // 每题自带「其他…」，再来一个全局框会让人以为要填两遍。
          if (freeText && (questions is! List || questions.isEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _freeTextController,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '输入回复…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _OptionChip(
                    label: '发送',
                    accent: accent,
                    busy: _busy,
                    onTap: () =>
                        _resolve(freeText: _freeTextController.text.trim()),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _freeTextController.dispose();
    super.dispose();
  }
}

class _OptionChip extends StatelessWidget {
  final String label;
  final Color accent;
  final bool busy;
  final VoidCallback onTap;

  const _OptionChip({
    required this.label,
    required this.accent,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: accent,
          shadows: ZT.hard(dx: 2, dy: 2, color: ZT.ink.withValues(alpha: 0.3)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(w: 1.4),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 多题问答视图（AskUserQuestion）。
///
/// 契约来自 2026-09-11 探针实测，三个关键点与旧实现不同：
///   1. 回传形状是 `{action:'accept', content:{answers:[{question, selected:[…]}]}}`
///      —— 数组，不是 map。旧实现发 map，服务端收不到。
///   2. `multiSelect` 是题目级字段，必须读——旧实现无条件单选，
///      点第二个会覆盖第一个（用户的"多选失效"就是这个）。
///   3. 自由文本入口由 **payload 顶层 `freeText`** 控制，不是选项级字段；
///      旧实现只在「无 questions」分支渲染，题目下没有入口。
///
/// 选项用 `value` 做标识（实测无 optionId）；题干做键（实测无 id）。
class _QuestionsView extends StatefulWidget {
  final List<Map> questions;

  /// 顶层 payload.freeText：为 true 时每题显示「其他…」输入入口。
  final bool allowFreeText;
  final bool busy;
  final void Function(Map<String, dynamic> payload) onResolve;

  const _QuestionsView({
    required this.questions,
    required this.allowFreeText,
    required this.busy,
    required this.onResolve,
  });

  @override
  State<_QuestionsView> createState() => _QuestionsViewState();
}

class _QuestionsViewState extends State<_QuestionsView> {
  late List<AskQuestion> _qs;
  late List<AskAnswer> _answers;
  late List<TextEditingController> _others;

  /// 哪一题的「其他…」输入框展开着（-1 表示都没展开）。
  int _otherOpen = -1;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    _qs = [for (final q in widget.questions) AskQuestion.fromMap(q)];
    _answers = [for (var i = 0; i < _qs.length; i++) const AskAnswer()];
    _others = [
      for (var i = 0; i < _qs.length; i++) TextEditingController(),
    ];
  }

  @override
  void didUpdateWidget(covariant _QuestionsView old) {
    super.didUpdateWidget(old);
    // 交互**内容**变了才重置作答。不能用实例身份比较：pendingInteractions
    // 每次读取都是 castMapList 的新拷贝，任意一次页面刷新（流式帧/定时器/
    // 键盘）都会让身份比较失败 → _rebuild 清空已选/已填 → 选项点不动、
    // 输入被清空、提交恒灰（真机 2026-09-12 实证"完全无法交互"）。
    final sameInteraction =
        jsonEncode(old.questions) == jsonEncode(widget.questions) &&
        old.allowFreeText == widget.allowFreeText;
    if (!sameInteraction) {
      for (final c in _others) {
        c.dispose();
      }
      _rebuild();
      _otherOpen = -1;
    }
  }

  @override
  void dispose() {
    for (final c in _others) {
      c.dispose();
    }
    super.dispose();
  }

  void _pick(int qi, String value) {
    final q = _qs[qi];
    setState(() {
      _answers[qi] = _answers[qi].toggle(value, multiSelect: q.multiSelect);
    });
  }

  void _toggleOther(int qi) {
    setState(() => _otherOpen = _otherOpen == qi ? -1 : qi);
  }

  void _submit() {
    widget.onResolve(
      buildAskAnswersPayload(questions: _qs, answers: _answers),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !widget.busy && allAnswered(_answers);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var qi = 0; qi < _qs.length; qi++) _questionBlock(qi),
        const SizedBox(height: 10),
        Row(
          children: [
            if (widget.allowFreeText)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '可多选可填其他',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: ZT.inkSoft.withValues(alpha: 0.75),
                  ),
                ),
              ),
            const Spacer(),
            _OptionChip(
              label: '提交',
              accent: ZT.grape,
              busy: !canSubmit,
              onTap: _submit,
            ),
          ],
        ),
      ],
    );
  }

  Widget _questionBlock(int qi) {
    final q = _qs[qi];
    final a = _answers[qi];
    return Padding(
      padding: EdgeInsets.only(top: qi == 0 ? 6 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  q.question.isEmpty ? q.header : q.question,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 多选标记：让用户一眼知道这题能选几个。
              Container(
                margin: const EdgeInsets.only(top: 1),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: ShapeDecoration(
                  color: q.multiSelect
                      ? ZT.grape.withValues(alpha: 0.12)
                      : ZT.bg,
                  shape: StadiumBorder(
                    side: ZT.inkSide(
                      w: 1.1,
                      color: q.multiSelect ? ZT.grape : ZT.inkSoft,
                    ),
                  ),
                ),
                child: Text(
                  q.multiSelect ? '多选' : '单选',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: q.multiSelect ? ZT.grape : ZT.inkSoft,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final o in q.options)
            _optionRow(
              label: o.label,
              description: o.description,
              picked: a.selected.contains(o.value),
              multi: q.multiSelect,
              onTap: widget.busy ? null : () => _pick(qi, o.value),
            ),
          if (widget.allowFreeText) ...[
            const SizedBox(height: 2),
            _otherRow(qi, a),
          ],
        ],
      ),
    );
  }

  /// 选项行：整行可点（≥48dp 触控），左侧勾选框表明选中态。
  /// 旧实现用 StadiumBorder 小 chip，垂直 padding 仅 5px（高约 21dp），
  /// 远低于 48dp 触控标准，且没有水波纹反馈。
  Widget _optionRow({
    required String label,
    required String description,
    required bool picked,
    required bool multi,
    required VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: ShapeDecoration(
            color: picked ? ZT.grape.withValues(alpha: 0.1) : ZT.bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
              side: ZT.inkSide(
                w: picked ? 1.5 : 1.2,
                color: picked ? ZT.grape : ZT.inkSoft,
              ),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: ZT.tapMin),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 多选用方框、单选用圆圈——形状本身就是提示。
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        picked
                            ? (multi
                                ? Icons.check_box_rounded
                                : Icons.radio_button_checked_rounded)
                            : (multi
                                ? Icons.check_box_outline_blank_rounded
                                : Icons.radio_button_unchecked_rounded),
                        size: 17,
                        color: picked ? ZT.grape : ZT.inkSoft,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                              color: picked ? ZT.grape : ZT.ink,
                            ),
                          ),
                          if (description.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                description,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.35,
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
        ),
      ),
    );
  }

  /// 「其他…」入口：点了才展开输入框，避免占满屏幕。
  Widget _otherRow(int qi, AskAnswer a) {
    final open = _otherOpen == qi || a.other.isNotEmpty;
    if (!open) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: ShapeDecoration(
              color: ZT.bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
                side: ZT.inkSide(w: 1.2, color: ZT.inkSoft),
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: widget.busy ? null : () => _toggleOther(qi),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: ZT.tapMin),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.edit_rounded, size: 16, color: ZT.inkSoft),
                      SizedBox(width: 8),
                      Text(
                        '其他…',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: ZT.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _others[qi],
            enabled: !widget.busy,
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(fontSize: 12.5),
            onChanged: (v) => setState(() {
              // 保留已选选项，只替换自由文本。
              _answers[qi] = _answers[qi].copyWith(other: v);
            }),
            decoration: InputDecoration(
              isDense: true,
              hintText: '输入你的答案…',
              hintStyle: const TextStyle(fontSize: 12),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: ZT.inkSide(w: 1.2, color: ZT.inkSoft),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: ZT.inkSide(w: 1.5, color: ZT.grape),
              ),
              fillColor: ZT.bg,
              filled: true,
            ),
          ),
          if (a.other.trim().isNotEmpty || _otherOpen == qi)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.busy ? null : () => _toggleOther(qi),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text(
                  '收起',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: ZT.inkSoft,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------- config sheet

/// 选项当前值判断：value 相等，或 model 值以 `/current` 结尾。
bool _optionIsCurrent(Map option, String current) {
  final value = '${option['value'] ?? option['name'] ?? ''}';
  if (value == current) return true;
  if (current.isNotEmpty && value.endsWith('/$current')) return true;
  return false;
}

/// 模型二级选择：一级供应商（手风琴展开），二级该供应商下的模型，点选即关。
/// 模型二级选择：一级供应商（手风琴展开），二级模型。
/// 点选不关弹层（先选模型再选思考等级），底部「完成」或点弹层外空白关闭。
/// 思考等级词表实时跟随所选模型：服务端切完模型会把该模型的词表
/// （config.thoughtLevels）推进快照，这里直接读快照，不再用
/// prepareWorkspace 的静态缓存（那是工作区当前模型的词表，常张冠李戴）。
class _ModelSheet extends StatefulWidget {
  final ZApp app;
  final String currentProvider;
  final String currentModel;
  final String currentThought;
  final Future<void> Function(Map option) onPick;
  final Future<void> Function(Map option) onPickThought;

  const _ModelSheet({
    required this.app,
    required this.currentProvider,
    required this.currentModel,
    required this.currentThought,
    required this.onPick,
    required this.onPickThought,
  });

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String? _expanded;

  /// 草稿模式（无会话态）下的本地高亮：选中暂存本地，发送时落库。
  String? _draftPick; // provider/model value
  String? _draftThoughtPick;

  /// 切换在途：防连点，期间思考区提示刷新中。
  bool _switching = false;

  /// provider → 模型选项组，打开弹层时算一次（弹层生命周期内选项不变）。
  late final Map<String, List<Map>> _groups;

  @override
  void initState() {
    super.initState();
    // 当前供应商默认展开。
    _expanded = widget.currentProvider.isEmpty ? null : widget.currentProvider;
    final groups = <String, List<Map>>{};
    for (final o in widget.app.configOptionList('model')) {
      final (prov, _) = splitModelValue('${o['value'] ?? ''}');
      final named = '${o['modelProviderName'] ?? ''}'.trim();
      final key = named.isNotEmpty ? named : prov;
      groups.putIfAbsent(key, () => []).add(o);
    }
    _groups = groups;
  }

  ConversationState? get _st => widget.app.chat?.state;

  /// 实时当前值：会话快照就绪时以服务端为准（切换后乐观补丁立即可见）；
  /// 草稿/无会话退回打开瞬间值 + 本地草稿选择。
  String get _liveModel {
    final st = _st;
    if (st != null && st.ready && st.currentModel.isNotEmpty) {
      return st.currentModel;
    }
    final dp = _draftPick;
    if (dp != null && dp.isNotEmpty) return dp.split('/').last;
    return widget.currentModel;
  }

  String get _liveProvider {
    final st = _st;
    if (st != null && st.ready && st.currentProvider.isNotEmpty) {
      return st.currentProvider;
    }
    final dp = _draftPick;
    if (dp != null && dp.contains('/')) {
      return dp.substring(0, dp.lastIndexOf('/'));
    }
    return widget.currentProvider;
  }

  String get _liveThought {
    final st = _st;
    if (st != null && st.ready) return st.currentThought; // 可能为空=模型默认
    return _draftThoughtPick ?? widget.currentThought;
  }

  /// 思考等级行：快照 thoughtLevels 优先（所选模型的真实词表），
  /// 缺失退回 prepareWorkspace 缓存。
  List<Map> _thoughtRows() {
    final cfg = _st?.snapshot?['config'];
    final levels = cfg is Map ? cfg['thoughtLevels'] : null;
    if (levels is List && levels.isNotEmpty) {
      return [
        for (final lv in levels)
          {'value': '$lv', 'name': thoughtLevelLabel('$lv')},
      ];
    }
    return widget.app.configOptionList('thought_level');
  }

  Future<void> _pick(Map option) async {
    if (_switching) return;
    final st = _st;
    if (st == null || !st.ready) {
      setState(() => _draftPick = '${option['value'] ?? ''}');
    }
    setState(() => _switching = true);
    try {
      await widget.onPick(option);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _pickThought(Map option) async {
    if (_switching) return;
    final st = _st;
    if (st == null || !st.ready) {
      setState(() => _draftThoughtPick = _optionValue(option));
    }
    setState(() => _switching = true);
    try {
      await widget.onPickThought(option);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  static String _optionValue(Map o) => '${o['value'] ?? o['name'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.app, ?_st]),
      builder: (context, _) {
        final groups = _groups;
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ZT.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Icon(Icons.smart_toy_rounded, size: 18, color: ZT.primary),
                    SizedBox(width: 8),
                    Text(
                      '模型',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                const Text(
                  '选模型 → 选思考等级，点「完成」或弹层外空白关闭',
                  style: TextStyle(fontSize: 11.5, color: ZT.inkFaint),
                ),
                const SizedBox(height: 10),
                if (groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6, bottom: 4),
                    child: Text(
                      '（暂无可用模型）',
                      style: TextStyle(fontSize: 12.5, color: ZT.inkFaint),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final entry in groups.entries)
                          _providerSection(entry.key, entry.value),
                        ..._thoughtSection,
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                BigButton(
                  label: _switching ? '切换中…' : '完成',
                  icon: Icons.check_rounded,
                  expand: true,
                  onPressed: _switching
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 思考等级区：点选生效不关弹层；词表随所选模型实时刷新。
  List<Widget> get _thoughtSection {
    final rows = _thoughtRows();
    if (rows.isEmpty) return const [];
    final current = _liveThought;
    return [
      const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 6),
        child: Row(
          children: [
            Icon(Icons.psychology_rounded, size: 15, color: ZT.grape),
            SizedBox(width: 6),
            Text(
              '思考等级',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: ZT.inkSoft,
              ),
            ),
          ],
        ),
      ),
      if (_switching)
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            '已切换模型，思考等级刷新中…',
            style: TextStyle(fontSize: 11, color: ZT.inkFaint),
          ),
        ),
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final o in rows)
            GestureDetector(
              onTap: _switching ? null : () => _pickThought(o),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: ShapeDecoration(
                  color: _optionValue(o) == current ? ZT.grape : ZT.surface,
                  shape: StadiumBorder(
                    side: ZT.inkSide(
                      w: 1.2,
                      color: _optionValue(o) == current ? ZT.grape : ZT.line,
                    ),
                  ),
                ),
                child: Text(
                  '${o['name'] ?? _optionValue(o)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: _optionValue(o) == current
                        ? Colors.white
                        : ZT.inkSoft,
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  Widget _providerSection(String provider, List<Map> models) {
    final open = _expanded == provider;
    final isCur = provider == _liveProvider;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: Ink(
              decoration: ShapeDecoration(
                color: open || isCur ? ZT.surface : ZT.bg,
                shadows: open
                    ? ZT.hard(
                        dx: 2,
                        dy: 2,
                        color: ZT.ink.withValues(alpha: 0.2),
                      )
                    : const [],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(ZT.radius),
                  side: ZT.inkSide(
                    w: open || isCur ? 1.5 : 1.2,
                    color: isCur ? ZT.primaryDeep : ZT.ink,
                  ),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(ZT.radius),
                onTap: () => setState(() => _expanded = open ? null : provider),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.dns_rounded,
                        size: 16,
                        color: isCur ? ZT.primaryDeep : ZT.inkSoft,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          provider,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: isCur ? ZT.primaryDeep : ZT.ink,
                          ),
                        ),
                      ),
                      Text(
                        '${models.length} 个模型',
                        style: const TextStyle(
                          fontSize: 11,
                          color: ZT.inkFaint,
                        ),
                      ),
                      const SizedBox(width: 7),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: const Icon(
                          Icons.expand_more,
                          size: 17,
                          color: ZT.inkFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(top: 7, left: 4, right: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final o in models)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _modelRow(o),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _modelRow(Map option) {
    final (prov, model) = splitModelValue('${option['value'] ?? ''}');
    final selected =
        _optionIsCurrent(option, _liveModel) && prov == _liveProvider;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: selected ? ZT.primary.withValues(alpha: 0.14) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(
              w: selected ? 1.5 : 1.2,
              color: selected ? ZT.primaryDeep : ZT.line,
            ),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: _switching ? null : () => _pick(option),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${option['name'] ?? model}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? ZT.primaryDeep : ZT.ink,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: ZT.primaryDeep,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 联想/插入共用的小胶囊：前缀符号着色 + 名称 + 截断描述。
class _TokenChip extends StatelessWidget {
  final String prefix;
  final String label;
  final String description;
  final Color accent;
  final VoidCallback onTap;

  const _TokenChip({
    required this.prefix,
    required this.label,
    required this.description,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: ZT.surface,
          shape: StadiumBorder(side: ZT.inkSide(w: 1.2, color: accent)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  prefix,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: ZT.inkFaint,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹层内分组小标题（图标 + 粗体小字）。
class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// 二段弹层的可选项药丸（模式/权限共用）。
class _ModePill extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ModePill({
    required this.label,
    required this.value,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: ShapeDecoration(
          color: selected ? accent.withValues(alpha: 0.14) : ZT.surface,
          shape: StadiumBorder(
            side: ZT.inkSide(
              w: selected ? 1.6 : 1.2,
              color: selected ? accent : ZT.line,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.trim(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: selected ? accent : ZT.inkSoft,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 4),
              Icon(Icons.check_rounded, size: 13, color: accent),
            ],
          ],
        ),
      ),
    );
  }
}

/// 底部快捷槽位：圆角图标块 + 下方小字标签，六格等宽铺满一行。
class _QuickSlot extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback? onTap;
  final String? badge;

  const _QuickSlot({
    required this.icon,
    required this.label,
    this.accent = ZT.inkSoft,
    this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Badge(
                isLabelVisible: badge != null,
                label: Text(badge ?? ''),
                backgroundColor: ZT.grape,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: ShapeDecoration(
                    color: ZT.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                      side: ZT.inkSide(w: 1.2),
                    ),
                  ),
                  child: Icon(icon, size: 22, color: accent),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: ZT.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选项行：整行等宽，选中打勾 —— 文字长短不一也对齐。
class _OptionRow extends StatelessWidget {
  final Map option;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  /// 可选前导图标（附件三入口用，对齐参考端的相机/相册/文件夹）。
  final IconData? icon;

  const _OptionRow({
    required this.option,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final name =
        '${option['name'] ?? option['value'] ?? option['optionId'] ?? ''}';
    // Ink 画到 Material 上层，涟漪才能盖住底色。
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: ZT.inkSide(
              w: selected ? 1.5 : 1.2,
              color: selected ? accent : ZT.line,
            ),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: selected ? accent : ZT.inkSoft),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected ? accent : ZT.ink,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 16, color: accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
