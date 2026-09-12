/// Value-stream codec — TS 移植自 lib/protocol/value_codec.dart。
/// VS Code IPC 血统的二进制编解码。
/// Tags: Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4,
/// Object=5（JSON 字节）, Int=6（0..0x7FFFFFFF varint）。
/// 长度/计数为 7-bit 小端 varint。

const MAX_CONTAINER_ITEMS = 100_000
const MAX_VALUE_BYTES = 16 * 1024 * 1024

class BytesWriter {
  private chunks: Uint8Array[] = []
  private length = 0

  byte(v: number): void {
    const arr = new Uint8Array(1)
    arr[0] = v & 0xff
    this.chunks.push(arr)
    this.length += 1
  }

  bytes(b: Uint8Array): void {
    this.chunks.push(b)
    this.length += b.length
  }

  varint(value: number): void {
    let v = value
    do {
      let byte = v & 0x7f
      v = Math.floor(v / 128) // 无符号 7 位右移
      if (v > 0) byte |= 0x80
      this.byte(byte & 0xff)
    } while (v > 0)
  }

  take(): Uint8Array {
    const out = new Uint8Array(this.length)
    let pos = 0
    for (const c of this.chunks) {
      out.set(c, pos)
      pos += c.length
    }
    return out
  }
}

const enc = new TextEncoder()
const dec = new TextDecoder()

export class ValueWriter {
  private w = new BytesWriter()

  writeValue(value: unknown): void {
    if (value === null || value === undefined) {
      this.w.byte(0)
    } else if (typeof value === 'string') {
      const bytes = enc.encode(value)
      this.w.byte(1)
      this.w.varint(bytes.length)
      this.w.bytes(bytes)
    } else if (value instanceof Uint8Array) {
      this.w.byte(3)
      this.w.varint(value.length)
      this.w.bytes(value)
    } else if (Array.isArray(value)) {
      this.w.byte(4)
      this.w.varint(value.length)
      for (const item of value) this.writeValue(item)
    } else if (typeof value === 'number' && Number.isInteger(value) && value >= 0 && value <= 0x7fffffff) {
      this.w.byte(6)
      this.w.varint(value)
    } else {
      const bytes = enc.encode(JSON.stringify(value))
      this.w.byte(5)
      this.w.varint(bytes.length)
      this.w.bytes(bytes)
    }
  }

  take(): Uint8Array {
    return this.w.take()
  }
}

export class ValueReader {
  pos = 0

  constructor(public data: Uint8Array) {}

  private read(n: number): Uint8Array {
    if (this.pos + n > this.data.length) {
      throw new Error(`ValueReader: need ${n} bytes, only ${this.data.length - this.pos} left`)
    }
    const out = this.data.subarray(this.pos, this.pos + n)
    this.pos += n
    return out
  }

  private varint(): number {
    let value = 0
    let shift = 0
    while (this.pos < this.data.length) {
      const b = this.read(1)[0]
      value += (b & 0x7f) * Math.pow(2, shift) // 避免 32 位溢出
      if ((b & 0x80) === 0) return value
      shift += 7
      if (shift >= 35) break
    }
    throw new Error('invalid varint')
  }

  readValue(): unknown {
    const tag = this.read(1)[0]
    switch (tag) {
      case 0:
        return null
      case 1: {
        const length = this.varint()
        if (length > MAX_VALUE_BYTES) throw new Error('string too large')
        return dec.decode(this.read(length))
      }
      case 2:
      case 3: {
        const length = this.varint()
        if (length > MAX_VALUE_BYTES) throw new Error('bytes too large')
        return this.read(length)
      }
      case 4: {
        const count = this.varint()
        if (count > MAX_CONTAINER_ITEMS) throw new Error('list too large')
        const out: unknown[] = new Array(count)
        for (let i = 0; i < count; i++) out[i] = this.readValue()
        return out
      }
      case 5: {
        const length = this.varint()
        if (length > MAX_VALUE_BYTES) throw new Error('object too large')
        return JSON.parse(dec.decode(this.read(length)))
      }
      case 6:
        return this.varint()
      default:
        throw new Error(`unknown value tag ${tag}`)
    }
  }
}
