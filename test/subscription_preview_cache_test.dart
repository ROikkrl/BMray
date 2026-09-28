import 'dart:io';

import 'package:bmray/subscription_preview_cache.dart';
import 'package:bmray/subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('display cache omits credentials and ignores corrupt files', () async {
    final directory = await Directory.systemTemp.createTemp('bmray-preview-test');
    try {
      final cache = SubscriptionPreviewCache(directory: () async => directory);
      final previews = subscriptionPreviews([
        Subscription(id: 'one', name: 'Estonia',
          url: 'https://provider.test/private-subscription-token',
          nodes: [{'tag': 'Server A', 'uuid': 'private-uuid',
            'server': 'secret.example', 'password': 'private-password'}],
          rawResponse: 'secret-response'),
      ]);
      await cache.save(previews);
      final contents = await File('${directory.path}/bmray/subscription-preview.json')
          .readAsString();
      expect(contents, contains('Server A'));
      for (final secret in ['private-subscription-token', 'private-uuid',
        'secret.example', 'private-password', 'secret-response']) {
        expect(contents, isNot(contains(secret)));
      }
      expect((await cache.read()).single.nodeNames, ['Server A']);
      await cache.clear();
      expect(await cache.read(), isEmpty);
      await File('${directory.path}/bmray/subscription-preview.json')
          .writeAsString('{broken');
      expect(await cache.read(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
