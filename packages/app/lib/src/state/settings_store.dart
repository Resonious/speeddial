import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-local UI settings, persisted via shared_preferences. Currently just
/// the theme mode; defaults to [ThemeMode.system] when nothing is stored or
/// [init] was never called (tests, demo mode).
///
/// Stores never hold a BuildContext; UI reads them through `AppScope`.
class SettingsStore extends ChangeNotifier {
  static const String storageKey = 'speeddial.settings.v1';

  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  /// Loads persisted settings (called once at startup).
  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    final ThemeMode? mode = ThemeMode.values.asNameMap()[raw];
    if (mode == null || mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, mode.name);
  }
}
