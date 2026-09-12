/// 配对链接解析 — TS 移植自 lib/protocol/link_params.dart。
/// 形如 https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...

export interface LinkParams {
  deviceSid: string
  passHash: string
  deviceMid: string | null
  deviceName: string | null
  appVersion: string | null
  source: URL
}

function get(uri: URL, key: string): string | null {
  const v = uri.searchParams.get(key)?.trim()
  return v ? v : null
}

export function parseLinkParams(raw: string): LinkParams | null {
  let uri: URL
  try {
    uri = new URL(raw.trim())
  } catch {
    return null
  }
  if (uri.protocol !== 'https:' && uri.protocol !== 'wss:') return null
  const sid = get(uri, 'sid')
  const hash = get(uri, 'hash')
  const t = Number(get(uri, 't') ?? '')
  if (!sid || !hash || !Number.isFinite(t) || t <= 0) return null
  return {
    deviceSid: sid,
    passHash: hash,
    deviceMid: get(uri, 'mid'),
    deviceName: get(uri, 'name'),
    appVersion: get(uri, 'app_version'),
    source: uri,
  }
}

/** relay websocket 地址：wss(s)://<host>/ws（带 mid 时挂 query）。 */
export function relayWsUri(p: LinkParams): string {
  const secure = p.source.protocol === 'https:' || p.source.protocol === 'wss:'
  const scheme = secure ? 'wss' : 'ws'
  const base = `${scheme}://${p.source.host}/ws`
  return p.deviceMid ? `${base}?mid=${encodeURIComponent(p.deviceMid)}` : base
}
