# 批次一接口接入 + 追问模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把协议层已就绪的 5 个接口（历史翻页/压缩上下文/重新生成/计划查询/技能+斜杠命令）接上 UI，并加追问模式（setFollowupMode）；输入区归纳为一个 `+` 插入键弹层。

**Architecture:** 纯逻辑（rowsRange 解析、合并去重、计划载荷提取、`/` `$` 联想）放可测的顶层函数与 ConversationState；协议方法在 conversation.dart 补 setFollowupMode；ZApp 做透传与缓存；ChatPage 只做接线。TDD：先写 test/batch1_test.dart 看红，再实现看绿。

**Tech Stack:** Flutter/Dart，无新依赖。分支 `feat/batch1-interfaces`。

---

### Task 1: 历史翻页（rowsRange）状态逻辑

**Files:**
- Modify: `lib/protocol/conversation.dart`（顶层 `parseRowsRangeResult`；`ConversationState` 加 `loadingOlder`/`mergeOlder`/`hasMoreOlder`；`ConvSubscription.loadOlder`）
- Test: `test/batch1_test.dart`（新建）

- [ ] **Step 1: 写失败测试**

```dart
test('parseRowsRangeResult: List 直通 / Map.rows / Map.window / 垃圾值', () {
  final row = {'rowId': 1, 'kind': 'userInput'};
  expect(parseRowsRangeResult([row]), [row]);
  expect(parseRowsRangeResult({'rows': [row]}), [row]);
  expect(parseRowsRangeResult({'window': [row]}), [row]);
  expect(parseRowsRangeResult('junk'), isEmpty);
  expect(parseRowsRangeResult({'rows': ['x', row]}), [row]); // 非 Map 剔除
});

test('mergeOlder: 去重、按 rowId 升序前置、更新 firstRowId', () {
  final st = ConversationState();
  st.rows = [
    {'rowId': 5, 'kind': 'userInput'},
    {'rowId': 6, 'kind': 'assistantText'},
  ];
  st.firstRowId = 5;
  st.totalCount = 8;
  st.mergeOlder([
    {'rowId': 6, 'kind': 'dup'},        // 去重
    {'rowId': 4, 'kind': 'a'},
    {'rowId': 3, 'kind': 'b'},          // 乱序 → 排成 3,4
  ]);
  expect(st.rows.map((r) => r['rowId']), [3, 4, 5, 6]);
  expect(st.firstRowId, 3);
  expect(st.loadingOlder, false);
});

test('hasMoreOlder: rows.length < totalCount 且 firstRowId 非空', () {
  final st = ConversationState();
  expect(st.hasMoreOlder, false);
  st.firstRowId = 10;
  st.rows = [for (var i = 10; i < 15; i++) {'rowId': i}];
  st.totalCount = 20;
  expect(st.hasMoreOlder, true);
  st.totalCount = 5;
  expect(st.hasMoreOlder, false);
});
```

- [ ] **Step 2: 跑测试确认红** — `flutter test test/batch1_test.dart`，预期编译错（函数不存在）。
- [ ] **Step 3: 实现**（conversation.dart）

```dart
/// rowsRange 结果解析：List 直通；Map 取 rows/window/items。
List<Map<String, dynamic>> parseRowsRangeResult(Object? res) {
  Object? list = res;
  if (res is Map) {
    list = res['rows'] ?? res['window'] ?? res['items'];
    if (list == null && res['row'] is Map) list = [res['row']];
  }
  if (list is! List) return const [];
  return [
    for (final r in list) if (r is Map) r.cast<String, dynamic>(),
  ];
}
```

ConversationState 加字段与方法：

```dart
bool loadingOlder = false;

bool get hasMoreOlder => firstRowId != null && rows.length < totalCount;

/// rowsRange 拉回的更早行：去重、升序、前置合并。
void mergeOlder(List<Map<String, dynamic>> older) {
  final known = {for (final r in rows) (r['rowId'] as num?)?.toInt(): true};
  final fresh = [
    for (final r in older)
      if (r['rowId'] != null && !known.containsKey((r['rowId'] as num?)?.toInt())) r,
  ]..sort((a, b) => ((a['rowId'] as num?)?.toInt() ?? 0)
      .compareTo((b['rowId'] as num?)?.toInt() ?? 0));
  if (fresh.isNotEmpty) {
    rows = [...fresh, ...rows];
    firstRowId = (rows.first['rowId'] as num?)?.toInt();
  }
  loadingOlder = false;
  notifyListeners();
}
```

ConvSubscription 加：

```dart
/// 上滑翻页：拉更早的行前置合并（hasMoreOlder 才发请求）。
Future<void> loadOlder({int limit = 60}) async {
  final head = state.firstRowId;
  if (head == null || state.loadingOlder || !state.hasMoreOlder) return;
  state.loadingOlder = true;
  state.notifyListeners();
  try {
    final res =
        await transport.rowsRange(sessionId, beforeRowId: head, limit: limit);
    final older = [
      for (final r in parseRowsRangeResult(res))
        if (((r['rowId'] as num?)?.toInt() ?? head) < head) r,
    ];
    state.mergeOlder(older);
  } on Object catch (e) {
    state.loadingOlder = false;
    state.notifyListeners();
    transport._log('[v4] rowsRange failed: $e');
  }
}
```

- [ ] **Step 4: 跑测试看绿**，然后 ChatPage 接线（Task 7 一并验证）。
- [ ] **Step 5: Commit** `feat: 历史翻页状态逻辑（rowsRange 解析+合并）`

### Task 2: ChatPage 上滑触发翻页

**Files:** Modify `lib/ui/chat_page.dart`（ScrollController + 触发 + 顶部加载条）

- [ ] Step 1: `_ChatPageState` 加 `final _scroll = ScrollController();`，initState 监听：

```dart
_scroll.addListener(() {
  final pos = _scroll.position;
  // reverse 列表：滚得越深内容越旧；接近最旧端 600px 内翻页。
  if (pos.maxScrollExtent - pos.pixels < 600) {
    widget.app.chat?.loadOlder();
  }
});
```

- [ ] Step 2: `_buildList` 的 ListView.builder 挂 `controller: _scroll`；`loadingOlder` 时在列表头（headerCells 前插一条）显示 `LinearProgressIndicator`。
- [ ] Step 3: dispose 释放 `_scroll`。
- [ ] Step 4: analyze；Commit `feat: 上滑加载更早消息`

### Task 3: 计划查询兜底（conversationPlansV4）

**Files:** Modify `lib/protocol/conversation.dart`（顶层 `latestPlanPayload`；ConversationState 加 `historicalPlan`）、`lib/state/app_controller.dart`（openSession 后异步拉）、`lib/ui/chat_page.dart`（derivePlanSteps fallback）

- [ ] Step 1: 失败测试：

```dart
test('latestPlanPayload: plans 列表取最新一份 plan 载荷', () {
  final plan = {'todos': [{'content': 'a'}]};
  expect(latestPlanPayload([{'planId': 'p1'}, {'planId': 'p2', 'plan': plan}]), plan);
  expect(latestPlanPayload({'plans': [{'value': plan}]}), plan);
  expect(latestPlanPayload({'plans': [{'todos': []}]}), isNotNull);
  expect(latestPlanPayload(null), isNull);
  expect(latestPlanPayload({'plans': []}), isNull);
});
```

- [ ] Step 2: 红 → 实现：

```dart
/// conversationPlansV4 结果 → 最新一份计划载荷（直接喂 derivePlanSteps）。
Object? latestPlanPayload(Object? res) {
  List? plans;
  if (res is List) {
    plans = res;
  } else if (res is Map) {
    final inner = res['plans'] ?? res['result'] ?? res['items'];
    if (inner is List) {
      plans = inner;
    } else if (res['plan'] != null) {
      return res['plan'];
    } else {
      return null;
    }
  }
  if (plans == null) return null;
  for (final item in plans.reversed) {
    if (item is! Map) continue;
    if (item['plan'] is Map || item['plan'] is List) return item['plan'];
    if (item['value'] is Map || item['value'] is List) return item['value'];
    if (item['todos'] is List || item['steps'] is List) return item;
  }
  return null;
}
```

ConversationState 加 `Object? historicalPlan;`。ZApp.openSession 订阅成功后：

```dart
unawaited(_loadHistoricalPlan(sessionId));
```

```dart
Future<void> _loadHistoricalPlan(String sessionId) async {
  final c = conv;
  if (c == null) return;
  try {
    final plan = latestPlanPayload(await c.plans(sessionId));
    final st = chat?.state;
    if (plan != null && st != null && st.historicalPlan == null) {
      st.historicalPlan = plan;
      st.notifyListeners();
    }
  } on Object catch (e) {
    log('[app] 计划查询失败: $e');
  }
}
```

- [ ] Step 3: ChatPage 两处 `derivePlanSteps(rows: …, snapshotPlan: …)` 改为

```dart
snapshotPlan: (st.plan?.isNotEmpty ?? false) ? st.plan : st.historicalPlan
```

（`_buildList` 与 `_openPlanSheet`；变量名随现场。）
- [ ] Step 4: 绿 + analyze；Commit `feat: 会话打开时拉权威计划兜底粘性缓存`

### Task 4: 追问模式 setFollowupMode

**Files:** Modify `lib/protocol/conversation.dart`、`lib/state/app_controller.dart`、`lib/ui/chat_page.dart`

- [ ] Step 1: 协议方法（'setFollowupMode' 已在 casCommands）：

```dart
Future<dynamic> setFollowupMode(String sessionId, String mode) =>
    sendCommand(sessionId, 'setFollowupMode', {'mode': mode});
```

ConversationState getter：

```dart
String get currentFollowupMode => config?['followupMode'] as String? ?? 'queue';
```

ZApp 透传：

```dart
Future<dynamic> setFollowupMode(String sessionId, String mode) =>
    conv!.setFollowupMode(sessionId, mode);
```

- [ ] Step 2: `_openOptionSheet` 加可选 `List<Map>? options` 覆写（optionId 变 `String?`），签名：

```dart
void _openOptionSheet({
  required String title,
  required IconData icon,
  required Color accent,
  String? optionId,
  List<Map>? options,
  required String current,
  required Future<void> Function(Map option) onApply,
})
```

内部 `final rows = options ?? (widget.app.configOption(optionId ?? '')?['options'] as List?)?.whereType<Map>().toList() ?? const <Map>[];`

- [ ] Step 3: 追问弹层 + 应用：

```dart
String get _curFollowup {
  final m = _state?.currentFollowupMode ?? '';
  return m.isEmpty ? 'queue' : m;
}

Future<void> _applyFollowup(Map option) async {
  final app = widget.app;
  final sid = app.chat?.sessionId ?? widget.sessionId;
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
```

- [ ] Step 4: 队列栏挂入口。build 处条件改 `if (state != null && (state.queueItems.isNotEmpty || state.isRunning)) _queueBar(state),`；`_queueBar` 头部 `Spacer()` 后插：

```dart
GestureDetector(
  onTap: _openFollowupSheet,
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    Text('追问·${state.currentFollowupMode == 'guide' ? '引导' : '排队'}',
        style: const TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w800, color: ZT.inkSoft)),
    const Icon(Icons.expand_more, size: 13, color: ZT.inkSoft),
  ]),
),
const SizedBox(width: 10),
```

items 为空时标题文案 `state.queueItems.isEmpty ? '运行中' : '排队中 ${state.queueItems.length} 条'`。
- [ ] Step 5: analyze + test；Commit `feat: 追问模式（排队/引导）切换`

### Task 5: 重新生成本轮（retryTurn）+ 失败回显真重试

**Files:** Modify `lib/state/app_controller.dart`、`lib/ui/chat_page.dart`

- [ ] Step 1: ZApp 透传：

```dart
Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
    conv!.retryTurn(sessionId, target);
```

- [ ] Step 2: `_buildList` userInput 行包长按：

```dart
final rowId = (row['rowId'] as num?)?.toInt();
Widget card = buildRowCard(row, transport: …, sessionId: …);
if (row['kind'] == 'userInput' && rowId != null) {
  card = GestureDetector(onLongPress: () => _openRowActions(rowId), child: card);
}
```

```dart
void _openRowActions(int rowId) {
  final app = widget.app;
  final sid = app.chat?.sessionId ?? widget.sessionId;
  if (sid == null) return;
  showModalBottomSheet(
    context: context,
    backgroundColor: ZT.bg,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 44, height: 4,
              decoration: BoxDecoration(color: ZT.line,
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),
          _OptionRow(
            option: const {'name': '重新生成本轮'},
            selected: false,
            accent: ZT.primaryDeep,
            onTap: () {
              Navigator.pop(sheetCtx);
              _retryTurn(sid, rowId);
            },
          ),
        ]),
      ),
    ),
  );
}

Future<void> _retryTurn(String sid, int rowId) async {
  try {
    _assertAccepted(await widget.app.retryTurn(sid, {'rowId': rowId}));
    widget.app.log('[chat] 已请求重新生成');
  } on Object catch (e) {
    if (!mounted) return;
    _flash('重新生成失败：$e', error: true);
  }
}
```

- [ ] Step 3: 失败回显重试接活（替换 `() {}`）：

```dart
_EchoBubble(
  echo: echo,
  onRetry: echo['status'] == 'failed' ? () => _retryEcho(echo) : null,
)
```

```dart
/// 失败重试：文本与附件塞回输入区，走完整发送路径（含草稿建会话）。
void _retryEcho(Map<String, Object?> echo) {
  final text = '${echo['text'] ?? ''}';
  final files = (echo['files'] as List?)
          ?.whereType<PlatformFile>()
          .toList() ??
      const <PlatformFile>[];
  setState(() {
    _echoes.remove(echo);
    if (text.isNotEmpty) _input.text = text;
    _picked.addAll(files);
  });
  _send();
}
```

- [ ] Step 4: analyze + test；Commit `feat: 重新生成本轮 + 失败消息真重试`

### Task 6: 压缩上下文（compact）

**Files:** Modify `lib/state/app_controller.dart`、`lib/ui/chat_page.dart`

- [ ] Step 1: ZApp：`Future<dynamic> compact(String sessionId) => conv!.compact(sessionId);`
- [ ] Step 2: 用量弹层底部加按钮（sheetCtx 弹层关闭后执行）：

```dart
const SizedBox(height: 14),
BigButton(
  label: '压缩上下文 · 保留要点释放窗口',
  icon: Icons.compress_rounded,
  expand: true,
  onPressed: () {
    Navigator.pop(sheetCtx);
    _compact();
  },
),
```

```dart
Future<void> _compact() async {
  final app = widget.app;
  final sid = app.chat?.sessionId ?? widget.sessionId;
  if (sid == null) return;
  try {
    await app.compact(sid);
    app.log('[chat] 已请求压缩上下文');
  } on Object catch (e) {
    if (!mounted) return;
    _flash('压缩失败：$e', error: true);
  }
}
```

- [ ] Step 3: analyze；Commit `feat: 用量面板一键压缩上下文`

### Task 7: 技能 + 斜杠命令（归纳进 `+` 插入键）+ 联想条

**Files:** Create `lib/ui/suggestions.dart`；Modify `lib/state/app_controller.dart`、`lib/ui/chat_page.dart`、`test/batch1_test.dart`

- [ ] Step 1: 失败测试：

```dart
test('buildSuggestions: / 命令前缀过滤、$ 技能、句中不提示、上限 8', () {
  final skills = [
    {'name': 'review'},
    {'name': 'deep-think', 'description': '慢思考'},
  ];
  final cmds = [
    {'command': 'fix'},
    {'name': 'init'},
  ];
  expect(buildSuggestions('/f', skills, cmds).single.token, '/fix');
  expect(buildSuggestions('$de', skills, cmds).single.token, '\$deep-think');
  expect(buildSuggestions('hi /f', skills, cmds), isEmpty);
  expect(buildSuggestions('/', skills, cmds), isEmpty);
  expect(
    buildSuggestions('', [
      for (var i = 0; i < 20; i++) {'name': 's$i'}
    ], const []).length,
    8,
  );
});
```

- [ ] Step 2: 红 → 实现 `lib/ui/suggestions.dart`（纯 Dart，无 Flutter 依赖）：

```dart
/// 输入框 `/`（斜杠命令）`$`（技能）联想：整段文本就是一个 token 时才提示。
class Suggestion {
  final String token; // 含前缀
  final String label;
  final String description;
  final bool isSkill;

  const Suggestion({
    required this.token,
    required this.label,
    required this.description,
    required this.isSkill,
  });
}

List<Suggestion> buildSuggestions(
  String text,
  List<Map<String, dynamic>> skills,
  List<Map<String, dynamic>> commands, {
  int limit = 8,
}) {
  final t = text.trim();
  if (t.length < 2 || t.contains(RegExp(r'\s'))) return const [];
  if (t.startsWith('/') || t.startsWith('\$')) {
    final isSkill = t.startsWith('\$');
    final q = t.substring(1).toLowerCase();
    if (q.isEmpty) return const [];
    final source = isSkill ? skills : commands;
    final out = <Suggestion>[];
    for (final m in source) {
      final name = _nameOf(m);
      if (name.toLowerCase().startsWith(q)) {
        out.add(Suggestion(
          token: '${isSkill ? '\$' : '/'}$name',
          label: name,
          description: _descOf(m),
          isSkill: isSkill,
        ));
        if (out.length >= limit) break;
      }
    }
    return out;
  }
  return const [];
}

String _nameOf(Map<String, dynamic> m) =>
    '${m['name'] ?? m['command'] ?? m['slug'] ?? m['id'] ?? ''}';

String _descOf(Map<String, dynamic> m) =>
    '${m['description'] ?? m['desc'] ?? m['summary'] ?? ''}';
```

- [ ] Step 3: ZApp 缓存：

```dart
/// skills.list 结果（composer $ 技能）。
List<Map<String, dynamic>> skills = const [];

List<Map<String, dynamic>> get slashCommands {
  final list = prep['slashCommands'];
  if (list is! List) return const [];
  return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
}

Future<void> loadSkills() async {
  final c = conv;
  if (c == null) return;
  skills = await c.skills();
  notifyListeners();
}
```

`openWorkspace` 里 `unawaited(loadPrep());` 后加 `unawaited(loadSkills());`。

- [ ] Step 4: ChatPage 接线：
  - 附件按钮换 `+`（`Icons.add_rounded`，tooltip `插入：文件 / 技能 / 命令`，onPressed `_sending ? null : _openInsertSheet`）；`_pickFile` 保留给弹层调用。
  - `_openInsertSheet()`：弹层含「图片 / 文件」行 + 技能 Wrap（`\$name`，grape）+ 斜杠命令 Wrap（`/name`，aqua），点击 pop 后 `_insertToken('${s.token} ')`；空列表给空态文案。AnimatedBuilder 挂 `widget.app` 保证 skills 异步到位后刷新。
  - `_insertToken`：

```dart
void _insertToken(String token) {
  _input.text = token;
  _input.selection = TextSelection.collapsed(offset: token.length);
}
```

  - 联想条：`_buildComposer` 输入行上方加 `ValueListenableBuilder<TextEditingValue>`（`valueListenable: _input`），内里 `buildSuggestions(value.text, widget.app.skills, widget.app.slashCommands)` 非空时 Wrap 渲染 stadium 小 chip（`$`grape `/`aqua，描述截 18 字），点选 `_insertToken('${s.token} ')`。
- [ ] Step 5: 绿 + analyze + 全量 test；Commit `feat: + 插入弹层（文件/技能/命令）与 / $ 联想`

### Task 8: verification + finishing

- [ ] Step 1: `Set-Location D:\tools\zremote; flutter analyze`（预期 0 issues）+ `flutter test`（预期全绿）。
- [ ] Step 2: finishing-a-development-branch：验证通过后给 4 选项（本地合并 master / 推送建 PR / 保留分支 / 丢弃）。
- [ ] Step 3: 构建部署等用户下令（铁律：不主动 build）。

## Self-Review

- 覆盖：批次一 5 项 + 追问模式 + UI 归纳（`+` 键）✓；快排 6 图标不动 ✓。
- 占位符：无；所有新函数给出完整代码。
- 类型一致：`mergeOlder(List<Map<String,dynamic>>)`、`loadOlder({int limit})`、`latestPlanPayload(Object?) → Object?`、`buildSuggestions(String, List<Map>, List<Map>, {int limit})` 各处引用一致。
- 已知风险：rowsRange/plans 返回形状未实测 → 解析器做成多形状兼容并打日志；retryTurn target 语义（userInput 行）若服务器拒绝，日志可见后调 target。
