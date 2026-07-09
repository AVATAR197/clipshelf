#!/bin/sh
# Regenerates Resources/AppIcon.icns from Scripts/generate-icon.swift.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MASTER="$TMP_DIR/master.png"
swift "$ROOT_DIR/Scripts/generate-icon.swift" "$MASTER" >/dev/null

ICONSET="$TMP_DIR/ClipShelf.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Resources/AppIcon.icns"
echo "Wrote $ROOT_DIR/Resources/AppIcon.icns"
