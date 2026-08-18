import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Connection state of a live [DaemonClient], exposed through
/// `WsDaemonClient.connState` (a [ValueNotifier]) so stores and UI can track
/// an endpoint's health. Starts at [connecting]; a failed initial connect
/// lands on [failed].
enum DaemonConnectionState {
  /// First connection attempt in progress (or awaiting auth).
  connecting,

  /// Authenticated and receiving live notifications.
  connected,

  /// The socket dropped; waiting to retry with exponential backoff.
  reconnecting,

  /// The initial connection (or auth) failed and was not retried.
  failed,
}

/// Client interface for a single SpeedDial daemon endpoint, as consumed by
/// the app's stores and panes.
///
/// A concrete implementation talks PROTOCOL.md (WebSocket JSON-RPC); the
/// [FakeDaemonClient] provides the same surface in memory for demos and
/// tests. All text in, text out; no BuildContext is ever held through this
/// interface.
///
/// Sessions are identified by daemon-scoped ids; projects likewise. Methods
/// may throw [DaemonError] from `package:speeddial_protocol` on failures.
abstract class DaemonClient {
  // ---------------------------------------------------------------------
  // Daemon / projects
  // ---------------------------------------------------------------------

  /// Static daemon identity: version, protocol, auth, providers.
  Future<DaemonInfo> info();

  /// All known projects, any order.
  Future<List<Project>> listProjects();

  /// Adds a project rooted at [path] (absolute path on the daemon host).
  Future<Project> addProject(String path, {String? name});

  /// Removes a project and archives its sessions. Does not touch the filesystem.
  Future<void> removeProject(String id);

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  /// Sessions, optionally filtered by project / archive state.
  Future<List<Session>> listSessions({String? projectId, bool includeArchived = false});

  /// Creates a session and returns it; also surfaces on [sessionUpdates].
  /// When [baseBranch] is given the daemon fetches `origin/<baseBranch>` and
  /// runs the agent in a fresh worktree branched off the remote tip.
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? baseBranch,
  });

  /// Starts a turn with [text]. Events stream via [sessionEvents].
  Future<void> sendMessage(String sessionId, String text);

  /// Cancels the running turn, if any.
  Future<void> cancelSession(String sessionId);

  Future<Session> renameSession(String sessionId, String title);
  Future<Session> archiveSession(String sessionId, bool archived);

  /// Deletes a session and kills its agent process if alive.
  Future<void> deleteSession(String sessionId);

  Future<Session> setMode(String sessionId, SessionMode mode);
  Future<Session> setModel(String sessionId, String model);

  /// A page of persisted events for a session, ordered by `seq` ascending.
  /// Without [beforeSeq] the latest page (up to [limit]) is returned;
  /// [hasMore] reports whether an older page exists (callers page backwards
  /// by passing `beforeSeq = oldestKnownSeq - 1` until it is false).
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  });

  /// Resolves a pending permission request; errors `-32002` if unknown/expired.
  Future<void> respondPermission(String sessionId, String requestId, String optionId);

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  /// Directory listing; [path] defaults to the project root (`"."`).
  Future<List<FileEntry>> listFiles(String projectId, [String path = '.']);

  /// Reads a file, optionally capping the returned bytes.
  Future<FileReadResult> readFile(String projectId, String path, {int? maxBytes});

  // ---------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------

  Future<GitStatus> gitStatus(String projectId);
  Future<List<GitDiff>> gitDiff(String projectId, {String? path, bool staged = false});
  Future<List<Branch>> gitBranches(String projectId);
  Future<void> gitCheckout(String projectId, String branch);
  Future<String> gitCommit(String projectId, String message, {bool stageAll = false});
  Future<void> gitPush(String projectId);
  Future<String> gitCreatePr(String projectId, {String? title, String? body, String? base, bool draft = false});

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  /// Live events for one session; one broadcast stream per session.
  Stream<SessionEvent> sessionEvents(String sessionId);

  /// `session.created` and `session.updated` notifications.
  Stream<Session> get sessionUpdates;

  /// Ids of sessions that were removed.
  Stream<String> get sessionRemovals;

  /// Emits whenever the daemon announces `projects.changed` (a project was
  /// added, renamed, or removed on the daemon side); consumers refetch
  /// `listProjects()`.
  Stream<void> get projectsChanged;

  /// Emits after every successful reconnect, once the client is authenticated
  /// again. Store-side consumers (e.g. ChatStore) refetch persisted history
  /// on this to backfill events missed while the socket was down. Never emits
  /// on the initial connect; implementations that never reconnect emit
  /// nothing.
  Stream<void> get resynced;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  bool get isConnected;

  Future<void> dispose();
}
