/// `zcode-task.getTaskConfigOptions` 返回的选项组解析 —— 纯函数，可单测。
///
/// 形状来源是 Flutter 端 `app_controller.loadPrep()` 的实测结论：
/// · 返回**可能是裸数组**，也可能是 `{configOptions: [...]}`——两种都要认；
/// · 组的 `id` 是 `model` / `mode` / **`thought_level`（下划线）**，
///   写成 `thoughtLevel` 就匹配不上（实测踩过）；
/// · 组内 `options[]` 每项至少有 `value` / `name`，模型项还带 `modelProviderName`
///   （供应商 id，切模型必须一起回传，否则同名模型会落到错误供应商）。
///
/// 桌面端会自动升级并改返回形状（`prepareWorkspace` 已经整个被删），
/// 所以这里对每一层都做"认不出的形状退化成空、绝不抛"的处理。

export interface ConfigOption {
  value: string
  name: string
  description: string
  /** 供应商 id：`switchModelConfig` 的 provider 参数就取它。 */
  provider: string
}

export interface ConfigGroup {
  id: string
  current: string
  options: ConfigOption[]
}

export const GROUP_MODEL = 'model'
export const GROUP_MODE = 'mode'
export const GROUP_THOUGHT = 'thought_level'

function str(v: unknown): string {
  if (typeof v === 'string') return v
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  return ''
}

function isMap(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

function parseOption(raw: unknown): ConfigOption | null {
  if (!isMap(raw)) return null
  const value = str(raw['value'])
  if (!value) return null
  return {
    value,
    name: str(raw['name']) || value,
    description: str(raw['description']),
    provider: str(raw['modelProviderName'] ?? raw['provider']),
  }
}

function parseGroup(raw: unknown): ConfigGroup | null {
  if (!isMap(raw)) return null
  const id = str(raw['id'])
  if (!id) return null
  const list = Array.isArray(raw['options']) ? raw['options'] : []
  const options = list.map(parseOption).filter((o): o is ConfigOption => o != null)
  // currentValue 在不同版本也叫 current / value——逐个试。
  const current = str(raw['currentValue'] ?? raw['current'] ?? raw['value'])
  return { id, current, options }
}

/**
 * 解析选项响应。认不出来的形状一律给空数组（调用方据此显示"没拿到选项"，
 * 而不是崩在解析上，也不是假装选项列表是空的合法结果）。
 */
export function parseConfigGroups(raw: unknown): ConfigGroup[] {
  const list = Array.isArray(raw) ? raw : isMap(raw) && Array.isArray(raw['configOptions'])
    ? raw['configOptions']
    : null
  if (!list) return []
  return list.map(parseGroup).filter((g): g is ConfigGroup => g != null)
}

export function groupOf(groups: ConfigGroup[], id: string): ConfigGroup | null {
  return groups.find((g) => g.id === id) ?? null
}

/** 当前模型的可读标签：名字带 `provider/` 前缀时剥掉，避免 "glm/glm-4.6"。 */
export function modelLabel(groups: ConfigGroup[]): string {
  const g = groupOf(groups, GROUP_MODEL)
  if (!g) return ''
  const hit = g.options.find((o) => o.value === g.current)
  const raw = hit ? hit.name : g.current
  if (!raw) return ''
  if (hit && hit.provider && raw.startsWith(`${hit.provider}/`)) {
    return raw.slice(hit.provider.length + 1)
  }
  return raw
}

/**
 * 选中的模型项 → `switchModelConfig` 的 `{provider, model, thought}`。
 *
 * ⚠️ 三个字段**都必填**（桌面 schema 就是必填），thought 缺失时沿用当前
 * 思考等级，不能省略——省略会被判参数错误。
 */
export function buildModelSelection(
  groups: ConfigGroup[],
  modelValue: string,
  thoughtValue?: string,
): { provider: string; model: string; thought: string } | null {
  const g = groupOf(groups, GROUP_MODEL)
  if (!g) return null
  const opt = g.options.find((o) => o.value === modelValue)
  if (!opt) return null
  const thought = groupOf(groups, GROUP_THOUGHT)
  return {
    provider: opt.provider,
    model: opt.value,
    thought: thoughtValue || thought?.current || '',
  }
}
