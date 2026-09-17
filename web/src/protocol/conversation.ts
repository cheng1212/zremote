/// Conversation V4 — TS 移植自 lib/protocol/conversation.dart 的核心链路。
/// Flow: hello → initialize(clientHello) → subscribe(scope+sessionId) →
/// frames via dynamic event → commands via sendConversationCommandV4。
/// 本期对齐：握手、会话订阅（快照/增量帧、微批）、sessions-index 订阅、
/// 发送命令（CAS）、rowsRange 翻页、ResyncGate 单飞闸。

import type { Bridge } from './remoteSession'
import { ChannelClient } from './channelClient'
import { Subscription } from './subscription'
import { sha256Hex } from '../lib/crypto'
import { base64ToBytes } from '../lib/fragments'
import {
  CONV_CHANNEL,
  CONV_PROTOCOL_VERSION,
  CONV_PROTOCOL_APP_VERSION,
  CONV_CLIENT_KIND,
  M_HELLO,
  M_INITIALIZE,
  M_SEND_COMMAND,
  M_SUBSCRIBE_CONV,
  M_UNSUBSCRIBE_CONV,
  M_RESYNC_CONV,
  M_SUBSCRIBE_INDEX,
  M_UNSUBSCRIBE_INDEX,
  M_RESYNC_INDEX,
  EV_CONV_FRAME,
  EV_INDEX_FRAME,
  M_ROWS_RANGE,
  M_ATTACHMENT_BEGIN,
  M_ATTACHMENT_CHUNK,
  M_ATTACHMENT_COMMIT,
  M_ATTACHMENT_READ,
  ATTACHMENT_CHUNK_BYTES,
  CAS_COMMANDS,
  ROW_TARGET_COMMANDS,
  genId,
  genUuid,
} from './constants'

type Frame = Record<string, unknown>

/**
 * Uint8Array → base64。
 * 分块拼接（每块 32KiB）避免 `String.fromCharCode(...大数组)` 爆调用栈——
 * 附件分片 384KiB，一次性展开会直接 RangeError。
 */
function toBase64(bytes: Uint8Array): string {
  let bin = ''
  const CHUNK = 0x8000
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(bin)
}

/** 拼接多段字节（读回附件时按片累积）。 */
function concatBytes(parts: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total)
  let off = 0
  for (const p of parts) {
    out.set(p, off)
    off += p.length
  }
  return out
}

export interface ConvRow extends Frame {
  rowId?: number
  kind?: string
  state?: string
  text?: string
}

/** 单飞闸与微批队列已抽到 `lib/gates.ts`（订阅层也要用，避免循环依赖）。
 *  这里 re-export 保持既有引用不破。 */
export { ResyncGate } from '../lib/gates'

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

  /**
   * 订阅一个会话。
   *
   * ⚠️ **不要在回调里直接读 `data.payload`**——服务端推来的是**信封**
   * （`{kind:"complete", frame:{payload:…}}` 或 `{kind:"fragment", …dataBase64}`），
   * 真正的帧在下一层。原实现直接把信封当帧读 `payload`，导致每一帧都被静默
   * 丢弃、聊天记录永远加载不出来。信封解包与分片组装在 `Subscription` 里。
   */
  subscribeSession(
    sessionId: string,
    onFrame: (frame: Frame) => void,
    getBase?: () => { seq: number; logEpoch: string | null },
  ): Subscription {
    const sub = new Subscription(this.ch, {
      channel: CONV_CHANNEL,
      event: EV_CONV_FRAME,
      subscribeMethod: M_SUBSCRIBE_CONV,
      unsubscribeMethod: M_UNSUBSCRIBE_CONV,
      resyncMethod: M_RESYNC_CONV,
      subscribeArgs: { sessionId },
      unsubscribeArgs: {},
      // 断档恢复靠整份快照：本地 seq 已对不上，只有全量能重新对齐。
      resyncArgs: { forceSnapshot: true },
      tag: 'v4',
      scope: () => this.bridge.scope,
      onFrame,
      getBase: getBase ?? (() => ({ seq: 0, logEpoch: null })),
      onLog: this.onLog,
    })
    const old = this.convSubs.get(sessionId)
    if (old) old.cancel()
    this.convSubs.set(sessionId, sub)
    void sub.start().catch((e) => this.onLog?.(`[v4] subscribe failed: ${e}`))
    return sub
  }

  /** 会话订阅表（按 sessionId）。 */
  private convSubs = new Map<string, Subscription>()

  /** sessions-index 订阅（任务列表实时帧）。 */
  subscribeIndex(
    onFrame: (frame: Frame) => void,
    getBase?: () => { seq: number; logEpoch: string | null },
  ): Subscription {
    const sub = new Subscription(this.ch, {
      channel: CONV_CHANNEL,
      event: EV_INDEX_FRAME,
      subscribeMethod: M_SUBSCRIBE_INDEX,
      unsubscribeMethod: M_UNSUBSCRIBE_INDEX,
      resyncMethod: M_RESYNC_INDEX,
      // ⚠️ 订阅**不能**带 runtimePolicy:'existing-only'——该策略语义是
      // 「只准挂到已经在跑的运行时上」，目标工作区的 agent 运行时没在跑时
      // 桌面端会在 1ms 内直接拒绝（ZCode Agent runtime is not running），
      // 切项目必然报错（BUG-09）。不传则桌面端走 start-if-needed。
      subscribeArgs: {},
      // 退订 / 重同步**保持** existing-only：清理与断线恢复路径不该顺手启动运行时。
      unsubscribeArgs: { runtimePolicy: 'existing-only' },
      resyncArgs: { runtimePolicy: 'existing-only', forceSnapshot: true },
      tag: 'v4-index',
      scope: () => this.bridge.scope,
      onFrame,
      getBase: getBase ?? (() => ({ seq: 0, logEpoch: null })),
      onLog: this.onLog,
    })
    this.indexSub?.cancel()
    this.indexSub = sub
    void sub.start().catch((e) => this.onLog?.(`[v4] index subscribe failed: ${e}`))
    return sub
  }

  private indexSub: Subscription | null = null

  /** 索引断档重同步（单飞闸在 Subscription 内部）。 */
  resyncIndex(): void {
    this.indexSub?.resync()
  }

  /** 会话断档重同步（单飞闸在 Subscription 内部）。 */
  resync(sessionId: string): void {
    this.convSubs.get(sessionId)?.resync()
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

  async sendText(
    sessionId: string,
    text: string,
    opts?: {
      heldQueueDisposition?: string
      attachments?: Record<string, unknown>[]
    },
  ): Promise<unknown> {
    const payload: Record<string, unknown> = { text }
    if (opts?.heldQueueDisposition) payload['heldQueueDisposition'] = opts.heldQueueDisposition
    // 附件为空数组时**不传**该字段：桌面端 zod 对空数组与缺字段的处理不同，
    // 空数组可能被判为「有附件但无效」。
    if (opts?.attachments && opts.attachments.length > 0) {
      payload['attachments'] = opts.attachments
    }
    return this.sendCommand(sessionId, 'sendText', payload, {
      baseRevision: 0,
      logEpoch: null,
    })
  }

  stop(sessionId: string): Promise<unknown> {
    return this.sendCommand(sessionId, 'stop', {}, { baseRevision: 0, logEpoch: null })
  }

  /**
   * 回答询问 / 审批。
   *
   * **服务端在 `pendingInteractions` 非空时在等这个回答，回合不会继续**——
   * 不回传会话就永久卡住。两个分支形状不同（BUG-17 实测）：
   * · questions：`{action:'accept', content:{answers:[{question, selected:[…]}]}}`
   * · permission：`{optionId}`
   * 两者都用同一个 `answer` 包一层。
   */
  resolveInteraction(
    sessionId: string,
    interactionId: string,
    answer: {
      optionId?: string
      freeText?: string
      action?: string
      content?: Record<string, unknown>
    },
  ): Promise<unknown> {
    const payload: Record<string, unknown> = { interactionId, answer: {} }
    const a = payload['answer'] as Record<string, unknown>
    if (answer.optionId != null) a['optionId'] = answer.optionId
    if (answer.freeText != null) a['freeText'] = answer.freeText
    if (answer.action != null) a['action'] = answer.action
    if (answer.content != null) a['content'] = answer.content
    return this.sendCommand(sessionId, 'resolveInteraction', payload, {
      baseRevision: 0,
      logEpoch: null,
    })
  }

  /**
   * 上传附件（begin → chunk → commit，对齐移动端 `attachmentPut`）。
   *
   * 返回 `{ref, fileName, mime, bytes}`，随 `sendText` 的 `attachments` 发出去。
   * 服务端把文件落到**会话 cwd 的 `uploads/`**，消息以电脑本地路径引用它。
   *
   * 两个必须照抄的细节：
   * · `connectionId` 来自 hello，**没有它上传必失败**（桥没完成握手）。
   * · 服务端回的 `nextChunkIndex` 必须等于 n+1；不吻合要报错而不是继续——
   *   继续会写出坏文件，而坏文件在服务端看起来是「上传成功」。
   *
   * @param isCancelled 分片边界检查取消旗标。分片边界是唯一自然的取消窗口：
   *   每片一个网络往返，延迟天然限频。
   */
  async attachmentPut(
    sessionId: string,
    opts: {
      fileName: string
      mime: string
      bytes: Uint8Array
      onProgress?: (ratio: number) => void
      isCancelled?: () => boolean
    },
  ): Promise<{ ref: string; fileName: string; mime: string; bytes: number }> {
    await this.handshake()
    const connId = this.connectionId
    if (!connId) throw new Error('attachmentPut: 缺少 connectionId（桥未完成握手）')

    const uploadId = `upload-${genUuid()}`
    const scope = this.bridge.scope
    const base = { connectionId: connId, uploadId, sessionId }
    const totalBytes = opts.bytes.length
    const totalChunks = Math.max(1, Math.ceil(totalBytes / ATTACHMENT_CHUNK_BYTES))
    const checksum = `sha256:${await sha256Hex(opts.bytes)}`

    const beginRes = (await this.ch.call(CONV_CHANNEL, M_ATTACHMENT_BEGIN, [
      {
        ...scope,
        ...base,
        fileName: opts.fileName,
        mime: opts.mime,
        totalBytes,
        totalChunks,
        checksum,
      },
    ])) as Record<string, unknown> | null

    // 服务端已存过同校验文件（秒传）
    if (beginRes && beginRes['state'] === 'committed') {
      opts.onProgress?.(1)
      return {
        ref: String(beginRes['ref'] ?? ''),
        fileName: opts.fileName,
        mime: opts.mime,
        bytes: totalBytes,
      }
    }

    let nextChunk =
      beginRes && typeof beginRes['nextChunkIndex'] === 'number'
        ? (beginRes['nextChunkIndex'] as number)
        : 0

    for (let n = nextChunk; n < totalChunks; n++) {
      if (opts.isCancelled?.()) throw new Error('上传已取消')
      const start = n * ATTACHMENT_CHUNK_BYTES
      const end = Math.min(start + ATTACHMENT_CHUNK_BYTES, totalBytes)
      const chunkRes = (await this.ch.call(CONV_CHANNEL, M_ATTACHMENT_CHUNK, [
        {
          ...scope,
          ...base,
          chunkIndex: n,
          dataBase64: toBase64(opts.bytes.subarray(start, end)),
        },
      ])) as Record<string, unknown> | null

      nextChunk =
        chunkRes && typeof chunkRes['nextChunkIndex'] === 'number'
          ? (chunkRes['nextChunkIndex'] as number)
          : n + 1
      if (nextChunk !== n + 1) {
        throw new Error(`attachmentPut: 服务器分片进度异常 (${nextChunk})`)
      }
      opts.onProgress?.(nextChunk / totalChunks)
    }

    opts.onProgress?.(1)
    const commitRes = (await this.ch.call(CONV_CHANNEL, M_ATTACHMENT_COMMIT, [
      { ...scope, ...base },
    ])) as Record<string, unknown> | null
    const ref = commitRes ? commitRes['ref'] : null
    if (typeof ref !== 'string' || !ref) {
      throw new Error('attachmentPut: commit 未返回 ref')
    }
    return { ref, fileName: opts.fileName, mime: opts.mime, bytes: totalBytes }
  }

  /**
   * 读回附件字节（图片预览 / 文件下载用）。
   *
   * ⚠️ **这是网页端唯一的「读文件」途径**：浏览器有安全沙箱，
   * 读不到本地路径（`D:\…` 打不开、`file://` URL 也加载不了，Chrome 直接报
   * "Not allowed to load local resource"）。Flutter 是原生 App 才有文件系统
   * 权限。所以正解只能是**按 ref 走协议拉字节**，本地拼成 Blob 再显示。
   *
   * 服务端按 offset/limit 分片返回；`nextOffset <= offset` 或
   * `offset >= totalBytes` 即结束。**64MB 上限**防服务端谎报大小把内存撑爆
   * （对齐移动端 `attachmentRead` 的护栏）。
   */
  async attachmentRead(
    sessionId: string,
    ref: string,
  ): Promise<{ bytes: Uint8Array; mediaType: string | null }> {
    await this.handshake()
    const MAX_TOTAL_BYTES = 64 * 1024 * 1024
    const parts: Uint8Array[] = []
    let total = 0
    let offset = 0
    let mediaType: string | null = null

    for (let round = 0; round < 1024; round++) {
      const res = (await this.ch.call(CONV_CHANNEL, M_ATTACHMENT_READ, [
        {
          ...this.bridge.scope,
          sessionId,
          ref,
          offset,
          limit: ATTACHMENT_CHUNK_BYTES,
        },
      ])) as Record<string, unknown> | null
      if (!res || typeof res !== 'object') break

      if (mediaType == null && typeof res['mediaType'] === 'string') {
        mediaType = res['mediaType'] as string
      }
      const data = res['dataBase64']
      if (typeof data === 'string' && data) {
        const bytes = base64ToBytes(data)
        parts.push(bytes)
        total += bytes.length
      }
      if (total > MAX_TOTAL_BYTES) {
        this.onLog?.('[v4] attachmentRead aborted: exceeds 64MB')
        break
      }
      const next = typeof res['nextOffset'] === 'number' ? (res['nextOffset'] as number) : null
      const totalBytes = typeof res['totalBytes'] === 'number' ? (res['totalBytes'] as number) : null
      if (next == null || next <= offset) break
      offset = next
      if (totalBytes != null && offset >= totalBytes) break
    }

    return { bytes: concatBytes(parts, total), mediaType }
  }
}
