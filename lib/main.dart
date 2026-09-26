import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  StreamSubscription<VpnStatus>? _statusSubscription;
  List<Subscription> _subscriptions = [];
  String? _subscriptionId;
  int _nodeIndex = 0;
  VpnStatus _status = const VpnStatus.disconnected();
  bool _busy = false;
  bool _pingBusy = false;
  PingMethod _pingMethod = PingMethod.proxyGet;
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
          _status = status;
          if (status.message != null) _error = status.message;
        });
    });
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final subscriptions = await _store.load();
      final status = await _vpn.currentStatus();
      if (mounted)
        setState(() {
          _subscriptions = subscriptions;
          _status = status;
          if (subscriptions.isNotEmpty) _nodeIndex = _firstUsableIndex(subscriptions.first);
        });
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Не удалось открыть защищённое хранилище.');
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

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
    await _perform(() async {
      final item = await _store.import(newName, newUrl);
      final next = [..._subscriptions, item];
      await _store.save(next);
      setState(() {
        _subscriptions = next;
        _subscriptionId = item.id;
        _nodeIndex = _firstUsableIndex(item);
      });
    });
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
      await _perform(_vpn.stop);
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

  Future<void> _refresh() async {
    final item = _selected;
    if (item == null) return;
    await _perform(() async {
      await _store.refresh(item);
      _nodeIndex = _firstUsableIndex(item);
      _latencies.removeWhere((key, _) => key.startsWith('${item.id}:'));
      _pingErrors.removeWhere((key, _) => key.startsWith('${item.id}:'));
      await _store.save(_subscriptions);
      if (mounted) setState(() {});
    });
  }

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

  Future<void> _remove() async {
    final item = _selected;
    if (item == null) return;
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
      if (_status.state.isActive) await _vpn.stop();
      final next = _subscriptions.where((e) => e.id != item.id).toList();
      await _store.save(next);
      if (mounted)
        setState(() {
          _subscriptions = next;
          _subscriptionId = null;
          _nodeIndex = 0;
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    final isActive = _status.state == VpnState.connected;
    final isConnecting = _status.state == VpnState.connecting;
    final canChange =
        !_busy && !_status.state.isActive && !_status.state.isBusy;
    final label = switch (_status.state) {
      VpnState.connected => 'Подключено',
      VpnState.connecting => 'Подключение…',
      VpnState.disconnecting => 'Отключение…',
      VpnState.reasserting => 'Восстановление…',
      VpnState.error => 'Ошибка подключения',
      _ => 'Не подключено',
    };
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF101827),
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(7),
            child: Image.asset('assets/brand/logo.jpg', width: 34, height: 34)),
          const SizedBox(width: 10),
          const Text('BMray', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          if (_pageIndex == 0) IconButton(
            tooltip: 'Добавить подписку', onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
      body: _pageIndex == 1 ? _settingsView() : SafeArea(
        child: ListView(
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
            Row(children: [
              const Expanded(child: Text('Подписки', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
              IconButton(tooltip: 'Обновить выбранную подписку',
                onPressed: canChange && item != null && item.isRemote ? _refresh : null,
                icon: const Icon(Icons.refresh_rounded)),
              IconButton(tooltip: 'Удалить выбранную подписку',
                onPressed: canChange && item != null ? _remove : null,
                icon: const Icon(Icons.delete_outline_rounded)),
            ]),
            if (_subscriptions.isEmpty)
              Card(child: Padding(padding: const EdgeInsets.all(18), child: Text(
                'Нажмите +, чтобы добавить подписку или ссылку сервера.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))))
            else ...[
              for (final subscription in _subscriptions) Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: canChange ? () => setState(() {
                    _subscriptionId = subscription.id;
                    _nodeIndex = _firstUsableIndex(subscription);
                  }) : null,
                  child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                    Icon(subscription.id == item?.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: subscription.id == item?.id ? const Color(0xFF91A4FF) : const Color(0xFF8491AA)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(subscription.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
                    Text('${subscription.nodes.length}', style: const TextStyle(color: Color(0xFF9DAEC7))),
                  ])),
                )),
              ),
            ],
            if (item != null) ...[
              if (item.notice != null) Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Card(child: Padding(padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      const Icon(Icons.info_outline_rounded, size: 20),
                      const SizedBox(width: 10),
                      Expanded(child: Text(item.notice!, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12))),
                    ]))),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(child: Text('Серверы', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                TextButton.icon(
                  onPressed: _pingBusy || _busy || item.nodes.isEmpty ? null :
                      () => _ping(item, List.generate(item.nodes.length, (i) => i)),
                  icon: _pingBusy ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.speed_rounded),
                  label: const Text('Проверить все'),
                ),
              ]),
              const SizedBox(height: 12),
              for (var i = 0; i < item.nodes.length; i++) Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _nodeCard(item, i, canChange),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_pageIndex == 0) _connectionBar(item, label, isActive, isConnecting),
        NavigationBar(
          selectedIndex: _pageIndex,
          onDestinationSelected: (index) => setState(() {
            _pageIndex = index;
            if (index == 1) _logs = _vpn.readLogs();
          }),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Серверы'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
          ],
        ),
      ]),
    );
  }

  Widget _connectionBar(Subscription? item, String label,
      bool isActive, bool isConnecting) {
    final node = item == null || item.nodes.isEmpty ? null
        : item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)];
    final canToggle = !_busy && !_pingBusy &&
        _status.state != VpnState.disconnecting &&
        _status.state != VpnState.reasserting && !isConnecting &&
        (isActive || (node != null && node['_unsupported_reason'] == null));
    return Material(
      color: const Color(0xFF1D2538),
      child: SafeArea(top: false, bottom: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(node?['tag']?.toString() ??
                  (item?.name ?? 'Добавьте подписку, чтобы начать'),
                maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9DAEC7))),
            ],
          )),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: canToggle ? _toggle : null,
            icon: _busy || isConnecting
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.power_settings_new_rounded),
            label: Text(isActive ? 'Отключить' : 'Подключить'),
          ),
        ]),
      )),
    );
  }

  Widget _settingsView() => SafeArea(child: DefaultTabController(
    length: 3,
    child: Column(children: [
      const TabBar(tabs: [
        Tab(text: 'Пинг'), Tab(text: 'Информация'), Tab(text: 'Логи'),
      ]),
      Expanded(child: TabBarView(children: [
        _pingSettingsView(), _informationView(), _logsView(),
      ])),
    ]),
  ));

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
    ]);
  }

  Widget _informationView() => FutureBuilder<String>(
    future: _coreVersion,
    builder: (context, snapshot) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Информация', style: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _infoTile('Приложение', 'BMray 0.1.8 (сборка 9)'),
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
        onTap: canChange && unsupported == null ? () => setState(() => _nodeIndex = index) : null,
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
