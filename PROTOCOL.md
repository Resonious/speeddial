# SpeedDial Protocol v1

Wire protocol between the SpeedDial daemon and UI clients.
Transport: **WebSocket, text frames, newline-free JSON-RPC 2.0**, one message per frame.
Default endpoint: `ws://127.0.0.1:7331/ws`.

All timestamps are ISO-8601 UTC strings. All IDs are URL-safe random strings (16+ chars).
Money/cost values are decimal USD strings.

## Envelope

Request:  `{"jsonrpc":"2.0","id":<int|string>,"method":"<name>","params":{...}}`
Success:  `{"jsonrpc":"2.0","id":<same>,"result":{...}}`
Failure:  `{"jsonrpc":"2.0","id":<same>,"error":{"code":<int>,"message":<string>,"data":<any?>}}`
Notification (server→client, no `id`): `{"jsonrpc":"2.0","method":"<name>","params":{...}}`

Error codes: standard JSON-RPC (-32700, -32600, -32601, -32602, -32603) plus:
`-32001` unauthenticated, `-32002` not found, `-32003` conflict, `-32010` provider unavailable,
`-32011` agent process error, `-32020` git error.

## Auth

If the daemon requires auth (default when bound to non-loopback, or `--token` given), the
client's first request MUST be `auth.authenticate`. All other requests before that fail
with `-32001`. Loopback connections without a configured token skip auth.

As the sole exception besides `auth.authenticate`, `daemon.info` is always answered
pre-auth — it returns `authRequired: true` on a token-gated daemon — so clients can
probe whether a token is needed before authenticating.

- `auth.authenticate {token: string}` → `{ok: true, daemon: DaemonInfo}`

## Models

```ts
DaemonInfo = {
  version: string,            // semver
  protocolVersion: 1,
  authRequired: boolean,
  providers: ProviderInfo[],
}

ProviderInfo = {
  id: string,                 // "omp" | "claude" | "codex" | "ante" | custom
  name: string,               // display name
  available: boolean,         // command resolvable on this host
  command: string,            // resolved spawn command (display/debug)
  protocol: "acp" | "codex" | "ante", // wire protocol; tells clients where model
                             // selection lives — Ante pins the upstream provider at
                             // session creation, so its models are picked there;
                             // ACP/Codex advertise config options on the live session
  models: string[],           // selectable model ids, may be []
                             // Ante entries are provider-qualified
                             // ("cerebras/gemma-4-31b"): model ids collide
                             // across Ante's upstream providers. Only upstream
                             // providers the user can actually run are listed:
                             // the catalog is filtered to auth descriptors that
                             // resolve (env key set or stored in the Ante home's
                             // `auth/api_keys.json`, OAuth preset with a token file
                             // under `auth/`), plus providers named by the Ante
                             // settings (`provider`, `provider_model` keys) and
                             // providers with no auth descriptor. Entries are
                             // grouped by upstream provider in catalog order, with
                             // the settings-chosen default model first per provider
                             // — Ante pins the provider at session creation, so
                             // clients present a provider picker and submit the
                             // provider's first entry.
  sandboxModes: SessionSandboxMode[], // selectable isolation modes; [] when provider-managed
}

HarnessInfo = {
  id: string,                 // "omp" | "claude" | "codex" | "ante"
  name: string,               // display name
  version: string,            // installed CLI's version output
}

Project = {
  id: string,
  name: string,
  path: string,               // absolute path on the daemon host
  addedAt: string,
  lastActiveAt: string,
}
McpTransport = "stdio" | "http"
McpAuthType = "none" | "oauth" | "oauth_localhost"
McpOAuthStatus = "not_connected" | "authorizing" | "authorized" | "expired" | "error"

McpServerProfile = {
  id: string,
  projectId: string | null,   // null = every project on this daemon
  name: string,
  transport: McpTransport,
  enabled: boolean,
  command: string | null,      // stdio only
  args: string[],              // stdio only
  url: string | null,          // HTTP only
  secretNames: string[],       // configured env/header names; values are never returned
  authType: McpAuthType,
  oauthStatus: McpOAuthStatus,
  oauthClientId: string | null,
  oauthClientSecretConfigured: boolean,
  oauthScopes: string[],
  oauthExpiresAt: string | null,
  oauthError: string | null,
  createdAt: string,
  updatedAt: string,
}

McpOAuthFlow = {
  flowId: string,
  authorizationUrl: string,
}


SessionStatus = "idle" | "running" | "waitingPermission" | "error" | "closed"
SessionMode   = "build" | "plan"
SessionSandboxMode = "workspaceWrite" | "unrestricted"

Session = {
  id: string,
  projectId: string,
  providerId: string,
  title: string,
  status: SessionStatus,
  mode: SessionMode,
  model: string | null,       // current model id — agent-reported when the provider
                              // advertises a model config option, else a local preference
                              // (for Ante: the bare id; the upstream provider is fixed
                              // at session creation)
  models: string[],           // selectable model ids advertised by the agent (ACP config
                              // option); empty when the provider has none (for Ante: the
                              // session provider's own catalog models, bare)
  cwd: string,                // working dir of the agent (project path or worktree)
  baseBranch: string | null,  // base branch the session's worktree was created from
  thinkingLevel: string | null,   // current agent thinking level (e.g. omp's "auto");
                              // null when the provider exposes no thinking-level option
  thinkingLevels: string[],   // selectable levels advertised by the agent (ACP config
                              // option); empty when the provider has none
  sandboxMode: SessionSandboxMode | null, // selected provider isolation; null when provider-managed
  yolo: boolean,              // daemon auto-approves the agent's permission requests
  archived: boolean,
  createdAt: string,
  lastActivityAt: string,     // last accepted user message or terminal turn outcome
  updatedAt: string,
}

FileEntry = { name: string, path: string, isDir: boolean, size: int, modifiedAt: string }
FileDownload = { name: string, size: int, data: string } // full file payload, base64 encoded

// Attachments (files the user attaches to a message)
OutgoingAttachment = {           // client → daemon payload (sessions.send only)
  name: string,                  // file name incl. extension
  mimeType: string,              // IANA type; "application/octet-stream" when unknown
  data: string,                  // base64-encoded content
}
Attachment = {                   // metadata carried by userMessage/image events (no payload)
  id: string,                    // daemon-assigned, unique within the session
  name: string,
  mimeType: string,
  size: int,                     // decoded byte count
}
AttachmentData = Attachment & { data: string }   // attachments.read result: metadata + base64

GitStatusFile = { path: string, indexStatus: string, worktreeStatus: string, staged: boolean }
GitStatus = { branch: string, ahead: int, behind: int, files: GitStatusFile[] }
GitDiff = { path: string, patch: string, isNew: boolean, isDeleted: boolean, isBinary: boolean }
Branch = { name: string, isCurrent: boolean, upstream: string | null }
MergeResult = {
  baseBranch: string,          // branch that received the merge
  sessionBranch: string,       // worktree branch that was merged in
  baseFastForwarded: boolean,  // local base first advanced to origin/<base>
  alreadyUpToDate: boolean,    // base already contained every session commit
  fastForward: boolean,        // merge resolved by moving the base ref (no merge commit)
  commit: string,              // resulting tip of baseBranch
}
RebaseResult = {
  baseBranch: string,          // branch the session branch was rebased onto
  sessionBranch: string,       // worktree branch that was rebased
  baseFastForwarded: boolean,  // local base first advanced to origin/<base>
  alreadyUpToDate: boolean,    // session branch already contained the base tip
  commit: string,              // resulting tip of sessionBranch
}

SessionGitSummary = {
  sessionId: string,
  dirty: boolean | null,       // uncommitted changes (staged, unstaged, untracked) in the
                               // session's cwd; null when unknown (cwd gone / not a repo)
  aheadOfBase: int | null,     // commits on the session branch contained in neither the local
                               // base branch nor its origin ref; null when the session has no
                               // baseBranch or the count could not be determined
  behindBase: int | null,      // commits reachable from the base branch (local or origin) but
                               // not from the session branch — a sibling session merged into
                               // the local base counts immediately; null like aheadOfBase
  mergedIntoBase: boolean | null, // every commit the session branch gained since its creation
                               // is contained in the base branch (local or origin); false while
                               // any commit is unmerged, and false while the branch never gained
                               // a commit of its own (nothing to merge); null like aheadOfBase
}
```

### SessionEvent (discriminated union on `type`)

`seq` and `timestamp` are added by the daemon when persisting/broadcasting; clients always
receive them. `sessions.history` returns events ordered by `seq` ascending.

```ts
SessionEvent =
  | { type: "userMessage", text: string, attachments?: Attachment[] }  // attachments omitted when empty
  | { type: "image", attachment: Attachment }          // agent-requested image displayed in the UI
  | { type: "agentMessageChunk", text: string }        // streaming delta
  | { type: "agentThoughtChunk", text: string }        // streaming delta, collapsible in UI
  | { type: "toolCall", toolCall: ToolCall }           // created or updated; match by toolCall.id
  | { type: "plan", entries: PlanEntry[] }             // full replacement
  | { type: "permissionRequest", request: PermissionRequest }
  | { type: "permissionResolved", requestId: string, optionId: string }
  | { type: "usage", usage: UsageInfo }
  | { type: "agentActivity", activity: AgentActivity } // provider lifecycle/background activity; snapshots match by activity.id
  | { type: "turnComplete", stopReason: string }       // "end_turn" | "cancelled" | "refusal" | "max_tokens" | ...
  | { type: "sessionError", message: string }

ToolCall = {
  id: string, title: string,
  kind: string,              // "read"|"edit"|"delete"|"move"|"search"|"execute"|"think"|"fetch"|"other"
  status: "pending" | "running" | "completed" | "failed",
  content: ToolCallContent[], // may be []
  locations: string[],        // file paths touched, may be []
  rawInput: any | null,      // structured payloads; update events carry these only when
  rawOutput: any | null,     // the call is completed/failed — running updates omit them
                              // (clients fold by id; the terminal event carries the full state)
}
ToolCallContent =
  | { type: "text", text: string }
  | { type: "image", attachment: Attachment }          // payload fetched through attachments.read
  | { type: "diff", path: string, oldText: string | null, newText: string }
  | { type: "patch", path: string, diff: string }       // provider-native unified diff for one file
  | { type: "terminal", terminalId: string, output: string }
PlanEntry = { content: string, priority: "high" | "medium" | "low", status: "pending" | "in_progress" | "completed" }

PermissionRequest = {
  requestId: string,
  toolCallId: string | null,
  title: string,
  options: PermissionOption[],
}
PermissionOption = { optionId: string, name: string, kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" }

AgentActivity = {
  id: string,
  kind: string,               // provider-defined category, e.g. "session" | "extensions" | "info" | "subagent"
  title: string,
  status: "running" | "completed" | "failed",
  details: string[],          // human-readable detail lines, may be []
}

UsageInfo = {
  inputTokens: int,
  outputTokens: int,
  totalTokens: int,
  cost: string | null,
  cacheReadTokens?: int,
  cacheCreationTokens?: int,
  contextUsedTokens?: int,
  contextLimitTokens?: int,
}
```

## Methods

### Daemon
- `daemon.info {}` → `DaemonInfo`
- `providers.list {}` → `{providers: ProviderInfo[]}`

### Harnesses
- `harnesses.list {}` → `{harnesses: HarnessInfo[]}` — returns only installed built-in
  harnesses (OMP, Claude Code, Codex, and Ante) and probes each with its native `--version`
  command
- `harnesses.update {id: string}` → `{harness: HarnessInfo}` — runs the installed harness's
  native `update` command and returns its newly probed version; errors `-32002` for an unknown
  harness, `-32009` when an update is already running, `-32010` when it is not installed, and
  `-32011` when the updater fails

### Environment
- `environment.list {}` → `{names: string[]}`
- `environment.update {set?: {[name: string]: string}, remove?: string[]}` →
  `{names: string[]}`

Environment values are write-only and remain in daemon SQLite; public clients receive only sorted
names. Names must match `[A-Za-z_][A-Za-z0-9_]*`. `environment.update` atomically removes requested
names and sets/replaces supplied values (a name in both inputs is set). The saved values overlay the
daemon process environment for every harness process started after the update, including new and
resumed sessions; already-running harness processes are not restarted.

### Projects
- `projects.list {}` → `{projects: Project[]}`
- `projects.add {path: string, name?: string}` → `{project: Project}` — errors `-32602` if path missing or not a directory; a leading `~` or `~/` expands to the daemon user's home (`$HOME`, else `%USERPROFILE%`)
- `projects.remove {id: string}` → `{}` — also archives its sessions; does NOT touch the filesystem
- `projects.rename {id: string, name: string}` → `{project: Project}`
### MCP servers
- `mcp.list {}` → `{servers: McpServerProfile[]}`
- `mcp.create {name: string, projectId?: string, transport: McpTransport, enabled: boolean,
  command?: string, args?: string[], url?: string, secrets?: {[name: string]: string},
  authType?: McpAuthType, oauthClientId?: string, oauthClientSecret?: string}` →
  `{server: McpServerProfile}`
- `mcp.update {id: string, name: string, transport: McpTransport, enabled: boolean,
  command?: string, args?: string[], url?: string, secrets?: {[name: string]: string},
  removeSecretNames?: string[], authType?: McpAuthType, oauthClientId?: string,
  oauthClientSecret?: string}` → `{server: McpServerProfile}`
- `mcp.delete {id: string}` → `{ok: true}`
- `mcp.oauth.begin {id: string, redirectUri: string}` → `{flow: McpOAuthFlow}` — discovers
  protected-resource and authorization-server metadata, dynamically registers a public client
  when no client ID is configured, and returns an authorization-code URL with S256 PKCE
- `mcp.oauth.complete {id: string, flowId: string, callbackUri: string}` →
  `{server: McpServerProfile}` — validates and completes a browser callback received by the app;
  its origin and path must match the flow redirect URI and it must carry the matching OAuth state
- `mcp.oauth.status {id: string, flowId: string}` → `{server: McpServerProfile}`
- `mcp.oauth.disconnect {id: string}` → `{server: McpServerProfile}` — deletes access and refresh
  tokens while retaining client registration settings

`stdio` requires a command; each entry in `secrets` becomes an environment variable. `http`
requires an absolute HTTP(S) URL; each secret becomes an HTTP header. Secret values are stored only
on the daemon and never returned—`secretNames` lets clients replace or remove them. `projectId` is
immutable: when absent the profile applies daemon-wide; when present it must name an existing
project and applies only to that project's sessions. Daemon-wide and matching project profiles are
combined. Names remain unique case-insensitively across the daemon, and `speeddial` is reserved for
the built-in bridge.

Enabled matching profiles are not passed to agent processes. Every compatible agent receives only
the daemon-owned `speeddial` stdio bridge. After that bridge authenticates, the daemon opens the
matching upstream stdio processes in the session cwd or Streamable HTTP connections, performs MCP
initialization, follows `tools/list` pagination, and forwards `tools/call`. HTTP supports JSON and
SSE responses, resumable SSE event IDs, protocol/session headers, and best-effort session deletion.
OAuth access tokens are refreshed before provider startup and terminate at the daemon proxy.
Upstream commands, environment values, URLs, and headers are never included in agent MCP
configuration.

Managed tools appear inside the `speeddial` server as
`<normalized-server-name>__<normalized-tool-name>`; deterministic numeric suffixes resolve
collisions. The bridge preserves each upstream descriptor and result while adding source metadata,
except it strips JSON-schema `pattern` constraints that use regex lookaround: OpenAI- and
Anthropic-family tool-schema validators reject lookaround (`(?=`, `(?!`, `(?<=`, `(?<!`) with an
HTTP 400 that fails every turn, so unsupported constraints are dropped (server-side validation
remains authoritative) and the affected server contributes a warning. A profile that fails to
initialize contributes a warning without hiding the built-in tools or tools from healthy profiles.
The upstream connections close with their authenticated bridge connection.

Ante still needs a private transient `ANTE_HOME` (0700 with a 0600 settings file on POSIX) so its
server mode can discover the single `speeddial` descriptor. The daemon links non-settings Ante data
back to the user's real home, preserving auth, sessions, memory, skills, and logs, and removes the
transient home when Ante exits. Ante-native MCP entries remain direct and available. A daemon-wide
profile change reloads every compatible session; a project change reloads only that project's
sessions. Idle resume-capable agents are parked immediately and running agents before their
following turn. Agents without resume support retain their current connections; all new sessions
receive the saved configuration.

Because `ante serve` ignores the settings default provider/model when `StartSession` carries no
model (it resolves the subscription instead), the daemon reseeds new sessions with the Ante
settings defaults it already merges into the transient home.

OAuth applies only to HTTP profiles. `oauth` sends the browser callback to the daemon;
`oauth_localhost` starts a temporary HTTP listener in the native frontend at a
`http://localhost:<ephemeral-port>/oauth/callback` redirect URI, then hands the full callback URI
to the authenticated daemon through `mcp.oauth.complete`. The authorization code and OAuth state
cross the app/daemon connection, while the PKCE verifier, client secret, and resulting tokens remain
daemon-only. The web frontend cannot host a loopback listener and therefore cannot use
`oauth_localhost`.

The daemon implements OAuth 2.1 authorization-code + PKCE,
RFC 9728 protected-resource metadata, RFC 8414 authorization-server metadata, RFC 7591 dynamic
client registration, RFC 8707 resource indicators, refresh tokens, and the token endpoint
authentication methods `none`, `client_secret_post`, and `client_secret_basic`. For `ws` daemon
connections, the app uses the daemon port with the canonical loopback callback host `127.0.0.1`
(`::1` is preserved). The app rejects daemon-callback OAuth through a non-loopback `ws` endpoint
because its HTTP callback would be insecure and unreachable from a remote device. For `wss`
connections, the app
derives an HTTPS callback from the daemon WebSocket URL. Both use `/oauth/callback`; remote HTTPS
deployments must route that path to the daemon alongside `/ws`. Localhost OAuth does not require a
secure daemon connection because the browser callback terminates at the frontend's loopback-only
listener and is handed to the daemon over its already-authenticated WebSocket connection.
Client secrets, access tokens, and refresh tokens remain in daemon SQLite and never cross the
public RPC surface or enter agent configuration. The daemon adds the current
`Authorization: Bearer ...` header only to proxied upstream HTTP requests, refreshes expiring
tokens before session creation/resume, and checks them periodically while running.


### Sessions
- `sessions.list {projectId?: string, includeArchived?: boolean}` → `{sessions: Session[]}`
- `sessions.create {projectId: string, providerId: string, model?: string, mode?: SessionMode, title?: string, cwd?: string, baseBranch?: string, sandboxMode?: SessionSandboxMode, yolo?: boolean}` → `{session: Session}`
  For Ante, `model` carries a `provider/` prefix taken from a qualified
  `ProviderInfo.models` entry (or a custom typed id such as
  `openai-compatible/<model>`); the daemon pins that upstream provider in
  `StartSession` and the session reports the bare model id plus that
  provider's own model list. Catalog providers with no preferred models
  (e.g. a custom OpenAI-compatible upstream) cannot be enumerated, so
  clients may submit any `provider/model` pair the provider's API accepts —
  the model id passes through to that provider. Mid-session model switches
  (`sessions.setModel`) stay within the session's provider — Ante's
  `UpdateSession` cannot change it.
  — with `baseBranch`, the daemon runs `git fetch origin <baseBranch>` in the project repo, adds a
    worktree at `<project-parent>/.speeddial-worktrees/<project-name>-<id8>` on a new
    `speeddial/<slug>-<id8>` branch, and uses the worktree as the session `cwd`. The worktree is
    based on `origin/<baseBranch>` when the remote is strictly ahead, on the local branch
    otherwise (local ahead, equal, or diverged). `baseBranch` and `cwd` are mutually exclusive
    (`-32602`); fetch/worktree failures are `-32020`. Deleting the session never touches the
    worktree on disk.
  — with `yolo: true` (default `false`), the daemon resolves every permission request itself
    instead of parking it for a client: it picks the first `allow_always` option (falling back
    to the first `allow_once`), emits the `permissionRequest` and `permissionResolved` events
    back-to-back (the session never enters `waitingPermission`), and the turn continues
    uninterrupted. A request offering no allow option still parks for a client response.
  — `sandboxMode` is accepted only when advertised by the selected provider's
    `ProviderInfo.sandboxModes` (`-32602` otherwise). For compatibility, Codex still advertises
    `workspaceWrite` and `unrestricted`, but always uses and reports `unrestricted`; its
    `danger-full-access` mode disables the filesystem and network sandbox. Permission approvals
    remain independent and continue to follow `yolo`.
  — the daemon adopts the agent's configurable model and effort/thinking options at
    creation: `models`/`thinkingLevels` carry the advertised options and
    `model`/`thinkingLevel` the agent-reported current values. ACP providers use
    `configOptions`; Codex uses `model/list` plus thread settings; Ante uses its
    catalog plus `SessionStart`/`SessionUpdated`. A `model` argument is applied
    best-effort through the provider transport when a model option exists (the
    returned session reflects the provider-reported model, which may differ when
    the provider rejects it); when the provider advertises none, `model` stays a
    local label as before.
  — without `title`, the session starts as `New session`; the first user message sent to it
    replaces that placeholder (see `sessions.send`).
- `sessions.fork {sessionId: string, seq: int}` → `{session: Session}` — creates a new idle
  session containing the source session's persisted history through `seq`. `seq` must identify a
  `userMessage` or `agentMessageChunk` event (`-32602` otherwise), so clients can fork from either
  side of any visible exchange. The fork inherits the source provider, project, cwd/worktree,
  base branch, mode, model, thinking level, sandbox mode, and yolo setting; it is titled
  `Fork of <source title>`.
  Attachment payloads referenced by copied user messages or image events are cloned into the new session.
  The daemon starts a fresh provider session and supplies the copied user/agent conversation as
  inherited context with the fork's first new turn. This provider-independent handoff makes
  arbitrary-message forks available even when the ACP agent has no native `session/fork` support.
  The source session and its agent remain unchanged.
- `sessions.send {sessionId: string, text: string, attachments?: OutgoingAttachment[]}` → `{}` — starts a turn; errors `-32003` if a turn is already running. `text`
  may be empty only when `attachments` is non-empty. ACP providers accept text, image, and binary
  attachments. Codex accepts text, non-text images, and audio; it rejects other binary attachments
  with `-32602` before persisting the turn. Ante accepts text-like attachments (`text/*`,
  JSON/XML/YAML, source code, and SVG): the daemon sends their file label and UTF-8 content through
  Ante's `UserInput` operation. For non-text `image/*`, the daemon writes the decoded image to a
  private transient directory and adds an `@` file mention to `UserInput`, invoking Ante's native
  image-context path; whether the model can inspect pixels depends on its Ante catalog
  `support_vision` capability. Ante rejects other binary attachments with `-32602` before
  persisting the turn.
  General caps: at most 8 attachments, 8 MiB decoded per attachment, 16 MiB decoded total;
  violations are `-32602`, as are malformed base64 payloads and text-like payloads that are not valid
  UTF-8. For an accepted turn, the daemon persists each payload (fetchable later via
  `attachments.read`) and records the metadata on the turn's `userMessage` event. ACP receives the
  files as prompt content blocks: non-text `image/*` becomes an `image` block; text-like types become
  an embedded `resource` block with `text`; anything else becomes an embedded `resource` block with
  a base64 `blob`. Resource URIs have the form `speeddial-attachment:///<id>/<name>`. Codex receives
  native `text`, `image`, and `audio` input items.
  The request resolves at turn start — once the `userMessage` event is persisted and the session is
  `running` — not when the agent finishes. The turn's output arrives as live `session.event` notifications,
  ending in `turnComplete`; a client awaiting the response only gates the send, never the whole turn, so a
  connection drop mid-turn errors nothing the caller is still waiting on (the draft is cleared on ack, not
  on turn completion).
  Sessions survive a daemon restart: when the agent process is gone, the daemon respawns it and
  resumes the conversation through the provider transport before starting the turn. ACP uses
  `session/load`; Codex uses `thread/resume`; Ante starts the persisted Ante session id and
  suppresses replayed history until the next live `TurnStart`. Errors `-32003` when the session is
  closed or its ACP provider cannot resume (no `session/load` support), `-32010` when the provider
  is unavailable, and `-32011` when the agent failed to resume (its own state is lost). A daemon
  restart that interrupts a turn marks the session `error` and appends a `sessionError` event to
  its history; the session becomes usable again on the next send.
  A session's `lastActivityAt` advances when the accepted user message starts the turn and again
  when the turn reaches its terminal idle/error outcome, so clients can order sessions by recent
  conversation activity independently of metadata changes.
  A session still titled `New session` is auto-titled from `text`'s first line (whitespace-collapsed,
  capped at 60 characters) right after the `userMessage` event is persisted, and the change is
  broadcast as `session.updated`; explicitly set titles are never overwritten, and an
  attachment-only turn (empty `text`) skips the auto-title.
- `sessions.cancel {sessionId: string}` → `{}`
- `sessions.rename {sessionId: string, title: string}` → `{session: Session}`
- `sessions.archive {sessionId: string, archived: boolean}` → `{session: Session}`
- `sessions.delete {sessionId: string}` → `{}` — kills the agent process if alive
- `sessions.setMode {sessionId: string, mode: SessionMode}` → `{session: Session}`
- `sessions.setModel {sessionId: string, model: string}` → `{session: Session}` — when the
  provider advertises selectable models (`Session.models`), the daemon validates against them
  (`-32602` when not listed) and forwards the change to a live idle agent through the provider
  transport, persisting the provider-reported state (which also carries the current thinking
  level/levels, since those can be model-dependent); without a live agent the choice is persisted
  and reapplied on resume. Providers without a model option keep the legacy local-preference
  behavior (any string is stored verbatim).
  For Ante, `Session.models` contains only the session provider's models (bare ids), so any
  validated pick forwards as-is; switching upstream providers is impossible mid-session
  (`UpdateSession` ignores provider changes) — choose the provider when creating the session.
- `sessions.setThinkingLevel {sessionId: string, level: string}` → `{session: Session}` — sets the
  agent's thinking level (forwarded to a live agent through the provider transport; otherwise
  persisted and reapplied on resume). `level` must be one of the session's `thinkingLevels`;
  `-32602` when it is not or when the session's provider advertises no thinking-level option. The
  returned session reflects the agent-reported state, which may differ from the requested level
  when the agent clamps it.
- `sessions.history {sessionId: string, limit?: int, beforeSeq?: int, detail?: "full" | "summary"}` → `{events: SessionEvent[], hasMore: boolean}` — default limit 200, max 1000; without `beforeSeq` returns the latest page. `detail` defaults to `full`; `summary` preserves event kinds, ordering, sequence/timestamp metadata, user/agent messages, and permission data while clearing verbose thought text, tool content/raw input/raw output/locations, plan text, and activity details for compact clients.
- `sessions.respondPermission {sessionId: string, requestId: string, optionId: string}` → `{}` — errors `-32002` if request unknown/expired

### Attachments
- `attachments.read {sessionId: string, attachmentId: string}` → `{attachment: AttachmentData}` — fetches one
  attachment's metadata plus base64 payload; `-32002` when the session or attachment is unknown. Payloads are
  persisted by the daemon and survive restarts; they are deleted with their session.

### Built-in MCP bridge (daemon-private)

Every compatible provider session includes a daemon-owned stdio MCP server named `speeddial`.
ACP receives it directly in `session/new`/`session/load`; Ante receives it through the transient
home described above. It exposes:

- `search_projects {query?: string}` — lists projects whose name/path contains the
  case-insensitive query; an empty query lists all known projects.
- `search_sessions {query?: string, projectId?: string, includeArchived?: boolean, limit?: int}` —
  searches session titles and persisted history across the daemon, excluding the calling session.
  Archived sessions are omitted by default; `includeArchived: true` includes them and every result
  carries its `archived` state. Results contain session/project metadata and a matching excerpt.
  Default limit 20, maximum 100; an empty query returns recent sessions.
- `read_session_transcript {sessionId: string, limit?: int, beforeSeq?: int}` — browses a
  session's transcript as chronological `userMessage`, `agentMessageChunk`, and `sessionError`
  events. Thoughts, tool calls, plans, usage, and lifecycle events are omitted. The newest page is
  returned by default; pass `nextBeforeSeq` from a response as `beforeSeq` to read the previous
  page. Default limit 50, maximum 200. The response also identifies the session and its archive
  state. Archived sessions remain readable.
- `archive_session {sessionId: string}` — archives another session so it is hidden from default
  session lists and `search_sessions`. The target can be restored through the regular SpeedDial
  API or CLI; the calling session cannot archive itself.
- `unarchive_session {sessionId: string}` — revives an archived session so it returns to default
  session lists and `search_sessions`; the calling session cannot unarchive itself.
- `display_image {path?: string, data?: string, mimeType?: string, name?: string}` — requires
  exactly one of a path confined to the session cwd or a base64 payload. The decoded image is capped
  at 8 MiB, persisted as an attachment, and emitted as an `image` event; clients fetch it through
  `attachments.read`. The MCP result also includes MCP image content for the model.

The subprocess connects to `/ws` over loopback and must first call
`internal.mcpAuthenticate {secret: string, sessionId: string}`. A distinct random secret and the
session's project/cwd proxy context are registered before provider startup; only the bridge process
receives that session-bound secret. It may then call
`internal.mcpListTools {}` → `{tools: Tool[], warnings: string[]}`,
`internal.mcpCallTool {name: string, arguments: object}` → the upstream MCP call result,
`internal.mcpSearchProjects`, `internal.mcpSearchSessions`,
`internal.mcpReadSessionTranscript {sessionId: string, limit?: int, beforeSeq?: int}`,
`internal.mcpArchiveSession {sessionId: string, archived: boolean}`, and
`internal.mcpDisplayImage`. It cannot call the public daemon API and receives no broadcasts. Public
clients cannot use the internal methods without the MCP secret.

### Files
- `fs.list {projectId: string, path?: string}` → `{entries: FileEntry[]}` — default path `"."`; skips `.git` internals; dirs first, then name ascending
- `fs.read {projectId: string, path: string, maxBytes?: int}` → `{content: string, truncated: boolean, isBinary: boolean}` — default maxBytes 512 KiB, hard cap 4 MiB; binary files return `isBinary: true` with empty content
- `fs.download {sessionId: string, path: string}` → `FileDownload` — fetches a complete
  binary-safe file for a chat link. Relative paths resolve from the session's `cwd`; absolute paths
  are accepted only when they resolve inside that `cwd`. Symlink escapes, directories, missing
  files, and files larger than 64 MiB are rejected with `-32602`.

`fs.list` and `fs.read` paths are relative to the project root; absolute paths are rejected with
`-32602`.

### Git (scoped to the project's repo, or to a session's worktree)

Every `git.*` method accepts an optional `sessionId: string`. When given, the
operation runs in that session's `cwd` instead of the project path — this is
how worktree sessions (see `sessions.create` with `baseBranch`) are inspected
and committed, since their worktree lives outside the project directory. The
session must belong to `projectId` (`-32602` otherwise; `-32002` when unknown).
- `git.status {projectId: string, sessionId?: string}` → `{status: GitStatus}`
- `git.diff {projectId: string, sessionId?: string, path?: string, staged?: boolean}` → `{diffs: GitDiff[]}` — patches are unified diffs for that file only
- `git.branches {projectId: string, sessionId?: string}` → `{branches: Branch[]}`
- `git.checkout {projectId: string, sessionId?: string, branch: string}` → `{}`
- `git.createBranch {projectId: string, sessionId?: string, name: string, checkout?: boolean}` → `{}`
- `git.commit {projectId: string, sessionId?: string, message: string, stageAll?: boolean}` → `{commitHash: string}`
- `git.push {projectId: string, sessionId?: string, setUpstream?: boolean}` → `{}`
- `git.createPullRequest {projectId: string, sessionId?: string, title?: string, body?: string, base?: string, draft?: boolean}` → `{url: string}` — uses `gh`; errors `-32020` if `gh` missing/unauthenticated. With `sessionId` given and `base` omitted, the PR targets the session's `baseBranch`; without either, `gh` picks the repo's default branch.
- `git.mergeToBase {projectId: string, sessionId: string}` → `{merge: MergeResult}` — merges the session's worktree branch back into the `baseBranch` the session was created from (`sessionId` is required here and the session must have one, `-32602` otherwise). First fetches `origin/<baseBranch>`; when the remote-tracking ref is strictly ahead of the local base, the local base is fast-forwarded to it first (`baseFastForwarded: true`) — via `git merge --ff-only` in the checkout that has the base branch, or by moving the ref when the base is checked out nowhere. Diverged local/remote base branches error `-32003`. Then the session branch is merged into the (synced) local base: a regular merge (fast-forward or merge commit) in the checkout holding the base branch, or a ref move when the base is checked out nowhere and the merge is a fast-forward; a non-fast-forward merge with no base checkout errors `-32003`. The session worktree must be clean (`-32003` — commit or discard first). Merge conflicts surface as `-32020`; the merge is aborted (`git merge --abort`) and the base checkout returns to its pre-merge state. The session worktree and its branch are left in place.
- `git.rebaseOntoBase {projectId: string, sessionId: string}` → `{rebase: RebaseResult}` — rebases the session's worktree branch onto the `baseBranch` the session was created from (`sessionId` is required here and the session must have one, `-32602` otherwise). The local base is first synchronized with `origin/<baseBranch>` exactly like `git.mergeToBase` (fetch, fast-forward when strictly behind with `baseFastForwarded: true`, `-32003` on divergence). When the session branch already contains the base tip, nothing moves and `alreadyUpToDate` is `true`. Otherwise `git rebase <baseBranch>` runs in the session worktree — unlike a merge this needs no checkout of the base branch, so it works for diverged histories regardless of where the base is checked out. The session worktree must be clean (`-32003` — commit or discard first). Rebase conflicts surface as `-32020`; the rebase is aborted (`git rebase --abort`) and the session branch returns to its pre-rebase tip. `commit` is the new tip of the session branch.
- `git.sessionSummaries {projectId: string}` → `{summaries: SessionGitSummary[]}` — one entry per non-archived session of the project, for the left-rail badges. Computed from local git state only (the request itself runs no fetch): each session's `cwd` is checked for uncommitted changes, and sessions with a `baseBranch` additionally get `aheadOfBase`/`behindBase`/`mergedIntoBase` against the local base branch and the (possibly stale) `origin/<baseBranch>` ref. The daemon's background watcher (see `git.changed`) fetches base branches periodically, so the origin ref drifts at most a couple of minutes behind the remote. A per-session failure (e.g. a deleted worktree) yields null fields in that session's entry, not a request error.

## Notifications (daemon → all authenticated clients)

- `session.created {session: Session}`
- `session.updated {session: Session}` — any metadata/status change
- `session.removed {sessionId: string}`
- `session.event {sessionId: string, seq: int, event: SessionEvent}`
- `git.changed {projectId: string}` — a daemon-side watcher noticed the project's session git summaries move (a session gained/lost commits or dirty state, a merge/rebase advanced the local base branch under its siblings, or a periodic fetch advanced `origin/<baseBranch>`); clients refresh their badges with `git.sessionSummaries`. Sent at most once per watcher pass per project and only for actual changes; a watcher pass recomputes from local state every ~15s while any client is connected.
- `projects.changed {}` — clients refetch `projects.list`

`seq` is a per-session monotonically increasing integer starting at 1. Clients use it for
gap detection: on reconnect, refetch history with `beforeSeq` of the oldest known gap.
