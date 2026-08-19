/// [SessionEngine]: owns live ACP agent processes per session and maps their
/// updates onto protocol [SessionEvent]s, persisting every event with a
/// per-session sequence number and broadcasting it.
///
/// Lifecycle:
///   * `createSession` spawns a provider's ACP agent (cwd = session cwd),
///     creates an ACP session, and persists an idle protocol session.
///   * `sendMessage` runs a turn: user message event (with attachment
///     metadata when files were attached), status `running`, mapped ACP
///     updates (chunks, tool calls, plan, usage) streamed and persisted,
///     permission requests parked until `respondPermission`, then
///     `turnComplete` and status `idle`.
///   * `cancel` cancels the running turn via the agent.
///   * `delete` kills the agent and removes the session (and its events).
///
/// Daemon restarts: the ACP session id is persisted at creation, so after a
/// restart `sendMessage` lazily respawns the provider's agent and resumes it
/// with ACP `session/load` ([SessionEngine.restore] only flags sessions that
/// were interrupted mid-turn).
///
/// fs/read+write requests from agents are served with paths confined to the
/// session cwd; anything escaping it is rejected with a JSON-RPC error.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:uuid/uuid.dart';

import '../acp/acp_client.dart';
import '../acp/acp_types.dart';
import '../git/git_service.dart';
import '../providers/provider_registry.dart';
import '../store/daemon_store.dart';
import 'event_mapper.dart';

/// JSON-RPC code: invalid params (PROTOCOL.md `-32602`), used for
/// `sessions.create` cwd confinement rejects.
const int _kErrInvalidParams = -32602;

/// The four protocol session fields backed by ACP config options, as
/// reported by one configOptions snapshot: the current model + advertised
/// models, and the current thinking level + advertised levels. Providers
/// exposing neither option report null/empty.
typedef _ConfigSnapshot = ({
  String? model,
  List<String> models,
  String? thinkingLevel,
  List<String> thinkingLevels,
});

/// One live engine session: its agent client plus in-memory turn state.
class _LiveSession {
  _LiveSession({
    required this.session,
    required this.client,
    required this.acpSessionId,
    this.modelConfigId,
    this.thinkingConfigId,
  });

  Session session;
  final AcpClient client;
  final String acpSessionId;

  /// The config option id of the provider's model (for ACP
  /// `session/set_config_option`), null when the provider exposes none.
  final String? modelConfigId;

  /// The config option id of the provider's thinking level (for ACP
  /// `session/set_config_option`), null when the provider exposes none.
  final String? thinkingConfigId;

  /// The in-flight turn future, or null when idle.
  Future<void>? turn;

  /// Parked permission requests: requestId → completer of the chosen option.
  final Map<String, Completer<String>> pendingPermissions = {};

  /// Set before the client is torn down so a dying turn suppresses its
  /// error events.
  bool closed = false;

  String get sessionId => session.id;
  String get cwd => session.cwd;
}

/// A validated, persisted attachment ready for the turn: its metadata plus
/// the decoded payload (for ACP block building).
class _PreparedAttachment {
  _PreparedAttachment({required this.data, required this.bytes});

  final AttachmentData data;
  final List<int> bytes;
}

/// Orchestrates ACP agent processes and the project session lifecycle.
class SessionEngine {
  SessionEngine({
    required DaemonStore store,
    required ProviderRegistry providers,
    GitService? git,
  })  : _store = store, // ignore: prefer_initializing_formals — public API name
        _providers = providers, // ignore: prefer_initializing_formals — public API name
        _git = git; // ignore: prefer_initializing_formals — public API name

  final DaemonStore _store;
  final ProviderRegistry _providers;

  /// Git operations for per-session worktrees (`baseBranch` on
  /// [createSession]); null only in tests that never pass a base branch.
  final GitService? _git;
  final Uuid _uuid = const Uuid();

  final Map<String, _LiveSession> _live = {};

  /// Per-session in-flight tool call state (toolCallId → protocol ToolCall),
  /// cleared at the start of every turn.
  final Map<String, Map<String, ToolCall>> _toolCalls = {};

  // Synchronous broadcast controllers: subscription listeners that are
  // attached *before* an engine call (createSession/delete/sendMessage/...)
  // must observe the emissions as soon as that awaited call returns. With the
  // default async delivery the event is only dispatched a full event-loop turn
  // after the emitting method (which does real I/O: spawning an agent, awaiting
  // the turn, disposing the process) completes, so listeners see it too late.
  final StreamController<({String sessionId, int seq, SessionEvent event})>
      _eventsController = StreamController.broadcast(sync: true);
  final StreamController<Session> _sessionChangesController =
      StreamController.broadcast(sync: true);
  final StreamController<String> _sessionRemovalsController =
      StreamController.broadcast(sync: true);

  /// Persisted/broadcast events with their per-session sequence numbers.
  Stream<({String sessionId, int seq, SessionEvent event})> get events =>
      _eventsController.stream;

  /// Session created or any metadata/status change.
  Stream<Session> get sessionChanges => _sessionChangesController.stream;

  /// Session ids deleted (agent killed, rows removed).
  Stream<String> get sessionRemovals => _sessionRemovalsController.stream;

  /// Reconciles persisted sessions with a fresh process table after a daemon
  /// restart. Agent processes are gone, but sessions persist them lazily:
  /// [sendMessage] respawns the agent and resumes it via ACP `session/load`
  /// (see [_resume]), so idle sessions keep their status. Only sessions
  /// interrupted mid-turn ([SessionStatus.running]/[SessionStatus.waitingPermission]
  /// at shutdown) are marked `error`, with a persisted note in their history
  /// explaining the interruption. Call once at startup.
  Future<void> restore() async {
    for (final session in _store.listSessions(includeArchived: true)) {
      if (session.status != SessionStatus.running &&
          session.status != SessionStatus.waitingPermission) {
        continue;
      }
      final updated = _withStatus(session, SessionStatus.error);
      _store.updateSession(updated);
      final int seq = _store.nextSeq(session.id);
      final SessionEvent event = _store.appendEvent(
        session.id,
        seq,
        SessionErrorEvent(
          message: 'Daemon restarted before the turn completed',
        ),
      );
      if (!_eventsController.isClosed) {
        _eventsController
            .add((sessionId: session.id, seq: seq, event: event));
      }
      if (!_sessionChangesController.isClosed) {
        _sessionChangesController.add(updated);
      }
    }
  }

  /// Creates a new protocol session and spawns its ACP agent.
  ///
  /// When [baseBranch] is given, the session runs in a fresh git worktree:
  /// the daemon fetches `origin/<baseBranch>` in the project repo and adds a
  /// worktree at `<project-parent>/.speeddial-worktrees/<name>-<id8>` on a
  /// new `speeddial/<slug>-<id8>` branch based on whichever of the local
  /// branch and the remote-tracking ref is ahead (local wins ties and
  /// divergence — see [GitService.worktreeBaseRef]). The worktree becomes
  /// the session cwd; [cwd] and [baseBranch] are mutually exclusive. The
  /// worktree is rolled back if the agent fails to start.
  ///
  /// With [yolo], the engine resolves the agent's permission requests itself
  /// (see [_onPermissionRequest]) instead of parking them for a client.
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? cwd,
    String? baseBranch,
    bool yolo = false,
  }) async {
    final spec = _providers.byId(providerId);
    if (spec == null) {
      throw DaemonError(kErrProviderUnavailable, 'Unknown provider: $providerId');
    }
    if (!_providers.isAvailable(providerId)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'Provider "$providerId" is not available on this host',
      );
    }
    final project = _store.getProject(projectId);
    if (project == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: $projectId');
    }
    if (cwd != null && baseBranch != null) {
      throw DaemonError(
        _kErrInvalidParams,
        'cwd and baseBranch are mutually exclusive',
      );
    }
    if (cwd != null) {
      // The session cwd becomes the agent's working directory and the fs
      // sandbox root; allowing an arbitrary cwd would void project
      // confinement (the agent's read/write handlers confine to the cwd).
      // Compare symlink-resolved real paths so a cwd that is a symlink
      // escape is rejected; equality is allowed.
      final realProject = _realPathOfDeepestExisting(project.path);
      final realCwd = _realPathOfDeepestExisting(cwd);
      final prefix = realProject.endsWith(p.separator)
          ? realProject
          : '$realProject${p.separator}';
      if (realCwd != realProject && !realCwd.startsWith(prefix)) {
        throw DaemonError(
          _kErrInvalidParams,
          'cwd must be inside the project directory',
        );
      }
    }
    final sessionId = _uuid.v4();
    final shortId = sessionId.substring(0, 8);

    // A daemon-computed worktree path needs no confinement check: it is
    // derived from the project path, never from client input.
    String? worktreePath;
    final String workingDir;
    if (baseBranch != null) {
      final git = _git;
      if (git == null) {
        throw DaemonError(kErrGit, 'worktree sessions are not supported');
      }
      final String baseRef =
          await git.worktreeBaseRef(project.path, baseBranch);
      worktreePath = p.join(
        p.dirname(project.path),
        '.speeddial-worktrees',
        '${p.basename(project.path)}-$shortId',
      );
      await git.addWorktree(
        project.path,
        path: worktreePath,
        branch: 'speeddial/${_branchSlug(title) ?? 'session'}-$shortId',
        baseRef: baseRef,
      );
      workingDir = worktreePath;
    } else {
      workingDir = cwd ?? project.path;
    }
    final now = DateTime.now().toUtc();
    final baseSession = Session(
      id: sessionId,
      projectId: projectId,
      providerId: providerId,
      title: title ?? kDefaultSessionTitle,
      status: SessionStatus.idle,
      mode: mode ?? SessionMode.build,
      model: model,
      cwd: workingDir,
      baseBranch: baseBranch,
      yolo: yolo,
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    final client = _spawnAgent(baseSession);
    final String acpSessionId;
    final Session session;
    ({String configId, String? current, List<String> levels})? modelOption;
    ({String configId, String? current, List<String> levels})? thinking;
    try {
      final info = await client.initialized;
      if (info.authMethods.isNotEmpty) {
        await client.authenticate(info.authMethods.first);
      }
      final created = await client.newSession(cwd: workingDir);
      acpSessionId = created.sessionId;
      modelOption = _modelOptionOf(created.configOptions);
      thinking = _thinkingOptionOf(created.configOptions);
      // An explicitly requested model is applied best-effort — the agent
      // may reject a fuzzy id, which must never fail creation; the
      // response is then the authoritative snapshot for all config-backed
      // fields.
      var adoptedOptions = created.configOptions;
      if (modelOption != null && model != null) {
        try {
          adoptedOptions = await client.setConfigOption(
            acpSessionId,
            modelOption.configId,
            model,
          );
        } on Object {
          // Fall through to the pre-call reported state.
        }
      }
      var snapshot = _configSnapshotOf(adoptedOptions);
      if (modelOption == null) {
        // No model option advertised: keep the legacy behavior — the
        // requested model stays a plain local label and models stay empty.
        snapshot = (
          model: model,
          models: const <String>[],
          thinkingLevel: snapshot.thinkingLevel,
          thinkingLevels: snapshot.thinkingLevels,
        );
      }
      session = _withConfigOptions(baseSession, snapshot);
    } on Object catch (error) {
      // Never leak a half-initialized agent process or its worktree.
      await client.dispose();
      if (worktreePath != null) {
        try {
          await _git!.removeWorktree(project.path, worktreePath);
        } on Object {
          // Rollback is best-effort; the spawn error is the real failure.
        }
      }
      throw DaemonError(
        kErrAgentProcess,
        'Failed to start provider "$providerId": $error',
      );
    }
    _store.insertSession(session);
    // Persisted so [sendMessage] can resume the agent (ACP `session/load`)
    // after a daemon restart.
    _store.setAcpSessionId(session.id, acpSessionId);
    _live[session.id] = _LiveSession(
      session: session,
      client: client,
      acpSessionId: acpSessionId,
      modelConfigId: modelOption?.configId,
      thinkingConfigId: thinking?.configId,
    );
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(session);
    }
    return session;
  }

  /// Spawns the ACP agent for [session]'s provider in its cwd, wired to this
  /// engine's permission/fs handlers. Shared by [createSession] and the
  /// restart-resume path in [sendMessage].
  AcpClient _spawnAgent(Session session) {
    final ProviderSpec spec = _providers.byId(session.providerId)!;
    return AcpClient.spawn(
      spec.command,
      cwd: session.cwd,
      // The closures capture our protocol sessionId, so the ACP session id
      // (which collides across agents, e.g. "s1") never needs disambiguation.
      requestPermission: (acpSessionId, toolCallId, requestTitle, options) =>
          _onPermissionRequest(session.id, toolCallId, requestTitle, options),
      readTextFile: (acpSessionId, path) => _readTextFile(session.id, path),
      writeTextFile: (acpSessionId, path, content) =>
          _writeTextFile(session.id, path, content),
    );
  }

  /// Starts a turn for [text] with the attached files. When the session's
  /// agent process is gone (daemon restarted), the agent is first respawned
  /// and resumed via ACP `session/load` — see [_resume]. Errors
  /// `kErrConflict` when a turn is already running or the session cannot be
  /// resumed (closed, predates resume support, or the provider lacks
  /// `session/load`).
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const <OutgoingAttachment>[],
  }) async {
    // Concurrent sends to the same not-live session share one resume.
    _LiveSession? live = _live[sessionId];
    live ??= await _resuming.putIfAbsent(
      sessionId,
      () => _resume(sessionId).whenComplete(() {
        // Block body, not `=>`: Map.remove returns the removed value, and
        // here that value is this very future — returning it would make
        // whenComplete await itself and never complete.
        _resuming.remove(sessionId);
      }),
    );
    if (live.turn != null) {
      throw DaemonError(
        kErrConflict,
        'A turn is already running for session "$sessionId"',
      );
    }
    // Decode and persist each attachment before the turn starts so the
    // metadata rides on the user message event and the payload is fetchable
    // via `attachments.read`. The wire handler has already validated the
    // base64 and the size caps; the defensive decoding here turns a malformed
    // payload into a clean -32602 instead of an internal error.
    final prepared = <_PreparedAttachment>[];
    for (final attachment in attachments) {
      final List<int> bytes;
      try {
        bytes = base64Decode(attachment.data);
      } on FormatException {
        throw DaemonError(
          _kErrInvalidParams,
          'Attachment "${attachment.name}" carries malformed base64 data',
        );
      }
      final data = AttachmentData(
        id: _uuid.v4(),
        name: attachment.name,
        mimeType: attachment.mimeType,
        size: bytes.length,
        data: attachment.data,
      );
      _store.insertAttachment(sessionId, data);
      prepared.add(_PreparedAttachment(data: data, bytes: bytes));
    }
    final turn = _runTurn(live, text, prepared);
    live.turn = turn;
    try {
      await turn;
    } finally {
      live.turn = null;
    }
  }

  /// In-flight resume attempts, keyed by session id; prevents concurrent
  /// [sendMessage] calls from each spawning their own agent process.
  final Map<String, Future<_LiveSession>> _resuming = {};

  /// Respawns the agent for a session whose process is gone and reloads its
  /// ACP session, making persisted sessions usable across daemon restarts.
  ///
  /// Throws `DaemonError(kErrNotFound)` for unknown sessions and
  /// `DaemonError(kErrConflict)` when the session is closed, predates resume
  /// support (no persisted ACP session id), or its provider cannot resume.
  /// A provider/agent failure during resume marks the session `error` (its
  /// agent-side state is presumed lost) and throws `kErrAgentProcess`.
  Future<_LiveSession> _resume(String sessionId) async {
    final Session? session = _store.getSession(sessionId);
    if (session == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    if (session.status == SessionStatus.closed) {
      throw DaemonError(
        kErrConflict,
        'Session "$sessionId" is closed; create a new session',
      );
    }
    final String? acpSessionId = _store.acpSessionIdOf(sessionId);
    if (acpSessionId == null) {
      throw DaemonError(
        kErrConflict,
        'Session "$sessionId" predates resume support (its agent process '
        'is gone; create a new session)',
      );
    }
    final ProviderSpec? spec = _providers.byId(session.providerId);
    if (spec == null || !_providers.isAvailable(session.providerId)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'Provider "${session.providerId}" is not available on this host',
      );
    }
    final AcpClient client = _spawnAgent(session);
    final List<AcpConfigOption> configOptions;
    try {
      final InitializeResult info = await client.initialized;
      if (info.authMethods.isNotEmpty) {
        await client.authenticate(info.authMethods.first);
      }
      if (info.agentCapabilities['loadSession'] != true) {
        throw DaemonError(
          kErrConflict,
          'Provider "${session.providerId}" cannot resume sessions after a '
          'restart (no ACP session/load support); create a new session',
        );
      }
      configOptions =
          await client.loadSession(sessionId: acpSessionId, cwd: session.cwd);
    } on Object catch (error) {
      await client.dispose();
      if (error is DaemonError) rethrow;
      // The agent lost its own persisted state (or died mid-load): the
      // session's transcript is intact here, but the agent cannot continue
      // it, so the error status is the honest one.
      await _updateSession(
        sessionId,
        (Session s) => _withStatus(s, SessionStatus.error),
      );
      throw DaemonError(
        kErrAgentProcess,
        'Failed to resume session "$sessionId": $error',
      );
    }
    final modelOption = _modelOptionOf(configOptions);
    final thinkingOption = _thinkingOptionOf(configOptions);
    var currentOptions = configOptions;
    var reported = _configSnapshotOf(configOptions);
    if (modelOption == null) {
      // No model option: the persisted model is a plain local preference,
      // not agent state — keep it (and the empty models list) across
      // resumes.
      reported = (
        model: session.model,
        models: session.models,
        thinkingLevel: reported.thinkingLevel,
        thinkingLevels: reported.thinkingLevels,
      );
    }
    final _LiveSession live = _LiveSession(
      session: session,
      client: client,
      acpSessionId: acpSessionId,
      modelConfigId: modelOption?.configId,
      thinkingConfigId: thinkingOption?.configId,
    );
    _live[sessionId] = live;
    // A setMode only persisted the
    // choice; reapply it now. Advisory: a rejecting agent must not fail the
    // resume — the next explicit setMode tries again.
    if (session.mode != SessionMode.build) {
      try {
        await client.setMode(acpSessionId, session.mode.wire);
      } on Object {
        // Best-effort; see comment above.
      }
    }
    // A setModel/setThinkingLevel only persisted the choice too; reconcile
    // both with the freshly loaded agent. Model first: a model switch may
    // change the thinking levels, so each step re-derives the snapshot from
    // the previous step's response. Advisory: a rejecting agent must not
    // fail the resume — the next explicit call tries again. The store is
    // only touched when model/models/thinkingLevel/thinkingLevels actually
    // changed, so a resume does not spam session.updated.
    final String? persistedModel = session.model;
    if (persistedModel != null &&
        persistedModel != reported.model &&
        reported.models.contains(persistedModel) &&
        modelOption != null) {
      try {
        currentOptions = await client.setConfigOption(
          acpSessionId,
          modelOption.configId,
          persistedModel,
        );
      } on Object {
        // Best-effort; keep the load-reported state.
      }
      reported = _configSnapshotOf(currentOptions);
    }
    final String? persistedLevel = session.thinkingLevel;
    if (persistedLevel != null &&
        persistedLevel != reported.thinkingLevel &&
        reported.thinkingLevels.contains(persistedLevel)) {
      final thinking = _thinkingOptionOf(currentOptions);
      if (thinking != null) {
        try {
          currentOptions = await client.setConfigOption(
            acpSessionId,
            thinking.configId,
            persistedLevel,
          );
        } on Object {
          // Best-effort; keep the reported state.
        }
        reported = _configSnapshotOf(currentOptions);
      }
    }
    if (session.model != reported.model ||
        !_sameStringLists(session.models, reported.models) ||
        session.thinkingLevel != reported.thinkingLevel ||
        !_sameStringLists(session.thinkingLevels, reported.thinkingLevels)) {
      await _updateSession(
        sessionId,
        (s) => _withConfigOptions(s, reported),
      );
    }
    return live;
  }

  /// Cancels the running turn of [sessionId] via the agent (resolves pending
  /// permission requests first, per ACP). No-op when idle.
  ///
  /// Parked permission handlers are expired with an error (the agent already
  /// received the cancelled outcome, so the client swallows it); a stale
  /// `respondPermission` afterwards correctly reports `kErrNotFound` instead
  /// of resurrecting the turn.
  Future<void> cancel(String sessionId) async {
    final live = _live[sessionId];
    if (live == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    if (live.turn == null) return;
    await live.client.cancel(live.acpSessionId);
    _expirePendingPermissions(live, 'Permission request cancelled');
  }

  Future<Session> rename(String sessionId, String title) =>
      _updateSession(sessionId, (session) => _withTitle(session, title));

  Future<Session> archive(String sessionId, bool archived) =>
      _updateSession(sessionId, (session) => _withArchived(session, archived));

  /// Switches the agent's session mode and persists it. Sessions without a
  /// live agent are persisted locally; [_resume] reapplies the persisted
  /// mode when the agent is respawned.
  Future<Session> setMode(String sessionId, SessionMode mode) async {
    final live = _live[sessionId];
    if (live != null && live.turn == null) {
      await live.client.setMode(live.acpSessionId, mode.wire);
    }
    return _updateSession(sessionId, (session) => _withMode(session, mode));
  }

  /// Sets the session's model. When the provider advertises a model option
  /// (ACP), the choice is validated against the advertised models and, with
  /// a live idle agent, forwarded (`session/set_config_option`); the
  /// response — authoritative for ALL config-backed fields — is adopted.
  /// Sessions without a live agent persist the requested model locally and
  /// [_resume] reapplies it. When the provider advertises no model option,
  /// any string is accepted as a local preference and never forwarded.
  ///
  /// Errors `-32602` when the provider advertises a model option but
  /// [model] is not among the advertised models.
  Future<Session> setModel(String sessionId, String model) async {
    final session = _store.getSession(sessionId);
    if (session == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final models = session.models;
    if (models.isNotEmpty && !models.contains(model)) {
      // No enumeration of the valid ids: providers like omp advertise
      // hundreds of models, which would flood the error message.
      throw DaemonError(
        _kErrInvalidParams,
        'Unknown model "$model" for provider "${session.providerId}" '
            '(${models.length} models advertised)',
      );
    }
    final live = _live[sessionId];
    if (models.isNotEmpty &&
        live != null &&
        live.turn == null &&
        live.modelConfigId != null) {
      final configOptions = await live.client.setConfigOption(
        live.acpSessionId,
        live.modelConfigId!,
        model,
      );
      // The agent may adjust more than the requested option (a model switch
      // can carry new thinking levels); its report is adopted wholesale.
      return _updateSession(
        sessionId,
        (current) => _withConfigOptions(current, _configSnapshotOf(configOptions)),
      );
    }
    // No live agent (or no model option): a local preference, models
    // unchanged; [_resume] reapplies model choices to a resumed agent.
    return _updateSession(sessionId, (current) => _withModel(current, model));
  }

  /// Switches the session's thinking level and persists the agent-reported
  /// state. When a live agent is idle and exposes the thinking option, the
  /// choice is forwarded (`session/set_config_option`) and the response —
  /// authoritative for ALL config-backed fields — is adopted wholesale;
  /// sessions without a live agent persist the requested level locally and
  /// [_resume] reapplies it.
  ///
  /// Errors `-32602` when the provider exposes no thinking level option or
  /// [level] is not among the advertised levels.
  Future<Session> setThinkingLevel(String sessionId, String level) async {
    final session = _store.getSession(sessionId);
    if (session == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final levels = session.thinkingLevels;
    if (levels.isEmpty) {
      throw DaemonError(
        _kErrInvalidParams,
        'Provider "${session.providerId}" does not expose a thinking level '
        'option',
      );
    }
    if (!levels.contains(level)) {
      throw DaemonError(
        _kErrInvalidParams,
        'Unknown thinking level "$level" for provider '
        '"${session.providerId}": valid levels are ${levels.join(', ')}',
      );
    }
    final live = _live[sessionId];
    if (live != null && live.turn == null && live.thinkingConfigId != null) {
      final configOptions = await live.client.setConfigOption(
        live.acpSessionId,
        live.thinkingConfigId!,
        level,
      );
      // The agent may clamp the requested value or revise any other
      // config-backed field; its report is adopted wholesale.
      return _updateSession(
        sessionId,
        (current) => _withConfigOptions(current, _configSnapshotOf(configOptions)),
      );
    }
    // No live agent: persist the requested level locally (levels unchanged);
    // [_resume] reapplies it.
    return _updateSession(
      sessionId,
      (current) => _withThinking(current, level, levels),
    );
  }

  /// Resolves a parked permission request. Unknown/expired requests error
  /// `kErrNotFound` (per PROTOCOL.md `sessions.respondPermission`).
  ///
  /// Parked requests are expired (completed with an error and cleared) when
  /// the agent's process dies mid-turn, on delete, and on dispose, so a stale
  /// `respondPermission` after the fact reads as `kErrNotFound` — it can
  /// never revive a dead session's turn. A request that is somehow still
  /// parked on a session already in `error`/`closed` status is refused with
  /// `kErrConflict` instead of being resolved.
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  ) async {
    final live = _live[sessionId];
    if (live == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final completer = live.pendingPermissions.remove(requestId);
    if (completer == null) {
      // Covers never-parked ids, expired ids, and stale ids on sessions whose
      // agent died (the pending set was cleared when the turn errored).
      throw DaemonError(
        kErrNotFound,
        'Unknown or expired permission request: $requestId',
      );
    }
    if (live.session.status == SessionStatus.error ||
        live.session.status == SessionStatus.closed) {
      // The agent this request belonged to is gone; resolving it would flip
      // the session back towards running without an agent behind it.
      throw DaemonError(
        kErrConflict,
        'Session "$sessionId" is not waiting for a permission '
        '(its agent process is gone; create a new session)',
      );
    }
    // The resolved event + status flip happen inside the parked handler as it
    // resumes and returns the option to the agent.
    completer.complete(optionId);
  }

  /// Kills the agent (if alive), removes the session and its events, and
  /// emits a removal notification.
  Future<void> delete(String sessionId) async {
    final live = _live.remove(sessionId);
    if (live == null && _store.getSession(sessionId) == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    if (live != null) {
      live.closed = true;
      // Expire parked permissions first: a stale respondPermission must not
      // observe them as resolvable once the session is gone.
      _expirePendingPermissions(live, 'Session deleted');
      _toolCalls.remove(sessionId);
      await live.client.dispose();
    }
    _store.deleteSession(sessionId);
    if (!_sessionRemovalsController.isClosed) {
      _sessionRemovalsController.add(sessionId);
    }
  }

  /// Kills every agent process and closes the broadcast streams.
  Future<void> dispose() async {
    for (final live in _live.values) {
      live.closed = true;
      _expirePendingPermissions(live, 'Daemon shutting down');
      await live.client.dispose();
    }
    _live.clear();
    _toolCalls.clear();
    if (!_eventsController.isClosed) _eventsController.close();
    if (!_sessionChangesController.isClosed) _sessionChangesController.close();
    if (!_sessionRemovalsController.isClosed) _sessionRemovalsController.close();
  }

  // -------------------------------------------------------------------------
  // Turn machinery
  // -------------------------------------------------------------------------

  Future<void> _runTurn(
    _LiveSession live,
    String text,
    List<_PreparedAttachment> attachments,
  ) async {
    final sessionId = live.sessionId;
    _toolCalls[sessionId] = <String, ToolCall>{};
    _emit(
      live,
      UserMessageEvent(
        text: text,
        // AttachmentData is an Attachment; only the metadata fields are
        // serialized by Attachment.toJson (no payload).
        attachments: [for (final prepared in attachments) prepared.data],
      ),
    );
    // A session still carrying the default title is named from this, its
    // first user message (see PROTOCOL.md `sessions.send`). Explicit titles
    // — creation `title` or a prior `sessions.rename` — are never clobbered,
    // and an attachment-only turn (empty text) leaves the default in place.
    if (live.session.title == kDefaultSessionTitle) {
      final String derivedTitle = _titleFromMessage(text);
      if (derivedTitle.isNotEmpty) {
        _setTitle(live, derivedTitle);
      }
    }
    _setStatus(live, SessionStatus.running);

    final updates = live.client.sessionUpdates(live.acpSessionId);
    final subscription = updates.listen((update) {
      final event = _mapUpdate(live, update);
      if (event != null) _emit(live, event);
    });

    try {
      final result = await live.client.prompt(
        live.acpSessionId,
        _promptBlocks(text, attachments),
      );
      _emit(live, TurnCompleteEvent(stopReason: result.stopReason));
      _setStatus(live, SessionStatus.idle);
    } on Object catch (error) {
      if (!live.closed) {
        // The agent is gone (process exit / stream failure). Expire every
        // parked permission first so a stale respondPermission reports
        // kErrNotFound and cannot flip the dead session back to running.
        _expirePendingPermissions(live, 'Agent process ended: $error');
        _emit(live, SessionErrorEvent(message: 'Agent process ended: $error'));
        _setStatus(live, SessionStatus.error);
      }
    } finally {
      await subscription.cancel();
    }
  }

  /// The ACP prompt content blocks for a turn: an optional leading text block
  /// (only when [text] is non-empty), then one block per [attachments] — an
  /// `image` block for images, and an embedded `resource` block for anything
  /// else (inline `text` for text mime types, base64 `blob` otherwise). The
  /// resource URI is stable per attachment id so an agent can reference the
  /// file across requests.
  static List<Map<String, Object?>> _promptBlocks(
    String text,
    List<_PreparedAttachment> attachments,
  ) {
    final blocks = <Map<String, Object?>>[];
    if (text.isNotEmpty) {
      blocks.add(<String, Object?>{'type': 'text', 'text': text});
    }
    for (final prepared in attachments) {
      final data = prepared.data;
      if (isImageMimeType(data.mimeType)) {
        blocks.add(<String, Object?>{
          'type': 'image',
          'data': data.data,
          'mimeType': data.mimeType,
        });
        continue;
      }
      final resource = <String, Object?>{
        'uri': 'speeddial-attachment:///${data.id}/'
            '${Uri.encodeComponent(data.name)}',
        'mimeType': data.mimeType,
      };
      if (isTextMimeType(data.mimeType)) {
        resource['text'] = utf8.decode(prepared.bytes);
      } else {
        resource['blob'] = data.data;
      }
      blocks.add(<String, Object?>{'type': 'resource', 'resource': resource});
    }
    return blocks;
  }

  /// Completes and clears every parked permission request for [live]. Called
  /// when a turn errors (agent death), on cancel (the agent already received
  /// the cancelled outcome), on delete, and on dispose. A stale
  /// `respondPermission` afterwards correctly reports `kErrNotFound` instead
  /// of resuming a dead turn.
  void _expirePendingPermissions(_LiveSession live, String reason) {
    for (final completer in live.pendingPermissions.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(reason));
      }
    }
    live.pendingPermissions.clear();
  }

  SessionEvent? _mapUpdate(_LiveSession live, AcpSessionUpdate update) {
    final sessionId = live.sessionId;
    switch (update) {
      case final AcpAgentMessageChunk chunk:
        return AgentMessageChunkEvent(text: chunk.text);
      case final AcpAgentThoughtChunk chunk:
        return AgentThoughtChunkEvent(text: chunk.text);
      case AcpUserMessageChunk():
        return null; // Echo of the user's own text; not persisted.
      case final AcpToolCall toolCall:
        final mapped = toolCallFromAcp(toolCall.toolCall, cwd: live.cwd);
        _toolCalls[sessionId]?[mapped.id] = mapped;
        return ToolCallEvent(toolCall: mapped);
      case final AcpToolCallUpdate toolCallUpdate:
        final toolCallId = toolCallUpdate.toolCallId;
        final prior = _toolCalls[sessionId]?[toolCallId];
        final merged = prior == null
            ? toolCallFromAcpUpdate(
                toolCallId, toolCallUpdate.fields, cwd: live.cwd)
            : mergeToolCallUpdate(prior, toolCallUpdate, cwd: live.cwd);
        _toolCalls[sessionId]?[toolCallId] = merged;
        return ToolCallEvent(toolCall: merged);
      case final AcpPlan plan:
        return planEventFromAcp(plan);
      case final AcpUsageUpdate usage:
        return usageEventFromAcp(usage);
      case AcpAvailableCommandsUpdate():
      case AcpCurrentModeUpdate():
        return null; // Not part of the protocol event stream.
    }
  }

  Future<String> _onPermissionRequest(
    String sessionId,
    String? toolCallId,
    String title,
    List<PermissionOptionData> options,
  ) async {
    final live = _live[sessionId];
    if (live == null) {
      throw StateError('Permission request for unknown session: $sessionId');
    }
    final requestId = _uuid.v4();
    final mapped = permissionOptionsFromAcp(options);
    // Yolo sessions resolve the request themselves: the first allow_always
    // option wins, then the first allow_once. The request/resolved events are
    // still emitted (back-to-back, without the waitingPermission status) so
    // the transcript records what was auto-approved. A request with no allow
    // option falls through to the normal parked flow.
    if (live.session.yolo) {
      PermissionOption? allow;
      for (final option in mapped) {
        if (option.kind == PermissionKind.allowAlways) {
          allow = option;
          break;
        }
        if (option.kind == PermissionKind.allowOnce && allow == null) {
          allow = option;
        }
      }
      if (allow != null) {
        _emit(
          live,
          PermissionRequestEvent(
            request: PermissionRequest(
              requestId: requestId,
              toolCallId: toolCallId,
              title: title,
              options: mapped,
            ),
          ),
        );
        _emit(
          live,
          PermissionResolvedEvent(
            requestId: requestId,
            optionId: allow.optionId,
          ),
        );
        return allow.optionId;
      }
    }
    final completer = Completer<String>();
    live.pendingPermissions[requestId] = completer;
    _emit(
      live,
      PermissionRequestEvent(
        request: PermissionRequest(
          requestId: requestId,
          toolCallId: toolCallId,
          title: title,
          options: mapped,
        ),
      ),
    );
    _setStatus(live, SessionStatus.waitingPermission);
    final optionId = await completer.future;
    _emit(live, PermissionResolvedEvent(requestId: requestId, optionId: optionId));
    _setStatus(live, SessionStatus.running);
    return optionId;
  }

  // -------------------------------------------------------------------------
  // fs/read+write delegation (sandboxed to the session cwd)
  // -------------------------------------------------------------------------

  Future<String> _readTextFile(String sessionId, String path) async {
    final file = _resolveInCwd(sessionId, path);
    return file.readAsString();
  }

  Future<void> _writeTextFile(
    String sessionId,
    String path,
    String content,
  ) async {
    final file = _resolveInCwd(sessionId, path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  /// The symlink-resolved real path of [path], or of its deepest existing
  /// ancestor when [path] itself does not exist yet.
  String _realPathOfDeepestExisting(String path) {
    var current = p.normalize(p.absolute(path));
    while (true) {
      try {
        return File(current).resolveSymbolicLinksSync();
      } on FileSystemException {
        final parent = p.dirname(current);
        if (parent == current) rethrow; // Reached the filesystem root.
        current = parent;
      }
    }
  }

  /// Turns a session title into a git-branch-safe slug (`[a-z0-9-]`, max 32
  /// chars); null when nothing usable remains.
  static String? _branchSlug(String? title) {
    if (title == null) return null;
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('-{2,}'), '-')
        .replaceAll(RegExp('^-+|-+\$'), '');
    if (slug.isEmpty) return null;
    if (slug.length <= 32) return slug;
    // Truncation may cut mid-word and leave a dangling '-'.
    return slug.substring(0, 32).replaceAll(RegExp('-+\$'), '');
  }

  /// Derives an auto-title from a user message: its first line,
  /// whitespace-collapsed, capped at 60 characters (the pre-overhaul
  /// new-session sheet behavior). Empty when the message carries no text
  /// (e.g. attachments only).
  static String _titleFromMessage(String text) {
    final String firstLine =
        text.split('\n').first.trim().replaceAll(RegExp(r'\s+'), ' ');
    return firstLine.length <= 60
        ? firstLine
        : '${firstLine.substring(0, 60)}…';
  }

  /// Resolves [requested] against the session cwd and rejects anything that
  /// escapes it (the thrown error becomes a JSON-RPC error response to the
  /// agent). Symlink escapes are not guarded; that is a follow-up concern.
  File _resolveInCwd(String sessionId, String requested) {
    final live = _live[sessionId];
    if (live == null) {
      throw StateError('Unknown session: $sessionId');
    }
    final cwdNorm = p.normalize(p.absolute(live.cwd));
    final candidate = p.isAbsolute(requested)
        ? p.normalize(requested)
        : p.normalize(p.join(cwdNorm, requested));
    final prefix = cwdNorm.endsWith(p.separator)
        ? cwdNorm
        : '$cwdNorm${p.separator}';
    if (candidate == cwdNorm || candidate.startsWith(prefix)) {
      return File(candidate);
    }
    throw const FormatException(
      'Path escapes the session working directory',
    );
  }

  // -------------------------------------------------------------------------
  // Metadata / persistence helpers
  // -------------------------------------------------------------------------

  Future<Session> _updateSession(
    String sessionId,
    Session Function(Session current) transform,
  ) async {
    final session = _store.getSession(sessionId);
    if (session == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final updated = transform(session);
    _store.updateSession(updated);
    final live = _live[sessionId];
    if (live != null) live.session = updated;
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(updated);
    }
    return updated;
  }

  /// Persists [event] under the next sequence number and broadcasts it as a
  /// (sessionId, seq, event) tuple. Fully synchronous: store access and
  /// stream delivery cannot interleave.
  void _emit(_LiveSession live, SessionEvent event) {
    final seq = _store.nextSeq(live.sessionId);
    final persisted = _store.appendEvent(live.sessionId, seq, event);
    if (!_eventsController.isClosed) {
      _eventsController.add((
        sessionId: live.sessionId,
        seq: seq,
        event: persisted,
      ));
    }
  }

  void _setStatus(_LiveSession live, SessionStatus status) {
    final updated = _withStatus(live.session, status);
    live.session = updated;
    _store.updateSession(updated);
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(updated);
    }
  }

  /// Synchronous title update mirroring [_setStatus]. The auto-title in
  /// [_runTurn] must not introduce an await between the userMessage emit
  /// and the agent prompt — a cancel racing the send would otherwise reach
  /// the agent before its own prompt.
  void _setTitle(_LiveSession live, String title) {
    final updated = _withTitle(live.session, title);
    live.session = updated;
    _store.updateSession(updated);
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(updated);
    }
  }

  Session _withStatus(Session session, SessionStatus status) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: status,
        mode: session.mode,
        model: session.model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: session.thinkingLevel,
        thinkingLevels: session.thinkingLevels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  Session _withTitle(Session session, String title) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: title,
        status: session.status,
        mode: session.mode,
        model: session.model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: session.thinkingLevel,
        thinkingLevels: session.thinkingLevels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  Session _withArchived(Session session, bool archived) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: session.status,
        mode: session.mode,
        model: session.model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: session.thinkingLevel,
        thinkingLevels: session.thinkingLevels,
        yolo: session.yolo,
        archived: archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  Session _withMode(Session session, SessionMode mode) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: session.status,
        mode: mode,
        model: session.model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: session.thinkingLevel,
        thinkingLevels: session.thinkingLevels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  Session _withModel(Session session, String model) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: session.status,
        mode: session.mode,
        model: model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: session.thinkingLevel,
        thinkingLevels: session.thinkingLevels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  Session _withThinking(Session session, String? level, List<String> levels) =>
      Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: session.status,
        mode: session.mode,
        model: session.model,
        models: session.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: level,
        thinkingLevels: levels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  /// Copies [session] adopting [snapshot]'s model/thinking state wholesale:
  /// a `session/set_config_option` response is authoritative for ALL
  /// config-backed fields (a model switch may carry new thinking levels).
  Session _withConfigOptions(Session session, _ConfigSnapshot snapshot) =>
      Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: session.status,
        mode: session.mode,
        model: snapshot.model,
        models: snapshot.models,
        cwd: session.cwd,
        baseBranch: session.baseBranch,
        thinkingLevel: snapshot.thinkingLevel,
        thinkingLevels: snapshot.thinkingLevels,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );

  /// The thinking-level config option among [options], per the protocol
  /// contract: the first select-type option whose category is
  /// `thought_level`, else the first whose id is `thinking`, else null for
  /// unsupported providers. Only select-type options with a non-empty
  /// options list count. [current] is the option's currentValue (null when
  /// empty); [levels] are the option values in order.
  static ({String configId, String? current, List<String> levels})?
      _thinkingOptionOf(List<AcpConfigOption> options) {
    AcpConfigOption? thinking;
    for (final option in options) {
      if (option.type == 'select' &&
          option.options.isNotEmpty &&
          option.category == 'thought_level') {
        thinking = option;
        break;
      }
    }
    if (thinking == null) {
      for (final option in options) {
        if (option.type == 'select' &&
            option.options.isNotEmpty &&
            option.id == 'thinking') {
          thinking = option;
          break;
        }
      }
    }
    if (thinking == null) return null;
    return (
      configId: thinking.id,
      current: thinking.currentValue.isEmpty ? null : thinking.currentValue,
      levels: <String>[for (final value in thinking.options) value.value],
    );
  }

  /// The model config option among [options], per the protocol contract:
  /// the first select-type option whose category is `model`, else the first
  /// whose id is `model`, else null for providers that advertise none. Only
  /// select-type options with a non-empty options list count. [current] is
  /// the option's currentValue (null when empty); [levels] are the option
  /// values in order.
  static ({String configId, String? current, List<String> levels})?
      _modelOptionOf(List<AcpConfigOption> options) {
    AcpConfigOption? model;
    for (final option in options) {
      if (option.type == 'select' &&
          option.options.isNotEmpty &&
          option.category == 'model') {
        model = option;
        break;
      }
    }
    if (model == null) {
      for (final option in options) {
        if (option.type == 'select' &&
            option.options.isNotEmpty &&
            option.id == 'model') {
          model = option;
          break;
        }
      }
    }
    if (model == null) return null;
    return (
      configId: model.id,
      current: model.currentValue.isEmpty ? null : model.currentValue,
      levels: <String>[for (final value in model.options) value.value],
    );
  }

  static bool _sameStringLists(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Maps [options] to the config-backed session fields: the model and
  /// thinking current values plus their advertised option lists.
  static _ConfigSnapshot _configSnapshotOf(List<AcpConfigOption> options) {
    final model = _modelOptionOf(options);
    final thinking = _thinkingOptionOf(options);
    return (
      model: model?.current,
      models: model?.levels ?? const <String>[],
      thinkingLevel: thinking?.current,
      thinkingLevels: thinking?.levels ?? const <String>[],
    );
  }
}
