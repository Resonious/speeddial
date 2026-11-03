import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';
import 'package:speeddial_app/src/ui/chat/session_handoff.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

Session _session(String id) => Session(
  id: id,
  projectId: 'p',
  providerId: 'codex',
  title: id,
  status: SessionStatus.idle,
  model: null,
  cwd: '/',
  baseBranch: null,
  yolo: false,
  archived: false,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

class _Client extends FakeDaemonClient {
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  @override
  Stream<SessionEvent> sessionEvents(String sessionId) => const Stream.empty();

  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async => <Session>[_session('a'), _session('b')];

  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    await gates[sessionId]?.future;
    return (
      events: <SessionEvent>[UserMessageEvent(text: 'in $sessionId', seq: 1)],
      hasMore: false,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  final Finder handoff = find.byKey(const Key('session-handoff'));

  Future<(_Client, AppData)> open(WidgetTester tester) async {
    final _Client client = _Client();
    final AppData data = AppData(clientFor: (_) => client);
    await data.connections.addEndpoint(
      id: 'ep',
      name: 'Daemon',
      url: 'ws://daemon/ws',
      token: '',
      persist: false,
    );
    data.connections.setStatus('ep', ConnectionStatus.connected);
    await data.sessions.refresh('ep');
    data.selection.selectSession(
      daemonId: 'ep',
      projectId: 'p',
      sessionId: 'a',
    );
    await tester.pumpWidget(
      AppScope(
        data: data,
        child: MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const Scaffold(body: ChatPane()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (client, data);
  }

  void switchTo(AppData data, String id) => data.selection.selectSession(
    daemonId: 'ep',
    projectId: 'p',
    sessionId: id,
  );

  Future<void> close(WidgetTester tester, _Client client, AppData data) async {
    await tester.pumpWidget(const SizedBox());
    data.dispose();
    await client.dispose();
  }

  double held(WidgetTester tester) =>
      tester.widget<FadeTransition>(handoff).opacity.value;

  testWidgets('the old frame holds until the new session lands, then fades', (
    WidgetTester tester,
  ) async {
    final (_Client client, AppData data) = await open(tester);
    final Completer<void> gate = client.gates['b'] = Completer<void>();
    switchTo(data, 'b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(held(tester), 1);

    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('in b'), findsOneWidget);
    expect(held(tester), inExclusiveRange(0, 1));

    await tester.pumpAndSettle();
    expect(handoff, findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    await close(tester, client, data);
  });

  testWidgets('a load that outlasts the hold gives way to its loading state', (
    WidgetTester tester,
  ) async {
    final (_Client client, AppData data) = await open(tester);
    final Completer<void> gate = client.gates['b'] = Completer<void>();
    switchTo(data, 'b');
    await tester.pump();
    await tester.pump(SessionHandoff.maxHold);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(handoff, findsNothing);
    expect(find.text('Loading history…'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    await close(tester, client, data);
  });

  testWidgets('reduced motion swaps at once', (WidgetTester tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final (_Client client, AppData data) = await open(tester);
    switchTo(data, 'b');
    await tester.pump();
    expect(handoff, findsNothing);
    await tester.pumpAndSettle();
    await close(tester, client, data);
  });
}
