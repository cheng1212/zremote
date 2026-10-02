// crc32 —— 协议帧校验的回归锁。
//
// 钉两条：① 标准向量（CRC-32/IEEE 802.3，与 zlib/桌面端 Dart 实现同源）；
// ② hex 输出 8 位零填充无 0x 前缀（服务端按字符串比对 checksum.value）。
// 此前零测试——算法抄错一位，所有 rpc-frame 都会在服务端 checksum mismatch。
import { describe, expect, it } from 'vitest'
import { crc32, crc32Hex } from '../src/protocol/crc32'

const bytesOf = (s: string) => new TextEncoder().encode(s)

describe('crc32（CRC-32/IEEE 802.3）', () => {
  it('标准向量：123456789 → 0xcbf43926', () => {
    expect(crc32(bytesOf('123456789'))).toBe(0xcbf43926)
  })

  it('标准向量：空串 → 0，"a" → 0xe8b7be43，"abc" → 0x352441c2', () => {
    expect(crc32(bytesOf(''))).toBe(0)
    expect(crc32(bytesOf('a'))).toBe(0xe8b7be43)
    expect(crc32(bytesOf('abc'))).toBe(0x352441c2)
  })

  it('含非 ASCII 字节（UTF-8 多字节）也算得稳', () => {
    // 参考值经 Python zlib.crc32 预计算（同 IEEE 802.3 多项式）。
    expect(crc32Hex(bytesOf('中文'))).toBe('5a09ed37')
    expect(crc32Hex(bytesOf('The quick brown fox jumps over the lazy dog'))).toBe('414fa339')
  })

  it('hex 输出 8 位零填充、无 0x 前缀', () => {
    expect(crc32Hex(bytesOf(''))).toBe('00000000')
    expect(crc32Hex(bytesOf('a'))).toBe('e8b7be43')
    expect(crc32Hex(bytesOf('123456789'))).toBe('cbf43926')
  })
})
