import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'subscriptions.dart';
import 'subscription_identity.dart';
import 'xray_bridge.dart';
import 'node_label.dart';
import 'json_config_page.dart';
import 'appearance.dart';

enum PingMethod { proxyGet, tcp, icmp }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appearance.load();
  runApp(const BMrayApp());
}

class BMrayApp extends StatelessWidget {
  const BMrayApp({super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appearance,
    builder: (context, _) => MaterialApp(
    title: 'BMray',
    debugShowCheckedModeBanner: false,
    theme: appearance.theme,
    home: const HomePage(),
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _vpn = SingboxVpn();
  static const _quickTile = MethodChannel('bmray/quick_tile');
  final _store = SubscriptionStore();
  static const _settingsStorage = FlutterSecureStorage();
  static const _proxyTimeoutKey = 'bmray.proxyTimeoutSeconds';
  static const _cacheLimitKey = 'bmray.subscriptionCacheLimitMb';
  static const _selectedSubscriptionKey = 'bmray.selectedSubscription';
  static const _selectedNodeKey = 'bmray.selectedNode';
  static const _showSystemAppsKey = 'bmray.showSystemApps';
  final _hwidInput = TextEditingController();
  final _userAgentInput = TextEditingController();
  final _appSearch = TextEditingController();
  final _themeName = TextEditingController();
  final _themeJson = TextEditingController();
  Future<void> _selectionWrite = Future<void>.value();
  StreamSubscription<VpnStatus>? _statusSubscription;
  Timer? _uptimeTimer;
  Timer? _subscriptionTimer;
  bool _autoRefreshing = false;
  final Map<String, DateTime> _autoRetryAfter = {};
  DateTime? _connectedAt;
  List<Subscription> _subscriptions = [];
  final Set<String> _expandedSubscriptionIds = {};
  String? _subscriptionId;
  int _nodeIndex = 0;
  VpnStatus _status = const VpnStatus.disconnected();
  bool _busy = false;
  bool _initialized = false;
  bool _tileConnectionPending = false;
  bool _handlingTileConnection = false;
  bool _pingBusy = false;
  int _pingEpoch = 0;
  PingMethod _pingMethod = PingMethod.proxyGet;
  int _proxyTimeoutSeconds = 4;
  int _cacheLimitMb = 25;
  late Future<int> _cacheSize = _store.requestLog.sizeBytes();
  late Future<String> _requestLogs = _store.requestLog.read();
  // 0: servers, 1: settings, 2: ping, 3: information, 4: core logs,
  // 5: user agent, 6: cache, 7: subscription requests,
  // 8: per-app VPN, 9: language, 10: themes.
  int _pageIndex = 0;
  late final Future<String> _coreVersion = _vpn.coreVersion();
  late final Future<String> _appVersion = PackageInfo.fromPlatform().then(
      (info) => 'BMray ${info.version} (сборка ${info.buildNumber})');
  late Future<String> _logs = _vpn.readLogs();
  final Map<String, int?> _latencies = {};
  final Map<String, String> _pingErrors = {};
  String? _error;
  String _t(String ru, String en) => appearance.text(ru, en);
  String _perAppMode = 'off';
  final Set<String> _perAppPackages = {};
  bool _showSystemApps = false;
  List<Map<String, dynamic>> _installedApps = [];

  Subscription? get _selected {
    for (final item in _subscriptions) {
      if (item.id == _subscriptionId) return item;
    }
    return _subscriptions.isEmpty ? null : _subscriptions.first;
  }

  int _firstUsableIndex(Subscription item) {
    final index = item.nodes.indexWhere((node) => node['_unsupported_reason'] == null);
    return index < 0 ? 0 : index;
  }

  bool _useXrayForNode(Map<String, dynamic> node) =>
      usesXray(node) || (Platform.isAndroid && prefersXrayTls(node));

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _quickTile.setMethodCallHandler((call) async {
        if (call.method == 'connect') {
          _tileConnectionPending = true;
          if (_initialized) await _connectFromQuickTile();
        }
      });
    }
    _statusSubscription = _vpn.statusStream().listen((status) {
      if (mounted)
        setState(() {
          _setStatus(status);
          if (status.message != null) _error = status.message;
        });
    });
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status.state == VpnState.connected) setState(() {});
    });
    _subscriptionTimer = Timer.periodic(const Duration(minutes: 1),
        (_) => _refreshDueSubscriptions());
    _initialize();
  }

  void _setStatus(VpnStatus status) {
    _status = status;
    if (status.state == VpnState.connected) {
      _connectedAt = status.connectedAt ?? _connectedAt ?? DateTime.now();
    } else if (status.state == VpnState.disconnected ||
        status.state == VpnState.error) {
      _connectedAt = null;
    }
  }

  Future<void> _initialize() async {
    try {
      final subscriptions = await _store.load();
      final identity = await SubscriptionIdentity.load();
      _store.identity = identity;
      final status = await _vpn.currentStatus();
      var perApp = (mode: 'off', packages: <String>[]);
      var apps = <Map<String, dynamic>>[];
      if (Platform.isAndroid) {
        try {
          perApp = await _vpn.perAppSettings();
          apps = await _vpn.installedApps();
        } catch (_) {
          // An old native plugin still allows saved subscriptions to load.
        }
      }
      String? storedTimeout;
      String? storedSubscription;
      String? storedNode;
      String? storedCacheLimit;
      String? showSystemApps;
      try {
        storedTimeout = await _settingsStorage.read(key: _proxyTimeoutKey);
        storedSubscription = await _settingsStorage.read(key: _selectedSubscriptionKey);
        storedNode = await _settingsStorage.read(key: _selectedNodeKey);
        storedCacheLimit = await _settingsStorage.read(key: _cacheLimitKey);
        showSystemApps = await _settingsStorage.read(key: _showSystemAppsKey);
      } catch (_) {
        // Keep the default when a preference cannot be read.
      }
      final cacheLimit = int.tryParse(storedCacheLimit ?? '');
      if (cacheLimit != null && cacheLimit >= 5 && cacheLimit <= 500) {
        await _store.requestLog.setLimitMb(cacheLimit);
      }
      if (mounted)
        setState(() {
          _cacheLimitMb = _store.requestLog.limitMb;
          _perAppMode = perApp.mode;
          _perAppPackages.addAll(perApp.packages);
          _showSystemApps = showSystemApps == 'true';
          _installedApps = apps;
          _cacheSize = _store.requestLog.sizeBytes();
          _hwidInput.text = identity.hwid;
          _userAgentInput.text = identity.userAgent;
          _subscriptions = subscriptions;
          _expandedSubscriptionIds.addAll(subscriptions.map((item) => item.id));
          _setStatus(status);
          final timeout = int.tryParse(storedTimeout ?? '');
          if ([2, 4, 6, 10].contains(timeout)) _proxyTimeoutSeconds = timeout!;
          if (subscriptions.isNotEmpty) {
            final index = subscriptions.indexWhere((e) => e.id == storedSubscription);
            final chosen = index < 0 ? subscriptions.first : subscriptions[index];
            _subscriptionId = chosen.id;
            final match = chosen.nodes.indexWhere((node) =>
                _nodeSelectionKey(node) == storedNode);
            _nodeIndex = match < 0 ? _firstUsableIndex(chosen) : match;
          }
        });
      _initialized = true;
      _rememberSelection();
      if (Platform.isAndroid) await _connectFromQuickTile();
      if (mounted) unawaited(_refreshDueSubscriptions());
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Не удалось открыть защищённое хранилище.');
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) _quickTile.setMethodCallHandler(null);
    _statusSubscription?.cancel();
    _uptimeTimer?.cancel();
    _subscriptionTimer?.cancel();
    _hwidInput.dispose();
    _userAgentInput.dispose();
    _appSearch.dispose();
    _themeName.dispose();
    _themeJson.dispose();
    super.dispose();
  }

  Future<void> _showImportMenu() async {
    final choice = await showModalBottomSheet<String>(context: context,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(Icons.link_rounded),
            title: Text(_t('Добавить ссылку или JSON', 'Add link or JSON')),
            onTap: () => Navigator.pop(ctx, 'manual')),
          ListTile(leading: const Icon(Icons.content_paste_rounded),
            title: Text(_t('Импортировать из буфера обмена', 'Import from clipboard')),
            onTap: () => Navigator.pop(ctx, 'clipboard')),
          ListTile(leading: const Icon(Icons.qr_code_scanner_rounded),
            title: Text(_t('Сканировать QR', 'Scan QR')),
            onTap: () => Navigator.pop(ctx, 'qr')),
        ],
      )),
    );
    if (!mounted) return;
    switch (choice) {
      case 'manual':
        await _add();
        break;
      case 'clipboard':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted) return;
        final input = data?.text?.trim() ?? '';
        if (input.isEmpty) {
          setState(() => _error = 'Буфер обмена пуст.');
        } else {
          await _importInput('', input);
        }
        break;
      case 'qr':
        final input = await Navigator.push<String>(context,
          MaterialPageRoute(builder: (_) => const _QrScanPage()));
        if (mounted && input != null) await _importInput('', input);
        break;
    }
  }

  Future<void> _importInput(String name, String input) => _perform(() async {
    late final Subscription item;
    try {
      item = await _store.import(name, input);
    } catch (_) {
      if (input.trim().startsWith('https://')) {
        throw const FormatException('Сервер недоступен, возможно активны белые списки');
      }
      rethrow;
    }
    final next = [..._subscriptions];
    next.insert(next.indexWhere((existing) => !existing.pinned) < 0
        ? next.length : next.indexWhere((existing) => !existing.pinned), item);
    await _store.save(next);
    if (mounted) setState(() {
      _subscriptions = next;
      _subscriptionId = item.id;
      _nodeIndex = _firstUsableIndex(item);
      _expandedSubscriptionIds.add(item.id);
    });
    _rememberSelection();
  });

  String _nodeSelectionKey(Map<String, dynamic> node) => jsonEncode([
    node['tag'], node['server'], node['server_port'], node['uuid'],
  ]);

  void _rememberSelection() {
    final selected = _selected;
    final node = selected != null && selected.nodes.isNotEmpty
        ? selected.nodes[_nodeIndex.clamp(0, selected.nodes.length - 1)] : null;
    final id = node == null ? null : selected!.id;
    final nodeKey = node == null ? null : _nodeSelectionKey(node);
    _selectionWrite = _selectionWrite.then((_) async {
      try {
        if (id == null || nodeKey == null) {
          await _settingsStorage.delete(key: _selectedSubscriptionKey);
          await _settingsStorage.delete(key: _selectedNodeKey);
        } else {
          await _settingsStorage.write(key: _selectedSubscriptionKey, value: id);
          await _settingsStorage.write(key: _selectedNodeKey, value: nodeKey);
        }
      } catch (_) {
        // The tile can still use the current selection for this session.
      }
      if (!Platform.isAndroid) return;
      try {
        final profile = node == null ? null : _connectionConfig(selected!, node);
        await _vpn.setQuickTileProfile(profile?.configJson,
            xrayConfig: profile?.xrayJson);
      } catch (_) {
        // Never leave a previous server armed when the selection cannot start.
        await _vpn.setQuickTileProfile(null);
      }
    }).catchError((Object _) {});
  }

  Future<void> _connectFromQuickTile() async {
    if (!_initialized || _handlingTileConnection) return;
    _handlingTileConnection = true;
    try {
      final pending = await _quickTile.invokeMethod<bool>('consumeConnect') ?? false;
      if (!pending && !_tileConnectionPending) return;
      _tileConnectionPending = false;
      if (!mounted || _busy || _pingBusy) return;
      final status = await _vpn.currentStatus();
      if (!mounted || status.state.isActive || status.state.isBusy) return;
      setState(() => _setStatus(status));
      await _selectionWrite;
      if (mounted) await _toggle();
    } catch (_) {
      // The regular connect button remains available if a tile intent fails.
    } finally {
      _handlingTileConnection = false;
    }
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final shouldImport = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Добавить подключение', 'Add connection')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(
                labelText: _t('Название (необязательно)', 'Name (optional)'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _t('Подписка или ссылка сервера', 'Subscription or server link'),
                hintText: _t('https://…, vless://… или Xray JSON',
                    'https://…, vless://… or Xray JSON'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_t('Импортировать', 'Import')),
          ),
        ],
      ),
    );
    final newName = name.text;
    final newUrl = url.text;
    name.dispose();
    url.dispose();
    if (shouldImport != true) return;
    await _importInput(newName, newUrl);
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted)
        setState(
          () => _error = e is FormatException
              ? e.message
              : 'Операция не удалась. Проверьте ссылку и подключение к сети.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    if (_pingBusy) return;
    final item = _selected;
    if (_status.state == VpnState.connected) {
      setState(() => _setStatus(const VpnStatus(VpnState.disconnecting)));
      await _perform(() async {
        try {
          await _vpn.stop();
        } catch (_) {
          if (mounted) setState(() => _setStatus(const VpnStatus(VpnState.connected)));
          rethrow;
        }
      });
      return;
    }
    if (item == null || item.nodes.isEmpty || _status.state.isBusy || _pingBusy) return;
    await _perform(_startSelected);
  }

  Future<void> _startSelected() async {
      final item = _selected;
      if (item == null || item.nodes.isEmpty) return;
      final node = item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
      final profile = _connectionConfig(item, node);
      final validationError = await _vpn.validateConfig(profile.configJson);
      if (validationError != null) throw FormatException(validationError);
      await _vpn.start(profile.configJson, name: 'BMray',
          xrayConfig: profile.xrayJson);
  }

  ({String configJson, String? xrayJson}) _connectionConfig(
      Subscription item, Map<String, dynamic> node) {
      if (node['_unsupported_reason'] != null) {
        throw FormatException(node['_unsupported_reason'].toString());
      }
      final bridge = _useXrayForNode(node) && Platform.isAndroid
          ? buildXrayBridge(node,
              options: const SingboxConfigOptions(usePlatformDns: true))
          : null;
      if (_useXrayForNode(node) && bridge == null) {
        throw const FormatException('Этот профиль Xray доступен только на Android.');
      }
      final config = bridge?.singbox ?? buildSingboxConfig(node,
          options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
      if (item.directRules.isNotEmpty && node['type'] != 'auto') {
        (config['route']['rules'] as List).addAll(item.directRules);
      }
      return (configJson: jsonEncode(config),
          xrayJson: bridge == null ? null : jsonEncode(bridge.xray));
  }

  Future<void> _waitForDisconnect() async {
    for (var attempt = 0; attempt < 60; attempt++) {
      if ((await _vpn.currentStatus()).state == VpnState.disconnected) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const FormatException('VPN не успел отключиться. Повторите попытку.');
  }

  Future<void> _selectServer(Subscription item, int index) async {
    if (_busy || _pingBusy || _status.state.isBusy ||
        (_selected?.id == item.id && _nodeIndex == index)) return;
    if (_status.state == VpnState.connected) {
      await _perform(() async {
        await _vpn.stop();
        await _waitForDisconnect();
        if (!mounted) return;
        setState(() {
          _subscriptionId = item.id;
          _nodeIndex = index;
        });
        _rememberSelection();
        await _startSelected();
      });
    } else {
      setState(() {
        _subscriptionId = item.id;
        _nodeIndex = index;
      });
      _rememberSelection();
    }
  }

  Future<void> _refresh(Subscription item) async {
    if (_pingBusy) {
      ++_pingEpoch;
      setState(() => _error = null);
    }
    await _perform(() async {
      try {
        await _refreshSubscription(item);
      } catch (_) {
        throw const FormatException('Сервер недоступен, возможно активны белые списки');
      }
    });
  }

  Future<void> _refreshSubscription(Subscription item) async {
    final selected = _selected?.id == item.id && item.nodes.isNotEmpty
        ? item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)] : null;
    await _store.refresh(item);
    if (selected != null) {
      final match = item.nodes.indexWhere((node) =>
          node['tag'] == selected['tag'] && node['server'] == selected['server']);
      _nodeIndex = match < 0 ? _firstUsableIndex(item) : match;
    }
    _latencies.removeWhere((key, _) => key.startsWith('${item.id}:'));
    _pingErrors.removeWhere((key, _) => key.startsWith('${item.id}:'));
    await _store.save(_subscriptions);
    _rememberSelection();
    if (mounted) setState(() {});
  }

  Future<void> _refreshDueSubscriptions() async {
    if (!mounted || _busy || _autoRefreshing) return;
    _autoRefreshing = true;
    try {
      for (final item in List<Subscription>.of(_subscriptions)) {
        if (!mounted || _busy) break;
        final hours = item.updateHours;
        if (!item.isRemote || (hours == null && item.lastUpdatedAt != null)) continue;
        final now = DateTime.now();
        if ((hours != null && item.lastUpdatedAt != null &&
                now.isBefore(item.lastUpdatedAt!.add(Duration(hours: hours)))) ||
            now.isBefore(_autoRetryAfter[item.id] ?? DateTime.fromMillisecondsSinceEpoch(0))) {
          continue;
        }
        try {
          await _refreshSubscription(item);
          _autoRetryAfter.remove(item.id);
        } catch (_) {
          _autoRetryAfter[item.id] = DateTime.now().add(const Duration(minutes: 15));
        }
      }
    } finally {
      _autoRefreshing = false;
    }
  }

  Future<void> _moveSubscription(Subscription item, int direction) => _perform(() async {
    final index = _subscriptions.indexWhere((entry) => entry.id == item.id);
    final target = index + direction;
    if (target < 0 || target >= _subscriptions.length ||
        _subscriptions[target].pinned != item.pinned) return;
    final next = [..._subscriptions];
    next[index] = next[target];
    next[target] = item;
    await _store.save(next);
    if (mounted) setState(() => _subscriptions = next);
  });

  Future<void> _toggleSubscriptionPin(Subscription item) => _perform(() async {
    final next = _subscriptions.where((entry) => entry.id != item.id).toList();
    final pinned = !item.pinned;
    final index = pinned ? 0 : next.indexWhere((entry) => !entry.pinned);
    final insertion = index < 0 ? next.length : index;
    item.pinned = pinned;
    next.insert(insertion, item);
    try {
      await _store.save(next);
    } catch (_) {
      item.pinned = !pinned;
      rethrow;
    }
    if (mounted) setState(() => _subscriptions = next);
  });

  String _delayKey(Subscription item, int index) =>
      '${item.id}:$index:${_pingMethod.name}';

  String _formatJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(value is String ? jsonDecode(value) : value);
    } catch (error) {
      return 'Не удалось сформировать JSON: $error';
    }
  }

  String _formatSource(String source) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
    } on FormatException {
      return source;
    }
  }

  void _showSubscriptionJson(Subscription item) {
    final source = item.rawResponse;
    final decoded = source == null ? null : decodedSubscriptionResponse(source);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
        JsonConfigPage(title: item.name, tabs: [
          JsonConfigTab('Ответ подписки', source == null
              ? 'Исходный ответ ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
              : _formatSource(source)),
          if (decoded != null)
            JsonConfigTab('Декодировано', _formatSource(decoded)),
        ])));
  }

  void _showNodeJson(Subscription item, int index) {
    final node = item.nodes[index];
    final source = item.rawResponse;
    final decoded = source == null ? null : decodedSubscriptionResponse(source);
    final tabs = <JsonConfigTab>[
      JsonConfigTab('Ответ подписки', source == null
          ? 'Исходный ответ ещё не сохранён. Обновите подписку или импортируйте профиль заново.'
          : _formatSource(source)),
      if (decoded != null)
        JsonConfigTab('Декодировано', _formatSource(decoded)),
      JsonConfigTab('Импортированный узел', _formatJson(node)),
    ];
    final key = _delayKey(item, index);
    final diagnostics = <String, dynamic>{
      'method': _pingMethod.name,
      'proxyTimeoutSeconds': _proxyTimeoutSeconds,
      'lastLatencyMs': _latencies[key],
      'lastError': _pingErrors[key],
      'profileKind': node['_xray_template'] is Map
          ? 'Xray template with balancer'
          : node['_xray_outbound'] is Map
              ? 'Individual Xray outbound'
              : 'Individual server',
      if (node['_template_warning'] != null)
        'templateWarning': node['_template_warning'],
    };
    final server = node['server']?.toString();
    if (node['type'] != 'auto' && server != null &&
        (server == 'localhost' ||
            InternetAddress.tryParse(server)?.isLoopback == true)) {
      diagnostics['warning'] = 'Этот выход направлен на $server:${node['server_port']} '
          'на самом телефоне. Он не может достичь удалённого VPN-сервера '
          'без отдельного локального прокси. Сравните ответ подписки с конфигом HAPP.';
    }
    try {
      if (_useXrayForNode(node)) {
        final bridge = buildXrayBridge(node,
            options: const SingboxConfigOptions(usePlatformDns: true));
        tabs.add(JsonConfigTab('Xray: подключение', _formatJson(bridge.xray)));
        tabs.add(JsonConfigTab('sing-box: туннель', _formatJson(bridge.singbox)));
        diagnostics['note'] = 'Локальный SOCKS порт и пароль генерируются заново при подключении.';
        final template = node['_xray_template'];
        if (template is Map && template['routing'] is Map &&
            template['outbounds'] is List) {
          final routing = template['routing'] as Map;
          final balancers = routing['balancers'];
          if (balancers is List && balancers.isNotEmpty && balancers.first is Map) {
            final balancer = balancers.first as Map;
            final selectors = (balancer['selector'] is List)
                ? (balancer['selector'] as List).map((value) => value.toString()).toList()
                : <String>[];
            final outbounds = (template['outbounds'] as List).whereType<Map>().toList();
            final candidates = outbounds.where((outbound) =>
                selectors.any((prefix) => (outbound['tag']?.toString() ?? '')
                    .startsWith(prefix))).toList();
            final fallback = balancer['fallbackTag']?.toString();
            diagnostics['selectors'] = selectors;
            diagnostics['candidates'] = [for (final outbound in candidates)
              {'tag': outbound['tag'], 'protocol': outbound['protocol'],
                'vnext': (outbound['settings'] is Map)
                    ? (outbound['settings'] as Map)['vnext'] : null}];
            diagnostics['fallbackTag'] = fallback;
            diagnostics['fallbackExists'] = outbounds.any((entry) => entry['tag'] == fallback);
            for (final outbound in [
              if (candidates.isNotEmpty) candidates.first,
              if (fallback != null) ...outbounds.where((entry) => entry['tag'] == fallback),
            ]) {
              final tag = outbound['tag']?.toString();
              if (tag == null) continue;
              final probe = buildXrayBridge(node, probe: true,
                  probeOutboundTag: tag,
                  options: const SingboxConfigOptions(usePlatformDns: true));
              tabs.add(JsonConfigTab('Пинг: $tag', _formatJson(probe.xray)));
            }
          }
        } else {
          final probe = buildXrayBridge(node, probe: true,
              options: const SingboxConfigOptions(usePlatformDns: true));
          tabs.add(JsonConfigTab('Xray: пинг', _formatJson(probe.xray)));
        }
      } else {
        final config = buildSingboxConfig(node,
            options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
        if (item.directRules.isNotEmpty && node['type'] != 'auto') {
          (config['route']['rules'] as List).addAll(item.directRules);
        }
        tabs.add(JsonConfigTab('sing-box: подключение', _formatJson(config)));
      }
    } catch (error) {
      diagnostics['configError'] = error.toString();
    }
    tabs.add(JsonConfigTab('Диагностика', _formatJson(diagnostics)));
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
        JsonConfigPage(title: node['tag']?.toString() ?? 'Сервер ${index + 1}',
            tabs: tabs)));
  }

  Future<({int? delay, String? reason})> _probeAutoProxy(
      Map<String, dynamic> node) async {
    final template = node['_xray_template'];
    if (template is! Map || template['outbounds'] is! List ||
        template['routing'] is! Map) {
      return (delay: null, reason: 'Автовыбор: нет серверов');
    }
    final routing = template['routing'] as Map;
    final balancers = routing['balancers'];
    if (balancers is! List || balancers.isEmpty || balancers.first is! Map) {
      return (delay: null, reason: 'Автовыбор: нет балансировщика');
    }
    final balancer = balancers.first as Map;
    final selectors = balancer['selector'] is List
        ? (balancer['selector'] as List).map((item) => item.toString()).toList()
        : <String>[];
    final tags = (template['outbounds'] as List)
        .whereType<Map>()
        .map((item) => item['tag']?.toString() ?? '')
        .where((tag) => selectors.any((prefix) => tag.startsWith(prefix)))
        .toList();
    final fallback = balancer['fallbackTag']?.toString();
    final available = (template['outbounds'] as List)
        .whereType<Map>().any((item) => item['tag'] == fallback);
    int? fastest;
    String? lastError;
    for (final tag in tags) {
      try {
        final bridge = buildXrayBridge(node, probe: true,
            probeOutboundTag: tag,
            options: const SingboxConfigOptions(usePlatformDns: true));
        final result = await _vpn.proxyGetDelay(jsonEncode(bridge.singbox),
            timeout: Duration(seconds: _proxyTimeoutSeconds),
            xrayConfig: jsonEncode(bridge.xray));
        if (result.delay != null &&
            (fastest == null || result.delay! < fastest)) {
          fastest = result.delay;
        }
        lastError = result.reason ?? lastError;
      } catch (_) {
        lastError = 'Ошибка проверки прокси';
      }
    }
    if (fastest == null && available && fallback != null &&
        !tags.contains(fallback)) {
      try {
        final bridge = buildXrayBridge(node, probe: true,
            probeOutboundTag: fallback,
            options: const SingboxConfigOptions(usePlatformDns: true));
        final result = await _vpn.proxyGetDelay(jsonEncode(bridge.singbox),
            timeout: Duration(seconds: _proxyTimeoutSeconds),
            xrayConfig: jsonEncode(bridge.xray));
        fastest = result.delay;
        lastError = result.reason ?? lastError;
      } catch (_) {
        lastError = 'Ошибка проверки резервного сервера';
      }
    }
    return (delay: fastest,
        reason: fastest == null ? lastError ?? 'Автовыбор: нет ответа' : null);
  }

  Future<({int? delay, String? reason})> _probe(Map<String, dynamic> node) async {
    if (node['type'] == 'auto' && _pingMethod != PingMethod.proxyGet) {
      final template = node['_xray_template'];
      final outbounds = template is Map ? template['outbounds'] : null;
      final endpoints = <String, Map<String, dynamic>>{};
      if (outbounds is List) {
        for (final outbound in outbounds) {
          final settings = outbound is Map ? outbound['settings'] : null;
          final vnext = settings is Map ? settings['vnext'] : null;
          if (vnext is! List || vnext.isEmpty || vnext.first is! Map) continue;
          final target = vnext.first as Map;
          final host = target['address']?.toString();
          final port = int.tryParse('${target['port']}');
          if (host == null || port == null) continue;
          endpoints['$host:$port'] = {'server': host, 'server_port': port};
        }
      }
      int? fastest;
      for (final endpoint in endpoints.values) {
        final result = await _probe(endpoint);
        if (result.delay != null &&
            (fastest == null || result.delay! < fastest)) fastest = result.delay;
      }
      return (delay: fastest,
          reason: fastest == null ? 'Автовыбор: нет ответа от серверов' : null);
    }
    final host = node['server']?.toString() ?? '';
    final port = node['server_port'];
    switch (_pingMethod) {
      case PingMethod.tcp:
        if (port is! int || host.isEmpty) return (delay: null, reason: 'Некорректный адрес');
        final delay = await _vpn.tcpDelay(host, port);
        return (delay: delay, reason: delay == null ? 'TCP: нет ответа' : null);
      case PingMethod.icmp:
        if (!Platform.isAndroid ||
            !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$').hasMatch(host)) {
          return (delay: null, reason: 'Некорректный адрес');
        }
        try {
          final process = await Process.run('ping', [
            '-c', '1', '-W', '2', host,
          ]).timeout(const Duration(seconds: 4));
          if (process.exitCode != 0) return (delay: null, reason: 'ICMP: нет ответа');
          final match = RegExp(r'time[=<]([\d.]+)')
              .firstMatch(process.stdout.toString());
          return (delay: match == null ? null : double.parse(match.group(1)!).ceil(),
              reason: match == null ? 'ICMP: нет ответа' : null);
        } catch (_) {
          return (delay: null, reason: 'ICMP: проверка недоступна');
        }
      case PingMethod.proxyGet:
        if (node['_unsupported_reason'] != null) {
          return (delay: null, reason: node['_unsupported_reason'].toString());
        }
        if (_useXrayForNode(node) && !Platform.isAndroid) {
          return (delay: null, reason: 'Этот профиль Xray доступен только на Android');
        }
        if (node['type'] == 'auto') return _probeAutoProxy(node);
        final bridge = _useXrayForNode(node) ? buildXrayBridge(node, probe: true,
            options: const SingboxConfigOptions(usePlatformDns: true)) : null;
        final config = bridge?.singbox ?? buildSingboxConfig(node,
            options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
        config['inbounds'] = <Object>[];
        try {
          final result = await _vpn.proxyGetDelay(jsonEncode(config),
              timeout: Duration(seconds: node['type'] == 'auto' &&
                  _proxyTimeoutSeconds < 12 ? 12 : _proxyTimeoutSeconds),
              xrayConfig: bridge == null ? null : jsonEncode(bridge.xray));
          return (delay: result.delay, reason: result.reason);
        } catch (_) {
          return (delay: null, reason: 'Ошибка проверки прокси');
        }
    }
  }

  Future<void> _ping(Subscription item, List<int> indices) async {
    if (_pingBusy || _busy || _status.state.isBusy) return;
    final epoch = ++_pingEpoch;
    final nodes = List<Map<String, dynamic>>.of(item.nodes);
    setState(() {
      _pingBusy = true;
      _error = null;
      for (final index in indices) {
        _latencies.remove(_delayKey(item, index));
        _pingErrors.remove(_delayKey(item, index));
      }
    });
    final method = _pingMethod;
    try {
      if (_status.state == VpnState.connected) {
        await _vpn.stop();
        await _waitForDisconnect();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (Platform.isAndroid) {
        await _prepareNetworkForPing(item, indices, epoch);
      }
      if (epoch != _pingEpoch) return;
      if (await _vpn.otherVpnActive()) {
        throw const FormatException('Выключите VPN другого приложения в настройках Android перед проверкой.');
      }
      for (var start = 0; start < indices.length; start += 3) {
        if (epoch != _pingEpoch) break;
        final batch = indices.skip(start).take(3).toList();
        final values = await Future.wait(batch.map((i) => _probe(nodes[i])));
        if (!mounted || epoch != _pingEpoch || method != _pingMethod) break;
        setState(() {
          for (var j = 0; j < batch.length; j++) {
            _latencies[_delayKey(item, batch[j])] = values[j].delay;
            if (values[j].reason != null) {
              _pingErrors[_delayKey(item, batch[j])] = values[j].reason!;
            }
          }
        });
      }
    } catch (error) {
      if (mounted && epoch == _pingEpoch) setState(() => _error = error is FormatException
          ? error.message : 'Проверка серверов не удалась.');
    } finally {
      if (mounted) setState(() => _pingBusy = false);
    }
  }

  Future<void> _prepareNetworkForPing(
      Subscription item, List<int> indices, int epoch) async {
    final candidates = <Map<String, dynamic>>[
      for (final index in indices)
        if (index >= 0 && index < item.nodes.length) item.nodes[index],
      for (final subscription in _subscriptions) ...subscription.nodes,
    ];
    String? configJson;
    String? xrayJson;
    for (final node in candidates) {
      if (epoch != _pingEpoch) return;
      final host = node['server']?.toString() ?? '';
      if (node['_unsupported_reason'] != null || host.isEmpty ||
          host == 'localhost' ||
          InternetAddress.tryParse(host)?.isLoopback == true) continue;
      try {
        final bridge = _useXrayForNode(node)
            ? buildXrayBridge(node,
                options: const SingboxConfigOptions(usePlatformDns: true))
            : null;
        final config = bridge?.singbox ?? buildSingboxConfig(node,
            options: const SingboxConfigOptions(usePlatformDns: true));
        final candidateJson = jsonEncode(config);
        if (await _vpn.validateConfig(candidateJson) != null) continue;
        configJson = candidateJson;
        xrayJson = bridge == null ? null : jsonEncode(bridge.xray);
        break;
      } catch (_) {
        // A different imported server may still be suitable for preparation.
      }
    }
    if (configJson == null) {
      if (await _vpn.otherVpnActive()) {
        throw const FormatException('Нет пригодного сервера для смены VPN перед пингом.');
      }
      return;
    }
    var attempted = false;
    try {
      attempted = true;
      await _vpn.start(configJson, name: 'BMray', xrayConfig: xrayJson);
      for (var attempt = 0; attempt < 100; attempt++) {
        if (epoch != _pingEpoch) return;
        final status = await _vpn.currentStatus();
        if (status.state == VpnState.connected) break;
        if (status.state == VpnState.error) {
          throw FormatException(status.message ?? 'Не удалось подготовить VPN для пинга.');
        }
        if (attempt == 99) {
          throw const FormatException('VPN не запустился для подготовки пинга.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      if (attempted) {
        await _vpn.stop();
        await _waitForDisconnect();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  String _safeLogs(String logs) => logs
        .replaceAll(
          RegExp(r'(?:vless|vmess|trojan|ss|hy2|hysteria2|tuic)://\S+'),
          '[ссылка скрыта]',
        )
        .replaceAll(
          RegExp(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'),
          '[UUID скрыт]',
        );

  Future<void> _remove(Subscription item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('Удалить подписку?', 'Delete subscription?')),
        content: Text(item.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_t('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_t('Удалить', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _perform(() async {
      final removedSelected = _selected?.id == item.id;
      if (_status.state.isActive) await _vpn.stop();
      final next = _subscriptions.where((e) => e.id != item.id).toList();
      await _store.save(next);
      if (mounted)
        setState(() {
          _subscriptions = next;
          _expandedSubscriptionIds.remove(item.id);
          if (removedSelected) {
            _subscriptionId = next.isEmpty ? null : next.first.id;
            _nodeIndex = next.isEmpty ? 0 : _firstUsableIndex(next.first);
          }
        });
      _rememberSelection();
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    final isActive = _status.state == VpnState.connected;
    final isConnecting = _status.state == VpnState.connecting;
    final canChange =
        !_busy && !_pingBusy && !_autoRefreshing && !_status.state.isBusy;
    final label = switch (_status.state) {
      VpnState.connected => _t('Подключено', 'Connected'),
      VpnState.connecting => _t('Подключение…', 'Connecting…'),
      VpnState.disconnecting => _t('Отключение…', 'Disconnecting…'),
      VpnState.reasserting => _t('Восстановление…', 'Reconnecting…'),
      VpnState.error => _t('Ошибка подключения', 'Connection error'),
      _ => _t('Не подключено', 'Disconnected'),
    };
    return PopScope(
      canPop: _pageIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _pageIndex = _pageIndex == 1 ? 0 : 1);
      },
      child: Scaffold(
      appBar: AppBar(
        backgroundColor: appearance.backgroundColors.first,
        leading: IconButton(
          tooltip: _pageIndex == 0 ? _t('Настройки', 'Settings') : _t('Назад', 'Back'),
          onPressed: () => setState(() {
            if (_pageIndex == 0) {
              _pageIndex = 1;
              _logs = _vpn.readLogs();
            } else {
              _pageIndex = _pageIndex == 1 ? 0 : 1;
            }
          }),
          icon: Icon(_pageIndex == 0 ? Icons.settings_rounded : Icons.arrow_back_rounded),
        ),
        title: _pageIndex == 0 ? Row(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(7),
            child: Image.asset('assets/brand/logo.jpg', width: 34, height: 34)),
          const SizedBox(width: 10),
          const Text('BMray', style: TextStyle(fontWeight: FontWeight.w800)),
        ]) : Text(switch (_pageIndex) {
          1 => _t('Настройки', 'Settings'),
          2 => _t('Пинг', 'Ping'),
          3 => _t('Информация', 'Information'),
          4 => _t('Журнал подключения', 'Connection log'),
          5 => 'User-Agent', 6 => _t('Кэш', 'Cache'),
          7 => _t('Запросы подписки', 'Subscription requests'),
          8 => _t('Прокси для приложений', 'Per-app proxy'),
          9 => _t('Язык', 'Language'),
          10 => _t('Темы', 'Themes'),
          _ => _t('Настройки', 'Settings'),
        }),
        actions: [
          if (_pageIndex == 0) IconButton(
            tooltip: _t('Добавить', 'Add'), onPressed: _busy || _autoRefreshing ? null : _showImportMenu,
            icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
      body: _pageIndex != 0 ? SafeArea(child: switch (_pageIndex) {
        1 => _settingsView(),
        2 => _pingSettingsView(),
        3 => _informationView(),
        4 => _logsView(),
        5 => _userAgentView(),
        6 => _cacheView(),
        7 => _subscriptionRequestsView(),
        8 => _perAppView(),
        9 => _languageView(),
        10 => _themesView(),
        _ => _settingsView(),
      }) : SafeArea(child: LayoutBuilder(builder: (context, constraints) => Column(
        children: [
          SizedBox(
            height: constraints.maxHeight * 0.31,
            child: _connectionPanel(item, label, isActive, isConnecting),
          ),
          Expanded(child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            if (_error != null) Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(14),
                  child: Text(_error!, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)))),
            ),
            const SizedBox(height: 8),
            Text(_t('Подписки и серверы', 'Subscriptions and servers'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (_subscriptions.isEmpty)
              Card(child: Padding(padding: const EdgeInsets.all(18), child: Text(
                _t('Нажмите +, чтобы добавить подписку или ссылку сервера.',
                    'Tap + to add a subscription or server link.'),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)))),
            for (final subscription in _subscriptions) Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _subscriptionCard(subscription, canChange),
            ),
          ],
          )),
        ],
      ))),
      ),
    );
  }

  Widget _connectionPanel(Subscription? item, String label,
      bool isActive, bool isConnecting) {
    final node = item == null || item.nodes.isEmpty ? null
        : item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
    final canToggle = !_busy && !_pingBusy &&
        _status.state != VpnState.disconnecting &&
        _status.state != VpnState.reasserting && !isConnecting &&
        (isActive || (node != null && node['_unsupported_reason'] == null));
    return LayoutBuilder(builder: (context, constraints) {
      final diameter = (constraints.maxHeight * 0.46).clamp(64.0, 144.0).toDouble();
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          transform: GradientRotation(
            ((appearance.palette['backgroundGradientRotationAngle'] as num?) ?? 0)
                .toDouble() * math.pi / 180),
          colors: appearance.backgroundColors)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Semantics(
            button: true,
            label: isActive ? 'Отключить VPN' : 'Подключить VPN',
            child: Material(
              color: appearance.color('buttonColor'),
              shape: CircleBorder(side: BorderSide(
                color: appearance.color('settingsControlsTintColor'),
                width: 5,
              )),
              elevation: 10,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: canToggle ? _toggle : null,
                child: SizedBox(width: diameter, height: diameter,
                  child: Center(child: _busy || isConnecting
                    ? const CircularProgressIndicator()
                    : Icon(Icons.power_settings_new_rounded,
                        size: diameter * 0.43,
                        color: appearance.color('powerIconColor'))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: appearance.color('serverRowTitleTextColor'))),
          if (isActive && _connectedAt != null) Text(_uptimeLabel(),
            style: TextStyle(fontSize: 13,
                color: appearance.color('buttonTimerColor'))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(node?['tag']?.toString() ??
                (item?.name ?? _t('Добавьте подписку, чтобы начать',
                    'Add a subscription to begin')),
              maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12,
                  color: appearance.color('serverRowSubTitleTextColor')))),
        ]),
      );
    });
  }

  String _uptimeLabel() {
    final elapsed = DateTime.now().difference(_connectedAt!);
    final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
    final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$rest';
  }

  Widget _settingsView() => ListView(children: [
    _settingsHeading(_t('Подписка', 'Subscription')),
    _settingsEntry('User-Agent', 'HWID, User-Agent и Cookie BMray',
        Icons.badge_outlined, 5),
    _settingsHeading(_t('Проверка соединения', 'Connection diagnostics')),
    _settingsEntry(_t('Пинг', 'Ping'), 'Proxy GET, TCP, ICMP', Icons.speed_rounded, 2),
    _settingsEntry(_t('Логи запросов подписки', 'Subscription requests'),
        _t('HTTP-ответы и выбор формата подписки', 'HTTP responses and formats'),
        Icons.receipt_long_outlined, 7),
    _settingsEntry(_t('Журнал подключения', 'Connection log'),
        _t('Логи ядра и VPN', 'Core and VPN logs'),
        Icons.description_outlined, 4),
    _settingsHeading(_t('Настройки туннеля', 'Tunnel settings')),
    if (Platform.isAndroid) ListTile(
      leading: const Icon(Icons.power_settings_new_rounded),
      title: Text(_t('Кнопка VPN в быстрых настройках',
          'VPN tile in Quick Settings')),
      subtitle: Text(_t('Включайте выбранный сервер из панели телефона',
          'Toggle the selected server from the phone panel')),
      trailing: const Icon(Icons.add_circle_outline_rounded),
      onTap: _addQuickTile,
    ),
    _settingsEntry(_t('Прокси для выбранных приложений', 'Per-app proxy'),
        _t('Все приложения, только выбранные или обход',
          'All apps, selected apps or bypass'), Icons.apps_rounded, 8),
    _settingsHeading(_t('Кастомизация', 'Customization')),
    _settingsEntry(_t('Язык', 'Language'),
        _t('Системный, русский или английский', 'System, Russian or English'),
        Icons.language_rounded, 9),
    _settingsEntry(_t('Темы', 'Themes'),
        _t('Светлая, тёмная и собственные темы', 'Light, dark and custom themes'),
        Icons.palette_outlined, 10),
    _settingsHeading(_t('Приложение', 'Application')),
    _settingsEntry(_t('Кэш', 'Cache'),
        _t('Лимит размера и очистка журнала', 'Size limit and clear log'),
        Icons.storage_rounded, 6),
    _settingsEntry(_t('Информация', 'Information'),
        _t('Версии и сведения о системе', 'Versions and system details'),
        Icons.info_outline_rounded, 3),
  ]);

  Future<void> _addQuickTile() async {
    bool added = false;
    try {
      added = await _quickTile.invokeMethod<bool>('requestAdd') ?? false;
    } catch (_) {
      // The user can still add the tile through Android's Quick Settings editor.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added
        ? _t('Кнопка BMray добавлена в быстрые настройки.',
            'BMray tile added to Quick Settings.')
        : _t('Откройте панель быстрых настроек, нажмите «Изменить» и добавьте BMray VPN.',
            'Open Quick Settings, tap Edit and add BMray VPN.'))));
  }

  Future<void> _setCacheLimit(int megabytes) async {
    try {
      await _store.requestLog.setLimitMb(megabytes);
      await _settingsStorage.write(key: _cacheLimitKey, value: '$megabytes');
      if (mounted) setState(() => _cacheSize = _store.requestLog.sizeBytes());
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось изменить размер кэша.');
    }
  }

  Widget _cacheView() => ListView(padding: const EdgeInsets.all(16), children: [
    Text(_t('Кэш', 'Cache'), style: const TextStyle(fontSize: 20,
        fontWeight: FontWeight.w700)),
    const SizedBox(height: 12),
    Text(_t('В кэше хранится журнал запросов подписок: время, адрес сервера '
        'без секретного пути и параметров, отправленные имена заголовков, '
        'User-Agent, HTTP-статус, имена заголовков ответа и формат содержимого. '
        'Для Base64 записывается число ссылок и их протоколы; для JSON — '
        'ключи и число выходов. Сами ссылки, ключи, HWID, Cookie и тело ответа '
        'в журнал не записываются. Исходные подписки и выбранный сервер '
        'хранятся отдельно; очистка кэша их не удалит. Android и iOS могут '
        'очистить временный кэш автоматически. Лимит относится к этому '
        'журналу; журнал ядра и системные временные файлы в него не входят.',
        'The cache stores subscription request logs: time, host without secret '
        'path or query, header names, User-Agent, HTTP status and response '
        'format. Links, credentials, HWID, Cookie values and response bodies '
        'are not logged. Imported subscriptions and selected server are stored '
        'separately. This limit does not include core logs or system cache.')),
    const SizedBox(height: 20),
    Text(_t('Максимальный размер: $_cacheLimitMb МБ',
        'Maximum size: $_cacheLimitMb MB'),
        style: const TextStyle(fontWeight: FontWeight.w600)),
    Slider(
      min: 5, max: 500, divisions: 99,
      value: _cacheLimitMb.toDouble(),
      label: _t('$_cacheLimitMb МБ', '$_cacheLimitMb MB'),
      onChanged: (value) => setState(() =>
          _cacheLimitMb = (value / 5).round() * 5),
      onChangeEnd: (value) => _setCacheLimit((value / 5).round() * 5),
    ),
    FutureBuilder<int>(future: _cacheSize, builder: (context, snapshot) =>
        Text('${_t('Занято', 'Used')}: ${snapshot.hasData ? _formatTraffic(snapshot.data) : '…'}')),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      icon: const Icon(Icons.delete_outline_rounded),
      label: Text(_t('Очистить журнал запросов', 'Clear request log')),
      onPressed: () async {
        await _store.requestLog.clear();
        if (mounted) setState(() {
          _cacheSize = _store.requestLog.sizeBytes();
          _requestLogs = _store.requestLog.read();
        });
      },
    ),
  ]);

  Widget _subscriptionRequestsView() => FutureBuilder<String>(
    future: _requestLogs,
    builder: (context, snapshot) {
      final logs = snapshot.data ?? '';
      return Padding(padding: const EdgeInsets.all(16), child: Column(children: [
        Text(_t('Обновите подписку, затем скопируйте журнал и отправьте его '
            'для диагностики. Секретные значения заголовков и ссылки скрыты.',
            'Refresh a subscription, then copy the log for diagnostics. '
            'Secret header values and links are hidden.')),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Text(_t('Последние 256 КБ журнала', 'Last 256 KB of logs'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          IconButton(tooltip: _t('Обновить', 'Refresh'),
              onPressed: () => setState(() => _requestLogs = _store.requestLog.read()),
              icon: const Icon(Icons.refresh_rounded)),
          IconButton(tooltip: _t('Копировать для диагностики', 'Copy diagnostics'),
              onPressed: logs.isEmpty ? null : () =>
                  Clipboard.setData(ClipboardData(text: logs)),
              icon: const Icon(Icons.copy_rounded)),
        ]),
        const SizedBox(height: 8),
        Expanded(child: Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: SingleChildScrollView(child: SelectableText(
            snapshot.hasError ? _t('Не удалось прочитать кэш.', 'Unable to read cache.') :
            snapshot.connectionState != ConnectionState.done ? _t('Загрузка…', 'Loading…') :
            logs.isEmpty ? _t('Журнал пуст. Обновите подписку и вернитесь сюда.',
                'Log is empty. Refresh a subscription and return here.') : logs,
          )),
        ))),
      ]));
    },
  );

  Widget _settingsHeading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
    child: Text(title, style: TextStyle(fontSize: 16,
      fontWeight: FontWeight.w700,
      color: appearance.color('settingsControlsTintColor'))),
  );

  Widget _settingsEntry(String title, String subtitle, IconData icon, int page) =>
    Column(children: [
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => setState(() {
          _pageIndex = page;
          if (page == 6) _cacheSize = _store.requestLog.sizeBytes();
          if (page == 7) _requestLogs = _store.requestLog.read();
          if (page == 4) _logs = _vpn.readLogs();
        }),
      ),
      const Divider(height: 1),
    ]);

  Widget _userAgentView() => ListView(padding: const EdgeInsets.all(16), children: [
    Text(_t('Идентификатор подписки', 'Subscription identity'), style: const TextStyle(
      fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 12),
    Text(_t('BMray отправляет постоянный HWID в x-hwid и Cookie BMray. '
      'Изменение HWID может занять новое место в лимите устройств панели.',
      'BMray sends a stable HWID and BMray Cookie. Changing HWID may use '
      'another device slot on the provider panel.')),
    const SizedBox(height: 8),
    Text(_t('Для подписки Base64 с локальным адресом АвтоБС BMray '
      'повторяет запрос с User-Agent «Happ/версия BMray/…»: панель может '
      'выдать готовый XRAY_JSON. В остальных запросах действует '
      'указанный ниже User-Agent. Если он уже начинается с Happ, повторного '
      'запроса не будет.',
      'For Base64 subscriptions with a loopback AutoBS host, BMray retries '
      'with a Happ-compatible User-Agent to request XRAY_JSON. A manually '
      'configured User-Agent starting with Happ is never rewritten.')),
    const SizedBox(height: 18),
    TextField(controller: _hwidInput, autocorrect: false,
      decoration: InputDecoration(labelText: 'HWID',
        helperText: _t('10–64 символа: латинские буквы, цифры, = или -',
            '10–64 characters: letters, digits, = or -'),
        border: const OutlineInputBorder())),
    const SizedBox(height: 18),
    TextField(controller: _userAgentInput, autocorrect: false,
      decoration: const InputDecoration(labelText: 'User-Agent',
        border: OutlineInputBorder())),
    const SizedBox(height: 18),
    FilledButton(onPressed: _busy ? null : () => _perform(() async {
      final next = SubscriptionIdentity(
        _hwidInput.text.trim(), _userAgentInput.text.trim());
      try {
        await next.save();
      } on FormatException catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error.message)));
        rethrow;
      }
      _store.identity = next;
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Настройки подписки сохранены',
              'Subscription settings saved'))));
    }), child: Text(_t('Сохранить', 'Save'))),
  ]);

  Widget _pingSettingsView() {
    final description = switch (_pingMethod) {
      PingMethod.proxyGet =>
        _t('Proxy GET: выполняет настоящий HTTPS GET через выбранный сервер. '
        'Проверяет, что прокси подключается и передаёт данные.',
        'Proxy GET sends an HTTPS request through the selected server and '
        'checks that the proxy connects and transfers data.'),
      PingMethod.tcp =>
        _t('TCP: измеряет время прямого соединения с адресом и портом сервера. '
        'Не проверяет авторизацию и работу прокси.',
        'TCP measures a direct connection to the server. It does not '
        'verify proxy authentication.'),
      PingMethod.icmp =>
        _t('ICMP: отправляет эхо-запрос на адрес сервера без прокси. '
        'Сервер может не отвечать на ICMP, даже если подключение работает. '
        'Перед проверкой отключите VPN.',
        'ICMP sends an echo request directly to the server. It may fail '
        'even when the proxy works.'),
    };
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t('Способ проверки', 'Ping method'), style: const TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 16),
      for (final option in PingMethod.values) Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: _pingMethod == option ? appearance.color('selectedServerRowColor') :
              Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: _pingBusy ? null : () => setState(() => _pingMethod = option),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _pingMethod == option
                    ? Theme.of(context).colorScheme.primary : Colors.transparent,
                    width: 1.5),
              ),
              child: Row(children: [
                Icon(switch (option) {
                  PingMethod.proxyGet => Icons.public_rounded,
                  PingMethod.tcp => Icons.cable_rounded,
                  PingMethod.icmp => Icons.graphic_eq_rounded,
                }, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (option) {
                      PingMethod.proxyGet => 'Proxy GET',
                      PingMethod.tcp => 'TCP',
                      PingMethod.icmp => 'ICMP',
                    }, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(switch (option) {
                      PingMethod.proxyGet => _t('Запрос через прокси', 'Request through proxy'),
                      PingMethod.tcp => _t('Прямое TCP соединение', 'Direct TCP connection'),
                      PingMethod.icmp => _t('Эхо-запрос до адреса', 'Echo request to host'),
                    }, style: TextStyle(fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ])),
                if (_pingMethod == option) Container(width: 8, height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Text(description))),
      const SizedBox(height: 12),
      Text(_t('Выбранный способ применяется к кнопкам проверки на экране серверов.',
          'The selected method is used by server ping buttons.'),
        style: const TextStyle(color: Color(0xFF9DAEC7))),
      const SizedBox(height: 24),
      Text(_t('Тайм-аут Proxy GET', 'Proxy GET timeout'), style: const TextStyle(
        fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(_t('Время ожидания одного HTTPS-запроса. При неудаче проверка пробует следующий адрес.',
          'Wait time for one HTTPS request. On failure, try the next address.'),
        style: const TextStyle(color: Color(0xFF9DAEC7))),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        for (final seconds in [2, 4, 6, 10]) ChoiceChip(
          label: Text(_t('$seconds с', '$seconds s')),
          selected: _proxyTimeoutSeconds == seconds,
          onSelected: _pingBusy ? null : (_) => _setProxyTimeout(seconds),
        ),
      ]),
    ]);
  }

  Future<void> _setProxyTimeout(int seconds) async {
    setState(() => _proxyTimeoutSeconds = seconds);
    try {
      await _settingsStorage.write(key: _proxyTimeoutKey, value: '$seconds');
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось сохранить тайм-аут пинга.');
    }
  }

  Future<void> _savePerAppSettings() => _perform(() async {
    if (_perAppMode == 'only' && _perAppPackages.isEmpty) {
      throw const FormatException('Выберите хотя бы одно приложение для VPN.');
    }
    await _vpn.setPerAppSettings(_perAppMode, _perAppPackages);
    if (_status.state == VpnState.connected) {
      await _vpn.stop();
      await _waitForDisconnect();
      await _startSelected();
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('Настройки приложений сохранены',
            'App settings saved'))));
  });

  Widget _perAppView() {
    if (!Platform.isAndroid) return Center(child: Text(_t(
      'Выбор приложений доступен в версии для Android.',
      'Per-app proxy is available on Android.')));
    final descriptions = {
      'off': _t('Весь трафик приложений идёт через VPN.',
          'All app traffic goes through VPN.'),
      'only': _t('Только выбранные приложения идут через VPN; остальные напрямую.',
          'Selected apps use VPN; all others connect directly.'),
      'bypass': _t('Выбранные приложения работают напрямую; остальные через VPN.',
          'Selected apps connect directly; all others use VPN.'),
    };
    final query = _appSearch.text.trim().toLowerCase();
    final shown = _installedApps.where((app) =>
      (_showSystemApps || app['system'] != true) &&
      (query.isEmpty || app['label'].toString().toLowerCase().contains(query) ||
        app['packageName'].toString().toLowerCase().contains(query))).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t('Прокси для выбранных приложений', 'Per-app proxy'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      for (final mode in ['off', 'only', 'bypass']) Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => setState(() => _perAppMode = mode),
          child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            Icon(mode == 'off' ? Icons.public_rounded :
                mode == 'only' ? Icons.filter_alt_rounded : Icons.route_rounded,
              color: _perAppMode == mode ? Theme.of(context).colorScheme.primary : null),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (mode) {
                  'only' => _t('Вкл', 'On'),
                  'bypass' => _t('Обход', 'Bypass'),
                  _ => _t('Выкл', 'Off'),
                }, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(descriptions[mode]!, style: const TextStyle(fontSize: 12)),
              ])),
            if (_perAppMode == mode) Icon(Icons.circle,
                size: 12, color: Theme.of(context).colorScheme.primary),
          ])),
        )),
      ),
      const SizedBox(height: 8),
      SwitchListTile(title: Text(_t('Показать системные приложения',
          'Show system apps')),
        value: _showSystemApps, onChanged: (value) async {
          setState(() => _showSystemApps = value);
          await _settingsStorage.write(key: _showSystemAppsKey, value: '$value');
        }),
      TextField(controller: _appSearch, onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: _t('Найти приложение', 'Search apps'),
          prefixIcon: const Icon(Icons.search_rounded))),
      Padding(padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('${_t('Выбрано', 'Selected')}: ${_perAppPackages.length}')),
      if (_installedApps.isEmpty) Text(_t('Список приложений недоступен.',
          'App list is unavailable.')),
      for (final app in shown) CheckboxListTile(
        dense: true,
        title: Text(app['label']?.toString() ?? ''),
        subtitle: Text(app['packageName']?.toString() ?? ''),
        value: _perAppPackages.contains(app['packageName']),
        onChanged: (value) => setState(() {
          final id = app['packageName']?.toString() ?? '';
          if (value == true) _perAppPackages.add(id);
          else _perAppPackages.remove(id);
        }),
      ),
      const SizedBox(height: 12),
      FilledButton(onPressed: _busy ? null : _savePerAppSettings,
        child: Text(_t('Сохранить и применить', 'Save and apply'))),
    ]);
  }

  Widget _languageView() => ListView(padding: const EdgeInsets.all(16), children: [
    Text(_t('Язык приложения', 'App language'),
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
    const SizedBox(height: 12),
    for (final entry in const [
      ('auto', 'Автоматически', 'System language'),
      ('ru', 'Русский', 'Russian'),
      ('en', 'English', 'English'),
    ]) Padding(padding: const EdgeInsets.only(bottom: 8),
      child: Card(child: ListTile(
        title: Text(_t(entry.$2, entry.$3)),
        subtitle: entry.$1 == 'auto' ? Text(_t(
          'Использовать язык устройства', 'Follow device language')) : null,
        trailing: appearance.language == entry.$1
          ? Icon(Icons.circle, size: 12, color: Theme.of(context).colorScheme.primary)
          : null,
        onTap: () async {
          await appearance.setLanguage(entry.$1);
          if (mounted) setState(() {});
        },
      ))),
  ]);

  Widget _themesView() {
    final names = [...builtInThemes.keys, ...appearance.customThemes.keys];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(_t('Темы оформления', 'Themes'),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      for (final name in names) Padding(padding: const EdgeInsets.only(bottom: 8),
        child: Card(child: ListTile(
          leading: CircleAvatar(backgroundColor: AppearanceSettings.decodeColor(
            ((appearance.customThemes[name] ?? builtInThemes[name])!
                ['backgroundColors'] as List).first.toString())),
          title: Text(switch (name) {
            'dark' => _t('Тёмная', 'Dark'),
            'light' => _t('Светлая', 'Light'),
            _ => name,
          }),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (appearance.themeId == name)
              Icon(Icons.circle, size: 12,
                color: Theme.of(context).colorScheme.primary),
            if (appearance.customThemes.containsKey(name)) IconButton(
              tooltip: _t('Удалить тему', 'Delete theme'),
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                await appearance.deleteCustom(name);
                if (mounted) setState(() {});
              }),
          ]),
          onTap: () async {
            await appearance.setTheme(name);
            if (mounted) setState(() {});
          },
        ))),
      const SizedBox(height: 20),
      Text(_t('Редактор собственной темы', 'Custom theme editor'),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(_t('Вставьте JSON с цветами в формате #RRGGBBAA. '
        'Можно использовать конфигурацию темы Happ.',
        'Paste theme JSON with #RRGGBBAA colors. Happ theme JSON is supported.')),
      const SizedBox(height: 12),
      TextField(controller: _themeName, maxLength: 40,
        decoration: InputDecoration(labelText: _t('Название темы', 'Theme name'),
          border: const OutlineInputBorder())),
      TextField(controller: _themeJson, minLines: 5, maxLines: 12,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(labelText: _t('JSON темы', 'Theme JSON'),
          border: const OutlineInputBorder())),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.content_copy_rounded),
        label: Text(_t('Загрузить текущую тему в редактор',
          'Load current theme into editor')),
        onPressed: () => setState(() => _themeJson.text =
          const JsonEncoder.withIndent('  ').convert(appearance.palette))),
      const SizedBox(height: 8),
      FilledButton.icon(icon: const Icon(Icons.save_rounded),
        label: Text(_t('Сохранить и применить', 'Save and apply')),
        onPressed: () => _perform(() async {
          await appearance.saveCustom(_themeName.text, _themeJson.text);
          if (mounted) setState(() {});
        })),
    ]);
  }

  Widget _informationView() => FutureBuilder<String>(
    future: _coreVersion,
    builder: (context, snapshot) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_t('Информация', 'Information'), style: const TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        FutureBuilder<String>(future: _appVersion,
          builder: (context, app) => _infoTile(_t('Приложение', 'Application'),
              app.data ?? (app.hasError ? 'Недоступно' : 'Загрузка…'))),
        _infoTile('Xray', Platform.isAndroid ? '26.9.9' : 'Недоступен на iOS'),
        _infoTile('sing-box', snapshot.hasError ? 'Недоступно' :
            snapshot.data ?? 'Загрузка…'),
        _infoTile(_t('Платформа', 'Platform'), Platform.operatingSystem),
        _infoTile(_t('Система', 'System'), Platform.operatingSystemVersion),
        _infoTile(_t('Среда Dart', 'Dart runtime'), Platform.version),
      ],
    ),
  );

  Widget _infoTile(String title, String value) => Card(
    child: Padding(padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Color(0xFF9DAEC7))),
        const SizedBox(height: 4),
        SelectableText(value),
      ])),
  );

  Widget _logsView() => FutureBuilder<String>(
    future: _logs,
    builder: (context, snapshot) {
      final logs = _safeLogs(snapshot.data ?? '');
      return Padding(padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Expanded(child: Text(_t('Журнал подключения', 'Connection log'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            IconButton(tooltip: _t('Обновить', 'Refresh'), onPressed: () =>
              setState(() => _logs = _vpn.readLogs()),
              icon: const Icon(Icons.refresh_rounded)),
            IconButton(tooltip: _t('Копировать', 'Copy'), onPressed: logs.isEmpty ? null :
              () => Clipboard.setData(ClipboardData(text: logs)),
              icon: const Icon(Icons.copy_rounded)),
          ]),
          const SizedBox(height: 12),
          Expanded(child: Card(child: Padding(
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(child: SelectableText(
              snapshot.hasError ? _t('Не удалось прочитать журнал.',
                  'Unable to read log.') :
              snapshot.connectionState != ConnectionState.done ?
                  _t('Загрузка…', 'Loading…') :
              logs.isEmpty ? _t('Журнал пуст. Попробуйте подключиться и открыть сайт.',
                  'The log is empty. Connect and try opening a website.') : logs,
            )),
          ))),
        ]),
      );
    },
  );

  Widget _subscriptionCard(Subscription item, bool canChange) {
    final expanded = _expandedSubscriptionIds.contains(item.id);
    final host = item.isRemote ? Uri.tryParse(item.url)?.host : null;
    final description = item.notice ??
        (host != null && host.isNotEmpty ? host : _t('Локальный профиль', 'Local profile'));
    final index = _subscriptions.indexOf(item);
    final lastUpdated = item.lastUpdatedAt == null ?
        _t('Не обновлялась', 'Never updated') :
        _formatSubscriptionDate(item.lastUpdatedAt!);
    final updateText = item.updateHours == null ?
        _t('Автообновление выкл.', 'Auto-update off') :
        _t('Автообновление — ${item.updateHours} ч.',
           'Auto-update — ${item.updateHours} h');
    return Card(color: appearance.color('subsHeaderColor'),
      child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(8, 8, 2, 4),
        child: Row(children: [
          IconButton(tooltip: expanded ? _t('Свернуть', 'Collapse') :
              _t('Развернуть', 'Expand'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              if (expanded) {
                _expandedSubscriptionIds.remove(item.id);
              } else {
                _expandedSubscriptionIds.add(item.id);
              }
            }),
            icon: Icon(expanded ? Icons.keyboard_arrow_down_rounded :
                Icons.keyboard_arrow_right_rounded)),
          Expanded(child: InkWell(onTap: () => setState(() {
            if (expanded) {
              _expandedSubscriptionIds.remove(item.id);
            } else {
              _expandedSubscriptionIds.add(item.id);
            }
          }), child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, maxLines: 1, softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(lastUpdated, maxLines: 1,
                softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9DAEC7))),
              Text(updateText, maxLines: 1,
                softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9DAEC7))),
            ]))),
          IconButton(tooltip: item.pinned ? _t('Открепить', 'Unpin') :
              _t('Закрепить', 'Pin'),
            onPressed: _busy || _autoRefreshing ? null : () => _toggleSubscriptionPin(item),
            icon: Icon(item.pinned ? Icons.push_pin_rounded :
                Icons.push_pin_outlined, size: 19)),
          PopupMenuButton<String>(tooltip: _t('Действия с подпиской',
              'Subscription actions'),
            onSelected: (action) {
              switch (action) {
                case 'up': _moveSubscription(item, -1); break;
                case 'down': _moveSubscription(item, 1); break;
                case 'json': _showSubscriptionJson(item); break;
                case 'remove': _remove(item); break;
              }
            }, itemBuilder: (_) => [
              PopupMenuItem(value: 'json',
                child: Text(_t('Ответ подписки', 'Subscription response'))),
              PopupMenuItem(value: 'up', enabled: !_busy && !_autoRefreshing && index > 0 &&
                  _subscriptions[index - 1].pinned == item.pinned,
                child: Text(_t('Переместить вверх', 'Move up'))),
              PopupMenuItem(value: 'down', enabled: !_busy && !_autoRefreshing &&
                  index < _subscriptions.length - 1 &&
                  _subscriptions[index + 1].pinned == item.pinned,
                child: Text(_t('Переместить вниз', 'Move down'))),
              PopupMenuItem(value: 'remove', enabled: canChange && !_status.state.isActive,
                child: Text(_t('Удалить', 'Remove'))),
            ]),
        ])),
      if (expanded) ...[
        if (item.announcement != null)
          Padding(padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Align(alignment: Alignment.centerLeft,
              child: SelectableText(item.announcement!,
                style: const TextStyle(fontSize: 13)))),
        if (item.traffic != null)
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(alignment: Alignment.centerLeft,
              child: Text('${_t('Израсходовано', 'Used')}: ${_formatTraffic(item.traffic!.used)} / '
                  '${item.traffic!.unlimited ? '∞' : _formatTraffic(item.traffic!.total)}',
                style: const TextStyle(fontSize: 12,
                  color: Color(0xFF9DAEC7))))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(children: [
            Expanded(child: Text(description, maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9DAEC7)))),
            IconButton(tooltip: _t('Проверить все серверы', 'Ping all servers'),
              onPressed: _pingBusy || _busy || _autoRefreshing || item.nodes.isEmpty ? null :
                () => _ping(item, List.generate(item.nodes.length, (i) => i)),
              icon: const Icon(Icons.speed_rounded, size: 20)),
            IconButton(tooltip: _t('Обновить подписку', 'Refresh subscription'),
              onPressed: !_busy && !_autoRefreshing &&
                  (_pingBusy || !_status.state.isActive) && item.isRemote
                  ? () => _refresh(item) : null,
              icon: const Icon(Icons.refresh_rounded, size: 20)),
            Text('${item.nodes.length}', style: const TextStyle(
              color: Color(0xFF9DAEC7))),
          ])),
        for (var i = 0; i < item.nodes.length; i++) Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: _nodeCard(item, i, canChange),
        ),
      ],
    ]));
  }

  String _formatSubscriptionDate(DateTime date) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatTraffic(int? bytes) {
    if (bytes == null) return '—';
    final labels = appearance.isEnglish ?
        ['B', 'KB', 'MB', 'GB', 'TB'] : ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < labels.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${unit == 0 ? bytes : size.toStringAsFixed(2)} ${labels[unit]}';
  }

  Widget _nodeCard(Subscription item, int index, bool canChange) {
    final selected = _selected?.id == item.id && _nodeIndex == index;
    final node = item.nodes[index];
    final unsupported = node['_unsupported_reason']?.toString();
    final key = _delayKey(item, index);
    final measured = _latencies.containsKey(key);
    final delay = _latencies[key];
    return Card(
      color: selected ? appearance.color('selectedServerRowColor') :
          appearance.color('serverRowBackgroundColor'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: selected ? BorderSide(
            color: appearance.color('settingsControlsTintColor'), width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canChange && unsupported == null
            ? () => _selectServer(item, index) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(node['tag']?.toString() ?? _t('Сервер ${index + 1}',
                  'Server ${index + 1}'),
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w600,
                  color: appearance.color('serverRowTitleTextColor'))),
              Text(nodeLabel(node), maxLines: 1, softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11,
                    color: appearance.color('serverRowSubTitleTextColor'))),
              if (unsupported != null) Text(unsupported,
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
              if (node['_template_warning'] != null) Text(
                node['_template_warning'].toString(), maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFFC58F))),
              if (_pingErrors[key] != null) Text(_pingErrors[key]!,
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
            ])),
            const SizedBox(width: 6),
            if (measured) Text(delay == null ? '—' : _t('$delay мс', '$delay ms'),
              maxLines: 1, softWrap: false,
              style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                fontSize: 12, fontWeight: FontWeight.w600)),
            IconButton(
              tooltip: _t('Просмотреть конфигурацию', 'View config'),
              onPressed: () => _showNodeJson(item, index),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.article_outlined, size: 19),
            ),
            IconButton(
              tooltip: _t('Проверить сервер', 'Ping server'),
              onPressed: _pingBusy ? null : () => _ping(item, [index]),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.speed_outlined, size: 19),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(appearance.text('Сканировать QR', 'Scan QR'))),
    body: Stack(children: [
      MobileScanner(controller: _controller, onDetect: (capture) {
        if (_handled) return;
        for (final code in capture.barcodes) {
          final value = code.rawValue?.trim();
          if (value != null && value.isNotEmpty) {
            _handled = true;
            Navigator.pop(context, value);
            return;
          }
        }
      }),
      Align(alignment: Alignment.bottomCenter,
        child: SafeArea(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(appearance.text('Наведите камеру на QR-код подписки или сервера.',
              'Point the camera at a subscription or server QR code.'),
            textAlign: TextAlign.center),
        ))),
    ]),
  );
}
