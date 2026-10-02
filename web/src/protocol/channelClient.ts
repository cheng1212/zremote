/// Channel RPC over bridge — TS 移植自 lib/protocol/channel_client.dart。
/// 请求头 `[reqType, reqId, channelName, name]` + 参数 value，二进制走 ValueCodec。

import {
  IPC_REQ_PROMISE,
  IPC_REQ_EVENT_LISTEN,
  IPC_REQ_EVENT_DISPOSE,
  IPC_RES_INITIALIZE,
  IPC_RES_PROMISE_SUCCESS,
  IPC_RES_PROMISE_ERROR,
  IPC_RES_PROMISE_ERROR_OBJ,
  IPC_RES_EVENT_FIRE,
} from './constants'
import { ValueReader, ValueWriter } from './valueCodec'

export class ChannelRpcError extends Error {
  constructor(message: string) {
    super(`ChannelRpcError: ${message}`)
    this.name = 'ChannelRpcError'
  }
}

type ResHandler = (type: number, data: unknown) => void

export class ChannelClient {
  private lastRequestId = 0
  private readyResolve: (() => void) | null = null
  private readyPromise: Promise<void> | null = null
  private readyReady = false
  private handlers = new Map<number, ResHandler>()
  private pending = new Map<
    number,
    { resolve: (v: unknown) => void; reject: (e: unknown) => void; timer?: ReturnType<typeof setTimeout> }
  >()
  private disposed = false

  constructor(
    private sendBody: (body: Uint8Array) => void,
    private onLog?: (line: string) => void,
  ) {}

  /**
   * 立刻可 await 的 ready promise（对齐 Dart 的 Completer）。
   *
   * ⚠️ 必须**缓存同一个 promise**：早先每次 `ready` 都新建一个 Promise 并把
   * `readyResolve` 覆盖掉，于是**只有最后一个 await 者**会被唤醒——
   * 冷桥面上并发发起多路调用时（`loadSessions` 的 `listTasks` +
   * `listPinnedTasks` 就是并发），先发起的那一路拿不到 initialize，
   * 白等满 30s 超时才失败。
   */
  get ready(): Promise<void> {
    if (this.readyReady) return Promise.resolve()
    if (!this.readyPromise) {
      this.readyPromise = new Promise<void>((resolve) => {
        this.readyResolve = resolve
      })
    }
    return this.readyPromise
  }

  private markReady(): void {
    if (this.readyReady) return
    this.readyReady = true
    const resolve = this.readyResolve
    this.readyResolve = null
    this.readyPromise = null
    resolve?.()
  }

  handleMessage(body: Uint8Array): void {
    try {
      const reader = new ValueReader(body)
      const header = reader.readValue()
      if (!Array.isArray(header) || header.length === 0 || typeof header[0] !== 'number') return
      const type = header[0]
      if (type === IPC_RES_INITIALIZE) {
        this.onLog?.('[ipc] initialized')
        this.markReady()
        return
      }
      if (header.length < 2 || typeof header[1] !== 'number') return
      const id = header[1]
      const data = reader.readValue()
      this.handlers.get(id)?.(type, data)
    } catch (e) {
      this.onLog?.(`[ipc] invalid frame: ${e}`)
    }
  }

  async call(
    channel: string,
    method: string,
    args: unknown[],
    timeoutMs = 30_000,
  ): Promise<unknown> {
    if (this.disposed) throw new Error('channel disposed')
    await this.waitForReady()
    const id = this.lastRequestId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.handlers.delete(id)
        this.pending.delete(id)
        reject(new Error(`${channel}.${method} timed out`))
      }, timeoutMs)
      const settle = (fn: () => void) => {
        clearTimeout(timer)
        fn()
      }
      this.handlers.set(id, (type, data) => {
        switch (type) {
          case IPC_RES_PROMISE_SUCCESS:
            settle(() => {
              this.handlers.delete(id)
              this.pending.delete(id)
              resolve(data)
            })
            break
          case IPC_RES_PROMISE_ERROR:
            settle(() => {
              this.handlers.delete(id)
              this.pending.delete(id)
              const message =
                data && typeof data === 'object' && 'message' in data
                  ? String((data as Record<string, unknown>)['message'])
                  : String(data)
              reject(new ChannelRpcError(message))
            })
            break
          case IPC_RES_PROMISE_ERROR_OBJ:
            settle(() => {
              this.handlers.delete(id)
              this.pending.delete(id)
              reject(new ChannelRpcError(String(data)))
            })
            break
        }
      })
      this.pending.set(id, { resolve, reject, timer })
      this.onLog?.(`[ipc] call ${channel}.${method} id=${id}`)
      this.send(IPC_REQ_PROMISE, id, channel, method, args)
    })
  }

  private waitForReady(): Promise<void> {
    if (this.readyReady) return Promise.resolve()
    // 计时器必须在胜出后清掉：留着既会让失败的 race 分支在 30s 后再抛一次
    // （未处理的 rejection），也会在浏览器里长期占住一个定时器句柄和闭包。
    let timer: ReturnType<typeof setTimeout> | undefined
    return Promise.race([
      this.ready,
      new Promise<never>(
        (_, reject) =>
          (timer = setTimeout(() => reject(new Error('channel init timeout')), 30_000)),
      ),
    ]).finally(() => clearTimeout(timer)) as Promise<void>
  }

  /** 订阅通道事件；返回取消函数。 */
  addEventListener(
    channel: string,
    event: string,
    onEvent: (data: unknown) => void,
    arg?: unknown,
  ): () => void {
    const id = this.lastRequestId++
    let sent = false
    let cancelled = false
    this.handlers.set(id, (type, data) => {
      if (type === IPC_RES_EVENT_FIRE) onEvent(data)
    })
    void this.ready.then(() => {
      // ready 可能比 dispose 晚到：桥已拆时 sendBody 会抛，而这里是条
      // 无人接管的浮动 promise，异常会变成页面上的 unhandled rejection。
      if (cancelled || this.disposed) return
      sent = true
      this.onLog?.(`[ipc] listen ${channel}.${event} id=${id}`)
      this.send(IPC_REQ_EVENT_LISTEN, id, channel, event, arg)
    })
    return () => {
      cancelled = true
      this.handlers.delete(id)
      if (sent && !this.disposed) this.send(IPC_REQ_EVENT_DISPOSE, id, channel, event, null)
    }
  }

  private send(reqType: number, id: number, channel: string, name: string, arg: unknown): void {
    const writer = new ValueWriter()
    writer.writeValue([reqType, id, channel, name])
    writer.writeValue(arg)
    this.sendBody(writer.take())
  }

  /** 桥栈切换时在途调用立刻报错（超时 timer 一并清掉，别占着句柄自然触发）。 */
  dispose(): void {
    this.disposed = true
    for (const p of this.pending.values()) {
      if (p.timer) clearTimeout(p.timer)
      p.reject(new Error('channel disposed'))
    }
    this.pending.clear()
    this.handlers.clear()
  }
}
