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
