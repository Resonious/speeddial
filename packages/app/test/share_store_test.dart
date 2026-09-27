import 'dart:convert';

import 'package:flutter/services.dart';

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

  testWidgets(
    'iOS imports one share at launch and advances after dismiss or attach',
    (tester) async {
      final (data, fake) = await setup();
      final session = (await fake.listSessions()).first;
      final queue = <Map<String, Object?>>[
        {
          'name': 'first.txt',
          'data': base64Encode([1]),
        },
        {
          'name': 'second.txt',
          'data': base64Encode([2]),
        },
        {
          'name': 'third.txt',
          'data': base64Encode([3]),
        },
      ];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel(ShareStore.channelName);
      int reads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takeInitial') {
          reads++;
          return queue.isEmpty ? null : queue.removeAt(0);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await data.shares.startMobile(ios: true);
      expect(data.shares.pending?.name, 'first.txt');
      await data.shares.resumeIOS();
      expect(reads, 1);
      data.shares.cancel();
      await tester.pump();
      expect(data.shares.pending?.name, 'second.txt');
      data.shares.attachTo('fake', session.id);
      await tester.pump();
      expect(
        data.shares.stagedFor('fake', session.id).single.name,
        'second.txt',
      );
      expect(data.shares.pending?.name, 'third.txt');
      data.shares.cancel();
      await tester.pump();
      queue.add({
        'name': 'resumed.txt',
        'data': base64Encode([4]),
      });
      await data.shares.resumeIOS();
      expect(data.shares.pending?.name, 'resumed.txt');
    },
  );

  testWidgets('iOS native failure is visible and can be dismissed to retry', (
    tester,
  ) async {
    final (data, _) = await setup();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(ShareStore.channelName);
    bool fail = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'takeInitial') return null;
      if (fail) {
        throw PlatformException(
          code: 'share_read',
          message: 'File unavailable',
        );
      }
      return {
        'name': 'recovered.txt',
        'data': base64Encode([1]),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await data.shares.startMobile(ios: true);
    expect(data.shares.error, contains('File unavailable'));
    fail = false;
    data.shares.cancel();
    await tester.pump();
    expect(data.shares.pending?.name, 'recovered.txt');
    expect(data.shares.error, isNull);
  });

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
