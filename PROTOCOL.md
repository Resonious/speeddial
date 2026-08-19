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
  model: string | null,
  cwd: string,                // working dir of the agent (project path or worktree)
  baseBranch: string | null,  // base branch the session's worktree was created from
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
Attachment = {                   // metadata carried by userMessage events (no payload)
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
  rawInput: any | null,
  rawOutput: any | null,
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
- `sessions.create {projectId: string, providerId: string, model?: string, mode?: SessionMode, title?: string, cwd?: string, baseBranch?: string}` → `{session: Session}`
  — with `baseBranch`, the daemon runs `git fetch origin <baseBranch>` in the project repo, adds a
    worktree at `<project-parent>/.speeddial-worktrees/<project-name>-<id8>` on a new
    `speeddial/<slug>-<id8>` branch, and uses the worktree as the session `cwd`. The worktree is
    based on `origin/<baseBranch>` when the remote is strictly ahead, on the local branch
    otherwise (local ahead, equal, or diverged). `baseBranch` and `cwd` are mutually exclusive
    (`-32602`); fetch/worktree failures are `-32020`. Deleting the session never touches the
    worktree on disk.
- `sessions.send {sessionId: string, text: string, attachments?: OutgoingAttachment[]}` → `{}` — starts a turn; errors `-32003` if a turn is already running. `text`
  may be empty only when `attachments` is non-empty. Caps: at most 8 attachments, 8 MiB decoded per
  attachment, 16 MiB decoded total; violations are `-32602`, as are malformed base64 payloads. The daemon
  persists each payload (fetchable later via `attachments.read`), records the metadata on the turn's
  `userMessage` event, and forwards the files to the agent as ACP prompt content blocks: `image/*` becomes
  an `image` block; text-like types (`text/*`, JSON/XML/YAML, source code, SVG) become an embedded `resource`
  block with `text`; anything else becomes an embedded `resource` block with a base64 `blob`. Resource URIs
  have the form `speeddial-attachment:///<id>/<name>`.
  Sessions survive a daemon restart: when the agent process is gone, the daemon respawns it and resumes the
  conversation via ACP `session/load` before starting the turn. Errors `-32003` when the session is closed or its
  provider cannot resume (no `session/load` support), `-32010` when the provider is unavailable, and `-32011` when
  the agent failed to resume (its own state is lost). A daemon restart that interrupts a turn marks the session
  `error` and appends a `sessionError` event to its history; the session becomes usable again on the next send.
- `sessions.cancel {sessionId: string}` → `{}`
- `sessions.rename {sessionId: string, title: string}` → `{session: Session}`
- `sessions.archive {sessionId: string, archived: boolean}` → `{session: Session}`
- `sessions.delete {sessionId: string}` → `{}` — kills the agent process if alive
- `sessions.setMode {sessionId: string, mode: SessionMode}` → `{session: Session}`
- `sessions.setModel {sessionId: string, model: string}` → `{session: Session}`
- `sessions.history {sessionId: string, limit?: int, beforeSeq?: int}` → `{events: SessionEvent[], hasMore: boolean}` — default limit 200, max 1000; without `beforeSeq` returns the latest page
- `sessions.respondPermission {sessionId: string, requestId: string, optionId: string}` → `{}` — errors `-32002` if request unknown/expired

### Attachments
- `attachments.read {sessionId: string, attachmentId: string}` → `{attachment: AttachmentData}` — fetches one
  attachment's metadata plus base64 payload; `-32002` when the session or attachment is unknown. Payloads are
  persisted by the daemon and survive restarts; they are deleted with their session.

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
- `git.sessionSummaries {projectId: string}` → `{summaries: SessionGitSummary[]}` — one entry per non-archived session of the project, for the left-rail badges. Computed from local git state only (no fetch): each session's `cwd` is checked for uncommitted changes, and sessions with a `baseBranch` additionally get `aheadOfBase`/`mergedIntoBase` against the local base branch and the (possibly stale) `origin/<baseBranch>` ref. A per-session failure (e.g. a deleted worktree) yields null fields in that session's entry, not a request error.

## Notifications (daemon → all authenticated clients)

- `session.created {session: Session}`
- `session.updated {session: Session}` — any metadata/status change
- `session.removed {sessionId: string}`
- `session.event {sessionId: string, seq: int, event: SessionEvent}`
- `projects.changed {}` — clients refetch `projects.list`

`seq` is a per-session monotonically increasing integer starting at 1. Clients use it for
gap detection: on reconnect, refetch history with `beforeSeq` of the oldest known gap.
