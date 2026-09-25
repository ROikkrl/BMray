import 'dart:convert';
import 'dart:math';

import 'package:vpn_plugin/vpn_plugin.dart';

/// One Xray process per tunnel/probe. SOCKS credentials guard the loopback port.
class XrayBridge {
  const XrayBridge(this.singbox, this.xray);
  final Map<String, dynamic> singbox;
  final Map<String, dynamic> xray;
}

bool usesXray(Map<String, dynamic> node) =>
    node['type'] == 'vless' && node['transport'] is Map &&
    (node['transport'] as Map)['type'] == 'xhttp';

XrayBridge buildXrayBridge(Map<String, dynamic> node, {
  bool probe = false,
  SingboxConfigOptions options = const SingboxConfigOptions(),
}) {
  if (!usesXray(node)) throw const FormatException('Ожидался VLESS XHTTP');
  final random = Random.secure();
  final port = 20000 + random.nextInt(35000);
  final user = 'bmray';
  final password = List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final raw = node['_xray_outbound'];
  final outbound = raw is Map
      ? jsonDecode(jsonEncode(raw)) as Map<String, dynamic>
      : _toXrayOutbound(node);
  outbound['tag'] = 'proxy';
  final xray = <String, dynamic>{
    'log': {'loglevel': 'warning'},
    'inbounds': [{
      'tag': 'local-socks', 'listen': '127.0.0.1', 'port': port,
      'protocol': 'socks',
      'settings': {'auth': 'password', 'users': [{'user': user, 'pass': password}], 'udp': true},
    }],
    'outbounds': [outbound, {'tag': 'direct', 'protocol': 'freedom'}],
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
