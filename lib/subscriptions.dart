import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'clash_subscription.dart';
import 'subscription_title.dart';
import 'xray_subscription.dart';

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    required this.nodes,
    this.customName = false,
    this.notice,
    this.directRules = const [],
  });

  final String id;
  String name;
  String url;
  List<Map<String, dynamic>> nodes;
  bool customName;
  String? notice;
  List<Map<String, dynamic>> directRules;

  bool get isRemote => Uri.tryParse(url)?.scheme == 'https';

  factory Subscription.fromJson(Map<String, dynamic> value) {
    final url = value['url'] as String;
    final storedName = value['name'] as String;
    final customName = value['customName'] as bool? ??
        (storedName != Uri.tryParse(url)?.host);
    return Subscription(
    id: value['id'] as String,
    name: customName ? storedName : (subscriptionTitle(storedName, '') ?? storedName),
    url: url,
    nodes: (value['nodes'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
    customName: customName,
    notice: value['notice'] as String?,
    directRules: (value['directRules'] as List? ?? [])
        .map((rule) => Map<String, dynamic>.from(rule as Map)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'nodes': nodes,
    'customName': customName,
    'notice': notice,
    'directRules': directRules,
  };
}

class SubscriptionStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'bmray.subscriptions.v1';

  Future<List<Subscription>> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> save(List<Subscription> subscriptions) => _storage.write(
    key: _key,
    value: jsonEncode(subscriptions.map((e) => e.toJson()).toList()),
  );

  Future<Subscription> import(String name, String url) async {
    final input = url.trim();
    if (input.startsWith('{')) {
      final template = parseXrayTemplate(input);
      if (template == null) {
        throw const FormatException('Не удалось разобрать Xray JSON.');
      }
      if (template.nodes.isEmpty) {
        throw const FormatException('В Xray JSON нет клиентских серверов с адресом и учётными данными.');
      }
      return Subscription(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.trim().isEmpty ? template.name ?? 'Xray JSON' : name.trim(),
        url: input, nodes: template.nodes, directRules: template.directRules,
        notice: template.notice, customName: name.trim().isNotEmpty,
      );
    }
    final normalized = Uri.tryParse(input);
    const shareSchemes = {
      'vless',
      'vmess',
      'trojan',
      'ss',
      'hysteria2',
      'hy2',
      'tuic',
    };
    if (normalized != null && shareSchemes.contains(normalized.scheme)) {
      final node = parseShareLink(input, includeUnsupported: true);
      if (node == null) {
        throw const FormatException(
          'Не удалось разобрать ссылку сервера. Проверьте, что она скопирована полностью.',
        );
      }
      return Subscription(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.trim().isEmpty
            ? (node['tag'] ?? 'Сервер').toString()
            : name.trim(),
        url: input,
        nodes: [node],
        notice: node['_unsupported_reason']?.toString(),
      );
    }
    if (normalized == null ||
        normalized.scheme != 'https' ||
        normalized.host.isEmpty ||
        normalized.userInfo.isNotEmpty) {
      throw const FormatException(
        'Вставьте HTTPS-подписку или ссылку сервера vless://, vmess://, trojan://, ss://, hy2://, tuic://',
      );
    }
    final downloaded = await _download(normalized);
    final parsed = _parse(downloaded.body);
    if (parsed.nodes.isEmpty) {
      throw const FormatException(
        'У подписки нет распознанных серверов. Попробуйте формат sing-box, V2Ray или Clash в боте.',
      );
    }
    return Subscription(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty
          ? (subscriptionTitle(downloaded.title, downloaded.body) ?? parsed.name ?? normalized.host)
          : name.trim(),
      url: normalized.toString(),
      nodes: parsed.nodes,
      directRules: parsed.directRules,
      notice: parsed.notice,
      customName: name.trim().isNotEmpty,
    );
  }

  Future<void> refresh(Subscription item) async {
    if (!item.isRemote) {
      throw const FormatException(
        'Это отдельный сервер. Для изменения импортируйте новую ссылку.',
      );
    }
    final downloaded = await _download(Uri.parse(item.url));
    final parsed = _parse(downloaded.body);
    if (parsed.nodes.isEmpty)
      throw const FormatException(
        'В обновлённой подписке нет распознанных серверов.',
      );
    item.nodes = parsed.nodes;
    item.notice = parsed.notice;
    item.directRules = parsed.directRules;
    if (!item.customName) {
      item.name = subscriptionTitle(downloaded.title, downloaded.body) ?? parsed.name ?? item.name;
    }
  }

  ({List<Map<String, dynamic>> nodes, String? name, String? notice,
      List<Map<String, dynamic>> directRules}) _parse(String content) {
    final xray = parseXrayTemplate(content);
    if (xray != null) {
      return (nodes: xray.nodes, name: xray.name, notice: xray.notice,
          directRules: xray.directRules);
    }
    final standard = parseSubscription(content, includeUnsupported: true);
    if (standard.isNotEmpty) {
      final unsupported = standard.where((node) => node['_unsupported_reason'] != null).length;
      return (nodes: standard, name: null,
          notice: unsupported == 0 ? null :
              '$unsupported из ${standard.length} серверов показаны, но XHTTP требует ядро Xray.',
          directRules: <Map<String, dynamic>>[]);
    }
    try {
      final nodes = parseClashSubscription(content, includeUnsupported: true);
      final unsupported = nodes.where((node) => node['_unsupported_reason'] != null).length;
      return (nodes: nodes, name: null,
          notice: unsupported == 0 ? null :
              '$unsupported из ${nodes.length} серверов показаны, но XHTTP требует ядро Xray.',
          directRules: <Map<String, dynamic>>[]);
    } catch (_) {
      return (nodes: <Map<String, dynamic>>[], name: null, notice: null,
          directRules: <Map<String, dynamic>>[]);
    }
  }

  Future<({String body, String? title})> _download(Uri initial) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      var uri = initial;
      for (var redirect = 0; redirect < 4; redirect++) {
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
          throw const FormatException(
            'Переадресация на небезопасный адрес подписки.',
          );
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'sing-box');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>();
          if (location == null)
            throw const FormatException('Пустая переадресация подписки.');
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw FormatException(
            'Сервер подписки ответил: HTTP ${response.statusCode}.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw const FormatException(
              'Подписка слишком большая (более 2 МБ).',
            );
          }
        }
        return (body: utf8.decode(bytes), title: response.headers.value('profile-title'));
      }
      throw const FormatException('Слишком много переадресаций подписки.');
    } finally {
      client.close(force: true);
    }
  }
}
