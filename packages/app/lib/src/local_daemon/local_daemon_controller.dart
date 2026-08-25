/// Contract for the embedded in-process daemon, implemented per platform.
///
/// Desktop builds (linux/macos/windows) use the native implementation backed
/// by `package:speeddial_daemon`'s [LocalDaemon]; web/mobile use a stub that
/// reports unsupported. The app gates embedding on
/// [embeddedDaemonSupported] (from `local_daemon.dart`) and never calls
/// [start] otherwise.
library;

/// A handle on an in-process daemon, or a report that none is available.
abstract class LocalDaemonController {
  /// Starts the daemon with [host] (bind interface, default loopback),
  /// [port] (0 = OS-chosen) and [token] (empty = no auth; required for
  /// non-loopback hosts). Returns the WebSocket endpoint URL
  /// (`ws://<host>:<port>/ws`) on success; `null` when unsupported, already
  /// starting, or the bind failed (see [lastError]).
  ///
  /// Idempotent: calling [start] again after success returns the same URL.
  Future<String?> start({
    String host = '127.0.0.1',
    int port = 0,
    String token = '',
  });

  /// Stops the daemon (best-effort, idempotent). Safe to call when [start]
  /// was never called, never completed, or already stopped.
  Future<void> stop();

  /// True after a successful [start] and before [stop].
  bool get isRunning;

  /// The error that made the most recent [start] return `null`; null after a
  /// successful start (or before any attempt).
  Object? get lastError;
}
