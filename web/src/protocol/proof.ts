/// 配对证明 — TS 移植自 lib/protocol/proof.dart。
/// proof = base64url_nopad(HMAC-SHA256(key: utf8(passHash),
///                                    msg: utf8('$nonce|$role|$deviceSid')))
/// Web Crypto 的 HMAC 是异步的，调用方（relay 握手）相应 await。

function base64UrlNoPad(bytes: Uint8Array): string {
  let bin = ''
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export async function calculateProof(opts: {
  passHash: string
  nonce: string
  role: string
  deviceSid: string
}): Promise<string> {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(opts.passHash) as unknown as ArrayBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const msg = enc.encode(`${opts.nonce}|${opts.role}|${opts.deviceSid}`)
  const sig = await crypto.subtle.sign('HMAC', key, msg as unknown as ArrayBuffer)
  return base64UrlNoPad(new Uint8Array(sig))
}
