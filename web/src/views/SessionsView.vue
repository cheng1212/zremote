<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useAppStore } from '../stores/app'
import type { Workspace } from '../protocol/remoteSession'

const app = useAppStore()
const showSwitcher = ref(false)

const title = computed(() => (app.workspace ? app.workspaceTitle : '选择项目'))

function workspaceName(w: Workspace): string {
  return String(
    (w['label'] as string | undefined) ??
      String(w['workspacePath'] ?? '').split(/[\\/]/).filter(Boolean).pop() ??
      '',
  )
}

async function pick(w: Workspace) {
  showSwitcher.value = false
  try {
    await app.openWorkspace(w)
  } catch (e) {
    app.log(`[ws] 打开工作区失败: ${e}`)
  }
}

onMounted(() => {
  // 已连上但没有工作区被选（多项目），会话列表只做展示与切换入口
})
</script>

<template>
  <div class="wrap">
    <header class="topbar">
      <button class="ws-btn" @click="showSwitcher = !showSwitcher">
        <strong>{{ title }}</strong>
        <span class="chev">▾</span>
      </button>
      <span class="chip" :class="app.relayState">
        {{ app.relayState === 'paired' ? '已连接' : app.relayState }}
      </span>
    </header>

    <div v-if="showSwitcher" class="card switcher">
      <div
        v-for="w in app.workspaces"
        :key="String(w['workspaceKey'] ?? w['workspacePath'])"
        class="ws-item"
        @click="pick(w)"
      >
        {{ workspaceName(w) }}
      </div>
      <div v-if="app.workspaces.length === 0" class="empty">还没有工作区</div>
    </div>

    <main class="body">
      <div v-if="!app.workspace" class="hint">
        <div class="card tip">从顶部选择一个项目开始</div>
      </div>
      <div v-else class="hint">
        <div class="card tip">
          <strong>{{ workspaceName(app.workspace) }}</strong>
          <p>Web 端首期对齐：会话订阅/发送/流式渲染。会话列表数据（sessions-index 网格）接入中——先用桌面端或手机端打开某条会话，把会话 ID 粘贴到下方快速进入。</p>
          <input
            v-model.trim="sessionIdInput"
            class="field"
            placeholder="会话 ID（sess_…）"
            @keydown.enter="open"
          />
          <button class="big-btn" :disabled="!sessionIdInput" @click="open">打开会话</button>
        </div>
      </div>
    </main>
  </div>
</template>

<script lang="ts">
export default {
  data() {
    return { sessionIdInput: '' }
  },
  methods: {
    async open() {
      const sid = (this as unknown as { sessionIdInput: string }).sessionIdInput
      if (sid) await (this as unknown as { $store: never }).$store
      await useAppStore().openSession(sid)
    },
  },
}
</script>

<style scoped>
.wrap { max-width: 720px; margin: 0 auto; padding: 18px 16px; }
.topbar { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
.ws-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font: inherit;
  font-size: 17px;
  color: var(--ink);
  background: none;
  border: none;
  cursor: pointer;
  padding: 8px 10px;
  border-radius: 10px;
}
.ws-btn:hover { background: var(--surface); }
.chev { font-size: 12px; color: var(--ink-soft); }
.switcher { position: absolute; z-index: 10; margin-top: 6px; overflow: hidden; min-width: 240px; }
.ws-item { padding: 11px 16px; font-weight: 700; cursor: pointer; border-bottom: 1px solid var(--line); }
.ws-item:hover { background: rgba(255, 201, 60, 0.18); }
.empty { padding: 14px; color: var(--ink-faint); font-size: 13px; }
.body { margin-top: 10px; }
.hint { display: flex; justify-content: center; padding-top: 48px; }
.tip { padding: 20px; max-width: 460px; display: flex; flex-direction: column; gap: 12px; }
.tip p { margin: 0; font-size: 13px; color: var(--ink-soft); line-height: 1.6; }
</style>
