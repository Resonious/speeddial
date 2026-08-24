#!/usr/bin/env bash
# build_and_serve.sh — build all SpeedDial release artifacts and serve the
# download links over HTTP. Sending a newline (bare Enter) to this process's
# stdin triggers a rebuild without restarting the server.
#
#   scripts/build_and_serve.sh [port]
#
# Environment (defaults match the dev workstation):
#   PORT          HTTP port (default 8777)
#   DOWNLOAD_DIR  dir to serve and stage builds into (default ~/speeddial-download)
#   FLUTTER_ROOT  Flutter SDK root (default ~/p/flutter-sdk)
#   ANDROID_HOME  (default ~/Android/Sdk)
#   JAVA_HOME     (default /usr/lib/jvm/java-21-temurin-jdk)
#
# While running:
#   - Enter (any input) -> rebuild all artifacts, re-stage, keep serving
#   - "q" (or Ctrl-C)   -> stop
#
# Builds run in parallel across the three packages (app / wear / daemon);
# inside the app package, the Android APK and Linux bundle build sequentially
# because they share build/ and .dart_tool.

set -euo pipefail

PORT="${1:-${PORT:-8777}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/speeddial-download}"
FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/p/flutter-sdk}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-temurin-jdk}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="$FLUTTER_ROOT/bin:$PATH"
export ANDROID_HOME JAVA_HOME

_cleanup() { trap - EXIT INT TERM; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; }
trap _cleanup EXIT INT TERM

require() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not found" >&2; exit 1; }; }
require flutter; require dart; require python3; require git; require tar

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

stage_app_apk() {
  cp "$REPO_ROOT/packages/app/build/app/outputs/flutter-apk/app-release.apk" \
     "$DOWNLOAD_DIR/speeddial.apk"
  log "staged speeddial.apk"
}
stage_app_linux() {
  tar -czf "$DOWNLOAD_DIR/speeddial-linux.tar.gz" \
      -C "$REPO_ROOT/packages/app/build/linux/x64/release" bundle
  log "staged speeddial-linux.tar.gz"
}
stage_wear() {
  cp "$REPO_ROOT/packages/wear/build/app/outputs/flutter-apk/app-release.apk" \
     "$DOWNLOAD_DIR/speeddial-wear.apk"
  log "staged speeddial-wear.apk"
}
stage_daemon() {
  tar -czf "$DOWNLOAD_DIR/speeddial-daemon-linux-x64.tar.gz" \
      -C /tmp/sd-daemon-build bundle
  log "staged speeddial-daemon-linux-x64.tar.gz"
}

build_all() {
  local head
  head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  log "build all from HEAD $head (parallel: app / wear / daemon)"

  ( cd "$REPO_ROOT/packages/app" \
      && flutter build apk --release \
      && flutter build linux --release ) &
  local app_pid=$!

  ( cd "$REPO_ROOT/packages/wear" \
      && flutter pub get >/dev/null \
      && flutter build apk --release ) &
  local wear_pid=$!

  ( cd "$REPO_ROOT/packages/daemon" \
      && rm -rf /tmp/sd-daemon-build \
      && dart build cli -t bin/speeddial.dart -o /tmp/sd-daemon-build ) &
  local daemon_pid=$!

  local rc=0
  wait "$app_pid" "$wear_pid" "$daemon_pid" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: one or more builds failed (rc=$rc); serving existing artifacts"
    return 1
  fi

  stage_app_apk; stage_wear; stage_daemon; stage_app_linux
  log "all artifacts staged in $DOWNLOAD_DIR"
  return 0
}

mkdir -p "$DOWNLOAD_DIR"

# Initial build so the served links resolve immediately.
build_all || true

log "serving $DOWNLOAD_DIR at http://0.0.0.0:$PORT/ (Enter=rebuild, q=quit)"
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DOWNLOAD_DIR" \
    >/dev/null 2>&1 &
SERVER_PID=$!

while IFS= read -r line; do
  case "$line" in
    q|quit) log "quitting"; break ;;
    *) build_all || true ;;
  esac
done

log "server stopped"
