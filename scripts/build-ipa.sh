#!/bin/bash
# Builds a signed .ipa of the iOS app.
#
#   PI_TEAM=<team id> scripts/build-ipa.sh                   → dist/PiMobile-<version>.ipa, ad hoc
#   PI_TEAM=<team id> scripts/build-ipa.sh --development     → signed with the team's development certificate and profile
#   PI_TEAM=<team id> scripts/build-ipa.sh --profile FILE    → signed with a profile downloaded from developer.apple.com
#                                                               (development, ad hoc, App Store, or enterprise, told apart
#                                                               by its contents)
#   PI_TEAM=<team id> scripts/build-ipa.sh --safari-identity → the browser identifies as Safari (some sites, Google's
#                                                               sign-in among them, refuse other browsers)
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
while [[ $# -gt 0 ]]; do
	case "$1" in
		--development) METHOD=debugging ;;
		--profile) PROFILE="${2:?--profile needs a .mobileprovision file}"; shift ;;
		--safari-identity) CONDITIONS='$(inherited) SAFARI_IDENTITY' ;;
		*) echo "usage: $0 [--development | --profile FILE] [--safari-identity]" >&2; exit 2 ;;
	esac
	shift
done

# A downloaded profile is installed where Xcode looks for profiles and used for manual signing. Without one, Xcode makes
# or updates profiles through its signed-in Apple account (-allowProvisioningUpdates); CI has no account and needs none.
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
xcodebuild archive \
	-project "$ROOT/App/PiMobile.xcodeproj" -scheme PiMobile -configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$BUILD/PiMobile.xcarchive" -derivedDataPath "$BUILD/DerivedData" \
	${UPDATES[@]+"${UPDATES[@]}"} \
	DEVELOPMENT_TEAM="$TEAM" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	PI_BUNDLE_ID="$BUNDLE_ID" \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" ${SIGNING[@]+"${SIGNING[@]}"}

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
