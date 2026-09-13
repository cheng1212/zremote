/// 会话历史的纯逻辑：无 Flutter 依赖，可单测。
///
/// 背景（探针实测 2026-09-13）：桌面端订阅快照只给**最近 60 行**，
/// `totalCount` 是**整个会话**的行数（实测某会话 4083 行），翻页
/// `rowsRange(beforeRowId)` 一次给一页。所以"会话太长"不是拉不动，
/// 是默认窗口小、要够到很早的内容得翻几十轮。用户裁定：首屏只要 100 条，
/// 需要全部时给一个显式的「拉取全部」入口。
library;

/// 一页多少行：默认翻页（上滑自动加载）用。
const int kHistoryPageSize = 60;

/// 首屏目标行数：订阅快照给 60，补一次到这个数就停（用户要的 100）。
const int kInitialHistoryRows = 100;

/// 「拉取全部」时先试的大页；桌面端不认就退回 [kHistoryPageSize]。
/// （实测 limit=300 会一轮 0 进账，所以不能无脑开大。）
const int kHistoryBulkPageSize = 200;

/// 还剩多少条更早的行（已加载 >= 总数 → 0）。
int olderRemaining({required int loaded, required int total}) {
  final left = total - loaded;
  return left > 0 ? left : 0;
}

/// 历史进度文案（列表顶部的入口用）。
/// [pulling] = 正在批量拉取，文案换成进度。
String historyPullLabel({
  required int loaded,
  required int total,
  bool pulling = false,
}) {
  final left = olderRemaining(loaded: loaded, total: total);
  if (left == 0) return '';
  if (pulling) return '正在拉取 $loaded/$total…';
  return '还有 $left 条更早 · 点这里拉取全部';
}

/// 批量拉取还要不要继续：没得拉了，或连续两轮 0 进账（防死循环）。
bool shouldKeepPulling({
  required bool hasMoreOlder,
  required int loaded,
  required int lastLoaded,
  required int stallRounds,
}) {
  if (!hasMoreOlder) return false;
  if (loaded <= lastLoaded && stallRounds >= 2) return false;
  return true;
}
