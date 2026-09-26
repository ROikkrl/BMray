import 'dart:convert';

/// Client outbounds from an Xray template. XHTTP uses the Android Xray bridge.
class XrayTemplate {
  const XrayTemplate(this.name, this.nodes, this.directRules, this.notice);

  final String? name;
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> directRules;
  final String? notice;
}

XrayTemplate? parseXrayTemplate(String content) {
  Map? root;
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map && decoded['outbounds'] is List &&
        (decoded['routing'] is Map ||
            (decoded['outbounds'] as List).any((o) => o is Map && o['protocol'] != null))) {
      root = decoded;
    }
  } on FormatException {
    return null;
  }
  if (root == null) return null;

  final nodes = <Map<String, dynamic>>[];
  final unsupported = <String>{};
  for (final entry in root['outbounds'] as List) {
    if (entry is! Map) continue;
    if (entry['protocol'] == 'hysteria') {
      final opts = entry['settings'];
      final stream = entry['streamSettings'];
      final address = opts is Map ? opts['address']?.toString() : null;
      final port = opts is Map ? int.tryParse('${opts['port']}') : null;
      if (opts is Map && opts['version'] == 2 && stream is Map &&
          address != null && address.isNotEmpty &&
          port != null && port >= 1 && port <= 65535) {
        nodes.add({
          'type': 'hysteria2',
          'tag': entry['tag']?.toString() ?? '$address:$port',
          'server': address,
          'server_port': port,
          'transport': {'type': stream['network']?.toString() ?? 'hysteria'},
          '_xray_outbound': Map<String, dynamic>.from(entry),
        });
      }
      continue;
    }
    if (entry['protocol'] != 'vless') {
      if (entry['protocol'] != 'freedom' && entry['protocol'] != 'blackhole') {
        unsupported.add(entry['protocol']?.toString() ?? 'unknown');
      }
      continue;
    }
    final vnext = (entry['settings'] as Map?)?['vnext'];
    final server = vnext is List && vnext.isNotEmpty ? vnext.first : null;
    final users = server is Map ? server['users'] : null;
    final user = users is List && users.isNotEmpty ? users.first : null;
    final settings = entry['streamSettings'];
    if (server is! Map || user is! Map || settings is! Map) continue;
    final network = (settings['network'] ?? 'tcp').toString().toLowerCase();
    final host = server['address']?.toString() ?? '';
    final port = int.tryParse('${server['port']}');
    final uuid = user['id']?.toString() ?? '';
    if (host.isEmpty || port == null || port < 1 || port > 65535 || uuid.isEmpty) continue;
    final node = <String, dynamic>{
      'type': 'vless',
      'tag': entry['tag']?.toString() ?? '$host:$port',
      'server': host,
      'server_port': port,
      'uuid': uuid,
    };
    if (network == 'xhttp') {
      node['transport'] = {
        'type': 'xhttp',
        ...?((settings['xhttpSettings'] as Map?)?.cast<String, dynamic>()),
      };
      node['_xray_outbound'] = Map<String, dynamic>.from(entry);
      nodes.add(node);
      continue;
    }
    if (network == 'grpc') {
      final grpc = settings['grpcSettings'];
      node['transport'] = {
        'type': 'grpc',
        if (grpc is Map && grpc['serviceName']?.toString().isNotEmpty == true)
          'service_name': grpc['serviceName'].toString(),
      };
    } else if (network != 'tcp') {
      node['_unsupported_reason'] = '$network требует ядро Xray';
      nodes.add(node);
      unsupported.add(network);
      continue;
    }
    final flow = user['flow']?.toString();
    if (flow != null && flow.isNotEmpty) node['flow'] = flow;
    final security = settings['security']?.toString().toLowerCase();
    if (security == 'reality' || security == 'tls') {
      final opts = security == 'reality'
          ? settings['realitySettings'] as Map? : settings['tlsSettings'] as Map?;
      if (opts == null) continue;
      final tls = <String, dynamic>{'enabled': true};
      final sni = opts['serverName']?.toString();
      tls['server_name'] = sni == null || sni.isEmpty ? host : sni;
      final fp = opts['fingerprint']?.toString();
      if (fp != null && fp.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fp};
      }
      if (opts['alpn'] is List) tls['alpn'] = (opts['alpn'] as List).map((x) => x.toString()).toList();
      if (security == 'reality') {
        final key = opts['publicKey']?.toString() ?? '';
        if (key.isEmpty) continue;
        tls['reality'] = {
          'enabled': true,
          'public_key': key,
          if (opts['shortId']?.toString().isNotEmpty == true) 'short_id': opts['shortId'].toString(),
        };
        tls['utls'] ??= {'enabled': true, 'fingerprint': 'chrome'};
      }
      node['tls'] = tls;
    } else if (security != null && security != '' && security != 'none') {
      unsupported.add(security);
      continue;
    }
    nodes.add(node);
  }

  final directRules = <Map<String, dynamic>>[];
  final routing = root['routing'];
  var skippedGeo = false;
  if (routing is Map && routing['rules'] is List) {
    for (final entry in routing['rules'] as List) {
      if (entry is! Map || entry['outboundTag'] != 'direct') continue;
      final suffixes = <String>[];
      final exact = <String>[];
      final regexes = <String>[];
      for (final value in (entry['domain'] is List ? entry['domain'] as List : const [])) {
        final text = value.toString();
        if (text.startsWith('domain:')) suffixes.add(text.substring(7));
        else if (text.startsWith('full:')) exact.add(text.substring(5));
        else if (text.startsWith('regexp:')) regexes.add(text.substring(7));
        else skippedGeo = true;
      }
      if (suffixes.isNotEmpty || exact.isNotEmpty || regexes.isNotEmpty) {
        directRules.add({
          if (suffixes.isNotEmpty) 'domain_suffix': suffixes,
          if (exact.isNotEmpty) 'domain': exact,
          if (regexes.isNotEmpty) 'domain_regex': regexes,
          'action': 'route', 'outbound': 'direct',
        });
      }
      final addresses = <String>[];
      for (final value in (entry['ip'] is List ? entry['ip'] as List : const [])) {
        final text = value.toString();
        if (RegExp(r'^[0-9a-fA-F.:]+/[0-9]+$').hasMatch(text)) addresses.add(text);
        else if (text != 'geoip:private') skippedGeo = true;
      }
      if (addresses.isNotEmpty) {
        directRules.add({'ip_cidr': addresses, 'action': 'route', 'outbound': 'direct'});
      }
    }
  }
  final notices = <String>[];
  if (unsupported.isNotEmpty) {
    notices.add('Серверы ${unsupported.join(', ')} требуют другого транспорта.');
  }
  if (routing is Map && routing['balancers'] is List && (routing['balancers'] as List).isNotEmpty) {
    notices.add('Автоматический балансировщик Xray не перенесён; выберите доступный сервер вручную.');
  }
  if (skippedGeo) notices.add('Часть правил geosite/geoip не перенесена.');
  return XrayTemplate(root['remarks']?.toString(), nodes, directRules,
      notices.isEmpty ? null : notices.join(' '));
}
