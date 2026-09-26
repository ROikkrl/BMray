import 'dart:convert';

class SubscriptionTraffic {
  const SubscriptionTraffic({this.upload, this.download, this.total, this.expire});

  final int? upload;
  final int? download;
  final int? total;
  final int? expire;

  int? get used => upload == null && download == null
      ? null : (upload ?? 0) + (download ?? 0);

  static SubscriptionTraffic? fromHeader(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final values = <String, int>{};
    for (final part in header.split(';')) {
      final match = RegExp(r'^\s*(upload|download|total|expire)\s*=\s*(\d+)\s*$',
          caseSensitive: false).firstMatch(part);
      if (match == null) continue;
      final parsed = int.tryParse(match.group(2)!);
      if (parsed != null) values[match.group(1)!.toLowerCase()] = parsed;
    }
    if (values.isEmpty) return null;
    return SubscriptionTraffic(upload: values['upload'],
        download: values['download'], total: values['total'], expire: values['expire']);
  }

  factory SubscriptionTraffic.fromJson(Map<String, dynamic> json) =>
      SubscriptionTraffic(upload: json['upload'] as int?,
          download: json['download'] as int?, total: json['total'] as int?,
          expire: json['expire'] as int?);

  Map<String, dynamic> toJson() => {
    'upload': upload, 'download': download, 'total': total, 'expire': expire,
  };
}

String? subscriptionAnnouncement(String? header) {
  if (header == null || header.trim().isEmpty) return null;
  var value = header.trim();
  final encoded = value.startsWith('base64:');
  if (encoded) {
    try {
      value = utf8.decode(base64.decode(base64.normalize(value.substring(7))));
    } on FormatException {
      return null;
    }
  }
  value = value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), ' ').trim();
  if (value.isEmpty) return null;
  return String.fromCharCodes(value.runes.take(1000));
}

int? subscriptionUpdateHours(String? header) {
  final hours = int.tryParse(header?.trim() ?? '');
  return hours != null && hours >= 1 && hours <= 8760 ? hours : null;
}
