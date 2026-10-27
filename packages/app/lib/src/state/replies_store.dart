import 'package:flutter/foundation.dart';

/// A reply to a passage the user selected in the timeline, staged in the
/// composer like an attachment until the next send.
@immutable
class ReplyDraft {
  const ReplyDraft({
    required this.id,
    required this.quote,
    required this.reply,
  });

  /// Stable for the reply's life so edits and removals find it.
  final int id;

  /// The selected text being replied to.
  final String quote;
  final String reply;

  ReplyDraft copyWith({String? reply}) =>
      ReplyDraft(id: id, quote: quote, reply: reply ?? this.reply);
}

/// One reply carried inside a sent message's text.
@immutable
class SentReply {
  const SentReply({required this.quote, required this.reply});

  final String quote;
  final String reply;
}

/// Replies have no wire field of their own: they travel in the message text
/// as tagged blocks ahead of the message body, which agents read as plain
/// context and [parseReplies] turns back into chips in the bubble.
String formatMessageWithReplies(List<ReplyDraft> replies, String text) {
  final StringBuffer buffer = StringBuffer();
  for (final ReplyDraft reply in replies) {
    if (buffer.isNotEmpty) buffer.write('\n\n');
    buffer
      ..write('<reply>\n<quote>\n')
      ..write(reply.quote.trim())
      ..write('\n</quote>\n')
      ..write(reply.reply.trim())
      ..write('\n</reply>');
  }
  if (text.isNotEmpty) {
    if (buffer.isNotEmpty) buffer.write('\n\n');
    buffer.write(text);
  }
  return buffer.toString();
}

final RegExp _replyBlock = RegExp(
  r'^<reply>\n<quote>\n([\s\S]*?)\n</quote>\n([\s\S]*?)\n</reply>(?:\n\n|\n?$)',
);

/// Splits leading reply blocks (see [formatMessageWithReplies]) off [text].
({List<SentReply> replies, String body}) parseReplies(String text) {
  if (!text.startsWith('<reply>')) {
    return (replies: const <SentReply>[], body: text);
  }
  final List<SentReply> replies = <SentReply>[];
  String rest = text;
  while (true) {
    final RegExpMatch? match = _replyBlock.firstMatch(rest);
    if (match == null) break;
    replies.add(SentReply(quote: match.group(1)!, reply: match.group(2)!));
    rest = rest.substring(match.end);
  }
  return (replies: replies, body: rest);
}

/// Replies staged per daemon/session. In memory only, like shared files:
/// they outlive composer remounts and failed sends, not the app.
class RepliesStore extends ChangeNotifier {
  final Map<String, List<ReplyDraft>> _staged = <String, List<ReplyDraft>>{};
  int _nextId = 0;

  String _key(String daemonId, String sessionId) => '$daemonId\u0000$sessionId';

  List<ReplyDraft> repliesFor(String daemonId, String sessionId) =>
      List<ReplyDraft>.unmodifiable(
        _staged[_key(daemonId, sessionId)] ?? const <ReplyDraft>[],
      );

  void add(String daemonId, String sessionId, String quote, String reply) {
    _staged
        .putIfAbsent(_key(daemonId, sessionId), () => <ReplyDraft>[])
        .add(ReplyDraft(id: _nextId++, quote: quote, reply: reply));
    notifyListeners();
  }

  void edit(String daemonId, String sessionId, int id, String reply) {
    final List<ReplyDraft>? staged = _staged[_key(daemonId, sessionId)];
    if (staged == null) return;
    final int index = staged.indexWhere((ReplyDraft r) => r.id == id);
    if (index < 0 || staged[index].reply == reply) return;
    staged[index] = staged[index].copyWith(reply: reply);
    notifyListeners();
  }

  void remove(String daemonId, String sessionId, Iterable<int> ids) {
    final String key = _key(daemonId, sessionId);
    final List<ReplyDraft>? staged = _staged[key];
    if (staged == null) return;
    final Set<int> gone = ids.toSet();
    final int before = staged.length;
    staged.removeWhere((ReplyDraft r) => gone.contains(r.id));
    if (staged.isEmpty) _staged.remove(key);
    if (staged.length != before) notifyListeners();
  }
}
