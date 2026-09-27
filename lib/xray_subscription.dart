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
        (decoded['outbounds'] as List).any(
            (o) => o is Map && o['protocol'] != null)) {
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
    if (entry['protocol'] == 'hysteria' || entry['protocol'] == 'hysteria2') {
      final opts = entry['settings'];
      final stream = entry['streamSettings'];
      final address = opts is Map ? opts['address']?.toString() : null;
      final port = opts is Map ? int.tryParse('${opts['port']}') : null;
      final transport = stream is Map ? stream['hysteriaSettings'] : null;
      final version = opts is Map ? int.tryParse('${opts['version']}') : null;
      final transportVersion = transport is Map
          ? int.tryParse('${transport['version']}') : null;
      final validEndpoint = address != null && address.isNotEmpty &&
          port != null && port >= 1 && port <= 65535;
      nodes.add({
        'type': 'hysteria2',
        'tag': entry['tag']?.toString() ??
            (validEndpoint ? '$address:$port' : 'Hysteria2'),
        'server': address ?? '',
        'server_port': port ?? 0,
        'transport': {'type': stream is Map
            ? stream['network']?.toString() ?? 'hysteria' : 'hysteria'},
        if (validEndpoint && version == 2 && stream is Map &&
            transportVersion == 2)
          '_xray_outbound': Map<String, dynamic>.from(entry)
            ..['protocol'] = 'hysteria'
        else
          '_unsupported_reason': 'Hysteria2: в подписке нет корректных '
              'address/port или version=2 в settings и hysteriaSettings',
      });
      continue;
    }
    if (entry['protocol'] != 'vless') {
      if (!const {'freedom', 'blackhole', 'dns'}
          .contains(entry['protocol'])) {
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
  if (routing is Map && routing['balancers'] is List) {
    for (final candidate in routing['balancers'] as List) {
      if (candidate is! Map || candidate['tag'] is! String ||
          candidate['selector'] is! List) continue;
      final selectors = (candidate['selector'] as List).map((x) => x.toString()).toList();
      final matched = <Map<String, dynamic>>[];
      for (final outbound in root['outbounds'] as List) {
        if (outbound is! Map) continue;
        final tag = outbound['tag']?.toString() ?? '';
        if (selectors.any((prefix) => tag.startsWith(prefix)) ||
            tag == candidate['fallbackTag']) {
          matched.add(Map<String, dynamic>.from(outbound));
        }
      }
      if (!matched.any((entry) => selectors.any(
          (prefix) => entry['tag']?.toString().startsWith(prefix) == true))) continue;
      final first = matched.firstWhere((entry) => selectors.any(
          (prefix) => entry['tag']?.toString().startsWith(prefix) == true));
      final vnext = (first['settings'] as Map?)?['vnext'];
      final target = vnext is List && vnext.isNotEmpty ? vnext.first : null;
      final address = target is Map ? target['address']?.toString() : null;
      final port = target is Map ? int.tryParse('${target['port']}') : null;
      final supportingTags = <String>{};
      if (candidate['fallbackTag'] is String) {
        supportingTags.add(candidate['fallbackTag'] as String);
      }
      if (routing['rules'] is List) {
        for (final rule in routing['rules'] as List) {
          if (rule is Map && rule['outboundTag'] is String) {
            supportingTags.add(rule['outboundTag'] as String);
          }
        }
      }
      for (final outbound in root['outbounds'] as List) {
        if (outbound is Map && supportingTags.contains(outbound['tag']) &&
            !matched.any((item) => item['tag'] == outbound['tag'])) {
          matched.add(Map<String, dynamic>.from(outbound));
        }
      }
      final selectedBalancer = Map<String, dynamic>.from(candidate);
      if (!matched.any((item) => item['tag'] == selectedBalancer['fallbackTag'])) {
        selectedBalancer.remove('fallbackTag');
      }
      final config = <String, dynamic>{
        'outbounds': matched,
        'routing': {
          'balancers': [selectedBalancer],
          if (routing['rules'] is List) 'rules': routing['rules'],
          if (routing['domainStrategy'] != null)
            'domainStrategy': routing['domainStrategy'],
          if (routing['domainMatcher'] != null)
            'domainMatcher': routing['domainMatcher'],
        },
        if (root['dns'] is Map) 'dns': root['dns'],
        if (root['burstObservatory'] is Map)
          'burstObservatory': root['burstObservatory'],
        if (root['observatory'] is Map) 'observatory': root['observatory'],
      };
      nodes.insert(0, {
        'type': 'auto',
        'tag': root['remarks']?.toString() ?? candidate['tag'].toString(),
        if (address != null) 'server': address,
        if (port != null) 'server_port': port,
        '_xray_template': config,
      });
    }
    if (nodes.isEmpty && root['remnawave'] is Map) {
      notices.add('injectHosts заполняется панелью Remnawave. '
          'Импортируйте ссылку на выданную подписку с готовыми серверами.');
    }
  }
  if (skippedGeo) notices.add('Часть правил geosite/geoip не перенесена.');
  return XrayTemplate(root['remarks']?.toString(), nodes, directRules,
      notices.isEmpty ? null : notices.join(' '));
}
