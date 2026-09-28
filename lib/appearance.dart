import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const builtInThemes = <String, Map<String, dynamic>>{
  'dark': {
    'backgroundColors': ['#101827FF', '#101827FF', '#101827FF'],
    'serverRowBackgroundColor': '#1D2538FF',
    'selectedServerRowColor': '#28375CFF',
    'subsHeaderColor': '#1D2538FF',
    'buttonColor': '#1D2538FF',
    'buttonTextColor': '#FFFFFFFF',
    'powerIconColor': '#B6B9FFFF',
    'serverRowTitleTextColor': '#FFFFFFFF',
    'serverRowSubTitleTextColor': '#9DAEC7FF',
    'topBarButtonsColor': '#FFFFFFFF',
    'settingsControlsTintColor': '#7976F6FF',
    'buttonTimerColor': '#60DFC3FF',
  },
  'light': {
    'backgroundColors': ['#F3F6FFFF', '#F3F6FFFF', '#E5ECFFFF'],
    'serverRowBackgroundColor': '#FFFFFFFF',
    'selectedServerRowColor': '#DCE8FFFF',
    'subsHeaderColor': '#FFFFFFFF',
    'buttonColor': '#E4EAFFFF',
    'buttonTextColor': '#162140FF',
    'powerIconColor': '#3F57B8FF',
    'serverRowTitleTextColor': '#101827FF',
    'serverRowSubTitleTextColor': '#58667EFF',
    'topBarButtonsColor': '#263554FF',
    'settingsControlsTintColor': '#375FD5FF',
    'buttonTimerColor': '#176B60FF',
  },
  'OLEDBlack': {
    'backgroundColors': ['#000000FF', '#000000FF', '#000000FF'],
    'serverRowBackgroundColor': '#050505FF',
    'selectedServerRowColor': '#151515FF',
    'subsHeaderColor': '#0A0A0AFF',
    'buttonColor': '#FFFFFFFF',
    'buttonTextColor': '#000000FF',
    'powerIconColor': '#000000FF',
    'serverRowTitleTextColor': '#FFFFFFFF',
    'serverRowSubTitleTextColor': '#888888FF',
    'topBarButtonsColor': '#FFFFFFFF',
    'settingsControlsTintColor': '#FFFFFFFF',
    'buttonTimerColor': '#FFFFFFFF',
  },
  'Electric Blue': {
    'backgroundGradientRotationAngle': 55,
    'backgroundColors': ['#00101CFF', '#001D33FF', '#00345BFF'],
    'serverRowBackgroundColor': '#06253AFF',
    'selectedServerRowColor': '#064D78FF',
    'subsHeaderColor': '#063C61FF',
    'buttonColor': '#23B7FFFF',
    'buttonTextColor': '#00111DFF',
    'powerIconColor': '#00375AFF',
    'serverRowTitleTextColor': '#F0FAFFFF',
    'serverRowSubTitleTextColor': '#9AC6DFFF',
    'topBarButtonsColor': '#4CC5FFFF',
    'settingsControlsTintColor': '#23B7FFFF',
    'buttonTimerColor': '#FFFFFFFF',
  },
};

class AppearanceSettings extends ChangeNotifier {
  static const _storage = FlutterSecureStorage();
  static const _languageKey = 'bmray.appearance.language';
  static const _themeKey = 'bmray.appearance.theme';
  static const _customKey = 'bmray.appearance.customThemes';

  String language = 'auto';
  String themeId = 'dark';
  final Map<String, Map<String, dynamic>> customThemes = {};

  Map<String, dynamic> get palette =>
      customThemes[themeId] ?? builtInThemes[themeId] ?? builtInThemes['dark']!;

  bool get isEnglish => language == 'en' ||
      (language == 'auto' && WidgetsBinding.instance.platformDispatcher.locale
          .languageCode.toLowerCase() != 'ru');

  String text(String russian, String english) => isEnglish ? english : russian;

  static Color decodeColor(String value) {
    if (!RegExp(r'^#[0-9A-Fa-f]{8}$').hasMatch(value)) {
      throw const FormatException('Цвет должен быть в формате #RRGGBBAA.');
    }
    final hex = value.substring(1);
    return Color(int.parse('${hex.substring(6)}${hex.substring(0, 6)}', radix: 16));
  }

  Color color(String key) => decodeColor((palette[key] ??
      builtInThemes['dark']![key] ?? '#FFFFFFFF').toString());

  List<Color> get backgroundColors =>
      ((palette['backgroundColors'] ?? builtInThemes['dark']!['backgroundColors'])
          as List).map((entry) => decodeColor(entry.toString())).toList();

  ThemeData get theme {
    final background = backgroundColors.first;
    final isLight = ThemeData.estimateBrightnessForColor(background) ==
        Brightness.light;
    final brightness = isLight ? Brightness.light : Brightness.dark;
    final surface = color('serverRowBackgroundColor');
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: color('settingsControlsTintColor'),
        brightness: brightness,
        surface: surface,
      ),
      scaffoldBackgroundColor: background,
      cardTheme: CardThemeData(color: surface, elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)))),
    );
  }

  Future<void> load() async {
    try {
      language = await _storage.read(key: _languageKey) ?? 'auto';
      themeId = await _storage.read(key: _themeKey) ?? 'dark';
      final raw = await _storage.read(key: _customKey);
      if (raw != null) {
        final stored = jsonDecode(raw);
        if (stored is Map) {
          for (final entry in stored.entries) {
            if (entry.value is Map) {
              customThemes[entry.key.toString()] =
                  Map<String, dynamic>.from(entry.value as Map);
            }
          }
        }
      }
    } catch (_) {
      // A corrupt appearance preference does not prevent the app from opening.
    }
    notifyListeners();
  }

  Future<void> setLanguage(String value) async {
    if (!const {'auto', 'ru', 'en'}.contains(value)) return;
    language = value;
    notifyListeners();
    await _storage.write(key: _languageKey, value: value);
  }

  Future<void> setTheme(String value) async {
    if (!builtInThemes.containsKey(value) && !customThemes.containsKey(value)) {
      throw const FormatException('Тема не найдена.');
    }
    themeId = value;
    notifyListeners();
    await _storage.write(key: _themeKey, value: value);
  }

  Future<void> saveCustom(String name, String json) async {
    final title = name.trim();
    if (title.isEmpty || title.length > 40 || builtInThemes.containsKey(title)) {
      throw const FormatException('Введите другое название темы (до 40 символов).');
    }
    final parsed = jsonDecode(json);
    if (parsed is! Map || parsed['backgroundColors'] is! List ||
        (parsed['backgroundColors'] as List).isEmpty) {
      throw const FormatException('Нужен JSON темы с массивом backgroundColors.');
    }
    for (final entry in parsed.entries) {
      if (entry.key.toString().endsWith('Color')) {
        decodeColor(entry.value.toString());
      } else if (entry.key.toString().endsWith('Colors') && entry.value is List) {
        for (final color in entry.value as List) {
          decodeColor(color.toString());
        }
      }
    }
    customThemes[title] = Map<String, dynamic>.from(parsed);
    await _storage.write(key: _customKey, value: jsonEncode(customThemes));
    await setTheme(title);
  }

  Future<void> deleteCustom(String name) async {
    customThemes.remove(name);
    if (themeId == name) await setTheme('dark');
    await _storage.write(key: _customKey, value: jsonEncode(customThemes));
    notifyListeners();
  }
}

final appearance = AppearanceSettings();
