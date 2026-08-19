import 'dart:async';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'daemon_client.dart';

/// In-memory, scripted [DaemonClient] used by widget tests and `--demo` mode.
///
/// Seeds one project (`Demo Project`, path `/demo`) and two sessions. There is
/// no network or agent: every method returns immediately (the send script
/// steps through its event sequence on live streams with a small delay).
class FakeDaemonClient implements DaemonClient {
  FakeDaemonClient({this.eventDelay = const Duration(milliseconds: 50)});

  /// Delay between scripted streaming events; tests may pass a tiny duration.
  final Duration eventDelay;

  bool _disposed = false;
  bool _seeded = false;
  int _projectCounter = 1;
  int _sessionCounter = 3;

  final List<Project> _projects = <Project>[];
  final Map<String, Session> _sessions = <String, Session>{};
  final Map<String, List<SessionEvent>> _history = <String, List<SessionEvent>>{};
  final Map<String, int> _seqBySession = <String, int>{};
  final Map<String, StreamController<SessionEvent>> _eventControllers =
      <String, StreamController<SessionEvent>>{};

  /// sessions currently executing a scripted turn; a second send conflicts.
  final Set<String> _runningScripts = <String>{};
  final Set<String> _cancelRequested = <String>{};
  final Map<String, String> _pendingPermissions = <String, String>{};

  final Map<String, List<FileEntry>> _fileTree = <String, List<FileEntry>>{};
  final Map<String, String> _fileContents = <String, String>{};

  // Git state is keyed by repo root (project path, or the session's worktree
  // cwd) so worktree sessions see their own tree, mirroring the daemon.
  final Map<String, GitStatus> _gitStatus = <String, GitStatus>{};
  final Map<String, List<Branch>> _gitBranches = <String, List<Branch>>{};
  final Map<String, List<GitDiff>> _gitDiffs = <String, List<GitDiff>>{};

  /// Scripted per-session git summaries for the left-rail badges
  /// (`gitSessionSummaries`), keyed by session id; seeded for the two demo
  /// sessions. Tests overwrite entries to drive the badges; the real daemon
  /// computes these from git state.
  final Map<String, SessionGitSummary> sessionGitSummaries =
      <String, SessionGitSummary>{};
  late final StreamController<Session> _sessionUpdatesController;
  late final StreamController<String> _sessionRemovalsController;
  late final StreamController<void> _projectsChangedController;

  // ---------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------

  /// Seeds the demo project and two sessions. Called lazily on first use so
  /// `FakeDaemonClient()` is safe even when nothing consults it.
  void _ensureSeeded() {
    if (_seeded) return;
    _seeded = true;
    final DateTime now = DateTime.now().toUtc();
    final Project project = Project(
      id: 'proj-demo',
      name: 'Demo Project',
      path: '/demo',
      addedAt: now,
      lastActiveAt: now,
    );
    _projects.add(project);
    _sessions['sess-1'] = Session(
      id: 'sess-1',
      projectId: project.id,
      providerId: 'omp',
      title: 'Build the feature',
      status: SessionStatus.idle,
      mode: SessionMode.build,
      model: 'omp-default',
      cwd: project.path,
      baseBranch: 'main',
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    _sessions['sess-2'] = Session(
      id: 'sess-2',
      projectId: project.id,
      providerId: 'omp',
      title: 'Plan the refactor',
      status: SessionStatus.idle,
      mode: SessionMode.plan,
      model: null,
      cwd: project.path,
      baseBranch: null,
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    _eventControllers.clear();
    _history.clear();
    _fileTree
      ..['.'] = List<FileEntry>.unmodifiable(<FileEntry>[
        FileEntry(name: 'lib', path: 'lib', isDir: true, size: 0, modifiedAt: now),
        FileEntry(name: 'main.dart', path: 'main.dart', isDir: false, size: 120, modifiedAt: now),
        FileEntry(name: 'pubspec.yaml', path: 'pubspec.yaml', isDir: false, size: 30, modifiedAt: now),
      ])
      ..['lib'] = List<FileEntry>.unmodifiable(<FileEntry>[
        FileEntry(name: 'main.dart', path: 'lib/main.dart', isDir: false, size: 64, modifiedAt: now),
      ]);
    _fileContents
      ..['main.dart'] = 'void main() { print("hi"); }\n'
      ..['pubspec.yaml'] = 'name: demo\n'
      ..['lib/main.dart'] = 'import "package:flutter/material.dart";\n\n'
          'void main() => runApp(const App());\n';
    _gitStatus[project.path] = const GitStatus(
      branch: 'main',
      ahead: 0,
      behind: 0,
      files: <GitStatusFile>[
        GitStatusFile(
          path: 'lib/main.dart',
          indexStatus: '.',
          worktreeStatus: 'M',
          staged: false,
        ),
      ],
    );
    _gitBranches[project.path] = const <Branch>[
      Branch(name: 'main', isCurrent: true, upstream: 'origin/main'),
      Branch(name: 'feature/x', isCurrent: false, upstream: null),
    ];
    _gitDiffs[project.path] = const <GitDiff>[
      GitDiff(
        path: 'lib/main.dart',
        patch: '--- a/lib/main.dart\n+++ b/lib/main.dart\n@@ -1 +1 @@\n'
            '-void main()\n+void main() { print("hi"); }\n',
        isNew: false,
        isDeleted: false,
        isBinary: false,
      ),
    ];
    // Left-rail badges: sess-1 has uncommitted work and two unmerged commits;
    // sess-2 shares the (dirty) project checkout and has no base branch.
    sessionGitSummaries
      ..['sess-1'] = const SessionGitSummary(
          sessionId: 'sess-1',
          dirty: true,
          aheadOfBase: 2,
          mergedIntoBase: false)
      ..['sess-2'] = const SessionGitSummary(
          sessionId: 'sess-2',
          dirty: true,
          aheadOfBase: null,
          mergedIntoBase: null);
    _sessionUpdatesController = StreamController<Session>.broadcast();
    _sessionRemovalsController = StreamController<String>.broadcast();
    _projectsChangedController = StreamController<void>.broadcast();
  }

  Project _project(String id) {
    for (final Project p in _projects) {
      if (p.id == id) return p;
    }
    throw DaemonError(kErrNotFound, 'unknown project: $id');
  }

  void _requireSession(String id) {
    if (!_sessions.containsKey(id)) {
      throw DaemonError(kErrNotFound, 'unknown session: $id');
    }
  }

  // ---------------------------------------------------------------------
  // Daemon / projects
  // ---------------------------------------------------------------------

  @override
  Future<DaemonInfo> info() async {
    _ensureSeeded();
    return const DaemonInfo(
      version: '0.0.0-fake',
      protocolVersion: 1,
      authRequired: false,
      providers: <ProviderInfo>[
        ProviderInfo(
          id: 'omp',
          name: 'OMP Agent',
          available: true,
          command: 'omp',
          models: <String>['omp-default', 'omp-fast'],
        ),
        ProviderInfo(
          id: 'claude',
          name: 'Claude',
          available: true,
          command: 'npx -y @zed-industries/claude-code-acp',
          models: <String>['claude-sonnet'],
        ),
      ],
    );
  }

  @override
  Future<List<Project>> listProjects() async {
    _ensureSeeded();
    return List<Project>.unmodifiable(_projects);
  }

  @override
  Future<Project> addProject(String path, {String? name}) async {
    _ensureSeeded();
    final DateTime now = DateTime.now().toUtc();
    final String trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final String fallback =
        trimmed.substring(trimmed.lastIndexOf('/') + 1);
    final Project project = Project(
      id: 'proj-${_projectCounter++}',
      name: name ?? (fallback.isEmpty ? path : fallback),
      path: path,
      addedAt: now,
      lastActiveAt: now,
    );
    _projects.add(project);
    _gitStatus[project.path] = const GitStatus(
      branch: 'main',
      ahead: 0,
      behind: 0,
      files: <GitStatusFile>[],
    );
    _gitBranches[project.path] = const <Branch>[
      Branch(name: 'main', isCurrent: true, upstream: null),
    ];
    _gitDiffs[project.path] = const <GitDiff>[];
    _projectsChangedController.add(null);
    return project;
  }

  @override
  Future<void> removeProject(String id) async {
    _ensureSeeded();
    _project(id);
    _projects.removeWhere((Project p) => p.id == id);
    final List<String> removed = <String>[
      for (final Session s in _sessions.values.where(
          (Session s) => s.projectId == id))
        s.id,
    ];
    for (final String sessionId in removed) {
      _removeSession(sessionId);
    }
    _projectsChangedController.add(null);
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    _ensureSeeded();
    return List<Session>.unmodifiable(_sessions.values.where((Session s) =>
        (projectId == null || s.projectId == projectId) &&
        (includeArchived || !s.archived)));
  }

  @override
  Future<Session> createSession({
    required String projectId,
    required String providerId,
    String? model,
    SessionMode? mode,
    String? title,
    String? baseBranch,
  }) async {
    _ensureSeeded();
    _project(projectId);
    final DateTime now = DateTime.now().toUtc();
    final String id = 'sess-${_sessionCounter++}';
    final Session session = Session(
      id: id,
      projectId: projectId,
      providerId: providerId,
      title: title ?? 'New session',
      status: SessionStatus.idle,
      mode: mode ?? SessionMode.build,
      model: model,
      // No real git here: a base branch just moves the cwd to a plausible
      // worktree path, mirroring the daemon's layout.
      cwd: baseBranch == null
          ? _project(projectId).path
          : '${_project(projectId).path}/../.speeddial-worktrees/'
              '${_project(projectId).name.toLowerCase()}-$id',
      baseBranch: baseBranch,
      archived: false,
      createdAt: now,
      updatedAt: now,
    );
    _sessions[session.id] = session;
    if (baseBranch != null) {
      // A fresh worktree branched off the remote tip is clean; give it its
      // own git state so session-scoped git calls see the worktree, not the
      // main checkout.
      final String branch = 'speeddial/${session.id}';
      _gitStatus[session.cwd] = GitStatus(
        branch: branch,
        ahead: 0,
        behind: 0,
        files: const <GitStatusFile>[],
      );
      _gitBranches[session.cwd] = <Branch>[
        Branch(name: branch, isCurrent: true, upstream: null),
      ];
      _gitDiffs[session.cwd] = const <GitDiff>[];
    }
    _sessionUpdatesController.add(session);
    return session;
  }

  @override
  Future<void> sendMessage(String sessionId, String text) async {
    _ensureSeeded();
    _requireSession(sessionId);
    if (_runningScripts.contains(sessionId)) {
      throw const DaemonError(kErrConflict, 'a turn is already running');
    }
    _runningScripts.add(sessionId);
    _cancelRequested.remove(sessionId);
    // The daemon broadcasts the user's own message as the turn's first event
    // (see daemon SessionEngine._runTurn); mirror that here.
    _emit(sessionId, UserMessageEvent(text: text));
    _setStatus(sessionId, SessionStatus.running);
    unawaited(_runScript(sessionId, text));
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    _ensureSeeded();
    _requireSession(sessionId);
    if (!_runningScripts.contains(sessionId)) return;
    _cancelRequested.add(sessionId);
    await _emitTurnTail(sessionId, stopReason: 'cancelled');
  }

  @override
  Future<Session> renameSession(String sessionId, String title) async {
    _ensureSeeded();
    final Session session = _updateSession(sessionId,
        (Session s) => Session(
              id: s.id,
              projectId: s.projectId,
              providerId: s.providerId,
              title: title,
              status: s.status,
              mode: s.mode,
              model: s.model,
              cwd: s.cwd,
              baseBranch: s.baseBranch,
              archived: s.archived,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
            ));
    return session;
  }

  @override
  Future<Session> archiveSession(String sessionId, bool archived) async {
    _ensureSeeded();
    final Session session = _updateSession(sessionId,
        (Session s) => Session(
              id: s.id,
              projectId: s.projectId,
              providerId: s.providerId,
              title: s.title,
              status: s.status,
              mode: s.mode,
              model: s.model,
              cwd: s.cwd,
              baseBranch: s.baseBranch,
              archived: archived,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
            ));
    return session;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _ensureSeeded();
    _requireSession(sessionId);
    _removeSession(sessionId);
  }

  @override
  Future<Session> setMode(String sessionId, SessionMode mode) async {
    _ensureSeeded();
    final Session session = _updateSession(sessionId,
        (Session s) => Session(
              id: s.id,
              projectId: s.projectId,
              providerId: s.providerId,
              title: s.title,
              status: s.status,
              mode: mode,
              model: s.model,
              cwd: s.cwd,
              baseBranch: s.baseBranch,
              archived: s.archived,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
            ));
    return session;
  }

  @override
  Future<Session> setModel(String sessionId, String model) async {
    _ensureSeeded();
    final Session session = _updateSession(sessionId,
        (Session s) => Session(
              id: s.id,
              projectId: s.projectId,
              providerId: s.providerId,
              title: s.title,
              status: s.status,
              mode: s.mode,
              model: model,
              cwd: s.cwd,
              baseBranch: s.baseBranch,
              archived: s.archived,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
            ));
    return session;
  }

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    _ensureSeeded();
    _requireSession(sessionId);
    final List<SessionEvent> all =
        List<SessionEvent>.of(_history[sessionId] ?? const <SessionEvent>[]);
    // Strictly below beforeSeq (mirrors the daemon's listEvents paging).
    final List<SessionEvent> filtered = beforeSeq == null
        ? all
        : all.where((SessionEvent e) => (e.seq ?? 0) < beforeSeq).toList();
    // The newest `limit` events ascending; hasMore means an older page exists.
    final bool hasMore = filtered.length > limit;
    return (
      events: hasMore ? filtered.sublist(filtered.length - limit) : filtered,
      hasMore: hasMore,
    );
  }

  /// Seeds persisted history for [sessionId] as if the daemon had recorded
  /// it earlier (e.g. to exercise multi-page `history` backfill in the app).
  /// Events are stamped with ascending `seq`s continuing from the session's
  /// current sequence; nothing is emitted on the live streams. Order given
  /// is the `seq` order.
  void seedHistory(String sessionId, Iterable<SessionEvent> events) {
    _ensureSeeded();
    _requireSession(sessionId);
    final List<SessionEvent> stamped = <SessionEvent>[];
    int seq = _seqBySession[sessionId] ?? 0;
    final DateTime now = DateTime.now().toUtc();
    for (final SessionEvent event in events) {
      seq += 1;
      stamped.add(_withSeq(event, seq, now));
    }
    _seqBySession[sessionId] = seq;
    _history.putIfAbsent(sessionId, () => <SessionEvent>[]).addAll(stamped);
  }

  @override
  Future<void> respondPermission(
    String sessionId,
    String requestId,
    String optionId,
  ) async {
    _ensureSeeded();
    _requireSession(sessionId);
    final String? pending = _pendingPermissions[sessionId];
    if (pending != requestId) {
      throw DaemonError(kErrNotFound, 'unknown permission request: $requestId');
    }
    await _delay();
    _emit(
      sessionId,
      PermissionResolvedEvent(requestId: requestId, optionId: optionId),
    );
    await _emitTurnTail(sessionId);
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  @override
  Future<List<FileEntry>> listFiles(String projectId, [String path = '.']) async {
    _ensureSeeded();
    _project(projectId);
    final List<FileEntry>? entries = _fileTree[path];
    if (entries == null) {
      throw DaemonError(kErrNotFound, 'no such directory: $path');
    }
    return List<FileEntry>.unmodifiable(entries);
  }

  @override
  Future<FileReadResult> readFile(
    String projectId,
    String path, {
    int? maxBytes,
  }) async {
    _ensureSeeded();
    _project(projectId);
    final String? content = _fileContents[path];
    if (content == null) {
      throw DaemonError(kErrNotFound, 'file not found: $path');
    }
    if (maxBytes != null && content.length > maxBytes) {
      return FileReadResult(
        content: content.substring(0, maxBytes),
        truncated: true,
        isBinary: false,
      );
    }
    return FileReadResult(content: content, truncated: false, isBinary: false);
  }

  // ---------------------------------------------------------------------
  // Git
  // ---------------------------------------------------------------------

  /// The repo root a git call runs against: the session's cwd (worktree)
  /// when [sessionId] is given, else the project path — same resolution and
  /// errors as the daemon (`kErrNotFound` unknown session, `-32602` when the
  /// session belongs to another project).
  String _gitRoot(String projectId, String? sessionId) {
    final Project project = _project(projectId);
    if (sessionId == null) return project.path;
    final Session? session = _sessions[sessionId];
    if (session == null) {
      throw DaemonError(kErrNotFound, 'unknown session: $sessionId');
    }
    if (session.projectId != project.id) {
      throw const DaemonError(-32602, 'session does not belong to project');
    }
    return session.cwd;
  }

  @override
  Future<GitStatus> gitStatus(String projectId, {String? sessionId}) async {
    _ensureSeeded();
    return _gitStatus[_gitRoot(projectId, sessionId)]!;
  }

  @override
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  }) async {
    _ensureSeeded();
    final List<GitDiff> diffs =
        _gitDiffs[_gitRoot(projectId, sessionId)] ?? const <GitDiff>[];
    if (path == null) return List<GitDiff>.unmodifiable(diffs);
    return List<GitDiff>.unmodifiable(
        diffs.where((GitDiff d) => d.path == path));
  }

  @override
  Future<List<Branch>> gitBranches(String projectId,
      {String? sessionId}) async {
    _ensureSeeded();
    return List<Branch>.unmodifiable(
        _gitBranches[_gitRoot(projectId, sessionId)] ?? const <Branch>[]);
  }

  @override
  Future<void> gitCheckout(String projectId, String branch,
      {String? sessionId}) async {
    _ensureSeeded();
    final String root = _gitRoot(projectId, sessionId);
    final List<Branch> branches = _gitBranches[root]!;
    if (!branches.any((Branch b) => b.name == branch)) {
      throw DaemonError(kErrGit, 'no such branch: $branch');
    }
    _gitBranches[root] = List<Branch>.unmodifiable(branches
        .map((Branch b) => Branch(
              name: b.name,
              isCurrent: b.name == branch,
              upstream: b.upstream,
            ))
        .toList());
    final GitStatus status = _gitStatus[root]!;
    _gitStatus[root] = GitStatus(
      branch: branch,
      ahead: status.ahead,
      behind: status.behind,
      files: status.files,
    );
  }

  @override
  Future<String> gitCommit(
    String projectId,
    String message, {
    String? sessionId,
    bool stageAll = false,
  }) async {
    _ensureSeeded();
    final String root = _gitRoot(projectId, sessionId);
    if (message.trim().isEmpty) {
      throw const DaemonError(kErrGit, 'commit message is empty');
    }
    final GitStatus status = _gitStatus[root]!;
    _gitStatus[root] = GitStatus(
      branch: status.branch,
      ahead: status.ahead,
      behind: status.behind,
      files: const <GitStatusFile>[],
    );
    _gitDiffs[root] = const <GitDiff>[];
    return 'deadbeef';
  }

  @override
  Future<void> gitPush(String projectId, {String? sessionId}) async {
    _ensureSeeded();
    _gitRoot(projectId, sessionId);
  }

  @override
  Future<MergeResult> gitMergeToBase(String projectId,
      {required String sessionId}) async {
    _ensureSeeded();
    final String root = _gitRoot(projectId, sessionId);
    final Session session = _sessions[sessionId]!;
    if (session.baseBranch == null) {
      throw const DaemonError(-32602, 'session has no base branch');
    }
    return MergeResult(
      baseBranch: session.baseBranch!,
      sessionBranch: _gitStatus[root]!.branch,
      baseFastForwarded: false,
      alreadyUpToDate: false,
      fastForward: true,
      commit: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
    );
  }

  @override
  Future<RebaseResult> gitRebaseOntoBase(String projectId,
      {required String sessionId}) async {
    _ensureSeeded();
    final String root = _gitRoot(projectId, sessionId);
    final Session session = _sessions[sessionId]!;
    if (session.baseBranch == null) {
      throw const DaemonError(-32602, 'session has no base branch');
    }
    return RebaseResult(
      baseBranch: session.baseBranch!,
      sessionBranch: _gitStatus[root]!.branch,
      baseFastForwarded: false,
      alreadyUpToDate: false,
      commit: 'feedfacefeedfacefeedfacefeedfacefeedface',
    );
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
    _ensureSeeded();
    _gitRoot(projectId, sessionId);
    return 'https://github.com/speeddial/demo/pull/1';
  }

  @override
  Future<List<SessionGitSummary>> gitSessionSummaries(String projectId) async {
    _ensureSeeded();
    final Project project = _project(projectId);
    // One entry per non-archived session, like the daemon; sessions without
    // a scripted entry report all-unknown.
    return <SessionGitSummary>[
      for (final Session session in _sessions.values)
        if (session.projectId == project.id && !session.archived)
          sessionGitSummaries[session.id] ??
              SessionGitSummary(
                sessionId: session.id,
                dirty: null,
                aheadOfBase: null,
                mergedIntoBase: null,
              ),
    ];
  }

  // ---------------------------------------------------------------------
  // Live streams
  // ---------------------------------------------------------------------

  @override
  Stream<SessionEvent> sessionEvents(String sessionId) {
    _ensureSeeded();
    _requireSession(sessionId);
    return _eventControllers
        .putIfAbsent(
            sessionId, () => StreamController<SessionEvent>.broadcast())
        .stream;
  }

  @override
  Stream<Session> get sessionUpdates {
    _ensureSeeded();
    return _sessionUpdatesController.stream;
  }

  @override
  Stream<String> get sessionRemovals {
    _ensureSeeded();
    return _sessionRemovalsController.stream;
  }

  @override
  Stream<void> get projectsChanged {
    _ensureSeeded();
    return _projectsChangedController.stream;
  }

  final StreamController<void> _resyncController =
      StreamController<void>.broadcast();

  @override
  Stream<void> get resynced => _resyncController.stream;

  /// Test hook: simulate a reconnect-driven resync. The real client emits
  /// this after a successful reconnect that followed a failure; stores
  /// refetch whatever they missed while "offline".
  void triggerResync() {
    if (_disposed) return;
    _resyncController.add(null);
  }

  @override
  bool get isConnected => !_disposed;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _runningScripts.clear();
    _pendingPermissions.clear();
    for (final StreamController<SessionEvent> controller
        in _eventControllers.values) {
      await controller.close();
    }
    _eventControllers.clear();
    await _resyncController.close();
    if (_seeded) {
      await _sessionUpdatesController.close();
      await _sessionRemovalsController.close();
      await _projectsChangedController.close();
    }
  }

  // ---------------------------------------------------------------------
  // Scripted turn
  // ---------------------------------------------------------------------

  Future<void> _runScript(String sessionId, String text) async {
    const List<String> thoughts = <String>[
      'The user asked a question. ',
      'I should answer with a short demo response.',
    ];
    for (final String chunk in thoughts) {
      if (_isCancelled(sessionId)) return;
      await _delay();
      if (_isCancelled(sessionId)) return;
      _emit(sessionId, AgentThoughtChunkEvent(text: chunk));
    }

    const List<String> chunks = <String>[
      'Working on it…\n\n',
      '```dart\nvoid main() {}\n```\n\n',
      'Done.',
    ];
    for (final String chunk in chunks) {
      if (_isCancelled(sessionId)) return;
      await _delay();
      if (_isCancelled(sessionId)) return;
      _emit(sessionId, AgentMessageChunkEvent(text: chunk));
    }

    await _delay();
    if (_isCancelled(sessionId)) return;
    _emit(sessionId, ToolCallEvent(toolCall: _toolCall(ToolCallStatus.running)));

    await _delay();
    if (_isCancelled(sessionId)) return;
    _emit(
      sessionId,
      ToolCallEvent(
        toolCall: _toolCall(ToolCallStatus.completed),
      ),
    );

    await _delay();
    if (_isCancelled(sessionId)) return;
    _emit(sessionId, PlanEvent(entries: _planEntries()));

    if (text.toLowerCase().contains('permission')) {
      await _delay();
      if (_isCancelled(sessionId)) return;
      final PermissionRequest request = _permissionRequest();
      _emit(sessionId, PermissionRequestEvent(request: request));
      _pendingPermissions[sessionId] = request.requestId;
      _setStatus(sessionId, SessionStatus.waitingPermission);
      // Parked: the turn stays "running" until respondPermission's tail
      // clears it, so a second send conflicts and cancel works.
      return;
    }

    await _emitTurnTail(sessionId);
  }

  Future<void> _emitTurnTail(String sessionId,
      {String stopReason = 'end_turn'}) async {
    await _delay();
    if (_disposed || !_sessions.containsKey(sessionId)) return;
    _emit(
      sessionId,
      const UsageEvent(
        usage: UsageInfo(
          inputTokens: 1180,
          outputTokens: 320,
          totalTokens: 1500,
          cost: '0.0021',
        ),
      ),
    );
    await _delay();
    if (_disposed || !_sessions.containsKey(sessionId)) return;
    // A pending cancel turns this into the cancelled tail; consume the flag
    // so the racing cancelSession path does not emit a second tail.
    final String reason =
        _cancelRequested.remove(sessionId) ? 'cancelled' : stopReason;
    _emit(sessionId, TurnCompleteEvent(stopReason: reason));
    _pendingPermissions.remove(sessionId);
    _runningScripts.remove(sessionId);
    _setStatus(sessionId, SessionStatus.idle);
  }

  bool _isCancelled(String sessionId) => _cancelRequested.contains(sessionId);

  ToolCall _toolCall(ToolCallStatus status) => ToolCall(
        id: 'tc-exec-1',
        title: 'Run tests',
        kind: 'execute',
        status: status,
        content: status == ToolCallStatus.completed
            ? const <ToolCallContent>[ToolCallText(text: 'exit 0')]
            : const <ToolCallContent>[],
        locations: const <String>[],
      );

  List<PlanEntry> _planEntries() => const <PlanEntry>[
        PlanEntry(
          content: 'Update the build script',
          priority: PlanPriority.high,
          status: PlanEntryStatus.pending,
        ),
        PlanEntry(
          content: 'Run the test suite',
          priority: PlanPriority.medium,
          status: PlanEntryStatus.pending,
        ),
      ];

  PermissionRequest _permissionRequest() => const PermissionRequest(
        requestId: 'pr-1',
        toolCallId: 'tc-exec-1',
        title: 'Allow running `flutter test`?',
        options: <PermissionOption>[
          PermissionOption(
            optionId: 'allow-once',
            name: 'Allow once',
            kind: PermissionKind.allowOnce,
          ),
          PermissionOption(
            optionId: 'reject',
            name: 'Reject',
            kind: PermissionKind.rejectOnce,
          ),
        ],
      );

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  Future<void> _delay() => Future<void>.delayed(eventDelay);

  Session _updateSession(
    String sessionId,
    Session Function(Session current) copy,
  ) {
    _requireSession(sessionId);
    final DateTime now = DateTime.now().toUtc();
    final Session current = _sessions[sessionId]!;
    final Session updated = Session(
      id: current.id,
      projectId: current.projectId,
      providerId: current.providerId,
      title: current.title,
      status: current.status,
      mode: current.mode,
      model: current.model,
      cwd: current.cwd,
      baseBranch: current.baseBranch,
      archived: current.archived,
      createdAt: current.createdAt,
      updatedAt: now,
    );
    final Session result = copy(updated);
    _sessions[sessionId] = result;
    _sessionUpdatesController.add(result);
    return result;
  }

  void _setStatus(String sessionId, SessionStatus status) {
    final Session? current = _sessions[sessionId];
    if (current == null || current.status == status) return;
    _sessions[sessionId] = Session(
      id: current.id,
      projectId: current.projectId,
      providerId: current.providerId,
      title: current.title,
      status: status,
      mode: current.mode,
      model: current.model,
      cwd: current.cwd,
      baseBranch: current.baseBranch,
      archived: current.archived,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
    _sessionUpdatesController.add(_sessions[sessionId]!);
  }

  void _removeSession(String sessionId) {
    _sessions.remove(sessionId);
    _history.remove(sessionId);
    _seqBySession.remove(sessionId);
    _runningScripts.remove(sessionId);
    _cancelRequested.remove(sessionId);
    _pendingPermissions.remove(sessionId);
    final StreamController<SessionEvent>? controller =
        _eventControllers.remove(sessionId);
    if (_disposed) return;
    _sessionRemovalsController.add(sessionId);
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  void _emit(String sessionId, SessionEvent event) {
    if (_disposed || !_sessions.containsKey(sessionId)) return;
    final int seq = (_seqBySession[sessionId] ?? 0) + 1;
    _seqBySession[sessionId] = seq;
    final SessionEvent stamped = _withSeq(event, seq, DateTime.now().toUtc());
    // History is the source for backfill and always records, listeners or not.
    _history.putIfAbsent(sessionId, () => <SessionEvent>[]).add(stamped);
    final StreamController<SessionEvent>? controller = _eventControllers[sessionId];
    if (controller != null && !controller.isClosed) {
      controller.add(stamped);
    }
  }

  SessionEvent _withSeq(SessionEvent event, int seq, DateTime timestamp) =>
      switch (event) {
        UserMessageEvent e =>
          UserMessageEvent(text: e.text, seq: seq, timestamp: timestamp),
        AgentMessageChunkEvent e =>
          AgentMessageChunkEvent(text: e.text, seq: seq, timestamp: timestamp),
        AgentThoughtChunkEvent e =>
          AgentThoughtChunkEvent(text: e.text, seq: seq, timestamp: timestamp),
        ToolCallEvent e =>
          ToolCallEvent(toolCall: e.toolCall, seq: seq, timestamp: timestamp),
        PlanEvent e => PlanEvent(entries: e.entries, seq: seq, timestamp: timestamp),
        PermissionRequestEvent e => PermissionRequestEvent(
            request: e.request, seq: seq, timestamp: timestamp),
        PermissionResolvedEvent e => PermissionResolvedEvent(
            requestId: e.requestId, optionId: e.optionId, seq: seq, timestamp: timestamp),
        UsageEvent e =>
          UsageEvent(usage: e.usage, seq: seq, timestamp: timestamp),
        TurnCompleteEvent e =>
          TurnCompleteEvent(stopReason: e.stopReason, seq: seq, timestamp: timestamp),
        SessionErrorEvent e =>
          SessionErrorEvent(message: e.message, seq: seq, timestamp: timestamp),
      };
}
