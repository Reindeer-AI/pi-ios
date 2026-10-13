#!/bin/bash
# Builds a signed .ipa of the iOS app.
#
#   PI_TEAM=<team id> scripts/build-ipa.sh                   → dist/PiMobile-<version>.ipa, ad hoc
#   PI_TEAM=<team id> scripts/build-ipa.sh --development     → signed with the team's development certificate and profile
#   PI_TEAM=<team id> scripts/build-ipa.sh --profile FILE --watch-profile FILE --widgets-profile FILE
#                                                             → signed with profiles downloaded from developer.apple.com
#                                                               (development, ad hoc, App Store, or enterprise, told apart
#                                                               by their contents): the app's, the Watch app's, and the
#                                                               widgets' (the app's and the widgets' with pi's App Group)
#   PI_TEAM=<team id> scripts/build-ipa.sh --safari-identity → the browser identifies as Safari (some sites, Google's
#                                                               sign-in among them, refuse other browsers)
#   PI_TEAM=<team id> scripts/build-ipa.sh --no-watch        → without the Watch app (no --watch-profile)
#   PI_TEAM=<team id> scripts/build-ipa.sh --no-widgets      → without the Home Screen widgets, and the App Group they
#                                                               share with the app (no --widgets-profile; the app's
#                                                               profile needs no App Group)
#
# PI_TEAM is the Apple developer team that signs it; PI_VERSION its version (default 0.1.<commit count>; an MDM needs
# it higher on every upload), PI_BUILD its build number (default PI_VERSION; App Store Connect needs it higher on every
# upload of a version), and PI_BUNDLE_ID its bundle identifier (default dev.pimobile.PiMobile). Ad hoc and development builds install only on iPhones registered to the
# team (developer.apple.com → Certificates, IDs & Profiles → Devices) and in its profile. Without a profile, Xcode makes
# or updates profiles through the Apple account signed in to it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${PI_TEAM:?set PI_TEAM to the Apple developer team that signs the app}"
VERSION="${PI_VERSION:-0.1.$(git -C "$ROOT" rev-list --count HEAD)}"
BUILD_NUMBER="${PI_BUILD:-$VERSION}"
# The app target reads it from PI_BUNDLE_ID, as the profile below: given to every target, it would rename the package
# targets' resource bundles too.
BUNDLE_ID="${PI_BUNDLE_ID:-dev.pimobile.PiMobile}"
CONDITIONS='$(inherited)'
METHOD=release-testing
PROFILE=""
WATCH_PROFILE=""
WATCH=1
WIDGETS_PROFILE=""
WIDGETS=1
while [[ $# -gt 0 ]]; do
	case "$1" in
		--development) METHOD=debugging ;;
		--watch-profile) WATCH_PROFILE="${2:?--watch-profile needs a .mobileprovision file}"; shift ;;
		--widgets-profile) WIDGETS_PROFILE="${2:?--widgets-profile needs a .mobileprovision file}"; shift ;;
		--profile) PROFILE="${2:?--profile needs a .mobileprovision file}"; shift ;;
		--safari-identity) CONDITIONS='$(inherited) SAFARI_IDENTITY' ;;
		--no-watch) WATCH="" ;;
		--no-widgets) WIDGETS="" ;;
		*) echo "usage: $0 [--development | --profile FILE (--watch-profile FILE | --no-watch) (--widgets-profile FILE | --no-widgets)] [--safari-identity]" >&2; exit 2 ;;
	esac
	shift
done

# A downloaded profile is installed where Xcode looks for profiles and used for manual signing. Without one, Xcode makes
# or updates profiles through its signed-in Apple account (-allowProvisioningUpdates); CI has no account and needs none.
if [[ -n "$WATCH" ]] && [[ -n "$PROFILE" && -z "$WATCH_PROFILE" || -z "$PROFILE" && -n "$WATCH_PROFILE" ]]; then
	echo "error: manual signing requires both --profile and --watch-profile (the embedded Watch app has its own bundle ID), or --no-watch" >&2
	exit 2
fi
if [[ -n "$WIDGETS" ]] && [[ -n "$PROFILE" && -z "$WIDGETS_PROFILE" || -z "$PROFILE" && -n "$WIDGETS_PROFILE" ]]; then
	echo "error: manual signing requires both --profile and --widgets-profile (the widgets have their own bundle ID), or --no-widgets" >&2
	exit 2
fi
# The App Group the app shares with its widgets (PI_APP_GROUP in the project).
APP_GROUP="group.$BUNDLE_ID"
# A profile must grant the App Group for the widgets: its App ID has App Groups on, with this group, before it's made.
grants_group() {
	plutil -extract "Entitlements.com\.apple\.security\.application-groups" json -o - - <<<"$1" 2>/dev/null | grep -q "\"$APP_GROUP\""
}
SIGNING=()
UPDATES=(-allowProvisioningUpdates)
if [[ -n "$PROFILE" ]]; then
	DECODED="$(security cms -D -i "$PROFILE")"
	PROFILE_NAME="$(plutil -extract Name raw -o - - <<<"$DECODED")"
	PROFILE_UUID="$(plutil -extract UUID raw -o - - <<<"$DECODED")"
	if plutil -extract ProvisionsAllDevices raw -o - - <<<"$DECODED" >/dev/null 2>&1; then
		METHOD=enterprise
	elif [[ "$(plutil -extract Entitlements.get-task-allow raw -o - - <<<"$DECODED")" == true ]]; then
		METHOD=debugging
	elif plutil -extract ProvisionedDevices raw -o - - <<<"$DECODED" >/dev/null 2>&1; then
		METHOD=release-testing
	else
		METHOD=app-store-connect
	fi
	IDENTITY="Apple Distribution"
	if [[ "$METHOD" == debugging ]]; then IDENTITY="Apple Development"; fi
	PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
	mkdir -p "$PROFILES_DIR"
	cp "$PROFILE" "$PROFILES_DIR/$PROFILE_UUID.mobileprovision"
	# The app target reads the profile from PI_PROVISIONING_PROFILE: a profile given to every target fails on package
	# targets (swift-nio's and swift-crypto's resource bundles).
	SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" PI_PROVISIONING_PROFILE="$PROFILE_NAME")
	if [[ -n "$WATCH" ]]; then
		WATCH_DECODED="$(security cms -D -i "$WATCH_PROFILE")"
		WATCH_PROFILE_NAME="$(plutil -extract Name raw -o - - <<<"$WATCH_DECODED")"
		WATCH_PROFILE_UUID="$(plutil -extract UUID raw -o - - <<<"$WATCH_DECODED")"
		cp "$WATCH_PROFILE" "$PROFILES_DIR/$WATCH_PROFILE_UUID.mobileprovision"
		SIGNING+=(PI_WATCH_PROVISIONING_PROFILE="$WATCH_PROFILE_NAME")
	fi
	if [[ -n "$WIDGETS" ]]; then
		WIDGETS_DECODED="$(security cms -D -i "$WIDGETS_PROFILE")"
		WIDGETS_PROFILE_NAME="$(plutil -extract Name raw -o - - <<<"$WIDGETS_DECODED")"
		WIDGETS_PROFILE_UUID="$(plutil -extract UUID raw -o - - <<<"$WIDGETS_DECODED")"
		for each in "$PROFILE_NAME:$DECODED" "$WIDGETS_PROFILE_NAME:$WIDGETS_DECODED"; do
			if ! grants_group "${each#*:}"; then
				echo "error: the profile \"${each%%:*}\" doesn't grant the App Group $APP_GROUP (turn on App Groups with it for its App ID, then make the profile again), or build --no-widgets" >&2
				exit 1
			fi
		done
		cp "$WIDGETS_PROFILE" "$PROFILES_DIR/$WIDGETS_PROFILE_UUID.mobileprovision"
		SIGNING+=(PI_WIDGETS_PROVISIONING_PROFILE="$WIDGETS_PROFILE_NAME")
	fi
	UPDATES=()
	echo "Signing with \"$PROFILE_NAME\" ($METHOD, $IDENTITY)"
fi
BUILD="$ROOT/App/build/ipa"
DIST="$ROOT/dist"

for dir in Vendor/ashell Vendor/build Vendor/llama Vendor/python; do
	if [[ ! -d "$ROOT/$dir" ]]; then
		echo "error: $dir is missing; run the Vendor scripts first (README.md, Building)" >&2
		exit 1
	fi
done

(cd "$ROOT/engine" && npm run build)

rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

# Without the Watch app or the widgets: archived from a copy of the project whose app target neither depends on them
# nor embeds them (Xcode can't leave a dependency out by a setting, and checks anything it embeds is signed like the
# app); without the widgets, the app is signed without their App Group too.
PROJECT="$ROOT/App/PiMobile.xcodeproj"
if [[ -z "$WATCH" || -z "$WIDGETS" ]]; then
	PROJECT="$ROOT/App/PiMobile-trimmed.xcodeproj"
	rm -rf "$PROJECT"
	cp -R "$ROOT/App/PiMobile.xcodeproj" "$PROJECT"
	trap 'rm -rf "$ROOT/App/PiMobile-trimmed.xcodeproj"' EXIT
	if [[ -z "$WIDGETS" ]]; then
		cp "$ROOT/App/PiMobile.entitlements" "$ROOT/App/build/PiMobile-no-widgets.entitlements"
		plutil -remove "com\.apple\.security\.application-groups" "$ROOT/App/build/PiMobile-no-widgets.entitlements"
	fi
	python3 - "$PROJECT/project.pbxproj" "$WATCH" "$WIDGETS" <<'UNHOOK'
import re
import sys

path, watch, widgets = sys.argv[1:4]
text = open(path).read()

def unhook(name, embed, flag):
    """Takes a target's dependency and embed phase out of the app target, found by name."""
    global text
    target = re.search(r"^\t+(\w+) /\* " + name + r" \*/ = \{\s*isa = PBXNativeTarget;", text, re.M)
    phase = re.search(r"^\t+(\w+) /\* " + embed + r" \*/ = \{isa = PBXCopyFilesBuildPhase;", text, re.M)
    dependency = target and re.search(r"^\t+(\w+) = \{isa = PBXTargetDependency; target = " + target.group(1) + ";", text, re.M)
    if not (target and phase and dependency):
        sys.exit(f"error: {flag} can't find {name}'s target, its dependency, or its embed phase in the project")
    before = len(text)
    text = re.sub(r"^\t+" + phase.group(1) + r" /\* " + embed + r" \*/,\n", "", text, flags=re.M)
    text = re.sub(r"^\t+" + dependency.group(1) + r",\n", "", text, flags=re.M)
    if len(text) == before:
        sys.exit(f"error: {flag} removed nothing from the app target")

if not watch:
    unhook("PiWatch", "Embed Watch Content", "--no-watch")
if not widgets:
    unhook("PiWidgets", "Embed Widgets", "--no-widgets")
    entitlements = "CODE_SIGN_ENTITLEMENTS = PiMobile.entitlements;"
    if text.count(entitlements) != 2:
        sys.exit("error: --no-widgets can't find the app's entitlements in the project")
    text = text.replace(entitlements, 'CODE_SIGN_ENTITLEMENTS = "build/PiMobile-no-widgets.entitlements";')
open(path, "w").write(text)
UNHOOK
fi
xcodebuild archive \
	-project "$PROJECT" -scheme PiMobile -configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$BUILD/PiMobile.xcarchive" -derivedDataPath "$BUILD/DerivedData" \
	${UPDATES[@]+"${UPDATES[@]}"} \
	DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	PI_BUNDLE_ID="$BUNDLE_ID" \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" ${SIGNING[@]+"${SIGNING[@]}"}
ARCHIVED="$BUILD/PiMobile.xcarchive/Products/Applications/PiMobile.app"
if [[ -z "$WATCH" && -d "$ARCHIVED/Watch" ]]; then
	echo "error: --no-watch, yet the archived app has a Watch app" >&2
	exit 1
fi
if [[ -z "$WIDGETS" && -d "$ARCHIVED/PlugIns/PiWidgets.appex" ]]; then
	echo "error: --no-widgets, yet the archived app has widgets" >&2
	exit 1
fi
if [[ -n "$WIDGETS" && ! -d "$ARCHIVED/PlugIns/PiWidgets.appex" ]]; then
	echo "error: the archived app has no widgets (PlugIns/PiWidgets.appex)" >&2
	exit 1
fi

cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$METHOD</string>
	<key>teamID</key>
	<string>$TEAM</string>
$(if [[ -n "$PROFILE" ]]; then cat <<SIGNING
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$IDENTITY</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$BUNDLE_ID</key>
		<string>$PROFILE_NAME</string>
$(if [[ -n "$WATCH" ]]; then cat <<WATCH_ENTRY
		<key>$BUNDLE_ID.watchkitapp</key>
		<string>$WATCH_PROFILE_NAME</string>
WATCH_ENTRY
fi)
$(if [[ -n "$WIDGETS" ]]; then cat <<WIDGETS_ENTRY
		<key>$BUNDLE_ID.widgets</key>
		<string>$WIDGETS_PROFILE_NAME</string>
WIDGETS_ENTRY
fi)
	</dict>
SIGNING
else cat <<SIGNING
	<key>signingStyle</key>
	<string>automatic</string>
SIGNING
fi)
$(if [[ "$METHOD" == app-store-connect ]]; then cat <<STORE
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
STORE
else cat <<THINNING
	<key>thinning</key>
	<string>&lt;none&gt;</string>
THINNING
fi)
</dict>
</plist>
EOF
xcodebuild -exportArchive \
	-archivePath "$BUILD/PiMobile.xcarchive" -exportPath "$BUILD/export" \
	-exportOptionsPlist "$BUILD/ExportOptions.plist" ${UPDATES[@]+"${UPDATES[@]}"}

# Keys the app cannot do without (a lost key fails at runtime, not at build time): the GitHub sign-in's client ID, and
# the microphone and speech descriptions (iOS ends an app that asks for those permissions without them).
for key in PIGitHubClientID NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSFaceIDUsageDescription NSAppTransportSecurity BGTaskSchedulerPermittedIdentifiers; do
	if ! plutil -extract "$key" raw -o /dev/null "$BUILD/PiMobile.xcarchive/Products/Applications/PiMobile.app/Info.plist" 2>/dev/null \
		&& ! plutil -extract "$key" xml1 -o /dev/null "$BUILD/PiMobile.xcarchive/Products/Applications/PiMobile.app/Info.plist" 2>/dev/null; then
		echo "error: the app's Info.plist has no $key (App/Info.plist)" >&2
		exit 1
	fi
done
cp "$BUILD/export/PiMobile.ipa" "$DIST/PiMobile-$VERSION.ipa"
echo "$DIST/PiMobile-$VERSION.ipa"
