import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/daemon_client.dart';
import 'package:speeddial_app/src/api/ws_daemon_client.dart';
import 'package:speeddial_app/src/state/chat_store.dart';

/// Polls until [condition] holds, failing the test after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// An in-process daemon speaking the protocol through [RpcPeer] over a real
/// `dart:io` WebSocket: registers `auth.authenticate`, `daemon.info`,
/// `projects.list`, `sessions.send` and `sessions.history`, and pushes
/// `session.event` notifications on a timer for each accepted connection.
class TestDaemonServer {
  TestDaemonServer._(this.server);

  final HttpServer server;
  final List<WebSocket> sockets = <WebSocket>[];
  final List<RpcPeer> peers = <RpcPeer>[];
  final List<Timer> timers = <Timer>[];
  final Map<String, List<Map<String, Object?>>> history =
      <String, List<Map<String, Object?>>>{};

  /// Every `sessions.send` params object received, in call order.
  final List<Map<String, Object?>> sends = <Map<String, Object?>>[];

  /// Every `mcp.oauth.begin` params object received, in call order.
  final List<Map<String, Object?>> oauthBegins = <Map<String, Object?>>[];

  /// Attachment payloads keyed by session id then attachment id, served by
  /// the `attachments.read` handler.
  final Map<String, Map<String, Map<String, Object?>>> attachments =
      <String, Map<String, Map<String, Object?>>>{};

  int connectionCount = 0;
  int seq = 0;

  static Future<TestDaemonServer> start({String token = 'secret', int port = 0}) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    final TestDaemonServer daemon = TestDaemonServer._(server);
    server.listen((HttpRequest request) => daemon._handle(request, token));
    return daemon;
  }

  String get url => 'ws://127.0.0.1:${server.port}/ws';

  Future<void> _handle(HttpRequest request, String token) async {
    final WebSocket socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    connectionCount++;
    final RpcPeer peer = RpcPeer(
      incoming: socket.map((Object? message) => jsonDecode(message as String)),
      send: (Object? message) {
        try {
          socket.add(jsonEncode(message));
        } on Object {
          // Socket is gone; the peer is being torn down.
        }
      },
    );
    peers.add(peer);

    peer.registerHandler(
      'auth.authenticate',
      (Map<String, Object?> params) {
        if (params['token'] != token) {
          throw DaemonError(kErrUnauthenticated, 'bad token');
        }
        return <String, Object?>{'ok': true, 'daemon': daemonInfoJson()};
      },
    );
    peer.registerHandler('daemon.info', (Map<String, Object?> _) {
      return daemonInfoJson();
    });
    peer.registerHandler('projects.list', (Map<String, Object?> _) {
      return <String, Object?>{'projects': <Object?>[projectJson()]};
    });
    peer.registerHandler('mcp.oauth.begin', (Map<String, Object?> params) {
      oauthBegins.add(params);
      return <String, Object?>{
        'flow': <String, Object?>{
          'flowId': 'flow-1',
          'authorizationUrl': 'https://auth.example/authorize',
        },
      };
    });
    peer.registerHandler('sessions.send', (Map<String, Object?> params) {
      sends.add(params);
      if (params['text'] == 'boom') {
        throw DaemonError(kErrConflict, 'turn already running');
      }
      return <String, Object?>{};
    });
    peer.registerHandler('attachments.read', (Map<String, Object?> params) {
      final String sessionId = params['sessionId']! as String;
      final String attachmentId = params['attachmentId']! as String;
      final Map<String, Object?>? stored =
          attachments[sessionId]?[attachmentId];
      if (stored == null) {
        throw DaemonError(kErrNotFound, 'unknown attachment: $attachmentId');
      }
      return <String, Object?>{'attachment': stored};
    });
    peer.registerHandler('sessions.history', (Map<String, Object?> params) {
      final String sessionId = params['sessionId']! as String;
      final int limit = (params['limit'] as int?) ?? 200;
      final int? beforeSeq = params['beforeSeq'] as int?;
      final List<Map<String, Object?>> all =
          history[sessionId] ?? const <Map<String, Object?>>[];
      // Strictly below beforeSeq, ascending by seq; newest `limit` kept.
      final List<Map<String, Object?>> filtered =
          beforeSeq == null ? all : <Map<String, Object?>>[
        for (final Map<String, Object?> event in all)
          if ((event['seq']! as int) < beforeSeq) event,
      ];
      final bool hasMore = filtered.length > limit;
      return <String, Object?>{
        'events': hasMore
            ? <Object?>[...filtered.sublist(filtered.length - limit)]
            : <Object?>[...filtered],
        'hasMore': hasMore,
      };
    });

    // Liveliness: push `session.event` notifications while this socket lives.
    final Stopwatch firstPush = Stopwatch()..start();
    final Timer timer = Timer.periodic(
      const Duration(milliseconds: 20),
      (Timer _) {
        if (firstPush.elapsed < const Duration(milliseconds: 30)) return;
        pushEvent('sess-1');
      },
    );
    timers.add(timer);
    socket.done.whenComplete(() {
      unawaited(peer.close());
      timer.cancel();
    });
  }

  Map<String, Object?> daemonInfoJson() => <String, Object?>{
        'version': '1.2.3',
        'protocolVersion': 1,
        'authRequired': true,
        'providers': <Object?>[
          <String, Object?>{
            'id': 'omp',
            'name': 'OMP Agent',
            'available': true,
            'command': 'omp',
            'models': <Object?>['omp-default'],
          },
        ],
      };

  Map<String, Object?> projectJson() => <String, Object?>{
        'id': 'proj-1',
        'name': 'Demo',
        'path': '/demo',
        'addedAt': '2026-01-01T00:00:00.000Z',
        'lastActiveAt': '2026-01-01T00:00:00.000Z',
      };

  Map<String, Object?> sessionJson({String status = 'idle'}) =>
      <String, Object?>{
        'id': 'sess-1',
        'projectId': 'proj-1',
        'providerId': 'omp',
        'title': 'Build the feature',
        'status': status,
        'mode': 'build',
        'model': 'omp-default',
        'cwd': '/demo',
        'archived': false,
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:00:00.000Z',
      };

  /// Pushes a `session.event` notification on the most recent connection.
  void pushEvent(String sessionId, {String? text}) {
    if (peers.isEmpty) return;
    final int nextSeq = ++seq;
    final Map<String, Object?> event = <String, Object?>{
      'type': 'userMessage',
      'text': text ?? 'msg $nextSeq',
      'seq': nextSeq,
    };
    history
        .putIfAbsent(sessionId, () => <Map<String, Object?>>[])
        .add(event);
    peers.last.notify('session.event', <String, Object?>{
      'sessionId': sessionId,
      'seq': nextSeq,
      'event': event,
    });
  }

  void pushSessionUpdated({String status = 'running'}) {
    if (peers.isEmpty) return;
    peers.last.notify(
      'session.updated',
      <String, Object?>{'session': sessionJson(status: status)},
    );
  }

  void pushSessionRemoved(String sessionId) {
    if (peers.isEmpty) return;
    peers.last
        .notify('session.removed', <String, Object?>{'sessionId': sessionId});
  }

  void pushProjectsChanged() {
    if (peers.isEmpty) return;
    peers.last.notify('projects.changed', <String, Object?>{});
  }

  /// Server-side socket drop: closes the most recent accepted connection.
  Future<void> kick() async {
    if (timers.isNotEmpty) timers.removeLast().cancel();
    final WebSocket socket = sockets.removeLast();
    await socket.close();
  }

  Future<void> close() async {
    for (final Timer timer in timers) {
      timer.cancel();
    }
    timers.clear();
    for (final WebSocket socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    for (final RpcPeer peer in peers) {
      unawaited(peer.close());
    }
    peers.clear();
    await server.close(force: true);
  }
}

void main() {
  test('connect authenticates and typed calls roundtrip', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    expect(client.connState.value, DaemonConnectionState.connecting);
    expect(client.isConnected, isFalse);

    await client.connect();
    expect(client.connState.value, DaemonConnectionState.connected);
    expect(client.isConnected, isTrue);
    expect(server.connectionCount, 1);

    // Typed call roundtrip (daemon.info).
    final DaemonInfo info = await client.info();
    expect(info.version, '1.2.3');
    expect(info.providers.single.id, 'omp');

    // projects.list decoding.
    final List<Project> projects = await client.listProjects();
    expect(projects.single.name, 'Demo');

    // DaemonError codes pass through untouched (sessions.send).
    await expectLater(
      client.sendMessage('sess-1', 'boom'),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', kErrConflict),
      ),
    );

    // Void calls resolve without error.
    await client.sendMessage('sess-1', 'hello');
  });

  test('beginMcpOAuth derives the browser callback from the daemon URL',
      () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    final McpOAuthFlow flow = await client.beginMcpOAuth('mcp-1');

    expect(flow.flowId, 'flow-1');
    expect(flow.authorizationUrl, 'https://auth.example/authorize');
    expect(server.oauthBegins, <Map<String, Object?>>[
      <String, Object?>{
        'id': 'mcp-1',
        'redirectUri':
            'http://127.0.0.1:${server.server.port}/oauth/callback',
      },
    ]);
  });

  test('sendMessage omits attachments when empty and serializes them otherwise',
      () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    // PROTOCOL.md: the `attachments` param is absent entirely when empty.
    await client.sendMessage('sess-1', 'hello');
    await client.sendMessage('sess-1', '', attachments: <OutgoingAttachment>[
      const OutgoingAttachment(
        name: 'shot.png',
        mimeType: 'image/png',
        data: 'aGVsbG8=',
      ),
    ]);

    expect(server.sends, hasLength(2));
    expect(server.sends[0].containsKey('attachments'), isFalse);
    expect(server.sends[0]['text'], 'hello');
    final Object? wire = server.sends[1]['attachments'];
    expect(wire, isA<List<Object?>>());
    final List<Object?> list = wire! as List<Object?>;
    expect(list, hasLength(1));
    expect(list.single, <String, Object?>{
      'name': 'shot.png',
      'mimeType': 'image/png',
      'data': 'aGVsbG8=',
    });
  });

  test('readAttachment decodes the attachment result and errors on unknowns',
      () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    server.attachments['sess-1'] = <String, Map<String, Object?>>{
      'att-1': <String, Object?>{
        'id': 'att-1',
        'name': 'shot.png',
        'mimeType': 'image/png',
        'size': 5,
        'data': 'aGVsbG8=',
      },
    };
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    final AttachmentData data = await client.readAttachment('sess-1', 'att-1');
    expect(data.id, 'att-1');
    expect(data.name, 'shot.png');
    expect(data.mimeType, 'image/png');
    expect(data.size, 5);
    expect(data.data, 'aGVsbG8=');

    // Server-side unknown attachment surfaces as a not-found DaemonError.
    await expectLater(
      client.readAttachment('sess-1', 'att-99'),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', kErrNotFound),
      ),
    );
  });

  test('auth failure propagates and leaves the client failed', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'wrong',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    await expectLater(
      client.connect(),
      throwsA(
        isA<DaemonError>()
            .having((DaemonError e) => e.code, 'code', kErrUnauthenticated),
      ),
    );
    expect(client.connState.value, DaemonConnectionState.failed);
    expect(client.isConnected, isFalse);
  });

  test('connects without auth when no token is configured', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    await client.connect();
    expect(client.isConnected, isTrue);
    expect(client.connState.value, DaemonConnectionState.connected);
  });

  test('connect to an unreachable socket fails instead of hanging', () async {
    // A port that is guaranteed closed: bind, observe the port, release it.
    final HttpServer sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int port = sink.port;
    await sink.close(force: true);

    final WsDaemonClient client = WsDaemonClient(
      url: 'ws://127.0.0.1:$port/ws',
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    // The handshake is refused; connect must fail fast and land `failed`
    // (never hang on closing a channel that never established).
    await expectLater(client.connect(), throwsA(anything));
    expect(client.connState.value, DaemonConnectionState.failed);
    expect(client.isConnected, isFalse);
  });

  test('a failed initial connect self-heals once the daemon comes up',
      () async {
    // A port that is guaranteed closed: bind, observe the port, release it.
    final HttpServer sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int port = sink.port;
    await sink.close(force: true);

    final WsDaemonClient client = WsDaemonClient(
      url: 'ws://127.0.0.1:$port/ws',
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    await expectLater(client.connect(), throwsA(anything));
    expect(client.connState.value, DaemonConnectionState.failed);

    int resyncCount = 0;
    final StreamSubscription<void> resyncSub =
        client.resynced.listen((void _) => resyncCount++);
    addTearDown(resyncSub.cancel);

    // The daemon comes up later; the armed backoff retry must connect on its
    // own (no restart of the app, no manual retry).
    final TestDaemonServer server =
        await TestDaemonServer.start(port: port);
    addTearDown(server.close);
    await waitFor(
      () => client.connState.value == DaemonConnectionState.connected,
    );
    expect(client.isConnected, isTrue);
    expect(
      resyncCount,
      1,
      reason: 'stores must backfill what they missed while the daemon '
          'was unreachable',
    );
  });

  test('retryNow reconnects immediately instead of waiting out the backoff',
      () async {
    // A port that is guaranteed closed: bind, observe the port, release it.
    final HttpServer sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final int port = sink.port;
    await sink.close(force: true);

    // A backoff so slow the armed timer cannot fire within the test.
    final WsDaemonClient client = WsDaemonClient(
      url: 'ws://127.0.0.1:$port/ws',
      token: 'secret',
      reconnectBase: const Duration(seconds: 30),
    );
    addTearDown(client.dispose);

    await expectLater(client.connect(), throwsA(anything));
    expect(client.connState.value, DaemonConnectionState.failed);

    int resyncCount = 0;
    final StreamSubscription<void> resyncSub =
        client.resynced.listen((void _) => resyncCount++);
    addTearDown(resyncSub.cancel);

    final TestDaemonServer server =
        await TestDaemonServer.start(port: port);
    addTearDown(server.close);
    client.retryNow();
    await waitFor(
      () => client.connState.value == DaemonConnectionState.connected,
    );
    expect(resyncCount, 1);
  });

  test('the first clean connect never emits resynced', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);

    int resyncCount = 0;
    final StreamSubscription<void> resyncSub =
        client.resynced.listen((void _) => resyncCount++);
    addTearDown(resyncSub.cancel);

    await client.connect();
    expect(client.isConnected, isTrue);
    // Nothing was missed on a clean first connect; emitting anyway would
    // make every store refetch for no reason.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(resyncCount, 0);
  });

  test('routes session.event / updated / removed notifications to streams',
      () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    final List<SessionEvent> events = <SessionEvent>[];
    final List<Session> updates = <Session>[];
    final List<String> removals = <String>[];
    int projectsChanged = 0;
    final StreamSubscription<SessionEvent> eventSub =
        client.sessionEvents('sess-1').listen(events.add);
    final StreamSubscription<Session> updateSub =
        client.sessionUpdates.listen(updates.add);
    final StreamSubscription<String> removalSub =
        client.sessionRemovals.listen(removals.add);
    final StreamSubscription<void> projectSub =
        client.projectsChanged.listen((void _) => projectsChanged++);
    addTearDown(eventSub.cancel);
    addTearDown(updateSub.cancel);
    addTearDown(removalSub.cancel);
    addTearDown(projectSub.cancel);

    server.pushEvent('sess-1');
    server.pushEvent('sess-1');
    server.pushSessionUpdated();
    server.pushSessionRemoved('sess-1');
    server.pushProjectsChanged();
    await waitFor(
      () =>
          events.length >= 2 &&
          updates.length == 1 &&
          removals.length == 1 &&
          projectsChanged == 1,
    );

    expect(events, everyElement(isA<UserMessageEvent>()));
    expect(events[0].seq, lessThan(events[1].seq!));
    expect(updates.single.status, SessionStatus.running);
    expect(removals.single, 'sess-1');
    expect(projectsChanged, 1);

    // Per-session filters: events for sess-1 never leak onto sess-2.
    final List<SessionEvent> other = <SessionEvent>[];
    final StreamSubscription<SessionEvent> otherSub =
        client.sessionEvents('sess-2').listen(other.add);
    addTearDown(otherSub.cancel);
    server.pushEvent('sess-1');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(other, isEmpty);
  });

  test('reconnects after the server closes the socket', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();
    expect(server.connectionCount, 1);

    final List<DaemonConnectionState> states = <DaemonConnectionState>[];
    client.connState.addListener(() {
      states.add(client.connState.value);
    });
    int resyncCount = 0;
    final StreamSubscription<void> resyncSub =
        client.resynced.listen((void _) => resyncCount++);
    addTearDown(resyncSub.cancel);

    await server.kick(); // server-side drop

    await waitFor(
      () =>
          client.connState.value == DaemonConnectionState.connected &&
          resyncCount == 1,
    );
    // The drop surfaced as reconnecting, then re-auth succeeded.
    expect(
      states,
      contains(DaemonConnectionState.reconnecting),
    );
    expect(states.last, DaemonConnectionState.connected);
    expect(server.connectionCount, greaterThanOrEqualTo(2));

    // Live notifications flow again on the fresh socket.
    final List<SessionEvent> events = <SessionEvent>[];
    final StreamSubscription<SessionEvent> eventSub =
        client.sessionEvents('sess-1').listen(events.add);
    addTearDown(eventSub.cancel);
    await waitFor(() => events.isNotEmpty);
  });

  test('ChatStore backfills missed history after a reconnect', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    final ChatStore chat = ChatStore(clientFor: (String daemonId) => client);
    addTearDown(chat.dispose);
    chat.watchSession('d', 'sess-1');

    // Let several events flow and the initial history load settle.
    await waitFor(() => server.seq >= 5);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(chat.eventsFor('sess-1'), isNotEmpty);

    // Drop the socket. While the client is offline, the daemon keeps
    // producing events that reach _history only_ (recorded server-side, no
    // live socket to notify).
    final List<DaemonConnectionState> observed = <DaemonConnectionState>[];
    client.connState.addListener(() => observed.add(client.connState.value));
    await server.kick();
    await waitFor(
      () => observed.contains(DaemonConnectionState.reconnecting),
    );
    server.pushEvent('sess-1');
    server.pushEvent('sess-1');
    final int offlineSeq = server.seq;

    await waitFor(
      () => client.connState.value == DaemonConnectionState.connected,
    );
    // The buffer must contain the offline events: only the resynced-triggered
    // history refetch can supply them (a live-only client would skip them).
    await waitFor(() {
      return chat
          .eventsFor('sess-1')
          .any((SessionEvent event) => event.seq == offlineSeq);
    });

    // No duplicates: the refetch dedupes against the already-buffered seqs.
    final List<int> seqs = <int>[
      for (final SessionEvent event in chat.eventsFor('sess-1')) event.seq!,
    ];
    expect(seqs, orderedEquals(seqs.toSet().toList()..sort()));
  });

  test('history pages backwards with beforeSeq and hasMore', () async {
    final TestDaemonServer server = await TestDaemonServer.start();
    addTearDown(server.close);
    final WsDaemonClient client = WsDaemonClient(
      url: server.url,
      token: 'secret',
      reconnectBase: const Duration(milliseconds: 20),
    );
    addTearDown(client.dispose);
    await client.connect();

    // Seed a quiet session's persisted history directly (the liveliness
    // timer only pushes events for 'sess-1').
    server.history['sess-paging'] = <Map<String, Object?>>[
      for (var i = 1; i <= 5; i++)
        <String, Object?>{'type': 'userMessage', 'text': 'm$i', 'seq': i},
    ];

    final ({List<SessionEvent> events, bool hasMore}) all =
        await client.history('sess-paging');
    expect(all.hasMore, isFalse);
    expect(all.events.map((SessionEvent e) => e.seq).toList(), <int>[1, 2, 3, 4, 5]);

    final ({List<SessionEvent> events, bool hasMore}) page1 =
        await client.history('sess-paging', limit: 2);
    expect(page1.hasMore, isTrue);
    expect(page1.events.map((SessionEvent e) => e.seq).toList(), <int>[4, 5]);

    final ({List<SessionEvent> events, bool hasMore}) page2 =
        await client.history('sess-paging', limit: 2, beforeSeq: 4);
    expect(page2.hasMore, isTrue);
    expect(page2.events.map((SessionEvent e) => e.seq).toList(), <int>[2, 3]);

    final ({List<SessionEvent> events, bool hasMore}) page3 =
        await client.history('sess-paging', limit: 2, beforeSeq: 2);
    expect(page3.hasMore, isFalse);
    expect(page3.events.map((SessionEvent e) => e.seq).toList(), <int>[1]);
  });
}
