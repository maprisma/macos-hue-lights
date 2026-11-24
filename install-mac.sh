#!/usr/bin/env bash
# Builds Maprisma Lights and installs it into /Applications when that is writable, else into
# ~/Applications. INSTALL_DIR=/some/folder overrides the choice; --open launches it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Maprisma Lights"
EXECUTABLE="MaprismaHueLights"
OPEN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN_AFTER=1 ;;
        -h|--help)
            echo "usage: ./install-mac.sh [--open]   (INSTALL_DIR=... to choose the folder)"
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

./build-mac.sh

if [ -n "${INSTALL_DIR:-}" ]; then
    DEST="$INSTALL_DIR"
elif [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
TARGET="$DEST/$APP_NAME.app"

# A running copy keeps the old binary: quit it first (it ends its helper on the way out).
if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
    echo "==> Quitting the running $APP_NAME"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$EXECUTABLE" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

echo "==> Installing to $TARGET"
rm -rf "$TARGET"
ditto "dist/$APP_NAME.app" "$TARGET"

PY_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
if PATH="$PY_PATH" /usr/bin/env python3 -c 'import ssl, sys; assert sys.version_info >= (3, 8)' >/dev/null 2>&1; then
    PY_VERSION="$(PATH="$PY_PATH" /usr/bin/env python3 -c 'import sys; print(sys.version.split()[0])')"
    echo "    python3 $PY_VERSION found (the bridge helper needs no pip packages)"
else
    echo "    WARNING: no working python3 found. Install the Command Line Tools (xcode-select --install)"
    echo "             or Homebrew python (brew install python), then start the app again."
fi

cat <<EOF

Installed: $TARGET

Launch it:
    open "$TARGET"
  or find "$APP_NAME" in Spotlight / Launchpad. The bulb appears in the menu bar (no Dock icon).

First start:
  * Allow "Local Network" access when macOS asks (System Settings > Privacy & Security >
    Local Network), so the app can find and reach the Hue bridge.
  * Click the bulb, pick your bridge (or type its IP), press the bridge's round link button.

Start at login: System Settings > General > Login Items > "+" > $APP_NAME.
Uninstall: quit it from Settings > Quit, delete "$TARGET" and ~/.config/hue-lights.
EOF

if [ "$OPEN_AFTER" = "1" ]; then
    open "$TARGET"
fi
