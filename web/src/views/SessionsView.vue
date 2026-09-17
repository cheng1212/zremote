<script setup lang="ts">
/// 会话列表 —— 加载 / 刷新 / 搜索 / 进入会话。
///
/// 数据来源两条腿（缺一不可）：
///   `listTasks` + `listPinnedTasks` → 权威骨架（标题、归档态、置顶态）
///   `sessions-index` 实时帧        → phase / 活跃时间（列表不刷新也能看到「运行中」）
/// 两者在 store 里合并、排序（置顶组在前，组内按活跃时间倒序——BUG-24）。

import { computed, onMounted, ref } from 'vue'
import { useAppStore } from '../stores/app'
import { phaseLabel } from '../lib/phase'
import { timeLabel } from '../lib/sessions'
import type { Workspace } from '../protocol/remoteSession'

const app = useAppStore()
const showSwitcher = ref(false)

const title = computed(() => (app.workspace ? app.workspaceTitle : '选择项目'))

function workspaceName(w: Workspace): string {
  return String(
    (w['label'] as string | undefined) ??
      String(w['workspacePath'] ?? '')
        .split(/[\\/]/)
        .filter(Boolean)
        .pop() ??
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

async function openSession(sessionId: string, t: string) {
  try {
    await app.openSession(sessionId, t)
  } catch (e) {
    app.log(`[chat] 打开会话失败: ${e}`)
  }
}

function onRefresh() {
  void app.refreshSessions()
}

onMounted(() => {
  // 已连上但还没有列表（例如刷新页面后重连）：补一次加载。
  if (app.workspace && app.allSessions.length === 0 && !app.sessionsLoading) {
    void app.loadSessions()
  }
})
</script>

<template>
  <div class="sessions">
    <header class="topbar">
      <button class="ws-btn" type="button" @click="showSwitcher = !showSwitcher">
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
      <div v-if="app.workspaces.length === 0" class="ws-empty">还没有工作区</div>
    </div>

    <!-- 未连接 / 陈旧：诚实提示，别假装新鲜 -->
    <button
      v-if="app.relayState !== 'paired'"
      type="button"
      class="strip strip--warn"
      @click="onRefresh"
    >
      <span class="dot" /> 未连接（{{ app.relayState }}）—— 点此重试
    </button>
    <button
      v-else-if="app.sessionsStale"
      type="button"
      class="strip strip--warn"
      @click="onRefresh"
    >
      <span class="dot" /> 同步中，内容可能滞后 —— 点此重拉
    </button>

    <div v-if="!app.workspace" class="hint">
      <div class="card tip">从顶部选择一个项目开始</div>
    </div>

    <template v-else>
      <div class="tools">
        <input
          class="field search"
          :value="app.sessionsQuery"
          placeholder="搜索会话标题…"
          aria-label="搜索会话"
          @input="app.setSessionsQuery(($event.target as HTMLInputElement).value)"
        />
        <button class="refresh" type="button" :disabled="app.sessionsLoading" @click="onRefresh">
          {{ app.sessionsLoading ? '…' : '刷新' }}
        </button>
      </div>

      <div v-if="app.sessionsError" class="strip strip--error">{{ app.sessionsError }}</div>

      <main class="body">
        <!-- 加载中（首次，还没有任何数据） -->
        <div v-if="app.sessionsLoading && app.sessionsTotal === 0" class="hint">
          <div class="card tip">正在加载会话…</div>
        </div>

        <!-- 真的一条都没有 -->
        <div v-else-if="app.sessionsTotal === 0" class="hint">
          <div class="card tip">
            <strong>这个项目还没有会话</strong>
            <p>去桌面端或手机端开一个会话，这里会自动出现。</p>
          </div>
        </div>

        <!-- 有会话但搜索无结果 -->
        <div v-else-if="app.sessions.length === 0" class="hint">
          <div class="card tip">没有匹配「{{ app.sessionsQuery }}」的会话。</div>
        </div>

        <ul v-else class="list">
          <li
            v-for="s in app.sessions"
            :key="s.sessionId"
            class="card row"
            @click="openSession(s.sessionId, s.title)"
          >
            <div class="row-main">
              <div class="row-title">
                <span v-if="s.pinned" class="pin">◆</span>
                <span class="t">{{ s.title }}</span>
              </div>
              <div class="row-meta">
                <span v-if="s.phase" class="chip" :class="s.phase">{{ phaseLabel(s.phase) }}</span>
                <span v-if="s.hasPendingInteraction" class="chip waiting">待回答</span>
                <span class="time">{{ timeLabel(s.lastActivityAt) }}</span>
              </div>
              <div v-if="s.preview" class="row-preview">{{ s.preview }}</div>
            </div>
            <span class="row-arrow">›</span>
          </li>
        </ul>
      </main>
    </template>
  </div>
</template>

<style scoped>
.sessions {
  flex: 1;
  display: flex;
  flex-direction: column;
  width: 100%;
  max-width: 720px;
  margin: 0 auto;
  padding: 14px 14px 20px;
  min-height: 0;
}
.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 10px;
}
.ws-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font: inherit;
  font-size: 17px;
  font-weight: 800;
  color: var(--ink);
  background: none;
  border: none;
  cursor: pointer;
  padding: 6px 8px;
  border-radius: 10px;
}
.chev {
  font-size: 12px;
  color: var(--ink-soft);
}
.switcher {
  position: relative;
  z-index: 5;
  margin-bottom: 10px;
  overflow: hidden;
}
.ws-item {
  padding: 12px 16px;
  font-weight: 700;
  cursor: pointer;
  border-bottom: 1px solid var(--line);
}
.ws-item:last-child {
  border-bottom: none;
}
.ws-empty {
  padding: 14px;
  color: var(--ink-faint);
  font-size: 13px;
}
.strip {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  text-align: left;
  font: inherit;
  font-size: 12.5px;
  font-weight: 700;
  padding: 9px 12px;
  margin-bottom: 10px;
  border-radius: var(--radius);
  border: 1.4px solid;
  cursor: pointer;
}
.strip--warn {
  color: var(--primary-deep);
  border-color: var(--primary);
  background: rgba(255, 107, 26, 0.1);
}
.strip--error {
  color: var(--rose);
  border-color: var(--rose);
  background: rgba(229, 72, 77, 0.1);
  cursor: default;
}
.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: currentColor;
  animation: pulse 1.4s ease-in-out infinite;
}
@keyframes pulse {
  50% {
    opacity: 0.3;
  }
}
.tools {
  display: flex;
  gap: 8px;
  margin-bottom: 10px;
}
.field.search {
  flex: 1;
  padding: 9px 12px;
  font-size: 13.5px;
}
.refresh {
  flex: none;
  min-width: 64px;
  font: inherit;
  font-size: 13px;
  font-weight: 800;
  color: var(--ink);
  background: var(--surface);
  border: 1.6px solid var(--ink);
  border-radius: var(--radius);
  cursor: pointer;
}
.refresh:disabled {
  color: var(--ink-faint);
  border-color: var(--ink-faint);
  cursor: default;
}
.hint {
  display: flex;
  justify-content: center;
  padding-top: 40px;
}
.tip {
  padding: 18px;
  max-width: 460px;
  font-size: 13px;
  line-height: 1.6;
  color: var(--ink-soft);
}
.tip p {
  margin: 8px 0 0;
}
.body {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  -webkit-overflow-scrolling: touch;
}
.list {
  list-style: none;
  margin: 0;
  padding: 0 0 10px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px 13px;
  cursor: pointer;
  transition: transform 90ms ease;
}
.row:active {
  transform: translate(1.5px, 1.5px);
}
.row-main {
  flex: 1;
  min-width: 0;
}
.row-title {
  display: flex;
  align-items: baseline;
  gap: 5px;
  font-size: 14.5px;
  font-weight: 700;
  line-height: 1.35;
}
.row-title .t {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.pin {
  color: var(--primary);
  font-size: 11px;
  flex: none;
}
.row-meta {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 5px;
  flex-wrap: wrap;
}
.chip.waiting {
  color: var(--grape);
  border-color: var(--grape);
  background: rgba(124, 92, 255, 0.1);
}
.time {
  font-size: 11px;
  color: var(--ink-faint);
}
.row-preview {
  margin-top: 5px;
  font-size: 12px;
  color: var(--ink-soft);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.row-arrow {
  flex: none;
  font-size: 20px;
  color: var(--ink-faint);
}
</style>
