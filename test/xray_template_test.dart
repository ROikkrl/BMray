import 'dart:convert';

import 'package:bmray/xray_subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_plugin/vpn_plugin.dart';
import 'fixtures.dart';

/// Synthetic template: deliberately no real server, key, or subscription data.


void main() {
  test('Xray template imports valid primary, never pretends XHTTP is TCP', () {
    final profile = parseXrayTemplate(xrayFixture)!;
    expect(profile.name, 'Польша - АвтоБС');
    expect(profile.nodes, hasLength(3));
    final node = profile.nodes.first;
    expect(node['tag'], 'WIFI_');
    expect(node['tls']['utls']['fingerprint'], 'qq');
    expect(node['tls']['reality']['short_id'], '0123456789abcdef');
    expect(profile.notice, contains('xhttp'));
    expect(profile.notice, contains('балансировщик'));
    expect(profile.nodes[1]['tag'], 'FALLBACK_');
    expect(profile.nodes[1]['_unsupported_reason'], contains('XHTTP'));
    expect(profile.nodes[2]['transport'], {'type': 'grpc', 'service_name': 'service'});
    expect(profile.directRules, isNotEmpty);
    final config = buildSingboxConfig(node);
    (config['route']['rules'] as List).addAll(profile.directRules);
    expect(jsonEncode(config), isNot(contains('backup.example.com')));
  });
}
