@TestOn('vm')
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/acp/acp_types.dart';
import 'package:speeddial_daemon/src/agents/agent_client.dart';
import 'package:speeddial_daemon/src/ante/ante_client.dart';
import 'package:speeddial_daemon/src/mcp/built_in_mcp_server.dart'
    show kSessionSummaryInstruction;
import 'package:speeddial_protocol/speeddial_protocol.dart';
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
  for (final resume in [false, true]) {
    for (final short in [false, true]) {
      for (final builtIn in [false, true]) {
        test(
          'title guidance (resume: $resume, short: $short, built-in: $builtIn)',
          () async {
            final home = await Directory.systemTemp.createTemp(
              'ante_title_test',
            );
            addTearDown(() => home.delete(recursive: true));
            final settings = File(p.join(home.path, 'work.settings.json'));
            final original = jsonEncode({
              'system_prompt': 'Custom base instructions',
              'append_system_prompt': 'Keep my appended instructions.',
            });
            await settings.writeAsString(original);
            final config = File(p.join(home.path, 'request.json'));
            final input = File(p.join(home.path, 'input.txt'));
            final client = spawnAnte(
              environment: {
                'ANTE_HOME': home.path,
                'ANTE_PROFILE': 'work',
                'FAKE_ANTE_SESSION_CONFIG_REPORT': config.path,
                'FAKE_ANTE_USER_INPUT_REPORT': input.path,
              },
            );
            addTearDown(client.dispose);
            final servers = <Map<String, Object?>>[
              {
                'name': builtIn ? 'speeddial' : 'another-server',
                'command': 'fake-mcp',
                'args': <String>[],
              },
            ];
            final String sessionId;
            if (resume) {
              sessionId = 'ses_01M0H000000000000000000000';
              await client.loadSession(
                sessionId: sessionId,
                cwd: home.path,
                mcpServers: servers,
                shortPrompt: short,
              );
            } else {
              sessionId = (await client.newSession(
                cwd: home.path,
                mcpServers: servers,
                shortPrompt: short,
              )).sessionId;
            }
            final request = jsonDecode(await config.readAsString()) as Map;
            if (builtIn && !resume) {
              expect(
                request['append_system_prompt'],
                'Keep my appended instructions.\n\n$kSessionSummaryInstruction',
              );
            } else {
              expect(request.containsKey('append_system_prompt'), isFalse);
            }
            expect(
              request.containsKey('system_prompt'),
              isFalse,
              reason: 'Never replace the configured base prompt',
            );
            for (final message in ['normal', 'A different task']) {
              await client.prompt(sessionId, textBlocks(message));
              final sent = await input.readAsString();
              if (builtIn && resume) {
                expect(
                  sent,
                  '<speeddial_context>\n$kSessionSummaryInstruction\n</speeddial_context>\n\n$message',
                );
              } else {
                expect(sent, message);
              }
            }
            expect(await settings.readAsString(), original);
          },
        );
      }
    }
  }

  test('native provider switch, fork and rewind round trip', () async {
    final turns = <String>[];
    final String script = fakeAnteScript();
    final client = AnteClient.spawn(
      <String>[Platform.resolvedExecutable, script, 'serve'],
      cwd: Directory.current.path,
      onTurnStarted: turns.add,
      catalogCommand: <String>[Platform.resolvedExecutable, script, 'catalog'],
    );
    addTearDown(client.dispose);
    final created = await client.newSession(
      cwd: Directory.current.path,
      yolo: true,
    );
    await client.prompt(created.sessionId, textBlocks('normal'));
    expect(turns, hasLength(1));
    final String child = await client.fork(created.sessionId);
    expect(child, isNot(created.sessionId));
    await client.rewind(created.sessionId, turns.single);
    await expectLater(
      client.rewind(created.sessionId, turns.single),
      throwsA(isA<AnteTurnException>()),
    );
    final options = await client.switchProvider(
      created.sessionId,
      'other-provider',
      model: 'fake-large',
    );
    expect(client.upstreamProvider, 'other-provider');
    expect(options.first.currentValue, 'other-provider/fake-large');
    await expectLater(
      client.switchProvider(created.sessionId, 'missing'),
      throwsA(isA<AnteTurnException>()),
    );
    expect(client.upstreamProvider, 'other-provider');
  });

  test('native operations use Ante protocol and discover skills', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);
    final commands = await client.availableCommands(created.sessionId);
    expect(commands.map((command) => command.name),
        containsAll(<String>['compact', 'context']));
    for (final name in <String>['compact', 'context']) {
      final NativeCommand command = commands.firstWhere((c) => c.name == name);
      final result = await client.runNativeCommand(created.sessionId, command, '');
      expect(result.stopReason, 'end_turn');
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final NativeCommand skill = (await client.availableCommands(created.sessionId))
        .firstWhere((command) => command.name == 'commit');
    expect(skill.kind, 'skill');
    final result = await client.runNativeCommand(created.sessionId, skill, 'now');
    expect(result.stopReason, 'end_turn');
  });

  test(
    'each compaction is its own activity, settled with its summary',
    () async {
      final AnteClient client = spawnAnte();
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);
      final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
      final StreamSubscription<AcpSessionUpdate> subscription = client
          .sessionUpdates(created.sessionId)
          .listen(updates.add);
      addTearDown(subscription.cancel);
      final NativeCommand compact = (await client.availableCommands(
        created.sessionId,
      )).firstWhere((NativeCommand command) => command.name == 'compact');

      for (int i = 0; i < 2; i++) {
        await client.runNativeCommand(created.sessionId, compact, '');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final List<AcpAgentActivityUpdate> compactions = updates
          .whereType<AcpAgentActivityUpdate>()
          .where((AcpAgentActivityUpdate update) => update.kind == 'compaction')
          .toList();
      expect(compactions.map((AcpAgentActivityUpdate u) => u.status), <String>[
        'running',
        'completed',
        'running',
        'completed',
      ]);
      // Started and settled under one id, a new one each time.
      expect(compactions[0].id, compactions[1].id);
      expect(compactions[2].id, compactions[3].id);
      expect(compactions[2].id, isNot(compactions[0].id));
      expect(compactions[1].details, <String>['Compacted context']);
    },
  );

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
    expect(model.currentValue, 'fake-provider/fake-model');
    expect(model.options.map((AcpConfigOptionValue item) => item.value), [
      'fake-provider/fake-model',
      'fake-provider/fake-large',
    ]);
    final AcpConfigOption effort = created.configOptions.firstWhere(
      (AcpConfigOption option) => option.id == 'thinking',
    );
    expect(effort.currentValue, 'medium');
    expect(effort.options.map((AcpConfigOptionValue item) => item.value), [
      'default',
      'min',
      'low',
      'medium',
      'high',
    ]);
  });

  test('uses model effort options and can clear an effort override', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);

    final created = await client.newSession(cwd: Directory.current.path);
    await expectLater(
      client.setConfigOption(created.sessionId, 'thinking', 'max'),
      throwsA(
        isA<ArgumentError>().having(
          (ArgumentError error) => error.invalidValue,
          'invalidValue',
          'max',
        ),
      ),
    );

    final List<AcpConfigOption> high = await client.setConfigOption(
      created.sessionId,
      'thinking',
      'high',
    );
    expect(
      high
          .firstWhere((AcpConfigOption option) => option.id == 'thinking')
          .currentValue,
      'high',
    );

    final List<AcpConfigOption> reset = await client.setConfigOption(
      created.sessionId,
      'thinking',
      'default',
    );
    expect(
      reset
          .firstWhere((AcpConfigOption option) => option.id == 'thinking')
          .currentValue,
      'default',
    );
  });

  test(
    'omits effort control when the selected model advertises none',
    () async {
      final AnteClient client = spawnAnte();
      addTearDown(client.dispose);

      final created = await client.newSession(
        cwd: Directory.current.path,
        model: 'fake-large',
        provider: 'fake-provider',
      );
      expect(
        created.configOptions.where(
          (AcpConfigOption option) => option.id == 'thinking',
        ),
        isEmpty,
      );
    },
  );

  for (final String mode in <String>[
    'legacy',
    'catalog-only',
    'absent',
    'live-empty',
  ]) {
    test('effort discovery handles $mode declarations', () async {
      final AnteClient client = spawnAnte(
        environment: <String, String>{'FAKE_ANTE_EFFORTS': mode},
      );
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);
      final Iterable<AcpConfigOption> options = created.configOptions.where(
        (AcpConfigOption option) => option.id == 'thinking',
      );
      if (mode == 'live-empty') {
        expect(options, isEmpty, reason: 'Live empty overrides catalog levels');
        await expectLater(
          client.setConfigOption(created.sessionId, 'thinking', 'high'),
          throwsArgumentError,
        );
      } else {
        expect(
          options.single.options.map((AcpConfigOptionValue v) => v.value),
          <String>[
            'default',
            'min',
            'low',
            'medium',
            'high',
            if (mode == 'absent') ...<String>['xhigh', 'max'],
          ],
        );
        final String chosen = mode == 'absent' ? 'max' : 'high';
        final List<AcpConfigOption> updated = await client.setConfigOption(
          created.sessionId,
          'thinking',
          chosen,
        );
        expect(updated.last.currentValue, chosen);
      }
    });
  }

  test('switching models removes and restores effort choices', () async {
    final AnteClient client = spawnAnte();
    addTearDown(client.dispose);
    final created = await client.newSession(cwd: Directory.current.path);
    final without = await client.setConfigOption(
      created.sessionId,
      'model',
      'fake-large',
    );
    expect(
      without.map((AcpConfigOption o) => o.id),
      isNot(contains('thinking')),
    );
    final restored = await client.setConfigOption(
      created.sessionId,
      'model',
      'fake-model',
    );
    expect(restored.last.id, 'thinking');
  });

  test(
    'reports background task success, failure, and unknown exit code',
    () async {
      final AnteClient client = spawnAnte();
      addTearDown(client.dispose);
      final created = await client.newSession(cwd: Directory.current.path);
      final List<AcpSessionUpdate> updates = <AcpSessionUpdate>[];
      final subscription = client
          .sessionUpdates(created.sessionId)
          .listen(updates.add);
      addTearDown(subscription.cancel);
      await client.prompt(created.sessionId, textBlocks('background tasks'));
      final tasks = updates
          .whereType<AcpAgentActivityUpdate>()
          .where((AcpAgentActivityUpdate a) => a.kind == 'task')
          .toList();
      expect(tasks.map((AcpAgentActivityUpdate a) => a.status), <String>[
        'completed',
        'failed',
        'completed',
      ]);
      expect(tasks.first.id, 'ante-task-job-0');
      expect(tasks[1].details, contains('Exit code: 7'));
      expect(tasks.last.details, contains('Exit code unavailable'));
    },
  );

  test('native yolo mode prevents Ante approval pauses', () async {
    var permissionRequests = 0;
    final AnteClient client = spawnAnte(
      requestPermission:
          (
            String sessionId,
            String? toolCallId,
            String title,
            List<PermissionOptionData> options,
          ) async {
            permissionRequests++;
            return 'AcceptAlways';
          },
    );
    addTearDown(client.dispose);

    final created = await client.newSession(
      cwd: Directory.current.path,
      yolo: true,
    );
    final PromptResult result = await client.prompt(
      created.sessionId,
      textBlocks('normal'),
    );

    expect(result.stopReason, 'end_turn');
    expect(permissionRequests, 0);
  });

  test('short prompt is sent on start and resume, defaulting off', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'ante_short_prompt_test',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final File report = File(p.join(tempDir.path, 'config-report.json'));

    Future<Map<String, Object?>> capture({required bool shortPrompt}) async {
      if (await report.exists()) await report.delete();
      final AnteClient client = spawnAnte(
        environment: <String, String>{
          'FAKE_ANTE_SESSION_CONFIG_REPORT': report.path,
        },
      );
      addTearDown(client.dispose);
      if (shortPrompt) {
        await client.loadSession(
          sessionId: 'ses_01M0H000000000000000000000',
          cwd: Directory.current.path,
          shortPrompt: true,
        );
      } else {
        await client.newSession(cwd: Directory.current.path);
      }
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await report.exists()) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await report.exists(), isTrue);
      final Map<String, Object?> captured = Map<String, Object?>.from(
        jsonDecode(await report.readAsString()) as Map,
      );
      return captured;
    }

    final Map<String, Object?> started = await capture(shortPrompt: true);
    expect(started['short_prompt'], isTrue);

    final Map<String, Object?> resumed = await capture(shortPrompt: true);
    expect(resumed['short_prompt'], isTrue);

    // Default stays off: the key is omitted entirely.
    final Map<String, Object?> defaultStart = await capture(
      shortPrompt: false,
    );
    expect(defaultStart.containsKey('short_prompt'), isFalse);
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
    expect(model.currentValue, 'cerebras/gemma-4-31b');
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

  test('surfaces subagent progress as separate tagged activities', () async {
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
      textBlocks('run subagent'),
    );

    expect(result.stopReason, 'end_turn');
    expect(updates.whereType<AcpToolCall>(), isEmpty);
    expect(updates.whereType<AcpToolCallUpdate>(), isEmpty);
    final List<AcpAgentActivityUpdate> activities = updates
        .whereType<AcpAgentActivityUpdate>()
        .where((AcpAgentActivityUpdate update) => update.kind == 'subagent')
        .toList();
    expect(activities, hasLength(5));

    final List<AcpAgentActivityUpdate> lifecycle = activities
        .where(
          (AcpAgentActivityUpdate update) =>
              update.id == 'ante-subagent-agent-1',
        )
        .toList();
    expect(lifecycle.map((AcpAgentActivityUpdate update) => update.status), [
      'running',
      'completed',
    ]);
    expect(lifecycle.last.title, 'Trace the deployment graph');
    expect(lifecycle.last.details, <String>[
      'explore',
      'The workflow has three deployment entry points.',
    ]);

    expect(
      activities.map((AcpAgentActivityUpdate update) => update.title),
      containsAll(<String>[
        'I’ll map the workflow and its scripts.',
        'Glob',
        'Read',
      ]),
    );
    final AcpAgentActivityUpdate read = activities.singleWhere(
      (AcpAgentActivityUpdate update) => update.title == 'Read',
    );
    expect(
      read.details.single,
      'file_path="/workspace/.github/workflows/deploy.yml"',
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
    'flattens text resources and materializes images and files into Ante '
    'UserInput',
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
          <String, Object?>{
            'type': 'resource',
            'resource': <String, Object?>{
              'uri': 'speeddial-attachment:///att-2/report.pdf',
              'mimeType': 'application/pdf',
              'blob': 'aQ==',
            },
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
      final RegExpMatch? pathMatch = RegExp(r'\[Attached image\]\n@([^\r\n]+)')
          .firstMatch(input);
      expect(pathMatch, isNotNull);
      final File image = File(pathMatch!.group(1)!);
      expect(image.path, endsWith('.png'));
      expect(await image.readAsBytes(), <int>[105]);
      final Directory imageDirectory = image.parent;
      expect(await imageDirectory.exists(), isTrue);

      final RegExpMatch? fileMatch = RegExp(
        r'\[Attached file: report\.pdf \(application/pdf\)\]\n'
        r'Saved to: ([^\r\n]+)$',
      ).firstMatch(input);
      expect(fileMatch, isNotNull);
      final File attachedFile = File(fileMatch!.group(1)!);
      expect(attachedFile.path, endsWith('report.pdf'));
      expect(attachedFile.parent.path, imageDirectory.path);
      expect(await attachedFile.readAsBytes(), <int>[105]);

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
