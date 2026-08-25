import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'store_base.dart';

/// Startup configuration of the desktop app's embedded in-process daemon.
@immutable
class EmbeddedDaemonConfig {
  const EmbeddedDaemonConfig({
    this.host = '127.0.0.1',
    this.port = 0,
    this.token = '',
  });

  factory EmbeddedDaemonConfig.fromJson(Map<String, Object?> json) {
    return EmbeddedDaemonConfig(
      host: (json['host'] as String?) ?? '127.0.0.1',
      port: (json['port'] as int?) ?? 0,
      token: (json['token'] as String?) ?? '',
    );
  }

  /// Bind interface: `127.0.0.1` (default) keeps the daemon loopback-only;
  /// `0.0.0.0`/`::` expose it to every interface; any other address binds
  /// just that interface. Non-loopback hosts require a [token].
  final String host;

  /// Listen port; 0 lets the OS choose a free one.
  final int port;

  /// Auth token clients must present; empty disables auth (loopback only).
  final String token;

  bool get isLoopback =>
      host == '127.0.0.1' || host == '::1' || host == 'localhost';

  Map<String, Object?> toJson() => <String, Object?>{
    if (host != '127.0.0.1') 'host': host,
    if (port != 0) 'port': port,
    if (token.isNotEmpty) 'token': token,
  };

  @override
  bool operator ==(Object other) =>
      other is EmbeddedDaemonConfig &&
      other.host == host &&
      other.port == port &&
      other.token == token;

  @override
  int get hashCode => Object.hash(host, port, token);
}


/// Configuration of the embedded in-process daemon: the persisted
/// [EmbeddedDaemonConfig] plus live restart state written by
/// [AppData.applyEmbeddedDaemonConfig] (which owns the controller).
///
/// Stores never hold a BuildContext; UI reads them through [AppScope].
class EmbeddedDaemonStore extends StoreBase {
  static const String storageKey = 'speeddial.embeddedDaemon.v1';

  EmbeddedDaemonConfig _config = const EmbeddedDaemonConfig();
  Object? _lastError;
  bool _restarting = false;

  EmbeddedDaemonConfig get config => _config;

  /// The error of the last failed (re)start attempt; null after a success.
  Object? get lastError => _lastError;

  /// True while the embedded daemon is being stopped and restarted with new
  /// settings.
  bool get restarting => _restarting;

  /// Loads the persisted config (called once at startup).
  Future<void> init() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return;
      _config = EmbeddedDaemonConfig.fromJson(decoded);
      notifyListeners();
    } on FormatException {
      // Corrupt storage: keep defaults rather than crash at launch.
    }
  }

  /// Persists [config] (whitespace-trimmed) so the next launch reuses it and
  /// notifies listeners. Clears [lastError]: a new attempt is starting.
  Future<void> save(EmbeddedDaemonConfig config) async {
    _config = EmbeddedDaemonConfig(
      host: config.host.trim(),
      port: config.port,
      token: config.token.trim(),
    );
    _lastError = null;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_config.toJson()));
    } on Object catch (error) {
      _lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  /// Restart bookkeeping owned by [AppData.applyEmbeddedDaemonConfig].
  void setRestarting(bool value) {
    if (_restarting == value) return;
    _restarting = value;
    notifyListeners();
  }

  /// Records a (re)start failure for the settings UI. Notifies.
  void setLastError(Object? error) {
    if (_lastError == error) return;
    _lastError = error;
    notifyListeners();
  }
}

/// A crypto-secure random token: 12 random bytes hex-encoded (24 chars),
/// matching `speeddial serve`'s generated tokens.
String generateEmbeddedDaemonToken() {
  final Random random = Random.secure();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 12; i++) {
    out.write(random.nextInt(1 << 8).toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
