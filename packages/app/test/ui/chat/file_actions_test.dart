import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/file_transfer_store.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_app/src/ui/shell.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _DownloadFake extends FakeDaemonClient {
  final Completer<FileDownloadChunk> download = Completer<FileDownloadChunk>();
  int downloads = 0;

  @override
  Future<FileDownloadChunk> downloadFileChunk(
    String sessionId,
    String path, {
    required int offset,
    String? revision,
  }) {
    downloads++;
    return download.future;
  }

  void complete({int size = 3}) => download.complete(
    FileDownloadChunk(
      name: 'archive.zip',
      size: size,
      data: 'AAf/',
      offset: 0,
      revision: '1',
    ),
  );
}

void main() {
  Future<(AppData, _DownloadFake)> pumpApp(
    WidgetTester tester, {
    bool narrow = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _DownloadFake fake = _DownloadFake();
    final AppData data = AppData()..registerClient('fake', fake);
    addTearDown(data.dispose);
    await data.sessions.refresh('fake');
    final Session session = (await fake.listSessions()).first;
    data.selection
      ..selectedDaemonId = 'fake'
      ..selectedProjectId = session.projectId
      ..selectedSessionId = session.id;
    tester.view.physicalSize = narrow
        ? const Size(390, 844)
        : const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppScope(
        data: data,
        child: MaterialApp(
          theme: buildSpeedDialTheme(),
          home: const SpeedDialShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (data, fake);
  }

  Future<void> openFile(WidgetTester tester) => tester
      .widget<Timeline>(find.byType(Timeline))
      .openLocalFile!('archive.zip');

  for (final String outcome in <String>['saved', 'cancelled', 'failed']) {
    testWidgets(
      'download keeps a dismissible $outcome receipt across sessions',
      (tester) async {
        const MethodChannel channel = MethodChannel('sh.speeddial/downloads');
        int saves = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'getCacheDirectory') {
                return Directory.systemTemp.path;
              }
              saves++;
              expect(
                await File((call.arguments as Map)['path'] as String)
                    .readAsBytes(),
                <int>[0, 7, 255],
              );
              return outcome == 'saved';
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final (AppData data, _DownloadFake fake) = await pumpApp(tester);
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = openFile(tester);
        });
        await tester.pumpAndSettle();
        expect(find.text('Download'), findsOneWidget);
        expect(find.text('Float'), findsOneWidget);
        expect(fake.downloads, 0);
        await tester.runAsync(() => tester.tap(find.text('Download')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Preparing download…'), findsOneWidget);
        expect(fake.downloads, 1);
        await openFile(tester);
        expect(fake.downloads, 1);
        await tester.runAsync(() async {
          if (outcome == 'failed') {
            fake.download.completeError(
              const DaemonError(-32602, 'File missing'),
            );
          } else {
            fake.complete();
          }
          await pending;
        });
        await tester.pumpAndSettle();
        final String title = switch (outcome) {
          'saved' => 'Download complete',
          'cancelled' => 'Download cancelled',
          _ => 'Download failed',
        };
        expect(saves, outcome == 'failed' ? 0 : 1);
        expect(find.text(title), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        if (outcome == 'saved') {
          expect(
            find.textContaining('Saved to your chosen location'),
            findsOneWidget,
          );
        }
        if (outcome == 'failed') {
          expect(find.text('File missing'), findsOneWidget);
        }
        data.selection.selectedSessionId = null;
        await tester.pump(const Duration(minutes: 2));
        expect(find.text(title), findsOneWidget);
        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();
        expect(find.text(title), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('closing the action dialog does not transfer a file', (
    tester,
  ) async {
    final (_, _DownloadFake fake) = await pumpApp(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = openFile(tester);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.runAsync(() => pending);
    await tester.pumpAndSettle();
    expect(fake.downloads, 0);
  });

  testWidgets('cancel during transfer leaves no floating file', (tester) async {
    final (AppData data, _DownloadFake fake) = await pumpApp(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = openFile(tester);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Float')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    fake.complete();
    await tester.runAsync(() => pending);
    await tester.pumpAndSettle();
    expect(data.shares.pending, isNull);
    expect(find.text('Float cancelled'), findsOneWidget);
  });

  for (final bool narrow in <bool>[false, true]) {
    testWidgets(
      'float attaches to another session (${narrow ? 'mobile' : 'desktop'})',
      (tester) async {
        final (AppData data, _DownloadFake fake) = await pumpApp(
          tester,
          narrow: narrow,
        );
        final String source = data.selection.selectedSessionId!;
        final Session target = await data.sessions.create(
          'fake',
          projectId: data.selection.selectedProjectId!,
          providerId: 'codex',
        );
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = openFile(tester);
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Float')));
        await tester.pump(const Duration(milliseconds: 300));
        // Switching sessions while downloading must not cancel the float.
        data.selection.selectedSessionId = target.id;
        await tester.pump(const Duration(milliseconds: 300));
        fake.complete();
        await tester.runAsync(() => pending);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('attach-shared-file')), findsOneWidget);
        expect(base64Decode(data.shares.pending!.data), <int>[0, 7, 255]);
        expect(
          data.shares.pending!.mimeType,
          mimeTypeForFileName('archive.zip'),
        );
        expect(data.shares.stagedFor('fake', source), isEmpty);
        await tester.tap(find.byKey(const Key('attach-shared-file')));
        await tester.pumpAndSettle();
        expect(data.shares.pending, isNull);
        expect(
          data.shares.stagedFor('fake', target.id).single.name,
          'archive.zip',
        );
        expect(find.text('archive.zip'), findsOneWidget);
      },
    );
  }

  testWidgets('oversize floats fail with an actionable explanation', (
    tester,
  ) async {
    final (AppData data, _DownloadFake fake) = await pumpApp(
      tester,
      narrow: true,
    );
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = openFile(tester);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Float')));
    await tester.pump(const Duration(milliseconds: 300));
    fake.complete(size: kMaxAttachmentBytes + 1);
    await tester.runAsync(() => pending);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Choose Download to save this file.'),
      findsOneWidget,
    );
    expect(data.shares.pending, isNull);
    expect(fake.downloads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('float cannot replace an existing shared file', (tester) async {
    final (AppData data, _) = await pumpApp(tester);
    await data.shares.receive(<String, Object?>{
      'name': 'existing.txt',
      'data': 'AA==',
    });
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = openFile(tester);
    });
    await tester.pumpAndSettle();
    final ListTile float = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Float'),
    );
    expect(float.enabled, isFalse);
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.runAsync(() => pending);
    expect(data.shares.pending!.name, 'existing.txt');
  });

  test(
    'a new transfer does not erase an undismissed download receipt',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const MethodChannel channel = MethodChannel('sh.speeddial/downloads');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCacheDirectory') {
              return Directory.systemTemp.path;
            }
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final AppData data = AppData();
      addTearDown(data.dispose);
      final _DownloadFake fake = _DownloadFake()..complete();
      await data.fileTransfers.start(
        fake,
        'session',
        'archive.zip',
        FileAction.download,
      );
      final FileTransferNotice first = data.fileTransfers.finished.single;
      await data.fileTransfers.start(
        fake,
        'session',
        'archive.zip',
        FileAction.download,
      );
      expect(data.fileTransfers.finished.length, 2);
      data.fileTransfers.dismiss(first);
      expect(data.fileTransfers.finished.length, 1);
      expect(data.fileTransfers.finished.single.title, 'Download complete');
    },
  );

  test('an incoming share during a float keeps its payload', () async {
    final AppData data = AppData();
    addTearDown(data.dispose);
    final _DownloadFake fake = _DownloadFake();
    final Future<void> pending = data.fileTransfers.start(
      fake,
      'session',
      'archive.zip',
      FileAction.float,
    );
    await data.shares.receive(<String, Object?>{
      'name': 'incoming.txt',
      'data': 'AA==',
    });
    final Future<void> failure = expectLater(pending, throwsStateError);
    fake.complete();
    await failure;
    expect(data.shares.pending!.name, 'incoming.txt');
    expect(data.fileTransfers.lastError, contains('Attach or dismiss'));
    expect(data.fileTransfers.finished.single.error, isTrue);
  });
}
