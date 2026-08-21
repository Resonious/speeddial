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
  Object? _lastError;

  ThemeMode get themeMode => _themeMode;

  Object? get lastError => _lastError;

  /// Loads persisted settings (called once at startup).
  Future<void> init() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(storageKey);
      final ThemeMode? mode = raw == null || raw.isEmpty
          ? null
          : ThemeMode.values.asNameMap()[raw];
      if (mode == null || mode == _themeMode) {
        _clearError();
        return;
      }
      _themeMode = mode;
      _lastError = null;
      notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, mode.name);
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  void _clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }
}
