#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d)"
trap 'rm -rf "$TEST_BUILD"' EXIT
swift test --package-path "$ROOT/PiWatchLink"
swiftc -swift-version 6 -emit-library -emit-module -module-name PiWatchLink \
  "$ROOT"/PiWatchLink/Sources/PiWatchLink/*.swift \
  -emit-module-path "$TEST_BUILD/PiWatchLink.swiftmodule" -o "$TEST_BUILD/libPiWatchLink.dylib"
swiftc -swift-version 6 -D DEBUG -parse-as-library \
  -I "$TEST_BUILD" -L "$TEST_BUILD" -lPiWatchLink -Xlinker -rpath -Xlinker "$TEST_BUILD" \
  "$ROOT/App/PiMobile/WatchRequestStore.swift" "$ROOT/App/PiMobile/SimulatorVoiceUpload.swift" \
  "$ROOT/App/PiWatch/WatchListVisibility.swift" \
  "$ROOT/tools/WatchTests/StorageChecks.swift" -o "$TEST_BUILD/watch-storage-checks"
"$TEST_BUILD/watch-storage-checks"
