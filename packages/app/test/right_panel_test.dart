import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/right/right_panel.dart';

void main() {
  /// Pumps the right panel at 400x800 with a registered fake daemon and the
  /// seeded demo project selected, mirroring the shell's layout.
  Future<AppData> pumpRightPanel(
    WidgetTester tester,
    FakeDaemonClient fake,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppData app = AppData()..registerClient('fake', fake);
    final Project project = (await fake.listProjects()).single;
    app.selection.selectedDaemonId = 'fake';
    app.selection.selectedProjectId = project.id;

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: AppScope(data: app, child: const RightPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('files tab lists root entries with humanized sizes',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    final List<FileEntry> root = await fake.listFiles(project.id);
    for (final FileEntry entry in root) {
      expect(find.text(entry.name), findsOneWidget);
    }
    // lib/ is a directory (no size); the two files show byte counts.
    expect(find.text('120 B'), findsOneWidget); // main.dart
    expect(find.text('30 B'), findsOneWidget); // pubspec.yaml
  });

  testWidgets('expanding a directory lazily loads its children',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    final List<FileEntry> children = await fake.listFiles(project.id, 'lib');
    expect(children, isNotEmpty);

    // Only the root-level main.dart is visible before expansion.
    expect(find.text('main.dart'), findsOneWidget);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();

    // Root main.dart plus the child loaded from lib/.
    expect(find.text('main.dart'), findsNWidgets(2));
    final FileEntry child = children.single;
    expect(find.text('64 B'), findsOneWidget); // lib/main.dart size
    expect(child.isDir, isFalse);
  });

  testWidgets('tapping a file opens a highlighted viewer below the tree',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    await tester.tap(find.text('pubspec.yaml'));
    await tester.pumpAndSettle();

    // Tree row stays; the viewer header repeats the path.
    expect(find.text('pubspec.yaml'), findsNWidgets(2));
    final FileReadResult result =
        await fake.readFile(project.id, 'pubspec.yaml');
    expect(
      find.textContaining(result.content.trim(), findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('opens lib/main.dart with a dart-highlighted body',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    // The lib/ child is rendered before the root's own main.dart row.
    await tester.tap(find.text('main.dart').first);
    await tester.pumpAndSettle();

    expect(find.text('lib/main.dart'), findsOneWidget); // viewer path header
    final FileReadResult result =
        await fake.readFile(project.id, 'lib/main.dart');
    expect(
      find.textContaining(result.content.trim(), findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('git tab shows the branch and changed files',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    final GitStatus status = await fake.gitStatus(project.id);
    expect(find.text(status.branch), findsOneWidget); // branch dropdown
    expect(find.text(status.files.single.path), findsOneWidget);
    expect(find.text('Unstaged'), findsOneWidget);
    expect(find.text('Staged'), findsNothing);
  });

  testWidgets('git tab follows the selected worktree session',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData app = await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    // No session selected: the project checkout is shown.
    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);

    // Selecting a worktree session switches the tab to the session's tree:
    // the worktree branch and its (clean) status replace the project's.
    final Session session = await app.sessions.create(
      'fake',
      projectId: project.id,
      providerId: 'omp',
      title: 'Worktree session',
      baseBranch: 'main',
    );
    app.selection.selectedSessionId = session.id;
    await tester.pumpAndSettle();

    expect(find.text('speeddial/${session.id}'), findsOneWidget);
    expect(find.text('No changes'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsNothing);
    expect(
      app.git.statusFor(project.id, sessionId: session.id),
      isNotNull,
      reason: 'the pane refreshes under the session scope',
    );

    // Clearing the selection falls back to the project checkout.
    app.selection.selectedSessionId = null;
    await tester.pumpAndSettle();
    expect(find.text('lib/main.dart'), findsOneWidget);
  });

  testWidgets('tapping a changed file shows its diff with colored lines',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    await pumpRightPanel(tester, fake);
    final Project project = (await fake.listProjects()).single;

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    final GitStatus status = await fake.gitStatus(project.id);
    final GitDiff diff = (await fake.gitDiff(
      project.id,
      path: status.files.single.path,
    ))
        .single;
    final List<String> lines = diff.patch
        .split('\n')
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(lines, isNotEmpty);

    await tester.tap(find.text(status.files.single.path));
    await tester.pumpAndSettle();

    for (final String line in lines) {
      expect(find.text(line), findsWidgets, reason: 'patch line: $line');
    }
    // Color per line prefix: + green, - red, @@ hunk blue, ---/+++ meta amber.
    final SpeedDialColors colors = buildSpeedDialTheme().speedDialColors;
    final Text remove = tester.widget<Text>(find.text('-void main()').first);
    expect(remove.style?.color, colors.diffRemove);
    final Text add = tester
        .widget<Text>(find.text('+void main() { print("hi"); }').first);
    expect(add.style?.color, colors.success);
    final Text hunk = tester.widget<Text>(find.text('@@ -1 +1 @@').first);
    expect(hunk.style?.color, colors.running);
    final Text meta = tester.widget<Text>(find.text('--- a/lib/main.dart').first);
    expect(meta.style?.color, colors.waitingPermission);
  });

  testWidgets('commit button asks the session to commit its changes',
      (WidgetTester tester) async {
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData app = await pumpRightPanel(tester, fake);

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    // No session selected: there is no agent to instruct, so the button is
    // disabled.
    FilledButton commit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commit'),
    );
    expect(commit.onPressed, isNull);

    // sess-1 is a worktree session with base branch 'main'.
    await app.sessions.refresh('fake');
    app.selection.selectedSessionId = 'sess-1';
    await tester.pumpAndSettle();

    commit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commit'),
    );
    expect(commit.onPressed, isNotNull);

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();

    final List<SessionEvent> events = (await fake.history('sess-1')).events;
    expect(
      events.whereType<UserMessageEvent>().map((UserMessageEvent e) => e.text),
      contains('Please commit your changes'),
    );
    expect(
      find.text('Sent to session: Please commit your changes'),
      findsOneWidget,
    );

    // Let the snackbar's dismiss timer fire so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('create PR asks the session to base the PR on its base branch',
      (WidgetTester tester) async {
    final FakeDaemonClient fake =
        FakeDaemonClient(eventDelay: const Duration(milliseconds: 1));
    final AppData app = await pumpRightPanel(tester, fake);

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    // Without a worktree session the base branch is unknown: disabled.
    OutlinedButton createPr = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Create PR'),
    );
    expect(createPr.onPressed, isNull);

    // sess-1's base branch is 'main'.
    await app.sessions.refresh('fake');
    app.selection.selectedSessionId = 'sess-1';
    await tester.pumpAndSettle();

    createPr = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Create PR'),
    );
    expect(createPr.onPressed, isNotNull);

    await tester.tap(find.text('Create PR'));
    await tester.pumpAndSettle();

    final List<SessionEvent> events = (await fake.history('sess-1')).events;
    expect(
      events.whereType<UserMessageEvent>().map((UserMessageEvent e) => e.text),
      contains('Please create a PR based on main'),
    );

    // Let the snackbar's dismiss timer fire so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('git tab merges the session branch back into its base branch',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData app = await pumpRightPanel(tester, fake);

    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    // No session selected: the project checkout shows no merge-back action.
    expect(find.textContaining('Merge into'), findsNothing);
    expect(find.textContaining('Rebase onto'), findsNothing);

    // Load the seeded sessions and pick sess-1, whose base branch is 'main'.
    await app.sessions.refresh('fake');
    app.selection.selectedSessionId = 'sess-1';
    await tester.pumpAndSettle();

    expect(find.text('Merge into main'), findsOneWidget);

    await tester.tap(find.text('Merge into main'));
    await tester.pumpAndSettle();

    // The fake resolves a fast-forward merge, which the snackbar announces.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Merged'), findsOneWidget);

    // Let the snackbar's dismiss timer fire so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('git tab rebases the session branch onto its base branch',
      (WidgetTester tester) async {
    final FakeDaemonClient fake = FakeDaemonClient();
    final AppData app = await pumpRightPanel(tester, fake);

    await app.sessions.refresh('fake');
    app.selection.selectedSessionId = 'sess-1';
    await tester.tap(find.text('Git'));
    await tester.pumpAndSettle();

    // sess-1's base branch is 'main'.
    expect(find.text('Rebase onto main'), findsOneWidget);

    await tester.tap(find.text('Rebase onto main'));
    await tester.pumpAndSettle();

    // The fake resolves a rebase, which the snackbar announces.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Rebased'), findsOneWidget);

    // Let the snackbar's dismiss timer fire so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('failed directory listing shows an error row; retry recovers',
      (WidgetTester tester) async {
    final _FlakyFilesFake fake = _FlakyFilesFake();
    await pumpRightPanel(tester, fake);

    // The root load failed: an error row with a Retry button replaces the
    // endless spinner.
    expect(find.text('no such directory: .'), findsOneWidget);
    expect(find.byKey(const Key('files-dir-retry')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // The daemon recovers; retrying loads the listing.
    fake.allowRoot = true;
    await tester.tap(find.byKey(const Key('files-dir-retry')));
    await tester.pumpAndSettle();

    final Project project = (await fake.listProjects()).single;
    final List<FileEntry> root = await fake.listFiles(project.id);
    for (final FileEntry entry in root) {
      expect(find.text(entry.name), findsOneWidget);
    }
    expect(find.byKey(const Key('files-dir-retry')), findsNothing);
  });
}

/// A fake whose root directory listing fails until [allowRoot] is set,
/// driving the files tab's error-row + retry path.
class _FlakyFilesFake extends FakeDaemonClient {
  bool allowRoot = false;

  @override
  Future<List<FileEntry>> listFiles(String projectId, [String path = '.']) async {
    if (path == '.' && !allowRoot) {
      throw const DaemonError(kErrNotFound, 'no such directory: .');
    }
    return super.listFiles(projectId, path);
  }
}
