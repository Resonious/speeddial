import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/share_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  Future<(AppData, FakeDaemonClient)> setup() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final FakeDaemonClient fake = FakeDaemonClient(
      eventDelay: const Duration(milliseconds: 1),
    );
    final AppData data = AppData()..registerClient('fake', fake);
    addTearDown(data.dispose);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Phone daemon',
      url: 'fake://local',
      token: '',
    );
    await data.shares.init();
    await data.projects.refresh('fake');
    await data.sessions.refresh('fake');
    return (data, fake);
  }

  testWidgets('generic share floats, can be dismissed or staged in a session', (
    WidgetTester tester,
  ) async {
    final (AppData data, FakeDaemonClient fake) = await setup();
    final Session session = (await fake.listSessions()).first;
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = session.projectId
      ..selectedSessionId = session.id;
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pump();

    final Map<String, Object?> payload = <String, Object?>{
      'name': 'bug.txt',
      'mimeType': 'text/plain',
      'data': base64Encode(utf8.encode('bug details')),
    };
    await data.shares.receive(payload);
    await tester.pump();
    expect(find.byKey(const Key('attach-shared-file')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-shared-file')));
    await tester.pump();
    expect(data.shares.pending, isNull);

    await data.shares.receive(payload);
    await tester.pump();
    await tester.tap(find.byKey(const Key('attach-shared-file')));
    await tester.pump();
    expect(data.shares.pending, isNull);
    expect(data.shares.stagedFor('fake', session.id).single.name, 'bug.txt');
    expect(find.text('bug.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove').last);
    await tester.pump();
    expect(data.shares.stagedFor('fake', session.id), isEmpty);

    await data.shares.receive(payload);
    await tester.pump();
    await tester.tap(find.byKey(const Key('attach-shared-file')));
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send));
    await tester.pumpAndSettle(const Duration(milliseconds: 20));
    expect(data.shares.stagedFor('fake', session.id), isEmpty);
    final List<SessionEvent> events = (await fake.history(session.id)).events;
    expect(
      events.whereType<UserMessageEvent>().last.attachments.single.name,
      'bug.txt',
    );
  });

  test(
    'project target creates session with cached settings and stages file',
    () async {
      final (AppData data, FakeDaemonClient fake) = await setup();
      final Project project = (await fake.listProjects()).first;
      final Session previous = await data.sessions.create(
        'fake',
        projectId: project.id,
        providerId: 'codex',
        baseBranch: 'main',
        sandboxMode: SessionSandboxMode.unrestricted,
        yolo: true,
        mode: SessionMode.plan,
      );
      data.shares.rememberSession('fake', previous);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final ShareTarget target = data.shares.targets.singleWhere(
        (ShareTarget item) => item.projectId == project.id,
      );
      data.dispose();
      final AppData reopened = AppData()..registerClient('fake', fake);
      addTearDown(reopened.dispose);
      await reopened.connections.addEndpoint(
        id: 'fake',
        name: 'Phone daemon',
        url: 'fake://local',
        token: '',
      );
      await reopened.shares.init();
      expect(
        reopened.shares.targets.any((ShareTarget item) => item.id == target.id),
        isTrue,
      );
      await reopened.shares.receive(<String, Object?>{
        'name': 'screenshot.png',
        'mimeType': 'image/png',
        'data': base64Encode(<int>[137, 80, 78, 71]),
        'shortcutId': target.id,
      });

      final String? sessionId = reopened.selection.selectedSessionId;
      expect(sessionId, isNotNull);
      final Session created = reopened.sessions.byId(sessionId!)!;
      expect(created.id, isNot(previous.id));
      expect(created.providerId, 'codex');
      expect(created.baseBranch, 'main');
      expect(created.sandboxMode, SessionSandboxMode.unrestricted);
      expect(created.yolo, isTrue);
      expect(created.mode, SessionMode.plan);
      expect(reopened.shares.pending, isNull);
      expect(
        reopened.shares.stagedFor('fake', created.id).single.name,
        'screenshot.png',
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String cache = prefs.getString(ShareStore.storageKey)!;
      expect(cache, contains(target.id));
      expect(cache, contains('"yolo":true'));
    },
  );

  test(
    'stale project shortcut leaves the file available for manual attach',
    () async {
      final (AppData data, _) = await setup();
      await data.shares.receive(<String, Object?>{
        'name': 'bug.txt',
        'data': base64Encode(<int>[1]),
        'shortcutId': 'project:removed:missing',
      });
      expect(data.shares.pending?.name, 'bug.txt');
      expect(data.shares.error, contains('no longer available'));
    },
  );

  test('cached project targets are ready before daemon refresh', () async {
    final String id = ShareStore.targetId('fake', 'project-1');
    SharedPreferences.setMockInitialValues(<String, Object>{
      ShareStore.storageKey: jsonEncode(<String, Object?>{
        'targets': <Object?>[
          <String, Object?>{
            'id': id,
            'daemonId': 'fake',
            'projectId': 'project-1',
            'label': 'App · Phone daemon',
          },
        ],
        'settings': const <Object?>[],
      }),
    });
    final AppData data = AppData()..registerClient('fake', FakeDaemonClient());
    addTearDown(data.dispose);
    await data.connections.addEndpoint(
      id: 'fake',
      name: 'Phone daemon',
      url: 'fake://local',
      token: '',
    );
    await data.shares.init();
    expect(data.projects.hasLoaded('fake'), isFalse);
    expect(data.shares.targets.single.id, id);
  });

  test(
    'a second share stays floating while a project session is created',
    () async {
      final (AppData data, FakeDaemonClient fake) = await setup();
      final Project project = (await fake.listProjects()).first;
      final Session previous = await data.sessions.create(
        'fake',
        projectId: project.id,
        providerId: 'omp',
      );
      data.shares.rememberSession('fake', previous);
      final String targetId = ShareStore.targetId('fake', project.id);

      final Future<void> first = data.shares.receive(<String, Object?>{
        'name': 'first.txt',
        'data': base64Encode(<int>[1]),
        'shortcutId': targetId,
      });
      await data.shares.receive(<String, Object?>{
        'name': 'second.txt',
        'data': base64Encode(<int>[2]),
      });
      await first;

      expect(data.shares.pending?.name, 'second.txt');
      expect(
        data.shares
            .stagedFor('fake', data.selection.selectedSessionId!)
            .single
            .name,
        'first.txt',
      );
    },
  );
}
