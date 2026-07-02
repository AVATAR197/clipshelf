#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/ClipShelf.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/ClipShelf" "$MACOS_DIR/ClipShelf"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/ClipShelf"

# Prefer a stable signing identity: ad-hoc signatures ("-") change on every
# build, which makes macOS drop the Accessibility grant after each rebuild.
# Create one via Keychain Access > Certificate Assistant > Create a
# Certificate (name: "ClipShelf Dev", type: Code Signing), or pass
# CODESIGN_IDENTITY=<name> to this script.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "ClipShelf Dev"; then
    IDENTITY="ClipShelf Dev"
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR" >/dev/null
else
    echo "warning: no code signing identity found; using ad-hoc signing." >&2
    echo "warning: macOS will require re-granting Accessibility after every rebuild." >&2
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
