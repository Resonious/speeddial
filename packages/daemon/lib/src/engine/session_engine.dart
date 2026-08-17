/// [SessionEngine]: owns live ACP agent processes per session and maps their
/// updates onto protocol [SessionEvent]s, persisting every event with a
/// per-session sequence number and broadcasting it.
///
/// Lifecycle:
///   * `createSession` spawns a provider's ACP agent (cwd = session cwd),
///     creates an ACP session, and persists an idle protocol session.
///   * `sendMessage` runs a turn: user message event, status `running`,
///     mapped ACP updates (chunks, tool calls, plan, usage) streamed and
///     persisted, permission requests parked until `respondPermission`, then
///     `turnComplete` and status `idle`.
///   * `cancel` cancels the running turn via the agent.
///   * `delete` kills the agent and removes the session (and its events).
///
/// fs/read+write requests from agents are served with paths confined to the
/// session cwd; anything escaping it is rejected with a JSON-RPC error.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:uuid/uuid.dart';

import '../acp/acp_client.dart';
import '../acp/acp_types.dart';
import '../providers/provider_registry.dart';
import '../store/daemon_store.dart';
import 'event_mapper.dart';

/// One live engine session: its agent client plus in-memory turn state.
class _LiveSession {
  _LiveSession({
    required this.session,
    required this.client,
    required this.acpSessionId,
  });

  Session session;
  final AcpClient client;
  final String acpSessionId;

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

/// Orchestrates ACP agent processes and the project session lifecycle.
class SessionEngine {
  SessionEngine({
    required DaemonStore store,
    required ProviderRegistry providers,
  })  : _store = store, // ignore: prefer_initializing_formals — public API name
        _providers = providers; // ignore: prefer_initializing_formals — public API name

  final DaemonStore _store;
  final ProviderRegistry _providers;
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

  /// Marks every non-closed session from the database as `error`: after a
  /// daemon restart the agent processes are gone, so those sessions cannot
  /// resume. Call once at startup.
  Future<void> restore() async {
    for (final session in _store.listSessions(includeArchived: true)) {
      if (session.status == SessionStatus.closed) continue;
      final updated = _withStatus(session, SessionStatus.error);
      _store.updateSession(updated);
      if (!_sessionChangesController.isClosed) {
        _sessionChangesController.add(updated);
      }
    }
  }

  /// Creates a new protocol session and spawns its ACP agent.
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? cwd,
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
    final workingDir = cwd ?? project.path;
    final now = DateTime.now().toUtc();
    final session = Session(
      id: _uuid.v4(),
      projectId: projectId,
      providerId: providerId,
      title: title ?? 'New session',
      status: SessionStatus.idle,
      mode: mode ?? SessionMode.build,
      model: model,
      cwd: workingDir,
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    final client = AcpClient.spawn(
      spec.command,
      cwd: workingDir,
      // The closures capture our protocol sessionId, so the ACP session id
      // (which collides across agents, e.g. "s1") never needs disambiguation.
      requestPermission: (acpSessionId, toolCallId, requestTitle, options) =>
          _onPermissionRequest(session.id, toolCallId, requestTitle, options),
      readTextFile: (acpSessionId, path) => _readTextFile(session.id, path),
      writeTextFile: (acpSessionId, path, content) =>
          _writeTextFile(session.id, path, content),
    );
    final String acpSessionId;
    try {
      final info = await client.initialized;
      if (info.authMethods.isNotEmpty) {
        await client.authenticate(info.authMethods.first);
      }
      acpSessionId = await client.newSession(cwd: workingDir);
    } on Object catch (error) {
      // Never leak a half-initialized agent process.
      await client.dispose();
      throw DaemonError(
        kErrAgentProcess,
        'Failed to start provider "$providerId": $error',
      );
    }
    _store.insertSession(session);
    _live[session.id] = _LiveSession(
      session: session,
      client: client,
      acpSessionId: acpSessionId,
    );
    if (!_sessionChangesController.isClosed) {
      _sessionChangesController.add(session);
    }
    return session;
  }

  /// Starts a turn for [text]. Errors `kErrConflict` when a turn is already
  /// running or the session has no live agent process.
  Future<void> sendMessage(String sessionId, String text) async {
    final live = _live[sessionId];
    if (live == null) {
      throw DaemonError(
        kErrConflict,
        'Session "$sessionId" is not active (its agent process is gone; '
        'create a new session)',
      );
    }
    if (live.turn != null) {
      throw DaemonError(
        kErrConflict,
        'A turn is already running for session "$sessionId"',
      );
    }
    final turn = _runTurn(live, text);
    live.turn = turn;
    try {
      await turn;
    } finally {
      live.turn = null;
    }
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
    for (final completer in live.pendingPermissions.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('Permission request cancelled'),
        );
      }
    }
    live.pendingPermissions.clear();
  }

  Future<Session> rename(String sessionId, String title) =>
      _updateSession(sessionId, (session) => Session(
            id: session.id,
            projectId: session.projectId,
            providerId: session.providerId,
            title: title,
            status: session.status,
            mode: session.mode,
            model: session.model,
            cwd: session.cwd,
            archived: session.archived,
            createdAt: session.createdAt,
            updatedAt: DateTime.now().toUtc(),
          ));

  Future<Session> archive(String sessionId, bool archived) =>
      _updateSession(sessionId, (session) => _withArchived(session, archived));

  /// Switches the agent's session mode and persists it. Sessions without a
  /// live agent are persisted locally (mode changes on restore-marked
  /// sessions apply to a future session).
  Future<Session> setMode(String sessionId, SessionMode mode) async {
    final live = _live[sessionId];
    if (live != null && live.turn == null) {
      await live.client.setMode(live.acpSessionId, mode.wire);
    }
    return _updateSession(sessionId, (session) => _withMode(session, mode));
  }

  /// Persists the selected model. ACP has no universal `session/set_model`
  /// method, so the model stays a local preference applied on future turns;
  /// providers that support it can honor it at session creation/provisioning.
  Future<Session> setModel(String sessionId, String model) =>
      _updateSession(sessionId, (session) => _withModel(session, model));

  /// Resolves a parked permission request. Unknown/expired requests error
  /// `kErrNotFound` (per PROTOCOL.md `sessions.respondPermission`).
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
      throw DaemonError(
        kErrNotFound,
        'Unknown or expired permission request: $requestId',
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

  Future<void> _runTurn(_LiveSession live, String text) async {
    final sessionId = live.sessionId;
    _toolCalls[sessionId] = <String, ToolCall>{};
    _emit(live, UserMessageEvent(text: text));
    _setStatus(live, SessionStatus.running);

    final updates = live.client.sessionUpdates(live.acpSessionId);
    final subscription = updates.listen((update) {
      final event = _mapUpdate(live, update);
      if (event != null) _emit(live, event);
    });

    try {
      final result = await live.client.prompt(live.acpSessionId, text);
      _emit(live, TurnCompleteEvent(stopReason: result.stopReason));
      _setStatus(live, SessionStatus.idle);
    } on Object catch (error) {
      if (!live.closed) {
        _emit(live, SessionErrorEvent(message: 'Agent process ended: $error'));
        _setStatus(live, SessionStatus.error);
      }
    } finally {
      await subscription.cancel();
    }
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
    final completer = Completer<String>();
    live.pendingPermissions[requestId] = completer;
    _emit(
      live,
      PermissionRequestEvent(
        request: PermissionRequest(
          requestId: requestId,
          toolCallId: toolCallId,
          title: title,
          options: permissionOptionsFromAcp(options),
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

  Session _withStatus(Session session, SessionStatus status) => Session(
        id: session.id,
        projectId: session.projectId,
        providerId: session.providerId,
        title: session.title,
        status: status,
        mode: session.mode,
        model: session.model,
        cwd: session.cwd,
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
        cwd: session.cwd,
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
        cwd: session.cwd,
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
        cwd: session.cwd,
        archived: session.archived,
        createdAt: session.createdAt,
        updatedAt: DateTime.now().toUtc(),
      );
}
