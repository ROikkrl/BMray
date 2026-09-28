import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Display-only cache. Never store subscription URLs, keys, or usable nodes here.
class SubscriptionPreview {
  const SubscriptionPreview(this.id, this.name, this.nodeNames);

  final String id;
  final String name;
  final List<String> nodeNames;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'nodes': nodeNames,
  };

  static SubscriptionPreview? fromJson(Object? value) {
    if (value is! Map || value['id'] is! String ||
        value['name'] is! String || value['nodes'] is! List) return null;
    final names = (value['nodes'] as List).whereType<String>().toList();
    return SubscriptionPreview(value['id'] as String,
        value['name'] as String, names);
  }
}

class SubscriptionPreviewCache {
  SubscriptionPreviewCache({Future<Directory> Function()? directory})
      : _directory = directory ?? getTemporaryDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future<void>.value();

  Future<File> _file() async {
    final root = Directory('${(await _directory()).path}/bmray');
    await root.create(recursive: true);
    return File('${root.path}/subscription-preview.json');
  }

  Future<List<SubscriptionPreview>> read() async {
    try {
      await _pending;
      final file = await _file();
      if (!await file.exists() || await file.length() > 1024 * 1024) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1 ||
          decoded['subscriptions'] is! List) return [];
      return (decoded['subscriptions'] as List)
          .map(SubscriptionPreview.fromJson)
          .whereType<SubscriptionPreview>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<SubscriptionPreview> subscriptions) {
    _pending = _pending.catchError((Object _) {}).then((_) async {
      final file = await _file();
      final temporary = File('${file.path}.tmp');
      final data = jsonEncode({
        'version': 1,
        'subscriptions': subscriptions.map((item) => item.toJson()).toList(),
      });
      if (utf8.encode(data).length > 1024 * 1024) {
        if (await file.exists()) await file.delete();
        return;
      }
      await temporary.writeAsString(data, flush: true);
      await temporary.rename(file.path);
    });
    return _pending;
  }

  Future<void> clear() async {
    await _pending.catchError((Object _) {});
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
