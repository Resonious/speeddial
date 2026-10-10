# SpeedDial Architecture

Monorepo, pure Dart/Flutter, no code generation anywhere (no build_runner, no freezed,
no riverpod codegen). All JSON is hand-written `fromJson`/`toJson`. Performance is the
top priority: avoid avoidable allocations, rebuild only what changed, keep hot paths free
of per-frame work.

## Layout

```
packages/protocol/   pure Dart, zero deps beyond SDK. Implements PROTOCOL.md exactly:
                     models, SessionEvent union, JSON-RPC 2.0 codec (peer for both sides).
packages/daemon/     Dart CLI + library. Spawns ACP and Ante agent CLIs, owns
                     session/project bookkeeping (SQLite), git/gh operations, WebSocket
                     JSON-RPC server.
packages/app/        Flutter app (desktop + mobile + web). Three-pane control surface.
packages/wear/       Standalone Wear OS Flutter target. Reuses the app's daemon client/store
                     graph and exposes only connection bootstrap, project/session browsing,
                     session creation, and compact chat/send/permission flows.
```

Pub workspace: root `pubspec.yaml` lists all three in `workspace:`; every package sets
`resolution: workspace`. One `dart pub get` at the root resolves everything.

## Package conventions

- SDK: Dart `^3.13.0`; app uses Flutter `>=3.47.0`.
- Lints: `package:lints/recommended.yaml` (protocol, daemon), `package:flutter_lints/flutter.yaml` (app).
- Errors across the wire use the PROTOCOL.md error codes. Inside the daemon, throw
  `DaemonError(code, message, [data])` (defined in protocol package) and let the server
  translate; never hand-roll error JSON at call sites.
- No global mutable state outside explicit store/manager classes.
- Tests: `package:test` for protocol/daemon, `flutter_test` for app. No network, no real
  agent CLIs, no real git remotes in tests — use fakes/fixtures/local temp repos.

## Daemon

Entrypoint `bin/speeddial.dart`, package name `speeddial_daemon`.

When `serve` starts inside the SpeedDial workspace on `main`, the CLI supervises
an updatable source worker (requires Dart on PATH for compiled CLI launches).
The worker records HEAD at boot, checks on idle transitions and every minute
while idle, and runs noninteractive `git pull --ff-only`. A changed HEAD triggers
a graceful worker restart after all turns, permission waits, and session startup
operations finish. The supervisor preserves arguments, working directory, and
credentials and forwards termination signals. Git failures are logged and retried
on the next idle check. Other repositories, branches, and embedded daemons do not
auto-update. No wire API changes are involved.

```
lib/src/agents/     AgentClient transport boundary shared by the session engine.
lib/src/acp/        ACP (Agent Client Protocol) client over newline-delimited JSON-RPC
                    stdio. Spec: https://agentclientprotocol.com — implements:
                    initialize, authenticate, session/new, session/load,
                    session/prompt, session/cancel, session/set_mode, session/set_model;
                    notifications session/update (variants: user_message_chunk,
                    agent_message_chunk, agent_thought_chunk, tool_call, tool_call_update,
                    plan, available_commands_update, current_mode_update, usage_update);
                    agent→client requests: session/request_permission, fs/read_text_file,
                    fs/write_text_file (sandboxed to the session cwd; terminal/* → error).
                    Session creation/resume uses existing provider credentials; advertised
                    login methods are not automatically invoked (Claude uses terminal login).
                    Explicit busy prompt rejections (the agent is running its own
                    background turn — OMP continues subagent-driven work after
                    yielding) are retried with backoff until the agent accepts or
                    the turn is cancelled, never surfaced as turn errors; other
                    request failures are reported separately from process exits.
                    ACP has no standard session permission policy; the built-in OMP provider
                    selects its native yolo mode through its launch command, while custom ACP
                    providers retain the engine's auto-resolution fallback.
lib/src/codex/      Codex's native `codex app-server --stdio` JSONL transport. Initializes
                    the app server, starts/resumes threads with `danger-full-access`
                    because SpeedDial worktrees and localhost tooling must stay usable,
                    starts/steers/interrupts turns, applies model and reasoning-effort
                    settings, resolves command and patch approvals, injects MCP server
                    configuration as required (30-second startup budget) on both start and
                    resume so Codex does not omit a pending bridge from the model's tools,
                    appends explicit SpeedDial tool-discovery guidance to the effective Codex
                    developer instructions on start/resume,
                    and maps native message, reasoning, command, file-change,
                    MCP, collaboration, web-search, image, plan, review, usage, compaction,
                    and lifecycle notifications into the shared agent update stream.
lib/src/ante/       Ante's `ante serve --stdio` JSONL client. Reports the resolved upstream
                    provider to the engine, which persists that identity separately from
                    the bare public model id. Forks copy it before lazy startup; legacy
                    forks retain the source native session id for a provider lookup on
                    their first send. Starts/resumes sessions, sends `UserInput`,
                    handles approval pauses, and maps message/thought
                    deltas, tool progress, usage/context accounting, extension/MCP refresh,
                    info blocks, shell output, compaction, and errors into the shared agent
                    update stream. Native `Agent` tool progress is flattened into tagged
                    top-level subagent activities instead of one growing output block.
                    Native `TodoWrite` calls become shared plan updates so
                    every provider uses the same checklist UI. Catalog data comes from
                    `ante catalog`. Only the
                    daemon-owned `speeddial` MCP descriptor is merged into the selected
                    native Ante settings in a private transient `ANTE_HOME`; non-settings
                    state links back to the real home, native MCP entries remain direct,
                    and the transient directory is removed on process exit. New sessions
                    are seeded with the settings default model/provider (serve mode
                    ignores them when StartSession omits a model). Effort controls mirror
                    the selected catalog model's `effort_options`; `default` clears an
                    override instead of forcing reasoning onto models that omit one. Ante
                    always uses the plain server launch because that subcommand rejects
                    default-run permission flags; yolo is selected per session so approval
                    pauses are not generated.
lib/src/mcp/        BuiltInMcpServer: daemon-owned stdio MCP JSON-RPC subprocess injected
                    into every compatible provider session. ACP and Codex receive its
                    descriptor directly; Ante receives it through its transient home.
                    Built-in tools bridge over an authenticated, session-bound loopback
                    WebSocket to query projects/session history (including archived
                    sessions), browse message-only transcript pages, archive or restore
                    other sessions, or persist an attachment and emit an image event.
                    McpProxySession owns
                    the matching managed upstreams for that bridge connection, starts stdio
                    servers in the session cwd, drives Streamable HTTP JSON/SSE sessions,
                    qualifies, sanitizes,
                    aggregates tool descriptors (stripping regex-lookaround `pattern` constraints
                    model providers reject), routes calls, and closes every upstream
                    with the bridge. Managed commands, URLs, environment values, headers,
                    and OAuth tokens never enter provider configuration. Each upstream has a
                    15-second total connection/initialization/tool-listing budget so a slow
                    server cannot exhaust the agent's 30-second bridge startup deadline.
                    Healthy tools survive with named warnings for failed upstreams; late
                    connections are closed and subsequent listings can retry. Always-advertised
                    discovery and invocation tools let agents retry missing upstreams, read
                    discovery warnings, and invoke recovered tools despite a cached harness
                    catalog.
                    OAuth callbacks can
                    terminate at the daemon or at a temporary native-app localhost listener;
                    app-received callbacks are validated and completed through authenticated RPC.
                    The same hidden
                    subprocess entry works from the daemon CLI and native Flutter
                    executable. Profiles are daemon-wide or project-scoped; a project
                    receives both matching sets. HTTP OAuth 2.1 authorization-code + S256
                    PKCE discovery, registration, callback handling, and refresh live in
                    server/mcp_oauth_service.dart. Repeated identical refresh failures remain
                    retryable without repeatedly parking the project's agent sessions.
lib/src/providers/  Provider registry. Built-ins:
                      omp    → ["omp", "acp"]                              (ACP)
                      claude → ["npx", "-y", "@agentclientprotocol/claude-agent-acp"] (ACP)
                      codex  → ["codex", "app-server", "--stdio"]          (Codex)
                      ante   → ["ante", "serve", "--stdio"]                (Ante)
                    OMP also defines a native yolo launch command selected per session; provider
                    overrides do not inherit those harness-specific arguments. Ante selects yolo
                    in its StartSession operation instead of its server launch command.
                    `~/.speeddial/config.json` may add/override providers:
                    {"providers":{"<id>":{"name":"...","command":["...",...],
                    "protocol":"acp|codex|ante","catalogCommand":["...",...]}}}
                    `protocol` defaults to `acp`; `catalogCommand` is used only by Ante.
                    Models come from a static list, `modelsCommand`, or — for
                    Ante — `catalogCommand`, which yields provider-qualified
                    ids ("cerebras/gemma-4-31b") because model ids collide
                    across Ante's upstream providers. The Ante catalog is
                    filtered to providers the user can actually run: auth
                    descriptors that resolve (env key set or stored in the
                    Ante home's auth/, OAuth preset with a token file), plus
                    settings-named providers. Availability = command[0]
                    resolvable via PATH (or absolute exists).
lib/src/harnesses/  HarnessService detects the four supported installed CLIs
                    (OMP, Claude Code, Codex, Ante), probes their versions, and
                    runs their native update commands. Daemon-managed
                    environment values are overlaid on probes, updates, and new
                    agent processes.
lib/src/engine/     SessionEngine owns live AgentClient processes per session, maps
                    transport updates to protocol SessionEvents, assigns seq, persists
                    via SessionStore, and broadcasts to listeners. It preserves provider
                    message/thought ids and assigns turn-scoped synthetic ids when a
                    provider omits them, making logical streamed content daemon-owned.
                    Ante Question pauses use the same parked-request lifecycle with typed
                    question/answer payloads; choices and free-text notes return through
                    respondPermission. Questions bypass yolo auto-approval and expire on
                    provider resume, turn end, cancellation, or exit.
                    Handles permission requests (parked until respondPermission, or
                    auto-resolved as a yolo fallback), cancel, process exit, and turn
                    lifecycle. The update subscription lives for the agent's lifetime
                    rather than one turn, so updates arriving between client turns
                    (an OMP background wakeup after a finished subagent) are persisted
                    instead of dropped, and a prompt parked behind such an agent-busy
                    turn surfaces as a `session`-kind agentActivity instead of an
                    error. Eventless Codex sessions whose empty rollout vanished with their
                    app-server process start a replacement thread before their first turn.
                    Inline tool-result images and provider-reported image
                    file reads are deduplicated into attachment-backed tool content. MCP
                    injection supports ACP, Codex, and Ante. ACP
                    receives structured attachments; Codex receives native text, image,
                    and audio inputs and saves other binary files to private transient disk
                    paths referenced in text input; Ante inlines UTF-8 text attachments and
                    materializes images as transient `@` file mentions for Ante's native
                    context resolver and saves other binary files as tool-readable paths. Tool progress persists lifecycle metadata rather than
                    repeated accumulated output; terminal tool content/raw payloads are
                    bounded before they enter history.
lib/src/notifications/  Opt-in ntfy.sh completed-turn publishing. The engine
                    collects the latest logical message only while a turn is
                    active and a completion callback is configured; title and
                    final text are captured at terminal idle. Delivery runs
                    independently of the turn and failures are logged without
                    changing its outcome. Shutdown drains pending deliveries.
                    NtfyNotifier uses dart:io with a 10-second exchange deadline,
                    bounded Unicode-safe title/message previews, Markdown,
                    a completion tag, and a session click/action link.
lib/src/store/      Bundled SQLite (package:sqlite3 build hooks; no system SQLite runtime
                    dependency) at ~/.speeddial/speeddial.db (override with --db or
                    SPEEDIAL_DB). Tables: projects, sessions, session_events,
                    attachments (message and MCP-displayed image payloads, FK-cascaded
                    with their session; events carry metadata only, `attachments.read`
                    serves blobs), mcp_servers, mcp_secrets, mcp_oauth, and
                    daemon_environment. MCP static secrets, OAuth client
                    secrets, and access/refresh tokens stay
                    daemon-side; public reads expose only credential names and OAuth
                    connection metadata. Daemon environment values are likewise
                    write-only over the public API. SQLite database/WAL files are
                    restricted to owner access (0600) on POSIX hosts. WAL mode,
                    foreign keys on. Events are stored as JSON blobs + seq.
                    Session/event substring queries back MCP search.
lib/src/git/        GitService: shells out to `git` (never libgit2). Parses porcelain v2
                    for status, --no-color unified diffs, branch lists; fetch and
                    worktree add/remove back per-session worktrees. mergeIntoBase
                    merges a session branch back into its base branch (fast-forwarding
                    the local base to origin first when the remote moved ahead).
                    SummaryWatcher recomputes per-session git summaries every ~15s
                    while clients are connected (fetching base branches every ~2min)
                    and reports changed projects so the server broadcasts
                    `git.changed`. PrService uses `gh pr create`. All ops take an
                    absolute repo path.
lib/src/server/     WebSocket server (dart:io HttpServer + WebSocketTransformer) speaking
                    PROTOCOL.md. JsonRpcPeer from the protocol package does framing. FsService
                    confines project browsing, including symlink resolution. Binary chat-link
                    downloads accept any readable daemon-host file, resolving relative paths
                    from the session cwd.
lib/src/client.dart DaemonClient: Dart client for the same protocol (used by the CLI
                    subcommands to talk to a running daemon).
lib/src/local_daemon.dart  LocalDaemon: in-process daemon (same engine/store/server as
                    `serve`) without CLI arg parsing, discovery file, or
                    signal handling. Configurable bind interface, port
                    (default loopback + OS-chosen), and auth token; a
                    non-loopback bind requires a token (ArgumentError
                    otherwise, mirroring `serve` policy). `url` reports a
                    connectable host (`0.0.0.0` → `127.0.0.1`, `::` →
                    `[::1]`, IPv6 literals bracketed). Started/stopped by the
                    embedding app; exported via the public library.
```

CLI (`speeddial <command>`), all bookkeeping commands talk to the running daemon over
WebSocket except `serve` and `token`:
- `serve [--port 7331] [--host 127.0.0.1] [--token T] [--db PATH]` — runs the daemon.
  Writes PID + port + token to `~/.speeddial/daemon.json` for discovery.
  `--ntfy-topic TOPIC` enables completed-turn pushes to ntfy.sh; omitted means
  disabled. `--ntfy-app-url URL` optionally links to a hosted HTTP(S) frontend
  instead of the mobile app. Both flags survive supervised worker restarts.
- `token` — prints/rotates the auth token.
- `projects list|add <path>|remove <id>`
- `sessions list [--project <id>]|create --project <id> --provider <id> [--model m] [--title t] [--base b] [--yolo]|send <id> <text>|cancel <id>|archive <id>|delete <id>|history <id>|attach <id>` (attach = stream session.event notifications to stdout)
- `git status|diff [--staged]|commit -m <msg> [--all]|push|pr [--title t] [--base b]|merge-base --session <id>` — all take `--project <id>`
- Global flags: `--host`, `--port`, `--token` override discovery file.

## App

The desktop embedded daemon owns its engine, SQLite store, and WebSocket server
on a dedicated Dart isolate. The UI exchanges only startup configuration, endpoint,
errors, and shutdown signals with that worker; regular requests still use WebSocket
JSON-RPC. Shutdown waits for daemon cleanup and worker exit, including when startup
is still in progress. Synchronous daemon work must never run on the UI isolate.

Chat and Wear timelines cache completed turns and rederive only the mutable tail.
They read a read-only live event view instead of copying loaded history on each
update; permission requests are tracked incrementally in `ChatStore`. Paging or
refetching history invalidates the turn cache. Late snapshots of an activity
from a sealed turn also invalidate it so the original card updates in place. Streamed Markdown refreshes at most
every 100 ms and flushes the final text immediately when the turn stops. Code
highlighting waits until streaming stops, runs in serialized background batches on
native platforms, and uses a bounded shared cache. Large code blocks remain fully
visible as plain text (8,000-character native / 2,000-character web highlight limit;
32,000 characters per batch). Web highlighting uses the main thread.

Package name `speeddial_app`. No third-party state management: plain `ChangeNotifier`
stores + `ListenableBuilder`. One inherited-widget accessor `AppScope.of(context)`
(lib/src/scope.dart) exposing the store graph. Deps: `web_socket_channel`,
`shared_preferences`, `flutter_markdown_plus`, `syntax_highlight`, `collection`,
`speeddial_daemon` (path dep — the desktop build embeds the daemon in-process).

```
lib/main.dart                hidden native MCP subprocess dispatch, then runApp; desktop builds start an embedded in-process daemon
                             (lib/src/local_daemon/) on a dedicated Dart isolate from the persisted
                             EmbeddedDaemonStore config and auto-add a
                             non-persistent "This computer" endpoint; web/mobile
                             skip embedding. SpeedDialApp is a WidgetsBindingObserver
                             that stops the embedded daemon on app shutdown.
lib/src/scope.dart           AppScope inherited widget + store graph
lib/src/theme.dart           light + dark Material 3 themes (GitHub palettes), monospace accents, dense
lib/src/api/daemon_client.dart    DaemonClient: WebSocket JSON-RPC client per PROTOCOL.md
                                  (auth, reconnect with backoff, request map, notification
                                  stream, seq-gap detection + history refetch, resume
                                  liveness probe that catches half-dead sockets)
lib/src/api/fake_daemon.dart      FakeDaemonClient: in-memory scripted implementation used
                                  by widget tests AND by --demo mode; simulates streaming
lib/src/files/                    Chunked file transfers and platform save pickers/browser downloads.
lib/src/oauth/                    Conditional native localhost OAuth callback listener; binds
                                  an ephemeral loopback port and forwards the callback URI to
                                  the daemon. Web builds expose an unsupported stub.
lib/src/local_daemon/         embedded in-process daemon (desktop only). Conditional
                             import: local_daemon_native.dart (linux/macos/windows)
                             backs LocalDaemonController with speeddial_daemon's
                             LocalDaemon; local_daemon_stub.dart (web/mobile) reports
                             unsupported. embeddedDaemonSupported gates startup.
lib/src/state/               stores: ConnectionsStore (daemon add/remove/connect,
                             persisted), ProjectsStore, SessionsStore, ChatStore
                             (per-session event buffers, incremental adjacent chunk
                             append, optimistic outgoing messages held from send until
                             the daemon's `userMessage` echo retires them — the echo's
                             seq is remembered as delivered; a rejected send drops the
                             entry, and an acknowledged entry that never matches is
                             dropped at turn end), and the shared presentation-neutral session timeline
                             fold used by both the full client and Wear (logical content
                             identity plus tool/activity snapshot replacement),
                             FilesStore, FileTransferStore (active transfers and dismissible receipts),
                             ShareStore (floating files and staged attachments), GitStore, McpStore, DaemonConfigStore (installed
                             harnesses + write-only environment names), DraftsStore
                             (per-daemon/session composer text persisted locally),
                             SettingsStore (theme mode persisted locally),
                             EmbeddedDaemonStore (persisted
                             interface/port/token of the built-in daemon; restart
                             errors surfaced for its settings page). Stores NEVER hold
                             BuildContext.
                             SessionLinkStore resolves notification links across
                             saved daemon connections, caches only the matching
                             session, and selects daemon/project/session together.
                             Failed and ambiguous lookups retain and rethrow an
                             error; superseded lookups cannot replace selection.
lib/src/ui/shell.dart        responsive shell: >=1000px → three columns (left rail
                             draggable from 240–480px, chat flexible, right 360;
                             side panes collapsible); <1000px →
                             chat full-screen, left = Drawer, right = ModalBottomSheet.
lib/src/ui/flame.dart        hand-painted flame glyph (flickering seamless loop, blaze or
                             blue pilot light) marking agent work in the rail and chat
lib/src/ui/left/             tabbed rail: Sessions keeps the selected daemon's project/session
                             hierarchy and connection controls; Inbox lists sessions across
                             every configured daemon (pinned first, then activity), with
                             a daemon/project chooser for new sessions. Session rows show
                             title, status chip, provider badge, and daemon/project in Inbox;
                             their status mark is a live flame while running and an
                             oven-timer ping while waiting on permission. While the
                             session's daemon is out of reach (connecting, reconnecting,
                             failed) an in-progress status is only the last one heard:
                             flame, ping and chip go grey and still, and the chat's turn
                             row reads "Reconnecting…" / "Daemon unreachable".
                             New-session sheet (provider, worktree branch, yolo,
                             and short prompt —
                             model/thinking are picked in the
                             composer on the live session), pin/unpin/rename/archive/delete menus
lib/src/ui/settings/         daemon-scoped MCP profile list/editor, installed
                             harness/version list with update actions, write-only
                             daemon environment editor, and the built-in daemon's
                             interface/port/token settings (apply restarts the
                             embedded daemon and repoints its endpoint); stored
                             secret values are never read back into Flutter.
lib/src/ui/chat/             timeline (virtualized centered CustomScrollView, reversed), message bubbles,
                             a placeholder conversation while a session's history first loads
                             (history_skeleton.dart: faint bubbles from the bottom up under a
                             warm glint, shown only once the wait outlasts a blink, going cold
                             under the retry card if the fetch fails; the conversation
                             crossfades in over it),
                             MCP-displayed images with lazy attachment payload loading,
                             markdown + syntax-highlighted code blocks, Mermaid flowcharts drawn
                             natively (`chat/mermaid/`: subset parser, layered layout, painter;
                             anything unsupported stays a code block), remote file links that
                             transfer in bounded 256 KiB RPC chunks with progress/cancellation,
                             offer Download (system save picker) or Float (the shared-file card).
                             Transfers and dismissible completion/error receipts live in
                             FileTransferStore across session changes. Native downloads spool to disk;
                             desktop saves replace the chosen destination only after transfer success,
                             Android stages in the cache directory returned by the native
                             downloads channel (`getCacheDirectory`) and exports through the
                             system picker without whole-file buffers,
                             and web hands browser Blobs to the browser with an explicit handoff receipt.
                             Floated files use ShareStore and the protocol’s 8 MiB attachment cap,
                             compact collapsible tool-call rows (kind icon; the agent's own words
                             for the call — a shell tool's `description`, Codex `commandActions`,
                             readable MCP names, or for a call titled only with a Claude Code
                             tool's name what its input did ("Read lines 40–79 of main.dart",
                             "Search “retry” in src") — over the command cleaned of login-shell
                             wrappers, `cd <dir> &&`, env assignments and long paths, or the
                             file's path (tool_call_summary.dart); expandable raw
                             input/content/diff),
                             including lazily loaded image outputs. Rows stay collapsed until
                             tapped. Tool calls and the thinking among them fold into one run
                             (`ToolRunItem`, tool_run.dart; providers think between calls more
                             often than not) that soon settles at its height however many steps
                             come: what the agent last thought and what it last did, a line
                             each — the end of the thought running on as it streams, its start
                             fading off the left (tail_text.dart, thought_line.dart), and the
                             call's description typed out, backspaced and retyped for each new
                             call (typed_text.dart; its command moves into its details). The
                             thought gets its own line because Claude thinks in a burst just
                             before the call it leads to, which would otherwise replace it at
                             once. A rolling "N tool calls · M thoughts" appears once steps
                             are out of sight and opens every step. A call still unfinished in a
                             running turn — whatever its status, since Claude never reports
                             calls as running — is on the heat: its icon glows, a glint
                             sweeps its title (heat_shimmer.dart) and its running time ticks
                             (tool_call_heat.dart); it cools back down once done. While the
                             daemon is out of reach the pane derives the turn as not running,
                             so nothing in it (heat, ember, "Thinking…") claims to be going.
                             A permission request gating a
                             tool call in view folds into that row (pending/denied flagged, the
                             chosen option in its details); other requests and questions take one
                             line with their answer. An agent message first seen while it is
                             being written types itself out behind a glowing ember, at a
                             steady pace that quickens to work off a backlog, however the
                             provider delivers it (typewriter.dart: a clip and a cursor over the
                             laid-out markdown, measured in paint; the bubble grows a line at a
                             time; progress is kept per row so scrolling back does not retype).
                             The ember waits at the end while the message may go on, then goes
                             out with a pop once it is done: a flash, a burst of sparks the air
                             soon slows, and wisps of smoke like a delivered message's steam;
                             plan panel, permission banner with option buttons, composer
                             (multiline, Enter send / Shift+Enter newline, file attachments
                             via file_picker with image thumbnails + file chips,
                             model + thinking/effort selectors fed by the provider, stop button while running), expandable provider
                             activity cards, usage/context footer. A leading `/` opens a
                             filtered menu of commands discovered from the live session.
                             "Oven" turn feedback (oven.dart): sent messages appear at once
                             as veiled "baking" bubbles laid out like their final rows,
                             pop with a glow and steam when the echo replaces them, and a
                             rejected message shakes back into the composer, which blocks
                             another send while one is in flight. The timeline's live end
                             carries a flame row: Preheating… (sent or no output yet), a
                             per-turn cooking verb, Keeping warm… (pilot light) while
                             waiting on permission; it goes out in smoke when the turn ends.
                             Subagents (Codex `subagent` activities, one per interaction, by
                             path; Ante's, one per subagent plus one per action it takes, by
                             the subagent's activity id; older Ante history's Agent tool calls
                             and their progress) gather into one crew per turn
                             (`SubagentCrewItem`, subagent_crew.dart) instead of a card per
                             update: while the turn runs, a little spot at the
                             end of its flame row — a small flame per subagent, flaring as it
                             reports — opens to the list; once the turn ends, the crew takes
                             one line ahead of its divider, the flames gone cold. An opened
                             subagent reads as a log: its actions as tool-style lines (Ante's
                             `Name(key="value", …)` progress parsed back into the tool call it
                             made, subagent_action.dart, and summarized like a tool row; tap
                             for the arguments), its own words without terminal styling, and
                             its report rendered as a message.
                             Codex compact/review/skills and Ante compact/context/skills dispatch
                             through their native transports, with the usual turn events.
lib/src/ui/right/            tabbed panel: Files (lazy tree, tap → viewer with syntax
                             highlight) and Git (branch picker, staged/unstaged lists,
                             per-file diff view, commit field + button, push, create PR)
```

Performance rules for the app:
- Session search: the rail opens a daemon-scoped modal. Queries debounce for 250 ms and
  coalesce while a request is outstanding; stale replies cannot replace newer text or filters.
  Results use a virtualized list of bounded excerpts and keyset pages. Only the selected result
  enters SessionsStore; searching never fetches transcript pages or the full session list.
  The daemon maintains a SQLite FTS5 trigram index in `store/session_search_index.dart`.
  Transactional triggers mark titles/events dirty; short background batches persist their
  cursor alongside 4 KiB text blocks with 256-character overlap. Streaming only rewrites the
  bounded tail of a message. Existing histories backfill without a startup transcript scan,
  and deletes cascade through the index. File-backed MATCH queries use separate read-only
  connections in isolates so broad searches do not stall daemon/embedded-app event handling.
- Timeline: a reversed `CustomScrollView` with history and live slivers growing on
  opposite sides of a fixed origin preserves the reading position. Stable row keys
  and local page storage retain expansion; the down-arrow or a successful local send
  resumes following live events. The down-arrow jumps instantly (an animated scroll over
  long history would only blur past it). Any return to the bottom from far enough away to
  show the down-arrow — the button, a drag, fling or wheel, or following resumed after a
  send — lands in a short spark burst along the bottom edge (landing_sparks.dart);
  wiggles that never leave the bottom do not. The down-arrow rises into view and sinks
  back out (ignoring taps on the way out). While shown, it flares with activity at the
  live end (latest_button.dart): the chat pane counts changes of the newest buffered
  event, which new events and streamed text replace but older pages never touch. Failed
  sends retain the reading position. A touch stops following, so opening something to
  read holds it still; a tap that does not scroll on the newest row (opening the latest
  tool call; a finished turn's divider and the running turn's crew don't count as rows)
  or on the flame row keeps following, so what opens grows into view at the live end.
  Adjacent deltas with the same identity
  append through a `StringBuffer`, while the shared timeline fold joins identified
  content across interleaved replacement snapshots. Notify once per animation frame at
  most (batch via `scheduleMicrotask` coalescing in ChatStore).
- Diff/code highlighting: compute once per event, cache on the event object; never in
  `build`.
- Animations: continuous ones (flame, timer ping, shimmer, a tool call's heat) run only
  while a turn is active, repaint through painters/render objects behind repaint
  boundaries rather than rebuilding, and hold still when the platform requests reduced
  motion.
- No `setState` in panes; only store notifications through `ListenableBuilder` scoped to
  the narrowest widget.

## Wear OS companion app

`packages/wear` is the watch build of the Android application (`sh.speeddial.speeddial`).
The phone and watch APKs must use the same application id and signing certificate so Google Play
Services Wearable Data Layer treats them as one companion application. The phone app publishes its
persistent daemon endpoint snapshot at `/speeddial/endpoints`; the watch consumes that snapshot,
persists it locally, and removes stale watch endpoints when the phone removes them. Embedded desktop
endpoints are never synchronized.

The phone also publishes a compact, activity-sorted session snapshot at `/speeddial/sessions`.
Native watch storage keeps that snapshot available when Flutter is not running and merges live
session changes observed by the open watch app. On launch and resume, the watch fetches a complete
all-project listing from every reachable daemon; those daemon slices replace, rather than append to,
their native cache so deleted sessions and old statuses cannot linger. Unreachable daemons retain
their last phone snapshot. `RecentSessionsTileService` renders the three newest sessions in a
circular-safe Tile; each row carries its daemon/project/session identity and opens that chat
directly. `SessionCountsComplicationService` exposes short- and
long-text count fallbacks plus weighted elements for running/waiting-for-approval sessions and
daemon-persisted unacknowledged completed turns. The weighted elements use blue for in-progress
and green for done; tapping the complication opens an activity-sorted list of those sessions across
all configured daemons. Each watch face controls whether that split appears as a bar, arc, or
another supported layout. Tile
updates are requested whenever the snapshot changes; complication push updates are limited to once
per five minutes and backed by the platform's five-minute periodic refresh.

The watch opens a bidirectional Wear Data Layer channel at `/speeddial/proxy/v1` for each daemon
connection. A foreground `WearableListenerService` on the paired phone opens the actual WebSocket
and forwards its text frames over that channel. Consequently daemon traffic follows the phone's
active network/VPN route (including Tailscale); the daemon does not need to be public or directly
reachable from the watch. The paired Android phone must be connected, and it shows a low-priority
notification while a watch proxy is active. The watch and phone reuse the app's normal JSON-RPC,
authentication, reconnect, and notification handling around this raw-frame transport. Credentials
remain owned and edited by the phone app; the watch has no endpoint-entry UI.

The channel starts with the original uncompressed record format. A new phone advertises `gzip-v1`
in its ready record and enables compressed data records only after a new watch echoes that
capability, so phone/watch updates can be installed in either order. Frames of at least 1 KiB are
gzipped when that shrinks them. Wear also requests 100-event `summary` history pages (verbose
thought/tool/plan/activity detail is projected out) and retains an LRU of three inactive chat
buffers; reopens render immediately while normal sequence reconciliation catches up in the
background.

Watch layouts derive circular-safe header/content/composer insets from their allocated width. This
keeps complete header actions, list rows, empty-state actions, and bottom chat controls inside round
screens down to 192 logical pixels without hardware-type checks.

The reusable watch UI lives under `packages/app/lib/src/ui/wear/` and consumes the same
`AppData`, `ProjectsStore`, `SessionsStore`, and `ChatStore` as the full client. The watch does
not expose files, git mutations, MCP, worktree, project, or daemon settings.

## Verification gates (orchestrator runs these, subagents NEVER do)

- `dart analyze` in packages/protocol and packages/daemon; `flutter analyze` in packages/app
  and packages/wear
- `dart test` in packages/protocol and packages/daemon; `flutter test` in packages/app
- UI: `flutter run -d web-server` + screenshots at desktop (1440x900) and mobile (390x844)
- Wear OS: watch widget tests run from packages/app; `flutter build apk` runs from packages/wear
  sizes

## Deferred (explicitly out of scope for this build)

Voice dictation, E2E-encrypted relay pairing, iOS/Android store packaging. UI must remain
mobile-sized-layout correct (verified via narrow viewport), daemon must not assume
loopback-only networking (token auth + bind flag).

### Mobile incoming shares

`ShareStore` consumes the `sh.speeddial/share` platform channel on Android and
iOS. Android uses `singleTask` with the default app task affinity so incoming
shares return to the existing app and reach its Flutter engine through
`MainActivity.onNewIntent`, preserving the selected chat and in-memory state.
Both reuse floating attachments, composer staging, and project-specific
session creation settings. iOS includes a native Share extension with a project
picker and an App Group inbox; the app imports one file on launch or resume,
then advances after attach or dismiss. The extension has no daemon credentials
and does not send messages. Its immutable inbox entries are published atomically
and consumed by a serial native worker.

### Notification session links

The protocol package's SessionLink helper builds and parses
`speeddial://session?sessionId=<id>&projectId=<id>` and hosted-web equivalents.
Android/iOS register the `speeddial` scheme and use Flutter's built-in deep-link
delivery. The root app handles initial and incoming route information within
the existing shell, and web startup reads session parameters from `Uri.base`.
Links use already saved endpoints and credentials; they never add a connection.
If the same project/session IDs exist on multiple daemons, the app reports the
ambiguity instead of opening an arbitrary copy. Native desktop URL-scheme
registration is not provided; desktop notification links can use a hosted web app.

### Session preparation

The wire create operation persists and publishes a session with `preparing: true` before
Git or harness I/O. SessionEngine owns background preparation and one accepted queued turn;
the user message and attachments are persisted before acknowledgement. Cancellation drops
the queued turn, deletion/shutdown drain preparation, and errors remain in session history.
Interrupted preparation is retryable by sending again, without automatically replaying an
old queued message. The new-session sheet warms the selected base branch fetch, sharing its
in-flight result with worktree creation (30-second freshness, consumed on use).
