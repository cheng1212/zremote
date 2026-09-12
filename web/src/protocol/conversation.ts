/// Conversation V4 — TS 移植自 lib/protocol/conversation.dart 的核心链路。
/// Flow: hello → initialize(clientHello) → subscribe(scope+sessionId) →
/// frames via dynamic event → commands via sendConversationCommandV4。
/// 本期对齐：握手、会话订阅（快照/增量帧、微批）、sessions-index 订阅、
/// 发送命令（CAS）、rowsRange 翻页、ResyncGate 单飞闸。

import type { Bridge } from './remoteSession'
import { ChannelClient } from './channelClient'
import {
  CONV_CHANNEL,
  CONV_PROTOCOL_VERSION,
  CONV_PROTOCOL_APP_VERSION,
  CONV_CLIENT_KIND,
  M_HELLO,
  M_INITIALIZE,
  M_SEND_COMMAND,
  M_SUBSCRIBE_CONV,
  M_RESYNC_CONV,
  M_SUBSCRIBE_INDEX,
  EV_CONV_FRAME,
  EV_INDEX_FRAME,
  M_ROWS_RANGE,
  CAS_COMMANDS,
  ROW_TARGET_COMMANDS,
  IPC_UNSUBSCRIBE_TIMEOUT_MS,
  genId,
} from './constants'

type Frame = Record<string, unknown>

export interface ConvRow extends Frame {
  rowId?: number
  kind?: string
  state?: string
  text?: string
}

/** ResyncGate 单飞闸（移植自 conversation.dart）：断档重同步并发风暴的断环器。 */
export class ResyncGate {
  private inFlightFlag = false
  get inFlight(): boolean {
    return this.inFlightFlag
  }
  tryAcquire(): boolean {
    if (this.inFlightFlag) return false
    this.inFlightFlag = true
    return true
  }
  release(): void {
    this.inFlightFlag = false
  }
}

/** 40ms 微批队列：帧到齐先入队，定时器统一次 notify（对齐 _scheduleBatchNotify）。 */
class BatchQueue {
  private pending: Frame[] = []
  private timer: ReturnType<typeof setTimeout> | null = null
  constructor(private onFlush: (frames: Frame[]) => void) {}

  push(frame: Frame): void {
    this.pending.push(frame)
    if (!this.timer) {
      this.timer = setTimeout(() => {
        this.timer = null
        const batch = this.pending
        this.pending = []
        this.onFlush(batch)
      }, 40)
    }
  }
}

export class ConversationV4 {
  readonly clientId = genId('zr')
  connectionId: string | null = null
  private handshaken = false
  private handshakePromise: Promise<void> | null = null

  constructor(
    public bridge: Bridge,
    private onLog?: (line: string) => void,
  ) {}

  private get ch(): ChannelClient {
    return this.bridge.channels
  }

  handshake(): Promise<void> {
    if (this.handshaken) return Promise.resolve()
    if (this.handshakePromise) return this.handshakePromise
    this.handshakePromise = (async () => {
      const hello = (await this.ch.call(CONV_CHANNEL, M_HELLO, [])) as Record<string, unknown>
      this.onLog?.(`[v4] hello: ${JSON.stringify(hello)}`)
      if (hello && typeof hello === 'object') {
        this.connectionId = (hello['connectionId'] as string | undefined) ?? null
      }
      await this.ch.call(CONV_CHANNEL, M_INITIALIZE, [
        {
          kind: 'clientHello',
          protocolVersion: CONV_PROTOCOL_VERSION,
          clientId: this.clientId,
          clientKind: CONV_CLIENT_KIND,
          appVersion: CONV_PROTOCOL_APP_VERSION,
        },
      ])
      this.handshaken = true
    })()
    this.handshakePromise.catch(() => {
      this.handshakePromise = null
    })
    return this.handshakePromise
  }

  /** 订阅一个会话：帧经 conv 事件到达；返回取消函数与帧流。 */
  subscribeSession(
    sessionId: string,
    onFrame: (frame: Frame) => void,
  ): { cancel: () => void; resubscribe: () => void } {
    const scope = this.bridge.scope
    const queue = new BatchQueue((frames) => {
      for (const f of frames) onFrame(f)
    })
    let cancelListener: (() => void) | null = null
    let subscriptionId: string | null = null
    let stopped = false

    const start = async () => {
      await this.handshake()
      cancelListener = this.ch.addEventListener(CONV_CHANNEL, EV_CONV_FRAME, (data) => {
        const frame = data as Frame
        if (frame && String(frame['sessionId'] ?? sessionId) === sessionId) queue.push(frame)
      }, scope)
      const res = (await this.ch.call(
        CONV_CHANNEL,
        M_SUBSCRIBE_CONV,
        [{ ...scope, sessionId }],
        60_000,
      )) as Record<string, unknown> | null
      const ack = (res?.['ack'] as Record<string, unknown> | undefined) ?? null
      subscriptionId = (ack?.['subscriptionId'] as string | undefined) ?? null
      this.onLog?.(`[v4] subscribed ${sessionId} id=${subscriptionId}`)
      if (!subscriptionId) throw new Error('subscribeConversationV4: missing ack.subscriptionId')
    }

    void start().catch((e) => this.onLog?.(`[v4] subscribe failed: ${e}`))

    const resubscribe = () => {
      if (stopped) return
      void (async () => {
        await this.handshake()
        cancelListener?.()
        cancelListener = null
        const oldId = subscriptionId
        subscriptionId = null
        if (oldId) {
          try {
            await this.ch.call(
              CONV_CHANNEL,
              'unsubscribeConversationV4',
              [{ ...scope, sessionId, subscriptionId: oldId }],
              IPC_UNSUBSCRIBE_TIMEOUT_MS,
            )
          } catch {
            /* 旧桥已死时退订必然失败——直接换新订阅 */
          }
        }
        await start()
      })().catch((e) => this.onLog?.(`[v4] resubscribe failed: ${e}`))
    }

    return {
      cancel: () => {
        stopped = true
        cancelListener?.()
        if (subscriptionId) {
          void this.ch
            .call(
              CONV_CHANNEL,
              'unsubscribeConversationV4',
              [{ ...scope, sessionId, subscriptionId }],
              IPC_UNSUBSCRIBE_TIMEOUT_MS,
            )
            .catch(() => {})
        }
      },
      resubscribe,
    }
  }

  /** sessions-index 订阅（任务列表实时帧）。 */
  subscribeIndex(onFrame: (frame: Frame) => void): { cancel: () => void } {
    const scope = this.bridge.scope
    let cancelListener: (() => void) | null = null
    let stopped = false
    void (async () => {
      await this.handshake()
      if (stopped) return
      cancelListener = this.ch.addEventListener(
        CONV_CHANNEL,
        EV_INDEX_FRAME,
        (data) => onFrame((data as Frame) ?? {}),
        scope,
      )
      const res = (await this.ch.call(CONV_CHANNEL, M_SUBSCRIBE_INDEX, [
        scope,
      ])) as Record<string, unknown> | null
      this.onLog?.(`[v4] index subscribed: ${JSON.stringify(res?.['ack'] ?? {})}`)
    })().catch((e) => this.onLog?.(`[v4] index subscribe failed: ${e}`))
    return {
      cancel: () => {
        stopped = true
        cancelListener?.()
      },
    }
  }

  /** 断档重同步：ResyncGate 保证一次在途时后续合流（resync 风暴断环）。 */
  private gate = new ResyncGate()

  resync(sessionId: string): void {
    if (!this.gate.tryAcquire()) {
      this.onLog?.('[v4] resync in flight, coalesced')
      return
    }
    void this.ch
      .call(CONV_CHANNEL, M_RESYNC_CONV, [{ sessionId, forceSnapshot: true }], 30_000)
      .catch((e) => this.onLog?.(`[v4] resync failed: ${e}`))
      .finally(() => this.gate.release())
  }

  async rowsRange(
    sessionId: string,
    beforeRowId: number,
    limit = 60,
  ): Promise<Frame[]> {
    const res = (await this.ch.call(CONV_CHANNEL, M_ROWS_RANGE, [
      { sessionId, beforeRowId, limit },
    ])) as Record<string, unknown>
    return (res?.['rows'] as Frame[] | undefined) ?? []
  }

  /** 发送会话命令（CAS 命令自动带 baseRevision / 行级命令带 baseLogEpoch）。 */
  async sendCommand(
    sessionId: string,
    type: string,
    payload: Record<string, unknown>,
    ctx: { baseRevision: number; logEpoch: string | null },
  ): Promise<unknown> {
    await this.handshake()
    const envelope: Record<string, unknown> = {
      commandId: genId('cmd'),
      clientId: this.clientId,
      sessionId,
      ...(CAS_COMMANDS.has(type) ? { baseRevision: ctx.baseRevision } : {}),
      ...(ROW_TARGET_COMMANDS.has(type) && ctx.logEpoch ? { baseLogEpoch: ctx.logEpoch } : {}),
      type,
      payload,
      issuedAt: Date.now(),
    }
    return this.ch.call(CONV_CHANNEL, M_SEND_COMMAND, [envelope], 30_000)
  }

  async sendText(sessionId: string, text: string, heldQueueDisposition?: string): Promise<unknown> {
    return this.sendCommand(
      sessionId,
      'sendText',
      { text, ...(heldQueueDisposition ? { heldQueueDisposition } : {}) },
      { baseRevision: 0, logEpoch: null },
    )
  }

  stop(sessionId: string): Promise<unknown> {
    return this.sendCommand(sessionId, 'stop', {}, { baseRevision: 0, logEpoch: null })
  }
}
