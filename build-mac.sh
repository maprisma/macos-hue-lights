#!/usr/bin/env bash
# Builds "dist/Maprisma Lights.app" for macOS 13+ (100% pure Swift, App Sandbox ready).
#
#   ./build-mac.sh                                      # release build for this Mac, ad-hoc signed
#   UNIVERSAL=1 ./build-mac.sh                          # arm64 + x86_64 universal binary
#   SANDBOX=1 SIGN_IDENTITY="Apple Distribution: ..." ./build-mac.sh
#
# Needs Swift 5.9+ (Xcode 15+ or the Command Line Tools: xcode-select --install). Written for the
# bash 3.2 that macOS ships.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Maprisma Lights"
EXECUTABLE="MaprismaHueLights"
BUNDLE_ID="com.maprisma.lights"
VERSION="${VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/$APP_NAME.app"
ENTITLEMENTS="MacAppStore/MaprismaHueLights.entitlements"
PRIVACY_MANIFEST="MacAppStore/PrivacyInfo.xcprivacy"
ICONSET_SRC="MacAppStore/Assets.xcassets/AppIcon.appiconset"

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/translations/extra"
install -m 0755 "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# bundled.json is what the app reads; the per-language sources travel along for reference.
cp translations/*.json "$APP/Contents/Resources/translations/"
cp translations/extra/*.json "$APP/Contents/Resources/translations/extra/"
cp "$PRIVACY_MANIFEST" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
if [ -d "$ICONSET_SRC" ] && command -v iconutil >/dev/null 2>&1; then
    ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_TMP"
    cp "$ICONSET_SRC"/icon_*.png "$ICONSET_TMP/"
    iconutil -c icns "$ICONSET_TMP" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET_TMP")"
fi
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Uwe Bruckhaus. All rights reserved.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Maprisma Lights finds your Philips Hue bridge and local smart lights (Home Assistant, WLED, WiZ, LIFX, Govee, Nanoleaf, Shelly, IKEA DIRIGERA) on your local network. It talks only to your local devices.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Optional: Maprisma Lights uses your microphone only when you start the Light Synthesizer in Microphone mode. Audio is analyzed in memory only and is never recorded or sent off your Mac.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Optional: Maprisma Lights uses Screen and System Audio Recording only when you start the Light Synthesizer in System Audio mode to sync lights with music or movies. Audio is analyzed in memory only and is never recorded or sent off your Mac.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_hue._tcp</string>
        <string>_home-assistant._tcp</string>
        <string>_wled._tcp</string>
        <string>_nanoleafapi._tcp</string>
        <string>_shelly._tcp</string>
        <string>_ihsp._tcp</string>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

xattr -cr "$APP" 2>/dev/null || true
IDENTITY="${SIGN_IDENTITY:--}"
if [ "${SANDBOX:-0}" = "1" ] || [ "$IDENTITY" != "-" ]; then
    echo "==> codesign ($IDENTITY, sandboxed)"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
else
    echo "==> codesign (ad hoc)"
    codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || uname -m), version $VERSION)"
echo "Run it with: open \"$APP\""
