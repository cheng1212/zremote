/// 滚动稳定性纯逻辑 — 对齐 `lib/ui/composer_logic.dart` 的
/// `AnchorThresholds` / `FollowLock`（参考实现 `D:\workspace\zcode-dev\web`
/// 的 ChatPage 是同源移植）。
///
/// **为什么需要双阈值滞回**：流式期间内容每 tick 长高，「贴底」判定在
/// 临界带会反复横跳 → 视口抖。`exit(180)` 与 `enter(100)` 之间是死区。
///
/// **为什么需要 FollowLock**：位置判定挡不住「内容自己长高把你推离底部」。
/// 必须锁存「用户在看历史」这个**意图**——锁存期间内容再长也不拽人。
/// 只靠位置判定，用户翻历史时会被流式输出一次次拽回底部。
///
/// 抽成纯函数是为了可单测：滚动是 Flutter 端投入最大、踩坑最多的域
/// （BUG-27/28/32 家族），Web 端不许再靠手感调参。

export const FOLLOW_EXIT_PX = 180
export const FOLLOW_ENTER_PX = 100
export const FOLLOW_RELEASE_PX = 40

/** 滚动容器的几何（只取用到的三个量，便于单测传字面量）。 */
export interface ScrollGeom {
  scrollHeight: number
  scrollTop: number
  clientHeight: number
}

/** 距底空隙。负数按 0 处理——部分浏览器 overscroll 会给负 scrollTop。 */
export function bottomGap(el: ScrollGeom): number {
  const gap = el.scrollHeight - el.scrollTop - el.clientHeight
  return gap > 0 ? gap : 0
}

/** 可滚动余量。<=0 表示内容不足一屏。 */
export function maxScroll(el: ScrollGeom): number {
  const m = el.scrollHeight - el.clientHeight
  return m > 0 ? m : 0
}

/**
 * 双阈值滞回：是否算「贴底」。
 * 内容不足一屏（maxScroll<=0）永远算贴底——此时没有「历史」可看。
 */
export function resolveAtBottom(prev: boolean, gap: number, max: number): boolean {
  if (max <= 0) return true
  return prev ? gap <= FOLLOW_EXIT_PX : gap <= FOLLOW_ENTER_PX
}

/**
 * 「在看历史」意图锁存。
 *
 * 上锁：主动滚离超过 `exit`（或显式 `lock()`，如 wheel 上滚 / 点「加载更早」）。
 * 解锁：滚回 `release` 以内（与 `enter` 之间留死区，防临界横跳）。
 */
export class FollowLock {
  private locked = false

  get isLocked(): boolean {
    return this.locked
  }

  /** 用户主动离开（上滑手势/点击加载更早）：立刻上锁，不等滚动事件。 */
  lock(): void {
    this.locked = true
  }

  /** 程序化回底：直接解锁。 */
  release(): void {
    this.locked = false
  }

  /**
   * 按几何更新锁存状态。
   * @returns 是否发生了「解锁」——调用方据此清零未读徽标。
   */
  update(gap: number, max: number): boolean {
    if (max <= 0) {
      const was = this.locked
      this.locked = false
      return was
    }
    if (!this.locked && gap > FOLLOW_EXIT_PX) {
      this.locked = true
      return false
    }
    if (this.locked && gap <= FOLLOW_RELEASE_PX) {
      this.locked = false
      return true
    }
    return false
  }
}

/**
 * 初始钉底：逐帧 `scrollTop = scrollHeight`，直到高度连续 `stableFrames`
 * 帧不再增长。markdown / 代码高亮 / 图片都是异步渲染完才撑高，所以必须
 * 「稳定才停」而不是「固定时间点补滚一次」——后者会在补滚窗口之后才长完，
 * 视口又被顶离底部。
 */
export function shouldKeepPinning(stableFrames: number, frame: number, maxFrames = 60): boolean {
  return stableFrames < 3 && frame < maxFrames
}

/**
 * 翻页高度补偿：前插更早的消息后，把 scrollTop 加上高度增量，
 * 让视口锚在原内容上不跳。
 * @returns 需要设置的 scrollTop
 */
export function compensatedScrollTop(prevScrollTop: number, heightDelta: number): number {
  const next = prevScrollTop + heightDelta
  return next > 0 ? next : 0
}
