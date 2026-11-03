import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/api/saved_history_client.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/catching_up.dart';
import 'package:speeddial_app/src/ui/chat/chat_pane.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'api/local_history_test.dart' as fixture;

class _SavedClient extends FakeDaemonClient implements SavedHistoryClient {
  bool connected = true;
  Completer<({List<SessionEvent> events, bool hasMore})> response = Completer();
  final saved = <SessionEvent>[
    const UserMessageEvent(text: 'Can I read this while offline?', seq: 1),
    const AgentMessageChunkEvent(
      text: 'Your saved messages remain readable while the rest of the conversation loads.',
      seq: 4,
    ),
    const TurnCompleteEvent(stopReason: 'end_turn', seq: 5),
  ];
  @override
  bool get isConnected => connected;
  @override
  Stream<SessionEvent> sessionEvents(String sessionId) => const Stream.empty();
  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async => [fixture.session];
  @override
  Future<({List<SessionEvent> events, bool hasMore, bool complete})?>
  savedHistory(String sessionId, {required int limit, int? beforeSeq}) async =>
      (events: saved, hasMore: false, complete: false);
  @override
  Future<({List<SessionEvent> events, bool hasMore})> history(
    String sessionId, {
    int limit = 200,
    int? beforeSeq,
  }) => response.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final dark in [false, true]) {
    testWidgets(
      'saved conversation survives updating, failure, retry and offline ($dark)',
      (tester) async {
        final client = _SavedClient();
        final data = AppData(clientFor: (_) => client);
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
          sessionId: 's',
        );
        await tester.pumpWidget(
          AppScope(
            data: data,
            child: MaterialApp(
              theme: dark ? buildSpeedDialTheme() : buildSpeedDialLightTheme(),
              home: const Scaffold(body: ChatPane()),
            ),
          ),
        );
        await tester.pump();
        // Opening the session refreshes it; the strip shows only once that
        // outlasts the opening patience.
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('Can I read this while offline?'), findsOneWidget);
        expect(find.text('Updating conversation…'), findsNothing);
        await tester.pump(CatchingUpStrip.openingPatience);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Updating conversation…'), findsOneWidget);
        expect(find.text('Loading history…'), findsNothing);
        client.response.completeError(StateError('History unavailable'));
        await tester.pumpAndSettle();
        expect(find.text('Could not update conversation'), findsOneWidget);
        expect(find.text('Can I read this while offline?'), findsOneWidget);
        client.response = Completer();
        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Updating conversation…'), findsOneWidget);
        client.response.complete((
          events: [
            client.saved.first,
            const AgentMessageChunkEvent(
              text: 'A previously missing reply.',
              seq: 2,
              messageId: 'missing',
            ),
            const TurnCompleteEvent(stopReason: 'end_turn', seq: 3),
            ...client.saved.skip(1),
          ],
          hasMore: false,
        ));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('A previously missing reply.'),
          findsOneWidget,
        );
        expect(find.text('Updating conversation…'), findsNothing);
        client.connected = false;
        data.connections.setStatus('ep', ConnectionStatus.failed);
        await tester.pumpAndSettle();
        expect(find.text('Offline · Viewing saved messages'), findsOneWidget);
        expect(find.text('Can I read this while offline?'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
        await tester.pumpWidget(const SizedBox());
        data.dispose();
        await client.dispose();
      },
    );
  }
}
