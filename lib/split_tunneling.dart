import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// User-facing routing profile. Only these fields are accepted from deep links.
class SplitProfile {
  SplitProfile({required this.id, required this.name, this.defaultRoute = 'proxy',
      this.directDomains = const [], this.proxyDomains = const [],
      this.directIp = const [], this.proxyIp = const [],
      this.directGeoip = const [], this.proxyGeoip = const []});

  final String id;
  final String name;
  final String defaultRoute;
  final List<String> directDomains, proxyDomains, directIp, proxyIp;
  final List<String> directGeoip, proxyGeoip;

  static List<String> _strings(Object? value) {
    if (value == null) return [];
    if (value is! List || value.length > 500 || !value.every((e) => e is String)) {
      throw const FormatException('Неверный список правил маршрутизации.');
    }
    return value.cast<String>();
  }

  factory SplitProfile.fromJson(Map<String, dynamic> data) {
    final name = data['name']?.toString().trim() ?? '';
    final route = data['defaultRoute']?.toString() ?? 'proxy';
    if (name.isEmpty || name.length > 80 || !['proxy', 'direct'].contains(route)) {
      throw const FormatException('Укажите название и маршрут по умолчанию.');
    }
    final id = data['id']?.toString() ?? '';
    final directDomains = _domains(_strings(data['directDomains']));
    final proxyDomains = _domains(_strings(data['proxyDomains']));
    final directIp = _cidrs(_strings(data['directIp']));
    final proxyIp = _cidrs(_strings(data['proxyIp']));
  final directGeoip = _countries(_strings(data['directGeoip']));
  final proxyGeoip = _countries(_strings(data['proxyGeoip']));
    if ({...directGeoip, ...proxyGeoip}.length > 24) {
      throw const FormatException('Слишком много стран GeoIP (максимум 24).');
    }
    return SplitProfile(id: id.isEmpty ? DateTime.now().microsecondsSinceEpoch.toString() : id,
      name: name, defaultRoute: route, directDomains: directDomains,
      proxyDomains: proxyDomains, directIp: directIp, proxyIp: proxyIp,
      directGeoip: directGeoip, proxyGeoip: proxyGeoip);
  }

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'defaultRoute': defaultRoute,
    'directDomains': directDomains, 'proxyDomains': proxyDomains,
    'directIp': directIp, 'proxyIp': proxyIp,
    'directGeoip': directGeoip, 'proxyGeoip': proxyGeoip,
  };

  Set<String> get geoipCodes => {...directGeoip, ...proxyGeoip};

  static List<String> _domains(List<String> values) => values.map((raw) {
    final value = raw.trim().toLowerCase().replaceFirst(RegExp(r'^\*\.'), '');
    if (value.isEmpty || value.length > 253 || value.contains('..') ||
        !RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)*$').hasMatch(value)) {
      throw FormatException('Неверный домен: $raw');
    }
    return value;
  }).toSet().toList();

  static List<String> _cidrs(List<String> values) => values.map((raw) {
    final parts = raw.trim().split('/');
    final ip = InternetAddress.tryParse(parts.first);
    final bits = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (ip == null || parts.length > 2 ||
        (parts.length == 2 && (bits == null || bits < 0 ||
            bits > (ip.type == InternetAddressType.IPv4 ? 32 : 128)))) {
      throw FormatException('Неверный IP/CIDR: $raw');
    }
    return parts.length == 1 ? ip.address : '${ip.address}/$bits';
  }).toSet().toList();

  static List<String> _countries(List<String> values) => values.map((raw) {
    final value = raw.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2}$').hasMatch(value)) {
      throw FormatException('Неверный код страны GeoIP: $raw');
    }
    return value;
  }).toSet().toList();
}

/// Rules are inserted after DNS sniffing and before the final route. Native
/// per-app VPN inclusion/exclusion is configured separately on Android.
void applySplitProfile(Map<String, dynamic> config, SplitProfile? profile,
    {Map<String, String> localGeoip = const {}}) {
  if (profile == null) return;
  final route = config['route'] as Map<String, dynamic>;
  final rules = route['rules'] as List;
  final insertion = <Map<String, dynamic>>[];
  final dns = config['dns'] as Map<String, dynamic>;
  final dnsRules = <Map<String, dynamic>>[
    ...((dns['rules'] as List?) ?? []).map((v) => Map<String, dynamic>.from(v as Map)),
  ];
  final sets = <Map<String, dynamic>>[
    ...((route['rule_set'] as List?) ?? []).map((v) => Map<String, dynamic>.from(v as Map)),
  ];

  void add(String field, List<String> values, String outbound) {
    if (values.isEmpty) return;
    insertion.add({field: values, 'action': 'route', 'outbound': outbound});
    if (field == 'domain_suffix') {
      dnsRules.add({field: values, 'action': 'route',
        'server': outbound == 'direct' ? 'local' : 'remote'});
    }
  }

  add('domain_suffix', profile.directDomains, 'direct');
  add('domain_suffix', profile.proxyDomains, 'proxy');
  add('ip_cidr', profile.directIp, 'direct');
  add('ip_cidr', profile.proxyIp, 'proxy');
  for (final code in profile.geoipCodes) {
    final tag = 'geoip-$code';
    final existing = sets.indexWhere((entry) => entry['tag'] == tag);
    if (existing >= 0) {
      if (localGeoip[tag] != null) sets[existing] = {
        'type': 'local', 'tag': tag, 'format': 'binary', 'path': localGeoip[tag],
      };
      continue;
    }
    sets.add(localGeoip[tag] == null ? {
      'type': 'remote', 'tag': tag, 'format': 'binary',
      'url': 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/$tag.srs',
      'download_detour': 'proxy',
    } : {'type': 'local', 'tag': tag, 'format': 'binary', 'path': localGeoip[tag]});
  }
  add('rule_set', profile.directGeoip.map((c) => 'geoip-$c').toList(), 'direct');
  add('rule_set', profile.proxyGeoip.map((c) => 'geoip-$c').toList(), 'proxy');
  // Keep the DNS interception and sniff rules ahead of custom routing.
  final insertAt = rules.indexWhere((rule) => rule is Map &&
      rule['action'] != 'hijack-dns' && rule['action'] != 'sniff');
  rules.insertAll(insertAt < 0 ? rules.length : insertAt, insertion);
  if (dnsRules.isNotEmpty) dns['rules'] = dnsRules;
  if (sets.isNotEmpty) route['rule_set'] = sets;
  route['final'] = profile.defaultRoute;
  dns['final'] = profile.defaultRoute == 'direct' ? 'local' : 'remote';
}

class SplitProfileStore {
  static const _storage = FlutterSecureStorage();
  static const _profilesKey = 'bmray.split.profiles.v1';
  static const _selectedKey = 'bmray.split.selected.v1';

  Future<({List<SplitProfile> profiles, String? selected})> load() async {
    final raw = await _storage.read(key: _profilesKey);
    final selected = await _storage.read(key: _selectedKey);
    final parsed = raw == null ? [] : jsonDecode(raw) as List;
    return (profiles: parsed.map((v) => SplitProfile.fromJson(
        Map<String, dynamic>.from(v as Map))).toList(), selected: selected);
  }

  Future<void> save(List<SplitProfile> profiles, String? selected) async {
    await _storage.write(key: _profilesKey,
        value: jsonEncode(profiles.map((e) => e.toJson()).toList()));
    if (selected == null) await _storage.delete(key: _selectedKey);
    else await _storage.write(key: _selectedKey, value: selected);
  }
}

class GeoIpFiles {
  Future<Directory> _directory() async => Directory(
      '${(await getApplicationSupportDirectory()).path}/bmray-geoip')
    ..createSync(recursive: true);

  Future<Map<String, String>> available(Iterable<String> countries) async {
    final directory = await _directory();
    return {for (final code in countries)
      if (await File('${directory.path}/geoip-$code.srs').exists())
        'geoip-$code': '${directory.path}/geoip-$code.srs'};
  }

  Future<void> redownload(Iterable<String> countries) async {
    final directory = await _directory();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      for (final code in countries.toSet()) {
        if (!RegExp(r'^[a-z]{2}$').hasMatch(code)) throw const FormatException('Неверный GeoIP.');
        final url = Uri.parse('https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-$code.srs');
        final response = await (await client.getUrl(url)).close()
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);
        final bytes = await response.fold<List<int>>(<int>[], (all, chunk) {
          if (all.length + chunk.length > 16 * 1024 * 1024) throw const FormatException('GeoIP слишком большой.');
          return all..addAll(chunk);
        }).timeout(const Duration(seconds: 30));
        if (bytes.length < 4 || bytes[0] != 0x53 || bytes[1] != 0x52 || bytes[2] != 0x53) {
          throw const FormatException('Ответ не содержит GeoIP SRS.');
        }
        final file = File('${directory.path}/geoip-$code.srs');
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
      }
    } finally { client.close(force: true); }
  }
}
