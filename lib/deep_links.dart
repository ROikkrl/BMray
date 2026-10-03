import 'dart:convert';

enum BMrayLinkAction { open, close, vpnOn, vpnOff, vpnToggle,
  importBase64, importUrl, addRouting }

class BMrayLink {
  const BMrayLink(this.action, [this.value]);
  final BMrayLinkAction action;
  final String? value;

  static BMrayLink parse(String raw) {
    if (raw.length > 1024 * 1024) throw const FormatException('Ссылка слишком большая.');
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.toLowerCase() != 'bmray' ||
        uri.userInfo.isNotEmpty || uri.hasPort || uri.fragment.isNotEmpty) {
      throw const FormatException('Неверная ссылка BMray.');
    }
    final route = '${uri.host.toLowerCase()}/${uri.pathSegments.join('/').toLowerCase()}';
    final params = uri.queryParametersAll;
    String parameter(String key) {
      if (params.length != 1 || params[key]?.length != 1 ||
          params[key]!.single.isEmpty) {
        throw const FormatException('У ссылки отсутствуют данные или есть лишние параметры.');
      }
      return params[key]!.single;
    }
    if (params.isNotEmpty && !['import/base64', 'import/url', 'routing/add'].contains(route)) {
      throw const FormatException('Лишние параметры в команде BMray.');
    }
    return switch (route) {
      'app/open' => const BMrayLink(BMrayLinkAction.open),
      'app/close' => const BMrayLink(BMrayLinkAction.close),
      'vpn/on' => const BMrayLink(BMrayLinkAction.vpnOn),
      'vpn/off' => const BMrayLink(BMrayLinkAction.vpnOff),
      'vpn/toggle' => const BMrayLink(BMrayLinkAction.vpnToggle),
      'import/url' => BMrayLink(BMrayLinkAction.importUrl, parameter('url')),
      'import/base64' => BMrayLink(BMrayLinkAction.importBase64,
          _decode(parameter('data'))),
      'routing/add' => BMrayLink(BMrayLinkAction.addRouting,
          _decode(parameter('data'))),
      _ => throw const FormatException('Неизвестная команда BMray.'),
    };
  }

  static String _decode(String data) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(data)));
    } catch (_) {
      throw const FormatException('Неверные данные Base64.');
    }
  }
}
