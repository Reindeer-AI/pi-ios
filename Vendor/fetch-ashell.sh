#!/bin/sh
# Fetches a-Shell's prebuilt command components (BSD-3, https://github.com/holzschu/a-shell) into Vendor/ashell:
# the ios_system command engine and its command frameworks, lg2 (git via libgit2), and the openssl/libssh2 frameworks
# curl and lg2 link against. dash is built from source with our patches by build-dash.sh.
#
# Every download is pinned by SHA-256: ios_system assets by the digests GitHub publishes for release v3.0.6 (the same
# files ios_system's Package.swift pins), the others by the checksums in a-Shell's xcfs/Package.swift.
set -eu

cd "$(dirname "$0")"
DEST="ashell"
mkdir -p "$DEST/download"

fetch() { # url sha256 output
  if [ -f "$3" ] && [ "$(shasum -a 256 "$3" | cut -d' ' -f1)" = "$2" ]; then return; fi
  curl -fsSL "$1" -o "$3.part"
  actual="$(shasum -a 256 "$3.part" | cut -d' ' -f1)"
  if [ "$actual" != "$2" ]; then
    echo "error: checksum mismatch for $1 (expected $2, got $actual)" >&2
    rm -f "$3.part"
    exit 1
  fi
  mv "$3.part" "$3"
}

IOS_SYSTEM="https://github.com/holzschu/ios_system/releases/download/v3.0.6"
while read -r name url sha; do
  fetch "$url" "$sha" "$DEST/download/$name.xcframework.zip"
  rm -rf "$DEST/$name.xcframework"
  unzip -q -o "$DEST/download/$name.xcframework.zip" -d "$DEST"
done <<EOF
ios_system $IOS_SYSTEM/ios_system.xcframework.zip c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6
files $IOS_SYSTEM/files.xcframework.zip 5db63958f686cc79f107bafd0d50feff32fb2b64d0dd976478c5dd405f7600b0
text $IOS_SYSTEM/text.xcframework.zip 9eef16c23ddaa03d5f28ce2183737b1dbdcfb06e6dc46035a404d9e0f3828604
shell $IOS_SYSTEM/shell.xcframework.zip 89da3b8bd7f83e42a2311aeac54c38acc7a2f9c2fc0d0d27f75897b393cdfec2
awk $IOS_SYSTEM/awk.xcframework.zip 675d3b2e3b5ba60ae1a727528b2cf5e11eda262d404c1e9708dc7e061898df86
curl_ios $IOS_SYSTEM/curl_ios.xcframework.zip f9a74e005115aad3b51dd8daa2fb4727eb8425018805d7dd2973e598af65f968
tar $IOS_SYSTEM/tar.xcframework.zip 74146ae19720d3d885d181bce4be2b6b92f11d306a47aa07486bf0dd35fc8f68
lg2 https://github.com/holzschu/libgit2/releases/download/ios_1.0/lg2.xcframework.zip 7d205a771be8d120a80d2f7281135dfffd21a3713c86eb4f1957638f6b4b365e
openssl https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip 329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80
libssh2 https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip cacfe1789b197b727119f7e32f561eaf9acc27bf38cd19975b74fce107f868a6
EOF

# lg2 ships an x86_64-only simulator slice, but Apple-silicon simulators run arm64. Derive an arm64 simulator slice
# from the device binary by retargeting its build version to the simulator platform (same instructions).
for name in lg2; do
  xcf="$DEST/$name.xcframework"
  minos="$(xcrun vtool -show-build "$xcf/ios-arm64/$name.framework/$name" | awk '/minos/ {print $2; exit}')"
  sdk="$(xcrun vtool -show-build "$xcf/ios-arm64/$name.framework/$name" | awk '/sdk/ {print $2; exit}')"
  rm -rf "$xcf/ios-arm64-simulator"
  mkdir -p "$xcf/ios-arm64-simulator"
  cp -R "$xcf/ios-arm64/$name.framework" "$xcf/ios-arm64-simulator/"
  xcrun vtool -arch arm64 -set-build-version iossim "$minos" "$sdk" -replace \
    -output "$xcf/ios-arm64-simulator/$name.framework/$name" "$xcf/ios-arm64/$name.framework/$name"
done

fetch "$IOS_SYSTEM/commandDictionary.plist" 7911fe0e7b1a9eb2c1ba761fe728fc3ede50093d29beb9735c0d8bb4201100b3 \
  "$DEST/download/commandDictionary.plist"

# CA certificates for curl and lg2 (a-Shell's bundle, pinned to a commit).
fetch "https://raw.githubusercontent.com/holzschu/a-shell/fb5c04f40140b30b9815545cc8ebf84c3e03a7e2/cacert.pem" \
  f524fc21859b776e18df01a87880efa198112214e13494275dbcbd9bcb71d976 "$DEST/cacert.pem"

# The app's command dictionary: ios_system's commands plus dash, lg2, and python, with a-Shell's definitions.
cp "$DEST/download/commandDictionary.plist" "$DEST/commandDictionary.plist"
plutil -insert dash -json '["dash.framework/dash", "main", "efIimnsxvVECabu", "no"]' "$DEST/commandDictionary.plist"
plutil -insert lg2 -json '["lg2.framework/lg2", "main", "", "directory"]' "$DEST/commandDictionary.plist"
# git: lg2 under the name agents use (libgit2's command set: clone, status, add, commit, log, diff, push, ...).
plutil -insert git -json '["lg2.framework/lg2", "main", "", "directory"]' "$DEST/commandDictionary.plist"
# Commands the shell and files frameworks contain that ios_system's dictionary leaves out.
plutil -insert basename -json '["shell.framework/shell", "basename_main", "", "no"]' "$DEST/commandDictionary.plist"
plutil -insert dirname -json '["shell.framework/shell", "dirname_main", "", "no"]' "$DEST/commandDictionary.plist"
plutil -insert realpath -json '["shell.framework/shell", "realpath_main", "q", "file"]' "$DEST/commandDictionary.plist"
plutil -insert sleep -json '["shell.framework/shell", "sleep_main", "", "no"]' "$DEST/commandDictionary.plist"
plutil -insert id -json '["shell.framework/shell", "id_main", "AFGMPagnpru", "no"]' "$DEST/commandDictionary.plist"
plutil -insert base64 -json '["files.framework/files", "base64_main", "b:Ddhi:o:", "file"]' "$DEST/commandDictionary.plist"
# python3/python: the official CPython build (fetch-python.sh), through the app's pimobile_python
# (App/PiMobile/PythonCommand.m, in the app binary: MAIN), which runs a program given on standard input, then
# Py_BytesMain.
plutil -insert python3 -json '["MAIN", "pimobile_python", "", "file"]' "$DEST/commandDictionary.plist"
plutil -insert python -json '["MAIN", "pimobile_python", "", "file"]' "$DEST/commandDictionary.plist"

echo "a-Shell components ready in Vendor/$DEST"
