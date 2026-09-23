// Pure-Dart sing-box (v1.13) config builder.
//
// Takes a single proxy OUTBOUND json object (as produced by
// share_link_parser.dart) and wraps it in a complete, validatable sing-box
// configuration: log, dns, one tun inbound, a route block, and outbounds.
//
// No Flutter / package imports — only dart:convert.

import 'dart:convert';

/// Tunable options for the generated config.
class SingboxConfigOptions {
  /// TUN MTU. Default 9000.
  final int mtu;

  /// Whether to assign an IPv6 address to the TUN interface and resolve AAAA.
  final bool enableIpv6;

  /// sing-box log level (trace/debug/info/warn/error/fatal/panic). Default 'info'.
  final String logLevel;

  /// When true, traffic to private/LAN IPs is allowed through the tunnel
  /// (routed to "proxy" via the final rule) instead of being sent direct.
  final bool allowLan;

  /// Routing mode:
  ///  - 'global': everything (except LAN) → proxy.
  ///  - 'rule':   smart — China (geoip-cn / geosite-cn) + LAN → direct, rest → proxy.
  ///  - 'direct': everything → direct (proxy off).
  final String routeMode;

  const SingboxConfigOptions({
    this.mtu = 9000,
    this.enableIpv6 = false,
    this.logLevel = 'info',
    this.allowLan = false,
    this.routeMode = 'global',
  });
}

/// Build a COMPLETE sing-box config (v1.13) for one selected proxy outbound.
///
/// The given [outbound] is cloned (never mutated) and its "tag" is forced to
/// "proxy". The result contains:
///  - log;
///  - dns (remote DoH via detour "proxy" + local DoH via "direct", with a dns
///    rule resolving the proxy server name via "local" to avoid a loop, final
///    remote);
///  - one tun inbound (auto_route, strict_route, gvisor stack, mtu from
///    options, inet4 address always + inet6 only when enableIpv6);
///  - a route block (auto_detect_interface; rules: sniff; dns -> hijack-dns;
///    ip_is_private -> direct unless allowLan; final "proxy");
///  - outbounds: the proxy outbound (tag "proxy") + a direct outbound.
Map<String, dynamic> buildSingboxConfig(
  Map<String, dynamic> outbound, {
  SingboxConfigOptions options = const SingboxConfigOptions(),
}) {
  // Deep clone so we never mutate the caller's map, then force the tag.
  final proxy = _deepClone(outbound);
  proxy['tag'] = 'proxy';

  final serverName = _extractServerName(proxy);

  return <String, dynamic>{
    'log': _buildLog(options),
    'dns': _buildDns(serverName, options),
    'inbounds': [_buildTun(options)],
    'outbounds': [
      proxy,
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': _buildRoute(options),
  };
}

/// Same as [buildSingboxConfig] but returns pretty-printed JSON.
String buildSingboxConfigJson(
  Map<String, dynamic> outbound, {
  SingboxConfigOptions options = const SingboxConfigOptions(),
}) {
  final config = buildSingboxConfig(outbound, options: options);
  return const JsonEncoder.withIndent('  ').convert(config);
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

Map<String, dynamic> _buildLog(SingboxConfigOptions options) {
  return <String, dynamic>{'level': options.logLevel, 'timestamp': true};
}

Map<String, dynamic> _buildDns(
  String? serverName,
  SingboxConfigOptions options,
) {
  // Typed DNS servers (v1.12+ schema). Remote resolves via the proxy; local
  // resolves via direct so the proxy server's own name does not loop.
  final servers = <Map<String, dynamic>>[
    {'type': 'https', 'tag': 'remote', 'server': '1.1.1.1', 'detour': 'proxy'},
    {
      // No `detour` here: sing-box 1.13 rejects detour-to-empty-direct-outbound.
      // With no detour the query dials directly by default, which is exactly
      // what bootstraps the proxy server's own name without looping.
      'type': 'https',
      'tag': 'local',
      'server': '223.5.5.5',
    },
  ];

  final rules = <Map<String, dynamic>>[];
  // Resolve the proxy server's own hostname using the local (direct) resolver
  // to avoid a chicken-and-egg loop. Only meaningful when the server is a
  // domain (not a literal IP).
  if (serverName != null && serverName.isNotEmpty && _isDomain(serverName)) {
    rules.add({
      'domain': [serverName],
      'action': 'route',
      'server': 'local',
    });
  }
  // Smart mode: resolve China domains via the local (direct, Chinese) resolver.
  if (options.routeMode == 'rule') {
    rules.add({
      'rule_set': ['geosite-cn'],
      'action': 'route',
      'server': 'local',
    });
  }

  final dns = <String, dynamic>{
    'servers': servers,
    'final': options.routeMode == 'direct' ? 'local' : 'remote',
    'strategy': options.enableIpv6 ? 'prefer_ipv4' : 'ipv4_only',
  };
  if (rules.isNotEmpty) dns['rules'] = rules;
  return dns;
}

Map<String, dynamic> _buildTun(SingboxConfigOptions options) {
  // Combined "address" list (v1.12+). inet4 always; inet6 only when enabled.
  final addresses = <String>['172.19.0.1/30'];
  if (options.enableIpv6) {
    addresses.add('fdfe:dcba:9876::1/126');
  }

  final tun = <String, dynamic>{
    'type': 'tun',
    'tag': 'tun-in',
    'address': addresses,
    'mtu': options.mtu,
    'auto_route': true,
    'strict_route': true,
    'stack': 'gvisor',
  };

  // When allowing LAN, listen on all interfaces for the tunnel; sniffing/route
  // handling is done in the route block.
  return tun;
}

Map<String, dynamic> _buildRoute(SingboxConfigOptions options) {
  final mode = options.routeMode;
  final rules = <Map<String, dynamic>>[
    // Sniff protocol/destination for all connections.
    {'action': 'sniff'},
    // Hijack DNS queries to the configured DNS module.
    {'protocol': 'dns', 'action': 'hijack-dns'},
  ];

  // Private/LAN traffic: send direct unless allowLan is set (then it falls
  // through to the final outbound).
  if (!options.allowLan) {
    rules.add({'ip_is_private': true, 'action': 'route', 'outbound': 'direct'});
  }

  // Smart mode: China IPs/domains go direct, everything else falls to "proxy".
  if (mode == 'rule') {
    rules.add({
      'rule_set': ['geoip-cn', 'geosite-cn'],
      'action': 'route',
      'outbound': 'direct',
    });
  }

  final route = <String, dynamic>{
    'auto_detect_interface': true,
    // Required by sing-box 1.12+: resolve the outbound server's DOMAIN via the
    // local (direct) DoH so the proxy can be dialed. Without this, runtime
    // dialing fails with "domain resolver not found" — even though `check`
    // only emits a deprecation warning. This is what lets domain-based nodes
    // actually connect on device.
    'default_domain_resolver': 'local',
    'rules': rules,
    'final': mode == 'direct' ? 'direct' : 'proxy',
  };
  if (mode == 'rule') {
    route['rule_set'] = _buildRuleSets();
  }
  return route;
}

/// China geoip/geosite rule sets (official sing-box rule-set, downloaded
/// through the proxy on first connect). Only used in 'rule' mode.
List<Map<String, dynamic>> _buildRuleSets() => [
  {
    'type': 'remote',
    'tag': 'geoip-cn',
    'format': 'binary',
    'url':
        'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',
    'download_detour': 'proxy',
  },
  {
    'type': 'remote',
    'tag': 'geosite-cn',
    'format': 'binary',
    'url': 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',
    'download_detour': 'proxy',
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The outbound's *dialed* host — the only name resolved before the TCP dial,
/// and therefore the one the loop-avoidance DNS rule must key on. NEVER the TLS
/// server_name (SNI): the SNI is never DNS-resolved, and for reality /
/// domain-fronting it differs from the real server, so keying on it would leave
/// the real server resolving via the proxy detour → resolve-loop → no connect.
String? _extractServerName(Map<String, dynamic> outbound) {
  final server = outbound['server'];
  if (server is String && server.trim().isNotEmpty) return server.trim();
  return null;
}

/// True when [host] is a domain name (not an IPv4/IPv6 literal).
bool _isDomain(String host) {
  if (host.isEmpty) return false;
  // IPv6 literal (may be bracketed or contain ':').
  if (host.contains(':')) return false;
  // IPv4 literal: all dot-separated segments are numeric.
  final parts = host.split('.');
  if (parts.length == 4 &&
      parts.every((p) {
        final n = int.tryParse(p);
        return n != null && n >= 0 && n <= 255;
      })) {
    return false;
  }
  return true;
}

/// Deep-clone a JSON-compatible map (so the caller's object is never mutated).
Map<String, dynamic> _deepClone(Map<String, dynamic> input) {
  return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
}
