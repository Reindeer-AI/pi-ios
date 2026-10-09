#!/bin/sh
# Builds dash for iOS from a-Shell's dash_iOS (pinned commit) with our patches (patches/dash_iOS.patch) into
# ashell/dash.xcframework, for arm64 devices and arm64 simulators. Run fetch-ashell.sh first (for ios_system).
#
# The patches make dash safe to host in-process: interrupting unwinds instead of raising SIGINT in the app, `>&2`
# reaches the command's stderr instead of the app's, and /etc/profile is not sourced. They also make redirections and
# pipelines work for every command, not only the first: dash tracks what 0-2 are redirected to and gives each command
# its own copies (ios_system hands a command its streams once), and a pipeline starts its external commands before
# running builtins, functions, and loops in order (so `cmd | while read x` does not wait forever).
set -eu

cd "$(dirname "$0")"
VENDOR="$PWD"
COMMIT="3da49bb7ac15458ea4f554b589dde5197816f6ba"
SRC="$VENDOR/build/dash_iOS"
IOS_SYSTEM="$VENDOR/ashell/ios_system.xcframework"
OUT="$VENDOR/build/dash-frameworks"

if [ ! -d "$IOS_SYSTEM" ]; then
  echo "error: $IOS_SYSTEM missing (run: Vendor/fetch-ashell.sh)" >&2
  exit 1
fi

rm -rf "$SRC" "$OUT"
git clone -q https://github.com/holzschu/dash_iOS.git "$SRC"
git -C "$SRC" checkout -q "$COMMIT"
git -C "$SRC" apply "$VENDOR/patches/dash_iOS.patch"
# The repository's automake helper scripts are missing or symlinks into its author's automake install. Nothing here
# runs `make install` or regenerates the build files, and clang compiles with -c -o itself, so stubs suffice.
rm -f "$SRC/install-sh" "$SRC/compile" "$SRC/missing"
printf '#!/bin/sh\nexec install "$@"\n' > "$SRC/install-sh"
printf '#!/bin/sh\nexec "$@"\n' > "$SRC/compile"
printf '#!/bin/sh\necho "missing: not regenerating with $1" >&2\nexit 0\n' > "$SRC/missing"
chmod +x "$SRC/install-sh" "$SRC/compile" "$SRC/missing"
# Keep the checked-in generated files newer than their sources, so make never tries to regenerate them.
(cd "$SRC" && touch aclocal.m4 && touch configure Makefile.in src/Makefile.in config.h.in)

OSX_SDK="$(xcrun --sdk macosx --show-sdk-path)"

build() { # sdk version-min-flag ios_system-slice platform-name info-plist
  sdk="$(xcrun --sdk "$1" --show-sdk-path)"
  flags="-arch arm64 $2=14.0 -isysroot $sdk -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$SRC"
  (
    cd "$SRC"
    make distclean > /dev/null 2>&1 || true
    ./configure CC=clang CC_FOR_BUILD="clang -isysroot $OSX_SDK -DJOBS=0" \
      CFLAGS="$flags" CPPFLAGS="$flags" \
      LDFLAGS="-arch arm64 $2=14.0 -isysroot $sdk -dynamiclib -F $IOS_SYSTEM/$3 -framework ios_system" \
      --build=aarch64-apple-darwin --host=aarch64-apple-ios cross_compiling=yes --with-libedit --disable-dependency-tracking > /dev/null
    make -j8 --quiet > /dev/null
  )
  framework="$OUT/$4/dash.framework"
  mkdir -p "$framework"
  cp "$SRC/src/dash" "$framework/dash"
  cp "$SRC/$5" "$framework/Info.plist"
  plutil -replace CFBundleExecutable -string dash "$framework/Info.plist"
  plutil -replace CFBundleName -string dash "$framework/Info.plist"
  plutil -replace CFBundleIdentifier -string dev.pimobile.dash "$framework/Info.plist"
  install_name_tool -id @rpath/dash.framework/dash "$framework/dash"
}

build iphoneos -miphoneos-version-min ios-arm64 iphoneos basic_Info.plist
build iphonesimulator -mios-simulator-version-min ios-arm64_x86_64-simulator iphonesimulator basic_Info_Simulator.plist

rm -rf "$VENDOR/ashell/dash.xcframework"
xcodebuild -create-xcframework \
  -framework "$OUT/iphoneos/dash.framework" \
  -framework "$OUT/iphonesimulator/dash.framework" \
  -output "$VENDOR/ashell/dash.xcframework" > /dev/null
echo "dash built into Vendor/ashell/dash.xcframework"
