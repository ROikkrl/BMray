import 'dart:convert';

import 'package:bmray/subscription_identity.dart';
import 'package:bmray/subscriptions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HWID follows Remnawave header constraints', () {
    expect(SubscriptionIdentity.validHwid('BMray-0123456789'), true);
    expect(SubscriptionIdentity.validHwid('bad'), false);
    expect(SubscriptionIdentity.validHwid('newline\n0123456789'), false);
    expect(SubscriptionIdentity.validHwid('bad_0123456789'), false);
  });

  test('subscription requests identify BMray consistently', () {
    const identity = SubscriptionIdentity('BMray-0123456789', 'BMray/android/0.2.4');
    final headers = identity.requestHeaders;
    expect(headers['x-hwid'], identity.hwid);
    expect(headers['user-agent'], 'BMray/android/0.2.4');
    expect(headers['cookie'], 'BMray=BMray-0123456789');
    expect(identity.xrayJsonUserAgent, 'Happ/0.2.4 BMray/android/0.2.4');
    expect(RegExp(r'^happ', caseSensitive: false)
        .hasMatch(identity.xrayJsonUserAgent), true);
    expect(headers['user-agent'], 'BMray/android/0.2.4');
    expect(SubscriptionIdentity.validUserAgent('BMray\r\nExtra: bad'), false);
  });

  test('default user agents include platform and installed version', () {
    expect(SubscriptionIdentity.defaultUserAgentFor('android', '0.2.4'),
        'BMray/android/0.2.4');
    expect(SubscriptionIdentity.defaultUserAgentFor('ios', '0.2.4'),
        'BMray/ios/0.2.4');
  });

  test('a manually set Happ agent is kept exactly as entered', () {
    const identity = SubscriptionIdentity('BMray-0123456789', 'hApP/android/9.9');
    expect(identity.isHappUserAgent, true);
    expect(identity.requestHeaders['user-agent'], 'hApP/android/9.9');
    expect(identity.xrayJsonUserAgent, 'hApP/android/9.9');
  });

  test('HTML response retries once with the exact requested Happ agent', () {
    const identity = SubscriptionIdentity('BMray-0123456789', 'BMray/android/0.3.5');
    const custom = SubscriptionIdentity('BMray-0123456789', 'hApP/custom');
    const html = '<!doctype html><html><body>Subscription page</body></html>';
    expect(subscriptionRetryUserAgent(html, identity),
        'Happ/4.4.1/Android/17891107313301967618');
    expect(subscriptionRetryUserAgent(html, custom), happHtmlRetryUserAgent);
    expect(identity.requestHeaders['user-agent'], 'BMray/android/0.3.5');

    const loopback = 'vless://00000000-0000-4000-8000-000000000001@'
        '127.0.0.1:237#Auto';
    final encoded = base64Encode(utf8.encode(loopback));
    expect(subscriptionRetryUserAgent(encoded, identity),
        identity.xrayJsonUserAgent);
    expect(subscriptionRetryUserAgent(encoded, custom), isNull);
    expect(subscriptionRetryUserAgent('{"outbounds":[]}', identity), isNull);
  });
}
