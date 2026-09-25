import 'dart:convert';

import 'package:bmray/subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'fixtures.dart';

void main() {
  test(
    'direct VLESS imports without an HTTPS fetch and preserves Reality',
    () async {
      final profile = await SubscriptionStore().import('', '  $realityLink  ');
      expect(profile.isRemote, false);
      expect(profile.name, '🇪🇪 Test');
      expect(profile.nodes, hasLength(1));
      final node = profile.nodes.single;
      expect(node['server'], 'vpn.example.com');
      expect(node['server_port'], 4444);
      expect(node['flow'], 'xtls-rprx-vision');
      expect(
        node.containsKey('transport'),
        false,
      ); // TCP is not a V2Ray transport.
      expect(node['tls']['server_name'], 'www.example.org');
      expect(node['tls']['utls']['fingerprint'], 'firefox');
      expect(node['tls']['reality']['short_id'], '0123456789abcdef');
      final restored = Subscription.fromJson(profile.toJson());
      expect(restored.isRemote, false);
      expect(restored.nodes, profile.nodes);
      await expectLater(
        SubscriptionStore().refresh(restored),
        throwsFormatException,
      );
    },
  );

  test('custom profile name overrides the URI fragment', () async {
    final profile = await SubscriptionStore().import('My server', realityLink);
    expect(profile.name, 'My server');
  });

  test('rejects malformed links and insecure subscription URLs', () async {
    for (final input in ['', 'vless://broken', 'http://example.com/sub']) {
      await expectLater(
        SubscriptionStore().import('', input),
        throwsFormatException,
      );
    }
  });

  test('existing HTTPS subscriptions remain refreshable', () {
    final profile = Subscription(
      id: 'test',
      name: 'Test',
      url: 'https://example.com/sub',
      nodes: [],
    );
    expect(Subscription.fromJson(profile.toJson()).isRemote, true);
    expect(
      parseSubscription(base64Encode(utf8.encode(realityLink))),
      hasLength(1),
    );
  });

  test(
    'Android bootstrap DNS cannot recurse through the proxy or hardcode AliDNS',
    () {
      final node = parseShareLink(realityLink)!;
      final before = jsonEncode(node);
      final config = buildSingboxConfig(
        node,
        options: const SingboxConfigOptions(usePlatformDns: true),
      );
      final dns = config['dns'];
      final local = (dns['servers'] as List).singleWhere(
        (s) => s['tag'] == 'local',
      );
      final remote = (dns['servers'] as List).singleWhere(
        (s) => s['tag'] == 'remote',
      );
      expect(local, {'type': 'local', 'tag': 'local'});
      expect(remote['detour'], 'proxy');
      expect(config['route']['default_domain_resolver'], 'local');
      expect(dns['rules'][0]['domain'], ['vpn.example.com']);
      expect(jsonEncode(config), isNot(contains('223.5.5.5')));
      expect(jsonEncode(node), before);
      expect(config['inbounds'][0]['mtu'], 1500);
    },
  );

  test('DNS on port 53 is intercepted before the private-address rule', () {
    final config = buildSingboxConfig(parseShareLink(realityLink)!);
    final rules = config['route']['rules'] as List;
    expect(rules.first, {'port': 53, 'action': 'hijack-dns'});
    expect(rules.indexWhere((r) => r['ip_is_private'] == true), greaterThan(0));
    expect(config['route']['final'], 'proxy');
  });

  test('XHTTP links are not silently interpreted as plain TCP', () {
    final link = realityLink.replaceFirst('type=tcp', 'type=xhttp');
    expect(parseShareLink(link), isNull);
    expect(parseSubscription(link), isEmpty);
  });
}
