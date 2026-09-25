import 'dart:async';

import 'package:flutter/services.dart';

import 'singbox_config.dart';
import 'vpn_status.dart';

/// Controls the sing-box VPN tunnel running in the platform's native VPN engine
/// (iOS NetworkExtension / Android VpnService).
class SingboxVpn {
  SingboxVpn();

  static const MethodChannel _methods = MethodChannel(
    'flutter_singbox_vpn/methods',
  );
  static const EventChannel _events = EventChannel(
    'flutter_singbox_vpn/events',
  );

  /// Live tunnel status pushed from native. A native-side stream error is
  /// surfaced as a [VpnState.error] status rather than being swallowed.
  Stream<VpnStatus> statusStream() => _events
      .receiveBroadcastStream()
      .map((e) => VpnStatus.fromMap(e as Map))
      .transform(
        StreamTransformer<VpnStatus, VpnStatus>.fromHandlers(
          handleError: (error, stack, sink) =>
              sink.add(VpnStatus(VpnState.error, message: '$error')),
        ),
      );

  /// Start the tunnel with a complete sing-box configuration (JSON string).
  /// On Android the user is prompted to grant VPN permission the first time.
  Future<void> start(String configJson, {String name = 'sing-box'}) => _methods
      .invokeMethod<void>('start', {'config': configJson, 'name': name});

  /// Convenience: build a config from a single proxy outbound (e.g. the result
  /// of [parseShareLink]) and start the tunnel.
  Future<void> startOutbound(
    Map<String, dynamic> outbound, {
    SingboxConfigOptions options = const SingboxConfigOptions(),
    String name = 'sing-box',
  }) => start(buildSingboxConfigJson(outbound, options: options), name: name);

  /// Stop the tunnel.
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// One-shot current status.
  Future<VpnStatus> currentStatus() async {
    final res = await _methods.invokeMethod<dynamic>('status');
    return res is Map ? VpnStatus.fromMap(res) : const VpnStatus.disconnected();
  }

  /// Validate a config via the embedded core. Returns an error string, or null.
  Future<String?> validateConfig(String configJson) async {
    try {
      final err = await _methods.invokeMethod<String?>('validateConfig', {
        'config': configJson,
      });
      return (err == null || err.isEmpty) ? null : err;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return null;
    }
  }

  /// Embedded sing-box version string.
  Future<String> coreVersion() async {
    try {
      return await _methods.invokeMethod<String>('coreVersion') ?? '-';
    } on MissingPluginException {
      return '-';
    }
  }

  /// Recent core logs (best effort).
  Future<String> readLogs() async {
    try {
      return await _methods.invokeMethod<String>('readLogs') ?? '';
    } on MissingPluginException {
      return '';
    }
  }

  Future<void> clearLogs() async {
    try {
      await _methods.invokeMethod<void>('clearLogs');
    } on MissingPluginException {
      // no-op
    }
  }

  /// Real HTTP GET through the selected sing-box outbound; null on timeout/error.
  Future<int?> proxyGetDelay(String configJson) => _methods.invokeMethod<int>(
    'probeProxyGet', {'config': configJson},
  );

  /// Direct TCP connect on the underlying Android network; null on error.
  Future<int?> tcpDelay(String host, int port) => _methods.invokeMethod<int>(
    'probeTcp', {'host': host, 'port': port},
  );
}
