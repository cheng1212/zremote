<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useAppStore } from '../stores/app'

const app = useAppStore()
const input = ref('')
const listEl = ref<HTMLElement | null>(null)
const sending = ref(false)

const rows = computed(() => app.chat?.rows ?? [])
const reverseRows = computed(() => [...rows.value].reverse())
const atBottom = ref(true)

watch(
  () => rows.value.length,
  async () => {
    if (atBottom.value) {
      await nextTick()
      listEl.value?.scrollTo({ top: listEl.value.scrollHeight })
    }
  },
)

function onScroll() {
  const el = listEl.value
  if (!el) return
  atBottom.value = el.scrollHeight - el.scrollTop - el.clientHeight < 80
}

function phaseOf(row: Record<string, unknown>): string {
  return String(row['state'] ?? '')
}

async function send() {
  const text = input.value.trim()
  if (!text || sending.value) return
  sending.value = true
  input.value = ''
  try {
    await app.sendText(text)
  } finally {
    sending.value = false
  }
}

async function stop() {
  const sid = app.chat?.sessionId
  if (sid && app.conv) await app.conv.stop(sid)
}

function back() {
  app.chat = null
}
</script>

<template>
  <div class="wrap">
    <header class="topbar">
      <button class="back" @click="back">←</button>
      <strong class="title">{{ app.chat?.sessionId.slice(0, 18) }}</strong>
      <span v-if="app.relayState !== 'paired'" class="chip">{{ app.relayState }}</span>
    </header>

    <main ref="listEl" class="list" @scroll="onScroll">
      <div v-for="r in reverseRows" :key="String(r.rowId)" class="row" :class="String(r.kind)">
        <!-- 用户消息：右对齐墨色气泡（微信式） -->
        <div v-if="r.kind === 'userInput'" class="bubble-user">
          <div class="md">{{ r.text }}</div>
        </div>
        <!-- 助手消息：md 渲染 + 流式光标 -->
        <div v-else-if="r.kind === 'assistantText'" class="bubble-assistant">
          <div v-if="r.state === 'streaming'" class="streaming-tag">正在回复</div>
          <div class="md">{{ r.text }}<span v-if="r.state === 'streaming'" class="caret">▌</span></div>
        </div>
        <!-- 工具调用：紧凑活动行 -->
        <div v-else-if="r.kind === 'toolCall'" class="tool-row">
          <span class="chip" :class="phaseOf(r)">{{ phaseOf(r) || 'tool' }}</span>
          <code class="tool-name">{{ String(r['toolName'] ?? '') }}</code>
        </div>
        <!-- 其余行类型：极简一行标记 -->
        <div v-else class="row-kind">· {{ r.kind ?? '?' }} ·</div>
      </div>
    </main>

    <footer class="composer">
      <input
        v-model="input"
        class="field"
        placeholder="给 ZCode 发送消息…"
        @keydown.enter="send"
      />
      <button class="big-btn" :disabled="!input.trim() || sending" @click="send">发送</button>
      <button v-if="app.chat?.rows.some((r) => r.state === 'streaming')" class="stop" @click="stop">■</button>
    </footer>
  </div>
</template>

<style scoped>
.wrap { flex: 1; display: flex; flex-direction: column; min-height: 100vh; }
.topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 14px;
  border-bottom: 1px solid var(--line);
}
.back {
  border: none;
  background: none;
  font-size: 20px;
  cursor: pointer;
  color: var(--ink);
  padding: 4px 8px;
}
.title { flex: 1; font-size: 15px; }
.list { flex: 1; overflow-y: auto; padding: 14px 16px; display: flex; flex-direction: column; gap: 12px; }
.row { display: flex; flex-direction: column; }
.row.userInput { align-items: flex-end; }
.bubble-user {
  max-width: 82%;
  background: var(--ink);
  color: var(--on-ink);
  padding: 9px 13px;
  border: 1.6px solid var(--ink);
  border-radius: 14px 4px 14px 14px;
  box-shadow: var(--shadow-hard-sm);
}
.bubble-assistant { max-width: 94%; padding-right: 10px; }
.streaming-tag {
  font-size: 10.5px;
  font-weight: 800;
  color: var(--primary-deep);
  letter-spacing: 0.5px;
  margin-bottom: 3px;
}
.caret { animation: blink 1s steps(1) infinite; color: var(--primary); }
@keyframes blink { 50% { opacity: 0; } }
.tool-row { display: flex; align-items: center; gap: 8px; }
.tool-name { font-family: var(--mono); font-size: 12px; color: var(--ink-soft); }
.row-kind { font-size: 10px; color: var(--ink-faint); }
.composer {
  display: flex;
  gap: 8px;
  padding: 10px 14px 14px;
  border-top: 1px solid var(--line);
  background: var(--bg);
}
.stop {
  width: 46px;
  border: 1.8px solid var(--ink);
  border-radius: var(--radius);
  background: var(--rose);
  color: #fff;
  cursor: pointer;
}
</style>
