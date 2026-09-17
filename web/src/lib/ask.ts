/// 询问交互（AskUserQuestion）纯逻辑 — 移植自 `lib/ui/composer_logic.dart`。
///
/// **为什么这是高危缺口**：服务端在 `pendingInteractions` 非空时**在等回答**，
/// 回合不会继续。客户端不渲染面板、不回传，会话就**永久卡住**——
/// 用户看到的是「发出去没反应」，找不到原因。
///
/// 契约形状是实测出来的（BUG-17），别重新猜：
/// · 进来：`pendingInteractions[].payload = {kind:'userInput', freeText, prompt,
///   questions:[{question, header, multiSelect, options:[{value,label,description}]}]}`
///   —— **没有 id、没有 required、没有 allowOther**，选项标识是 `value`（不是 label）。
/// · 回传：`{action:'accept', content:{answers:[{question:'题干原文', selected:[…]}]}}`
///   —— `answers` 是**数组**，元素的键是**题干原文**（服务端没有 id 可用）。

export interface AskOption {
  value: string
  label: string
  description: string
}

export interface AskQuestion {
  /** 题干原文。既是展示内容，也是回传 answers 的键。 */
  question: string
  /** 短标题；缺省退回题干。 */
  header: string
  multiSelect: boolean
  options: AskOption[]
}

export interface AskAnswer {
  selected: string[]
  other: string
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v)
}

function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

/** 解析选项。缺字段一律给安全默认，绝不抛。 */
export function parseOption(raw: unknown): AskOption {
  if (!isMap(raw)) return { value: '', label: '', description: '' }
  const label = str(raw['label'])
  const value = str(raw['value'])
  return {
    value: value || label,
    label: label || value,
    description: str(raw['description']),
  }
}

/** 解析一道题。缺字段一律给安全默认，绝不抛。 */
export function parseQuestion(raw: unknown): AskQuestion {
  if (!isMap(raw)) return { question: '', header: '', multiSelect: false, options: [] }
  const options = Array.isArray(raw['options']) ? raw['options'].map(parseOption) : []
  const question = str(raw['question'] ?? raw['prompt'])
  const header = str(raw['header'])
  return {
    question,
    header: header || question,
    multiSelect: raw['multiSelect'] === true,
    options,
  }
}

/** 解析整个 interaction 的题目列表。 */
export function parseQuestions(interaction: Record<string, unknown>): AskQuestion[] {
  const payload = interaction['payload']
  if (!isMap(payload)) return []
  const qs = payload['questions']
  return Array.isArray(qs) ? qs.map(parseQuestion) : []
}

/** 该题的回传键。没有 id，只能用题干；题干也空时给稳定占位，
 *  避免多道空题干题全部塌到同一个键上互相覆盖。 */
export function questionKey(q: AskQuestion, index: number): string {
  return q.question || `#q${index}`
}

/** payload 是否带顶层 freeText 开关（控制「其他…」入口是否出现）。 */
export function payloadAllowsFreeText(interaction: Record<string, unknown>): boolean {
  const payload = interaction['payload']
  return isMap(payload) && payload['freeText'] === true
}

export function isQuestionInteraction(interaction: Record<string, unknown>): boolean {
  const payload = interaction['payload']
  return isMap(payload) && payload['kind'] === 'userInput'
}

export function emptyAnswers(count: number): AskAnswer[] {
  return Array.from({ length: count }, () => ({ selected: [], other: '' }))
}

export function answerIsEmpty(a: AskAnswer): boolean {
  return a.selected.length === 0 && a.other.trim() === ''
}

/** 所有题都答了才允许提交（门槛）。 */
export function allAnswered(answers: AskAnswer[]): boolean {
  return answers.length > 0 && answers.every((a) => !answerIsEmpty(a))
}

/**
 * 点一个选项。
 * 多选：toggle（已选则取消）。单选：替换（**点已选中的则清空，允许反悔**）。
 */
export function toggleOption(a: AskAnswer, value: string, multiSelect: boolean): AskAnswer {
  if (multiSelect) {
    const next = new Set(a.selected)
    if (next.has(value)) next.delete(value)
    else next.add(value)
    return { ...a, selected: [...next] }
  }
  if (a.selected.length === 1 && a.selected[0] === value) {
    return { ...a, selected: [] }
  }
  return { ...a, selected: [value] }
}

/**
 * 组装回传载荷。
 *
 * 契约里 `selected` 是唯一出口，**没有独立的 other 字段**；所以自由文本
 * 拼进 selected。调用方同时会把原文放进顶层 freeText 兜底——服务端认哪个用哪个。
 * 门槛由 `allAnswered` 把关，这里不校验。
 */
export function buildAskAnswersPayload(
  questions: AskQuestion[],
  answers: AskAnswer[],
): { action: string; content: { answers: { question: string; selected: string[] }[] } } {
  const list = questions.map((q, i) => {
    const a = answers[i] ?? { selected: [], other: '' }
    const selected = [...a.selected]
    const t = a.other.trim()
    if (t) selected.push(t)
    return { question: questionKey(q, i), selected }
  })
  return { action: 'accept', content: { answers: list } }
}

/** 权限类交互（非 questions）：直接用 optionId 回传。 */
export function isPermissionInteraction(interaction: Record<string, unknown>): boolean {
  const payload = interaction['payload']
  if (!isMap(payload)) return false
  return payload['kind'] === 'permission' || payload['requestId'] != null
}

/** 权限交互的可选项（服务端可能给 options，也可能只给 approve/deny 两态）。 */
export function permissionOptions(interaction: Record<string, unknown>): AskOption[] {
  const payload = interaction['payload']
  if (!isMap(payload)) return []
  const opts = payload['options']
  if (Array.isArray(opts) && opts.length) return opts.map(parseOption)
  return [
    { value: 'allow', label: '允许', description: '' },
    { value: 'deny', label: '拒绝', description: '' },
  ]
}

/** 交互的稳定标识（列表 key 用——每帧都是新拷贝，无 key 会误判换卡）。 */
export function interactionId(interaction: Record<string, unknown>): string {
  return str(interaction['interactionId'] ?? interaction['requestId'])
}
