import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/theme.dart';
import 'package:speeddial_app/src/ui/chat/message_view.dart';
import 'package:speeddial_app/src/ui/chat/oven.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

void main() {
  Widget bubble(ValueNotifier<double> upload, {ThemeData? theme}) =>
      MaterialApp(
        theme: theme ?? buildSpeedDialTheme(),
        home: Scaffold(
          body: Center(
            child: BakingBubble(
              upload: upload,
              child: const UserMessageBubble(
                text: 'clip',
                attachments: <Attachment>[
                  Attachment(
                    id: 'outgoing-0',
                    name: 'clip.mp4',
                    mimeType: 'video/mp4',
                    size: 40 * 1024 * 1024,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('dark', buildSpeedDialTheme()),
    ('light', buildSpeedDialLightTheme()),
  ]) {
    testWidgets('upload progress browns the crust and counts up ($name)', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<double> upload = ValueNotifier<double>(0);
      addTearDown(upload.dispose);
      await tester.pumpWidget(bubble(upload, theme: theme));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Uploading… 0%'), findsOneWidget);
      expect(find.text('40 MiB'), findsOneWidget);

      upload.value = 0.5;
      await tester.pump();
      expect(find.text('Uploading… 50%'), findsOneWidget);
      final RenderBox box = tester.renderObject(
        find.byKey(const Key('baking-bubble')),
      );
      final Rect bubbleRect = UserMessageBubble.margin.deflateRect(
        Offset.zero & box.size,
      );
      expect(
        find.byKey(const Key('baking-bubble')),
        paints
          ..rrect()
          ..rrect()
          ..rect(
            rect: Rect.fromLTRB(
              bubbleRect.left,
              bubbleRect.bottom - 3,
              bubbleRect.left + bubbleRect.width * 0.5,
              bubbleRect.bottom,
            ),
            color: theme.colorScheme.primary,
          ),
      );

      upload.value = 1;
      await tester.pump();
      expect(find.text('Uploaded, sending…'), findsOneWidget);
    });
  }

  testWidgets('reduced motion still shows upload progress, without a ticker', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final ValueNotifier<double> upload = ValueNotifier<double>(0.25);
    addTearDown(upload.dispose);
    await tester.pumpWidget(bubble(upload));
    expect(find.text('Uploading… 25%'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    upload.value = 0.75;
    await tester.pump();
    expect(find.text('Uploading… 75%'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
