# AGENTS.md — SpeedDial

Fast agent development environment: Dart daemon + Flutter UI. Read this, then
[PROTOCOL.md](PROTOCOL.md) (wire API — authoritative) and
[ARCHITECTURE.md](ARCHITECTURE.md) (layout + conventions) before editing.

## Layout

- `packages/protocol` — wire models + JSON-RPC codec. Zero deps. Daemon and app both import it.
- `packages/daemon` — CLI daemon: ACP agent sessions (`lib/src/acp/`), SQLite store (`lib/src/store/`),
  session engine (`lib/src/engine/`), git/`gh` (`lib/src/git/`), WebSocket server (`lib/src/server/`),
  CLI (`lib/src/cli/`, `bin/speeddial.dart`).
- `packages/app` — Flutter UI: `lib/src/api/` (DaemonClient, fake, ws impl), `lib/src/state/`
  (ChangeNotifier stores), `lib/src/ui/{shell,left,chat,right}` (three panes).

## Hard rules

1. **No code generation.** No build_runner/freezed/riverpod-codegen. Hand-written `fromJson`/`toJson`.
2. **PROTOCOL.md is the contract.** Change a method/field/notification → update PROTOCOL.md *and* both
   sides (daemon `lib/src/server/`, app `lib/src/api/`) in the same change.
3. **No new dependencies** without strong justification; state/state-management: only `ChangeNotifier`
   + `ListenableBuilder` + `AppScope.of(context)`.
4. **Never swallow errors** in stores: record to `errorFor`/`lastError`, notify, and rethrow.
5. Tests must not touch the network, real agent CLIs, or real git remotes — use the fake ACP agent
   (`packages/daemon/test/fixtures/fake_acp_agent.dart`) and `FakeDaemonClient` in the app.

## Toolchain (this machine)

Flutter SDK is NOT on PATH by default:

```bash
export PATH="$HOME/p/flutter-sdk/bin:$PATH"
dart pub get   # once, at repo root (pub workspace resolves all packages)
```

## Gates — run before considering work done

```bash
dart analyze packages/protocol packages/daemon packages/app
(cd packages/protocol && dart test)
(cd packages/daemon && dart test)    # MUST run with cwd = packages/daemon
(cd packages/app && flutter test)
```

Known traps:
- Run daemon tests from `packages/daemon/` (some tests resolve fixtures relative to cwd).
- `dart test packages/daemon` from the repo root also works (tests handle both), but don't assume.
- One flaky-looking broadcast race was real before; if `ws_server_test` fails, rerun once — then
  actually investigate, don't just retry.

## Run things

```bash
# Daemon (loopback, no auth):
cd packages/daemon && dart run bin/speeddial.dart serve            # ws://127.0.0.1:7331/ws
# App, demo mode (fake backend, no daemon needed):
cd packages/app && flutter run -d linux --dart-define=demo=true
# App against the real daemon: add daemon "localhost:7331" (no token) in the left rail.
```

`--dart-define` is **build-time only** — passing it to a built binary does nothing.

## Platform notes (this host)

- Linux desktop build works (GTK toolchain installed). Impeller only — **software rendering is
  compiled out**, so the app renders black under Xvfb; don't try to screenshot it there.
- Web: `flutter run -d web-server --web-port=8899 --dart-define=demo=true` — used for screenshot
  verification (no system Chrome needed).
- Android SDK is installed (`~/Android/Sdk`, `ANDROID_HOME` not exported by default) and the debug
  APK builds, but the emulator crashes on this kernel; use a physical device over adb.
- GNOME blocks programmatic screen capture; desktop screenshots go through the interactive portal.

## Style

Boring code wins. Final fields, explicit types, small files. Performance matters: no per-frame
allocation in build methods; cache syntax highlighting; chunk-merge via StringBuffer (see
`chat_store.dart`); stores coalesce notifications.
