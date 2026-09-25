import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'subscriptions.dart';

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
  final Map<String, int?> _latencies = {};
  String? _error;

  Subscription? get _selected {
    for (final item in _subscriptions) {
      if (item.id == _subscriptionId) return item;
    }
    return _subscriptions.isEmpty ? null : _subscriptions.first;
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
                hintText: 'https://… или vless://…',
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
        _nodeIndex = 0;
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
      final config = buildSingboxConfigJson(
        node,
        options: SingboxConfigOptions(usePlatformDns: Platform.isAndroid),
      );
      final validationError = await _vpn.validateConfig(config);
      if (validationError != null) throw FormatException(validationError);
      await _vpn.start(config, name: 'BMray');
    });
  }

  Future<void> _refresh() async {
    final item = _selected;
    if (item == null) return;
    await _perform(() async {
      await _store.refresh(item);
      _nodeIndex = _nodeIndex.clamp(0, item.nodes.length - 1);
      _latencies.removeWhere((key, _) => key.startsWith('${item.id}:'));
      await _store.save(_subscriptions);
      if (mounted) setState(() {});
    });
  }

  String _delayKey(Subscription item, int index) =>
      '${item.id}:$index:${_pingMethod.name}';

  Future<int?> _probe(Map<String, dynamic> node) async {
    final host = node['server']?.toString() ?? '';
    final port = node['server_port'];
    switch (_pingMethod) {
      case PingMethod.tcp:
        if (port is! int || host.isEmpty) return null;
        return _vpn.tcpDelay(host, port);
      case PingMethod.icmp:
        if (!Platform.isAndroid ||
            !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$').hasMatch(host)) {
          return null;
        }
        try {
          final process = await Process.run('ping', [
            '-c', '1', '-W', '2', host,
          ]).timeout(const Duration(seconds: 4));
          if (process.exitCode != 0) return null;
          final match = RegExp(r'time[=<]([\d.]+)')
              .firstMatch(process.stdout.toString());
          return match == null ? null : double.parse(match.group(1)!).ceil();
        } catch (_) {
          return null;
        }
      case PingMethod.proxyGet:
        final config = buildSingboxConfig(node, options: SingboxConfigOptions(
          usePlatformDns: Platform.isAndroid,
        ));
        config['inbounds'] = <Object>[];
        try {
          return await _vpn.proxyGetDelay(jsonEncode(config));
        } catch (_) {
          return null;
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
            _latencies[_delayKey(item, batch[j])] = values[j];
          }
        });
      }
    } finally {
      if (mounted) setState(() => _pingBusy = false);
    }
  }

  Future<void> _showLogs() async {
    final logs = await _vpn.readLogs();
    if (!mounted) return;
    // Never display/copy a complete share link or a user UUID.
    final safeLogs = logs
        .replaceAll(
          RegExp(r'(?:vless|vmess|trojan|ss|hy2|hysteria2|tuic)://\S+'),
          '[ссылка скрыта]',
        )
        .replaceAll(
          RegExp(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'),
          '[UUID скрыт]',
        );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Журнал подключения'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              safeLogs.isEmpty
                  ? 'Журнал пуст. Попробуйте подключиться и открыть сайт.'
                  : safeLogs,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: safeLogs.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: safeLogs));
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

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
        title: const Text('BMray', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'Журнал', onPressed: _showLogs,
              icon: const Icon(Icons.receipt_long_outlined)),
          IconButton(tooltip: 'Добавить подписку', onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  const SizedBox(height: 8),
                  Container(
                    height: 116, width: 116,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? const Color(0xFF214E57) : const Color(0xFF273459),
                      border: Border.all(
                        color: isActive ? const Color(0xFF53E0C3) : const Color(0xFF7890FF), width: 2,
                      ),
                    ),
                    child: IconButton(
                      tooltip: isActive ? 'Отключить VPN' : 'Подключить VPN',
                      onPressed: (_busy || _pingBusy || isConnecting || _status.state == VpnState.disconnecting ||
                          _status.state == VpnState.reasserting || item == null) ? null : _toggle,
                      icon: _busy || isConnecting
                          ? const CircularProgressIndicator()
                          : Icon(Icons.power_settings_new_rounded, size: 55,
                              color: isActive ? const Color(0xFF53E0C3) : const Color(0xFF91A4FF)),
                    ),
                  ),
                  const SizedBox(height: 15),
                  Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  Text(item == null ? 'Добавьте подписку, чтобы начать' :
                      (item.nodes.isEmpty ? item.name : item.nodes[_nodeIndex.clamp(0, item.nodes.length - 1)]['tag']?.toString() ?? item.name),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF9DAEC7))),
                ]),
              ),
            ),
            if (_error != null) Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(14),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)))),
            ),
            const SizedBox(height: 22),
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
                    _subscriptionId = subscription.id; _nodeIndex = 0;
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
              const SizedBox(height: 6),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: SegmentedButton<PingMethod>(
                segments: const [
                  ButtonSegment(value: PingMethod.proxyGet, label: Text('Proxy GET')),
                  ButtonSegment(value: PingMethod.tcp, label: Text('TCP')),
                  ButtonSegment(value: PingMethod.icmp, label: Text('ICMP')),
                ],
                selected: {_pingMethod},
                onSelectionChanged: _pingBusy ? null : (values) => setState(() => _pingMethod = values.first),
              )),
              if (_pingMethod == PingMethod.icmp) const Padding(
                padding: EdgeInsets.only(top: 7, bottom: 4),
                child: Text('ICMP проверяется без VPN. Перед проверкой отключите подключение.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9DAEC7))),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < item.nodes.length; i++) Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _nodeCard(item, i, canChange),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _nodeCard(Subscription item, int index, bool canChange) {
    final selected = _selected?.id == item.id && _nodeIndex == index;
    final node = item.nodes[index];
    final key = _delayKey(item, index);
    final measured = _latencies.containsKey(key);
    final delay = _latencies[key];
    return Card(
      color: selected ? const Color(0xFF28375C) : const Color(0xFF1D2538),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canChange ? () => setState(() => _nodeIndex = index) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 7, 10),
          child: Row(children: [
            Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              color: selected ? const Color(0xFF91A4FF) : const Color(0xFF65748F)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(node['tag']?.toString() ?? 'Сервер ${index + 1}',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(node['type']?.toString().toUpperCase() ?? 'ПРОКСИ',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9DAEC7))),
            ])),
            if (measured) Text(delay == null ? '—' : '$delay мс',
              style: TextStyle(color: delay == null ? const Color(0xFFFF9C9C) : const Color(0xFF60DFC3),
                fontWeight: FontWeight.w600)),
            IconButton(
              tooltip: 'Проверить сервер',
              onPressed: _pingBusy ? null : () => _ping(item, [index]),
              icon: const Icon(Icons.speed_outlined, size: 21),
            ),
          ]),
        ),
      ),
    );
  }
}
