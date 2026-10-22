#!/bin/bash
# Settings sync between simulated devices, on this Mac (tools/settings-sync-test): changes to different items merge, a
# change iCloud Keychain lost (another device's write of the item crossed it) is sent again, an MCP server changed
# differently on two devices, neither having seen the other's change, is asked about instead of overwritten, and so is
# another device's change to a network server, Crabbox broker or MCP server set on this one; kept, it stays this one's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 6 "$ROOT/App/PiMobile/SyncedSettings.swift" "$ROOT/tools/settings-sync-test/main.swift" -o "$OUT/settings-sync-test"
"$OUT/settings-sync-test"
