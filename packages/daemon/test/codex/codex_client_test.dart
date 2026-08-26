@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/acp/acp_types.dart';
import 'package:speeddial_daemon/src/agents/agent_client.dart';
import 'package:speeddial_daemon/src/codex/codex_client.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

String fakeCodexScript() => <String>[
  p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'fake_codex_app_server.dart',
  ),
  p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'fake_codex_app_server.dart',
  ),
].firstWhere((String path) => File(path).existsSync());

CodexClient spawnCodex({
  AgentPermissionHandler? requestPermission,
  Map<String, String>? environment,
}) => CodexClient.spawn(
  <String>[Platform.resolvedExecutable, fakeCodexScript()],
  cwd: Directory.current.path,
  environment: environment,
  requestPermission: requestPermission,
);

List<Map<String, Object?>> textBlocks(String text) => <Map<String, Object?>>[
  <String, Object?>{'type': 'text', 'text': text},
];

Future<Map<String, Object?>> readJsonMap(File file) async =>
    Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map);

void main() {
  test(
    'starts and resumes native threads with models and managed MCP',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'codex_client_start_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File startReport = File(p.join(tempDir.path, 'start.json'));
      final File resumeReport = File(p.join(tempDir.path, 'resume.json'));
      final File turnReport = File(p.join(tempDir.path, 'turn.json'));
      final CodexClient client = spawnCodex(
        environment: <String, String>{
          'FAKE_CODEX_START_REPORT': startReport.path,
        },
      );
      addTearDown(client.dispose);

      final InitializeResult initialized = await client.initialized;
      expect(initialized.protocolVersion, 2);
      expect(initialized.agentCapabilities['loadSession'], isTrue);
      expect(initialized.agentCapabilities['mcpServers'], isTrue);

      final created = await client.newSession(
        cwd: Directory.current.path,
        model: 'gpt-test',
        yolo: true,
        mcpServers: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'speeddial',
            'command': 'dart',
            'args': <String>['run', 'mcp.dart'],
            'env': <Object?>[
              <String, Object?>{'name': 'TOKEN', 'value': 'secret'},
            ],
          },
        ],
      );
      expect(created.sessionId, startsWith('thr_fake_'));
      final AcpConfigOption model = created.configOptions.firstWhere(
        (AcpConfigOption option) => option.id == 'model',
      );
      expect(model.currentValue, 'gpt-test');
      expect(model.options.map((AcpConfigOptionValue value) => value.value), [
        'gpt-test',
        'gpt-fast',
      ]);
      final AcpConfigOption thinking = created.configOptions.firstWhere(
        (AcpConfigOption option) => option.id == 'thinking',
      );
      expect(thinking.currentValue, 'medium');
      expect(
        thinking.options.map((AcpConfigOptionValue value) => value.value),
        <String>['low', 'medium', 'high'],
      );

      final Map<String, Object?> start = await readJsonMap(startReport);
      expect(start['sandbox'], 'danger-full-access');
      expect(start['approvalPolicy'], 'never');
      final Map<String, Object?> config = Map<String, Object?>.from(
        start['config']! as Map,
      );
      final Map<String, Object?> servers = Map<String, Object?>.from(
        config['mcp_servers']! as Map,
      );
      expect(servers['speeddial'], <String, Object?>{
        'command': 'dart',
        'args': <Object?>['run', 'mcp.dart'],
        'env': <String, Object?>{'TOKEN': 'secret'},
      });

      final List<AcpConfigOption> changed = await client.setConfigOption(
        created.sessionId,
        'model',
        'gpt-fast',
      );
      expect(
        changed
            .firstWhere((AcpConfigOption option) => option.id == 'model')
            .currentValue,
        'gpt-fast',
      );
      final AcpConfigOption fastThinking = changed.firstWhere(
        (AcpConfigOption option) => option.id == 'thinking',
      );
      expect(fastThinking.currentValue, 'low');
      expect(fastThinking.options.single.value, 'low');

      await client.dispose();
      final CodexClient resumed = spawnCodex(
        environment: <String, String>{
          'FAKE_CODEX_RESUME_REPORT': resumeReport.path,
          'FAKE_CODEX_TURN_REPORT': turnReport.path,
        },
      );
      addTearDown(resumed.dispose);
      final List<AcpConfigOption> resumedOptions = await resumed.loadSession(
        sessionId: created.sessionId,
        cwd: Directory.current.path,
        yolo: true,
      );
      expect(
        resumedOptions
            .firstWhere((AcpConfigOption option) => option.id == 'model')
            .currentValue,
        'gpt-test',
      );
      final Map<String, Object?> resume = await readJsonMap(resumeReport);
      expect(resume['sandbox'], 'danger-full-access');
      expect(resume['approvalPolicy'], 'never');

      await resumed.prompt(created.sessionId, textBlocks('resumed yolo turn'));
      final Map<String, Object?> turn = await readJsonMap(turnReport);
      expect(turn['approvalPolicy'], 'never');
    },
  );

  test('legacy sandbox choices cannot re-enable the Codex sandbox', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'codex_client_sandbox_test',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final File startReport = File(p.join(tempDir.path, 'start.json'));
    final File resumeReport = File(p.join(tempDir.path, 'resume.json'));
    final CodexClient client = spawnCodex(
      environment: <String, String>{
        'FAKE_CODEX_START_REPORT': startReport.path,
      },
    );
    addTearDown(client.dispose);

    final created = await client.newSession(
      cwd: Directory.current.path,
      sandboxMode: SessionSandboxMode.workspaceWrite,
    );
    expect((await readJsonMap(startReport))['sandbox'], 'danger-full-access');

    await client.dispose();
    final CodexClient resumed = spawnCodex(
      environment: <String, String>{
        'FAKE_CODEX_RESUME_REPORT': resumeReport.path,
      },
    );
    addTearDown(resumed.dispose);
    await resumed.loadSession(
      sessionId: created.sessionId,
      cwd: Directory.current.path,
      sandboxMode: SessionSandboxMode.workspaceWrite,
    );
    expect((await readJsonMap(resumeReport))['sandbox'], 'danger-full-access');
  });

  test(
    'maps native rich items and resolves exact approval decisions',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'codex_client_turn_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File approvalReport = File(p.join(tempDir.path, 'approval.json'));
      List<PermissionOptionData>? offered;
      final CodexClient client = spawnCodex(
        environment: <String, String>{
          'FAKE_CODEX_APPROVAL_REPORT': approvalReport.path,
        },
        requestPermission:
            (
              String sessionId,
              String? toolCallId,
              String title,
              List<PermissionOptionData> options,
            ) async {
              expect(sessionId, startsWith('thr_fake_'));
              expect(toolCallId, 'command-1');
              expect(title, contains('dart test'));
              expect(title, contains('Run the regression suite'));
              offered = options;
              return 'acceptWithExecpolicyAmendment';
            },
      );
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);
      final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
      final StreamSubscription<AcpSessionUpdate> subscription = client
          .sessionUpdates(created.sessionId)
          .listen(updates.add);
      addTearDown(subscription.cancel);

      final PromptResult result = await client.prompt(
        created.sessionId,
        textBlocks('Exercise rich events'),
      );
      expect(result.stopReason, 'end_turn');
      expect(
        offered?.map((PermissionOptionData option) => option.optionId),
        containsAll(<String>[
          'accept',
          'acceptForSession',
          'acceptWithExecpolicyAmendment',
          'decline',
          'cancel',
        ]),
      );
      expect(await readJsonMap(approvalReport), <String, Object?>{
        'decision': <String, Object?>{
          'acceptWithExecpolicyAmendment': <String, Object?>{
            'execpolicy_amendment': <Object?>['dart', 'test'],
          },
        },
      });

      expect(
        updates
            .whereType<AcpAgentMessageChunk>()
            .map((AcpAgentMessageChunk update) => update.text)
            .join(),
        'Hello Codex',
      );
      expect(
        updates
            .whereType<AcpAgentThoughtChunk>()
            .map((AcpAgentThoughtChunk update) => update.text)
            .join(),
        'Thinking',
      );
      final AcpPlan plan = updates.whereType<AcpPlan>().single;
      expect(plan.entries.map((AcpPlanEntry entry) => entry.content), [
        'Inspect',
        'Edit',
      ]);
      expect(plan.entries.last.status, 'in_progress');

      final List<AcpToolCall> started = updates
          .whereType<AcpToolCall>()
          .toList();
      expect(
        started.map((AcpToolCall update) => update.toolCall.id),
        containsAll(<String>[
          'command-1',
          'patch-1',
          'delete-1',
          'dynamic-1',
          'mcp-1',
          'collab-1',
          'search-1',
          'image-1',
        ]),
      );
      final AcpToolCall moved = started.singleWhere(
        (AcpToolCall update) => update.toolCall.id == 'patch-1',
      );
      expect(moved.toolCall.kind, 'move');
      expect(
        moved.toolCall.locations.map(
          (AcpToolCallLocation location) => location.path,
        ),
        <String>['lib/main.dart', 'lib/renamed.dart'],
      );
      expect(
        started
            .singleWhere(
              (AcpToolCall update) => update.toolCall.id == 'delete-1',
            )
            .toolCall
            .kind,
        'delete',
      );
      final AcpToolCallUpdate command = updates
          .whereType<AcpToolCallUpdate>()
          .lastWhere(
            (AcpToolCallUpdate update) => update.toolCallId == 'command-1',
          );
      expect(command.fields['status'], 'completed');
      expect(
        ((command.fields['content']! as List<Object?>).single as Map)['output'],
        'All tests passed\n',
      );
      final AcpToolCallUpdate commandProgress = updates
          .whereType<AcpToolCallUpdate>()
          .firstWhere(
            (AcpToolCallUpdate update) => update.toolCallId == 'command-1',
          );
      expect(commandProgress.fields['status'], 'in_progress');
      expect(commandProgress.fields, isNot(contains('content')));
      final AcpToolCallUpdate patch = updates
          .whereType<AcpToolCallUpdate>()
          .lastWhere(
            (AcpToolCallUpdate update) => update.toolCallId == 'patch-1',
          );
      final Map<Object?, Object?> patchContent =
          (patch.fields['content']! as List<Object?>).single as Map;
      expect(patchContent['type'], 'patch');
      expect(patchContent['path'], 'lib/main.dart');
      expect(patchContent['diff'], '@@ -1 +1 @@\n-old\n+new');
      final AcpToolCallUpdate dynamic = updates
          .whereType<AcpToolCallUpdate>()
          .lastWhere(
            (AcpToolCallUpdate update) => update.toolCallId == 'dynamic-1',
          );
      final Map<Object?, Object?> dynamicContent =
          (dynamic.fields['content']! as List<Object?>).single as Map;
      expect(dynamicContent['type'], 'content');
      expect(
        (dynamicContent['content']! as Map<Object?, Object?>)['text'],
        'pubspec contents',
      );
      final AcpToolCallUpdate collab = updates
          .whereType<AcpToolCallUpdate>()
          .lastWhere(
            (AcpToolCallUpdate update) => update.toolCallId == 'collab-1',
          );
      expect(
        ((collab.fields['content']! as List<Object?>).single
            as Map<Object?, Object?>)['content'],
        isA<Map<Object?, Object?>>().having(
          (Map<Object?, Object?> content) => content['text'],
          'text',
          allOf(contains('thr_child'), contains('completed')),
        ),
      );

      final AcpUsageUpdate usage = updates.whereType<AcpUsageUpdate>().single;
      expect(usage.size, 200000);
      expect(usage.used, 150);
      expect(usage.inputTokens, 500);
      expect(usage.outputTokens, 100);
      expect(usage.cacheReadTokens, 400);
      expect(usage.cacheCreationTokens, 7);
      final List<AcpAgentActivityUpdate> activities = updates
          .whereType<AcpAgentActivityUpdate>()
          .toList();
      expect(
        activities.map((AcpAgentActivityUpdate update) => update.kind),
        containsAll(<String>['mcp', 'compaction', 'model', 'subagent']),
      );
    },
  );

  test(
    'maps text, image, and audio attachments to native input items',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'codex_client_attachment_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File inputReport = File(p.join(tempDir.path, 'input.json'));
      final CodexClient client = spawnCodex(
        environment: <String, String>{
          'FAKE_CODEX_INPUT_REPORT': inputReport.path,
        },
        requestPermission: (
          String sessionId,
          String? toolCallId,
          String title,
          List<PermissionOptionData> options,
        ) async => 'accept',
      );
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);

      final PromptResult result = await client.prompt(
        created.sessionId,
        <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': 'Review attachments.'},
          <String, Object?>{
            'type': 'resource',
            'resource': <String, Object?>{
              'uri': 'speeddial-attachment:///att-1/notes.txt',
              'mimeType': 'text/plain',
              'text': 'alpha\nbeta',
            },
          },
          <String, Object?>{
            'type': 'image',
            'mimeType': 'image/png',
            'data': 'aQ==',
          },
          <String, Object?>{
            'type': 'resource',
            'resource': <String, Object?>{
              'uri': 'speeddial-attachment:///att-2/voice.wav',
              'mimeType': 'audio/wav',
              'blob': 'UklGRg==',
            },
          },
        ],
      );
      expect(result.stopReason, 'end_turn');
      final List<Object?> inputs =
          jsonDecode(await inputReport.readAsString()) as List<Object?>;
      expect(inputs, hasLength(4));
      final List<Map<String, Object?>> mapped = inputs
          .map((Object? value) => Map<String, Object?>.from(value! as Map))
          .toList();
      expect(mapped[0], <String, Object?>{
        'type': 'text',
        'text': 'Review attachments.',
      });
      expect(mapped[1]['type'], 'text');
      expect(mapped[1]['text'], contains('<attached_file name="notes.txt">'));
      expect(mapped[1]['text'], contains('alpha\nbeta'));
      expect(mapped[2], <String, Object?>{
        'type': 'image',
        'url': 'data:image/png;base64,aQ==',
      });
      expect(mapped[3], <String, Object?>{
        'type': 'audio',
        'url': 'data:audio/wav;base64,UklGRg==',
      });
    },
  );

  test('cancels while turn/start is still in flight', () async {
    final CodexClient client = spawnCodex();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);

    final Future<PromptResult> prompt = client.prompt(
      created.sessionId,
      textBlocks('delay turn start and wait for cancel'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await client.cancel(created.sessionId).timeout(const Duration(seconds: 2));

    expect(
      await prompt.timeout(const Duration(seconds: 2)),
      isA<PromptResult>().having(
        (PromptResult result) => result.stopReason,
        'stopReason',
        'cancelled',
      ),
    );
  });

  test('dispose fails an in-flight prompt instead of hanging', () async {
    final CodexClient client = spawnCodex();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);
    final Future<PromptResult> prompt = client.prompt(
      created.sessionId,
      textBlocks('delay turn start and wait for cancel'),
    );
    final Future<void> expectation = expectLater(
      prompt.timeout(const Duration(seconds: 2)),
      throwsA(isA<StateError>()),
    );

    await Future<void>.delayed(const Duration(milliseconds: 10));
    await client.dispose();
    await expectation;
  });

  test('surfaces failed native turns', () async {
    final CodexClient client = spawnCodex();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);

    await expectLater(
      client.prompt(created.sessionId, textBlocks('fail turn')),
      throwsA(
        isA<CodexTurnException>().having(
          (CodexTurnException error) => error.message,
          'message',
          contains('Provider failed: bad credentials'),
        ),
      ),
    );
  });
}
