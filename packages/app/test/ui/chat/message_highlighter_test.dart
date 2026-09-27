import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/message_highlighter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('obsolete queued requests skip highlighting', () async {
    final MessageHighlighter highlighter = MessageHighlighter();
    expect(
      await highlighter.highlight(<String, String>{
        'unused': 'unknown',
      }, isCurrent: () => false),
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
      );
      expect(first[code]?.toPlainText(), code);
      expect(first[code]?.children, isNotEmpty);
      final Map<String, TextSpan> second = await highlighter.highlight(
        <String, String>{code: 'dart'},
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
        await highlighter.highlight(<String, String>{large: 'dart'}),
        isEmpty,
      );
      await expectLater(
        highlighter.highlight(<String, String>{'oops': 'unknown'}),
        throwsA(anything),
      );
      expect(
        (await highlighter.highlight(<String, String>{
          '{}': 'json',
        }))['{}']?.toPlainText(),
        '{}',
      );
    },
  );
}
