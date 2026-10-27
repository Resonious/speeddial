#!/usr/bin/env bash
# Build on startup, Enter, and changes to this checkout's HEAD; serve throughout.
# Usage: scripts/build_and_serve.sh [port] (default PORT=8777)
# DOWNLOAD_DIR defaults to ~/speeddial-download. q or Ctrl-C stops the server.
set -euo pipefail
FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/p/flutter-sdk}"
export PATH="$FLUTTER_ROOT/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-temurin-jdk}"
for command in flutter dart python3 git tar; do
  command -v "$command" >/dev/null || { echo "error: $command not found" >&2; exit 1; }
done
exec python3 "$(dirname "${BASH_SOURCE[0]}")/build_server.py" "$@"
