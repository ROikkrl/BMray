import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_plugin/vpn_plugin.dart';

void main() {
  test('VPN status includes native connection start for uptime', () {
    final status = VpnStatus.fromMap({
      'state': 'connected',
      'connectedAtMillis': 1700000000000,
    });
    expect(status.state, VpnState.connected);
    expect(status.connectedAt?.millisecondsSinceEpoch, 1700000000000);
    expect(VpnStatus.fromMap({'state': 'disconnected'}).connectedAt, isNull);
  });
}
