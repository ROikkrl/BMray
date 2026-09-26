import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bmray/subscription_metadata.dart';
import 'package:bmray/subscriptions.dart';

void main() {
  test('parses Remnawave traffic counters and preserves absent values', () {
    final usage = SubscriptionTraffic.fromHeader(
        'upload=1024; download=2048; total=1048576; expire=0')!;
    expect(usage.used, 3072);
    expect(usage.total, 1048576);
    expect(usage.expire, 0);
    expect(SubscriptionTraffic.fromHeader('total=0')!.used, isNull);
    expect(SubscriptionTraffic.fromHeader('invalid'), isNull);
  });

  test('decodes announcement, rejects malformed encoded data', () {
    final encoded = base64.encode(utf8.encode('Описание VPN\nВторая строка'));
    expect(subscriptionAnnouncement('base64:$encoded'), 'Описание VPN\nВторая строка');
    expect(subscriptionAnnouncement('base64:%%%'), isNull);
    expect(subscriptionAnnouncement('Обычное описание'), 'Обычное описание');
  });

  test('reads update interval in hours', () {
    expect(subscriptionUpdateHours('6'), 6);
    expect(subscriptionUpdateHours('0'), isNull);
    expect(subscriptionUpdateHours('invalid'), isNull);
  });

  test('subscription metadata survives storage round trip and older entries load', () {
    final date = DateTime.utc(2026, 9, 26, 12, 29);
    final item = Subscription(id: '1', name: 'Профиль', url: 'https://example.com/sub',
        nodes: const [], pinned: true, announcement: 'Привет',
        traffic: const SubscriptionTraffic(upload: 1, download: 2, total: 100),
        updateHours: 6, lastUpdatedAt: date);
    final restored = Subscription.fromJson(jsonDecode(jsonEncode(item.toJson())));
    expect(restored.pinned, true);
    expect(restored.announcement, 'Привет');
    expect(restored.traffic!.used, 3);
    expect(restored.updateHours, 6);
    expect(restored.lastUpdatedAt, date);
    final old = Subscription.fromJson({'id': '2', 'name': 'Старый',
        'url': 'https://example.com', 'nodes': <Object>[]});
    expect(old.pinned, false);
    expect(old.lastUpdatedAt, isNull);
  });
}
