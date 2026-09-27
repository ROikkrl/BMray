import 'dart:convert';

import 'xray_bridge.dart';

bool isLocalTemplateHost(Map<String, dynamic> node) =>
    node['server'] == '127.0.0.1' || node['server'] == '::1' ||
    node['server'] == 'localhost';

/// The subscription contains links, while Remnawave keeps injectHosts in a
/// separate server-side template. This binds a pasted template to one host.
Map<String, dynamic> injectRemnawaveTemplate(
    String source, List<Map<String, dynamic>> nodes, String hostTag) {
  final decoded = jsonDecode(source);
  if (decoded is! Map || decoded['remnawave'] is! Map ||
      (decoded['remnawave'] as Map)['injectHosts'] is! List ||
      decoded['routing'] is! Map ||
      (decoded['routing'] as Map)['balancers'] is! List) {
    throw const FormatException('Нужен Xray JSON шаблон Remnawave с injectHosts и balancers.');
  }
  final hostIndex = nodes.indexWhere((node) =>
      node['tag'] == hostTag && isLocalTemplateHost(node));
  if (hostIndex < 0) {
    throw const FormatException('Локальный хост АвтоБС отсутствует в подписке.');
  }
  final injected = <Map<String, dynamic>>[];
  final missing = <String>[];
  for (final rule in (decoded['remnawave'] as Map)['injectHosts'] as List) {
    if (rule is! Map || rule['selector'] is! Map ||
        (rule['selector'] as Map)['type'] != 'remarkRegex') continue;
    final prefix = rule['tagPrefix']?.toString() ?? '';
    final pattern = (rule['selector'] as Map)['pattern']?.toString() ?? '';
    if (prefix.isEmpty || pattern.isEmpty) continue;
    final matcher = RegExp(pattern, caseSensitive: false);
    final matching = nodes.where((node) =>
        !isLocalTemplateHost(node) && node['type'] == 'vless' &&
        matcher.hasMatch(node['tag']?.toString() ?? '')).toList();
    if (matching.isEmpty) missing.add(prefix);
    for (var i = 0; i < matching.length; i++) {
      final outbound = xrayOutboundFromNode(matching[i]);
      outbound['tag'] = i == 0 ? prefix : '$prefix-${i + 1}';
      injected.add(outbound);
    }
  }
  final routing = jsonDecode(jsonEncode(decoded['routing'])) as Map<String, dynamic>;
  final balancers = routing['balancers'] as List;
  for (final balancer in balancers.whereType<Map>()) {
    final prefixes = balancer['selector'] is List
        ? (balancer['selector'] as List).map((e) => e.toString()) : <String>[];
    if (!injected.any((outbound) => prefixes.any(
        (prefix) => outbound['tag'].toString().startsWith(prefix)))) {
      throw const FormatException('Шаблон не нашёл основных серверов по remarkRegex.');
    }
    if (!injected.any((outbound) => outbound['tag'] == balancer['fallbackTag'])) {
      balancer.remove('fallbackTag');
    }
  }
  final baseOutbounds = decoded['outbounds'] is List
      ? (decoded['outbounds'] as List).whereType<Map>().where((outbound) =>
          outbound['protocol'] == 'freedom' || outbound['protocol'] == 'blackhole')
          .map((outbound) => Map<String, dynamic>.from(outbound)).toList()
      : <Map<String, dynamic>>[];
  if (!baseOutbounds.any((outbound) => outbound['tag'] == 'direct')) {
    baseOutbounds.add({'tag': 'direct', 'protocol': 'freedom'});
  }
  final host = Map<String, dynamic>.from(nodes[hostIndex]);
  host['type'] = 'auto';
  host.remove('_unsupported_reason');
  host['_xray_template'] = {
    'outbounds': [...injected, ...baseOutbounds],
    'routing': routing,
    if (decoded['dns'] is Map) 'dns': decoded['dns'],
    if (decoded['burstObservatory'] is Map)
      'burstObservatory': decoded['burstObservatory'],
  };
  if (missing.isNotEmpty) {
    host['_template_warning'] = 'В подписке не найдены: ${missing.join(', ')}. '
        'Скрытые хосты панель не передала; отсутствующий fallback отключён.';
  }
  return host;
}
