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
    final servers = entry is Map ? (entry['settings'] as Map?)?['vnext'] : null;
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
    'inbounds': [{
      'tag': 'local-socks', 'listen': '127.0.0.1', 'port': port,
      'protocol': 'socks',
      'settings': {'auth': 'password', 'users': [{'user': user, 'pass': password}], 'udp': true},
    }],
    'outbounds': templateOutbounds ?? [outbound, {'tag': 'direct', 'protocol': 'freedom'}],
    if (template is Map) 'routing': {
      'rules': [{
        'type': 'field', 'network': 'tcp,udp',
        'balancerTag': (template['routing'] as Map)['balancers'][0]['tag'],
      }],
      'balancers': (template['routing'] as Map)['balancers'],
    },
    if (template is Map && template['burstObservatory'] is Map)
      'burstObservatory': template['burstObservatory'],
    if (template is Map && template['observatory'] is Map)
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

Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
  final transport = node['transport'] as Map;
  final tls = node['tls'] as Map?;
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
      'serverName': tls?['server_name'] ?? node['server'],
      'publicKey': reality?['public_key'],
      'shortId': reality?['short_id'] ?? '',
      if (reality?['spider_x'] != null) 'spiderX': reality?['spider_x'],
      'fingerprint': fp ?? 'chrome',
    },
    if (security == 'tls') 'tlsSettings': {
      'serverName': tls?['server_name'] ?? node['server'],
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
