/// Connection lifecycle, mirrored from the native NEVPNStatus / VpnService state.
enum VpnState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  reasserting,
  error;

  static VpnState parse(String? raw) {
    switch (raw) {
      case 'connecting':
        return VpnState.connecting;
      case 'connected':
        return VpnState.connected;
      case 'disconnecting':
        return VpnState.disconnecting;
      case 'reasserting':
        return VpnState.reasserting;
      case 'error':
        return VpnState.error;
      case 'disconnected':
      case 'invalid':
      default:
        return VpnState.disconnected;
    }
  }

  bool get isActive =>
      this == VpnState.connected ||
      this == VpnState.connecting ||
      this == VpnState.reasserting;

  bool get isBusy =>
      this == VpnState.connecting || this == VpnState.disconnecting;
}

/// A snapshot of connection status + optional error, delivered over the
/// event channel as a map: { "state": "...", "message": "..." }.
class VpnStatus {
  final VpnState state;
  final String? message;
  final DateTime? connectedAt;

  const VpnStatus(this.state, {this.message, this.connectedAt});

  const VpnStatus.disconnected()
    : state = VpnState.disconnected,
      message = null,
      connectedAt = null;

  factory VpnStatus.fromMap(Map<dynamic, dynamic> map) => VpnStatus(
    VpnState.parse(map['state'] as String?),
    message: map['message'] as String?,
    connectedAt: map['connectedAtMillis'] is int
        ? DateTime.fromMillisecondsSinceEpoch(map['connectedAtMillis'] as int)
        : null,
  );
}
