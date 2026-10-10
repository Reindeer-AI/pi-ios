#!/bin/sh
# Xcode build phase: embeds a-Shell's command frameworks (without linking them), the command dictionary, and the
# placeholder files dash needs to find commands.
# ios_system dlopens a command's framework from the app's Frameworks folder when the command runs.
set -eu

VENDOR="${PROJECT_DIR}/../Vendor/ashell"
FRAMEWORKS="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [ ! -f "$VENDOR/commandDictionary.plist" ]; then
  echo "error: a-Shell components missing at $VENDOR (run: Vendor/fetch-ashell.sh)"
  exit 1
fi

mkdir -p "$FRAMEWORKS"
for name in files text shell awk curl_ios tar dash lg2 openssl libssh2; do
  # The slice for this platform whose binary contains every architecture being built.
  slice=""
  for candidate in "$VENDOR/$name.xcframework"/*/; do
    case "$(basename "$candidate")" in
      *maccatalyst*|macos*|tvos*|watchos*) continue ;;
      *simulator) [ "$PLATFORM_NAME" = "iphonesimulator" ] || continue ;;
      ios-*) [ "$PLATFORM_NAME" = "iphoneos" ] || continue ;;
      *) continue ;;
    esac
    archs="$(lipo -archs "$candidate$name.framework/$name")"
    missing=""
    for arch in $ARCHS; do
      case " $archs " in *" $arch "*) ;; *) missing=1 ;; esac
    done
    [ -z "$missing" ] && slice="$candidate"
  done
  if [ -z "$slice" ]; then
    echo "error: no $PLATFORM_NAME slice with $ARCHS in $name.xcframework"
    exit 1
  fi
  rm -rf "$FRAMEWORKS/$name.framework"
  cp -R "$slice$name.framework" "$FRAMEWORKS/"
  # App Store validation wants each framework's platform in its Info.plist (a-Shell's openssl leaves it out) and only
  # the architectures the app is built for (libssh2 also carries arm64e).
  plist="$FRAMEWORKS/$name.framework/Info.plist"
  if [ "$PLATFORM_NAME" = "iphoneos" ] && ! /usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "$plist"
  fi
  binary="$FRAMEWORKS/$name.framework/$name"
  for arch in $(lipo -archs "$binary"); do
    case " $ARCHS " in *" $arch "*) ;; *) lipo -remove "$arch" "$binary" -output "$binary" ;; esac
  done
  # libssh2 also carries bitcode, and an unfilled MinimumOSVersion ("ios_version_min"): both refused by App Store
  # validation. The bitcode goes, and the version becomes the binary's own (its build version's minos).
  if otool -l "$binary" | grep -q __LLVM; then
    xcrun bitcode_strip -r "$binary" -o "$binary"
  fi
  case "$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$plist" 2>/dev/null)" in
    [0-9]*) ;;
    *)
      minos="$(otool -l "$binary" | awk '/LC_BUILD_VERSION/ {found=1} found && $1 == "minos" {print $2; exit}')"
      /usr/libexec/PlistBuddy -c "Delete :MinimumOSVersion" "$plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string ${minos:-14.0}" "$plist"
      ;;
  esac
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$FRAMEWORKS/$name.framework"
done

# Python (fetch-python.sh): embed Python.framework unlinked, like the commands above, then let CPython's own helper
# install the standard library and wrap each binary extension module as a signed framework (as iOS requires).
PYTHON_XCFRAMEWORK="../Vendor/python/Python.xcframework"
if [ ! -d "$PROJECT_DIR/$PYTHON_XCFRAMEWORK" ]; then
  echo "error: CPython missing (run: Vendor/fetch-python.sh)"
  exit 1
fi
case "$PLATFORM_NAME" in
  iphonesimulator) python_slice="ios-arm64_x86_64-simulator" ;;
  *) python_slice="ios-arm64" ;;
esac
rm -rf "$FRAMEWORKS/Python.framework"
cp -R "$PROJECT_DIR/$PYTHON_XCFRAMEWORK/$python_slice/Python.framework" "$FRAMEWORKS/"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$FRAMEWORKS/Python.framework"
EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
# Unsigned builds (CODE_SIGNING_ALLOWED=NO, as in CI) set neither; the frameworks are then signed ad hoc.
EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-ad hoc}"
. "$PROJECT_DIR/$PYTHON_XCFRAMEWORK/build/utils.sh"
install_python "$PYTHON_XCFRAMEWORK" > /dev/null
# Two things in the helper's module frameworks would make App Store Connect take one of them for the app: they say they
# are apps (CFBundlePackageType APPL), and a module's leading underscore becomes a leading hyphen in its identifier
# ("<app>.-asyncio"). They become frameworks (FMWK) named <app>.py-<module>, signed again.
for framework in "$FRAMEWORKS"/*.framework; do
  plist="$framework/Info.plist"
  id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)" || continue
  type="$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$plist" 2>/dev/null || true)"
  changed=""
  case "$id" in
    "$PRODUCT_BUNDLE_IDENTIFIER".-*)
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PRODUCT_BUNDLE_IDENTIFIER.py${id#"$PRODUCT_BUNDLE_IDENTIFIER".}" "$plist"
      changed=1
      ;;
  esac
  if [ "$type" = "APPL" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundlePackageType FMWK" "$plist"
    changed=1
  fi
  if [ -n "$changed" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} -o runtime --timestamp=none --generate-entitlement-der "$framework"
  fi
done
cp "$PROJECT_DIR/../Vendor/python-support/sitecustomize.py" "$CODESIGNING_FOLDER_PATH/python/lib/python3.14/"

cp "$VENDOR/commandDictionary.plist" "$RESOURCES/commandDictionary.plist"
cp "$VENDOR/cacert.pem" "$RESOURCES/cacert.pem"

# dash finds commands by searching $PATH for files. As in a-Shell, every ios_system command gets an empty placeholder
# in $APPDIR/bin (on ios_system's $PATH); dash then hands the command to ios_system, which runs it by name.
rm -rf "$RESOURCES/bin"
mkdir -p "$RESOURCES/bin"
/usr/libexec/PlistBuddy -c Print "$VENDOR/commandDictionary.plist" | awk '/^    [^ ]+ = Array/ {print $1}' |
  while read -r command; do
    : > "$RESOURCES/bin/$command"
    chmod 755 "$RESOURCES/bin/$command"
  done

# Commands the toolbox lacks (pip, which, cut, seq, ...): pitools.py under each name, run by ios_system through its
# #! line; the name picks the command.
PITOOLS="$PROJECT_DIR/../Vendor/python-support/pitools.py"
for command in $(/usr/bin/python3 -c "import runpy, sys; print(' '.join(runpy.run_path(sys.argv[1])['COMMANDS']))" "$PITOOLS"); do
  { echo '#!/usr/bin/env python3'; cat "$PITOOLS"; } > "$RESOURCES/bin/$command"
  chmod 755 "$RESOURCES/bin/$command"
done
