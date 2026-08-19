/// Protocol error codes and the [DaemonError] exception shape.
library;

/// The client is not authenticated (first request must be `auth.authenticate`).
const int kErrUnauthenticated = -32001;

/// The requested project, session, or resource does not exist.
const int kErrNotFound = -32002;

/// The operation conflicts with current state (e.g. a turn already running).
const int kErrConflict = -32003;

/// The provider command is not available on this host.
const int kErrProviderUnavailable = -32010;

/// The agent process failed or exited unexpectedly.
const int kErrAgentProcess = -32011;

/// A git/gh operation failed.
const int kErrGit = -32020;

/// JSON-RPC internal error (-32603): malformed frames, unexpected shapes.
const int kErrInternal = -32603;

/// Error payload carried across the wire inside a JSON-RPC error object.
///
/// Throw this from daemon internals and let the transport translate it;
/// never hand-roll error JSON at call sites.
class DaemonError implements Exception {
  const DaemonError(this.code, this.message, [this.data]);

  /// JSON-RPC error code from PROTOCOL.md (negative int).
  final int code;

  /// Human-readable error message.
  final String message;

  /// Optional structured detail, passed through verbatim.
  final Object? data;

  /// The `error` object of a JSON-RPC failure envelope.
  Map<String, Object?> toErrorJson() => <String, Object?>{
        'code': code,
        'message': message,
        'data': ?data,
      };

  @override
  String toString() => 'DaemonError($code): $message';
}

/// A [DaemonError] raised client-side when the connection drops or was
/// never up: pending calls fail with it on socket close, and calls made
/// while disconnected/disposed fail with it immediately.
///
/// Never crosses the wire — the daemon reports real rejections as plain
/// [DaemonError]s — so UI can treat this subtype as transient (the client
/// reconnects with backoff and stores resync afterwards) instead of a
/// failed request. Code and message stay `-32603`/`'peer closed'`-style,
/// so existing `DaemonError` catches and code/message checks are unaffected.
class DaemonConnectionError extends DaemonError {
  const DaemonConnectionError(String message) : super(kErrInternal, message);
}
