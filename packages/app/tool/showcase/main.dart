// Showcase build for the landing page screenshots (`site/`).
//
//   flutter build web -t tool/showcase/main.dart
//
// Query parameters pick the scene: `?theme=light|dark` and
// `?session=<id>` (default: the finished upload session). The data is
// invented; nothing here talks to a daemon.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Uri.base follows <base href>, which drops the page's query string.
  final String search = _locationSearch;
  final Map<String, String> query = search.length > 1
      ? Uri.splitQueryString(search.substring(1))
      : const <String, String>{};
  final AppData data = AppData();
  await data.settings.init();
  await data.settings.setThemeMode(
    query['theme'] == 'light' ? ThemeMode.light : ThemeMode.dark,
  );

  final ShowcaseDaemonClient workstation = ShowcaseDaemonClient();
  await workstation.stage();
  data.registerClient('workstation', workstation);
  final List<(String, String, String, ConnectionStatus)> daemons =
      <(String, String, String, ConnectionStatus)>[
        (
          'workstation',
          'workstation',
          'wss://workstation.tail0c1d.ts.net/ws',
          ConnectionStatus.connected,
        ),
        (
          'studio',
          'Studio Mac',
          'ws://studio-mac.local:7331/ws',
          ConnectionStatus.connected,
        ),
        (
          'buildbox',
          'buildbox',
          'wss://buildbox.example.dev/ws',
          ConnectionStatus.connecting,
        ),
        (
          'laptop',
          'Laptop',
          'ws://thinkpad:7331/ws',
          ConnectionStatus.connected,
        ),
      ];
  for (final (String id, String name, String url, ConnectionStatus status)
      in daemons) {
    if (id != 'workstation') data.registerClient(id, FakeDaemonClient());
    await data.connections.addEndpoint(
      id: id,
      name: name,
      url: url,
      token: '',
      persist: false,
    );
    data.connections.setStatus(id, status);
  }
  data.selection.selectedDaemonId = 'workstation';
  await data.projects.refresh('workstation');
  await data.sessions.refresh('workstation');
  data.selection.selectedProjectId = ShowcaseDaemonClient.tidepoolId;
  final String sessionId = query['session'] ?? workstation.uploadSessionId;
  data.selection.selectedSessionId = sessionId;
  unawaited(
    data.git.refresh(
      'workstation',
      ShowcaseDaemonClient.tidepoolId,
      sessionId: sessionId,
    ),
  );
  runApp(SpeedDialApp(data: data));
}

@JS('location.search')
external String get _locationSearch;

/// How a staged session should look in listings (status, age, flags).
class _Dress {
  const _Dress(this.status, this.idleFor, {this.done = false});

  final SessionStatus status;
  final Duration idleFor;
  final bool done;
}

/// The fake daemon with a believable project list and conversations.
class ShowcaseDaemonClient extends FakeDaemonClient {
  ShowcaseDaemonClient() : super(eventDelay: const Duration(milliseconds: 60));

  static const String tidepoolId = 'proj-1';

  final Map<String, _Dress> _dress = <String, _Dress>{};
  late final String uploadSessionId;
  late final String runningSessionId;

  Future<void> stage() async {
    await removeProject('proj-demo');
    final Project tidepool = await addProject(
      '/home/sam/code/tidepool',
      name: 'tidepool',
    );
    assert(tidepool.id == tidepoolId);
    final Project harbor = await addProject(
      '/home/sam/code/harbor',
      name: 'harbor',
    );
    final Project inkwell = await addProject(
      '/home/sam/code/inkwell',
      name: 'inkwell',
    );

    Future<String> session(
      Project project,
      String provider,
      String title,
      _Dress dress, {
      SessionGitSummary? git,
    }) async {
      final Session s = await createSession(
        projectId: project.id,
        providerId: provider,
        title: title,
        baseBranch: 'main',
      );
      _dress[s.id] = dress;
      sessionGitSummaries[s.id] =
          git ??
          SessionGitSummary(
            sessionId: s.id,
            dirty: false,
            aheadOfBase: 0,
            behindBase: 0,
            mergedIntoBase: null,
          );
      return s.id;
    }

    SessionGitSummary merged(String id, {int behind = 0}) => SessionGitSummary(
      sessionId: id,
      dirty: false,
      aheadOfBase: 0,
      behindBase: behind,
      mergedIntoBase: true,
    );

    runningSessionId = await session(
      tidepool,
      'claude',
      'Passkey sign-in for the mobile app',
      const _Dress(SessionStatus.running, Duration.zero),
    );
    final String waiting = await session(
      tidepool,
      'codex',
      'Migrate the jobs table to Postgres 17',
      const _Dress(SessionStatus.waitingPermission, Duration(minutes: 2)),
    );
    uploadSessionId = await session(
      tidepool,
      'claude',
      'Stream large uploads straight to S3',
      const _Dress(SessionStatus.idle, Duration(minutes: 4)),
    );
    final String darkMode = await session(
      tidepool,
      'claude',
      'Dark mode for the billing pages',
      const _Dress(SessionStatus.idle, Duration(minutes: 50), done: true),
    );
    final String flaky = await session(
      tidepool,
      'codex',
      'Fix the flaky websocket reconnect test',
      const _Dress(SessionStatus.idle, Duration(hours: 2)),
    );
    final String i18n = await session(
      tidepool,
      'claude',
      'Extract strings for Japanese locale',
      const _Dress(SessionStatus.idle, Duration(hours: 20)),
    );
    final String bump = await session(
      harbor,
      'codex',
      'Bump tokio and fix the deprecations',
      const _Dress(SessionStatus.running, Duration.zero),
    );
    final String tls = await session(
      harbor,
      'claude',
      'Hot-reload TLS certificates',
      const _Dress(SessionStatus.idle, Duration(hours: 1)),
    );
    final String search = await session(
      inkwell,
      'claude',
      'Full-text search across notebooks',
      const _Dress(SessionStatus.idle, Duration(hours: 30)),
    );

    sessionGitSummaries
      ..[uploadSessionId] = SessionGitSummary(
        sessionId: uploadSessionId,
        dirty: false,
        aheadOfBase: 0,
        behindBase: 0,
        mergedIntoBase: true,
      )
      ..[darkMode] = merged(darkMode)
      ..[flaky] = merged(flaky, behind: 3)
      ..[i18n] = merged(i18n, behind: 7)
      ..[tls] = merged(tls)
      ..[search] = merged(search, behind: 2)
      ..[runningSessionId] = SessionGitSummary(
        sessionId: runningSessionId,
        dirty: true,
        aheadOfBase: 2,
        behindBase: 0,
        mergedIntoBase: false,
      )
      ..[waiting] = SessionGitSummary(
        sessionId: waiting,
        dirty: true,
        aheadOfBase: 0,
        behindBase: 0,
        mergedIntoBase: false,
      )
      ..[bump] = SessionGitSummary(
        sessionId: bump,
        dirty: true,
        aheadOfBase: 1,
        behindBase: 0,
        mergedIntoBase: false,
      );

    seedHistory(uploadSessionId, _uploadConversation());
    seedHistory(runningSessionId, _passkeyConversation());
  }

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    final List<Session> sessions = await super.listSessions(
      projectId: projectId,
      includeArchived: includeArchived,
    );
    final DateTime now = DateTime.now().toUtc();
    return <Session>[
      for (final Session s in sessions)
        if (_dress[s.id] case final _Dress dress)
          Session(
            id: s.id,
            projectId: s.projectId,
            providerId: s.providerId,
            title: s.title,
            status: dress.status,
            model: s.model,
            models: s.models,
            cwd: s.cwd,
            baseBranch: s.baseBranch,
            yolo: s.yolo,
            done: dress.done,
            archived: s.archived,
            createdAt: now.subtract(dress.idleFor + const Duration(hours: 1)),
            lastActivityAt: now.subtract(dress.idleFor),
            updatedAt: now.subtract(dress.idleFor),
          )
        else
          s,
    ];
  }

  @override
  Future<GitStatus> gitStatus(String projectId, {String? sessionId}) async {
    if (sessionId == runningSessionId) {
      return const GitStatus(
        branch: 'speeddial/passkeys',
        ahead: 2,
        behind: 0,
        files: <GitStatusFile>[
          GitStatusFile(
            path: 'app/lib/auth/passkey_sheet.dart',
            indexStatus: '?',
            worktreeStatus: '?',
            staged: false,
          ),
          GitStatusFile(
            path: 'server/src/auth/webauthn.ts',
            indexStatus: '.',
            worktreeStatus: 'M',
            staged: false,
          ),
          GitStatusFile(
            path: 'server/src/routes/session.ts',
            indexStatus: '.',
            worktreeStatus: 'M',
            staged: false,
          ),
        ],
      );
    }
    return super.gitStatus(projectId, sessionId: sessionId);
  }

  @override
  Future<List<GitDiff>> gitDiff(
    String projectId, {
    String? sessionId,
    String? path,
    bool staged = false,
  }) async {
    if (sessionId == runningSessionId) {
      return const <GitDiff>[
        GitDiff(
          path: 'server/src/auth/webauthn.ts',
          patch:
              '--- a/server/src/auth/webauthn.ts\n'
              '+++ b/server/src/auth/webauthn.ts\n'
              '@@ -12,7 +12,12 @@ export async function beginRegistration(user: User) {\n'
              '   const options = await generateRegistrationOptions({\n'
              '     rpName: "Tidepool",\n'
              '     rpID: config.rpId,\n'
              '-    userName: user.email,\n'
              '+    userName: user.email,\n'
              '+    userDisplayName: user.name ?? user.email,\n'
              '+    authenticatorSelection: {\n'
              '+      residentKey: "required",\n'
              '+      userVerification: "preferred",\n'
              '+    },\n'
              '   });\n',
          isNew: false,
          isDeleted: false,
          isBinary: false,
        ),
      ];
    }
    return super.gitDiff(
      projectId,
      sessionId: sessionId,
      path: path,
      staged: staged,
    );
  }

  @override
  Future<List<FileEntry>> listFiles(
    String projectId, [
    String path = '.',
  ]) async {
    if (path != '.') return const <FileEntry>[];
    final DateTime now = DateTime.now().toUtc();
    FileEntry entry(String name, {int size = 0}) => FileEntry(
      name: name,
      path: name,
      isDir: size == 0,
      size: size,
      modifiedAt: now,
    );
    return <FileEntry>[
      entry('.github'),
      entry('app'),
      entry('docs'),
      entry('server'),
      entry('web'),
      entry('.gitignore', size: 212),
      entry('AGENTS.md', size: 3480),
      entry('README.md', size: 5112),
      entry('docker-compose.yml', size: 1204),
      entry('package.json', size: 1630),
      entry('pnpm-lock.yaml', size: 284906),
      entry('pnpm-workspace.yaml', size: 64),
      entry('tsconfig.base.json', size: 588),
    ];
  }

  static ToolCall _tool(
    String id,
    String title,
    String kind, {
    ToolCallStatus status = ToolCallStatus.completed,
    List<ToolCallContent> content = const <ToolCallContent>[],
    List<String> locations = const <String>[],
  }) => ToolCall(
    id: id,
    title: title,
    kind: kind,
    status: status,
    content: content,
    locations: locations,
  );

  static List<SessionEvent> _uploadConversation() => <SessionEvent>[
    const UserMessageEvent(
      text:
          'Uploads over ~50 MB time out behind the load balancer. Stream them '
          'to S3 instead of buffering in memory, and keep the progress bar '
          'honest for big files.',
    ),
    const AgentThoughtChunkEvent(
      text:
          'Find where the upload route reads the body, then check how the '
          'bucket client writes objects.',
      messageId: 'u-t1',
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u1',
        'Read server/src/routes/upload.ts',
        'read',
        locations: const <String>['server/src/routes/upload.ts'],
      ),
    ),
    ToolCallEvent(
      toolCall: _tool('u2', 'Search "arrayBuffer(" in server/src', 'search'),
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u3',
        'Read server/src/storage/bucket.ts',
        'read',
        locations: const <String>['server/src/storage/bucket.ts'],
      ),
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u4',
        'Read web/src/components/UploadProgress.tsx',
        'read',
      ),
    ),
    const AgentMessageChunkEvent(
      text:
          'Found it: the route calls `await req.arrayBuffer()` before it '
          'touches the bucket, so a big file sits in memory while the 30 s '
          'proxy timer runs out. Switching to a streamed multipart upload.',
      messageId: 'u-m1',
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u5',
        'Edit server/src/routes/upload.ts',
        'edit',
        content: const <ToolCallContent>[
          ToolCallDiff(
            path: 'server/src/routes/upload.ts',
            oldText:
                'const body = await req.arrayBuffer();\n'
                'await bucket.put(key, body);\n',
            newText:
                'const upload = bucket.uploadStream(key, {\n'
                '  partSize: 8 * MiB,\n'
                '  onPart: (sent) => progress.emit(id, sent),\n'
                '});\n'
                'await pipeline(req.body, upload);\n',
          ),
        ],
      ),
    ),
    ToolCallEvent(
      toolCall: _tool('u6', 'Edit server/src/storage/bucket.ts', 'edit'),
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u7',
        'Edit web/src/components/UploadProgress.tsx',
        'edit',
      ),
    ),
    const AgentMessageChunkEvent(
      text: 'Now the tests, including a 120 MB fixture.',
      messageId: 'u-m2',
    ),
    ToolCallEvent(
      toolCall: _tool(
        'u8',
        'Run upload tests',
        'execute',
        content: const <ToolCallContent>[
          ToolCallText(
            text:
                '\$ pnpm test upload\n'
                ' ✓ routes/upload.test.ts (14)\n'
                ' ✓ storage/bucket.test.ts (6)\n'
                ' ✓ streams a 120 MB file without buffering (3.1s)\n\n'
                ' Test Files  3 passed (3)\n'
                '      Tests  21 passed (21)\n',
          ),
        ],
      ),
    ),
    const AgentMessageChunkEvent(
      text:
          'Uploads now stream straight to S3 in 8 MB parts. Nothing is held in '
          'memory, and the load balancer sees bytes moving the whole time.\n\n'
          '- **Route:** `server/src/routes/upload.ts` pipes the request body '
          'into `bucket.uploadStream()` instead of reading it whole.\n'
          '- **Progress:** each finished part emits `upload.progress`, so the '
          'bar moves for a 2 GB video the same as for a photo.\n'
          '- **Limit:** the size cap is now `UPLOAD_MAX_BYTES` (default '
          '2 GB) rather than a hard-coded 50 MB.\n\n'
          'All 21 upload tests pass, including a new 120 MB streaming test. '
          'Nothing is committed yet.',
      messageId: 'u-m3',
    ),
    const TurnCompleteEvent(stopReason: 'end_turn'),
    const UserMessageEvent(text: 'ship it'),
    ToolCallEvent(
      toolCall: _tool('u9', 'Commit, rebase on main, push', 'execute'),
    ),
    const AgentMessageChunkEvent(
      text:
          'Pushed to `main` as `4e1c9b2`, "Stream large uploads to S3". '
          '`origin/main` had two new commits, so I rebased first; the tests '
          'still pass on top.',
      messageId: 'u-m4',
    ),
    const UsageEvent(
      usage: UsageInfo(
        inputTokens: 18240,
        outputTokens: 9312,
        totalTokens: 27552,
        cost: '0.412870',
        cacheReadTokens: 214000,
        contextUsedTokens: 61840,
        contextLimitTokens: 1000000,
      ),
    ),
    const TurnCompleteEvent(stopReason: 'end_turn'),
  ];

  static List<SessionEvent> _passkeyConversation() => <SessionEvent>[
    const UserMessageEvent(
      text: 'How does sign-in work on web today? Short version.',
    ),
    ToolCallEvent(
      toolCall: _tool('p0a', 'Read web/src/auth/SignIn.tsx', 'read'),
    ),
    ToolCallEvent(
      toolCall: _tool('p0b', 'Read server/src/routes/session.ts', 'read'),
    ),
    const AgentMessageChunkEvent(
      text:
          'Email magic link first, then an optional passkey:\n\n'
          '1. `POST /session/link` mails a one-time link (15 min TTL).\n'
          '2. After the first sign-in, web offers to register a passkey via '
          '`@simplewebauthn/browser`.\n'
          '3. Later visits try `navigator.credentials.get()` first and fall '
          'back to the link.\n\n'
          'The mobile app only does step 1, which is why people keep '
          'digging through their inbox.',
      messageId: 'p-m0',
    ),
    const TurnCompleteEvent(stopReason: 'end_turn'),
    const UserMessageEvent(
      text:
          'Add passkey sign-in to the mobile app. Server already has '
          'WebAuthn for web; reuse it.',
    ),
    ToolCallEvent(
      toolCall: _tool('p1', 'Read server/src/auth/webauthn.ts', 'read'),
    ),
    ToolCallEvent(
      toolCall: _tool('p2', 'Search "signInWith" in app/lib', 'search'),
    ),
    ToolCallEvent(
      toolCall: _tool('p3', 'Read app/lib/auth/sign_in_page.dart', 'read'),
    ),
    const AgentMessageChunkEvent(
      text:
          'The server side is nearly there; it just needs discoverable '
          'credentials so the phone can offer the passkey without a username. '
          'Then a sheet in the app that drives the platform prompt.',
      messageId: 'p-m1',
    ),
    ToolCallEvent(
      toolCall: _tool('p4', 'Edit server/src/auth/webauthn.ts', 'edit'),
    ),
    ToolCallEvent(
      toolCall: _tool('p5', 'Write app/lib/auth/passkey_sheet.dart', 'edit'),
    ),
    ToolCallEvent(
      toolCall: _tool(
        'p6',
        'Run auth tests',
        'execute',
        status: ToolCallStatus.running,
      ),
    ),
  ];
}
