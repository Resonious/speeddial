import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LeftRailTab { sessions, inbox }

typedef _ProjectDefaults = ({String providerId, bool yolo, bool shortPrompt});

/// The choices a new session starts from in one project.
class NewSessionDefaults {
  const NewSessionDefaults({
    required this.providerId,
    required this.yolo,
    required this.shortPrompt,
  });

  /// Null until a provider has ever been chosen.
  final String? providerId;
  final bool yolo;
  final bool shortPrompt;
}

/// App-local UI settings persisted via shared_preferences. The theme has a
/// safe default; the new-session provider remains null until selected.
///
/// New-session choices are remembered per project, and the most recent choice
/// anywhere is the fallback for a project with no memory of its own.
///
/// Stores never hold a BuildContext; UI reads them through `AppScope`.
class SettingsStore extends ChangeNotifier {
  static const String storageKey = 'speeddial.settings.v1';
  static const String providerStorageKey = 'speeddial.provider.v1';
  static const String yoloStorageKey = 'speeddial.yolo.v1';
  static const String shortPromptStorageKey = 'speeddial.shortPrompt.v1';
  static const String projectDefaultsStorageKey =
      'speeddial.projectSessionDefaults.v1';

  static const String leftRailTabStorageKey = 'speeddial.leftRailTab.v1';

  LeftRailTab _leftRailTab = LeftRailTab.sessions;
  ThemeMode _themeMode = ThemeMode.system;
  String? _providerId;
  bool _yolo = false;
  bool _shortPrompt = false;
  final Map<String, _ProjectDefaults> _projectDefaults =
      <String, _ProjectDefaults>{};
  Object? _lastError;

  LeftRailTab get leftRailTab => _leftRailTab;

  ThemeMode get themeMode => _themeMode;

  /// The most recently chosen provider in any project.
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
      _yolo = prefs.getBool(yoloStorageKey) ?? false;
      _shortPrompt = prefs.getBool(shortPromptStorageKey) ?? false;
      _lastError = null;
      _loadProjectDefaults(prefs.getString(projectDefaultsStorageKey));
      if (changed || _lastError != null) notifyListeners();
    } catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  /// Reads the per-project memory. It only seeds a form, so an unreadable
  /// value is recorded and dropped rather than blocking app startup.
  void _loadProjectDefaults(String? raw) {
    _projectDefaults.clear();
    if (raw == null) return;
    try {
      final Map<String, Object?> decoded = (jsonDecode(raw) as Map)
          .cast<String, Object?>();
      for (final MapEntry<String, Object?> entry in decoded.entries) {
        final Map<String, Object?> item = (entry.value as Map)
            .cast<String, Object?>();
        _projectDefaults[entry.key] = (
          providerId: item['providerId'] as String,
          yolo: item['yolo'] as bool? ?? false,
          shortPrompt: item['shortPrompt'] as bool,
        );
      }
    } on Object catch (error) {
      _projectDefaults.clear();
      _lastError = error;
    }
  }

  /// What a new session in [projectId] starts from: that project's own memory,
  /// else the last used choice.
  NewSessionDefaults newSessionDefaultsFor(String projectId) {
    final _ProjectDefaults? project = _projectDefaults[projectId];
    return NewSessionDefaults(
      providerId: project?.providerId ?? _providerId,
      yolo: project?.yolo ?? _yolo,
      shortPrompt: project?.shortPrompt ?? _shortPrompt,
    );
  }

  /// Records the choices for [projectId], which also become the last used
  /// choice for projects with no memory of their own.
  Future<void> rememberNewSessionDefaults(
    String projectId, {
    required String providerId,
    required bool yolo,
    required bool shortPrompt,
  }) async {
    final _ProjectDefaults project = (
      providerId: providerId,
      yolo: yolo,
      shortPrompt: shortPrompt,
    );
    if (providerId == _providerId &&
        yolo == _yolo &&
        shortPrompt == _shortPrompt &&
        project == _projectDefaults[projectId]) {
      return;
    }
    _providerId = providerId;
    _yolo = yolo;
    _shortPrompt = shortPrompt;
    _projectDefaults[projectId] = project;
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(providerStorageKey, providerId);
      await prefs.setBool(yoloStorageKey, yolo);
      await prefs.setBool(shortPromptStorageKey, shortPrompt);
      await prefs.setString(
        projectDefaultsStorageKey,
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, _ProjectDefaults> entry
              in _projectDefaults.entries)
            entry.key: <String, Object?>{
              'providerId': entry.value.providerId,
              'yolo': entry.value.yolo,
              'shortPrompt': entry.value.shortPrompt,
            },
        }),
      );
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
}
