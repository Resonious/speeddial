import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/copy_formats.dart';

void main() {
  const String table =
      '| Name | Value |\n| :--- | ---: |\n| **A**, B | "yes" |\n| a\\|b | `&` |';
  test(
    'Markdown is unchanged and HTML preserves table structure and styling',
    () {
      expect(formatCopy(table, CopyFormat.markdown), table);
      final String html = formatCopy(table, CopyFormat.html);
      expect(html, contains('<table>'));
      expect(html, contains('<strong>A</strong>, B'));
      expect(html, contains('<code>&amp;</code>'));
      expect(html, contains('align="right"'));
    },
  );
  test('CSV escapes commas and quotes and removes inline markup', () {
    expect(
      formatCopy(table, CopyFormat.csv),
      'Name,Value\r\n"A, B","""yes"""\r\na|b,&',
    );
  });
  test('Slack converts emphasis, links and tables without changing code', () {
    final String slack = formatCopy(
      '# Heading\n\n**bold** *italic* ~~gone~~ [link](https://example.com)\n\n$table\n\n```dart\n  x ** y\n```',
      CopyFormat.slack,
    );
    expect(
      slack,
      startsWith(
        '*Heading*\n\n*bold* _italic_ ~gone~ link (https://example.com)',
      ),
    );
    expect(
      slack,
      contains('```\nName | Value\n-----+------\nA, B | "yes"\na|b  | &\n```'),
    );
    expect(slack, endsWith('```\n  x ** y\n```'));
  });
  test('empty cells and header-only tables are retained', () {
    expect(
      formatCopy('| A | B |\n| - | - |\n| | |', CopyFormat.csv),
      'A,B\r\n,',
    );
    expect(formatCopy('| A | B |\n| - | - |', CopyFormat.csv), 'A,B');
  });
}
