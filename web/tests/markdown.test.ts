// Markdown 渲染的安全与节流回归锁。
//
// 内容来自**远端桌面**（半可信）：助手正文里的原始 HTML、`javascript:` 链接
// 都算注入面。`html:false` 关掉 raw HTML；危险协议由 markdown-it 内置表拦
// （实测 v15.0.2：自定义 `validateLink` 钩子从不被调用，所以**下面的注入面用例
// 钉的是库的契约**——将来升级若放宽协议表，这几条会红，而不是静默变不安全）。
import { beforeEach, describe, expect, it } from 'vitest'
import {
  STREAM_THROTTLE_MS,
  markdownCacheSize,
  markdownFor,
  renderMarkdown,
  resetMarkdownCaches,
  resetStreamingMarkdown,
} from '../src/lib/markdown'

beforeEach(() => resetMarkdownCaches())

describe('注入面', () => {
  it('原始 HTML 标签变成字面文本，不产生可执行节点', () => {
    const html = renderMarkdown('<script>alert(1)</script>')
    expect(html).not.toContain('<script')
    expect(html).toContain('&lt;script&gt;')
  })

  it('<img onerror=…> 这类属性注入不生效', () => {
    const html = renderMarkdown('<img src=x onerror=alert(1)>')
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img')
  })

  it('javascript: / data: / vbscript: 链接被降级成纯文本（文字仍在，点不动）', () => {
    for (const url of [
      'javascript:alert(1)',
      'JaVaScRiPt&colon;alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'vbscript:msgbox(1)',
    ]) {
      const html = renderMarkdown(`[点我](${url})`)
      expect(html).not.toContain('<a')
      expect(html).toContain('点我')
    }
  })

  it('http/https/mailto/相对/锚点 照常成链', () => {
    expect(renderMarkdown('[a](https://x.dev)')).toContain('<a href="https://x.dev"')
    expect(renderMarkdown('[a](http://x.dev)')).toContain('<a href="http://x.dev"')
    expect(renderMarkdown('[a](mailto:x@y.dev)')).toContain('mailto:x@y.dev')
    expect(renderMarkdown('[a](/docs/x)')).toContain('<a href="/docs/x"')
    expect(renderMarkdown('[a](#sec)')).toContain('<a href="#sec"')
  })

  it('外链补 rel="noopener noreferrer"，防 window.opener 反向操控', () => {
    expect(renderMarkdown('[a](https://x.dev)')).toContain('rel="noopener noreferrer"')
  })
})

describe('常见语法', () => {
  it('代码块带语言 class，内容里的尖括号被转义', () => {
    const html = renderMarkdown('```ts\nconst a = 1 < 2\n```')
    expect(html).toContain('class="lang-ts"')
    expect(html).toContain('1 &lt; 2')
  })

  it('GFM：表格与删除线', () => {
    expect(renderMarkdown('| a |\n|---|\n| 1 |')).toContain('<table>')
    expect(renderMarkdown('~~x~~')).toContain('<s>x</s>')
  })

  it('软换行按 <br> 处理（聊天里换行是有意义的）', () => {
    expect(renderMarkdown('一\n二')).toContain('<br')
  })

  it('裸链接自动成链', () => {
    expect(renderMarkdown('看下 https://x.dev 吧')).toContain('<a href="https://x.dev"')
  })

  it('空串直接返回空，不进缓存', () => {
    expect(markdownFor('r0', '', false)).toBe('')
    expect(markdownCacheSize().final).toBe(0)
  })
})

describe('缓存与流式节流', () => {
  it('终态同文本命中缓存（不重复 parse）', () => {
    const a = markdownFor('r1', '# 标题\n\n正文', false)
    const before = markdownCacheSize().final
    const b = markdownFor('r2', '# 标题\n\n正文', false)
    expect(b).toBe(a)
    expect(markdownCacheSize().final).toBe(before)
  })

  it('流式窗口内沿用上一次结果，不重排', () => {
    const t0 = 1_000_000
    const first = markdownFor('r3', '第一段', true, t0)
    expect(first).toContain('第一段')
    const second = markdownFor('r3', '第一段 第二段', true, t0 + 40)
    expect(second).toBe(first) // 40ms < 200ms：沿用旧结果
  })

  it('超过节流窗口才真重排', () => {
    const t0 = 1_000_000
    markdownFor('r4', 'A', true, t0)
    const later = markdownFor('r4', 'B', true, t0 + STREAM_THROTTLE_MS)
    expect(later).toContain('B')
  })

  it('流式结束那一刻绕过节流，终态不丢尾字', () => {
    const t0 = 1_000_000
    markdownFor('r5', '前半', true, t0)
    // 同一毫秒内 streaming=false：仍必须拿到完整终态
    const final = markdownFor('r5', '前半 + 尾巴', false, t0)
    expect(final).toContain('尾巴')
    // 节流态随行结束回收，不会攒着不放
    expect(markdownCacheSize().streaming).toBe(0)
  })

  it('切会话清节流态，终态缓存可留', () => {
    markdownFor('r6', 'X', true, 1_000_000)
    markdownFor('r7', 'Y', false, 1_000_000)
    resetStreamingMarkdown()
    const size = markdownCacheSize()
    expect(size.streaming).toBe(0)
    expect(size.final).toBeGreaterThan(0)
  })
})
