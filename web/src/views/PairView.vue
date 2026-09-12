<script setup lang="ts">
import { ref } from 'vue'
import { useAppStore } from '../stores/app'

const app = useAppStore()
const link = ref('')

async function connect() {
  if (!link.value.trim() || app.connecting) return
  try {
    await app.connect(link.value)
  } catch {
    /* failure 已在 store */
  }
}
</script>

<template>
  <div class="pair">
    <div class="hero">
      <div class="logo">☀</div>
      <h1>zremote</h1>
      <p class="sub">柑橘晨光 · ZCode 远程聊天（Web）</p>
    </div>

    <div class="card panel">
      <div class="label">远端链接</div>
      <input
        v-model="link"
        class="field"
        type="password"
        placeholder="https://zcode.z.ai/remote/v4?sid=…&hash=…"
        @keydown.enter="connect"
      />
      <button class="big-btn expand" :disabled="app.connecting" @click="connect">
        {{ app.connecting ? '连接中…' : '连接桌面端' }}
      </button>
    </div>

    <div v-if="app.failure" class="card-flat err">● 连接失败：{{ app.failure }}</div>

    <div v-if="app.logs.length" class="logs card-flat">
      <div v-for="(l, i) in app.logs.slice(-8)" :key="i">{{ l }}</div>
    </div>
  </div>
</template>

<style scoped>
.pair {
  max-width: 460px;
  margin: 0 auto;
  padding: 64px 20px 40px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.hero { text-align: center; }
.logo {
  width: 72px;
  height: 72px;
  margin: 0 auto 14px;
  display: grid;
  place-items: center;
  font-size: 34px;
  background: var(--primary);
  color: #fff;
  border: 2px solid var(--ink);
  border-radius: 20px;
  box-shadow: var(--shadow-hard);
}
h1 { margin: 0; font-size: 30px; font-weight: 900; letter-spacing: -0.5px; }
.sub { margin: 6px 0 0; color: var(--ink-soft); font-size: 13.5px; }
.panel { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
.label { font-size: 13px; font-weight: 800; color: var(--ink-soft); }
.expand { width: 100%; }
.err {
  color: var(--rose);
  border: 1.6px solid var(--rose);
  border-radius: var(--radius);
  padding: 10px 14px;
  font-size: 13px;
  font-weight: 700;
  background: rgba(229, 72, 77, 0.06);
}
.logs {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--ink-faint);
  padding: 10px 12px;
  border-radius: 10px;
  border: 1px solid var(--line);
  max-height: 160px;
  overflow: auto;
}
</style>
