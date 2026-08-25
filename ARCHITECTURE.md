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
lib/src/codex/      Codex's native `codex app-server --stdio` JSONL transport. Initializes
                    the app server, starts/resumes threads with `danger-full-access`
                    because SpeedDial worktrees and localhost tooling must stay usable,
                    starts/steers/interrupts turns, applies model and reasoning-effort
                    settings, resolves command and patch approvals, injects MCP server
                    configuration, and maps native message, reasoning, command, file-change,
                    MCP, collaboration, web-search, image, plan, review, usage, compaction,
                    and lifecycle notifications into the shared agent update stream.
lib/src/ante/       Ante's `ante serve --stdio` JSONL client. Starts/resumes sessions,
                    sends `UserInput`, handles approval pauses, and maps message/thought
                    deltas, tool progress, usage/context accounting, extension/MCP refresh,
                    info blocks, shell output, compaction, and errors into the shared agent
                    update stream. Native `TodoWrite` calls become shared plan updates so
                    every provider uses the same checklist UI. Catalog data comes from
                    `ante catalog`. Only the
                    daemon-owned `speeddial` MCP descriptor is merged into the selected
                    native Ante settings in a private transient `ANTE_HOME`; non-settings
                    state links back to the real home, native MCP entries remain direct,
                    and the transient directory is removed on process exit. New sessions
                    are seeded with the settings default model/provider (serve mode
                    ignores them when StartSession omits a model).
lib/src/mcp/        BuiltInMcpServer: daemon-owned stdio MCP JSON-RPC subprocess injected
                    into every compatible provider session. ACP and Codex receive its
                    descriptor directly; Ante receives it through its transient home.
                    Search tools bridge over an authenticated, session-bound loopback
                    WebSocket to query projects/session history; display_image persists
                    an attachment and emits an image event. McpProxySession owns the matching
                    managed upstreams for that bridge connection, starts stdio servers in the
                    session cwd, drives Streamable HTTP JSON/SSE sessions, qualifies, sanitizes,
                    aggregates tool descriptors (stripping regex-lookaround `pattern` constraints
                    model providers reject), routes calls, and closes every upstream
                    with the bridge. Managed commands, URLs, environment values, headers,
                    and OAuth tokens never enter provider configuration. OAuth callbacks can
                    terminate at the daemon or at a temporary native-app localhost listener;
                    app-received callbacks are validated and completed through authenticated RPC.
                    The same hidden
                    subprocess entry works from the daemon CLI and native Flutter
                    executable. Profiles are daemon-wide or project-scoped; a project
                    receives both matching sets. HTTP OAuth 2.1 authorization-code + S256
                    PKCE discovery, registration, callback handling, and refresh live in
                    server/mcp_oauth_service.dart.
lib/src/providers/  Provider registry. Built-ins:
                      omp    → ["omp", "acp"]                              (ACP)
                      claude → ["npx", "-y", "@zed-industries/claude-code-acp"] (ACP)
                      codex  → ["codex", "app-server", "--stdio"]          (Codex)
                      ante   → ["ante", "serve", "--stdio"]                (Ante)
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
                    via SessionStore, and broadcasts to listeners. Handles permission
                    requests (parked until respondPermission), cancel, process exit, and
                    turn lifecycle. Inline tool-result images and provider-reported image
                    file reads are deduplicated into attachment-backed tool content. MCP
                    injection supports ACP, Codex, and Ante. ACP
                    receives structured attachments; Codex receives native text, image,
                    and audio inputs; Ante inlines UTF-8 text attachments and
                    materializes images as transient `@` file mentions for Ante's native
                    context resolver. Unsupported binary attachments are rejected before
                    turn start.
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
                    confines project browsing and binary session-cwd link downloads, including
                    symlink resolution, before any bytes cross the wire.
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
- `token` — prints/rotates the auth token.
- `projects list|add <path>|remove <id>`
- `sessions list [--project <id>]|create --project <id> --provider <id> [--model m] [--mode plan] [--title t] [--base b] [--yolo]|send <id> <text>|cancel <id>|archive <id>|delete <id>|history <id>|attach <id>` (attach = stream session.event notifications to stdout)
- `git status|diff [--staged]|commit -m <msg> [--all]|push|pr [--title t] [--base b]|merge-base --session <id>` — all take `--project <id>`
- Global flags: `--host`, `--port`, `--token` override discovery file.

## App

Package name `speeddial_app`. No third-party state management: plain `ChangeNotifier`
stores + `ListenableBuilder`. One inherited-widget accessor `AppScope.of(context)`
(lib/src/scope.dart) exposing the store graph. Deps: `web_socket_channel`,
`shared_preferences`, `flutter_markdown_plus`, `syntax_highlight`, `collection`,
`speeddial_daemon` (path dep — the desktop build embeds the daemon in-process).

```
lib/main.dart                hidden native MCP subprocess dispatch, then runApp; desktop builds start an embedded in-process daemon
                             (lib/src/local_daemon/) from the persisted
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
                             (per-session event buffers, incremental chunk append),
                             FilesStore, GitStore, McpStore, DaemonConfigStore (installed
                             harnesses + write-only environment names), DraftsStore
                             (per-daemon/session composer text persisted locally),
                             SettingsStore (theme mode persisted locally),
                             EmbeddedDaemonStore (persisted
                             interface/port/token of the built-in daemon; restart
                             errors surfaced for its settings page). Stores NEVER hold
                             BuildContext.
lib/src/ui/shell.dart        responsive shell: >=1000px → three columns (left 280,
                             chat flexible, right 360, both collapsible); <1000px →
                             chat full-screen, left = Drawer, right = ModalBottomSheet.
lib/src/ui/left/             daemon/project/session rail: connection status dot, project
                             groups, session rows (title, status chip, provider badge),
                             new-session sheet (provider, worktree branch, and yolo —
                             model/thinking are picked in the
                             composer on the live session), rename/archive/delete menus
lib/src/ui/settings/         daemon-scoped MCP profile list/editor, installed
                             harness/version list with update actions, write-only
                             daemon environment editor, and the built-in daemon's
                             interface/port/token settings (apply restarts the
                             embedded daemon and repoints its endpoint); stored
                             secret values are never read back into Flutter.
lib/src/ui/chat/             timeline (virtualized ListView, reversed), message bubbles,
                             MCP-displayed images with lazy attachment payload loading,
                             markdown + syntax-highlighted code blocks, remote file links that
                             download to a client-local temporary copy and open via the OS,
                             collapsible
                             tool-call cards (status icon, title, expandable content/diff),
                             including lazily loaded image outputs,
                             plan panel, permission banner with option buttons, composer
                             (multiline, Enter send / Shift+Enter newline, file attachments
                             via file_picker with image thumbnails + file chips, mode
                             selector, model + thinking/effort selectors fed by the
                             provider, stop button while running), expandable provider
                             activity cards, usage/context footer
lib/src/ui/right/            tabbed panel: Files (lazy tree, tap → viewer with syntax
                             highlight) and Git (branch picker, staged/unstaged lists,
                             per-file diff view, commit field + button, push, create PR)
```

Performance rules for the app:
- Timeline: `ListView.builder(reverse: true)`, streaming chunks append to the LAST
  event's `StringBuffer`; notify once per animation frame at most (batch via
  `scheduleMicrotask` coalescing in ChatStore).
- Diff/code highlighting: compute once per event, cache on the event object; never in
  `build`.
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
session changes observed by the open watch app. `RecentSessionsTileService` renders the three newest
active sessions in a circular-safe Tile. `SessionCountsComplicationService` exposes short- and
long-text count fallbacks plus weighted elements for running/waiting-for-approval sessions and
unseen completed turns. The weighted elements use blue for in-progress and green for done; each
watch face controls whether that split appears as a bar, arc, or another supported layout. Tile
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
