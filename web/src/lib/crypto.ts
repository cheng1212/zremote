/// 加密工具 —— 带**非安全上下文降级**。
///
/// ⚠️ 这不是防御性编程，是真实约束：`crypto.subtle` 与 `crypto.randomUUID`
/// **只在安全上下文可用**（https 或 localhost）。局域网 http 访问
/// （例如 `http://192.168.31.194:5173`）时两者都是 `undefined`：
/// · `crypto.randomUUID()` 直接抛 TypeError → uploadId / clientId 生成失败；
/// · `crypto.subtle.digest` 不可用 → 附件 sha256 校验算不出来 → 上传失败。
/// 而「手机连局域网 IP 打开」正是本项目的**主要使用方式**。
///
/// 所以这里两个都自己做降级：
/// · UUID 用 `crypto.getRandomValues`（**不受**安全上下文限制）拼 v4；
/// · SHA-256 用纯 JS 实现（无依赖，任何上下文都能跑）。
/// 性能足够：附件分片 384KiB，纯 JS 算一次在毫秒级。

/** 随机 UUID v4。优先原生，非安全上下文用 getRandomValues 自拼。 */
export function randomUuid(): string {
  const c = globalThis.crypto as Crypto | undefined
  if (c && typeof c.randomUUID === 'function') {
    try {
      return c.randomUUID()
    } catch {
      /* 某些环境存在但抛错——落到下面的兜底 */
    }
  }
  const bytes = new Uint8Array(16)
  if (c && typeof c.getRandomValues === 'function') {
    c.getRandomValues(bytes)
  } else {
    // 最后兜底：Math.random。**只用于本地标识**，不用于安全用途
    //（配对凭据来自链接参数，不经过这里）。
    for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256)
  }
  // 版本位与变体位（RFC 4122 v4）
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex: string[] = []
  for (let i = 0; i < 16; i++) hex.push(bytes[i].toString(16).padStart(2, '0'))
  return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex
    .slice(8, 10)
    .join('')}-${hex.slice(10, 16).join('')}`
}

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
])

function rotr(x: number, n: number): number {
  return (x >>> n) | (x << (32 - n))
}

/** 纯 JS SHA-256。无依赖，非安全上下文可用。 */
export function sha256Bytes(data: Uint8Array): Uint8Array {
  const H = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ])
  const len = data.length
  const bitLen = len * 8
  // padding: 1 位 '1' + k 个 '0' + 64 位长度，使总长 ≡ 0 mod 64
  const padded = new Uint8Array(((len + 9 + 63) >> 6) << 6)
  padded.set(data)
  padded[len] = 0x80
  // 64 位长度（高 32 位本场景恒为 0，但照写以防大文件）
  const hi = Math.floor(bitLen / 0x100000000)
  const lo = bitLen >>> 0
  const dv = new DataView(padded.buffer)
  dv.setUint32(padded.length - 8, hi)
  dv.setUint32(padded.length - 4, lo)

  const w = new Uint32Array(64)
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4)
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0
    }
    let [a, b, c, d, e, f, g, h] = H
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      const ch = (e & f) ^ (~e & g)
      const t1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      const maj = (a & b) ^ (a & c) ^ (b & c)
      const t2 = (S0 + maj) >>> 0
      h = g
      g = f
      f = e
      e = (d + t1) >>> 0
      d = c
      c = b
      b = a
      a = (t1 + t2) >>> 0
    }
    H[0] = (H[0] + a) >>> 0
    H[1] = (H[1] + b) >>> 0
    H[2] = (H[2] + c) >>> 0
    H[3] = (H[3] + d) >>> 0
    H[4] = (H[4] + e) >>> 0
    H[5] = (H[5] + f) >>> 0
    H[6] = (H[6] + g) >>> 0
    H[7] = (H[7] + h) >>> 0
  }
  const out = new Uint8Array(32)
  const odv = new DataView(out.buffer)
  for (let i = 0; i < 8; i++) odv.setUint32(i * 4, H[i])
  return out
}

function toHex(bytes: Uint8Array): string {
  let s = ''
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, '0')
  return s
}

/**
 * SHA-256 十六进制。优先原生 `crypto.subtle`（快），不可用时落纯 JS。
 * 两者结果一致——`tests/crypto.test.ts` 用已知向量钉住。
 */
export async function sha256Hex(data: Uint8Array): Promise<string> {
  const c = globalThis.crypto as Crypto | undefined
  if (c && c.subtle && typeof c.subtle.digest === 'function') {
    try {
      // 传 ArrayBuffer 副本：subarray 的 buffer 可能带 offset，直接传会算错
      const buf = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)
      const digest = await c.subtle.digest('SHA-256', buf)
      return toHex(new Uint8Array(digest))
    } catch {
      /* 非安全上下文或算法不可用——落纯 JS */
    }
  }
  return toHex(sha256Bytes(data))
}

/** 是否运行在安全上下文（https / localhost）。用于给用户提示能力降级。 */
export function isSecureContext(): boolean {
  return globalThis.isSecureContext === true
}
