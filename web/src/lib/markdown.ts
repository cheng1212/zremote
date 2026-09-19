/// Markdown 渲染 —— 助手正文专用。
///
/// 三个刻意的选择：
///
/// 1. **`html:false`**：不注入原始 HTML，源文档里的 `<script>` / `<img onerror>`
///    只会变成字面文本。这与参考母本（`D:\WorkSpace\zcode-dev\web` 用
///    `react-markdown`，默认不接 raw HTML）是同一套安全模型——靠"默认不执行"，
///    不靠"记得消毒"。
/// 2. **危险协议是 markdown-it 自己拦的，不是我们拦的**（2026-09-19 实测 v15.0.2：
///    `[a](javascript:…)`、`data:`、`vbscript:`、实体写法的 `JaVaScRiPt&colon;`
///    全部退化成纯文本）。⚠️ **我们传给构造器的 `validateLink` 钩子从不被调用**——
///    探针里它 `return true` 全放行，`javascript:` 依然出不来 `<a>`，且钩子一次
///    都没收到调用。所以这里**不放自定义白名单**（放了也是死代码，还会给人
///    "安全由我们把关"的错觉）。`tests/markdown.test.ts` 的注入面用例因此
///    是**钉库的契约**：将来升级 markdown-it 若放宽了协议表，那几条会红。
/// 3. **流式节流 200ms，终态必全量**（照 `docs/fix-streaming-markdown-throttle.md`
///    的结论）：流式行每批文本必变，逐帧全量 parse 会把 UI 线程压死
///    （几千字回复尾部 ~20 次/秒）。节流后 ~5 次/秒，且 `streaming` 落下那一刻
///    绕过节流立即重排，不丢尾字。

import MarkdownIt from 'markdown-it'

/** 与母本一致的观感取向：软换行算换行、裸链接自动成链。 */
export const md = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
  langPrefix: 'lang-',
})

// 外链统一加 rel，避免 `window.opener` 反向操控。target 不设：
// 手机浏览器上交给系统处理更安全，也不依赖弹窗行为。
const defaultLinkOpen =
  md.renderer.rules.link_open ??
  ((tokens, idx, opts, _env, slf) => slf.renderToken(tokens, idx, opts))
md.renderer.rules.link_open = (tokens, idx, opts, env, slf) => {
  const href = String(tokens[idx].attrs?.find(([k]) => k === 'href')?.[1] ?? '')
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(href)) {
    tokens[idx].attrSet('rel', 'noopener noreferrer')
  }
  return defaultLinkOpen(tokens, idx, opts, env, slf)
}

/** 渲染一次（不做缓存）。 */
export function renderMarkdown(text: string): string {
  return md.render(text)
}

/** 终态缓存上限（按"条"计，够覆盖一屏历史；再老的自然淘汰）。 */
const FINAL_MAX = 200
/** 流式重排最小间隔（Flutter 端实测 200ms 肉眼无感、parse 降 4 倍）。 */
export const STREAM_THROTTLE_MS = 200

const finalCache = new Map<string, string>()
const streamState = new Map<string, { html: string; at: number }>()

/**
 * 行级渲染入口。
 *
 * @param rowId 行标识（节流态按它存，行结束即回收）
 * @param streaming 该行是否还在流式增长（`row.state === 'streaming'`）
 * @param now 可注入，供单测断言节流窗口
 */
export function markdownFor(
  rowId: string,
  text: string,
  streaming = false,
  now: number = Date.now(),
): string {
  if (!text) return ''

  if (!streaming) {
    const hit = finalCache.get(text)
    if (hit !== undefined) {
      // LRU：命中就挪到最新
      finalCache.delete(text)
      finalCache.set(text, hit)
      streamState.delete(rowId)
      return hit
    }
    const html = renderMarkdown(text)
    finalCache.set(text, html)
    if (finalCache.size > FINAL_MAX) {
      const oldest = finalCache.keys().next().value
      if (oldest !== undefined) finalCache.delete(oldest)
    }
    // 终态一定绕过节流结果，不丢尾字
    streamState.delete(rowId)
    return html
  }

  const prev = streamState.get(rowId)
  if (prev && now - prev.at < STREAM_THROTTLE_MS) return prev.html
  const html = renderMarkdown(text)
  streamState.set(rowId, { html, at: now })
  return html
}

/** 切会话 / 断开时清节流态（终态缓存留着——同一段文本跨会话复用无害）。 */
export function resetStreamingMarkdown(): void {
  streamState.clear()
}

/** 全清（测试与彻底断开用）。 */
export function resetMarkdownCaches(): void {
  streamState.clear()
  finalCache.clear()
}

/** 只给单测看内部规模。 */
export function markdownCacheSize(): { final: number; streaming: number } {
  return { final: finalCache.size, streaming: streamState.size }
}
