import 'dart:convert';
import 'dart:io';

import '../packages/vpn_plugin/lib/src/share_link_parser.dart';
import '../packages/vpn_plugin/lib/src/singbox_config.dart';
import '../test/fixtures.dart';

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
}
