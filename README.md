# Maprisma Lights (macOS)

A native, 100% pure-SwiftUI **multi-brand local smart lighting controller & Floorplan Studio** for macOS 13 Ventura or newer (Apple Silicon & Intel).

**100% free & open — all features unlocked for everyone.** Zero paywall, zero subscription, zero cloud accounts, and zero telemetry.

## Highlights

- **Multi-Brand Local Smart Lighting (9 Ecosystems):** Native support for **Philips Hue Bridge** (live CLIP v2 Server-Sent Events, Bridge Pro MotionAware™, physical motion/contact/switch sensors, native Hue effects, Entertainment v2 DTLS-PSK) alongside **Home Assistant, WLED, WiZ, LIFX, Govee LAN, Nanoleaf, Shelly, and IKEA DIRIGERA** — all controlled locally on your LAN from one unified interface.
- **Floorplan Studio v2 (`Map` tab):** Design your home with **freeform polygon rooms**, **multi-floor** navigation, an editable **template & house/apartment gallery**, and a built-in **lighting planner**. Place lamps and sensors on an interactive 2D canvas with live radial color halos, draggable 90°-rotatable architectural furniture stamps, or an optional custom floorplan background image (PNG/JPEG/HEIC/WebP). Pick from 12 lamp icons, rename lamps inline, recall/save/schedule room scenes in 1 click, wire visual **Bezier dependency rules**, and push updates to your Hue Bridge via 1-click **Sync All** or **Auto-sync**.
- **Movable, Resizable, Tileable Main Window + Menu Bar Toggle:** Behaves like a first-class macOS desktop app — freely movable, resizable, and compatible with tiling window managers — paired with a quick-toggle menu bar icon (8 selectable icons + optional lit-count badge) and right-click quick menu.
- **Lights, Rooms, Scenes & Per-Lamp Light Themes:** Favorites strip, filter pills, smart **All On / All Off** with per-room exclusions, Kelvin warmth, full color, native Hue effects (*Candle, Fire, Sparkle, Prism, Opal, Glisten*), and 8 built-in + custom per-lamp **Light Themes**.
- **Schedules & Linked-Light Rules:** Clock or **Sunrise / Sunset** (± offset) schedules (`On Hue Bridge` or `Live on Mac`), plus **Follow/Mirror, Exclusive, and Companion** rules with **Mac wake, sleep, and screen lock** triggers, time windows, cycle detection, and echo suppression.
- **Live Audio Light Synthesizer (`Synth` tab):** 3-band `vDSP` FFT (Bass, Mids, Treble) + beat detection from **System Audio** (`ScreenCaptureKit`), **Microphone** (`AVAudioEngine`), or built-in **Demo Beat**, with standard API and ultra-low-latency **Hue Entertainment v2 (DTLS-PSK)** output.
- **Optional Local-First Ask AI (Off by Default) & Built-in MCP Server (`--mcp`):** Ask AI defaults to **OFF** so zero AI code runs unless you opt in (`⌘K` offline EN/DE parser + optional loopback-only Ollama fallback). Power users can also launch `MaprismaHueLights --mcp` (or `--mcp --demo`) as a local stdio JSON-RPC 2.0 MCP server.
- **6 App Skins, Global Hotkeys, Siri / Apple Shortcuts, Demo Home & 8 Languages:** *System Native, Neon Synthwave, Cozy Cabin, Retro Terminal, Disco Lava, Minimal Zen* · built-in offline translations for **English, Deutsch, Français, Español, Italiano, Português, Nederlands, and Polski**.
- **Local-Only Privacy & macOS Keychain Storage:** All traffic stays strictly on your local network. Philips Hue connections use certificate-pinned HTTPS (SHA-256 fingerprint + CN == bridge ID), all bridge keys and provider tokens are stored securely in the **macOS Keychain**, and the `.app` bundle has zero Python or external runtime dependencies.

## Install (macOS 13+)

### Option 1: Download the prebuilt app (recommended)

1. Download **`Maprisma-Lights-macOS.zip`** (and optional `.sha256` checksum) from the [latest GitHub Release](https://github.com/maprisma/macos-hue-lights/releases/latest).
2. Verify the checksum (optional) and unzip:
   ```sh
   shasum -a 256 -c Maprisma-Lights-macOS.zip.sha256
   ditto -x -k Maprisma-Lights-macOS.zip /Applications
   ```
   Or double-click the zip in Finder and drag **`Maprisma Lights.app`** into **`/Applications`**.
3. **First launch (ad-hoc signed GitHub release):** Because GitHub releases are ad-hoc signed rather than notarized by Apple, clear the quarantine flag once before opening (or right-click → **Open**):
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Maprisma Lights.app"
   open "/Applications/Maprisma Lights.app"
   ```
4. Allow **Local Network** access when macOS prompts so Maprisma Lights can discover and control your local smart lights.

### Option 2: Build and install from source

Requires macOS 13+ and Swift 5.9+ (Xcode 15+ or `xcode-select --install`):

```sh
git clone https://github.com/maprisma/macos-hue-lights.git
cd macos-hue-lights
./install-mac.sh --open
```

`./install-mac.sh` builds a release bundle (`dist/Maprisma Lights.app`) and installs it into `/Applications` (or `~/Applications` if `/Applications` is not writable; override with `INSTALL_DIR=...`). Pass `UNIVERSAL=1 ./build-mac.sh` to build an Apple Silicon + Intel universal binary.

## Development & Tests

```sh
swift test                                                     # HueCore unit tests (providers, floorplan, rules, sync, 8 langs)
./build-mac.sh && codesign --verify --deep --strict "dist/Maprisma Lights.app"
python3 -m unittest discover -s tests -v                       # 8-language catalog & static Swift/sandbox checks
```

## Part of the Maprisma Family

Looking for Linux (COSMIC / KDE / Omarchy) versions of Maprisma apps? Visit [maprisma.com](https://maprisma.com) or [github.com/maprisma](https://github.com/maprisma).
