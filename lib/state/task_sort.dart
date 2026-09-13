/// 任务卡排序纯逻辑：置顶优先，其余按最新活跃在前。无 Flutter 依赖。
library;

/// 卡片可用的最新时间戳：lastActivityAt > updatedAt > createdAt（毫秒）。
/// 三者皆缺/非法时给 0（沉底）。
int taskActivityTs(Map<String, dynamic> t) {
  for (final key in const ['lastActivityAt', 'updatedAt', 'createdAt']) {
    final v = t[key];
    if (v is num && v > 0) return v.toInt();
  }
  return 0;
}

/// 置顶组在前，**组内也按活跃时间倒序**，其余按活跃时间倒序。
/// 数据来源不限（channel 列表 / sessions-index），统一在这里收敛。
/// （2026-09-12 用户判定「保持原相对顺序」= 乱序：置顶来源顺序经过
/// channel/index/缓存多次洗牌后不可预期，改为组内同样按活跃时间排。）
List<Map<String, dynamic>> sortTaskCards(List<Map<String, dynamic>> all) {
  List<Map<String, dynamic>> byActivityDesc(List<Map<String, dynamic>> list) =>
      list..sort((a, b) => taskActivityTs(b).compareTo(taskActivityTs(a)));
  final pinned = byActivityDesc(
    all.where((t) => t['pinned'] == true).toList(),
  );
  final rest = byActivityDesc(all.where((t) => t['pinned'] != true).toList());
  return [...pinned, ...rest];
}

/// getTaskTokenUsage 结果 → 累计 token 数。形状未实测：
/// num 直通；Map 取 totalTokens/total，cumulative/usage 内层兜底，认不出给 null。
num? parseTaskTokenUsage(Object? res) {
  if (res is num) return res;
  if (res is! Map) return null;
  final r = res.cast<String, dynamic>();
  for (final v in [r['totalTokens'], r['total']]) {
    if (v is num) return v;
  }
  for (final key in const ['cumulative', 'usage']) {
    final inner = r[key];
    if (inner is Map) {
      for (final v in [inner['totalTokens'], inner['total']]) {
        if (v is num) return v;
      }
    }
  }
  return null;
}

/// token 数 → 短标签：过万 x.x万、过亿 x.x亿；null/非正给空（调用方隐藏）。
String tokenCountLabel(num? n) {
  if (n == null || n <= 0) return '';
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return '$n';
}

/// 任务卡 token 是否到了该重拉的时间：没拉过必须拉；
/// 拉过的按会话状态分 TTL——运行中 30s（数字在涨），其余 5min。
/// 没有这个过期，长跑会话的角标永远停在首次拉取的旧值。
bool tokenFetchDue(DateTime? fetchedAt, String phase, DateTime now) {
  if (fetchedAt == null) return true;
  final running = phase == 'running' || phase == 'prewarming';
  final ttl = running
      ? const Duration(seconds: 30)
      : const Duration(minutes: 5);
  return now.difference(fetchedAt) >= ttl;
}

/// 任务卡相对时间：今天 HH:mm / 昨天 / 一周内 周x / 同年 M月d日 / 跨年 yyyy/M/d。
/// 缺时间戳或未来时间（时钟偏差）给空——调用方整段隐藏。
String taskTimeLabel(Map<String, dynamic> t, {int? nowMs}) {
  final ts = taskActivityTs(t);
  if (ts <= 0) return '';
  final now = DateTime.fromMillisecondsSinceEpoch(
    nowMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  if (d.isAfter(now)) return '';
  final dayDiff = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (dayDiff == 0) {
    final hh = '${d.hour}'.padLeft(2, '0');
    final mm = '${d.minute}'.padLeft(2, '0');
    return '$hh:$mm';
  }
  if (dayDiff == 1) return '昨天';
  if (dayDiff < 7) {
    return '周${const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';
  }
  if (d.year == now.year) return '${d.month}月${d.day}日';
  return '${d.year}/${d.month}/${d.day}';
}

// ---------------------------------------------------------- 跨项目任务卡

/// 任务卡所属项目的标识：workspacePath > workspaceIdentity > workspaceKey。
/// 「全部对话」视图靠它把卡片对回具体项目，并决定点开前要不要先切桥。
String? taskProjectKey(Map<String, dynamic> t) {
  for (final key in const [
    'workspacePath',
    'workspaceIdentity',
    'workspaceKey',
  ]) {
    final v = t[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// 项目标识 → 短标签（路径尾段）。对不出路径就原样返回。
String taskProjectLabel(String key) {
  if (key.isEmpty) return '';
  final parts = key.split(RegExp(r'[\\/]'));
  return parts.lastWhere((p) => p.isNotEmpty, orElse: () => key);
}

/// `bootstrap-response` 的 `tasks[]` → 跨项目任务卡列表（「全部对话」数据源）。
///
/// 形状已实测（2026-09-12 探针 manual_bootstrap_tasks_probe_test.dart）：
/// 每条自带 taskId/title/workspacePath/model/status 等，无需外层包装。
/// 保留多形态兜底以防桌面端版本差异：
/// 元素可能是任务对象本身，也可能是 `{task: {...}, workspacePath: ...}` 这类包装
/// （工作区字段在外层）；taskId 也可能叫 id / sessionId。
/// 认不出 id 的元素直接丢弃——「全部对话」宁缺勿错，混进认不出的卡片比少一张更糟。
List<Map<String, dynamic>> parseBootstrapTasks(Object? raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final outer = item.cast<String, dynamic>();
    final inner = outer['task'] ?? outer['session'];
    final base = inner is Map
        ? {...inner.cast<String, dynamic>()}
        : {...outer};
    if (inner is Map) {
      // 包装形态下内层通常没有工作区信息，从外层补进来。
      for (final key in const [
        'workspacePath',
        'workspaceIdentity',
        'workspaceKey',
        'label',
      ]) {
        final v = outer[key];
        if (v != null) base[key] = v;
      }
    }
    final id = base['taskId'] ?? base['id'] ?? base['sessionId'];
    if (id == null || '$id'.isEmpty) continue;
    out.add({...base, 'taskId': '$id'});
  }
  return out;
}

/// 「删除进行中」会话对账的裁决结果。
class DeletionSweep {
  /// 服务端列表已无此会话 → 确认删干净（摘乐观隐藏层）。
  final Set<String> confirmed;

  /// 服务端仍在且已过宽限期 → 删除未生效，恢复显示（以服务端为准）。
  final Set<String> restore;

  const DeletionSweep({required this.confirmed, required this.restore});
}

/// 对「删除进行中」的会话做一次服务端对账（多端一致性批次）。
///
/// 原则：本机的删除只是乐观意图，不是事实。服务端列表里还看得到的会话，
/// 宽限期一到就恢复显示——旧版桌面拒删的"钉子户"不再被本机永久私藏。
/// [deleting] 由调用方按返回值自行摘除，本函数不改入参。
DeletionSweep sweepDeletions({
  required Iterable<String> serverIds,
  required Map<String, DateTime> deleting,
  required DateTime now,
  Duration grace = const Duration(seconds: 8),
}) {
  final ids = <String>{for (final id in serverIds) id};
  final confirmed = <String>{};
  final restore = <String>{};
  deleting.forEach((id, startedAt) {
    if (!ids.contains(id)) {
      confirmed.add(id); // 服务端没有 = 删干净了
    } else if (now.difference(startedAt) >= grace) {
      restore.add(id); // 删除被拒/未生效 → 卡片回来
    }
    // 未过宽限期：删除 RPC 还在路上，继续隐藏，本轮不裁决。
  });
  return DeletionSweep(confirmed: confirmed, restore: restore);
}
