import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// App-local UI settings persisted via shared_preferences. Theme and session
/// sandbox mode have safe defaults; the new-session provider remains null
/// until selected.
///
/// Stores never hold a BuildContext; UI reads them through `AppScope`.
class SettingsStore extends ChangeNotifier {
  static const String storageKey = 'speeddial.settings.v1';
  static const String providerStorageKey = 'speeddial.provider.v1';
  static const String sandboxStorageKey = 'speeddial.sessionSandboxMode.v1';

  ThemeMode _themeMode = ThemeMode.system;
  String? _providerId;
  SessionSandboxMode _sandboxMode = SessionSandboxMode.workspaceWrite;
  Object? _lastError;

  ThemeMode get themeMode => _themeMode;

  String? get providerId => _providerId;

  SessionSandboxMode get sandboxMode => _sandboxMode;

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
      final SessionSandboxMode? sandboxMode = SessionSandboxMode.values
          .asNameMap()[prefs.getString(sandboxStorageKey)];
      final bool changed =
          (mode != null && mode != _themeMode) ||
          providerId != _providerId ||
          (sandboxMode != null && sandboxMode != _sandboxMode);
      if (mode != null) _themeMode = mode;
      _providerId = providerId;
      if (sandboxMode != null) _sandboxMode = sandboxMode;
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

  Future<void> setSandboxMode(SessionSandboxMode mode) async {
    if (mode == _sandboxMode) return;
    _sandboxMode = mode;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(sandboxStorageKey, mode.wire);
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }
}
