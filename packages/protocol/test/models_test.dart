import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('enum wire values', () {
    test('SessionStatus uses waitingPermission override', () {
      expect(SessionStatus.idle.wire, 'idle');
      expect(SessionStatus.running.wire, 'running');
      expect(SessionStatus.waitingPermission.wire, 'waitingPermission');
      expect(SessionStatus.error.wire, 'error');
      expect(SessionStatus.closed.wire, 'closed');

      expect(SessionStatus.parse('idle'), SessionStatus.idle);
      expect(SessionStatus.parse('running'), SessionStatus.running);
      expect(
        SessionStatus.parse('waitingPermission'),
        SessionStatus.waitingPermission,
      );
      expect(SessionStatus.parse('error'), SessionStatus.error);
      expect(SessionStatus.parse('closed'), SessionStatus.closed);
      expect(
        () => SessionStatus.parse('waiting_permission'),
        throwsFormatException,
      );
      expect(() => SessionStatus.parse('nope'), throwsFormatException);
    });

    test('SessionMode is name-based', () {
      expect(SessionMode.build.wire, 'build');
      expect(SessionMode.plan.wire, 'plan');
      expect(SessionMode.parse('build'), SessionMode.build);
      expect(SessionMode.parse('plan'), SessionMode.plan);
      expect(() => SessionMode.parse('builds'), throwsFormatException);
    });

    test('SessionSandboxMode is name-based', () {
      for (final SessionSandboxMode mode in SessionSandboxMode.values) {
        expect(SessionSandboxMode.parse(mode.wire), mode);
      }
      expect(
        () => SessionSandboxMode.parse('danger-full-access'),
        throwsFormatException,
      );
    });

    test('ToolCallStatus is name-based', () {
      expect(ToolCallStatus.pending.wire, 'pending');
      expect(ToolCallStatus.running.wire, 'running');
      expect(ToolCallStatus.completed.wire, 'completed');
      expect(ToolCallStatus.failed.wire, 'failed');
      for (final status in ToolCallStatus.values) {
        expect(ToolCallStatus.parse(status.wire), status);
      }
      expect(() => ToolCallStatus.parse('done'), throwsFormatException);
    });

    test('PlanPriority is name-based', () {
      expect(PlanPriority.high.wire, 'high');
      expect(PlanPriority.medium.wire, 'medium');
      expect(PlanPriority.low.wire, 'low');
      for (final priority in PlanPriority.values) {
        expect(PlanPriority.parse(priority.wire), priority);
      }
      expect(() => PlanPriority.parse('urgent'), throwsFormatException);
    });

    test('PlanEntryStatus uses in_progress override', () {
      expect(PlanEntryStatus.pending.wire, 'pending');
      expect(PlanEntryStatus.inProgress.wire, 'in_progress');
      expect(PlanEntryStatus.completed.wire, 'completed');
      expect(PlanEntryStatus.parse('pending'), PlanEntryStatus.pending);
      expect(PlanEntryStatus.parse('in_progress'), PlanEntryStatus.inProgress);
      expect(PlanEntryStatus.parse('completed'), PlanEntryStatus.completed);
      expect(() => PlanEntryStatus.parse('inProgress'), throwsFormatException);
    });

    test('PermissionKind uses snake_case wire values', () {
      expect(PermissionKind.allowOnce.wire, 'allow_once');
      expect(PermissionKind.allowAlways.wire, 'allow_always');
      expect(PermissionKind.rejectOnce.wire, 'reject_once');
      expect(PermissionKind.rejectAlways.wire, 'reject_always');
      expect(PermissionKind.parse('allow_once'), PermissionKind.allowOnce);
      expect(PermissionKind.parse('allow_always'), PermissionKind.allowAlways);
      expect(PermissionKind.parse('reject_once'), PermissionKind.rejectOnce);
      expect(
        PermissionKind.parse('reject_always'),
        PermissionKind.rejectAlways,
      );
      expect(() => PermissionKind.parse('allowOnce'), throwsFormatException);
    });
  });

  group('models JSON roundtrip', () {
    test('DaemonInfo / ProviderInfo', () {
      final model = DaemonInfo(
        version: '0.1.0',
        protocolVersion: 1,
        authRequired: false,
        providers: [
          ProviderInfo(
            id: 'omp',
            name: 'Oh My Pi',
            available: true,
            command: 'omp',
            models: const ['default', 'flash'],
            sandboxModes: const <SessionSandboxMode>[
              SessionSandboxMode.workspaceWrite,
              SessionSandboxMode.unrestricted,
            ],
          ),
          ProviderInfo(
            id: 'claude',
            name: 'Claude',
            available: false,
            command: 'npx @zed-industries/claude-code-acp',
            models: const [],
          ),
        ],
      );
      final decoded = DaemonInfo.fromJson(model.toJson());
      expect(decoded.version, model.version);
      expect(decoded.protocolVersion, model.protocolVersion);
      expect(decoded.authRequired, model.authRequired);
      expect(decoded.providers, hasLength(2));
      expect(decoded.providers[0].id, 'omp');
      expect(decoded.providers[0].name, 'Oh My Pi');
      expect(decoded.providers[0].available, isTrue);
      expect(decoded.providers[0].command, 'omp');
      expect(decoded.providers[0].models, ['default', 'flash']);
      expect(decoded.providers[0].sandboxModes, SessionSandboxMode.values);
      expect(decoded.providers[1].models, isEmpty);
      // protocol defaults to acp for old daemons that do not send it.
      expect(decoded.providers[0].protocol, 'acp');
      expect(decoded.providers[1].protocol, 'acp');
      final decodedWithProtocol = DaemonInfo.fromJson(<String, Object?>{
        ...model.toJson(),
        'providers': <Object?>[
          <String, Object?>{...model.providers[0].toJson(), 'protocol': 'ante'},
          model.providers[1].toJson(),
        ],
      });
      expect(decodedWithProtocol.providers[0].protocol, 'ante');
      expect(decoded.toJson(), model.toJson());
    });

    test('Project with DateTime fields', () {
      final model = Project(
        id: 'proj_abc1234567890',
        name: 'speeddial',
        path: '/home/nigel/p/speeddial',
        addedAt: DateTime.utc(2026, 8, 1, 12, 30),
        lastActiveAt: DateTime.utc(2026, 8, 18, 9, 15, 42),
      );
      final json = model.toJson();
      expect(json['addedAt'], '2026-08-01T12:30:00.000Z');
      expect(json['lastActiveAt'], '2026-08-18T09:15:42.000Z');

      final decoded = Project.fromJson(json);
      expect(decoded.id, 'proj_abc1234567890');
      expect(decoded.name, 'speeddial');
      expect(decoded.path, '/home/nigel/p/speeddial');
      expect(decoded.addedAt, DateTime.utc(2026, 8, 1, 12, 30));
      expect(decoded.lastActiveAt, DateTime.utc(2026, 8, 18, 9, 15, 42));
      expect(decoded.addedAt.isUtc, isTrue);
      expect(decoded.toJson(), json);
    });

    test('HarnessInfo', () {
      const HarnessInfo model = HarnessInfo(
        id: 'codex',
        name: 'Codex',
        version: 'codex-cli 0.148.0',
      );
      final Map<String, Object?> json = model.toJson();
      expect(json, <String, Object?>{
        'id': 'codex',
        'name': 'Codex',
        'version': 'codex-cli 0.148.0',
      });
      final HarnessInfo decoded = HarnessInfo.fromJson(json);
      expect(decoded.id, model.id);
      expect(decoded.name, model.name);
      expect(decoded.version, model.version);
    });

    test('Session parses enum wire spellings and null model', () {
      final json = <String, Object?>{
        'id': 'sess_abcdefghijklmno',
        'projectId': 'proj_abc1234567890',
        'providerId': 'omp',
        'title': 'Fix the flaky test',
        'status': 'waitingPermission',
        'mode': 'plan',
        'model': null,
        'cwd': '/home/nigel/p/speeddial',
        'archived': false,
        'createdAt': '2026-08-18T10:00:00Z',
        'updatedAt': '2026-08-18T10:01:00Z',
      };
      final session = Session.fromJson(json);
      expect(session.id, 'sess_abcdefghijklmno');
      expect(session.status, SessionStatus.waitingPermission);
      expect(session.mode, SessionMode.plan);
      expect(session.model, isNull);
      expect(session.cwd, '/home/nigel/p/speeddial');
      expect(
        session.baseBranch,
        isNull,
        reason: 'baseBranch is absent on pre-merge-back daemons',
      );
      expect(
        session.yolo,
        isFalse,
        reason: 'yolo is absent on pre-yolo daemons',
      );
      expect(
        session.sandboxMode,
        isNull,
        reason: 'sandboxMode is absent on older daemons',
      );
      expect(session.archived, isFalse);
      expect(session.createdAt.isUtc, isTrue);
      expect(
        session.lastActivityAt,
        session.updatedAt,
        reason: 'lastActivityAt is absent on older daemons',
      );

      final roundtrip = Session.fromJson(session.toJson());
      expect(roundtrip.status, SessionStatus.waitingPermission);
      expect(roundtrip.mode, SessionMode.plan);
      expect(roundtrip.createdAt, session.createdAt);
      expect(roundtrip.updatedAt, session.updatedAt);
      expect(roundtrip.toJson(), session.toJson());
    });

    test('Session with running status and set model', () {
      final model = Session(
        id: 's1',
        projectId: 'p1',
        providerId: 'codex',
        title: 'T',
        status: SessionStatus.running,
        mode: SessionMode.build,
        model: 'gpt-5',
        models: const <String>['gpt-5', 'gpt-5-mini'],
        cwd: '/tmp/wt',
        baseBranch: 'main',
        thinkingLevel: 'auto',
        thinkingLevels: const <String>['off', 'auto', 'low', 'high', 'max'],
        sandboxMode: SessionSandboxMode.unrestricted,
        yolo: true,
        archived: true,
        createdAt: DateTime.utc(2026, 1, 1),
        lastActivityAt: DateTime.utc(2026, 1, 2, 2, 3, 4, 567),
        updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 678),
      );
      final decoded = Session.fromJson(model.toJson());
      expect(decoded.status, SessionStatus.running);
      expect(decoded.model, 'gpt-5');
      expect(decoded.models, <String>['gpt-5', 'gpt-5-mini']);
      expect(decoded.baseBranch, 'main');
      expect(decoded.thinkingLevel, 'auto');
      expect(decoded.thinkingLevels, <String>[
        'off',
        'auto',
        'low',
        'high',
        'max',
      ]);
      expect(decoded.sandboxMode, SessionSandboxMode.unrestricted);
      expect(decoded.yolo, isTrue);
      expect(decoded.archived, isTrue);
      expect(decoded.lastActivityAt, model.lastActivityAt);
      expect(decoded.toJson(), model.toJson());
    });

    test('Session defaults to no thinking levels on older daemons', () {
      final json = <String, Object?>{
        'id': 's1',
        'projectId': 'p1',
        'providerId': 'claude',
        'title': 'T',
        'status': 'idle',
        'mode': 'build',
        'model': null,
        'cwd': '/tmp',
        'baseBranch': null,
        'yolo': false,
        'archived': false,
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
      };
      final session = Session.fromJson(json);
      expect(
        session.models,
        isEmpty,
        reason: 'models is absent on pre-config-option daemons',
      );
      expect(
        session.thinkingLevel,
        isNull,
        reason: 'thinkingLevel is absent on pre-thinking-level daemons',
      );
      expect(
        session.thinkingLevels,
        isEmpty,
        reason: 'thinkingLevels is absent on pre-thinking-level daemons',
      );
      expect(session.toJson()['thinkingLevels'], isEmpty);
    });

    test('FileEntry', () {
      final model = FileEntry(
        name: 'main.dart',
        path: 'lib/main.dart',
        isDir: false,
        size: 2048,
        modifiedAt: DateTime.utc(2026, 8, 17, 22, 0, 0),
      );
      final decoded = FileEntry.fromJson(model.toJson());
      expect(decoded.name, 'main.dart');
      expect(decoded.path, 'lib/main.dart');
      expect(decoded.isDir, isFalse);
      expect(decoded.size, 2048);
      expect(decoded.modifiedAt, DateTime.utc(2026, 8, 17, 22, 0, 0));
      expect(decoded.toJson(), model.toJson());
    });

    test('FileDownload', () {
      const model = FileDownload(
        name: 'report.pdf',
        size: 4,
        data: 'AAECAw==',
      );
      final decoded = FileDownload.fromJson(model.toJson());
      expect(decoded.name, 'report.pdf');
      expect(decoded.size, 4);
      expect(decoded.data, 'AAECAw==');
      expect(decoded.toJson(), model.toJson());
    });

    test('GitStatusFile / GitStatus', () {
      final file = GitStatusFile(
        path: 'lib/src/rpc.dart',
        indexStatus: 'M',
        worktreeStatus: '.',
        staged: true,
      );
      expect(file.toJson(), {
        'path': 'lib/src/rpc.dart',
        'indexStatus': 'M',
        'worktreeStatus': '.',
        'staged': true,
      });
      final decodedFile = GitStatusFile.fromJson(file.toJson());
      expect(decodedFile.path, 'lib/src/rpc.dart');
      expect(decodedFile.indexStatus, 'M');
      expect(decodedFile.worktreeStatus, '.');
      expect(decodedFile.staged, isTrue);

      final status = GitStatus(
        branch: 'main',
        ahead: 2,
        behind: 0,
        files: [
          file,
          GitStatusFile(
            path: 'README.md',
            indexStatus: '.',
            worktreeStatus: 'M',
            staged: false,
          ),
        ],
      );
      final decodedStatus = GitStatus.fromJson(status.toJson());
      expect(decodedStatus.branch, 'main');
      expect(decodedStatus.ahead, 2);
      expect(decodedStatus.behind, 0);
      expect(decodedStatus.files, hasLength(2));
      expect(decodedStatus.files[0].staged, isTrue);
      expect(decodedStatus.files[1].staged, isFalse);
      expect(decodedStatus.toJson(), status.toJson());
    });

    test('GitDiff', () {
      final model = GitDiff(
        path: 'lib/src/rpc.dart',
        patch: '@@ -1,3 +1,4 @@\n-old\n+new\n',
        isNew: false,
        isDeleted: false,
        isBinary: false,
      );
      final decoded = GitDiff.fromJson(model.toJson());
      expect(decoded.path, 'lib/src/rpc.dart');
      expect(decoded.patch, '@@ -1,3 +1,4 @@\n-old\n+new\n');
      expect(decoded.isNew, isFalse);
      expect(decoded.isDeleted, isFalse);
      expect(decoded.isBinary, isFalse);
      expect(decoded.toJson(), model.toJson());

      final binary = GitDiff(
        path: 'assets/logo.png',
        patch: '',
        isNew: true,
        isDeleted: false,
        isBinary: true,
      );
      expect(binary.toJson()['isBinary'], isTrue);
      expect(binary.toJson()['isNew'], isTrue);
    });

    test('Branch with and without upstream', () {
      final withUpstream = Branch(
        name: 'feature/x',
        isCurrent: true,
        upstream: 'origin/feature/x',
      );
      final decoded = Branch.fromJson(withUpstream.toJson());
      expect(decoded.name, 'feature/x');
      expect(decoded.isCurrent, isTrue);
      expect(decoded.upstream, 'origin/feature/x');
      expect(decoded.toJson(), withUpstream.toJson());

      final noUpstream = Branch(name: 'main', isCurrent: false);
      expect(noUpstream.toJson(), {
        'name': 'main',
        'isCurrent': false,
        'upstream': null,
      });
      final decoded2 = Branch.fromJson(noUpstream.toJson());
      expect(decoded2.upstream, isNull);
      expect(decoded2.toJson(), noUpstream.toJson());
    });

    test('MergeResult', () {
      final model = MergeResult(
        baseBranch: 'main',
        sessionBranch: 'speeddial/fix-login-a1b2c3d4',
        baseFastForwarded: true,
        alreadyUpToDate: false,
        fastForward: true,
        commit: 'a' * 40,
      );
      expect(model.toJson(), {
        'baseBranch': 'main',
        'sessionBranch': 'speeddial/fix-login-a1b2c3d4',
        'baseFastForwarded': true,
        'alreadyUpToDate': false,
        'fastForward': true,
        'commit': 'a' * 40,
      });
      final decoded = MergeResult.fromJson(model.toJson());
      expect(decoded.baseBranch, 'main');
      expect(decoded.sessionBranch, 'speeddial/fix-login-a1b2c3d4');
      expect(decoded.baseFastForwarded, isTrue);
      expect(decoded.alreadyUpToDate, isFalse);
      expect(decoded.fastForward, isTrue);
      expect(decoded.commit, 'a' * 40);
      expect(decoded.toJson(), model.toJson());
    });

    test('RebaseResult', () {
      final model = RebaseResult(
        baseBranch: 'main',
        sessionBranch: 'speeddial/fix-login-a1b2c3d4',
        baseFastForwarded: true,
        alreadyUpToDate: false,
        commit: 'b' * 40,
      );
      expect(model.toJson(), {
        'baseBranch': 'main',
        'sessionBranch': 'speeddial/fix-login-a1b2c3d4',
        'baseFastForwarded': true,
        'alreadyUpToDate': false,
        'commit': 'b' * 40,
      });
      final decoded = RebaseResult.fromJson(model.toJson());
      expect(decoded.baseBranch, 'main');
      expect(decoded.sessionBranch, 'speeddial/fix-login-a1b2c3d4');
      expect(decoded.baseFastForwarded, isTrue);
      expect(decoded.alreadyUpToDate, isFalse);
      expect(decoded.commit, 'b' * 40);
      expect(decoded.toJson(), model.toJson());
    });

    test('SessionGitSummary, fully populated and all-null', () {
      final model = SessionGitSummary(
        sessionId: 'sess-1',
        dirty: true,
        aheadOfBase: 3,
        behindBase: 1,
        mergedIntoBase: false,
      );
      expect(model.toJson(), {
        'sessionId': 'sess-1',
        'dirty': true,
        'aheadOfBase': 3,
        'behindBase': 1,
        'mergedIntoBase': false,
      });
      final decoded = SessionGitSummary.fromJson(model.toJson());
      expect(decoded.sessionId, 'sess-1');
      expect(decoded.dirty, isTrue);
      expect(decoded.aheadOfBase, 3);
      expect(decoded.behindBase, 1);
      expect(decoded.mergedIntoBase, isFalse);
      expect(decoded.toJson(), model.toJson());

      // Unknown/not-applicable fields travel as explicit nulls.
      const empty = SessionGitSummary(
        sessionId: 'sess-2',
        dirty: null,
        aheadOfBase: null,
        behindBase: null,
        mergedIntoBase: null,
      );
      expect(empty.toJson(), {
        'sessionId': 'sess-2',
        'dirty': null,
        'aheadOfBase': null,
        'behindBase': null,
        'mergedIntoBase': null,
      });
      final decodedEmpty = SessionGitSummary.fromJson(empty.toJson());
      expect(decodedEmpty.dirty, isNull);
      expect(decodedEmpty.aheadOfBase, isNull);
      expect(decodedEmpty.behindBase, isNull);
      expect(decodedEmpty.mergedIntoBase, isNull);
      expect(decodedEmpty.toJson(), empty.toJson());
    });

    test('ToolCall with content, locations, and raw payloads', () {
      final model = ToolCall(
        id: 'tc_1234567890abcde',
        title: 'Edit rpc.dart',
        kind: 'edit',
        status: ToolCallStatus.completed,
        content: [
          const ToolCallText(text: 'Applying edit'),
          const ToolCallImage(
            attachment: Attachment(
              id: 'att_tool_image',
              name: 'screenshot.png',
              mimeType: 'image/png',
              size: 68,
            ),
          ),
          ToolCallDiff(
            path: 'lib/src/rpc.dart',
            oldText: 'old line',
            newText: 'new line',
          ),
          const ToolCallPatch(
            path: 'lib/src/native.dart',
            diff: '@@ -1 +1 @@\n-old\n+new',
          ),
        ],
        locations: const ['lib/src/rpc.dart'],
        rawInput: <String, Object?>{'path': 'lib/src/rpc.dart'},
        rawOutput: <String, Object?>{'ok': true},
      );
      final json = model.toJson();
      expect(json['kind'], 'edit');
      expect(json['status'], 'completed');
      expect(json['content'], hasLength(4));
      expect(json['locations'], ['lib/src/rpc.dart']);

      final decoded = ToolCall.fromJson(json);
      expect(decoded.id, 'tc_1234567890abcde');
      expect(decoded.title, 'Edit rpc.dart');
      expect(decoded.kind, 'edit');
      expect(decoded.status, ToolCallStatus.completed);
      expect(decoded.content, hasLength(4));
      expect(decoded.content[0], isA<ToolCallText>());
      expect((decoded.content[0] as ToolCallText).text, 'Applying edit');
      expect(decoded.content[1], isA<ToolCallImage>());
      final image = decoded.content[1] as ToolCallImage;
      expect(image.attachment.id, 'att_tool_image');
      expect(image.attachment.name, 'screenshot.png');
      expect(image.attachment.mimeType, 'image/png');
      expect(image.attachment.size, 68);
      expect(decoded.content[2], isA<ToolCallDiff>());
      final diff = decoded.content[2] as ToolCallDiff;
      expect(diff.path, 'lib/src/rpc.dart');
      expect(diff.oldText, 'old line');
      expect(diff.newText, 'new line');
      expect(decoded.content[3], isA<ToolCallPatch>());
      final patch = decoded.content[3] as ToolCallPatch;
      expect(patch.path, 'lib/src/native.dart');
      expect(patch.diff, '@@ -1 +1 @@\n-old\n+new');
      expect(decoded.locations, ['lib/src/rpc.dart']);
      expect(decoded.rawInput, {'path': 'lib/src/rpc.dart'});
      expect(decoded.rawOutput, {'ok': true});
      expect(decoded.toJson(), json);
    });

    test('ToolCall with null raw fields and empty lists', () {
      final model = ToolCall(
        id: 'tc_1',
        title: 'Think',
        kind: 'think',
        status: ToolCallStatus.pending,
        content: const [],
        locations: const [],
      );
      final json = model.toJson();
      expect(json['rawInput'], isNull);
      expect(json['rawOutput'], isNull);
      final decoded = ToolCall.fromJson(json);
      expect(decoded.status, ToolCallStatus.pending);
      expect(decoded.content, isEmpty);
      expect(decoded.locations, isEmpty);
      expect(decoded.rawInput, isNull);
      expect(decoded.toJson(), json);
    });

    test('PlanEntry', () {
      final model = PlanEntry(
        content: 'Implement RpcPeer',
        priority: PlanPriority.high,
        status: PlanEntryStatus.inProgress,
      );
      expect(model.toJson(), {
        'content': 'Implement RpcPeer',
        'priority': 'high',
        'status': 'in_progress',
      });
      final decoded = PlanEntry.fromJson(model.toJson());
      expect(decoded.content, 'Implement RpcPeer');
      expect(decoded.priority, PlanPriority.high);
      expect(decoded.status, PlanEntryStatus.inProgress);
      expect(decoded.toJson(), model.toJson());

      final completed = PlanEntry.fromJson(const {
        'content': 'x',
        'priority': 'low',
        'status': 'completed',
      });
      expect(completed.priority, PlanPriority.low);
      expect(completed.status, PlanEntryStatus.completed);
    });

    test('PermissionOption / PermissionRequest', () {
      final request = PermissionRequest(
        requestId: 'req_abcdefghijklmno',
        toolCallId: 'tc_1234567890abcde',
        title: 'Allow editing lib/src/rpc.dart?',
        options: [
          PermissionOption(
            optionId: 'allow_once',
            name: 'Allow once',
            kind: PermissionKind.allowOnce,
          ),
          PermissionOption(
            optionId: 'allow_always',
            name: 'Always allow',
            kind: PermissionKind.allowAlways,
          ),
          PermissionOption(
            optionId: 'reject',
            name: 'Reject',
            kind: PermissionKind.rejectOnce,
          ),
        ],
      );
      final json = request.toJson();
      expect(json['toolCallId'], 'tc_1234567890abcde');
      expect(json['options'], hasLength(3));
      expect((json['options']! as List)[0], {
        'optionId': 'allow_once',
        'name': 'Allow once',
        'kind': 'allow_once',
      });

      final decoded = PermissionRequest.fromJson(json);
      expect(decoded.requestId, 'req_abcdefghijklmno');
      expect(decoded.toolCallId, 'tc_1234567890abcde');
      expect(decoded.title, 'Allow editing lib/src/rpc.dart?');
      expect(decoded.options, hasLength(3));
      expect(decoded.options[0].kind, PermissionKind.allowOnce);
      expect(decoded.options[1].kind, PermissionKind.allowAlways);
      expect(decoded.options[2].kind, PermissionKind.rejectOnce);
      expect(decoded.toJson(), json);

      final noTool = PermissionRequest(
        requestId: 'r2',
        toolCallId: null,
        title: 'T',
        options: const [],
      );
      expect(noTool.toJson()['toolCallId'], isNull);
      expect(PermissionRequest.fromJson(noTool.toJson()).toolCallId, isNull);
    });

    test('UsageInfo', () {
      final model = UsageInfo(
        inputTokens: 1234,
        outputTokens: 567,
        totalTokens: 1801,
        cost: '0.0421',
      );
      final decoded = UsageInfo.fromJson(model.toJson());
      expect(decoded.inputTokens, 1234);
      expect(decoded.outputTokens, 567);
      expect(decoded.totalTokens, 1801);
      expect(decoded.cost, '0.0421');
      expect(decoded.toJson(), model.toJson());

      final noCost = UsageInfo(inputTokens: 1, outputTokens: 2, totalTokens: 3);
      expect(noCost.toJson(), {
        'inputTokens': 1,
        'outputTokens': 2,
        'totalTokens': 3,
        'cost': null,
      });
      expect(UsageInfo.fromJson(noCost.toJson()).cost, isNull);
    });

    test('Attachment metadata roundtrip', () {
      const model = Attachment(
        id: 'att_1',
        name: 'shot.png',
        mimeType: 'image/png',
        size: 12345,
      );
      final json = model.toJson();
      expect(json, {
        'id': 'att_1',
        'name': 'shot.png',
        'mimeType': 'image/png',
        'size': 12345,
      });
      final decoded = Attachment.fromJson(json);
      expect(decoded.id, 'att_1');
      expect(decoded.size, 12345);
      expect(decoded.toJson(), json);
    });

    test('AttachmentData adds the payload to the metadata wire shape', () {
      const model = AttachmentData(
        id: 'att_1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: 5,
        data: 'aGVsbG8=',
      );
      final json = model.toJson();
      expect(json['data'], 'aGVsbG8=');
      expect(json['mimeType'], 'text/plain');
      final decoded = AttachmentData.fromJson(json);
      expect(decoded.data, 'aGVsbG8=');
      expect(decoded.name, 'notes.txt');
      expect(decoded.toJson(), json);
    });

    test('OutgoingAttachment roundtrip', () {
      const model = OutgoingAttachment(
        name: 'a.bin',
        mimeType: 'application/octet-stream',
        data: 'AAE=',
      );
      final decoded = OutgoingAttachment.fromJson(model.toJson());
      expect(decoded.name, 'a.bin');
      expect(decoded.mimeType, 'application/octet-stream');
      expect(decoded.data, 'AAE=');
      expect(decoded.toJson(), model.toJson());
    });
    test('McpServerProfile redacted credential roundtrip', () {
      final McpServerProfile model = McpServerProfile(
        id: 'mcp-1',
        projectId: 'project-1',
        name: 'GitHub',
        transport: McpTransport.http,
        enabled: true,
        url: 'https://example.test/mcp',
        secretNames: const <String>['Authorization'],
        createdAt: DateTime.utc(2026, 8, 20),
        updatedAt: DateTime.utc(2026, 8, 20, 1),
        authType: McpAuthType.oauth,
        oauthStatus: McpOAuthStatus.authorized,
        oauthClientId: 'client-1',
        oauthClientSecretConfigured: true,
        oauthScopes: const <String>['mcp:tools'],
        oauthExpiresAt: DateTime.utc(2026, 8, 20, 2),
      );
      final McpServerProfile decoded = McpServerProfile.fromJson(
        model.toJson(),
      );
      expect(decoded.projectId, 'project-1');
      expect(decoded.transport, McpTransport.http);
      expect(decoded.url, 'https://example.test/mcp');
      expect(decoded.command, isNull);
      expect(decoded.secretNames, const <String>['Authorization']);
      expect(decoded.authType, McpAuthType.oauth);
      expect(decoded.oauthStatus, McpOAuthStatus.authorized);
      expect(decoded.oauthClientId, 'client-1');
      expect(decoded.oauthClientSecretConfigured, isTrue);
      expect(decoded.oauthScopes, const <String>['mcp:tools']);
      expect(decoded.toJson(), model.toJson());
      expect(decoded.toJson(), isNot(contains('secrets')));
    });
    test('McpOAuthFlow roundtrip', () {
      const McpOAuthFlow flow = McpOAuthFlow(
        flowId: 'flow-1',
        authorizationUrl: 'https://auth.example/authorize?state=flow-1',
      );
      expect(McpOAuthFlow.fromJson(flow.toJson()).toJson(), flow.toJson());
    });
  });

  group('attachment MIME helpers', () {
    test('mimeTypeForFileName maps known extensions case-insensitively', () {
      expect(mimeTypeForFileName('shot.PNG'), 'image/png');
      expect(mimeTypeForFileName('photo.jpeg'), 'image/jpeg');
      expect(mimeTypeForFileName('doc.pdf'), 'application/pdf');
      expect(mimeTypeForFileName('data.yaml'), 'application/yaml');
      expect(mimeTypeForFileName('main.dart'), 'text/plain');
      expect(mimeTypeForFileName('archive.tar.gz'), 'application/gzip');
    });

    test(
      'mimeTypeForFileName falls back for unknown or missing extensions',
      () {
        expect(mimeTypeForFileName('README'), 'application/octet-stream');
        expect(mimeTypeForFileName('trailing.'), 'application/octet-stream');
        expect(mimeTypeForFileName('x.weirdext'), 'application/octet-stream');
      },
    );

    test('isImageMimeType / isTextMimeType classify', () {
      expect(isImageMimeType('image/png'), isTrue);
      expect(isImageMimeType('IMAGE/JPEG'), isTrue);
      expect(isImageMimeType('text/plain'), isFalse);

      expect(isTextMimeType('text/plain'), isTrue);
      expect(isTextMimeType('application/json'), isTrue);
      expect(isTextMimeType('application/ld+json'), isTrue);
      expect(isTextMimeType('image/svg+xml'), isTrue);
      expect(isTextMimeType('application/octet-stream'), isFalse);
      expect(isTextMimeType('image/png'), isFalse);
    });
  });
}
