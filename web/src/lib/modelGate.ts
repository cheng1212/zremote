/// 新会话模型放行闸门 —— 移植自 Flutter 端 `lib/ui/composer_logic.dart` 的
/// `sessionModelMatches` / `splitModelValue`（唯一蓝本）。
///
/// 为什么需要它：桌面端接受 createSession 后，仍可能把模型**回退**成工作区默认
/// （provider 不在册 / 本地模型代理没起）。首条消息如果随建会话一起提交，
/// 就会静默发进那个跑不通的模型。所以路径是：
///   createSession(config) → 开订阅等快照 → 比对快照模型 == 请求模型 → 才 sendText
/// （见 docs/feat-draft-model-ready-gate.md，提交 309ee1f）

/** `provider/model` 拆分：无斜杠时两边同值，调用方不必判空。 */
export function splitModelValue(value: string): [string, string] {
  const idx = value.lastIndexOf('/')
  if (idx <= 0) return [value, value]
  return [value.slice(0, idx), value.slice(idx + 1)]
}

/**
 * 快照模型是否已落到请求值。
 * model 必须一致；**请求了 provider 才校验 provider**（服务端可能回填同义 id），
 * 但只要请求过就必须一致——防同名模型跨供应商回退。
 */
export function sessionModelMatches(args: {
  curProvider: string
  curModel: string
  wantProvider: string
  wantModel: string
}): boolean {
  const { curProvider, curModel, wantProvider, wantModel } = args
  if (!wantModel || curModel !== wantModel) return false
  return !wantProvider || curProvider === wantProvider
}

export interface SnapshotModel {
  provider: string
  model: string
  thought: string
  mode: string
}

/** 从会话快照里读 `config`（形状未全实测，缺字段一律退化成空串）。 */
export function readSnapshotModel(snapshot: Record<string, unknown> | null): SnapshotModel {
  const cfg = snapshot?.['config']
  const c = cfg && typeof cfg === 'object' && !Array.isArray(cfg) ? (cfg as Record<string, unknown>) : {}
  const str = (v: unknown): string => (typeof v === 'string' ? v : '')
  return {
    provider: str(c['provider']),
    model: str(c['model']),
    thought: str(c['thought']),
    mode: str(c['mode']),
  }
}

/** 请求的 config（`{provider?, model?, thought?}`，model 也可写成 `provider/model`）→ 比对用的 want 值。 */
export function wantedModel(config: Record<string, unknown> | null | undefined): {
  provider: string
  model: string
} {
  if (!config) return { provider: '', model: '' }
  const raw = typeof config['model'] === 'string' ? (config['model'] as string) : ''
  const [p, m] = splitModelValue(raw)
  const wantProvider = typeof config['provider'] === 'string' && config['provider'] ? (config['provider'] as string) : raw.includes('/') ? p : ''
  const wantModel = raw.includes('/') ? m : raw
  return { provider: wantProvider, model: wantModel }
}

export interface GateResult {
  ok: boolean
  /** 失败时给人看的说明（直接进 sendError）。 */
  reason: string
}

/**
 * 闸门判定：请求了模型才校验；没请求（用工作区默认）直接放行。
 */
export function checkModelGate(
  snapshot: Record<string, unknown> | null,
  config: Record<string, unknown> | null | undefined,
): GateResult {
  const want = wantedModel(config)
  if (!want.model) return { ok: true, reason: '' }
  const cur = readSnapshotModel(snapshot)
  if (
    sessionModelMatches({
      curProvider: cur.provider,
      curModel: cur.model,
      wantProvider: want.provider,
      wantModel: want.model,
    })
  ) {
    return { ok: true, reason: '' }
  }
  return {
    ok: false,
    reason: `会话模型被服务端置为 ${cur.provider ? cur.provider + '/' : ''}${cur.model || '(未知)'}，` +
      `未落到请求的 ${want.provider ? want.provider + '/' : ''}${want.model}。消息未发送`,
  }
}
