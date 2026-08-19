/// Wire models from PROTOCOL.md: hand-written JSON, no codegen.
///
/// All timestamps are ISO-8601 UTC strings on the wire and [DateTime] (UTC)
/// in memory. Enums serialize via `wire` (name-based except where PROTOCOL.md
/// overrides the spelling) and parse via `parse`, which throws [FormatException]
/// on unknown values.
library;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Lifecycle state of a session.
enum SessionStatus {
  idle,
  running,
  waitingPermission,
  error,
  closed;

  /// Wire value; `waitingPermission` is the only non-name spelling.
  String get wire => switch (this) {
        SessionStatus.idle => 'idle',
        SessionStatus.running => 'running',
        SessionStatus.waitingPermission => 'waitingPermission',
        SessionStatus.error => 'error',
        SessionStatus.closed => 'closed',
      };

  static SessionStatus parse(String value) => switch (value) {
        'idle' => SessionStatus.idle,
        'running' => SessionStatus.running,
        'waitingPermission' => SessionStatus.waitingPermission,
        'error' => SessionStatus.error,
        'closed' => SessionStatus.closed,
        _ => throw FormatException('Unknown SessionStatus: "$value"'),
      };
}

/// What a session is doing: executing changes or planning only.
enum SessionMode {
  build,
  plan;

  String get wire => switch (this) {
        SessionMode.build => 'build',
        SessionMode.plan => 'plan',
      };

  static SessionMode parse(String value) => switch (value) {
        'build' => SessionMode.build,
        'plan' => SessionMode.plan,
        _ => throw FormatException('Unknown SessionMode: "$value"'),
      };
}

/// Execution state of a tool call.
enum ToolCallStatus {
  pending,
  running,
  completed,
  failed;

  String get wire => switch (this) {
        ToolCallStatus.pending => 'pending',
        ToolCallStatus.running => 'running',
        ToolCallStatus.completed => 'completed',
        ToolCallStatus.failed => 'failed',
      };

  static ToolCallStatus parse(String value) => switch (value) {
        'pending' => ToolCallStatus.pending,
        'running' => ToolCallStatus.running,
        'completed' => ToolCallStatus.completed,
        'failed' => ToolCallStatus.failed,
        _ => throw FormatException('Unknown ToolCallStatus: "$value"'),
      };
}

/// Priority of a plan step.
enum PlanPriority {
  high,
  medium,
  low;

  String get wire => switch (this) {
        PlanPriority.high => 'high',
        PlanPriority.medium => 'medium',
        PlanPriority.low => 'low',
      };

  static PlanPriority parse(String value) => switch (value) {
        'high' => PlanPriority.high,
        'medium' => PlanPriority.medium,
        'low' => PlanPriority.low,
        _ => throw FormatException('Unknown PlanPriority: "$value"'),
      };
}

/// Progress state of a plan step; `inProgress` serializes as `in_progress`.
enum PlanEntryStatus {
  pending,
  inProgress,
  completed;

  String get wire => switch (this) {
        PlanEntryStatus.pending => 'pending',
        PlanEntryStatus.inProgress => 'in_progress',
        PlanEntryStatus.completed => 'completed',
      };

  static PlanEntryStatus parse(String value) => switch (value) {
        'pending' => PlanEntryStatus.pending,
        'in_progress' => PlanEntryStatus.inProgress,
        'completed' => PlanEntryStatus.completed,
        _ => throw FormatException('Unknown PlanEntryStatus: "$value"'),
      };
}

/// How a permission request option resolves; snake_case on the wire.
enum PermissionKind {
  allowOnce,
  allowAlways,
  rejectOnce,
  rejectAlways;

  String get wire => switch (this) {
        PermissionKind.allowOnce => 'allow_once',
        PermissionKind.allowAlways => 'allow_always',
        PermissionKind.rejectOnce => 'reject_once',
        PermissionKind.rejectAlways => 'reject_always',
      };

  static PermissionKind parse(String value) => switch (value) {
        'allow_once' => PermissionKind.allowOnce,
        'allow_always' => PermissionKind.allowAlways,
        'reject_once' => PermissionKind.rejectOnce,
        'reject_always' => PermissionKind.rejectAlways,
        _ => throw FormatException('Unknown PermissionKind: "$value"'),
      };
}

// ---------------------------------------------------------------------------
// Tool call content
// ---------------------------------------------------------------------------

/// One piece of a tool call's content, discriminated on `type`.
sealed class ToolCallContent {
  const ToolCallContent();

  factory ToolCallContent.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'text' => ToolCallText.fromJson(json),
        'diff' => ToolCallDiff.fromJson(json),
        'terminal' => ToolCallTerminal.fromJson(json),
        _ => throw FormatException(
            'Unknown ToolCallContent type: ${json['type']}'),
      };

  Map<String, Object?> toJson();
}

/// Plain text content of a tool call.
class ToolCallText extends ToolCallContent {
  const ToolCallText({required this.text});

  final String text;

  factory ToolCallText.fromJson(Map<String, Object?> json) =>
      ToolCallText(text: json['text']! as String);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'text',
        'text': text,
      };
}

/// File edit content of a tool call.
class ToolCallDiff extends ToolCallContent {
  const ToolCallDiff({
    required this.path,
    required this.oldText,
    required this.newText,
  });

  final String path;

  /// Original content before the edit; null for new files.
  final String? oldText;

  final String newText;

  factory ToolCallDiff.fromJson(Map<String, Object?> json) => ToolCallDiff(
        path: json['path']! as String,
        oldText: json['oldText'] as String?,
        newText: json['newText']! as String,
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'diff',
        'path': path,
        'oldText': oldText,
        'newText': newText,
      };
}

/// Terminal output content of a tool call.
class ToolCallTerminal extends ToolCallContent {
  const ToolCallTerminal({required this.terminalId, required this.output});

  final String terminalId;

  /// Raw output, typically a trailing window of the terminal buffer.
  final String output;

  factory ToolCallTerminal.fromJson(Map<String, Object?> json) =>
      ToolCallTerminal(
        terminalId: json['terminalId']! as String,
        output: json['output']! as String,
      );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': 'terminal',
        'terminalId': terminalId,
        'output': output,
      };
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A tool call made by the agent: created or updated via `toolCall` events.
class ToolCall {
  const ToolCall({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.content,
    required this.locations,
    this.rawInput,
    this.rawOutput,
  });

  final String id;
  final String title;

  /// "read" | "edit" | "delete" | "move" | "search" | "execute" | "think"
  /// | "fetch" | "other". Plain string, not an enum.
  final String kind;

  final ToolCallStatus status;
  final List<ToolCallContent> content;

  /// File paths touched, relative to the session cwd. May be empty.
  final List<String> locations;

  /// Original structured input passed to the tool, if any.
  final Object? rawInput;

  /// Original structured output of the tool, if any.
  final Object? rawOutput;

  factory ToolCall.fromJson(Map<String, Object?> json) => ToolCall(
        id: json['id']! as String,
        title: json['title']! as String,
        kind: json['kind']! as String,
        status: ToolCallStatus.parse(json['status']! as String),
        content: (json['content']! as List<Object?>)
            .map((e) => ToolCallContent.fromJson(e! as Map<String, Object?>))
            .toList(growable: false),
        locations: (json['locations']! as List<Object?>)
            .map((e) => e! as String)
            .toList(growable: false),
        rawInput: json['rawInput'],
        rawOutput: json['rawOutput'],
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'kind': kind,
        'status': status.wire,
        'content': content.map((e) => e.toJson()).toList(growable: false),
        'locations': locations,
        'rawInput': rawInput,
        'rawOutput': rawOutput,
      };
}

/// One step of an agent plan.
class PlanEntry {
  const PlanEntry({
    required this.content,
    required this.priority,
    required this.status,
  });

  final String content;
  final PlanPriority priority;
  final PlanEntryStatus status;

  factory PlanEntry.fromJson(Map<String, Object?> json) => PlanEntry(
        content: json['content']! as String,
        priority: PlanPriority.parse(json['priority']! as String),
        status: PlanEntryStatus.parse(json['status']! as String),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'content': content,
        'priority': priority.wire,
        'status': status.wire,
      };
}

/// One selectable option of a permission request.
class PermissionOption {
  const PermissionOption({
    required this.optionId,
    required this.name,
    required this.kind,
  });

  final String optionId;

  /// Display label for the option.
  final String name;

  final PermissionKind kind;

  factory PermissionOption.fromJson(Map<String, Object?> json) =>
      PermissionOption(
        optionId: json['optionId']! as String,
        name: json['name']! as String,
        kind: PermissionKind.parse(json['kind']! as String),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'optionId': optionId,
        'name': name,
        'kind': kind.wire,
      };
}

/// A request from the agent for the user to allow/reject a pending action.
class PermissionRequest {
  const PermissionRequest({
    required this.requestId,
    required this.toolCallId,
    required this.title,
    required this.options,
  });

  final String requestId;

  /// Id of the tool call awaiting permission, when applicable.
  final String? toolCallId;

  final String title;
  final List<PermissionOption> options;

  factory PermissionRequest.fromJson(Map<String, Object?> json) =>
      PermissionRequest(
        requestId: json['requestId']! as String,
        toolCallId: json['toolCallId'] as String?,
        title: json['title']! as String,
        options: (json['options']! as List<Object?>)
            .map((e) => PermissionOption.fromJson(e! as Map<String, Object?>))
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'requestId': requestId,
        'toolCallId': toolCallId,
        'title': title,
        'options': options.map((e) => e.toJson()).toList(growable: false),
      };
}

/// Token usage of a turn; `cost` is a decimal USD string when known.
class UsageInfo {
  const UsageInfo({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.cost,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final String? cost;

  factory UsageInfo.fromJson(Map<String, Object?> json) => UsageInfo(
        inputTokens: json['inputTokens']! as int,
        outputTokens: json['outputTokens']! as int,
        totalTokens: json['totalTokens']! as int,
        cost: json['cost'] as String?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': totalTokens,
        'cost': cost,
      };
}

/// A conversation session bound to one provider/model.
class Session {
  const Session({
    required this.id,
    required this.projectId,
    required this.providerId,
    required this.title,
    required this.status,
    required this.mode,
    required this.model,
    required this.cwd,
    required this.baseBranch,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String providerId;
  final String title;
  final SessionStatus status;
  final SessionMode mode;

  /// Selected model id, null while unset/auto.
  final String? model;

  /// Working dir of the agent (project path or worktree).
  final String cwd;

  /// Base branch the session's worktree was created from; null for
  /// non-worktree sessions.
  final String? baseBranch;

  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Session.fromJson(Map<String, Object?> json) => Session(
        id: json['id']! as String,
        projectId: json['projectId']! as String,
        providerId: json['providerId']! as String,
        title: json['title']! as String,
        status: SessionStatus.parse(json['status']! as String),
        mode: SessionMode.parse(json['mode']! as String),
        model: json['model'] as String?,
        cwd: json['cwd']! as String,
        baseBranch: json['baseBranch'] as String?,
        archived: json['archived']! as bool,
        createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
        updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'projectId': projectId,
        'providerId': providerId,
        'title': title,
        'status': status.wire,
        'mode': mode.wire,
        'model': model,
        'cwd': cwd,
        'baseBranch': baseBranch,
        'archived': archived,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// An entry in a project's file listing.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.modifiedAt,
  });

  final String name;

  /// Path relative to the project root.
  final String path;

  final bool isDir;

  /// Size in bytes; 0 for directories.
  final int size;

  final DateTime modifiedAt;

  factory FileEntry.fromJson(Map<String, Object?> json) => FileEntry(
        name: json['name']! as String,
        path: json['path']! as String,
        isDir: json['isDir']! as bool,
        size: json['size']! as int,
        modifiedAt: DateTime.parse(json['modifiedAt']! as String).toUtc(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'path': path,
        'isDir': isDir,
        'size': size,
        'modifiedAt': modifiedAt.toUtc().toIso8601String(),
      };
}

/// Result of `fs.read`.
class FileReadResult {
  const FileReadResult({
    required this.content,
    required this.truncated,
    required this.isBinary,
  });

  final String content;
  final bool truncated;
  final bool isBinary;

  factory FileReadResult.fromJson(Map<String, Object?> json) => FileReadResult(
        content: json['content']! as String,
        truncated: json['truncated']! as bool,
        isBinary: json['isBinary']! as bool,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'content': content,
        'truncated': truncated,
        'isBinary': isBinary,
      };
}

/// One file's git state, as reported by `git status --porcelain=v2`.
class GitStatusFile {
  const GitStatusFile({
    required this.path,
    required this.indexStatus,
    required this.worktreeStatus,
    required this.staged,
  });

  /// File path relative to the repo root.
  final String path;

  /// Index status code (XY pair first char, e.g. "M", "." when unchanged).
  final String indexStatus;

  /// Worktree status code (XY pair second char, e.g. "M", "." when unchanged).
  final String worktreeStatus;

  /// Whether the change is staged in the index.
  final bool staged;

  factory GitStatusFile.fromJson(Map<String, Object?> json) => GitStatusFile(
        path: json['path']! as String,
        indexStatus: json['indexStatus']! as String,
        worktreeStatus: json['worktreeStatus']! as String,
        staged: json['staged']! as bool,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'indexStatus': indexStatus,
        'worktreeStatus': worktreeStatus,
        'staged': staged,
      };
}

/// Repository status: current branch, divergence, and changed files.
class GitStatus {
  const GitStatus({
    required this.branch,
    required this.ahead,
    required this.behind,
    required this.files,
  });

  final String branch;

  /// Commits the local branch leads its upstream by.
  final int ahead;

  /// Commits the local branch trails its upstream by.
  final int behind;

  final List<GitStatusFile> files;

  factory GitStatus.fromJson(Map<String, Object?> json) => GitStatus(
        branch: json['branch']! as String,
        ahead: json['ahead']! as int,
        behind: json['behind']! as int,
        files: (json['files']! as List<Object?>)
            .map((e) => GitStatusFile.fromJson(e! as Map<String, Object?>))
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'branch': branch,
        'ahead': ahead,
        'behind': behind,
        'files': files.map((e) => e.toJson()).toList(growable: false),
      };
}

/// A unified diff for a single file.
class GitDiff {
  const GitDiff({
    required this.path,
    required this.patch,
    required this.isNew,
    required this.isDeleted,
    required this.isBinary,
  });

  /// File path relative to the repo root.
  final String path;

  /// Unified diff text without color codes.
  final String patch;

  final bool isNew;
  final bool isDeleted;

  /// Binary files carry no patch; the UI shows a placeholder instead.
  final bool isBinary;

  factory GitDiff.fromJson(Map<String, Object?> json) => GitDiff(
        path: json['path']! as String,
        patch: json['patch']! as String,
        isNew: json['isNew']! as bool,
        isDeleted: json['isDeleted']! as bool,
        isBinary: json['isBinary']! as bool,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'patch': patch,
        'isNew': isNew,
        'isDeleted': isDeleted,
        'isBinary': isBinary,
      };
}

/// A git branch in a project's repository.
class Branch {
  const Branch({required this.name, required this.isCurrent, this.upstream});

  final String name;

  /// Whether this is the checked-out branch.
  final bool isCurrent;

  /// Upstream tracking branch ("origin/main"), null when none.
  final String? upstream;

  factory Branch.fromJson(Map<String, Object?> json) => Branch(
        name: json['name']! as String,
        isCurrent: json['isCurrent']! as bool,
        upstream: json['upstream'] as String?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'isCurrent': isCurrent,
        'upstream': upstream,
      };
}

/// Outcome of `git.mergeToBase`: the session's worktree branch merged back
/// into the base branch the session was created from.
class MergeResult {
  const MergeResult({
    required this.baseBranch,
    required this.sessionBranch,
    required this.baseFastForwarded,
    required this.alreadyUpToDate,
    required this.fastForward,
    required this.commit,
  });

  /// Branch that received the merge.
  final String baseBranch;

  /// Worktree branch that was merged in.
  final String sessionBranch;

  /// Whether the local base was first fast-forwarded to `origin/<base>`
  /// because the remote-tracking ref was strictly ahead.
  final bool baseFastForwarded;

  /// Whether the base already contained every session commit (no-op merge).
  final bool alreadyUpToDate;

  /// Whether the merge resolved by moving the base ref (no merge commit).
  final bool fastForward;

  /// Resulting tip commit of [baseBranch].
  final String commit;

  factory MergeResult.fromJson(Map<String, Object?> json) => MergeResult(
        baseBranch: json['baseBranch']! as String,
        sessionBranch: json['sessionBranch']! as String,
        baseFastForwarded: json['baseFastForwarded']! as bool,
        alreadyUpToDate: json['alreadyUpToDate']! as bool,
        fastForward: json['fastForward']! as bool,
        commit: json['commit']! as String,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'baseBranch': baseBranch,
        'sessionBranch': sessionBranch,
        'baseFastForwarded': baseFastForwarded,
        'alreadyUpToDate': alreadyUpToDate,
        'fastForward': fastForward,
        'commit': commit,
      };
}

/// Outcome of `git.rebaseOntoBase`: the session's worktree branch rebased
/// onto the base branch the session was created from.
class RebaseResult {
  const RebaseResult({
    required this.baseBranch,
    required this.sessionBranch,
    required this.baseFastForwarded,
    required this.alreadyUpToDate,
    required this.commit,
  });

  /// Branch the session branch was rebased onto.
  final String baseBranch;

  /// Worktree branch that was rebased.
  final String sessionBranch;

  /// Whether the local base was first fast-forwarded to `origin/<base>`
  /// because the remote-tracking ref was strictly ahead.
  final bool baseFastForwarded;

  /// Whether the session branch already contained the base tip (no-op
  /// rebase).
  final bool alreadyUpToDate;

  /// Resulting tip commit of [sessionBranch].
  final String commit;

  factory RebaseResult.fromJson(Map<String, Object?> json) => RebaseResult(
        baseBranch: json['baseBranch']! as String,
        sessionBranch: json['sessionBranch']! as String,
        baseFastForwarded: json['baseFastForwarded']! as bool,
        alreadyUpToDate: json['alreadyUpToDate']! as bool,
        commit: json['commit']! as String,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'baseBranch': baseBranch,
        'sessionBranch': sessionBranch,
        'baseFastForwarded': baseFastForwarded,
        'alreadyUpToDate': alreadyUpToDate,
        'commit': commit,
      };
}

/// Per-session git summary for the left rail (see `git.sessionSummaries`):
/// uncommitted changes in the session's cwd, plus — for sessions created
/// with a `baseBranch` — how the session branch relates to its base.
///
/// Computed from local git state only (no fetch): `origin` refs are used
/// as-is, however stale. Every field is nullable: null means "unknown"
/// (e.g. the session's cwd is gone or is not a git repository) or, for
/// [aheadOfBase]/[mergedIntoBase], "not applicable" (no base branch).
class SessionGitSummary {
  const SessionGitSummary({
    required this.sessionId,
    required this.dirty,
    required this.aheadOfBase,
    required this.mergedIntoBase,
  });

  final String sessionId;

  /// Whether the session's cwd has uncommitted changes (staged, unstaged or
  /// untracked). Null when the directory could not be queried.
  final bool? dirty;

  /// Commits on the session branch contained in neither the local base
  /// branch nor its `origin` ref. Null when the session has no base branch
  /// or the count could not be determined.
  final int? aheadOfBase;

  /// Whether every commit the session branch gained since its creation is
  /// contained in the base branch (local or `origin`). False while any
  /// commit is unmerged, and false while the branch never gained a commit
  /// of its own (nothing to merge). Null like [aheadOfBase].
  final bool? mergedIntoBase;

  factory SessionGitSummary.fromJson(Map<String, Object?> json) =>
      SessionGitSummary(
        sessionId: json['sessionId']! as String,
        dirty: json['dirty'] as bool?,
        aheadOfBase: json['aheadOfBase'] as int?,
        mergedIntoBase: json['mergedIntoBase'] as bool?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'sessionId': sessionId,
        'dirty': dirty,
        'aheadOfBase': aheadOfBase,
        'mergedIntoBase': mergedIntoBase,
      };
}

/// An added project on the daemon host.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.path,
    required this.addedAt,
    required this.lastActiveAt,
  });

  final String id;
  final String name;

  /// Absolute path on the daemon host.
  final String path;

  final DateTime addedAt;
  final DateTime lastActiveAt;

  factory Project.fromJson(Map<String, Object?> json) => Project(
        id: json['id']! as String,
        name: json['name']! as String,
        path: json['path']! as String,
        addedAt: DateTime.parse(json['addedAt']! as String).toUtc(),
        lastActiveAt: DateTime.parse(json['lastActiveAt']! as String).toUtc(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'path': path,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'lastActiveAt': lastActiveAt.toUtc().toIso8601String(),
      };
}

/// A provider that can run agent sessions.
class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    required this.available,
    required this.command,
    required this.models,
  });

  /// "omp" | "claude" | "codex" | custom id.
  final String id;

  /// Display name.
  final String name;

  /// Whether the provider's command is resolvable on this host.
  final bool available;

  /// Resolved spawn command (display/debug).
  final String command;

  /// Selectable model ids; may be empty.
  final List<String> models;

  factory ProviderInfo.fromJson(Map<String, Object?> json) => ProviderInfo(
        id: json['id']! as String,
        name: json['name']! as String,
        available: json['available']! as bool,
        command: json['command']! as String,
        models: (json['models']! as List<Object?>)
            .map((e) => e! as String)
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'available': available,
        'command': command,
        'models': models,
      };
}

/// Static daemon identity handed out at connect/auth time.
class DaemonInfo {
  const DaemonInfo({
    required this.version,
    required this.protocolVersion,
    required this.authRequired,
    required this.providers,
  });

  /// Daemon semver.
  final String version;

  /// Wire protocol version; currently 1.
  final int protocolVersion;

  /// Whether the daemon requires a token for connections.
  final bool authRequired;

  final List<ProviderInfo> providers;

  factory DaemonInfo.fromJson(Map<String, Object?> json) => DaemonInfo(
        version: json['version']! as String,
        protocolVersion: json['protocolVersion']! as int,
        authRequired: json['authRequired']! as bool,
        providers: (json['providers']! as List<Object?>)
            .map((e) => ProviderInfo.fromJson(e! as Map<String, Object?>))
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'protocolVersion': protocolVersion,
        'authRequired': authRequired,
        'providers': providers.map((e) => e.toJson()).toList(growable: false),
      };
}
