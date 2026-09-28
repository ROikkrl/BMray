import 'dart:convert';
import 'dart:io';

import 'package:bmray/subscription_request_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostic summary identifies Base64 without exposing share links', () {
    const link = 'vless://00000000-0000-4000-8000-000000000001@'
        '127.0.0.1:237?security=tls#Auto';
    final summary = subscriptionBodySummary(base64Encode(utf8.encode('$link\n'
        'hysteria2://password@vpn.example.com:443#Test')));
    expect(summary['format'], 'base64-links');
    expect(summary['linkSchemes'], {'vless': 1, 'hysteria2': 1});
    expect(summary['loopbackLinks'], 1);
    expect(jsonEncode(summary), isNot(contains('password')));
    expect(jsonEncode(summary), isNot(contains('00000000')));
    final target = subscriptionRequestTarget(
        Uri.parse('https://example.com/private-token?key=secret'));
    expect(target['host'], 'example.com');
    expect(jsonEncode(target), isNot(contains('private-token')));
    expect(jsonEncode(target), isNot(contains('secret')));
  });

  test('JSON diagnostic summary recognizes generated Xray balancer', () {
    final summary = subscriptionBodySummary(jsonEncode({
      'remarks': 'Auto', 'outbounds': [
        {'tag': 'WIFI_', 'protocol': 'vless'},
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {'balancers': [{'tag': 'auto_wifi'}]},
    }));
    expect(summary['format'], 'json');
    expect(summary['outboundCount'], 2);
    expect(summary['balancerCount'], 1);
  });

  test('HTML subscription response is classified without copying page content', () {
    const html = '<!doctype html><html><head><title>private-token</title>'
        '</head><body>Checking your browser cf-chl-private-token</body></html>';
    final summary = subscriptionBodySummary(html);
    expect(summary, {'format': 'html', 'pageKind': 'challenge'});
    expect(jsonEncode(summary), isNot(contains('private-token')));
    expect(looksLikeHtmlSubscriptionResponse(' <HTML><body></body></HTML>'), true);
    expect(looksLikeHtmlSubscriptionResponse('{"html":"<html>"}'), false);
    expect(subscriptionBodySummary('<html><form><input type="password"></form></html>')
        ['pageKind'], 'login');
  });

  test('request journal stays within configured cache limit', () async {
    final dir = await Directory.systemTemp.createTemp('bmray-cache-test');
    try {
      final cache = SubscriptionRequestCache(directory: () async => dir);
      await cache.setLimitMb(5);
      // Keep each line below read()'s 256 KB window and reduce fsync calls
      // while still crossing the 5 MB limit.
      for (var i = 0; i < 21; i++) {
        await cache.append({'event': 'synthetic', 'index': i,
          'data': 'a' * 250000});
      }
      expect(await cache.sizeBytes(), lessThanOrEqualTo(5 * 1024 * 1024));
      expect(await cache.read(), contains('"index":20'));
      await cache.clear();
      expect(await cache.sizeBytes(), 0);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
