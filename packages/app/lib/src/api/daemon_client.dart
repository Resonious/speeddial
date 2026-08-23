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

  /// The socket dropped (or a connect attempt failed); waiting to retry with
  /// exponential backoff.
  reconnecting,

  /// The initial connection (or auth) failed. A backoff retry is armed and
  /// flips the state to [reconnecting] when it starts, so this state is
  /// transient unless the client is disposed.
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
  // MCP servers
  // ---------------------------------------------------------------------

  Future<List<McpServerProfile>> listMcpServers();

  Future<McpServerProfile> createMcpServer({
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? projectId,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  });

  Future<McpServerProfile> updateMcpServer({
    required String id,
    required String name,
    required McpTransport transport,
    required bool enabled,
    String? command,
    List<String> args = const <String>[],
    String? url,
    Map<String, String> secrets = const <String, String>{},
    List<String> removeSecretNames = const <String>[],
    McpAuthType authType = McpAuthType.none,
    String? oauthClientId,
    String? oauthClientSecret,
  });

  Future<void> deleteMcpServer(String id);

  Future<McpOAuthFlow> beginMcpOAuth(String id);

  Future<McpServerProfile> mcpOAuthStatus(String id, String flowId);

  Future<McpServerProfile> disconnectMcpOAuth(String id);

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  /// Sessions, optionally filtered by project / archive state.
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  });

  /// Creates a session and returns it; also surfaces on [sessionUpdates].
  /// When [baseBranch] is given the daemon fetches `origin/<baseBranch>` and
  /// runs the agent in a fresh worktree branched off the remote tip.
  /// [sandboxMode] selects provider isolation when advertised. With [yolo]
  /// the daemon auto-approves the agent's permission requests.
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? baseBranch,
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  });

  /// Forks [sessionId] into a new session whose history ends at the message
  /// event identified by [seq].
  Future<Session> forkSession(String sessionId, int seq);

  /// Starts a turn with [text]. Events stream via [sessionEvents].
  ///
  /// [attachments] carries the files (base64 payloads) to attach to the
  /// message; `text` may be empty when at least one attachment is present.
  /// The daemon broadcasts the user's message (with attachment metadata) as
  /// the turn's first event; payloads are fetched via [readAttachment].
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  });

  /// Fetches an attachment's base64 payload by id; errors `-32002` when the
  /// session or attachment is unknown.
  Future<AttachmentData> readAttachment(String sessionId, String attachmentId);

  /// Cancels the running turn, if any.
  Future<void> cancelSession(String sessionId);

  Future<Session> renameSession(String sessionId, String title);
  Future<Session> archiveSession(String sessionId, bool archived);

  /// Deletes a session and kills its agent process if alive.
  Future<void> deleteSession(String sessionId);

  Future<Session> setMode(String sessionId, SessionMode mode);
  Future<Session> setModel(String sessionId, String model);

  /// Sets the session's thinking level. Valid levels come from
  /// `Session.thinkingLevels`; the current selection is `Session.thinkingLevel`.
  Future<Session> setThinkingLevel(String sessionId, String level);

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
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  );

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  /// Directory listing; [path] defaults to the project root (`"."`).
  Future<List<FileEntry>> listFiles(String projectId, [String path = '.']);

  /// Reads a file, optionally capping the returned bytes.
  Future<FileReadResult> readFile(
    String projectId,
    String path, {
    int? maxBytes,
  });

  /// Downloads a complete binary-safe file referenced by an agent message.
  /// Relative paths resolve from the session's cwd; absolute paths must stay
  /// inside it.
  Future<FileDownload> downloadFile(String sessionId, String path);

  // ---------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------

  // Every git method takes an optional [sessionId]: when given, the daemon
  // runs the operation in that session's cwd (its worktree) instead of the
  // project path. The session must belong to the project.
  Future<GitStatus> gitStatus(String projectId, {String? sessionId});
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  });
  Future<List<Branch>> gitBranches(String projectId, {String? sessionId});
  Future<void> gitCheckout(
    String projectId,
    String branch, {
    String? sessionId,
  });
  Future<String> gitCommit(
    String projectId,
    String message, {
    String? sessionId,
    bool stageAll = false,
  });
  Future<void> gitPush(String projectId, {String? sessionId});

  /// Merges the session's worktree branch back into the base branch it was
  /// created from; fast-forwards the local base to origin first when the
  /// remote moved ahead.
  Future<MergeResult> gitMergeToBase(
    String projectId, {
    required String sessionId,
  });

  /// Rebases the session's worktree branch onto the base branch it was
  /// created from; fast-forwards the local base to origin first when the
  /// remote moved ahead.
  Future<RebaseResult> gitRebaseOntoBase(
    String projectId, {
    required String sessionId,
  });
  Future<String> gitCreatePr(
    String projectId, {
    String? sessionId,
    String? title,
    String? body,
    String? base,
    bool draft = false,
  });

  /// Per-session git summaries (dirty / ahead-of-base / merged-into-base)
  /// for every non-archived session of [projectId] — the left-rail badges.
  Future<List<SessionGitSummary>> gitSessionSummaries(String projectId);

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  /// Live events for one session; one broadcast stream per session.
  Stream<SessionEvent> sessionEvents(String sessionId);

  /// `session.created` and `session.updated` notifications.
  Stream<Session> get sessionUpdates;

  /// Ids of sessions that were removed.
  Stream<String> get sessionRemovals;

  /// Project ids whose session git summaries moved daemon-side (the
  /// watcher noticed commits, dirty-state changes, or a periodic fetch
  /// advancing the base branch); consumers refetch
  /// `gitSessionSummaries(projectId)`.
  Stream<String> get gitChanged;

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
