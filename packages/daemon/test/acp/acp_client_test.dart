@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/acp/acp_client.dart';
import 'package:speeddial_daemon/src/acp/acp_types.dart';
import 'package:test/test.dart';

/// Resolves the fake agent fixture whether the test runner's cwd is the
/// package dir (`dart test` in packages/daemon) or the repo root
/// (`dart test packages/daemon`).
String fakeAgentScript() => <String>[
      p.join(Directory.current.path, 'test', 'fixtures', 'fake_acp_agent.dart'),
      p.join(Directory.current.path, 'packages', 'daemon', 'test', 'fixtures',
          'fake_acp_agent.dart'),
    ].firstWhere((path) => File(path).existsSync());

/// Spawns the fake agent fixture as a real subprocess (via the current Dart
/// VM) and wraps it in an [AcpClient].
AcpClient spawnClient({
  String? targetPath,
  String? cwd,
  AcpPermissionHandler? requestPermission,
  AcpReadTextFileHandler? readTextFile,
  AcpWriteTextFileHandler? writeTextFile,
}) {
  return AcpClient.spawn(
    <String>[Platform.resolvedExecutable, fakeAgentScript()],
    cwd: cwd ?? Directory.current.path,
    environment: <String, String>{'FAKE_ACP_TARGET': ?targetPath},
    requestPermission: requestPermission,
    readTextFile: readTextFile,
    writeTextFile: writeTextFile,
  );
}

/// True for any error a pending request can fail with when the client is
/// disposed or the agent process exits.
bool isDisposalError(Object error) =>
    error is StateError || error is AcpProcessExitedException;

/// A single-text ACP prompt (the shape every test turn uses).
List<Map<String, Object?>> textBlocks(String text) =>
    <Map<String, Object?>>[<String, Object?>{'type': 'text', 'text': text}];

void main() {
  late Directory tempDir;
  late String targetPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('acp_client_test');
    targetPath = p.join(tempDir.path, 'example.txt');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Cleanup failure is not a test failure.
    }
  });

  test('initializes, creates a session, and streams prompt updates in order',
      () async {
    final permissionCalls = <Map<String, Object?>>[];
    final readCalls = <(String, String)>[];
    final client = spawnClient(
      targetPath: targetPath,
      requestPermission: (sessionId, toolCallId, title, options) async {
        permissionCalls.add(<String, Object?>{
          'sessionId': sessionId,
          'toolCallId': toolCallId,
          'title': title,
          'options': options.map((o) => o.optionId).toList(),
        });
        return 'allow';
      },
      readTextFile: (sessionId, path) async {
        readCalls.add((sessionId, path));
        return 'hello from file\n';
      },
      writeTextFile: (sessionId, path, content) async {},
    );
    addTearDown(client.dispose);

    final info = await client.initialized;
    expect(info.protocolVersion, 1);
    expect(info.agentCapabilities, isNotEmpty);
    expect(info.authMethods, isEmpty);

    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;
    expect(sessionId, 's1');

    final updates = <AcpSessionUpdate>[];
    final subscription = client.sessionUpdates(sessionId).listen(updates.add);
    addTearDown(subscription.cancel);

    final result =
        await client.prompt(sessionId, textBlocks('please edit the file'));
    expect(result.stopReason, 'end_turn');

    // Updates arrive in the order the agent emitted them.
    expect(
      updates.map((u) => u.runtimeType).toList(),
      <Type>[
        AcpAgentMessageChunk,
        AcpAgentMessageChunk,
        AcpToolCall,
        AcpToolCallUpdate,
        AcpPlan,
        AcpUsageUpdate,
      ],
    );

    final firstChunk = updates[0] as AcpAgentMessageChunk;
    expect(firstChunk.text, 'I will inspect the target file.');
    final secondChunk = updates[1] as AcpAgentMessageChunk;
    expect(secondChunk.text, 'Reading its contents first.');

    final toolCall = (updates[2] as AcpToolCall).toolCall;
    expect(toolCall.id, 'tc1');
    expect(toolCall.kind, 'read');
    expect(toolCall.status, 'in_progress');
    expect(toolCall.content, isEmpty);
    expect(toolCall.locations.single.path, targetPath);
    expect(toolCall.rawInput['path'], targetPath);

    final toolCallUpdate = updates[3] as AcpToolCallUpdate;
    expect(toolCallUpdate.toolCallId, 'tc1');
    expect(toolCallUpdate.fields['status'], 'completed');
    expect(
      (toolCallUpdate.fields['rawOutput'] as Map)['content'],
      'hello from file\n',
    );

    final plan = updates[4] as AcpPlan;
    expect(plan.entries, hasLength(2));
    expect(plan.entries.first.content, 'Read the target file');
    expect(plan.entries.first.priority, 'high');
    expect(plan.entries.first.status, 'in_progress');
    expect(plan.entries.last.priority, 'medium');

    final usage = updates[5] as AcpUsageUpdate;
    expect(usage.size, 10000);
    expect(usage.used, 250);
    expect(usage.cost, isNotNull);
    expect(usage.cost!.amount, 0.012);
    expect(usage.cost!.currency, 'USD');

    // The permission request was delegated and answered.
    expect(permissionCalls, hasLength(1));
    expect(permissionCalls.single['sessionId'], 's1');
    expect(permissionCalls.single['toolCallId'], 'tc1');
    expect(permissionCalls.single['title'], 'Read example.txt');
    expect(permissionCalls.single['options'], <String>['allow', 'reject']);

    // The fs/read_text_file request was delegated.
    expect(readCalls, hasLength(1));
    expect(readCalls.single.$1, 's1');
    expect(readCalls.single.$2, targetPath);
  });

  test('cancel resolves the pending prompt with the cancelled stop reason',
      () async {
    final client = spawnClient(targetPath: targetPath);
    addTearDown(client.dispose);

    await client.initialized;
    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;

    final promptFuture = client.prompt(sessionId, textBlocks('cancel'));
    await client.cancel(sessionId);
    final result = await promptFuture;
    expect(result.stopReason, 'cancelled');
  });

  test('dispose fails pending requests', () async {
    final client = spawnClient(targetPath: targetPath);
    addTearDown(() async {
      try {
        await client.dispose();
      } on Object {
        // Disposal is idempotent.
      }
    });

    await client.initialized;
    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;

    final pending = client.prompt(sessionId, textBlocks('hang'));
    // Attach the matcher before dispose() so the pending future's error has a
    // listener from the start (an unlistened error would be reported as an
    // unhandled async error).
    final expectation = expectLater(
      pending,
      throwsA(predicate(isDisposalError)),
    );
    await client.dispose();
    await expectation;
    // Disposing twice is harmless.
    await client.dispose();
  });

  test('unknown session update variants are dropped without crashing',
      () async {
    final client = spawnClient(targetPath: targetPath);
    addTearDown(client.dispose);

    await client.initialized;
    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;

    final updates = <AcpSessionUpdate>[];
    final subscription = client.sessionUpdates(sessionId).listen(updates.add);
    addTearDown(subscription.cancel);

    final result = await client.prompt(sessionId, textBlocks('weird'));
    expect(result.stopReason, 'end_turn');
    expect(updates, hasLength(1));
    final usage = updates.single as AcpUsageUpdate;
    expect(usage.size, 100);
    expect(usage.used, 10);
  });

  test('authenticate and setMode round-trip', () async {
    final client = spawnClient(targetPath: targetPath);
    addTearDown(client.dispose);

    await client.initialized;
    await client.authenticate('token');
    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;
    expect(sessionId, 's1');
    await client.setMode(sessionId, 'plan');
  });

  test('loadSession resumes a previously created session', () async {
    final client = spawnClient(targetPath: targetPath);
    addTearDown(client.dispose);

    final info = await client.initialized;
    expect(info.agentCapabilities['loadSession'], isTrue);

    final sessionId = (await client.newSession(cwd: tempDir.path)).sessionId;
    await client.loadSession(sessionId: sessionId, cwd: tempDir.path);
    // The resumed session accepts prompts.
    final result = await client.prompt(sessionId, textBlocks('weird'));
    expect(result.stopReason, 'end_turn');
  });

  test('loadSession surfaces an agent error when the session is unknown',
      () async {
    // The fake answers session/load with an error when this signal file
    // exists in its process cwd.
    File(p.join(tempDir.path, 'agent.load_fails')).createSync();
    final client = spawnClient(targetPath: targetPath, cwd: tempDir.path);
    addTearDown(client.dispose);

    final info = await client.initialized;
    expect(info.agentCapabilities['loadSession'], isTrue);
    await expectLater(
      client.loadSession(sessionId: 'gone', cwd: tempDir.path),
      throwsA(isA<AcpJsonRpcException>()
          .having((e) => e.code, 'code', -32000)),
    );
  });

  test('loadSession capability is absent when the agent declines it',
      () async {
    File(p.join(tempDir.path, 'agent.no_load_session')).createSync();
    final client = spawnClient(targetPath: targetPath, cwd: tempDir.path);
    addTearDown(client.dispose);

    final info = await client.initialized;
    expect(info.agentCapabilities['loadSession'], isFalse);
  });

  test('newSession and loadSession report configOptions; setConfigOption '
      'updates the agent and returns the full list', () async {
    final client = spawnClient(targetPath: targetPath, cwd: tempDir.path);
    addTearDown(client.dispose);

    await client.initialized;
    final created = await client.newSession(cwd: tempDir.path);
    expect(created.sessionId, 's1');
    final model = created.configOptions
        .firstWhere((option) => option.id == 'model');
    expect(model.name, 'Model');
    expect(model.category, 'model');
    expect(model.type, 'select');
    expect(model.currentValue, 'fake-fast');
    expect(
      model.options.map((option) => option.value),
      <String>['fake-fast', 'fake-smart'],
    );
    final thinking = created.configOptions
        .firstWhere((option) => option.id == 'thinking');
    expect(thinking.name, 'Thinking');
    expect(thinking.category, 'thought_level');
    expect(thinking.type, 'select');
    expect(thinking.currentValue, 'auto');
    expect(
      thinking.options.map((option) => option.value),
      <String>['off', 'auto', 'low', 'high', 'max'],
    );

    // Resuming advertises the same options.
    final loaded =
        await client.loadSession(sessionId: created.sessionId, cwd: tempDir.path);
    expect(
      loaded.map((option) => option.id),
      <String>['model', 'thinking'],
    );
    expect(
      loaded.firstWhere((option) => option.id == 'thinking').currentValue,
      'auto',
    );

    // A model choice (any non-empty string, like omp's fuzzy ids) is
    // applied and recorded.
    final changedModel = await client.setConfigOption(
        created.sessionId, 'model', 'claude-sonnet');
    expect(
      changedModel.firstWhere((option) => option.id == 'model').currentValue,
      'claude-sonnet',
    );
    expect(
      File(p.join(tempDir.path, 'agent.model')).readAsStringSync(),
      'claude-sonnet',
    );

    // Setting the thinking option updates the agent and returns the full
    // list.
    final updated =
        await client.setConfigOption(created.sessionId, 'thinking', 'max');
    expect(
      updated.firstWhere((option) => option.id == 'thinking').currentValue,
      'max',
    );
    expect(
      updated
          .firstWhere((option) => option.id == 'thinking')
          .options
          .map((option) => option.value),
      <String>['off', 'auto', 'low', 'high', 'max'],
    );
    expect(
      File(p.join(tempDir.path, 'agent.thinking')).readAsStringSync(),
      'max',
    );

    // An unknown value is a JSON-RPC error.
    await expectLater(
      client.setConfigOption(created.sessionId, 'thinking', 'bogus'),
      throwsA(isA<AcpJsonRpcException>()
          .having((e) => e.code, 'code', -32602)),
    );
  });

  test('configOptions omit the thinking option and reject its config id '
      'behind agent.no_thinking', () async {
    File(p.join(tempDir.path, 'agent.no_thinking')).createSync();
    final client = spawnClient(targetPath: targetPath, cwd: tempDir.path);
    addTearDown(client.dispose);

    await client.initialized;
    final created = await client.newSession(cwd: tempDir.path);
    expect(created.sessionId, 's1');
    // The thinking option is gone, but the model option stays advertised.
    expect(
      created.configOptions.map((option) => option.id),
      <String>['model'],
    );
    await expectLater(
      client.setConfigOption(created.sessionId, 'thinking', 'auto'),
      throwsA(isA<AcpJsonRpcException>()
          .having((e) => e.code, 'code', -32602)),
    );
  });

  test('configOptions omit the model option and reject its config id '
      'behind agent.no_model', () async {
    File(p.join(tempDir.path, 'agent.no_model')).createSync();
    final client = spawnClient(targetPath: targetPath, cwd: tempDir.path);
    addTearDown(client.dispose);

    await client.initialized;
    final created = await client.newSession(cwd: tempDir.path);
    expect(created.sessionId, 's1');
    // The model option is gone, but the thinking option stays advertised.
    expect(
      created.configOptions.map((option) => option.id),
      <String>['thinking'],
    );
    await expectLater(
      client.setConfigOption(created.sessionId, 'model', 'fake-fast'),
      throwsA(isA<AcpJsonRpcException>()
          .having((e) => e.code, 'code', -32602)),
    );
  });
}
