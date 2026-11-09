import 'package:speeddial_daemon/src/git/pull_request_receipt.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

ToolCall call({
  String title = 'Bash',
  Object? rawInput,
  String? text,
  Object? rawOutput,
  ToolCallStatus status = ToolCallStatus.completed,
}) => ToolCall(
  id: 'call',
  title: title,
  kind: 'execute',
  status: status,
  content: <ToolCallContent>[if (text != null) ToolCallText(text: text)],
  locations: const <String>[],
  rawInput: rawInput,
  rawOutput: rawOutput,
);

void main() {
  const String url = 'https://github.com/org/repo/pull/42';

  test('reads the URL gh prints last, past the push hint', () {
    expect(
      createdPullRequestUrl(
        call(
          rawInput: <String, Object?>{
            'command': 'git push -u origin HEAD && gh pr create --fill',
          },
          text:
              'remote:   https://github.com/org/repo/pull/new/feature\n'
              '$url\n```',
        ),
      ),
      url,
    );
  });

  test('accepts Codex argv, titles and raw output', () {
    expect(
      createdPullRequestUrl(
        call(
          rawInput: <String, Object?>{
            'command': <String>['gh', 'pr', 'create', '--draft'],
          },
          rawOutput: <String, Object?>{'stdout': '$url\n'},
        ),
      ),
      url,
    );
    expect(
      createdPullRequestUrl(call(title: 'gh pr create --fill', text: url)),
      url,
    );
  });

  test('an existing pull request reported by a failed create still counts', () {
    expect(
      createdPullRequestUrl(
        call(
          status: ToolCallStatus.failed,
          rawInput: 'gh pr create --fill',
          text:
              'a pull request for branch "x" into branch "main" already '
              'exists:\n$url',
        ),
      ),
      url,
    );
  });

  test(
    'other commands, unfinished calls and URLs only in the input do not',
    () {
      expect(
        createdPullRequestUrl(call(rawInput: 'gh pr view 42', text: url)),
        isNull,
      );
      expect(
        createdPullRequestUrl(
          call(
            status: ToolCallStatus.running,
            rawInput: 'gh pr create --fill',
            text: url,
          ),
        ),
        isNull,
      );
      expect(
        createdPullRequestUrl(
          call(
            rawInput: 'gh pr create --title t --body "Follows up $url"',
            text: 'Warning: 1 uncommitted change\n',
          ),
        ),
        isNull,
      );
    },
  );
}
