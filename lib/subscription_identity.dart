import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SubscriptionIdentity {
  const SubscriptionIdentity(this.hwid, this.userAgent);

  static const _storage = FlutterSecureStorage();
  static const hwidKey = 'bmray.subscriptionHwid';
  static const userAgentKey = 'bmray.subscriptionUserAgent';
  static const defaultUserAgent = 'BMray/0.2.2';
  final String hwid;
  final String userAgent;

  static bool validHwid(String value) =>
      RegExp(r'^[A-Za-z0-9=-]{10,64}$').hasMatch(value);

  static bool validUserAgent(String value) => value.length >= 3 &&
      value.length <= 128 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  static Future<SubscriptionIdentity> load() async {
    var hwid = await _storage.read(key: hwidKey);
    if (hwid == null || !validHwid(hwid)) {
      final random = Random.secure();
      hwid = base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      await _storage.write(key: hwidKey, value: hwid);
    }
    final savedAgent = await _storage.read(key: userAgentKey);
    return SubscriptionIdentity(hwid,
        savedAgent != null && validUserAgent(savedAgent)
            ? savedAgent : defaultUserAgent);
  }

  Future<void> save() async {
    if (!validHwid(hwid) || !validUserAgent(userAgent)) {
      throw const FormatException('Проверьте формат HWID и User-Agent.');
    }
    await _storage.write(key: hwidKey, value: hwid);
    await _storage.write(key: userAgentKey, value: userAgent);
  }

  Map<String, String> get requestHeaders => {
    HttpHeaders.userAgentHeader: userAgent,
    'x-hwid': hwid,
    'x-device-os': Platform.isAndroid ? 'Android' : Platform.operatingSystem,
    'x-ver-os': Platform.operatingSystemVersion,
    'x-device-model': 'BMray',
    HttpHeaders.cookieHeader: 'BMray=$hwid',
  };
}
