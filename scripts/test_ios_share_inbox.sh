#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$repo_dir/packages/app/ios/Shared/ShareInbox.swift" \
  "$repo_dir/packages/app/ios/ShareTests/main.swift" -o "$test_dir/share-tests"
"$test_dir/share-tests"
