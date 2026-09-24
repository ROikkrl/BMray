import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

import 'subscriptions.dart';

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
        seedColor: const Color(0xFF5D6AF2),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF10121F),
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
      _nodeIndex = 0;
      await _store.save(_subscriptions);
      if (mounted) setState(() {});
    });
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
        title: const Text(
          'BMray',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Журнал подключения',
            onPressed: _showLogs,
            icon: const Icon(Icons.article_outlined),
          ),
          IconButton(
            tooltip: 'Добавить подключение',
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add_link_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 30),
            Center(
              child: SizedBox(
                width: 176,
                height: 176,
                child: FilledButton(
                  onPressed:
                      (_busy ||
                          isConnecting ||
                          _status.state == VpnState.disconnecting ||
                          _status.state == VpnState.reasserting ||
                          item == null)
                      ? null
                      : _toggle,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: isActive
                        ? const Color(0xFF2DAE91)
                        : const Color(0xFF5D6AF2),
                  ),
                  child: _busy || isConnecting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Icon(
                          isActive
                              ? Icons.power_settings_new
                              : Icons.power_settings_new,
                          size: 68,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                item == null
                    ? 'Добавьте подписку или ссылку сервера, чтобы начать'
                    : 'Выберите сервер и нажмите кнопку подключения',
                textAlign: TextAlign.center,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 40),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Подключения',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: canChange && item != null && item.isRemote
                      ? _refresh
                      : null,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Удалить',
                  onPressed: canChange && item != null ? _remove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (_subscriptions.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'Нажмите + и вставьте HTTPS-подписку или ссылку сервера VLESS, VMess, Trojan, Shadowsocks, Hysteria2 или TUIC.',
                  ),
                ),
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey(_subscriptionId),
                initialValue: item?.id,
                items: _subscriptions
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.id,
                        child: Text(
                          '${e.name} · ${e.nodes.length} серверов',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: canChange
                    ? (id) => setState(() {
                        _subscriptionId = id;
                        _nodeIndex = 0;
                      })
                    : null,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            const SizedBox(height: 22),
            const Text(
              'Сервер',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (item != null && item.nodes.isNotEmpty)
              DropdownButtonFormField<int>(
                key: ValueKey('${item.id}:$_nodeIndex'),
                initialValue: _nodeIndex.clamp(0, item.nodes.length - 1),
                isExpanded: true,
                items: [
                  for (var i = 0; i < item.nodes.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        item.nodes[i]['tag']?.toString() ?? 'Сервер ${i + 1}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: canChange
                    ? (index) => setState(() => _nodeIndex = index ?? 0)
                    : null,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            const SizedBox(height: 20),
            const Text(
              'Поддерживаются sing-box JSON, V2Ray/base64 и распространённые серверы Clash YAML.',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
