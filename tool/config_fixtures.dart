import 'dart:convert';
import 'dart:io';

import '../packages/vpn_plugin/lib/src/share_link_parser.dart';
import '../packages/vpn_plugin/lib/src/singbox_config.dart';
import '../test/fixtures.dart';
import '../lib/xray_subscription.dart';

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
}
