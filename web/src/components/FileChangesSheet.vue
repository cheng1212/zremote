<script setup lang="ts">
/// 本回合文件变更 + 回滚入口。
///
/// 回滚是**破坏性动作**（会改工作区文件），所以强制两步：
///   预览（服务端算 canApply / 哪些文件被用户自己改过）→ 用户确认 → 执行。
/// 客户端绝不自己数一遍就滚。预览结果不可用时按钮是灰的，不是"试试看"。
import { computed } from 'vue'
import { useAppStore } from '../stores/app'

const props = defineProps<{ row: Record<string, unknown> }>()
const emit = defineEmits<{ (e: 'close'): void }>()
const app = useAppStore()

const canRollback = computed(
  () => !!app.rewindPreview && app.rewindPreview.canApply && !app.rewinding,
)
const previewed = computed(() => app.rewindPreview != null)

async function confirmRewind(): Promise<void> {
  if (await app.applyRewind()) emit('close')
}
</script>

<template>
  <div class="scrim" role="presentation" @click.self="emit('close')">
    <div class="sheet" role="dialog" aria-label="文件变更">
      <div class="sheet-head">
        <strong>本回合文件变更</strong>
        <button class="close" type="button" aria-label="关闭" @click="emit('close')">✕</button>
      </div>

      <div v-if="app.changesLoading" class="note">正在取清单…</div>
      <div v-else-if="app.changes.length === 0" class="note">
        {{ app.changesError || '没有文件变更。' }}
      </div>
      <ul v-else class="list">
        <li v-for="(c, i) in app.changes" :key="`${c.path}-${i}`" class="item">
          <span class="act">{{ c.action }}</span>
          <span class="path">{{ c.path }}</span>
          <span v-if="c.stats" class="stats">{{ c.stats }}</span>
        </li>
      </ul>

      <div v-if="previewed" class="pv">
        可回滚：{{ app.rewindPreview?.canApply ? '是' : '否' }} ·
        安全 {{ app.rewindPreview?.safe }} · 会覆盖 {{ app.rewindPreview?.unsafe }} ·
        跳过 {{ app.rewindPreview?.ignored }}
        <span v-if="app.rewindPreview?.reason" class="note note--mini">
          {{ app.rewindPreview.reason }}
        </span>
      </div>

      <button
        v-if="!previewed"
        class="btn"
        type="button"
        :disabled="app.changesLoading"
        @click="void app.previewRewind(props.row)"
      >
        先看看回滚会影响什么
      </button>
      <button
        v-else
        class="btn btn--danger"
        type="button"
        :disabled="!canRollback"
        @click="void confirmRewind()"
      >
        {{ app.rewinding ? '回滚中…' : '确认回滚这一回合' }}
      </button>
      <div v-if="previewed && !canRollback && !app.rewinding" class="note note--mini">
        服务端判定这一回合不能回滚，或还缺 revision——按钮不会放行。
      </div>

      <div v-if="app.changesError" class="note note--err">{{ app.changesError }}</div>
      <button class="btn btn--quiet" type="button" @click="emit('close')">关闭</button>
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
  max-height: 78dvh;
  overflow-y: auto;
  background: var(--card, #fff);
  border-radius: 16px 16px 0 0;
  padding: 12px 16px calc(18px + env(safe-area-inset-bottom));
}
.sheet-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.close {
  min-width: 44px;
  min-height: 44px;
  font-size: 18px;
  border: none;
  background: none;
  color: var(--ink-soft, #666);
  cursor: pointer;
}
.list {
  list-style: none;
  margin: 8px 0;
  padding: 0;
}
.item {
  display: flex;
  gap: 8px;
  align-items: baseline;
  padding: 7px 10px;
  margin-bottom: 5px;
  font-size: 13.5px;
  border: 1.2px solid var(--line, #e5e5e5);
  border-radius: 10px;
  background: var(--surface, #fafafa);
}
.act {
  flex: none;
  font-weight: 800;
  font-size: 12px;
}
.path {
  flex: 1;
  min-width: 0;
  word-break: break-all;
}
.stats {
  flex: none;
  font-size: 12px;
  color: var(--ink-soft, #888);
}
.pv {
  font-size: 13px;
  margin: 8px 0;
}
.btn {
  display: block;
  width: 100%;
  min-height: 46px;
  margin-top: 8px;
  font: inherit;
  font-size: 15px;
  font-weight: 800;
  border: 1.6px solid var(--ink, #222);
  border-radius: 12px;
  background: var(--card, #fff);
  color: var(--ink, #222);
  cursor: pointer;
}
.btn:disabled {
  opacity: 0.55;
  cursor: default;
}
.btn--danger {
  color: #b3261e;
  border-color: rgba(179, 38, 30, 0.5);
}
.btn--quiet {
  border-color: transparent;
  color: var(--ink-soft, #777);
}
.note {
  font-size: 13px;
  color: var(--ink-soft, #666);
}
.note--mini {
  display: block;
  font-size: 12px;
}
.note--err {
  color: #b3261e;
}
</style>
