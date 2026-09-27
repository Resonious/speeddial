import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LeftRailTab { sessions, inbox }

/// App-local UI settings persisted via shared_preferences. The theme has a
/// safe default; the new-session provider remains null until selected.
///
/// Stores never hold a BuildContext; UI reads them through `AppScope`.
class SettingsStore extends ChangeNotifier {
  static const String storageKey = 'speeddial.settings.v1';
  static const String providerStorageKey = 'speeddial.provider.v1';

  static const String leftRailTabStorageKey = 'speeddial.leftRailTab.v1';

  LeftRailTab _leftRailTab = LeftRailTab.sessions;
  ThemeMode _themeMode = ThemeMode.system;
  String? _providerId;
  Object? _lastError;

  LeftRailTab get leftRailTab => _leftRailTab;

  ThemeMode get themeMode => _themeMode;

  String? get providerId => _providerId;

  Object? get lastError => _lastError;

  /// Loads persisted settings (called once at startup).
  Future<void> init() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(storageKey);
      final ThemeMode? mode = raw == null || raw.isEmpty
          ? null
          : ThemeMode.values.asNameMap()[raw];
      final String? providerId = prefs.getString(providerStorageKey);
      final LeftRailTab tab =
          LeftRailTab.values.asNameMap()[prefs.getString(
            leftRailTabStorageKey,
          )] ??
          LeftRailTab.sessions;
      final bool changed =
          tab != _leftRailTab ||
          (mode != null && mode != _themeMode) ||
          providerId != _providerId;
      if (mode != null) _themeMode = mode;
      _providerId = providerId;
      _leftRailTab = tab;
      _lastError = null;
      if (changed) notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setLeftRailTab(LeftRailTab tab) async {
    if (tab == _leftRailTab) return;
    _leftRailTab = tab;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(leftRailTabStorageKey, tab.name);
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

  Future<void> setProviderId(String providerId) async {
    if (providerId == _providerId) return;
    _providerId = providerId;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(providerStorageKey, providerId);
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }
}
