<script setup lang="ts">
/// 模型 / 思考等级 / 模式选择面板。
///
/// 数据来源是 `zcode-task.getTaskConfigOptions({taskId})`（老方法
/// `prepareWorkspace` 已被桌面端升级删除，**不要**再写回退路径）。
/// 选项组是**会话域**的：store 里按 taskId 缓存，切会话会自动重拉。
///
/// 三个动作都走 CAS 命令（`switchModelConfig` / `switchCollaborationMode`），
/// 成功后 store 会 forceResync + 重拉选项 ⇒ 面板上显示的永远是服务端落位后的值，
/// 不是本地点下去的样子。
import { computed, ref } from 'vue'
import { useAppStore } from '../stores/app'
import {
  GROUP_MODE,
  GROUP_MODEL,
  GROUP_THOUGHT,
  groupOf,
  type ConfigGroup,
} from '../lib/configOptions'

const emit = defineEmits<{ (e: 'close'): void }>()
const app = useAppStore()

/** 正在提交的那一项（点下去到服务端落位之间只允许一个在途）。 */
const pending = ref('')

const model = computed<ConfigGroup | null>(() => groupOf(app.configGroups, GROUP_MODEL))
const thought = computed<ConfigGroup | null>(() => groupOf(app.configGroups, GROUP_THOUGHT))
const mode = computed<ConfigGroup | null>(() => groupOf(app.configGroups, GROUP_MODE))
const empty = computed(() => !app.configLoading && !model.value && !mode.value)

async function choose(kind: 'model' | 'mode', value: string): Promise<void> {
  if (pending.value) return
  pending.value = `${kind}:${value}`
  try {
    const ok = kind === 'model' ? await app.applyModel(value) : await app.applyMode(value)
    if (ok) emit('close')
  } finally {
    pending.value = ''
  }
}
</script>

<template>
  <div class="scrim" role="presentation" @click.self="emit('close')">
    <div class="sheet" role="dialog" aria-label="模型与模式">
      <div class="sheet-head">
        <strong>模型 / 模式</strong>
        <button class="close" type="button" aria-label="关闭" @click="emit('close')">✕</button>
      </div>

      <div v-if="app.configLoading" class="note">正在取选项（这一步桌面端要 2 秒上下）…</div>
      <div v-else-if="app.configError" class="note note--err">
        {{ app.configError }}
        <button class="retry" type="button" @click="void app.loadConfigOptions(true)">重试</button>
      </div>
      <div v-else-if="empty" class="note">没拿到可选项。</div>

      <section v-if="model" class="grp">
        <h4>模型</h4>
        <button
          v-for="o in model.options"
          :key="o.value"
          class="opt"
          :class="{ on: o.value === model.current }"
          type="button"
          :disabled="!!pending"
          @click="void choose('model', o.value)"
        >
          <span class="opt-name">{{ o.name }}</span>
          <span v-if="o.description" class="opt-desc">{{ o.description }}</span>
          <span
            v-if="pending === 'model:' + o.value"
            class="opt-busy"
            >切换中…</span
          >
        </button>
      </section>

      <section v-if="thought" class="grp">
        <h4>思考等级</h4>
        <div class="row-btns">
          <span v-for="o in thought.options" :key="o.value" class="pill" :class="{ on: o.value === thought.current }">
            {{ o.name }}
          </span>
        </div>
        <div class="note note--mini">思考等级随模型一起下发，不能单独在这里改。</div>
      </section>

      <section v-if="mode" class="grp">
        <h4>协作模式</h4>
        <div class="row-btns">
          <button
            v-for="o in mode.options"
            :key="o.value"
            class="pill pill--btn"
            :class="{ on: o.value === mode.current }"
            type="button"
            :disabled="!!pending"
            @click="void choose('mode', o.value)"
          >
            {{ o.name }}
          </button>
        </div>
      </section>
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
  margin-bottom: 6px;
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
.grp {
  margin-top: 12px;
}
.grp h4 {
  margin: 0 0 6px;
  font-size: 13px;
  color: var(--ink-soft, #777);
}
.opt {
  display: block;
  width: 100%;
  min-height: 48px;
  margin-bottom: 6px;
  padding: 8px 12px;
  text-align: left;
  font: inherit;
  font-size: 15px;
  border: 1.6px solid var(--line, #e5e5e5);
  border-radius: 12px;
  background: var(--card, #fff);
  color: var(--ink, #222);
  cursor: pointer;
}
.opt.on {
  border-color: var(--ink, #222);
  font-weight: 800;
}
.opt:disabled {
  opacity: 0.6;
  cursor: default;
}
.opt-name {
  display: block;
}
.opt-desc {
  display: block;
  font-size: 12px;
  color: var(--ink-soft, #888);
}
.opt-busy {
  font-size: 12px;
  color: var(--ink-soft, #888);
}
.row-btns {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.pill {
  min-height: 40px;
  padding: 8px 14px;
  font: inherit;
  font-size: 14px;
  font-weight: 700;
  border-radius: 999px;
  border: 1.6px solid var(--line, #e5e5e5);
  background: var(--card, #fff);
  color: var(--ink, #222);
}
.pill.on {
  border-color: var(--ink, #222);
  background: var(--ink, #222);
  color: var(--card, #fff);
}
.pill--btn {
  cursor: pointer;
}
.pill--btn:disabled {
  opacity: 0.6;
  cursor: default;
}
.note {
  font-size: 13px;
  color: var(--ink-soft, #666);
  margin: 8px 0;
}
.note--mini {
  font-size: 12px;
  margin-top: 6px;
}
.note--err {
  color: #b3261e;
}
.retry {
  min-height: 36px;
  margin-left: 8px;
  font: inherit;
  font-size: 13px;
  font-weight: 800;
  border: 1.6px solid currentColor;
  border-radius: 10px;
  background: none;
  cursor: pointer;
}
</style>
