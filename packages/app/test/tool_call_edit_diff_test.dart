import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/tool_call_edit_diff.dart';

import 'package:speeddial_protocol/speeddial_protocol.dart';

ToolCall _edit({
  Object? rawInput,
  Object? rawOutput,
  List<String> locations = const <String>[],
}) =>
    ToolCall(
      id: 'tc-edit',
      title: 'Edit',
      kind: 'edit',
      status: ToolCallStatus.completed,
      content: const <ToolCallContent>[],
      locations: locations,
      rawInput: rawInput,
      rawOutput: rawOutput,
    );

void main() {
  group('extractEditDiffFromToolCall', () {
    test('parses a codex-style hunks patch from the raw output', () {
      // Shape sampled from real session events:
      // {"patch":{"hunks":[{"lines":[" ctx","-old","+new"],"old_start":9,...}]}}
      final ToolCall call = _edit(
        rawOutput: <String, Object?>{
          'patch': <String, Object?>{
            'hunks': <Object?>[
              <String, Object?>{
                'lines': <String>[
                  ' /// Buckets keep the complete picture (archived included);',
                  '-/// the public [sessionsFor] view omits old archives.',
                  '+/// the public [sessionsFor] view omits archived sessions.',
                  ' ///',
                ],
                'new_lines': 12,
                'new_start': 9,
                'old_lines': 12,
                'old_start': 9,
              },
            ],
          },
          'summary': 'File packages/app/x.dart edited successfully.',
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(diff!.absorbsRawOutput, isTrue);
      expect(diff.deletions, 1);
      expect(diff.additions, 1);
      final List<ToolEditLine> lines = diff.lines;
      expect(lines, hasLength(4));
      expect(lines[0].sign, ' ');
      expect(lines[0].oldNum, 9);
      expect(lines[0].newNum, 9);
      final ToolEditLine removed = lines[1];
      expect(removed.sign, '-');
      expect(removed.oldNum, 10);
      expect(removed.newNum, null);
      final ToolEditLine added = lines[2];
      expect(added.sign, '+');
      expect(added.newNum, 10);
      expect(added.oldNum, null);
      expect(lines[3].oldNum, 11);
      expect(lines[3].newNum, 11);
    });

    test('parses an Ante numbered diff (details.diff) with numbers', () {
      // Shape sampled from real session events: " 26|ctx", "-28|old", "+28|new".
      final ToolCall call = _edit(
        rawOutput: <String, Object?>{
          'details': <String, Object?>{
            'diff': ' 26|/// A merged run of agent thought chunks.\n'
                ' 27|class AgentThoughtItem extends TimelineItem {\n'
                '-28|  const AgentThoughtItem({required this.text});\n'
                '+28|  const AgentThoughtItem({required this.text, '
                    'this.active = false});\n'
                ' 29|  final String text;\n',
          },
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(diff!.absorbsRawOutput, isTrue);
      expect(diff.additions, 1);
      expect(diff.deletions, 1);
      expect(diff.lines, hasLength(5));
      expect(diff.lines[0].oldNum, 26);
      expect(diff.lines[0].newNum, 26);
      final ToolEditLine removed = diff.lines[2];
      expect(removed.sign, '-');
      expect(
        removed.text,
        '  const AgentThoughtItem({required this.text});',
      );
      expect(removed.oldNum, 28);
      final ToolEditLine added = diff.lines[3];
      expect(added.sign, '+');
      expect(added.newNum, 28);
      expect(added.oldNum, null);
    });

    test('marks an omission gap between Ante hunk blocks', () {
      final ToolCall call = _edit(
        rawOutput: <String, Object?>{
          'details': <String, Object?>{
            'diff': ' 1|alpha\n'
                ' 2|beta\n'
                '-3|gamma\n'
                '+3|delta\n'
                '\n'
                ' 6|epsilon\n'
                ' 7|zeta\n',
          },
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(
        diff!.lines,
        contains(
          predicate(
            (ToolEditLine line) =>
                line.sign == ' ' && line.text == '… 2 lines omitted',
          ),
        ),
      );
    });

    test('derives a diff from old_string/new_string input', () {
      final ToolCall call = _edit(
        rawInput: <String, Object?>{
          'file_path': 'packages/app/lib/src/ui/chat/timeline.dart',
          'old_string': 'int x = 1;\nint y = 2;\n',
          'new_string': 'int x = 1;\nint y = 9;\n',
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(diff!.path, 'packages/app/lib/src/ui/chat/timeline.dart');
      expect(diff.absorbsRawOutput, isFalse);
      expect(diff.lines, hasLength(3)); // context + one replaced line
      expect(diff.deletions, 1);
      expect(diff.additions, 1);
    });

    test('parses a unified diff string in the output patch', () {
      final ToolCall call = _edit(
        rawOutput: <String, Object?>{
          'patch': 'diff --git a/x.dart b/x.dart\n'
              '--- a/x.dart\n'
              '+++ b/x.dart\n'
              '@@ -3,3 +3,3 @@\n'
              ' ctx\n'
              '-del\n'
              '+add\n',
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(diff!.absorbsRawOutput, isTrue);
      expect(diff.deletions, 1);
      expect(diff.additions, 1);
      final ToolEditLine del =
          diff.lines.firstWhere((ToolEditLine line) => line.sign == '-');
      expect(del.oldNum, 4);
    });

    test('prefers the provider diff over the input snippets', () {
      final ToolCall call = _edit(
        rawInput: <String, Object?>{
          'old_string': 'a\n',
          'new_string': 'b\n',
        },
        rawOutput: <String, Object?>{
          'details': <String, Object?>{
            'diff': '-1|a\n+1|b\n',
          },
        },
      );
      final ToolEditDiff? diff = extractEditDiffFromToolCall(call);
      expect(diff, isNotNull);
      expect(diff!.absorbsRawOutput, isTrue);
      // The provider line, not an input-derived one.
      expect(diff.lines.where((ToolEditLine l) => l.text == 'b'), hasLength(1));
    });

    test('returns null for other kinds and empty payloads', () {
      expect(extractEditDiffFromToolCall(_edit()), isNull);
      final ToolCall execute = ToolCall(
        id: 'tc-exec',
        title: 'Run tests',
        kind: 'execute',
        status: ToolCallStatus.completed,
        content: const <ToolCallContent>[],
        locations: const <String>[],
        rawInput: <String, Object?>{
          'old_string': 'a\n',
          'new_string': 'b\n',
        },
      );
      expect(extractEditDiffFromToolCall(execute), isNull);
    });
  });

  group('diffFileLines', () {
    test('keeps three context lines around a change', () {
      final List<ToolEditLine> lines = diffFileLines(
        'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n',
        'l1\nl2\nL3\nl4\nl5\nl6\nl7\nl8\n',
      );
      expect(lines, hasLength(7)); // l1..l6 with l3 replaced
      expect(lines.first.text, 'l1');
      expect(lines[2].sign, '-');
      expect(lines[3].sign, '+');
      expect(lines.last.text, 'l6');
    });

    test('returns no lines when the contents are identical', () {
      expect(diffFileLines('a\nb\n', 'a\nb\n'), isEmpty);
    });
  });

  group('unifiedDiffLines', () {
    test('tracks numbers across hunk headers and marks file headers', () {
      final List<ToolEditLine> lines = unifiedDiffLines(
        '--- a/f.dart\n'
            '+++ b/f.dart\n'
            '@@ -3,3 +3,3 @@\n'
            ' ctx\n'
            '-del\n'
            '+add\n',
      );
      expect(lines.any((ToolEditLine line) => line.isHeader), isTrue);
      final ToolEditLine del = lines.firstWhere(
        (ToolEditLine line) => line.sign == '-',
      );
      expect(del.oldNum, 4);
      final ToolEditLine add = lines.firstWhere(
        (ToolEditLine line) => line.sign == '+',
      );
      expect(add.newNum, 4);
      expect(add.oldNum, null);
    });
  });
}