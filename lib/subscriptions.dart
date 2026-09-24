import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'clash_subscription.dart';

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    required this.nodes,
  });

  final String id;
  String name;
  String url;
  List<Map<String, dynamic>> nodes;

  bool get isRemote => Uri.tryParse(url)?.scheme == 'https';

  factory Subscription.fromJson(Map<String, dynamic> value) => Subscription(
    id: value['id'] as String,
    name: value['name'] as String,
    url: value['url'] as String,
    nodes: (value['nodes'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'nodes': nodes,
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
      final node = parseShareLink(input);
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
    final nodes = _parse(await _download(normalized));
    if (nodes.isEmpty) {
      throw const FormatException(
        'У подписки нет распознанных серверов. Попробуйте формат sing-box, V2Ray или Clash в боте.',
      );
    }
    return Subscription(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? normalized.host : name.trim(),
      url: normalized.toString(),
      nodes: nodes,
    );
  }

  Future<void> refresh(Subscription item) async {
    if (!item.isRemote) {
      throw const FormatException(
        'Это отдельный сервер. Для изменения импортируйте новую ссылку.',
      );
    }
    final nodes = _parse(await _download(Uri.parse(item.url)));
    if (nodes.isEmpty)
      throw const FormatException(
        'В обновлённой подписке нет распознанных серверов.',
      );
    item.nodes = nodes;
  }

  List<Map<String, dynamic>> _parse(String content) {
    final standard = parseSubscription(content);
    if (standard.isNotEmpty) return standard;
    try {
      return parseClashSubscription(content);
    } catch (_) {
      return [];
    }
  }

  Future<String> _download(Uri initial) async {
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
        return utf8.decode(bytes);
      }
      throw const FormatException('Слишком много переадресаций подписки.');
    } finally {
      client.close(force: true);
    }
  }
}
