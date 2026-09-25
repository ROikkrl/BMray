import 'package:flutter_test/flutter_test.dart';
import '../lib/subscription_title.dart';

void main() {
  test('HTTP profile-title takes precedence over body', () {
    expect(subscriptionTitle('Название VPN', '#profile-title: Другое\nvless://x'), 'Название VPN');
  });
  test('body profile-title and UTF-8 Base64 decode', () {
    expect(subscriptionTitle(null, '#profile-title: 0KLQtdGB0YI=\nvless://x'), 'Тест');
  });
  test('missing and invalid titles never become blank or contain control characters', () {
    expect(subscriptionTitle(null, 'vless://x'), isNull);
    expect(subscriptionTitle('\n', 'vless://x'), isNull);
    expect(subscriptionTitle('Hi\r\nBad', ''), 'Hi  Bad');
  });
}
