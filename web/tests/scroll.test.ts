// 滚动稳定性纯逻辑 —— 回归锁。
//
// 锁住的是 Flutter 端 BUG-27/28/32 家族换来的那套阈值语义：
// 双阈值滞回（enter 100 / exit 180）防临界横跳；FollowLock 锁存「在看历史」
// 的意图（位置判定挡不住内容自己长高把你推离底部）。
// Web 端不许再靠手感调参——所以这些数字与判定必须有测试。
import { describe, expect, it } from 'vitest'
import {
  FOLLOW_ENTER_PX,
  FOLLOW_EXIT_PX,
  FOLLOW_RELEASE_PX,
  FollowLock,
  bottomGap,
  compensatedScrollTop,
  maxScroll,
  resolveAtBottom,
  shouldKeepPinning,
} from '../src/lib/scroll'

describe('几何量', () => {
  it('bottomGap 把负值按 0 处理（overscroll 会给负 scrollTop）', () => {
    expect(bottomGap({ scrollHeight: 1000, scrollTop: 900, clientHeight: 100 })).toBe(0)
    expect(bottomGap({ scrollHeight: 1000, scrollTop: 800, clientHeight: 100 })).toBe(100)
    expect(bottomGap({ scrollHeight: 1000, scrollTop: 950, clientHeight: 100 })).toBe(0)
  })

  it('maxScroll 内容不足一屏时为 0', () => {
    expect(maxScroll({ scrollHeight: 300, scrollTop: 0, clientHeight: 500 })).toBe(0)
    expect(maxScroll({ scrollHeight: 900, scrollTop: 0, clientHeight: 500 })).toBe(400)
  })
})

describe('resolveAtBottom —— 双阈值滞回', () => {
  it('内容不足一屏永远算贴底（此时没有「历史」可看）', () => {
    expect(resolveAtBottom(false, 500, 0)).toBe(true)
  })

  it('已贴底时用 exit 阈值：gap<=180 仍算贴底', () => {
    expect(resolveAtBottom(true, FOLLOW_EXIT_PX, 1000)).toBe(true)
    expect(resolveAtBottom(true, FOLLOW_EXIT_PX + 1, 1000)).toBe(false)
  })

  it('未贴底时用 enter 阈值：gap<=100 才算回到贴底', () => {
    expect(resolveAtBottom(false, FOLLOW_ENTER_PX, 1000)).toBe(true)
    expect(resolveAtBottom(false, FOLLOW_ENTER_PX + 1, 1000)).toBe(false)
  })

  it('100~180 之间是死区：保持原状态不变（这就是防横跳的关键）', () => {
    const inDeadZone = 140
    expect(resolveAtBottom(true, inDeadZone, 1000)).toBe(true)
    expect(resolveAtBottom(false, inDeadZone, 1000)).toBe(false)
  })

  it('阈值大小关系成立（release < enter < exit）', () => {
    // release(40) 比 enter(100) 更紧：解锁跟随要求比「贴底」更靠近底部，
    // 两阈值之间形成死区——否则锁存会在临界带反复开关，等同于没锁。
    expect(FOLLOW_RELEASE_PX).toBeLessThan(FOLLOW_ENTER_PX)
    expect(FOLLOW_ENTER_PX).toBeLessThan(FOLLOW_EXIT_PX)
  })
})

describe('FollowLock —— 意图锁存', () => {
  it('滚离超过 exit 上锁', () => {
    const lock = new FollowLock()
    expect(lock.update(FOLLOW_EXIT_PX + 1, 1000)).toBe(false)
    expect(lock.isLocked).toBe(true)
  })

  it('锁存中滚回 release 以内解锁，并报告「发生了解锁」', () => {
    const lock = new FollowLock()
    lock.update(500, 1000)
    expect(lock.isLocked).toBe(true)
    expect(lock.update(FOLLOW_RELEASE_PX, 1000)).toBe(true)
    expect(lock.isLocked).toBe(false)
  })

  it('release 与 exit 之间的死区不解锁（防临界横跳）', () => {
    const lock = new FollowLock()
    lock.update(500, 1000)
    // 回到 100（大于 release 40，小于 exit 180）——仍在死区，保持锁存
    expect(lock.update(100, 1000)).toBe(false)
    expect(lock.isLocked).toBe(true)
  })

  it('内容不足一屏时自动解锁（没有历史可看）', () => {
    const lock = new FollowLock()
    lock.update(500, 1000)
    expect(lock.update(0, 0)).toBe(true)
    expect(lock.isLocked).toBe(false)
  })

  it('lock() 供用户主动上滑立刻上锁，release() 供程序化回底解锁', () => {
    const lock = new FollowLock()
    lock.lock()
    expect(lock.isLocked).toBe(true)
    lock.release()
    expect(lock.isLocked).toBe(false)
  })

  it('锁存期间内容再长也不解锁（这正是它存在的理由）', () => {
    const lock = new FollowLock()
    lock.lock()
    // 流式内容长高把 gap 顶到很大——位置判定会误判，锁存不会
    expect(lock.update(900, 5000)).toBe(false)
    expect(lock.isLocked).toBe(true)
  })
})

describe('初始钉底与翻页补偿', () => {
  it('高度还在长就继续钉，连续 3 帧稳定后停', () => {
    expect(shouldKeepPinning(0, 1)).toBe(true)
    expect(shouldKeepPinning(2, 10)).toBe(true)
    expect(shouldKeepPinning(3, 10)).toBe(false)
  })

  it('帧数封顶 60，防渲染异常时死循环', () => {
    expect(shouldKeepPinning(0, 60)).toBe(false)
    expect(shouldKeepPinning(0, 59)).toBe(true)
  })

  it('补偿量加到 scrollTop 上，且不为负', () => {
    expect(compensatedScrollTop(300, 120)).toBe(420)
    expect(compensatedScrollTop(10, -500)).toBe(0)
  })
})
