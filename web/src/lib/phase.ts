/// phase 判定 — 移植自 lib/protocol/conversation.dart 的纯函数。
///
/// 为什么单独成文件：这些判定决定「按钮该不该出现」「能不能停止」。
/// 猜错会让用户对着排队中的会话点「停止」而毫无反应（排队态没东西可停），
/// 或者让忙着的会话被当空闲、允许再叠队列。

/** 忙：占着运行时（**含排队**）。queued 也算忙——消息还没跑，但用户不该再叠。 */
export function isBusyPhase(phase: string): boolean {
  return phase === 'running' || phase === 'prewarming' || phase === 'queued'
}

/** 真的在产出（可以停止）。排队中给「停止」是错的——停了也没东西可停。 */
export function isProducingPhase(phase: string): boolean {
  return phase === 'running' || phase === 'prewarming'
}

/** 会话级出错 phase（服务端把 control.phase 标成这两个之一）。 */
export function isErrorPhase(phase: string): boolean {
  return phase === 'error' || phase === 'completedError'
}

/**
 * 错误值 → 人话。
 *
 * 桌面端错误有两种形态（schema 反解实证）：纯字符串，或结构体
 * `{code, message, recoverable, source, statusCode?, providerErrorCode?, detail?}`。
 * **只认字符串会把具体原因全丢掉**（BUG-33：余额不足这类 provider 业务错误
 * 就是结构体，用户只看到「发送失败」四个字，不知道该去充值）。
 *
 * message → detail → code 三级兜底；code 是内部分类（provider_business 之类），
 * 当正文对用户是噪音，只在没有更可读的字段时顶上。
 */
export function errorValueText(v: unknown): string | null {
  if (typeof v === 'string') return v.trim() || null
  if (!v || typeof v !== 'object') return null
  const m = v as Record<string, unknown>
  for (const k of ['message', 'detail', 'code']) {
    const s = m[k]
    if (typeof s === 'string' && s.trim()) return s.trim()
  }
  return null
}

/** 会话相位 → 中文标签（列表卡 chip 用）。未知相位原样透传，不吞信息。 */
export function phaseLabel(phase: string): string {
  switch (phase) {
    case 'running':
      return '运行中'
    case 'prewarming':
      return '准备中'
    case 'queued':
      return '排队中'
    case 'idle':
      return '空闲'
    case 'error':
    case 'completedError':
      return '出错'
    case 'completedSuccess':
    case 'completed':
      return '已完成'
    default:
      return phase
  }
}
