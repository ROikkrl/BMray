import 'package:flutter_test/flutter_test.dart';
import '../lib/subscription_title.dart';

void main() {
  test('HTTP profile-title takes precedence over body', () {
    expect(subscriptionTitle('Название VPN', '#profile-title: Другое\nvless://x'), 'Название VPN');
  });
  test('body profile-title and UTF-8 Base64 decode', () {
    expect(subscriptionTitle(null, '#profile-title: 0KLQtdGB0YI=\nvless://x'), 'Тест');
    expect(subscriptionTitle('0KLQtdGB0YI', ''), 'Тест');
    expect(subscriptionTitle('base64:0KLQtdGB0YI', ''), 'Тест');
    expect(subscriptionTitle('=?UTF-8?B?0KLQtdGB0YI=?=', ''), 'Тест');
    expect(subscriptionTitle('U29tZS10aXRsZQ', ''), 'Some-title');
  });
  test('missing and invalid titles never become blank or contain control characters', () {
    expect(subscriptionTitle(null, 'vless://x'), isNull);
    expect(subscriptionTitle('\n', 'vless://x'), isNull);
    expect(subscriptionTitle('Hi\r\nBad', ''), 'Hi  Bad');
  });
}
