import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/constants.dart';
import '../protocol/conversation.dart';
import '../protocol/link_params.dart';
import '../protocol/relay_client.dart';
import '../protocol/remote_session.dart';
import '../services/notification_service.dart';
import 'automation_view.dart';
import 'history_logic.dart';
import 'model_defaults.dart';
import 'notification_logic.dart';
import 'session_open_logic.dart';
import 'task_sort.dart';
import 'usage_stats.dart';

/// 路径分隔（Windows / POSIX 都认）——每次调用都编译 RegExp 太浪费。
final _pathSeparators = RegExp(r'[\\/]');

/// App brain: relay link → workspace bridge → task list → chat session.
class ZApp extends ChangeNotifier with WidgetsBindingObserver {
  ZApp() {
    unawaited(_loadWorkspacePrefs());
    unawaited(_loadSessionModels());
    unawaited(_loadSessionApprovalModes());
    unawaited(_purgeLegacyRemovedTaskIds());
    unawaited(_loadDrafts());
    // token ticker 生命周期监听延迟初始化，避免测试环境无 binding
  }

  Timer? _tokenTicker;
  bool _appInForeground = true;
  bool _tickerInited = false;

  /// 前台操作在途计数（切项目 / 打开会话）。
  int _foregroundOps = 0;

  /// 被"让路"挡下的后台工作键，前台空闲后补跑一次。
  final _deferredBackground = <String>{};

  /// 前台是否忙。桌面端的 channel RPC 走同一个队——实测一次"排空暴发"里
  /// 4 个 getTaskTokenUsage 和用户的 subscribeConversationV4 一起等了 5.1s，
  /// 即用户点开会话时可能正排在我们自己的后台补拉后面。所以前台忙时**不发**，
  /// 空闲再补：不改服务端行为，只把队列让给用户。
  bool get _foregroundBusy => _foregroundOps > 0;

  /// 把一次前台操作包起来：期间后台工作让路，结束后补跑被挡下的那些。
  Future<T> _asForeground<T>(Future<T> Function() body) async {
    _foregroundOps++;
    try {
      return await body();
    } finally {
      _foregroundOps--;
      if (_foregroundOps == 0) _runDeferredBackground();
    }
  }

  /// 后台任务统一闸门。返回 false = 这次别发，已记账等空闲补跑。
  bool _backgroundGate(String key) {
    if (!_foregroundBusy) return true;
    _deferredBackground.add(key);
    return false;
  }

  /// 前台空闲了，把刚才被挡下的后台工作补一遍。都是幂等的重取，
  /// 补跑最多比原计划晚一次前台操作的时长。
  void _runDeferredBackground() {
    if (_deferredBackground.isEmpty) return;
    final keys = _deferredBackground.toList();
    _deferredBackground.clear();
    for (final key in keys) {
      switch (key) {
        case 'tokens':
          unawaited(_fetchTaskTokens());
        case 'models':
          unawaited(reconcileTaskModels());
        case 'prep':
          unawaited(loadPrep());
        case 'skills':
          unawaited(loadSkills());
        case 'archived':
          unawaited(loadArchivedTasks());
      }
    }
  }

  void _ensureTokenTicker() {
    if (_tickerInited) return;
    _tickerInited = true;
    // 生命周期监听：只在前台刷新 token 角标，省电
    WidgetsBinding.instance.addObserver(this);
    _tokenTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_appInForeground) {
        refreshTaskTokens();
      }
    });
    // 全局任务事件轮询：不受前台门控——用户切去玩手机时正是它要工作的
    // 时候（任何项目的会话报错/完成都要弹通知）。
    _pollTicker = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_pollGlobalTaskEvents());
    });
  }

  /// 在 connect() 等实际使用时调用，确保 ticker 已启动
  void _maybeStartTokenTicker() => _ensureTokenTicker();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (_appInForeground) {
      // 回前台立即刷一次
      refreshTaskTokens();
    }
  }

  LinkParams? params;
  RemoteSession? session;
  RelayState relayState = RelayState.idle;
  String? failure;
  bool connecting = false;

  List<Map<String, dynamic>> workspaces = [];
  Map<String, dynamic>? workspace;
  Bridge? bridge;
  ConversationV4? conv;
  IndexSubscription? indexSub;
  bool openingWorkspace = false;

  /// `zcode-task.listTasks` 结果 + sessions-index 合并后的任务卡数据。
  /// `pinned` 字段来自 listPinnedTasks 合并。
  List<Map<String, dynamic>> tasks = [];
  bool tasksLoading = false;

  /// 「全部对话」视图：整机任务（bootstrap 的 tasks[]，跨全部项目）。
  /// 它不是当前项目的数据——切视图只换数据源，不动当前项目的桥。
  List<Map<String, dynamic>> allProjectTasks = [];

  /// 列表页当前是否处于「全部对话」视图。
  bool viewingAllProjects = false;

  /// 冷启动默认进「全部对话」（用户裁定：每次进来显示全部会话）。
  /// 只在配对页发起的全新连接里消费一次；之后用户手动进项目、就地
  /// 重连（keepShell）都不再强制，尊重当前视图。
  bool _openAllProjectsOnConnect = true;

  /// 列表页真正展示的数据源：单项目视图 / 全部对话视图的**唯一分岔点**。
  List<Map<String, dynamic>> get listedTasks =>
      viewingAllProjects ? allProjectTasks : tasks;

  /// 删除进行中的会话（taskId → 发起时刻）：乐观隐藏层，**只在内存**。
  /// 删除是双通道 RPC，服务端处理有延迟——期间列表与索引帧合并不得把卡
  /// 复活。但它不是事实源：对账（`sweepDeletions`）发现服务端仍保留该
  /// 会话时恢复显示——会话列表以服务端为准（多端一致性批次）。
  final _deletingTasks = <String, DateTime>{};

  /// 重命名后 index 标题滞后时的本地覆盖。
  final _titleOverrides = <String, String>{};

  /// 跨项目置顶的本地待确认记录（taskId → pinned）。
  /// 服务端 setTaskPinned 是**带项目 scope** 的，而「全部对话」视图里当前桥属于
  /// 另一个项目——先把用户意图记在本地，让两个视图立刻一致，等服务端状态追上来再撤。
  /// **故意不持久化**：它是乐观层不是权威，重启即清，免得本地状态长期压着服务端。
  final _pinOverrides = <String, bool>{};

  ConvSubscription? chat;
  bool chatLoading = false;

  /// 打开会话失败的**真实原因**（null = 没失败）。页面据此显示「订阅失败/重试」。
  ///
  /// 不能拿 `chat == null` 当失败判据：乐观切换期间用户已经在聊天页里，
  /// 而切桥/订阅还没走完——那时 `chat` 也是 null，页面就会闪一屏
  /// 「会话订阅失败」（用户实测反馈）。只有这里非空才算真失败。
  String? chatError;

  /// prepareWorkspace 的 configOptions / slashCommands 缓存。
  bool prepLoading = false;
  String? prepError;
  Map<String, dynamic> prep = const {};
  List<Map<String, dynamic>> _slashCommands = const [];

  /// skills.list 结果（composer `$` 技能触发）。
  List<Map<String, dynamic>> skills = const [];

  final logs = <String>[];

  /// 未发送草稿暂存（sessionId → 文本，新会话用 'draft'）；进出聊天页不丢字。
  /// 持久化到 SharedPreferences：App 被系统杀掉也不丢打了一半的话。
  final drafts = <String, String>{};

  /// 暂存草稿并落盘（空文本 = 清除该会话草稿）。
  Future<void> stashDraft(String key, String text) {
    if (text.isEmpty) {
      drafts.remove(key);
    } else {
      drafts[key] = text;
    }
    return _saveDraftsToDisk();
  }

  /// 取走草稿（进入聊天页消费），并同步落盘删除。
  String takeDraft(String key) {
    final v = drafts.remove(key) ?? '';
    unawaited(_saveDraftsToDisk());
    return v;
  }

  Future<void> _saveDraftsToDisk() async {
    try {
      final sp = await SharedPreferences.getInstance();
      // 单条 64KB 封顶：防粘贴超长文本把 SharedPreferences 撑爆。
      final safe = <String, String>{
        for (final e in drafts.entries)
          if (e.value.length <= 64 * 1024) e.key: e.value,
      };
      await sp.setString('drafts', jsonEncode(safe));
    } on Object catch (e) {
      log('[draft] 草稿持久化失败: $e');
    }
  }

  Future<void> _loadDrafts() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('drafts');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          drafts
            ..clear()
            ..addEntries([
              for (final e in decoded.entries)
                if (e.value is String) MapEntry('${e.key}', e.value as String),
            ]);
        }
      }
    } on Object catch (e) {
      log('[draft] 草稿读取失败: $e');
    }
  }

  /// 会话最后显式选择的模型（sessionId → {provider,model,thought}）。
  /// 本地持久化：服务端若没把切换落进会话配置（重启后快照回默认），
  /// 打开会话时按本地记录补发落库。
  final sessionModels = <String, Map<String, dynamic>>{};

  Future<void> _loadSessionModels() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('sessionModels');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          sessionModels
            ..clear()
            ..addEntries([
              for (final e in decoded.entries)
                if (e.value is Map)
                  MapEntry(
                    '${e.key}',
                    (e.value as Map).cast<String, dynamic>(),
                  ),
            ]);
        }
      }
    } on Object catch (e) {
      log('[config] 模型持久化读取失败: $e');
    }
  }

  /// 记录/覆盖会话的模型选择并落盘（失败只记日志，内存值仍生效）。
  Future<void> recordSessionModel(
    String sessionId,
    Map<String, dynamic> cfg,
  ) async {
    if (sessionId.isEmpty || '${cfg['model'] ?? ''}'.isEmpty) return;
    sessionModels[sessionId] = Map<String, dynamic>.from(cfg);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('sessionModels', jsonEncode(sessionModels));
    } on Object catch (e) {
      log('[config] 模型持久化写入失败: $e');
    }
  }

  /// 弃用旧版持久化墓碑库（removedTaskIds）：它曾让本机永久隐藏服务端
  /// 还活着的会话，多端各存一份必然各说各话。删除已改为「进行中 + 对账」
  /// （见 `_deletingTasks`），列表以服务端为准——启动即弃旧库。
  Future<void> _purgeLegacyRemovedTaskIds() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getString('removedTaskIds');
      if (legacy == null) return;
      await sp.remove('removedTaskIds');
      var n = 0;
      final decoded = jsonDecode(legacy);
      if (decoded is List) n = decoded.length;
      log('[task] 已弃用旧持久化墓碑（$n 条）——列表回归服务端权威');
    } on Object catch (e) {
      log('[task] 旧墓碑库清理失败: $e');
    }
  }

  /// 会话最后显式选择的权限模式（sessionId → 正式 id）。
  /// 服务端 config 不回显 approvalMode 或词汇表外时，权限面板用它兜底高亮。
  final sessionApprovalModes = <String, String>{};

  Future<void> _loadSessionApprovalModes() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('sessionApprovalModes');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          sessionApprovalModes
            ..clear()
            ..addEntries([
              for (final e in decoded.entries)
                if (e.value is String) MapEntry('${e.key}', e.value as String),
            ]);
        }
      }
    } on Object catch (e) {
      log('[approval] 权限模式持久化读取失败: $e');
    }
  }

  /// 记录/覆盖会话的权限模式并落盘（失败只记日志，内存值仍生效）。
  Future<void> recordApprovalMode(String sessionId, String mode) async {
    if (sessionId.isEmpty || mode.isEmpty) return;
    sessionApprovalModes[sessionId] = mode;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        'sessionApprovalModes',
        jsonEncode(sessionApprovalModes),
      );
    } on Object catch (e) {
      log('[approval] 权限模式持久化写入失败: $e');
    }
  }

  /// 日志版本号：日志窗只听这个——每行日志不再把整个 app 通知一遍。
  final logsRevision = ValueNotifier<int>(0);

  StreamSubscription? _pushSub;

  // ------------------------------------------------------------- plumbing

  void log(String line) {
    logs.add('${DateTime.now().toIso8601String().substring(11, 19)} $line');
    if (logs.length > 300) logs.removeRange(0, logs.length - 300);
    logsRevision.value++;
  }

  /// 连接远端链接：解析 → 配对 → bootstrap → 自动开桥。
  /// [keepShell] = true 时不清空旧列表（就地重连用），见 [disconnect]。
  Future<void> connect(String raw, {bool keepShell = false}) async {
    _maybeStartTokenTicker();
    final params = LinkParams.parse(raw.trim());
    if (params == null) {
      failure = '链接无法解析：需要 zcode.z.ai/remote/v4?sid=…&hash=… 的完整链接';
      notifyListeners();
      throw const FormatException('bad link');
    }
    await disconnect(silent: true, keepShell: keepShell);
    this.params = params;
    failure = null;
    // 用户主动在连，别再钉在配对页上。
    _pairPageRequested = false;
    notifyListeners();
    log('[app] 连接 ${params.deviceName ?? 'desktop'} (${params.deviceMid})');
    final session = RemoteSession(params, onLog: log);
    this.session = session;
    // 断线重连成功 → 与服务端对账（BUG-34）。
    session.onRePaired = _reconcileAfterRePair;
    void onRelay() {
      final prev = relayState;
      relayState = session.relay.state;
      // 意外终止提醒：连着的时候断了、且知道有任务在跑 → 弹一条。
      // （桌面端崩溃/断网正是用户点单的"意外终止"场景——此时轮询也断了，
      // 只有这条即时提醒能告诉用户任务状态未知。）
      if ((relayState == RelayState.reconnecting ||
              relayState == RelayState.error) &&
          prev == RelayState.paired &&
          _pollPhases.values.any((s) => s == 'running') &&
          _shouldNotify('#link#')) {
        NotificationService.showTaskEvent(
          id: 'link-drop'.hashCode & 0x7fffffff,
          title: '连接中断',
          body: '与桌面端的连接断了，有任务正在跑；恢复连接后会自动对账',
        );
      }
      notifyListeners();
    }

    session.relay.stateListenable.addListener(onRelay);
    _onRelayChanged = onRelay;
    _pushSub = session.workspaceListUpdated.listen((result) {
      if (result is Map && result['workspaces'] is List) {
        workspaces = (result['workspaces'] as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        notifyListeners();
      }
    });
    connecting = true;
    notifyListeners();
    try {
      await session.connect();
      await session.waitPaired(timeout: const Duration(seconds: 45));
      final bootstrap = await session.bootstrap();
      final list = bootstrap['workspaces'];
      workspaces = list is List
          ? list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : [];
      // bootstrap 顺带带回整机任务列表——「全部对话」的数据源，先存下来，
      // 用户切到那个视图时就不用再等一次往返。
      allProjectTasks = _applyPinsAndSort(
        parseBootstrapTasks(bootstrap['tasks']),
      );
      log('[app] bootstrap: ${workspaces.length} 个工作区');
      // 连上了：列表不再是只读快照，卡片恢复可点。
      _disconnectedKeptShell = false;
      connecting = false;
      notifyListeners();
      // 工作区选择策略：记住上次用的优先，其次唯一工作区自动开，
      // 多个且没用过时留给选择页。
      final stored = _lastWorkspaceKey;
      Map<String, dynamic>? picked;
      if (stored != null) {
        for (final w in workspaces) {
          if (workspaceKeyOf(w) == stored) {
            picked = w;
            break;
          }
        }
      }
      if (picked == null && workspaces.length == 1) {
        picked = workspaces.first;
      }
      if (picked != null) {
        await openWorkspace(picked);
      }
      // 冷启动默认进「全部对话」：bootstrap 已带回整机任务列表（上面
      // 408 行），切视图零开销。只对配对页发起的全新连接生效——就地
      // 重连（keepShell）不动用户当前视图；标记只消费一次。
      if (_openAllProjectsOnConnect && !keepShell) {
        _openAllProjectsOnConnect = false;
        viewingAllProjects = true;
        notifyListeners();
      }
    } on Object catch (e) {
      connecting = false;
      failure = '$e';
      notifyListeners();
      rethrow;
    }
  }

  void Function()? _onRelayChanged;

  /// 就地重连中：根 widget 要留在主壳，别把用户甩回配对页。
  bool _inPlaceReconnect = false;

  /// 用户主动要求去配对页（抽屉里的「去连接」）。
  bool _pairPageRequested = false;

  /// 就地断开过：连接已拆、列表作为只读快照留着。
  /// 单独记这个标记而不是只判 `session == null`——后者语义是"还没连过"，
  /// 会误伤（裸 ZApp 的 widget 测试就没 session，但它期望卡片能点开）。
  bool _disconnectedKeptShell = false;

  /// 就地重连中（会话页顶部提示「重连中…」用）。
  bool get reconnectingInPlace => _inPlaceReconnect;

  /// 列表当前是只读快照：就地断开后、或正在就地重连（桥还没挂上）。
  /// 这两种情况下卡片点开只会得到一个空聊天页，所以 UI 直接挡掉。
  bool get isReadOnlySnapshot => _disconnectedKeptShell || _inPlaceReconnect;

  /// 根 widget 该显示主壳还是配对页。
  ///
  /// 只要还有内容（工作区 / 工作区列表），或正在**就地重连**，就留在主壳——
  /// 「重新连接」和「断开连接」都不该把人甩回连接页。只有用户主动点了
  /// 「去连接」、或压根没有可显示的内容时才回配对页。
  bool get showMainShell =>
      !_pairPageRequested &&
      (workspace != null || workspaces.isNotEmpty || _inPlaceReconnect);

  /// 抽屉「去连接」：显式回配对页换链接。
  /// （断开后我们不再自动跳过去，所以必须留这个入口，否则换不了链接。）
  void openPairPage() {
    if (_pairPageRequested) return;
    _pairPageRequested = true;
    notifyListeners();
  }

  /// 关闭当前连接（换链接 / 退出）。
  ///
  /// [keepShell] = true：只拆连接，**保留工作区与列表内容**，让用户留在会话页
  /// ——「断开连接」和「就地重连」都走这条。列表此时是只读的历史快照
  /// （`session == null`，卡片点击会被 UI 挡掉）。
  Future<void> disconnect({bool silent = false, bool keepShell = false}) async {
    if (!silent) log('[app] 断开连接');
    unawaited(_pushSub?.cancel());
    _pushSub = null;
    if (_onRelayChanged != null) {
      session?.relay.stateListenable.removeListener(_onRelayChanged!);
      _onRelayChanged = null;
    }
    await _disposeBridgeStack();
    await session?.dispose();
    session = null;
    if (!keepShell) {
      // 彻底断开：清空全部内容，根 widget 自然回落到配对页。
      workspaces = [];
      workspace = null;
      tasks = [];
      archivedTasks = [];
      allProjectTasks = [];
      viewingAllProjects = false;
      automations = [];
      usageStats = null;
      _lastPhases.clear();
      _lastWaiting.clear();
      _phaseWatchPrimed = false;
      // 派生缓存全部让位服务端：重连后全量重拉，本地不留任何压在服务端
      // 上的事实（多端一致性批次）。彻底断开 = 下次连接是全新进入，
      // 冷启动「全部对话」默认重新生效。
      _deletingTasks.clear();
      _archivedTaskIds.clear();
      _titleOverrides.clear();
      _openAllProjectsOnConnect = true;
      _taskTokens.clear();
      _taskTokensAt.clear();
      _tokenSampleLogged = false;
      _livePhase.clear();
      prep = const {};
      _slashCommands = const [];
    }
    if (!silent) {
      // 只有"用户主动断开 + 保留列表"才算只读快照；就地重连走的 silent
      // 路径不算（那个由 _inPlaceReconnect 表示）。
      if (keepShell) _disconnectedKeptShell = true;
      relayState = RelayState.idle;
      notifyListeners();
    }
  }

  /// 断线重连成功后的**状态对账**（BUG-34）。
  ///
  /// 触发场景：桌面端崩溃重启、网络闪断后 relay 重新配对。桥恢复只是
  /// 链路层——数据层全是崩溃前的旧账，不清就会一直错下去：
  /// ① `_livePhase` 相位覆盖（服务端全新了，覆盖还写着 running）；
  /// ② 会话/索引订阅（服务端订阅已随崩溃消失，等 watchdog 最长 5 分钟）；
  /// ③ 任务列表（本地快照陈旧）。
  /// 原则：突发事故后一切以服务端为准，本地覆盖全部让路。
  Future<void> _reconcileAfterRePair() async {
    log('[app] 重连成功：与桌面端对账');
    // ① 相位覆盖 & 通知基线清账（基线重录，避免误报通知）。
    _livePhase.clear();
    _lastPhases.clear();
    _lastWaiting.clear();
    _phaseWatchPrimed = false;
    if (tasks.isNotEmpty) {
      tasks = _composeVisibleTasks(tasks);
      allProjectTasks = _applyPinsAndSort(allProjectTasks);
    }
    notifyListeners();
    // ② 订阅强制重同步：崩溃后服务端订阅大概率已不存在，resync 按
    // logEpoch/seq 要快照重放；要不上来就靠 ③ 的兜底重订阅。
    unawaited(chat?.forceResync());
    unawaited(indexSub?.forceResync());
    // ③ 任务列表全量重拉。
    unawaited(loadTasks());
    if (viewingAllProjects) unawaited(loadAllProjectTasks());
    // 兜底：4s 后会话还没有任何行 → resync 没救活（服务端订阅确实没了），
    // 整条重订阅。openSession 会换新订阅对象，UI 闪一下但状态是权威的。
    final sid = chat?.sessionId;
    if (sid != null) {
      Timer(const Duration(seconds: 4), () async {
        final st = chat?.state;
        if (chat == null || chat!.sessionId != sid) return;
        if (st == null || st.rows.isEmpty) {
          log('[app] 重同步未恢复会话 $sid，整条重订阅');
          try {
            await openSession(sid);
          } on Object catch (e) {
            log('[app] 重订阅失败: $e');
          }
        }
      });
    }
  }

  /// 断线后手动重连：用当前链接重走 connect（断开→重配对→重开桥）。
  ///
  /// 全程留在会话页：`_inPlaceReconnect` 让根 widget 不回落配对页，
  /// `keepShell` 让旧列表保留到新 bootstrap 回来为止。
  Future<void> reconnect() async {    final raw = params?.source.toString();
    if (raw == null || raw.isEmpty) {
      throw StateError('没有可重连的链接');
    }
    _inPlaceReconnect = true;
    notifyListeners();
    try {
      await connect(raw, keepShell: true);
    } on Object {
      // 重连失败：列表降级成只读快照（顶部提示"已断开"）。此时 session 对象
      // 还在（connect 里先建后连），光判 session==null 会漏掉这种"假活"状态。
      _disconnectedKeptShell = true;
      rethrow;
    } finally {
      _inPlaceReconnect = false;
      notifyListeners();
    }
  }

  /// 回前台立即探测链路；死了马上触发重连，不等心跳超时。
  /// relay 层会自己判断，空闲/已关闭状态下是 no-op。
  void pokeRelay() {
    session?.pokeRelay();
  }

  /// 工作区本地别名（key → 别名）：协议没有重命名文件夹的接口，
  /// 重命名只在 App 端显示层生效。
  final _workspaceAliases = <String, String>{};

  String? _lastWorkspaceKey;

  Future<void> _loadWorkspacePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('workspaceAliases');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _workspaceAliases
            ..clear()
            ..addEntries([
              for (final e in decoded.entries)
                if (e.value is String && '${e.key}'.isNotEmpty)
                  MapEntry('${e.key}', e.value as String),
            ]);
        }
      }
      final last = sp.getString('lastWorkspaceKey');
      if (last != null && last.isNotEmpty) _lastWorkspaceKey = last;
    } on Object catch (e) {
      log('[workspace] 工作区偏好读取失败: $e');
    }
  }

  Future<void> _saveWorkspaceAliases() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('workspaceAliases', jsonEncode(_workspaceAliases));
    } on Object catch (e) {
      log('[workspace] 工作区别名写入失败: $e');
    }
  }

  Future<void> _saveLastWorkspaceKey(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('lastWorkspaceKey', key);
    } on Object {
      // 非关键，失败静默
    }
  }

  /// 工作区显示名：本地别名优先，否则路径尾段/键名。
  String workspaceDisplayName(Map<String, dynamic> w) {
    final key = workspaceKeyOf(w);
    final alias = key != null ? _workspaceAliases[key] : null;
    if (alias != null && alias.trim().isNotEmpty) return alias.trim();
    return workspaceTitle(w);
  }

  /// 重命名工作区（本地别名）。
  Future<void> renameWorkspace(String key, String alias) async {
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      _workspaceAliases.remove(key);
    } else {
      _workspaceAliases[key] = trimmed;
    }
    notifyListeners();
    await _saveWorkspaceAliases();
  }

  String? workspaceKeyOf(Map<String, dynamic> w) {
    final identity = w['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = w['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    for (final key in const ['workspaceKey', 'key', 'id']) {
      final v = w[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  String workspaceTitle(Map<String, dynamic> w) {
    final key = workspaceKeyOf(w);
    final alias = key != null ? _workspaceAliases[key] : null;
    if (alias != null && alias.trim().isNotEmpty) return alias.trim();
    final label = w['label'] as String?;
    if (label != null && label.isNotEmpty) return label;
    final path = w['workspacePath'] as String?;
    if (path != null && path.isNotEmpty) {
      return path
          .split(_pathSeparators)
          .lastWhere((p) => p.isNotEmpty, orElse: () => path);
    }
    return workspaceKeyOf(w) ?? '未知工作区';
  }

  /// 换工作区 / 断开共用的桥栈收尾：订阅 → 会话 → 桥（监听器都挂在下层上）。
  ///
  /// 退订是**尽力而为**的收尾动作，绝不能为它把拆栈卡住——拆栈在
  /// `openWorkspace` 的关键路径上，卡住就是切项目白屏。两个订阅互不相干，
  /// 并行发出去；单次等待由 `ipcUnsubscribeTimeout` 兜底（默认 30s 时，
  /// 链路僵死会让这里串行等满 60s）。收尾失败一律吞掉：拆到一半抛出去
  /// 会让 workspace/bridge 字段停在半截状态。
  Future<void> _disposeBridgeStack() async {
    final oldChat = chat;
    final oldIndex = indexSub;
    final oldConv = conv;
    _stashChat(); // 拆桥前收一份本机历史，回头进同一个会话能立刻画出来
    chat = null;
    indexSub = null;
    conv = null;
    await Future.wait([
      if (oldChat != null) _bestEffort(oldChat.dispose),
      if (oldIndex != null) _bestEffort(oldIndex.dispose),
    ]);
    if (oldConv != null) await _bestEffort(oldConv.dispose);
    bridge?.dispose();
    bridge = null;
  }

  /// 收尾动作的兜底包装：拆栈路径上任何异常都不该往外抛。
  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      log('[workspace] 收尾失败（已忽略）: $e');
    }
  }

  /// 建起目标工作区的桥栈（旧栈先拆，再开新桥 + 订阅 sessions-index）。
  /// 失败时抛异常，且不会留下半截状态——桥字段要么全新、要么全空。
  Future<void> _mountWorkspaceStack(String key) async {
    await _disposeBridgeStack();
    final newBridge = await session!.openBridge(key);
    final newConv = ConversationV4(bridge: newBridge, onLog: log);
    try {
      indexSub = await newConv.subscribeSessionsIndex();
    } on Object {
      // 订阅没成：把新桥一起收掉，别让桌面端以为移动端还挂在这个工作区。
      await newConv.dispose();
      newBridge.dispose();
      rethrow;
    }
    bridge = newBridge;
    conv = newConv;
    // index 帧直接驱动任务卡刷新：phase/预览/时间戳实时跟上。
    indexSub!.state.addListener(refreshFromIndex);
  }

  /// 打开工作区桥 + V4 订阅 + 任务列表。
  ///
  /// 整段包在 [_asForeground] 里：切项目期间后台补拉一律让路，
  /// 别让用户的切换排在我们自己的 token 补拉后面（见 `_backgroundGate`）。
  Future<void> openWorkspace(
    Map<String, dynamic> w, {
    bool preserveView = false,
  }) => _asForeground(() => _openWorkspace(w, preserveView: preserveView));

  Future<void> _openWorkspace(
    Map<String, dynamic> w, {
    bool preserveView = false,
  }) async {
    final key = workspaceKeyOf(w);
    // 断开后列表会作为只读快照留在页面上，别让残留点击走到 session! 上。
    if (key == null || openingWorkspace || session == null) return;
    final prevWorkspace = workspace;
    final prevKey = _lastWorkspaceKey;
    openingWorkspace = true;
    notifyListeners();
    try {
      await _mountWorkspaceStack(key);
      // 桥栈真正立起来之后才认这个工作区：中途失败时标题和列表不会各说各话。
      workspace = w;
      // 切到具体项目就退出「全部对话」视图（数据源回到该项目自己的列表）。
      // preserveView = 跨项目开会话的切桥（ensureTaskProject）：用户只是想
      // 看那个会话，列表停在「全部对话」别动（多端一致性批次第三批）。
      if (!preserveView) viewingAllProjects = false;
      _lastWorkspaceKey = key;
      unawaited(_saveLastWorkspaceKey(key));
      openingWorkspace = false;
      notifyListeners();
      // 归档集合是上个工作区的：不清会把旧项目的会话误判成"已归档"，
      // 主列表合并时被错误排重（多端一致性批次）。
      _archivedTaskIds.clear();
      unawaited(loadTasks());
      // 归档**不在开工作区时拉**：它是跨项目聚合，一次 7 条 RPC（每个项目
      // 一次 listArchivedTasks），而主列表根本不用它（服务端 listTasks 本
      // 就只回活跃会话）。等用户真点归档 tab / 硬同步时再 force 拉。
      unawaited(loadPrep());
      unawaited(loadSkills());
    } on Object {
      // 切换失败：桥栈已经被拆掉一半，必须把状态拉回切换前。否则标题是失败的
      // 目标项目、列表却还是上一个项目的会话，而且"上次用的工作区"已被写成目标
      // 项目——重启后还会自动跳回这个打不开的项目。
      await _disposeBridgeStack();
      workspace = prevWorkspace;
      if (prevKey != null) {
        _lastWorkspaceKey = prevKey;
        unawaited(_saveLastWorkspaceKey(prevKey));
      }
      // 旧工作区静默挂回来。这里 await 住而不是 unawaited：openingWorkspace
      // 得一直把着，否则用户紧接着再点一次就会和回滚并发建栈、把桥字段写乱。
      if (prevWorkspace != null && prevKey != null) {
        await _remountQuietly(prevKey);
      }
      openingWorkspace = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 切换失败后的静默自愈：把上一个工作区的桥栈重新挂上。
  /// 失败只记日志——用户已经收到主错误提示了，不该再挨一次弹窗。
  Future<void> _remountQuietly(String key) async {
    try {
      await _mountWorkspaceStack(key);
      _archivedTaskIds.clear();
      unawaited(loadTasks());
    } on Object catch (e) {
      log('[workspace] 回滚旧工作区失败: $e');
    }
  }

  // ------------------------------------------------- 「全部对话」跨项目视图

  /// 切到「全部对话」：只换列表数据源，**不动当前项目的桥**——
  /// 这样从「全部对话」切回项目时不用重新开桥，也不会打断正在跑的会话。
  Future<void> showAllProjects() async {
    if (viewingAllProjects) return;
    viewingAllProjects = true;
    notifyListeners();
    await loadAllProjectTasks();
  }

  /// 回到当前项目视图（桥一直是当前项目的，无需重开）。
  void showCurrentProject() {
    if (!viewingAllProjects) return;
    viewingAllProjects = false;
    notifyListeners();
  }

  /// 拉整机任务列表（bootstrap 的 tasks[]）。失败保留旧数据，不清空。
  ///
  /// `pinned` 得**自己补**：bootstrap 的 tasks[] 里没有这个字段
  /// （`parseBootstrapTasks` 也不合成），而置顶筛选 / 图钉都看它。
  /// 单项目视图靠 `listPinnedTasks` 拿，这里同源——否则「全部」里
  /// 图钉全灭、置顶 tab 永远空。
  Future<void> loadAllProjectTasks() async {
    final s = session;
    if (s == null) return;
    try {
      final boot = await s.bootstrap();
      final parsed = parseBootstrapTasks(boot['tasks']);
      // 逐项目问一次 listPinnedTasks（该方法 scope 带项目，只能按项目查）。
      final pinnedIds = await _collectPinnedIdsAcrossProjects(parsed);
      allProjectTasks = _composeVisibleAllTasks([
        for (final t in parsed)
          if (pinnedIds == null)
            t
          else
            {...t, 'pinned': pinnedIds.contains('${t['taskId']}')},
      ]);
      notifyListeners();
      // 「全部对话」的卡片也有 ⚡token 角标：数据源不同，取数也要跟上，
      // 否则跨项目会话在全部视图里永远没有角标。
      unawaited(_fetchTaskTokens(from: allProjectTasks));
    } on Object catch (e) {
      log('[all] 整机任务拉取失败: $e');
    }
  }

  /// 跨项目收集置顶会话 id。返回 null 表示**一个项目都没问成**——
  /// 此时调用方保留原样（不把 pinned 全刷成 false，那会把图钉全灭掉）。
  ///
  /// 实现：在当前桥上逐项目直发 `listPinnedTasks`，scope 只带
  /// workspacePath/workspaceIdentity。桌面端 task 通道是 host 级服务，
  /// **按参数里的 workspacePath 路由**、与桥绑定哪个项目无关
  /// （getTaskTokenUsage 跨项目直发早已实证）。
  ///
  /// 绝不能为查置顶逐项目 `openBridge`：桌面端一个 relay 会话只保一个
  /// 活动工作区桥，每开一个新桥就把当前桥顶掉（degraded → 重连 →
  /// 「正在打开工作区桥…」连环弹，正是 2026-09-12 切换风暴的根因）。
  Future<Set<String>?> _collectPinnedIdsAcrossProjects(
    List<Map<String, dynamic>> tasks,
  ) async {
    final bridge = this.bridge;
    if (bridge == null) return null;
    // 项目 key → 查询 scope。key 实际就是 workspacePath（taskProjectKey
    // 首选它）；identity 取该路径下首个非空值，没有就不带。
    final scopes = <String, Map<String, dynamic>>{};
    for (final t in tasks) {
      final key = taskProjectKey(t);
      if (key == null || scopes.containsKey(key)) continue;
      final identity = t['workspaceIdentity'];
      scopes[key] = {
        'workspacePath': key,
        if (identity is String && identity.isNotEmpty)
          'workspaceIdentity': identity,
      };
    }
    if (scopes.isEmpty) return null;
    final out = <String>{};
    var anyOk = false;
    for (final entry in scopes.entries) {
      final cached = _pinnedIdsCache[entry.key];
      if (cached != null) {
        out.addAll(cached);
        anyOk = true;
        continue;
      }
      try {
        final res = await bridge.channels.call(
          Chan.task,
          'listPinnedTasks',
          [entry.value],
          timeout: const Duration(seconds: 12),
        );
        final ids = {
          for (final t in castMapList(res)) '${t['taskId']}',
        };
        _pinnedIdsCache[entry.key] = ids;
        out.addAll(ids);
        anyOk = true;
      } on Object catch (e) {
        log('[all] ${entry.key} 置顶列表拉取失败: $e');
      }
    }
    return anyOk ? out : null;
  }

  /// 项目 key → 该项目的置顶 session id 集（「全部」视图专用缓存）。
  final _pinnedIdsCache = <String, Set<String>>{};

  /// 置顶状态一变就作废缓存，下次进「全部」重新问。
  void _invalidatePinnedCache() => _pinnedIdsCache.clear();

  /// 任务卡所属项目的显示名（「全部对话」视图用）：先按工作区列表对出别名，
  /// 对不上就退回路径尾段——宁可显示个路径，也别显示空。
  String taskProjectName(Map<String, dynamic> t) {
    final key = taskProjectKey(t);
    if (key == null) return '';
    for (final w in workspaces) {
      if (workspaceKeyOf(w) == key || '${w['workspacePath'] ?? ''}' == key) {
        return workspaceDisplayName(w);
      }
    }
    return taskProjectLabel(key);
  }

  /// 打开会话前的项目对齐：「全部对话」里点开别的项目的会话，得先把桥切过去，
  /// 否则会拿当前项目的桥去开别人的会话（开不出来或开错）。
  /// 返回 false 表示目标项目打不开，调用方应放弃这次打开而不是硬闯。
  Future<bool> ensureTaskProject(Map<String, dynamic> t) async {
    if (!viewingAllProjects) return true;
    final key = taskProjectKey(t);
    if (key == null) return true;
    final currentKey = workspace == null ? null : workspaceKeyOf(workspace!);
    if (key == currentKey) return true;
    for (final w in workspaces) {
      if (workspaceKeyOf(w) == key || '${w['workspacePath'] ?? ''}' == key) {
        try {
          // preserveView：切桥只为订阅那个会话，用户的「全部对话」列表
          // 视图原样保留——点会话不该被拽进项目分类里。
          await openWorkspace(w, preserveView: true);
          return true;
        } on Object catch (e) {
          log('[all] 打开目标项目失败: $e');
          return false;
        }
      }
    }
    // 工作区列表里没有它（桌面端可能已关闭该项目）：不拦，按原样试一次。
    return true;
  }

  /// zcode-task 三列表 + sessions-index 合并成任务卡。
  Future<void> loadTasks() async {
    final bridge = this.bridge;
    if (bridge == null) return;
    tasksLoading = true;
    notifyListeners();
    final scope = bridge.scope;
    Object? listErr;
    Object? pinErr;
    final results = await Future.wait([
      bridge.channels
          .call(Chan.task, 'listTasks', [
            scope,
          ], timeout: const Duration(seconds: 12))
          .catchError((Object e) {
            listErr = e;
            return const [];
          }),
      bridge.channels
          .call(Chan.task, 'listPinnedTasks', [
            scope,
          ], timeout: const Duration(seconds: 12))
          .catchError((Object e) {
            pinErr = e;
            return const [];
          }),
    ]);
    // 服务端列表没拿到 → 现有列表按「缓存」降级保留，标陈旧并退避重试。
    // 不能吞成空列表——那在用户眼里就是"会话全没了"（多端一致性批次）。
    if (listErr != null) {
      tasksLoading = false;
      tasksStale = true;
      notifyListeners();
      log('[task] listTasks 失败，保留本地缓存稍后重试: $listErr');
      _scheduleTasksRetry();
      return;
    }
    _taskRetryTimer?.cancel();
    _taskRetryTimer = null;
    _taskRetryDelay = const Duration(seconds: 3);
    tasksStale = false;
    final list = results[0] is List ? results[0] as List : const [];
    final pins = results[1];
    // 置顶列表失败时沿用上次的置顶状态（缓存语义），成功则以服务端为准。
    final pinnedIds = pinErr == null && pins is List
        ? {
            for (final t in pins)
              if (t is Map && t['taskId'] != null) '${t['taskId']}',
          }
        : {
            for (final t in tasks)
              if (t['pinned'] == true) '${t['taskId']}',
          };
    final byId = <String, Map<String, dynamic>>{};
    for (final t in list) {
      if (t is! Map || t['taskId'] == null) continue;
      final id = '${t['taskId']}';
      if (t['archived'] == true || t['deleted'] == true) {
        byId.remove(id);
        continue;
      }
      byId[id] = {
        ...?byId[id],
        ...t.cast<String, dynamic>(),
        'pinned': pinnedIds.contains(id),
      };
    }
    // 删除进行中的会话对账（服务端为准，多端一致性批次）：
    // · 服务端列表已没有 → 确认删干净，摘掉乐观隐藏层；
    // · 服务端还有且已过宽限期 → 删除没生效（如旧版桌面拒删），恢复显示。
    final sweep = sweepDeletions(
      serverIds: byId.keys,
      deleting: _deletingTasks,
      now: DateTime.now(),
    );
    _deletingTasks
      ..removeWhere((id, _) => sweep.confirmed.contains(id))
      ..removeWhere((id, _) => sweep.restore.contains(id));
    for (final id in sweep.restore) {
      log('[task] 服务端仍保留 $id，删除未生效——按服务端恢复显示');
    }
    if (sweep.restore.isNotEmpty && viewingAllProjects) {
      // 恢复的会话在「全部对话」数据源里也补回来（那张表只在整拉时重建）。
      unawaited(loadAllProjectTasks());
    }
    // 置顶记录收敛：服务端已经跟上了本地意图就撤掉记录，
    // 别让一个乐观层长期压着服务端（他端取消置顶时能正常体现出来）。
    for (final t in byId.values) {
      final id = '${t['taskId']}';
      final local = _pinOverrides[id];
      if (local != null && (t['pinned'] == true) == local) {
        _pinOverrides.remove(id);
      }
    }
    tasks = _composeVisibleTasks(byId.values.toList());
    tasksLoading = false;
    _mergeIndexIntoTasks();
    notifyListeners();
    // token 消耗逐任务异步补拉，不阻塞列表本身。
    unawaited(_fetchTaskTokens());
    // 模型批量对账（BUG-07 护栏）：夜间无人值守时桌面端可能把会话批量
    // 刷回欠费基线——列表级就能发现并纠正，不等用户逐个点进聊天页。
    unawaited(reconcileTaskModels());
  }

  /// 当前列表是否为本地缓存降级（listTasks 失败、尚未从服务端确认）。
  /// 列表页据此提示「同步中，内容可能滞后」——缓存可用，但要诚实。
  bool tasksStale = false;
  Timer? _taskRetryTimer;
  Duration _taskRetryDelay = const Duration(seconds: 3);

  /// listTasks 失败后的退避重试：3s 起步翻倍，30s 封顶；成功即复位。
  void _scheduleTasksRetry() {
    _taskRetryTimer?.cancel();
    _taskRetryTimer = Timer(_taskRetryDelay, () {
      _taskRetryDelay *= 2;
      if (_taskRetryDelay > const Duration(seconds: 30)) {
        _taskRetryDelay = const Duration(seconds: 30);
      }
      unawaited(loadTasks());
    });
  }

  /// 硬同步（抽屉「从服务端拉取最新」）：整表重拉服务端权威数据——
  /// 会话列表 + 归档 + 「全部对话」视图（若在）+ 索引流强制重同步
  /// （标题/相位跟着刷新）。用户手动触发的「以服务端为准」校准入口，
  /// 与自动轮询/退避重试互不干扰。
  Future<void> pullLatest() {
    return Future.wait([
      loadTasks(),
      loadArchivedTasks(force: true),
      if (viewingAllProjects) loadAllProjectTasks(),
      indexSub?.forceResync() ?? Future<void>.value(),
    ]);
  }

  /// 任务卡 token 消耗缓存（taskId → 累计 token）；异步补拉，失败静默。
  /// 拉过的按 tokenFetchDue 的 TTL 过期重拉——长跑会话的数字不能停在旧值。
  final _taskTokens = <String, num>{};
  final _taskTokensAt = <String, DateTime>{};
  bool _tokenSampleLogged = false;

  /// 打开中会话的 phase 权威覆盖（taskId → phase）：conv 通道直达，
  /// 比 sessions-index 可靠——index 流丢更新时任务卡也不会里外不一致。
  final _livePhase = <String, String>{};

  /// 待释放的覆盖（离开聊天页后进入缓冲）：taskId → 离开时刻。
  final _pendingPhaseRelease = <String, DateTime>{};
  Timer? _phaseReleaseTimer;

  /// 会话级发送异常（taskId → 简短文案）。聊天页发送失败/超慢时写进来，
  /// 任务卡据此在列表上打标——用户在列表页也能看到"这条没发出去"，
  /// 不必点进会话才发现。会话重新发成功或用户重试成功后清除。
  final _sendIssues = <String, String>{};

  /// 该会话当前的发送异常文案（没有则 null）。任务卡渲染用。
  String? sendIssue(String taskId) => _sendIssues[taskId];

  /// 聊天页上报发送异常/恢复。空文案 = 恢复（清除标记）。
  ///
  /// 只在真正变化时 notify——发送流程里这个会被高频调用（每个 stage
  /// 都要对账），无条件通知会让列表整页重建。
  void reportSendIssue(String sessionId, String issue) {
    if (sessionId.isEmpty) return;
    final had = _sendIssues[sessionId];
    if (sameSendIssue(had, issue)) return;
    if (shouldFlagSendIssue(issue)) {
      _sendIssues[sessionId] = issue.trim();
    } else {
      _sendIssues.remove(sessionId);
    }
    notifyListeners();
  }

  /// 聊天页每次 build 后同步当前会话 phase（post-frame 调用，内部去重）。
  void setLivePhase(String sessionId, String phase) {
    if (sessionId.isEmpty || phase.isEmpty) return;
    // 重新打开该会话 → 取消待释放，继续用实时值覆盖。
    _pendingPhaseRelease.remove(sessionId);
    if (_livePhase[sessionId] == phase) return;
    _livePhase[sessionId] = phase;
    _mergeIndexIntoTasks();
    notifyListeners();
  }

  /// 离开聊天页时解除覆盖，任务卡回到 index 权威。
  ///
  /// **延迟释放**：index 流有滞后，立刻清会让状态"倒退"——刚在聊天页看到
  /// "运行中"，退回列表变成"空闲"。留一段缓冲期，等 index 追平（两边一致）
  /// 再清；追不平就超时兜底，不会永久占着覆盖。
  void clearLivePhase(String sessionId) {
    if (!_livePhase.containsKey(sessionId)) return;
    _pendingPhaseRelease[sessionId] = DateTime.now();
    // 追平检查：index 当前值已经和覆盖一致 → 立刻释放。
    _tryReleaseLivePhase(sessionId);
    // 无论追没追平，兜底定时器保证最终一定释放。
    _phaseReleaseTimer?.cancel();
    _phaseReleaseTimer = Timer(const Duration(seconds: 20), () {
      _phaseReleaseTimer = null;
      final ids = _pendingPhaseRelease.keys.toList();
      for (final id in ids) {
        _livePhase.remove(id);
      }
      _pendingPhaseRelease.clear();
      _mergeIndexIntoTasks();
      notifyListeners();
    });
  }

  /// 覆盖值与 index 权威值一致时释放（不需要再靠覆盖撑着了）。
  void _tryReleaseLivePhase(String sessionId) {
    final index = indexSub?.state;
    if (index == null || !index.ready) return;
    final entry = index.sessions[sessionId];
    if (!canReleaseLivePhase(
      overridePhase: _livePhase[sessionId],
      indexPhase: entry?.phase,
    )) {
      return;
    }
    if (_livePhase.remove(sessionId) == null && entry == null) return;
    _pendingPhaseRelease.remove(sessionId);
    _mergeIndexIntoTasks();
    notifyListeners();
  }

  /// 任务卡角标用：该会话累计 token（没拉到给 null）。
  num? taskToken(String taskId) => _taskTokens[taskId];

  /// 任务页定时器调：按 TTL 重拉过期的 token 角标（内部自带节流）。
  void refreshTaskTokens() => unawaited(_fetchTaskTokens());

  Future<void> _fetchTaskTokens({List<Map<String, dynamic>>? from}) async {
    if (!_backgroundGate('tokens')) return;
    final now = DateTime.now();
    // 首次补拉按预算限流（列表已按置顶+活跃倒序，先补第一屏看得见的）：
    // 「全部对话」整机 41 张卡一次全 due = 11 批 RPC 排满通道，
    // 用户紧接着点会话/下拉刷新都要排在后面。
    final targets = tokenFetchTargets(
      from ?? tasks,
      _taskTokensAt,
      now: now,
    );
    var changed = false;
    // 限流：一批最多 4 个在途请求，任务一多也别把桥瞬间的 RPC 打爆。
    for (var i = 0; i < targets.length; i += 4) {
      // 用户动手了：剩下的批次别发，记账等前台空闲再补。
      if (!_backgroundGate('tokens')) break;
      await Future.wait([
        for (final t in targets.skip(i).take(4))
          () async {
            final id = '${t['taskId']}';
            _taskTokensAt[id] = now; // 失败也计时，别每轮刷新都重锤
            try {
              final res = await _taskCall('getTaskTokenUsage', _taskScope(t));
              final n = parseTaskTokenUsage(res);
              if (n != null) {
                _taskTokens[id] = n;
                changed = true;
              }
              // 口径诊断：后台账单动辄几百万，这里得确认服务端统计的是哪部分。
              if (!_tokenSampleLogged) {
                _tokenSampleLogged = true;
                log('[token] 原始返回样例 $id → $res');
              } else if (n == null) {
                log('[token] $id 形状认不出: $res');
              }
            } on Object {
              // 拉不到就保留旧值；下个 TTL 周期再试。
            }
          }(),
      ]);
    }
    if (changed) notifyListeners();
  }

  /// 删除进行中过滤 + 重命名覆盖 + 打开会话的 phase 权威覆盖 + 本地置顶记录 + 排序。
  List<Map<String, dynamic>> _composeVisibleTasks(
    List<Map<String, dynamic>> all,
  ) {
    final kept = <Map<String, dynamic>>[
      for (final t in all)
        if (!_deletingTasks.containsKey('${t['taskId']}'))
          _titleOverrides['${t['taskId']}'] is String
              ? {...t, 'title': _titleOverrides['${t['taskId']}']}
              : t,
    ];
    return _applyPinsAndSort([
      for (final t in kept)
        _livePhase['${t['taskId']}'] is String
            ? {...t, 'phase': _livePhase['${t['taskId']}']}
            : t,
    ]);
  }

  /// 用索引流增补一组卡片（标题/相位/活跃时间/预览/待交互）。
  /// 只动**已存在**的卡，不造新卡——列表成员一律以服务端列表为准。
  List<Map<String, dynamic>> _enrichFromIndex(
    List<Map<String, dynamic>> cards,
  ) {
    final index = indexSub?.state;
    if (index == null || !index.ready) return cards;
    final byId = {for (final e in index.list) e.sessionId: e};
    final out = <Map<String, dynamic>>[];
    for (final t in cards) {
      final entry = byId['${t['taskId']}'];
      if (entry == null) {
        out.add(t);
        continue;
      }
      // 本地重命名覆盖优先（同 _mergeIndexIntoTasks，别踩回旧标题）。
      final override = _titleOverrides['${t['taskId']}'];
      out.add({
        ...t,
        'title': override is String
            ? override
            : entry.title.isNotEmpty
            ? entry.title
            : t['title'],
        'phase': entry.phase,
        if (entry.lastActivityAt > 0) 'lastActivityAt': entry.lastActivityAt,
        'lastAssistantPreview': entry.lastAssistantPreview,
        'pendingInteraction': entry.pendingInteraction,
      });
    }
    return out;
  }

  /// 「全部对话」视图的可见合成：删除进行中过滤 + 已删排重 +
  /// 索引流实时增补 + 打开会话的 phase 覆盖 + 置顶 + 排序。
  /// 与单项目视图同一条「服务端为准」纪律。
  ///
  /// **archived 不过滤**（2026-09-13 探针实测裁定）：桌面端的 archived
  /// 是「会话已关闭」的生命周期标记（36/41 都带，连正在跑的会话都带），
  /// 桌面端自己的主列表照样显示——服务端有什么就显示什么。归档的单独
  /// 入口是归档 tab（跨项目聚合），不是从主列表里藏掉。
  List<Map<String, dynamic>> _composeVisibleAllTasks(
    List<Map<String, dynamic>> all,
  ) {
    final kept = <Map<String, dynamic>>[
      for (final t in all)
        if (!_deletingTasks.containsKey('${t['taskId']}'))
          if (t['deleted'] != true) t,
    ];
    return _applyPinsAndSort([
      for (final t in _enrichFromIndex(kept))
        _livePhase['${t['taskId']}'] is String
            ? {...t, 'phase': _livePhase['${t['taskId']}']}
            : t,
    ]);
  }

  /// 叠加本地置顶记录，再按「置顶优先 + 活跃倒序」重排。
  /// 置顶是用户看得见的顺序变化——不能等下一次 loadTasks 才跳到最前面。
  List<Map<String, dynamic>> _applyPinsAndSort(List<Map<String, dynamic>> src) {
    return sortTaskCards([
      for (final t in src)
        _pinOverrides['${t['taskId']}'] == null
            ? t
            : {...t, 'pinned': _pinOverrides['${t['taskId']}']},
    ]);
  }

  /// 任务卡是否置顶：本地待确认记录优先，否则看服务端字段。
  bool isTaskPinned(Map<String, dynamic> t) {
    final id = '${t['taskId'] ?? ''}';
    return _pinOverrides[id] ?? (t['pinned'] == true);
  }

  // --------------------------------------------------------- task actions

  Map<String, dynamic> _taskScope(Map<String, dynamic> t) {
    final w = workspace ?? const <String, dynamic>{};
    final taskPath = t['workspacePath'];
    final wPath = w['workspacePath'];
    // 任务自带工作区路径时以它为准（「全部对话」里的卡片就属于别的项目）。
    // 只有当它确实是当前项目、或者压根没写路径时，才允许补上当前项目的工作区标识
    // ——否则会拼出 path=X + identity=Y 的错 scope，服务端要么拒要么打错项目。
    //
    // 判"是不是当前项目"不能只看路径：同一路径在不同 identity 下是不同工作区
    // （identity 才是服务端的真身份，路径只是显示名）。路径相同但 identity 不同
    // 时补上当前 identity，就会拼出上面那种错 scope——所以两个都比。
    final taskIdentity = t['workspaceIdentity'];
    final sameAsCurrent =
        (taskPath == null || taskPath == wPath) &&
        (taskIdentity == null || taskIdentity == w['workspaceIdentity']);
    final identity = taskIdentity ?? (sameAsCurrent ? w['workspaceIdentity'] : null);
    return {
      'taskId': t['taskId'] ?? t['id'],
      'workspacePath': taskPath ?? wPath,
      'workspaceIdentity': ?identity,
    };
  }

  /// 查不到给 null（不抛）。**打开会话必须用这个**：刚 createSession 出来的
  /// 新会话此刻不在任何列表里、索引帧也还没到，查不到是正常状态——那时桥
  /// 本来就是对的（会话刚在当前桥上建的），不该因此把首条消息打回去。
  /// （回归记录：`_openSessionAligned` 用了会抛的 `_taskById`，导致
  /// 「新会话第一条消息总是发不出去 / Bad state: 任务不存在」。）
  Map<String, dynamic>? _taskByIdOrNull(String taskId) {
    for (final t in tasks) {
      if ('${t['taskId']}' == taskId) return t;
    }
    // 「全部对话」视图里的卡片也允许操作——它的 scope 自带所属项目路径。
    for (final t in allProjectTasks) {
      if ('${t['taskId']}' == taskId) return t;
    }
    // 归档里的会话也允许操作（删除/取消归档都从归档 tab 发起）。
    for (final t in archivedTasks) {
      if ('${t['taskId']}' == taskId) return t;
    }
    // channel 列表滞后、只在 sessions-index 里出现的新任务。
    if (indexSub?.state.sessions.containsKey(taskId) == true) {
      return {'taskId': taskId};
    }
    return null;
  }

  /// 查不到就抛：重命名/置顶/归档这类**必须知道会话属于哪个项目**的操作，
  /// 拿不准 scope 会把请求打到错的项目上（服务端静默拒绝或改错库）。
  Map<String, dynamic> _taskById(String taskId) =>
      _taskByIdOrNull(taskId) ?? (throw StateError('任务不存在: $taskId'));

  Future<dynamic> _taskCall(String method, Map<String, dynamic> arg) {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    return bridge.channels.call(Chan.task, method, [
      arg,
    ], timeout: const Duration(seconds: 12));
  }

  Future<void> renameTask(String taskId, String title) async {
    final t = _taskById(taskId);
    // 跨项目直发即可：桌面端 task 通道按参数 workspacePath 路由、与桥无关
    // （同 getTaskTokenUsage）。不要为重命名切桥——桌面端一个 relay 会话
    // 只保一个活动桥，切一次顶掉一次，全是重连风暴。
    await _taskCall('renameTask', {..._taskScope(t), 'title': title});
    _titleOverrides[taskId] = title;
    notifyListeners();
  }

  /// 置顶 / 取消置顶。
  ///
  /// 在当前桥上直发即可：桌面端 task 通道是 host 级服务、按参数里的
  /// workspacePath 路由（桌面库反解 + 置顶在多项目同时落库实证），
  /// 与桥绑定哪个项目无关。**不要**为此切桥——切桥会顶掉当前活动桥，
  /// 引发重连风暴和「已切换到」连环弹（BUG-29 的另一半）。
  Future<void> setTaskPinned(String taskId, bool pinned) async {
    final t = _taskById(taskId);
    final before = _pinOverrides[taskId];
    // 乐观更新：先让列表立刻反映（置顶要跳到最前），再发 RPC。
    _pinOverrides[taskId] = pinned;
    _resortLists();
    notifyListeners();
    try {
      final res = await _taskCall('setTaskPinned', {
        ..._taskScope(t),
        'pinned': pinned,
      });
      // 软失败也要回滚：服务端可能返回 {ok:false} 而不抛异常。
      // 不拦的话 _pinOverrides 会永久留着脏记录，两个视图各说各话。
      if (_isSoftFailure(res)) {
        throw StateError('服务端拒绝了置顶：$res');
      }
    } on Object {
      // 失败回滚：别让用户以为置上了——下次刷新自己变回来更费解。
      if (before == null) {
        _pinOverrides.remove(taskId);
      } else {
        _pinOverrides[taskId] = before;
      }
      _resortLists();
      notifyListeners();
      rethrow;
    }
  }

  /// 服务端"静默拒绝"识别：返回体带 ok/accepted/success 且为 false。
  /// 这些方法不抛异常但没生效，只判异常会漏。
  bool _isSoftFailure(Object? res) {
    if (res is! Map) return false;
    for (final k in const ['ok', 'accepted', 'success']) {
      if (res.containsKey(k) && res[k] == false) return true;
    }
    return false;
  }

  /// 置顶状态一变就重排两个列表：顺序是数据层算好的，不重排不会跳位。
  void _resortLists() {
    tasks = _applyPinsAndSort(tasks);
    allProjectTasks = _applyPinsAndSort(allProjectTasks);
    _invalidatePinnedCache();
  }

  /// 任务列表级模型批量对账：listTasks 自带每会话 model（providerId/
  /// modelId），无需逐个订阅会话就能发现漂移。服务端模型是回退基线
  /// （千问系/历史默认）→ 按本机意图记录纠正（无记录用首选默认 GLM）；
  /// 服务端是真实模型 → 不发 RPC（他端新选择，打开会话时对账采纳）。
  /// 纠正不写意图记录——套默认不算用户显式选择，保持迁移语义。
  Future<void> reconcileTaskModels() async {
    if (!_backgroundGate('models')) return;
    final conv = this.conv;
    if (conv == null) return;
    var changed = false;
    for (final t in tasks) {
      // 每个漂移会话都要发一次 switchModel，是串行长循环——用户动手就停。
      if (!_backgroundGate('models')) break;
      final sid = '${t['taskId']}';
      final raw = '${t['model'] ?? ''}'.trim();
      if (raw.isEmpty) continue;
      final slash = raw.indexOf('/');
      final serverModel = slash >= 0 ? raw.substring(slash + 1) : raw;
      if (!isServerFallbackModel(serverModel)) continue;
      final rec = sessionModels[sid];
      final recModel = '${rec?['model'] ?? ''}'.trim();
      final useRec = recModel.isNotEmpty && !shouldApplyPreferredDefaultModel(rec);
      final provider = useRec
          ? '${rec!['provider'] ?? ''}'
          : preferredDefaultModelProvider;
      final model = useRec ? recModel : preferredDefaultModelId;
      if (model.isEmpty) continue;
      final recThought = '${rec?['thought'] ?? ''}';
      final thought = useRec && recThought.isNotEmpty
          ? recThought
          : preferredDefaultModelThought;
      t['model'] = '$provider/$model';
      changed = true;
      try {
        await switchModel(sid, provider: provider, model: model, thought: thought);
        log('[config] 批量对账 $sid: 服务端在基线 $serverModel，纠正为 $provider/$model');
      } on Object catch (e) {
        log('[config] 批量对账 $sid 纠正失败: $e');
      }
    }
    if (changed) notifyListeners();
  }

  /// 删除会话。先乐观隐藏（`_deletingTasks`，仅内存），随后双通道删除；
  /// 之后由 loadTasks 对账：服务端删干净则维持隐藏，服务端仍保留（旧版
  /// 桌面拒删等）则恢复显示——会话列表以服务端为准，本机不再永久私藏。
  ///
  /// task 通道 deleteTask 只摘任务列表条目；会话本体要再调 agent 通道
  /// deleteSession，否则 sessions-index 还能看见它，别的设备（无本机
  /// 隐藏层）会把它重建出来——这正是"手机删了平板复活"的根因。
  Future<void> deleteTask(String taskId) async {
    final t = _taskById(taskId);
    // 跨项目直发即可（同 setTaskPinned）：桌面端按参数 workspacePath 路由。
    // 不再为此切桥——切不开也就地删除，删除意图优先。
    // 运行中的会话先请求停止再删：桌面库实证删除会清 task_status，但旧版
    // 桌面端可能因「任务在跑」拒绝删除；多发一个 stop 是廉价的防御。
    if ('${t['phase'] ?? t['status'] ?? ''}' == 'running') {
      try {
        final conv = this.conv;
        if (conv != null) await conv.stop(taskId);
      } on Object {
        // 停不下来也继续删——删除意图优先，桌面端自行裁决。
      }
    }
    try {
      await _taskCall('deleteTask', _taskScope(t));
    } on Object {
      try {
        await _taskCall('deleteTask', _taskScope(t));
      } on Object catch (e) {
        log('[task] 服务端删除 $taskId 被拒: $e（仍从本机列表隐藏）');
      }
    }
    try {
      // conv 绑当前桥：跨项目删除时 agent 通道的 deleteSession 可能打不到
      // 目标项目——失败只记日志（他端索引可能复活），不阻断本机删除。
      final conv = this.conv;
      if (conv != null) await conv.deleteSession(taskId);
    } on Object catch (e) {
      log('[task] 会话本体删除 $taskId 失败（他端索引可能复活）: $e');
    }
    _deletingTasks[taskId] = DateTime.now();
    _titleOverrides.remove(taskId);
    _livePhase.remove(taskId);
    _sendIssues.remove(taskId);
    _taskTokens.remove(taskId);
    _taskTokensAt.remove(taskId);
    sessionModels.remove(taskId);
    sessionApprovalModes.remove(taskId);
    // 三个集合都要摘：「全部对话」的数据源是 allProjectTasks，
    // 只清 tasks/archivedTasks 的话在「全部」里删完那张卡还在。
    tasks = [
      for (final x in tasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    allProjectTasks = [
      for (final x in allProjectTasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    // 从归档 tab 删除的也要从归档集合清掉，否则换页又出现。
    archivedTasks = [
      for (final x in archivedTasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    _archivedTaskIds.remove(taskId);
    _invalidatePinnedCache();
    notifyListeners();
    // 删除对账：给服务端处理留时间，之后拉一次列表核对。服务端仍保留
    // 的话 sweepDeletions 恢复显示——以服务端为准（多端一致性批次）。
    Timer(const Duration(seconds: 10), () {
      if (_deletingTasks.containsKey(taskId)) unawaited(loadTasks());
    });
  }

  // -------------------------------------------------------------- archive

  /// 归档会话集合（listArchivedTasks），切到归档 tab 时按需加载。
  List<Map<String, dynamic>> archivedTasks = [];
  bool archivedLoading = false;

  /// 归档中会话的 id 集合：sessions-index 合并主列表时拿它排重，
  /// 归档会话不回主列表（归档/取消归档时同步增删）。
  final _archivedTaskIds = <String>{};

  /// 归档列表：**跨项目聚合**（2026-09-13 探针实测裁定）——桌面端的归档
  /// 是全局视图（7 个项目合计 36 条），只查当前桥一个项目必然比服务端
  /// 少一大截（用户报障：服务端归档比本地多很多）。task 通道是 host 级
  /// 服务、按参数里的 workspacePath 路由（跨项目置顶/归档直发早已实证），
  /// 逐项目并发直发合并即可，不切桥。
  ///
  /// [force] = 用户显式动作（点归档 tab/硬同步）：绕过后台闸门直接拉，
  /// 绝不让用户的等待被静默吞成空列表。
  Future<void> loadArchivedTasks({bool force = false}) async {
    if (!force && !_backgroundGate('archived')) return;
    final bridge = this.bridge;
    if (bridge == null) return;
    archivedLoading = true;
    notifyListeners();
    try {
      final scopes = <Map<String, dynamic>>[
        for (final w in workspaces)
          if ('${w['workspacePath'] ?? ''}'.isNotEmpty)
            {
              'workspacePath': '${w['workspacePath']}',
              if (w['workspaceIdentity'] is String &&
                  (w['workspaceIdentity'] as String).isNotEmpty)
                'workspaceIdentity': w['workspaceIdentity'],
            },
      ];
      final resList = await Future.wait([
        for (final scope in scopes)
          bridge.channels
              .call(Chan.task, 'listArchivedTasks', [
                scope,
              ], timeout: const Duration(seconds: 12))
              .catchError((Object e) {
                log('[task] ${scope['workspacePath']} 归档拉取失败: $e');
                return const [];
              }),
      ]);
      final merged = <String, Map<String, dynamic>>{};
      for (final res in resList) {
        for (final t in castMapList(res)) {
          merged['${t['taskId']}'] = t;
        }
      }
      archivedTasks = merged.values.toList();
      _archivedTaskIds
        ..clear()
        ..addAll(merged.keys);
    } finally {
      archivedLoading = false;
      notifyListeners();
    }
  }

  /// 归档：服务端移动 + 本地主列表→归档列表（探针实测返回任务对象）。
  ///
  /// 跨项目直发即可（同 setTaskPinned）：桌面端按参数 workspacePath 路由，
  /// 不切桥。
  Future<void> archiveTask(String taskId) async {
    final t = _taskById(taskId);
    await _taskCall('archiveTask', _taskScope(t));
    final map = {...t};
    // 三个集合一起摘（含「全部」的数据源），否则在「全部」里归档完那张卡还在。
    tasks = [
      for (final x in tasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    allProjectTasks = [
      for (final x in allProjectTasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    archivedTasks = [map, ...archivedTasks];
    _archivedTaskIds.add(taskId);
    _invalidatePinnedCache();
    notifyListeners();
  }

  /// 从某条 assistant 回复分叉新会话（继承该回合前上下文）。
  /// 返回新 sessionId（探针实测 result.sessionId）。
  Future<String> forkAssistant(
    String sessionId, {
    required int rowId,
    required String entityId,
  }) async {
    final res = await conv!.sendCommand(sessionId, 'forkAssistant', {
      'target': {'rowId': rowId, 'entityId': entityId},
    });
    final result = res is Map ? res['result'] : null;
    final newId = result is Map ? '${result['sessionId'] ?? ''}' : '';
    if (newId.isEmpty || newId == 'null') {
      throw StateError('fork 未返回新 sessionId');
    }
    return newId;
  }

  // ----------------------------------------------------------- automations

  /// 定时任务集合（listAllAutomations），进入自动化页时加载。
  List<Map<String, dynamic>> automations = [];
  bool automationsLoading = false;

  Future<void> loadAutomations() async {
    final bridge = this.bridge;
    if (bridge == null) return;
    automationsLoading = true;
    notifyListeners();
    try {
      final res = await bridge.channels.call(
        Chan.agent,
        'listAllAutomations',
        [],
        timeout: const Duration(seconds: 15),
      );
      automations = parseAutomations(res);
    } on Object catch (e) {
      log('[auto] 定时任务列表加载失败: $e');
    } finally {
      automationsLoading = false;
      notifyListeners();
    }
  }

  Map<String, dynamic> get _automationScope => {
    ...?(() {
      final b = bridge;
      if (b == null) return null;
      return b.scope;
    })(),
  };

  Future<void> setAutomationEnabled(
    String automationId,
    bool enabled, {
    String? workspacePath,
  }) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    // 跨工作区：记录自带工作区时优先于当前桥接 scope。
    // 桌面端内部按 workspaceKey 索引任务（触发日志实证），两个名字都带，
    // 值相同（实测 workspaceKey == 工作区路径）。
    final ws = workspacePath
        ?? (_automationScope['workspacePath'] ?? _automationScope['workspaceKey'])
              as String?;
    final scope = <String, dynamic>{
      ..._automationScope,
      'workspacePath': ?ws,
      'workspaceKey': ?ws,
    };
    await bridge.channels.call(Chan.agent, 'setAutomationEnabled', [
      {...scope, 'automationId': automationId, 'enabled': enabled},
    ], timeout: const Duration(seconds: 15));
    for (final a in automations) {
      if ('${a['automationId']}' == automationId) {
        a['enabled'] = enabled;
        break;
      }
    }
    notifyListeners();
  }

  /// [workspacePath]：记录自带的工作区（跨工作区任务删除必须带上，
  /// 否则桌面端在当前 scope 里找不到任务——「看得见删不掉」的根因）。
  /// 带了仍失败时，再去掉 scope 重试一次（部分桌面端版本按 id 全局删）。
  Future<void> deleteAutomation(
    String automationId, {
    String? workspacePath,
  }) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    // 桌面端内部按 workspaceKey 索引任务（触发日志实证），两个名字都带。
    final ws = workspacePath
        ?? (_automationScope['workspacePath'] ?? _automationScope['workspaceKey'])
              as String?;
    final scope = <String, dynamic>{
      ..._automationScope,
      'workspacePath': ?ws,
      'workspaceKey': ?ws,
    };
    try {
      await bridge.channels.call(Chan.agent, 'deleteAutomation', [
        {...scope, 'automationId': automationId},
      ], timeout: const Duration(seconds: 15));
    } on Object {
      if (workspacePath == null) rethrow;
      await bridge.channels.call(Chan.agent, 'deleteAutomation', [
        {'automationId': automationId},
      ], timeout: const Duration(seconds: 15));
    }
    // 假成功防护：RPC 返回 OK 不代表真删掉（scope 不匹配时桌面端会静默跳过
    // ——「删了很多次一刷新又出现」的根因）。回读列表核对，没删掉就说真相。
    await loadAutomations();
    if (automations.any((a) => '${a['automationId']}' == automationId)) {
      throw StateError('桌面端返回成功但任务仍在，删除未生效（请反馈厂商）');
    }
    automations = [
      for (final a in automations)
        if ('${a['automationId']}' != automationId) a,
    ];
    notifyListeners();
  }

  /// 自动化运行历史（探针实测：runId/trigger/outcome/sessionId/attempts）。
  Future<List<AutomationRunView>> loadAutomationRuns(
    String automationId,
  ) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    final res = await bridge.channels.call(Chan.agent, 'listAutomationRuns', [
      {..._automationScope, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
    return parseAutomationRuns(res);
  }

  /// 取消后台任务（V4 命令 cancelBackgroundWork {workId}，非 CAS；
  /// schema 实锤后台任务带 cancellable 标志——只在可取消时调）。
  Future<void> cancelBackgroundWork(String workId) async {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    await conv.sendCommand(null, 'cancelBackgroundWork', {
      'workId': workId,
    });
  }

  /// 立即运行（探针实测返回 {status: queued}，由桌面端调度投递）。
  Future<void> runAutomationNow(String automationId) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    await bridge.channels.call(Chan.agent, 'runAutomationNow', [
      {..._automationScope, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
  }

  /// 编辑标题/提示词：桌面端无 update 接口，用「先建新、再删旧」实现，
  /// cron/启停状态原样保留（createAutomation 支持带 enabled）。
  /// 代价：换新 automationId → 已跑次数与执行历史清零。
  Future<void> updateAutomation(
    AutomationView a, {
    required String title,
    required String prompt,
  }) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    final created = await bridge.channels.call(
      Chan.agent,
      'createAutomation',
      [
        {
          ..._automationScope,
          'title': title,
          'cronExpr': a.cronExpr,
          'prompt': prompt,
          'recurring': a.recurring,
          if (a.maxRuns != null) 'maxRuns': a.maxRuns,
          'enabled': a.enabled,
        },
      ],
      timeout: const Duration(seconds: 20),
    );
    final createdMap =
        created is Map ? (created['automation'] as Map? ?? created) : const {};
    final newId = '${createdMap['automationId'] ?? ''}';
    if (newId.isEmpty) throw StateError('createAutomation 未返回 automationId');
    await deleteAutomation(a.id, workspacePath: a.workspacePath);
    await loadAutomations();
  }

  /// 会话右上角直建定时任务：任务名=会话名，内容用户原文直输不经转述。
  /// 先带 targetTaskId 绑定当前会话；桌面端不认该字段时去参重试保成功。
  Future<void> createAutomationForSession({
    required String sessionId,
    required String sessionTitle,
    required String cronExpr,
    required String prompt,
  }) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    final base = <String, dynamic>{
      ..._automationScope,
      'title': sessionTitle.isEmpty ? '定时任务' : sessionTitle,
      'cronExpr': cronExpr,
      'prompt': prompt,
      'recurring': true,
      'enabled': true,
    };
    Object? lastErr;
    for (final withTarget in const [true, false]) {
      try {
        await bridge.channels.call(
          Chan.agent,
          'createAutomation',
          [
            {...base, if (withTarget) 'targetTaskId': sessionId},
          ],
          timeout: const Duration(seconds: 20),
        );
        await loadAutomations();
        return;
      } on Object catch (e) {
        lastErr = e;
      }
    }
    throw StateError('创建失败: $lastErr');
  }

  /// 重启自动化（协议参考文档列为标准方法）：重置其调度状态并按 cron
  /// 重新排程——自动化状态异常（不触发/重复触发）时的自救手段。
  Future<void> restartAutomation(String automationId) async {
    final bridge = this.bridge;
    if (bridge == null) throw StateError('未连接');
    await bridge.channels.call(Chan.agent, 'restartAutomation', [
      {..._automationScope, 'automationId': automationId},
    ], timeout: const Duration(seconds: 15));
    notifyListeners();
  }

  // ------------------------------------------------------------ usage stats

  /// 用量统计原始快照（usage-stats.getAppUsageSnapshot，探针实测：
  /// 参数 [{range: all|7d|30d, timeZone?}]，无 scope——统计是整机级的）。
  Map<String, dynamic>? usageStats;
  bool usageStatsLoading = false;
  String usageStatsRange = '7d';

  /// 加载用量快照；失败静默 + log（用量页保旧数据展示）。
  Future<void> loadUsageStats({String range = '7d'}) async {
    final bridge = this.bridge;
    if (bridge == null) return;
    usageStatsLoading = true;
    usageStatsRange = range;
    notifyListeners();
    try {
      final res = await bridge.channels.call(
        Chan.usageStats,
        'getAppUsageSnapshot',
        [
          {'range': range, 'timeZone': deviceTimeZoneLabel()},
        ],
        timeout: const Duration(seconds: 20),
      );
      usageStats = res is Map ? res.cast<String, dynamic>() : null;
      if (usageStats == null) log('[usage] 快照形状认不出: $res');
    } on Object catch (e) {
      log('[usage] 用量统计加载失败: $e');
    } finally {
      usageStatsLoading = false;
      notifyListeners();
    }
  }

  /// 取消归档：从归档集合移回主列表头部。
  ///
  /// 归位到**任务自己所属的项目**，不是"当前项目"——从归档 tab 取消归档一个
  /// 别的项目的会话时，塞进当前项目的列表会让它看起来换了项目。
  Future<void> unarchiveTask(String taskId) async {
    Map<String, dynamic> t;
    try {
      t = archivedTasks.firstWhere(
        (e) => '${e['taskId']}' == taskId,
      );
    } on StateError {
      t = {'taskId': taskId};
    }
    final taskKey = taskProjectKey(t);
    // 跨项目直发即可（同 archiveTask）：桌面端按参数 workspacePath 路由。
    await _taskCall('unarchiveTask', _taskScope(t));
    archivedTasks = [
      for (final x in archivedTasks)
        if ('${x['taskId']}' != taskId) x,
    ];
    _archivedTaskIds.remove(taskId);
    // 只在"它属于当前项目"时补进 tasks；属于别的项目就留给那个项目自己刷，
    // 否则又是一张错项目的卡。
    final nowKey = workspace == null ? null : workspaceKeyOf(workspace!);
    if (taskKey == null || taskKey == nowKey) {
      tasks = [{...t}, ...tasks];
    }
    _invalidatePinnedCache();
    notifyListeners();
  }

  /// sessions-index 的实时 phase / 预览合入任务卡。
  /// 时间戳一并合入（index-only 卡也要能参与最新排序），
  /// 最终顺序由 _composeVisibleTasks → sortTaskCards 统一收敛。
  void _mergeIndexIntoTasks() {
    final index = indexSub?.state;
    if (index == null || !index.ready) return;
    final byId = {for (final t in tasks) '${t['taskId']}': t};
    // 索引流只**增补**已存在的卡片（标题/相位/活跃时间/预览），不再把
    // 「索引有、列表没有」的会话重建成新卡——那是幽灵复活的口子：跨项目
    // 删除只摘了列表条目时，别端下次加载会把它变回来。列表成员一律以
    // 服务端 listTasks 为准（多端一致性批次，用户裁定：下次加载必一致）。
    // 新会话的及时可见由 createSession 成功后主动 loadTasks 承担。
    for (final entry in index.list) {
      final existing = byId[entry.sessionId];
      if (existing != null) {
        // 本地重命名覆盖优先：索引还没追上新标题（仍是旧值非空）时，
        // 不能把用户刚改的名字踩回旧名。
        final override = _titleOverrides[entry.sessionId];
        byId[entry.sessionId] = {
          ...existing,
          'title': override is String
              ? override
              : entry.title.isNotEmpty
              ? entry.title
              : existing['title'],
          'phase': entry.phase,
          if (entry.lastActivityAt > 0) 'lastActivityAt': entry.lastActivityAt,
          'lastAssistantPreview': entry.lastAssistantPreview,
          'pendingInteraction': entry.pendingInteraction,
        };
      }
    }
    final ordered = <Map<String, dynamic>>[];
    for (final entry in index.list) {
      final t = byId.remove(entry.sessionId);
      if (t != null) ordered.add(t);
    }
    tasks = _composeVisibleTasks([...ordered, ...byId.values]);
    // 「全部对话」视图同样吃索引流的实时增补——不然运行/空闲永远停在
    // 连接时刻的 bootstrap 快照上（用户报障：对话运行中显示空闲）。
    // 只在用户正看着这个视图时才重组：索引流没有微批、每帧都来，
    // 整机卡片的全量重建不能在单项目视图里白烧。
    if (viewingAllProjects) {
      allProjectTasks = _composeVisibleAllTasks(allProjectTasks);
    }
  }

  void refreshFromIndex() {
    // index 一到就是"追平"的自然时机：检查待释放的覆盖能不能撤了。
    if (_pendingPhaseRelease.isNotEmpty) {
      for (final id in _pendingPhaseRelease.keys.toList()) {
        _tryReleaseLivePhase(id);
      }
    }
    // 通知的变迁检测必须**逐帧**看：相位可能一闪而过，被微批合并掉就漏报了。
    final index = indexSub?.state;
    if (index != null && index.ready) _watchTaskEvents(index.list);
    // 重组是贵的（整机卡片全量重建 + 排序，默认视图又是最贵的「全部对话」），
    // 而索引流在流式期间每帧都来——合并成 200ms 一次，且内容没变不通知。
    // 逐帧 notify 等于让整页 setState 跟着索引帧的频率跑（用户报的"变慢"）。
    _indexRefreshTimer ??= Timer(_indexRefreshBatch, _applyIndexRefresh);
  }

  static const _indexRefreshBatch = Duration(milliseconds: 200);
  Timer? _indexRefreshTimer;

  void _applyIndexRefresh() {
    _indexRefreshTimer = null;
    final before = '${cardsSignature(tasks)}#${cardsSignature(allProjectTasks)}';
    _mergeIndexIntoTasks();
    if ('${cardsSignature(tasks)}#${cardsSignature(allProjectTasks)}' ==
        before) {
      return; // 可见内容没变：不通知，整页不重建
    }
    notifyListeners();
  }

  // -------------------------------------------------------- notifications

  /// 上一帧各会话 phase 快照（通知变迁检测用）；首帧只记录不响。
  final _lastPhases = <String, String>{};
  final _lastWaiting = <String, bool>{};
  bool _phaseWatchPrimed = false;
  final _notifiedTitles = <String, String>{};

  /// 会话名缓存：通知里要有可读标题（index 帧带 title）。
  String _titleFor(String sessionId, String fallback) {
    final cached = _notifiedTitles[sessionId];
    if (cached != null && cached.isNotEmpty) return cached;
    if (fallback.isNotEmpty) {
      _notifiedTitles[sessionId] = fallback;
      return fallback;
    }
    return sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
  }

  /// index 帧驱动的变迁检测 → 系统通知（完成/中断/报错/等待确认）。
  void _watchTaskEvents(List<SessionEntry> entries) {
    for (final e in entries) {
      if (e.title.isNotEmpty) _notifiedTitles[e.sessionId] = e.title;
      final prevPhase = _lastPhases[e.sessionId];
      final prevWaiting = _lastWaiting[e.sessionId] ?? false;
      final nextWaiting = e.pendingInteraction != null;
      _lastPhases[e.sessionId] = e.phase;
      _lastWaiting[e.sessionId] = nextWaiting;
      if (!_phaseWatchPrimed) continue;
      final event = detectTaskEvent(
        prevPhase,
        e.phase,
        prevWaiting: prevWaiting,
        nextWaiting: nextWaiting,
      );
      if (event == null) continue;
      // 与全局轮询共用去重账：同一会话的终结类事件 90s 内只提醒一次
      // （实时通道先报了，轮询通道就不再重复报）。
      final dkey =
          '${e.sessionId}#${event.kind == TaskEventKind.waitingInput ? 'wait' : 'end'}';
      if (!_shouldNotify(dkey)) continue;
      final title = _titleFor(e.sessionId, e.title);
      // 报错通知带具体原因（桌面端 lastError 结构体，BUG-33 同源解析）；
      // 解析不出就保持通用提示，不为凑详情硬编。
      final detail = event.kind == TaskEventKind.error
          ? errorValueText(e.raw['lastError'] ?? e.raw['error'])
          : null;
      NotificationService.showTaskEvent(
        id: e.sessionId.hashCode & 0x7fffffff,
        title: '${event.title} · $title',
        body: taskEventHint(event.kind),
        detail: detail,
        sessionId: e.sessionId,
      );
    }
    _phaseWatchPrimed = true;
  }

  // ---------------------------------------------- 全局轮询通知（跨项目）

  /// 通知去重账（key → 上次提醒时间戳毫秒）。实时索引与全局轮询两条
  /// 通道都可能看到同一事件——90s 窗口内同一账目只提醒一次。
  final _recentNotified = <String, int>{};

  bool _shouldNotify(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _recentNotified[key];
    if (last != null && now - last < 90 * 1000) return false;
    _recentNotified[key] = now;
    if (_recentNotified.length > 300) {
      _recentNotified.removeWhere((_, t) => now - t > 90 * 1000);
    }
    return true;
  }

  /// 全局轮询的相位基线（taskId → meta.status），首帧只记录不响。
  final _pollPhases = <String, String>{};

  Timer? _pollTicker;

  /// 跨项目任务事件轮询：一次 listTaskList(workspaceScopes: 全部项目)
  /// 查完所有项目的任务状态（host 级通道按参数路由，不切桥）。
  /// 场景（用户点单）：提交任务后去玩手机，**任何一个项目**的会话
  /// 报错/完成都要弹通知——实时索引只覆盖当前项目，这条慢通道补全覆盖。
  /// 刻意不受前台门控：App 切后台也要继续轮询（Android 挂起前尽力而为，
  /// 与既有通知同一进程级限制）。
  Future<void> _pollGlobalTaskEvents() async {
    if (!NotificationService.enabled) return;
    final bridge = this.bridge;
    if (bridge == null || workspaces.isEmpty) return;
    // workspaceScopes 要的是**工作区对象**（桌面 normalizeWorkspaceKeys
    // 对每个元素取 workspaceIdentity/workspacePath——发纯字符串会让它
    // 对 undefined 调 .trim 直接炸，实测 FAIL 证据在桌面日志）。
    final scopes = [
      for (final w in workspaces)
        if (w['workspacePath'] != null)
          {
            'workspacePath': w['workspacePath'],
            if (w['workspaceIdentity'] != null)
              'workspaceIdentity': w['workspaceIdentity'],
            if (workspaceKeyOf(w) != null) 'workspaceKey': workspaceKeyOf(w),
          },
    ];
    if (scopes.isEmpty) return;
    try {
      final res = await bridge.channels.call(Chan.task, 'listTaskList', [
        {'workspaceScopes': scopes},
      ], timeout: const Duration(seconds: 10));
      final items = castMapList(res is Map ? res['items'] : res);
      for (final t in items) {
        final id = '${t['taskId'] ?? ''}';
        if (id.isEmpty) continue;
        final status = '${t['status'] ?? ''}';
        final prev = _pollPhases[id];
        _pollPhases[id] = status;
        final event = detectPollTaskEvent(prev, status);
        if (event == null) continue;
        if (!_shouldNotify('$id#${event.dedupeKey}')) continue;
        final tTitle = '${t['title'] ?? ''}';
        final shortTitle = tTitle.isNotEmpty
            ? tTitle
            : (id.length > 8 ? id.substring(0, 8) : id);
        unawaited(NotificationService.showTaskEvent(
          id: id.hashCode & 0x7fffffff,
          title: '${event.title} · $shortTitle',
          body: event.body,
          detail: event.title == '任务报错'
              ? errorValueText(t['lastError'])
              : null,
          sessionId: id,
        ));
      }
    } on Object catch (e) {
      // 轮询失败静默重试（桥抖动/超时），但节流记一条日志——
      // 参数形状这类持续性问题要能在 App 日志里看到痕迹。
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPollFailLogAt > 5 * 60 * 1000) {
        _lastPollFailLogAt = now;
        log('[poll] 全局任务轮询失败（5 分钟内不再重复记）: $e');
      }
    }
  }

  int _lastPollFailLogAt = 0;

  /// 模型 / 思考等级 / 模式选项（zcode-task.prepareWorkspace）。
  /// 实测这一步本身要 1.7~3.3s，是最该给用户让路的一个。
  Future<void> loadPrep({bool force = false}) async {
    if (!force && !_backgroundGate('prep')) return;
    final conv = this.conv;
    if (conv == null) {
      prepError = '桥未就绪（未连接桌面端），稍后重试';
      notifyListeners();
      return;
    }
    prepLoading = true;
    prepError = null;
    notifyListeners();
    try {
      final res = await conv.prepareWorkspace();
      if (res is Map) {
        prep = res.cast<String, dynamic>();
      } else {
        prep = const {};
        prepError = '服务端返回了意外类型：${res.runtimeType}';
        log('[app] prepareWorkspace 非 Map: ${res.runtimeType} $res');
      }
      _slashCommands = castMapList(prep['slashCommands']);
      final opts = prep['configOptions'];
      if (opts is! List || opts.isEmpty) {
        log('[app] prepareWorkspace 无选项: keys=${prep.keys.toList()}');
      }
      notifyListeners();
    } on Object catch (e) {
      prepError = 'prepareWorkspace 失败: $e';
      log('[app] prepareWorkspace 失败: $e');
    } finally {
      prepLoading = false;
      notifyListeners();
    }
  }

  Map<String, dynamic>? configOption(String id) {
    final options = prep['configOptions'];
    if (options is! List) return null;
    for (final o in options) {
      if (o is Map && o['id'] == id) return o.cast<String, dynamic>();
    }
    return null;
  }

  /// 选项组里的 options 列表（模型 / 思考等级 / 模式弹层共用）。
  List<Map<String, dynamic>> configOptionList(String id) =>
      castMapList(configOption(id)?['options']);

  /// prepareWorkspace 返回的斜杠命令（composer `/` 触发），loadPrep 时缓存。
  List<Map<String, dynamic>> get slashCommands => _slashCommands;

  /// skills.list —— 失败给空列表（协议层已兜底）。
  Future<void> loadSkills() async {
    if (!_backgroundGate('skills')) return;
    final c = conv;
    if (c == null) return;
    skills = await c.skills();
    notifyListeners();
  }

  // ----------------------------------------------------------------- chat

  /// 正在打开的那个会话（切桥 + 订阅在飞）。并发来的同一个会话直接复用，
  /// 别发第二条订阅——见 `session_open_logic.dart` 的说明。
  Future<void>? _opening;
  String? _openingSid;

  /// 「本机历史」快照：最近看过的几个会话的**最后一份消息行**。
  ///
  /// 用户裁定（2026-09-13）：切会话要**立刻有内容**，不要一进去就等服务端
  /// （实测订阅中位 4ms、撞上排空暴发能到 22.6s）；允许与平板/PC 不一致，
  /// 要准就下拉刷新。所以切走/断桥前把行留一份，下次进同一个会话先拿它顶上，
  /// 服务端订阅在后台补、落地后自动换成活的。
  ///
  /// 存的是**拷贝**（新 ConversationState + 行列表浅拷贝）：原 state 会随
  /// 订阅销毁，留着引用等于抱着个已被 dispose 的 ChangeNotifier。只留最近
  /// [_snapshotKeep] 个——行里挂着图片描述，别囤。
  final _chatSnapshots = <String, ConversationState>{};
  static const _snapshotKeep = 3;

  /// 本机历史快照（没有给 null）。只用于**先把内容画出来**，不参与
  /// 运行状态/发送判定——那些一律以活订阅为准。
  ConversationState? chatSnapshot(String sessionId) =>
      _chatSnapshots[sessionId];

  /// 丢掉 `chat` 之前先把它的行收一份下来（切会话/切桥/断开都走这里）。
  void _stashChat() {
    final c = chat;
    if (c == null) return;
    final st = c.state;
    if (st.rows.isEmpty) return; // 空会话没什么可顶的
    _chatSnapshots.remove(c.sessionId);
    _chatSnapshots[c.sessionId] = ConversationState()
      ..rows = List<Map<String, dynamic>>.of(st.rows)
      ..firstRowId = st.firstRowId
      ..totalCount = st.totalCount;
    while (_chatSnapshots.length > _snapshotKeep) {
      _chatSnapshots.remove(_chatSnapshots.keys.first); // 插入序 = 最旧的先走
    }
  }

  /// 打开已有会话（sessionId == taskId）。
  ///
  /// 这一步就是实测里最慢的 `subscribeConversationV4`（中位 4ms，撞上排空
  /// 暴发能到 22.6s）。它必须独占队列：整段包在 [_asForeground] 里，
  /// 期间后台补拉让路，别让用户的开会话排在我们自己的补拉后面。
  ///
  /// **乐观切换**（用户裁定 2026-09-13）：调用方（列表点卡片）不再先 await
  /// 切桥再跳转——那样切桥的几秒里界面毫无反馈，表现为「第一次点不出来、
  /// 第二次才出来」。现在切桥挪进这里，在后台跟订阅一起做，用户已经在
  /// 聊天页里了。发送路径用 [ensureSessionReady] 等它。
  Future<void> openSession(String sessionId) {
    final plan = sessionOpenPlan(
      sessionId: sessionId,
      openingSid: _openingSid,
    );
    if (plan == SessionOpenPlan.awaitInflight) return _opening!;
    final gen = ++_openGen;
    // 从**这一刻**就算在打开：切桥（对齐项目）也在打开过程里，而它还没走到
    // `_openSession`。不在这里置位的话，聊天页会看到 "chatLoading=false +
    // chat=null" 而闪一屏「会话订阅失败」（用户实测反馈）。
    chatLoading = true;
    chatError = null;
    notifyListeners();
    final fut = _asForeground(() => _openSessionAligned(sessionId, gen));
    _opening = fut;
    _openingSid = sessionId;
    // 失败如实记下来给页面用；同时保持 fut 本身的错误语义（发送路径要 await
    // 它并据此回显失败），所以这里另挂一个只做记账的监听。
    unawaited(
      fut.then<void>(
        (_) {},
        onError: (Object e) {
          if (gen != _openGen) return;
          chatError = '$e';
          chatLoading = false;
          notifyListeners();
        },
      ),
    );
    return fut.whenComplete(() {
      if (identical(_opening, fut)) {
        _opening = null;
        _openingSid = null;
      }
    });
  }

  /// 发送前的就绪闸门：没订上就把这次打开等完。
  Future<void> ensureSessionReady(String sessionId) {
    final plan = sessionReadyPlan(
      sessionId: sessionId,
      chatSid: chat?.sessionId,
      openingSid: _openingSid,
    );
    switch (plan) {
      case SessionReadyPlan.sendNow:
        return Future<void>.value();
      case SessionReadyPlan.awaitInflight:
        return _opening!;
      case SessionReadyPlan.openThenSend:
        return openSession(sessionId);
    }
  }

  /// 对齐项目再订阅：「全部对话」里点别的项目的会话，桥得先切过去，
  /// 否则订阅会打到错的项目上（开不出来或开错）。
  Future<void> _openSessionAligned(String sessionId, int gen) async {
    // 查不到 = 新会话还没进列表/索引：**不切桥**（桥本就是对的，见
    // `_taskByIdOrNull` 的说明），直接订阅。查得到才需要对齐项目。
    final t = _taskByIdOrNull(sessionId);
    if (t != null) {
      final ok = await ensureTaskProject(t);
      if (!ok) throw StateError('这个会话所属的项目现在连不上');
    }
    await _openSession(sessionId, gen);
  }

  /// 每次打开自增：并发打开时用它判断"我这次还算不算数"。
  /// 乐观切换之后并发打开成了常态（点 A 又点 B、重连重试），不作废的话
  /// 先发的慢请求回来会把 `chat` 覆盖成**上一个会话**，订阅还漏着不释放。
  int _openGen = 0;

  Future<void> _openSession(String sessionId, int gen) async {
    final conv = this.conv;
    if (conv == null) {
      // 切桥失败已经把 chatError 记下了；这里补一句更好懂的（桥没立起来）。
      chatError ??= '桥未就绪';
      chatLoading = false;
      notifyListeners();
      return;
    }
    chatLoading = true;
    _stashChat();
    chat = null;
    notifyListeners();
    try {
      final sub = await conv.subscribe(sessionId);
      if (gen != _openGen) {
        // 已被更新的那次打开顶掉：结果作废，订阅还回去，别留在桥上。
        unawaited(sub.dispose());
        return;
      }
      chat = sub;
      chatLoading = false;
      notifyListeners();
      // 权威历史计划异步拉一次：滑出窗口/换设备的计划不再丢。
      unawaited(_loadHistoricalPlan(sessionId));
      // 首屏补到 100 条就停（桌面端快照只给 60）——用户裁定：一个会话
      // 几千条，**不要一进来就全拉**，要看全部得用户自己点「拉取全部」。
      unawaited(_topUpInitialHistory(sub, gen));
    } on Object {
      if (gen == _openGen) {
        chatLoading = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  /// 新对话草稿（首条消息触发 createSession）。
  void newDraft() {
    _stashChat();
    chat = null;
    chatLoading = false;
    chatError = null;
    notifyListeners();
  }

  /// 批量拉取历史进行中（列表顶部入口据此显示进度、防重复触发）。
  bool historyPulling = false;

  /// 首屏补历史：订阅快照默认只有 60 行，补到 [kInitialHistoryRows] 就停。
  /// 补不动也不影响使用（进来就能看能发），失败只记日志。
  Future<void> _topUpInitialHistory(ConvSubscription sub, int gen) async {
    final st = sub.state;
    final want = kInitialHistoryRows - st.rows.length;
    if (!st.hasMoreOlder || want <= 0) return;
    try {
      await sub.loadOlder(limit: want);
      if (gen == _openGen) notifyListeners();
    } on Object catch (e) {
      log('[app] 首屏补历史失败: $e');
    }
  }

  /// 拉取整个会话历史（**用户显式动作**，用户裁定 2026-09-13）。
  ///
  /// 探针实测：快照给 60 行、`totalCount` 是整个会话（例：4083 行），
  /// 翻页一轮一页。所以"要看全部"是一次几十轮的循环——不能自动做，
  /// 得用户点。先试大页（[kHistoryBulkPageSize]），一轮 0 进账就退回
  /// 小页（实测 limit=300 桌面端会一轮不给），仍无进展就收手。
  Future<void> pullAllHistory() async {
    final sub = chat;
    if (sub == null || historyPulling) return;
    final st = sub.state;
    historyPulling = true;
    notifyListeners();
    var last = st.rows.length;
    var stall = 0;
    try {
      while (shouldKeepPulling(
        hasMoreOlder: st.hasMoreOlder,
        loaded: st.rows.length,
        lastLoaded: last,
        stallRounds: stall,
      )) {
        await sub.loadOlder(
          limit: stall == 0 ? kHistoryBulkPageSize : kHistoryPageSize,
        );
        if (st.rows.length <= last) {
          stall++;
        } else {
          stall = 0;
          last = st.rows.length;
        }
        notifyListeners(); // 进度：列表顶部显示 已加载/总数
      }
      log('[app] 历史拉取结束 ${st.rows.length}/${st.totalCount}');
    } on Object catch (e) {
      log('[app] 历史拉取中断: $e');
    } finally {
      historyPulling = false;
      notifyListeners();
    }
  }

  Future<void> _loadHistoricalPlan(String sessionId) async {
    final c = conv;
    if (c == null) return;
    try {
      final plan = latestPlanPayload(await c.plans(sessionId));
      final st = chat?.state;
      if (plan != null && st != null && st.historicalPlan == null) {
        st.setHistoricalPlan(plan);
      }
    } on Object catch (e) {
      log('[app] 计划查询失败: $e');
    }
  }

  void closeChat() {
    _stashChat();
    chat = null;
    chatError = null;
    notifyListeners();
  }

  Future<String> createSession(
    String? firstText,
    Map<String, dynamic>? config,
  ) async {
    final conv = this.conv!;
    final key = workspaceKeyOf(workspace ?? const {}) ?? '';
    final sessionId = await conv.createSession(
      key,
      firstText: firstText,
      config: config,
    );
    // 索引流不再复活幽灵卡（多端一致性批次），新会话的卡片由服务端列表
    // 承担——建完立刻拉一次，本机不用等下一轮轮询才看到。
    unawaited(loadTasks());
    return sessionId;
  }

  // ------------------------------------------------------------- commands

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    List<Map<String, dynamic>>? attachments,
  }) {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    return conv.sendText(
      sessionId,
      text,
      heldQueueDisposition: heldQueueDisposition,
      expectedHeldQueueItemIds: expectedHeldQueueItemIds,
      attachments: attachments,
    );
  }

  Future<dynamic> stop(String sessionId) => conv!.stop(sessionId);

  Future<dynamic> switchModel(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) {
    return conv!.switchModelConfig(
      sessionId,
      provider: provider,
      model: model,
      thought: thought,
    );
  }

  Future<dynamic> switchMode(String sessionId, String mode) =>
      conv!.switchCollaborationMode(sessionId, mode);

  Future<dynamic> setApprovalMode(String sessionId, String mode) =>
      conv!.setApprovalMode(sessionId, mode);

  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      conv!.setFollowupMode(sessionId, mode);

  Future<dynamic> compact(String sessionId) => conv!.compact(sessionId);

  Future<dynamic> pauseGoal(String sessionId) => conv!.pauseGoal(sessionId);

  Future<dynamic> resumeGoal(String sessionId) => conv!.resumeGoal(sessionId);

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      conv!.retryTurn(sessionId, target);

  /// 编辑已发用户消息并重发（行级 CAS，服务端截断本回合后重跑）。
  Future<dynamic> editUserQuery(
    String sessionId, {
    required int rowId,
    required String entityId,
    required String newText,
  }) => conv!.editUserQuery(
    sessionId,
    rowId: rowId,
    entityId: entityId,
    newText: newText,
  );

  /// 回复点赞/点踩；feedback: 'like' / 'dislike' / null（撤销）。
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => conv!.setAssistantFeedback(sessionId, target, feedback);

  /// 本会话改动过的文件清单（conversationFileChangesV4）。
  Future<List<Map<String, dynamic>>> fileChanges(String sessionId) =>
      conv!.fileChanges(sessionId);

  /// 上传附件；[sessionId] 传空串时先创建空会话再上传（见 ChatPage._send）。
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    return conv.attachmentPut(
      sessionId,
      fileName: fileName,
      mime: mime,
      bytes: bytes,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// 读回附件字节（聊天记录里回显图片用）。
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    return conv.attachmentRead(sessionId, ref: ref);
  }

  /// 回滚预览：回滚最近回合会动哪些文件（行级 target + CAS 同 fileChanges）。
  Future<List<Map<String, dynamic>>> fileRewindPreview(String sessionId) {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    return conv.fileRewindPreview(sessionId);
  }

  /// 文件回滚：把最近回合的文件改动恢复为回合前状态（行级 CAS）。
  Future<dynamic> applyFileRewind(String sessionId) {
    final conv = this.conv;
    if (conv == null) throw StateError('未连接');
    return conv.applyFileRewind(sessionId);
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) {
    return conv!.resolveInteraction(
      sessionId,
      interactionId,
      optionId: optionId,
      freeText: freeText,
      action: action,
      content: content,
    );
  }

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      conv!.sendQueuedNow(sessionId, queueItemId);

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      conv!.deleteQueueItem(sessionId, queueItemId);

  /// 编辑排队中的消息。
  Future<dynamic> editQueueItem(
    String sessionId, {
    required String queueItemId,
    required String newText,
  }) => conv!.editQueueItem(
    sessionId,
    queueItemId: queueItemId,
    newText: newText,
  );

  /// 队列重排：移到 beforeQueueItemId 之前。
  Future<dynamic> reorderQueueItem(
    String sessionId, {
    required String queueItemId,
    String? beforeQueueItemId,
  }) => conv!.reorderQueueItem(
    sessionId,
    queueItemId: queueItemId,
    beforeQueueItemId: beforeQueueItemId,
  );

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      conv!.setAutoDrain(sessionId, autoDrain);

  @override
  void dispose() {
    logsRevision.dispose();
    _pushSub?.cancel();
    _indexRefreshTimer?.cancel();
    _tokenTicker?.cancel();
    _pollTicker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_onRelayChanged != null) {
      session?.relay.stateListenable.removeListener(_onRelayChanged!);
    }
    chat?.dispose();
    _phaseReleaseTimer?.cancel();
    indexSub?.dispose();
    conv?.dispose();
    bridge?.dispose();
    session?.dispose();
    super.dispose();
  }
}
