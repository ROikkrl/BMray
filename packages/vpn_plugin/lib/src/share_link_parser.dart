// Pure-Dart proxy share-link parser.
//
// Converts a single proxy "share link" (vmess://, vless://, trojan://, ss://,
// hysteria2://hy2://, tuic://) into a sing-box v1.13 OUTBOUND json object, and
// can parse a whole subscription (raw or base64) into a list of outbounds.
//
// No Flutter / package imports — only dart:core + dart:convert.

import 'dart:convert';

/// Parse one proxy share link into a sing-box OUTBOUND json object (v1.13 schema).
///
/// The returned map's "tag" field is set to a human display name (from the URL
/// fragment `#name`, else `host:port`). Returns null if the link is unrecognized
/// or cannot be parsed. Never throws.
Map<String, dynamic>? parseShareLink(String link) {
  try {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;

    final schemeEnd = trimmed.indexOf('://');
    if (schemeEnd <= 0) return null;
    final scheme = trimmed.substring(0, schemeEnd).toLowerCase();

    switch (scheme) {
      case 'vmess':
        return _parseVmess(trimmed);
      case 'vless':
        return _parseVless(trimmed);
      case 'trojan':
        return _parseTrojan(trimmed);
      case 'ss':
        return _parseShadowsocks(trimmed);
      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(trimmed);
      case 'tuic':
        return _parseTuic(trimmed);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// Parse subscription content. The content may be either raw newline-separated
/// links, or a single base64 blob that decodes to newline-separated links.
/// Returns the list of outbound json objects, skipping unparseable lines.
/// Never throws.
List<Map<String, dynamic>> parseSubscription(String content) {
  final result = <Map<String, dynamic>>[];
  final trimmed = content.trim();
  if (trimmed.isEmpty) return result;

  // sing-box JSON subscription (v2board/xboard return this when the client UA
  // contains "sing-box"): pull the proxy outbounds directly.
  if (trimmed.startsWith('{')) {
    final fromJson = _parseSingboxOutbounds(trimmed);
    if (fromJson.isNotEmpty) return fromJson;
  }

  var text = content;

  // If the whole blob looks like a single base64 chunk (no scheme markers,
  // no newlines among meaningful content), try to base64-decode it.
  if (!text.contains('://')) {
    final decoded = _tryBase64ToString(text.trim());
    if (decoded != null && decoded.contains('://')) {
      text = decoded;
    }
  }

  for (final rawLine in const LineSplitter().convert(text)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final parsed = parseShareLink(line);
    if (parsed != null) result.add(parsed);
  }
  return result;
}

/// Extract proxy outbounds from a sing-box JSON config (an alternative
/// subscription format returned by v2board/xboard for sing-box clients).
List<Map<String, dynamic>> _parseSingboxOutbounds(String jsonText) {
  const proxyTypes = {
    'vmess',
    'vless',
    'trojan',
    'shadowsocks',
    'hysteria2',
    'hysteria',
    'tuic',
    'wireguard',
    'shadowtls',
    'anytls',
    'socks',
    'http',
    'ssh',
  };
  try {
    final obj = jsonDecode(jsonText);
    if (obj is! Map) return const [];
    final outbounds = obj['outbounds'];
    if (outbounds is! List) return const [];
    final result = <Map<String, dynamic>>[];
    for (final o in outbounds) {
      if (o is Map && proxyTypes.contains(o['type'])) {
        final m = Map<String, dynamic>.from(o);
        final tag = (m['tag'] ?? '').toString().trim();
        if (tag.isEmpty) m['tag'] = '${m['server']}:${m['server_port']}';
        result.add(m);
      }
    }
    return result;
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Best-effort base64 decode (handles url-safe alphabet and missing padding).
/// Returns null if not valid base64 / not valid UTF-8.
String? _tryBase64ToString(String input) {
  final bytes = _tryBase64ToBytes(input);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return null;
  }
}

List<int>? _tryBase64ToBytes(String input) {
  var s = input.trim().replaceAll('\n', '').replaceAll('\r', '');
  if (s.isEmpty) return null;
  // Normalize url-safe alphabet.
  s = s.replaceAll('-', '+').replaceAll('_', '/');
  // Fix padding.
  final mod = s.length % 4;
  if (mod != 0) {
    s = s + '=' * (4 - mod);
  }
  try {
    return base64.decode(s);
  } catch (_) {
    try {
      return base64.decode(base64.normalize(s));
    } catch (_) {
      return null;
    }
  }
}

/// URL-decode a string, tolerating already-decoded / malformed input.
String _urlDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }
}

/// Extract the `#fragment` display name from a link (url-decoded), or null.
String? _fragmentName(String link) {
  final hashIdx = link.indexOf('#');
  if (hashIdx < 0 || hashIdx + 1 >= link.length) return null;
  final frag = link.substring(hashIdx + 1).trim();
  if (frag.isEmpty) return null;
  return _urlDecode(frag);
}

/// Parse an int from a dynamic value (string or num). Returns null on failure.
int? _toInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }
  return null;
}

/// Split a comma/whitespace separated alpn string into a list, or null.
List<String>? _parseAlpn(String? raw) {
  if (raw == null) return null;
  final parts = raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  return parts;
}

/// Build a v2ray "transport" object from network params common to
/// vless/trojan/vmess. Returns null when no transport (e.g. tcp) is needed.
Map<String, dynamic>? _buildTransport({
  required String? network,
  String? path,
  String? host,
  String? serviceName,
  String? headerType,
}) {
  final net = (network ?? 'tcp').toLowerCase();
  switch (net) {
    case 'ws':
    case 'websocket':
      final t = <String, dynamic>{'type': 'ws'};
      if (path != null && path.isNotEmpty) t['path'] = path;
      if (host != null && host.isNotEmpty) {
        t['headers'] = {'Host': host};
      }
      return t;
    case 'grpc':
      final t = <String, dynamic>{'type': 'grpc'};
      final svc = serviceName ?? path;
      if (svc != null && svc.isNotEmpty) {
        t['service_name'] = svc;
      }
      return t;
    case 'http':
    case 'h2':
      final t = <String, dynamic>{'type': 'http'};
      if (path != null && path.isNotEmpty) t['path'] = path;
      if (host != null && host.isNotEmpty) {
        t['host'] = [host];
      }
      return t;
    case 'httpupgrade':
      final t = <String, dynamic>{'type': 'httpupgrade'};
      if (path != null && path.isNotEmpty) t['path'] = path;
      if (host != null && host.isNotEmpty) t['host'] = host;
      return t;
    case 'quic':
      return {'type': 'quic'};
    case 'tcp':
    default:
      // sing-box "tcp" network uses no transport object. If headerType=http
      // an HTTP transport is implied; map it for completeness.
      if ((headerType ?? '').toLowerCase() == 'http') {
        final t = <String, dynamic>{'type': 'http'};
        if (path != null && path.isNotEmpty) t['path'] = path;
        if (host != null && host.isNotEmpty) {
          t['host'] = [host];
        }
        return t;
      }
      return null;
  }
}

bool _supportedNetwork(String? network) => const {
  '', 'tcp', 'ws', 'websocket', 'grpc', 'http', 'h2', 'httpupgrade', 'quic',
}.contains((network ?? 'tcp').toLowerCase());

// ---------------------------------------------------------------------------
// vmess:// (v2rayN base64 JSON)
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseVmess(String link) {
  // Strip scheme. Body is base64(JSON). A trailing #fragment is uncommon but
  // tolerated.
  var body = link.substring('vmess://'.length);
  String? fragName;
  final hashIdx = body.indexOf('#');
  if (hashIdx >= 0) {
    fragName = _fragmentName(link);
    body = body.substring(0, hashIdx);
  }

  final jsonStr = _tryBase64ToString(body);
  if (jsonStr == null) return null;

  Map<String, dynamic> j;
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map) return null;
    j = decoded.map((k, v) => MapEntry(k.toString(), v));
  } catch (_) {
    return null;
  }

  final server = (j['add'] ?? '').toString().trim();
  final port = _toInt(j['port']);
  final uuid = (j['id'] ?? '').toString().trim();
  if (server.isEmpty || port == null || uuid.isEmpty) return null;

  final net = (j['net'] ?? 'tcp').toString();
  if (!_supportedNetwork(net)) return null;
  final path = (j['path'] ?? '').toString();
  final host = (j['host'] ?? '').toString();
  // v2rayN security/cipher field is "scy" (newer) or "security"; "type" is the
  // header type for tcp.
  final security = (j['scy'] ?? j['security'] ?? j['scid'] ?? 'auto')
      .toString();
  final headerType = (j['type'] ?? '').toString();

  final out = <String, dynamic>{
    'type': 'vmess',
    'server': server,
    'server_port': port,
    'uuid': uuid,
    'security': security.isEmpty ? 'auto' : security,
  };

  final aid = _toInt(j['aid']);
  if (aid != null && aid != 0) out['alter_id'] = aid;

  final transport = _buildTransport(
    network: net,
    path: path,
    host: host,
    serviceName:
        (j['serviceName'] ?? j['sni'] ?? '').toString().isNotEmpty &&
            net.toLowerCase() == 'grpc'
        ? (j['serviceName'] ?? path).toString()
        : null,
    headerType: headerType,
  );
  if (transport != null) out['transport'] = transport;

  // TLS
  final tlsMode = (j['tls'] ?? '').toString().toLowerCase();
  if (tlsMode == 'tls' || tlsMode == 'reality') {
    final tls = <String, dynamic>{'enabled': true};
    final sni = (j['sni'] ?? '').toString().trim();
    final serverName = sni.isNotEmpty ? sni : (host.isNotEmpty ? host : server);
    if (serverName.isNotEmpty) tls['server_name'] = serverName;
    final alpn = _parseAlpn((j['alpn'] ?? '').toString());
    if (alpn != null) tls['alpn'] = alpn;
    final fp = (j['fp'] ?? '').toString().trim();
    if (fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }
    out['tls'] = tls;
  }

  final ps = (j['ps'] ?? '').toString().trim();
  String tag = fragName ?? ps;
  if (tag.isEmpty) tag = '$server:$port';
  out['tag'] = tag;
  return out;
}

// ---------------------------------------------------------------------------
// Shared URI-style parsing for vless / trojan / hysteria2 / tuic
// ---------------------------------------------------------------------------

class _UriParts {
  final String userInfo;
  final String host;
  final int port;
  final Map<String, String> params;
  final String? name;
  _UriParts(this.userInfo, this.host, this.port, this.params, this.name);
}

/// Parse a `scheme://userinfo@host:port?query#frag` link defensively.
/// Returns null if host/port cannot be determined.
_UriParts? _parseUriStyle(String link, String scheme) {
  var rest = link.substring('$scheme://'.length);

  // Fragment.
  String? name;
  final hashIdx = rest.indexOf('#');
  if (hashIdx >= 0) {
    name = _fragmentName(link);
    rest = rest.substring(0, hashIdx);
  }

  // Query.
  final params = <String, String>{};
  final qIdx = rest.indexOf('?');
  if (qIdx >= 0) {
    final query = rest.substring(qIdx + 1);
    rest = rest.substring(0, qIdx);
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) {
        params[_urlDecode(pair)] = '';
      } else {
        final k = _urlDecode(pair.substring(0, eq));
        final v = _urlDecode(pair.substring(eq + 1));
        params[k] = v;
      }
    }
  }

  // userinfo@hostport
  String userInfo = '';
  String hostPort = rest;
  final atIdx = rest.lastIndexOf('@');
  if (atIdx >= 0) {
    userInfo = rest.substring(0, atIdx);
    hostPort = rest.substring(atIdx + 1);
  }

  // Split host:port, accounting for IPv6 [..]:port.
  String host;
  int? port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    host = hostPort.substring(1, close);
    final after = hostPort.substring(close + 1);
    if (after.startsWith(':')) {
      port = _toInt(after.substring(1));
    }
  } else {
    final colon = hostPort.lastIndexOf(':');
    if (colon >= 0) {
      host = hostPort.substring(0, colon);
      port = _toInt(hostPort.substring(colon + 1));
    } else {
      host = hostPort;
    }
  }

  host = host.trim();
  if (host.isEmpty || port == null) return null;

  return _UriParts(userInfo, host, port, params, name);
}

String _tagFor(_UriParts p) {
  if (p.name != null && p.name!.isNotEmpty) return p.name!;
  return '${p.host}:${p.port}';
}

// ---------------------------------------------------------------------------
// vless://
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseVless(String link) {
  final p = _parseUriStyle(link, 'vless');
  if (p == null) return null;
  final uuid = _urlDecode(p.userInfo).trim();
  if (uuid.isEmpty) return null;

  final out = <String, dynamic>{
    'type': 'vless',
    'server': p.host,
    'server_port': p.port,
    'uuid': uuid,
    'tag': _tagFor(p),
  };

  final flow = p.params['flow'];
  if (flow != null && flow.isNotEmpty) out['flow'] = flow;

  final network = p.params['type'] ?? 'tcp';
  if (!_supportedNetwork(network)) return null;
  final transport = _buildTransport(
    network: network,
    path: p.params['path'],
    host: p.params['host'],
    serviceName: p.params['serviceName'],
    headerType: p.params['headerType'],
  );
  if (transport != null) out['transport'] = transport;

  final security = (p.params['security'] ?? '').toLowerCase();
  if (security == 'tls' || security == 'reality' || security == 'xtls') {
    final tls = <String, dynamic>{'enabled': true};
    final sni = p.params['sni'] ?? p.params['host'];
    if (sni != null && sni.isNotEmpty) {
      tls['server_name'] = sni;
    } else {
      tls['server_name'] = p.host;
    }
    final alpn = _parseAlpn(p.params['alpn']);
    if (alpn != null) tls['alpn'] = alpn;
    if (_isInsecure(p.params)) tls['insecure'] = true;

    final fp = p.params['fp'];
    if (fp != null && fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }

    if (security == 'reality') {
      final pbk = p.params['pbk'];
      // reality needs a public_key; with one we emit the reality block. Without
      // one we DON'T drop the node (it would hide e.g. whole airport groups) —
      // we keep it as plain TLS so it still shows and never breaks the config.
      if (pbk != null && pbk.isNotEmpty) {
        final reality = <String, dynamic>{'enabled': true, 'public_key': pbk};
        final sid = p.params['sid'];
        if (sid != null && sid.isNotEmpty) reality['short_id'] = sid;
        tls['reality'] = reality;
        // Reality requires utls; default to chrome if not provided.
        tls['utls'] ??= {'enabled': true, 'fingerprint': 'chrome'};
      }
    }
    out['tls'] = tls;
  }

  return out;
}

// ---------------------------------------------------------------------------
// trojan://
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseTrojan(String link) {
  final p = _parseUriStyle(link, 'trojan');
  if (p == null) return null;
  final password = _urlDecode(p.userInfo);
  if (password.isEmpty) return null;

  final out = <String, dynamic>{
    'type': 'trojan',
    'server': p.host,
    'server_port': p.port,
    'password': password,
    'tag': _tagFor(p),
  };

  final network = p.params['type'] ?? 'tcp';
  if (!_supportedNetwork(network)) return null;
  final transport = _buildTransport(
    network: network,
    path: p.params['path'],
    host: p.params['host'],
    serviceName: p.params['serviceName'],
    headerType: p.params['headerType'],
  );
  if (transport != null) out['transport'] = transport;

  // Trojan implies TLS by default unless security=none.
  final security = (p.params['security'] ?? 'tls').toLowerCase();
  if (security != 'none') {
    final tls = <String, dynamic>{'enabled': true};
    final sni = p.params['sni'] ?? p.params['peer'] ?? p.params['host'];
    tls['server_name'] = (sni != null && sni.isNotEmpty) ? sni : p.host;
    final alpn = _parseAlpn(p.params['alpn']);
    if (alpn != null) tls['alpn'] = alpn;
    if (_isInsecure(p.params)) tls['insecure'] = true;
    final fp = p.params['fp'];
    if (fp != null && fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }
    out['tls'] = tls;
  }

  return out;
}

// ---------------------------------------------------------------------------
// ss:// (Shadowsocks) — legacy base64 and SIP002
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseShadowsocks(String link) {
  var rest = link.substring('ss://'.length);

  // Fragment.
  String? name;
  final hashIdx = rest.indexOf('#');
  if (hashIdx >= 0) {
    name = _fragmentName(link);
    rest = rest.substring(0, hashIdx);
  }

  // Query (SIP002 plugin etc.)
  final params = <String, String>{};
  final qIdx = rest.indexOf('?');
  if (qIdx >= 0) {
    final query = rest.substring(qIdx + 1);
    rest = rest.substring(0, qIdx);
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) {
        params[_urlDecode(pair)] = '';
      } else {
        params[_urlDecode(pair.substring(0, eq))] = _urlDecode(
          pair.substring(eq + 1),
        );
      }
    }
  }

  String? method;
  String? password;
  String? host;
  int? port;

  final atIdx = rest.lastIndexOf('@');
  if (atIdx >= 0) {
    // SIP002: ss://base64(method:password)@host:port  (userinfo may be plain)
    final userInfo = rest.substring(0, atIdx);
    final hostPort = rest.substring(atIdx + 1);

    String decodedUser = userInfo;
    if (!userInfo.contains(':')) {
      final d = _tryBase64ToString(userInfo);
      if (d != null) decodedUser = d;
    } else {
      // Some encoders url-encode the userinfo.
      decodedUser = _urlDecode(userInfo);
    }
    final colon = decodedUser.indexOf(':');
    if (colon < 0) return null;
    method = decodedUser.substring(0, colon);
    password = decodedUser.substring(colon + 1);

    final hp = _splitHostPort(hostPort);
    if (hp == null) return null;
    host = hp.$1;
    port = hp.$2;
  } else {
    // Legacy: ss://base64(method:password@host:port)
    final decoded = _tryBase64ToString(rest);
    if (decoded == null) return null;
    final at2 = decoded.lastIndexOf('@');
    if (at2 < 0) return null;
    final cred = decoded.substring(0, at2);
    final hostPort = decoded.substring(at2 + 1);
    final colon = cred.indexOf(':');
    if (colon < 0) return null;
    method = cred.substring(0, colon);
    password = cred.substring(colon + 1);
    final hp = _splitHostPort(hostPort);
    if (hp == null) return null;
    host = hp.$1;
    port = hp.$2;
  }

  if (host.isEmpty || port == null || method.isEmpty) return null;

  final out = <String, dynamic>{
    'type': 'shadowsocks',
    'server': host,
    'server_port': port,
    'method': method,
    'password': password,
    'tag': name ?? '$host:$port',
  };

  // Plugin (best effort).
  final plugin = params['plugin'];
  if (plugin != null && plugin.isNotEmpty) {
    // SIP002 plugin format: "name;opt1=val1;opt2".
    final semi = plugin.indexOf(';');
    if (semi >= 0) {
      out['plugin'] = plugin.substring(0, semi);
      out['plugin_opts'] = plugin.substring(semi + 1);
    } else {
      out['plugin'] = plugin;
    }
  }

  return out;
}

(String, int?)? _splitHostPort(String hostPort) {
  String host;
  int? port;
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) return null;
    host = hostPort.substring(1, close);
    final after = hostPort.substring(close + 1);
    if (after.startsWith(':')) port = _toInt(after.substring(1));
  } else {
    final colon = hostPort.lastIndexOf(':');
    if (colon >= 0) {
      host = hostPort.substring(0, colon);
      port = _toInt(hostPort.substring(colon + 1));
    } else {
      host = hostPort;
    }
  }
  return (host.trim(), port);
}

// ---------------------------------------------------------------------------
// hysteria2:// / hy2://
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseHysteria2(String link) {
  final scheme = link.toLowerCase().startsWith('hysteria2://')
      ? 'hysteria2'
      : 'hy2';
  final p = _parseUriStyle(link, scheme);
  if (p == null) return null;
  final password = _urlDecode(p.userInfo);

  final out = <String, dynamic>{
    'type': 'hysteria2',
    'server': p.host,
    'server_port': p.port,
    'tag': _tagFor(p),
  };
  if (password.isNotEmpty) out['password'] = password;

  // Bandwidth.
  final up = _toInt(
    p.params['up'] ?? p.params['upmbps'] ?? p.params['up_mbps'],
  );
  if (up != null) out['up_mbps'] = up;
  final down = _toInt(
    p.params['down'] ?? p.params['downmbps'] ?? p.params['down_mbps'],
  );
  if (down != null) out['down_mbps'] = down;

  // Obfs (salamander).
  final obfs = p.params['obfs'];
  final obfsPwd = p.params['obfs-password'] ?? p.params['obfs_password'];
  if (obfs != null && obfs.isNotEmpty) {
    final o = <String, dynamic>{'type': obfs};
    if (obfsPwd != null && obfsPwd.isNotEmpty) o['password'] = obfsPwd;
    out['obfs'] = o;
  }

  // TLS is always enabled for hysteria2.
  final tls = <String, dynamic>{'enabled': true};
  final sni = p.params['sni'] ?? p.params['peer'];
  tls['server_name'] = (sni != null && sni.isNotEmpty) ? sni : p.host;
  if (_isInsecure(p.params)) tls['insecure'] = true;
  final alpn = _parseAlpn(p.params['alpn']);
  if (alpn != null) tls['alpn'] = alpn;
  out['tls'] = tls;

  return out;
}

// ---------------------------------------------------------------------------
// tuic://
// ---------------------------------------------------------------------------

Map<String, dynamic>? _parseTuic(String link) {
  final p = _parseUriStyle(link, 'tuic');
  if (p == null) return null;

  // userinfo is uuid:password
  final ui = p.userInfo;
  final colon = ui.indexOf(':');
  String uuid;
  String password;
  if (colon >= 0) {
    uuid = _urlDecode(ui.substring(0, colon));
    password = _urlDecode(ui.substring(colon + 1));
  } else {
    uuid = _urlDecode(ui);
    password = '';
  }
  if (uuid.isEmpty) return null;

  final out = <String, dynamic>{
    'type': 'tuic',
    'server': p.host,
    'server_port': p.port,
    'uuid': uuid,
    'tag': _tagFor(p),
  };
  if (password.isNotEmpty) out['password'] = password;

  final cc = p.params['congestion_control'] ?? p.params['congestion'];
  if (cc != null && cc.isNotEmpty) out['congestion_control'] = cc;
  final urm = p.params['udp_relay_mode'];
  if (urm != null && urm.isNotEmpty) out['udp_relay_mode'] = urm;

  // TLS always enabled for tuic.
  final tls = <String, dynamic>{'enabled': true};
  final sni = p.params['sni'] ?? p.params['peer'];
  tls['server_name'] = (sni != null && sni.isNotEmpty) ? sni : p.host;
  final alpn = _parseAlpn(p.params['alpn']);
  if (alpn != null) tls['alpn'] = alpn;
  if (_isInsecure(p.params)) tls['insecure'] = true;
  out['tls'] = tls;

  return out;
}

bool _isInsecure(Map<String, String> params) {
  final v =
      (params['insecure'] ??
              params['allowInsecure'] ??
              params['allow_insecure'] ??
              params['skip-cert-verify'] ??
              '')
          .toLowerCase()
          .trim();
  return v == '1' || v == 'true' || v == 'yes';
}
