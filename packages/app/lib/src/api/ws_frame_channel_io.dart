import 'dart:async';
import 'dart:io' as io;

import 'daemon_frame_channel.dart';

DaemonFrameChannel connectWebSocketFrameChannel(
  Uri uri, {
  required Duration connectTimeout,
  Duration? pingInterval,
}) => _IoWebSocketDaemonFrameChannel(
  uri,
  connectTimeout: connectTimeout,
  pingInterval: pingInterval,
);

/// Native `dart:io` WebSocket channel with an abortable per-attempt
/// [io.HttpClient], bounded handshake timeout, and protocol-level keepalive
/// pings.
class _IoWebSocketDaemonFrameChannel implements DaemonFrameChannel {
  _IoWebSocketDaemonFrameChannel(
    Uri uri, {
    required Duration connectTimeout,
    Duration? pingInterval,
  }) : _httpClient = _createHttpClient(connectTimeout) {
    // Prevent an unhandled zone error if `close()` is called before a caller
    // reads [ready]; callers that do await [ready] still receive the error.
    _ready.future.ignore();
    unawaited(
      _connect(uri, connectTimeout: connectTimeout, pingInterval: pingInterval),
    );
  }

  static final _DirectHttpOverrides _directHttp = _DirectHttpOverrides();

  static io.HttpClient _createHttpClient(Duration connectTimeout) {
    // `flutter_test` installs a global HttpOverrides whose _MockHttpResponse
    // throws an unhandled UnsupportedError from detachSocket() inside
    // dart:io WebSocket.connect(). Bypassing it matches dart:io's built-in
    // static WebSocket._httpClient while still giving each attempt its own
    // abortable HttpClient with connectionTimeout.
    final io.HttpClient client = io.HttpOverrides.runWithHttpOverrides(
      io.HttpClient.new,
      _directHttp,
    );
    client.connectionTimeout = connectTimeout;
    return client;
  }

  io.HttpClient? _httpClient;
  io.WebSocket? _webSocket;
  StreamSubscription<Object?>? _socketSub;
  Timer? _connectTimer;
  final Completer<void> _ready = Completer<void>();
  final StreamController<Object?> _incoming = StreamController<Object?>();
  bool _closed = false;

  Future<void> _connect(
    Uri uri, {
    required Duration connectTimeout,
    Duration? pingInterval,
  }) async {
    final io.HttpClient? client = _httpClient;
    if (client == null || _closed) return;
    // `HttpClient.connectionTimeout` only covers TCP/TLS connect, not a stalled
    // HTTP Upgrade response. This timer bounds the entire handshake and force-
    // closes the per-attempt HttpClient so the underlying socket aborts cleanly.
    final Timer timer = Timer(connectTimeout, () {
      if (_closed || _webSocket != null) return;
      _closeHttpClient(force: true);
      if (!_ready.isCompleted) {
        _ready.completeError(
          TimeoutException('WebSocket connect timed out', connectTimeout),
        );
      }
      if (!_incoming.isClosed) {
        unawaited(_incoming.close());
      }
    });
    _connectTimer = timer;
    try {
      final io.WebSocket socket = await io.WebSocket.connect(
        uri.toString(),
        customClient: client,
      );
      timer.cancel();
      if (identical(_connectTimer, timer)) _connectTimer = null;
      if (_closed || _ready.isCompleted) {
        unawaited(_closeSocketQuietly(socket));
        return;
      }
      _webSocket = socket;
      if (pingInterval != null) {
        socket.pingInterval = pingInterval;
      }
      // The WebSocket has detached its socket from `client`; close the
      // per-attempt HttpClient now so no idle client resources linger.
      _closeHttpClient(force: false);
      _socketSub = socket.listen(
        (Object? data) {
          if (!_incoming.isClosed) _incoming.add(data);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_incoming.isClosed) _incoming.addError(error, stackTrace);
        },
        onDone: () {
          if (!_incoming.isClosed) unawaited(_incoming.close());
        },
      );
      if (!_ready.isCompleted) _ready.complete();
    } on Object catch (error, stackTrace) {
      timer.cancel();
      if (identical(_connectTimer, timer)) _connectTimer = null;
      _closeHttpClient(force: true);
      if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
      if (!_incoming.isClosed) unawaited(_incoming.close());
    }
  }

  void _closeHttpClient({required bool force}) {
    final io.HttpClient? client = _httpClient;
    _httpClient = null;
    if (client == null) return;
    try {
      client.close(force: force);
    } on Object {
      // Best-effort cleanup.
    }
  }

  Future<void> _closeSocketQuietly(io.WebSocket socket) async {
    try {
      await socket.close();
    } on Object {
      // Already closed or peer unreachable.
    }
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  void add(Object? data) {
    if (_closed) return;
    _webSocket?.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connectTimer?.cancel();
    _connectTimer = null;
    // Force-closing the per-attempt HttpClient immediately aborts any hung
    // TCP/TLS/HTTP-upgrade handshake on Android background/network changes.
    _closeHttpClient(force: true);
    if (!_ready.isCompleted) {
      _ready.completeError(
        const io.WebSocketException('WebSocket closed before ready'),
      );
    }
    final StreamSubscription<Object?>? sub = _socketSub;
    _socketSub = null;
    if (sub != null) {
      await sub.cancel();
    }
    final io.WebSocket? socket = _webSocket;
    _webSocket = null;
    if (socket != null) {
      await _closeSocketQuietly(socket);
    }
    if (!_incoming.isClosed) {
      // Single-subscription StreamController.close() waits for a listener to
      // drain the done event; fire-and-forget so closing an unlistened channel
      // never hangs.
      unawaited(_incoming.close());
    }
  }
}

class _DirectHttpOverrides extends io.HttpOverrides {
  _DirectHttpOverrides();
}
