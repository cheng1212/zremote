<script setup lang="ts">
/// 询问 / 审批面板 —— **不回传会话就永久卡住**（服务端在等回答，回合不继续）。
///
/// 契约形状是实测出来的（BUG-17），别重新猜：
/// · questions 进来没有 id / 没有 required / 没有 allowOther；选项标识是
///   `value`（不是 label）。
/// · 回传 `{action:'accept', content:{answers:[{question:题干原文, selected:[…]}]}}`
///   —— answers 是数组、键是**题干原文**。
/// · permission 走 `{optionId}`。
///
/// 状态按「交互内容」重置：不能用实例身份比较——`pendingInteractions`
/// 每帧都是新拷贝，用身份比会把用户答到一半的选择反复清空。

import { computed, ref, watch } from 'vue'
import { useAppStore } from '../stores/app'
import {
  allAnswered,
  emptyAnswers,
  interactionId,
  isPermissionInteraction,
  payloadAllowsFreeText,
  permissionOptions,
  questionKey,
  toggleOption,
  type AskAnswer,
  type AskQuestion,
} from '../lib/ask'

const app = useAppStore()

/** 当前正在处理的交互（一次只展示一张卡，避免多张卡同时抢焦点）。 */
const current = computed<Record<string, unknown> | null>(
  () => app.pendingInteractions[0] ?? null,
)

const curId = computed(() => (current.value ? interactionId(current.value) : ''))

/** 解析题目列表。缺字段一律给安全默认（形状来自服务端，会随版本漂移）。 */
function parseQuestions(i: Record<string, unknown>): AskQuestion[] {
  const payload = i['payload']
  if (!payload || typeof payload !== 'object') return []
  const list = (payload as Record<string, unknown>)['questions']
  if (!Array.isArray(list)) return []
  return list.map((raw) => {
    const r = (raw ?? {}) as Record<string, unknown>
    const opts = Array.isArray(r['options'])
      ? r['options'].map((o) => {
          const oo = (o ?? {}) as Record<string, unknown>
          const label = String(oo['label'] ?? '')
          const value = String(oo['value'] ?? '')
          return {
            value: value || label,
            label: label || value,
            description: String(oo['description'] ?? ''),
          }
        })
      : []
    const question = String(r['question'] ?? r['prompt'] ?? '')
    const header = String(r['header'] ?? '')
    return {
      question,
      header: header || question,
      multiSelect: r['multiSelect'] === true,
      options: opts,
    }
  })
}

const questions = computed<AskQuestion[]>(() =>
  current.value ? parseQuestions(current.value) : [],
)

const allowOther = computed(() =>
  current.value ? payloadAllowsFreeText(current.value) : false,
)
const isPermission = computed(() =>
  current.value ? isPermissionInteraction(current.value) : false,
)
const permOptions = computed(() =>
  current.value && isPermission.value ? permissionOptions(current.value) : [],
)

/** 权限卡的正文（服务端可能给 prompt / title，都没有时给兜底文案）。 */
const permPrompt = computed(() => {
  const i = current.value
  if (!i) return ''
  const payload = i['payload']
  const p = payload && typeof payload === 'object' ? (payload as Record<string, unknown>) : {}
  return String(p['prompt'] ?? i['title'] ?? '这个操作需要授权')
})

const answers = ref<AskAnswer[]>([])
const submitting = ref(false)

/** 交互内容指纹：变了才重置作答。 */
function fingerprint(i: Record<string, unknown> | null): string {
  if (!i) return ''
  return `${interactionId(i)}|${JSON.stringify(i['payload'] ?? {})}`
}

watch(
  () => fingerprint(current.value),
  () => {
    answers.value = emptyAnswers(questions.value.length)
    submitting.value = false
  },
  { immediate: true },
)

const canSubmit = computed(() => allAnswered(answers.value))

function pick(qi: number, value: string) {
  const q = questions.value[qi]
  const cur = answers.value[qi] ?? { selected: [], other: '' }
  const next = [...answers.value]
  next[qi] = toggleOption(cur, value, q.multiSelect)
  answers.value = next
}

function isPicked(qi: number, value: string): boolean {
  return (answers.value[qi]?.selected ?? []).includes(value)
}

function setOther(qi: number, text: string) {
  const cur = answers.value[qi] ?? { selected: [], other: '' }
  const next = [...answers.value]
  next[qi] = { ...cur, other: text }
  answers.value = next
}

async function submit() {
  if (!canSubmit.value || submitting.value || !curId.value) return
  submitting.value = true
  try {
    await app.resolveQuestions(curId.value, questions.value, answers.value)
  } finally {
    submitting.value = false
  }
}

async function pickPermission(optionId: string) {
  if (submitting.value || !curId.value) return
  submitting.value = true
  try {
    await app.resolvePermission(curId.value, optionId, permNote.value || undefined)
  } finally {
    submitting.value = false
  }
}

const permNote = ref('')
</script>

<template>
  <div v-if="current" class="ask card">
    <!-- ── questions ── -->
    <template v-if="!isPermission">
      <div class="ask__head">需要你回答</div>
      <div v-for="(q, qi) in questions" :key="questionKey(q, qi)" class="q">
        <div class="q__head">
          <span class="q__header">{{ q.header }}</span>
          <span class="q__hint">{{ q.multiSelect ? '可多选' : '单选' }}</span>
        </div>
        <p v-if="q.question && q.question !== q.header" class="q__prompt">{{ q.question }}</p>
        <div class="q__opts">
          <button
            v-for="o in q.options"
            :key="o.value"
            type="button"
            class="opt"
            :class="{ 'is-picked': isPicked(qi, o.value) }"
            @click="pick(qi, o.value)"
          >
            <span class="opt__mark">{{ q.multiSelect ? (isPicked(qi, o.value) ? '☑' : '☐') : (isPicked(qi, o.value) ? '●' : '○') }}</span>
            <span class="opt__label">{{ o.label }}</span>
            <span v-if="o.description" class="opt__desc">{{ o.description }}</span>
          </button>
        </div>
        <input
          v-if="allowOther"
          class="field q__other"
          :value="answers[qi]?.other ?? ''"
          placeholder="其他（自己填）"
          :aria-label="`${q.header} 的其他回答`"
          @input="setOther(qi, ($event.target as HTMLInputElement).value)"
        />
      </div>
      <div class="ask__ops">
        <button class="big-btn" type="button" :disabled="!canSubmit || submitting" @click="submit">
          {{ submitting ? '提交中…' : '提交' }}
        </button>
      </div>
    </template>

    <!-- ── permission ── -->
    <template v-else>
      <div class="ask__head">需要你确认</div>
      <p class="q__prompt">{{ permPrompt }}</p>
      <input
        v-model="permNote"
        class="field q__other"
        placeholder="附言（可选）"
        aria-label="附言"
      />
      <div class="ask__ops">
        <button
          v-for="o in permOptions"
          :key="o.value"
          type="button"
          class="perm-btn"
          :class="{ danger: o.value === 'deny' }"
          :disabled="submitting"
          @click="pickPermission(o.value)"
        >
          {{ o.label }}
        </button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.ask {
  margin: 0 0 10px;
  padding: 12px 13px;
  border-color: var(--grape);
  box-shadow: 2.5px 2.5px 0 rgba(124, 92, 255, 0.35);
}
.ask__head {
  font-size: 12px;
  font-weight: 800;
  color: var(--grape);
  letter-spacing: 0.3px;
  margin-bottom: 8px;
}
.q {
  padding: 8px 0;
  border-top: 1px solid var(--line);
}
.q:first-of-type {
  border-top: none;
  padding-top: 0;
}
.q__head {
  display: flex;
  align-items: baseline;
  gap: 8px;
}
.q__header {
  font-size: 13.5px;
  font-weight: 800;
}
.q__hint {
  font-size: 11px;
  color: var(--ink-faint);
}
.q__prompt {
  margin: 4px 0 0;
  font-size: 12.5px;
  color: var(--ink-soft);
  line-height: 1.5;
  white-space: pre-wrap;
}
.q__opts {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-top: 8px;
}
.opt {
  display: flex;
  align-items: baseline;
  gap: 8px;
  width: 100%;
  text-align: left;
  font: inherit;
  font-size: 13px;
  padding: 8px 10px;
  background: var(--bg);
  border: 1.4px solid var(--line);
  border-radius: 10px;
  cursor: pointer;
}
.opt.is-picked {
  border-color: var(--primary);
  background: rgba(255, 107, 26, 0.1);
}
.opt__mark {
  flex: none;
  color: var(--primary-deep);
  font-size: 12px;
}
.opt__label {
  flex: none;
  font-weight: 700;
}
.opt__desc {
  flex: 1;
  min-width: 0;
  font-size: 11.5px;
  color: var(--ink-faint);
}
.q__other {
  margin-top: 8px;
  padding: 8px 10px;
  font-size: 13px;
}
.ask__ops {
  display: flex;
  gap: 8px;
  margin-top: 10px;
}
.perm-btn {
  flex: 1;
  font: inherit;
  font-size: 13.5px;
  font-weight: 800;
  padding: 10px 14px;
  color: var(--ink);
  background: var(--lemon);
  border: 1.6px solid var(--ink);
  border-radius: var(--radius);
  box-shadow: var(--shadow-hard-sm);
  cursor: pointer;
}
.perm-btn.danger {
  background: var(--rose);
  color: #fff;
}
.perm-btn:disabled {
  opacity: 0.6;
  cursor: default;
}
</style>
