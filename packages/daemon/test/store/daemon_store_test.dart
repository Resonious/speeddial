@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:test/test.dart';

DaemonStore openStore(Directory dir) =>
    DaemonStore(p.join(dir.path, 'speeddial.db'));

Project project({
  String id = 'p1',
  String? path,
  DateTime? addedAt,
}) =>
    Project(
      id: id,
      name: 'Project $id',
      path: path ?? p.join(Directory.systemTemp.path, 'proj-$id'),
      addedAt: addedAt ?? DateTime.utc(2026, 1, 1),
      lastActiveAt: addedAt ?? DateTime.utc(2026, 1, 2),
    );

Session session({
  required String id,
  String projectId = 'p1',
  String providerId = 'fake',
  SessionStatus status = SessionStatus.idle,
  SessionMode mode = SessionMode.build,
  String title = 'Test session',
  String? baseBranch,
  bool yolo = false,
  bool archived = false,
}) =>
    Session(
      id: id,
      projectId: projectId,
      providerId: providerId,
      title: title,
      status: status,
      mode: mode,
      model: null,
      cwd: p.join(Directory.systemTemp.path, 'cwd'),
      baseBranch: baseBranch,
      yolo: yolo,
      archived: archived,
      createdAt: DateTime.utc(2026, 1, 2),
      updatedAt: DateTime.utc(2026, 1, 2),
    );

void main() {
  late Directory tempDir;
  late DaemonStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('daemon_store_test');
    store = openStore(tempDir);
  });

  tearDown(() {
    store.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  test('project CRUD roundtrips and touch bumps lastActiveAt', () {
    final before = project();
    store.insertProject(before);
    store.insertProject(project(id: 'p2'));

    final loaded = store.getProject('p1')!;
    expect(loaded.id, 'p1');
    expect(loaded.name, 'Project p1');
    expect(loaded.path, before.path);
    expect(loaded.addedAt, DateTime.utc(2026, 1, 1).toUtc());

    expect(store.listProjects(), hasLength(2));
    expect(store.listProjects().first.id, 'p1');

    expect(store.getProject('nope'), isNull);

    store.touchProject('p1');
    final touched = store.getProject('p1')!;
    expect(
      touched.lastActiveAt.isAfter(before.lastActiveAt),
      isTrue,
      reason: 'touchProject must advance lastActiveAt',
    );
  });

  test('inserting a project with a duplicate path conflicts', () {
    final path = p.join(tempDir.path, 'shared');
    store.insertProject(project(id: 'p1', path: path));
    expect(
      () => store.insertProject(project(id: 'p2', path: path)),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrConflict)),
    );
  });

  test('session CRUD roundtrips and list filtering', () {
    store.insertProject(project());
    store.insertProject(
      project(id: 'p2', path: p.join(tempDir.path, 'other')),
    );
    store.insertSession(session(id: 's1'));
    store.insertSession(session(
      id: 's2',
      title: 'Archived one',
      status: SessionStatus.closed,
      archived: true,
    ));
    store.insertSession(
      session(id: 's3', projectId: 'p2', status: SessionStatus.running),
    );

    expect(store.getSession('s1'), isNotNull);
    expect(store.getSession('s1')!.status, SessionStatus.idle);
    expect(store.getSession('missing'), isNull);

    // Archived sessions hidden unless explicitly requested.
    expect(store.listSessions().map((s) => s.id), <String>['s1', 's3']);
    expect(
      store.listSessions(includeArchived: true).map((s) => s.id),
      <String>['s1', 's2', 's3'],
    );
    // Project filter.
    expect(
      store.listSessions(projectId: 'p2').map((s) => s.id),
      <String>['s3'],
    );

    // updateSession persists the new state and bumps nothing implicitly.
    final update = Session(
      id: 's1',
      projectId: 'p1',
      providerId: 'fake',
      title: 'Renamed',
      status: SessionStatus.waitingPermission,
      mode: SessionMode.plan,
      model: 'sonnet',
      cwd: '/cwd',
      baseBranch: 'main',
      yolo: true,
      archived: true,
      createdAt: store.getSession('s1')!.createdAt,
      updatedAt: DateTime.utc(2026, 1, 3),
    );
    store.updateSession(update);
    final reloaded = store.getSession('s1')!;
    expect(reloaded.title, 'Renamed');
    expect(reloaded.status, SessionStatus.waitingPermission);
    expect(reloaded.mode, SessionMode.plan);
    expect(reloaded.model, 'sonnet');
    expect(reloaded.baseBranch, 'main');
    expect(reloaded.yolo, isTrue);
    expect(reloaded.archived, isTrue);
    expect(reloaded.updatedAt, DateTime.utc(2026, 1, 3).toUtc());

    expect(
      () => store.updateSession(session(id: 'missing')),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
  });

  test('migrates pre-base_branch databases', () {
    store.dispose();
    final dbPath = p.join(tempDir.path, 'speeddial.db');
    File(dbPath).deleteSync();
    for (final suffix in const <String>['-wal', '-shm']) {
      final sidecar = File('$dbPath$suffix');
      if (sidecar.existsSync()) sidecar.deleteSync();
    }
    // Recreate the pre-merge-back schema: sessions without base_branch.
    final raw = sqlite3.open(dbPath);
    raw.execute('''
      CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        added_at INTEGER NOT NULL,
        last_active_at INTEGER NOT NULL
      );
    ''');
    raw.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES projects(id),
        provider_id TEXT NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL,
        mode TEXT NOT NULL,
        model TEXT,
        cwd TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    raw.execute(
      'INSERT INTO projects (id, name, path, added_at, last_active_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['p1', 'Project p1', '/tmp/proj-p1', 1, 1],
    );
    raw.execute(
      'INSERT INTO sessions (id, project_id, provider_id, title, status, '
      'mode, model, cwd, archived, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['s1', 'p1', 'fake', 'Legacy', 'idle', 'build', null, '/tmp/x', 0, 1, 1],
    );
    raw.dispose();

    store = openStore(tempDir);
    final migrated = store.getSession('s1')!;
    expect(migrated.title, 'Legacy');
    expect(migrated.baseBranch, isNull,
        reason: 'legacy rows gain a null base branch');
    expect(migrated.yolo, isFalse,
        reason: 'legacy rows default to yolo off');
    expect(store.acpSessionIdOf('s1'), isNull,
        reason: 'legacy rows have no resumable ACP session id');

    // New inserts carry the base branch and the yolo flag.
    store.insertSession(session(id: 's2', baseBranch: 'main', yolo: true));
    expect(store.getSession('s2')!.baseBranch, 'main');
    expect(store.getSession('s2')!.yolo, isTrue);
    expect(
      store.listSessions().map((s) => s.baseBranch),
      <String?>[null, 'main'],
    );

    // The migrated schema accepts ACP session ids.
    store.setAcpSessionId('s2', 'acp-42');
    expect(store.acpSessionIdOf('s2'), 'acp-42');
  });

  test('acp_session_id roundtrips and rejects unknown sessions', () {
    store.insertProject(project());
    store.insertSession(session(id: 's1'));

    expect(store.acpSessionIdOf('s1'), isNull);
    expect(store.acpSessionIdOf('missing'), isNull);

    store.setAcpSessionId('s1', 'acp-1');
    expect(store.acpSessionIdOf('s1'), 'acp-1');

    // Overwrite (a provider that re-issues ids on resume) works.
    store.setAcpSessionId('s1', 'acp-2');
    expect(store.acpSessionIdOf('s1'), 'acp-2');

    // The wire-facing Session model never carries the id.
    expect(store.getSession('s1')!.toJson().containsKey('acpSessionId'),
        isFalse);

    expect(
      () => store.setAcpSessionId('missing', 'acp-x'),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );

    // The value survives a reopen (it is the whole point of the column).
    store.dispose();
    store = openStore(tempDir);
    expect(store.acpSessionIdOf('s1'), 'acp-2');
  });

  test('removeProject archives its sessions and removes the project', () {
    store.insertProject(project());
    store.insertProject(project(id: 'p2', path: p.join(tempDir.path, 'other')));
    store.insertSession(session(id: 's1'));
    store.insertSession(session(id: 's2', projectId: 'p2'));

    store.removeProject('p1');

    expect(store.getProject('p1'), isNull);
    expect(store.listProjects().map((p) => p.id), <String>['p2']);
    // p1's sessions survive, archived.
    final survivors = store.listSessions(includeArchived: true).toList();
    expect(survivors.map((s) => s.id), <String>['s1', 's2']);
    final archived = survivors.firstWhere((s) => s.id == 's1');
    expect(archived.archived, isTrue);
    // Hidden from the default listing.
    expect(store.listSessions().map((s) => s.id), <String>['s2']);
  });

  test('per-session seq is monotonic and independent across sessions', () {
    store.insertProject(project());
    store.insertSession(session(id: 'a'));
    store.insertSession(session(id: 'b'));

    expect(store.nextSeq('a'), 1);
    store.appendEvent('a', store.nextSeq('a'), UserMessageEvent(text: 'x'));
    expect(store.nextSeq('a'), 2);
    store.appendEvent('a', store.nextSeq('a'), UserMessageEvent(text: 'y'));
    expect(store.nextSeq('a'), 3);

    // The other session starts fresh at 1.
    expect(store.nextSeq('b'), 1);
    store.appendEvent('b', store.nextSeq('b'), UserMessageEvent(text: 'z'));
    expect(store.nextSeq('b'), 2);

    final events = store.listEvents('a');
    expect(events.events.map((e) => e.seq), <int>[1, 2]);
    expect((events.events.first as UserMessageEvent).text, 'x');
    expect((events.events.last as UserMessageEvent).text, 'y');
  });

  test('listEvents pages newest-first with beforeSeq and hasMore', () {
    store.insertProject(project());
    store.insertSession(session(id: 'a'));
    for (var i = 1; i <= 10; i++) {
      store.appendEvent('a', store.nextSeq('a'), UserMessageEvent(text: 'm$i'));
    }
    final all = store.listEvents('a');
    expect(all.hasMore, isFalse);
    expect(
      all.events.map((e) => (e as UserMessageEvent).text),
      <String>['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10'],
    );

    final page1 = store.listEvents('a', limit: 3);
    expect(page1.hasMore, isTrue);
    expect(
      page1.events.map((e) => (e as UserMessageEvent).text),
      <String>['m8', 'm9', 'm10'],
    );
    expect(page1.events.first.seq, 8);

    final page2 = store.listEvents('a', limit: 3, beforeSeq: 8);
    expect(page2.hasMore, isTrue);
    expect(
      page2.events.map((e) => (e as UserMessageEvent).text),
      <String>['m5', 'm6', 'm7'],
    );

    final page3 = store.listEvents('a', limit: 3, beforeSeq: 5);
    expect(page3.hasMore, isTrue);
    expect(
      page3.events.map((e) => (e as UserMessageEvent).text),
      <String>['m2', 'm3', 'm4'],
    );

    final page4 = store.listEvents('a', limit: 3, beforeSeq: 2);
    expect(page4.hasMore, isFalse);
    expect(
      page4.events.map((e) => (e as UserMessageEvent).text),
      <String>['m1'],
    );
  });

  test('all event types round-trip through the store', () {
    store.insertProject(project());
    store.insertSession(session(id: 'a'));
    final toolCall = ToolCall(
      id: 'tc1',
      title: 'Edit file',
      kind: 'edit',
      status: ToolCallStatus.completed,
      content: const <ToolCallContent>[
        ToolCallDiff(path: 'a.dart', oldText: 'old', newText: 'new'),
      ],
      locations: const <String>['a.dart'],
      rawInput: <String, Object?>{'path': 'a.dart'},
      rawOutput: <String, Object?>{'ok': true},
    );
    final events = <SessionEvent>[
      UserMessageEvent(text: 'hi'),
      AgentMessageChunkEvent(text: 'chunk'),
      AgentThoughtChunkEvent(text: 'thought'),
      ToolCallEvent(toolCall: toolCall),
      PlanEvent(entries: const <PlanEntry>[
        PlanEntry(
          content: 'step',
          priority: PlanPriority.high,
          status: PlanEntryStatus.inProgress,
        ),
      ]),
      PermissionRequestEvent(
        request: PermissionRequest(
          requestId: 'r1',
          toolCallId: 'tc1',
          title: 'Allow?',
          options: const <PermissionOption>[
            PermissionOption(
              optionId: 'ok',
              name: 'OK',
              kind: PermissionKind.allowAlways,
            ),
          ],
        ),
      ),
      PermissionResolvedEvent(requestId: 'r1', optionId: 'ok'),
      UsageEvent(
        usage: const UsageInfo(
          inputTokens: 1,
          outputTokens: 2,
          totalTokens: 3,
          cost: '0.01',
        ),
      ),
      TurnCompleteEvent(stopReason: 'end_turn'),
      SessionErrorEvent(message: 'boom'),
    ];
    var seq = 1;
    for (final event in events) {
      final persisted = store.appendEvent('a', seq, event);
      expect(persisted.seq, seq);
      expect(persisted.timestamp, isNotNull);
      seq++;
    }

    final replayed = store.listEvents('a').events;
    expect(replayed, hasLength(events.length));
    for (var i = 0; i < events.length; i++) {
      expect(replayed[i].runtimeType, events[i].runtimeType,
          reason: 'event $i keeps its type');
    }
    final replayedTool = (replayed[3] as ToolCallEvent).toolCall;
    expect(replayedTool.id, 'tc1');
    expect(replayedTool.status, ToolCallStatus.completed);
    expect(replayedTool.content.single, isA<ToolCallDiff>());
    expect((replayedTool.content.single as ToolCallDiff).newText, 'new');
    final replayedPlan = (replayed[4] as PlanEvent);
    expect(replayedPlan.entries.single.priority, PlanPriority.high);
    expect(replayedPlan.entries.single.status, PlanEntryStatus.inProgress);
    final replayedPerm = (replayed[5] as PermissionRequestEvent).request;
    expect(replayedPerm.options.single.kind, PermissionKind.allowAlways);
    final replayedUsage = (replayed[7] as UsageEvent).usage;
    expect(replayedUsage.totalTokens, 3);
    expect(replayedUsage.cost, '0.01');
    expect((replayed[8] as TurnCompleteEvent).stopReason, 'end_turn');
    expect((replayed[9] as SessionErrorEvent).message, 'boom');
  });

  test('appendEvent enforces the per-session sequence key', () {
    store.insertProject(project());
    store.insertSession(session(id: 'a'));
    store.appendEvent('a', 1, UserMessageEvent(text: 'x'));
    expect(
      () => store.appendEvent('a', 1, UserMessageEvent(text: 'dup')),
      throwsA(isA<SqliteException>()),
    );
    // A later seq for the same session is fine (the duplicate was rejected).
    expect(store.nextSeq('a'), 2);
  });

  test('deleteSession removes the session and cascades its events', () {
    store.insertProject(project());
    store.insertSession(session(id: 'a'));
    store.appendEvent('a', 1, UserMessageEvent(text: 'x'));
    store.appendEvent('a', 2, UserMessageEvent(text: 'y'));

    store.deleteSession('a');
    expect(store.getSession('a'), isNull);
    expect(store.listEvents('a').events, isEmpty);
  });

  test('attachments round-trip including binary bytes and survive a reopen',
      () {
    store.insertProject(project());
    store.insertSession(session(id: 's1'));
    // Bytes that are not valid UTF-8: the payload must round-trip verbatim.
    final binaryBytes = <int>[0, 1, 2, 250, 251, 255, 128, 0];
    store.insertAttachment(
      's1',
      AttachmentData(
        id: 'a1',
        name: 'blob.bin',
        mimeType: 'application/octet-stream',
        size: binaryBytes.length,
        data: base64Encode(binaryBytes),
      ),
    );
    final loaded = store.getAttachment('s1', 'a1')!;
    expect(loaded.id, 'a1');
    expect(loaded.name, 'blob.bin');
    expect(loaded.mimeType, 'application/octet-stream');
    expect(loaded.size, binaryBytes.length);
    expect(base64Decode(loaded.data), binaryBytes);

    // Unknown ids and unknown sessions read as null.
    expect(store.getAttachment('s1', 'nope'), isNull);
    expect(store.getAttachment('nope', 'a1'), isNull);

    // Attachments are scoped to their session.
    store.insertSession(session(id: 's2'));
    expect(store.getAttachment('s2', 'a1'), isNull);

    // The payload survives a reopen (it is stored as a BLOB, not re-decoded
    // from the base64 metadata).
    store.dispose();
    store = openStore(tempDir);
    final reloaded = store.getAttachment('s1', 'a1')!;
    expect(reloaded.name, 'blob.bin');
    expect(base64Decode(reloaded.data), binaryBytes);
  });

  test('deleteSession cascades attachments', () {
    store.insertProject(project());
    store.insertSession(session(id: 's1'));
    store.insertAttachment(
      's1',
      AttachmentData(
        id: 'a1',
        name: 'notes.md',
        mimeType: 'text/markdown',
        size: 5,
        data: base64Encode(utf8.encode('hello')),
      ),
    );
    expect(store.getAttachment('s1', 'a1'), isNotNull);

    store.deleteSession('s1');
    expect(store.getAttachment('s1', 'a1'), isNull,
        reason: 'attachments die with their session (ON DELETE CASCADE)');
  });
}
