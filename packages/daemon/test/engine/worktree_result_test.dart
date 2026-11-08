import 'package:speeddial_daemon/src/engine/worktree_result.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  ToolCall call({
    String title = 'EnterWorktree',
    ToolCallStatus status = ToolCallStatus.completed,
    Object? output,
    Object? input,
    String? text,
  }) => ToolCall(
    id: 'one',
    title: title,
    kind: 'other',
    status: status,
    content: [if (text != null) ToolCallText(text: text)],
    locations: const [],
    rawInput: input,
    rawOutput: output,
  );

  test('accepts structured and text receipts, including paths with spaces', () {
    const String path = '/repo with spaces/.claude/worktrees/one';
    for (final Object output in <Object>[
      {'worktreePath': path},
      '{"worktreePath":"$path"}',
      [
        {'type': 'text', 'text': '{"worktreePath":"$path"}'},
      ],
      'Created worktree at “$path” on branch “worktree-one”',
      'Created worktree at "$path" on branch "worktree-one"',
    ]) {
      expect(enteredWorktreePath(call(output: output)), path);
    }
    expect(
      enteredWorktreePath(
        call(text: 'Created worktree at “$path” on branch “one”'),
      ),
      path,
    );
  });

  test(
    'ignores failed, running, unrelated, input-only and malformed calls',
    () {
      for (final ToolCall value in [
        call(status: ToolCallStatus.failed, output: {'worktreePath': '/repo'}),
        call(status: ToolCallStatus.running, output: {'worktreePath': '/repo'}),
        call(title: 'Read', output: {'worktreePath': '/repo'}),
        call(title: 'Agent: EnterWorktree', output: {'worktreePath': '/repo'}),
        call(input: {'path': '/repo'}),
        call(
          output: 'The docs say: Created worktree at “/repo” on branch “one”',
        ),
        call(output: {'worktreePath': 4}),
        call(output: '{invalid json'),
      ]) {
        expect(enteredWorktreePath(value), isNull);
      }
    },
  );
}
