import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'store_base.dart';

/// Persists message-composer text per daemon/session.
///
/// Drafts are client-local UI state: they never cross the daemon protocol.
/// Each draft has its own preference entry so editing one session does not
/// rewrite every saved draft. Attachment bytes deliberately stay in the
/// composer; their protocol limits are too large for shared preferences,
/// especially on the web.
class DraftsStore extends StoreBase {
  static const String storagePrefix = 'speeddial.chatDraft.v1.';

  final Map<String, String> _textByKey = <String, String>{};
  final Map<String, Future<void>> _writeTails = <String, Future<void>>{};
  SharedPreferences? _preferences;
  Object? _lastError;

  Object? get lastError => _lastError;

  /// Loads every saved draft before the first composer is shown.
  Future<void> init() async {
    try {
      final SharedPreferences preferences = _preferences ??=
          await SharedPreferences.getInstance();
      _textByKey.clear();
      for (final String key in preferences.getKeys()) {
        if (!key.startsWith(storagePrefix)) continue;
        final String? text = preferences.getString(key);
        if (text != null && text.isNotEmpty) _textByKey[key] = text;
      }
      _clearError();
    } on Object catch (error) {
      _recordError(error);
      rethrow;
    }
  }

  String textFor(String daemonId, String sessionId) =>
      _textByKey[_storageKey(daemonId, sessionId)] ?? '';

  /// Updates the in-memory draft immediately and serializes persistence for
  /// this session so slower writes can never overwrite newer keystrokes.
  Future<void> setText(String daemonId, String sessionId, String text) {
    final String key = _storageKey(daemonId, sessionId);
    final String current = _textByKey[key] ?? '';
    if (current == text) return Future<void>.value();
    if (text.isEmpty) {
      _textByKey.remove(key);
    } else {
      _textByKey[key] = text;
    }

    final Future<void> previous = _writeTails[key] ?? Future<void>.value();
    final Future<void> operation = previous.then(
      (_) => _write(key, text),
      onError: (Object _, StackTrace _) => _write(key, text),
    );
    _writeTails[key] = operation;
    return operation;
  }

  /// Completes after all writes currently queued by composers.
  Future<void> flush() => Future.wait<void>(_writeTails.values);

  Future<void> _write(String key, String text) async {
    try {
      final SharedPreferences preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final bool saved = text.isEmpty
          ? await preferences.remove(key)
          : await preferences.setString(key, text);
      if (!saved) throw StateError('Could not persist a chat draft');
      _clearError();
    } on Object catch (error) {
      _recordError(error);
      rethrow;
    }
  }

  void _recordError(Object error) {
    _lastError = error;
    notifyListeners();
  }

  void _clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  static String _storageKey(String daemonId, String sessionId) {
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return '$storagePrefix${encode(daemonId)}.${encode(sessionId)}';
  }
}
