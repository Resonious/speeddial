import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_app/src/ui/chat/subagent_action.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

AgentActivity _update(
  String title, [
  List<String> details = const <String>[],
]) => AgentActivity(
  id: 'ante-subagent-call-step-0',
  kind: 'subagent',
  title: title,
  status: AgentActivityStatus.completed,
  details: details,
);

void main() {
  group('parseToolArguments', () {
    test('reads the arguments Ante lists for a subagent action', () {
      expect(
        parseToolArguments(
          '-A=3, -i=true, glob="*.{yml,yaml}", head_limit=250, offset=0, '
          'output_mode="content", path="/srv/app", pattern="a|b", type=""',
        ),
        <String, Object?>{
          '-A': 3,
          '-i': true,
          'glob': '*.{yml,yaml}',
          'head_limit': 250,
          'offset': 0,
          'output_mode': 'content',
          'path': '/srv/app',
          'pattern': 'a|b',
          'type': '',
        },
      );
    });

    test('unescapes quoted values, cut short or not', () {
      expect(
        parseToolArguments(
          r'command="git -C \"/srv/app\" log, then\nmore…", '
          r'description="Shows, briefly, the log"',
        ),
        <String, Object?>{
          'command': 'git -C "/srv/app" log, then\nmore…',
          'description': 'Shows, briefly, the log',
        },
      );
    });

    test('keeps lists and maps as written', () {
      expect(
        parseToolArguments(
          'edits=[{"old": "a, b", "new": "c"}], replace_all=false, note=null',
        ),
        <String, Object?>{
          'edits': '[{"old": "a, b", "new": "c"}]',
          'replace_all': false,
          'note': null,
        },
      );
    });

    test('reads nothing into words', () {
      expect(parseToolArguments('I’ll start from the importer.'), isNull);
      expect(parseToolArguments('path="never closed'), isNull);
      expect(parseToolArguments(''), isNull);
    });
  });

  test('a subagent action stands for the tool call it made', () {
    final ToolCall action = subagentActionOf(
      _update('Grep', <String>['path="/srv/app", pattern="retry"']),
    )!;
    expect(action.title, 'Grep');
    expect(action.kind, 'search');
    expect(action.rawInput, <String, Object?>{
      'path': '/srv/app',
      'pattern': 'retry',
    });
    // The subagent's own words, and Codex's interactions, are not actions.
    expect(subagentActionOf(_update('I’ll start from the importer.')), isNull);
    expect(
      subagentActionOf(_update('Summary', <String>['Summary\nAll good.'])),
      isNull,
    );
    expect(
      subagentActionOf(
        _update('Sub-agent interaction', <String>[
          '/root/audit_references',
          '01a0f964-25bc-71b1-8048-0538d00f2b35',
        ]),
      ),
      isNull,
    );
  });

  test("tool kinds follow the daemon's for Ante's own calls", () {
    expect(
      <String>[
        'Read',
        'Edit',
        'Grep',
        'Glob',
        'Bash',
        'WebFetch',
        'WebSearch',
        'Task',
      ].map(toolKindOf),
      <String>[
        'read',
        'edit',
        'search',
        'search',
        'execute',
        'fetch',
        'search',
        'other',
      ],
    );
  });

  test('terminal styling comes off, escaped or quoted from a log', () {
    expect(
      withoutTerminalCodes(
        '^[[1mimport^[[0m ^[[2;3mwith^[[0m \x1b[31mmode\x1b[0m: Restart',
      ),
      'import with mode: Restart',
    );
  });
}
