// 加密工具 —— 回归锁。
//
// 为什么必须有：`crypto.subtle` / `crypto.randomUUID` **只在安全上下文**
// （https / localhost）可用。局域网 http 访问（手机连 IP，本项目主要用法）
// 时两者都是 undefined——`crypto.randomUUID()` 直接抛 TypeError。
// 所以 UUID 与 SHA-256 都有自实现降级，必须用已知向量钉住正确性。
import { describe, expect, it } from 'vitest'
import { randomUuid, sha256Bytes, sha256Hex } from '../src/lib/crypto'

function hex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('')
}

describe('sha256Bytes —— 纯 JS 实现（非安全上下文用）', () => {
  it('空输入：NIST 已知向量', () => {
    expect(hex(sha256Bytes(new Uint8Array(0)))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    )
  })

  it('"abc"：NIST 已知向量', () => {
    expect(hex(sha256Bytes(new TextEncoder().encode('abc')))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    )
  })

  it('"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"（跨块边界）', () => {
    expect(
      hex(sha256Bytes(new TextEncoder().encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
    ).toBe('248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
  })

  it('55 / 56 / 64 字节（padding 边界）都能算', () => {
    // 这三个长度分别落在「不需额外块 / 需额外块 / 恰好整块」的边界上
    for (const n of [55, 56, 64]) {
      const out = sha256Bytes(new Uint8Array(n).fill(0x61))
      expect(out.length).toBe(32)
      expect(hex(out)).toMatch(/^[0-9a-f]{64}$/)
    }
    // 55 与 56 的填充路径不同，结果必须不同（防 padding 写错）
    expect(hex(sha256Bytes(new Uint8Array(55).fill(0x61)))).not.toBe(
      hex(sha256Bytes(new Uint8Array(56).fill(0x61))),
    )
  })

  it('长输入（>1 个块，含 1000 字节）稳定', () => {
    const out = sha256Bytes(new Uint8Array(1000).fill(7))
    expect(out.length).toBe(32)
    // 同样输入两次结果一致
    expect(hex(out)).toBe(hex(sha256Bytes(new Uint8Array(1000).fill(7))))
  })
})

describe('sha256Hex', () => {
  it('与纯 JS 实现结果一致（走原生或降级都对）', async () => {
    const data = new TextEncoder().encode('zremote 附件校验')
    const viaApi = await sha256Hex(data)
    const viaJs = hex(sha256Bytes(data))
    expect(viaApi).toBe(viaJs)
    expect(viaApi).toMatch(/^[0-9a-f]{64}$/)
  })

  it('带 byteOffset 的 subarray 也正确（原生路径曾在这里算错）', async () => {
    const full = new TextEncoder().encode('XXXabc')
    const slice = full.subarray(3) // "abc"
    expect(await sha256Hex(slice)).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    )
  })

  it('空输入与已知向量一致', async () => {
    expect(await sha256Hex(new Uint8Array(0))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    )
  })
})

describe('randomUuid', () => {
  it('格式是 v4 UUID', () => {
    const id = randomUuid()
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  })

  it('多次调用不重复', () => {
    const set = new Set<string>()
    for (let i = 0; i < 200; i++) set.add(randomUuid())
    expect(set.size).toBe(200)
  })
})
