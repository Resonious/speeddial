import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/daemon_client.dart';
import 'state/chat_store.dart';
import 'state/files_store.dart';
import 'state/git_store.dart';
import 'state/projects_store.dart';
import 'state/sessions_store.dart';

/// Connection state of a daemon endpoint. In-memory only for now; later
/// phases drive transitions from the WebSocket client.
enum ConnectionStatus { disconnected, connecting, connected, failed }

/// A configured daemon endpoint. UI-local model (the daemon itself reports a
/// `DaemonInfo` over the wire); fields are `final`.
@immutable
class DaemonEndpoint {
  const DaemonEndpoint({
    required this.id,
    required this.name,
    required this.url,
    required this.token,
  });

  factory DaemonEndpoint.fromJson(Map<String, Object?> json) {
    return DaemonEndpoint(
      id: json['id']! as String,
      name: json['name']! as String,
      url: json['url']! as String,
      token: json['token']! as String,
    );
  }

  final String id;
  final String name;
  final String url;
  final String token;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'url': url,
        'token': token,
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
  final Map<String, ConnectionStatus> _statuses =
      <String, ConnectionStatus>{};
  static int _idCounter = 0;

  List<DaemonEndpoint> get endpoints =>
      List<DaemonEndpoint>.unmodifiable(_endpoints);

  ConnectionStatus statusOf(String id) =>
      _statuses[id] ?? ConnectionStatus.disconnected;

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
        ..addAll(decoded
            .whereType<Map<String, Object?>>()
            .map(DaemonEndpoint.fromJson));
      _statuses.clear();
      for (final DaemonEndpoint e in _endpoints) {
        _statuses[e.id] = ConnectionStatus.disconnected;
      }
      notifyListeners();
    } on FormatException {
      // Corrupt storage: start fresh rather than crash at launch.
    }
  }

  /// Adds an endpoint. When [id] is given it is used verbatim (tests and
  /// demo mode register clients under such ids); otherwise one is generated.
  Future<void> addEndpoint({
    required String name,
    required String url,
    required String token,
    String? id,
  }) async {
    final String resolvedId =
        id ??
        'ep-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_idCounter++}';
    _endpoints.add(
      DaemonEndpoint(id: resolvedId, name: name, url: url, token: token),
    );
    _statuses[resolvedId] = ConnectionStatus.disconnected;
    notifyListeners();
    await _persist();
  }

  Future<void> removeEndpoint(String id) async {
    final int before = _endpoints.length;
    _endpoints.removeWhere((DaemonEndpoint e) => e.id == id);
    if (_endpoints.length == before) return;
    _statuses.remove(id);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(<Object?>[
        for (final DaemonEndpoint e in _endpoints) e.toJson(),
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

/// Store graph handed to [AppScope]. The five domain stores are constructed
/// internally and resolve their [DaemonClient] through [clientFor], which
/// serves ids registered via [registerClient] (tests/demo) or the optional
/// constructor resolver (real wiring in a later phase).
class AppData {
  /// [connections] and [selection] default to fresh instances; they exist so
  /// the pre-Phase-3 callers (main.dart) can keep injecting. The canonical
  /// construction is `AppData()..registerClient('id', client)`.
  AppData({
    ConnectionsStore? connections,
    SelectionStore? selection,
    DaemonClient Function(String daemonId)? clientFor,
  })  : connections = connections ?? ConnectionsStore(),
        selection = selection ?? SelectionStore(),
        _fallbackClientFor = clientFor {
    projects = ProjectsStore(clientFor: this.clientFor);
    sessions = SessionsStore(clientFor: this.clientFor);
    chat = ChatStore(clientFor: this.clientFor);
    files = FilesStore(clientFor: this.clientFor);
    git = GitStore(clientFor: this.clientFor);
  }

  final ConnectionsStore connections;
  final SelectionStore selection;

  late final ProjectsStore projects;
  late final SessionsStore sessions;
  late final ChatStore chat;
  late final FilesStore files;
  late final GitStore git;

  final Map<String, DaemonClient> _clients = <String, DaemonClient>{};

  /// Optional resolver consulted when an id was never [registerClient]ed; the
  /// real WebSocket wiring lands in a later phase.
  final DaemonClient Function(String daemonId)? _fallbackClientFor;

  /// Registers the client serving [daemonId]. Tests and demo mode inject
  /// fakes this way. Notifies nothing.
  void registerClient(String daemonId, DaemonClient client) {
    _clients[daemonId] = client;
  }

  /// Returns the registered client for [daemonId], or throws [StateError].
  DaemonClient clientFor(String daemonId) {
    final DaemonClient? client = _clients[daemonId];
    if (client != null) return client;
    final DaemonClient Function(String daemonId)? fallback = _fallbackClientFor;
    if (fallback != null) return fallback(daemonId);
    throw StateError('No client registered for daemon "$daemonId"');
  }

  /// Releases every store in the graph.
  void dispose() {
    connections.dispose();
    selection.dispose();
    projects.dispose();
    sessions.dispose();
    chat.dispose();
    files.dispose();
    git.dispose();
  }
}

/// Inherited-widget accessor for the store graph. Panes read stores with
/// `AppScope.of(context)` and listen through `ListenableBuilder`; no
/// BuildContext is ever held by a store.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.data, required super.child});

  final AppData data;

  static AppData of(BuildContext context) {
    final AppScope? scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing from the widget tree');
    return scope!.data;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.data != data;
}
