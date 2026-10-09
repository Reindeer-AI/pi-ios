#!/bin/sh
# Fetches the official CPython iOS build (BeeWare Python-Apple-support, PSF license) into Vendor/python, pinned by
# SHA-256. The app's "Embed a-Shell commands" build phase installs it as the shell's `python3` command.
set -eu

cd "$(dirname "$0")"
RELEASE="3.14-b11"
URL="https://github.com/beeware/Python-Apple-support/releases/download/$RELEASE/Python-3.14-iOS-support.b11.tar.gz"
SHA256="b591f3301bd22a4f423c49c746cac9e55558b909fd14d6eb8327ccc62234ab7b"
ARCHIVE="python/download/Python-iOS-support.tar.gz"

mkdir -p python/download
if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$SHA256" ]; then
  curl -fsSL "$URL" -o "$ARCHIVE.part"
  actual="$(shasum -a 256 "$ARCHIVE.part" | cut -d' ' -f1)"
  if [ "$actual" != "$SHA256" ]; then
    echo "error: checksum mismatch for $URL (expected $SHA256, got $actual)" >&2
    rm -f "$ARCHIVE.part"
    exit 1
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
rm -rf python/Python.xcframework
tar xzf "$ARCHIVE" -C python Python.xcframework
echo "CPython ($RELEASE) ready in Vendor/python"
