/// Relay 终端 socket — TS 移植自 lib/protocol/relay_client.dart。
/// JSON 文本帧 over wss://<host>/ws。握手 auth_init → auth_challenge →
/// auth_response(HMAC proof) → pair_status matched；心跳 + 断线重连。

import { calculateProof } from './proof'
import type { LinkParams } from './linkParams'
import { relayWsUri } from './linkParams'
import { RELAY_HEARTBEAT_INTERVAL_MS, RELAY_HEARTBEAT_ACK_TIMEOUT_MS, RELAY_RECONNECT_MAX_BACKOFF_MS } from './constants'

export type RelayState =
  | 'idle'
  | 'connecting'
  | 'authenticating'
  | 'waiting'
  | 'paired'
  | 'reconnecting'
  | 'error'
  | 'kicked'
  | 'closed'

interface RelayFrame {
  type: string
  [k: string]: unknown
}

function relayCloseReason(code: number): string | null {
  switch (code) {
    case 4004:
      return 'session-not-found'
    case 4009:
      return 'session-conflict'
    case 4010:
      return 'desktop-disconnected'
    case 4011:
      return 'session-expired'
    case 4012:
      return 'workspace-closed'
    case 4013:
      return 'invalid-mobile-connection'
    default:
      return null
  }
}

type Listener = () => void

export class RelayClient {
  private socket: WebSocket | null = null
  private generation = 0
  private connectInFlight = false
  private intentionallyClosed = false
  private disposed = false
  private reconnectAttempt = 0
  private heartbeatTick = 0
  private lastPairAckAt = Date.now()
  private lastInboundAt = Date.now()
  private wasPaired = false

  private heartbeat: ReturnType<typeof setInterval> | null = null
  private waitingTimer: ReturnType<typeof setTimeout> | null = null
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private rewaitTimer: ReturnType<typeof setTimeout> | null = null

  private outbound: RelayFrame[] = []
  private payloadListeners = new Set<(p: RelayFrame) => void>()
  private stateListeners = new Set<Listener>()

  constructor(
    public params: LinkParams,
    private onLog?: (line: string) => void,
  ) {}

  private _state: RelayState = 'idle'
  get state(): RelayState {
    return this._state
  }

  private setState(s: RelayState): void {
    this._state = s
    this.onLog?.(`[relay] state -> ${s}`)
    for (const l of this.stateListeners) l()
  }

  onState(listener: Listener): () => void {
    this.stateListeners.add(listener)
    return () => this.stateListeners.delete(listener)
  }

  onPayload(listener: (p: RelayFrame) => void): () => void {
    this.payloadListeners.add(listener)
    return () => this.payloadListeners.delete(listener)
  }

  async start(): Promise<void> {
    this.disposed = false
    this.intentionallyClosed = false
    this.reconnectAttempt = 0
    this.setState('connecting')
    await this.connect()
  }

  private async connect(): Promise<void> {
    if (this.connectInFlight || this.disposed) return
    this.connectInFlight = true
    const generation = ++this.generation
    this.lastPairAckAt = Date.now()
    this.lastInboundAt = Date.now()
    const uri = relayWsUri(this.params)
    this.onLog?.(`[relay] connecting ${new URL(uri).host}/ws`)
    try {
      await this.openSocket(uri, generation)
    } catch (e) {
      this.connectInFlight = false
      this.onLog?.(`[relay] connect failed: ${e}`)
      if (generation === this.generation) this.handleClosed(1006, `${e}`)
      return
    }
    if (this.disposed || generation !== this.generation) {
      this.connectInFlight = false
      return
    }
    this.connectInFlight = false
    this.setState('authenticating')
    this.sendFrame({
      type: 'auth_init',
      role: 'terminal',
      device_sid: this.params.deviceSid,
      meta: {
        platform: 'web',
        version: this.params.appVersion ?? 'zremote',
        name: 'zremote',
      },
      client_ts: Date.now(),
    })
  }

  /** new WebSocket + 等 open（对齐 socket.ready 语义）。 */
  private openSocket(uri: string, generation: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const sock = new WebSocket(uri)
      this.socket = sock
      sock.onopen = () => resolve()
      sock.onerror = () => {
        if (generation === this.generation) reject(new Error('websocket error'))
      }
      sock.onclose = (ev) => {
        if (generation === this.generation) this.handleClosed(ev.code, ev.reason)
      }
      sock.onmessage = (ev) => {
        if (generation === this.generation) this.handleRaw(ev.data as string)
      }
    })
  }

  private sendFrame(frame: RelayFrame): void {
    this.socket?.send(JSON.stringify(frame))
  }

  sendPayload(payload: Record<string, unknown>): void {
    if (this._state !== 'paired' || !this.socket) {
      if (this.outbound.length < 100) {
        this.onLog?.(`[relay] queued (state=${this._state})`)
        this.outbound.push(payload as RelayFrame)
      }
      return
    }
    this.sendFrame({ type: 'data', payload, client_ts: Date.now() })
  }

  private flushOutbound(): void {
    if (this.outbound.length === 0) return
    this.onLog?.(`[relay] flushing ${this.outbound.length} queued payload(s)`)
    const queued = [...this.outbound]
    this.outbound = []
    for (const payload of queued) {
      this.sendFrame({ type: 'data', payload, client_ts: Date.now() })
    }
  }

  private async handleRaw(text: string): Promise<void> {
    this.lastInboundAt = Date.now()
    let frame: RelayFrame
    try {
      const decoded = JSON.parse(text)
      if (decoded && typeof decoded === 'object' && 'type' in decoded) frame = decoded
      else return
    } catch {
      this.onLog?.('[relay] bad frame')
      return
    }
    switch (frame.type) {
      case 'auth_challenge': {
        const proof = await calculateProof({
          passHash: this.params.passHash,
          nonce: (frame['nonce'] as string) ?? '',
          role: 'terminal',
          deviceSid: this.params.deviceSid,
        })
        this.sendFrame({
          type: 'auth_response',
          device_sid: this.params.deviceSid,
          proof,
          client_ts: Date.now(),
        })
        break
      }
      case 'auth_ack':
      case 'pair_status_ack':
        this.applyPairStatus(frame['pair_status'] as string | undefined)
        break
      case 'data': {
        const payload = frame['payload'] as RelayFrame | undefined
        if (payload) for (const l of this.payloadListeners) l(payload)
        break
      }
      case 'error':
        this.handleError(frame['code'] as string | null)
        break
    }
  }

  private applyPairStatus(status: string | undefined): void {
    this.lastPairAckAt = Date.now()
    if (status === 'waiting') {
      if (this.wasPaired) {
        if (this.waitingTimer) clearTimeout(this.waitingTimer)
        this.waitingTimer = setTimeout(() => {
          if (this._state === 'waiting') {
            this.onLog?.('[relay] re-pair stuck in waiting, reconnecting')
            this.reconnect()
          }
        }, RELAY_HEARTBEAT_ACK_TIMEOUT_MS)
        this.setState('waiting')
        this.startHeartbeat()
      } else {
        this.setState('waiting')
        this.startHeartbeat()
        // 首次配对等待：给总超时
        if (this.waitingTimer) clearTimeout(this.waitingTimer)
        this.waitingTimer = setTimeout(() => {
          if (this._state !== 'paired' && !this.disposed) {
            this.onLog?.('[relay] waiting timeout')
            this.handleClosed(1006, 'waiting timeout')
          }
        }, RELAY_HEARTBEAT_ACK_TIMEOUT_MS)
      }
      return
    }
    if (status === 'matched') {
      if (this.rewaitTimer) clearTimeout(this.rewaitTimer)
      this.reconnectAttempt = 0
      if (this.waitingTimer) clearTimeout(this.waitingTimer)
      this.setState('paired')
      this.wasPaired = true
      this.startHeartbeat()
      this.flushOutbound()
    }
  }

  private handleError(code: string | null): void {
    this.onLog?.(`[relay] error frame: ${code}`)
    if (code === 'KICKED') {
      this.setState('kicked')
      this.intentionallyClosed = true
      this.socket?.close()
    }
  }

  private handleClosed(code: number, reason: string | null): void {
    if (this.disposed) return
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.heartbeat = null
    if (this.waitingTimer) clearTimeout(this.waitingTimer)
    const mapped = relayCloseReason(code)
    this.onLog?.(`[relay] closed code=${code} reason=${reason ?? ''} mapped=${mapped}`)
    if (this.intentionallyClosed) return
    if (this.wasPaired || mapped === 'desktop-disconnected') {
      this.scheduleReconnect()
      return
    }
    this.setState('error')
  }

  private startHeartbeat(): void {
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.heartbeatTick = 0
    this.heartbeat = setInterval(() => {
      if (this._state !== 'paired' && this._state !== 'waiting') return
      this.heartbeatTick++
      if (this._state === 'waiting' && this.heartbeatTick % 2 === 1) return
      if (Date.now() - this.lastPairAckAt > RELAY_HEARTBEAT_ACK_TIMEOUT_MS) {
        this.onLog?.('[relay] heartbeat ack timeout, reconnecting')
        this.reconnect()
        return
      }
      this.sendFrame({
        type: 'pair_status_query',
        device_sid: this.params.deviceSid,
        client_ts: Date.now(),
      })
    }, RELAY_HEARTBEAT_INTERVAL_MS)
  }

  /** 回前台探测：链路像死的一样就立刻重连（Web 无 lifecycle，用 visibilitychange）。 */
  poke(): void {
    if (this.disposed || this.intentionallyClosed) return
    if (this._state === 'paired') {
      if (Date.now() - this.lastInboundAt > 25_000) {
        this.onLog?.('[relay] poke: stale link, reconnecting')
        this.reconnect()
      }
    } else if (this._state === 'error') {
      this.reconnect()
    }
  }

  private scheduleReconnect(): void {
    if (this.disposed || this.intentionallyClosed) return
    const wasReconnecting = this._state === 'reconnecting'
    if (!wasReconnecting) this.setState('reconnecting')
    this.reconnectAttempt++
    const backoff = Math.min(
      RELAY_RECONNECT_MAX_BACKOFF_MS,
      500 * Math.pow(2, Math.min(this.reconnectAttempt, 6)),
    )
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    this.reconnectTimer = setTimeout(() => this.reconnect(), backoff)
  }

  reconnect(): void {
    if (this.disposed || this.intentionallyClosed) return
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
    this.socket?.close()
    this.socket = null
    void this.connect()
  }

  dispose(): void {
    this.disposed = true
    this.intentionallyClosed = true
    if (this.heartbeat) clearInterval(this.heartbeat)
    if (this.waitingTimer) clearTimeout(this.waitingTimer)
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    if (this.rewaitTimer) clearTimeout(this.rewaitTimer)
    this.socket?.close()
    this.socket = null
    this.payloadListeners.clear()
    this.stateListeners.clear()
  }
}
