/// 分片重组器 — 移植自 `lib/protocol/fragment_assembler.dart`。
///
/// **为什么必须有**：会话订阅帧是**信封结构**（`docs/API.md` L5）：
/// ```
/// {wireVersion:3, kind:"complete"|"fragment", topic, subscriptionId,
///  frame | logicalFrameId+fragmentIndex+fragmentCount+dataBase64}
/// ```
/// · `kind:"complete"` —— 真正的帧在 `frame` 字段里（**嵌一层**）
/// · `kind:"fragment"` —— 长内容被切成 ≤64 片 base64，需按 `logicalFrameId`
///   收齐后 base64 解码 + UTF-8 解码 + JSON 解析，才得到真正的帧
///
/// Web 端原实现直接把外层信封当帧读 `payload`——`payload` 在信封的下一层，
/// 所以**永远读不到**：会话列表拉不到、聊天记录加载不出来（用户报障
/// 「聊天记录和电脑依旧不同步，加载不了」的根因）。
///
/// 抽成纯类可单测：槽位覆盖、乱序到达、重复片、过期清理都要钉住。

export class FragmentAssembler {
  private parts: (Uint8Array | null)[]
  private received = 0
  readonly createdAt = Date.now()

  constructor(public readonly fragmentCount: number) {
    this.parts = new Array(fragmentCount).fill(null)
  }

  /** 收一片。越界忽略；重复片不重复计数（但会覆盖内容）。 */
  add(index: number, data: Uint8Array): void {
    if (index < 0 || index >= this.fragmentCount) return
    if (this.parts[index] === null) this.received += 1
    this.parts[index] = data
  }

  get isComplete(): boolean {
    return this.received === this.fragmentCount
  }

  /** 顺序拼装。缺失槽位按空处理（`isComplete` 为真时不会缺失）。 */
  assemble(): Uint8Array {
    let total = 0
    for (const p of this.parts) if (p) total += p.length
    const out = new Uint8Array(total)
    let off = 0
    for (const p of this.parts) {
      if (p) {
        out.set(p, off)
        off += p.length
      }
    }
    return out
  }
}

/** 分片表：按 `logicalFrameId` 收集，带过期清理。 */
export class FragmentTable {
  private map = new Map<string, FragmentAssembler>()

  constructor(private ttlMs = 60_000) {}

  /**
   * 收一片。收齐则返回组装好的原始字节，否则返回 null。
   * 片数不吻合（服务端换了分片方案）时丢弃该 id 的已有收集。
   */
  accept(frame: Record<string, unknown>): Uint8Array | null {
    const id = typeof frame['logicalFrameId'] === 'string' ? frame['logicalFrameId'] : null
    const index = typeof frame['fragmentIndex'] === 'number' ? frame['fragmentIndex'] : null
    const count = typeof frame['fragmentCount'] === 'number' ? frame['fragmentCount'] : null
    const dataBase64 = typeof frame['dataBase64'] === 'string' ? frame['dataBase64'] : null
    if (id == null || index == null || count == null || dataBase64 == null) return null
    if (count < 1 || count > 64 || index < 0 || index >= count) return null

    let asm = this.map.get(id)
    if (!asm) {
      asm = new FragmentAssembler(count)
      this.map.set(id, asm)
    } else if (asm.fragmentCount !== count) {
      // 片数变了：同一 logicalFrameId 不可能有两种片数，说明状态错乱，重来。
      this.map.delete(id)
      return null
    }

    let bytes: Uint8Array
    try {
      bytes = base64ToBytes(dataBase64)
    } catch {
      this.map.delete(id)
      return null
    }
    asm.add(index, bytes)
    if (!asm.isComplete) return null
    this.map.delete(id)
    return asm.assemble()
  }

  /** 清理超过 ttl 的残留（帧丢了永远收不齐，不清会一直占内存）。 */
  purge(now = Date.now()): number {
    let n = 0
    for (const [id, asm] of this.map) {
      if (now - asm.createdAt > this.ttlMs) {
        this.map.delete(id)
        n += 1
      }
    }
    return n
  }

  clear(): void {
    this.map.clear()
  }

  get size(): number {
    return this.map.size
  }
}

/** base64 → Uint8Array。 */
export function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

/** Uint8Array → base64（分块拼接避免爆栈）。 */
export function bytesToBase64(bytes: Uint8Array): string {
  let bin = ''
  const CHUNK = 0x8000
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(bin)
}

/**
 * 解包信封帧，返回**真正的逻辑帧**；需要继续收片的返回 null。
 *
 * - `kind:"complete"` → 取 `frame` 字段（嵌一层）
 * - `kind:"fragment"` → 交给分片表；收齐则 JSON 解析组装结果
 * - 其它/缺 kind → 返回 null（不认识的信封不猜）
 */
export function unwrapEnvelope(
  wire: Record<string, unknown>,
  table: FragmentTable,
): Record<string, unknown> | null {
  const kind = wire['kind']
  if (kind === 'complete') {
    const inner = wire['frame']
    return inner && typeof inner === 'object' ? (inner as Record<string, unknown>) : null
  }
  if (kind === 'fragment') {
    const bytes = table.accept(wire)
    if (!bytes) return null
    try {
      const text = new TextDecoder('utf-8').decode(bytes)
      const parsed = JSON.parse(text)
      return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null
    } catch {
      return null
    }
  }
  return null
}
