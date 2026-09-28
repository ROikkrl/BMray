import 'dart:convert';

import 'package:bmray/xray_subscription.dart';
import 'package:bmray/xray_bridge.dart';
import 'package:bmray/remnawave_template.dart';
import 'package:bmray/node_label.dart';
import 'package:bmray/subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_plugin/vpn_plugin.dart';
import 'fixtures.dart';

/// Synthetic template: deliberately no real server, key, or subscription data.


void main() {
  test('AutoBS label uses the original loopback host transport and security', () {
    final auto = <String, dynamic>{
      'type': 'auto',
      '_origin_node': {
        'type': 'vless',
        'transport': {'type': 'xhttp'},
        'tls': {'enabled': true},
      },
    };
    expect(nodeLabel(auto), 'VLESS / XHTTP / TLS');
    auto['_origin_node'] = {
      'type': 'vless', 'tls': {'enabled': true, 'reality': <String, dynamic>{}},
    };
    expect(nodeLabel(auto), 'VLESS / TCP / REALITY');
  });

  test('Remnawave selector injects real endpoints and drops absent fallback', () {
    const uuid = '00000000-0000-4000-8000-000000000001';
    final links = [
      'vless://$uuid@one.example.com:443?type=xhttp&security=reality&'
          'sni=www.example.org&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '&sid=0123456789abcdef&path=%2Ftest#Estonia%20%232',
      'vless://$uuid@two.example.com:4444?type=tcp&flow=xtls-rprx-vision&'
          'security=reality&sni=www.example.org&'
          'pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
          '&sid=0123456789abcdef#Estonia%20%232%20(backup)',
      'vless://$uuid@127.0.0.1:237?type=xhttp&security=tls#Estonia%20Auto',
    ];
    final nodes = links.map((link) =>
        parseShareLink(link, includeUnsupported: true)!).toList();
    final json = jsonEncode({
      'routing': {'rules': [
        {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto_wifi'}
      ], 'balancers': [{
        'tag': 'auto_wifi', 'selector': ['WIFI_'],
        'strategy': {'type': 'leastPing'}, 'fallbackTag': 'FALLBACK_'
      }]},
      'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}],
      'remnawave': {'injectHosts': [
        {'selector': {'type': 'remarkRegex', 'pattern': 'Estonia #2'},
          'tagPrefix': 'WIFI_', 'selectFrom': 'NOT_HIDDEN'},
        {'selector': {'type': 'remarkRegex', 'pattern': r'Estonia \(BS\)'},
          'tagPrefix': 'FALLBACK_', 'selectFrom': 'ALL'},
      ]},
    });
    final node = injectRemnawaveTemplate(json, nodes, 'Estonia Auto');
    expect(node['type'], 'auto');
    expect(node['_template_warning'], contains('FALLBACK_'));
    final bridge = buildXrayBridge(node);
    final outbounds = bridge.xray['outbounds'] as List;
    expect(outbounds.map((o) => o['tag']), ['WIFI_', 'WIFI_-2', 'direct']);
    expect(outbounds[0]['settings']['vnext'][0]['address'], 'one.example.com');
    expect(outbounds[1]['settings']['vnext'][0]['address'], 'two.example.com');
    expect(outbounds[1]['settings']['vnext'][0]['users'][0]['flow'],
        'xtls-rprx-vision');
    expect(bridge.xray['routing']['balancers'][0].containsKey('fallbackTag'), false);
    final item = Subscription(id: '1', name: 'test', url: 'https://example.com/sub',
        nodes: nodes, autoTemplates: {'Estonia Auto': json});
    expect(Subscription.fromJson(item.toJson()).autoTemplates['Estonia Auto'], json);
  });
  test('Xray template preserves XHTTP outbound without turning it into TCP', () {
    final profile = parseXrayTemplate(xrayFixture)!;
    expect(profile.name, 'Польша - АвтоБС');
    expect(profile.nodes, hasLength(5));
    final auto = profile.nodes.first;
    expect(auto['type'], 'auto');
    expect(usesXray(auto), true);
    final autoBridge = buildXrayBridge(auto);
    expect(autoBridge.xray['routing']['rules'].last['balancerTag'], 'auto_wifi');
    expect(autoBridge.xray['routing']['balancers'][0]['strategy']['type'], 'leastPing');
    expect(autoBridge.xray['burstObservatory']['subjectSelector'], ['WIFI_']);
    expect(autoBridge.xray['outbounds'], hasLength(4));
    expect((autoBridge.xray['outbounds'] as List)
        .map((outbound) => outbound['tag']),
        containsAll(['WIFI_', 'WIFI_-2', 'FALLBACK_', 'direct']));
    final rules = autoBridge.xray['routing']['rules'] as List;
    expect(rules.first['outboundTag'], 'direct');
    expect(rules.first['domain'], isNot(contains('geosite:category-test')));
    expect(rules[1]['ip'], contains('10.0.0.0/8'));
    expect(rules.last['balancerTag'], 'auto_wifi');
    expect(autoBridge.xray['inbounds'][0]['sniffing']['enabled'], true);
    final probeBridge = buildXrayBridge(auto, probe: true,
        probeOutboundTag: 'WIFI_-2');
    expect(probeBridge.xray['routing']['rules'], hasLength(1));
    expect(probeBridge.xray['routing']['rules'][0]['outboundTag'], 'WIFI_-2');
    expect(probeBridge.xray.containsKey('burstObservatory'), false);
    expect(autoBridge.xray['inbounds'][0]['protocol'], 'socks');
    expect(probeBridge.singbox['inbounds'], isEmpty);
    final node = profile.nodes[1];
    expect(node['tag'], 'WIFI_');
    expect(node['tls']['utls']['fingerprint'], 'qq');
    expect(node['tls']['reality']['short_id'], '0123456789abcdef');
    expect(profile.nodes[3]['tag'], 'FALLBACK_');
    expect(usesXray(profile.nodes[3]), isTrue);
    final bridge = buildXrayBridge(profile.nodes[3]);
    expect(bridge.xray['outbounds'][0]['streamSettings']['network'], 'xhttp');
    expect(bridge.singbox['outbounds'][0]['type'], 'socks');
    expect(profile.nodes[4]['transport'], {'type': 'grpc', 'service_name': 'service'});
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

  test('XHTTP TLS uses transport host when an explicit SNI is empty', () {
    final node = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
      '?type=xhttp&security=tls&sni=&host=cdn.example.com&path=%2Ffile#Test',
      includeUnsupported: true,
    )!;
    expect(node['tls']['server_name'], 'cdn.example.com');
    node['tls']['server_name'] = '';
    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
  });

  test('raw XHTTP TLS outbound restores absent SNI from its Host', () {
    final node = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443'
      '?type=xhttp&security=tls&host=cdn.example.com&path=%2Ffile#Test',
      includeUnsupported: true,
    )!;
    final raw = xrayOutboundFromNode(node);
    (raw['streamSettings']['tlsSettings'] as Map)['serverName'] = '';
    node['_xray_outbound'] = raw;
    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
    expect(raw['streamSettings']['tlsSettings']['serverName'], '');
  });

  test('VLESS TCP TLS can use Xray on Android without losing SNI', () {
    final node = parseShareLink(
      'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
      '?type=tcp&security=tls&sni=cdn.example.com&fp=firefox#TLS',
    )!;
    expect(prefersXrayTls(node), true);
    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
    expect(stream['network'], 'tcp');
    expect(stream['security'], 'tls');
    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
    expect(stream['tlsSettings']['fingerprint'], 'firefox');
  });

  test('DNS outbound is an Xray internal route, not a broken server', () {
    final config = jsonDecode(xrayFixture) as Map<String, dynamic>;
    (config['outbounds'] as List).add({'tag': 'dns', 'protocol': 'dns'});
    final parsed = parseXrayTemplate(jsonEncode(config))!;
    expect(parsed.notice ?? '', isNot(contains('dns')));
    expect(parsed.nodes.first['type'], 'auto');
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

  test('Incomplete Hysteria stays visible instead of disappearing', () {
    final incomplete = hysteriaXrayFixture.replaceFirst('"version":2,"address"',
        '"version":1,"address"');
    final nodes = parseXrayTemplate(incomplete)!.nodes;
    expect(nodes, hasLength(1));
    expect(nodes.single['tag'], 'Латвия (Hysteria2)');
    expect(nodes.single['_unsupported_reason'], contains('version=2'));
  });

  test('Hysteria version 2 share link is imported', () {
    final node = parseShareLink(
        'hysteria://password@vpn.example.com:443?version=2&sni=example.org#Test');
    expect(node?['type'], 'hysteria2');
    expect(node?['password'], 'password');
  });

  test('Hysteria2 share link with slash after port imports and builds', () async {
    const link = 'hysteria2://00000000-0000-4000-8000-000000000001@'
        'lv.example.com:4443/?sni=lv.example.com#%F0%9F%87%B1%F0%9F%87%BB%20Latvia';
    final node = parseShareLink(link, includeUnsupported: true)!;
    expect(node['type'], 'hysteria2');
    expect(node['server'], 'lv.example.com');
    expect(node['server_port'], 4443);
    expect(node['password'], '00000000-0000-4000-8000-000000000001');
    expect(node['tls']['server_name'], 'lv.example.com');
    expect(node['tag'], contains('Latvia'));
    expect(buildSingboxConfig(node)['outbounds'][0]['type'], 'hysteria2');
    expect(parseSubscription('$link\n$link'), hasLength(2));
    final imported = await SubscriptionStore().import('', link);
    expect(imported.nodes, hasLength(1));
    expect(imported.nodes.single['server_port'], 4443);
  });

  test('Raw Xray outbound array keeps Hysteria in the subscription', () async {
    final raw = jsonDecode(hysteriaXrayFixture) as Map;
    final subscription = await SubscriptionStore()
        .import('', jsonEncode(raw['outbounds']));
    expect(subscription.nodes, hasLength(1));
    expect(subscription.nodes.single['type'], 'hysteria2');
    expect(usesXray(subscription.nodes.single), true);
  });

  test('XRAY_JSON array shows one named region per config, including AutoBS', () async {
    final ordinary = jsonDecode(xrayFixture) as Map<String, dynamic>;
    ordinary.remove('routing');
    ordinary.remove('burstObservatory');
    ordinary['remarks'] = '🇪🇪 Эстония';
    final imported = await SubscriptionStore().import('', jsonEncode([
      ordinary,
      jsonDecode(xrayFixture),
      jsonDecode(hysteriaXrayFixture),
    ]));
    expect(imported.nodes, hasLength(3));
    expect(imported.nodes.map((node) => node['tag']), [
      '🇪🇪 Эстония', 'Польша - АвтоБС', 'Латвия (Hysteria2)',
    ]);
    expect(imported.nodes[1]['type'], 'auto');
    expect((buildXrayBridge(imported.nodes[1]).xray['outbounds'] as List)
        .map((outbound) => outbound['tag']),
        containsAll(['WIFI_', 'WIFI_-2', 'FALLBACK_']));
    expect(imported.nodes[2]['type'], 'hysteria2');
    expect(usesXray(imported.nodes[2]), true);
  });

  test('Imported template retains the original JSON across storage serialization', () async {
    final imported = await SubscriptionStore().import('', xrayFixture);
    expect(jsonDecode(imported.rawResponse!), jsonDecode(xrayFixture));
    final restored = Subscription.fromJson(imported.toJson());
    expect(restored.rawResponse, imported.rawResponse);
    expect(restored.nodes.first['_xray_template'], isNotNull);
  });

  test('Base64 link subscription can be inspected without losing its response', () {
    final body = base64Encode(utf8.encode('$realityLink\n$realityLink'));
    final subscription = Subscription(id: 'test', name: 'Test',
        url: 'https://example.com/sub', nodes: [], rawResponse: body);
    final restored = Subscription.fromJson(subscription.toJson());
    expect(restored.rawResponse, body);
    expect(decodedSubscriptionResponse(body), '$realityLink\n$realityLink');
  });

  test('only Base64 subscriptions with local template hosts trigger JSON retry', () {
    const local = 'vless://00000000-0000-4000-8000-000000000001@127.0.0.1:237'
        '?type=xhttp&security=tls#Auto';
    const remote = 'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
        '?type=xhttp&security=reality#Remote';
    expect(needsXrayJsonRetry(base64Encode(utf8.encode('$remote\n$local'))), true);
    expect(needsXrayJsonRetry(base64Encode(utf8.encode(remote))), false);
    expect(needsXrayJsonRetry('$remote\n$local'), false);
    expect(needsXrayJsonRetry(xrayFixture), false);
    expect(parseXrayTemplate(xrayFixture)!.nodes.first['type'], 'auto');
  });

  test('loopback discovery uses endpoints rather than AutoBS names', () {
    const nameAgnostic = 'vless://00000000-0000-4000-8000-000000000001@'
        '[::1]:237?type=xhttp&security=tls#Unexpected%20name';
    final encoded = base64Encode(utf8.encode(nameAgnostic));
    expect(needsXrayJsonRetry(encoded), true);
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
