import 'package:speeddial_protocol/speeddial_protocol.dart';

/// `gh pr create` as a command word sequence, anywhere in a shell command.
final RegExp _kCreateCommand = RegExp(r'\bgh\s+pr\s+create\b');

/// A pull request page URL. `/pull/new/<branch>` (the hint `git push` prints)
/// does not match, since its segment is not a number.
final RegExp _kPullRequestUrl = RegExp(
  r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+\b',
);

/// The pull request a finished `gh pr create` tool call opened, or null for
/// any other call.
///
/// This is how a session claims a pull request: by the receipt of the call
/// that made it, not by the branch of its cwd. Sessions can share a cwd (forks
/// keep their source's) while each agent works in its own checkout through
/// `cd`, so the cwd branch alone would hang one pull request on all of them.
///
/// `gh` prints the new URL last; when the branch already has a pull request it
/// fails with that one's URL instead, which is still the pull request of the
/// branch the agent was on. Only the call's own output is read: the command
/// itself (a body naming other pull requests) is never a receipt.
String? createdPullRequestUrl(ToolCall call) {
  if (call.status != ToolCallStatus.completed &&
      call.status != ToolCallStatus.failed) {
    return null;
  }
  if (!_mentionsCreate(call.rawInput) &&
      !_kCreateCommand.hasMatch(call.title)) {
    return null;
  }
  final StringBuffer output = StringBuffer();
  for (final ToolCallContent content in call.content) {
    if (content is ToolCallText) output.writeln(content.text);
  }
  return _lastUrl(output.toString()) ?? _lastUrlIn(call.rawOutput);
}

/// Canonical form of a pull request URL, for comparing a claim with `gh`'s.
String pullRequestKey(String url) => url.toLowerCase();

bool _mentionsCreate(Object? value) {
  if (value is String) return _kCreateCommand.hasMatch(value);
  if (value is Map) return value.values.any(_mentionsCreate);
  if (value is List) {
    // Codex passes argv: ["bash", "-lc", "gh pr create ..."] or
    // ["gh", "pr", "create", ...].
    if (value.every((Object? part) => part is String) &&
        _kCreateCommand.hasMatch(value.join(' '))) {
      return true;
    }
    return value.any(_mentionsCreate);
  }
  return false;
}

String? _lastUrlIn(Object? value) {
  if (value is String) return _lastUrl(value);
  if (value is Map) {
    String? last;
    for (final Object? entry in value.values) {
      last = _lastUrlIn(entry) ?? last;
    }
    return last;
  }
  if (value is List) {
    String? last;
    for (final Object? entry in value) {
      last = _lastUrlIn(entry) ?? last;
    }
    return last;
  }
  return null;
}

String? _lastUrl(String text) {
  String? last;
  for (final RegExpMatch match in _kPullRequestUrl.allMatches(text)) {
    last = match.group(0);
  }
  return last;
}
