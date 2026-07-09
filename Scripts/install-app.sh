#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_APP="$ROOT_DIR/.build/ClipShelf.app"
INSTALL_APP="/Applications/ClipShelf.app"

# Build and package the .app bundle (handles signing).
"$ROOT_DIR/Scripts/package-app.sh"

# Quit a running instance before replacing the bundle.
if pgrep -x ClipShelf >/dev/null 2>&1; then
    echo "Stopping running ClipShelf..."
    pkill -x ClipShelf || true
    sleep 1
fi

echo "Installing to $INSTALL_APP..."
rm -rf "$INSTALL_APP"
cp -R "$BUILT_APP" "$INSTALL_APP"

# Register as a login item (idempotent).
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q "ClipShelf"; then
    echo "Adding ClipShelf to login items..."
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$INSTALL_APP\", hidden:true}" >/dev/null
else
    echo "ClipShelf already registered as a login item."
fi

echo "Launching ClipShelf..."
open "$INSTALL_APP"

echo "Done. ClipShelf is installed in /Applications and will start at login."
