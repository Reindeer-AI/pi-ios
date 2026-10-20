#!/bin/bash
# Session sync end to end, on two new simulators that share a folder in place of iCloud: one is the "iPhone", the other
# the "Mac". The iPhone runs a session that writes a file; the Mac gets it, continues it and writes another; the iPhone
# gets that back (tools/DemoTour's testSyncSend, testSyncContinue, testSyncBack). Then the iPhone adds to the session with
# sync off while the Mac takes it over; once the iPhone syncs again, the Mac's work is in the session and the iPhone's
# offline work in a session of its own (testSyncOffline, testSyncTakeOver, testSyncSplit). The files are checked in each
# simulator's copy of the workspaces.
#
#   scripts/test-session-sync.sh [WORK]    WORK: a folder for builds and the shared folder (default: a new one)
#   KEEP=1 keeps the simulators afterwards.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d)}"
CLOUD="$WORK/cloud-$(date +%s)"
mkdir -p "$CLOUD"
BUNDLE_ID=dev.pimobile.PiMobile

PHONE=$(xcrun simctl create "pi sync iPhone" "iPhone 17 Pro")
MAC=$(xcrun simctl create "pi sync Mac" "iPhone 17")
cleanup() {
	if [[ -z "${KEEP:-}" ]]; then
		xcrun simctl shutdown "$PHONE" "$MAC" 2>/dev/null || true
		xcrun simctl delete "$PHONE" "$MAC"
	fi
}
trap cleanup EXIT
(cd "$ROOT/engine" && npm run build >/dev/null)
# For the simulator's own architecture (the vendored frameworks have no Intel simulator slices).
xcodebuild build -project "$ROOT/App/PiMobile.xcodeproj" -scheme PiMobile -destination "id=$PHONE" \
	-derivedDataPath "$WORK/app" >"$WORK/app.log" 2>&1 || { grep -E ' error:' "$WORK/app.log" | head -20; exit 1; }
APP="$WORK/app/Build/Products/Debug-iphonesimulator/PiMobile.app"
for device in "$PHONE" "$MAC"; do
	xcrun simctl boot "$device"
	xcrun simctl install "$device" "$APP"
done

step() {
	local device=$1 test=$2
	echo "== $test"
	TEST_RUNNER_SYNC_FOLDER="$CLOUD" xcodebuild test -project "$ROOT/tools/DemoTour/DemoTour.xcodeproj" -scheme DemoTour \
		-destination "id=$device" -derivedDataPath "$WORK/tour" -only-testing:"DemoTourUITests/TourTests/$test" \
		>"$WORK/$test.log" 2>&1 || { grep -E 'error:|failed|SCREEN' -A3 "$WORK/$test.log" | head -40; exit 1; }
	xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null || true
}

# The file a session wrote, in a simulator's copy of its workspace.
workspace_file() {
	local device=$1 name=$2
	local data
	data=$(xcrun simctl get_app_container "$device" "$BUNDLE_ID" data)
	find "$data/Documents/sessions" -name "$name" -type f | head -1
}

expect_file() {
	local device=$1 name=$2 expected=$3 file
	file=$(workspace_file "$device" "$name")
	if [[ -z "$file" || "$(cat "$file")" != "$expected" ]]; then
		echo "error: $name on $device: ${file:+$(cat "$file")}${file:-missing}" >&2
		exit 1
	fi
	echo "$name: as expected"
}

step "$PHONE" testSyncSend
step "$MAC" testSyncContinue
expect_file "$MAC" note.txt "synced from the iPhone"
step "$PHONE" testSyncBack
expect_file "$PHONE" seen.txt $'synced from the iPhone\ncontinued on the Mac'
# The iPhone adds to the session offline while the Mac takes it: neither's work is lost.
step "$PHONE" testSyncOffline
step "$MAC" testSyncTakeOver
expect_file "$MAC" mac.txt "written on the Mac"
step "$PHONE" testSyncSplit
expect_file "$PHONE" offline.txt "written offline"
expect_file "$PHONE" mac.txt "written on the Mac"
# The iPhone deletes the Mac's session with sync off; it's deleted in the folder once it syncs, then on the Mac.
step "$PHONE" testSyncDelete
python3 - "$CLOUD" <<'EOF'
import json, os, sys
root = sys.argv[1]
records = [json.load(open(os.path.join(root, "records", name)))["record"] for name in os.listdir(os.path.join(root, "records")) if name.endswith(".json")]
deleted = [record for record in records if record["deleted"]]
if len(deleted) != 1: sys.exit(f"error: {len(deleted)} deleted records")
record = deleted[0]
if record["title"] or record["holderName"] or record["holder"] or record["chunks"] or "manifest" in record or "docs" in record:
    sys.exit(f"error: the deleted session's record still has {record}")
chunks = os.path.join(root, "chunks", record["syncId"])
if os.path.isdir(chunks) and os.listdir(chunks): sys.exit(f"error: the deleted session's chunks are still there: {os.listdir(chunks)}")
print("the deleted session's record: emptied, its chunks gone")
EOF
step "$MAC" testSyncDeleted
blob() { printf '%s\n' "$1" | shasum -a 256 | cut -d' ' -f1; }
[[ ! -e "$CLOUD/blobs/$(blob "written on the Mac")" ]] || { echo "error: the deleted session's file is still in the folder" >&2; exit 1; }
[[ -e "$CLOUD/blobs/$(blob "written offline")" ]] || { echo "error: the iPhone's session's file is gone from the folder" >&2; exit 1; }
[[ -z "$(workspace_file "$MAC" mac.txt)" && -z "$(workspace_file "$PHONE" mac.txt)" ]] || { echo "error: the deleted session's workspace is still on a device" >&2; exit 1; }
echo "the deleted session's file: swept from the folder and gone from both devices; the other session's file stays"
echo "Session sync works between the two simulators."
