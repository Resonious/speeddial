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
  /// Starts the daemon. Returns the WebSocket endpoint URL
  /// (`ws://127.0.0.1:<port>/ws`) on success; `null` when unsupported or
  /// already stopped by a racing [stop].
  ///
  /// Idempotent: calling [start] again after success returns the same URL.
  Future<String?> start();

  /// Stops the daemon (best-effort, idempotent). Safe to call when [start]
  /// was never called, never completed, or already stopped.
  Future<void> stop();

  /// True after a successful [start] and before [stop].
  bool get isRunning;
}
