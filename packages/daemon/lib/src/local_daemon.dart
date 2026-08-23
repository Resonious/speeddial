/// In-process daemon: the same WebSocket JSON-RPC server, engine, and store
/// as `speeddial serve`, but without the CLI arg parsing, discovery file, or
/// signal handling. The embedding app owns the lifecycle via [start]/[stop].
///
/// Binds to `127.0.0.1` with no auth token (loopback per PROTOCOL.md) on an
/// OS-chosen free port ([port] / [url] are available after [start]). Shares
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
  LocalDaemon._(this._server, this._engine, this._store);

  final SpeedDialServer _server;
  final SessionEngine _engine;
  final DaemonStore _store;

  /// The bound port (meaningful after [start]).
  int get port => _server.port;

  /// `ws://127.0.0.1:<port>/ws` — the endpoint URL for a WebSocket client.
  String get url => 'ws://127.0.0.1:${_server.port}$kWsPath';

  /// Starts the daemon: opens the store, restores sessions, binds the
  /// WebSocket server on `127.0.0.1` (loopback, no auth).
  ///
  /// [port] defaults to 0 (OS-assigned free port). [dbPath] defaults to
  /// `~/.speeddial/speeddial.db`.
  static Future<LocalDaemon> start({int port = 0, String? dbPath}) async {
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
        host: '127.0.0.1',
        port: port,
        engine: engine,
        store: store,
        providers: providers,
        authToken: null,
        git: git,
        pr: pr,
      );
    } on Object {
      await engine.dispose();
      store.dispose();
      rethrow;
    }

    return LocalDaemon._(server, engine, store);
  }

  /// Shuts the daemon down: disposes the engine (kills agent processes),
  /// closes the server, disposes the store. Idempotent.
  Future<void> stop() async {
    await _engine.dispose();
    await _server.close();
    _store.dispose();
  }
}
