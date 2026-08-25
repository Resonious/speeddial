/// In-process daemon: the same WebSocket JSON-RPC server, engine, and store
/// as `speeddial serve`, but without the CLI arg parsing, discovery file, or
/// signal handling. The embedding app owns the lifecycle via [start]/[stop].
///
/// Defaults to loopback (`127.0.0.1`) with no auth token (per PROTOCOL.md)
/// on an OS-chosen free port; [start] also accepts a fixed port, a custom
/// bind interface, and a token. A non-loopback bind requires a non-empty
/// token. [port]/[url] are available after [start]. Shares
/// `~/.speeddial/speeddial.db` with the standalone CLI daemon so projects and
/// sessions are visible from both surfaces.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'client.dart';
import 'engine/session_engine.dart';
import 'git/git_service.dart';
import 'git/pr_service.dart';
import 'paths.dart';
import 'providers/provider_registry.dart';
import 'server/ws_server.dart';
import 'store/daemon_store.dart';

/// A SpeedDial daemon running in the current process, driven directly by the
/// embedding app instead of the CLI.
class LocalDaemon {
  LocalDaemon._(this._server, this._engine, this._store, this._bindHost);

  final SpeedDialServer _server;
  final SessionEngine _engine;
  final DaemonStore _store;
  final String _bindHost;

  /// The bound port (meaningful after [start]).
  int get port => _server.port;

  /// The interface the server is bound to, exactly as requested from
  /// [start] (meaningful after [start]).
  String get host => _bindHost;

  /// `ws://<host>:<port>/ws` — the endpoint URL for a WebSocket client.
  ///
  /// Any-interface binds report a loopback address (`0.0.0.0` → `127.0.0.1`,
  /// `::` → `[::1]`), and IPv6 literals get URL brackets; every other host is
  /// used verbatim.
  String get url => 'ws://${_clientHost(_bindHost)}:${_server.port}$kWsPath';

  static String _clientHost(String bindHost) {
    if (bindHost == '0.0.0.0') return '127.0.0.1';
    if (bindHost == '::') return '[::1]';
    if (bindHost.contains(':')) return '[$bindHost]'; // IPv6 literal
    return bindHost;
  }

  static bool _isLoopback(String host) =>
      host == '127.0.0.1' || host == '::1' || host == 'localhost';

  /// Starts the daemon: opens the store, restores sessions, and binds the
  /// WebSocket server.
  ///
  /// [host] defaults to `127.0.0.1` (loopback, no auth required); any other
  /// interface requires a non-empty [authToken] (matching `speeddial serve`
  /// policy) and throws [ArgumentError] otherwise. [port] defaults to 0
  /// (OS-assigned free port). [dbPath] defaults to
  /// `~/.speeddial/speeddial.db`.
  static Future<LocalDaemon> start({
    String host = '127.0.0.1',
    int port = 0,
    String? authToken,
    String? dbPath,
  }) async {
    final String token = (authToken ?? '').trim();
    if (!_isLoopback(host) && token.isEmpty) {
      throw ArgumentError.value(
        host,
        'host',
        'binding a non-loopback interface requires a non-empty authToken',
      );
    }
    final String resolvedDb =
        dbPath ??
        p.join(
          homeDir() ?? Directory.current.path,
          '.speeddial',
          'speeddial.db',
        );
    Directory(p.dirname(resolvedDb)).createSync(recursive: true);

    final store = DaemonStore(resolvedDb);
    final providers = ProviderRegistry(
      environmentProvider: store.daemonEnvironment,
    );
    final git = GitService();
    final engine = SessionEngine(store: store, providers: providers, git: git);
    final pr = PrService();
    await engine.restore();

    final SpeedDialServer server;
    try {
      server = await SpeedDialServer.bind(
        host: host,
        port: port,
        engine: engine,
        store: store,
        providers: providers,
        authToken: token.isEmpty ? null : token,
        git: git,
        pr: pr,
      );
    } on Object {
      await engine.dispose();
      store.dispose();
      rethrow;
    }

    return LocalDaemon._(server, engine, store, host);
  }

  /// Shuts the daemon down: disposes the engine (kills agent processes),
  /// closes the server, disposes the store. Idempotent.
  Future<void> stop() async {
    await _engine.dispose();
    await _server.close();
    _store.dispose();
  }
}

