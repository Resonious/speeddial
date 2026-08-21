import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  final timestamp = DateTime.utc(2026, 8, 18, 14, 30, 15, 250);

  final toolCall = ToolCall(
    id: 'tc_1234567890abcde',
    title: 'Edit rpc.dart',
    kind: 'edit',
    status: ToolCallStatus.running,
    content: [
      ToolCallText(text: 'Rewriting'),
      ToolCallDiff(path: 'lib/src/rpc.dart', oldText: 'a', newText: 'b'),
    ],
    locations: const ['lib/src/rpc.dart'],
  );

  final planEntries = [
    PlanEntry(
      content: 'Implement RpcPeer',
      priority: PlanPriority.high,
      status: PlanEntryStatus.inProgress,
    ),
    PlanEntry(
      content: 'Ship it',
      priority: PlanPriority.low,
      status: PlanEntryStatus.pending,
    ),
  ];

  final permissionRequest = PermissionRequest(
    requestId: 'req_abcdefghijklmno',
    toolCallId: 'tc_1234567890abcde',
    title: 'Allow?',
    options: [
      PermissionOption(
        optionId: 'allow_once',
        name: 'Allow once',
        kind: PermissionKind.allowOnce,
      ),
      PermissionOption(
        optionId: 'reject_always',
        name: 'Always reject',
        kind: PermissionKind.rejectAlways,
      ),
    ],
  );

  final usage = UsageInfo(
    inputTokens: 100,
    outputTokens: 50,
    totalTokens: 150,
    cost: '0.0030',
    cacheReadTokens: 80,
    cacheCreationTokens: 20,
    contextUsedTokens: 4096,
    contextLimitTokens: 200000,
  );

  const activity = AgentActivity(
    id: 'ante-extensions-s1',
    kind: 'extensions',
    title: 'Extensions refreshed',
    status: AgentActivityStatus.completed,
    details: <String>['Skills: commit, review'],
  );

  const attachment = Attachment(
    id: 'att_1234567890abc',
    name: 'chart.png',
    mimeType: 'image/png',
    size: 128,
  );

  /// Every variant with seq/timestamp set, plus its expected `type` wire.
  final List<({SessionEvent event, String type})> allEvents = [
    (
      event: UserMessageEvent(text: 'hello', seq: 1, timestamp: timestamp),
      type: 'userMessage',
    ),
    (
      event: ImageEvent(attachment: attachment, seq: 2, timestamp: timestamp),
      type: 'image',
    ),
    (
      event: AgentMessageChunkEvent(text: 'Hi', seq: 2, timestamp: timestamp),
      type: 'agentMessageChunk',
    ),
    (
      event: AgentThoughtChunkEvent(
        text: 'considering',
        seq: 3,
        timestamp: timestamp,
      ),
      type: 'agentThoughtChunk',
    ),
    (
      event: ToolCallEvent(toolCall: toolCall, seq: 4, timestamp: timestamp),
      type: 'toolCall',
    ),
    (
      event: PlanEvent(entries: planEntries, seq: 5, timestamp: timestamp),
      type: 'plan',
    ),
    (
      event: PermissionRequestEvent(
        request: permissionRequest,
        seq: 6,
        timestamp: timestamp,
      ),
      type: 'permissionRequest',
    ),
    (
      event: PermissionResolvedEvent(
        requestId: 'req_abcdefghijklmno',
        optionId: 'allow_once',
        seq: 7,
        timestamp: timestamp,
      ),
      type: 'permissionResolved',
    ),
    (
      event: UsageEvent(usage: usage, seq: 8, timestamp: timestamp),
      type: 'usage',
    ),
    (
      event: AgentActivityEvent(
        activity: activity,
        seq: 9,
        timestamp: timestamp,
      ),
      type: 'agentActivity',
    ),
    (
      event: TurnCompleteEvent(
        stopReason: 'end_turn',
        seq: 9,
        timestamp: timestamp,
      ),
      type: 'turnComplete',
    ),
    (
      event: SessionErrorEvent(
        message: 'agent crashed',
        seq: 10,
        timestamp: timestamp,
      ),
      type: 'sessionError',
    ),
  ];

  test(
    'roundtrip: every variant preserves type, seq, timestamp, and fields',
    () {
      for (final entry in allEvents) {
        final event = entry.event;
        final json = event.toJson();
        expect(json['type'], entry.type);

        final decoded = SessionEvent.fromJson(json);
        expect(decoded.runtimeType, event.runtimeType);
        expect(decoded.seq, event.seq);
        expect(decoded.timestamp, event.timestamp);
        expect(decoded.toJson(), json);
      }
    },
  );

  test('roundtrip: client-constructed variants omit seq/timestamp', () {
    final variants = <SessionEvent>[
      UserMessageEvent(text: 'hi'),
      ImageEvent(attachment: attachment),
      AgentMessageChunkEvent(text: 'a'),
      AgentThoughtChunkEvent(text: 't'),
      ToolCallEvent(toolCall: toolCall),
      PlanEvent(entries: planEntries),
      PermissionRequestEvent(request: permissionRequest),
      PermissionResolvedEvent(requestId: 'r', optionId: 'o'),
      UsageEvent(usage: usage),
      AgentActivityEvent(activity: activity),
      TurnCompleteEvent(stopReason: 'cancelled'),
      SessionErrorEvent(message: 'boom'),
    ];
    for (final event in variants) {
      expect(event.seq, isNull);
      expect(event.timestamp, isNull);
      final json = event.toJson();
      expect(json.containsKey('seq'), isFalse);
      expect(json.containsKey('timestamp'), isFalse);
      final decoded = SessionEvent.fromJson(json);
      expect(decoded.seq, isNull);
      expect(decoded.timestamp, isNull);
      expect(decoded.toJson(), json);
    }
  });

  test('per-variant field checks', () {
    final user = SessionEvent.fromJson(const {
      'type': 'userMessage',
      'text': 'hello',
      'seq': 1,
      'timestamp': '2026-08-18T14:30:15.250Z',
    }) as UserMessageEvent;
    expect(user.text, 'hello');
    expect(user.seq, 1);
    expect(user.timestamp, DateTime.utc(2026, 8, 18, 14, 30, 15, 250));

    final image = SessionEvent.fromJson(const {
      'type': 'image',
      'attachment': {
        'id': 'att_1234567890abc',
        'name': 'chart.png',
        'mimeType': 'image/png',
        'size': 128,
      },
      'seq': 2,
    }) as ImageEvent;
    expect(image.attachment.name, 'chart.png');
    expect(image.attachment.mimeType, 'image/png');
    expect(user.timestamp!.isUtc, isTrue);

    final chunk = SessionEvent.fromJson(const {
      'type': 'agentMessageChunk',
      'text': 'delta',
    }) as AgentMessageChunkEvent;
    expect(chunk.text, 'delta');

    // Attachments ride the userMessage event as metadata only.
    const withAttachment = UserMessageEvent(
      text: 'look at this',
      attachments: [
        Attachment(
          id: 'att_1',
          name: 'shot.png',
          mimeType: 'image/png',
          size: 42,
        ),
      ],
    );
    final attachmentJson = withAttachment.toJson();
    expect(attachmentJson['attachments'], [
      {'id': 'att_1', 'name': 'shot.png', 'mimeType': 'image/png', 'size': 42},
    ]);
    final decodedUser =
        SessionEvent.fromJson(attachmentJson) as UserMessageEvent;
    expect(decodedUser.attachments, hasLength(1));
    expect(decodedUser.attachments.single.name, 'shot.png');
    expect(decodedUser.toJson(), attachmentJson);

    // No attachments: the key is omitted entirely, and parsing defaults to [].
    expect(const UserMessageEvent(text: 'hi').toJson()['attachments'], isNull);
    expect(decodedUser.text, 'look at this');
    expect(
      (SessionEvent.fromJson(const {
        'type': 'userMessage',
        'text': 'x',
      }) as UserMessageEvent).attachments,
      isEmpty,
    );
    final thought = SessionEvent.fromJson(const {
      'type': 'agentThoughtChunk',
      'text': 'hmm',
    }) as AgentThoughtChunkEvent;
    expect(thought.text, 'hmm');

    final tool = SessionEvent.fromJson({
      'type': 'toolCall',
      'toolCall': toolCall.toJson(),
    }) as ToolCallEvent;
    expect(tool.toolCall.id, 'tc_1234567890abcde');
    expect(tool.toolCall.status, ToolCallStatus.running);

    final plan = SessionEvent.fromJson(const {
      'type': 'plan',
      'entries': [
        {'content': 'a', 'priority': 'high', 'status': 'in_progress'},
      ],
    }) as PlanEvent;
    expect(plan.entries, hasLength(1));
    expect(plan.entries.single.status, PlanEntryStatus.inProgress);

    final permission = SessionEvent.fromJson(const {
      'type': 'permissionRequest',
      'request': {
        'requestId': 'r1',
        'toolCallId': null,
        'title': 'Allow?',
        'options': [
          {'optionId': 'o1', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      },
    }) as PermissionRequestEvent;
    expect(permission.request.requestId, 'r1');
    expect(permission.request.toolCallId, isNull);
    expect(permission.request.options.single.kind, PermissionKind.allowOnce);

    final resolved = SessionEvent.fromJson(const {
      'type': 'permissionResolved',
      'requestId': 'r1',
      'optionId': 'o1',
    }) as PermissionResolvedEvent;
    expect(resolved.requestId, 'r1');
    expect(resolved.optionId, 'o1');

    final usageEvent = SessionEvent.fromJson(const {
      'type': 'usage',
      'usage': {
        'inputTokens': 1,
        'outputTokens': 2,
        'totalTokens': 3,
        'cost': null,
      },
    }) as UsageEvent;
    expect(usageEvent.usage.totalTokens, 3);
    expect(usageEvent.usage.cost, isNull);
    expect(usageEvent.usage.contextUsedTokens, isNull);

    final activityEvent = SessionEvent.fromJson(const {
      'type': 'agentActivity',
      'activity': {
        'id': 'a1',
        'kind': 'compaction',
        'title': 'Compacting conversation',
        'status': 'running',
        'details': ['Summarizing history'],
      },
    }) as AgentActivityEvent;
    expect(activityEvent.activity.kind, 'compaction');
    expect(activityEvent.activity.status, AgentActivityStatus.running);
    expect(activityEvent.activity.details, ['Summarizing history']);

    final done = SessionEvent.fromJson(const {
      'type': 'turnComplete',
      'stopReason': 'max_tokens',
    }) as TurnCompleteEvent;
    expect(done.stopReason, 'max_tokens');

    final error = SessionEvent.fromJson(const {
      'type': 'sessionError',
      'message': 'kaboom',
    }) as SessionErrorEvent;
    expect(error.message, 'kaboom');
  });

  test('fromJson dispatches on type and rejects unknown types', () {
    for (final entry in allEvents) {
      final decoded = SessionEvent.fromJson(entry.event.toJson());
      expect(decoded, isA<SessionEvent>());
    }
    expect(
      () => SessionEvent.fromJson(const {'type': 'unknown'}),
      throwsFormatException,
    );
    expect(
      () => SessionEvent.fromJson(const {'type': 'toolCall'}),
      throwsA(isA<TypeError>()),
    );
  });

  test('missing timestamp field decodes to null', () {
    final event = SessionEvent.fromJson(const {
      'type': 'sessionError',
      'message': 'x',
      'seq': 3,
    }) as SessionErrorEvent;
    expect(event.seq, 3);
    expect(event.timestamp, isNull);
    expect(event.toJson(), const {
      'type': 'sessionError',
      'message': 'x',
      'seq': 3,
    });
  });

  group('ToolCallContent', () {
    test('text/diff/terminal roundtrip', () {
      final variants = <ToolCallContent>[
        const ToolCallText(text: 'plain output'),
        ToolCallDiff(path: 'a/b.dart', oldText: 'old', newText: 'new'),
        ToolCallDiff(path: 'new.dart', oldText: null, newText: 'entire file'),
        const ToolCallTerminal(terminalId: 'term-1', output: '\$ ls\\nlib\\n'),
      ];
      for (final content in variants) {
        final decoded = ToolCallContent.fromJson(content.toJson());
        expect(decoded.runtimeType, content.runtimeType);
        expect(decoded.toJson(), content.toJson());
      }
    });

    test('exact wire shapes', () {
      expect(const ToolCallText(text: 'x').toJson(), const {
        'type': 'text',
        'text': 'x',
      });
      expect(
        ToolCallDiff(path: 'p', oldText: null, newText: 'n').toJson(),
        const {'type': 'diff', 'path': 'p', 'oldText': null, 'newText': 'n'},
      );
      expect(
        const ToolCallTerminal(terminalId: 't', output: 'o').toJson(),
        const {'type': 'terminal', 'terminalId': 't', 'output': 'o'},
      );
    });

    test('unknown type throws FormatException', () {
      expect(
        () => ToolCallContent.fromJson(const {'type': 'image'}),
        throwsFormatException,
      );
    });
  });
}
