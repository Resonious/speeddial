import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/files/file_download_transfer.dart';
import 'package:speeddial_app/src/files/downloaded_file_saver.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class ChunkClient extends FakeDaemonClient {
  final List<int> offsets = <int>[];
  final List<int> content = List<int>.generate(256 * 1024 + 3, (i) => i % 256);
  int? failure;
  bool malformed = false;

  @override
  Future<FileDownloadChunk> downloadFileChunk(
    String sessionId,
    String path, {
    required int offset,
    String? revision,
  }) async {
    offsets.add(offset);
    if (failure != null) throw DaemonError(failure!, 'failure');
    if (offset > 0) expect(revision, 'version');
    return FileDownloadChunk(
      name: 'file.bin',
      size: content.length,
      offset: malformed ? offset + 1 : offset,
      revision: 'version',
      data: base64Encode(
        content.sublist(offset, (offset + 256 * 1024).clamp(0, content.length)),
      ),
    );
  }

  @override
  Future<FileDownload> downloadFile(String sessionId, String path) async =>
      FileDownload(
        name: 'file.bin',
        size: content.length,
        data: base64Encode(content),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pulls ordered chunks and reports progress through completion',
    () async {
      final ChunkClient client = ChunkClient();
      final FileDownloadTransfer transfer = FileDownloadTransfer(
        client,
        'session',
        'path',
      );
      await transfer.prepare();
      final List<int> received = <int>[];
      final List<int> progress = <int>[];
      await for (final bytes in transfer.bytes((value, total) {
        expect(total, client.content.length);
        progress.add(value);
      })) {
        received.addAll(bytes);
      }
      expect(received, client.content);
      expect(client.offsets, <int>[0, 256 * 1024]);
      expect(progress, <int>[256 * 1024, client.content.length]);
    },
  );

  test('cancellation stops before requesting another chunk', () async {
    final ChunkClient client = ChunkClient();
    final FileDownloadTransfer transfer = FileDownloadTransfer(
      client,
      'session',
      'path',
    );
    await transfer.prepare();
    final Future<void> read = () async {
      await for (final _ in transfer.bytes((_, _) {})) {
        transfer.cancelled = true;
      }
    }();
    await expectLater(read, throwsA(isA<DownloadCancelled>()));
    expect(client.offsets, <int>[0]);
  });

  test('rejects malformed chunks', () async {
    final ChunkClient client = ChunkClient()..malformed = true;
    final FileDownloadTransfer transfer = FileDownloadTransfer(
      client,
      'session',
      'path',
    );
    await transfer.prepare();
    await expectLater(
      transfer.bytes((_, _) {}).drain<void>(),
      throwsFormatException,
    );
  });

  test('falls back only for an unknown method', () async {
    final ChunkClient client = ChunkClient()..failure = -32601;
    final FileDownloadTransfer transfer = FileDownloadTransfer(
      client,
      'session',
      'path',
    );
    await transfer.prepare();
    final chunks = await transfer.bytes((_, _) {}).toList();
    expect(chunks.single, client.content);
    client.failure = -32003;
    await expectLater(
      FileDownloadTransfer(client, 'session', 'path').prepare(),
      throwsA(isA<DaemonError>()),
    );
  });

  test('Android saves more than 64 MiB using a bounded stream', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const MethodChannel channel = MethodChannel('sh.speeddial/downloads');
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    late String stagedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          stagedPath = (call.arguments as Map)['path'] as String;
          expect(await File(stagedPath).length(), 65 * 1024 * 1024);
          return true;
        });
    Stream<Uint8List> content() async* {
      final Uint8List chunk = Uint8List(256 * 1024);
      for (int i = 0; i < 260; i++) {
        yield chunk;
      }
    }

    expect(
      (await saveDownloadedStream('large.apk', content())).status,
      DownloadedFileStatus.saved,
    );
    expect(await File(stagedPath).parent.exists(), false);
  });

  test(
    'Android exports a staged file and cleans it up for save and cancel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const MethodChannel channel = MethodChannel('sh.speeddial/downloads');
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      for (final bool saved in <bool>[true, false]) {
        late String stagedPath;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'save');
              final args = call.arguments as Map;
              stagedPath = args['path'] as String;
              expect(args['name'], 'file.bin');
              expect(await File(stagedPath).readAsBytes(), <int>[0, 1, 255, 2]);
              return saved;
            });
        final result = await saveDownloadedStream(
          '../file.bin',
          Stream<Uint8List>.fromIterable(<Uint8List>[
            Uint8List.fromList(<int>[0, 1]),
            Uint8List.fromList(<int>[255, 2]),
          ]),
        );
        expect(
          result.status,
          saved ? DownloadedFileStatus.saved : DownloadedFileStatus.cancelled,
        );
        expect(await File(stagedPath).parent.exists(), false);
      }
    },
  );
}
