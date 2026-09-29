import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/files/downloaded_file_saver.dart';
import 'package:speeddial_app/src/files/file_download_transfer.dart';

class _SavePicker extends FilePicker {
  String? destination;
  String? suggestedName;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    expect(bytes, isNull);
    suggestedName = fileName;
    return destination;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _SavePicker picker;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    directory = await Directory.systemTemp.createTemp('download-save-test-');
    picker = _SavePicker();
    FilePicker.platform = picker;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test('desktop saves bytes only to the user-selected path', () async {
    final File destination = File('${directory.path}/chosen-name.zip');
    picker.destination = destination.path;
    final DownloadedFileResult result = await saveDownloadedStream(
      '../archive.zip',
      Stream<Uint8List>.fromIterable(<Uint8List>[
        Uint8List.fromList(<int>[0, 7]),
        Uint8List.fromList(<int>[255]),
      ]),
    );
    expect(result.status, DownloadedFileStatus.saved);
    expect(result.path, destination.path);
    expect(picker.suggestedName, 'archive.zip');
    expect(await destination.readAsBytes(), <int>[0, 7, 255]);
    expect(await directory.list().length, 1);
  });

  test('picker cancellation does not consume the transfer stream', () async {
    bool consumed = false;
    Stream<Uint8List> bytes() async* {
      consumed = true;
      yield Uint8List(1);
    }

    final DownloadedFileResult result = await saveDownloadedStream(
      'file.bin',
      bytes(),
    );
    expect(result.status, DownloadedFileStatus.cancelled);
    expect(consumed, isFalse);
    expect(await directory.list().isEmpty, isTrue);
  });

  for (final Object error in <Object>[
    const DownloadCancelled(),
    const FormatException('bad chunk'),
  ]) {
    test(
      '$error leaves an existing destination intact and removes partial data',
      () async {
        final File destination = File('${directory.path}/existing.txt');
        await destination.writeAsString('keep me');
        picker.destination = destination.path;
        Stream<Uint8List> bytes() async* {
          yield Uint8List.fromList(<int>[1, 2, 3]);
          throw error;
        }

        await expectLater(
          saveDownloadedStream('file.bin', bytes()),
          throwsA(same(error)),
        );
        expect(await destination.readAsString(), 'keep me');
        expect(await directory.list().length, 1);
      },
    );
  }

  test(
    'successful save replaces an existing file after transfer completion',
    () async {
      final File destination = File('${directory.path}/existing.txt');
      await destination.writeAsString('old');
      picker.destination = destination.path;
      Stream<Uint8List> bytes() async* {
        yield Uint8List.fromList(<int>[1, 2, 3]);
        expect(await destination.readAsString(), 'old');
      }

      final DownloadedFileResult result = await saveDownloadedStream(
        'file.bin',
        bytes(),
      );
      expect(result.status, DownloadedFileStatus.saved);
      expect(await destination.readAsBytes(), <int>[1, 2, 3]);
      expect(await directory.list().length, 1);
    },
  );
}
