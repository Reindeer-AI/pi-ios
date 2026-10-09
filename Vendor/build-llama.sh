#!/bin/sh
# Builds llama.cpp's llama-server (pinned build tag) as a static library for iOS devices and simulators (arm64, Metal)
# into llama/LlamaServer.xcframework. The app runs the server in-process on 127.0.0.1, so pi reaches on-device models
# through the same OpenAI-compatible API (streaming, Jinja chat templates, tool calls) as any other provider.
#
# Uses CMake and Ninja from a local virtualenv (build/tools), created on first run.
set -eu

cd "$(dirname "$0")"
VENDOR="$PWD"
TAG="b11391"
SRC="$VENDOR/build/llama.cpp"
TOOLS="$VENDOR/build/tools/bin"
OUT="$VENDOR/build/llama-out"

if [ ! -x "$TOOLS/cmake" ]; then
  python3 -m venv "$VENDOR/build/tools"
  "$TOOLS/pip" install -q --disable-pip-version-check cmake ninja
fi
if [ "$(git -C "$SRC" describe --tags 2>/dev/null || true)" != "$TAG" ]; then
  rm -rf "$SRC"
  git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
# Our patches (patches/llama-*.patch) on a clean checkout. llama-server-relisten: the HTTP listener listens again after
# iOS takes back a suspended app's socket, so a model kept loaded stays reachable.
git -C "$SRC" checkout -q -- .
for patch in "$VENDOR"/patches/llama-*.patch; do git -C "$SRC" apply "$patch"; done

rm -rf "$OUT"
mkdir -p "$OUT/include"

# Swift-callable entry points (the server's own are C++ functions).
cat > "$OUT/include/llama_server.h" <<'EOF'
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
/// Runs llama-server with command-line style arguments; returns when the server stops.
int pi_llama_server_main(int argc, char **argv);
/// Asks a running server to shut down.
void pi_llama_server_terminate(void);
#ifdef __cplusplus
}
#endif
EOF
cat > "$OUT/include/module.modulemap" <<'EOF'
module LlamaServer {
    header "llama_server.h"
    export *
}
EOF
cat > "$OUT/shim.cpp" <<'EOF'
#include "llama_server.h"
int llama_server(int argc, char **argv);
void llama_server_terminate();
extern "C" int pi_llama_server_main(int argc, char **argv) { return llama_server(argc, argv); }
extern "C" void pi_llama_server_terminate(void) { llama_server_terminate(); }
EOF

build() { # sdk platform-name
  dir="$OUT/$2"
  "$TOOLS/cmake" -S "$SRC" -B "$dir/cmake" -G Ninja -DCMAKE_MAKE_PROGRAM="$TOOLS/ninja" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$1" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_MACOSX_BUNDLE=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_COMMON=ON \
    -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_SUBPROCESS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    > "$dir.configure.log"
  "$TOOLS/cmake" --build "$dir/cmake" --target llama-server-impl -j 8 > "$dir.build.log"
  sdkpath="$(xcrun --sdk "$1" --show-sdk-path)"
  target="arm64-apple-ios17.0"
  [ "$1" = iphonesimulator ] && target="arm64-apple-ios17.0-simulator"
  xcrun clang++ -std=c++17 -O2 -target "$target" -isysroot "$sdkpath" -I "$OUT/include" \
    -c "$OUT/shim.cpp" -o "$dir/shim.o"
  # One static library: the server, llama-common, mtmd, llama, ggml (with Metal), and the shim.
  find "$dir/cmake" -name '*.a' > "$dir/libs.txt"
  xcrun libtool -static -o "$dir/libllama-server.a" "$dir/shim.o" $(cat "$dir/libs.txt") 2> "$dir.libtool.log"
}

build iphoneos iphoneos
build iphonesimulator iphonesimulator

rm -rf "$VENDOR/llama/LlamaServer.xcframework"
mkdir -p "$VENDOR/llama"
xcodebuild -create-xcframework \
  -library "$OUT/iphoneos/libllama-server.a" -headers "$OUT/include" \
  -library "$OUT/iphonesimulator/libllama-server.a" -headers "$OUT/include" \
  -output "$VENDOR/llama/LlamaServer.xcframework" > /dev/null
echo "llama-server built into Vendor/llama/LlamaServer.xcframework"
