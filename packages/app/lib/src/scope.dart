import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'api/daemon_client.dart';
import 'api/fake_daemon.dart';
import 'api/ws_daemon_client.dart';
import 'local_daemon/local_daemon.dart';
import 'state/chat_store.dart';
import 'state/daemon_config_store.dart';
import 'state/embedded_daemon_store.dart';
import 'state/files_store.dart';
import 'state/git_store.dart';
import 'state/mcp_store.dart';
import 'state/projects_store.dart';
import 'state/sessions_store.dart';
import 'state/settings_store.dart';

/// Connection state of a daemon endpoint. Driven live from each
/// [WsDaemonClient]'s `connState`: [connecting] is the first attempt,
/// [reconnecting] the armed backoff retry after a drop or failed attempt,
/// [failed] a first connect that has not succeeded yet (the retry timer is
/// still armed — the state is transient). In-memory only; never persisted.
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// A configured daemon endpoint. UI-local model (the daemon itself reports a
/// `DaemonInfo` over the wire); fields are `final`.
@immutable
class DaemonEndpoint {
  const DaemonEndpoint({
    required this.id,
    required this.name,
    required this.url,
    required this.token,
    this.embedded = false,
  });

  factory DaemonEndpoint.fromJson(Map<String, Object?> json) {
    return DaemonEndpoint(
      id: json['id']! as String,
      name: json['name']! as String,
      url: json['url']! as String,
      token: json['token']! as String,
      embedded: (json['embedded'] as bool?) ?? false,
    );
  }

  final String id;
  final String name;
  final String url;
  final String token;

  /// True for the in-process daemon the desktop build starts itself. Such
  /// endpoints are never persisted (their URL/port is ephemeral) and are
  /// excluded from the add/edit/remove UI.
  final bool embedded;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': url,
    'token': token,
    if (embedded) 'embedded': true,
  };
}

/// Owns the list of configured daemon endpoints plus their (in-memory)
/// connection status. Persists the endpoint list as JSON via
/// shared_preferences; connection status is intentionally not persisted.
///
/// Stores never hold a BuildContext; UI reads them through [AppScope].
class ConnectionsStore extends ChangeNotifier {
  ConnectionsStore();

  static const String storageKey = 'speeddial.connections.v1';

  final List<DaemonEndpoint> _endpoints = <DaemonEndpoint>[];
  final Map<String, ConnectionStatus> _statuses = <String, ConnectionStatus>{};
  static int _idCounter = 0;

  List<DaemonEndpoint> get endpoints =>
      List<DaemonEndpoint>.unmodifiable(_endpoints);

  ConnectionStatus statusOf(String id) =>
      _statuses[id] ?? ConnectionStatus.disconnected;

  /// Updates the in-memory status of an existing endpoint and notifies
  /// listeners. Unknown ids are ignored (no status is materialized); setting
  /// the same value is a no-op.
  void setStatus(String id, ConnectionStatus status) {
    if (!_statuses.containsKey(id) || _statuses[id] == status) return;
    _statuses[id] = status;
    notifyListeners();
  }

  /// Loads persisted endpoints (called once at startup).
  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _endpoints
        ..clear()
        ..addAll(
          decoded
              .whereType<Map<String, Object?>>()
              .map(DaemonEndpoint.fromJson)
              .where((DaemonEndpoint e) => !e.embedded),
        );
      _statuses.clear();
      for (final DaemonEndpoint e in _endpoints) {
        _statuses[e.id] = ConnectionStatus.disconnected;
      }
      notifyListeners();
    } on FormatException {
      // Corrupt storage: start fresh rather than crash at launch.
    }
  }

  /// Normalizes a user-entered host or URL into a connectable endpoint:
  /// prepends `ws://` when no scheme is present and appends `/ws` when the
  /// value has no path. `localhost:7331` → `ws://localhost:7331/ws`;
  /// `wss://host` → `wss://host/ws`; `ws://host:7331/ws` is unchanged.
  static String normalizeEndpointUrl(String url) {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    final bool hasScheme = trimmed.contains('://');
    final String withScheme = hasScheme ? trimmed : 'ws://$trimmed';
    final int authorityStart = withScheme.indexOf('://') + 3;
    final String rest = withScheme.substring(authorityStart);
    final int firstSlash = rest.indexOf('/');
    // A path exists when a '/' separates the authority from non-empty
    // path characters.
    final bool hasPath = firstSlash >= 0 && firstSlash < rest.length - 1;
    if (hasPath) return withScheme;
    final String base = withScheme.endsWith('/')
        ? withScheme.substring(0, withScheme.length - 1)
        : withScheme;
    return '$base/ws';
  }

  /// Adds an endpoint. When [id] is given it is used verbatim (tests and
  /// demo mode register clients under such ids); otherwise one is generated.
  /// [url] is normalized (see [normalizeEndpointUrl]) so dialogs and tests
  /// can pass bare hosts. When [persist] is false the endpoint is kept
  /// in-memory only (used by the embedded in-process daemon, whose URL/port
  /// is ephemeral); when [embedded] is true the endpoint is marked as such
  /// so the UI hides its edit/remove actions.
  Future<void> addEndpoint({
    required String name,
    required String url,
    required String token,
    String? id,
    bool persist = true,
    bool embedded = false,
  }) async {
    final String resolvedId =
        id ??
        'ep-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_idCounter++}';
    _endpoints.add(
      DaemonEndpoint(
        id: resolvedId,
        name: name,
        url: normalizeEndpointUrl(url),
        token: token,
        embedded: embedded,
      ),
    );
    _statuses[resolvedId] = ConnectionStatus.disconnected;
    notifyListeners();
    if (persist) await _persist();
  }

  Future<void> removeEndpoint(String id) async {
    final int before = _endpoints.length;
    _endpoints.removeWhere((DaemonEndpoint e) => e.id == id);
    if (_endpoints.length == before) return;
    _statuses.remove(id);
    notifyListeners();
    await _persist();
  }

  /// Replaces the endpoint [id] in place (same id, normalized [url]).
  /// Unknown ids are a no-op. The endpoint's `embedded` flag is preserved:
  /// embedded endpoints stay non-persistent. Listeners diff url/token to
  /// decide whether a live client must be reconnected.
  Future<void> updateEndpoint({
    required String id,
    required String name,
    required String url,
    required String token,
  }) async {
    final int index = _endpoints.indexWhere((DaemonEndpoint e) => e.id == id);
    if (index < 0) return;
    final DaemonEndpoint existing = _endpoints[index];
    _endpoints[index] = DaemonEndpoint(
      id: id,
      name: name,
      url: normalizeEndpointUrl(url),
      token: token,
      embedded: existing.embedded,
    );
    notifyListeners();
    await _persist();
  }

  /// Replaces all persistent endpoints with a phone-synchronized snapshot.
  Future<void> replaceEndpoints(Iterable<DaemonEndpoint> endpoints) async {
    final List<DaemonEndpoint> replacement = <DaemonEndpoint>[
      for (final DaemonEndpoint endpoint in endpoints)
        if (!endpoint.embedded)
          DaemonEndpoint(
            id: endpoint.id,
            name: endpoint.name,
            url: normalizeEndpointUrl(endpoint.url),
            token: endpoint.token,
          ),
    ];
    final String before = jsonEncode(<Object?>[
      for (final DaemonEndpoint endpoint in _endpoints)
        if (!endpoint.embedded) endpoint.toJson(),
    ]);
    final String after = jsonEncode(<Object?>[
      for (final DaemonEndpoint endpoint in replacement) endpoint.toJson(),
    ]);
    if (before == after) return;
    _endpoints
      ..removeWhere((DaemonEndpoint endpoint) => !endpoint.embedded)
      ..addAll(replacement);
    _statuses.removeWhere(
      (String id, ConnectionStatus _) =>
          !_endpoints.any((DaemonEndpoint endpoint) => endpoint.id == id),
    );
    for (final DaemonEndpoint endpoint in replacement) {
      _statuses.putIfAbsent(endpoint.id, () => ConnectionStatus.disconnected);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(<Object?>[
        for (final DaemonEndpoint e in _endpoints)
          if (!e.embedded) e.toJson(),
      ]),
    );
  }
}

/// Holds the currently selected daemon/project/session ids. Nullable and
/// notify-on-set; the chat, files and git stores key off these.
class SelectionStore extends ChangeNotifier {
  String? _selectedDaemonId;
  String? _selectedProjectId;
  String? _selectedSessionId;

  String? get selectedDaemonId => _selectedDaemonId;
  set selectedDaemonId(String? value) {
    if (value == _selectedDaemonId) return;
    _selectedDaemonId = value;
    notifyListeners();
  }

  String? get selectedProjectId => _selectedProjectId;
  set selectedProjectId(String? value) {
    if (value == _selectedProjectId) return;
    _selectedProjectId = value;
    notifyListeners();
  }

  String? get selectedSessionId => _selectedSessionId;
  set selectedSessionId(String? value) {
    if (value == _selectedSessionId) return;
    _selectedSessionId = value;
    notifyListeners();
  }
}

/// Store graph handed to [AppScope]. The domain stores are constructed
/// internally and resolve their [DaemonClient] through [clientFor], which
/// serves ids registered via [registerClient] (tests/demo), the optional
/// constructor resolver, or — for plain [DaemonEndpoint]s — a lazily created
/// [WsDaemonClient] connecting to the endpoint's own URL/token.
class AppData {
  /// [connections], [selection] and [embeddedDaemon] default to fresh
  /// instances; they exist so the pre-Phase-3 callers (main.dart) can keep
  /// injecting. [clientFor], if given, is consulted for ids that were never
  /// [registerClient]ed and takes precedence over the lazy WebSocket wiring
  /// (legacy override). The canonical construction is
  /// `AppData()..registerClient('id', client)`.
  AppData({
    ConnectionsStore? connections,
    SelectionStore? selection,
    SettingsStore? settings,
    EmbeddedDaemonStore? embeddedDaemon,
    DaemonClient Function(String daemonId)? clientFor,
    this.daemonChannelFactory,
    this.daemonHistoryDetail = SessionHistoryDetail.full,
    int chatHistoryPageSize = 500,
    int chatRetainedSessionLimit = 0,
  }) : connections = connections ?? ConnectionsStore(),
       selection = selection ?? SelectionStore(),
       settings = settings ?? SettingsStore(),
       embeddedDaemon = embeddedDaemon ?? EmbeddedDaemonStore(),
       _fallbackClientFor = clientFor {
    projects = ProjectsStore(clientFor: this.clientFor);
    sessions = SessionsStore(
      clientFor: this.clientFor,
      selection: this.selection,
      selectedDaemonId: () => this.selection.selectedDaemonId,
      selectedSessionId: () => this.selection.selectedSessionId,
    );
    chat = ChatStore(
      clientFor: this.clientFor,
      historyPageSize: chatHistoryPageSize,
      retainedSessionLimit: chatRetainedSessionLimit,
    );
    files = FilesStore(clientFor: this.clientFor);
    git = GitStore(clientFor: this.clientFor);
    mcp = McpStore(clientFor: this.clientFor);
    daemonConfig = DaemonConfigStore(clientFor: this.clientFor);
    // Endpoints added after construction connect on arrival; status-only
    // changes are filtered out by [_connectedEndpointIds] to avoid churn.
    this.connections.addListener(_onConnectionsChanged);
  }

  final ConnectionsStore connections;
  final SelectionStore selection;
  final SettingsStore settings;
  final EmbeddedDaemonStore embeddedDaemon;

  late final ProjectsStore projects;
  late final SessionsStore sessions;
  late final ChatStore chat;
  late final FilesStore files;
  late final GitStore git;
  late final McpStore mcp;
  late final DaemonConfigStore daemonConfig;

  /// Sticky default for the new-session sheet's "yolo mode" checkbox: the
  /// sheet seeds its toggle from here and writes back on change, so the
  /// choice carries over to the next sheet. In-memory only — deliberately
  /// not persisted across launches, since yolo auto-approves every
  /// permission request.
  bool newSessionYolo = false;

  /// Endpoint id of the in-process daemon's non-persistent connection.
  static const String embeddedDaemonId = 'embedded';

  /// The in-process daemon controller set by [main] on desktop builds; null
  /// on web/mobile or in demo mode. Stopped via [stopLocalDaemon] on
  /// [dispose] / app shutdown.
  LocalDaemonController? localDaemon;

  final Map<String, DaemonClient> _clients = <String, DaemonClient>{};

  /// Lazily created WebSocket clients, one per endpoint id.
  final Map<String, WsDaemonClient> _websocketClients =
      <String, WsDaemonClient>{};

  /// connState listeners per WebSocket client (kept for disposal).
  final Map<String, VoidCallback> _statusListeners = <String, VoidCallback>{};

  /// Endpoint ids whose lazily created client already had [connect] triggered;
  /// presence prevents re-connecting on unrelated status notifications.
  final Set<String> _connectedEndpointIds = <String>{};

  /// Optional resolver consulted when an id was never [registerClient]ed; when
  /// provided it owns all non-registered wiring (the WebSocket clients are not
  /// created in that case).
  final DaemonClient Function(String daemonId)? _fallbackClientFor;

  /// Optional transport override used by the Wear target to open each daemon
  /// WebSocket through the paired phone. All normal app targets leave this
  /// null and connect directly.
  final DaemonFrameChannelFactory? daemonChannelFactory;

  /// Persisted-history projection used by lazily created WebSocket clients.
  final SessionHistoryDetail daemonHistoryDetail;

  /// Registers the client serving [daemonId]. Tests and demo mode inject
  /// fakes this way; registered ids always win over the lazy wiring and are
  /// never connected (or disposed) by [AppData]. Notifies nothing.
  void registerClient(String daemonId, DaemonClient client) {
    _clients[daemonId] = client;
  }

  /// Returns the client for [daemonId]: registered client first, then the
  /// optional constructor resolver, then a lazily created [WsDaemonClient]
  /// for a known [DaemonEndpoint]. The first touch of a lazily created
  /// client also starts its (unawaited) connection; failures land in
  /// [ConnectionsStore.statusOf] as `failed` via the connState listener.
  /// Throws [StateError] for unknown ids.
  DaemonClient clientFor(String daemonId) {
    final DaemonClient? client = _clients[daemonId];
    if (client != null) return client;
    final DaemonClient Function(String daemonId)? fallback = _fallbackClientFor;
    if (fallback != null) return fallback(daemonId);
    final WsDaemonClient wsClient = _ensureWebSocketClient(daemonId);
    // A lazy client is created only once per endpoint; the first time it is
    // touched, trigger its connect. A connect already started by
    // [connectAll] or the connect-on-add path is left in flight.
    if (_connectedEndpointIds.add(daemonId)) {
      unawaited(_connectQuietly(daemonId));
    }
    return wsClient;
  }

  /// Connects every currently configured endpoint, creating and caching its
  /// WebSocket client. Called once at startup after
  /// [ConnectionsStore.init]; endpoints added later are connected
  /// automatically as they arrive. Registered ids and endpoints handled by
  /// the constructor resolver are skipped. Tolerant of unreachable daemons:
  /// they surface through `ConnectionsStore.statusOf` as `failed`.
  Future<void> connectAll() async {
    if (_fallbackClientFor != null) return;
    for (final DaemonEndpoint endpoint in connections.endpoints) {
      if (_clients.containsKey(endpoint.id)) continue;
      if (!_connectedEndpointIds.add(endpoint.id)) continue;
      await _connectQuietly(endpoint.id);
    }
  }

  void _onConnectionsChanged() {
    if (_fallbackClientFor != null) return;
    final Set<String> known = <String>{
      for (final DaemonEndpoint endpoint in connections.endpoints) endpoint.id,
    };
    for (final String id in known) {
      if (_clients.containsKey(id)) continue; // registered fake: leave alone
      // An edited endpoint (url/token changed) invalidates its live client:
      // drop it so the reconnect below builds a fresh one with the new
      // parameters.
      final WsDaemonClient? live = _websocketClients[id];
      if (live != null) {
        final DaemonEndpoint endpoint = _endpointFor(id)!;
        if (live.url != endpoint.url || (live.token ?? '') != endpoint.token) {
          _connectedEndpointIds.remove(id);
          _disposeWebSocketClient(id);
        }
      }
      if (!_connectedEndpointIds.add(id)) continue; // already connecting
      unawaited(_connectQuietly(id));
    }
    for (final String id in _connectedEndpointIds.toList(growable: false)) {
      if (!known.contains(id)) {
        _connectedEndpointIds.remove(id);
        _disposeWebSocketClient(id);
      }
    }
  }

  Future<void> _connectQuietly(String daemonId) async {
    try {
      await _ensureWebSocketClient(daemonId).connect();
    } on Object {
      // Failures surface as a failed connection status; nothing to propagate.
    }
  }

  WsDaemonClient _ensureWebSocketClient(String daemonId) {
    final WsDaemonClient? existing = _websocketClients[daemonId];
    if (existing != null) return existing;
    final DaemonEndpoint? endpoint = _endpointFor(daemonId);
    if (endpoint == null) {
      throw StateError('No client registered for daemon "$daemonId"');
    }
    final WsDaemonClient client = WsDaemonClient(
      url: endpoint.url,
      token: endpoint.token,
      channelFactory: daemonChannelFactory,
      historyDetail: daemonHistoryDetail,
    );
    void listener() {
      connections.setStatus(daemonId, _mapClientState(client.connState.value));
    }

    client.connState.addListener(listener);
    _websocketClients[daemonId] = client;
    _statusListeners[daemonId] = listener;
    return client;
  }

  void _disposeWebSocketClient(String daemonId) {
    final WsDaemonClient? client = _websocketClients.remove(daemonId);
    if (client == null) return;
    final VoidCallback? listener = _statusListeners.remove(daemonId);
    if (listener != null) client.connState.removeListener(listener);
    unawaited(client.dispose());
  }

  DaemonEndpoint? _endpointFor(String daemonId) {
    for (final DaemonEndpoint endpoint in connections.endpoints) {
      if (endpoint.id == daemonId) return endpoint;
    }
    return null;
  }

  static ConnectionStatus _mapClientState(DaemonConnectionState state) =>
      switch (state) {
        DaemonConnectionState.connected => ConnectionStatus.connected,
        DaemonConnectionState.connecting => ConnectionStatus.connecting,
        DaemonConnectionState.reconnecting => ConnectionStatus.reconnecting,
        DaemonConnectionState.failed => ConnectionStatus.failed,
      };

  /// Retries every app-owned WebSocket immediately after the app resumes.
  /// Clients already marked connected get a [WsDaemonClient.verifyLiveness]
  /// probe instead of [retryNow]: a socket that survived on paper may be
  /// half-dead (device suspend can drop the TCP connection without a close
  /// event), in which case the probe tears it down and the reconnect it
  /// triggers backfills whatever the stores missed. Registered clients and
  /// constructor-provided clients own their lifecycle.
  void reconnectAll() {
    if (_disposed || _fallbackClientFor != null) return;
    for (final DaemonEndpoint endpoint in connections.endpoints) {
      reconnect(endpoint.id);
    }
  }

  /// Manual reconnect hook for the UI ("Retry now" on a failed endpoint):
  /// resets the live client's backoff and retries immediately, or starts the
  /// first connect for a never-touched endpoint. A client that already
  /// believes itself connected is probed for liveness instead (a no-op when
  /// the daemon answers). Registered clients (tests, demo mode) own their
  /// lifecycle; nothing happens for them.
  void reconnect(String daemonId) {
    if (_clients.containsKey(daemonId)) return;
    final WsDaemonClient? live = _websocketClients[daemonId];
    if (live != null) {
      if (live.connState.value == DaemonConnectionState.connected) {
        unawaited(live.verifyLiveness());
      } else {
        live.retryNow();
      }
      return;
    }
    if (!_connectedEndpointIds.add(daemonId)) return;
    unawaited(_connectQuietly(daemonId));
  }

  /// Stops the embedded in-process daemon, if any. Best-effort and
  /// idempotent: safe to call when none was started, or after [dispose].
  /// Called on app shutdown so agent processes are killed and the WebSocket
  /// server closed.
  Future<void> stopLocalDaemon() async {
    final LocalDaemonController? daemon = localDaemon;
    localDaemon = null;
    if (daemon != null) await daemon.stop();
  }

  /// Applies new embedded-daemon settings: persists them, restarts the
  /// in-process daemon (its agent processes are killed; sessions survive and
  /// respawn on their next turn), and repoints the embedded endpoint so the
  /// live client reconnects with the new URL/token.
  ///
  /// Throws (recording the failure in [EmbeddedDaemonStore.lastError]) when
  /// the daemon fails to restart — e.g. a fixed port already in use; the
  /// saved settings still apply to the next launch. With no controller
  /// (web/mobile/demo) it only persists.
  Future<void> applyEmbeddedDaemonConfig(EmbeddedDaemonConfig config) async {
    final EmbeddedDaemonStore embedded = embeddedDaemon;
    await embedded.save(config);
    final LocalDaemonController? controller = localDaemon;
    if (controller == null || _disposed) return;
    embedded.setRestarting(true);
    try {
      await controller.stop();
      final String? url = await controller.start(
        host: config.host,
        port: config.port,
        token: config.token,
      );
      if (url == null) {
        throw StateError(
          'the embedded daemon failed to start: ${controller.lastError}',
        );
      }
      await _upsertEmbeddedEndpoint(url, config.token);
    } on Object catch (error) {
      embedded.setLastError(error);
      rethrow;
    } finally {
      embedded.setRestarting(false);
    }
  }

  /// Points the embedded endpoint at [url]/[token], adding it when missing
  /// (e.g. the initial start failed at boot), never persisting it.
  Future<void> _upsertEmbeddedEndpoint(String url, String token) async {
    final bool exists = connections.endpoints.any(
      (DaemonEndpoint e) => e.id == embeddedDaemonId,
    );
    if (exists) {
      await connections.updateEndpoint(
        id: embeddedDaemonId,
        name: 'This computer',
        url: url,
        token: token,
      );
    } else {
      await connections.addEndpoint(
        id: embeddedDaemonId,
        name: 'This computer',
        url: url,
        token: token,
        persist: false,
        embedded: true,
      );
      selection.selectedDaemonId ??= embeddedDaemonId;
    }
  }

  /// True after [dispose]; async startup work must check this between awaits.
  bool get isDisposed => _disposed;
  bool _disposed = false;

  /// Releases every store in the graph plus any lazily created WebSocket
  /// clients. Registered clients (fakes) are left to their owners.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    connections.removeListener(_onConnectionsChanged);
    for (final MapEntry<String, VoidCallback> entry
        in _statusListeners.entries) {
      _websocketClients[entry.key]?.connState.removeListener(entry.value);
    }
    _statusListeners.clear();
    for (final WsDaemonClient client in _websocketClients.values) {
      unawaited(client.dispose());
    }
    _websocketClients.clear();
    _connectedEndpointIds.clear();
    connections.dispose();
    selection.dispose();
    projects.dispose();
    sessions.dispose();
    chat.dispose();
    files.dispose();
    git.dispose();
    mcp.dispose();
    daemonConfig.dispose();
    settings.dispose();
    embeddedDaemon.dispose();
  }
}

/// Inherited-widget accessor for the store graph. Panes read stores with
/// `AppScope.of(context)` and listen through `ListenableBuilder`; no
/// BuildContext is ever held by a store.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.data, required super.child});

  final AppData data;

  static AppData of(BuildContext context) {
    final AppScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing from the widget tree');
    return scope!.data;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.data != data;
}

/// Builds the store graph for `--dart-define=demo=true` mode: a single `demo`
/// endpoint backed by an in-memory [FakeDaemonClient], already selected and
/// marked connected. The fake is registered before the endpoint is added, so
/// the lazy WebSocket wiring never touches it.
AppData buildDemoAppData() {
  final AppData data = AppData();
  data.registerClient('demo', FakeDaemonClient());
  data.connections.addEndpoint(
    id: 'demo',
    name: 'Local demo',
    url: 'fake://local',
    token: '',
  );
  data.selection.selectedDaemonId = 'demo';
  data.connections.setStatus('demo', ConnectionStatus.connected);
  // Populate the project/session stores immediately; without these refreshes
  // the rail would show "No projects yet" until the user re-taps the daemon
  // tile (selection-change notifications alone do not load listings).
  unawaited(data.projects.refresh('demo'));
  unawaited(data.sessions.refresh('demo'));
  // Open straight into a live session: select the seeded project + session,
  // refresh git, and stream a scripted turn so the demo dashboard has real
  // content (history backfill covers a turn that started before the watch).
  unawaited(() async {
    await data.projects.refresh('demo');
    await data.sessions.refresh('demo');
    if (data.isDisposed) return;
    final projects = data.projects.projectsFor('demo');
    if (projects.isEmpty) return;
    final project = projects.first;
    data.selection.selectedProjectId = project.id;
    final sessions = data.sessions.sessionsFor(project.id);
    if (sessions.isEmpty) return;
    final session = sessions.first;
    data.selection.selectedSessionId = session.id;
    if (data.isDisposed) return;
    unawaited(data.git.refresh('demo', project.id, sessionId: session.id));
    unawaited(
      data.chat.send('demo', session.id, 'Add retry logic to the sync loop'),
    );
  }());
  return data;
}
