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
  // Some subscription servers encode profile-title as UTF-8 Base64.
  if (RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(title) && title.length % 4 == 0) {
    try {
      final decoded = utf8.decode(base64.decode(title));
      if (!decoded.contains(RegExp(r'[\x00-\x1f]'))) title = decoded;
    } on FormatException {
      // The original title is valid plain text.
    }
  }
  title = title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (title.isEmpty) return null;
  final characters = title.runes.toList();
  return String.fromCharCodes(characters.take(60));
}
