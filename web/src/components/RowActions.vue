<script setup lang="ts">
/// 会话行操作面板（置顶 / 重命名 / 归档 / 删除）。
///
/// 为什么是「⋯ 点开」而不是长按：列表的滚动与视口锚定是专门研究过的
/// （docs/SCROLL-STABILITY-RESEARCH.md），长按手势要和拖拽滚动抢事件，
/// 为了一个菜单把那块稳定性换回来不值。
///
/// 所有动作都走 store 的 runTaskOp：**成功就重拉服务端**，本地不做乐观状态
/// （两端一致性裁定）；失败把服务端给的人话原因显示出来，按钮留着可重试。
import { computed, ref } from 'vue'
import { useAppStore } from '../stores/app'
import type { SessionCard } from '../lib/sessions'

const props = defineProps<{
  card: SessionCard
  /** 面板是从归档视图打开的 → 提供「取消归档」而不是「归档」。 */
  archived?: boolean
}>()
const emit = defineEmits<{ (e: 'close'): void }>()

const app = useAppStore()
const busy = ref(false)
const renaming = ref(false)
const confirmingDelete = ref(false)
const draftTitle = ref(props.card.title)

const pinnedLabel = computed(() => (props.card.pinned ? '取消置顶' : '置顶'))

async function run(fn: () => Promise<unknown>): Promise<void> {
  if (busy.value) return
  busy.value = true
  try {
    await fn()
    // 失败时 store 会把人话原因写进 listNotice，此时面板留着让用户能重试
    if (!app.listNotice) emit('close')
  } finally {
    busy.value = false
  }
}

function startRename(): void {
  draftTitle.value = props.card.title
  renaming.value = true
}

async function submitRename(): Promise<void> {
  const next = draftTitle.value.trim()
  if (!next || next === props.card.title) {
    renaming.value = false
    return
  }
  await run(() => app.renameTask(props.card.sessionId, next))
}
</script>

<template>
  <div class="scrim" role="presentation" @click.self="emit('close')">
    <div class="sheet" role="dialog" aria-label="会话操作">
      <div class="sheet-title">{{ card.title }}</div>

      <template v-if="renaming">
        <input
          v-model="draftTitle"
          class="sheet-input"
          aria-label="新标题"
          maxlength="120"
          :disabled="busy"
          @keyup.enter="void submitRename()"
        />
        <button class="sheet-btn" type="button" :disabled="busy" @click="void submitRename()">
          {{ busy ? '提交中…' : '保存标题' }}
        </button>
        <button class="sheet-btn sheet-btn--quiet" type="button" @click="renaming = false">
          取消
        </button>
      </template>

      <template v-else-if="confirmingDelete">
        <div class="sheet-warn">
          删除后不可恢复。{{ card.pinned ? '该会话已置顶；' : ''
          }}{{ archived ? '这是归档会话。' : '' }}运行中的会话会先停止再删。
        </div>
        <button
          class="sheet-btn sheet-btn--danger"
          type="button"
          :disabled="busy"
          @click="run(() => app.removeTask(card.sessionId))"
        >
          {{ busy ? '删除中…' : '确认删除' }}
        </button>
        <button class="sheet-btn sheet-btn--quiet" type="button" @click="confirmingDelete = false">
          返回
        </button>
      </template>

      <template v-else>
        <button
          class="sheet-btn"
          type="button"
          :disabled="busy"
          @click="run(() => app.pinTask(card.sessionId, !card.pinned))"
        >
          {{ pinnedLabel }}
        </button>
        <button class="sheet-btn" type="button" :disabled="busy" @click="startRename()">
          重命名
        </button>
        <button
          v-if="archived"
          class="sheet-btn"
          type="button"
          :disabled="busy"
          @click="run(() => app.unarchiveTask(card.sessionId))"
        >
          取消归档
        </button>
        <button
          v-else
          class="sheet-btn"
          type="button"
          :disabled="busy"
          @click="run(() => app.archiveTask(card.sessionId))"
        >
          归档
        </button>
        <button
          class="sheet-btn sheet-btn--danger"
          type="button"
          :disabled="busy"
          @click="confirmingDelete = true"
        >
          删除
        </button>
        <button class="sheet-btn sheet-btn--quiet" type="button" @click="emit('close')">关闭</button>
      </template>

      <div v-if="app.listNotice" class="sheet-err">{{ app.listNotice }}</div>
    </div>
  </div>
</template>

<style scoped>
.scrim {
  position: fixed;
  inset: 0;
  z-index: 30;
  background: rgba(0, 0, 0, 0.42);
  display: flex;
  align-items: flex-end;
  justify-content: center;
}
.sheet {
  width: 100%;
  max-width: 520px;
  background: var(--card, #fff);
  border-radius: 16px 16px 0 0;
  padding: 14px 16px calc(18px + env(safe-area-inset-bottom));
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.sheet-title {
  font-weight: 800;
  font-size: 15px;
  margin-bottom: 4px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sheet-btn {
  min-height: 48px;
  font: inherit;
  font-size: 16px;
  font-weight: 700;
  text-align: left;
  padding: 0 14px;
  border: 1px solid var(--line, #e5e5e5);
  border-radius: 12px;
  background: var(--card, #fff);
  color: var(--ink, #222);
  cursor: pointer;
}
.sheet-btn:disabled {
  opacity: 0.55;
  cursor: default;
}
.sheet-btn--quiet {
  color: var(--ink-soft, #777);
  border-color: transparent;
}
.sheet-btn--danger {
  color: #b3261e;
  border-color: rgba(179, 38, 30, 0.35);
}
.sheet-input {
  min-height: 48px;
  font: inherit;
  font-size: 16px;
  padding: 8px 12px;
  border: 1px solid var(--line, #ddd);
  border-radius: 12px;
}
.sheet-warn {
  font-size: 14px;
  line-height: 1.5;
  color: var(--ink-soft, #666);
}
.sheet-err {
  font-size: 13px;
  color: #b3261e;
}
</style>
