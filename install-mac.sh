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

cat <<EOF

Installed: $TARGET

Launch it:
    open "$TARGET"
  or find "$APP_NAME" in Spotlight / Launchpad.
  Opens a movable, resizable main window with a quick-toggle bulb icon in the menu bar.

First start:
  * Allow "Local Network" access when macOS asks (System Settings > Privacy & Security >
    Local Network), so the app can discover and control your Philips Hue Bridge and local
    smart lights (Home Assistant, WLED, WiZ, LIFX, Govee LAN, Nanoleaf, Shelly, IKEA DIRIGERA).
  * Pair a Hue Bridge, add another local lighting provider, or try the built-in Demo Home.

Prebuilt releases:
  https://github.com/maprisma/macos-hue-lights/releases/latest (Maprisma-Lights-macOS.zip)

Start at login: System Settings > General > Login Items > "+" > $APP_NAME.
Uninstall: quit the app (Cmd+Q or menu bar right-click > Quit), delete "$TARGET", and optionally remove ~/Library/Application Support/MaprismaLights.
EOF

if [ "$OPEN_AFTER" = "1" ]; then
    open "$TARGET"
fi
