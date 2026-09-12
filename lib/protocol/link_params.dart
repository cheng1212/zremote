/// Parses a ZCode web-remote connection URL, e.g.
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...
class LinkParams {
  final String deviceSid;
  final String passHash;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final Uri source;

  const LinkParams({
    required this.deviceSid,
    required this.passHash,
    required this.source,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
  });

  static String? _get(Uri uri, String key) {
    final v = uri.queryParameters[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static LinkParams? parse(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    final sid = _get(uri, 'sid');
    final hash = _get(uri, 'hash');
    final t = int.tryParse(_get(uri, 't') ?? '');
    if ((uri.scheme != 'https' && uri.scheme != 'wss') ||
        sid == null ||
        hash == null ||
        t == null) {
      return null;
    }
    return LinkParams(
      deviceSid: sid,
      passHash: hash,
      deviceMid: _get(uri, 'mid'),
      deviceName: _get(uri, 'name'),
      appVersion: _get(uri, 'app_version'),
      source: uri,
    );
  }

  /// Relay websocket URL: `${ws(s)://<host>/ws` plus `?mid=` when present.
  Uri get relayWsUri {
    final scheme = secure ? 'wss' : 'ws';
    final base = Uri(
      scheme: scheme,
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }

  bool get secure => source.scheme == 'https' || source.scheme == 'wss';
}
