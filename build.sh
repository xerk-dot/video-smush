#!/bin/zsh
# Builds Video Smush.app into ./build
set -e
cd "$(dirname "$0")"

APP_NAME="Video Smush"
BIN="VideoSmush"
OUT="build"
BUNDLE="$OUT/$APP_NAME.app"

echo "==> Compiling"
mkdir -p "$OUT"
swiftc -O -parse-as-library \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  Sources/*.swift -o "$OUT/$BIN"

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$OUT/$BIN" "$BUNDLE/Contents/MacOS/$BIN"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"

echo "==> Signing (ad-hoc)"
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign -s - --force --deep "$BUNDLE" >/dev/null 2>&1 || true

echo "==> Done: $BUNDLE"
echo "    Install with:  cp -R \"$BUNDLE\" /Applications/"
