#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/BMray
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo 'Есть несохранённые изменения. Проверьте git status.' >&2
  exit 1
fi
git pull --ff-only origin main
version=$(sed -n 's/^version: //p' pubspec.yaml)
case "$version" in
  '0.2.5+16' | '0.2.6+17') ;;
  *) echo "Нужна версия 0.2.5+16 или 0.2.6+17, найдена $version" >&2; exit 1 ;;
esac
patch_26=$(mktemp)
patch_27=$(mktemp)
trap 'rm -f "$patch_26" "$patch_27"' EXIT
cat > "$patch_26" <<'BMRAY_PATCH_26_END'
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
BMRAY_PATCH_26_END
cat > "$patch_27" <<'BMRAY_PATCH_27_END'
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
BMRAY_PATCH_27_END
if [[ "$version" == '0.2.5+16' ]]; then
  git apply --check "$patch_26"
  git apply "$patch_26"
fi
git apply --check "$patch_27"
git apply "$patch_27"
git add -u
git commit -m "Preserve subscription responses for diagnostics"
git push origin main
