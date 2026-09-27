import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A bounded diagnostic journal. It never stores URLs, credentials, or bodies.
class SubscriptionRequestCache {
  SubscriptionRequestCache({Future<Directory> Function()? directory})
      : _directory = directory ?? getTemporaryDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future<void>.value();
  int _limitBytes = 25 * 1024 * 1024;

  int get limitMb => _limitBytes ~/ (1024 * 1024);

  Future<File> _file() async {
    final root = Directory('${(await _directory()).path}/bmray');
    await root.create(recursive: true);
    return File('${root.path}/subscription-requests.jsonl');
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _pending = _pending.then((_) => action()).catchError((Object _) {
      // Losing diagnostics must never break a subscription request.
    });
    return _pending;
  }

  Future<void> setLimitMb(int value) {
    _limitBytes = value.clamp(5, 500).toInt() * 1024 * 1024;
    return _enqueue(_trim);
  }

  Future<void> append(Map<String, dynamic> event) => _enqueue(() async {
    final file = await _file();
    final line = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      ...event,
    });
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    await _trim();
  });

  Future<void> _trim() async {
    final file = await _file();
    if (!await file.exists()) return;
    final length = await file.length();
    if (length <= _limitBytes) return;
    final source = await file.open();
    final temporary = File('${file.path}.tmp');
    final output = await temporary.open(mode: FileMode.write);
    try {
      final start = (length - _limitBytes ~/ 2).clamp(0, length).toInt();
      await source.setPosition(start);
      if (start > 0) {
        // Start with a complete JSON line, even when the byte offset is in UTF-8.
        while (await source.position() < length && await source.readByte() != 10) {}
      }
      while (true) {
        final chunk = await source.read(64 * 1024);
        if (chunk.isEmpty) break;
        await output.writeFrom(chunk);
      }
      await output.flush();
    } finally {
      await source.close();
      await output.close();
    }
    await temporary.rename(file.path);
  }

  Future<int> sizeBytes() async {
    await _pending;
    final file = await _file();
    return await file.exists() ? await file.length() : 0;
  }

  Future<String> read() async {
    await _pending;
    final file = await _file();
    if (!await file.exists()) return '';
    final source = await file.open();
    try {
      final length = await source.length();
      final start = (length - 256 * 1024).clamp(0, length).toInt();
      await source.setPosition(start);
      if (start > 0) {
        while (await source.position() < length && await source.readByte() != 10) {}
      }
      return utf8.decode(await source.read(length - await source.position()));
    } finally {
      await source.close();
    }
  }

  Future<void> clear() => _enqueue(() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  });
}

Map<String, dynamic> subscriptionRequestTarget(Uri uri) => {
  'scheme': uri.scheme,
  'host': uri.host,
  'port': uri.hasPort ? uri.port : 443,
  'pathSegmentCount': uri.pathSegments.where((segment) => segment.isNotEmpty).length,
  'queryKeys': uri.queryParameters.keys.toList()..sort(),
};

Map<String, dynamic> subscriptionBodySummary(String body) {
  var content = body.trim();
  var encoded = false;
  if (!content.startsWith('{') && !content.startsWith('[') &&
      !content.contains('://')) {
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(content)));
      if (decoded.contains('://') || decoded.trimLeft().startsWith('{') ||
          decoded.trimLeft().startsWith('[')) {
        content = decoded.trim();
        encoded = true;
      }
    } on FormatException {
      // An unknown response is described by size and type only.
    }
  }
  if (content.startsWith('{') || content.startsWith('[')) {
    try {
      final parsed = jsonDecode(content);
      if (parsed is Map) {
        final routing = parsed['routing'];
        return {
          'format': encoded ? 'base64-json' : 'json',
          'jsonKeys': parsed.keys.map((key) => key.toString()).toList()..sort(),
          'outboundCount': parsed['outbounds'] is List
              ? (parsed['outbounds'] as List).length : 0,
          'balancerCount': routing is Map && routing['balancers'] is List
              ? (routing['balancers'] as List).length : 0,
          'hasRemnawaveDirective': parsed['remnawave'] != null,
        };
      }
      if (parsed is List) {
        return {'format': encoded ? 'base64-json-array' : 'json-array',
          'items': parsed.length};
      }
    } on FormatException {
      // The parser will report malformed JSON separately.
    }
  }
  final schemes = <String, int>{};
  var loopback = 0;
  for (final line in const LineSplitter().convert(content)) {
    if (!line.contains('://')) continue;
    final uri = Uri.tryParse(line.trim());
    if (uri == null || uri.scheme.isEmpty) continue;
    schemes[uri.scheme] = (schemes[uri.scheme] ?? 0) + 1;
    if (uri.host == '127.0.0.1' || uri.host == '::1') loopback++;
  }
  return {
    'format': encoded ? 'base64-links' : schemes.isNotEmpty ? 'links' : 'unknown',
    'linkSchemes': schemes,
    'loopbackLinks': loopback,
  };
}
