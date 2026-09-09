#!/usr/bin/env bash
# Builds Windflow.saver (universal) and the windowed preview harness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
SAVER="$BUILD/Windflow.saver"
DEPLOY_TARGET="13.0"

SOURCES=("$ROOT"/Sources/Windflow/*.swift)

COMMON=(-O -swift-version 5 -module-name Windflow
        -framework ScreenSaver -framework AppKit)

mkdir -p "$BUILD"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

echo "==> compiling bundle"
SLICES=()
for arch in arm64 x86_64; do
    slice="$BUILD/Windflow-$arch"
    swiftc "${COMMON[@]}" \
        -target "${arch}-apple-macos${DEPLOY_TARGET}" \
        -emit-library -Xlinker -bundle \
        -o "$slice" "${SOURCES[@]}"
    SLICES+=("$slice")
done

lipo -create "${SLICES[@]}" -output "$SAVER/Contents/MacOS/Windflow"
cp "$ROOT/Resources/Info.plist" "$SAVER/Contents/Info.plist"

# Ad-hoc signature. Without one, macOS refuses to load the bundle at all.
codesign --force --deep --sign - "$SAVER"
echo "==> $SAVER"

echo "==> compiling preview harness"
swiftc "${COMMON[@]}" \
    -target "$(uname -m)-apple-macos${DEPLOY_TARGET}" \
    -o "$BUILD/windflow-preview" \
    "${SOURCES[@]}" "$ROOT/Sources/PreviewApp/main.swift"
codesign --force --sign - "$BUILD/windflow-preview"
echo "==> $BUILD/windflow-preview"

echo "==> compiling frame dumper"
swiftc "${COMMON[@]}" \
    -target "$(uname -m)-apple-macos${DEPLOY_TARGET}" \
    -o "$BUILD/windflow-dump" \
    "${SOURCES[@]}" "$ROOT/Sources/Dump/main.swift"
echo "==> $BUILD/windflow-dump"
