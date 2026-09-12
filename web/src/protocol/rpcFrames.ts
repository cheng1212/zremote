/// rpc-frame 分片传输 — TS 移植自 lib/protocol/rpc_frames.dart + fragment_assembler.dart。
/// 逻辑消息切块保证每个 JSON 信封 <512KB；每消息带 crc32 校验；
/// 对端用 rpc-frame-ack 确认。

import {
  RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES,
  RPC_FRAME_MAX_MESSAGE_BYTES,
  RPC_FRAME_MAX_FRAGMENTS,
} from './constants'
import { crc32Hex } from './crc32'

export interface RpcFramePayload {
  [k: string]: unknown
}

interface Assembly {
  parts: (Uint8Array | null)[]
  received: number
  fragmentCount: number
  messageBytes: number
  checksum: string | null
  createdAt: number
}

export class RpcFrames {
  private seq = 0
  private messageSeq = 0
  private assemblies = new Map<number, Assembly>()
  private cleanupTimer: ReturnType<typeof setInterval>

  constructor(
    private opts: {
      bridgeSessionId: string
      bridgeGeneration?: number
      recoveryId?: string
      send: (payload: RpcFramePayload) => void
      onMessage: (bytes: Uint8Array) => void
      onLog?: (line: string) => void
    },
  ) {
    this.cleanupTimer = setInterval(() => this.purge(), 30_000)
  }

  private get identity(): RpcFramePayload {
    return {
      bridgeSessionId: this.opts.bridgeSessionId,
      ...(this.opts.bridgeGeneration != null
        ? { bridgeGeneration: this.opts.bridgeGeneration }
        : {}),
      ...(this.opts.recoveryId ? { recoveryId: this.opts.recoveryId } : {}),
    }
  }

  sendMessage(bytes: Uint8Array): void {
    if (bytes.length === 0) throw new Error('empty rpc message')
    if (bytes.length > RPC_FRAME_MAX_MESSAGE_BYTES) throw new Error('rpc message too large')
    const messageSeq = ++this.messageSeq
    const checksum = crc32Hex(bytes)
    const fragmentCount = Math.ceil(bytes.length / RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES)
    if (fragmentCount > RPC_FRAME_MAX_FRAGMENTS) throw new Error('fragment limit exceeded')
    for (let i = 0; i < fragmentCount; i++) {
      const start = i * RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES
      const end = Math.min(start + RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES, bytes.length)
      const chunk = bytes.subarray(start, end)
      this.seq += 1
      this.opts.send({
        zcode_type: 'rpc-frame',
        ...this.identity,
        seq: this.seq,
        messageSeq,
        fragmentIndex: i,
        fragmentCount,
        messageBytes: bytes.length,
        checksum: { algorithm: 'crc32', value: checksum },
        dataBase64: uint8ToBase64(chunk),
      })
    }
  }

  /** 喂入 relay payload（只认 rpc-frame(-ack)；其余忽略）。 */
  accept(payload: RpcFramePayload): void {
    const type = payload['zcode_type']
    if (type !== 'rpc-frame' && type !== 'rpc-frame-ack') return
    if (payload['bridgeSessionId'] !== this.opts.bridgeSessionId) return

    if (type === 'rpc-frame-ack') return // 本端不发大消息时 ack 无需处理

    const messageSeq = payload['messageSeq'] as number | undefined
    const fragmentIndex = payload['fragmentIndex'] as number | undefined
    const fragmentCount = payload['fragmentCount'] as number | undefined
    const messageBytes = payload['messageBytes'] as number | undefined
    const dataBase64 = payload['dataBase64'] as string | undefined
    const checksum = (payload['checksum'] as Record<string, unknown> | undefined)?.value as
      | string
      | undefined
    if (
      messageSeq == null ||
      fragmentIndex == null ||
      fragmentCount == null ||
      messageBytes == null ||
      dataBase64 == null
    ) {
      return
    }
    if (
      messageSeq < 0 ||
      fragmentCount < 1 ||
      fragmentCount > RPC_FRAME_MAX_FRAGMENTS ||
      fragmentIndex < 0 ||
      fragmentIndex >= fragmentCount ||
      messageBytes < 1 ||
      messageBytes > RPC_FRAME_MAX_MESSAGE_BYTES
    ) {
      return
    }

    let chunk: Uint8Array
    try {
      chunk = base64ToUint8(dataBase64)
    } catch {
      return
    }
    if (chunk.length > RPC_FRAME_MAX_FRAGMENT_PAYLOAD_BYTES) return

    const existing = this.assemblies.get(messageSeq)
    if (
      existing &&
      (existing.fragmentCount !== fragmentCount ||
        existing.messageBytes !== messageBytes ||
        existing.checksum !== checksum)
    ) {
      this.assemblies.delete(messageSeq)
      return
    }
    let assembly = existing
    if (!assembly) {
      assembly = {
        parts: new Array(fragmentCount).fill(null),
        received: 0,
        fragmentCount,
        messageBytes,
        checksum: checksum ?? null,
        createdAt: Date.now(),
      }
      this.assemblies.set(messageSeq, assembly)
    }
    if (fragmentIndex >= 0 && fragmentIndex < assembly.fragmentCount) {
      if (assembly.parts[fragmentIndex] === null) assembly.received += 1
      assembly.parts[fragmentIndex] = chunk
    }
    if (assembly.received === assembly.fragmentCount) {
      this.assemblies.delete(messageSeq)
      const message = concat(assembly.parts.filter((p): p is Uint8Array => p !== null))
      if (message.length !== assembly.messageBytes) {
        this.opts.onLog?.(`[rpc] message ${messageSeq} size mismatch`)
      } else if (assembly.checksum === null || crc32Hex(message) === assembly.checksum) {
        this.opts.send({
          zcode_type: 'rpc-frame-ack',
          ...this.identity,
          ackMessageSeq: messageSeq,
        })
        this.opts.onMessage(message)
      } else {
        this.opts.onLog?.(`[rpc] message ${messageSeq} checksum mismatch`)
      }
    }
  }

  private purge(): void {
    const now = Date.now()
    for (const [seq, a] of this.assemblies) {
      if (now - a.createdAt > 60_000) {
        this.assemblies.delete(seq)
        this.opts.onLog?.(`[rpc] purged stale assembly ${seq}`)
      }
    }
  }

  dispose(): void {
    clearInterval(this.cleanupTimer)
    this.assemblies.clear()
  }
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0)
  const out = new Uint8Array(total)
  let pos = 0
  for (const p of parts) {
    out.set(p, pos)
    pos += p.length
  }
  return out
}

export function uint8ToBase64(bytes: Uint8Array): string {
  let bin = ''
  const CHUNK = 0x8000 // 32K 分块转换，避免 apply 栈溢出
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(bin)
}

export function base64ToUint8(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
