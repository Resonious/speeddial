@TestOn('vm')
library;

import 'package:speeddial_daemon/src/cli/output.dart';
import 'package:test/test.dart';

void main() {
  group('renderTable', () {
    test('aligns each column to its widest cell', () {
      const headers = ['ID', 'NAME'];
      const rows = [
        ['a', 'short'],
        ['very-long-id', 'x'],
      ];
      expect(
        renderTable(headers, rows),
        'ID            NAME\n'
        'a             short\n'
        'very-long-id  x',
      );
    });

    test('renders just the header when there are no rows', () {
      expect(renderTable(const ['ID', 'NAME'], const []), 'ID  NAME');
    });

    test('truncates overlong cells with an ellipsis', () {
      final table = renderTable(
        const ['C'],
        [
          [List.filled(120, 'x').join()],
        ],
      );
      // Header (1 char) + 80-char cell + 1 ellipsis, one line.
      expect(table, 'C\n${List.filled(80, 'x').join()}…');
    });

    test('single column without padding stays compact', () {
      expect(renderTable(const ['X'], const [['v']]), 'X\nv');
    });
  });

  group('renderRecord', () {
    test('aligns keys and values', () {
      expect(
        renderRecord(const <String, Object?>{'id': 'p1', 'name': 'Demo'}),
        'id    p1\nname  Demo',
      );
    });
  });

  group('jsonEncodePretty', () {
    test('pretty-prints nested JSON', () {
      expect(
        jsonEncodePretty(const <String, Object?>{'a': 1}),
        '{\n  "a": 1\n}',
      );
    });
  });

  group('Output', () {
    test('human table writes an aligned table, never JSON', () {
      final buffer = StringBuffer();
      Output(json: false, sink: buffer).table(
        const ['ID', 'NAME'],
        const [
          ['p1', 'Demo'],
        ],
      );
      final text = buffer.toString();
      expect(text, contains('ID  NAME\np1  Demo'));
      expect(text, isNot(contains('"')));
    });

    test('--json table writes a JSON array of header-keyed objects', () {
      final buffer = StringBuffer();
      Output(json: true, sink: buffer).table(
        const ['ID', 'NAME'],
        const [
          ['p1', 'Demo'],
        ],
      );
      final text = buffer.toString();
      expect(text, contains('"ID": "p1"'));
      expect(text, contains('"NAME": "Demo"'));
      expect(text.trim(), startsWith('['));
      expect(text.trim(), endsWith(']'));
    });

    test('--json record writes raw JSON', () {
      final buffer = StringBuffer();
      Output(json: true, sink: buffer)
          .record(const <String, Object?>{'id': 'p1'});
      expect(buffer.toString(), contains('"id": "p1"'));
    });

    test('--json raw writes raw JSON', () {
      final buffer = StringBuffer();
      Output(json: true, sink: buffer).raw(const <String, Object?>{});
      expect(buffer.toString().trim(), '{}');
    });

    test('line writes plain text', () {
      final buffer = StringBuffer();
      Output(json: true, sink: buffer).line('hello');
      expect(buffer.toString(), 'hello\n');
    });
  });
}
