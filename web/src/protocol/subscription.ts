/// 订阅层 —— 信封解包 + 分片组装 + 订阅 ack 前暂存 + 断档重同步。
/// 移植自 `lib/protocol/conversation.dart` 的 `_SubBase` / `ConvSubscription` /
/// `IndexSubscription`。
///
/// ⚠️ **这一层修掉的是「聊天记录加载不出来」的根因**：
/// 服务端推来的**不是逻辑帧本身**，而是信封
/// ```
/// {kind:"complete", topic, subscriptionId, frame:{payload:{kind:"snapshot"|"deltas", …}}}
/// {kind:"fragment", topic, subscriptionId, logicalFrameId, fragmentIndex, fragmentCount, dataBase64}
/// ```
/// 原实现把信封当帧直接读 `payload`——`payload` 在信封的下一层（`frame.frame.payload`），
/// 所以**每一帧都被静默丢弃**：会话列表永远是空的、聊天记录永远加载不出来。
///
/// 另三个必须照抄的细节（都是 Flutter 端踩出来的）：
/// 1. **订阅 ack 之前的帧要暂存**：`subscribeConversationV4` 返回 ack 前，事件
///    已经在推了；直接丢会把「进会话首屏」那一批快照帧全扔掉，界面停在空白。
/// 2. **按 subscriptionId 过滤**：切会话时旧订阅的迟到帧不能灌进新会话。
/// 3. **快照帧即时应用、deltas 走 40ms 微批**：快照会重置状态，批处理会错序。

import type { ChannelClient } from './channelClient'
import { BatchQueue, ResyncGate } from '../lib/gates'
import { FragmentTable, unwrapEnvelope } from '../lib/fragments'

type Frame = Record<string, unknown>

export interface SubscriptionOptions {
  /** 通道名（`zcode-agent`）。 */
  channel: string
  /** 事件名（`onDynamicConversationFrame` / `onDynamicSessionsIndexFrame`）。 */
  event: string
  subscribeMethod: string
  unsubscribeMethod: string
  resyncMethod: string
  /** 订阅参数（会与 scope 合并）。 */
  subscribeArgs: Record<string, unknown>
  /** 退订参数（会与 scope + subscriptionId 合并）。 */
  unsubscribeArgs: Record<string, unknown>
  /** 重同步参数（会与 scope + subscriptionId + base 合并）。 */
  resyncArgs: Record<string, unknown>
  /** 日志标签（`v4` / `v4-index`）。 */
  tag: string
  /** scope 延迟取（bridge 就绪后才有值）。 */
  scope: () => Record<string, unknown>
  /** 逻辑帧回调（已解包、已按 subscriptionId 过滤）。 */
  onFrame: (frame: Frame) => void
  /** resync 的 base（当前 seq / logEpoch）。 */
  getBase: () => { seq: number; logEpoch: string | null }
  onLog?: (line: string) => void
  /** 微批窗口（测试可调小）。 */
  batchMs?: number
}

/** 退订/重订阅的尽力而为超时：旧桥已死时必然失败，别等满默认 30s。 */
const BEST_EFFORT_TIMEOUT_MS = 1500

export class Subscription {
  private subscriptionId: string | null = null
  private cancelListener: (() => void) | null = null
  private fragments = new FragmentTable()
  private staged: Frame[] = []
  private stopped = false
  private resubscribing = false
  private gate = new ResyncGate()
  private purgeTimer: ReturnType<typeof setInterval> | null = null
  private batch: BatchQueue<Frame>
  private started = false

  constructor(
    private ch: ChannelClient,
    private opts: SubscriptionOptions,
  ) {
    this.batch = new BatchQueue<Frame>((frames) => {
      for (const f of frames) this.opts.onFrame(f)
    }, opts.batchMs ?? 40)
    // 帧丢了永远收不齐——定时清掉残留，否则一直占内存。
    this.purgeTimer = setInterval(() => {
      const n = this.fragments.purge()
      if (n > 0) this.log(`purged ${n} stale fragment group(s)`)
    }, 30_000)
  }

  private log(line: string): void {
    this.opts.onLog?.(`[${this.opts.tag}] ${line}`)
  }

  /** 建立订阅。Promise 在拿到 ack 后 resolve。 */
  async start(): Promise<void> {
    if (this.stopped) return
    const scope = this.opts.scope()
    this.cancelListener = this.ch.addEventListener(
      this.opts.channel,
      this.opts.event,
      (data) => this.handleWire(data),
      scope,
    )
    const res = (await this.ch.call(
      this.opts.channel,
      this.opts.subscribeMethod,
      [{ ...scope, ...this.opts.subscribeArgs }],
      60_000,
    )) as Record<string, unknown> | null

    const ack = (res?.['ack'] as Record<string, unknown> | undefined) ?? null
    this.subscriptionId = (ack?.['subscriptionId'] as string | undefined) ?? null
    this.log(`subscribed id=${this.subscriptionId}`)
    if (!this.subscriptionId) {
      throw new Error(`${this.opts.subscribeMethod}: missing ack.subscriptionId`)
    }
    this.started = true

    // 回放暂存帧：订阅 ack 之前到达的帧不能丢（否则进会话首屏一片空白）。
    const replay = this.staged
    this.staged = []
    for (const f of replay) this.accept(f)
  }

  /** 信封解包 → 逻辑帧。 */
  private handleWire(data: unknown): void {
    if (this.stopped) return
    if (!data || typeof data !== 'object') return
    const logical = unwrapEnvelope(data as Frame, this.fragments)
    if (!logical) return
    // ack 未到：暂存，等 ack 后回放。
    if (this.subscriptionId == null) {
      this.staged.push(logical)
      return
    }
    this.accept(logical)
  }

  /** 按 subscriptionId 过滤后交付（快照即时，deltas 微批）。 */
  private accept(frame: Frame): void {
    const subId = this.subscriptionId
    if (subId == null) return
    // 迟到帧过滤：切会话后旧订阅的帧不能灌进新会话。
    // 服务端在帧里带 subscriptionId；没带就按当前订阅处理（兼容旧版）。
    const frameSub = frame['subscriptionId']
    if (typeof frameSub === 'string' && frameSub !== subId) return

    const payload = frame['payload']
    const kind = payload && typeof payload === 'object' ? (payload as Frame)['kind'] : null
    if (kind === 'snapshot') {
      // 快照会重置状态，必须即时应用——批处理会让它落在 deltas 之后，错序。
      this.batch.flushNow()
      this.opts.onFrame(frame)
      return
    }
    this.batch.push(frame)
  }

  /**
   * 断档重同步。失败重试 2 次（1s / 2s 退避）——resync 是断档后**唯一**的
   * 恢复通道，失败即冻屏，必须重试。
   *
   * 单飞：在途时后续调用直接返回；自身重试链（attempt>0）不碰闸，
   * 避免把闸放跑。
   */
  resync(attempt = 0): void {
    const id = this.subscriptionId
    if (id == null || this.stopped) return
    if (attempt === 0) {
      if (!this.gate.tryAcquire()) {
        this.log('resync in flight, coalesced')
        return
      }
      this.log('resync (gap detected)')
    }
    const base = this.opts.getBase()
    void this.ch
      .call(
        this.opts.channel,
        this.opts.resyncMethod,
        [
          {
            ...this.opts.scope(),
            subscriptionId: id,
            ...this.opts.resyncArgs,
            base: { logEpoch: base.logEpoch, seq: base.seq },
          },
        ],
        30_000,
      )
      .catch((e) => {
        this.log(`resync failed (attempt ${attempt + 1}): ${e}`)
        if (attempt < 2 && !this.stopped) {
          setTimeout(() => this.resync(attempt + 1), 1000 << attempt)
        }
      })
      .finally(() => {
        if (attempt === 0) this.gate.release()
      })
  }

  /** 整条重订阅（换新订阅 id）。UI 会闪一下，但状态是权威的。 */
  resubscribe(): void {
    if (this.stopped || this.resubscribing) return
    this.resubscribing = true
    void (async () => {
      try {
        this.cancelListener?.()
        this.cancelListener = null
        const oldId = this.subscriptionId
        this.subscriptionId = null
        this.staged = []
        this.fragments.clear()
        this.batch.cancel()
        if (oldId) {
          try {
            await this.ch.call(
              this.opts.channel,
              this.opts.unsubscribeMethod,
              [
                {
                  ...this.opts.scope(),
                  subscriptionId: oldId,
                  ...this.opts.unsubscribeArgs,
                },
              ],
              BEST_EFFORT_TIMEOUT_MS,
            )
          } catch {
            /* 旧桥已死时退订必然失败——直接换新订阅 */
          }
        }
        await this.start()
      } catch (e) {
        this.log(`resubscribe failed: ${e}`)
      } finally {
        this.resubscribing = false
      }
    })()
  }

  cancel(): void {
    if (this.stopped) return
    this.stopped = true
    if (this.purgeTimer) {
      clearInterval(this.purgeTimer)
      this.purgeTimer = null
    }
    this.cancelListener?.()
    this.cancelListener = null
    this.batch.cancel()
    this.fragments.clear()
    this.staged = []
    const id = this.subscriptionId
    this.subscriptionId = null
    if (id) {
      void this.ch
        .call(
          this.opts.channel,
          this.opts.unsubscribeMethod,
          [{ ...this.opts.scope(), subscriptionId: id, ...this.opts.unsubscribeArgs }],
          BEST_EFFORT_TIMEOUT_MS,
        )
        .catch(() => {})
    }
  }

  get id(): string | null {
    return this.subscriptionId
  }

  get ready(): boolean {
    return this.started
  }
}
