import 'package:bmray/subscription_identity.dart';
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
    expect(SubscriptionIdentity.validUserAgent('BMray\r\nExtra: bad'), false);
  });

  test('default user agents include platform and installed version', () {
    expect(SubscriptionIdentity.defaultUserAgentFor('android', '0.2.4'),
        'BMray/android/0.2.4');
    expect(SubscriptionIdentity.defaultUserAgentFor('ios', '0.2.4'),
        'BMray/ios/0.2.4');
  });
}
