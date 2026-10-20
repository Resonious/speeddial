import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/timeline.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _ImageSavePicker extends FilePicker {
  final Completer<String?> result = Completer<String?>();
  int calls = 0;
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
  }) {
    calls++;
    suggestedName = fileName;
    return result.future;
  }
}

const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
    'DwAChwGA60e6kgAAAABJRU5ErkJggg==';
const Attachment _attachment = Attachment(
  id: 'image',
  name: 'original.png',
  mimeType: 'image/png',
  size: 70,
);

void main() {
  late _ImageSavePicker picker;

  Future<void> open(
    WidgetTester tester, {
    String source = 'agent',
    bool dark = true,
    bool reducedMotion = false,
    double width = 390,
  }) async {
    picker = _ImageSavePicker();
    FilePicker.platform = picker;
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SessionEvent event = switch (source) {
      'user' => const UserMessageEvent(
        text: 'Attached image',
        attachments: <Attachment>[_attachment],
        seq: 1,
      ),
      'tool' => const ToolCallEvent(
        toolCall: ToolCall(
          id: 'view',
          title: 'View image',
          kind: 'read',
          status: ToolCallStatus.completed,
          content: <ToolCallContent>[ToolCallImage(attachment: _attachment)],
          locations: <String>[],
        ),
        seq: 1,
      ),
      _ => const ImageEvent(attachment: _attachment, seq: 1),
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? buildSpeedDialTheme() : buildSpeedDialLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            padding: const EdgeInsets.only(top: 24, bottom: 34),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Timeline(
            items: deriveTimelineItems(<SessionEvent>[event]),
            attachmentLoader: (String id) async => AttachmentData(
              id: id,
              name: _attachment.name,
              mimeType: _attachment.mimeType,
              size: base64Decode(_png).length,
              data: _png,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (source == 'tool') {
      await tester.tap(find.text('View image'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Download image'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  for (final String source in <String>['user', 'agent', 'tool']) {
    testWidgets('$source image downloads its original bytes and filename', (
      WidgetTester tester,
    ) async {
      await open(tester, source: source);
      await tester.runAsync(() async {
        picker = _ImageSavePicker();
        FilePicker.platform = picker;
        final Directory directory = await Directory.systemTemp.createTemp(
          'image-download-',
        );
        try {
          final File file = File('${directory.path}/chosen.png');
          picker.result.complete(file.path);
          final IconButton button = tester.widget<IconButton>(
            find.byWidgetPredicate(
              (Widget widget) =>
                  widget is IconButton && widget.tooltip == 'Download image',
            ),
          );
          await (button.onPressed! as Future<void> Function())();
          expect(picker.suggestedName, _attachment.name);
          expect(picker.calls, 1);
          expect(await file.readAsBytes(), base64Decode(_png));
        } finally {
          await directory.delete(recursive: true);
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Image saved'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }

  for (final bool dark in <bool>[true, false]) {
    for (final double width in <double>[390, 1440]) {
      testWidgets(
        'cancel and retry ($dark, $width) holds still in reduced motion',
        (WidgetTester tester) async {
          await open(tester, dark: dark, width: width, reducedMotion: true);
          await tester.tap(find.byTooltip('Download image'));
          await tester.pump();
          expect(
            tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (Widget widget) =>
                        widget is IconButton &&
                        widget.tooltip == 'Saving image…',
                  ),
                )
                .onPressed,
            isNull,
          );
          expect(picker.calls, 1);
          picker.result.complete(null);
          await tester.pump();
          await tester.pump();
          expect(find.text('Download cancelled'), findsOneWidget);
          expect(find.byTooltip('Download image'), findsOneWidget);
          expect(
            tester
                .widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher).last)
                .duration,
            Duration.zero,
          );
          await tester.pumpAndSettle();
          expect(tester.hasRunningAnimations, isFalse);
          await tester.tap(find.byTooltip('Download image'));
          await tester.pump();
          expect(picker.calls, 2);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.linux),
      );
    }
  }

  testWidgets('save failure is visible and allows another attempt', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Download image'));
    await tester.pump();
    picker.result.completeError(StateError('Disk full'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Download failed:'), findsOneWidget);
    expect(find.textContaining('Disk full'), findsOneWidget);
    expect(find.byTooltip('Download image'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('closing during a save safely allows it to finish', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Download image'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    picker.result.complete(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
