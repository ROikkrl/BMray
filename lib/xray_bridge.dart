import 'dart:convert';
import 'dart:math';

import 'package:vpn_plugin/src/singbox_config.dart';

/// One Xray process per tunnel/probe. SOCKS credentials guard the loopback port.
class XrayBridge {
  const XrayBridge(this.singbox, this.xray);
  final Map<String, dynamic> singbox;
  final Map<String, dynamic> xray;
}

bool usesXray(Map<String, dynamic> node) =>
    node['_xray_template'] is Map ||
    (node['type'] == 'hysteria2' && node['_xray_outbound'] is Map) ||
    (node['type'] == 'vless' && node['transport'] is Map &&
    (node['transport'] as Map)['type'] == 'xhttp');

XrayBridge buildXrayBridge(Map<String, dynamic> node, {
  bool probe = false,
  String? probeOutboundTag,
  SingboxConfigOptions options = const SingboxConfigOptions(),
}) {
  if (!usesXray(node)) throw const FormatException('Ожидался профиль Xray');
  final random = Random.secure();
  final port = 20000 + random.nextInt(35000);
  final user = 'bmray';
  final password = List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final template = node['_xray_template'];
  final raw = node['_xray_outbound'];
  final outbound = template is Map ? <String, dynamic>{} : raw is Map
      ? jsonDecode(jsonEncode(raw)) as Map<String, dynamic>
      : _toXrayOutbound(node);
  if (template is! Map) outbound['tag'] = 'proxy';
  final templateOutbounds = template is Map
      ? jsonDecode(jsonEncode(template['outbounds'])) as List
      : null;
  // Xray requires the VLESS encryption field even in older client templates.
  for (final entry in templateOutbounds ?? [outbound]) {
    final settings = entry is Map ? entry['settings'] : null;
    final servers = settings is Map ? settings['vnext'] : null;
    if (servers is List) {
      for (final server in servers) {
        final users = server is Map ? server['users'] : null;
        if (users is List) {
          for (final user in users) {
            if (user is Map) user['encryption'] ??= 'none';
          }
        }
      }
    }
  }
  final xray = <String, dynamic>{
    'log': {'loglevel': 'warning'},
    if (template is Map && template['dns'] is Map)
      'dns': template['dns'],
    'inbounds': [{
      'tag': 'local-socks', 'listen': '127.0.0.1', 'port': port,
      'protocol': 'socks',
      'settings': {'auth': 'password', 'users': [{'user': user, 'pass': password}], 'udp': true},
      'sniffing': {'enabled': true, 'routeOnly': true,
        'destOverride': ['http', 'tls', 'quic']},
    }],
    'outbounds': templateOutbounds ?? [outbound, {'tag': 'direct', 'protocol': 'freedom'}],
    if (template is Map) 'routing': probeOutboundTag == null
        ? _autoRouting(template)
        : {'rules': [{'type': 'field', 'network': 'tcp,udp',
            'outboundTag': probeOutboundTag}]},
    if (template is Map && probeOutboundTag == null &&
        template['burstObservatory'] is Map)
      'burstObservatory': template['burstObservatory'],
    if (template is Map && probeOutboundTag == null &&
        template['observatory'] is Map)
      'observatory': template['observatory'],
  };
  final socks = <String, dynamic>{
    'type': 'socks', 'tag': 'proxy', 'server': '127.0.0.1',
    'server_port': port, 'username': user, 'password': password,
  };
  final singbox = buildSingboxConfig(socks, options: options);
  // The SOCKS endpoint is loopback. Binding its socket to wlan0/rmnet would
  // make it unreachable; the app UID is already excluded from this VPN.
  (singbox['route'] as Map)['auto_detect_interface'] = false;
  if (probe) singbox['inbounds'] = <Object>[];
  return XrayBridge(singbox, xray);
}

Map<String, dynamic> _autoRouting(Map template) {
  final source = template['routing'] as Map;
  final balancers = source['balancers'] as List;
  final tag = (balancers.first as Map)['tag'];
  final available = (template['outbounds'] as List)
      .whereType<Map>().map((item) => item['tag']).toSet();
  final rules = <Map<String, dynamic>>[];
  if (source['rules'] is List) {
    for (final original in source['rules'] as List) {
      if (original is! Map || original['type'] != 'field') continue;
      if (original['outboundTag'] != null &&
          !available.contains(original['outboundTag'])) continue;
      if (original['balancerTag'] != null && original['balancerTag'] != tag) continue;
      final inboundTags = original['inboundTag'];
      if (inboundTags is List &&
          !inboundTags.any((value) => value == 'socks' ||
              value == 'http' || value == 'local-socks')) continue;
      final rule = Map<String, dynamic>.from(original)..remove('inboundTag');
      if (rule['domain'] is List) {
        final domains = (rule['domain'] as List).where((value) =>
            !value.toString().startsWith('geosite:')).toList();
        if (domains.isEmpty) rule.remove('domain');
        else rule['domain'] = domains;
      }
      if (rule['ip'] is List) {
        final ips = <String>[];
        for (final value in rule['ip'] as List) {
          if (value == 'geoip:private') {
            ips.addAll(['10.0.0.0/8', '172.16.0.0/12',
              '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16',
              'fc00::/7', 'fe80::/10', '::1/128']);
          } else if (!value.toString().startsWith('geoip:')) {
            ips.add(value.toString());
          }
        }
        if (ips.isEmpty) rule.remove('ip');
        else rule['ip'] = ips;
      }
      // A geo-only rule must not turn into an unconditional direct rule.
      if (!rule.containsKey('domain') && !rule.containsKey('ip') &&
          !rule.containsKey('network') && !rule.containsKey('port') &&
          !rule.containsKey('protocol')) continue;
      rules.add(rule);
    }
  }
  // SOCKS traffic must always have a route, even for older stored templates.
  if (!rules.any((rule) => rule['balancerTag'] == tag &&
      rule['network'] == 'tcp,udp')) {
    rules.add({'type': 'field', 'network': 'tcp,udp', 'balancerTag': tag});
  }
  return {
    'rules': rules,
    'balancers': balancers,
    if (source['domainStrategy'] != null)
      'domainStrategy': source['domainStrategy'],
    if (source['domainMatcher'] != null)
      'domainMatcher': source['domainMatcher'],
  };
}

Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
  final transport = node['transport'] as Map;
  final tls = node['tls'] as Map?;
  final sni = tls?['server_name']?.toString();
  final transportHost = transport['host']?.toString();
  final serverName = sni != null && sni.isNotEmpty ? sni
      : transportHost != null && transportHost.isNotEmpty ? transportHost
      : node['server'];
  final reality = tls?['reality'] as Map?;
  final xhttp = <String, dynamic>{
    if (transport['path'] != null) 'path': transport['path'],
    if (transport['host'] != null) 'host': transport['host'],
    'mode': transport['mode'] ?? 'auto',
    if (transport['extra'] is Map) 'extra': transport['extra'],
  };
  final security = reality != null ? 'reality' : tls == null ? 'none' : 'tls';
  final fp = (tls?['utls'] as Map?)?['fingerprint'];
  final stream = <String, dynamic>{
    'network': 'xhttp', 'security': security,
    'xhttpSettings': xhttp,
    if (security == 'reality') 'realitySettings': {
      'serverName': serverName,
      'publicKey': reality?['public_key'],
      'shortId': reality?['short_id'] ?? '',
      if (reality?['spider_x'] != null) 'spiderX': reality?['spider_x'],
      'fingerprint': fp ?? 'chrome',
    },
    if (security == 'tls') 'tlsSettings': {
      'serverName': serverName,
      if (fp != null) 'fingerprint': fp,
      if (tls?['alpn'] is List) 'alpn': tls?['alpn'],
      if (tls?['insecure'] == true) 'allowInsecure': true,
    },
  };
  return {
    'tag': 'proxy', 'protocol': 'vless',
    'settings': {'vnext': [{
      'address': node['server'], 'port': node['server_port'],
      'users': [{
        'id': node['uuid'], 'encryption': 'none',
        if (node['flow']?.toString().isNotEmpty == true) 'flow': node['flow'],
      }],
    }]},
    'streamSettings': stream,
  };
}
