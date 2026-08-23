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

/// Filesystem/network isolation applied to a provider session.
///
/// Providers advertise supported values through [ProviderInfo.sandboxModes].
enum SessionSandboxMode {
  workspaceWrite,
  unrestricted;

  String get wire => name;

  static SessionSandboxMode parse(String value) => switch (value) {
    'workspaceWrite' => SessionSandboxMode.workspaceWrite,
    'unrestricted' => SessionSandboxMode.unrestricted,
    _ => throw FormatException('Unknown SessionSandboxMode: "$value"'),
  };
}

/// Lifecycle state of a provider-reported background activity.
enum AgentActivityStatus {
  running,
  completed,
  failed;

  String get wire => name;

  static AgentActivityStatus parse(String value) => switch (value) {
    'running' => AgentActivityStatus.running,
    'completed' => AgentActivityStatus.completed,
    'failed' => AgentActivityStatus.failed,
    _ => throw FormatException('Unknown AgentActivityStatus: "$value"'),
  };
}

/// Transport used to connect an ACP agent to an MCP server.
enum McpTransport {
  stdio,
  http;

  String get wire => name;

  static McpTransport parse(String value) => switch (value) {
    'stdio' => McpTransport.stdio,
    'http' => McpTransport.http,
    _ => throw FormatException('Unknown McpTransport: "$value"'),
  };
}

/// Authentication managed by SpeedDial for an HTTP MCP server.
enum McpAuthType {
  none,
  oauth;

  String get wire => name;

  static McpAuthType parse(String value) => switch (value) {
    'none' => McpAuthType.none,
    'oauth' => McpAuthType.oauth,
    _ => throw FormatException('Unknown McpAuthType: "$value"'),
  };
}

/// Last known daemon-side OAuth state for an HTTP MCP server.
enum McpOAuthStatus {
  notConnected,
  authorizing,
  authorized,
  expired,
  error;

  String get wire => switch (this) {
    McpOAuthStatus.notConnected => 'not_connected',
    McpOAuthStatus.authorizing => 'authorizing',
    McpOAuthStatus.authorized => 'authorized',
    McpOAuthStatus.expired => 'expired',
    McpOAuthStatus.error => 'error',
  };

  static McpOAuthStatus parse(String value) => switch (value) {
    'not_connected' => McpOAuthStatus.notConnected,
    'authorizing' => McpOAuthStatus.authorizing,
    'authorized' => McpOAuthStatus.authorized,
    'expired' => McpOAuthStatus.expired,
    'error' => McpOAuthStatus.error,
    _ => throw FormatException('Unknown McpOAuthStatus: "$value"'),
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
        'patch' => ToolCallPatch.fromJson(json),
        'terminal' => ToolCallTerminal.fromJson(json),
        _ => throw FormatException(
          'Unknown ToolCallContent type: ${json['type']}',
        ),
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

/// A provider-supplied unified diff for one file.
///
/// Unlike [ToolCallDiff], this preserves hunk headers and context lines
/// exactly as reported by providers with native patch events.
class ToolCallPatch extends ToolCallContent {
  const ToolCallPatch({required this.path, required this.diff});

  final String path;
  final String diff;

  factory ToolCallPatch.fromJson(Map<String, Object?> json) => ToolCallPatch(
    path: json['path']! as String,
    diff: json['diff']! as String,
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'patch',
    'path': path,
    'diff': diff,
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

/// Token usage of a turn plus optional context-window measurements.
class UsageInfo {
  const UsageInfo({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.cost,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    this.contextUsedTokens,
    this.contextLimitTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final String? cost;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
  final int? contextUsedTokens;
  final int? contextLimitTokens;

  factory UsageInfo.fromJson(Map<String, Object?> json) => UsageInfo(
    inputTokens: json['inputTokens']! as int,
    outputTokens: json['outputTokens']! as int,
    totalTokens: json['totalTokens']! as int,
    cost: json['cost'] as String?,
    cacheReadTokens: json['cacheReadTokens'] as int?,
    cacheCreationTokens: json['cacheCreationTokens'] as int?,
    contextUsedTokens: json['contextUsedTokens'] as int?,
    contextLimitTokens: json['contextLimitTokens'] as int?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'totalTokens': totalTokens,
    'cost': cost,
    if (cacheReadTokens != null) 'cacheReadTokens': cacheReadTokens,
    if (cacheCreationTokens != null) 'cacheCreationTokens': cacheCreationTokens,
    if (contextUsedTokens != null) 'contextUsedTokens': contextUsedTokens,
    if (contextLimitTokens != null) 'contextLimitTokens': contextLimitTokens,
  };
}

/// A provider-reported lifecycle or background activity.
///
/// Later events with the same [id] replace the prior timeline snapshot.
class AgentActivity {
  const AgentActivity({
    required this.id,
    required this.kind,
    required this.title,
    required this.status,
    this.details = const <String>[],
  });

  final String id;

  /// Provider-neutral category such as `session`, `extensions`, `info`, or
  /// `compaction`.
  final String kind;
  final String title;
  final AgentActivityStatus status;
  final List<String> details;

  factory AgentActivity.fromJson(Map<String, Object?> json) => AgentActivity(
    id: json['id']! as String,
    kind: json['kind']! as String,
    title: json['title']! as String,
    status: AgentActivityStatus.parse(json['status']! as String),
    details:
        (json['details'] as List<Object?>?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'title': title,
    'status': status.wire,
    'details': details,
  };
}

/// The title a session carries when created without an explicit one
/// (`sessions.create` without `title`). The daemon replaces it with a
/// title derived from the session's first user message (see PROTOCOL.md
/// `sessions.send`).
const String kDefaultSessionTitle = 'New session';

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
    this.models = const <String>[],
    required this.cwd,
    required this.baseBranch,
    this.thinkingLevel,
    this.thinkingLevels = const <String>[],
    this.sandboxMode,
    required this.yolo,
    required this.archived,
    required this.createdAt,
    DateTime? lastActivityAt,
    required this.updatedAt,
  }) : lastActivityAt = lastActivityAt ?? createdAt;

  final String id;
  final String projectId;
  final String providerId;
  final String title;
  final SessionStatus status;
  final SessionMode mode;

  /// Current model id — agent-reported when the provider advertises a model
  /// config option (ACP), otherwise a locally persisted preference; null
  /// while unset.
  final String? model;

  /// Selectable model ids advertised by the agent (ACP config option);
  /// empty when the provider has no model option.
  final List<String> models;

  /// Working dir of the agent (project path or worktree).
  final String cwd;

  /// Base branch the session's worktree was created from; null for
  /// non-worktree sessions.
  final String? baseBranch;

  /// Current agent thinking level (e.g. omp's `auto`); null when the
  /// provider exposes no thinking-level option.
  final String? thinkingLevel;

  /// Selectable thinking levels advertised by the agent (ACP config
  /// option); empty when the provider has no thinking-level option.
  final List<String> thinkingLevels;

  /// Provider sandbox selection; null when the provider manages isolation.
  final SessionSandboxMode? sandboxMode;

  /// Yolo mode: the daemon auto-approves the agent's permission requests.
  final bool yolo;

  final bool archived;
  final DateTime createdAt;
  final DateTime lastActivityAt;
  final DateTime updatedAt;

  factory Session.fromJson(Map<String, Object?> json) => Session(
    id: json['id']! as String,
    projectId: json['projectId']! as String,
    providerId: json['providerId']! as String,
    title: json['title']! as String,
    status: SessionStatus.parse(json['status']! as String),
    mode: SessionMode.parse(json['mode']! as String),
    model: json['model'] as String?,
    // Absent on pre-config-option daemons.
    models:
        (json['models'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
    cwd: json['cwd']! as String,
    baseBranch: json['baseBranch'] as String?,
    // Absent on pre-thinking-level daemons.
    thinkingLevel: json['thinkingLevel'] as String?,
    thinkingLevels:
        (json['thinkingLevels'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const <String>[],
    sandboxMode: json['sandboxMode'] == null
        ? null
        : SessionSandboxMode.parse(json['sandboxMode']! as String),
    // Absent on pre-yolo daemons.
    yolo: json['yolo'] as bool? ?? false,
    archived: json['archived']! as bool,
    createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
    lastActivityAt: DateTime.parse(
      (json['lastActivityAt'] ?? json['updatedAt'])! as String,
    ).toUtc(),
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
    'models': models,
    'cwd': cwd,
    'baseBranch': baseBranch,
    'thinkingLevel': thinkingLevel,
    'thinkingLevels': thinkingLevels,
    'sandboxMode': sandboxMode?.wire,
    'yolo': yolo,
    'archived': archived,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastActivityAt': lastActivityAt.toUtc().toIso8601String(),
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
/// Computed from local git state only (no fetch happens as part of the
/// request): `origin` refs are used as-is, however stale. Every field is
/// nullable: null means "unknown" (e.g. the session's cwd is gone or is not
/// a git repository) or, for the base-branch fields, "not applicable" (no
/// base branch).
class SessionGitSummary {
  const SessionGitSummary({
    required this.sessionId,
    required this.dirty,
    required this.aheadOfBase,
    required this.mergedIntoBase,
    required this.behindBase,
  });

  final String sessionId;

  /// Whether the session's cwd has uncommitted changes (staged, unstaged or
  /// untracked). Null when the directory could not be queried.
  final bool? dirty;

  /// Commits on the session branch contained in neither the local base
  /// branch nor its `origin` ref. Null when the session has no base branch
  /// or the count could not be determined.
  final int? aheadOfBase;

  /// Commits reachable from the base branch (local or `origin`) but not
  /// from the session branch. Null like [aheadOfBase].
  final int? behindBase;

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
        behindBase: json['behindBase'] as int?,
        mergedIntoBase: json['mergedIntoBase'] as bool?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'dirty': dirty,
    'aheadOfBase': aheadOfBase,
    'behindBase': behindBase,
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
    this.protocol = 'acp',
    this.sandboxModes = const <SessionSandboxMode>[],
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

  /// Wire protocol spoken by the provider: "acp" | "codex" | "ante".
  /// Clients use it to know where model selection lives: ACP and Codex
  /// advertise config options on the live session (composer picker), while
  /// Ante pins the upstream provider at creation, so its models are picked
  /// in the new-session sheet.
  final String protocol;

  /// Isolation modes selectable when creating sessions with this provider.
  final List<SessionSandboxMode> sandboxModes;

  factory ProviderInfo.fromJson(Map<String, Object?> json) => ProviderInfo(
    id: json['id']! as String,
    name: json['name']! as String,
    available: json['available']! as bool,
    command: json['command']! as String,
    models: (json['models']! as List<Object?>)
        .map((e) => e! as String)
        .toList(growable: false),
    protocol: json['protocol'] as String? ?? 'acp',
    sandboxModes:
        (json['sandboxModes'] as List<Object?>?)
            ?.map((Object? value) => SessionSandboxMode.parse(value! as String))
            .toList(growable: false) ??
        const <SessionSandboxMode>[],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'available': available,
    'command': command,
    'models': models,
    'protocol': protocol,
    'sandboxModes': sandboxModes
        .map((SessionSandboxMode mode) => mode.wire)
        .toList(growable: false),
  };
}

/// An installed coding-agent CLI managed by the daemon.
class HarnessInfo {
  const HarnessInfo({
    required this.id,
    required this.name,
    required this.version,
  });

  /// Stable built-in id: "omp", "claude", "codex", or "ante".
  final String id;

  /// Human-readable CLI name.
  final String name;

  /// The installed CLI's version output, normalized to one line.
  final String version;

  factory HarnessInfo.fromJson(Map<String, Object?> json) => HarnessInfo(
    id: json['id']! as String,
    name: json['name']! as String,
    version: json['version']! as String,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'version': version,
  };
}

/// Daemon-managed MCP server configuration.
///
/// Secret environment/header values never appear on the wire. Only their
/// names are returned so clients can preserve, replace, or remove them.
class McpServerProfile {
  const McpServerProfile({
    required this.id,
    required this.name,
    required this.transport,
    required this.enabled,
    required this.secretNames,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.command,
    this.args = const <String>[],
    this.url,
    this.authType = McpAuthType.none,
    this.oauthStatus = McpOAuthStatus.notConnected,
    this.oauthClientId,
    this.oauthClientSecretConfigured = false,
    this.oauthScopes = const <String>[],
    this.oauthExpiresAt,
    this.oauthError,
  });

  final String id;

  /// Project receiving this server, or null when daemon-wide.
  final String? projectId;
  final String name;
  final McpTransport transport;
  final bool enabled;
  final String? command;
  final List<String> args;
  final String? url;
  final List<String> secretNames;
  final DateTime createdAt;
  final DateTime updatedAt;
  final McpAuthType authType;
  final McpOAuthStatus oauthStatus;
  final String? oauthClientId;
  final bool oauthClientSecretConfigured;
  final List<String> oauthScopes;
  final DateTime? oauthExpiresAt;
  final String? oauthError;

  factory McpServerProfile.fromJson(Map<String, Object?> json) =>
      McpServerProfile(
        id: json['id']! as String,
        projectId: json['projectId'] as String?,
        name: json['name']! as String,
        transport: McpTransport.parse(json['transport']! as String),
        enabled: json['enabled']! as bool,
        command: json['command'] as String?,
        args: (json['args']! as List<Object?>)
            .map((Object? value) => value! as String)
            .toList(growable: false),
        url: json['url'] as String?,
        secretNames: (json['secretNames']! as List<Object?>)
            .map((Object? value) => value! as String)
            .toList(growable: false),
        authType: McpAuthType.parse(json['authType']! as String),
        oauthStatus: McpOAuthStatus.parse(json['oauthStatus']! as String),
        oauthClientId: json['oauthClientId'] as String?,
        oauthClientSecretConfigured:
            json['oauthClientSecretConfigured']! as bool,
        oauthScopes: (json['oauthScopes']! as List<Object?>)
            .map((Object? value) => value! as String)
            .toList(growable: false),
        oauthExpiresAt: switch (json['oauthExpiresAt']) {
          final String value => DateTime.parse(value).toUtc(),
          _ => null,
        },
        oauthError: json['oauthError'] as String?,
        createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
        updatedAt: DateTime.parse(json['updatedAt']! as String).toUtc(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'projectId': ?projectId,
    'name': name,
    'transport': transport.wire,
    'enabled': enabled,
    'command': ?command,
    'args': args,
    'url': ?url,
    'secretNames': secretNames,
    'authType': authType.wire,
    'oauthStatus': oauthStatus.wire,
    'oauthClientId': ?oauthClientId,
    'oauthClientSecretConfigured': oauthClientSecretConfigured,
    'oauthScopes': oauthScopes,
    'oauthExpiresAt': ?oauthExpiresAt?.toUtc().toIso8601String(),
    'oauthError': ?oauthError,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// Browser authorization request created by `mcp.oauth.begin`.
class McpOAuthFlow {
  const McpOAuthFlow({required this.flowId, required this.authorizationUrl});

  final String flowId;
  final String authorizationUrl;

  factory McpOAuthFlow.fromJson(Map<String, Object?> json) => McpOAuthFlow(
    flowId: json['flowId']! as String,
    authorizationUrl: json['authorizationUrl']! as String,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'flowId': flowId,
    'authorizationUrl': authorizationUrl,
  };
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/// Protocol cap: maximum attachments per `sessions.send`.
const int kMaxAttachmentsPerMessage = 8;

/// Protocol cap: maximum decoded size of one attachment (8 MiB).
const int kMaxAttachmentBytes = 8 * 1024 * 1024;

/// Protocol cap: maximum combined decoded size of one message's attachments
/// (16 MiB).
const int kMaxAttachmentTotalBytes = 16 * 1024 * 1024;

/// Persisted metadata of a file attached to a user message. The payload
/// travels only in `sessions.send` (client → daemon) and `attachments.read`
/// (daemon → client); events and history carry this metadata form.
class Attachment {
  const Attachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
  });

  /// Daemon-assigned id, unique within its session.
  final String id;

  /// File name, including extension.
  final String name;

  /// IANA media type; `application/octet-stream` when unknown.
  final String mimeType;

  /// Decoded payload size in bytes.
  final int size;

  factory Attachment.fromJson(Map<String, Object?> json) => Attachment(
    id: json['id']! as String,
    name: json['name']! as String,
    mimeType: json['mimeType']! as String,
    size: json['size']! as int,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'size': size,
  };
}

/// An [Attachment] with its base64-encoded payload, as returned by
/// `attachments.read`.
class AttachmentData extends Attachment {
  const AttachmentData({
    required super.id,
    required super.name,
    required super.mimeType,
    required super.size,
    required this.data,
  });

  /// Base64-encoded file content.
  final String data;

  factory AttachmentData.fromJson(Map<String, Object?> json) => AttachmentData(
    id: json['id']! as String,
    name: json['name']! as String,
    mimeType: json['mimeType']! as String,
    size: json['size']! as int,
    data: json['data']! as String,
  );

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    ...super.toJson(),
    'data': data,
  };
}

/// A file the client attaches to an outgoing `sessions.send` message.
class OutgoingAttachment {
  const OutgoingAttachment({
    required this.name,
    required this.mimeType,
    required this.data,
  });

  /// File name, including extension.
  final String name;

  /// IANA media type; `application/octet-stream` when unknown.
  final String mimeType;

  /// Base64-encoded file content.
  final String data;

  factory OutgoingAttachment.fromJson(Map<String, Object?> json) =>
      OutgoingAttachment(
        name: json['name']! as String,
        mimeType: json['mimeType']! as String,
        data: json['data']! as String,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'mimeType': mimeType,
    'data': data,
  };
}

/// Best-effort IANA media type for a file name, from its extension. Falls
/// back to `application/octet-stream` for unrecognized extensions.
String mimeTypeForFileName(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'application/octet-stream';
  final String ext = name.substring(dot + 1).toLowerCase();
  return _kExtensionMimeTypes[ext] ?? 'application/octet-stream';
}

/// Whether [mimeType] denotes an image agents can consume as an ACP `image`
/// content block.
bool isImageMimeType(String mimeType) =>
    mimeType.toLowerCase().startsWith('image/');

/// Whether [mimeType] denotes text that can be inlined as the `text` of an
/// ACP embedded resource (as opposed to a base64 `blob`).
bool isTextMimeType(String mimeType) {
  final String type = mimeType.toLowerCase();
  if (type.startsWith('text/')) return true;
  if (type.endsWith('+json') ||
      type.endsWith('+xml') ||
      type.endsWith('+yaml')) {
    return true;
  }
  return _kTextMimeTypes.contains(type);
}

const Set<String> _kTextMimeTypes = <String>{
  'application/json',
  'application/xml',
  'application/yaml',
  'application/x-yaml',
  'application/toml',
  'application/javascript',
  'application/typescript',
  'application/x-sh',
  'application/sql',
  'image/svg+xml',
};

const Map<String, String> _kExtensionMimeTypes = <String, String>{
  // Images
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'avif': 'image/avif',
  'heic': 'image/heic',
  // Text / code
  'txt': 'text/plain',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'dart': 'text/plain',
  'json': 'application/json',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'toml': 'application/toml',
  'xml': 'application/xml',
  'csv': 'text/csv',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'js': 'application/javascript',
  'mjs': 'application/javascript',
  'ts': 'application/typescript',
  'sh': 'application/x-sh',
  'sql': 'application/sql',
  'log': 'text/plain',
  // Documents / archives / media
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'tar': 'application/x-tar',
  'gz': 'application/gzip',
  'tgz': 'application/gzip',
  '7z': 'application/x-7z-compressed',
  'wasm': 'application/wasm',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
};

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
