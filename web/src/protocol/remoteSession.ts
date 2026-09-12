/// RemoteSession + Bridge — TS 移植自 lib/protocol/remote_session.dart。
/// 信令配对层：bootstrap / workspace-list / bridge-open → rpc-frame + IPC 栈。

import { RelayClient } from './relayClient'
import { ChannelClient } from './channelClient'
import { RpcFrames, type RpcFramePayload } from './rpcFrames'
import {
  SIG_BOOTSTRAP,
  SIG_BOOTSTRAP_RESPONSE,
  SIG_BRIDGE_OPEN,
  SIG_BRIDGE_READY,
  SIG_BRIDGE_ERROR,
  SIG_VIEW_STATE_UPDATE,
  PUSH_WORKSPACE_LIST_UPDATED,
  PUSH_BRIDGE_DEGRADED,
  genId,
} from './constants'
import type { LinkParams } from './linkParams'

export type Workspace = Record<string, unknown>

export class Bridge {
  info: Record<string, unknown>
  frames!: RpcFrames
  channels!: ChannelClient
  degraded: string | null = null
  recoveredTick = 0
  private disposedFlag = false
  private degradedListeners = new Set<() => void>()

  constructor(
    public session: RemoteSession,
    info: Record<string, unknown>,
  ) {
    this.info = info
    this.attach(info)
  }

  /** 建 rpc-frame + channel 栈（构造/恢复共用）。 */
  attach(info: Record<string, unknown>): void {
    this.info = info
    this.frames = new RpcFrames({
      bridgeSessionId: String(info['bridgeSessionId'] ?? ''),
      bridgeGeneration: (info['bridgeGeneration'] as number | undefined) ?? undefined,
      recoveryId: (info['recoveryId'] as string | undefined) ?? undefined,
      send: (p) => this.session.relay.sendPayload(p),
      onMessage: (bytes) => this.channels.handleMessage(bytes),
      onLog: this.session.onLog,
    })
    this.channels = new ChannelClient((body) => this.frames.sendMessage(body), this.session.onLog)
  }

  get workspaceKey(): string | null {
    return (this.info['workspaceKey'] as string | undefined) ?? null
  }

  get initialTaskId(): string | null {
    return (this.info['initialTaskId'] as string | undefined) ?? null
  }

  get scope(): Record<string, unknown> {
    return {
      workspacePath: this.info['workspacePath'] ?? this.workspaceKey,
      ...(this.info['workspaceIdentity'] != null
        ? { workspaceIdentity: this.info['workspaceIdentity'] }
        : {}),
    }
  }

  setDegraded(reason: string | null): void {
    if (this.disposedFlag) return
    this.degraded = reason
    for (const l of this.degradedListeners) l()
  }

  onDegraded(listener: () => void): () => void {
    this.degradedListeners.add(listener)
    return () => this.degradedListeners.delete(listener)
  }

  /** 恢复重试直到桥健康（对齐 recoverWithRetry）。 */
  async recoverWithRetry(): Promise<void> {
    if (this.disposedFlag) return
    for (let attempt = 1; attempt <= 8; attempt++) {
      if (this.disposedFlag) return
      if (await this.recoverOnce()) return
      if (this.disposedFlag) return
      this.session.onLog?.(`[bridge] recovery attempt ${attempt} failed`)
      await new Promise((r) => setTimeout(r, 3000))
    }
  }

  private async recoverOnce(): Promise<boolean> {
    const key = this.workspaceKey
    if (key == null) return false
    try {
      const res = await this.session.request(
        {
          zcode_type: 'workspace-reconnect-request',
          requestId: genId('rec'),
          bridgeSessionId: this.info['bridgeSessionId'],
          workspaceKey: key,
        },
        (p) =>
          (p['zcode_type'] === 'workspace-reconnect-response' ||
            p['zcode_type'] === SIG_BRIDGE_ERROR) &&
          p['bridgeSessionId'] === this.info['bridgeSessionId'],
      )
      if (res['zcode_type'] === SIG_BRIDGE_ERROR) return false
      const info = (res['bridge'] as Record<string, unknown> | undefined) ?? {}
      if (Object.keys(info).length === 0) return false
      this.attach(info)
      this.recoveredTick++
      this.setDegraded(null)
      return true
    } catch {
      return false
    }
  }

  dispose(): void {
    this.disposedFlag = true
    this.frames.dispose()
    this.channels.dispose()
  }
}

export class RemoteSession {
  relay: RelayClient
  private payloadListeners = new Set<(p: RpcFramePayload) => void>()
  private workspaceListListeners = new Set<(result: unknown) => void>()
  private matchers = new Map<string, (p: RpcFramePayload) => boolean>()
  private completers = new Map<string, { resolve: (p: RpcFramePayload) => void; reject: (e: unknown) => void }>()
  private frameRouters = new Map<string, Bridge>()
  private pendingBridgePayloads = new Map<string, RpcFramePayload[]>()
  private bridgeGeneration = 0
  private unsubs: (() => void)[] = []
  private needsBridgeRecovery = false
  private activeBridges: Bridge[] = []

  workspaces: Workspace[] = []

  constructor(
    public params: LinkParams,
    public onLog?: (line: string) => void,
  ) {
    this.relay = new RelayClient(params, onLog)
    this.unsubs.push(
      this.relay.onPayload((p) => this.dispatch(p)),
      this.relay.onState(() => this.onRelayState()),
    )
  }

  private onRelayState(): void {
    const s = this.relay.state
    if (s === 'reconnecting' || s === 'error') {
      if (this.activeBridges.length > 0) {
        this.needsBridgeRecovery = true
        for (const b of this.activeBridges) {
          if (b.degraded == null) b.setDegraded('reconnecting')
        }
      }
      return
    }
    if (s === 'paired' && this.needsBridgeRecovery) {
      this.needsBridgeRecovery = false
      for (const b of [...this.activeBridges]) void b.recoverWithRetry()
    }
  }

  connect(): Promise<void> {
    return this.relay.start()
  }

  /** 等 relay 到 paired（对齐 waitPaired）。 */
  waitPaired(timeoutMs = 60_000): Promise<void> {
    if (this.relay.state === 'paired') return Promise.resolve()
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        off()
        reject(new Error('配对超时'))
      }, timeoutMs)
      const off = this.relay.onState(() => {
        if (this.relay.state === 'paired') {
          clearTimeout(timer)
          off()
          resolve()
        }
      })
    })
  }

  /** 信令 request：按 requestId 挂 matcher，响应不保证回带 id，人人过一遍。 */
  request(
    payload: RpcFramePayload,
    match: (p: RpcFramePayload) => boolean,
    timeoutMs = 30_000,
  ): Promise<RpcFramePayload> {
    const requestId = payload['requestId'] as string
    return new Promise((resolve, reject) => {
      this.matchers.set(requestId, match)
      this.completers.set(requestId, { resolve, reject })
      this.relay.sendPayload(payload)
      setTimeout(() => {
        if (this.completers.has(requestId)) {
          this.matchers.delete(requestId)
          this.completers.delete(requestId)
          reject(new Error(`request ${requestId} timed out`))
        }
      }, timeoutMs)
    })
  }

  private dispatch(payload: RpcFramePayload): void {
    const type = payload['zcode_type']
    if (type === PUSH_WORKSPACE_LIST_UPDATED) {
      this.workspaces = ((payload['result'] as Record<string, unknown> | undefined)?.[
        'workspaces'
      ] as Workspace[] | undefined) ?? this.workspaces
      for (const l of this.workspaceListListeners) l(payload['result'])
      return
    }
    if (type === PUSH_BRIDGE_DEGRADED) {
      const id = payload['bridgeSessionId'] as string | undefined
      const reason = String(payload['reason'] ?? 'unknown')
      this.onLog?.(`[bridge] degraded: ${id} reason=${reason}`)
      for (const b of this.activeBridges) {
        if (b.info['bridgeSessionId'] === id) {
          b.setDegraded(reason)
          void b.recoverWithRetry()
        }
      }
      return
    }
    if (type === 'rpc-frame' || type === 'rpc-frame-ack') {
      const id = payload['bridgeSessionId'] as string | undefined
      const bridge = id ? this.frameRouters.get(id) : undefined
      if (bridge) bridge.frames.accept(payload)
      else if (id) {
        const list = this.pendingBridgePayloads.get(id) ?? []
        list.push(payload)
        this.pendingBridgePayloads.set(id, list)
      }
      return
    }
    const done: string[] = []
    for (const [requestId, match] of this.matchers) {
      const completer = this.completers.get(requestId)
      if (completer && match(payload)) {
        done.push(requestId)
        completer.resolve(payload)
      }
    }
    for (const id of done) {
      this.matchers.delete(id)
      this.completers.delete(id)
    }
  }

  async bootstrap(): Promise<Record<string, unknown>> {
    const res = await this.request(
      { zcode_type: SIG_BOOTSTRAP, requestId: genId('boot') },
      (p) => p['zcode_type'] === SIG_BOOTSTRAP_RESPONSE,
    )
    return (res['result'] as Record<string, unknown>) ?? res
  }

  sendViewState(workspaceKey: string, taskId?: string): void {
    this.relay.sendPayload({
      zcode_type: SIG_VIEW_STATE_UPDATE,
      viewState: {
        activeWorkspaceKey: workspaceKey,
        ...(taskId ? { activeTaskId: taskId } : {}),
        updatedAt: Date.now(),
      },
      deviceInfo: {
        platform: 'web',
        version: this.params.appVersion ?? 'zremote',
        name: 'zremote',
      },
    })
  }

  onWorkspaceList(listener: (result: unknown) => void): () => void {
    this.workspaceListListeners.add(listener)
    return () => this.workspaceListListeners.delete(listener)
  }

  /** workspace-bridge-open → ready → rpc-frame/IPC 栈（单活动桥语义）。 */
  async openBridge(workspaceKey: string, taskId?: string, timeoutMs = 30_000): Promise<Bridge> {
    const requestedId = genId('bridge')
    const generation = ++this.bridgeGeneration
    const res = await this.request(
      {
        zcode_type: SIG_BRIDGE_OPEN,
        requestId: genId('open'),
        bridgeSessionId: requestedId,
        bridgeGeneration: generation,
        workspaceKey,
        ...(taskId ? { taskId } : {}),
      },
      (p) =>
        (p['zcode_type'] === SIG_BRIDGE_READY || p['zcode_type'] === SIG_BRIDGE_ERROR) &&
        p['bridgeSessionId'] === requestedId,
      timeoutMs,
    )
    if (res['zcode_type'] === SIG_BRIDGE_ERROR) {
      throw new Error(`workspace-bridge-error: ${res['error'] ?? JSON.stringify(res)}`)
    }
    const info = (res['bridge'] as Record<string, unknown> | undefined) ?? {}
    this.onLog?.(`[bridge] ready: ${JSON.stringify(info)}`)
    const bridge = new Bridge(this, info)
    this.attachStack(bridge, info)
    this.activeBridges.push(bridge)
    const key = (info['workspaceKey'] as string | undefined) ?? workspaceKey
    this.sendViewState(key, bridge.initialTaskId ?? taskId)
    return bridge
  }

  private attachStack(bridge: Bridge, info: Record<string, unknown>): void {
    bridge.attach(info)
    const id = String(info['bridgeSessionId'] ?? '')
    this.frameRouters.set(id, bridge)
    const pending = this.pendingBridgePayloads.get(id)
    if (pending) {
      this.pendingBridgePayloads.delete(id)
      for (const payload of pending) bridge.frames.accept(payload)
    }
  }

  dispose(): void {
    for (const u of this.unsubs) u()
    for (const b of [...this.activeBridges]) b.dispose()
    this.relay.dispose()
    this.payloadListeners.clear()
  }
}
