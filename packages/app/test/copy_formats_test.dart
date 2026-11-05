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
  test('Slack provides rich HTML and readable text without typing markup', () {
    final SlackCopy slack = formatSlackCopy(
      '# Heading\n\n**bold** *italic* ~~gone~~ [link](https://example.com)\n\n$table\n\n```dart\n  x ** y\n```',
    );
    expect(
      slack.text,
      startsWith('Heading\n\nbold italic gone link (https://example.com)'),
    );
    expect(
      slack.text,
      contains('Name | Value\n-----+------\nA, B | "yes"\na|b  | &'),
    );
    expect(slack.text, endsWith('  x ** y'));
    expect(slack.text, isNot(contains('```')));
    expect(slack.html, contains('<p><strong>Heading</strong></p>'));
    expect(
      slack.html,
      contains('<strong>bold</strong> <em>italic</em> <s>gone</s>'),
    );
    expect(slack.html, contains('<a href="https://example.com">link</a>'));
    expect(
      slack.html,
      contains(
        '<pre>Name | Value\n-----+------\nA, B | &quot;yes&quot;\na|b  | &amp;</pre>',
      ),
    );
    expect(slack.html, endsWith('<pre>  x ** y\n</pre>'));
    expect(slack.html, isNot(contains('```')));
    expect(formatCopy(table, CopyFormat.slack), formatSlackCopy(table).text);
  });
  test(
    'rich copy escapes HTML, retains literal code, and rejects active links',
    () {
      final SlackCopy slack = formatSlackCopy(
        '<script>alert(1)</script>\n\n[bad](javascript:alert)\n\n````\n``` & <b>\n````',
      );
      expect(slack.html, contains('&lt;script&gt;'));
      expect(slack.html, isNot(contains('href="javascript:')));
      expect(slack.html, contains('<pre>``` &amp; &lt;b&gt;\n</pre>'));
      expect(slack.text, contains('``` & <b>'));
    },
  );
  test('rich copy retains lists and quotes', () {
    final SlackCopy slack = formatSlackCopy(
      '> Quoted **text**\n\n3. Third\n4. Fourth\n   - Nested',
    );
    expect(
      slack.html,
      contains('<blockquote><p>Quoted <strong>text</strong></p></blockquote>'),
    );
    expect(slack.html, contains('<ol start="3">'));
    expect(slack.html, contains('<ul><li>Nested</li></ul>'));
  });
  test('Android tables become labeled records in both representations', () {
    const String source =
        '| What | Where | Notes |\n'
        '| --- | --- | --- |\n'
        "| Dev build’s app data | `~/.local/share/xyz.block.buzz.desktop.dev` | Profiles, plugin settings (including the saved Claude/Codex off), WebView storage, caches |\n"
        '| Helper folder | `~/.buzz-foundation` | Empty |';
    final SlackCopy result = formatSlackCopy(source, stackTables: true);
    expect(
      result.text,
      'What: Dev build’s app data\n'
      'Where: ~/.local/share/xyz.block.buzz.desktop.dev\n'
      'Notes: Profiles, plugin settings (including the saved Claude/Codex off), WebView storage, caches\n\n'
      'What: Helper folder\n'
      'Where: ~/.buzz-foundation\n'
      'Notes: Empty',
    );
    expect(
      result.html,
      contains('<strong>What: </strong>Dev build’s app data<br>'),
    );
    expect(
      result.html,
      contains(
        '<strong>Where: </strong><code>~/.local/share/xyz.block.buzz.desktop.dev</code><br>',
      ),
    );
    expect(
      result.html,
      contains('</p><p><strong>What: </strong>Helper folder'),
    );
    expect(result.html, isNot(contains('<pre>')));
    expect(result.text, isNot(contains('---')));
    expect(result.text, isNot(contains(' | ')));
  });
  test(
    'stacked tables retain empty cells, links, markup and escaped content',
    () {
      final SlackCopy result = formatSlackCopy(
        '| | Label |\n| - | - |\n| | **Bold** & [link](https://example.com) |\n| `a<b` | a\\|b |',
        stackTables: true,
      );
      expect(
        result.text,
        'Column 1: \nLabel: Bold & link (https://example.com)\n\nColumn 1: a<b\nLabel: a|b',
      );
      expect(
        result.html,
        contains(
          '<strong>Bold</strong> &amp; <a href="https://example.com">link</a>',
        ),
      );
      expect(result.html, contains('<code>a&lt;b</code>'));
      expect(
        formatSlackCopy('| A | B |\n| - | - |', stackTables: true).text,
        'A\nB',
      );
    },
  );
  test(
    'Android stacked tables work inside quotes without changing real code',
    () {
      final SlackCopy result = formatSlackCopy(
        '> | A | B |\n> | - | - |\n> | 1 | 2 |\n\n```\n| keep | this |\n```',
        stackTables: true,
      );
      expect(result.text, startsWith('> A: 1\n> B: 2'));
      expect(
        result.html,
        contains(
          '<blockquote><p><strong>A: </strong>1<br><strong>B: </strong>2</p></blockquote>',
        ),
      );
      expect(result.html, contains('<pre>| keep | this |\n</pre>'));
    },
  );
  test('empty cells and header-only tables are retained', () {
    expect(
      formatCopy('| A | B |\n| - | - |\n| | |', CopyFormat.csv),
      'A,B\r\n,',
    );
    expect(formatCopy('| A | B |\n| - | - |', CopyFormat.csv), 'A,B');
  });
}
