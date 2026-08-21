# SpeedDial Architecture

Monorepo, pure Dart/Flutter, no code generation anywhere (no build_runner, no freezed,
no riverpod codegen). All JSON is hand-written `fromJson`/`toJson`. Performance is the
top priority: avoid avoidable allocations, rebuild only what changed, keep hot paths free
of per-frame work.

## Layout

```
packages/protocol/   pure Dart, zero deps beyond SDK. Implements PROTOCOL.md exactly:
                     models, SessionEvent union, JSON-RPC 2.0 codec (peer for both sides).
packages/daemon/     Dart CLI + library. Spawns agent CLIs via ACP, owns session/project
                     bookkeeping (SQLite), git/gh operations, WebSocket JSON-RPC server.
packages/app/        Flutter app (desktop + mobile + web). Three-pane control surface.
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
lib/src/acp/        ACP (Agent Client Protocol) client over newline-delimited JSON-RPC
                    stdio. Spec: https://agentclientprotocol.com — implements:
                    initialize, authenticate, session/new, session/load,
                    session/prompt, session/cancel, session/set_mode, session/set_model;
                    notifications session/update (variants: user_message_chunk,
                    agent_message_chunk, agent_thought_chunk, tool_call, tool_call_update,
                    plan, available_commands_update, current_mode_update, usage_update);
                    agent→client requests: session/request_permission, fs/read_text_file,
                    fs/write_text_file (sandboxed to the session cwd; terminal/* → error).
lib/src/mcp/        BuiltInMcpServer: daemon-owned stdio MCP JSON-RPC subprocess injected
                    into every ACP new/load request. Search tools bridge over an
                    authenticated, session-bound loopback WebSocket to query
                    projects/session history; display_image persists an attachment and
                    emits an image event. The same hidden subprocess entry works from the
                    daemon CLI and the native Flutter executable used by the embedded
                    daemon. User-configured stdio and Streamable HTTP MCP profiles are
                    daemon-managed or project-scoped, then injected directly into
                    compatible ACP agents; project sessions receive daemon-wide plus
                    matching project profiles. The built-in server does not proxy their
                    tools. HTTP profiles may use
                    daemon-managed OAuth 2.1 authorization-code + S256 PKCE; discovery,
                    dynamic client registration, callback handling, and token refresh live
                    in server/mcp_oauth_service.dart.
lib/src/providers/  Provider registry. Built-ins:
                      omp    → ["omp", "acp"]
                      claude → ["npx", "-y", "@zed-industries/claude-code-acp"]
                      codex  → ["npx", "-y", "@zed-industries/codex-acp"]
                    `~/.speeddial/config.json` may add/override providers:
                    {"providers": {"<id>": {"name": "...", "command": ["...", ...]}}}
                    Availability = command[0] resolvable via PATH (or absolute exists).
lib/src/engine/     SessionEngine: owns live ACP processes per session, maps ACP updates
                    to protocol SessionEvents, assigns seq, persists via SessionStore,
                    broadcasts to listeners. Handles permission requests (parked until
                    respondPermission), cancel, process exit, turn lifecycle.
lib/src/store/      Bundled SQLite (package:sqlite3 build hooks; no system SQLite runtime
                    dependency) at ~/.speeddial/speeddial.db (override with --db or
                    SPEEDIAL_DB). Tables: projects, sessions, session_events,
                    attachments (message and MCP-displayed image payloads, FK-cascaded
                    with their session; events carry metadata only, `attachments.read`
                    serves blobs), mcp_servers, mcp_secrets, and mcp_oauth. MCP static
                    secrets, OAuth client secrets, and access/refresh tokens stay
                    daemon-side; public reads expose only credential names and OAuth
                    connection metadata. SQLite database/WAL files are restricted to
                    owner access (0600) on POSIX hosts. WAL mode, foreign keys on. Events
                    are stored as JSON blobs + seq. Session/event substring queries back
                    MCP search.
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
                    PROTOCOL.md. JsonRpcPeer from the protocol package does framing.
lib/src/client.dart DaemonClient: Dart client for the same protocol (used by the CLI
                    subcommands to talk to a running daemon).
lib/src/local_daemon.dart  LocalDaemon: in-process daemon (same engine/store/server as
                    `serve`) without CLI arg parsing, discovery file, or signal handling.
                    Binds 127.0.0.1 on an OS-chosen port with no auth. Started/stopped
                    by the embedding app; exported via the public library.
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
                             (lib/src/local_daemon/) and auto-add a non-persistent
                             "This computer" endpoint; web/mobile skip embedding.
                             SpeedDialApp is a WidgetsBindingObserver that stops the
                             embedded daemon on app shutdown.
lib/src/scope.dart           AppScope inherited widget + store graph
lib/src/theme.dart           light + dark Material 3 themes (GitHub palettes), monospace accents, dense
lib/src/api/daemon_client.dart    DaemonClient: WebSocket JSON-RPC client per PROTOCOL.md
                                  (auth, reconnect with backoff, request map, notification
                                  stream, seq-gap detection + history refetch)
lib/src/api/fake_daemon.dart      FakeDaemonClient: in-memory scripted implementation used
                                  by widget tests AND by --demo mode; simulates streaming
lib/src/local_daemon/         embedded in-process daemon (desktop only). Conditional
                             import: local_daemon_native.dart (linux/macos/windows)
                             backs LocalDaemonController with speeddial_daemon's
                             LocalDaemon; local_daemon_stub.dart (web/mobile) reports
                             unsupported. embeddedDaemonSupported gates startup.
lib/src/state/               stores: ConnectionsStore (daemon add/remove/connect,
                             persisted), ProjectsStore, SessionsStore, ChatStore
                             (per-session event buffers, incremental chunk append),
                             FilesStore, GitStore, McpStore, SettingsStore (theme
                             mode persisted locally). Stores NEVER hold BuildContext.
lib/src/ui/shell.dart        responsive shell: >=1000px → three columns (left 280,
                             chat flexible, right 360, both collapsible); <1000px →
                             chat full-screen, left = Drawer, right = ModalBottomSheet.
lib/src/ui/left/             daemon/project/session rail: connection status dot, project
                             groups, session rows (title, status chip, provider badge),
                             new-session sheet (provider, worktree branch, yolo only —
                             model/thinking are picked in the composer on the live
                             session), rename/archive/delete menus
lib/src/ui/settings/         daemon-scoped MCP profile list/editor; stdio command/env and
                             remote HTTP URL/header values are written to the daemon,
                             while stored secret values are never read back into Flutter.
lib/src/ui/chat/             timeline (virtualized ListView, reversed), message bubbles,
                             MCP-displayed images with lazy attachment payload loading,
                             markdown + syntax-highlighted code blocks, collapsible
                             tool-call cards (status icon, title, expandable content/diff),
                             plan panel, permission banner with option buttons, composer
                             (multiline, Enter send / Shift+Enter newline, file attachments
                             via file_picker with image thumbnails + file chips, mode
                             selector, model + thinking-level selectors fed by the agent's
                             ACP config options, stop button while running), usage footer
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

## Verification gates (orchestrator runs these, subagents NEVER do)

- `dart analyze` in packages/protocol and packages/daemon; `flutter analyze` in packages/app
- `dart test` in packages/protocol and packages/daemon; `flutter test` in packages/app
- UI: `flutter run -d web-server` + screenshots at desktop (1440x900) and mobile (390x844)
  sizes

## Deferred (explicitly out of scope for this build)

Voice dictation, E2E-encrypted relay pairing, iOS/Android store packaging. UI must remain
mobile-sized-layout correct (verified via narrow viewport), daemon must not assume
loopback-only networking (token auth + bind flag).
