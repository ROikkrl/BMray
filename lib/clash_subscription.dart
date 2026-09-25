import 'package:yaml/yaml.dart';

/// Converts common Clash/Mihomo proxy records to sing-box outbounds.
/// Unsupported node types are skipped; the app reports an error if none remain.
List<Map<String, dynamic>> parseClashSubscription(String content,
    {bool includeUnsupported = false}) {
  final root = loadYaml(content);
  if (root is! Map || root['proxies'] is! List) return [];
  final converted = <Map<String, dynamic>>[];
  for (final raw in root['proxies'] as List) {
    if (raw is! Map) continue;
    final node = convertClashNode(raw, includeUnsupported: includeUnsupported);
    if (node != null) converted.add(node);
  }
  return converted;
}

Map<String, dynamic>? convertClashNode(Map raw, {bool includeUnsupported = false}) {
  final type = raw['type']?.toString().toLowerCase();
  final host = raw['server']?.toString();
  final port = int.tryParse(raw['port']?.toString() ?? '');
  if (host == null || host.isEmpty || port == null || port < 1 || port > 65535)
    return null;
  final result = <String, dynamic>{
    'type': type == 'ss'
        ? 'shadowsocks'
        : type == 'hy2'
        ? 'hysteria2'
        : type,
    'tag': raw['name']?.toString() ?? '$host:$port',
    'server': host,
    'server_port': port,
  };
  switch (type) {
    case 'vless':
    case 'vmess':
      final uuid = raw['uuid']?.toString();
      if (uuid == null || uuid.isEmpty) return null;
      result['uuid'] = uuid;
      if (type == 'vless') {
        if (_nonempty(raw['flow'])) result['flow'] = raw['flow'].toString();
      } else {
        result['security'] = raw['cipher']?.toString() ?? 'auto';
        result['alter_id'] =
            int.tryParse(raw['alterId']?.toString() ?? '0') ?? 0;
      }
      break;
    case 'trojan':
    case 'hysteria2':
    case 'hy2':
      if (!_nonempty(raw['password'])) return null;
      result['password'] = raw['password'].toString();
      break;
    case 'ss':
      if (!_nonempty(raw['cipher']) || !_nonempty(raw['password'])) return null;
      result['method'] = raw['cipher'].toString();
      result['password'] = raw['password'].toString();
      break;
    case 'tuic':
      if (!_nonempty(raw['uuid']) || !_nonempty(raw['password'])) return null;
      result['uuid'] = raw['uuid'].toString();
      result['password'] = raw['password'].toString();
      break;
    default:
      return null;
  }

  final reality = raw['reality-opts'];
  final tlsEnabled =
      raw['tls'] == true ||
      type == 'trojan' ||
      type == 'hysteria2' ||
      type == 'hy2' ||
      type == 'tuic' ||
      reality is Map;
  if (tlsEnabled) {
    final tls = <String, dynamic>{'enabled': true};
    final sni = raw['servername'] ?? raw['sni'];
    if (_nonempty(sni)) tls['server_name'] = sni.toString();
    if (raw['skip-cert-verify'] == true) tls['insecure'] = true;
    if (raw['alpn'] is List)
      tls['alpn'] = List<String>.from(
        (raw['alpn'] as List).map((e) => e.toString()),
      );
    if (reality is Map && _nonempty(reality['public-key'])) {
      tls['reality'] = {
        'enabled': true,
        'public_key': reality['public-key'].toString(),
        if (_nonempty(reality['short-id']))
          'short_id': reality['short-id'].toString(),
      };
    }
    if (_nonempty(raw['client-fingerprint']) || tls.containsKey('reality')) {
      tls['utls'] = {
        'enabled': true,
        'fingerprint': _nonempty(raw['client-fingerprint'])
            ? raw['client-fingerprint'].toString()
            : 'chrome',
      };
    }
    result['tls'] = tls;
  }

  final network = raw['network']?.toString().toLowerCase();
  if (network == 'ws') {
    final ws = raw['ws-opts'];
    final transport = <String, dynamic>{'type': 'ws'};
    if (ws is Map) {
      if (_nonempty(ws['path'])) transport['path'] = ws['path'].toString();
      if (ws['headers'] is Map) {
        transport['headers'] = Map<String, String>.fromEntries(
          (ws['headers'] as Map).entries.map(
            (e) => MapEntry(e.key.toString(), e.value.toString()),
          ),
        );
      }
    }
    result['transport'] = transport;
  } else if (network == 'grpc') {
    final grpc = raw['grpc-opts'];
    result['transport'] = {
      'type': 'grpc',
      if (grpc is Map && _nonempty(grpc['grpc-service-name']))
        'service_name': grpc['grpc-service-name'].toString(),
    };
  } else if (network == 'xhttp') {
    if (!includeUnsupported) return null;
    result['_unsupported_reason'] = 'XHTTP требует ядро Xray';
  } else if (network != null && network != 'tcp' && network.isNotEmpty) {
    return null;
  }
  return result;
}

bool _nonempty(Object? value) => value != null && value.toString().isNotEmpty;
