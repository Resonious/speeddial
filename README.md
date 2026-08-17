# SpeedDial

A fast agent development environment (ADE) written entirely in Dart and Flutter.
Control `omp`, `claude`, and `codex` coding agents from one three-pane UI —
desktop, mobile, or web — against any number of local or remote daemons.

Inspired by [T3 Code](https://github.com/pingdotgg/t3code) and
[Paseo](https://github.com/getpaseo/paseo); built in Flutter for speed.

## Components

| Package | What it is |
| --- | --- |
| `packages/protocol` | Wire protocol (models + JSON-RPC 2.0 codec). Zero dependencies. |
| `packages/daemon` | CLI daemon: ACP agent sessions, SQLite bookkeeping, git/`gh` ops, WebSocket API. |
| `packages/app` | Flutter UI: daemons/projects/sessions rail, agent chat, files/git panel. |

The daemon talks to agent CLIs over [ACP](https://agentclientprotocol.com)
(newline-delimited JSON-RPC over stdio):

- `omp` → `omp acp` (native)
- `claude` → `npx -y @zed-industries/claude-code-acp`
- `codex` → `npx -y @zed-industries/codex-acp`

Add or override providers in `~/.speeddial/config.json`:

```json
{
  "providers": {
    "my-agent": { "name": "My Agent", "command": ["my-agent", "--acp"] }
  }
}
```

## Run the daemon

```bash
cd packages/daemon
dart run bin/speeddial.dart serve --port 7331
# non-loopback bind or --token enables auth:
dart run bin/speeddial.dart serve --host 0.0.0.0 --token "$(openssl rand -hex 16)"
```

The daemon writes `~/.speeddial/daemon.json` (mode 0600) with host/port/token
for CLI and UI discovery.

## CLI

Every UI operation has a CLI equivalent against a running daemon:

```bash
dart run bin/speeddial.dart projects add ~/code/myrepo
dart run bin/speeddial.dart sessions create --project <id> --provider omp --title "fix login"
dart run bin/speeddial.dart sessions send <id> "add tests for the auth flow"
dart run bin/speeddial.dart sessions attach <id>        # live event stream
dart run bin/speeddial.dart git status --project <id>
dart run bin/speeddial.dart git commit --project <id> -m "wip" --all
dart run bin/speeddial.dart git pr --project <id> --title "Add auth" --draft
```

Add `--json` for machine-readable output. Exit codes: 0 ok, 1 usage, 2 daemon
unreachable, 3 daemon error.

## Run the UI

```bash
cd packages/app
flutter run -d linux          # or android / an emulator / chrome
flutter run -d web-server --dart-define=demo=true   # demo mode, no daemon needed
```

Add a daemon from the left rail ("Add daemon": name, `host:port` or full
`ws://` URL, token). Layout adapts: three columns on wide screens; drawer +
modal sheets on narrow ones.

## Wire protocol

See [PROTOCOL.md](PROTOCOL.md). JSON-RPC 2.0 over WebSocket at `/ws`; token
auth; sessions stream normalized events (message chunks, tool calls, plans,
permission requests, usage) with per-session `seq` for gap detection.

## Development

Pub workspace — one resolve at the root:

```bash
dart pub get
dart analyze packages/protocol packages/daemon packages/app
(cd packages/protocol && dart test) && (cd packages/daemon && dart test)
(cd packages/app && flutter test)
```

Conventions (no codegen, hand-written JSON, ChangeNotifier stores) are in
[ARCHITECTURE.md](ARCHITECTURE.md).
