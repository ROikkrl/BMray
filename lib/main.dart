import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'subscriptions.dart';
import 'xray_bridge.dart';
import 'node_label.dart';

enum PingMethod { proxyGet, tcp, icmp }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BMrayApp());
}

class BMrayApp extends StatelessWidget {
  const BMrayApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BMray',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6179FF),
        brightness: Brightness.dark,
        surface: const Color(0xFF1D2538),
      ),
      scaffoldBackgroundColor: const Color(0xFF101827),
      cardTheme: const CardThemeData(
        color: Color(0xFF1D2538),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
      ),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _vpn = SingboxVpn();
  final _store = SubscriptionStore();
  static const _settingsStorage = FlutterSecureStorage();
  static const _proxyTimeoutKey = 'bmray.proxyTimeoutSeconds';
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
  bool _pingBusy = false;
  PingMethod _pingMethod = PingMethod.proxyGet;
  int _proxyTimeoutSeconds = 4;
  // 0: servers, 1: settings, 2: ping, 3: information, 4: logs.
  int _pageIndex = 0;
  late final Future<String> _coreVersion = _vpn.coreVersion();
  late Future<String> _logs = _vpn.readLogs();
  final Map<String, int?> _latencies = {};
  final Map<String, String> _pingErrors = {};
  String? _error;

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

  @override
  void initState() {
    super.initState();
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
      final status = await _vpn.currentStatus();
      String? storedTimeout;
      try {
        storedTimeout = await _settingsStorage.read(key: _proxyTimeoutKey);
      } catch (_) {
        // Keep the default when a preference cannot be read.
      }
      if (mounted)
        setState(() {
          _subscriptions = subscriptions;
          _expandedSubscriptionIds.addAll(subscriptions.map((item) => item.id));
          _setStatus(status);
          final timeout = int.tryParse(storedTimeout ?? '');
          if ([2, 4, 6, 10].contains(timeout)) _proxyTimeoutSeconds = timeout!;
          if (subscriptions.isNotEmpty) _nodeIndex = _firstUsableIndex(subscriptions.first);
        });
      if (mounted) unawaited(_refreshDueSubscriptions());
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Не удалось открыть защищённое хранилище.');
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _uptimeTimer?.cancel();
    _subscriptionTimer?.cancel();
    super.dispose();
  }

  Future<void> _showImportMenu() async {
    final choice = await showModalBottomSheet<String>(context: context,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(Icons.link_rounded),
            title: const Text('Добавить ссылку или JSON'),
            onTap: () => Navigator.pop(ctx, 'manual')),
          ListTile(leading: const Icon(Icons.content_paste_rounded),
            title: const Text('Импортировать из буфера обмена'),
            onTap: () => Navigator.pop(ctx, 'clipboard')),
          ListTile(leading: const Icon(Icons.qr_code_scanner_rounded),
            title: const Text('Сканировать QR'),
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
    final item = await _store.import(name, input);
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
  });

  Future<void> _add() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final shouldImport = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Добавить подключение'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Название (необязательно)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Подписка или ссылка сервера',
                hintText: 'https://…, vless://… или Xray JSON',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Импортировать'),
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
    if (item == null || item.nodes.isEmpty || _status.state.isBusy) return;
    await _perform(() async {
      final node = item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
      if (node['_unsupported_reason'] != null) {
        throw FormatException(node['_unsupported_reason'].toString());
      }
      final bridge = usesXray(node) && Platform.isAndroid
          ? buildXrayBridge(node,
              options: const SingboxConfigOptions(usePlatformDns: true))
          : null;
      if (usesXray(node) && bridge == null) {
        throw const FormatException('Этот профиль Xray доступен только на Android.');
      }
      final config = bridge?.singbox ?? buildSingboxConfig(node,
          options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
      if (item.directRules.isNotEmpty) {
        (config['route']['rules'] as List).addAll(item.directRules);
      }
      final configJson = jsonEncode(config);
      final validationError = await _vpn.validateConfig(configJson);
      if (validationError != null) throw FormatException(validationError);
      await _vpn.start(configJson, name: 'BMray',
          xrayConfig: bridge == null ? null : jsonEncode(bridge.xray));
    });
  }

  Future<void> _refresh(Subscription item) async {
    await _perform(() async {
      await _refreshSubscription(item);
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

  Future<({int? delay, String? reason})> _probe(Map<String, dynamic> node) async {
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
        if (usesXray(node) && !Platform.isAndroid) {
          return (delay: null, reason: 'Этот профиль Xray доступен только на Android');
        }
        final bridge = usesXray(node) ? buildXrayBridge(node, probe: true,
            options: const SingboxConfigOptions(usePlatformDns: true)) : null;
        final config = bridge?.singbox ?? buildSingboxConfig(node,
            options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid));
        config['inbounds'] = <Object>[];
        try {
          final result = await _vpn.proxyGetDelay(jsonEncode(config),
              timeout: Duration(seconds: _proxyTimeoutSeconds),
              xrayConfig: bridge == null ? null : jsonEncode(bridge.xray));
          return (delay: result.delay, reason: result.reason);
        } catch (_) {
          return (delay: null, reason: 'Ошибка проверки прокси');
        }
    }
  }

  Future<void> _ping(Subscription item, List<int> indices) async {
    if (_pingBusy) return;
    if (_pingMethod == PingMethod.icmp && _status.state.isActive) {
      setState(() => _error = 'Для ICMP отключите VPN: ICMP не проходит через прокси.');
      return;
    }
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
      for (var start = 0; start < indices.length; start += 3) {
        final batch = indices.skip(start).take(3).toList();
        final values = await Future.wait(batch.map((i) => _probe(item.nodes[i])));
        if (!mounted || method != _pingMethod) break;
        setState(() {
          for (var j = 0; j < batch.length; j++) {
            _latencies[_delayKey(item, batch[j])] = values[j].delay;
            if (values[j].reason != null) {
              _pingErrors[_delayKey(item, batch[j])] = values[j].reason!;
            }
          }
        });
      }
    } finally {
      if (mounted) setState(() => _pingBusy = false);
    }
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
        title: const Text('Удалить подписку?'),
        content: Text(item.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    final isActive = _status.state == VpnState.connected;
    final isConnecting = _status.state == VpnState.connecting;
    final canChange =
        !_busy && !_autoRefreshing && !_status.state.isActive && !_status.state.isBusy;
    final label = switch (_status.state) {
      VpnState.connected => 'Подключено',
      VpnState.connecting => 'Подключение…',
      VpnState.disconnecting => 'Отключение…',
      VpnState.reasserting => 'Восстановление…',
      VpnState.error => 'Ошибка подключения',
      _ => 'Не подключено',
    };
    return PopScope(
      canPop: _pageIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _pageIndex = _pageIndex == 1 ? 0 : 1);
      },
      child: Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF101827),
        leading: IconButton(
          tooltip: _pageIndex == 0 ? 'Настройки' : 'Назад',
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
          1 => 'Настройки', 2 => 'Пинг', 3 => 'Информация', _ => 'Логи',
        }),
        actions: [
          if (_pageIndex == 0) IconButton(
            tooltip: 'Добавить', onPressed: _busy || _autoRefreshing ? null : _showImportMenu,
            icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
      body: _pageIndex != 0 ? SafeArea(child: switch (_pageIndex) {
        1 => _settingsView(),
        2 => _pingSettingsView(),
        3 => _informationView(),
        _ => _logsView(),
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
                  child: Text(_error!, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)))),
            ),
            const SizedBox(height: 8),
            const Text('Подписки и серверы', style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (_subscriptions.isEmpty)
              Card(child: Padding(padding: const EdgeInsets.all(18), child: Text(
                'Нажмите +, чтобы добавить подписку или ссылку сервера.',
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
    final canToggle = !_busy && (!_pingBusy || isActive) &&
        _status.state != VpnState.disconnecting &&
        _status.state != VpnState.reasserting && !isConnecting &&
        (isActive || (node != null && node['_unsupported_reason'] == null));
    return LayoutBuilder(builder: (context, constraints) {
      final diameter = (constraints.maxHeight * 0.46).clamp(64.0, 144.0).toDouble();
      return Container(
        width: double.infinity,
        color: const Color(0xFF101827),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Semantics(
            button: true,
            label: isActive ? 'Отключить VPN' : 'Подключить VPN',
            child: Material(
              color: const Color(0xFF1D2538),
              shape: CircleBorder(side: BorderSide(
                color: isActive ? const Color(0xFF53E0C3) : const Color(0xFF7976F6),
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
                        color: isActive ? const Color(0xFF53E0C3)
                            : const Color(0xFFB6B9FF))),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (isActive && _connectedAt != null) Text(_uptimeLabel(),
            style: const TextStyle(fontSize: 13, color: Color(0xFF60DFC3))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(node?['tag']?.toString() ??
                (item?.name ?? 'Добавьте подписку, чтобы начать'),
              maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB4BDDD)))),
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
    _settingsHeading('Проверка соединения'),
    _settingsEntry('Пинг', 'Proxy GET, TCP и ICMP', Icons.speed_rounded, 2),
    _settingsHeading('Приложение'),
    _settingsEntry('Журнал подключения', 'Логи ядра и VPN',
        Icons.receipt_long_outlined, 4),
    _settingsEntry('Информация', 'Версии и сведения о системе',
        Icons.info_outline_rounded, 3),
  ]);

  Widget _settingsHeading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
    child: Text(title, style: const TextStyle(
      fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF9794FF))),
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
          if (page == 4) _logs = _vpn.readLogs();
        }),
      ),
      const Divider(height: 1),
    ]);

  Widget _pingSettingsView() {
    final description = switch (_pingMethod) {
      PingMethod.proxyGet =>
        'Proxy GET: выполняет настоящий HTTPS GET через выбранный сервер. '
        'Проверяет, что прокси подключается и передаёт данные.',
      PingMethod.tcp =>
        'TCP: измеряет время прямого соединения с адресом и портом сервера. '
        'Не проверяет авторизацию и работу прокси.',
      PingMethod.icmp =>
        'ICMP: отправляет эхо-запрос на адрес сервера без прокси. '
        'Сервер может не отвечать на ICMP, даже если подключение работает. '
        'Перед проверкой отключите VPN.',
    };
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Способ проверки', style: TextStyle(
        fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 16),
      SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: SegmentedButton<PingMethod>(
          segments: const [
            ButtonSegment(value: PingMethod.proxyGet, label: Text('Proxy GET')),
            ButtonSegment(value: PingMethod.tcp, label: Text('TCP')),
            ButtonSegment(value: PingMethod.icmp, label: Text('ICMP')),
          ],
          selected: {_pingMethod},
          onSelectionChanged: _pingBusy ? null : (values) =>
              setState(() => _pingMethod = values.first),
        ),
      ),
      const SizedBox(height: 16),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Text(description))),
      const SizedBox(height: 12),
      const Text('Выбранный способ применяется к кнопкам проверки на экране серверов.',
        style: TextStyle(color: Color(0xFF9DAEC7))),
      const SizedBox(height: 24),
      const Text('Тайм-аут Proxy GET', style: TextStyle(
        fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Время ожидания одного HTTPS-запроса. При неудаче проверка пробует следующий адрес.',
        style: TextStyle(color: Color(0xFF9DAEC7))),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        for (final seconds in [2, 4, 6, 10]) ChoiceChip(
          label: Text('$seconds с'),
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

  Widget _informationView() => FutureBuilder<String>(
    future: _coreVersion,
    builder: (context, snapshot) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Информация', style: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _infoTile('Приложение', 'BMray 0.2.0 (сборка 11)'),
        _infoTile('Xray', Platform.isAndroid ? '26.9.9' : 'Недоступен на iOS'),
        _infoTile('sing-box', snapshot.hasError ? 'Недоступно' :
            snapshot.data ?? 'Загрузка…'),
        _infoTile('Платформа', Platform.operatingSystem),
        _infoTile('Система', Platform.operatingSystemVersion),
        _infoTile('Среда Dart', Platform.version),
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
            const Expanded(child: Text('Журнал подключения',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            IconButton(tooltip: 'Обновить', onPressed: () =>
              setState(() => _logs = _vpn.readLogs()),
              icon: const Icon(Icons.refresh_rounded)),
            IconButton(tooltip: 'Копировать', onPressed: logs.isEmpty ? null :
              () => Clipboard.setData(ClipboardData(text: logs)),
              icon: const Icon(Icons.copy_rounded)),
          ]),
          const SizedBox(height: 12),
          Expanded(child: Card(child: Padding(
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(child: SelectableText(
              snapshot.hasError ? 'Не удалось прочитать журнал.' :
              snapshot.connectionState != ConnectionState.done ? 'Загрузка…' :
              logs.isEmpty ? 'Журнал пуст. Попробуйте подключиться и открыть сайт.' : logs,
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
        (host != null && host.isNotEmpty ? host : 'Локальный профиль');
    final index = _subscriptions.indexOf(item);
    final lastUpdated = item.lastUpdatedAt == null ? 'Не обновлялась' :
        _formatSubscriptionDate(item.lastUpdatedAt!);
    final updateText = item.updateHours == null ? 'Автообновление выкл.' :
        'Автообновление — ${item.updateHours} ч.';
    return Card(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(8, 8, 2, 4),
        child: Row(children: [
          IconButton(tooltip: expanded ? 'Свернуть' : 'Развернуть',
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
              Text('$lastUpdated | $updateText', maxLines: 1,
                softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9DAEC7))),
            ]))),
          IconButton(tooltip: item.pinned ? 'Открепить' : 'Закрепить',
            onPressed: _busy || _autoRefreshing ? null : () => _toggleSubscriptionPin(item),
            icon: Icon(item.pinned ? Icons.push_pin_rounded :
                Icons.push_pin_outlined, size: 19)),
          PopupMenuButton<String>(tooltip: 'Действия с подпиской',
            onSelected: (action) {
              switch (action) {
                case 'up': _moveSubscription(item, -1); break;
                case 'down': _moveSubscription(item, 1); break;
                case 'remove': _remove(item); break;
              }
            }, itemBuilder: (_) => [
              PopupMenuItem(value: 'up', enabled: !_busy && !_autoRefreshing && index > 0 &&
                  _subscriptions[index - 1].pinned == item.pinned,
                child: const Text('Переместить вверх')),
              PopupMenuItem(value: 'down', enabled: !_busy && !_autoRefreshing &&
                  index < _subscriptions.length - 1 &&
                  _subscriptions[index + 1].pinned == item.pinned,
                child: const Text('Переместить вниз')),
              PopupMenuItem(value: 'remove', enabled: canChange,
                child: const Text('Удалить')),
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
              child: Text('Израсходовано: ${_formatTraffic(item.traffic!.used)} / '
                  '${_formatTraffic(item.traffic!.total)}',
                style: const TextStyle(fontSize: 12,
                  color: Color(0xFF9DAEC7))))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(children: [
            Expanded(child: Text(description, maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9DAEC7)))),
            IconButton(tooltip: 'Проверить все серверы',
              onPressed: _pingBusy || _busy || _autoRefreshing || item.nodes.isEmpty ? null :
                () => _ping(item, List.generate(item.nodes.length, (i) => i)),
              icon: const Icon(Icons.speed_rounded, size: 20)),
            IconButton(tooltip: 'Обновить подписку',
              onPressed: canChange && item.isRemote ? () => _refresh(item) : null,
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
    const labels = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
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
      color: selected ? const Color(0xFF28375C) : const Color(0xFF1D2538),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: selected ? const BorderSide(color: Color(0xFF91A4FF), width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canChange && unsupported == null ? () => setState(() {
          _subscriptionId = item.id;
          _nodeIndex = index;
        }) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(node['tag']?.toString() ?? 'Сервер ${index + 1}',
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(nodeLabel(node), maxLines: 1, softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9DAEC7))),
              if (unsupported != null) Text(unsupported,
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
              if (_pingErrors[key] != null) Text(_pingErrors[key]!,
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFFF9C9C))),
            ])),
            const SizedBox(width: 6),
            if (measured) Text(delay == null ? '—' : '$delay мс',
              maxLines: 1, softWrap: false,
              style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                fontSize: 12, fontWeight: FontWeight.w600)),
            IconButton(
              tooltip: 'Проверить сервер',
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
    appBar: AppBar(title: const Text('Сканировать QR')),
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
      const Align(alignment: Alignment.bottomCenter,
        child: SafeArea(child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Наведите камеру на QR-код подписки или сервера.',
            textAlign: TextAlign.center),
        ))),
    ]),
  );
}
