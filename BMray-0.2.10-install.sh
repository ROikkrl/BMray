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
  '0.2.7+18' | '0.2.8+19' | '0.2.9+20') ;;
  *) echo "Нужна версия 0.2.7+18, 0.2.8+19 или 0.2.9+20; найдена $version" >&2; exit 1 ;;
esac
patch_28=$(mktemp)
patch_29=$(mktemp)
patch_210=$(mktemp)
trap 'rm -f "$patch_28" "$patch_29" "$patch_210"' EXIT
cat > "$patch_28" <<'BMRAY_PATCH_28_END'
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
BMRAY_PATCH_28_END
cat > "$patch_29" <<'BMRAY_PATCH_29_END'
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
BMRAY_PATCH_29_END
cat > "$patch_210" <<'BMRAY_PATCH_210_END'
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
BMRAY_PATCH_210_END
if [[ "$version" == '0.2.7+18' ]]; then
  git apply --check "$patch_28"
  git apply "$patch_28"
fi
if [[ "$version" != '0.2.9+20' ]]; then
  git apply --check "$patch_29"
  git apply "$patch_29"
fi
git apply --check "$patch_210"
git apply "$patch_210"
git add lib/main.dart lib/remnawave_template.dart lib/subscriptions.dart lib/subscription_identity.dart lib/xray_bridge.dart lib/subscription_request_cache.dart packages/vpn_plugin/android/src/main/kotlin/dev/flexvpn/flutter_singbox_vpn/FlutterSingboxVpnPlugin.kt packages/vpn_plugin/lib/src/singbox_vpn.dart pubspec.yaml pubspec.lock test/xray_template_test.dart test/subscription_identity_test.dart test/subscription_request_cache_test.dart
git commit -m "Select Xray JSON for loopback template subscriptions"
git push origin main
