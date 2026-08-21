/// [SessionEngine]: owns live provider processes per session and maps their
/// updates onto protocol [SessionEvent]s, persisting every event with a
/// per-session sequence number and broadcasting it.
///
/// Lifecycle:
///   * `createSession` spawns the selected provider transport in the session
///     cwd, creates a provider session, and persists an idle protocol session.
///   * `sendMessage` runs a turn: user message event (with attachment metadata
///     when supported files were attached), status `running`, mapped provider
///     updates (chunks, tools, activities, plan, usage) streamed and persisted,
///     permission requests parked until `respondPermission`, then
///     `turnComplete` and status `idle`.
///   * `cancel` cancels the running turn via the agent.
///   * `delete` kills the agent and removes the session (and its events).
///
/// Daemon restarts: the provider-side session id is persisted at creation, so
/// `sendMessage` can lazily respawn the transport and resume that session
/// ([SessionEngine.restore] only flags sessions interrupted mid-turn).
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
import '../agents/agent_client.dart';
import '../ante/ante_client.dart';
import '../codex/codex_client.dart';
import '../git/git_service.dart';
import '../mcp/built_in_mcp_server.dart';
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
    required this.providerSessionId,
    this.modelConfigId,
    this.thinkingConfigId,
  });

  Session session;
  final AgentClient client;
  final String providerSessionId;

  /// The config option id of the provider's model, null when the provider
  /// exposes none.
  final String? modelConfigId;

  /// The config option id of the provider's thinking/effort level, null when
  /// the provider exposes none.
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
/// decoded text when the payload is text-like.
class _PreparedAttachment {
  _PreparedAttachment({required this.data, required this.text});

  final AttachmentData data;
  final String? text;
}

/// Provider prompt context prepared from the copied history of a fork.
typedef _ForkContext = ({
  String transcript,
  List<_PreparedAttachment> attachments,
});
typedef _BuiltInMcpConfig = ({
  String daemonUrl,
  String Function(Session session) secretForSession,
  String command,
  List<String> args,
});

/// Orchestrates agent transports and the project session lifecycle.
class SessionEngine {
  SessionEngine({
    required DaemonStore store,
    required ProviderRegistry providers,
    GitService? git,
  }) : _store = store, // ignore: prefer_initializing_formals
       _providers = providers, // ignore: prefer_initializing_formals
       _git = git; // ignore: prefer_initializing_formals

  final DaemonStore _store;
  final ProviderRegistry _providers;

  /// Git operations for per-session worktrees (`baseBranch` on
  /// [createSession]); null only in tests that never pass a base branch.
  final GitService? _git;
  final Uuid _uuid = const Uuid();

  final Map<String, _LiveSession> _live = {};
  _BuiltInMcpConfig? _builtInMcp;
  Future<void> Function()? _prepareMcpServers;

  /// Configures the daemon-owned MCP stdio server that is included in every
  /// subsequent provider session creation or resume.
  void configureBuiltInMcp({
    required String daemonUrl,
    required String Function(Session session) secretForSession,
    required String command,
    required List<String> args,
  }) {
    _builtInMcp = (
      daemonUrl: daemonUrl,
      secretForSession: secretForSession,
      command: command,
      args: List<String>.unmodifiable(args),
    );
  }

  /// Configures daemon-owned authentication preparation for remote MCP
  /// servers. Called immediately before every provider session start/resume.
  void configureMcpAuth({required Future<void> Function() prepare}) {
    _prepareMcpServers = prepare;
  }

  List<Map<String, Object?>> _mcpServersFor(
    Session session,
    InitializeResult info,
  ) {
    if (info.agentCapabilities['mcpServers'] == false) {
      return const <Map<String, Object?>>[];
    }
    final _BuiltInMcpConfig? builtIn = _builtInMcp;
    if (builtIn == null) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      <String, Object?>{
        'name': kMcpServerName,
        'command': builtIn.command,
        'args': builtIn.args,
        'env': <Object?>[
          <String, Object?>{
            'name': kMcpDaemonUrlEnv,
            'value': builtIn.daemonUrl,
          },
          <String, Object?>{
            'name': kMcpSecretEnv,
            'value': builtIn.secretForSession(session),
          },
          <String, Object?>{'name': kMcpSessionIdEnv, 'value': session.id},
          <String, Object?>{'name': kMcpSessionCwdEnv, 'value': session.cwd},
        ],
      },
    ];
  }

  final Set<String> _mcpReloadPending = <String>{};

  /// Disconnects idle, reload-capable agents so their next turn resumes with
  /// the current daemon-managed MCP list. Running turns are marked and parked
  /// before their next prompt. Agents without `session/load` keep their current
  /// connections; saved changes still apply to all newly created sessions.
  Future<void> reloadMcpServers({String? projectId}) async {
    for (final _LiveSession live in _live.values.toList(growable: false)) {
      if (projectId != null && live.session.projectId != projectId) continue;
      if (live.turn != null) {
        _mcpReloadPending.add(live.session.id);
        continue;
      }
      await _parkForMcpReload(live);
    }
  }

  Future<bool> _parkForMcpReload(_LiveSession live) async {
    final InitializeResult info = await live.client.initialized;
    if (info.agentCapabilities['mcpServers'] == false) return false;
    if (info.agentCapabilities['loadSession'] != true) return false;
    final String sessionId = live.session.id;
    if (!identical(_live[sessionId], live)) return false;
    _live.remove(sessionId);
    _mcpReloadPending.remove(sessionId);
    live.closed = true;
    await live.client.dispose();
    return true;
  }

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
        _eventsController.add((sessionId: session.id, seq: seq, event: event));
      }
      if (!_sessionChangesController.isClosed) {
        _sessionChangesController.add(updated);
      }
    }
  }

  /// Creates a new protocol session and spawns its provider transport.
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
    SessionSandboxMode? sandboxMode,
    bool yolo = false,
  }) async {
    final spec = _providers.byId(providerId);
    if (spec == null) {
      throw DaemonError(
        kErrProviderUnavailable,
        'Unknown provider: $providerId',
      );
    }
    if (!_providers.isAvailable(providerId)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'Provider "$providerId" is not available on this host',
      );
    }
    final SessionSandboxMode? effectiveSandboxMode = switch (spec.protocol) {
      ProviderProtocol.codex =>
        sandboxMode ?? SessionSandboxMode.workspaceWrite,
      _ when sandboxMode == null => null,
      _ => throw DaemonError(
        _kErrInvalidParams,
        'Provider "$providerId" does not support sandboxMode',
      ),
    };
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
      final String baseRef = await git.worktreeBaseRef(
        project.path,
        baseBranch,
      );
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
      sandboxMode: effectiveSandboxMode,
      yolo: yolo,
      archived: false,
      createdAt: now,
      lastActivityAt: now,
      updatedAt: now,
    );
    return _createPreparedSession(
      baseSession,
      requestedModel: model,
      rollbackProjectPath: project.path,
      rollbackWorktreePath: worktreePath,
    );
  }

  /// Creates a fresh provider session whose visible history is copied from
  /// [sourceSessionId] through the user/agent message event [throughSeq].
  ///
  /// The provider itself starts empty. The copied conversation is retained as
  /// a pending inherited context and injected with the fork's first new turn,
  /// which makes arbitrary-message forks independent of ACP `session/fork`.
  Future<Session> forkSession({
    required String sourceSessionId,
    required int throughSeq,
  }) async {
    final Session? source = _store.getSession(sourceSessionId);
    if (source == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sourceSessionId');
    }
    final SessionEvent? boundary = _store.eventAt(sourceSessionId, throughSeq);
    if (boundary is! UserMessageEvent && boundary is! AgentMessageChunkEvent) {
      throw DaemonError(
        _kErrInvalidParams,
        'seq must identify a user or agent message event',
      );
    }
    final ProviderSpec? spec = _providers.byId(source.providerId);
    if (spec == null || !_providers.isAvailable(source.providerId)) {
      throw DaemonError(
        kErrProviderUnavailable,
        'Provider "${source.providerId}" is not available on this host',
      );
    }
    if (_store.getProject(source.projectId) == null) {
      throw DaemonError(kErrNotFound, 'Unknown project: ${source.projectId}');
    }

    final now = DateTime.now().toUtc();
    final baseSession = Session(
      id: _uuid.v4(),
      projectId: source.projectId,
      providerId: source.providerId,
      title: 'Fork of ${source.title}',
      status: SessionStatus.idle,
      mode: source.mode,
      model: source.model,
      cwd: source.cwd,
      baseBranch: source.baseBranch,
      sandboxMode: source.sandboxMode,
      yolo: source.yolo,
      archived: false,
      createdAt: now,
      lastActivityAt: now,
      updatedAt: now,
    );
    final Session created = await _createPreparedSession(
      baseSession,
      requestedModel: source.model,
    );
    try {
      _copyForkHistory(source.id, created.id, throughSeq);
      _store.setForkContextSeq(created.id, throughSeq);

      // session/new starts in provider defaults. Preserve the source mode and
      // thinking selection when the new agent accepts them; these settings
      // are advisory for the same reason as resume-time reapplication.
      if (source.mode != SessionMode.build) {
        try {
          await setMode(created.id, source.mode);
        } on Object {
          // The persisted mode already matches the source.
        }
      }
      final String? thinkingLevel = source.thinkingLevel;
      if (thinkingLevel != null &&
          created.thinkingLevels.contains(thinkingLevel)) {
        try {
          await setThinkingLevel(created.id, thinkingLevel);
        } on Object {
          // Keep the provider-reported default when it rejects the source.
        }
      }
      return _store.getSession(created.id)!;
    } on Object {
      // The fork was never announced as created. Tear it down without
      // publishing a removal notification for an id clients never observed.
      final _LiveSession? live = _live.remove(created.id);
      if (live != null) {
        live.closed = true;
        await live.client.dispose();
      }
      _store.deleteSession(created.id);
      rethrow;
    }
  }

  /// Starts the ACP side of an already validated protocol session, adopts its
  /// config options, persists both ids, and publishes the created session.
  Future<Session> _createPreparedSession(
    Session baseSession, {
    String? requestedModel,
    String? rollbackProjectPath,
    String? rollbackWorktreePath,
  }) async {
    final client = _spawnAgent(baseSession);
    final String providerSessionId;
    final Session session;
    ({String configId, String? current, List<String> levels})? modelOption;
    ({String configId, String? current, List<String> levels})? thinking;
    try {
      final info = await client.initialized;
      if (info.authMethods.isNotEmpty) {
        await client.authenticate(info.authMethods.first);
      }
      if (info.agentCapabilities['mcpServers'] != false) {
        await _prepareMcpServers?.call();
      }
      final created = await client.newSession(
        cwd: baseSession.cwd,
        mcpServers: _mcpServersFor(baseSession, info),
        model: requestedModel,
        sandboxMode: baseSession.sandboxMode,
        yolo: baseSession.yolo,
      );
      providerSessionId = created.sessionId;
      modelOption = _modelOptionOf(created.configOptions);
      thinking = _thinkingOptionOf(created.configOptions);
      var adoptedOptions = created.configOptions;
      if (modelOption != null &&
          requestedModel != null &&
          modelOption.current != requestedModel) {
        try {
          adoptedOptions = await client.setConfigOption(
            providerSessionId,
            modelOption.configId,
            requestedModel,
          );
        } on Object {
          // Fall through to the pre-call reported state.
        }
      }
      var snapshot = _configSnapshotOf(adoptedOptions);
      if (modelOption == null) {
        snapshot = (
          model: requestedModel,
          models: const <String>[],
          thinkingLevel: snapshot.thinkingLevel,
          thinkingLevels: snapshot.thinkingLevels,
        );
      }
      session = _withConfigOptions(baseSession, snapshot);
    } on Object catch (error) {
      await client.dispose();
      if (rollbackWorktreePath != null && rollbackProjectPath != null) {
        try {
          await _git!.removeWorktree(rollbackProjectPath, rollbackWorktreePath);
        } on Object {
          // Rollback is best-effort; the spawn error is the real failure.
        }
      }
      throw DaemonError(
        kErrAgentProcess,
        'Failed to start provider "${baseSession.providerId}": $error',
      );
    }
    _store.insertSession(session);
    _store.setProviderSessionId(session.id, providerSessionId);
    _live[session.id] = _LiveSession(
      session: session,
      client: client,
      providerSessionId: providerSessionId,
      modelConfigId: modelOption?.configId,
      thinkingConfigId: thinking?.configId,
    );
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(session);
    }
    return session;
  }

  /// Copies visible history and attachment payloads into a fork. Event
  /// sequence numbers remain identical through the boundary, so the copied
  /// transcript is immediately page-compatible with the source.
  void _copyForkHistory(
    String sourceSessionId,
    String targetSessionId,
    int throughSeq,
  ) {
    Attachment copyAttachment(Attachment attachment) {
      final AttachmentData? data = _store.getAttachment(
        sourceSessionId,
        attachment.id,
      );
      if (data == null) {
        throw StateError('Missing attachment payload for ${attachment.id}');
      }
      final AttachmentData copied = AttachmentData(
        id: _uuid.v4(),
        name: data.name,
        mimeType: data.mimeType,
        size: data.size,
        data: data.data,
      );
      _store.insertAttachment(targetSessionId, copied);
      return copied;
    }

    for (final SessionEvent event in _store.eventsThrough(
      sourceSessionId,
      throughSeq,
    )) {
      final SessionEvent copy;
      if (event case UserMessageEvent(:final text, :final attachments)) {
        copy = UserMessageEvent(
          text: text,
          attachments: attachments.map(copyAttachment).toList(growable: false),
        );
      } else if (event case ImageEvent(:final attachment)) {
        copy = ImageEvent(attachment: copyAttachment(attachment));
      } else {
        final json = Map<String, Object?>.from(event.toJson())
          ..remove('seq')
          ..remove('timestamp');
        copy = SessionEvent.fromJson(json);
      }
      _store.appendEvent(targetSessionId, event.seq!, copy);
    }
  }

  /// Spawns the configured agent transport in [session.cwd], wired to the
  /// engine's permission and filesystem handlers where supported.
  AgentClient _spawnAgent(Session session) {
    final ProviderSpec spec = _providers.byId(session.providerId)!;
    Future<String> permissionHandler(
      String providerSessionId,
      String? toolCallId,
      String requestTitle,
      List<PermissionOptionData> options,
    ) => _onPermissionRequest(session.id, toolCallId, requestTitle, options);
    return switch (spec.protocol) {
      ProviderProtocol.acp => AcpClient.spawn(
        spec.command,
        cwd: session.cwd,
        requestPermission: permissionHandler,
        readTextFile: (providerSessionId, path) =>
            _readTextFile(session.id, path),
        writeTextFile: (providerSessionId, path, content) =>
            _writeTextFile(session.id, path, content),
      ),
      ProviderProtocol.codex => CodexClient.spawn(
        spec.command,
        cwd: session.cwd,
        requestPermission: permissionHandler,
      ),
      ProviderProtocol.ante => AnteClient.spawn(
        spec.command,
        cwd: session.cwd,
        catalogCommand: spec.catalogCommand,
        requestPermission: permissionHandler,
      ),
    };
  }

  /// Persists an agent-requested image and emits it into the session timeline.
  /// This does not start/resume the provider process or change turn state.
  Future<void> displayImage(
    String sessionId, {
    required String name,
    required String mimeType,
    required String data,
  }) async {
    if (_store.getSession(sessionId) == null) {
      throw DaemonError(kErrNotFound, 'Unknown session: $sessionId');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw DaemonError(_kErrInvalidParams, 'Invalid base64 image data');
    }
    if (!isImageMimeType(mimeType) || bytes.length > kMaxAttachmentBytes) {
      throw DaemonError(_kErrInvalidParams, 'Invalid image attachment');
    }
    final AttachmentData attachment = AttachmentData(
      id: _uuid.v4(),
      name: name,
      mimeType: mimeType,
      size: bytes.length,
      data: data,
    );
    _store.insertAttachment(sessionId, attachment);
    _emitForSession(
      sessionId,
      ImageEvent(
        attachment: Attachment(
          id: attachment.id,
          name: attachment.name,
          mimeType: attachment.mimeType,
          size: attachment.size,
        ),
      ),
    );
  }

  /// Starts a turn for [text] with the attached files. When the session's
  /// agent process is gone (daemon restarted), the agent is first respawned
  /// and resumed via ACP `session/load` — see [_resume]. Errors
  /// `kErrConflict` when a turn is already running or the session cannot be
  /// resumed (closed, predates resume support, or the provider lacks
  /// `session/load`).
  ///
  /// The returned future resolves as soon as the user message is persisted
  /// and the turn is started (status `running`) — not when the agent
  /// finishes. Turn output arrives as live `session.event` notifications,
  /// so the request itself must not stay in flight for the whole turn: a
  /// client that backgrounds the app mid-turn would otherwise see the socket
  /// drop error its still-pending `sessions.send` and restore the draft over
  /// a message the daemon already received (PROTOCOL.md: turn-start ack).
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const <OutgoingAttachment>[],
  }) async {
    // Concurrent sends to the same not-live session share one resume.
    _LiveSession? live = _live[sessionId];
    if (live != null && _mcpReloadPending.contains(sessionId)) {
      if (live.turn != null) {
        throw DaemonError(
          kErrConflict,
          'A turn is already running for session "$sessionId"',
        );
      }
      final bool parked = await _parkForMcpReload(live);
      _mcpReloadPending.remove(sessionId);
      if (parked) live = null;
    }
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
    final _ForkContext? forkContext = _prepareForkContext(sessionId);
    final ProviderSpec provider = _providers.byId(live.session.providerId)!;
    if (provider.protocol == ProviderProtocol.ante ||
        provider.protocol == ProviderProtocol.codex) {
      final bool codex = provider.protocol == ProviderProtocol.codex;
      bool supports(String mimeType) =>
          isTextMimeType(mimeType) ||
          isImageMimeType(mimeType) ||
          (codex && mimeType.startsWith('audio/'));
      String? unsupportedName;
      String? unsupportedMimeType;
      for (final OutgoingAttachment attachment in attachments) {
        if (!supports(attachment.mimeType)) {
          unsupportedName = attachment.name;
          unsupportedMimeType = attachment.mimeType;
          break;
        }
      }
      final List<_PreparedAttachment>? inherited = forkContext?.attachments;
      if (unsupportedMimeType == null && inherited != null) {
        for (final _PreparedAttachment attachment in inherited) {
          if (!supports(attachment.data.mimeType)) {
            unsupportedName = attachment.data.name;
            unsupportedMimeType = attachment.data.mimeType;
            break;
          }
        }
      }
      if (unsupportedMimeType != null) {
        throw DaemonError(
          _kErrInvalidParams,
          '${codex ? 'Codex app-server' : 'Ante serve'} accepts only '
          '${codex ? 'text, image, or audio' : 'text or image'} attachments; '
          '"$unsupportedName" has MIME type $unsupportedMimeType',
        );
      }
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
      String? attachmentText;
      if (isTextMimeType(attachment.mimeType)) {
        try {
          attachmentText = utf8.decode(bytes);
        } on FormatException {
          throw DaemonError(
            _kErrInvalidParams,
            'Attachment "${attachment.name}" is not valid UTF-8 text',
          );
        }
      }
      final data = AttachmentData(
        id: _uuid.v4(),
        name: attachment.name,
        mimeType: attachment.mimeType,
        size: bytes.length,
        data: attachment.data,
      );
      _store.insertAttachment(sessionId, data);
      prepared.add(_PreparedAttachment(data: data, text: attachmentText));
    }
    // Persist the user message, name the session if needed, and flip to
    // running synchronously — every failure mode below happens before any
    // agent I/O, so the caller learns it from this future rather than after
    // a socket drop mid-turn.
    _beginTurn(live, text, prepared);
    // The agent prompt runs detached; its completion clears the turn slot.
    // Errors are emitted as session events (not rethrown to the caller): a
    // turn that dies after it started is the session's problem, not the
    // sender's, and the client already cleared its draft on ack.
    final active = live;
    active.turn = _driveTurn(active, text, prepared, forkContext).whenComplete(
      () {
        active.turn = null;
      },
    );
  }

  /// In-flight resume attempts, keyed by session id; prevents concurrent
  /// [sendMessage] calls from each spawning their own agent process.
  final Map<String, Future<_LiveSession>> _resuming = {};

  /// Materializes a fork's copied user/agent messages as one structured
  /// context block plus the copied attachment payloads. Ordinary sessions
  /// and forks that already completed a new turn return null.
  _ForkContext? _prepareForkContext(String sessionId) {
    final int? throughSeq = _store.forkContextSeqOf(sessionId);
    if (throughSeq == null) return null;

    final messages = <Map<String, String>>[];
    final inheritedAttachments = <_PreparedAttachment>[];
    final assistant = StringBuffer();

    void flushAssistant() {
      if (assistant.isEmpty) return;
      messages.add(<String, String>{
        'role': 'assistant',
        'content': assistant.toString(),
      });
      assistant.clear();
    }

    for (final SessionEvent event in _store.eventsThrough(
      sessionId,
      throughSeq,
    )) {
      switch (event) {
        case UserMessageEvent e:
          flushAssistant();
          final content = StringBuffer(e.text);
          for (final Attachment attachment in e.attachments) {
            final AttachmentData? data = _store.getAttachment(
              sessionId,
              attachment.id,
            );
            if (data == null) {
              throw StateError(
                'Missing attachment payload for ${attachment.id}',
              );
            }
            if (content.isNotEmpty) content.writeln();
            content.write(
              '[Attachment: ${data.name}; ${data.mimeType}; ${data.size} bytes]',
            );
            inheritedAttachments.add(
              _PreparedAttachment(
                data: data,
                text: isTextMimeType(data.mimeType)
                    ? utf8.decode(base64Decode(data.data))
                    : null,
              ),
            );
          }
          messages.add(<String, String>{
            'role': 'user',
            'content': content.toString(),
          });
        case AgentMessageChunkEvent e:
          assistant.write(e.text);
        default:
          // Thoughts, tools, plans, and lifecycle events remain visible in
          // the copied timeline but are not conversational model messages.
          break;
      }
    }
    flushAssistant();
    return (
      transcript:
          'This session was forked from an earlier conversation. '
          'The JSON array below is inherited conversation history, not a new '
          'user request. Continue from that point and answer only the new user '
          'content that follows.\n${jsonEncode(messages)}',
      attachments: inheritedAttachments,
    );
  }

  /// Respawns the provider transport for a session whose process is gone,
  /// making persisted sessions usable across daemon restarts.
  ///
  /// Throws `DaemonError(kErrNotFound)` for unknown sessions and
  /// `DaemonError(kErrConflict)` when the session is closed, predates resume
  /// support (no persisted provider session id), or its provider cannot resume.
  /// A provider failure during resume marks the session `error` (its remote
  /// state is presumed lost) and throws `kErrAgentProcess`.
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
    final String? providerSessionId = _store.providerSessionIdOf(sessionId);
    if (providerSessionId == null) {
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
    final AgentClient client = _spawnAgent(session);
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
          'restart; create a new session',
        );
      }
      if (info.agentCapabilities['mcpServers'] != false) {
        await _prepareMcpServers?.call();
      }
      configOptions = await client.loadSession(
        sessionId: providerSessionId,
        cwd: session.cwd,
        sandboxMode: session.sandboxMode,
        mcpServers: _mcpServersFor(session, info),
      );
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
      providerSessionId: providerSessionId,
      modelConfigId: modelOption?.configId,
      thinkingConfigId: thinkingOption?.configId,
    );
    _live[sessionId] = live;
    // A setMode only persisted the
    // choice; reapply it now. Advisory: a rejecting agent must not fail the
    // resume — the next explicit setMode tries again.
    if (session.mode != SessionMode.build) {
      try {
        await client.setMode(providerSessionId, session.mode.wire);
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
          providerSessionId,
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
            providerSessionId,
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
      await _updateSession(sessionId, (s) => _withConfigOptions(s, reported));
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
    await live.client.cancel(live.providerSessionId);
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
      await live.client.setMode(live.providerSessionId, mode.wire);
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
        live.providerSessionId,
        live.modelConfigId!,
        model,
      );
      // The agent may adjust more than the requested option (a model switch
      // can carry new thinking levels); its report is adopted wholesale.
      return _updateSession(
        sessionId,
        (current) =>
            _withConfigOptions(current, _configSnapshotOf(configOptions)),
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
        live.providerSessionId,
        live.thinkingConfigId!,
        level,
      );
      // The agent may clamp the requested value or revise any other
      // config-backed field; its report is adopted wholesale.
      return _updateSession(
        sessionId,
        (current) =>
            _withConfigOptions(current, _configSnapshotOf(configOptions)),
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
    _mcpReloadPending.clear();
    if (!_eventsController.isClosed) _eventsController.close();
    if (!_sessionChangesController.isClosed) _sessionChangesController.close();
    if (!_sessionRemovalsController.isClosed) {
      _sessionRemovalsController.close();
    }
  }

  // -------------------------------------------------------------------------
  // Turn machinery
  // -------------------------------------------------------------------------

  /// Synchronous turn setup, run before [sendMessage] resolves: resets
  /// per-turn tool-call state, persists and emits the user message,
  /// auto-titles a default-named session, and flips status to `running`.
  /// Every step is synchronous store/event work that cannot block on agent
  /// I/O, so a caller learns of any failure from the [sendMessage] future
  /// itself.
  void _beginTurn(
    _LiveSession live,
    String text,
    List<_PreparedAttachment> attachments,
  ) {
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
    _setStatus(live, SessionStatus.running, activity: true);
  }

  /// Drives the agent prompt to completion, detached from the caller's
  /// [sendMessage] future. Streams mapped updates, emits `turnComplete` and
  /// returns to `idle` on success; on agent failure emits a `sessionError`
  /// and marks the session `error` (a turn that dies after it started is the
  /// session's problem, not the sender's — the sender already got its ack).
  /// [cancel] and [dispose] observe the in-flight future via `live.turn`.
  Future<void> _driveTurn(
    _LiveSession live,
    String text,
    List<_PreparedAttachment> attachments,
    _ForkContext? forkContext,
  ) async {
    final updates = live.client.sessionUpdates(live.providerSessionId);
    final subscription = updates.listen((update) {
      final event = _mapUpdate(live, update);
      if (event != null) _emit(live, event);
    });

    try {
      final result = await live.client.prompt(
        live.providerSessionId,
        _promptBlocks(text, attachments, forkContext: forkContext),
      );
      if (forkContext != null) {
        _store.setForkContextSeq(live.sessionId, null);
      }
      _emit(live, TurnCompleteEvent(stopReason: result.stopReason));
      _setStatus(live, SessionStatus.idle, activity: true);
    } on Object catch (error) {
      if (!live.closed) {
        final String message = switch (error) {
          AnteTurnException(:final message) => 'Ante turn failed: $message',
          CodexTurnException(:final message) => 'Codex turn failed: $message',
          _ => 'Agent process ended: $error',
        };
        // Expire every parked permission first so a stale
        // respondPermission reports kErrNotFound and cannot flip the failed
        // session back to running.
        _expirePendingPermissions(live, message);
        _emit(live, SessionErrorEvent(message: message));
        _setStatus(live, SessionStatus.error, activity: true);
      }
    } finally {
      await subscription.cancel();
    }
  }

  /// The structured provider prompt blocks for a turn. A fork's inherited
  /// transcript and copied attachments lead the first new prompt; the user's
  /// current text and attachments follow. ACP transports accept `image` and
  /// embedded `resource` attachment blocks. Ante converts text resources into
  /// its text-only `UserInput` operation.
  static List<Map<String, Object?>> _promptBlocks(
    String text,
    List<_PreparedAttachment> attachments, {
    _ForkContext? forkContext,
  }) {
    final blocks = <Map<String, Object?>>[];

    void appendAttachments(List<_PreparedAttachment> preparedAttachments) {
      for (final prepared in preparedAttachments) {
        final data = prepared.data;
        final String? attachmentText = prepared.text;
        if (attachmentText != null) {
          blocks.add(<String, Object?>{
            'type': 'resource',
            'resource': <String, Object?>{
              'uri':
                  'speeddial-attachment:///${data.id}/'
                  '${Uri.encodeComponent(data.name)}',
              'mimeType': data.mimeType,
              'text': attachmentText,
            },
          });
          continue;
        }
        if (isImageMimeType(data.mimeType)) {
          blocks.add(<String, Object?>{
            'type': 'image',
            'data': data.data,
            'mimeType': data.mimeType,
          });
          continue;
        }
        blocks.add(<String, Object?>{
          'type': 'resource',
          'resource': <String, Object?>{
            'uri':
                'speeddial-attachment:///${data.id}/'
                '${Uri.encodeComponent(data.name)}',
            'mimeType': data.mimeType,
            'blob': data.data,
          },
        });
      }
    }

    if (forkContext != null) {
      blocks.add(<String, Object?>{
        'type': 'text',
        'text': forkContext.transcript,
      });
      appendAttachments(forkContext.attachments);
    }
    if (text.isNotEmpty) {
      blocks.add(<String, Object?>{'type': 'text', 'text': text});
    }
    appendAttachments(attachments);
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
                toolCallId,
                toolCallUpdate.fields,
                cwd: live.cwd,
              )
            : mergeToolCallUpdate(prior, toolCallUpdate, cwd: live.cwd);
        _toolCalls[sessionId]?[toolCallId] = merged;
        // The persisted/broadcast snapshot drops raw fields while the call
        // is still running (they are re-sent in full on the terminal
        // update); the in-memory merged state stays complete so the next
        // update — and the terminal event — carry everything.
        return ToolCallEvent(toolCall: trimToolCallUpdateForEmit(merged));
      case final AcpPlan plan:
        return planEventFromAcp(plan);
      case final AcpUsageUpdate usage:
        return usageEventFromAcp(usage);
      case final AcpAgentActivityUpdate activity:
        return AgentActivityEvent(
          activity: AgentActivity(
            id: activity.id,
            kind: activity.kind,
            title: activity.title,
            status: AgentActivityStatus.parse(activity.status),
            details: activity.details,
          ),
        );
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
    _emit(
      live,
      PermissionResolvedEvent(requestId: requestId, optionId: optionId),
    );
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
    final String firstLine = text
        .split('\n')
        .first
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
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
    throw const FormatException('Path escapes the session working directory');
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
    _emitForSession(live.sessionId, event);
  }

  void _emitForSession(String sessionId, SessionEvent event) {
    final int seq = _store.nextSeq(sessionId);
    final SessionEvent persisted = _store.appendEvent(sessionId, seq, event);
    if (!_eventsController.isClosed) {
      _eventsController.add((sessionId: sessionId, seq: seq, event: persisted));
    }
  }

  void _setStatus(
    _LiveSession live,
    SessionStatus status, {
    bool activity = false,
  }) {
    final updated = _withStatus(live.session, status, activity: activity);
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

  Session _withStatus(
    Session session,
    SessionStatus status, {
    bool activity = false,
  }) {
    final DateTime now = DateTime.now().toUtc();
    return Session(
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
      sandboxMode: session.sandboxMode,
      yolo: session.yolo,
      archived: session.archived,
      createdAt: session.createdAt,
      lastActivityAt: activity ? now : session.lastActivityAt,
      updatedAt: now,
    );
  }

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
    sandboxMode: session.sandboxMode,
    yolo: session.yolo,
    archived: session.archived,
    createdAt: session.createdAt,
    lastActivityAt: session.lastActivityAt,
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
    sandboxMode: session.sandboxMode,
    yolo: session.yolo,
    archived: archived,
    createdAt: session.createdAt,
    lastActivityAt: session.lastActivityAt,
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
    sandboxMode: session.sandboxMode,
    yolo: session.yolo,
    archived: session.archived,
    createdAt: session.createdAt,
    lastActivityAt: session.lastActivityAt,
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
    sandboxMode: session.sandboxMode,
    yolo: session.yolo,
    archived: session.archived,
    createdAt: session.createdAt,
    lastActivityAt: session.lastActivityAt,
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
        sandboxMode: session.sandboxMode,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        lastActivityAt: session.lastActivityAt,
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
        sandboxMode: session.sandboxMode,
        yolo: session.yolo,
        archived: session.archived,
        createdAt: session.createdAt,
        lastActivityAt: session.lastActivityAt,
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
