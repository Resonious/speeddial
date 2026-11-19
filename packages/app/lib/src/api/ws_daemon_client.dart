import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'daemon_client.dart';
import 'daemon_frame_channel.dart';
import 'local_history.dart';
import 'saved_history_client.dart';
import 'ws_frame_channel.dart';

export 'daemon_frame_channel.dart';

/// Notification feeds belong to the configured endpoint, surviving edits to
/// its connection parameters. Stores may subscribe for the app's lifetime.
class _DaemonNotifications {
  final StreamController<void> resynced = StreamController<void>.broadcast();
  final StreamController<({String sessionId, SessionEvent event})> events =
      StreamController.broadcast();
  final StreamController<Session> sessions =
      StreamController<Session>.broadcast();
  final StreamController<String> git = StreamController<String>.broadcast();
  final StreamController<String> removals =
      StreamController<String>.broadcast();
  final StreamController<void> projects = StreamController<void>.broadcast();
  final StreamController<SessionNote> notes =
      StreamController<SessionNote>.broadcast();
  final StreamController<String> noteRemovals =
      StreamController<String>.broadcast();
  final StreamController<SessionQueue> queues =
      StreamController<SessionQueue>.broadcast();

  Future<void> close() async {
    await notes.close();
    await noteRemovals.close();
    await queues.close();
    await sessions.close();
    await git.close();
    await events.close();
    await removals.close();
    await projects.close();
    await resynced.close();
  }
}

/// Live [DaemonClient] speaking PROTOCOL.md's JSON-RPC 2.0 envelope over a
/// WebSocket. Transport uses a per-attempt native `dart:io` WebSocket on
/// native platforms (with bounded connect timeout, force-abortable handshakes,
/// and protocol pings) and `package:web_socket_channel` on web; decoded frames
/// are fed to an [RpcPeer].
///
/// [connect] must be called before use: the client authenticates first when a
/// [token] is configured and then switches `connState` to connected. Socket
/// drops (server close or network error) and failed initial connects alike
/// are retried with exponential backoff starting at [reconnectBase] (doubling
/// per attempt, capped at 15s); after each successful connect that followed
/// a failure the client re-authenticates and emits on [resynced] so stores
/// can backfill history missed while offline. [retryNow] resets the backoff,
/// aborts any hung in-flight attempt, and retries immediately.
///
/// Live notifications are broadcast without buffering: a session that nobody
/// is watching simply loses its events (stores watch deliberately and recover
/// through [resynced] + `history()`).
class WsDaemonClient implements DaemonClient, SavedHistoryClient {
  WsDaemonClient({
    required this.url,
    this.token,
    this.localHistory,
    DaemonFrameChannelFactory? channelFactory,
    // The explicit initializers (rather than `this.` formals) keep each
    // field's default next to its declaration.
    Duration reconnectBase = const Duration(milliseconds: 500),
    Duration livenessProbeTimeout = const Duration(seconds: 3),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration? pingInterval = const Duration(seconds: 25),
    this.historyDetail = SessionHistoryDetail.full,
  }) : _notifications = _DaemonNotifications(),
       _channelFactory =
           channelFactory ??
           ((Uri uri) => connectWebSocketFrameChannel(
             uri,
             connectTimeout: connectTimeout,
             pingInterval: pingInterval,
           )),
       reconnectBase = reconnectBase, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       livenessProbeTimeout = livenessProbeTimeout,
       connectTimeout = connectTimeout, // ignore: prefer_initializing_formals
       pingInterval = pingInterval; // ignore: prefer_initializing_formals

  WsDaemonClient._replacement(
    WsDaemonClient previous, {
    required this.url,
    this.token,
  }) : _notifications = previous._notifications,
       _channelFactory = previous._channelFactory,
       reconnectBase = previous.reconnectBase,
       livenessProbeTimeout = previous.livenessProbeTimeout,
       connectTimeout = previous.connectTimeout,
       pingInterval = previous.pingInterval,
       historyDetail = previous.historyDetail,
       localHistory = previous.localHistory {
    _resyncNeeded = true;
  }

  final LocalHistory? localHistory;
  Object? historyCacheError;
  void _cacheEvent(String id, SessionEvent event) {
    final cache = localHistory;
    if (cache != null) _cacheOperation(cache.record(id, event));
  }

  void _cacheOperation(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        historyCacheError = error;
        debugPrint('Offline history: $error');
      }),
    );
  }

  final _DaemonNotifications _notifications;
  bool _ownsNotifications = true;

  /// Replaces the connection while keeping existing store subscriptions alive.
  /// The next successful connect backfills state missed during the edit.
  /// This instance is disposed and notification ownership moves to the result.
  WsDaemonClient reconfigured({required String url, String? token}) {
    if (_disposed) throw StateError('Daemon client is disposed');
    final WsDaemonClient replacement = WsDaemonClient._replacement(
      this,
      url: url,
      token: token,
    );
    _ownsNotifications = false;
    unawaited(dispose());
    return replacement;
  }

  /// WebSocket endpoint, e.g. `ws://127.0.0.1:7331/ws`.
  final String url;

  /// Token for `auth.authenticate`; null means the daemon requires none
  /// (loopback per PROTOCOL.md).
  final String? token;

  final DaemonFrameChannelFactory _channelFactory;

  /// Delay of the first reconnect attempt; every retry doubles this,
  /// capped at 15 seconds.
  final Duration reconnectBase;

  /// How long [verifyLiveness] waits for the daemon to answer its probe
  /// before declaring the socket half-dead (see there).
  final Duration livenessProbeTimeout;

  /// Maximum time allowed for each connection phase (socket handshake and
  /// `auth.authenticate`) before tearing down and retrying. Bounds stalls
  /// caused by silent packet drops during mobile backgrounding or handoffs.
  final Duration connectTimeout;

  /// Native WebSocket keepalive ping interval; null disables protocol pings.
  final Duration? pingInterval;

  /// Projection requested for persisted history pages. Compact targets use
  /// summary events while desktop/mobile retain the full payload by default.
  final SessionHistoryDetail historyDetail;

  /// Live connection state; drive UI/status off this (or [isConnected]).
  /// Starts at [DaemonConnectionState.connecting].
  final ValueNotifier<DaemonConnectionState> connState =
      ValueNotifier<DaemonConnectionState>(DaemonConnectionState.connecting);

  /// Emits after reconnects, including the first connect after an endpoint edit.
  StreamController<void> get _resyncController => _notifications.resynced;

  /// Every decoded `session.event` notification, keyed by session id.
  StreamController<({String sessionId, SessionEvent event})>
  get _sessionEventFeed => _notifications.events;
  StreamController<Session> get _sessionUpdatesController =>
      _notifications.sessions;

  StreamController<String> get _gitChangedController => _notifications.git;

  StreamController<String> get _sessionRemovalsController =>
      _notifications.removals;

  StreamController<void> get _projectsChangedController =>
      _notifications.projects;

  static const Duration _maxReconnectDelay = Duration(seconds: 15);
  static const Duration _gracefulCloseTimeout = Duration(seconds: 2);

  DaemonFrameChannel? _channel;

  /// Whether [_channel] has completed its connect handshake (`ready`). Only
  /// an established channel gets a graceful (awaited) close on disposal;
  /// failed, timed-out, or aborted channels are released without awaiting.
  bool _socketReady = false;
  RpcPeer? _peer;
  StreamSubscription<dynamic>? _socketSub;
  StreamSubscription<RpcNotification>? _notificationSub;
  Timer? _reconnectTimer;
  Timer? _connectTimer;
  Future<void>? _inFlightConnect;
  Future<void>? _inFlightProbe;

  /// Monotonically incremented on each connect attempt, forced retry, liveness
  /// teardown, and disposal so an abandoned attempt can never clobber a newer
  /// connection's socket, state, or retry timer.
  int _connectEpoch = 0;

  /// Completed when the active establish attempt is superseded by [retryNow]
  /// or [dispose], unblocking any hung handshake or auth call immediately.
  Completer<void>? _attemptAbort;

  /// Completed by the next inbound frame while [verifyLiveness] is probing.
  Completer<void>? _inboundFrame;
  bool _establishing = false;
  int _reconnectAttempt = 0;

  /// Set by any connect failure or socket drop; the next successful
  /// establish emits [resynced] (stores may have missed events meanwhile)
  /// and clears it. Keeps the very first clean connect from emitting.
  bool _resyncNeeded = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Opens the socket (authenticating when [token] is set) and switches
  /// [connState] to connected. Idempotent: joins any connection attempt
  /// already in flight (including an automatic reconnect), or is a no-op when
  /// the client is already connected. A failed auth (or any other
  /// initial-connect failure) propagates as a [DaemonError] and leaves
  /// [connState] at [DaemonConnectionState.failed], with the backoff retry
  /// armed — the state self-heals to connected once the daemon answers.
  Future<void> connect() => _startEstablish(initial: true);

  Future<void> _startEstablish({
    required bool initial,
    bool forceRestart = false,
  }) {
    if (_disposed) return Future<void>.value();
    if (!forceRestart) {
      final Future<void>? inFlight = _inFlightConnect;
      if (inFlight != null) return inFlight;
    }
    if (connState.value == DaemonConnectionState.connected &&
        _channel != null &&
        _socketReady &&
        _peer != null) {
      return Future<void>.value();
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (forceRestart) {
      _abortInFlightAttempt();
    }
    final int epoch = ++_connectEpoch;
    final Completer<void> abort = Completer<void>();
    _attemptAbort = abort;
    late final Future<void> attempt;
    attempt = _establish(epoch: epoch, initial: initial, abort: abort)
        .whenComplete(() {
          if (identical(_inFlightConnect, attempt)) _inFlightConnect = null;
          if (identical(_attemptAbort, abort)) _attemptAbort = null;
        });
    _inFlightConnect = attempt;
    return attempt;
  }

  /// Aborts any active establish attempt synchronously so a replacement
  /// attempt can start right away without waiting on a wedged handshake.
  void _abortInFlightAttempt() {
    _connectTimer?.cancel();
    _connectTimer = null;
    final Completer<void>? abort = _attemptAbort;
    _attemptAbort = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    _establishing = false;
    unawaited(_tearDownSocket(graceful: false));
  }

  /// Races [operation] against [abort] and [connectTimeout] using a timer that
  /// is cancelled synchronously on completion, abort, or disposal.
  Future<T> _awaitConnectPhase<T>(
    Future<T> operation, {
    required Completer<void> abort,
    required String phase,
  }) {
    final Completer<T> result = Completer<T>();
    _connectTimer?.cancel();
    late final Timer timer;
    timer = Timer(connectTimeout, () {
      if (identical(_connectTimer, timer)) _connectTimer = null;
      if (!result.isCompleted) {
        result.completeError(
          TimeoutException('Daemon $phase timed out', connectTimeout),
        );
      }
    });
    _connectTimer = timer;
    void finish() {
      timer.cancel();
      if (identical(_connectTimer, timer)) _connectTimer = null;
    }

    operation.then(
      (T value) {
        finish();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        finish();
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    abort.future.then((void _) {
      finish();
      if (!result.isCompleted) {
        result.completeError(const DaemonConnectionError('connect aborted'));
      }
    });
    return result.future;
  }

  /// Establishes one connection. [initial] distinguishes the user-visible
  /// first connect (failures propagate, state ends `failed`) from automatic
  /// reconnects (failures only schedule another backoff retry). Either way a
  /// failure arms the backoff timer, so a `failed` initial connect still
  /// self-heals once the daemon comes up.
  Future<void> _establish({
    required int epoch,
    required bool initial,
    required Completer<void> abort,
  }) async {
    await _establishAttempt(epoch: epoch, initial: initial, abort: abort);
    if (!_disposed && epoch != _connectEpoch) {
      final Future<void>? replacement = _inFlightConnect;
      if (replacement != null) return replacement;
    }
  }

  Future<void> _establishAttempt({
    required int epoch,
    required bool initial,
    required Completer<void> abort,
  }) async {
    if (_disposed || epoch != _connectEpoch) return;
    _establishing = true;
    try {
      connState.value = initial
          ? DaemonConnectionState.connecting
          : DaemonConnectionState.reconnecting;
      await _openSocket(epoch: epoch, abort: abort);
      if (_disposed || epoch != _connectEpoch) return;
      final String? token = this.token;
      if (token != null) {
        final Future<Object?> authCall = _peer!.call(
          'auth.authenticate',
          <String, Object?>{'token': token},
        );
        await _awaitConnectPhase<Object?>(
          authCall,
          abort: abort,
          phase: 'authentication',
        );
        if (_disposed || epoch != _connectEpoch) return;
      }
      if (_disposed || epoch != _connectEpoch) return;
      connState.value = DaemonConnectionState.connected;
      _reconnectAttempt = 0;
      // Stores may already be displaying disk snapshots while the first
      // connection opens; they need authoritative catch-up on that connect too.
      if (!initial || _resyncNeeded || localHistory != null) {
        // Back on the wire after a gap: stores backfill what they missed
        // while offline (or while the first connect was failing).
        _resyncNeeded = false;
        _resyncController.add(null);
      }
    } on Object {
      if (_disposed || epoch != _connectEpoch) return;
      _resyncNeeded = true;
      await _tearDownSocket(graceful: false);
      if (_disposed || epoch != _connectEpoch) return;
      _scheduleReconnect();
      if (initial) connState.value = DaemonConnectionState.failed;
      rethrow;
    } finally {
      if (epoch == _connectEpoch) {
        _establishing = false;
      }
    }
  }

  /// Closes the current socket and its peer, if any. Idempotent; safe to run
  /// when the transport already shut the channel down on its own.
  ///
  /// Every live field is captured and cleared synchronously before any `await`
  /// so an older teardown can never clobber a replacement connection. When
  /// [graceful] is false (failed, timed-out, or aborted connections), the
  /// underlying channel closes without awaiting so a dead peer never stalls
  /// reconnection.
  Future<void> _tearDownSocket({bool graceful = true}) async {
    final DaemonFrameChannel? channel = _channel;
    final bool established = _socketReady;
    final StreamSubscription<RpcNotification>? notificationSub =
        _notificationSub;
    final StreamSubscription<dynamic>? socketSub = _socketSub;
    final RpcPeer? peer = _peer;
    _channel = null;
    _socketReady = false;
    _notificationSub = null;
    _socketSub = null;
    _peer = null;
    final bool awaitClose = graceful && established;
    if (channel != null && !awaitClose) {
      // The channel never completed its handshake or is already known dead:
      // start closing immediately without awaiting so any wedged HttpClient
      // aborts synchronously and reconnection never stalls.
      unawaited(_closeQuietly(channel));
    }
    if (notificationSub != null) await notificationSub.cancel();
    if (socketSub != null) await socketSub.cancel();
    if (peer != null) await peer.close();
    if (channel != null && awaitClose) {
      // The handshake completed, so a close frame normally round-trips quickly;
      // bound it anyway so disposal never hangs on a half-dead peer.
      try {
        await channel.close().timeout(_gracefulCloseTimeout);
      } on Object {
        // Already closed by the transport or peer unreachable.
      }
    }
  }

  /// Best-effort close that never blocks or propagates.
  Future<void> _closeQuietly(DaemonFrameChannel channel) async {
    try {
      await channel.close();
    } on Object {
      // The socket was never established or already closed; nothing to clean up.
    }
  }

  /// Opens a fresh socket and attaches a fresh [RpcPeer] to it.
  Future<void> _openSocket({
    required int epoch,
    required Completer<void> abort,
  }) async {
    final Uri uri = Uri.parse(url);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(
        url,
        'url',
        'WebSocket URL must use ws:// or wss://',
      );
    }
    final DaemonFrameChannel channel = _channelFactory(uri);
    _channel = channel;
    final Future<void> ready = channel.ready;
    // If the handshake resolves or errors after a timeout or forced retry,
    // close the orphaned socket quietly and absorb any late error.
    unawaited(
      ready.then(
        (void _) {
          if (_disposed ||
              epoch != _connectEpoch ||
              !identical(_channel, channel)) {
            unawaited(_closeQuietly(channel));
          }
        },
        onError: (Object _) {
          // Handled by the active attempt or ignored once superseded.
        },
      ),
    );
    await _awaitConnectPhase<void>(ready, abort: abort, phase: 'handshake');
    if (_disposed || epoch != _connectEpoch || !identical(_channel, channel)) {
      unawaited(_closeQuietly(channel));
      return;
    }
    _socketReady = true;
    final RpcPeer? previousPeer = _peer;
    _peer = null;
    unawaited(previousPeer?.close());
    final StreamSubscription<RpcNotification>? previousNotificationSub =
        _notificationSub;
    _notificationSub = null;
    if (previousNotificationSub != null) {
      await previousNotificationSub.cancel();
    }
    if (_disposed || epoch != _connectEpoch || !identical(_channel, channel)) {
      unawaited(_closeQuietly(channel));
      return;
    }

    final StreamController<Object?> incoming = StreamController<Object?>();
    final RpcPeer peer = RpcPeer(
      incoming: incoming.stream,
      send: (Object? message) {
        try {
          channel.add(jsonEncode(message));
        } on Object {
          // Socket may be closing underneath; the drop handler covers it.
        }
      },
    );
    _peer = peer;
    _notificationSub = peer.notifications.listen(_handleNotification);
    _socketSub = channel.stream.listen(
      (Object? data) {
        final Completer<void>? inbound = _inboundFrame;
        if (inbound != null && !inbound.isCompleted) inbound.complete();
        if (data is String) {
          try {
            incoming.add(jsonDecode(data));
          } on FormatException {
            // Malformed frame: ignore, mirroring RpcPeer's tolerance.
          }
        }
      },
      onError: (Object error) {
        _handleSocketClosed(
          channel,
          error: DaemonConnectionError(_transportErrorText(error)),
        );
        unawaited(incoming.close());
      },
      onDone: () {
        _handleSocketClosed(channel);
        unawaited(incoming.close());
      },
    );
  }

  /// The socket ended or errored: unblock pending calls and schedule a
  /// reconnect. During an in-flight [connect]/[reconnect] the establish flow
  /// itself disposes of the failure, so it does nothing here.
  void _handleSocketClosed(
    DaemonFrameChannel source, {
    DaemonConnectionError error = const DaemonConnectionError('peer closed'),
  }) {
    if (_disposed || !identical(_channel, source)) return;
    _channel = null;
    _socketReady = false;
    unawaited(_peer?.close(error));
    if (_establishing) return;
    _resyncNeeded = true;
    connState.value = DaemonConnectionState.reconnecting;
    _scheduleReconnect();
  }

  static String _transportErrorText(Object error) {
    if (error is PlatformException) {
      final String? message = error.message?.trim();
      return message == null || message.isEmpty ? error.code : message;
    }
    if (error is DaemonError) return error.message;
    return error.toString();
  }

  /// Arms the exponential-backoff retry timer. base * 2^n, capped at 15s.
  /// Touches no state: the caller owns the visible state (`reconnecting` for
  /// a dropped socket, `failed` until the retry starts for an initial
  /// connect), and the attempt itself flips to `reconnecting` when it runs.
  void _scheduleReconnect() {
    if (_disposed) return;
    final int attempt = _reconnectAttempt++;
    var ms = reconnectBase.inMilliseconds;
    for (
      var i = 0;
      i < attempt && ms < _maxReconnectDelay.inMilliseconds;
      i++
    ) {
      ms *= 2;
    }
    if (ms > _maxReconnectDelay.inMilliseconds) {
      ms = _maxReconnectDelay.inMilliseconds;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: ms < 1 ? 1 : ms), () {
      if (_disposed || _establishing) return;
      // A manual connect() may have won the race since this was scheduled.
      if (connState.value == DaemonConnectionState.connected) return;
      // Automatic retries are best-effort, but they still occupy the shared
      // single-flight future so a foreground action can join this exact
      // attempt instead of opening a competing socket.
      unawaited(
        _startEstablish(initial: false).catchError((Object _) {
          // The failed attempt scheduled the next retry before rethrowing.
        }),
      );
    });
  }

  @override
  bool get isConnected => connState.value == DaemonConnectionState.connected;

  /// Manual retry and resume hook: cancels any pending backoff attempt,
  /// resets the backoff counter, aborts any hung in-flight attempt (such as a
  /// handshake stalled while Android suspended or switched networks), and
  /// reconnects immediately. No-op when disposed or already connected.
  void retryNow() {
    if (_disposed) return;
    if (connState.value == DaemonConnectionState.connected) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    unawaited(
      _startEstablish(initial: true, forceRestart: true).catchError((Object _) {
        // The failed attempt scheduled the next retry before rethrowing.
      }),
    );
  }

  /// Probes a socket that believes itself connected and tears it down when
  /// the daemon does not answer within [livenessProbeTimeout].
  ///
  /// Device suspend can kill the TCP connection without delivering a close
  /// event: [connState] then stays `connected` while every call hangs and
  /// no resync ever runs. Call this on app resume; a failed probe flips to
  /// [DaemonConnectionState.reconnecting] and arms the backoff retry, whose
  /// successful establish emits [resynced] like any other reconnect. A
  /// merely slow answer is treated as dead too — the reconnect it triggers
  /// is cheap, unlike a stale socket. `daemon.info` is answered pre-auth,
  /// so the probe works even if the daemon forgot the authentication.
  ///
  /// Any inbound frame during the probe also proves the socket alive: the
  /// probe's answer can queue behind large responses (e.g. download chunks
  /// that resume when a native save dialog hands focus back), and tearing
  /// that socket down would fail the healthy transfer with "peer closed".
  Future<void> verifyLiveness() {
    if (_disposed || connState.value != DaemonConnectionState.connected) {
      return Future<void>.value();
    }
    final Future<void>? inFlight = _inFlightProbe;
    if (inFlight != null) return inFlight;
    final RpcPeer? peer = _peer;
    if (peer == null || !_socketReady) return Future<void>.value();
    final int epoch = _connectEpoch;
    late final Future<void> probe;
    probe = _runLivenessProbe(peer: peer, epoch: epoch).whenComplete(() {
      if (identical(_inFlightProbe, probe)) _inFlightProbe = null;
    });
    _inFlightProbe = probe;
    return probe;
  }

  Future<void> _runLivenessProbe({
    required RpcPeer peer,
    required int epoch,
  }) async {
    final Completer<void> inbound = Completer<void>();
    _inboundFrame = inbound;
    try {
      await Future.any<Object?>(<Future<Object?>>[
        peer.call('daemon.info'),
        inbound.future,
      ]).timeout(livenessProbeTimeout);
    } on Object {
      // A genuine drop or reconnect raced the probe: its handler already tore
      // the socket down and armed its own reconnect; do not double up.
      if (_disposed ||
          epoch != _connectEpoch ||
          connState.value != DaemonConnectionState.connected) {
        return;
      }
      final int teardownEpoch = ++_connectEpoch;
      _resyncNeeded = true;
      _reconnectAttempt = 0;
      connState.value = DaemonConnectionState.reconnecting;
      await _tearDownSocket(graceful: false);
      if (_disposed || teardownEpoch != _connectEpoch) return;
      _scheduleReconnect();
    } finally {
      if (identical(_inboundFrame, inbound)) _inboundFrame = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _connectEpoch++;
    _connectTimer?.cancel();
    _connectTimer = null;
    final Completer<void>? abort = _attemptAbort;
    _attemptAbort = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _tearDownSocket();
    if (_ownsNotifications) await _notifications.close();
    connState.dispose();
  }

  // ---------------------------------------------------------------------
  // Inbound notifications
  // ---------------------------------------------------------------------

  void _handleNotification(RpcNotification notification) {
    if (_disposed) return;
    final Map<String, Object?> params = notification.params;
    switch (notification.method) {
      case 'session.event':
        final Object? sessionId = params['sessionId'];
        final Object? event = params['event'];
        if (sessionId is String && event is Map) {
          // The daemon stamps seq/timestamp into the event itself; fall back
          // to the envelope-level fields for lenient servers.
          final Map<String, Object?> eventJson = Map<String, Object?>.from(
            event,
          );
          eventJson.putIfAbsent('seq', () => params['seq']);
          eventJson.putIfAbsent('timestamp', () => params['timestamp']);
          try {
            final decoded = SessionEvent.fromJson(eventJson);
            _sessionEventFeed.add((sessionId: sessionId, event: decoded));
            _cacheEvent(sessionId, decoded);
          } on Object {
            // Malformed event: drop rather than kill the notification feed.
          }
        }
      case 'session.created':
      case 'session.updated':
        // Decode the full snapshot, including optional preparationStep.
        final Object? session = params['session'];
        if (session is Map) {
          try {
            final decoded = Session.fromJson(
              Map<String, Object?>.from(session),
            );
            _sessionUpdatesController.add(decoded);
            if (localHistory != null) {
              _cacheOperation(
                localHistory!.writeIndex('sessions', [decoded.toJson()]),
              );
            }
          } on Object {
            // Malformed session: drop.
          }
        }
      case 'session.removed':
        final Object? sessionId = params['sessionId'];
        if (sessionId is String) {
          _sessionRemovalsController.add(sessionId);
          if (localHistory != null) {
            _cacheOperation(
              localHistory!.writeIndex('sessions', [], removeId: sessionId),
            );
          }
          if (localHistory != null) {
            _cacheOperation(localHistory!.remove(sessionId));
          }
        }
      case 'session.queue':
        final Object? queue = params['queue'];
        if (queue is Map) {
          try {
            _notifications.queues.add(
              SessionQueue.fromJson(Map<String, Object?>.from(queue)),
            );
          } on Object {
            // Malformed queue: drop.
          }
        }
      case 'git.changed':
        final Object? projectId = params['projectId'];
        if (projectId is String) {
          _gitChangedController.add(projectId);
        }
      case 'projects.changed':
        _projectsChangedController.add(null);
      case 'note.updated':
        final Object? note = params['note'];
        if (note is Map) {
          try {
            _notifications.notes.add(
              SessionNote.fromJson(note.cast<String, Object?>()),
            );
          } on Object {
            // Malformed note: drop.
          }
        }
      case 'note.removed':
        final Object? noteId = params['noteId'];
        if (noteId is String) {
          _notifications.noteRemovals.add(noteId);
        }
    }
  }

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  @override
  Stream<SessionEvent> sessionEvents(String sessionId) => _sessionEventFeed
      .stream
      .where(
        (({String sessionId, SessionEvent event}) entry) =>
            entry.sessionId == sessionId,
      )
      .map((({String sessionId, SessionEvent event}) entry) => entry.event);

  @override
  Stream<Session> get sessionUpdates => _sessionUpdatesController.stream;

  @override
  Stream<String> get sessionRemovals => _sessionRemovalsController.stream;

  @override
  Stream<SessionQueue> get queueUpdates => _notifications.queues.stream;

  @override
  Stream<String> get gitChanged => _gitChangedController.stream;

  @override
  Stream<void> get projectsChanged => _projectsChangedController.stream;

  @override
  Stream<void> get resynced => _resyncController.stream;

  @override
  Stream<SessionNote> get noteUpdates => _notifications.notes.stream;

  @override
  Stream<String> get noteRemovals => _notifications.noteRemovals.stream;

  // ---------------------------------------------------------------------
  // Daemon / projects
  // ---------------------------------------------------------------------

  @override
  Future<DaemonInfo> info() async {
    final Object? result = await _requirePeer().call('daemon.info');
    return DaemonInfo.fromJson(_resultMap(result));
  }

  @override
  Future<List<HarnessInfo>> listHarnesses() async {
    final Object? result = await _requirePeer().call('harnesses.list');
    return _decodeList(_resultField(result, 'harnesses'), HarnessInfo.fromJson);
  }

  @override
  Future<HarnessInfo> updateHarness(String id) async {
    final Object? result = await _requirePeer().call(
      'harnesses.update',
      <String, Object?>{'id': id},
    );
    return HarnessInfo.fromJson(_resultMap(_resultField(result, 'harness')));
  }

  @override
  Future<List<String>> listEnvironmentNames() async {
    final Object? result = await _requirePeer().call('environment.list');
    return (_resultField(result, 'names') as List<Object?>)
        .cast<String>()
        .toList(growable: false);
  }

  @override
  Future<List<String>> updateEnvironment({
    Map<String, String> set = const <String, String>{},
    List<String> remove = const <String>[],
  }) async {
    final Object? result = await _requirePeer().call(
      'environment.update',
      <String, Object?>{'set': set, 'remove': remove},
    );
    return (_resultField(result, 'names') as List<Object?>)
        .cast<String>()
        .toList(growable: false);
  }

  @override
  Future<List<Project>> listProjects() async {
    if (!isConnected && localHistory != null) {
      final saved = await localHistory!.readIndex('projects');
      if (saved != null) return saved.map(Project.fromJson).toList();
    }
    final Object? result = await _requirePeer().call('projects.list');
    final projects = _decodeList(
      _resultField(result, 'projects'),
      Project.fromJson,
    );
    if (localHistory != null) {
      _cacheOperation(
        localHistory!.writeIndex(
          'projects',
          projects.map((p) => p.toJson()).toList(),
          replace: true,
        ),
      );
    }
    return projects;
  }

  @override
  Future<Project> addProject(String path, {String? name}) async {
    final Object? result = await _requirePeer().call(
      'projects.add',
      <String, Object?>{'path': path, 'name': ?name},
    );
    return Project.fromJson(_resultMap(_resultField(result, 'project')));
  }

  @override
  Future<void> removeProject(String id) async {
    await _requirePeer().call('projects.remove', <String, Object?>{'id': id});
  }
  // ---------------------------------------------------------------------
  // MCP servers
  // ---------------------------------------------------------------------

  @override
  Future<List<McpServerProfile>> listMcpServers() async {
    final Object? result = await _requirePeer().call('mcp.list');
    return _decodeList(
      _resultField(result, 'servers'),
      McpServerProfile.fromJson,
    );
  }

  @override
  Future<McpServerProfile> createMcpServer({
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? projectId,
    List<String>? projectIds,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    final Object? result = await _requirePeer().call(
      'mcp.create',
      <String, Object?>{
        'name': name,
        'transport': transport.wire,
        'enabled': enabled,
        'projectId': ?(projectIds == null ? projectId : projectIds.firstOrNull),
        'projectIds': ?projectIds,
        'command': ?command,
        'args': args,
        'url': ?url,
        'secrets': secrets,
        'authType': authType.wire,
        'oauthClientId': ?oauthClientId,
        'oauthClientSecret': ?oauthClientSecret,
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> updateMcpServer({
    required String id,
    required String name,
    required McpTransport transport,
    required bool enabled,
    required String? projectId,
    List<String>? projectIds,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    List<String> removeSecretNames = const <String>[],
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  }) async {
    final Object? result = await _requirePeer().call(
      'mcp.update',
      <String, Object?>{
        'id': id,
        'name': name,
        'transport': transport.wire,
        'enabled': enabled,
        'projectId': projectIds == null ? projectId : projectIds.firstOrNull,
        'projectIds': ?projectIds,
        'command': ?command,
        'args': args,
        'url': ?url,
        'secrets': secrets,
        'removeSecretNames': removeSecretNames,
        'authType': authType.wire,
        'oauthClientId': ?oauthClientId,
        'oauthClientSecret': ?oauthClientSecret,
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<void> deleteMcpServer(String id) async {
    await _requirePeer().call('mcp.delete', <String, Object?>{'id': id});
  }

  @override
  Future<McpOAuthFlow> beginMcpOAuth(String id, {Uri? redirectUri}) async {
    final Uri callback = redirectUri ?? _daemonOAuthRedirectUri();
    final Object? result = await _requirePeer().call(
      'mcp.oauth.begin',
      <String, Object?>{'id': id, 'redirectUri': callback.toString()},
    );
    return McpOAuthFlow.fromJson(_resultMap(_resultField(result, 'flow')));
  }

  Uri _daemonOAuthRedirectUri() {
    final Uri endpoint = Uri.parse(url);
    final bool secure = endpoint.scheme == 'wss';
    if (!secure && !_isLoopbackOAuthHost(endpoint.host)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'MCP OAuth for a remote daemon requires a wss:// endpoint with '
        'HTTPS /oauth/callback routing, or OAuth 2.1 (localhost)',
      );
    }
    return endpoint.replace(
      scheme: secure ? 'https' : 'http',
      // Canonicalize local IPv4 aliases because authorization servers may
      // recognize only numeric loopback redirect URIs. IPv6 stays on ::1.
      host: secure
          ? endpoint.host
          : endpoint.host == '::1'
          ? '::1'
          : '127.0.0.1',
      path: '/oauth/callback',
      query: null,
      fragment: null,
    );
  }

  bool _isLoopbackOAuthHost(String host) {
    final String normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '0:0:0:0:0:0:0:1' ||
        normalized.startsWith('127.');
  }

  @override
  Future<McpServerProfile> completeMcpOAuth(
    String id,
    String flowId,
    Uri callbackUri,
  ) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.complete',
      <String, Object?>{
        'id': id,
        'flowId': flowId,
        'callbackUri': callbackUri.toString(),
      },
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> mcpOAuthStatus(String id, String flowId) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.status',
      <String, Object?>{'id': id, 'flowId': flowId},
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  @override
  Future<McpServerProfile> disconnectMcpOAuth(String id) async {
    final Object? result = await _requirePeer().call(
      'mcp.oauth.disconnect',
      <String, Object?>{'id': id},
    );
    return McpServerProfile.fromJson(
      _resultMap(_resultField(result, 'server')),
    );
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  @override
  Future<List<Session>> findSessionsByPullRequest(String url) async {
    final Object? result = await _requirePeer().call(
      'sessions.findByPullRequest',
      <String, Object?>{'url': url},
    );
    return _decodeList(_resultField(result, 'sessions'), Session.fromJson);
  }

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    if (!isConnected && localHistory != null) {
      final saved = await localHistory!.readIndex('sessions');
      if (saved != null) {
        return saved
            .map(Session.fromJson)
            .where(
              (s) =>
                  (projectId == null || s.projectId == projectId) &&
                  (includeArchived || !s.archived),
            )
            .toList();
      }
    }
    final Object? result = await _requirePeer().call(
      'sessions.list',
      <String, Object?>{
        'projectId': ?projectId,
        'includeArchived': includeArchived,
      },
    );
    final sessions = _decodeList(
      _resultField(result, 'sessions'),
      Session.fromJson,
    );
    if (localHistory != null) {
      _cacheOperation(
        localHistory!.writeIndex(
          'sessions',
          sessions.map((s) => s.toJson()).toList(),
          replace: projectId == null && includeArchived,
        ),
      );
    }
    return sessions;
  }

  @override
  Future<SessionSearchPage> searchSessions({
    required String query,
    String? projectId,
    bool includeArchived = false,
    int limit = 50,
    SessionSearchCursor? cursor,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.search',
      <String, Object?>{
        'query': query,
        'projectId': ?projectId,
        'includeArchived': includeArchived,
        'limit': limit,
        'cursor': ?cursor?.toJson(),
      },
    );
    return SessionSearchPage.fromJson(result as Map<String, Object?>);
  }

  @override
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    String? title,
    String? baseBranch,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
    bool shortPrompt = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.create',
      <String, Object?>{
        'projectId': projectId,
        'providerId': providerId,
        'model': ?model,
        'title': ?title,
        'baseBranch': ?baseBranch,
        'sandboxMode': ?sandboxMode?.wire,
        if (yolo) 'yolo': true,
        if (shortPrompt) 'shortPrompt': true,
      },
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> forkSession(String sessionId, int? seq) async {
    final Object? result = await _requirePeer().call(
      'sessions.fork',
      <String, Object?>{'sessionId': sessionId, 'seq': ?seq},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> retryMessage(String sessionId, int seq) async {
    await _requirePeer().call('sessions.retry', <String, Object?>{
      'sessionId': sessionId,
      'seq': seq,
    });
  }

  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) async {
    await _requirePeer().call('sessions.send', <String, Object?>{
      'sessionId': sessionId,
      'text': text,
      // PROTOCOL.md: the wire param is omitted entirely when empty; the
      // daemon rejects `sessions.send` without text *and* without
      // attachments, so clients never send a bare attachment list here.
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((OutgoingAttachment a) => a.toJson())
            .toList(growable: false),
    });
  }

  @override
  Future<QueuedMessage?> queueMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.send',
      <String, Object?>{
        'sessionId': sessionId,
        'text': text,
        if (attachments.isNotEmpty)
          'attachments': attachments
              .map((OutgoingAttachment a) => a.toJson())
              .toList(growable: false),
        'queue': true,
      },
    );
    final Object? queued = result is Map ? result['queued'] : null;
    return queued is Map
        ? QueuedMessage.fromJson(Map<String, Object?>.from(queued))
        : null;
  }

  @override
  Future<SessionQueue> sessionQueue(String sessionId) async {
    final Object? result = await _requirePeer().call(
      'sessions.queue',
      <String, Object?>{'sessionId': sessionId},
    );
    return SessionQueue.fromJson(_resultMap(_resultField(result, 'queue')));
  }

  @override
  Future<QueuedMessage> unqueueMessage(
    String sessionId,
    String messageId,
  ) async {
    final Object? result = await _requirePeer().call(
      'sessions.unqueue',
      <String, Object?>{'sessionId': sessionId, 'messageId': messageId},
    );
    return QueuedMessage.fromJson(_resultMap(_resultField(result, 'message')));
  }

  @override
  Future<bool> sendQueuedMessage(String sessionId, String messageId) async {
    final Object? result = await _requirePeer().call(
      'sessions.sendQueued',
      <String, Object?>{'sessionId': sessionId, 'messageId': messageId},
    );
    return _resultField(result, 'steered') == true;
  }

  @override
  Future<List<NativeCommand>> listCommands(String sessionId) async {
    final Object? result = await _requirePeer().call(
      'sessions.commands',
      <String, Object?>{'sessionId': sessionId},
    );
    final Object? raw = _resultField(result, 'commands');
    return (raw as List<Object?>)
        .map((Object? value) => NativeCommand.fromJson(_resultMap(value)))
        .toList(growable: false);
  }

  @override
  Future<void> runCommand(
    String sessionId,
    String name, {
    String arguments = '',
  }) async {
    await _requirePeer().call('sessions.command', <String, Object?>{
      'sessionId': sessionId,
      'name': name,
      if (arguments.isNotEmpty) 'arguments': arguments,
    });
  }

  @override
  Future<AttachmentData> readAttachment(
    String sessionId,
    String attachmentId,
  ) async {
    final Object? result = await _requirePeer().call(
      'attachments.read',
      <String, Object?>{'sessionId': sessionId, 'attachmentId': attachmentId},
    );
    return AttachmentData.fromJson(
      _resultMap(_resultField(result, 'attachment')),
    );
  }

  @override
  Future<String> beginUpload(int size) async {
    final Object? result = await _requirePeer().call(
      'uploads.begin',
      <String, Object?>{'size': size},
    );
    return _resultField(result, 'uploadId')! as String;
  }

  @override
  Future<int> appendUpload(String uploadId, int offset, Uint8List bytes) async {
    final Object? result = await _requirePeer().call(
      'uploads.append',
      <String, Object?>{
        'uploadId': uploadId,
        'offset': offset,
        'data': base64Encode(bytes),
      },
    );
    return _resultField(result, 'received')! as int;
  }

  @override
  Future<void> cancelUpload(String uploadId) async {
    await _requirePeer().call('uploads.cancel', <String, Object?>{
      'uploadId': uploadId,
    });
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    await _requirePeer().call('sessions.cancel', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  @override
  Future<Session> renameSession(String sessionId, String title) async {
    final Object? result = await _requirePeer().call(
      'sessions.rename',
      <String, Object?>{'sessionId': sessionId, 'title': title},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> pinSession(String sessionId, bool pinned) async {
    final Object? result = await _requirePeer().call(
      'sessions.pin',
      <String, Object?>{'sessionId': sessionId, 'pinned': pinned},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> archiveSession(String sessionId, bool archived) async {
    final Object? result = await _requirePeer().call(
      'sessions.archive',
      <String, Object?>{'sessionId': sessionId, 'archived': archived},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<ArchivePreview> previewArchive() async {
    final Object? result = await _requirePeer().call(
      'sessions.archivePreview',
      <String, Object?>{},
    );
    return ArchivePreview.fromJson(_resultMap(_resultField(result, 'archive')));
  }

  @override
  Future<ClearArchiveResult> clearArchive(List<String> sessionIds) async =>
      ClearArchiveResult.fromJson(
        _resultMap(
          await _requirePeer().call('sessions.clearArchive', <String, Object?>{
            'sessionIds': sessionIds,
          }),
        ),
      );

  @override
  Future<Session> acknowledgeCompletion(
    String sessionId,
    int completionRevision,
  ) async {
    final Object? result = await _requirePeer().call(
      'sessions.acknowledgeCompletion',
      <String, Object?>{
        'sessionId': sessionId,
        'completionRevision': completionRevision,
      },
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _requirePeer().call('sessions.delete', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  @override
  Future<Session> setModel(String sessionId, String model) async {
    final Object? result = await _requirePeer().call(
      'sessions.setModel',
      <String, Object?>{'sessionId': sessionId, 'model': model},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<Session> setThinkingLevel(String sessionId, String level) async {
    final Object? result = await _requirePeer().call(
      'sessions.setThinkingLevel',
      <String, Object?>{'sessionId': sessionId, 'level': level},
    );
    return Session.fromJson(_resultMap(_resultField(result, 'session')));
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    if (!isConnected) {
      final saved = await savedHistory(
        sessionId,
        limit: limit,
        beforeSeq: beforeSeq,
      );
      if (saved != null) return (events: saved.events, hasMore: saved.hasMore);
    }
    final page = await _remoteHistory(
      sessionId,
      limit: limit,
      beforeSeq: beforeSeq,
    );
    // Rewinds invalidate existing saved messages; history text itself is never cached.
    for (final rewind in page.events.whereType<HistoryRewoundEvent>()) {
      _cacheEvent(sessionId, rewind);
    }
    return page;
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore, bool complete})?>
  savedHistory(String sessionId, {required int limit, int? beforeSeq}) async {
    final saved = await localHistory?.read(sessionId);
    if (saved == null) return null;
    final events = saved.events
        .where((e) => beforeSeq == null || e.seq! < beforeSeq)
        .toList();
    final start = events.length > limit ? events.length - limit : 0;
    return (
      events: events.sublist(start),
      hasMore: start > 0,
      complete: saved.complete,
    );
  }

  Future<({List<SessionEvent> events, bool hasMore})> _remoteHistory(
    String sessionId, {
    required int limit,
    int? beforeSeq,
    SessionHistoryDetail? detail,
  }) async {
    final Object? result = await _requirePeer().call(
      'sessions.history',
      <String, Object?>{
        'sessionId': sessionId,
        'limit': limit,
        'beforeSeq': ?beforeSeq,
        if ((detail ?? historyDetail) != SessionHistoryDetail.full)
          'detail': (detail ?? historyDetail).wire,
      },
    );
    return (
      events: _decodeList(
        _resultField(result, 'events'),
        SessionEvent.fromJson,
      ),
      hasMore: _resultField(result, 'hasMore') == true,
    );
  }

  @override
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId, {
    List<UserQuestionAnswer>? answers,
  }) async {
    await _requirePeer().call('sessions.respondPermission', <String, Object?>{
      'sessionId': sessionId,
      'requestId': requestId,
      'optionId': optionId,
      if (answers != null) 'answers': answers.map((e) => e.toJson()).toList(),
    });
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles(
    String projectId, [
    String path = '.',
  ]) async {
    final Object? result = await _requirePeer().call(
      'fs.list',
      <String, Object?>{'projectId': projectId, 'path': path},
    );
    return _decodeList(_resultField(result, 'entries'), FileEntry.fromJson);
  }

  @override
  Future<FileReadResult> readFile(
    String projectId,
    String path, {
    int? maxBytes,
  }) async {
    final Object? result = await _requirePeer().call(
      'fs.read',
      <String, Object?>{
        'projectId': projectId,
        'path': path,
        'maxBytes': ?maxBytes,
      },
    );
    return FileReadResult.fromJson(_resultMap(result));
  }

  @override
  Future<FileDownloadChunk> downloadFileChunk(
    String sessionId,
    String path, {
    required int offset,
    String? revision,
  }) async {
    final Object? result = await _requirePeer().call(
      'fs.downloadChunk',
      <String, Object?>{
        'sessionId': sessionId,
        'path': path,
        'offset': offset,
        'revision': ?revision,
      },
    );
    return FileDownloadChunk.fromJson(_resultMap(result));
  }

  @override
  Future<FileDownload> downloadFile(String sessionId, String path) async {
    final Object? result = await _requirePeer().call(
      'fs.download',
      <String, Object?>{'sessionId': sessionId, 'path': path},
    );
    return FileDownload.fromJson(_resultMap(result));
  }

  // ---------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------

  @override
  Future<GitStatus> gitStatus(String projectId, {String? sessionId}) async {
    final Object? result = await _requirePeer().call(
      'git.status',
      <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId},
    );
    return GitStatus.fromJson(_resultMap(_resultField(result, 'status')));
  }

  @override
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.diff',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'path': ?path,
        'staged': staged,
      },
    );
    return _decodeList(_resultField(result, 'diffs'), GitDiff.fromJson);
  }

  @override
  Future<void> gitPrefetch(String projectId, String branch) async {
    await _requirePeer().call('git.prefetch', <String, Object?>{
      'projectId': projectId,
      'branch': branch,
    });
  }

  @override
  Future<List<Branch>> gitBranches(
    String projectId, {
    String? sessionId,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.branches',
      <String, Object?>{'projectId': projectId, 'sessionId': ?sessionId},
    );
    return _decodeList(_resultField(result, 'branches'), Branch.fromJson);
  }

  @override
  Future<void> gitCheckout(
    String projectId,
    String branch, {
    String? sessionId,
  }) async {
    await _requirePeer().call('git.checkout', <String, Object?>{
      'projectId': projectId,
      'sessionId': ?sessionId,
      'branch': branch,
    });
  }

  @override
  Future<String> gitCommit(
    String projectId,
    String message, {
    String? sessionId,
    bool stageAll = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.commit',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'message': message,
        'stageAll': stageAll,
      },
    );
    return _resultField(result, 'commitHash')! as String;
  }

  @override
  Future<void> gitPush(String projectId, {String? sessionId}) async {
    await _requirePeer().call('git.push', <String, Object?>{
      'projectId': projectId,
      'sessionId': ?sessionId,
    });
  }

  @override
  Future<MergeResult> gitMergeToBase(
    String projectId, {
    required String sessionId,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.mergeToBase',
      <String, Object?>{'projectId': projectId, 'sessionId': sessionId},
    );
    return MergeResult.fromJson(_resultMap(_resultField(result, 'merge')));
  }

  @override
  Future<RebaseResult> gitRebaseOntoBase(
    String projectId, {
    required String sessionId,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.rebaseOntoBase',
      <String, Object?>{'projectId': projectId, 'sessionId': sessionId},
    );
    return RebaseResult.fromJson(_resultMap(_resultField(result, 'rebase')));
  }

  @override
  Future<String> gitCreatePr(
    String projectId, {
    String? sessionId,
    String? title,
    String? body,
    String? base,
    bool draft = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'git.createPullRequest',
      <String, Object?>{
        'projectId': projectId,
        'sessionId': ?sessionId,
        'title': ?title,
        'body': ?body,
        'base': ?base,
        'draft': draft,
      },
    );
    return _resultField(result, 'url')! as String;
  }

  @override
  Future<List<SessionGitSummary>> gitSessionSummaries(String projectId) async {
    final Object? result = await _requirePeer().call(
      'git.sessionSummaries',
      <String, Object?>{'projectId': projectId},
    );
    return _decodeList(
      _resultField(result, 'summaries'),
      SessionGitSummary.fromJson,
    );
  }

  @override
  Future<List<SessionNote>> listNotes({
    String? sessionId,
    bool open = false,
  }) async {
    final Object? result = await _requirePeer().call(
      'notes.list',
      <String, Object?>{'sessionId': ?sessionId, if (open) 'open': true},
    );
    return _decodeList(_resultField(result, 'notes'), SessionNote.fromJson);
  }

  @override
  Future<SessionNote> createNote(String sessionId, String text) async {
    final Object? result = await _requirePeer().call(
      'notes.create',
      <String, Object?>{'sessionId': sessionId, 'text': text},
    );
    return SessionNote.fromJson(_resultMap(_resultField(result, 'note')));
  }

  @override
  Future<SessionNote> updateNote(
    String noteId, {
    String? text,
    bool? done,
  }) async {
    final Object? result = await _requirePeer().call(
      'notes.update',
      <String, Object?>{'noteId': noteId, 'text': ?text, 'done': ?done},
    );
    return SessionNote.fromJson(_resultMap(_resultField(result, 'note')));
  }

  @override
  Future<void> deleteNote(String noteId) async {
    await _requirePeer().call('notes.delete', <String, Object?>{
      'noteId': noteId,
    });
  }

  // ---------------------------------------------------------------------
  // Result decoding helpers
  // ---------------------------------------------------------------------

  RpcPeer _requirePeer() {
    if (_disposed) {
      throw const DaemonConnectionError('daemon client disposed');
    }
    final RpcPeer? peer = _peer;
    if (peer == null || connState.value != DaemonConnectionState.connected) {
      throw const DaemonConnectionError('daemon client is not connected');
    }
    return peer;
  }

  static Map<String, Object?> _resultMap(Object? raw) {
    if (raw is Map) return Map<String, Object?>.from(raw);
    throw DaemonError(kErrInternal, 'malformed result: expected an object');
  }

  static Object? _resultField(Object? result, String key) {
    final Map<String, Object?> map = _resultMap(result);
    if (!map.containsKey(key)) {
      throw DaemonError(kErrInternal, 'malformed result: missing "$key"');
    }
    return map[key];
  }

  static List<T> _decodeList<T>(
    Object? raw,
    T Function(Map<String, Object?>) fromJson,
  ) {
    if (raw is! List) {
      throw DaemonError(kErrInternal, 'malformed result: expected a list');
    }
    return <T>[for (final Object? item in raw) fromJson(_resultMap(item))];
  }
}
