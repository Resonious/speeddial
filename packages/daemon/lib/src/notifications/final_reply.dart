import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Collects only the latest logical agent message in a turn. Tool, thought,
/// and activity updates may interleave its chunks without splitting it.
class FinalReply {
  final Set<String?> _seen = <String?>{};
  String? _messageId;
  StringBuffer _text = StringBuffer();

  void add(AgentMessageChunkEvent event) {
    if (event.text.isEmpty) return;
    if (_seen.add(event.messageId)) {
      _messageId = event.messageId;
      _text = StringBuffer();
    }
    // A late delta from an earlier message must not replace the final one.
    if (event.messageId == _messageId) _text.write(event.text);
  }

  String get text => _text.toString().trim();
}
