// ValueCodec —— VS Code IPC 血统的二进制编解码，双端（Dart/TS）互操作的回归锁。
//
// 此前只在 channel-client 测试里被间接使用，无语义断言（审计 B4 剩余）。
// 钉五条：tag 语义、varint 多字节、嵌套容器、bytes 走 VSBuffer(tag 3)、
// 非负整数走 Int(tag 6) 而其他数字落 JSON(tag 5)。
import { describe, expect, it } from 'vitest'
import { ValueReader, ValueWriter } from '../src/protocol/valueCodec'

function roundtrip(value: unknown): unknown {
  const w = new ValueWriter()
  w.writeValue(value)
  return new ValueReader(w.take()).readValue()
}

describe('ValueCodec', () => {
  it('标量：null/字符串/正整数 roundtrip', () => {
    expect(roundtrip(null)).toBe(null)
    expect(roundtrip(undefined)).toBe(null) // Undefined 与 null 同 tag
    expect(roundtrip('hello 中文')).toBe('hello 中文')
    expect(roundtrip(0)).toBe(0)
    expect(roundtrip(127)).toBe(127)
    expect(roundtrip(128)).toBe(128)
    expect(roundtrip(0x7fffffff)).toBe(0x7fffffff)
  })

  it('varint 多字节编码：128 写 2 字节（首字节带续位）', () => {
    const w = new ValueWriter()
    w.writeValue(128)
    const bytes = w.take()
    // tag(6) + varint：0x80 0x01
    expect(Array.from(bytes)).toEqual([6, 0x80, 0x01])
  })

  it('字节走 VSBuffer(tag 3)，读回是等值 Uint8Array', () => {
    const src = new Uint8Array([0, 1, 2, 0xff, 0x80])
    const out = roundtrip(src) as Uint8Array
    expect(Array.from(out)).toEqual(Array.from(src))
  })

  it('嵌套数组/对象 roundtrip；对象走 JSON(tag 5)', () => {
    const v = { a: 1, b: ['x', 2, true], c: { d: null } }
    expect(roundtrip(v)).toEqual(v)
    expect(roundtrip([1, [2, [3]]])).toEqual([1, [2, [3]]])
    expect(roundtrip(true)).toBe(true)
    expect(roundtrip(1.5)).toBe(1.5) // 非整数 → JSON 分支
  })

  it('越界读取抛错（截断帧不静默错位）', () => {
    const w = new ValueWriter()
    w.writeValue('abc')
    const bytes = w.take()
    expect(() => new ValueReader(bytes.subarray(0, 2)).readValue()).toThrow()
    expect(() => new ValueReader(new Uint8Array([9])).readValue()).toThrow(/unknown value tag/)
  })
})
