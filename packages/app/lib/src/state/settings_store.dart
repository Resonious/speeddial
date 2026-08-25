import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-local UI settings persisted via shared_preferences. Theme and session
/// grouping have safe defaults; the new-session provider remains null until
/// selected.
///
/// Stores never hold a BuildContext; UI reads them through `AppScope`.
class SettingsStore extends ChangeNotifier {
  static const String storageKey = 'speeddial.settings.v1';
  static const String providerStorageKey = 'speeddial.provider.v1';
  static const String groupSessionsStorageKey =
      'speeddial.group_sessions_by_project.v1';

  ThemeMode _themeMode = ThemeMode.system;
  String? _providerId;
  bool _groupSessionsByProject = true;
  Object? _lastError;

  ThemeMode get themeMode => _themeMode;

  String? get providerId => _providerId;

  bool get groupSessionsByProject => _groupSessionsByProject;

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
      final bool groupSessionsByProject =
          prefs.getBool(groupSessionsStorageKey) ?? true;
      final bool changed =
          (mode != null && mode != _themeMode) ||
          providerId != _providerId ||
          groupSessionsByProject != _groupSessionsByProject;
      if (mode != null) _themeMode = mode;
      _providerId = providerId;
      _groupSessionsByProject = groupSessionsByProject;
      _lastError = null;
      if (changed) notifyListeners();
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

  Future<void> setGroupSessionsByProject(bool value) async {
    if (value == _groupSessionsByProject) return;
    _groupSessionsByProject = value;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(groupSessionsStorageKey, value);
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }
}
