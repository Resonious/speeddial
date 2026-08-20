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
  id: string,                 // "omp" | "claude" | "codex" | custom
  name: string,               // display name
  available: boolean,         // command resolvable on this host
  command: string,            // resolved spawn command (display/debug)
  models: string[],           // selectable model ids, may be []
}

Project = {
  id: string,
  name: string,
  path: string,               // absolute path on the daemon host
  addedAt: string,
  lastActiveAt: string,
}

SessionStatus = "idle" | "running" | "waitingPermission" | "error" | "closed"
SessionMode   = "build" | "plan"

Session = {
  id: string,
  projectId: string,
  providerId: string,
  title: string,
  status: SessionStatus,
  mode: SessionMode,
  model: string | null,       // current model id — agent-reported when the provider
                              // advertises a model config option, else a local preference
  models: string[],           // selectable model ids advertised by the agent (ACP config
                              // option); empty when the provider has none
  cwd: string,                // working dir of the agent (project path or worktree)
  baseBranch: string | null,  // base branch the session's worktree was created from
  thinkingLevel: string | null,   // current agent thinking level (e.g. omp's "auto");
                              // null when the provider exposes no thinking-level option
  thinkingLevels: string[],   // selectable levels advertised by the agent (ACP config
                              // option); empty when the provider has none
  yolo: boolean,              // daemon auto-approves the agent's permission requests
  archived: boolean,
  createdAt: string,
  updatedAt: string,
}

FileEntry = { name: string, path: string, isDir: boolean, size: int, modifiedAt: string }

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
  | { type: "diff", path: string, oldText: string | null, newText: string }
  | { type: "terminal", terminalId: string, output: string }

PlanEntry = { content: string, priority: "high" | "medium" | "low", status: "pending" | "in_progress" | "completed" }

PermissionRequest = {
  requestId: string,
  toolCallId: string | null,
  title: string,
  options: PermissionOption[],
}
PermissionOption = { optionId: string, name: string, kind: "allow_once" | "allow_always" | "reject_once" | "reject_always" }

UsageInfo = { inputTokens: int, outputTokens: int, totalTokens: int, cost: string | null }
```

## Methods

### Daemon
- `daemon.info {}` → `DaemonInfo`
- `providers.list {}` → `{providers: ProviderInfo[]}`

### Projects
- `projects.list {}` → `{projects: Project[]}`
- `projects.add {path: string, name?: string}` → `{project: Project}` — errors `-32602` if path missing or not a directory; a leading `~` or `~/` expands to the daemon user's home (`$HOME`, else `%USERPROFILE%`)
- `projects.remove {id: string}` → `{}` — also archives its sessions; does NOT touch the filesystem
- `projects.rename {id: string, name: string}` → `{project: Project}`

### Sessions
- `sessions.list {projectId?: string, includeArchived?: boolean}` → `{sessions: Session[]}`
- `sessions.create {projectId: string, providerId: string, model?: string, mode?: SessionMode, title?: string, cwd?: string, baseBranch?: string, yolo?: boolean}` → `{session: Session}`
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
  — the daemon adopts the agent's ACP `configOptions` at creation: `models`/`thinkingLevels`
    carry the advertised options and `model`/`thinkingLevel` the agent-reported current values.
    A `model` argument is applied best-effort via `session/set_config_option` when the agent
    advertises a model option (the returned session reflects the agent-reported model, which
    may differ when the agent rejects it); when the agent advertises none, `model` stays a
    local label as before.
  — without `title`, the session starts as `New session`; the first user message sent to it
    replaces that placeholder (see `sessions.send`).
- `sessions.fork {sessionId: string, seq: int}` → `{session: Session}` — creates a new idle
  session containing the source session's persisted history through `seq`. `seq` must identify a
  `userMessage` or `agentMessageChunk` event (`-32602` otherwise), so clients can fork from either
  side of any visible exchange. The fork inherits the source provider, project, cwd/worktree,
  base branch, mode, model, thinking level, and yolo setting; it is titled `Fork of <source title>`.
  Attachment payloads referenced by copied user messages or image events are cloned into the new session.
  The daemon starts a fresh provider session and supplies the copied user/agent conversation as
  inherited context with the fork's first new turn. This provider-independent handoff makes
  arbitrary-message forks available even when the ACP agent has no native `session/fork` support.
  The source session and its agent remain unchanged.
- `sessions.send {sessionId: string, text: string, attachments?: OutgoingAttachment[]}` → `{}` — starts a turn; errors `-32003` if a turn is already running. `text`
  may be empty only when `attachments` is non-empty. Caps: at most 8 attachments, 8 MiB decoded per
  attachment, 16 MiB decoded total; violations are `-32602`, as are malformed base64 payloads. The daemon
  persists each payload (fetchable later via `attachments.read`), records the metadata on the turn's
  `userMessage` event, and forwards the files to the agent as ACP prompt content blocks: `image/*` becomes
  an `image` block; text-like types (`text/*`, JSON/XML/YAML, source code, SVG) become an embedded `resource`
  block with `text`; anything else becomes an embedded `resource` block with a base64 `blob`. Resource URIs
  have the form `speeddial-attachment:///<id>/<name>`.
  The request resolves at turn start — once the `userMessage` event is persisted and the session is
  `running` — not when the agent finishes. The turn's output arrives as live `session.event` notifications,
  ending in `turnComplete`; a client awaiting the response only gates the send, never the whole turn, so a
  connection drop mid-turn errors nothing the caller is still waiting on (the draft is cleared on ack, not
  on turn completion).
  Sessions survive a daemon restart: when the agent process is gone, the daemon respawns it and resumes the
  conversation via ACP `session/load` before starting the turn. Errors `-32003` when the session is closed or its
  provider cannot resume (no `session/load` support), `-32010` when the provider is unavailable, and `-32011` when
  the agent failed to resume (its own state is lost). A daemon restart that interrupts a turn marks the session
  `error` and appends a `sessionError` event to its history; the session becomes usable again on the next send.
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
  (`-32602` when not listed) and forwards the change to a live idle agent via ACP
  `session/set_config_option`, persisting the agent-reported state (which also carries the
  current thinking level/levels, since those can be model-dependent); without a live agent the
  choice is persisted and reapplied on resume. Providers without a model option keep the legacy
  local-preference behavior (any string is stored verbatim).
- `sessions.setThinkingLevel {sessionId: string, level: string}` → `{session: Session}` — sets the
  agent's thinking level (forwarded to a live agent via ACP `session/set_config_option`; otherwise
  persisted and reapplied on resume). `level` must be one of the session's `thinkingLevels`;
  `-32602` when it is not or when the session's provider advertises no thinking-level option. The
  returned session reflects the agent-reported state, which may differ from the requested level
  when the agent clamps it.
- `sessions.history {sessionId: string, limit?: int, beforeSeq?: int}` → `{events: SessionEvent[], hasMore: boolean}` — default limit 200, max 1000; without `beforeSeq` returns the latest page
- `sessions.respondPermission {sessionId: string, requestId: string, optionId: string}` → `{}` — errors `-32002` if request unknown/expired

### Attachments
- `attachments.read {sessionId: string, attachmentId: string}` → `{attachment: AttachmentData}` — fetches one
  attachment's metadata plus base64 payload; `-32002` when the session or attachment is unknown. Payloads are
  persisted by the daemon and survive restarts; they are deleted with their session.

### Built-in MCP bridge (daemon-private)

Every ACP `session/new` and `session/load` request includes a daemon-owned stdio MCP server named
`speeddial`. It exposes:

- `search_projects {query?: string}` — lists projects whose name/path contains the
  case-insensitive query; an empty query lists all known projects.
- `search_sessions {query?: string, projectId?: string, limit?: int}` — searches non-archived
  session titles and persisted history across the daemon, excluding the calling session. Results
  contain session/project metadata and a matching excerpt. Default limit 20, maximum 100; an empty
  query returns recent sessions.
- `display_image {path?: string, data?: string, mimeType?: string, name?: string}` — requires
  exactly one of a path confined to the session cwd or a base64 payload. The decoded image is capped
  at 8 MiB, persisted as an attachment, and emitted as an `image` event; clients fetch it through
  `attachments.read`. The MCP result also includes MCP image content for the model.

The subprocess connects to `/ws` over loopback and must first call
`internal.mcpAuthenticate {secret: string, sessionId: string}`. A distinct random secret is bound
to each session and injected with its owning session id only into that session's ACP MCP configuration.
An authenticated MCP bridge may call only `internal.mcpSearchProjects`,
`internal.mcpSearchSessions`, and `internal.mcpDisplayImage`; it cannot call the public daemon API
and receives no broadcasts.
Public clients cannot use the internal methods without the MCP secret.

### Files (paths are relative to the project root; absolute rejected with `-32602`)
- `fs.list {projectId: string, path?: string}` → `{entries: FileEntry[]}` — default path `"."`; skips `.git` internals; dirs first, then name ascending
- `fs.read {projectId: string, path: string, maxBytes?: int}` → `{content: string, truncated: boolean, isBinary: boolean}` — default maxBytes 512 KiB, hard cap 4 MiB; binary files return `isBinary: true` with empty content

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
