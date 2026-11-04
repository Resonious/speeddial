import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/git/pr_service.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// Writes an executable shim that logs its argv (one per line, prefixed
/// "ARG:") to `<dir>/args.log`, then runs [extra] (e.g. an echo / exit).
Future<String> _writeGhShim(Directory dir, String extra) async {
  final path = p.join(dir.path, 'gh');
  await File(path).writeAsString('''
#!/bin/sh
{
  for a in "\$@"; do
    echo "ARG:\$a"
  done
} > "${p.join(dir.path, 'args.log')}"
$extra
''');
  await Process.run('chmod', ['+x', path]);
  return path;
}

Future<List<String>> _capturedArgs(Directory dir) async {
  final lines = await File(p.join(dir.path, 'args.log')).readAsLines();
  return lines
      .where((l) => l.startsWith('ARG:'))
      .map((l) => l.substring('ARG:'.length))
      .toList();
}

void main() {
  Session session(String id, String cwd, {bool archived = false}) => Session(
    id: id, projectId: 'project', providerId: 'fake', title: id,
    status: SessionStatus.idle, model: null, cwd: cwd, baseBranch: 'main',
    yolo: false, archived: archived, createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
  );

  test('PR lookup matches worktree identity including archived forks', () async {
    final dir = await Directory.systemTemp.createTemp('sd_pr_lookup_');
    addTearDown(() => dir.delete(recursive: true));
    final gh = await _writeGhShim(dir, 'echo \'{"headRefName":"speeddial/old-title-aabbccdd"}\'');
    final service = PrService(ghPath: gh);
    final sessions = <Session>[
      session('aabbccdd-original', '/p/.speeddial-worktrees/repo-aabbccdd'),
      session('11223344-fork', '/p/.speeddial-worktrees/repo-aabbccdd', archived: true),
      session('aabbccdd-other', '/p/.speeddial-worktrees/repo-11223344'),
      session('unmanaged', '/p/repo-aabbccdd'),
    ];
    final found = await service.findSessions('https://github.com/org/repo/pull/42/files#x', sessions);
    expect(found.map((s) => s.id), ['aabbccdd-original', '11223344-fork']);
    expect(await _capturedArgs(dir), ['pr', 'view', 'https://github.com/org/repo/pull/42', '--json', 'headRefName']);
  });

  test('unreadable PR, malformed output, missing gh and unrelated branch are silent', () async {
    final dir = await Directory.systemTemp.createTemp('sd_pr_lookup_');
    addTearDown(() => dir.delete(recursive: true));
    const url = 'https://github.com/org/repo/pull/1';
    for (final script in ['exit 1', 'echo invalid', 'echo \'{}\'', 'echo \'{"headRefName":"main"}\'']) {
      final gh = await _writeGhShim(dir, script);
      expect(await PrService(ghPath: gh).findSessions(url, []), isEmpty);
    }
    expect(await PrService(ghPath: '${dir.path}/missing').findSessions(url, []), isEmpty);
    await File('${dir.path}/args.log').delete();
    expect(await PrService(ghPath: '${dir.path}/gh').findSessions('--help', []), isEmpty);
    expect(File('${dir.path}/args.log').existsSync(), isFalse);
  });

  group('refreshPullRequests', () {
    Future<PrService> serviceWith(String script) async {
      final dir = await Directory.systemTemp.createTemp('sd_pr_list_');
      addTearDown(() => dir.delete(recursive: true));
      return PrService(ghPath: await _writeGhShim(dir, script));
    }

    Future<PrService> serviceListing(List<Map<String, Object?>> prs) async {
      final dir = await Directory.systemTemp.createTemp('sd_pr_list_');
      addTearDown(() => dir.delete(recursive: true));
      final json = File(p.join(dir.path, 'prs.json'));
      await json.writeAsString(jsonEncode(prs));
      return PrService(
        ghPath: await _writeGhShim(dir, 'cat "${json.path}"'),
      );
    }

    Map<String, Object?> pr(
      int number,
      String branch, {
      String state = 'OPEN',
      bool draft = false,
      bool fork = false,
      String review = '',
      List<Object?> checks = const <Object?>[],
    }) => <String, Object?>{
      'number': number,
      'url': 'https://github.com/org/repo/pull/$number',
      'state': state,
      'isDraft': draft,
      'headRefName': branch,
      'isCrossRepository': fork,
      'reviewDecision': review,
      'statusCheckRollup': checks,
    };

    Future<SessionPullRequest?> lookup(
      PrService service,
      String branch,
    ) async {
      await service.refreshPullRequests('project', Directory.systemTemp.path);
      return service.pullRequestLookup('project')?.call(branch);
    }

    test('runs in the repository and lists every state', () async {
      final dir = await Directory.systemTemp.createTemp('sd_pr_list_');
      addTearDown(() => dir.delete(recursive: true));
      final gh = await _writeGhShim(dir, 'echo "[]"');
      await PrService(ghPath: gh).refreshPullRequests('project', dir.path);
      expect(
        await _capturedArgs(dir),
        containsAllInOrder(<String>['pr', 'list', '--state', 'all']),
      );
    });

    test('maps state, draft, review and branch', () async {
      final service = await serviceListing(<Map<String, Object?>>[
        pr(1, 'open', review: 'CHANGES_REQUESTED'),
        pr(2, 'draft', draft: true),
        pr(3, 'merged', state: 'MERGED', review: 'APPROVED'),
        pr(4, 'closed', state: 'CLOSED', review: 'REVIEW_REQUIRED'),
      ]);
      final open = await lookup(service, 'open');
      expect(open?.number, 1);
      expect(open?.url, 'https://github.com/org/repo/pull/1');
      expect(open?.state, PullRequestState.open);
      expect(open?.review, PullRequestReview.changesRequested);
      expect((await lookup(service, 'draft'))?.state, PullRequestState.draft);
      expect((await lookup(service, 'draft'))?.review, isNull);
      expect((await lookup(service, 'merged'))?.state, PullRequestState.merged);
      expect((await lookup(service, 'closed'))?.state, PullRequestState.closed);
      expect(await lookup(service, 'absent'), isNull);
    });

    test('rolls check runs and commit statuses up to one verdict', () async {
      const passed = <String, Object?>{
        'status': 'COMPLETED',
        'conclusion': 'SUCCESS',
      };
      const skipped = <String, Object?>{
        'status': 'COMPLETED',
        'conclusion': 'SKIPPED',
      };
      const running = <String, Object?>{'status': 'IN_PROGRESS', 'conclusion': ''};
      const failed = <String, Object?>{
        'status': 'COMPLETED',
        'conclusion': 'FAILURE',
      };
      const statusOk = <String, Object?>{'state': 'SUCCESS'};
      const statusPending = <String, Object?>{'state': 'PENDING'};
      const statusError = <String, Object?>{'state': 'ERROR'};
      final service = await serviceListing(<Map<String, Object?>>[
        pr(1, 'none'),
        pr(2, 'pass', checks: <Object?>[passed, skipped, statusOk]),
        pr(3, 'run', checks: <Object?>[passed, running]),
        pr(4, 'status-run', checks: <Object?>[statusPending]),
        pr(5, 'fail', checks: <Object?>[running, failed]),
        pr(6, 'status-fail', checks: <Object?>[passed, statusError]),
      ]);
      expect((await lookup(service, 'none'))?.checks, isNull);
      expect((await lookup(service, 'pass'))?.checks, PullRequestChecks.passing);
      expect((await lookup(service, 'run'))?.checks, PullRequestChecks.pending);
      expect(
        (await lookup(service, 'status-run'))?.checks,
        PullRequestChecks.pending,
      );
      expect((await lookup(service, 'fail'))?.checks, PullRequestChecks.failing);
      expect(
        (await lookup(service, 'status-fail'))?.checks,
        PullRequestChecks.failing,
      );
    });

    test('prefers the open pull request, then the newest', () async {
      final service = await serviceListing(<Map<String, Object?>>[
        pr(9, 'reopened', state: 'CLOSED'),
        pr(8, 'reopened'),
        pr(7, 'reopened', state: 'MERGED'),
        pr(6, 'finished', state: 'MERGED'),
        pr(5, 'finished', state: 'CLOSED'),
      ]);
      expect((await lookup(service, 'reopened'))?.number, 8);
      expect((await lookup(service, 'finished'))?.number, 6);
    });

    test('ignores forks, whose branch names are not ours', () async {
      final service = await serviceListing(<Map<String, Object?>>[
        pr(1, 'main', fork: true),
      ]);
      expect(await lookup(service, 'main'), isNull);
    });

    test('every failure is silent and keeps the last known data', () async {
      final dir = await Directory.systemTemp.createTemp('sd_pr_list_');
      addTearDown(() => dir.delete(recursive: true));
      final json = File(p.join(dir.path, 'out'));
      await json.writeAsString(jsonEncode(<Object?>[pr(1, 'feature')]));
      final gh = await _writeGhShim(dir, 'cat "${json.path}"');
      final service = PrService(ghPath: gh);
      expect((await lookup(service, 'feature'))?.number, 1);

      await json.writeAsString('not json');
      expect((await lookup(service, 'feature'))?.number, 1);
      await json.writeAsString('{}');
      expect((await lookup(service, 'feature'))?.number, 1);
      await json.delete(); // cat exits non-zero.
      expect((await lookup(service, 'feature'))?.number, 1);
    });

    test('no gh, no auth and a missing directory yield no lookup', () async {
      final loggedOut = await serviceWith('echo "not logged in" >&2; exit 4');
      await loggedOut.refreshPullRequests('project', Directory.systemTemp.path);
      expect(loggedOut.pullRequestLookup('project'), isNull);

      final missing = PrService(ghPath: '/nonexistent/gh');
      await missing.refreshPullRequests('project', Directory.systemTemp.path);
      expect(missing.pullRequestLookup('project'), isNull);

      final goneDir = await serviceWith('echo "[]"');
      await goneDir.refreshPullRequests('project', '/nonexistent/repo');
      expect(goneDir.pullRequestLookup('project'), isNull);
    });
  });

  test('isAvailable is true when gh auth status exits 0', () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    final gh = await _writeGhShim(dir, 'exit 0');
    final service = PrService(ghPath: gh);
    expect(await service.isAvailable(), isTrue);
  });

  test('isAvailable is false when gh missing', () async {
    final missing = p.join(Directory.systemTemp.path, 'gh-does-not-exist-xyz');
    final service = PrService(ghPath: missing);
    expect(await service.isAvailable(), isFalse);
  });

  test('createPullRequest with title passes --title/--body/--base/--draft',
      () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    await _writeGhShim(dir, 'echo "https://github.com/x/pull/1"');
    final service = PrService(ghPath: p.join(dir.path, 'gh'));

    final url = await service.createPullRequest(dir.path,
        title: 'My Title',
        body: 'Details here',
        base: 'dev',
        draft: true);

    expect(url, 'https://github.com/x/pull/1');
    expect(await _capturedArgs(dir), containsAllInOrder([
      'pr',
      'create',
      '--title',
      'My Title',
      '--body',
      'Details here',
      '--base',
      'dev',
      '--draft',
    ]));
  });

  test('createPullRequest with base/draft but no title combines --fill '
      'with the explicit flags', () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    await _writeGhShim(dir, 'echo "https://github.com/x/pull/3"');
    final service = PrService(ghPath: p.join(dir.path, 'gh'));

    final url = await service.createPullRequest(dir.path,
        base: 'main', draft: true);

    expect(url, 'https://github.com/x/pull/3');
    final args = await _capturedArgs(dir);
    expect(args, containsAllInOrder(['pr', 'create', '--fill']));
    expect(args, containsAllInOrder(['--base', 'main']));
    expect(args, contains('--draft'));
  });

  test('createPullRequest with no title uses --fill', () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    await _writeGhShim(dir, 'echo "https://github.com/x/pull/2"');
    final service = PrService(ghPath: p.join(dir.path, 'gh'));

    final url = await service.createPullRequest(dir.path);
    expect(url, 'https://github.com/x/pull/2');
    expect(await _capturedArgs(dir), ['pr', 'create', '--fill']);
  });

  test('uses URL from the last line of stdout', () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    await _writeGhShim(
        dir, 'echo "Creating pull request..." && echo "https://pr.example/9"');
    final service = PrService(ghPath: p.join(dir.path, 'gh'));
    final url = await service.createPullRequest(dir.path);
    expect(url, 'https://pr.example/9');
  });

  test('throws DaemonError kErrGit on non-zero exit', () async {
    final dir = await Directory.systemTemp.createTemp('sd_gh_');
    await _writeGhShim(dir, 'echo "boom" >&2; exit 1');
    final service = PrService(ghPath: p.join(dir.path, 'gh'));
    await expectLater(
      service.createPullRequest(dir.path, title: 'T'),
      throwsA(isA<DaemonError>()
          .having((e) => e.code, 'code', kErrGit)
          .having((e) => e.message, 'message', 'boom')
          .having((e) => (e.data as Map)['exitCode'], 'exitCode', 1)),
    );
  });
}
