import 'package:speeddial_daemon/src/notifications/final_reply.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'joins the final message and excludes commentary and late old deltas',
    () {
      final FinalReply reply = FinalReply();
      reply.add(
        const AgentMessageChunkEvent(
          text: 'Inspecting files.',
          messageId: 'm1',
        ),
      );
      reply.add(
        const AgentMessageChunkEvent(text: '**Done** — ', messageId: 'm2'),
      );
      reply.add(
        const AgentMessageChunkEvent(text: 'more commentary', messageId: 'm1'),
      );
      reply.add(
        const AgentMessageChunkEvent(text: 'fixed it 🔥.\n', messageId: 'm2'),
      );
      expect(reply.text, '**Done** — fixed it 🔥.');
    },
  );

  test('empty chunks do not replace a reply', () {
    final FinalReply reply = FinalReply();
    reply.add(const AgentMessageChunkEvent(text: 'Done.', messageId: 'm1'));
    reply.add(const AgentMessageChunkEvent(text: '', messageId: 'm2'));
    expect(reply.text, 'Done.');
  });
}
