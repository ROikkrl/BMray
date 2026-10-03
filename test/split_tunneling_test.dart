import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bmray/deep_links.dart';
import 'package:bmray/split_tunneling.dart';

void main() {
  test('direct and VPN rules precede the default route and DNS matches', () {
    final config = <String, dynamic>{
      'dns': <String, dynamic>{'final': 'remote', 'rules': <Map<String, dynamic>>[]},
      'route': <String, dynamic>{'final': 'proxy', 'rules': <Map<String, dynamic>>[
        {'port': 53, 'action': 'hijack-dns'},
        {'action': 'sniff'},
        {'protocol': 'dns', 'action': 'hijack-dns'},
        {'ip_is_private': true, 'action': 'route', 'outbound': 'direct'},
      ]},
    };
    final profile = SplitProfile.fromJson({
      'name': 'Work', 'defaultRoute': 'direct',
      'directDomains': ['example.org'], 'proxyDomains': ['vpn.example'],
      'proxyIp': ['203.0.113.0/24'], 'directGeoip': ['ru'],
    });
    applySplitProfile(config, profile, localGeoip: {'geoip-ru': '/tmp/ru.srs'});
    final route = config['route'] as Map;
    final rules = route['rules'] as List;
    expect(route['final'], 'direct');
    expect((config['dns'] as Map)['final'], 'local');
    expect(rules[0]['action'], 'hijack-dns');
    expect(rules[3]['domain_suffix'], ['example.org']);
    expect(rules[3]['outbound'], 'direct');
    expect(rules[4]['domain_suffix'], ['vpn.example']);
    expect(rules[5]['ip_cidr'], ['203.0.113.0/24']);
    expect((route['rule_set'] as List).single['path'], '/tmp/ru.srs');
    final dnsRules = (config['dns'] as Map)['rules'] as List;
    expect(dnsRules.map((e) => e['server']), ['local', 'remote']);
  });

  test('invalid routing input is rejected before storage', () {
    expect(() => SplitProfile.fromJson({'name': 'A', 'directIp': ['192.0.2.0/99']}),
        throwsFormatException);
    expect(() => SplitProfile.fromJson({'name': 'A', 'proxyDomains': ['bad domain']}),
        throwsFormatException);
    expect(() => SplitProfile.fromJson({'name': 'A', 'directGeoip': ['not-country']}),
        throwsFormatException);
  });

  test('deep link routes decode only supported commands and reject extras', () {
    expect(BMrayLink.parse('bmray://vpn/toggle').action, BMrayLinkAction.vpnToggle);
    final encoded = base64Url.encode(utf8.encode('{"name":"Work"}'));
    expect(BMrayLink.parse('bmray://routing/add?data=$encoded').value,
        '{"name":"Work"}');
    expect(() => BMrayLink.parse('bmray://vpn/off?data=unexpected'),
        throwsFormatException);
    expect(() => BMrayLink.parse('https://example.com/vpn/on'),
        throwsFormatException);
  });
}
