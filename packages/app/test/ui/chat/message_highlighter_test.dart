import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/message_highlighter.dart';
import 'package:speeddial_app/src/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'light and dark code use readable palettes and separate caches',
    () async {
      final MessageHighlighter highlighter = MessageHighlighter();
      const String code = 'void main() { final value = "hello"; // comment\n}';
      final Map<String, TextSpan> light = await highlighter.highlight(
        <String, String>{code: 'dart'},
        brightness: Brightness.light,
        background: buildSpeedDialLightTheme().speedDialColors.codeBackground,
      );
      final Map<String, TextSpan> dark = await highlighter.highlight(
        <String, String>{code: 'dart'},
        brightness: Brightness.dark,
        background: buildSpeedDialTheme().speedDialColors.codeBackground,
      );
      expect(identical(light[code], dark[code]), isFalse);
      for (final Brightness brightness in Brightness.values) {
        final TextSpan span = (brightness == Brightness.light
            ? light
            : dark)[code]!;
        final Color background =
            (brightness == Brightness.light
                    ? buildSpeedDialLightTheme()
                    : buildSpeedDialTheme())
                .speedDialColors
                .codeBackground;
        final List<Color> colors = <Color>[];
        span.visitChildren((InlineSpan token) {
          final Color? color = token.style?.color;
          if (color != null) colors.add(color);
          return true;
        });
        expect(colors.toSet().length, greaterThan(1));
        for (final Color color in colors) {
          final double foreground = color.computeLuminance();
          final double surface = background.computeLuminance();
          final double contrast = foreground > surface
              ? (foreground + 0.05) / (surface + 0.05)
              : (surface + 0.05) / (foreground + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$brightness $color',
          );
        }
        final Map<String, TextSpan> cached = await highlighter.highlight(
          <String, String>{code: 'dart'},
          brightness: brightness,
          background:
              (brightness == Brightness.light
                      ? buildSpeedDialLightTheme()
                      : buildSpeedDialTheme())
                  .speedDialColors
                  .codeBackground,
        );
        expect(identical(cached[code], span), isTrue);
      }
    },
  );

  test('obsolete queued requests skip highlighting', () async {
    final MessageHighlighter highlighter = MessageHighlighter();
    expect(
      await highlighter.highlight(
        <String, String>{'unused': 'unknown'},
        brightness: Brightness.dark,
        background: buildSpeedDialTheme().speedDialColors.codeBackground,
        isCurrent: () => false,
      ),
      isEmpty,
    );
  });

  test(
    'native worker produces styled text and repeated requests reuse it',
    () async {
      final MessageHighlighter highlighter = MessageHighlighter();
      const String code = 'void main() { final value = 42; }';
      final Map<String, TextSpan> first = await highlighter.highlight(
        <String, String>{code: 'dart'},
        brightness: Brightness.dark,
        background: buildSpeedDialTheme().speedDialColors.codeBackground,
      );
      expect(first[code]?.toPlainText(), code);
      expect(first[code]?.children, isNotEmpty);
      final Map<String, TextSpan> second = await highlighter.highlight(
        <String, String>{code: 'dart'},
        brightness: Brightness.dark,
        background: buildSpeedDialTheme().speedDialColors.codeBackground,
      );
      expect(identical(first[code], second[code]), isTrue);
    },
  );

  test(
    'oversized code stays plain and a failed request does not break later work',
    () async {
      final MessageHighlighter highlighter = MessageHighlighter();
      final String large = 'x' * (MessageHighlighter.maxBlockLength + 1);
      expect(
        await highlighter.highlight(
          <String, String>{large: 'dart'},
          brightness: Brightness.dark,
          background: buildSpeedDialTheme().speedDialColors.codeBackground,
        ),
        isEmpty,
      );
      await expectLater(
        highlighter.highlight(
          <String, String>{'oops': 'unknown'},
          brightness: Brightness.dark,
          background: buildSpeedDialTheme().speedDialColors.codeBackground,
        ),
        throwsA(anything),
      );
      expect(
        (await highlighter.highlight(
          <String, String>{'{}': 'json'},
          brightness: Brightness.dark,
          background: buildSpeedDialTheme().speedDialColors.codeBackground,
        ))['{}']?.toPlainText(),
        '{}',
      );
    },
  );
}
