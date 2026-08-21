import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';
import 'package:speeddial_app/src/ui/chat/composer.dart';
import 'package:speeddial_app/src/ui/chat/permission_banner.dart';
import 'package:speeddial_app/src/ui/chat/plan_panel.dart';
import 'package:speeddial_app/src/ui/chat/tool_call_card.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/daemon_error_text.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Fake whose `history()` can be held open (loading state) or failed
/// (error state) on demand, so the pane's history-loading surfaces are
/// testable.
class _GatedFake extends FakeDaemonClient {
  _GatedFake() : super(eventDelay: const Duration(milliseconds: 1));

  bool blockHistory = false;
  bool failHistory = false;
  final List<Completer<void>> _gates = <Completer<void>>[];

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    if (failHistory) throw StateError('daemon unreachable');
    if (blockHistory) {
      final Completer<void> gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    return super.history(sessionId, limit: limit, beforeSeq: beforeSeq);
  }

  void releaseHistory() {
    for (final Completer<void> gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }
}

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

  /// The thinking-level selector: [DropdownButton] under the 'Thinking
  /// level' tooltip, scoped by tooltip so it never matches an unrelated
  /// dropdown.
  Finder thinkingDropdown() => find.descendant(
    of: find.byTooltip('Thinking level'),
    matching: find.byType(DropdownButton<String>),
  );

  /// The model selector: searchable picker trigger under the 'Model'
  /// tooltip.
  Finder modelPicker() => find.byKey(const Key('composer-model'));

  /// Pumps a bare [Composer] (no pane) with an injected [AttachmentPicker]
  /// and a recorded send callback, so attachment staging is testable without
  /// the real platform picker.
  Future<void> pumpComposer(
    WidgetTester tester, {
    required AttachmentPicker picker,
    ClipboardImageReader? clipboardImageReader,
    Future<void> Function(String text, List<OutgoingAttachment> attachments)?
    onSend,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Composer(
            status: SessionStatus.idle,
            mode: SessionMode.build,
            attachmentPicker: picker,
            clipboardImageReader: clipboardImageReader,
            onSend:
                onSend ??
                (String text, List<OutgoingAttachment> attachments) async {},
            onStop: () {},
            onModeChanged: (SessionMode _) {},
          ),
        ),
      ),
    );
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
    },
  );

  testWidgets('fork action creates and selects history through that message', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    fake.seedHistory('sess-1', const <SessionEvent>[
      UserMessageEvent(text: 'Fork boundary'),
      AgentMessageChunkEvent(text: 'Excluded answer'),
      TurnCompleteEvent(stopReason: 'end_turn'),
    ]);
    final (AppData app, _) = await pumpChat(tester, fake: fake);
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey<String>('fork-message-1')).hasFound,
    );

    await tester.tap(find.byKey(const ValueKey<String>('fork-message-1')));
    await pumpUntil(tester, () => app.selection.selectedSessionId != 'sess-1');

    final String forkId = app.selection.selectedSessionId!;
    final Session? fork = app.sessions.byId(forkId);
    expect(fork, isNotNull);
    expect(fork!.title, 'Fork of Build the feature');
    final List<SessionEvent> history = (await fake.history(forkId)).events;
    expect(history, hasLength(1));
    expect((history.single as UserMessageEvent).text, 'Fork boundary');
    await pumpUntil(
      tester,
      () =>
          find.text('Fork boundary').evaluate().isNotEmpty &&
          find.text('Excluded answer').evaluate().isEmpty,
    );
    expect(find.text('Excluded answer'), findsNothing);
  });

  testWidgets('copy actions copy exact user and merged agent message text', (
    WidgetTester tester,
  ) async {
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    fake.seedHistory('sess-1', const <SessionEvent>[
      UserMessageEvent(text: 'Copy this user message'),
      AgentMessageChunkEvent(text: 'Merged **agent** '),
      AgentMessageChunkEvent(text: 'message'),
      TurnCompleteEvent(stopReason: 'end_turn'),
    ]);
    await pumpChat(tester, fake: fake);
    await pumpUntil(
      tester,
      () =>
          find.byKey(const ValueKey<String>('copy-message-1')).hasFound &&
          find.byKey(const ValueKey<String>('copy-message-3')).hasFound,
    );

    final List<MethodCall> clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        clipboardCalls.add(call);
        return null;
      },
    );

    await tester.tap(find.byKey(const ValueKey<String>('copy-message-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('copy-message-3')));
    await tester.pump();

    final List<String> copied = clipboardCalls
        .where((MethodCall call) => call.method == 'Clipboard.setData')
        .map(
          (MethodCall call) =>
              (call.arguments! as Map<Object?, Object?>)['text']! as String,
        )
        .toList();
    expect(copied, <String>[
      'Copy this user message',
      'Merged **agent** message',
    ]);
    expect(find.text('Message copied'), findsOneWidget);
  });

  testWidgets('empty state shows the select-session placeholder', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, selectSession: false);

    expect(find.text('Select or create a session'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);
    expect(find.byType(PlanPanel), findsNothing);
  });

  testWidgets('history in flight shows a loading surface, never an empty '
      'session', (WidgetTester tester) async {
    final _GatedFake gated = _GatedFake();
    final String sessionId = (await gated.listSessions()).first.id;
    gated.seedHistory(sessionId, <SessionEvent>[
      UserMessageEvent(text: 'from disk'),
    ]);
    gated.blockHistory = true;

    await pumpChat(tester, fake: gated);
    await tester.pump();

    // While the fetch is held open the pane must not render as empty.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading history…'), findsOneWidget);

    gated.blockHistory = false;
    gated.releaseHistory();
    await pumpUntil(tester, () => find.text('from disk').evaluate().isNotEmpty);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('from disk'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a failed history load offers a retry that recovers', (
    WidgetTester tester,
  ) async {
    final _GatedFake gated = _GatedFake();
    final String sessionId = (await gated.listSessions()).first.id;
    gated.seedHistory(sessionId, <SessionEvent>[
      UserMessageEvent(text: 'from disk'),
    ]);
    gated.failHistory = true;

    await pumpChat(tester, fake: gated);
    await pumpUntil(
      tester,
      () => find.text('Could not load history').evaluate().isNotEmpty,
    );

    expect(find.text('Could not load history'), findsOneWidget);
    expect(find.byKey(const Key('history-retry')), findsOneWidget);
    expect(find.text('from disk'), findsNothing);

    // Daemon back: the retry button refetches and the content arrives.
    gated.failHistory = false;
    await tester.tap(find.byKey(const Key('history-retry')));
    await pumpUntil(tester, () => find.text('from disk').evaluate().isNotEmpty);
    expect(find.text('Could not load history'), findsNothing);
    expect(find.text('from disk'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('streaming fake events render markdown, tool card and plan', (
    WidgetTester tester,
  ) async {
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

  testWidgets('thinking indicator pulses while streaming, settles muted', (
    WidgetTester tester,
  ) async {
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
    expect(
      find.byKey(const ValueKey<String>('thought-pulse')),
      findsNWidgets(2),
    );
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

  testWidgets('timeline text is selectable and copyable', (
    WidgetTester tester,
  ) async {
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
        (writes.single.arguments! as Map<Object?, Object?>)['text']! as String;
    expect(copied, contains('hello'));
    expect(copied, contains('Working on it'));
    expect(copied, contains('void main()'));
    expect(copied, contains('Done.'));
  });

  testWidgets('typing and Enter sends a message; user bubble appears', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(
      tester,
      () => find.text('hello world').evaluate().isNotEmpty,
    );
    expect(find.text('hello world'), findsOneWidget);

    // Drain stream + settle timers.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Shift+Enter inserts a newline instead of sending', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'line one');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'line one\n');
    // The newline landed in the field; nothing was sent — the exact text
    // appears only in the field itself, not as an extra user bubble.
    expect(find.text('line one\n'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('stop button shows while running and cancels back to idle', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, eventDelay: const Duration(milliseconds: 50));

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

  testWidgets('permission script shows banner; allow resolves the request', (
    WidgetTester tester,
  ) async {
    final (AppData app, _) = await pumpChat(
      tester,
      eventDelay: const Duration(milliseconds: 10),
    );

    await tester.enterText(find.byType(TextField), 'permission please');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(
      tester,
      () => find.byType(PermissionBanner).evaluate().isNotEmpty,
    );
    expect(find.byType(PermissionBanner), findsOneWidget);

    // Allow options are the banner's FilledButtons (rejects are outlined).
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pump();

    await pumpUntil(
      tester,
      () => find.byType(PermissionBanner).evaluate().isEmpty,
    );
    expect(find.byType(PermissionBanner), findsNothing);

    // Turn completed: observed status back to idle (lands at turnComplete,
    // a beat after the banner hides on permissionResolved).
    final String sessionId =
        (await app.clientFor('fake').listSessions()).first.id;
    await pumpUntil(
      tester,
      () => app.chat.statusOf(sessionId) == SessionStatus.idle,
    );
    expect(app.chat.statusOf(sessionId), SessionStatus.idle);

    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('send failure shows a SnackBar and restores the composer text', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, fake: _FailingSendFake());

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
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

  testWidgets('a connection drop on send shows a reconnecting notice, not '
      'the raw socket error', (WidgetTester tester) async {
    await pumpChat(tester, fake: _DroppedConnectionFake());

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    // The drop self-heals (auto-reconnect + resync): transient copy only.
    expect(find.text(kConnectionLostMessage), findsOneWidget);
    expect(find.text('peer closed'), findsNothing);
    // The draft is still restored: the daemon may never have received it.
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'hello');

    // Let the SnackBar auto-dismiss timer fire so the test ends clean.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  // A real 1x1 transparent PNG, so image thumbnails decode in tests.
  final Uint8List pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  testWidgets('pasting an image stages and sends a PNG attachment', (
    WidgetTester tester,
  ) async {
    String? sentText;
    List<OutgoingAttachment>? sentAttachments;
    await pumpComposer(
      tester,
      picker: () async => const <({String name, Uint8List bytes})>[],
      clipboardImageReader: () async => pngBytes,
      onSend: (String text, List<OutgoingAttachment> attachments) async {
        sentText = text;
        sentAttachments = attachments;
      },
    );

    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(sentText, isEmpty);
    expect(sentAttachments, hasLength(1));
    expect(sentAttachments!.single.name, 'pasted-image.png');
    expect(sentAttachments!.single.mimeType, 'image/png');
    expect(sentAttachments!.single.data, base64Encode(pngBytes));
    expect(find.byTooltip('Remove'), findsNothing);
  });

  testWidgets('text paste still uses the TextField default action', (
    WidgetTester tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': 'pasted text'};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpComposer(
      tester,
      picker: () async => const <({String name, Uint8List bytes})>[],
      clipboardImageReader: () async => null,
    );

    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();

    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'pasted text');
    expect(find.byTooltip('Remove'), findsNothing);
  });

  testWidgets('keyboard rich content stages an image attachment', (
    WidgetTester tester,
  ) async {
    List<OutgoingAttachment>? sentAttachments;
    await pumpComposer(
      tester,
      picker: () async => const <({String name, Uint8List bytes})>[],
      clipboardImageReader: () async => null,
      onSend: (String text, List<OutgoingAttachment> attachments) async {
        sentAttachments = attachments;
      },
    );

    final TextField field = tester.widget<TextField>(find.byType(TextField));
    field.contentInsertionConfiguration!.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/jpeg',
        uri: 'content://clipboard/image',
        data: pngBytes,
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(sentAttachments, hasLength(1));
    expect(sentAttachments!.single.name, 'pasted-image.png');
    expect(sentAttachments!.single.mimeType, 'image/png');
  });

  testWidgets('attach button stages chips including an image thumbnail', (
    WidgetTester tester,
  ) async {
    await pumpComposer(
      tester,
      picker: () async => <({String name, Uint8List bytes})>[
        (name: 'shot.png', bytes: pngBytes),
        (name: 'notes.txt', bytes: Uint8List.fromList(<int>[104, 105])),
      ],
    );

    expect(find.byIcon(Icons.attach_file), findsOneWidget);
    // Send disabled with no draft (no text, no attachments).
    IconButton send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(send.onPressed, isNull);

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    // Image chip renders a decoded thumbnail; the text file renders a name
    // chip; each has a remove affordance.
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsNWidgets(2));

    // Attachments alone (still no text) enable send.
    send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(send.onPressed, isNotNull);
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('removing a staged chip drops it and re-disables send', (
    WidgetTester tester,
  ) async {
    await pumpComposer(
      tester,
      picker: () async => <({String name, Uint8List bytes})>[
        (name: 'one.txt', bytes: Uint8List.fromList(<int>[1])),
        (name: 'two.txt', bytes: Uint8List.fromList(<int>[2])),
      ],
    );

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();
    expect(find.byTooltip('Remove'), findsNWidgets(2));

    // Remove the second chip.
    await tester.tap(find.byTooltip('Remove').last);
    await tester.pump();
    expect(find.text('two.txt'), findsNothing);
    expect(find.text('one.txt'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget);

    // Remove the last one: no chips, send disabled again.
    await tester.tap(find.byTooltip('Remove'));
    await tester.pump();
    expect(find.byTooltip('Remove'), findsNothing);
    final IconButton send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('send with empty text and an attachment delivers attachments and '
      'clears the chips', (WidgetTester tester) async {
    String? sentText;
    List<OutgoingAttachment>? sentAttachments;
    await pumpComposer(
      tester,
      picker: () async => <({String name, Uint8List bytes})>[
        (name: 'notes.txt', bytes: Uint8List.fromList(<int>[104, 105])),
      ],
      onSend: (String text, List<OutgoingAttachment> attachments) async {
        sentText = text;
        sentAttachments = attachments;
      },
    );

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    // The daemon-facing payload: name, mime type, base64 data; empty text.
    expect(sentText, isEmpty);
    expect(sentAttachments, hasLength(1));
    final OutgoingAttachment sent = sentAttachments!.single;
    expect(sent.name, 'notes.txt');
    expect(sent.mimeType, 'text/plain');
    expect(sent.data, 'aGk='); // base64 of [104, 105]

    // Chips cleared, field still empty, send disabled again.
    expect(find.byTooltip('Remove'), findsNothing);
    expect(find.text('notes.txt'), findsNothing);
    final IconButton send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('a failed send restores both the text and the attachments', (
    WidgetTester tester,
  ) async {
    await pumpComposer(
      tester,
      picker: () async => <({String name, Uint8List bytes})>[
        (name: 'notes.txt', bytes: Uint8List.fromList(<int>[104, 105])),
      ],
      onSend: (String text, List<OutgoingAttachment> attachments) async {
        throw const DaemonError(kErrConflict, 'a turn is already running');
      },
    );

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    // Both halves of the draft are back: text in the field, chip restored.
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'hello');
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget);
    // Send is re-enabled (text restored).
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('a user message with attachments renders file chips and an image '
      'thumbnail from readAttachment', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final Session session = (await fake.listSessions()).first;
    // Seed a completed turn whose user message carries both an image and a
    // text file; the fake stores the payloads for attachments.read.
    await fake.sendMessage(
      session.id,
      'look at these',
      attachments: <OutgoingAttachment>[
        OutgoingAttachment(
          name: 'shot.png',
          mimeType: 'image/png',
          data: base64Encode(pngBytes),
        ),
        OutgoingAttachment(
          name: 'notes.txt',
          mimeType: 'text/plain',
          data: base64Encode(Uint8List.fromList(<int>[104, 105])),
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 1)); // run the scripted turn

    await pumpChat(tester, fake: fake);
    await pumpUntil(
      tester,
      () => find.text('look at these').evaluate().isNotEmpty,
    );
    expect(find.text('look at these'), findsOneWidget);

    // Non-image attachment renders its compact icon+name+size row.
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('2 B'), findsOneWidget);

    // Image thumbnail arrives once readAttachment resolves and decodes.
    await pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(find.byType(Image), findsOneWidget);

    // Drain stream + settle timers so the test ends clean.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('an MCP image event renders its persisted attachment', (
    WidgetTester tester,
  ) async {
    const Attachment attachment = Attachment(
      id: 'mcp-image',
      name: 'analysis.png',
      mimeType: 'image/png',
      size: 70,
    );
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildSpeedDialTheme(),
        home: Scaffold(
          body: Timeline(
            items: deriveTimelineItems(<SessionEvent>[
              const ImageEvent(attachment: attachment, seq: 1),
            ]),
            attachmentLoader: (String attachmentId) async => AttachmentData(
              id: attachmentId,
              name: attachment.name,
              mimeType: attachment.mimeType,
              size: pngBytes.length,
              data: base64Encode(pngBytes),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('analysis.png'), findsOneWidget);
  });

  testWidgets('a session with thinking levels lists exactly the advertised '
      'options', (WidgetTester tester) async {
    // Default pumpChat selects sess-1, which advertises the five omp levels.
    await pumpChat(tester);

    // The selector starts showing the current level (max), capitalized.
    expect(thinkingDropdown(), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);

    // Open the selector: every advertised level appears, and nothing else.
    await tester.tap(thinkingDropdown());
    await tester.pumpAndSettle();
    for (final String label in <String>['Off', 'Auto', 'Low', 'High', 'Max']) {
      expect(
        find.text(label).evaluate(),
        isNotEmpty,
        reason: 'expected "$label" in the thinking dropdown',
      );
    }
    expect(find.text('Thinking'), findsNothing);

    // Close the menu so the test ends clean.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('selecting a thinking level calls through and updates the UI', (
    WidgetTester tester,
  ) async {
    final (AppData _, FakeDaemonClient fake) = await pumpChat(tester);

    await tester.tap(thinkingDropdown());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Low').last);
    await tester.pumpAndSettle();

    // The fake client's session reflects the choice…
    final Session updated = (await fake.listSessions()).firstWhere(
      (Session s) => s.id == 'sess-1',
    );
    expect(updated.thinkingLevel, 'low');
    expect(updated.thinkingLevels, const <String>[
      'off',
      'auto',
      'low',
      'high',
      'max',
    ]);

    // …and the closed dropdown button now shows the new level.
    expect(thinkingDropdown(), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Max'), findsNothing);
  });

  testWidgets('a session without advertised options renders no selectors', (
    WidgetTester tester,
  ) async {
    final (AppData app, _) = await pumpChat(tester);

    // sess-2 keeps the defaults (no advertised thinking levels or models).
    app.selection
      ..selectedProjectId = 'proj-demo'
      ..selectedSessionId = 'sess-2';
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.byTooltip('Model'), findsNothing);
    expect(
      find.text('omp-default'),
      findsNothing,
      reason: 'no static model text either — model is null',
    );
  });

  testWidgets('a session with models lists exactly the advertised ids', (
    WidgetTester tester,
  ) async {
    // Default pumpChat selects sess-1, which advertises three omp models.
    await pumpChat(tester);

    // The selector starts showing the current id, raw (no capitalization).
    expect(modelPicker(), findsOneWidget);
    expect(find.text('omp-default'), findsOneWidget);

    // Open the picker: every advertised id appears, and nothing else.
    await tester.tap(modelPicker());
    await tester.pumpAndSettle();
    for (final String id in <String>['omp-default', 'kimi-k3', 'gpt-5.2']) {
      expect(
        find.text(id).evaluate(),
        isNotEmpty,
        reason: 'expected "$id" in the model picker',
      );
    }
    expect(
      find.text('omp-fast'),
      findsNothing,
      reason: 'only advertised ids, not the provider\'s full list',
    );
    expect(find.text('claude-sonnet'), findsNothing);

    // Close the picker so the test ends clean.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('selecting a model calls through and updates the UI', (
    WidgetTester tester,
  ) async {
    final (AppData _, FakeDaemonClient fake) = await pumpChat(tester);

    await tester.tap(modelPicker());
    await tester.pumpAndSettle();
    await tester.tap(find.text('kimi-k3').last);
    await tester.pumpAndSettle();

    // The fake client's session reflects the choice…
    final Session updated = (await fake.listSessions()).firstWhere(
      (Session s) => s.id == 'sess-1',
    );
    expect(updated.model, 'kimi-k3');
    expect(updated.models, const <String>['omp-default', 'kimi-k3', 'gpt-5.2']);

    // …and the closed picker button now shows the new id.
    expect(modelPicker(), findsOneWidget);
    expect(find.text('kimi-k3'), findsOneWidget);
    expect(find.text('omp-default'), findsNothing);
  });

  testWidgets('the picker searches; Enter picks, Escape keeps the current', (
    WidgetTester tester,
  ) async {
    final (AppData _, FakeDaemonClient fake) = await pumpChat(tester);
    final Finder queryField = find.byKey(const Key('model-picker-query'));

    // Typing filters, case-insensitively.
    await tester.tap(modelPicker());
    await tester.pumpAndSettle();
    await tester.enterText(queryField, 'KIMI');
    await tester.pumpAndSettle();
    expect(find.text('kimi-k3'), findsOneWidget);
    expect(
      find.text('omp-default'),
      findsOneWidget,
      reason: 'filtered out of the list; only the trigger label remains',
    );
    expect(find.text('gpt-5.2'), findsNothing);

    // A query with no matches shows the empty state, and Enter is a no-op.
    await tester.enterText(queryField, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matching models'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(queryField, findsOneWidget);

    // Escape closes without a pick: the session keeps its current model.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(queryField, findsNothing);
    expect(await _fakeSessionModel(fake), 'omp-default');

    // Arrow-down moves the active row and Enter selects it.
    await tester.tap(modelPicker());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await _fakeSessionModel(fake), 'kimi-k3');
  });
}

/// The fake daemon's sess-1 model, for picker assertions.
Future<String?> _fakeSessionModel(FakeDaemonClient fake) async =>
    (await fake.listSessions())
        .firstWhere((Session s) => s.id == 'sess-1')
        .model;

/// A fake whose sends always fail like a turn conflict, driving the
/// composer/pane failure path (SnackBar + text restore).
class _FailingSendFake extends FakeDaemonClient {
  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) async {
    throw const DaemonError(kErrConflict, 'a turn is already running');
  }
}

/// A fake whose sends fail like a dropped socket (device sleep), driving
/// the pane's softened connection-lost notice.
class _DroppedConnectionFake extends FakeDaemonClient {
  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment>? attachments,
  }) async {
    throw const DaemonConnectionError('peer closed');
  }
}
