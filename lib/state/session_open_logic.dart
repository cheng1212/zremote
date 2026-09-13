/// 「打开会话」的纯判定逻辑：无 Flutter 依赖，可单测。
///
/// 背景（用户裁定 2026-09-13）：切会话要**乐观**——点一下立刻进聊天页，
/// 切桥 + 订阅都在后台做，「快速切进去发消息」是第一需求，历史/实时消息
/// 晚一点无所谓。代价是同一个会话可能被**并发打开两次**：
///   ① 列表点卡片时 `onOpenTask` 先发起一次（不等）；
///   ② 聊天页 initState 看到 `chat == null` 又发起一次。
/// `chat` 在"订阅进行中"同样是 null，所以那里拦不住——不去重就会对同一个
/// 会话发两条 `subscribeConversationV4`，后一条覆盖前一条的结果，前一条
/// 的订阅没人释放（桌面端桥上留一个泄漏订阅），还让最拥挤的那一刻白占
/// 一个往返。
library;

/// 这次「打开会话」请求该怎么处理。
enum SessionOpenPlan {
  /// 已经有**同一个会话**的打开在飞：复用它，别再发一次订阅。
  awaitInflight,

  /// 没有在飞的（或飞的是别的会话）：发起一次新的打开。
  open,
}

/// [openingSid] = 当前在飞的打开的会话 id（没有给 null）。
SessionOpenPlan sessionOpenPlan({
  required String sessionId,
  required String? openingSid,
}) => openingSid == sessionId
    ? SessionOpenPlan.awaitInflight
    : SessionOpenPlan.open;

/// 按下发送时，「会话就绪」这件事该怎么处理。
enum SessionReadyPlan {
  /// 已经订上这个会话：直接发，一秒都别等。
  sendNow,

  /// 正在打开同一个会话（切桥/订阅在后台跑）：等它落地再发。
  awaitInflight,

  /// 没订上也没在开：开一次再发。
  openThenSend,
}

/// 乐观切换期间桥可能正在拆/重开（`conv` 中途甚至为 null），此时发消息
/// 会拿**旧桥**把消息发到别的项目去，或者直接撞上「桥未就绪，请返回重进」。
/// 所以发送前必须过这道判定。
SessionReadyPlan sessionReadyPlan({
  required String sessionId,
  required String? chatSid,
  required String? openingSid,
}) {
  if (chatSid == sessionId) return SessionReadyPlan.sendNow;
  if (openingSid == sessionId) return SessionReadyPlan.awaitInflight;
  return SessionReadyPlan.openThenSend;
}
