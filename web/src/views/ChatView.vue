<script setup lang="ts">
/// 聊天页 —— 聊天记录渲染 + 发送 + 停止 + 滚动稳定性。
///
/// 滚动策略（移植自 `lib/ui/composer_logic.dart`，参考实现同源）：
///   · **双阈值滞回**（enter 100 / exit 180）：流式期间内容每 tick 长高，
///     单阈值会让贴底判定在临界带反复横跳。
///   · **FollowLock 意图锁存**：位置判定挡不住「内容自己长高把你推离底部」，
///     必须锁存「用户在看历史」这个意图；锁存期间内容再长也不拽人，
///     错过的新行计入未读徽标。
///   · **初始钉底用「稳定才停」**：markdown / 图片异步渲染完才撑高，
///     固定时间点补滚一次会在窗口之后才长完，视口又被顶离底部。
///
/// 这些阈值与判定在 `lib/scroll.ts` 里是纯函数，有单测锁。

import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useAppStore } from '../stores/app'
import {
  FollowLock,
  bottomGap,
  compensatedScrollTop,
  maxScroll,
  resolveAtBottom,
  shouldKeepPinning,
} from '../lib/scroll'
import { isProducingPhase } from '../lib/phase'
import AskPanel from '../components/AskPanel.vue'
import type { ConvRow } from '../lib/convRows'

const app = useAppStore()

const input = ref('')
const sending = ref(false)
const listRef = ref<HTMLElement | null>(null)

const atBottom = ref(true)
const followLock = new FollowLock()
const unread = ref(0)
const showJump = ref(false)

const expanded = ref<Record<number, boolean>>({})

const rows = computed<ConvRow[]>(() => app.rows)
const phase = computed(() => app.phase)
const running = computed(() => isProducingPhase(phase.value))
const title = computed(() => app.chatMeta?.title ?? '')

let pinRaf = 0
let pinFallback: ReturnType<typeof setTimeout> | null = null
let pinning = false
let prevRowsLen = 0
let prevHeight = 0

function el(): HTMLElement | null {
  return listRef.value
}

function scrollToEnd(): void {
  const e = el()
  if (!e) return
  e.scrollTop = e.scrollHeight
}

function onScroll(): void {
  const e = el()
  if (!e) return
  const gap = bottomGap(e)
  const max = maxScroll(e)
  atBottom.value = resolveAtBottom(atBottom.value, gap, max)
  const unlocked = followLock.update(gap, max)
  if (unlocked) unread.value = 0
  showJump.value = !atBottom.value || (followLock.isLocked && unread.value > 0)

  // 滚到顶自动加载更早（前插后按高度差补偿，视口锚在原内容上不跳）
  if (e.scrollTop < 100 && app.canLoadOlder) {
    followLock.lock()
    prevHeight = e.scrollHeight
    void app.loadOlder()
  }
}

/** 用户主动上滑：立刻上锁，不等滚动事件（触屏与滚轮都要）。 */
function onWheel(e: WheelEvent): void {
  if (e.deltaY < 0) followLock.lock()
}
let touchStartY = 0
function onTouchStart(e: TouchEvent): void {
  touchStartY = e.touches[0]?.clientY ?? 0
}
function onTouchMove(e: TouchEvent): void {
  const y = e.touches[0]?.clientY ?? 0
  // 手指往下拖 = 内容往上走 = 在看历史
  if (y - touchStartY > 6) followLock.lock()
}

/** 初始钉底：逐帧补滚，直到高度连续 3 帧不再增长（60 帧封顶防死循环）。 */
function pinToBottom(): void {
  const e = el()
  if (!e) return
  pinning = true
  let frame = 0
  let lastHeight = 0
  let stable = 0
  const tick = () => {
    const box = el()
    if (!pinning || !box) return
    box.scrollTop = box.scrollHeight
    if (box.scrollHeight === lastHeight) stable += 1
    else {
      stable = 0
      lastHeight = box.scrollHeight
    }
    frame += 1
    if (shouldKeepPinning(stable, frame)) {
      pinRaf = requestAnimationFrame(tick)
    } else {
      pinning = false
    }
  }
  pinRaf = requestAnimationFrame(tick)
  // 兜底：无头/测试环境不驱动 rAF，至少补滚一次
  pinFallback = setTimeout(() => {
    if (pinning) {
      pinning = false
      scrollToEnd()
    }
  }, 400)
}

function jumpToLatest(): void {
  pinning = false
  atBottom.value = true
  followLock.release()
  unread.value = 0
  showJump.value = false
  scrollToEnd()
}

function back(): void {
  app.closeSession()
}

// ── 会话切换 / 首次拿到历史：重置并钉底 ──
watch(
  () => [app.chatMeta?.sessionId, rows.value.length > 0] as const,
  async ([sid, hasRows]) => {
    if (!sid || !hasRows) return
    await nextTick()
    atBottom.value = true
    followLock.release()
    unread.value = 0
    showJump.value = false
    prevRowsLen = rows.value.length
    pinToBottom()
  },
  { immediate: true },
)

// ── 新行 / 流式增长：跟随闸门 = 贴底 && 未锁存 ──
watch(
  () => rows.value.length,
  (len) => {
    if (pinning) {
      prevRowsLen = len
      return
    }
    const grew = len > prevRowsLen
    if (followLock.isLocked) {
      if (grew) {
        unread.value += len - prevRowsLen
        showJump.value = true
      }
    } else if (atBottom.value) {
      void nextTick(() => scrollToEnd())
    }
    prevRowsLen = len
  },
)

// ── 翻页完成：按高度差补偿，视口锚在原内容上 ──
watch(
  () => app.loadingOlder,
  async (loading, was) => {
    if (loading) {
      const e = el()
      if (e) prevHeight = e.scrollHeight
      return
    }
    if (was && prevHeight) {
      await nextTick()
      const e = el()
      if (e) e.scrollTop = compensatedScrollTop(e.scrollTop, e.scrollHeight - prevHeight)
      prevHeight = 0
    }
  },
)

onMounted(() => {
  prevRowsLen = rows.value.length
})

onBeforeUnmount(() => {
  pinning = false
  if (pinRaf) cancelAnimationFrame(pinRaf)
  if (pinFallback) clearTimeout(pinFallback)
})

async function send(): Promise<void> {
  const text = input.value.trim()
  if (!text || sending.value) return
  sending.value = true
  try {
    await app.sendText(text)
    input.value = ''
    // 自己发的消息：无条件回到最新（用户刚发完就想看结果）
    followLock.release()
    atBottom.value = true
    unread.value = 0
    showJump.value = false
    await nextTick()
    scrollToEnd()
  } catch {
    // 失败时不清空输入——用户的话不能丢；原因由 app.sendError 展示
  } finally {
    sending.value = false
  }
}

function onKeydown(e: KeyboardEvent): void {
  // 移动端软键盘的 Enter 是换行意图，只有 Ctrl/Cmd+Enter 才发。
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault()
    void send()
  }
}

function kindOf(r: ConvRow): string {
  return String(r['kind'] ?? '')
}
function textOf(r: ConvRow): string {
  return String(r['text'] ?? '')
}
function stateOf(r: ConvRow): string {
  return String(r['state'] ?? '')
}
function toolNameOf(r: ConvRow): string {
  return String(r['toolName'] ?? r['name'] ?? 'tool')
}
function outputTextOf(r: ConvRow): string {
  const out = r['output']
  if (out && typeof out === 'object') {
    const t = (out as Record<string, unknown>)['text']
    if (typeof t === 'string') return t
  }
  return ''
}
function rowKey(r: ConvRow, i: number): string {
  return `${String(r['rowId'] ?? i)}-${kindOf(r)}`
}
function toggle(r: ConvRow, i: number): void {
  const k = Number(r['rowId'] ?? i)
  expanded.value = { ...expanded.value, [k]: !expanded.value[k] }
}
function isExpanded(r: ConvRow, i: number): boolean {
  return expanded.value[Number(r['rowId'] ?? i)] === true
}
</script>

<template>
  <div class="chat">
    <header class="topbar">
      <button class="back" type="button" aria-label="返回列表" @click="back">‹</button>
      <strong class="title">{{ title }}</strong>
      <span v-if="phase" class="chip" :class="phase">{{ phase }}</span>
    </header>

    <main
      ref="listRef"
      class="list"
      @scroll.passive="onScroll"
      @wheel="onWheel"
      @touchstart.passive="onTouchStart"
      @touchmove.passive="onTouchMove"
    >
      <div class="inner">
        <!-- 加载更早：翻页触发点，也是手动入口 -->
        <button
          v-if="app.canLoadOlder || app.loadingOlder"
          class="load-older"
          type="button"
          :disabled="app.loadingOlder"
          @click="followLock.lock(); prevHeight = el()?.scrollHeight ?? 0; void app.loadOlder()"
        >
          {{ app.loadingOlder ? '加载中…' : '↑ 加载更早的消息' }}
        </button>
        <div v-else-if="rows.length > 0" class="list-start">— 会话开头 —</div>

        <div v-if="rows.length === 0" class="empty">
          {{ app.chatLoading ? '正在加载聊天记录…' : '还没有消息，发一条开始吧' }}
        </div>

        <template v-for="(r, i) in rows" :key="rowKey(r, i)">
          <!-- 用户消息 -->
          <div v-if="kindOf(r) === 'userInput'" class="line line--user">
            <div class="bubble-user">{{ textOf(r) }}</div>
          </div>

          <!-- 助手正文 -->
          <div v-else-if="kindOf(r) === 'assistantText'" class="line">
            <div class="assistant">
              <span v-if="stateOf(r) === 'streaming'" class="stream-tag">正在回复</span>
              <div class="md body">{{ textOf(r) }}<span
                v-if="stateOf(r) === 'streaming'"
                class="caret"
              >▌</span></div>
            </div>
          </div>

          <!-- 思考过程：默认折叠，别喧宾夺主 -->
          <div v-else-if="kindOf(r) === 'reasoning'" class="line">
            <button class="reasoning" type="button" @click="toggle(r, i)">
              <span class="reasoning__label">思考过程</span>
              <span class="reasoning__hint">{{ isExpanded(r, i) ? '收起' : '展开' }}</span>
            </button>
            <div v-if="isExpanded(r, i)" class="md body reasoning__body">{{ textOf(r) }}</div>
          </div>

          <!-- 工具调用 -->
          <div v-else-if="kindOf(r) === 'toolCall'" class="line">
            <div class="tool">
              <button class="tool__head" type="button" @click="toggle(r, i)">
                <span class="chip" :class="stateOf(r)">{{ stateOf(r) || 'tool' }}</span>
                <code class="tool__name">{{ toolNameOf(r) }}</code>
                <span class="tool__chev">{{ isExpanded(r, i) ? '▾' : '▸' }}</span>
              </button>
              <div v-if="isExpanded(r, i)" class="tool__body">
                <pre v-if="String(r['inputText'] ?? '')" class="tool__pre">{{ r['inputText'] }}</pre>
                <pre v-if="outputTextOf(r)" class="tool__pre">{{ outputTextOf(r) }}</pre>
                <div v-if="!String(r['inputText'] ?? '') && !outputTextOf(r)" class="tool__empty">
                  这一项还没有可展开的内容
                </div>
              </div>
            </div>
          </div>

          <!-- 子代理 -->
          <div v-else-if="kindOf(r) === 'subagent'" class="line">
            <div class="card subagent">
              <div class="subagent__title">子代理 · {{ String(r['agentName'] ?? r['name'] ?? '') }}</div>
              <div v-if="String(r['summaryText'] ?? '')" class="md subagent__body">{{ r['summaryText'] }}</div>
            </div>
          </div>

          <!-- 轮次头 / 时间线标记：细分隔 -->
          <div v-else-if="kindOf(r) === 'turnHeader' || kindOf(r) === 'timelineMarker'" class="line">
            <div class="marker">{{ textOf(r) || String(r['label'] ?? '') }}</div>
          </div>

          <!-- 未知行类型：显式占位，不静默吞掉（否则用户以为丢了消息） -->
          <div v-else class="line">
            <div class="unknown">未支持的行类型：{{ kindOf(r) || '?' }}</div>
          </div>
        </template>
      </div>
    </main>

    <button v-if="showJump" class="jump" type="button" @click="jumpToLatest">
      ↓ 最新{{ unread > 0 ? ` · ${unread}` : '' }}
    </button>

    <div v-if="app.chatError" class="strip strip--error">{{ app.chatError }}</div>
    <div v-if="app.sendError" class="strip strip--error">{{ app.sendError }}</div>

    <!-- 询问 / 审批：非空时服务端在等回答，不回传会话就卡死 -->
    <div v-if="app.pendingInteractions.length > 0" class="ask-host">
      <AskPanel />
    </div>

    <footer class="composer">
      <textarea
        v-model="input"
        class="composer__input"
        rows="1"
        placeholder="给 ZCode 发消息…"
        aria-label="消息输入"
        @keydown="onKeydown"
      />
      <button
        v-if="running"
        class="btn-stop"
        type="button"
        aria-label="停止输出"
        @click="app.stop()"
      >
        ■ 停止
      </button>
      <button
        v-else
        class="big-btn"
        type="button"
        aria-label="发送"
        :disabled="!input.trim() || sending"
        @click="send"
      >
        发送
      </button>
    </footer>
  </div>
</template>

<style scoped>
.chat {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  position: relative;
}
.topbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  border-bottom: 1px solid var(--line);
  background: var(--bg);
}
.back {
  flex: none;
  width: 36px;
  height: 36px;
  font-size: 24px;
  line-height: 1;
  color: var(--ink);
  background: none;
  border: none;
  cursor: pointer;
  border-radius: 10px;
}
.back:active {
  background: var(--surface);
}
.title {
  flex: 1;
  min-width: 0;
  font-size: 15px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  overflow-anchor: none;
  -webkit-overflow-scrolling: touch;
  padding: 12px 14px 16px;
}
.inner {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 760px;
  margin: 0 auto;
}
.load-older {
  align-self: center;
  font: inherit;
  font-size: 12.5px;
  font-weight: 700;
  color: var(--primary-deep);
  background: var(--surface);
  border: 1.4px solid var(--primary);
  border-radius: 999px;
  padding: 7px 14px;
  cursor: pointer;
}
.load-older:disabled {
  color: var(--ink-faint);
  border-color: var(--ink-faint);
  cursor: default;
}
.list-start {
  align-self: center;
  font-size: 11px;
  color: var(--ink-faint);
}
.empty {
  align-self: center;
  padding: 40px 0;
  font-size: 13px;
  color: var(--ink-faint);
}
.line {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.line--user {
  align-items: flex-end;
}
.bubble-user {
  max-width: 82%;
  background: var(--ink);
  color: var(--on-ink);
  padding: 9px 13px;
  border: 1.6px solid var(--ink);
  border-radius: 14px 4px 14px 14px;
  font-size: 14px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-word;
}
.assistant {
  max-width: 100%;
}
.stream-tag {
  display: inline-block;
  font-size: 10.5px;
  font-weight: 800;
  color: var(--primary-deep);
  letter-spacing: 0.4px;
  margin-bottom: 3px;
}
.md.body {
  white-space: pre-wrap;
  word-break: break-word;
}
.caret {
  animation: blink 1s steps(1) infinite;
  color: var(--primary);
}
@keyframes blink {
  50% {
    opacity: 0;
  }
}
.reasoning {
  align-self: flex-start;
  display: inline-flex;
  gap: 8px;
  align-items: center;
  font: inherit;
  font-size: 12px;
  color: var(--ink-faint);
  background: none;
  border: none;
  padding: 2px 0;
  cursor: pointer;
}
.reasoning__label {
  font-weight: 800;
}
.reasoning__body {
  margin-top: 4px;
  padding-left: 10px;
  border-left: 2px solid var(--line);
  font-size: 12.5px;
  color: var(--ink-soft);
}
.tool {
  border: 1.4px solid var(--line);
  border-radius: 10px;
  background: var(--surface);
  overflow: hidden;
}
.tool__head {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  font: inherit;
  padding: 7px 10px;
  background: none;
  border: none;
  cursor: pointer;
  text-align: left;
}
.tool__name {
  flex: 1;
  min-width: 0;
  font-family: var(--mono);
  font-size: 12px;
  color: var(--ink-soft);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tool__chev {
  flex: none;
  font-size: 11px;
  color: var(--ink-faint);
}
.tool__body {
  border-top: 1px solid var(--line);
  padding: 8px 10px;
}
.tool__pre {
  margin: 0 0 6px;
  padding: 8px 10px;
  background: var(--bg);
  border-radius: 8px;
  font-family: var(--mono);
  font-size: 12px;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 240px;
  overflow: auto;
}
.tool__pre:last-child {
  margin-bottom: 0;
}
.tool__empty {
  font-size: 12px;
  color: var(--ink-faint);
}
.subagent {
  padding: 10px 12px;
}
.subagent__title {
  font-size: 12.5px;
  font-weight: 800;
  color: var(--grape);
  margin-bottom: 5px;
}
.subagent__body {
  font-size: 13px;
  color: var(--ink-soft);
}
.marker {
  align-self: center;
  font-size: 11px;
  color: var(--ink-faint);
  letter-spacing: 0.3px;
}
.unknown {
  font-size: 11.5px;
  color: var(--ink-faint);
  font-style: italic;
}
.jump {
  position: absolute;
  right: 16px;
  bottom: 96px;
  font: inherit;
  font-size: 12.5px;
  font-weight: 800;
  color: var(--ink);
  background: var(--lemon);
  border: 1.6px solid var(--ink);
  border-radius: 999px;
  padding: 8px 14px;
  box-shadow: var(--shadow-hard-sm);
  cursor: pointer;
  z-index: 3;
}
.strip {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12.5px;
  font-weight: 700;
  padding: 9px 12px;
  border-top: 1.4px solid;
}
.strip--error {
  color: var(--rose);
  border-color: var(--rose);
  background: rgba(229, 72, 77, 0.1);
}
.ask-host {
  padding: 10px 12px 0;
  background: var(--bg);
}
.composer {
  display: flex;
  align-items: flex-end;
  gap: 8px;
  padding: 10px 12px 12px;
  border-top: 1px solid var(--line);
  background: var(--bg);
}
.composer__input {
  flex: 1;
  min-width: 0;
  resize: none;
  max-height: 140px;
  padding: 11px 13px;
  font: inherit;
  font-size: 14px;
  line-height: 1.45;
  color: var(--ink);
  background: var(--surface);
  border: 1.6px solid var(--ink);
  border-radius: var(--radius);
  outline: none;
}
.composer__input:focus {
  border-color: var(--primary);
  box-shadow: 0 0 0 3px rgba(255, 107, 26, 0.18);
}
.btn-stop {
  flex: none;
  min-width: 88px;
  padding: 11px 16px;
  font: inherit;
  font-size: 14px;
  font-weight: 800;
  color: #fff;
  background: var(--rose);
  border: 1.8px solid var(--ink);
  border-radius: var(--radius);
  box-shadow: var(--shadow-hard);
  cursor: pointer;
}
.btn-stop:active {
  transform: translate(2.5px, 2.5px);
  box-shadow: none;
}
</style>
