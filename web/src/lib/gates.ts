/// 并发原语 —— 单飞闸与微批队列。纯逻辑，可单测。

/**
 * 单飞闸：在途时后续调用直接合流。
 *
 * **它解决的是真机实测过的事故**：40ms 微批窗口里积压的帧会逐帧走断档判定
 * （`fromSeq != seq`），每帧真发一次 `resync`（带 forceSnapshot 整份替换列表）
 * → 视口被反复重置，观感是「聊天记录自己快速翻回最开头」。
 * 2026-09-12 桌面日志实测：同一毫秒 12 次并发 resync，耗时 650~678ms 整齐一致
 * （=同时起跑）。加闸后只剩 1 次。
 */
export class ResyncGate {
  private inFlightFlag = false

  get inFlight(): boolean {
    return this.inFlightFlag
  }

  /** 取闸。false = 已有一次在途，调用方应直接返回（合流）。 */
  tryAcquire(): boolean {
    if (this.inFlightFlag) return false
    this.inFlightFlag = true
    return true
  }

  release(): void {
    this.inFlightFlag = false
  }
}

/**
 * 40ms 微批队列：帧到齐先入队，定时器统一次 flush。
 *
 * 流式输出时服务端可能每秒推几十帧，每帧都触发一次渲染会严重掉帧。
 * 批内**逐帧**交给下游（不是合并成一帧）——顺序与 seq 语义都不能乱。
 */
export class BatchQueue<T> {
  private pending: T[] = []
  private timer: ReturnType<typeof setTimeout> | null = null

  constructor(
    private onFlush: (items: T[]) => void,
    private delayMs = 40,
  ) {}

  push(item: T): void {
    this.pending.push(item)
    if (!this.timer) {
      this.timer = setTimeout(() => {
        this.timer = null
        const batch = this.pending
        this.pending = []
        this.onFlush(batch)
      }, this.delayMs)
    }
  }

  /** 立即冲刷（快照帧必须即时应用——它会重置状态，不能批处理）。 */
  flushNow(): void {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    if (this.pending.length) {
      const batch = this.pending
      this.pending = []
      this.onFlush(batch)
    }
  }

  cancel(): void {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.pending = []
  }

  get size(): number {
    return this.pending.length
  }
}
