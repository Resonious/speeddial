import 'package:flutter_test/flutter_test.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import 'package:speeddial_app/src/ui/chat/tool_call_summary.dart';

ToolCall _tool({
  String title = 'Bash',
  String kind = 'execute',
  Object? rawInput,
  List<String> locations = const <String>[],
}) => ToolCall(
  id: 'tool',
  title: title,
  kind: kind,
  status: ToolCallStatus.completed,
  content: const <ToolCallContent>[],
  locations: locations,
  rawInput: rawInput,
);

void main() {
  const String cwd = '/home/nigel/p/vpt/.speeddial-worktrees/server-238d6431';

  group('cleanCommand', () {
    test('unwraps login-shell launchers, nested or not', () {
      expect(
        cleanCommand("/usr/bin/bash -lc 'kill -TERM 553376'"),
        'kill -TERM 553376',
      );
      expect(
        cleanCommand(r'/usr/bin/bash -lc "rg \"retry\" src | head -5"'),
        'rg "retry" src | head -5',
      );
      expect(
        cleanCommand("bash -lc 'echo '\\''hi'\\'' && ls'"),
        "echo 'hi' && ls",
      );
      expect(
        cleanCommand('/usr/bin/bash -lc "bash -lc \'df -h /home\'"'),
        'df -h /home',
      );
    });

    test('drops a leading cd, environment and program paths', () {
      expect(
        cleanCommand('cd $cwd && echo "--- velocity ---" && git log', cwd: cwd),
        'echo "--- velocity ---" && git log',
      );
      expect(
        cleanCommand(
          'RUST_LOG=debug CARGO_TARGET_DIR="/tmp/t a" cargo test && '
          'FOO=1 npm run lint',
        ),
        'cargo test && npm run lint',
      );
      expect(cleanCommand('/usr/bin/python3 -u job.py'), 'python3 -u job.py');
    });

    test('shortens paths and folds lines', () {
      expect(
        cleanCommand('sed -n 1,9p $cwd/native/src/main.rs $cwd', cwd: cwd),
        'sed -n 1,9p native/src/main.rs .',
      );
      expect(
        cleanCommand('cat /home/nigel/.zshrc /home/nigel', cwd: cwd),
        'cat ~/.zshrc ~',
      );
      expect(
        cleanCommand("python3 - <<'PY'\nprint(1)\nPY"),
        "python3 - <<'PY' print(1) PY",
      );
    });
  });

  group('summarizeToolCall', () {
    test("titles a shell call with the agent's description", () {
      final ToolCallSummary summary = summarizeToolCall(
        _tool(
          title: 'cd $cwd && git status --short',
          rawInput: <String, Object?>{
            'command': 'cd $cwd && git status --short',
            'description': 'Show working tree status',
          },
        ),
        cwd: cwd,
      );
      expect(summary.title, 'Show working tree status');
      expect(summary.detail, 'git status --short');
      expect(summary.titleIsCommand, isFalse);
    });

    test('falls back to the cleaned command, shown as code', () {
      final ToolCallSummary summary = summarizeToolCall(
        _tool(title: "/usr/bin/bash -lc 'df -h /home'"),
      );
      expect(summary.title, 'df -h /home');
      expect(summary.detail, isNull);
      expect(summary.titleIsCommand, isTrue);
    });

    test("reads Codex's command actions", () {
      ToolCallSummary codex(List<Object?> actions) => summarizeToolCall(
        _tool(
          title: '/usr/bin/bash -lc "…"',
          rawInput: <String, Object?>{
            'command': "/usr/bin/bash -lc 'cat a b; rg -n retry src'",
            'commandActions': actions,
          },
        ),
      );
      final ToolCallSummary summary = codex(<Object?>[
        <String, Object?>{'type': 'read', 'name': 'CLAUDE.md', 'path': '/x'},
        <String, Object?>{'type': 'read', 'name': 'main.rs', 'path': '/y'},
        <String, Object?>{'type': 'search', 'query': 'retry', 'path': 'src'},
        <String, Object?>{'type': 'listFiles', 'path': 'None'},
      ]);
      expect(
        summary.title,
        'Read CLAUDE.md, main.rs · Search “retry” in src · List files',
      );
      expect(summary.detail, 'cat a b; rg -n retry src');

      // Anything unclassified: the command says more.
      expect(
        codex(<Object?>[
          <String, Object?>{'type': 'unknown', 'command': 'kill 1'},
        ]).title,
        'cat a b; rg -n retry src',
      );
    });

    test('names MCP tools and previews their scalar arguments', () {
      final ToolCallSummary summary = summarizeToolCall(
        _tool(
          title: 'mcp__speeddial__VPT_Staging__vpt_invoke_operation',
          kind: 'other',
          rawInput: <String, Object?>{
            'operation': 'createAssignment',
            'arguments': <String, Object?>{'id': 1},
            'user_consent': true,
          },
        ),
      );
      expect(summary.title, 'VPT Staging · vpt invoke operation');
      expect(
        summary.detail,
        'operation: createAssignment · user_consent: true',
      );
      expect(
        summarizeToolCall(
          _tool(
            title: 'mcp__speeddial__read_session_transcript',
            kind: 'other',
          ),
        ).title,
        'SpeedDial · read session transcript',
      );
    });

    test('does not repeat a location the title already names', () {
      final ToolCallSummary read = summarizeToolCall(
        _tool(
          title: 'Read native/src/main.rs (462 - 811)',
          kind: 'read',
          locations: <String>['native/src/main.rs'],
        ),
      );
      expect(read.title, 'Read native/src/main.rs (462 - 811)');
      expect(read.detail, isNull);

      final ToolCallSummary edit = summarizeToolCall(
        _tool(
          title: 'Edit',
          kind: 'edit',
          locations: <String>['$cwd/lib/main.dart'],
        ),
        cwd: cwd,
      );
      expect(edit.title, 'Edit');
      expect(edit.detail, 'lib/main.dart');
    });

    test('says what a call titled only with its tool did', () {
      ToolCallSummary named(String title, Map<String, Object?> input) =>
          summarizeToolCall(
            _tool(title: title, kind: 'other', rawInput: input),
            cwd: cwd,
          );
      // A file leads by its own name, with where it lives beneath.
      final ToolCallSummary read = named('Read', <String, Object?>{
        'file_path': '$cwd/src/main.rs',
      });
      expect(read.title, 'Read main.rs');
      expect(read.detail, 'src/main.rs');
      expect(read.titleIsCommand, isFalse);
      // Only part of it: which part.
      String reading(Map<String, Object?> range) => named(
        'Read',
        <String, Object?>{'file_path': '$cwd/src/main.rs', ...range},
      ).title;
      expect(
        reading(<String, Object?>{'offset': 755, 'limit': 70}),
        'Read lines 755–824 of main.rs',
      );
      expect(
        reading(<String, Object?>{'offset': 1, 'limit': 130}),
        'Read lines 1–130 of main.rs',
      );
      expect(
        reading(<String, Object?>{'offset': 300}),
        'Read main.rs from line 300',
      );
      expect(
        reading(<String, Object?>{'offset': 0, 'limit': 2000}),
        'Read main.rs',
      );
      final ToolCallSummary edit = named('Edit', <String, Object?>{
        'file_path': '/home/nigel/.zshrc',
      });
      expect(edit.title, 'Edit .zshrc');
      expect(edit.detail, '~/.zshrc');
      final ToolCallSummary write = named('Write', <String, Object?>{
        'file_path': '$cwd/notes.md',
      });
      expect(write.title, 'Write notes.md');
      expect(write.detail, isNull);

      String titled(String title, Map<String, Object?> input) =>
          named(title, input).title;
      expect(
        titled('Grep', <String, Object?>{
          'pattern': 'retry|backoff',
          'path': '$cwd/src',
          '-n': true,
        }),
        'Search “retry|backoff” in src',
      );
      // Searching the working directory itself needs no "in".
      expect(
        titled('Glob', <String, Object?>{'pattern': '**/*.yml', 'path': cwd}),
        'Find **/*.yml',
      );
      expect(titled('LS', <String, Object?>{'path': '$cwd/lib'}), 'List lib');
      expect(
        titled('WebFetch', <String, Object?>{
          'url': 'https://docs.flutter.dev/ui',
          'prompt': 'Summarize',
        }),
        'Fetch docs.flutter.dev/ui',
      );
      expect(
        titled('WebSearch', <String, Object?>{'query': 'sliver keep alive'}),
        'Search the web for “sliver keep alive”',
      );
      expect(
        titled('Grep', <String, Object?>{'pattern': 'a' * 60}),
        'Search “${'a' * 39}…”',
      );

      // A title that already says what the call did stays, as does one
      // whose input lacks what it would take.
      expect(
        titled('Read native/src/main.rs (462 - 811)', <String, Object?>{
          'file_path': '$cwd/native/src/main.rs',
        }),
        'Read native/src/main.rs (462 - 811)',
      );
      expect(titled('Grep', <String, Object?>{'path': 'src'}), 'Grep');
    });
  });
}
