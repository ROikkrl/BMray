import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'clash_subscription.dart';
import 'subscription_title.dart';
import 'subscription_metadata.dart';
import 'subscription_identity.dart';
import 'xray_subscription.dart';
import 'remnawave_template.dart';
import 'subscription_request_cache.dart';
import 'subscription_preview_cache.dart';

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    required this.url,
    required this.nodes,
    this.customName = false,
    this.notice,
    this.directRules = const [],
    this.announcement,
    this.traffic,
    this.updateHours,
    this.lastUpdatedAt,
    this.pinned = false,
    this.rawResponse,
    this.autoTemplates = const {},
  });

  final String id;
  String name;
  String url;
  List<Map<String, dynamic>> nodes;
  bool customName;
  String? notice;
  List<Map<String, dynamic>> directRules;
  String? announcement;
  SubscriptionTraffic? traffic;
  int? updateHours;
  DateTime? lastUpdatedAt;
  bool pinned;
  String? rawResponse;
  Map<String, String> autoTemplates;

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
    announcement: value['announcement'] as String?,
    traffic: value['traffic'] is Map ? SubscriptionTraffic.fromJson(
        Map<String, dynamic>.from(value['traffic'] as Map)) : null,
    updateHours: value['updateHours'] as int?,
    lastUpdatedAt: DateTime.tryParse(value['lastUpdatedAt'] as String? ?? ''),
    pinned: value['pinned'] as bool? ?? false,
    rawResponse: value['rawResponse'] as String? ?? value['rawJson'] as String?,
    autoTemplates: (value['autoTemplates'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), value.toString())),
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
    'announcement': announcement,
    'traffic': traffic?.toJson(),
    'updateHours': updateHours,
    'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
    'pinned': pinned,
    'rawResponse': rawResponse,
    'autoTemplates': autoTemplates,
  };
}

List<SubscriptionPreview> subscriptionPreviews(List<Subscription> subscriptions) => [
  for (final item in subscriptions)
    SubscriptionPreview(item.id, item.name,
      [for (final node in item.nodes) node['tag']?.toString() ?? '']),
];

class SubscriptionStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'bmray.subscriptions.v1';
  SubscriptionIdentity? identity;
  final requestLog = SubscriptionRequestCache();
  final previewCache = SubscriptionPreviewCache();

  Future<List<SubscriptionPreview>> loadPreview() => previewCache.read();

  Future<List<Subscription>> load() async {
    final value = await _storage.read(key: _key);
    if (value == null) {
      unawaited(previewCache.clear().catchError((Object _) {}));
      return [];
    }
    final subscriptions = (jsonDecode(value) as List)
        .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    unawaited(previewCache.save(subscriptionPreviews(subscriptions))
        .catchError((Object _) {}));
    return subscriptions;
  }

  Future<void> save(List<Subscription> subscriptions) async {
    await _storage.write(key: _key,
      value: jsonEncode(subscriptions.map((e) => e.toJson()).toList()));
    try {
      await previewCache.save(subscriptionPreviews(subscriptions));
    } catch (_) {
      // Display cache failures never affect the canonical encrypted store.
    }
  }

  Future<Subscription> import(String name, String url) async {
    final input = url.trim();
    if (input.startsWith('{') || input.startsWith('[')) {
      final template = input.startsWith('{') ? parseXrayTemplate(input) : null;
      final parsed = template == null && input.startsWith('[')
          ? _parse(input) : null;
      if (template == null && parsed == null) {
        throw const FormatException('Не удалось разобрать Xray JSON.');
      }
      final nodes = template?.nodes ?? parsed!.nodes;
      if (nodes.isEmpty) {
        throw FormatException(template?.notice ?? parsed?.notice ??
            'В Xray JSON нет клиентских серверов с адресом и учётными данными.');
      }
      return Subscription(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.trim().isEmpty ? template?.name ?? 'Xray JSON' : name.trim(),
        url: input, nodes: nodes,
        directRules: template?.directRules ?? parsed!.directRules,
        notice: template?.notice ?? parsed?.notice,
        customName: name.trim().isNotEmpty,
        rawResponse: input,
      );
    }
    final normalized = Uri.tryParse(input);
    const shareSchemes = {
      'vless',
      'vmess',
      'trojan',
      'ss',
      'hysteria2',
      'hysteria',
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
        rawResponse: input,
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
    final downloaded = await _downloadPreferXrayJson(normalized);
    final parsed = _parse(downloaded.body);
    _attachOriginalHosts(parsed.nodes, downloaded.originalBody);
    await requestLog.append({'event': 'parse', 'id': downloaded.id,
      'format': subscriptionBodySummary(downloaded.body)['format'],
      'nodeCount': parsed.nodes.length,
      'autoNodeCount': parsed.nodes.where((node) => node['type'] == 'auto').length,
    });
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
      announcement: subscriptionAnnouncement(downloaded.announce),
      traffic: SubscriptionTraffic.fromHeader(downloaded.userInfo),
      updateHours: subscriptionUpdateHours(downloaded.updateInterval),
      lastUpdatedAt: DateTime.now(),
      rawResponse: downloaded.body,
    );
  }

  Subscription importEncoded(String content, {String name = ''}) {
    final parsed = _parse(content);
    if (parsed.nodes.isEmpty) {
      throw const FormatException('В конфигурации нет распознанных серверов.');
    }
    return Subscription(id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.isEmpty ? (parsed.name ?? 'Импорт Base64') : name,
      url: content, nodes: parsed.nodes, directRules: parsed.directRules,
      notice: parsed.notice, rawResponse: content, customName: name.isNotEmpty);
  }

  Future<void> refresh(Subscription item) async {
    if (!item.isRemote) {
      throw const FormatException(
        'Это отдельный сервер. Для изменения импортируйте новую ссылку.',
      );
    }
    final downloaded = await _downloadPreferXrayJson(Uri.parse(item.url));
    final parsed = _parse(downloaded.body);
    _attachOriginalHosts(parsed.nodes, downloaded.originalBody);
    await requestLog.append({'event': 'parse', 'id': downloaded.id,
      'format': subscriptionBodySummary(downloaded.body)['format'],
      'nodeCount': parsed.nodes.length,
      'autoNodeCount': parsed.nodes.where((node) => node['type'] == 'auto').length,
    });
    if (parsed.nodes.isEmpty)
      throw const FormatException(
        'В обновлённой подписке нет распознанных серверов.',
      );
    item.nodes = parsed.nodes;
    for (final template in item.autoTemplates.entries) {
      final index = item.nodes.indexWhere((node) =>
          node['tag'] == template.key && isLocalTemplateHost(node));
      if (index >= 0) {
        try {
          item.nodes[index] = injectRemnawaveTemplate(
              template.value, item.nodes, template.key);
        } on FormatException {
          // Preserve the new subscription and let the user reattach its template.
        }
      }
    }
    item.notice = parsed.notice;
    item.directRules = parsed.directRules;
    item.announcement = subscriptionAnnouncement(downloaded.announce);
    item.traffic = SubscriptionTraffic.fromHeader(downloaded.userInfo);
    item.updateHours = subscriptionUpdateHours(downloaded.updateInterval);
    item.lastUpdatedAt = DateTime.now();
    item.rawResponse = downloaded.body;
    if (!item.customName) {
      item.name = subscriptionTitle(downloaded.title, downloaded.body) ?? parsed.name ?? item.name;
    }
  }

  void attachAutoTemplate(Subscription item, int index, String raw) {
    final node = item.nodes[index];
    final tag = node['tag']?.toString() ?? '';
    final assembled = injectRemnawaveTemplate(raw, item.nodes, tag);
    item.nodes[index] = assembled;
    item.autoTemplates = {...item.autoTemplates, tag: raw};
  }

  void _attachOriginalHosts(List<Map<String, dynamic>> nodes, String? originalBody) {
    if (originalBody == null) return;
    final hosts = parseSubscription(originalBody, includeUnsupported: true)
        .where(isLocalTemplateHost).toList();
    final autos = nodes.where((node) => node['type'] == 'auto').toList();
    final used = <int>{};
    for (final auto in autos) {
      final name = auto['tag']?.toString().trim() ?? '';
      var match = hosts.indexWhere((host) =>
          host['tag']?.toString().trim() == name &&
          !used.contains(hosts.indexOf(host)));
      if (match < 0 && hosts.length == autos.length) {
        match = autos.indexOf(auto);
      }
      if (match >= 0 && match < hosts.length && used.add(match)) {
        final host = hosts[match];
        auto['_origin_node'] = {
          'type': host['type'],
          if (host['transport'] is Map) 'transport': host['transport'],
          if (host['tls'] is Map) 'tls': host['tls'],
        };
      }
    }
  }

  ({List<Map<String, dynamic>> nodes, String? name, String? notice,
      List<Map<String, dynamic>> directRules}) _parse(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[') &&
        !trimmed.contains('://')) {
      try {
        final decoded = utf8.decode(base64.decode(base64.normalize(trimmed)));
        if (decoded.trimLeft().startsWith('{') || decoded.trimLeft().startsWith('[')) {
          content = decoded;
        }
      } on FormatException {
        // A normal Base64 list of share links is handled below.
      }
    }
    if (content.trimLeft().startsWith('[')) {
      try {
        final entries = jsonDecode(content);
        if (entries is List) {
          final nodes = <Map<String, dynamic>>[];
          final directRules = <Map<String, dynamic>>[];
          final notices = <String>[];
          for (final entry in entries) {
            if (entry is! Map) continue;
            final profile = parseXrayTemplate(jsonEncode(
                entry['protocol'] != null && entry['outbounds'] == null
                    ? {'outbounds': [entry]} : entry));
            if (profile == null || profile.nodes.isEmpty) continue;
            // XRAY_JSON subscriptions contain one full configuration per item.
            // Its outbounds are implementation details, not extra regions.
            final selected = profile.nodes.firstWhere(
                (node) => node['type'] == 'auto',
                orElse: () => profile.nodes.first);
            final node = Map<String, dynamic>.from(selected);
            final remarks = entry['remarks']?.toString().trim();
            if (remarks != null && remarks.isNotEmpty) node['tag'] = remarks;
            nodes.add(node);
            directRules.addAll(profile.directRules);
            if (profile.notice != null) notices.add(profile.notice!);
          }
          if (nodes.isNotEmpty) return (nodes: nodes, name: null,
              notice: notices.isEmpty ? null : notices.join(' '),
              directRules: directRules);
        }
      } on FormatException {
        // Try the regular subscription formats below.
      }
    }
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
              '$unsupported из ${standard.length} серверов используют неподдерживаемый протокол.',
          directRules: <Map<String, dynamic>>[]);
    }
    try {
      final nodes = parseClashSubscription(content, includeUnsupported: true);
      final unsupported = nodes.where((node) => node['_unsupported_reason'] != null).length;
      return (nodes: nodes, name: null,
          notice: unsupported == 0 ? null :
              '$unsupported из ${nodes.length} серверов используют неподдерживаемый протокол.',
          directRules: <Map<String, dynamic>>[]);
    } catch (_) {
      return (nodes: <Map<String, dynamic>>[], name: null, notice: null,
          directRules: <Map<String, dynamic>>[]);
    }
  }

  Future<({String id, String body, String? title, String? announce,
      String? userInfo, String? updateInterval, String? originalBody})> _downloadPreferXrayJson(
          Uri initial) async {
    final original = await _download(initial);
    final html = looksLikeHtmlSubscriptionResponse(original.body);
    final loopback = needsXrayJsonRetry(original.body);
    if (!loopback && !html) return (
      id: original.id, body: original.body, title: original.title,
      announce: original.announce, userInfo: original.userInfo,
      updateInterval: original.updateInterval, originalBody: null);
    final reason = html ? 'html-response' : 'base64-loopback-template';
    final subscriptionIdentity = identity ??= await SubscriptionIdentity.load();
    final retryUserAgent = subscriptionRetryUserAgent(
        original.body, subscriptionIdentity);
    if (retryUserAgent == null) {
      await requestLog.append({'event': 'compatibility', 'id': original.id,
        'reason': reason, 'result': 'custom-happ-agent-kept'});
      return (id: original.id, body: original.body, title: original.title,
        announce: original.announce, userInfo: original.userInfo,
        updateInterval: original.updateInterval, originalBody: null);
    }
    await requestLog.append({'event': 'compatibility', 'id': original.id,
      'reason': reason, 'action': 'retry-xray-json'});
    try {
      final retried = await _download(initial, requestXrayJson: true,
          retryUserAgent: retryUserAgent);
      final json = retried.body.trimLeft();
      final usable = (html || json.startsWith('{') || json.startsWith('[')) &&
          _parse(retried.body).nodes.isNotEmpty;
      await requestLog.append({'event': 'compatibility', 'id': original.id,
        'retryId': retried.id, 'result': usable ? 'xray-json' : 'original-kept',
        'format': subscriptionBodySummary(retried.body)['format']});
      final selected = usable ? retried : original;
      return (id: selected.id, body: selected.body, title: selected.title,
        announce: selected.announce, userInfo: selected.userInfo,
        updateInterval: selected.updateInterval,
        originalBody: usable && loopback ? original.body : null);
    } catch (error) {
      await requestLog.append({'event': 'compatibility', 'id': original.id,
        'result': 'original-kept', 'retryError': error.runtimeType.toString()});
      return (id: original.id, body: original.body, title: original.title,
        announce: original.announce, userInfo: original.userInfo,
        updateInterval: original.updateInterval, originalBody: null);
    }
  }

  Future<({String id, String body, String? title, String? announce,
      String? userInfo, String? updateInterval})> _download(Uri initial,
          {bool requestXrayJson = false, String? retryUserAgent}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    var stage = 'connect';
    try {
      var uri = initial;
      for (var redirect = 0; redirect < 4; redirect++) {
        stage = 'connect';
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
          throw const FormatException(
            'Переадресация на небезопасный адрес подписки.',
          );
        }
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        final stopwatch = Stopwatch()..start();
        request.followRedirects = false;
        final subscriptionIdentity = identity ??= await SubscriptionIdentity.load();
        final headers = subscriptionIdentity.requestHeaders;
        if (requestXrayJson) {
          headers[HttpHeaders.userAgentHeader] =
              retryUserAgent ?? subscriptionIdentity.xrayJsonUserAgent;
          request.headers.set(HttpHeaders.acceptHeader,
              'application/json, text/plain, */*');
        }
        for (final entry in headers.entries) {
          request.headers.set(entry.key, entry.value);
        }
        if (requestXrayJson || subscriptionIdentity.isHappUserAgent) {
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          request.headers.set('Pragma', 'no-cache');
        }
        final requestHeaderNames = <String>[];
        request.headers.forEach((name, values) =>
            requestHeaderNames.add(name.toLowerCase()));
        requestHeaderNames.sort();
        await requestLog.append({
          'event': 'request', 'id': requestId, 'hop': redirect,
          'xrayJsonRetry': requestXrayJson,
          'method': 'GET', 'target': subscriptionRequestTarget(uri),
          'requestHeaderNames': requestHeaderNames,
          'userAgent': headers[HttpHeaders.userAgentHeader],
          'deviceOs': headers['x-device-os'],
          'deviceModel': headers['x-device-model'],
          'hwidSent': headers.containsKey('x-hwid'),
          'cookieSent': headers.containsKey(HttpHeaders.cookieHeader),
        });
        stage = 'response-headers';
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        final responseHeaders = <String>[];
        response.headers.forEach((name, values) => responseHeaders.add(name));
        responseHeaders.sort();
        final responseInfo = <String, dynamic>{
          'event': 'response', 'id': requestId, 'hop': redirect,
          'status': response.statusCode,
          'headersElapsedMs': stopwatch.elapsedMilliseconds,
          'responseHeaderNames': responseHeaders,
          'contentType': response.headers.contentType?.mimeType,
          'contentEncoding': response.headers.value(HttpHeaders.contentEncodingHeader),
          'profileTitlePresent': response.headers.value('profile-title') != null,
          'announcePresent': response.headers.value('announce') != null,
          'trafficHeaderPresent': response.headers.value('subscription-userinfo') != null,
          'updateIntervalHours': subscriptionUpdateHours(
              response.headers.value('profile-update-interval')),
          'providerIdPresent': response.headers.value('x-provider-id') != null,
        };
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location != null) {
            responseInfo['redirectTarget'] = subscriptionRequestTarget(uri.resolve(location));
          }
          await requestLog.append(responseInfo);
          await response.drain<void>();
          if (location == null)
            throw const FormatException('Пустая переадресация подписки.');
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await requestLog.append(responseInfo);
          await response.drain<void>();
          throw FormatException(
            'Сервер подписки ответил: HTTP ${response.statusCode}.',
          );
        }
        final bytes = <int>[];
        stage = 'response-body';
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
        final body = utf8.decode(bytes);
        responseInfo['bodyBytes'] = bytes.length;
        responseInfo['totalElapsedMs'] = stopwatch.elapsedMilliseconds;
        responseInfo['bodySummary'] = subscriptionBodySummary(body);
        await requestLog.append(responseInfo);
        return (id: requestId, body: body, title: response.headers.value('profile-title'),
            announce: response.headers.value('announce'),
            userInfo: response.headers.value('subscription-userinfo'),
            updateInterval: response.headers.value('profile-update-interval'));
      }
      throw const FormatException('Слишком много переадресаций подписки.');
    } catch (error) {
      await requestLog.append({'event': 'error', 'id': requestId,
        'target': subscriptionRequestTarget(initial),
        'errorType': error.runtimeType.toString(), 'stage': stage});
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

const happHtmlRetryUserAgent = 'Happ/4.4.1/Android/17891107313301967618';

/// A server returning a browser page gets one request with the exact Happ
/// identifier. The earlier Base64 loopback fallback keeps its existing agent.
String? subscriptionRetryUserAgent(String body, SubscriptionIdentity identity) {
  if (looksLikeHtmlSubscriptionResponse(body)) return happHtmlRetryUserAgent;
  if (needsXrayJsonRetry(body) && !identity.isHappUserAgent) {
    return identity.xrayJsonUserAgent;
  }
  return null;
}

/// Base64 links pointing to the phone itself need the server-generated
/// Remnawave template, which the panel returns to Happ-class clients.
bool needsXrayJsonRetry(String body) {
  final summary = subscriptionBodySummary(body);
  return summary['format'] == 'base64-links' &&
      (summary['loopbackLinks'] as int? ?? 0) > 0;
}

/// Gives the inspector a readable second view for Base64 subscriptions.
String? decodedSubscriptionResponse(String body) {
  final text = body.trim();
  if (text.startsWith('{') || text.startsWith('[') || text.contains('://')) {
    return null;
  }
  try {
    final decoded = utf8.decode(base64.decode(base64.normalize(text))).trim();
    if (decoded.startsWith('{') || decoded.startsWith('[') ||
        decoded.contains('://')) return decoded;
  } on FormatException {
    // Plain text responses are displayed without a decoded tab.
  }
  return null;
}
