@TestOn('vm')
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/acp/acp_types.dart';
import 'package:speeddial_daemon/src/agents/agent_client.dart';
import 'package:speeddial_daemon/src/ante/ante_client.dart';
import 'package:test/test.dart';

String fakeAnteScript() => <String>[
  p.join(Directory.current.path, 'test', 'fixtures', 'fake_ante_agent.dart'),
  p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'fake_ante_agent.dart',
  ),
].firstWhere((String path) => File(path).existsSync());

AnteClient spawnAnte({
  AgentPermissionHandler? requestPermission,
  Map<String, String>? environment,
}) {
  final String script = fakeAnteScript();
  return AnteClient.spawn(
    <String>[Platform.resolvedExecutable, script, 'serve'],
    cwd: Directory.current.path,
    catalogCommand: <String>[Platform.resolvedExecutable, script, 'catalog'],
    environment: environment,
    requestPermission: requestPermission,
  );
}

List<Map<String, Object?>> textBlocks(String text) => <Map<String, Object?>>[
  <String, Object?>{'type': 'text', 'text': text},
];

void main() {
  test('starts a session and exposes Ante model and effort options', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);

    final InitializeResult initialized = await client.initialized;
    expect(initialized.agentCapabilities['loadSession'], isTrue);
    expect(initialized.agentCapabilities['mcpServers'], isTrue);

    final created = await client.newSession(cwd: Directory.current.path);
    expect(created.sessionId, startsWith('ses_'));
    final AcpConfigOption model = created.configOptions.firstWhere(
      (AcpConfigOption option) => option.id == 'model',
    );
    expect(model.currentValue, 'fake-model');
    expect(model.options.map((AcpConfigOptionValue item) => item.value), [
      'fake-model',
      'fake-large',
    ]);
    final AcpConfigOption effort = created.configOptions.firstWhere(
      (AcpConfigOption option) => option.id == 'thinking',
    );
    expect(effort.currentValue, 'medium');
    expect(effort.options.map((AcpConfigOptionValue item) => item.value), [
      'min',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
  });

  test('seeds new sessions with the Ante settings default model', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'ante_defaults_test',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final Directory anteHome = Directory(p.join(tempDir.path, 'ante'));
    await anteHome.create();
    await File(p.join(anteHome.path, 'settings.json')).writeAsString(
      jsonEncode(<String, Object?>{
        'model': 'gemma-4-31b',
        'provider': 'cerebras',
      }),
    );

    // `ante serve` ignores settings defaults when StartSession carries no
    // model, resolving the subscription instead. SpeedDial must reseed them.
    final AnteClient client = spawnAnte(
      environment: <String, String>{'ANTE_HOME': anteHome.path},
    );
    addTearDown(client.dispose);
    final created = await client.newSession(
      cwd: Directory.current.path,
      mcpServers: <Map<String, Object?>>[
        <String, Object?>{'name': 'managed', 'command': 'managed-mcp'},
      ],
    );
    final AcpConfigOption model = created.configOptions.firstWhere(
      (AcpConfigOption option) => option.id == 'model',
    );
    expect(model.currentValue, 'gemma-4-31b');
  });

  test(
    'projects managed MCP servers into transient homes for start and resume',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'ante_mcp_home_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final Directory anteHome = Directory(p.join(tempDir.path, 'ante'));
      await anteHome.create();
      await File(p.join(anteHome.path, 'settings.json')).writeAsString(
        jsonEncode(<String, Object?>{
          'short_prompt': true,
          'mcp_servers': <String, Object?>{
            'native': <String, Object?>{
              'command': 'native-mcp',
              'args': <String>['--native'],
            },
          },
        }),
      );
      final File sharedMarker = File(p.join(anteHome.path, 'sessions', 'keep'));
      await sharedMarker.parent.create();
      await sharedMarker.writeAsString('preserved');
      final File report = File(p.join(tempDir.path, 'profile-report.json'));
      final File homeReport = File('${report.path}.home');

      Future<Map<String, Object?>> capture({
        required bool resume,
        required String managedName,
      }) async {
        if (await report.exists()) await report.delete();
        if (await homeReport.exists()) await homeReport.delete();
        final AnteClient client = spawnAnte(
          environment: <String, String>{
            'ANTE_HOME': anteHome.path,
            'FAKE_ANTE_PROFILE_REPORT': report.path,
          },
        );
        String? transientHome;
        try {
          final List<Map<String, Object?>> servers = <Map<String, Object?>>[
            <String, Object?>{
              'name': managedName,
              'command': 'managed-mcp',
              'args': <String>['--managed'],
              'env': <Object?>[
                <String, Object?>{'name': 'MCP_TOKEN', 'value': 'secret'},
              ],
            },
          ];
          if (resume) {
            await client.loadSession(
              sessionId: 'ses_01M0H000000000000000000000',
              cwd: Directory.current.path,
              mcpServers: servers,
            );
          } else {
            await client.newSession(
              cwd: Directory.current.path,
              mcpServers: servers,
            );
          }
          for (var attempt = 0; attempt < 50; attempt++) {
            if (await report.exists() && await homeReport.exists()) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            await report.exists() && await homeReport.exists(),
            isTrue,
            reason: 'Ante must be able to read its MCP home after SessionStart',
          );
          transientHome = await homeReport.readAsString();
          expect(transientHome, isNot(anteHome.path));
        } finally {
          await client.dispose();
        }
        expect(transientHome, isNotNull);
        expect(await Directory(transientHome).exists(), isFalse);
        return Map<String, Object?>.from(
          jsonDecode(await report.readAsString()) as Map,
        );
      }

      for (final (bool resume, String managedName) in <(bool, String)>[
        (false, 'created'),
        (true, 'resumed'),
      ]) {
        final Map<String, Object?> captured = await capture(
          resume: resume,
          managedName: managedName,
        );
        expect(captured['short_prompt'], isTrue);
        final Map<String, Object?> servers = Map<String, Object?>.from(
          captured['mcp_servers']! as Map,
        );
        expect(servers['native'], <String, Object?>{
          'command': 'native-mcp',
          'args': <Object?>['--native'],
        });
        expect(servers[managedName], <String, Object?>{
          'command': 'managed-mcp',
          'args': <Object?>['--managed'],
          'env': <String, Object?>{'MCP_TOKEN': 'secret'},
        });
      }
      expect(await sharedMarker.readAsString(), 'preserved');
    },
  );

  test('maps rich turn events and resolves Ante approval decisions', () async {
    List<PermissionOptionData>? offered;
    final AnteClient client = spawnAnte(
      requestPermission:
          (
            String sessionId,
            String? toolCallId,
            String title,
            List<PermissionOptionData> options,
          ) async {
            offered = options;
            expect(toolCallId, 'tool-1');
            expect(title, 'Allow reading the file?');
            return 'AcceptForSession';
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
      textBlocks('normal'),
    );
    expect(result.stopReason, 'end_turn');
    expect(
      offered?.map((PermissionOptionData option) => option.optionId),
      containsAll(<String>[
        'Accept',
        'AcceptForSession',
        'AcceptAlways',
        'Skip',
        'Abort',
      ]),
    );

    final String message = updates
        .whereType<AcpAgentMessageChunk>()
        .map((AcpAgentMessageChunk update) => update.text)
        .join();
    expect(message, 'Hello world');
    expect(
      updates.whereType<AcpAgentThoughtChunk>().single.text,
      'Considering',
    );
    final AcpToolCall toolCall = updates.whereType<AcpToolCall>().single;
    expect(toolCall.toolCall.rawInput['file_path'], '/tmp/example.dart');
    expect(toolCall.toolCall.locations.single.path, '/tmp/example.dart');
    final List<AcpToolCallUpdate> toolUpdates = updates
        .whereType<AcpToolCallUpdate>()
        .toList();
    expect(toolUpdates, hasLength(2));
    expect(
      (toolUpdates.last.fields['rawOutput'] as Map)['content'],
      'file contents',
    );
    final List<Object?> terminalContent =
        toolUpdates.last.fields['content']! as List<Object?>;
    final Map<String, Object?> terminalBlock = Map<String, Object?>.from(
      terminalContent.single! as Map,
    );
    expect((terminalBlock['content'] as Map)['text'], 'file contents');

    final AcpUsageUpdate usage = updates.whereType<AcpUsageUpdate>().single;
    expect(usage.inputTokens, 120);
    expect(usage.outputTokens, 30);
    expect(usage.cacheReadTokens, 80);
    expect(usage.cacheCreationTokens, 5);
    expect(usage.used, 4096);
    expect(usage.size, 200000);

    final List<AcpAgentActivityUpdate> activities = updates
        .whereType<AcpAgentActivityUpdate>()
        .toList();
    expect(
      activities.map((AcpAgentActivityUpdate update) => update.kind),
      containsAll(<String>['session', 'extensions', 'info']),
    );
    final AcpAgentActivityUpdate extensions = activities.lastWhere(
      (AcpAgentActivityUpdate update) => update.kind == 'extensions',
    );
    expect(extensions.details, contains('  read_file'));
    final AcpAgentActivityUpdate warmup = activities.lastWhere(
      (AcpAgentActivityUpdate update) => update.id == 'warmup',
    );
    expect(warmup.status, 'completed');
    expect(warmup.details, ['Ready']);
  });

  test('preserves image tool result blocks for the session engine', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);
    final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
    final StreamSubscription<AcpSessionUpdate> subscription = client
        .sessionUpdates(created.sessionId)
        .listen(updates.add);
    addTearDown(subscription.cancel);

    final PromptResult result = await client.prompt(
      created.sessionId,
      textBlocks('view image'),
    );
    expect(result.stopReason, 'end_turn');
    final AcpToolCall started = updates.whereType<AcpToolCall>().single;
    expect(started.toolCall.kind, 'read');

    final AcpToolCallUpdate completed = updates
        .whereType<AcpToolCallUpdate>()
        .single;
    final List<Object?> content = completed.fields['content']! as List<Object?>;
    expect(content, hasLength(2));
    final Map<Object?, Object?> image =
        (content.last! as Map<Object?, Object?>)['content']!
            as Map<Object?, Object?>;
    expect(image['type'], 'image');
    expect(image['mimeType'], 'image/png');
    expect(
      image['data'],
      isA<String>().having((String data) => data, 'data', isNotEmpty),
    );
  });

  test('normalizes TodoWrite calls into shared plan updates', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);
    final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
    final StreamSubscription<AcpSessionUpdate> subscription = client
        .sessionUpdates(created.sessionId)
        .listen(updates.add);
    addTearDown(subscription.cancel);

    final PromptResult result = await client.prompt(
      created.sessionId,
      textBlocks('write todos'),
    );

    expect(result.stopReason, 'end_turn');
    expect(updates.whereType<AcpToolCall>(), isEmpty);
    expect(updates.whereType<AcpToolCallUpdate>(), isEmpty);
    final AcpPlan plan = updates.whereType<AcpPlan>().single;
    expect(plan.entries.map((AcpPlanEntry entry) => entry.content), <String>[
      'Inspect the provider adapter',
      'Normalize TodoWrite updates',
      'Verify the shared plan UI',
    ]);
    expect(plan.entries.map((AcpPlanEntry entry) => entry.status), <String>[
      'completed',
      'in_progress',
      'pending',
    ]);
    expect(
      plan.entries.map((AcpPlanEntry entry) => entry.priority),
      everyElement('medium'),
    );
  });

  test(
    'flattens text resources and materializes images into Ante UserInput',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'ante_attachment_test',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final File report = File(p.join(tempDir.path, 'user-input.txt'));
      final AnteClient client = spawnAnte(
        environment: <String, String>{
          'FAKE_ANTE_USER_INPUT_REPORT': report.path,
        },
        requestPermission: (
          String sessionId,
          String? toolCallId,
          String title,
          List<PermissionOptionData> options,
        ) async => 'Accept',
      );
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);

      final PromptResult result = await client.prompt(
        created.sessionId,
        <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': 'Review these files.'},
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
        ],
      );

      expect(result.stopReason, 'end_turn');
      final String input = await report.readAsString();
      expect(
        input,
        startsWith(
          'Review these files.\n\n'
          '[Attached resource: speeddial-attachment:///att-1/notes.txt]\n'
          'alpha\nbeta\n\n'
          '[Attached image]\n@',
        ),
      );
      final RegExpMatch? pathMatch = RegExp(r'\[Attached image\]\n@([^\r\n]+)$')
          .firstMatch(input);
      expect(pathMatch, isNotNull);
      final File image = File(pathMatch!.group(1)!);
      expect(image.path, endsWith('.png'));
      expect(await image.readAsBytes(), <int>[105]);
      final Directory imageDirectory = image.parent;
      expect(await imageDirectory.exists(), isTrue);

      await client.dispose();
      expect(await imageDirectory.exists(), isFalse);
    },
  );

  test(
    'maps provider turn errors without treating them as completion',
    () async {
      final AnteClient client = spawnAnte();
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);

      await expectLater(
        client.prompt(created.sessionId, textBlocks('error')),
        throwsA(
          isA<AnteTurnException>().having(
            (AnteTurnException error) => error.message,
            'message',
            contains('Provider failed: bad credentials'),
          ),
        ),
      );
    },
  );

  test('drops resumed history replay before the next live turn', () async {
    final AnteClient client = spawnAnte(
      requestPermission: (
        String sessionId,
        String? toolCallId,
        String title,
        List<PermissionOptionData> options,
      ) async => 'Accept',
    );
    addTearDown(client.dispose);
    final List<AcpConfigOption> options = await client.loadSession(
      sessionId: 'ses_01M0H000000000000000000000',
      cwd: Directory.current.path,
    );
    expect(options, isNotEmpty);

    final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
    final StreamSubscription<AcpSessionUpdate> subscription = client
        .sessionUpdates('ses_01M0H000000000000000000000')
        .listen(updates.add);
    addTearDown(subscription.cancel);
    final PromptResult result = await client.prompt(
      'ses_01M0H000000000000000000000',
      textBlocks('normal'),
    );
    expect(result.stopReason, 'end_turn');
    final String message = updates
        .whereType<AcpAgentMessageChunk>()
        .map((AcpAgentMessageChunk update) => update.text)
        .join();
    expect(message, 'Hello world');
    expect(message, isNot(contains('replayed')));
  });
}
