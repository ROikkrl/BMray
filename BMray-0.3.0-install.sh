#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/BMray
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Есть несохранённые изменения. Проверьте git status." >&2
  exit 1
fi
git pull --ff-only origin main
version=$(sed -n 's/^version: //p' pubspec.yaml)
case "$version" in
  '0.2.4+15' | '0.2.5+16' | '0.2.6+17' | '0.2.7+18' | '0.2.8+19' | '0.2.9+20' | '0.2.10+21' | '0.2.11+22') ;;
  *) echo "Нужна версия 0.2.4+15–0.2.11+22; найдена $version" >&2; exit 1 ;;
esac
patch_dir=$(mktemp -d)
trap 'rm -rf "$patch_dir"' EXIT
cat > "$patch_dir/0.2.5.patch" <<'BMRAY_PATCH_030_0'
diff --git a/lib/json_config_page.dart b/lib/json_config_page.dart
new file mode 100644
index 0000000..c9fcdcc
--- /dev/null
+++ b/lib/json_config_page.dart
@@ -0,0 +1,65 @@
+import 'package:flutter/material.dart';
+import 'package:flutter/services.dart';
+
+class JsonConfigTab {
+  const JsonConfigTab(this.title, this.content);
+
+  final String title;
+  final String content;
+}
+
+/// Keeps subscription credentials on the device; copying is an explicit action.
+class JsonConfigPage extends StatelessWidget {
+  const JsonConfigPage({super.key, required this.title, required this.tabs});
+
+  final String title;
+  final List<JsonConfigTab> tabs;
+
+  @override
+  Widget build(BuildContext context) => DefaultTabController(
+    length: tabs.length,
+    child: Scaffold(
+      appBar: AppBar(
+        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
+        bottom: TabBar(
+          isScrollable: true,
+          tabs: [for (final tab in tabs) Tab(text: tab.title)],
+        ),
+      ),
+      body: TabBarView(children: [
+        for (final tab in tabs)
+          Column(children: [
+            Padding(
+              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
+              child: Row(children: [
+                const Expanded(child: Text(
+                  'JSON может содержать ключи и пароли. Не публикуйте его без удаления секретов.',
+                  style: TextStyle(fontSize: 12, color: Color(0xFF9DAEC7)),
+                )),
+                IconButton(
+                  tooltip: 'Копировать JSON',
+                  icon: const Icon(Icons.copy_rounded),
+                  onPressed: () async {
+                    await Clipboard.setData(ClipboardData(text: tab.content));
+                    if (context.mounted) {
+                      ScaffoldMessenger.of(context).showSnackBar(
+                        const SnackBar(content: Text('JSON скопирован')),
+                      );
+                    }
+                  },
+                ),
+              ]),
+            ),
+            Expanded(child: SingleChildScrollView(
+              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
+              child: SingleChildScrollView(
+                scrollDirection: Axis.horizontal,
+                child: SelectableText(tab.content,
+                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
+              ),
+            )),
+          ]),
+      ]),
+    ),
+  );
+}
diff --git a/lib/main.dart b/lib/main.dart
index 5d3f1d7..3f76aa1 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -13,6 +13,7 @@ import 'subscriptions.dart';
 import 'subscription_identity.dart';
 import 'xray_bridge.dart';
 import 'node_label.dart';
+import 'json_config_page.dart';
 
 enum PingMethod { proxyGet, tcp, icmp }
 
@@ -449,6 +450,103 @@ class _HomePageState extends State<HomePage> {
   String _delayKey(Subscription item, int index) =>
       '${item.id}:$index:${_pingMethod.name}';
 
+  String _formatJson(Object? value) {
+    try {
+      return const JsonEncoder.withIndent('  ')
+          .convert(value is String ? jsonDecode(value) : value);
+    } catch (error) {
+      return 'Не удалось сформировать JSON: $error';
+    }
+  }
+
+  void _showSubscriptionJson(Subscription item) {
+    final source = item.rawJson;
+    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
+        JsonConfigPage(title: item.name, tabs: [
+          JsonConfigTab('Ответ подписки', source == null
+              ? 'Исходный JSON ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
+              : _formatJson(source)),
+        ])));
+  }
+
+  void _showNodeJson(Subscription item, int index) {
+    final node = item.nodes[index];
+    final tabs = <JsonConfigTab>[
+      JsonConfigTab('Ответ подписки', item.rawJson == null
+          ? 'Исходный JSON ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
+          : _formatJson(item.rawJson)),
+      JsonConfigTab('Импортированный узел', _formatJson(node)),
+    ];
+    final key = _delayKey(item, index);
+    final diagnostics = <String, dynamic>{
+      'method': _pingMethod.name,
+      'proxyTimeoutSeconds': _proxyTimeoutSeconds,
+      'lastLatencyMs': _latencies[key],
+      'lastError': _pingErrors[key],
+    };
+    try {
+      if (usesXray(node)) {
+        final bridge = buildXrayBridge(node,
+            options: const SingboxConfigOptions(usePlatformDns: true));
+        tabs.add(JsonConfigTab('Xray: подключение', _formatJson(bridge.xray)));
+        tabs.add(JsonConfigTab('sing-box: туннель', _formatJson(bridge.singbox)));
+        diagnostics['note'] = 'Локальный SOCKS порт и пароль генерируются заново при подключении.';
+        final template = node['_xray_template'];
+        if (template is Map && template['routing'] is Map &&
+            template['outbounds'] is List) {
+          final routing = template['routing'] as Map;
+          final balancers = routing['balancers'];
+          if (balancers is List && balancers.isNotEmpty && balancers.first is Map) {
+            final balancer = balancers.first as Map;
+            final selectors = (balancer['selector'] is List)
+                ? (balancer['selector'] as List).map((value) => value.toString()).toList()
+                : <String>[];
+            final outbounds = (template['outbounds'] as List).whereType<Map>().toList();
+            final candidates = outbounds.where((outbound) =>
+                selectors.any((prefix) => (outbound['tag']?.toString() ?? '')
+                    .startsWith(prefix))).toList();
+            final fallback = balancer['fallbackTag']?.toString();
+            diagnostics['selectors'] = selectors;
+            diagnostics['candidates'] = [for (final outbound in candidates)
+              {'tag': outbound['tag'], 'protocol': outbound['protocol'],
+                'vnext': (outbound['settings'] is Map)
+                    ? (outbound['settings'] as Map)['vnext'] : null}];
+            diagnostics['fallbackTag'] = fallback;
+            diagnostics['fallbackExists'] = outbounds.any((entry) => entry['tag'] == fallback);
+            for (final outbound in [
+              if (candidates.isNotEmpty) candidates.first,
+              if (fallback != null) ...outbounds.where((entry) => entry['tag'] == fallback),
+            ]) {
+              final tag = outbound['tag']?.toString();
+              if (tag == null) continue;
+              final probe = buildXrayBridge(node, probe: true,
+                  probeOutboundTag: tag,
+                  options: const SingboxConfigOptions(usePlatformDns: true));
+              tabs.add(JsonConfigTab('Пинг: $tag', _formatJson(probe.xray)));
+            }
+          }
+        } else {
+          final probe = buildXrayBridge(node, probe: true,
+              options: const SingboxConfigOptions(usePlatformDns: true));
+          tabs.add(JsonConfigTab('Xray: пинг', _formatJson(probe.xray)));
+        }
+      } else {
+        final config = buildSingboxConfig(node,
+            options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
+        if (item.directRules.isNotEmpty && node['type'] != 'auto') {
+          (config['route']['rules'] as List).addAll(item.directRules);
+        }
+        tabs.add(JsonConfigTab('sing-box: подключение', _formatJson(config)));
+      }
+    } catch (error) {
+      diagnostics['configError'] = error.toString();
+    }
+    tabs.add(JsonConfigTab('Диагностика', _formatJson(diagnostics)));
+    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
+        JsonConfigPage(title: node['tag']?.toString() ?? 'Сервер ${index + 1}',
+            tabs: tabs)));
+  }
+
   Future<({int? delay, String? reason})> _probeAutoProxy(
       Map<String, dynamic> node) async {
     final template = node['_xray_template'];
@@ -1061,9 +1159,12 @@ class _HomePageState extends State<HomePage> {
               switch (action) {
                 case 'up': _moveSubscription(item, -1); break;
                 case 'down': _moveSubscription(item, 1); break;
+                case 'json': _showSubscriptionJson(item); break;
                 case 'remove': _remove(item); break;
               }
             }, itemBuilder: (_) => [
+              const PopupMenuItem(value: 'json',
+                child: Text('Исходный JSON подписки')),
               PopupMenuItem(value: 'up', enabled: !_busy && !_autoRefreshing && index > 0 &&
                   _subscriptions[index - 1].pinned == item.pinned,
                 child: const Text('Переместить вверх')),
@@ -1175,6 +1276,12 @@ class _HomePageState extends State<HomePage> {
               maxLines: 1, softWrap: false,
               style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                 fontSize: 12, fontWeight: FontWeight.w600)),
+            IconButton(
+              tooltip: 'Просмотр JSON конфигурации',
+              onPressed: () => _showNodeJson(item, index),
+              visualDensity: VisualDensity.compact,
+              icon: const Icon(Icons.data_object_rounded, size: 19),
+            ),
             IconButton(
               tooltip: 'Проверить сервер',
               onPressed: _pingBusy ? null : () => _ping(item, [index]),
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index 76394ca..6b6e26f 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -24,6 +24,7 @@ class Subscription {
     this.updateHours,
     this.lastUpdatedAt,
     this.pinned = false,
+    this.rawJson,
   });
 
   final String id;
@@ -38,6 +39,7 @@ class Subscription {
   int? updateHours;
   DateTime? lastUpdatedAt;
   bool pinned;
+  String? rawJson;
 
   bool get isRemote => Uri.tryParse(url)?.scheme == 'https';
 
@@ -63,6 +65,7 @@ class Subscription {
     updateHours: value['updateHours'] as int?,
     lastUpdatedAt: DateTime.tryParse(value['lastUpdatedAt'] as String? ?? ''),
     pinned: value['pinned'] as bool? ?? false,
+    rawJson: value['rawJson'] as String?,
     );
   }
 
@@ -79,6 +82,7 @@ class Subscription {
     'updateHours': updateHours,
     'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
     'pinned': pinned,
+    'rawJson': rawJson,
   };
 }
 
@@ -121,6 +125,7 @@ class SubscriptionStore {
         directRules: template?.directRules ?? parsed!.directRules,
         notice: template?.notice ?? parsed?.notice,
         customName: name.trim().isNotEmpty,
+        rawJson: _jsonPayload(input),
       );
     }
     final normalized = Uri.tryParse(input);
@@ -180,6 +185,7 @@ class SubscriptionStore {
       traffic: SubscriptionTraffic.fromHeader(downloaded.userInfo),
       updateHours: subscriptionUpdateHours(downloaded.updateInterval),
       lastUpdatedAt: DateTime.now(),
+      rawJson: _jsonPayload(downloaded.body),
     );
   }
 
@@ -202,6 +208,7 @@ class SubscriptionStore {
     item.traffic = SubscriptionTraffic.fromHeader(downloaded.userInfo);
     item.updateHours = subscriptionUpdateHours(downloaded.updateInterval);
     item.lastUpdatedAt = DateTime.now();
+    item.rawJson = _jsonPayload(downloaded.body);
     if (!item.customName) {
       item.name = subscriptionTitle(downloaded.title, downloaded.body) ?? parsed.name ?? item.name;
     }
@@ -331,3 +338,23 @@ class SubscriptionStore {
     }
   }
 }
+
+/// Preserve JSON responses for local inspection. Decode Base64-wrapped JSON.
+String? _jsonPayload(String body) {
+  var text = body.trim();
+  if (!text.startsWith('{') && !text.startsWith('[') &&
+      !text.contains('://')) {
+    try {
+      text = utf8.decode(base64.decode(base64.normalize(text))).trim();
+    } on FormatException {
+      return null;
+    }
+  }
+  if (!text.startsWith('{') && !text.startsWith('[')) return null;
+  try {
+    final parsed = jsonDecode(text);
+    return parsed is Map || parsed is List ? text : null;
+  } on FormatException {
+    return null;
+  }
+}
diff --git a/pubspec.yaml b/pubspec.yaml
index 83c422d..59fe4ab 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.4+15
+version: 0.2.5+16
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 16fd4ee..7430615 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -126,6 +126,14 @@ void main() {
     expect(usesXray(subscription.nodes.single), true);
   });
 
+  test('Imported template retains the original JSON across storage serialization', () async {
+    final imported = await SubscriptionStore().import('', xrayFixture);
+    expect(jsonDecode(imported.rawJson!), jsonDecode(xrayFixture));
+    final restored = Subscription.fromJson(imported.toJson());
+    expect(restored.rawJson, imported.rawJson);
+    expect(restored.nodes.first['_xray_template'], isNotNull);
+  });
+
   test('server subtitles use imported transport and security', () {
     final tcp = parseShareLink(realityLink)!;
     expect(nodeLabel(tcp), 'VLESS / TCP / REALITY');
BMRAY_PATCH_030_0
cat > "$patch_dir/0.2.6.patch" <<'BMRAY_PATCH_030_1'
diff --git a/lib/main.dart b/lib/main.dart
index 3f76aa1..470de5e 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -483,7 +483,20 @@ class _HomePageState extends State<HomePage> {
       'proxyTimeoutSeconds': _proxyTimeoutSeconds,
       'lastLatencyMs': _latencies[key],
       'lastError': _pingErrors[key],
+      'profileKind': node['_xray_template'] is Map
+          ? 'Xray template with balancer'
+          : node['_xray_outbound'] is Map
+              ? 'Individual Xray outbound'
+              : 'Individual server',
     };
+    final server = node['server']?.toString();
+    if (node['type'] != 'auto' && server != null &&
+        (server == 'localhost' ||
+            InternetAddress.tryParse(server)?.isLoopback == true)) {
+      diagnostics['warning'] = 'Этот выход направлен на $server:${node['server_port']} '
+          'на самом телефоне. Он не может достичь удалённого VPN-сервера '
+          'без отдельного локального прокси. Сравните ответ подписки с конфигом HAPP.';
+    }
     try {
       if (usesXray(node)) {
         final bridge = buildXrayBridge(node,
diff --git a/lib/xray_bridge.dart b/lib/xray_bridge.dart
index 4cd6868..fc64774 100644
--- a/lib/xray_bridge.dart
+++ b/lib/xray_bridge.dart
@@ -148,6 +148,11 @@ Map<String, dynamic> _autoRouting(Map template) {
 Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
   final transport = node['transport'] as Map;
   final tls = node['tls'] as Map?;
+  final sni = tls?['server_name']?.toString();
+  final transportHost = transport['host']?.toString();
+  final serverName = sni != null && sni.isNotEmpty ? sni
+      : transportHost != null && transportHost.isNotEmpty ? transportHost
+      : node['server'];
   final reality = tls?['reality'] as Map?;
   final xhttp = <String, dynamic>{
     if (transport['path'] != null) 'path': transport['path'],
@@ -161,14 +166,14 @@ Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
     'network': 'xhttp', 'security': security,
     'xhttpSettings': xhttp,
     if (security == 'reality') 'realitySettings': {
-      'serverName': tls?['server_name'] ?? node['server'],
+      'serverName': serverName,
       'publicKey': reality?['public_key'],
       'shortId': reality?['short_id'] ?? '',
       if (reality?['spider_x'] != null) 'spiderX': reality?['spider_x'],
       'fingerprint': fp ?? 'chrome',
     },
     if (security == 'tls') 'tlsSettings': {
-      'serverName': tls?['server_name'] ?? node['server'],
+      'serverName': serverName,
       if (fp != null) 'fingerprint': fp,
       if (tls?['alpn'] is List) 'alpn': tls?['alpn'],
       if (tls?['insecure'] == true) 'allowInsecure': true,
diff --git a/packages/vpn_plugin/lib/src/share_link_parser.dart b/packages/vpn_plugin/lib/src/share_link_parser.dart
index d3906cf..ccaef89 100644
--- a/packages/vpn_plugin/lib/src/share_link_parser.dart
+++ b/packages/vpn_plugin/lib/src/share_link_parser.dart
@@ -311,9 +311,13 @@ Map<String, dynamic>? _unsupportedXhttpLink(String link) {
   if (parts.params['flow']?.isNotEmpty == true) node['flow'] = parts.params['flow'];
   final security = (parts.params['security'] ?? 'none').toLowerCase();
   if (security == 'tls' || security == 'reality') {
+    final sni = parts.params['sni'];
+    final transportHost = parts.params['host'];
     node['tls'] = {
       'enabled': true,
-      'server_name': parts.params['sni'] ?? parts.host,
+      'server_name': sni != null && sni.isNotEmpty ? sni
+          : transportHost != null && transportHost.isNotEmpty
+              ? transportHost : parts.host,
       if (parts.params['fp']?.isNotEmpty == true)
         'utls': {'enabled': true, 'fingerprint': parts.params['fp']},
       if (parts.params['alpn']?.isNotEmpty == true)
diff --git a/pubspec.yaml b/pubspec.yaml
index 59fe4ab..3716779 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.5+16
+version: 0.2.6+17
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 7430615..28bc1eb 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -72,6 +72,18 @@ void main() {
     expect(stream['realitySettings']['shortId'], '0123456789abcdef');
   });
 
+  test('XHTTP TLS uses transport host when an explicit SNI is empty', () {
+    final node = parseShareLink(
+      'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
+      '?type=xhttp&security=tls&sni=&host=cdn.example.com&path=%2Ffile#Test',
+      includeUnsupported: true,
+    )!;
+    expect(node['tls']['server_name'], 'cdn.example.com');
+    node['tls']['server_name'] = '';
+    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
+    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
+  });
+
   test('Xray Hysteria2 JSON is preserved for the Android core', () {
     final template = parseXrayTemplate(hysteriaXrayFixture)!;
     expect(template.nodes, hasLength(1));
BMRAY_PATCH_030_1
cat > "$patch_dir/0.2.7.patch" <<'BMRAY_PATCH_030_2'
diff --git a/lib/main.dart b/lib/main.dart
index 470de5e..d48f7f6 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -459,22 +459,37 @@ class _HomePageState extends State<HomePage> {
     }
   }
 
+  String _formatSource(String source) {
+    try {
+      return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
+    } on FormatException {
+      return source;
+    }
+  }
+
   void _showSubscriptionJson(Subscription item) {
-    final source = item.rawJson;
+    final source = item.rawResponse;
+    final decoded = source == null ? null : decodedSubscriptionResponse(source);
     Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
         JsonConfigPage(title: item.name, tabs: [
           JsonConfigTab('Ответ подписки', source == null
-              ? 'Исходный JSON ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
-              : _formatJson(source)),
+              ? 'Исходный ответ ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
+              : _formatSource(source)),
+          if (decoded != null)
+            JsonConfigTab('Декодировано', _formatSource(decoded)),
         ])));
   }
 
   void _showNodeJson(Subscription item, int index) {
     final node = item.nodes[index];
+    final source = item.rawResponse;
+    final decoded = source == null ? null : decodedSubscriptionResponse(source);
     final tabs = <JsonConfigTab>[
-      JsonConfigTab('Ответ подписки', item.rawJson == null
-          ? 'Исходный JSON ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
-          : _formatJson(item.rawJson)),
+      JsonConfigTab('Ответ подписки', source == null
+          ? 'Исходный ответ ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
+          : _formatSource(source)),
+      if (decoded != null)
+        JsonConfigTab('Декодировано', _formatSource(decoded)),
       JsonConfigTab('Импортированный узел', _formatJson(node)),
     ];
     final key = _delayKey(item, index);
@@ -1177,7 +1192,7 @@ class _HomePageState extends State<HomePage> {
               }
             }, itemBuilder: (_) => [
               const PopupMenuItem(value: 'json',
-                child: Text('Исходный JSON подписки')),
+                child: Text('Ответ подписки')),
               PopupMenuItem(value: 'up', enabled: !_busy && !_autoRefreshing && index > 0 &&
                   _subscriptions[index - 1].pinned == item.pinned,
                 child: const Text('Переместить вверх')),
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index 6b6e26f..5a6f788 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -24,7 +24,7 @@ class Subscription {
     this.updateHours,
     this.lastUpdatedAt,
     this.pinned = false,
-    this.rawJson,
+    this.rawResponse,
   });
 
   final String id;
@@ -39,7 +39,7 @@ class Subscription {
   int? updateHours;
   DateTime? lastUpdatedAt;
   bool pinned;
-  String? rawJson;
+  String? rawResponse;
 
   bool get isRemote => Uri.tryParse(url)?.scheme == 'https';
 
@@ -65,7 +65,7 @@ class Subscription {
     updateHours: value['updateHours'] as int?,
     lastUpdatedAt: DateTime.tryParse(value['lastUpdatedAt'] as String? ?? ''),
     pinned: value['pinned'] as bool? ?? false,
-    rawJson: value['rawJson'] as String?,
+    rawResponse: value['rawResponse'] as String? ?? value['rawJson'] as String?,
     );
   }
 
@@ -82,7 +82,7 @@ class Subscription {
     'updateHours': updateHours,
     'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
     'pinned': pinned,
-    'rawJson': rawJson,
+    'rawResponse': rawResponse,
   };
 }
 
@@ -125,7 +125,7 @@ class SubscriptionStore {
         directRules: template?.directRules ?? parsed!.directRules,
         notice: template?.notice ?? parsed?.notice,
         customName: name.trim().isNotEmpty,
-        rawJson: _jsonPayload(input),
+        rawResponse: input,
       );
     }
     final normalized = Uri.tryParse(input);
@@ -154,6 +154,7 @@ class SubscriptionStore {
         url: input,
         nodes: [node],
         notice: node['_unsupported_reason']?.toString(),
+        rawResponse: input,
       );
     }
     if (normalized == null ||
@@ -185,7 +186,7 @@ class SubscriptionStore {
       traffic: SubscriptionTraffic.fromHeader(downloaded.userInfo),
       updateHours: subscriptionUpdateHours(downloaded.updateInterval),
       lastUpdatedAt: DateTime.now(),
-      rawJson: _jsonPayload(downloaded.body),
+      rawResponse: downloaded.body,
     );
   }
 
@@ -208,7 +209,7 @@ class SubscriptionStore {
     item.traffic = SubscriptionTraffic.fromHeader(downloaded.userInfo);
     item.updateHours = subscriptionUpdateHours(downloaded.updateInterval);
     item.lastUpdatedAt = DateTime.now();
-    item.rawJson = _jsonPayload(downloaded.body);
+    item.rawResponse = downloaded.body;
     if (!item.customName) {
       item.name = subscriptionTitle(downloaded.title, downloaded.body) ?? parsed.name ?? item.name;
     }
@@ -339,22 +340,18 @@ class SubscriptionStore {
   }
 }
 
-/// Preserve JSON responses for local inspection. Decode Base64-wrapped JSON.
-String? _jsonPayload(String body) {
-  var text = body.trim();
-  if (!text.startsWith('{') && !text.startsWith('[') &&
-      !text.contains('://')) {
-    try {
-      text = utf8.decode(base64.decode(base64.normalize(text))).trim();
-    } on FormatException {
-      return null;
-    }
+/// Gives the inspector a readable second view for Base64 subscriptions.
+String? decodedSubscriptionResponse(String body) {
+  final text = body.trim();
+  if (text.startsWith('{') || text.startsWith('[') || text.contains('://')) {
+    return null;
   }
-  if (!text.startsWith('{') && !text.startsWith('[')) return null;
   try {
-    final parsed = jsonDecode(text);
-    return parsed is Map || parsed is List ? text : null;
+    final decoded = utf8.decode(base64.decode(base64.normalize(text))).trim();
+    if (decoded.startsWith('{') || decoded.startsWith('[') ||
+        decoded.contains('://')) return decoded;
   } on FormatException {
-    return null;
+    // Plain text responses are displayed without a decoded tab.
   }
+  return null;
 }
diff --git a/pubspec.yaml b/pubspec.yaml
index 3716779..5884a69 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.6+17
+version: 0.2.7+18
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 28bc1eb..66f00b2 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -140,12 +140,21 @@ void main() {
 
   test('Imported template retains the original JSON across storage serialization', () async {
     final imported = await SubscriptionStore().import('', xrayFixture);
-    expect(jsonDecode(imported.rawJson!), jsonDecode(xrayFixture));
+    expect(jsonDecode(imported.rawResponse!), jsonDecode(xrayFixture));
     final restored = Subscription.fromJson(imported.toJson());
-    expect(restored.rawJson, imported.rawJson);
+    expect(restored.rawResponse, imported.rawResponse);
     expect(restored.nodes.first['_xray_template'], isNotNull);
   });
 
+  test('Base64 link subscription can be inspected without losing its response', () {
+    final body = base64Encode(utf8.encode('$realityLink\n$realityLink'));
+    final subscription = Subscription(id: 'test', name: 'Test',
+        url: 'https://example.com/sub', nodes: [], rawResponse: body);
+    final restored = Subscription.fromJson(subscription.toJson());
+    expect(restored.rawResponse, body);
+    expect(decodedSubscriptionResponse(body), '$realityLink\n$realityLink');
+  });
+
   test('server subtitles use imported transport and security', () {
     final tcp = parseShareLink(realityLink)!;
     expect(nodeLabel(tcp), 'VLESS / TCP / REALITY');
BMRAY_PATCH_030_2
cat > "$patch_dir/0.2.8.patch" <<'BMRAY_PATCH_030_3'
diff --git a/lib/main.dart b/lib/main.dart
index d48f7f6..35d4f43 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -14,6 +14,7 @@ import 'subscription_identity.dart';
 import 'xray_bridge.dart';
 import 'node_label.dart';
 import 'json_config_page.dart';
+import 'remnawave_template.dart';
 
 enum PingMethod { proxyGet, tcp, icmp }
 
@@ -328,6 +329,7 @@ class _HomePageState extends State<HomePage> {
   }
 
   Future<void> _toggle() async {
+    if (_pingBusy) return;
     final item = _selected;
     if (_status.state == VpnState.connected) {
       setState(() => _setStatus(const VpnStatus(VpnState.disconnecting)));
@@ -341,8 +343,13 @@ class _HomePageState extends State<HomePage> {
       });
       return;
     }
-    if (item == null || item.nodes.isEmpty || _status.state.isBusy) return;
-    await _perform(() async {
+    if (item == null || item.nodes.isEmpty || _status.state.isBusy || _pingBusy) return;
+    await _perform(_startSelected);
+  }
+
+  Future<void> _startSelected() async {
+      final item = _selected;
+      if (item == null || item.nodes.isEmpty) return;
       final node = item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
       if (node['_unsupported_reason'] != null) {
         throw FormatException(node['_unsupported_reason'].toString());
@@ -364,6 +371,68 @@ class _HomePageState extends State<HomePage> {
       if (validationError != null) throw FormatException(validationError);
       await _vpn.start(configJson, name: 'BMray',
           xrayConfig: bridge == null ? null : jsonEncode(bridge.xray));
+  }
+
+  Future<void> _waitForDisconnect() async {
+    for (var attempt = 0; attempt < 60; attempt++) {
+      if ((await _vpn.currentStatus()).state == VpnState.disconnected) return;
+      await Future<void>.delayed(const Duration(milliseconds: 100));
+    }
+    throw const FormatException('VPN не успел отключиться. Повторите попытку.');
+  }
+
+  Future<void> _selectServer(Subscription item, int index) async {
+    if (_busy || _pingBusy || _status.state.isBusy ||
+        (_selected?.id == item.id && _nodeIndex == index)) return;
+    if (_status.state == VpnState.connected) {
+      await _perform(() async {
+        await _vpn.stop();
+        await _waitForDisconnect();
+        if (!mounted) return;
+        setState(() {
+          _subscriptionId = item.id;
+          _nodeIndex = index;
+        });
+        _rememberSelection();
+        await _startSelected();
+      });
+    } else {
+      setState(() {
+        _subscriptionId = item.id;
+        _nodeIndex = index;
+      });
+      _rememberSelection();
+    }
+  }
+
+  Future<void> _attachAutoTemplate(Subscription item, int index) async {
+    final input = TextEditingController(text: item.autoTemplates[
+        item.nodes[index]['tag']?.toString() ?? ''] ?? '');
+    final apply = await showDialog<bool>(context: context, builder: (ctx) =>
+      AlertDialog(
+        title: const Text('Шаблон АвтоБС'),
+        content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
+          mainAxisSize: MainAxisSize.min, children: [
+            const Text('Вставьте Xray JSON шаблон этого хоста из Remnawave. '
+                'В ответе подписки injectHosts отсутствует.'),
+            TextField(controller: input, maxLines: 12, minLines: 5,
+                decoration: const InputDecoration(hintText: '{ "remnawave": ... }')),
+          ],
+        ))),
+        actions: [
+          TextButton(onPressed: () => Navigator.pop(ctx, false),
+              child: const Text('Отмена')),
+          FilledButton(onPressed: () => Navigator.pop(ctx, true),
+              child: const Text('Привязать')),
+        ],
+      ));
+    final raw = input.text;
+    input.dispose();
+    if (apply != true) return;
+    await _perform(() async {
+      _store.attachAutoTemplate(item, index, raw);
+      await _store.save(_subscriptions);
+      if (mounted) setState(() {});
     });
   }
 
@@ -503,6 +572,8 @@ class _HomePageState extends State<HomePage> {
           : node['_xray_outbound'] is Map
               ? 'Individual Xray outbound'
               : 'Individual server',
+      if (node['_template_warning'] != null)
+        'templateWarning': node['_template_warning'],
     };
     final server = node['server']?.toString();
     if (node['type'] != 'auto' && server != null &&
@@ -713,11 +784,7 @@ class _HomePageState extends State<HomePage> {
   }
 
   Future<void> _ping(Subscription item, List<int> indices) async {
-    if (_pingBusy) return;
-    if (_pingMethod == PingMethod.icmp && _status.state.isActive) {
-      setState(() => _error = 'Для ICMP отключите VPN: ICMP не проходит через прокси.');
-      return;
-    }
+    if (_pingBusy || _busy || _status.state.isBusy) return;
     setState(() {
       _pingBusy = true;
       _error = null;
@@ -728,6 +795,14 @@ class _HomePageState extends State<HomePage> {
     });
     final method = _pingMethod;
     try {
+      if (_status.state == VpnState.connected) {
+        await _vpn.stop();
+        await _waitForDisconnect();
+        await Future<void>.delayed(const Duration(milliseconds: 250));
+      }
+      if (await _vpn.otherVpnActive()) {
+        throw const FormatException('Выключите VPN другого приложения в настройках Android перед проверкой.');
+      }
       for (var start = 0; start < indices.length; start += 3) {
         final batch = indices.skip(start).take(3).toList();
         final values = await Future.wait(batch.map((i) => _probe(item.nodes[i])));
@@ -741,6 +816,9 @@ class _HomePageState extends State<HomePage> {
           }
         });
       }
+    } catch (error) {
+      if (mounted) setState(() => _error = error is FormatException
+          ? error.message : 'Проверка серверов не удалась.');
     } finally {
       if (mounted) setState(() => _pingBusy = false);
     }
@@ -799,7 +877,7 @@ class _HomePageState extends State<HomePage> {
     final isActive = _status.state == VpnState.connected;
     final isConnecting = _status.state == VpnState.connecting;
     final canChange =
-        !_busy && !_autoRefreshing && !_status.state.isActive && !_status.state.isBusy;
+        !_busy && !_pingBusy && !_autoRefreshing && !_status.state.isBusy;
     final label = switch (_status.state) {
       VpnState.connected => 'Подключено',
       VpnState.connecting => 'Подключение…',
@@ -889,7 +967,7 @@ class _HomePageState extends State<HomePage> {
       bool isActive, bool isConnecting) {
     final node = item == null || item.nodes.isEmpty ? null
         : item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
-    final canToggle = !_busy && (!_pingBusy || isActive) &&
+    final canToggle = !_busy && !_pingBusy &&
         _status.state != VpnState.disconnecting &&
         _status.state != VpnState.reasserting && !isConnecting &&
         (isActive || (node != null && node['_unsupported_reason'] == null));
@@ -1200,7 +1278,7 @@ class _HomePageState extends State<HomePage> {
                   index < _subscriptions.length - 1 &&
                   _subscriptions[index + 1].pinned == item.pinned,
                 child: const Text('Переместить вниз')),
-              PopupMenuItem(value: 'remove', enabled: canChange,
+              PopupMenuItem(value: 'remove', enabled: canChange && !_status.state.isActive,
                 child: const Text('Удалить')),
             ]),
         ])),
@@ -1227,7 +1305,8 @@ class _HomePageState extends State<HomePage> {
                 () => _ping(item, List.generate(item.nodes.length, (i) => i)),
               icon: const Icon(Icons.speed_rounded, size: 20)),
             IconButton(tooltip: 'Обновить подписку',
-              onPressed: canChange && item.isRemote ? () => _refresh(item) : null,
+              onPressed: canChange && !_status.state.isActive && item.isRemote
+                  ? () => _refresh(item) : null,
               icon: const Icon(Icons.refresh_rounded, size: 20)),
             Text('${item.nodes.length}', style: const TextStyle(
               color: Color(0xFF9DAEC7))),
@@ -1275,13 +1354,8 @@ class _HomePageState extends State<HomePage> {
       ),
       child: InkWell(
         borderRadius: BorderRadius.circular(20),
-        onTap: canChange && unsupported == null ? () {
-          setState(() {
-            _subscriptionId = item.id;
-            _nodeIndex = index;
-          });
-          _rememberSelection();
-        } : null,
+        onTap: canChange && unsupported == null
+            ? () => _selectServer(item, index) : null,
         child: Padding(
           padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
           child: Row(children: [
@@ -1295,6 +1369,10 @@ class _HomePageState extends State<HomePage> {
               if (unsupported != null) Text(unsupported,
                 maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                 style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
+              if (node['_template_warning'] != null) Text(
+                node['_template_warning'].toString(), maxLines: 1,
+                overflow: TextOverflow.ellipsis,
+                style: const TextStyle(fontSize: 11, color: Color(0xFFFFC58F))),
               if (_pingErrors[key] != null) Text(_pingErrors[key]!,
                 maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                 style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
@@ -1304,6 +1382,13 @@ class _HomePageState extends State<HomePage> {
               maxLines: 1, softWrap: false,
               style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                 fontSize: 12, fontWeight: FontWeight.w600)),
+            if (isLocalTemplateHost(node)) IconButton(
+              tooltip: 'Привязать Xray JSON шаблон АвтоБС',
+              onPressed: _busy || _status.state.isActive ? null
+                  : () => _attachAutoTemplate(item, index),
+              visualDensity: VisualDensity.compact,
+              icon: const Icon(Icons.account_tree_outlined, size: 19),
+            ),
             IconButton(
               tooltip: 'Просмотр JSON конфигурации',
               onPressed: () => _showNodeJson(item, index),
diff --git a/lib/remnawave_template.dart b/lib/remnawave_template.dart
new file mode 100644
index 0000000..9412cc6
--- /dev/null
+++ b/lib/remnawave_template.dart
@@ -0,0 +1,80 @@
+import 'dart:convert';
+
+import 'xray_bridge.dart';
+
+bool isLocalTemplateHost(Map<String, dynamic> node) =>
+    node['server'] == '127.0.0.1' || node['server'] == '::1' ||
+    node['server'] == 'localhost';
+
+/// The subscription contains links, while Remnawave keeps injectHosts in a
+/// separate server-side template. This binds a pasted template to one host.
+Map<String, dynamic> injectRemnawaveTemplate(
+    String source, List<Map<String, dynamic>> nodes, String hostTag) {
+  final decoded = jsonDecode(source);
+  if (decoded is! Map || decoded['remnawave'] is! Map ||
+      (decoded['remnawave'] as Map)['injectHosts'] is! List ||
+      decoded['routing'] is! Map ||
+      (decoded['routing'] as Map)['balancers'] is! List) {
+    throw const FormatException('Нужен Xray JSON шаблон Remnawave с injectHosts и balancers.');
+  }
+  final hostIndex = nodes.indexWhere((node) =>
+      node['tag'] == hostTag && isLocalTemplateHost(node));
+  if (hostIndex < 0) {
+    throw const FormatException('Локальный хост АвтоБС отсутствует в подписке.');
+  }
+  final injected = <Map<String, dynamic>>[];
+  final missing = <String>[];
+  for (final rule in (decoded['remnawave'] as Map)['injectHosts'] as List) {
+    if (rule is! Map || rule['selector'] is! Map ||
+        (rule['selector'] as Map)['type'] != 'remarkRegex') continue;
+    final prefix = rule['tagPrefix']?.toString() ?? '';
+    final pattern = (rule['selector'] as Map)['pattern']?.toString() ?? '';
+    if (prefix.isEmpty || pattern.isEmpty) continue;
+    final matcher = RegExp(pattern, caseSensitive: false);
+    final matching = nodes.where((node) =>
+        !isLocalTemplateHost(node) && node['type'] == 'vless' &&
+        matcher.hasMatch(node['tag']?.toString() ?? '')).toList();
+    if (matching.isEmpty) missing.add(prefix);
+    for (var i = 0; i < matching.length; i++) {
+      final outbound = xrayOutboundFromNode(matching[i]);
+      outbound['tag'] = i == 0 ? prefix : '$prefix-${i + 1}';
+      injected.add(outbound);
+    }
+  }
+  final routing = jsonDecode(jsonEncode(decoded['routing'])) as Map<String, dynamic>;
+  final balancers = routing['balancers'] as List;
+  for (final balancer in balancers.whereType<Map>()) {
+    final prefixes = balancer['selector'] is List
+        ? (balancer['selector'] as List).map((e) => e.toString()) : <String>[];
+    if (!injected.any((outbound) => prefixes.any(
+        (prefix) => outbound['tag'].toString().startsWith(prefix)))) {
+      throw const FormatException('Шаблон не нашёл основных серверов по remarkRegex.');
+    }
+    if (!injected.any((outbound) => outbound['tag'] == balancer['fallbackTag'])) {
+      balancer.remove('fallbackTag');
+    }
+  }
+  final baseOutbounds = decoded['outbounds'] is List
+      ? (decoded['outbounds'] as List).whereType<Map>().where((outbound) =>
+          outbound['protocol'] == 'freedom' || outbound['protocol'] == 'blackhole')
+          .map((outbound) => Map<String, dynamic>.from(outbound)).toList()
+      : <Map<String, dynamic>>[];
+  if (!baseOutbounds.any((outbound) => outbound['tag'] == 'direct')) {
+    baseOutbounds.add({'tag': 'direct', 'protocol': 'freedom'});
+  }
+  final host = Map<String, dynamic>.from(nodes[hostIndex]);
+  host['type'] = 'auto';
+  host.remove('_unsupported_reason');
+  host['_xray_template'] = {
+    'outbounds': [...injected, ...baseOutbounds],
+    'routing': routing,
+    if (decoded['dns'] is Map) 'dns': decoded['dns'],
+    if (decoded['burstObservatory'] is Map)
+      'burstObservatory': decoded['burstObservatory'],
+  };
+  if (missing.isNotEmpty) {
+    host['_template_warning'] = 'В подписке не найдены: ${missing.join(', ')}. '
+        'Скрытые хосты панель не передала; отсутствующий fallback отключён.';
+  }
+  return host;
+}
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index 5a6f788..d2949d5 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -9,6 +9,7 @@ import 'subscription_title.dart';
 import 'subscription_metadata.dart';
 import 'subscription_identity.dart';
 import 'xray_subscription.dart';
+import 'remnawave_template.dart';
 
 class Subscription {
   Subscription({
@@ -25,6 +26,7 @@ class Subscription {
     this.lastUpdatedAt,
     this.pinned = false,
     this.rawResponse,
+    this.autoTemplates = const {},
   });
 
   final String id;
@@ -40,6 +42,7 @@ class Subscription {
   DateTime? lastUpdatedAt;
   bool pinned;
   String? rawResponse;
+  Map<String, String> autoTemplates;
 
   bool get isRemote => Uri.tryParse(url)?.scheme == 'https';
 
@@ -66,6 +69,8 @@ class Subscription {
     lastUpdatedAt: DateTime.tryParse(value['lastUpdatedAt'] as String? ?? ''),
     pinned: value['pinned'] as bool? ?? false,
     rawResponse: value['rawResponse'] as String? ?? value['rawJson'] as String?,
+    autoTemplates: (value['autoTemplates'] as Map? ?? {}).map(
+        (key, value) => MapEntry(key.toString(), value.toString())),
     );
   }
 
@@ -83,6 +88,7 @@ class Subscription {
     'lastUpdatedAt': lastUpdatedAt?.toIso8601String(),
     'pinned': pinned,
     'rawResponse': rawResponse,
+    'autoTemplates': autoTemplates,
   };
 }
 
@@ -203,6 +209,18 @@ class SubscriptionStore {
         'В обновлённой подписке нет распознанных серверов.',
       );
     item.nodes = parsed.nodes;
+    for (final template in item.autoTemplates.entries) {
+      final index = item.nodes.indexWhere((node) =>
+          node['tag'] == template.key && isLocalTemplateHost(node));
+      if (index >= 0) {
+        try {
+          item.nodes[index] = injectRemnawaveTemplate(
+              template.value, item.nodes, template.key);
+        } on FormatException {
+          // Preserve the new subscription and let the user reattach its template.
+        }
+      }
+    }
     item.notice = parsed.notice;
     item.directRules = parsed.directRules;
     item.announcement = subscriptionAnnouncement(downloaded.announce);
@@ -215,6 +233,14 @@ class SubscriptionStore {
     }
   }
 
+  void attachAutoTemplate(Subscription item, int index, String raw) {
+    final node = item.nodes[index];
+    final tag = node['tag']?.toString() ?? '';
+    final assembled = injectRemnawaveTemplate(raw, item.nodes, tag);
+    item.nodes[index] = assembled;
+    item.autoTemplates = {...item.autoTemplates, tag: raw};
+  }
+
   ({List<Map<String, dynamic>> nodes, String? name, String? notice,
       List<Map<String, dynamic>> directRules}) _parse(String content) {
     final trimmed = content.trim();
diff --git a/lib/xray_bridge.dart b/lib/xray_bridge.dart
index fc64774..92b891f 100644
--- a/lib/xray_bridge.dart
+++ b/lib/xray_bridge.dart
@@ -30,7 +30,7 @@ XrayBridge buildXrayBridge(Map<String, dynamic> node, {
   final raw = node['_xray_outbound'];
   final outbound = template is Map ? <String, dynamic>{} : raw is Map
       ? jsonDecode(jsonEncode(raw)) as Map<String, dynamic>
-      : _toXrayOutbound(node);
+      : xrayOutboundFromNode(node);
   if (template is! Map) outbound['tag'] = 'proxy';
   final templateOutbounds = template is Map
       ? jsonDecode(jsonEncode(template['outbounds'])) as List
@@ -145,8 +145,13 @@ Map<String, dynamic> _autoRouting(Map template) {
   };
 }
 
-Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
-  final transport = node['transport'] as Map;
+/// Converts an imported VLESS link into an Xray outbound for injected hosts.
+Map<String, dynamic> xrayOutboundFromNode(Map<String, dynamic> node) {
+  if (node['type'] != 'vless') {
+    throw const FormatException('Шаблон АвтоБС поддерживает VLESS узлы');
+  }
+  final transport = node['transport'] is Map ? node['transport'] as Map : <String, dynamic>{};
+  final network = transport['type']?.toString() ?? 'tcp';
   final tls = node['tls'] as Map?;
   final sni = tls?['server_name']?.toString();
   final transportHost = transport['host']?.toString();
@@ -163,8 +168,12 @@ Map<String, dynamic> _toXrayOutbound(Map<String, dynamic> node) {
   final security = reality != null ? 'reality' : tls == null ? 'none' : 'tls';
   final fp = (tls?['utls'] as Map?)?['fingerprint'];
   final stream = <String, dynamic>{
-    'network': 'xhttp', 'security': security,
-    'xhttpSettings': xhttp,
+    'network': network, 'security': security,
+    if (network == 'xhttp') 'xhttpSettings': xhttp,
+    if (network == 'grpc') 'grpcSettings': {
+      'serviceName': transport['service_name'] ?? '',
+      if (transport['multi_mode'] == true) 'multiMode': true,
+    },
     if (security == 'reality') 'realitySettings': {
       'serverName': serverName,
       'publicKey': reality?['public_key'],
diff --git a/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt b/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
index e010c71..98c018c 100644
--- a/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
+++ b/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
@@ -112,6 +112,14 @@ class FlutterSingboxVpnPlugin :
                 result.success(null)
             }
             "stop" -> { stopVpn(); result.success(null) }
+            "otherVpnActive" -> {
+                val cm = context.getSystemService(ConnectivityManager::class.java)
+                val activeVpn = cm.activeNetwork?.let { network ->
+                    cm.getNetworkCapabilities(network)?.hasTransport(
+                        NetworkCapabilities.TRANSPORT_VPN)
+                } == true
+                result.success(activeVpn && SingBoxVpnService.state != "connected")
+            }
             "status" -> result.success(mapOf(
                 "state" to SingBoxVpnService.state,
                 "connectedAtMillis" to SingBoxVpnService.connectedAtMillis,
diff --git a/packages/vpn_plugin/lib/src/singbox_vpn.dart b/packages/vpn_plugin/lib/src/singbox_vpn.dart
index 4f264b7..afc7528 100644
--- a/packages/vpn_plugin/lib/src/singbox_vpn.dart
+++ b/packages/vpn_plugin/lib/src/singbox_vpn.dart
@@ -54,6 +54,15 @@ class SingboxVpn {
   /// Stop the tunnel.
   Future<void> stop() => _methods.invokeMethod<void>('stop');
 
+  /// Reports an Android VPN transport after this application's tunnel stops.
+  Future<bool> otherVpnActive() async {
+    try {
+      return await _methods.invokeMethod<bool>('otherVpnActive') ?? false;
+    } on MissingPluginException {
+      return false;
+    }
+  }
+
   /// One-shot current status.
   Future<VpnStatus> currentStatus() async {
     final res = await _methods.invokeMethod<dynamic>('status');
diff --git a/pubspec.yaml b/pubspec.yaml
index 5884a69..425f0c8 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.7+18
+version: 0.2.8+19
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 66f00b2..b089b8d 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -2,6 +2,7 @@ import 'dart:convert';
 
 import 'package:bmray/xray_subscription.dart';
 import 'package:bmray/xray_bridge.dart';
+import 'package:bmray/remnawave_template.dart';
 import 'package:bmray/node_label.dart';
 import 'package:bmray/subscriptions.dart';
 import 'package:flutter_test/flutter_test.dart';
@@ -12,6 +13,50 @@ import 'fixtures.dart';
 
 
 void main() {
+  test('Remnawave selector injects real endpoints and drops absent fallback', () {
+    const uuid = '00000000-0000-4000-8000-000000000001';
+    final links = [
+      'vless://$uuid@one.example.com:443?type=xhttp&security=reality&'
+          'sni=www.example.org&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
+          '&sid=0123456789abcdef&path=%2Ftest#Estonia%20%232',
+      'vless://$uuid@two.example.com:4444?type=tcp&flow=xtls-rprx-vision&'
+          'security=reality&sni=www.example.org&'
+          'pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
+          '&sid=0123456789abcdef#Estonia%20%232%20(backup)',
+      'vless://$uuid@127.0.0.1:237?type=xhttp&security=tls#Estonia%20Auto',
+    ];
+    final nodes = links.map((link) =>
+        parseShareLink(link, includeUnsupported: true)!).toList();
+    final json = jsonEncode({
+      'routing': {'rules': [
+        {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto_wifi'}
+      ], 'balancers': [{
+        'tag': 'auto_wifi', 'selector': ['WIFI_'],
+        'strategy': {'type': 'leastPing'}, 'fallbackTag': 'FALLBACK_'
+      }]},
+      'outbounds': [{'tag': 'direct', 'protocol': 'freedom'}],
+      'remnawave': {'injectHosts': [
+        {'selector': {'type': 'remarkRegex', 'pattern': 'Estonia #2'},
+          'tagPrefix': 'WIFI_', 'selectFrom': 'NOT_HIDDEN'},
+        {'selector': {'type': 'remarkRegex', 'pattern': r'Estonia \(BS\)'},
+          'tagPrefix': 'FALLBACK_', 'selectFrom': 'ALL'},
+      ]},
+    });
+    final node = injectRemnawaveTemplate(json, nodes, 'Estonia Auto');
+    expect(node['type'], 'auto');
+    expect(node['_template_warning'], contains('FALLBACK_'));
+    final bridge = buildXrayBridge(node);
+    final outbounds = bridge.xray['outbounds'] as List;
+    expect(outbounds.map((o) => o['tag']), ['WIFI_', 'WIFI_-2', 'direct']);
+    expect(outbounds[0]['settings']['vnext'][0]['address'], 'one.example.com');
+    expect(outbounds[1]['settings']['vnext'][0]['address'], 'two.example.com');
+    expect(outbounds[1]['settings']['vnext'][0]['users'][0]['flow'],
+        'xtls-rprx-vision');
+    expect(bridge.xray['routing']['balancers'][0].containsKey('fallbackTag'), false);
+    final item = Subscription(id: '1', name: 'test', url: 'https://example.com/sub',
+        nodes: nodes, autoTemplates: {'Estonia Auto': json});
+    expect(Subscription.fromJson(item.toJson()).autoTemplates['Estonia Auto'], json);
+  });
   test('Xray template preserves XHTTP outbound without turning it into TCP', () {
     final profile = parseXrayTemplate(xrayFixture)!;
     expect(profile.name, 'Польша - АвтоБС');
BMRAY_PATCH_030_3
cat > "$patch_dir/0.2.9.patch" <<'BMRAY_PATCH_030_4'
diff --git a/lib/main.dart b/lib/main.dart
index 35d4f43..a088da8 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -61,6 +61,7 @@ class _HomePageState extends State<HomePage> {
   final _store = SubscriptionStore();
   static const _settingsStorage = FlutterSecureStorage();
   static const _proxyTimeoutKey = 'bmray.proxyTimeoutSeconds';
+  static const _cacheLimitKey = 'bmray.subscriptionCacheLimitMb';
   static const _selectedSubscriptionKey = 'bmray.selectedSubscription';
   static const _selectedNodeKey = 'bmray.selectedNode';
   final _hwidInput = TextEditingController();
@@ -81,7 +82,11 @@ class _HomePageState extends State<HomePage> {
   bool _pingBusy = false;
   PingMethod _pingMethod = PingMethod.proxyGet;
   int _proxyTimeoutSeconds = 4;
-  // 0: servers, 1: settings, 2: ping, 3: information, 4: logs, 5: user agent.
+  int _cacheLimitMb = 25;
+  late Future<int> _cacheSize = _store.requestLog.sizeBytes();
+  late Future<String> _requestLogs = _store.requestLog.read();
+  // 0: servers, 1: settings, 2: ping, 3: information, 4: core logs,
+  // 5: user agent, 6: cache, 7: subscription requests.
   int _pageIndex = 0;
   late final Future<String> _coreVersion = _vpn.coreVersion();
   late final Future<String> _appVersion = PackageInfo.fromPlatform().then(
@@ -140,15 +145,23 @@ class _HomePageState extends State<HomePage> {
       String? storedTimeout;
       String? storedSubscription;
       String? storedNode;
+      String? storedCacheLimit;
       try {
         storedTimeout = await _settingsStorage.read(key: _proxyTimeoutKey);
         storedSubscription = await _settingsStorage.read(key: _selectedSubscriptionKey);
         storedNode = await _settingsStorage.read(key: _selectedNodeKey);
+        storedCacheLimit = await _settingsStorage.read(key: _cacheLimitKey);
       } catch (_) {
         // Keep the default when a preference cannot be read.
       }
+      final cacheLimit = int.tryParse(storedCacheLimit ?? '');
+      if (cacheLimit != null && cacheLimit >= 5 && cacheLimit <= 500) {
+        await _store.requestLog.setLimitMb(cacheLimit);
+      }
       if (mounted)
         setState(() {
+          _cacheLimitMb = _store.requestLog.limitMb;
+          _cacheSize = _store.requestLog.sizeBytes();
           _hwidInput.text = identity.hwid;
           _userAgentInput.text = identity.userAgent;
           _subscriptions = subscriptions;
@@ -913,7 +926,8 @@ class _HomePageState extends State<HomePage> {
           const Text('BMray', style: TextStyle(fontWeight: FontWeight.w800)),
         ]) : Text(switch (_pageIndex) {
           1 => 'Настройки', 2 => 'Пинг', 3 => 'Информация',
-          4 => 'Логи', _ => 'User-Agent',
+          4 => 'Логи', 5 => 'User-Agent', 6 => 'Кэш',
+          _ => 'Запросы подписки',
         }),
         actions: [
           if (_pageIndex == 0) IconButton(
@@ -926,7 +940,9 @@ class _HomePageState extends State<HomePage> {
         2 => _pingSettingsView(),
         3 => _informationView(),
         4 => _logsView(),
-        _ => _userAgentView(),
+        5 => _userAgentView(),
+        6 => _cacheView(),
+        _ => _subscriptionRequestsView(),
       }) : SafeArea(child: LayoutBuilder(builder: (context, constraints) => Column(
         children: [
           SizedBox(
@@ -1032,12 +1048,105 @@ class _HomePageState extends State<HomePage> {
     _settingsHeading('Проверка соединения'),
     _settingsEntry('Пинг', 'Proxy GET, TCP и ICMP', Icons.speed_rounded, 2),
     _settingsHeading('Приложение'),
+    _settingsEntry('Кэш', 'Журнал запросов подписок и лимит размера',
+        Icons.storage_rounded, 6),
     _settingsEntry('Журнал подключения', 'Логи ядра и VPN',
         Icons.receipt_long_outlined, 4),
     _settingsEntry('Информация', 'Версии и сведения о системе',
         Icons.info_outline_rounded, 3),
   ]);
 
+  Future<void> _setCacheLimit(int megabytes) async {
+    try {
+      await _store.requestLog.setLimitMb(megabytes);
+      await _settingsStorage.write(key: _cacheLimitKey, value: '$megabytes');
+      if (mounted) setState(() => _cacheSize = _store.requestLog.sizeBytes());
+    } catch (_) {
+      if (mounted) setState(() => _error = 'Не удалось изменить размер кэша.');
+    }
+  }
+
+  Widget _cacheView() => ListView(padding: const EdgeInsets.all(16), children: [
+    const Text('Кэш', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
+    const SizedBox(height: 12),
+    const Text('В кэше хранится журнал запросов подписок: время, адрес сервера '
+        'без секретного пути и параметров, отправленные имена заголовков, '
+        'User-Agent, HTTP-статус, имена заголовков ответа и формат содержимого. '
+        'Для Base64 записывается число ссылок и их протоколы; для JSON — '
+        'ключи и число выходов. Сами ссылки, ключи, HWID, Cookie и тело ответа '
+        'в журнал не записываются. Исходные подписки и выбранный сервер '
+        'хранятся отдельно; очистка кэша их не удалит. Android и iOS могут '
+        'очистить временный кэш автоматически. Лимит относится к этому '
+        'журналу; журнал ядра и системные временные файлы в него не входят.'),
+    const SizedBox(height: 20),
+    Text('Максимальный размер: $_cacheLimitMb МБ',
+        style: const TextStyle(fontWeight: FontWeight.w600)),
+    Slider(
+      min: 5, max: 500, divisions: 99,
+      value: _cacheLimitMb.toDouble(),
+      label: '$_cacheLimitMb МБ',
+      onChanged: (value) => setState(() =>
+          _cacheLimitMb = (value / 5).round() * 5),
+      onChangeEnd: (value) => _setCacheLimit((value / 5).round() * 5),
+    ),
+    FutureBuilder<int>(future: _cacheSize, builder: (context, snapshot) =>
+        Text('Занято: ${snapshot.hasData ? _formatTraffic(snapshot.data) : '…'}')),
+    const SizedBox(height: 12),
+    ListTile(
+      leading: const Icon(Icons.receipt_long_outlined),
+      title: const Text('Журнал запросов подписки'),
+      subtitle: const Text('Просмотреть и скопировать последние записи'),
+      trailing: const Icon(Icons.chevron_right_rounded),
+      onTap: () => setState(() {
+        _requestLogs = _store.requestLog.read();
+        _pageIndex = 7;
+      }),
+    ),
+    OutlinedButton.icon(
+      icon: const Icon(Icons.delete_outline_rounded),
+      label: const Text('Очистить журнал запросов'),
+      onPressed: () async {
+        await _store.requestLog.clear();
+        if (mounted) setState(() {
+          _cacheSize = _store.requestLog.sizeBytes();
+          _requestLogs = _store.requestLog.read();
+        });
+      },
+    ),
+  ]);
+
+  Widget _subscriptionRequestsView() => FutureBuilder<String>(
+    future: _requestLogs,
+    builder: (context, snapshot) {
+      final logs = snapshot.data ?? '';
+      return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
+        const Text('Обновите подписку, затем скопируйте журнал и отправьте его '
+            'для диагностики. Секретные значения заголовков и ссылки скрыты.'),
+        const SizedBox(height: 8),
+        Row(children: [
+          const Expanded(child: Text('Последние 256 КБ журнала',
+              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
+          IconButton(tooltip: 'Обновить',
+              onPressed: () => setState(() => _requestLogs = _store.requestLog.read()),
+              icon: const Icon(Icons.refresh_rounded)),
+          IconButton(tooltip: 'Копировать для диагностики',
+              onPressed: logs.isEmpty ? null : () =>
+                  Clipboard.setData(ClipboardData(text: logs)),
+              icon: const Icon(Icons.copy_rounded)),
+        ]),
+        const SizedBox(height: 8),
+        Expanded(child: Card(child: Padding(
+          padding: const EdgeInsets.all(14),
+          child: SingleChildScrollView(child: SelectableText(
+            snapshot.hasError ? 'Не удалось прочитать кэш.' :
+            snapshot.connectionState != ConnectionState.done ? 'Загрузка…' :
+            logs.isEmpty ? 'Журнал пуст. Обновите подписку и вернитесь сюда.' : logs,
+          )),
+        ))),
+      ]));
+    },
+  );
+
   Widget _settingsHeading(String title) => Padding(
     padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
     child: Text(title, style: const TextStyle(
@@ -1054,6 +1163,8 @@ class _HomePageState extends State<HomePage> {
         trailing: const Icon(Icons.chevron_right_rounded),
         onTap: () => setState(() {
           _pageIndex = page;
+          if (page == 6) _cacheSize = _store.requestLog.sizeBytes();
+          if (page == 7) _requestLogs = _store.requestLog.read();
           if (page == 4) _logs = _vpn.readLogs();
         }),
       ),
diff --git a/lib/subscription_request_cache.dart b/lib/subscription_request_cache.dart
new file mode 100644
index 0000000..005dd2e
--- /dev/null
+++ b/lib/subscription_request_cache.dart
@@ -0,0 +1,164 @@
+import 'dart:convert';
+import 'dart:io';
+
+import 'package:path_provider/path_provider.dart';
+
+/// A bounded diagnostic journal. It never stores URLs, credentials, or bodies.
+class SubscriptionRequestCache {
+  SubscriptionRequestCache({Future<Directory> Function()? directory})
+      : _directory = directory ?? getTemporaryDirectory;
+
+  final Future<Directory> Function() _directory;
+  Future<void> _pending = Future<void>.value();
+  int _limitBytes = 25 * 1024 * 1024;
+
+  int get limitMb => _limitBytes ~/ (1024 * 1024);
+
+  Future<File> _file() async {
+    final root = Directory('${(await _directory()).path}/bmray');
+    await root.create(recursive: true);
+    return File('${root.path}/subscription-requests.jsonl');
+  }
+
+  Future<void> _enqueue(Future<void> Function() action) {
+    _pending = _pending.then((_) => action()).catchError((Object _) {
+      // Losing diagnostics must never break a subscription request.
+    });
+    return _pending;
+  }
+
+  Future<void> setLimitMb(int value) {
+    _limitBytes = value.clamp(5, 500).toInt() * 1024 * 1024;
+    return _enqueue(_trim);
+  }
+
+  Future<void> append(Map<String, dynamic> event) => _enqueue(() async {
+    final file = await _file();
+    final line = jsonEncode({
+      'time': DateTime.now().toUtc().toIso8601String(),
+      ...event,
+    });
+    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
+    await _trim();
+  });
+
+  Future<void> _trim() async {
+    final file = await _file();
+    if (!await file.exists()) return;
+    final length = await file.length();
+    if (length <= _limitBytes) return;
+    final source = await file.open();
+    final temporary = File('${file.path}.tmp');
+    final output = await temporary.open(mode: FileMode.write);
+    try {
+      final start = (length - _limitBytes ~/ 2).clamp(0, length).toInt();
+      await source.setPosition(start);
+      if (start > 0) {
+        // Start with a complete JSON line, even when the byte offset is in UTF-8.
+        while (await source.position() < length && await source.readByte() != 10) {}
+      }
+      while (true) {
+        final chunk = await source.read(64 * 1024);
+        if (chunk.isEmpty) break;
+        await output.writeFrom(chunk);
+      }
+      await output.flush();
+    } finally {
+      await source.close();
+      await output.close();
+    }
+    await temporary.rename(file.path);
+  }
+
+  Future<int> sizeBytes() async {
+    await _pending;
+    final file = await _file();
+    return await file.exists() ? await file.length() : 0;
+  }
+
+  Future<String> read() async {
+    await _pending;
+    final file = await _file();
+    if (!await file.exists()) return '';
+    final source = await file.open();
+    try {
+      final length = await source.length();
+      final start = (length - 256 * 1024).clamp(0, length).toInt();
+      await source.setPosition(start);
+      if (start > 0) {
+        while (await source.position() < length && await source.readByte() != 10) {}
+      }
+      return utf8.decode(await source.read(length - await source.position()));
+    } finally {
+      await source.close();
+    }
+  }
+
+  Future<void> clear() => _enqueue(() async {
+    final file = await _file();
+    if (await file.exists()) await file.delete();
+  });
+}
+
+Map<String, dynamic> subscriptionRequestTarget(Uri uri) => {
+  'scheme': uri.scheme,
+  'host': uri.host,
+  'port': uri.hasPort ? uri.port : 443,
+  'pathSegmentCount': uri.pathSegments.where((segment) => segment.isNotEmpty).length,
+  'queryKeys': uri.queryParameters.keys.toList()..sort(),
+};
+
+Map<String, dynamic> subscriptionBodySummary(String body) {
+  var content = body.trim();
+  var encoded = false;
+  if (!content.startsWith('{') && !content.startsWith('[') &&
+      !content.contains('://')) {
+    try {
+      final decoded = utf8.decode(base64.decode(base64.normalize(content)));
+      if (decoded.contains('://') || decoded.trimLeft().startsWith('{') ||
+          decoded.trimLeft().startsWith('[')) {
+        content = decoded.trim();
+        encoded = true;
+      }
+    } on FormatException {
+      // An unknown response is described by size and type only.
+    }
+  }
+  if (content.startsWith('{') || content.startsWith('[')) {
+    try {
+      final parsed = jsonDecode(content);
+      if (parsed is Map) {
+        final routing = parsed['routing'];
+        return {
+          'format': encoded ? 'base64-json' : 'json',
+          'jsonKeys': parsed.keys.map((key) => key.toString()).toList()..sort(),
+          'outboundCount': parsed['outbounds'] is List
+              ? (parsed['outbounds'] as List).length : 0,
+          'balancerCount': routing is Map && routing['balancers'] is List
+              ? (routing['balancers'] as List).length : 0,
+          'hasRemnawaveDirective': parsed['remnawave'] != null,
+        };
+      }
+      if (parsed is List) {
+        return {'format': encoded ? 'base64-json-array' : 'json-array',
+          'items': parsed.length};
+      }
+    } on FormatException {
+      // The parser will report malformed JSON separately.
+    }
+  }
+  final schemes = <String, int>{};
+  var loopback = 0;
+  for (final line in const LineSplitter().convert(content)) {
+    if (!line.contains('://')) continue;
+    final uri = Uri.tryParse(line.trim());
+    if (uri == null || uri.scheme.isEmpty) continue;
+    schemes[uri.scheme] = (schemes[uri.scheme] ?? 0) + 1;
+    if (uri.host == '127.0.0.1' || uri.host == '::1') loopback++;
+  }
+  return {
+    'format': encoded ? 'base64-links' : schemes.isNotEmpty ? 'links' : 'unknown',
+    'linkSchemes': schemes,
+    'loopbackLinks': loopback,
+  };
+}
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index d2949d5..4e445de 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -10,6 +10,7 @@ import 'subscription_metadata.dart';
 import 'subscription_identity.dart';
 import 'xray_subscription.dart';
 import 'remnawave_template.dart';
+import 'subscription_request_cache.dart';
 
 class Subscription {
   Subscription({
@@ -96,6 +97,7 @@ class SubscriptionStore {
   static const _storage = FlutterSecureStorage();
   static const _key = 'bmray.subscriptions.v1';
   SubscriptionIdentity? identity;
+  final requestLog = SubscriptionRequestCache();
 
   Future<List<Subscription>> load() async {
     final value = await _storage.read(key: _key);
@@ -173,6 +175,11 @@ class SubscriptionStore {
     }
     final downloaded = await _download(normalized);
     final parsed = _parse(downloaded.body);
+    await requestLog.append({'event': 'parse', 'id': downloaded.id,
+      'format': subscriptionBodySummary(downloaded.body)['format'],
+      'nodeCount': parsed.nodes.length,
+      'autoNodeCount': parsed.nodes.where((node) => node['type'] == 'auto').length,
+    });
     if (parsed.nodes.isEmpty) {
       throw const FormatException(
         'У подписки нет распознанных серверов. Попробуйте формат sing-box, V2Ray или Clash в боте.',
@@ -204,6 +211,11 @@ class SubscriptionStore {
     }
     final downloaded = await _download(Uri.parse(item.url));
     final parsed = _parse(downloaded.body);
+    await requestLog.append({'event': 'parse', 'id': downloaded.id,
+      'format': subscriptionBodySummary(downloaded.body)['format'],
+      'nodeCount': parsed.nodes.length,
+      'autoNodeCount': parsed.nodes.where((node) => node['type'] == 'auto').length,
+    });
     if (parsed.nodes.isEmpty)
       throw const FormatException(
         'В обновлённой подписке нет распознанных серверов.',
@@ -306,10 +318,11 @@ class SubscriptionStore {
     }
   }
 
-  Future<({String body, String? title, String? announce,
+  Future<({String id, String body, String? title, String? announce,
       String? userInfo, String? updateInterval})> _download(Uri initial) async {
     final client = HttpClient()
       ..connectionTimeout = const Duration(seconds: 12);
+    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
     try {
       var uri = initial;
       for (var redirect = 0; redirect < 4; redirect++) {
@@ -321,16 +334,52 @@ class SubscriptionStore {
         final request = await client
             .getUrl(uri)
             .timeout(const Duration(seconds: 15));
+        final stopwatch = Stopwatch()..start();
         request.followRedirects = false;
         final headers = (identity ??= await SubscriptionIdentity.load()).requestHeaders;
         for (final entry in headers.entries) {
           request.headers.set(entry.key, entry.value);
         }
+        final requestHeaderNames = <String>[];
+        request.headers.forEach((name, values) =>
+            requestHeaderNames.add(name.toLowerCase()));
+        requestHeaderNames.sort();
+        await requestLog.append({
+          'event': 'request', 'id': requestId, 'hop': redirect,
+          'method': 'GET', 'target': subscriptionRequestTarget(uri),
+          'requestHeaderNames': requestHeaderNames,
+          'userAgent': headers[HttpHeaders.userAgentHeader],
+          'deviceOs': headers['x-device-os'],
+          'deviceModel': headers['x-device-model'],
+          'hwidSent': headers.containsKey('x-hwid'),
+          'cookieSent': headers.containsKey(HttpHeaders.cookieHeader),
+        });
         final response = await request.close().timeout(
           const Duration(seconds: 20),
         );
+        final responseHeaders = <String>[];
+        response.headers.forEach((name, values) => responseHeaders.add(name));
+        responseHeaders.sort();
+        final responseInfo = <String, dynamic>{
+          'event': 'response', 'id': requestId, 'hop': redirect,
+          'status': response.statusCode,
+          'headersElapsedMs': stopwatch.elapsedMilliseconds,
+          'responseHeaderNames': responseHeaders,
+          'contentType': response.headers.contentType?.mimeType,
+          'contentEncoding': response.headers.value(HttpHeaders.contentEncodingHeader),
+          'profileTitlePresent': response.headers.value('profile-title') != null,
+          'announcePresent': response.headers.value('announce') != null,
+          'trafficHeaderPresent': response.headers.value('subscription-userinfo') != null,
+          'updateIntervalHours': subscriptionUpdateHours(
+              response.headers.value('profile-update-interval')),
+          'providerIdPresent': response.headers.value('x-provider-id') != null,
+        };
         if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
           final location = response.headers.value(HttpHeaders.locationHeader);
+          if (location != null) {
+            responseInfo['redirectTarget'] = subscriptionRequestTarget(uri.resolve(location));
+          }
+          await requestLog.append(responseInfo);
           await response.drain<void>();
           if (location == null)
             throw const FormatException('Пустая переадресация подписки.');
@@ -338,6 +387,7 @@ class SubscriptionStore {
           continue;
         }
         if (response.statusCode != 200) {
+          await requestLog.append(responseInfo);
           await response.drain<void>();
           throw FormatException(
             'Сервер подписки ответил: HTTP ${response.statusCode}.',
@@ -354,12 +404,22 @@ class SubscriptionStore {
             );
           }
         }
-        return (body: utf8.decode(bytes), title: response.headers.value('profile-title'),
+        final body = utf8.decode(bytes);
+        responseInfo['bodyBytes'] = bytes.length;
+        responseInfo['totalElapsedMs'] = stopwatch.elapsedMilliseconds;
+        responseInfo['bodySummary'] = subscriptionBodySummary(body);
+        await requestLog.append(responseInfo);
+        return (id: requestId, body: body, title: response.headers.value('profile-title'),
             announce: response.headers.value('announce'),
             userInfo: response.headers.value('subscription-userinfo'),
             updateInterval: response.headers.value('profile-update-interval'));
       }
       throw const FormatException('Слишком много переадресаций подписки.');
+    } catch (error) {
+      await requestLog.append({'event': 'error', 'id': requestId,
+        'target': subscriptionRequestTarget(initial),
+        'errorType': error.runtimeType.toString()});
+      rethrow;
     } finally {
       client.close(force: true);
     }
diff --git a/pubspec.lock b/pubspec.lock
index c3a75dd..0b4c2bf 100644
--- a/pubspec.lock
+++ b/pubspec.lock
@@ -265,7 +265,7 @@ packages:
     source: hosted
     version: "1.9.1"
   path_provider:
-    dependency: transitive
+    dependency: "direct main"
     description:
       name: path_provider
       sha256: a7f4874f987173da295a61c181b8ee71dab59b332a486b391babf26a1b884825
diff --git a/pubspec.yaml b/pubspec.yaml
index 425f0c8..1d53814 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.8+19
+version: 0.2.9+20
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
@@ -12,6 +12,7 @@ dependencies:
   flutter_secure_storage: 11.2.0
   package_info_plus: 10.2.1
   mobile_scanner: 7.4.2
+  path_provider: 2.1.6
   yaml: 3.1.4
   vpn_plugin:
     path: packages/vpn_plugin
diff --git a/test/subscription_request_cache_test.dart b/test/subscription_request_cache_test.dart
new file mode 100644
index 0000000..5ca627f
--- /dev/null
+++ b/test/subscription_request_cache_test.dart
@@ -0,0 +1,55 @@
+import 'dart:convert';
+import 'dart:io';
+
+import 'package:bmray/subscription_request_cache.dart';
+import 'package:flutter_test/flutter_test.dart';
+
+void main() {
+  test('diagnostic summary identifies Base64 without exposing share links', () {
+    const link = 'vless://00000000-0000-4000-8000-000000000001@'
+        '127.0.0.1:237?security=tls#Auto';
+    final summary = subscriptionBodySummary(base64Encode(utf8.encode('$link\n'
+        'hysteria2://password@vpn.example.com:443#Test')));
+    expect(summary['format'], 'base64-links');
+    expect(summary['linkSchemes'], {'vless': 1, 'hysteria2': 1});
+    expect(summary['loopbackLinks'], 1);
+    expect(jsonEncode(summary), isNot(contains('password')));
+    expect(jsonEncode(summary), isNot(contains('00000000')));
+    final target = subscriptionRequestTarget(
+        Uri.parse('https://example.com/private-token?key=secret'));
+    expect(target['host'], 'example.com');
+    expect(jsonEncode(target), isNot(contains('private-token')));
+    expect(jsonEncode(target), isNot(contains('secret')));
+  });
+
+  test('JSON diagnostic summary recognizes generated Xray balancer', () {
+    final summary = subscriptionBodySummary(jsonEncode({
+      'remarks': 'Auto', 'outbounds': [
+        {'tag': 'WIFI_', 'protocol': 'vless'},
+        {'tag': 'direct', 'protocol': 'freedom'},
+      ],
+      'routing': {'balancers': [{'tag': 'auto_wifi'}]},
+    }));
+    expect(summary['format'], 'json');
+    expect(summary['outboundCount'], 2);
+    expect(summary['balancerCount'], 1);
+  });
+
+  test('request journal stays within configured cache limit', () async {
+    final dir = await Directory.systemTemp.createTemp('bmray-cache-test');
+    try {
+      final cache = SubscriptionRequestCache(directory: () async => dir);
+      await cache.setLimitMb(5);
+      for (var i = 0; i < 70; i++) {
+        await cache.append({'event': 'synthetic', 'index': i,
+          'data': 'a' * 80000});
+      }
+      expect(await cache.sizeBytes(), lessThanOrEqualTo(5 * 1024 * 1024));
+      expect(await cache.read(), contains('"index":69'));
+      await cache.clear();
+      expect(await cache.sizeBytes(), 0);
+    } finally {
+      await dir.delete(recursive: true);
+    }
+  });
+}
BMRAY_PATCH_030_4
cat > "$patch_dir/0.2.10.patch" <<'BMRAY_PATCH_030_5'
diff --git a/lib/main.dart b/lib/main.dart
index a088da8..98f28ef 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1177,6 +1177,11 @@ class _HomePageState extends State<HomePage> {
     const SizedBox(height: 12),
     const Text('BMray отправляет постоянный HWID в x-hwid и Cookie BMray. '
       'Изменение HWID может занять новое место в лимите устройств панели.'),
+    const SizedBox(height: 8),
+    const Text('Для подписки Base64 с локальным адресом АвтоБС BMray '
+      'повторяет запрос с User-Agent «Happ BMray/…»: правило Remnawave '
+      'выдаёт готовый XRAY_JSON. В остальных запросах действует '
+      'указанный ниже User-Agent.'),
     const SizedBox(height: 18),
     TextField(controller: _hwidInput, autocorrect: false,
       decoration: const InputDecoration(labelText: 'HWID',
diff --git a/lib/subscription_identity.dart b/lib/subscription_identity.dart
index 1031dff..176ec38 100644
--- a/lib/subscription_identity.dart
+++ b/lib/subscription_identity.dart
@@ -60,4 +60,9 @@ class SubscriptionIdentity {
     'x-device-model': 'BMray',
     HttpHeaders.cookieHeader: 'BMray=$hwid',
   };
+
+  /// The Remnawave XRAY_JSON rule requires the User-Agent to *start* with Happ.
+  /// Only the retry for a Base64 subscription with local template hosts uses it.
+  String get xrayJsonUserAgent =>
+      userAgent.toLowerCase().startsWith('happ') ? userAgent : 'Happ $userAgent';
 }
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index 4e445de..b60449d 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -173,7 +173,7 @@ class SubscriptionStore {
         'Вставьте HTTPS-подписку или ссылку сервера vless://, vmess://, trojan://, ss://, hy2://, tuic://',
       );
     }
-    final downloaded = await _download(normalized);
+    final downloaded = await _downloadPreferXrayJson(normalized);
     final parsed = _parse(downloaded.body);
     await requestLog.append({'event': 'parse', 'id': downloaded.id,
       'format': subscriptionBodySummary(downloaded.body)['format'],
@@ -209,7 +209,7 @@ class SubscriptionStore {
         'Это отдельный сервер. Для изменения импортируйте новую ссылку.',
       );
     }
-    final downloaded = await _download(Uri.parse(item.url));
+    final downloaded = await _downloadPreferXrayJson(Uri.parse(item.url));
     final parsed = _parse(downloaded.body);
     await requestLog.append({'event': 'parse', 'id': downloaded.id,
       'format': subscriptionBodySummary(downloaded.body)['format'],
@@ -319,7 +319,31 @@ class SubscriptionStore {
   }
 
   Future<({String id, String body, String? title, String? announce,
-      String? userInfo, String? updateInterval})> _download(Uri initial) async {
+      String? userInfo, String? updateInterval})> _downloadPreferXrayJson(
+          Uri initial) async {
+    final original = await _download(initial);
+    if (!needsXrayJsonRetry(original.body)) return original;
+    await requestLog.append({'event': 'compatibility', 'id': original.id,
+      'reason': 'base64-loopback-template', 'action': 'retry-xray-json'});
+    try {
+      final retried = await _download(initial, requestXrayJson: true);
+      final json = retried.body.trimLeft();
+      final usable = (json.startsWith('{') || json.startsWith('[')) &&
+          _parse(retried.body).nodes.isNotEmpty;
+      await requestLog.append({'event': 'compatibility', 'id': original.id,
+        'retryId': retried.id, 'result': usable ? 'xray-json' : 'original-kept',
+        'format': subscriptionBodySummary(retried.body)['format']});
+      return usable ? retried : original;
+    } catch (error) {
+      await requestLog.append({'event': 'compatibility', 'id': original.id,
+        'result': 'original-kept', 'retryError': error.runtimeType.toString()});
+      return original;
+    }
+  }
+
+  Future<({String id, String body, String? title, String? announce,
+      String? userInfo, String? updateInterval})> _download(Uri initial,
+          {bool requestXrayJson = false}) async {
     final client = HttpClient()
       ..connectionTimeout = const Duration(seconds: 12);
     final requestId = DateTime.now().microsecondsSinceEpoch.toString();
@@ -336,7 +360,12 @@ class SubscriptionStore {
             .timeout(const Duration(seconds: 15));
         final stopwatch = Stopwatch()..start();
         request.followRedirects = false;
-        final headers = (identity ??= await SubscriptionIdentity.load()).requestHeaders;
+        final subscriptionIdentity = identity ??= await SubscriptionIdentity.load();
+        final headers = subscriptionIdentity.requestHeaders;
+        if (requestXrayJson) {
+          headers[HttpHeaders.userAgentHeader] =
+              subscriptionIdentity.xrayJsonUserAgent;
+        }
         for (final entry in headers.entries) {
           request.headers.set(entry.key, entry.value);
         }
@@ -346,6 +375,7 @@ class SubscriptionStore {
         requestHeaderNames.sort();
         await requestLog.append({
           'event': 'request', 'id': requestId, 'hop': redirect,
+          'xrayJsonRetry': requestXrayJson,
           'method': 'GET', 'target': subscriptionRequestTarget(uri),
           'requestHeaderNames': requestHeaderNames,
           'userAgent': headers[HttpHeaders.userAgentHeader],
@@ -426,6 +456,14 @@ class SubscriptionStore {
   }
 }
 
+/// Base64 links pointing to the phone itself need the server-generated
+/// Remnawave template, which the panel returns to Happ-class clients.
+bool needsXrayJsonRetry(String body) {
+  final summary = subscriptionBodySummary(body);
+  return summary['format'] == 'base64-links' &&
+      (summary['loopbackLinks'] as int? ?? 0) > 0;
+}
+
 /// Gives the inspector a readable second view for Base64 subscriptions.
 String? decodedSubscriptionResponse(String body) {
   final text = body.trim();
diff --git a/pubspec.yaml b/pubspec.yaml
index 1d53814..45d169a 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.9+20
+version: 0.2.10+21
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/subscription_identity_test.dart b/test/subscription_identity_test.dart
index b7c45b9..8b549bb 100644
--- a/test/subscription_identity_test.dart
+++ b/test/subscription_identity_test.dart
@@ -15,6 +15,10 @@ void main() {
     expect(headers['x-hwid'], identity.hwid);
     expect(headers['user-agent'], 'BMray/android/0.2.4');
     expect(headers['cookie'], 'BMray=BMray-0123456789');
+    expect(identity.xrayJsonUserAgent, 'Happ BMray/android/0.2.4');
+    expect(RegExp(r'^happ', caseSensitive: false)
+        .hasMatch(identity.xrayJsonUserAgent), true);
+    expect(headers['user-agent'], 'BMray/android/0.2.4');
     expect(SubscriptionIdentity.validUserAgent('BMray\r\nExtra: bad'), false);
   });
 
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index b089b8d..56386d6 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -200,6 +200,18 @@ void main() {
     expect(decodedSubscriptionResponse(body), '$realityLink\n$realityLink');
   });
 
+  test('only Base64 subscriptions with local template hosts trigger JSON retry', () {
+    const local = 'vless://00000000-0000-4000-8000-000000000001@127.0.0.1:237'
+        '?type=xhttp&security=tls#Auto';
+    const remote = 'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
+        '?type=xhttp&security=reality#Remote';
+    expect(needsXrayJsonRetry(base64Encode(utf8.encode('$remote\n$local'))), true);
+    expect(needsXrayJsonRetry(base64Encode(utf8.encode(remote))), false);
+    expect(needsXrayJsonRetry('$remote\n$local'), false);
+    expect(needsXrayJsonRetry(xrayFixture), false);
+    expect(parseXrayTemplate(xrayFixture)!.nodes.first['type'], 'auto');
+  });
+
   test('server subtitles use imported transport and security', () {
     final tcp = parseShareLink(realityLink)!;
     expect(nodeLabel(tcp), 'VLESS / TCP / REALITY');
BMRAY_PATCH_030_5
cat > "$patch_dir/0.2.11.patch" <<'BMRAY_PATCH_030_6'
diff --git a/lib/main.dart b/lib/main.dart
index 98f28ef..1d2d50a 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -14,7 +14,6 @@ import 'subscription_identity.dart';
 import 'xray_bridge.dart';
 import 'node_label.dart';
 import 'json_config_page.dart';
-import 'remnawave_template.dart';
 
 enum PingMethod { proxyGet, tcp, icmp }
 
@@ -418,37 +417,6 @@ class _HomePageState extends State<HomePage> {
     }
   }
 
-  Future<void> _attachAutoTemplate(Subscription item, int index) async {
-    final input = TextEditingController(text: item.autoTemplates[
-        item.nodes[index]['tag']?.toString() ?? ''] ?? '');
-    final apply = await showDialog<bool>(context: context, builder: (ctx) =>
-      AlertDialog(
-        title: const Text('Шаблон АвтоБС'),
-        content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(
-          mainAxisSize: MainAxisSize.min, children: [
-            const Text('Вставьте Xray JSON шаблон этого хоста из Remnawave. '
-                'В ответе подписки injectHosts отсутствует.'),
-            TextField(controller: input, maxLines: 12, minLines: 5,
-                decoration: const InputDecoration(hintText: '{ "remnawave": ... }')),
-          ],
-        ))),
-        actions: [
-          TextButton(onPressed: () => Navigator.pop(ctx, false),
-              child: const Text('Отмена')),
-          FilledButton(onPressed: () => Navigator.pop(ctx, true),
-              child: const Text('Привязать')),
-        ],
-      ));
-    final raw = input.text;
-    input.dispose();
-    if (apply != true) return;
-    await _perform(() async {
-      _store.attachAutoTemplate(item, index, raw);
-      await _store.save(_subscriptions);
-      if (mounted) setState(() {});
-    });
-  }
-
   Future<void> _refresh(Subscription item) async {
     await _perform(() async {
       try {
@@ -1498,18 +1466,11 @@ class _HomePageState extends State<HomePage> {
               maxLines: 1, softWrap: false,
               style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                 fontSize: 12, fontWeight: FontWeight.w600)),
-            if (isLocalTemplateHost(node)) IconButton(
-              tooltip: 'Привязать Xray JSON шаблон АвтоБС',
-              onPressed: _busy || _status.state.isActive ? null
-                  : () => _attachAutoTemplate(item, index),
-              visualDensity: VisualDensity.compact,
-              icon: const Icon(Icons.account_tree_outlined, size: 19),
-            ),
             IconButton(
-              tooltip: 'Просмотр JSON конфигурации',
+              tooltip: 'Просмотреть конфигурацию',
               onPressed: () => _showNodeJson(item, index),
               visualDensity: VisualDensity.compact,
-              icon: const Icon(Icons.data_object_rounded, size: 19),
+              icon: const Icon(Icons.article_outlined, size: 19),
             ),
             IconButton(
               tooltip: 'Проверить сервер',
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index b60449d..68f2fed 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -279,8 +279,16 @@ class SubscriptionStore {
             final profile = parseXrayTemplate(jsonEncode(
                 entry['protocol'] != null && entry['outbounds'] == null
                     ? {'outbounds': [entry]} : entry));
-            if (profile == null) continue;
-            nodes.addAll(profile.nodes);
+            if (profile == null || profile.nodes.isEmpty) continue;
+            // XRAY_JSON subscriptions contain one full configuration per item.
+            // Its outbounds are implementation details, not extra regions.
+            final selected = profile.nodes.firstWhere(
+                (node) => node['type'] == 'auto',
+                orElse: () => profile.nodes.first);
+            final node = Map<String, dynamic>.from(selected);
+            final remarks = entry['remarks']?.toString().trim();
+            if (remarks != null && remarks.isNotEmpty) node['tag'] = remarks;
+            nodes.add(node);
             directRules.addAll(profile.directRules);
             if (profile.notice != null) notices.add(profile.notice!);
           }
diff --git a/pubspec.yaml b/pubspec.yaml
index 45d169a..e107d35 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.10+21
+version: 0.2.11+22
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 56386d6..4ec686e 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -183,6 +183,28 @@ void main() {
     expect(usesXray(subscription.nodes.single), true);
   });
 
+  test('XRAY_JSON array shows one named region per config, including AutoBS', () async {
+    final ordinary = jsonDecode(xrayFixture) as Map<String, dynamic>;
+    ordinary.remove('routing');
+    ordinary.remove('burstObservatory');
+    ordinary['remarks'] = '🇪🇪 Эстония';
+    final imported = await SubscriptionStore().import('', jsonEncode([
+      ordinary,
+      jsonDecode(xrayFixture),
+      jsonDecode(hysteriaXrayFixture),
+    ]));
+    expect(imported.nodes, hasLength(3));
+    expect(imported.nodes.map((node) => node['tag']), [
+      '🇪🇪 Эстония', 'Польша - АвтоБС', 'Латвия (Hysteria2)',
+    ]);
+    expect(imported.nodes[1]['type'], 'auto');
+    expect((buildXrayBridge(imported.nodes[1]).xray['outbounds'] as List)
+        .map((outbound) => outbound['tag']),
+        containsAll(['WIFI_', 'WIFI_-2', 'FALLBACK_']));
+    expect(imported.nodes[2]['type'], 'hysteria2');
+    expect(usesXray(imported.nodes[2]), true);
+  });
+
   test('Imported template retains the original JSON across storage serialization', () async {
     final imported = await SubscriptionStore().import('', xrayFixture);
     expect(jsonDecode(imported.rawResponse!), jsonDecode(xrayFixture));
BMRAY_PATCH_030_6
cat > "$patch_dir/0.3.0.patch" <<'BMRAY_PATCH_030_7'
diff --git a/.github/workflows/android.yml b/.github/workflows/android.yml
index 5e1ca2e..f923ac2 100644
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@ -68,6 +68,8 @@ jobs:
           build/reality-test/xray run -test -config build/config-check/xhttp-xray.json
           build/reality-test/xray run -test -config build/config-check/hysteria-xray.json
           build/reality-test/xray run -test -config build/config-check/auto-xray.json
+          build/reality-test/xray run -test -config build/config-check/tcp-tls-xray.json
+          build/reality-test/xray run -test -config build/config-check/xhttp-tls-xray.json
       - name: Test proxy GET through sing-box outbound
         run: (cd build/sing-box && go test -tags with_utls -run TestBMrayProbeProxyGET ./experimental/libbox)
       - uses: actions/cache@v4
diff --git a/README.md b/README.md
index b700bc3..44fcc12 100644
--- a/README.md
+++ b/README.md
@@ -1,5 +1,9 @@
 # BMray
 
+Текущая версия задаётся в `pubspec.yaml`. Для следующего релиза запустите
+`python3 scripts/next_version.py`: версии идут от 0.3.0 до 0.3.9, затем
+0.4.0; после 0.4.9 следует 0.5.0. Номер сборки после `+` растёт на единицу.
+
 Версия 0.1.7: под названиями серверов показаны протокол, транспорт и защита
 (например, `VLESS / XHTTP / REALITY`). Клиентский Xray JSON с Hysteria2
 использует встроенный Xray 26.9.9 на Android. В версии 0.2.0 подписки и серверы
diff --git a/lib/main.dart b/lib/main.dart
index 1d2d50a..d88ba16 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -107,6 +107,9 @@ class _HomePageState extends State<HomePage> {
     return index < 0 ? 0 : index;
   }
 
+  bool _useXrayForNode(Map<String, dynamic> node) =>
+      usesXray(node) || (Platform.isAndroid && prefersXrayTls(node));
+
   @override
   void initState() {
     super.initState();
@@ -366,11 +369,11 @@ class _HomePageState extends State<HomePage> {
       if (node['_unsupported_reason'] != null) {
         throw FormatException(node['_unsupported_reason'].toString());
       }
-      final bridge = usesXray(node) && Platform.isAndroid
+      final bridge = _useXrayForNode(node) && Platform.isAndroid
           ? buildXrayBridge(node,
               options: const SingboxConfigOptions(usePlatformDns: true))
           : null;
-      if (usesXray(node) && bridge == null) {
+      if (_useXrayForNode(node) && bridge == null) {
         throw const FormatException('Этот профиль Xray доступен только на Android.');
       }
       final config = bridge?.singbox ?? buildSingboxConfig(node,
@@ -565,7 +568,7 @@ class _HomePageState extends State<HomePage> {
           'без отдельного локального прокси. Сравните ответ подписки с конфигом HAPP.';
     }
     try {
-      if (usesXray(node)) {
+      if (_useXrayForNode(node)) {
         final bridge = buildXrayBridge(node,
             options: const SingboxConfigOptions(usePlatformDns: true));
         tabs.add(JsonConfigTab('Xray: подключение', _formatJson(bridge.xray)));
@@ -743,11 +746,11 @@ class _HomePageState extends State<HomePage> {
         if (node['_unsupported_reason'] != null) {
           return (delay: null, reason: node['_unsupported_reason'].toString());
         }
-        if (usesXray(node) && !Platform.isAndroid) {
+        if (_useXrayForNode(node) && !Platform.isAndroid) {
           return (delay: null, reason: 'Этот профиль Xray доступен только на Android');
         }
         if (node['type'] == 'auto') return _probeAutoProxy(node);
-        final bridge = usesXray(node) ? buildXrayBridge(node, probe: true,
+        final bridge = _useXrayForNode(node) ? buildXrayBridge(node, probe: true,
             options: const SingboxConfigOptions(usePlatformDns: true)) : null;
         final config = bridge?.singbox ?? buildSingboxConfig(node,
             options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
@@ -781,6 +784,9 @@ class _HomePageState extends State<HomePage> {
         await _waitForDisconnect();
         await Future<void>.delayed(const Duration(milliseconds: 250));
       }
+      if (Platform.isAndroid) {
+        await _prepareNetworkForPing(item, indices);
+      }
       if (await _vpn.otherVpnActive()) {
         throw const FormatException('Выключите VPN другого приложения в настройках Android перед проверкой.');
       }
@@ -805,6 +811,65 @@ class _HomePageState extends State<HomePage> {
     }
   }
 
+  Future<void> _prepareNetworkForPing(Subscription item, List<int> indices) async {
+    final candidates = <Map<String, dynamic>>[
+      for (final index in indices)
+        if (index >= 0 && index < item.nodes.length) item.nodes[index],
+      for (final subscription in _subscriptions) ...subscription.nodes,
+    ];
+    String? configJson;
+    String? xrayJson;
+    for (final node in candidates) {
+      final host = node['server']?.toString() ?? '';
+      if (node['_unsupported_reason'] != null || host.isEmpty ||
+          host == 'localhost' ||
+          InternetAddress.tryParse(host)?.isLoopback == true) continue;
+      try {
+        final bridge = _useXrayForNode(node)
+            ? buildXrayBridge(node,
+                options: const SingboxConfigOptions(usePlatformDns: true))
+            : null;
+        final config = bridge?.singbox ?? buildSingboxConfig(node,
+            options: const SingboxConfigOptions(usePlatformDns: true));
+        final candidateJson = jsonEncode(config);
+        if (await _vpn.validateConfig(candidateJson) != null) continue;
+        configJson = candidateJson;
+        xrayJson = bridge == null ? null : jsonEncode(bridge.xray);
+        break;
+      } catch (_) {
+        // A different imported server may still be suitable for preparation.
+      }
+    }
+    if (configJson == null) {
+      if (await _vpn.otherVpnActive()) {
+        throw const FormatException('Нет пригодного сервера для смены VPN перед пингом.');
+      }
+      return;
+    }
+    var attempted = false;
+    try {
+      attempted = true;
+      await _vpn.start(configJson, name: 'BMray', xrayConfig: xrayJson);
+      for (var attempt = 0; attempt < 100; attempt++) {
+        final status = await _vpn.currentStatus();
+        if (status.state == VpnState.connected) break;
+        if (status.state == VpnState.error) {
+          throw FormatException(status.message ?? 'Не удалось подготовить VPN для пинга.');
+        }
+        if (attempt == 99) {
+          throw const FormatException('VPN не запустился для подготовки пинга.');
+        }
+        await Future<void>.delayed(const Duration(milliseconds: 100));
+      }
+    } finally {
+      if (attempted) {
+        await _vpn.stop();
+        await _waitForDisconnect();
+      }
+    }
+    await Future<void>.delayed(const Duration(milliseconds: 250));
+  }
+
   String _safeLogs(String logs) => logs
         .replaceAll(
           RegExp(r'(?:vless|vmess|trojan|ss|hy2|hysteria2|tuic)://\S+'),
@@ -1013,10 +1078,12 @@ class _HomePageState extends State<HomePage> {
     _settingsHeading('Подписка'),
     _settingsEntry('User-Agent', 'HWID, User-Agent и Cookie BMray',
         Icons.badge_outlined, 5),
+    _settingsEntry('Логи запросов подписки', 'HTTP-ответы и выбор формата подписки',
+        Icons.receipt_long_outlined, 7),
     _settingsHeading('Проверка соединения'),
     _settingsEntry('Пинг', 'Proxy GET, TCP и ICMP', Icons.speed_rounded, 2),
     _settingsHeading('Приложение'),
-    _settingsEntry('Кэш', 'Журнал запросов подписок и лимит размера',
+    _settingsEntry('Кэш', 'Лимит размера и очистка журнала',
         Icons.storage_rounded, 6),
     _settingsEntry('Журнал подключения', 'Логи ядра и VPN',
         Icons.receipt_long_outlined, 4),
@@ -1060,16 +1127,6 @@ class _HomePageState extends State<HomePage> {
     FutureBuilder<int>(future: _cacheSize, builder: (context, snapshot) =>
         Text('Занято: ${snapshot.hasData ? _formatTraffic(snapshot.data) : '…'}')),
     const SizedBox(height: 12),
-    ListTile(
-      leading: const Icon(Icons.receipt_long_outlined),
-      title: const Text('Журнал запросов подписки'),
-      subtitle: const Text('Просмотреть и скопировать последние записи'),
-      trailing: const Icon(Icons.chevron_right_rounded),
-      onTap: () => setState(() {
-        _requestLogs = _store.requestLog.read();
-        _pageIndex = 7;
-      }),
-    ),
     OutlinedButton.icon(
       icon: const Icon(Icons.delete_outline_rounded),
       label: const Text('Очистить журнал запросов'),
@@ -1147,9 +1204,10 @@ class _HomePageState extends State<HomePage> {
       'Изменение HWID может занять новое место в лимите устройств панели.'),
     const SizedBox(height: 8),
     const Text('Для подписки Base64 с локальным адресом АвтоБС BMray '
-      'повторяет запрос с User-Agent «Happ BMray/…»: правило Remnawave '
-      'выдаёт готовый XRAY_JSON. В остальных запросах действует '
-      'указанный ниже User-Agent.'),
+      'повторяет запрос с User-Agent «Happ/версия BMray/…»: панель может '
+      'выдать готовый XRAY_JSON. В остальных запросах действует '
+      'указанный ниже User-Agent. Если он уже начинается с Happ, повторного '
+      'запроса не будет.'),
     const SizedBox(height: 18),
     TextField(controller: _hwidInput, autocorrect: false,
       decoration: const InputDecoration(labelText: 'HWID',
diff --git a/lib/subscription_identity.dart b/lib/subscription_identity.dart
index 176ec38..22fde80 100644
--- a/lib/subscription_identity.dart
+++ b/lib/subscription_identity.dart
@@ -14,6 +14,8 @@ class SubscriptionIdentity {
   final String hwid;
   final String userAgent;
 
+  bool get isHappUserAgent => userAgent.toLowerCase().startsWith('happ');
+
   static String defaultUserAgentFor(String platform, String version) =>
       'BMray/$platform/$version';
 
@@ -63,6 +65,10 @@ class SubscriptionIdentity {
 
   /// The Remnawave XRAY_JSON rule requires the User-Agent to *start* with Happ.
   /// Only the retry for a Base64 subscription with local template hosts uses it.
-  String get xrayJsonUserAgent =>
-      userAgent.toLowerCase().startsWith('happ') ? userAgent : 'Happ $userAgent';
+  String get xrayJsonUserAgent {
+    if (isHappUserAgent) return userAgent;
+    final version = RegExp(r'/([0-9]+(?:\.[0-9]+){1,2})$')
+        .firstMatch(userAgent)?.group(1) ?? '1.0.0';
+    return 'Happ/$version $userAgent';
+  }
 }
diff --git a/lib/subscriptions.dart b/lib/subscriptions.dart
index 68f2fed..1db728a 100644
--- a/lib/subscriptions.dart
+++ b/lib/subscriptions.dart
@@ -331,6 +331,12 @@ class SubscriptionStore {
           Uri initial) async {
     final original = await _download(initial);
     if (!needsXrayJsonRetry(original.body)) return original;
+    final subscriptionIdentity = identity ??= await SubscriptionIdentity.load();
+    if (subscriptionIdentity.isHappUserAgent) {
+      await requestLog.append({'event': 'compatibility', 'id': original.id,
+        'reason': 'base64-loopback-template', 'result': 'custom-happ-agent-kept'});
+      return original;
+    }
     await requestLog.append({'event': 'compatibility', 'id': original.id,
       'reason': 'base64-loopback-template', 'action': 'retry-xray-json'});
     try {
@@ -377,6 +383,10 @@ class SubscriptionStore {
         for (final entry in headers.entries) {
           request.headers.set(entry.key, entry.value);
         }
+        if (requestXrayJson || subscriptionIdentity.isHappUserAgent) {
+          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
+          request.headers.set('Pragma', 'no-cache');
+        }
         final requestHeaderNames = <String>[];
         request.headers.forEach((name, values) =>
             requestHeaderNames.add(name.toLowerCase()));
diff --git a/lib/xray_bridge.dart b/lib/xray_bridge.dart
index 92b891f..0e40851 100644
--- a/lib/xray_bridge.dart
+++ b/lib/xray_bridge.dart
@@ -16,12 +16,24 @@ bool usesXray(Map<String, dynamic> node) =>
     (node['type'] == 'vless' && node['transport'] is Map &&
     (node['transport'] as Map)['type'] == 'xhttp');
 
+/// Plain VLESS/TCP/TLS can use the same Xray core as XHTTP on Android.
+/// Other platforms continue using the sing-box outbound.
+bool prefersXrayTls(Map<String, dynamic> node) {
+  if (node['type'] != 'vless' || node['tls'] is! Map) return false;
+  final tls = node['tls'] as Map;
+  return tls['enabled'] == true && tls['reality'] is! Map &&
+      (node['transport'] is! Map ||
+          (node['transport'] as Map)['type'] == 'tcp');
+}
+
 XrayBridge buildXrayBridge(Map<String, dynamic> node, {
   bool probe = false,
   String? probeOutboundTag,
   SingboxConfigOptions options = const SingboxConfigOptions(),
 }) {
-  if (!usesXray(node)) throw const FormatException('Ожидался профиль Xray');
+  if (!usesXray(node) && !prefersXrayTls(node)) {
+    throw const FormatException('Ожидался профиль Xray');
+  }
   final random = Random.secure();
   final port = 20000 + random.nextInt(35000);
   final user = 'bmray';
@@ -39,6 +51,18 @@ XrayBridge buildXrayBridge(Map<String, dynamic> node, {
   for (final entry in templateOutbounds ?? [outbound]) {
     final settings = entry is Map ? entry['settings'] : null;
     final servers = settings is Map ? settings['vnext'] : null;
+    final stream = entry is Map ? entry['streamSettings'] : null;
+    if (stream is Map && stream['security'] == 'tls' &&
+        stream['tlsSettings'] is Map) {
+      final tls = stream['tlsSettings'] as Map;
+      if (tls['serverName']?.toString().isNotEmpty != true) {
+        final xhttp = stream['xhttpSettings'];
+        final transportHost = xhttp is Map ? xhttp['host']?.toString() : null;
+        if (transportHost != null && transportHost.isNotEmpty) {
+          tls['serverName'] = transportHost;
+        }
+      }
+    }
     if (servers is List) {
       for (final server in servers) {
         final users = server is Map ? server['users'] : null;
diff --git a/lib/xray_subscription.dart b/lib/xray_subscription.dart
index fc26632..c9cf912 100644
--- a/lib/xray_subscription.dart
+++ b/lib/xray_subscription.dart
@@ -58,7 +58,8 @@ XrayTemplate? parseXrayTemplate(String content) {
       continue;
     }
     if (entry['protocol'] != 'vless') {
-      if (entry['protocol'] != 'freedom' && entry['protocol'] != 'blackhole') {
+      if (!const {'freedom', 'blackhole', 'dns'}
+          .contains(entry['protocol'])) {
         unsupported.add(entry['protocol']?.toString() ?? 'unknown');
       }
       continue;
diff --git a/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt b/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
index 98c018c..32b49ec 100644
--- a/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
+++ b/packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt
@@ -111,7 +111,14 @@ class FlutterSingboxVpnPlugin :
                 startVpnFlow()
                 result.success(null)
             }
-            "stop" -> { stopVpn(); result.success(null) }
+            "stop" -> {
+                // The user may cancel while Android's VPN permission dialog is open.
+                // A late consent result must not start a tunnel after stop().
+                pendingConfig = null
+                pendingXrayConfig = null
+                stopVpn()
+                result.success(null)
+            }
             "otherVpnActive" -> {
                 val cm = context.getSystemService(ConnectivityManager::class.java)
                 val activeVpn = cm.activeNetwork?.let { network ->
@@ -177,6 +184,8 @@ class FlutterSingboxVpnPlugin :
                         val detail = e.message?.lowercase() ?: ""
                         val reason = when {
                             "reality verification failed" in detail -> "Ошибка проверки REALITY"
+                            "certificate" in detail || "x509" in detail -> "Ошибка сертификата TLS или SNI"
+                            "tls" in detail && "handshake" in detail -> "Ошибка TLS handshake"
                             "timeout" in detail || "deadline exceeded" in detail -> "Тайм-аут"
                             "unknown utls" in detail || "fingerprint" in detail -> "Неподдерживаемый fingerprint"
                             "dns" in detail || "lookup" in detail -> "Ошибка DNS"
diff --git a/pubspec.yaml b/pubspec.yaml
index e107d35..7d0685c 100644
--- a/pubspec.yaml
+++ b/pubspec.yaml
@@ -1,7 +1,7 @@
 name: bmray
 description: BMray — клиент подписок sing-box для Android и iOS.
 publish_to: none
-version: 0.2.11+22
+version: 0.3.0+23
 
 environment:
   sdk: '>=3.12.0 <4.0.0'
diff --git a/release-notes/v0.3.0.md b/release-notes/v0.3.0.md
new file mode 100644
index 0000000..76e2783
--- /dev/null
+++ b/release-notes/v0.3.0.md
@@ -0,0 +1,11 @@
+## BMray 0.3.0
+
+- Логи запросов подписок доступны напрямую из настроек.
+- Пользовательский User-Agent, начинающийся с `happ`, отправляется без изменения и без повторного запроса XRAY_JSON.
+- При обнаружении локального адреса `127.0.0.1` или `::1` в Base64-подписке клиент один раз повторяет запрос как `Happ/<версия> BMray/...`. Название хоста не влияет на проверку.
+- Служебный DNS outbound в XRAY_JSON не отображается как неподдерживаемый сервер.
+- VLESS/TCP/TLS на Android использует Xray. Для VLESS/XHTTP/TLS пустой SNI в готовом Xray outbound заполняется из транспортного Host, если он указан.
+- Перед проверкой пинга клиент один раз запускает собственный VPN с пригодным сервером, выключает его и затем проверяет серверы.
+- Версии после 0.3.9 продолжаются как 0.4.0, после 0.4.9 — 0.5.0.
+
+APK и AAB подписаны тестовым ключом. Если сервер подписки даже на запрос с `Happ/<версия>` возвращает Base64, автоматический шаблон из XRAY_JSON недоступен; этот ответ отображается в журнале запросов.
diff --git a/scripts/next_version.py b/scripts/next_version.py
new file mode 100644
index 0000000..c0b2bbb
--- /dev/null
+++ b/scripts/next_version.py
@@ -0,0 +1,29 @@
+#!/usr/bin/env python3
+"""Advance BMray versions with a single digit patch (0.3.9 -> 0.4.0)."""
+
+from pathlib import Path
+import re
+
+
+def next_version(current: str) -> str:
+    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\+(\d+)", current)
+    if not match:
+        raise ValueError(f"Invalid pubspec version: {current}")
+    major, minor, patch, build = map(int, match.groups())
+    if patch >= 9:
+        minor += 1
+        patch = 0
+    else:
+        patch += 1
+    return f"{major}.{minor}.{patch}+{build + 1}"
+
+
+if __name__ == "__main__":
+    pubspec = Path(__file__).resolve().parent.parent / "pubspec.yaml"
+    source = pubspec.read_text()
+    match = re.search(r"^version: (\S+)$", source, flags=re.MULTILINE)
+    if not match:
+        raise SystemExit("version missing from pubspec.yaml")
+    updated = next_version(match.group(1))
+    pubspec.write_text(source[: match.start(1)] + updated + source[match.end(1) :])
+    print(updated)
diff --git a/test/subscription_identity_test.dart b/test/subscription_identity_test.dart
index 8b549bb..4a9453b 100644
--- a/test/subscription_identity_test.dart
+++ b/test/subscription_identity_test.dart
@@ -15,7 +15,7 @@ void main() {
     expect(headers['x-hwid'], identity.hwid);
     expect(headers['user-agent'], 'BMray/android/0.2.4');
     expect(headers['cookie'], 'BMray=BMray-0123456789');
-    expect(identity.xrayJsonUserAgent, 'Happ BMray/android/0.2.4');
+    expect(identity.xrayJsonUserAgent, 'Happ/0.2.4 BMray/android/0.2.4');
     expect(RegExp(r'^happ', caseSensitive: false)
         .hasMatch(identity.xrayJsonUserAgent), true);
     expect(headers['user-agent'], 'BMray/android/0.2.4');
@@ -28,4 +28,11 @@ void main() {
     expect(SubscriptionIdentity.defaultUserAgentFor('ios', '0.2.4'),
         'BMray/ios/0.2.4');
   });
+
+  test('a manually set Happ agent is kept exactly as entered', () {
+    const identity = SubscriptionIdentity('BMray-0123456789', 'hApP/android/9.9');
+    expect(identity.isHappUserAgent, true);
+    expect(identity.requestHeaders['user-agent'], 'hApP/android/9.9');
+    expect(identity.xrayJsonUserAgent, 'hApP/android/9.9');
+  });
 }
diff --git a/test/xray_template_test.dart b/test/xray_template_test.dart
index 4ec686e..9163214 100644
--- a/test/xray_template_test.dart
+++ b/test/xray_template_test.dart
@@ -129,6 +129,41 @@ void main() {
     expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
   });
 
+  test('raw XHTTP TLS outbound restores absent SNI from its Host', () {
+    final node = parseShareLink(
+      'vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443'
+      '?type=xhttp&security=tls&host=cdn.example.com&path=%2Ffile#Test',
+      includeUnsupported: true,
+    )!;
+    final raw = xrayOutboundFromNode(node);
+    (raw['streamSettings']['tlsSettings'] as Map)['serverName'] = '';
+    node['_xray_outbound'] = raw;
+    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
+    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
+    expect(raw['streamSettings']['tlsSettings']['serverName'], '');
+  });
+
+  test('VLESS TCP TLS can use Xray on Android without losing SNI', () {
+    final node = parseShareLink(
+      'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
+      '?type=tcp&security=tls&sni=cdn.example.com&fp=firefox#TLS',
+    )!;
+    expect(prefersXrayTls(node), true);
+    final stream = buildXrayBridge(node).xray['outbounds'][0]['streamSettings'];
+    expect(stream['network'], 'tcp');
+    expect(stream['security'], 'tls');
+    expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
+    expect(stream['tlsSettings']['fingerprint'], 'firefox');
+  });
+
+  test('DNS outbound is an Xray internal route, not a broken server', () {
+    final config = jsonDecode(xrayFixture) as Map<String, dynamic>;
+    (config['outbounds'] as List).add({'tag': 'dns', 'protocol': 'dns'});
+    final parsed = parseXrayTemplate(jsonEncode(config))!;
+    expect(parsed.notice ?? '', isNot(contains('dns')));
+    expect(parsed.nodes.first['type'], 'auto');
+  });
+
   test('Xray Hysteria2 JSON is preserved for the Android core', () {
     final template = parseXrayTemplate(hysteriaXrayFixture)!;
     expect(template.nodes, hasLength(1));
@@ -234,6 +269,13 @@ void main() {
     expect(parseXrayTemplate(xrayFixture)!.nodes.first['type'], 'auto');
   });
 
+  test('loopback discovery uses endpoints rather than AutoBS names', () {
+    const nameAgnostic = 'vless://00000000-0000-4000-8000-000000000001@'
+        '[::1]:237?type=xhttp&security=tls#Unexpected%20name';
+    final encoded = base64Encode(utf8.encode(nameAgnostic));
+    expect(needsXrayJsonRetry(encoded), true);
+  });
+
   test('server subtitles use imported transport and security', () {
     final tcp = parseShareLink(realityLink)!;
     expect(nodeLabel(tcp), 'VLESS / TCP / REALITY');
diff --git a/tool/config_fixtures.dart b/tool/config_fixtures.dart
index 97b8d2b..4295e10 100644
--- a/tool/config_fixtures.dart
+++ b/tool/config_fixtures.dart
@@ -40,4 +40,15 @@ void main() {
       options: const SingboxConfigOptions(usePlatformDns: true));
   File('build/config-check/hysteria-xray.json')
       .writeAsStringSync(jsonEncode(hysteriaBridge.xray));
+  for (final transport in ['tcp', 'xhttp']) {
+    final tlsNode = parseShareLink(
+      'vless://00000000-0000-4000-8000-000000000001@vpn.example.com:443'
+      '?type=$transport&security=tls&sni=cdn.example.com&fp=chrome'
+      '&host=cdn.example.com&path=%2Fvideo#TLS',
+    )!;
+    final tlsBridge = buildXrayBridge(tlsNode,
+        options: const SingboxConfigOptions(usePlatformDns: true));
+    File('build/config-check/$transport-tls-xray.json')
+        .writeAsStringSync(jsonEncode(tlsBridge.xray));
+  }
 }
BMRAY_PATCH_030_7
if [[ "$version" == '0.2.4+15' ]]; then
  git apply --check "$patch_dir/0.2.5.patch"
  git apply "$patch_dir/0.2.5.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' ]]; then
  git apply --check "$patch_dir/0.2.6.patch"
  git apply "$patch_dir/0.2.6.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' || "$version" == '0.2.6+17' ]]; then
  git apply --check "$patch_dir/0.2.7.patch"
  git apply "$patch_dir/0.2.7.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' || "$version" == '0.2.6+17' || "$version" == '0.2.7+18' ]]; then
  git apply --check "$patch_dir/0.2.8.patch"
  git apply "$patch_dir/0.2.8.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' || "$version" == '0.2.6+17' || "$version" == '0.2.7+18' || "$version" == '0.2.8+19' ]]; then
  git apply --check "$patch_dir/0.2.9.patch"
  git apply "$patch_dir/0.2.9.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' || "$version" == '0.2.6+17' || "$version" == '0.2.7+18' || "$version" == '0.2.8+19' || "$version" == '0.2.9+20' ]]; then
  git apply --check "$patch_dir/0.2.10.patch"
  git apply "$patch_dir/0.2.10.patch"
fi
if [[ "$version" == '0.2.4+15' || "$version" == '0.2.5+16' || "$version" == '0.2.6+17' || "$version" == '0.2.7+18' || "$version" == '0.2.8+19' || "$version" == '0.2.9+20' || "$version" == '0.2.10+21' ]]; then
  git apply --check "$patch_dir/0.2.11.patch"
  git apply "$patch_dir/0.2.11.patch"
fi
if true; then
  git apply --check "$patch_dir/0.3.0.patch"
  git apply "$patch_dir/0.3.0.patch"
fi
git add .github/workflows/android.yml README.md release-notes/v0.3.0.md lib/main.dart lib/subscription_identity.dart lib/subscriptions.dart lib/xray_bridge.dart lib/xray_subscription.dart tool/config_fixtures.dart scripts/next_version.py packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt pubspec.yaml test/subscription_identity_test.dart test/xray_template_test.dart lib/json_config_page.dart lib/remnawave_template.dart lib/subscription_request_cache.dart packages/vpn_plugin/lib/src/share_link_parser.dart packages/vpn_plugin/lib/src/singbox_vpn.dart pubspec.lock test/subscription_request_cache_test.dart
git commit -m "Release BMray 0.3.0: subscription and TLS fixes"
git push origin main
