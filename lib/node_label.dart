/// A compact description of the selected proxy's protocol and wire transport.
/// Never guess REALITY from the display name: use the imported security fields.
String nodeLabel(Map<String, dynamic> node) {
  final type = node['type']?.toString().toLowerCase() ?? '';
  if (type == 'auto') {
    final origin = node['_origin_node'];
    if (origin is Map && origin['type'] != 'auto') {
      return nodeLabel(Map<String, dynamic>.from(origin));
    }
    final template = node['_xray_template'];
    final outbounds = template is Map ? template['outbounds'] : null;
    if (outbounds is List) {
      for (final outbound in outbounds) {
        if (outbound is! Map || outbound['protocol'] != 'vless') continue;
        final stream = outbound['streamSettings'];
        if (stream is Map) return nodeLabel({
          'type': 'vless', '_xray_outbound': outbound,
        });
      }
    }
    return 'VLESS / XHTTP / TLS';
  }
  final raw = node['_xray_outbound'];
  final stream = raw is Map ? raw['streamSettings'] : null;
  final transport = node['transport'];
  final net = (transport is Map ? transport['type'] : null) ??
      (stream is Map ? stream['network'] : null);
  final tls = node['tls'];
  final security = stream is Map ? stream['security']?.toString().toLowerCase() : null;

  final protocol = switch (type) {
    'hysteria2' || 'hy2' => 'HYSTERIA2',
    'shadowsocks' => 'SHADOWSOCKS',
    '' => 'ПРОКСИ',
    _ => type.toUpperCase(),
  };
  final network = switch (net?.toString().toLowerCase()) {
    'ws' || 'websocket' => 'WS',
    'grpc' => 'GRPC',
    'xhttp' => 'XHTTP',
    'httpupgrade' => 'HTTPUPGRADE',
    'hysteria' => 'HYSTERIA',
    'quic' => 'QUIC',
    null || '' => type == 'hysteria2' ? 'QUIC' : 'TCP',
    final value => value.toUpperCase(),
  };
  final protection = (tls is Map && tls['reality'] is Map) || security == 'reality'
      ? 'REALITY'
      : (tls is Map && tls['enabled'] == true) || security == 'tls' || type == 'hysteria2'
          ? 'TLS'
          : 'БЕЗ TLS';
  return '$protocol / $network / $protection';
}
