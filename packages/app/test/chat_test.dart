import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';
import 'package:speeddial_app/src/ui/chat/permission_banner.dart';
import 'package:speeddial_app/src/ui/chat/plan_panel.dart';
import 'package:speeddial_app/src/ui/chat/tool_call_card.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  /// Pumps the chat pane at 1200x800 with a fake daemon registered (either
  /// [fake] or a fresh scripted one), and (optionally) a session selected.
  Future<(AppData, FakeDaemonClient)> pumpChat(
    WidgetTester tester, {
    bool selectSession = true,
    Duration eventDelay = const Duration(milliseconds: 1),
    FakeDaemonClient? fake,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fakeClient =
        fake ?? FakeDaemonClient(eventDelay: eventDelay);
    final AppData app = AppData()..registerClient('fake', fakeClient);
    await app.sessions.refresh('fake');

    if (selectSession) {
      final Project project = (await fakeClient.listProjects()).first;
      final Session session = (await fakeClient.listSessions()).first;
      app.selection
        ..selectedDaemonId = 'fake'
        ..selectedProjectId = project.id
        ..selectedSessionId = session.id;
    }

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        data: app,
        child: MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(body: ChatPane()),
        ),
      ),
    );
    await tester.pump();
    return (app, fakeClient);
  }

  /// Pumps frames until [condition] holds or [attempts] budget is spent.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    int attempts = 200,
    Duration step = const Duration(milliseconds: 10),
  }) async {
    for (int i = 0; i < attempts && !condition(); i++) {
      await tester.pump(step);
    }
  }

  testWidgets(
      'session already selected when the pane first mounts still renders its history',
      (WidgetTester tester) async {
    // Seed a completed turn BEFORE the pane ever mounts, then select the
    // session; the pane must watch it on its initial build (not only on a
    // later selection change) and backfill the persisted history.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final AppData app = AppData()..registerClient('fake', fake);
    await app.sessions.refresh('fake');
    final Project project = (await fake.listProjects()).first;
    final Session session = (await fake.listSessions()).first;

    await fake.sendMessage(session.id, 'hello seeded');
    await tester.pump(const Duration(seconds: 1)); // run the scripted turn

    app.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = project.id
      ..selectedSessionId = session.id;

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppScope(
        data: app,
        child: MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(body: ChatPane()),
        ),
      ),
    );
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('hello seeded').evaluate().isNotEmpty,
    );

    expect(find.text('hello seeded'), findsOneWidget);
    expect(
      find.textContaining('Working on it', findRichText: true),
      findsOneWidget,
    );
    // Drain stream + settle timers so the test ends clean.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('empty state shows the select-session placeholder',
      (WidgetTester tester) async {
    await pumpChat(tester, selectSession: false);

    expect(find.text('Select or create a session'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);
    expect(find.byType(PlanPanel), findsNothing);
  });

  testWidgets('streaming fake events render markdown, tool card and plan',
      (WidgetTester tester) async {
    await pumpChat(tester);

    // PROTOCOL.md: events only start flowing after `sessions.send` starts a
    // turn, so drive the composer (same path the other tests use).
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await pumpUntil(
      tester,
      () => find
          .textContaining('Working on it', findRichText: true)
          .evaluate()
          .isNotEmpty,
    );

    // Drain the markdown settle/highlight timer so the test ends clean.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));

    // Merged agent message chunks render as markdown body text.
    expect(
      find.textContaining('Working on it', findRichText: true),
      findsOneWidget,
    );
    // Tool call card (running -> completed via a second event) is a single card.
    expect(find.byType(ToolCallCard), findsOneWidget);
    // Plan event renders its checklist.
    expect(find.byType(PlanPanel), findsOneWidget);
    // Usage event surfaces in the composer footer.
    expect(find.textContaining('tokens'), findsOneWidget);
  });

  testWidgets('thinking indicator pulses while streaming, settles muted',
      (WidgetTester tester) async {
    // Slow script: the thought run stays open long enough to inspect.
    final (AppData app, FakeDaemonClient _) = await pumpChat(
      tester,
      fake: FakeDaemonClient(eventDelay: const Duration(seconds: 30)),
    );

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // First thought delta lands after one eventDelay.
    await pumpUntil(
      tester,
      () => find.text('Thinking…').evaluate().isNotEmpty,
      attempts: 5,
      step: const Duration(seconds: 31),
    );
    expect(find.text('Thinking…'), findsOneWidget);

    final BuildContext tileContext = tester.element(find.byType(ExpansionTile));
    final ColorScheme scheme = Theme.of(tileContext).colorScheme;

    // Active: primary-colored icon with a running pulse animation on both
    // the icon and the title.
    Icon icon = tester.widget(find.byIcon(Icons.psychology_outlined));
    expect(icon.color, scheme.primary);
    expect(find.byKey(const ValueKey<String>('thought-pulse')), findsNWidgets(2));
    final FadeTransition pulse = tester.widget(
      find.byKey(const ValueKey<String>('thought-pulse')).first,
    );
    expect(
      pulse.opacity.status,
      anyOf(AnimationStatus.forward, AnimationStatus.reverse),
    );

    // Drain the rest of the scripted turn (~10 delays of 30 s).
    await pumpUntil(
      tester,
      () =>
          app.chat.statusOf(app.selection.selectedSessionId!) ==
          SessionStatus.idle,
      attempts: 20,
      step: const Duration(seconds: 31),
    );
    await tester.pump();

    // Settled: past-tense title, muted icon, no pulse wrapper.
    expect(find.text('Thought'), findsOneWidget);
    expect(find.text('Thinking…'), findsNothing);
    icon = tester.widget(find.byIcon(Icons.psychology_outlined));
    expect(icon.color, scheme.onSurfaceVariant);
    expect(find.byKey(const ValueKey<String>('thought-pulse')), findsNothing);

    // Drain stream + settle timers so the test ends clean.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('timeline text is selectable and copyable',
      (WidgetTester tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await pumpUntil(
      tester,
      () => find
          .textContaining('Working on it', findRichText: true)
          .evaluate()
          .isNotEmpty,
    );
    // Let the markdown settle/highlight pass finish, then pump once more so
    // the re-parsed rows' selection containers have registered (selectAll in
    // the same frame as the rebuild would miss the code block's container).
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    final List<MethodCall> clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        clipboardCalls.add(call);
        return null;
      },
    );

    // The timeline wraps its ListView in one SelectionArea; the composer's
    // EditableText manages its own selection, so this is the only region.
    final SelectableRegionState region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll();
    // Copy the way SelectionArea's own Ctrl+C handling does: the region
    // registers a CopySelectionTextIntent action.
    final BuildContext textContext = tester.element(
      find.textContaining('Working on it', findRichText: true),
    );
    Actions.invoke(textContext, CopySelectionTextIntent.copy);

    final Iterable<MethodCall> writes = clipboardCalls.where(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(writes, hasLength(1));
    final String copied =
        (writes.single.arguments! as Map<Object?, Object?>)['text']!
            as String;
    expect(copied, contains('hello'));
    expect(copied, contains('Working on it'));
    expect(copied, contains('void main()'));
    expect(copied, contains('Done.'));
  });

  testWidgets('typing and Enter sends a message; user bubble appears',
      (WidgetTester tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(tester, () => find.text('hello world').evaluate().isNotEmpty);
    expect(find.text('hello world'), findsOneWidget);

    // Drain stream + settle timers.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Shift+Enter inserts a newline instead of sending',
      (WidgetTester tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'line one');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    final TextField field =
        tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'line one\n');
    // The newline landed in the field; nothing was sent — the exact text
    // appears only in the field itself, not as an extra user bubble.
    expect(find.text('line one\n'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('stop button shows while running and cancels back to idle',
      (WidgetTester tester) async {
    await pumpChat(
      tester,
      eventDelay: const Duration(milliseconds: 50),
    );

    await tester.enterText(find.byType(TextField), 'run this');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // Wait for the session to enter running (stop icon replaces send).
    await pumpUntil(
      tester,
      () => find.byIcon(Icons.stop_circle_outlined).evaluate().isNotEmpty,
      attempts: 50,
    );
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();

    await pumpUntil(
      tester,
      () => find.byIcon(Icons.stop_circle_outlined).evaluate().isEmpty,
    );
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    expect(find.byIcon(Icons.send), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('permission script shows banner; allow resolves the request',
      (WidgetTester tester) async {
    final (AppData app, _) = await pumpChat(
      tester,
      eventDelay: const Duration(milliseconds: 10),
    );

    await tester.enterText(find.byType(TextField), 'permission please');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(tester, () => find.byType(PermissionBanner).evaluate().isNotEmpty);
    expect(find.byType(PermissionBanner), findsOneWidget);

    // Allow options are the banner's FilledButtons (rejects are outlined).
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pump();

    await pumpUntil(tester, () => find.byType(PermissionBanner).evaluate().isEmpty);
    expect(find.byType(PermissionBanner), findsNothing);

    // Turn completed: observed status back to idle (lands at turnComplete,
    // a beat after the banner hides on permissionResolved).
    final String sessionId = (await app.clientFor('fake').listSessions()).first.id;
    await pumpUntil(
      tester,
      () => app.chat.statusOf(sessionId) == SessionStatus.idle,
    );
    expect(app.chat.statusOf(sessionId), SessionStatus.idle);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('send failure shows a SnackBar and restores the composer text',
      (WidgetTester tester) async {
    await pumpChat(tester, fake: _FailingSendFake());

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(
      tester,
      () => find.byType(SnackBar).evaluate().isNotEmpty,
    );
    // DaemonError surfaced as a SnackBar...
    expect(find.text('a turn is already running'), findsOneWidget);
    // ...and the draft was restored into the field.
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'hello');
    expect(find.byIcon(Icons.send), findsOneWidget); // send re-enabled

    // Let the SnackBar auto-dismiss timer fire so the test ends clean.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });
}

/// A fake whose sends always fail like a turn conflict, driving the
/// composer/pane failure path (SnackBar + text restore).
class _FailingSendFake extends FakeDaemonClient {
  @override
  Future<void> sendMessage(String sessionId, String text) async {
    throw const DaemonError(kErrConflict, 'a turn is already running');
  }
}
