import 'dart:convert';

import 'package:bmray/xray_subscription.dart';
import 'package:bmray/xray_bridge.dart';
import 'package:bmray/node_label.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_plugin/vpn_plugin.dart';
import 'fixtures.dart';

/// Synthetic template: deliberately no real server, key, or subscription data.


void main() {
  test('Xray template preserves XHTTP outbound without turning it into TCP', () {
    final profile = parseXrayTemplate(xrayFixture)!;
    expect(profile.name, 'Польша - АвтоБС');
    expect(profile.nodes, hasLength(3));
    final node = profile.nodes.first;
    expect(node['tag'], 'WIFI_');
    expect(node['tls']['utls']['fingerprint'], 'qq');
    expect(node['tls']['reality']['short_id'], '0123456789abcdef');
    expect(profile.notice, contains('балансировщик'));
    expect(profile.nodes[1]['tag'], 'FALLBACK_');
    expect(usesXray(profile.nodes[1]), isTrue);
    final bridge = buildXrayBridge(profile.nodes[1]);
    expect(bridge.xray['outbounds'][0]['streamSettings']['network'], 'xhttp');
    expect(bridge.singbox['outbounds'][0]['type'], 'socks');
    expect(profile.nodes[2]['transport'], {'type': 'grpc', 'service_name': 'service'});
    expect(profile.directRules, isNotEmpty);
    final config = buildSingboxConfig(node);
    (config['route']['rules'] as List).addAll(profile.directRules);
    expect(jsonEncode(config), isNot(contains('backup.example.com')));
  });

  test('XHTTP share link preserves REALITY, path and extra', () {
    const link = 'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
        '?type=xhttp&security=reality&sni=www.example.org&fp=firefox'
        '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef'
        '&host=cdn.example.com&mode=packet-up&path=%2Fsegment.ts'
        '&extra=%7B%22uplinkHTTPMethod%22%3A%22GET%22%7D#XHTTP';
    final node = parseShareLink(link, includeUnsupported: true)!;
    final bridge = buildXrayBridge(node);
    final stream = bridge.xray['outbounds'][0]['streamSettings'];
    expect(stream['network'], 'xhttp');
    expect(stream['xhttpSettings']['host'], 'cdn.example.com');
    expect(stream['xhttpSettings']['path'], '/segment.ts');
    expect(stream['xhttpSettings']['extra']['uplinkHTTPMethod'], 'GET');
    expect(stream['realitySettings']['shortId'], '0123456789abcdef');
  });

  test('Xray Hysteria2 JSON is preserved for the Android core', () {
    final template = parseXrayTemplate(hysteriaXrayFixture)!;
    expect(template.nodes, hasLength(1));
    final node = template.nodes.single;
    expect(usesXray(node), isTrue);
    expect(nodeLabel(node), 'HYSTERIA2 / HYSTERIA / TLS');
    final bridge = buildXrayBridge(node);
    expect(bridge.xray['outbounds'][0]['protocol'], 'hysteria');
    expect(bridge.xray['outbounds'][0]['streamSettings']['hysteriaSettings'],
        {'version': 2});
  });

  test('server subtitles use imported transport and security', () {
    final tcp = parseShareLink(realityLink)!;
    expect(nodeLabel(tcp), 'VLESS / TCP / REALITY');
    final xhttp = parseShareLink(
        realityLink.replaceFirst('type=tcp', 'type=xhttp'),
        includeUnsupported: true)!;
    expect(nodeLabel(xhttp), 'VLESS / XHTTP / REALITY');
  });
}
