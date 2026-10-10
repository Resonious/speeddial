import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/session_link_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _GatedDaemon extends FakeDaemonClient {
  Completer<void>? gate;
  Object? listError;
  @override
  Future<List<Session>> listSessions({
    String? projectId,
    bool includeArchived = false,
  }) async {
    await gate?.future;
    if (listError != null) throw listError!;
    return super.listSessions(
      projectId: projectId,
      includeArchived: includeArchived,
    );
  }
}

void main() {
  late AppData data;
  late _GatedDaemon first;
  late FakeDaemonClient second;
  late Session target;
  late SessionLinkStore links;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    first = _GatedDaemon();
    second = FakeDaemonClient();
    data = AppData()
      ..registerClient('first', first)
      ..registerClient('second', second);
    await data.connections.addEndpoint(
      id: 'first',
      name: 'First',
      url: 'fake://first',
      token: 'saved-secret',
    );
    await data.connections.addEndpoint(
      id: 'second',
      name: 'Second',
      url: 'fake://second',
      token: '',
    );
    target = await second.createSession(
      projectId: 'proj-demo',
      providerId: 'omp',
      title: 'Notification target',
    );
    links = SessionLinkStore(data);
  });
  tearDown(() {
    links.dispose();
    data.dispose();
  });

  SessionLink linkFor(Session session) =>
      SessionLink(sessionId: session.id, projectId: session.projectId);

  test(
    'finds a session on the right saved daemon with an initially empty cache',
    () async {
      expect(data.sessions.byId(target.id), isNull);
      expect(await links.open(linkFor(target)), isTrue);
      expect(data.selection.selectedDaemonId, 'second');
      expect(data.selection.selectedProjectId, target.projectId);
      expect(data.selection.selectedSessionId, target.id);
      expect(data.connections.endpoints, hasLength(2));
      expect(data.connections.endpoints.first.token, 'saved-secret');
    },
  );

  test('an unrelated unreachable daemon does not prevent navigation', () async {
    first.listError = StateError('offline');
    expect(await links.open(linkFor(target)), isTrue);
    expect(data.selection.selectedDaemonId, 'second');
    expect(links.lastError, isNull);
  });

  test(
    'ambiguous daemon-scoped session IDs are reported without selecting one',
    () async {
      final Session duplicate = await first.createSession(
        projectId: target.projectId,
        providerId: 'omp',
        title: 'Duplicate',
      );
      expect(duplicate.id, target.id);
      await expectLater(
        links.open(linkFor(target)),
        throwsA(
          isA<SessionLinkException>().having(
            (e) => e.message,
            'message',
            contains('multiple daemons'),
          ),
        ),
      );
      expect(links.lastError, isA<SessionLinkException>());
      expect(data.selection.selectedSessionId, isNull);
    },
  );

  test(
    'missing sessions report and retain errors without changing selection',
    () async {
      data.selection.selectDaemon('first');
      await expectLater(
        links.open(
          const SessionLink(sessionId: 'missing', projectId: 'proj-demo'),
        ),
        throwsA(isA<SessionLinkException>()),
      );
      expect(links.lastError, isA<SessionLinkException>());
      expect(data.selection.selectedDaemonId, 'first');
      expect(data.selection.selectedSessionId, isNull);
    },
  );

  test('the latest link wins when an earlier lookup finishes late', () async {
    final Completer<void> gate = Completer<void>();
    first.gate = gate;
    final Future<bool> old = links.open(linkFor(target));
    first.gate = null;
    final Session newer = await second.createSession(
      projectId: 'proj-demo',
      providerId: 'omp',
      title: 'Newer target',
    );
    expect(await links.open(linkFor(newer)), isTrue);
    gate.complete();
    expect(await old, isFalse);
    expect(data.selection.selectedSessionId, newer.id);
  });

  testWidgets(
    'cold mobile launch opens the target chat in the existing shell',
    (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = linkFor(
        target,
      ).toUri().toString();
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );
      await tester.pumpWidget(SpeedDialApp(data: data));
      await tester.pumpAndSettle();
      expect(data.selection.selectedDaemonId, 'second');
      expect(data.selection.selectedSessionId, target.id);
      expect(find.text('Notification target'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a notification opens the session while the app is running', (
    tester,
  ) async {
    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pumpAndSettle();
    await tester.binding.handlePushRoute(linkFor(target).toUri().toString());
    await tester.pumpAndSettle();
    expect(data.selection.selectedDaemonId, 'second');
    expect(data.selection.selectedSessionId, target.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('web-style route information opens the target session', (
    tester,
  ) async {
    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pumpAndSettle();
    final Uri uri = linkFor(target)
        .toUri(appUrl: Uri.parse('https://app.example/'));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', {
          'location': uri.toString(),
          'state': null,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(data.selection.selectedSessionId, target.id);
    expect(tester.takeException(), isNull);
  });
}
