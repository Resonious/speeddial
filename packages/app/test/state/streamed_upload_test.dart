import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/fake_daemon.dart';
import 'package:speeddial_app/src/scope.dart';
import 'package:speeddial_app/src/state/chat_store.dart';
import 'package:speeddial_app/src/state/streamed_attachment.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Records the upload calls a send makes.
class _RecordingFake extends FakeDaemonClient {
  _RecordingFake() : super(eventDelay: const Duration(milliseconds: 1));

  final List<int> appendSizes = <int>[];
  final List<String> cancelled = <String>[];
  List<OutgoingAttachment> sent = const <OutgoingAttachment>[];

  @override
  Future<int> appendUpload(String uploadId, int offset, Uint8List bytes) {
    appendSizes.add(bytes.length);
    return super.appendUpload(uploadId, offset, bytes);
  }

  @override
  Future<void> cancelUpload(String uploadId) {
    cancelled.add(uploadId);
    return super.cancelUpload(uploadId);
  }

  @override
  Future<void> sendMessage(
    String sessionId,
    String text, {
    List<OutgoingAttachment> attachments = const [],
  }) {
    sent = attachments;
    return super.sendMessage(sessionId, text, attachments: attachments);
  }
}

void main() {
  late AppData app;
  late _RecordingFake fake;
  late String sessionId;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fake = _RecordingFake();
    app = AppData()..registerClient('fake', fake);
    sessionId = (await fake.listSessions()).first.id;
  });

  tearDown(() => app.dispose());

  StreamedAttachment streamed(
    Uint8List bytes, {
    Object? failAt,
    List<int>? reads,
  }) => StreamedAttachment(
    name: 'clip.mp4',
    mimeType: 'video/mp4',
    size: bytes.length,
    read: (int offset, int length) async {
      reads?.add(offset);
      if (failAt != null && offset >= (failAt as int)) {
        throw StateError('read failed');
      }
      return Uint8List.sublistView(bytes, offset, offset + length);
    },
  );

  test('send uploads streamed files in chunks and sends upload ids', () async {
    final Uint8List bytes = Uint8List.fromList(
      List<int>.generate(kMaxUploadChunkBytes * 2 + 17, (int i) => i % 253),
    );
    app.chat.watchSession('fake', sessionId);
    final List<double> progress = <double>[];
    final Future<void> sending = app.chat.send(
      'fake',
      sessionId,
      'look',
      attachments: <OutgoingAttachment>[
        const OutgoingAttachment(
          name: 'note.txt',
          mimeType: 'text/plain',
          data: 'aGk=',
        ),
        streamed(bytes),
      ],
    );
    final OutgoingMessage message = app.chat.outgoingFor(sessionId).single;
    message.upload!.addListener(() => progress.add(message.upload!.value));
    await sending;

    expect(fake.appendSizes, <int>[
      kMaxUploadChunkBytes,
      kMaxUploadChunkBytes,
      17,
    ]);
    expect(progress.last, 1);
    expect(progress, orderedEquals(List<double>.of(progress)..sort()));
    expect(fake.sent.first.data, 'aGk=');
    expect(fake.sent.last.data, isNull);
    expect(fake.sent.last.uploadId, isNotNull);
    expect(fake.sent.last.name, 'clip.mp4');

    final UserMessageEvent echo = (await fake.history(sessionId)).events
        .whereType<UserMessageEvent>()
        .last;
    expect(echo.attachments.last.size, bytes.length);
  });

  test('a failed upload cancels it, records the error and rethrows', () async {
    final Uint8List bytes = Uint8List(kMaxUploadChunkBytes + 1);
    final List<int> reads = <int>[];
    await expectLater(
      app.chat.send(
        'fake',
        sessionId,
        'look',
        attachments: <OutgoingAttachment>[
          streamed(bytes, failAt: kMaxUploadChunkBytes, reads: reads),
        ],
      ),
      throwsStateError,
    );
    expect(reads, <int>[0, kMaxUploadChunkBytes]);
    expect(fake.cancelled, hasLength(1));
    expect(app.chat.lastError, isA<StateError>());
    expect(fake.sent, isEmpty);
  });
}
