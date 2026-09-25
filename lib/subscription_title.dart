import 'dart:convert';

/// Happ-compatible subscription title from the response header or body.
String? subscriptionTitle(String? header, String body) {
  final lines = body.split(RegExp(r'\r?\n'));
  final bodyTitle = lines.take(12).where((line) =>
      line.trimLeft().toLowerCase().startsWith('#profile-title:'));
  final candidate = header?.trim().isNotEmpty == true
      ? header!
      : bodyTitle.isEmpty
          ? null
          : bodyTitle.first.trimLeft().substring('#profile-title:'.length).trim();
  if (candidate == null || candidate.isEmpty) return null;
  var title = candidate.trim();
  // Providers may send UTF-8, unpadded Base64, Base64URL, or RFC 2047 text.
  final mime = RegExp(r'^=\?utf-8\?b\?([^?]+)\?=$', caseSensitive: false)
      .firstMatch(title);
  final encoded = mime?.group(1) ??
      title.replaceFirst(RegExp(r'^(?:base64|b64):', caseSensitive: false), '');
  final looksEncoded = mime != null || encoded != title ||
      (encoded.length >= 8 && RegExp(r'^[A-Za-z0-9_+/\-]+={0,2}$').hasMatch(encoded));
  if (looksEncoded) {
    try {
      final padded = base64.normalize(encoded.replaceAll('-', '+').replaceAll('_', '/'));
      final decoded = utf8.decode(base64.decode(padded));
      if (decoded.trim().isNotEmpty &&
          !decoded.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        title = decoded;
      }
    } on FormatException {
      // Keep a genuine plain-text name unchanged.
    }
  }
  title = title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (title.isEmpty) return null;
  final characters = title.runes.toList();
  return String.fromCharCodes(characters.take(60));
}
