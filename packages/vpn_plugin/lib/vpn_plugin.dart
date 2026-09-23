/// A Flutter VPN engine that embeds the sing-box core (Karing/Hiddify-style):
/// a thin Dart API over the platform's native VPN engine (iOS NetworkExtension /
/// Android VpnService), plus pure-Dart share-link parsing and sing-box config
/// generation.
///
/// NOTE: sing-box is licensed under GPL-3.0, so this package and any app using
/// it are bound by GPL-3.0 (the app's full source must be made available).
library;

export 'src/share_link_parser.dart';
export 'src/singbox_config.dart';
export 'src/singbox_vpn.dart';
export 'src/vpn_status.dart';
