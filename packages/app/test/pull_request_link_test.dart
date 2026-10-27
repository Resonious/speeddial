import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/main.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/ui/pull_request_drop_region.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _PrDaemon extends FakeDaemonClient {
  List<Session> matches = <Session>[];
  Object? error;
  final List<String> urls = <String>[];
  Completer<List<Session>>? gate;
  @override
  Future<List<Session>> findSessionsByPullRequest(String url) async {
    urls.add(url);
    if (error != null) throw error!;
    return gate == null ? matches : gate!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppData data;
  late _PrDaemon first;
  late _PrDaemon second;
  late Session target;
  const String url = 'https://github.com/org/repo/pull/42';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    first = _PrDaemon();
    second = _PrDaemon();
    data = AppData()
      ..registerClient('first', first)
      ..registerClient('second', second);
    for (final String id in ['first', 'second']) {
      await data.connections.addEndpoint(
        id: id,
        name: id,
        url: 'fake://$id',
        token: '',
      );
    }
    target = (await second.listSessions()).first;
    second.matches = [target];
  });
  tearDown(() => data.dispose());

  test('Android shared text selects and caches the matching session', () async {
    first.error = StateError('offline');
    await data.shares.receive({'text': '$url/files#diff'});
    expect(second.urls, [url]);
    expect(data.selection.selectedDaemonId, 'second');
    expect(data.selection.selectedSessionId, target.id);
    expect(data.sessions.byId(target.id), isNotNull);
    expect(data.shares.pending, isNull);
    expect(data.shares.error, isNull);
  });

  test('iOS queued link opens without becoming an attachment', () async {
    await data.shares.receive({
      'mimeType': 'application/x-speeddial-link',
      'data': base64Encode(utf8.encode(url)),
    });
    expect(data.selection.selectedSessionId, target.id);
    expect(data.shares.pending, isNull);
  });

  test('invalid text and unmatched PR leave selection unchanged', () async {
    await data.shares.pullRequests.open('https://example.com');
    expect(second.urls, isEmpty);
    second.matches = [];
    await data.shares.pullRequests.open(url);
    expect(data.selection.selectedSessionId, isNull);
    expect(data.shares.error, isNull);
  });

  test('newer lookup supersedes late results', () async {
    final Completer<List<Session>> gate = Completer<List<Session>>();
    second.gate = gate;
    final Future<void> old = data.shares.pullRequests.open(url);
    second.gate = null;
    second.matches = [];
    await data.shares.pullRequests.open('$url/files');
    gate.complete([target]);
    await old;
    expect(data.selection.selectedSessionId, isNull);
  });

  testWidgets('multiple daemon matches offer explicit selection', (
    tester,
  ) async {
    first.matches = [target];
    await data.shares.pullRequests.open(url);
    expect(data.selection.selectedSessionId, isNull);
    await tester.pumpWidget(
      AppScope(
        data: data,
        child: const MaterialApp(
          home: Scaffold(body: Stack(children: [PullRequestMatches()])),
        ),
      ),
    );
    expect(find.text('Sessions for this pull request'), findsOneWidget);
    await tester.tap(find.text('second'));
    await tester.pump();
    expect(data.selection.selectedDaemonId, 'second');
    expect(find.text('Sessions for this pull request'), findsNothing);
  });

  testWidgets('a shared PR reveals the conversation above settings', (
    tester,
  ) async {
    await tester.pumpWidget(SpeedDialApp(data: data));
    await tester.pumpAndSettle();
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings route'), findsOneWidget);
    await data.shares.receive({'text': url});
    await tester.pumpAndSettle();
    expect(find.text('Settings route'), findsNothing);
    expect(data.selection.selectedSessionId, target.id);
  });

  testWidgets('Linux text drop channel shows hover and resolves the URL', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppScope(
        data: data,
        child: const MaterialApp(
          home: Scaffold(body: PullRequestDropRegion(child: SizedBox.expand())),
        ),
      ),
    );
    Future<void> send(String method, Object value) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'sh.speeddial/text-drop',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
        (_) {},
      );
      await tester.pump();
    }

    await send('hover', true);
    expect(find.byType(PullRequestDropHint), findsOneWidget);
    await send('hover', false);
    expect(find.byType(PullRequestDropHint), findsNothing);
    await send('hover', true);
    await send('text', url);
    expect(find.byType(PullRequestDropHint), findsNothing);
    expect(data.selection.selectedSessionId, target.id);
    expect(data.selection.selectedDaemonId, 'second');
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('drop hint stays still in both themes with reduced motion', (
    tester,
  ) async {
    for (final Brightness brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: PullRequestDropHint()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Drop a GitHub PR link to find its session'),
        findsOneWidget,
      );
      expect(tester.hasRunningAnimations, isFalse);
    }
  });
}
