import 'dart:convert';
import 'dart:io';

import '../packages/vpn_plugin/lib/src/share_link_parser.dart';
import 'package:vpn_plugin/src/singbox_config.dart';
import '../test/fixtures.dart';
import '../lib/xray_subscription.dart';
import '../lib/xray_bridge.dart';

void main() {
  Directory('build/config-check').createSync(recursive: true);
  for (final platformDns in [false, true]) {
    final config = buildSingboxConfig(
      parseShareLink(realityLink)!,
      options: SingboxConfigOptions(usePlatformDns: platformDns),
    );
    File('build/config-check/${platformDns ? 'android' : 'generic'}.json')
        .writeAsStringSync(jsonEncode(config));
  }
  final xray = parseXrayTemplate(xrayFixture)!;
  final config = buildSingboxConfig(xray.nodes.first,
      options: const SingboxConfigOptions(usePlatformDns: true));
  (config['route']['rules'] as List).addAll(xray.directRules);
  File('build/config-check/xray.json').writeAsStringSync(jsonEncode(config));
  final grpcConfig = buildSingboxConfig(xray.nodes[2],
      options: const SingboxConfigOptions(usePlatformDns: true));
  File('build/config-check/xray-grpc.json').writeAsStringSync(jsonEncode(grpcConfig));
  final bridge = buildXrayBridge(xray.nodes[1],
      options: const SingboxConfigOptions(usePlatformDns: true));
  File('build/config-check/xhttp-bridge.json').writeAsStringSync(jsonEncode(bridge.singbox));
  File('build/config-check/xhttp-xray.json').writeAsStringSync(jsonEncode(bridge.xray));
  final hysteria = parseXrayTemplate(hysteriaXrayFixture)!;
  final hysteriaBridge = buildXrayBridge(hysteria.nodes.single,
      options: const SingboxConfigOptions(usePlatformDns: true));
  File('build/config-check/hysteria-xray.json')
      .writeAsStringSync(jsonEncode(hysteriaBridge.xray));
}
