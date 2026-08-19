/// SnackBar copy for daemon calls that failed because the connection
/// dropped (a `DaemonConnectionError`: device sleep, network flap, daemon
/// restart). The client is already reconnecting with backoff and stores
/// resync on success, so the user gets this transient notice instead of a
/// raw error. Genuine daemon rejections still surface verbatim at the call
/// site.
const String kConnectionLostMessage = 'Connection lost — reconnecting…';
