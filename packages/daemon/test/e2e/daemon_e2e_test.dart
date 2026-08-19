// Full-stack end-to-end test of the REAL SpeedDial daemon binary.
//
// Spawns the actual CLI entrypoint (`bin/speeddial.dart serve`) as a
// subprocess with a sandboxed `$HOME`, registers the fake ACP agent fixture
// as a provider through the on-disk config (`~/.speeddial/config.json`), and
// drives the daemon over the wire with the real [DaemonClient] — no mocks
// except the fake ACP agent. Also exercises three bookkeeping CLI commands as
// subprocesses (discovery via `~/.speeddial/daemon.json`), then shuts the
// daemon down with SIGINT and asserts graceful cleanup.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/client.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// The `packages/daemon` directory, whether the runner's cwd is the package
/// dir (`dart test` in packages/daemon) or the repo root
/// (`dart test packages/daemon`).
String daemonPackageDir() {
  if (File(p.join(Directory.current.path, 'bin', 'speeddial.dart')).existsSync()) {
    return Directory.current.path;
  }
  final fromRepo = p.join(Directory.current.path, 'packages', 'daemon');
  if (File(p.join(fromRepo, 'bin', 'speeddial.dart')).existsSync()) {
    return fromRepo;
  }
  throw StateError(
      'Cannot locate packages/daemon from cwd ${Directory.current.path}');
}

/// The fake ACP agent fixture as an absolute path, usable directly in the
/// provider config's `command` array.
String resolveFixture(String daemonPkg) =>
    p.join(daemonPkg, 'test', 'fixtures', 'fake_acp_agent.dart');

/// Polls [probe] until it returns non-null or [timeout] elapses.
Future<T> waitFor<T>(
  T? Function() probe, {
  required Duration timeout,
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return fail('Timed out after $timeout'
      '${reason == null ? '' : ' ($reason)'}');
}

/// A copy of the current environment pinned to the sandbox [homeDir]:
/// discovery/config/db resolve inside the sandbox, and the user's real
/// `~/.speeddial` is never consulted or touched.
Map<String, String> sandboxEnv(String homeDir) {
  final env = Map<String, String>.from(Platform.environment)
    ..['HOME'] = homeDir
    ..['GIT_CONFIG_NOSYSTEM'] = '1';
  env
    ..remove('SPEEDIAL_TOKEN')
    ..remove('SPEEDIAL_DB');
  return env;
}

/// Runs `git` in [repoPath]; fails the test on a non-zero exit.
Future<void> runGit(
  String repoPath,
  List<String> args, {
  required Map<String, String> env,
}) async {
  final result = await Process.run('git', args,
      workingDirectory: repoPath, environment: env);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed (exit ${result.exitCode}): '
        '${result.stderr}');
  }
}

/// `git init` with `main` as the initial branch (falls back to a plain init +
/// branch rename for older gits).
Future<void> initRepo(String repoPath, Map<String, String> env) async {
  final init = await Process.run('git', ['init', '-b', 'main'],
      workingDirectory: repoPath, environment: env);
  if (init.exitCode == 0) return;
  await runGit(repoPath, ['init'], env: env);
  await runGit(repoPath, ['checkout', '-b', 'main'], env: env);
}

void main() {
  const token = 'e2e-daemon-token';

  test('spawns the real daemon; drives a full session, git, fs, and CLI '
      'round trip; SIGINT shuts it down cleanly', () async {
    final daemonPkg = daemonPackageDir();
    final fixture = resolveFixture(daemonPkg);
    final binScript = p.join(daemonPkg, 'bin', 'speeddial.dart');

    // ---------------------------------------------------------------------
    // Sandbox: temp HOME for ~/.speeddial, temp git project repo.
    // ---------------------------------------------------------------------
    final tempRoot = await Directory.systemTemp.createTemp('speeddial_e2e');
    addTearDown(() async {
      try {
        await tempRoot.delete(recursive: true);
      } on Object {
        // Best-effort cleanup; not a test failure.
      }
    });
    final homeDir = p.join(tempRoot.path, 'home');
    final projectDir = p.join(tempRoot.path, 'project');
    Directory(homeDir).createSync(recursive: true);
    Directory(projectDir).createSync(recursive: true);
    final env = sandboxEnv(homeDir);

    // Provider config: register the fake ACP agent fixture as 'fake', and
    // disable the built-in omp provider's model probe so the sandboxed
    // daemon never shells out to a real agent CLI for `providers.list`.
    final configDir = p.join(homeDir, '.speeddial');
    Directory(configDir).createSync(recursive: true);
    File(p.join(configDir, 'config.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'providers': <String, Object?>{
          'fake': <String, Object?>{
            'name': 'Fake',
            'command': <String>[Platform.resolvedExecutable, fixture],
          },
          'omp': <String, Object?>{
            'name': 'OMP',
            'command': <String>['omp', 'acp'],
            'modelsCommand': <String>[],
          },
        },
      }),
    );

    // Project repo: git init, repo-local identity, one committed file. The
    // fake agent reads `$cwd/example.txt` (its FAKE_ACP_TARGET default), so
    // the file must exist in the project dir the session runs in.
    await initRepo(projectDir, env);
    await runGit(projectDir, ['config', 'user.name', 'E2E Tester'], env: env);
    await runGit(projectDir, ['config', 'user.email', 'e2e@example.com'],
        env: env);
    File(p.join(projectDir, 'example.txt'))
        .writeAsStringSync('fixture contents for the fake agent\n');
    File(p.join(projectDir, 'README.md')).writeAsStringSync('# E2E project\n');
    await runGit(projectDir, ['add', '-A'], env: env);
    await runGit(projectDir, ['commit', '-m', 'initial commit'], env: env);

    // ---------------------------------------------------------------------
    // Spawn the real daemon binary (port 0 → free port; --token → auth).
    // ---------------------------------------------------------------------
    final serve = await Process.start(
      Platform.resolvedExecutable,
      [binScript, 'serve', '--port', '0', '--token', token],
      workingDirectory: daemonPkg,
      environment: env,
    );
    final serveStdout = <String>[];
    final serveStderr = <String>[];
    serve.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(serveStdout.add);
    serve.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(serveStderr.add);
    // Safety net: never leave the daemon (or its fake-agent child) running.
    addTearDown(() async {
      try {
        serve.kill(ProcessSignal.sigint);
        await serve.exitCode.timeout(const Duration(seconds: 10));
      } on Object {
        // Already exited or unresponsive; nothing more to do.
      }
    });

    // The discovery file is written right after bind, before the banner.
    final discoveryPath = p.join(configDir, 'daemon.json');
    final discovery = await waitFor<Map<String, Object?>>(
      () {
        final file = File(discoveryPath);
        if (!file.existsSync()) return null;
        try {
          final decoded = jsonDecode(file.readAsStringSync());
          return decoded is Map ? Map<String, Object?>.from(decoded) : null;
        } on FormatException {
          return null;
        }
      },
      timeout: const Duration(seconds: 30),
      reason: 'daemon discovery file',
    );
    final port = discovery['port']! as int;
    expect(discovery['host'], '127.0.0.1');
    expect(discovery['token'], token);
    // The discovery file is written right after bind, BEFORE the banner is
    // printed — poll for the banner instead of racing stdout.
    await waitFor<bool>(
      () => serveStdout.any((line) =>
              line.contains('speeddial daemon listening on ws://127.0.0.1:$port'))
          ? true
          : null,
      timeout: const Duration(seconds: 30),
      reason: 'serve banner (stdout was: $serveStdout)',
    );
    // The discovery file carries the auth token: owner-only on POSIX. The
    // banner is printed after the (awaited) chmod, so the mode is settled.
    if (Platform.isLinux || Platform.isMacOS) {
      expect(FileStat.statSync(discoveryPath).mode & 0x1FF, 0x180,
          reason: 'daemon.json must be 0600 (owner-only)');
    }

    // ---------------------------------------------------------------------
    // Drive the daemon over the wire with the real DaemonClient.
    // ---------------------------------------------------------------------
    final url = 'ws://127.0.0.1:$port$kWsPath';
    final client = await DaemonClient.connect(url, token: token);
    addTearDown(() async {
      try {
        await client.close();
      } on Object {
        // Best-effort; the daemon may already be gone.
      }
    });

    final info = await client.info();
    expect(info.protocolVersion, 1);
    expect(info.authRequired, isTrue);
    expect(info.providers.map((provider) => provider.id), contains('fake'));
    final fake =
        info.providers.firstWhere((provider) => provider.id == 'fake');
    expect(fake.available, isTrue, reason: 'fixture must be spawnable');
    expect(fake.command, contains('fake_acp_agent.dart'));

    final project = await client.addProject(projectDir);
    expect(project.path, projectDir);

    final session = await client.createSession(
      projectId: project.id,
      providerId: 'fake',
    );
    expect(session.projectId, project.id);
    expect(session.providerId, 'fake');

    // Collect session.event notifications for the full turn.
    final collected = <({String sessionId, int seq, SessionEvent event})>[];
    final eventsSub = client.sessionEvents.listen((tuple) {
      if (tuple.sessionId == session.id) collected.add(tuple);
    });
    addTearDown(() => eventsSub.cancel());

    // sessions.send blocks until the turn completes: respond to the parked
    // permission request while it runs.
    final sendFuture = client.sendMessage(session.id, 'hello');
    final permission = await waitFor<PermissionRequestEvent>(
      () {
        for (final tuple in collected) {
          if (tuple.event is PermissionRequestEvent) {
            return tuple.event as PermissionRequestEvent;
          }
        }
        return null;
      },
      timeout: const Duration(seconds: 60),
      reason: 'permissionRequest event after sessions.send',
    );
    expect(permission.request.requestId, isNotEmpty);
    expect(permission.request.options.map((option) => option.optionId),
        containsAll(['allow', 'reject']));
    await client.respondPermission(
        session.id, permission.request.requestId, 'allow');
    await sendFuture.timeout(const Duration(seconds: 60));
    await waitFor<TurnCompleteEvent>(
      () {
        for (final tuple in collected) {
          if (tuple.event is TurnCompleteEvent) {
            return tuple.event as TurnCompleteEvent;
          }
        }
        return null;
      },
      timeout: const Duration(seconds: 30),
      reason: 'turnComplete event',
    );

    // Event order and per-session seq monotonicity (1, 2, 3, …).
    final types = <Type>[for (final tuple in collected) tuple.event.runtimeType];
    expect(types, const <Type>[
      UserMessageEvent,
      AgentMessageChunkEvent,
      AgentMessageChunkEvent,
      ToolCallEvent,
      ToolCallEvent,
      PlanEvent,
      PermissionRequestEvent,
      PermissionResolvedEvent,
      UsageEvent,
      TurnCompleteEvent,
    ]);
    final seqs = <int>[for (final tuple in collected) tuple.seq];
    expect(seqs, [for (var i = 1; i <= seqs.length; i++) i]);

    // Spot-check payloads along the turn.
    expect((collected[0].event as UserMessageEvent).text, 'hello');
    final chunks = <AgentMessageChunkEvent>[
      for (final tuple in collected)
        if (tuple.event is AgentMessageChunkEvent)
          tuple.event as AgentMessageChunkEvent,
    ];
    expect(chunks.map((event) => event.text).join(), contains('inspect'));
    final toolCalls = <ToolCallEvent>[
      for (final tuple in collected)
        if (tuple.event is ToolCallEvent) tuple.event as ToolCallEvent,
    ];
    expect(toolCalls, hasLength(2));
    expect(toolCalls[0].toolCall.id, 'tc1');
    expect(toolCalls[0].toolCall.status, ToolCallStatus.running);
    expect(toolCalls[0].toolCall.locations, contains('example.txt'));
    expect(toolCalls[1].toolCall.status, ToolCallStatus.completed);
    final plan = <PlanEvent>[
      for (final tuple in collected)
        if (tuple.event is PlanEvent) tuple.event as PlanEvent,
    ].single;
    expect(plan.entries, hasLength(2));
    final usage = <UsageEvent>[
      for (final tuple in collected)
        if (tuple.event is UsageEvent) tuple.event as UsageEvent,
    ].single;
    expect(usage.usage.totalTokens, 250);
    final resolved = <PermissionResolvedEvent>[
      for (final tuple in collected)
        if (tuple.event is PermissionResolvedEvent)
          tuple.event as PermissionResolvedEvent,
    ].single;
    expect(resolved.requestId, permission.request.requestId);
    expect(resolved.optionId, 'allow');

    // History replay matches the broadcast stream.
    final page = await client.history(session.id);
    expect(page.events.map((event) => event.runtimeType).toList(), types);
    expect(page.events.map((event) => event.seq).toList(), seqs);
    expect(page.hasMore, isFalse);

    // Git: clean → change → status shows it → commit --all → clean again.
    var status = await client.gitStatus(project.id);
    expect(status.branch, 'main');
    expect(status.files, isEmpty);
    File(p.join(projectDir, 'note.txt')).writeAsStringSync('e2e change\n');
    status = await client.gitStatus(project.id);
    expect(status.files.map((file) => file.path), contains('note.txt'));
    final hash =
        await client.gitCommit(project.id, 'add note.txt', stageAll: true);
    expect(hash, isNotEmpty);
    status = await client.gitStatus(project.id);
    expect(status.files, isEmpty);

    // fs.list on the repo root shows the committed files.
    final entries = await client.listFiles(project.id);
    expect([for (final entry in entries) entry.name],
        containsAll(['example.txt', 'note.txt']));

    // ---------------------------------------------------------------------
    // Bookkeeping CLI commands as subprocesses (discovery via daemon.json).
    // ---------------------------------------------------------------------
    Future<Map<String, Object?>> cliJson(List<String> args) async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [binScript, ...args],
        workingDirectory: daemonPkg,
        environment: env,
      );
      expect(result.exitCode, 0,
          reason: 'speeddial ${args.join(' ')} failed: '
              '${result.stderr}');
      return Map<String, Object?>.from(jsonDecode(result.stdout as String) as Map);
    }

    final sessionsJson = await cliJson(['--json', 'sessions', 'list']);
    final sessionIds = <Object?>[
      for (final raw in sessionsJson['sessions']! as List)
        Map<String, Object?>.from(raw as Map)['id'],
    ];
    expect(sessionIds, contains(session.id));

    final projectsJson = await cliJson(['--json', 'projects', 'list']);
    final projectIds = <Object?>[
      for (final raw in projectsJson['projects']! as List)
        Map<String, Object?>.from(raw as Map)['id'],
    ];
    expect(projectIds, contains(project.id));

    final gitJson =
        await cliJson(['--json', 'git', 'status', '--project', project.id]);
    final statusMap = Map<String, Object?>.from(gitJson['status']! as Map);
    expect(statusMap['branch'], 'main');
    expect(statusMap['files'], isEmpty);

    // ---------------------------------------------------------------------
    // `sessions attach` must exit with the daemon-unreachable code (2) when
    // the daemon dies, instead of hanging on its event stream.
    //
    // Explicit --host/--port/--token: the daemon deletes daemon.json on
    // shutdown, and this process (slow JIT startup) may only resolve its
    // connection after that. With discovery gone the CLI falls back to the
    // default 127.0.0.1:7331, where a developer's real daemon may be
    // listening — the test must never depend on that port.
    // ---------------------------------------------------------------------
    final attach = await Process.start(
      Platform.resolvedExecutable,
      [
        binScript,
        '--json',
        '--host', '127.0.0.1',
        '--port', '$port',
        '--token', token,
        'sessions', 'attach', session.id,
      ],
      workingDirectory: daemonPkg,
      environment: env,
    );
    final attachErr = StringBuffer();
    attach.stderr.transform(utf8.decoder).listen(attachErr.write);
    var attachExitedEarly = false;
    attach.exitCode.then((_) => attachExitedEarly = true);
    addTearDown(() async {
      try {
        if (!attachExitedEarly) {
          attach.kill(ProcessSignal.sigkill);
          await attach.exitCode.timeout(const Duration(seconds: 5));
        }
      } on Object {
        // Already gone; nothing to do.
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(attachExitedEarly, isFalse,
        reason: 'attach must stay connected while the daemon is up');

    // ---------------------------------------------------------------------
    // Graceful shutdown: SIGINT → exit 0, "stopped" banner, discovery gone.
    // ---------------------------------------------------------------------
    await client.close();
    serve.kill(ProcessSignal.sigint);
    expect(
      await serve.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
        serve.kill(ProcessSignal.sigkill);
        return 137; // SIGKILL'd: never the graceful exit 0.
      }),
      0,
      reason: 'serve stderr was: $serveStderr',
    );
    expect(serveStdout, contains(contains('speeddial daemon stopped')));
    expect(File(discoveryPath).existsSync(), isFalse,
        reason: 'daemon.json must be removed on shutdown');

    // The attach subprocess observed the daemon's death and exited with the
    // daemon-unreachable code instead of hanging.
    final attachCode = await attach.exitCode
        .timeout(const Duration(seconds: 10), onTimeout: () {
      attach.kill(ProcessSignal.sigkill);
      return 99;
    });
    expect(attachCode, 2, reason: 'attach stderr was: $attachErr');
    expect(attachErr.toString(), contains('cannot reach daemon'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
