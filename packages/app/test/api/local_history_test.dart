import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_app/src/api/local_history.dart';
import 'package:speeddial_app/src/api/ws_daemon_client.dart';
import 'package:speeddial_app/src/state/chat_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

class _Channel implements DaemonFrameChannel {
  final incoming = StreamController<Object?>();
  bool holdHistory = false;
  bool failHistory = false;
  final List<Map> held = [];
  void releaseHistory() {
    holdHistory = false;
    for (final request in held) {
      respond(request);
    }
    held.clear();
  }

  final List<SessionEvent> events = [
    const UserMessageEvent(text: 'Question', seq: 1),
    const AgentMessageChunkEvent(text: 'Answer', seq: 2, messageId: 'reply'),
    const TurnCompleteEvent(stopReason: 'end_turn', seq: 3),
  ];
  @override
  Future<void> get ready async {}
  @override
  Stream<Object?> get stream => incoming.stream;
  @override
  void add(Object? data) {
    final request = jsonDecode(data as String) as Map;
    if (holdHistory && request['method'] == 'sessions.history') {
      held.add(request);
      return;
    }
    respond(request);
  }

  void respond(Map request) {
    if (failHistory && request['method'] == 'sessions.history') {
      incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32011, 'message': 'History unavailable'},
        }),
      );
      return;
    }
    final result = switch (request['method']) {
      'projects.list' => {'projects': <Object>[]},
      'sessions.list' => {
        'sessions': [session.toJson()],
      },
      'sessions.history' => {
        'events': events.map((e) => e.toJson()).toList(),
        'hasMore': false,
      },
      _ => <String, Object?>{},
    };
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  void emit(SessionEvent event) {
    events.add(event);
    incoming.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'session.event',
        'params': {'sessionId': 's', 'event': event.toJson()},
      }),
    );
  }

  @override
  Future<void> close() => incoming.close();
}

final session = Session(
  id: 's',
  projectId: 'p',
  providerId: 'codex',
  title: 'Offline conversation',
  status: SessionStatus.idle,
  model: null,
  cwd: '/',
  baseBranch: null,
  yolo: false,
  archived: false,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

Future<void> until(Future<bool> Function() check) async {
  for (int i = 0; i < 200; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Background cache did not finish');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'connected open shows sparse cache before a delayed full range refresh',
    () async {
      final cache = LocalHistory('daemon');
      await cache.merge('s', [
        const UserMessageEvent(text: 'Question', seq: 1),
        const AgentMessageChunkEvent(text: 'Answer', seq: 4),
        const TurnCompleteEvent(stopReason: 'end_turn', seq: 5),
      ]);
      final channel = _Channel()..holdHistory = true;
      channel.events
        ..clear()
        ..addAll([
          const UserMessageEvent(text: 'Question', seq: 1),
          const AgentThoughtChunkEvent(
            text: 'Previously omitted thinking',
            seq: 2,
          ),
          const AgentMessageChunkEvent(text: 'Missing reply. ', seq: 3),
          const AgentMessageChunkEvent(text: 'Answer', seq: 4),
          const TurnCompleteEvent(stopReason: 'end_turn', seq: 5),
        ]);
      final client = WsDaemonClient(
        url: 'ws://test/ws',
        localHistory: cache,
        channelFactory: (_) => channel,
      );
      final chat = ChatStore(clientFor: (_) => client);
      await client.connect();
      chat.watchSession('daemon', 's');
      await until(() async => chat.isCatchingUp('s'));
      expect(
        chat.eventsFor('s').whereType<AgentMessageChunkEvent>().single.text,
        'Answer',
      );
      expect(chat.isSavedHistory('s'), isTrue);
      expect(chat.isSavedHistoryComplete('s'), isFalse);
      channel.releaseHistory();
      await until(() async => !chat.isCatchingUp('s'));
      expect(
        chat.eventsFor('s').whereType<AgentMessageChunkEvent>().single.text,
        'Missing reply. Answer',
      );
      expect(
        chat.eventsFor('s').whereType<AgentThoughtChunkEvent>().single.text,
        'Previously omitted thinking',
      );
      expect(chat.isSavedHistory('s'), isFalse);
      chat.dispose();
      await client.dispose();
    },
  );

  test('failed refresh retains saved content and retry fills it without duplication', () async {
    final cache = LocalHistory('daemon');
    await cache.merge('s', [const UserMessageEvent(text: 'Question', seq: 1)]);
    final channel = _Channel()..failHistory = true;
    final client = WsDaemonClient(
      url: 'ws://test/ws',
      localHistory: cache,
      channelFactory: (_) => channel,
    );
    final chat = ChatStore(clientFor: (_) => client);
    await client.connect();
    chat.watchSession('daemon', 's');
    await until(() async => chat.historyStatusFor('s') == HistoryStatus.failed);
    expect(
      chat.eventsFor('s').whereType<UserMessageEvent>().single.text,
      'Question',
    );
    expect(chat.isSavedHistory('s'), isTrue);
    channel.failHistory = false;
    chat.retryHistory('daemon', 's');
    expect(chat.eventsFor('s'), isNotEmpty);
    await until(
      () async =>
          chat.historyStatusFor('s') == HistoryStatus.ready &&
          !chat.isCatchingUp('s'),
    );
    expect(chat.eventsFor('s').whereType<UserMessageEvent>(), hasLength(1));
    expect(
      chat.eventsFor('s').whereType<AgentMessageChunkEvent>().single.text,
      'Answer',
    );
    chat.dispose();
    await client.dispose();
  });

  test('persists across instances, isolates daemons, serializes writes and rewinds', () async {
    final cache = LocalHistory('a');
    final first = cache.merge('s', [
      const UserMessageEvent(text: 'old', seq: 1),
      const AgentMessageChunkEvent(text: 'old reply', seq: 2),
    ], watermark: 2);
    final second = cache.merge('s', [
      const HistoryRewoundEvent(beforeSeq: 1, seq: 3),
    ], watermark: 3);
    await Future.wait([first, second]);
    await cache.merge('s', [
      const UserMessageEvent(text: 'stale page', seq: 1),
    ]);
    final restored = await LocalHistory('a').read('s');
    expect(restored!.events.single, isA<HistoryRewoundEvent>());
    expect(restored.watermark, 3);
    expect(await LocalHistory('b').read('s'), isNull);
    await cache.remove('s');
    expect(await cache.read('s'), isNull);
  });

  test(
    'reconnect reconciles missed rewinds without duplicating saved replies',
    () async {
      final cache = LocalHistory('daemon');
      await cache.merge('s', [
        const UserMessageEvent(text: 'Removed question', seq: 1),
        const AgentMessageChunkEvent(text: 'Removed reply', seq: 2),
        const TurnCompleteEvent(stopReason: 'end_turn', seq: 3),
      ], watermark: 3);
      final channel = _Channel();
      channel.events
        ..clear()
        ..addAll([
          const HistoryRewoundEvent(beforeSeq: 1, seq: 4),
          const UserMessageEvent(text: 'Replacement question', seq: 5),
          const AgentMessageChunkEvent(text: 'Replacement reply', seq: 6),
          const TurnCompleteEvent(stopReason: 'end_turn', seq: 7),
        ]);
      final client = WsDaemonClient(
        url: 'ws://test/ws',
        localHistory: cache,
        channelFactory: (_) => channel,
      );
      final chat = ChatStore(clientFor: (_) => client);
      chat.watchSession('daemon', 's');
      await until(
        () async => chat.historyStatusFor('s') == HistoryStatus.ready,
      );
      expect(
        chat.eventsFor('s').whereType<AgentMessageChunkEvent>().single.text,
        'Removed reply',
      );
      await client.connect();
      await until(() async => (await cache.read('s'))?.watermark == 7);
      await until(
        () async =>
            chat
                .eventsFor('s')
                .whereType<AgentMessageChunkEvent>()
                .singleOrNull
                ?.text ==
            'Replacement reply',
      );
      chat.dispose();
      await client.dispose();
      final events = (await LocalHistory('daemon').read('s'))!.events;
      expect(
        events.whereType<UserMessageEvent>().single.text,
        'Replacement question',
      );
      expect(
        events.whereType<AgentMessageChunkEvent>().single.text,
        'Replacement reply',
      );
    },
  );

  test('unopened sessions and completed turns survive offline restart and paginate', () async {
    final channel = _Channel();
    final cache = LocalHistory('daemon');
    final online = WsDaemonClient(
      url: 'ws://test/ws',
      localHistory: cache,
      channelFactory: (_) => channel,
    );
    await online.connect();
    await until(() async => (await cache.read('s'))?.watermark == 3);
    channel.emit(const UserMessageEvent(text: 'Second question', seq: 4));
    channel.emit(const AgentMessageChunkEvent(text: 'Second answer', seq: 5));
    channel.emit(const TurnCompleteEvent(stopReason: 'end_turn', seq: 6));
    await until(() async => (await cache.read('s'))?.watermark == 6);
    await online.dispose();

    final offline = WsDaemonClient(
      url: 'ws://test/ws',
      localHistory: LocalHistory('daemon'),
    );
    final chat = ChatStore(clientFor: (_) => offline, historyPageSize: 3);
    addTearDown(chat.dispose);
    addTearDown(offline.dispose);
    expect((await offline.listSessions()).single.title, 'Offline conversation');
    chat.watchSession('daemon', 's');
    await until(() async => chat.historyStatusFor('s') == HistoryStatus.ready);
    expect(
      chat.eventsFor('s').whereType<AgentMessageChunkEvent>().single.text,
      'Second answer',
    );
    await chat.loadOlderHistory('daemon', 's');
    expect(
      chat.eventsFor('s').whereType<UserMessageEvent>().map((e) => e.text),
      ['Question', 'Second question'],
    );
    expect(
      chat
          .eventsFor('s')
          .whereType<AgentMessageChunkEvent>()
          .map((e) => e.text),
      ['Answer', 'Second answer'],
    );
  });
}
