#!/usr/bin/env bash
# Builds "dist/Maprisma Hue Lights.app" for macOS 13+ (Apple silicon by default) and signs it ad hoc.
#
#   ./build-mac.sh               # release build for this Mac's architecture (arm64 on an M4)
#   UNIVERSAL=1 ./build-mac.sh   # arm64 + x86_64 in one binary
#
# Needs Swift 5.9+ (Xcode 15+ or the Command Line Tools: xcode-select --install). Written for the
# bash 3.2 that macOS ships.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Maprisma Hue Lights"
EXECUTABLE="MaprismaHueLights"
BUNDLE_ID="io.github.ubruckhaus.MaprismaHueLights"
VERSION="${VERSION:-$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -n 1)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/$APP_NAME.app"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-mac.sh builds the macOS app and must run on macOS." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found. Install Xcode or the Command Line Tools: xcode-select --install" >&2
    exit 1
fi

ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "==> swift build -c release $ARCH_FLAGS"
# shellcheck disable=SC2086 # ARCH_FLAGS is a word list on purpose
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"
if [ ! -x "$BIN_DIR/$EXECUTABLE" ]; then
    echo "Build produced no $BIN_DIR/$EXECUTABLE" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/translations"
install -m 0755 "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
install -m 0755 scripts/hue-lights.py "$APP/Contents/Resources/scripts/hue-lights.py"
# bundled.json is what the app reads; the per-language sources travel along for reference.
cp translations/*.json "$APP/Contents/Resources/translations/"
mkdir -p "$APP/Contents/Resources/translations/extra"
cp translations/extra/*.json "$APP/Contents/Resources/translations/extra/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>fr</string>
        <string>es</string>
        <string>it</string>
        <string>pt</string>
        <string>nl</string>
        <string>pl</string>
    </array>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Maprisma Hue Lights finds your Philips Hue bridge on the local network and switches its lights. It talks only to the bridge.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_hue._tcp</string>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign (ad hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

echo
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || uname -m), version $VERSION)"
echo "Run it with: open \"$APP\""
