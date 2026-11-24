# AGY Handoff — Continuing Maprisma Lights on macOS

This file gives **Antigravity (AGY) on macOS** full context to compile-verify, polish, capture screenshots, archive in Xcode, and ship **Maprisma Lights** (`com.maprisma.lights`, **$4.99 / €4.99** one-time purchase) to the **Mac App Store**.

> **Warning on Git Remotes:** Push to your **private** repo (`origin` = `uBruckhaus/macos-hue-lights`). Do **not** push the paid Mac App Store release publicly — before launch, make `maprisma/macos-hue-lights` private and remove the free macOS download from `maprisma.com`.

---

## 1. What Was Already Built (from Linux)

Everything in `Sources/` was rewritten to **100% pure Swift 5.9+ (macOS 13+, App Sandbox–compliant, zero Python dependency)**:

- **Core (`Sources/HueCore/`):**
  - `NativeHueBridgeClient.swift`, `KeychainStore.swift`, `SSEParser.swift` — pinned HTTPS (`URLSessionDelegate` SHA-256 + CN == `bridge_id`), native Bonjour `_hue._tcp` via `NWBrowser`, Keychain storage (`service: com.maprisma.lights`) for `app_key` + `clientKey`, live `/eventstream/clip/v2` SSE stream + REST fallback.
  - `DemoBridgeClient.swift` — full interactive **"Try Demo Home"** (4 rooms, 9 lights, 8 scenes, schedules, live dependency rules, Demo Beat synth) for Apple App Review (Guideline 2.1).
  - `RuleEngine.swift` & `LocalScheduler.swift` — Follow/Mirror, Exclusive, Companion (time windows / `onlyIfOff`), Mac wake/sleep/lock triggers, cycle detection, 1.5 s echo suppression, 2 s cooldown, depth cap 3, activity log; user-selectable **On Hue Bridge** vs. **On this Mac (live)** schedule mode.
  - `LightThemes.swift` — 8 curated light themes + custom per-lamp theme editor + *"Save current state"*.
  - `AudioAnalyzer.swift` & `EntertainmentStreamer.swift` — `Accelerate/vDSP` 3-band FFT (Bass/Mids/Treble) + beat detector, Hue Entertainment v2 binary `HueStream` v2.0 DTLS-PSK (`NWProtocolTLS` UDP:2100) + zero-setup CLIP v2 fast sync fallback.
  - `AppSkin.swift` — 6 fun skins (*System Native, Neon Synthwave, Cozy Cabin, Retro Terminal, Disco Lava, Minimal Zen*) + 8 selectable Menu Bar Icons + optional lit-count badge.
  - `SettingsStore.swift` — sandbox-safe `Application Support/MaprismaLights`.
- **SwiftUI App (`Sources/MaprismaHueLights/`):**
  - `MaprismaHueLightsApp.swift` — `MenuBarExtra(.window)` + detachable resizable 2-column `Window("Maprisma Lights", id: "main-window")`, `NSWorkspace` wake/sleep & screen-lock observers.
  - `ContentView.swift`, `RoomsView.swift`, `SchedulesView.swift`, `RulesView.swift`, `SynthView.swift`, `LightThemesView.swift`, `PairingView.swift`, `SettingsView.swift`.
  - `AudioCaptureManager.swift` — `ScreenCaptureKit` system audio (MAS sandbox–compliant; never `AudioHardwareCreateProcessTap`) + `AVAudioEngine` microphone + Demo Beat.
  - `GlobalHotKeyManager.swift` — Carbon `RegisterEventHotKey` (sandbox-safe, zero Accessibility permission).
  - `HueAppIntents.swift` — Apple Shortcuts & Siri (`AppIntents` + `AppShortcutsProvider`).
- **Mac App Store Files (`MacAppStore/`):**
  - `MaprismaHueLights.entitlements` (`com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.device.audio-input`)
  - `PrivacyInfo.xcprivacy` (zero tracking / data collection)
  - `Assets.xcassets/AppIcon.appiconset/` (all 10 PNG sizes 16–1024 + `Contents.json`, rendered from `AppIcon.svg`)
  - `project.yml` (XcodeGen spec for `com.maprisma.lights`)
  - `LAUNCH-KIT.md` (8-language App Store Connect metadata, ASO keywords, App Review notes, Privacy Policy text, screenshot list, and Hueblog / Reddit / Show HN marketing templates)
- **Translations:** All 8 languages (`en`, `de`, `fr`, `es`, `it`, `pt`, `nl`, `pl`) updated and bundled (`python3 tools/gen-translations`; **116 Python/validation tests passing**).

---

## 2. Step-by-Step Next Actions on macOS (Tell AGY to Run These)

### Step A — First Compile & Test on macOS
Because Linux has no Swift toolchain, the very first step on macOS is compiling and running tests (fixing any Swift/SDK compiler warnings or errors if Xcode 15/16 flags anything):

```bash
cd /path/to/macos-hue-lights
swift test
./build-mac.sh
open "dist/Maprisma Lights.app"
```

### Step B — Live Smoke Test (Demo Mode + Real Hue Bridge)
1. Click the menu bar icon → click **Try Demo Home**:
   - Verify all 4 tabs (`Lights`, `Schedules`, `Rules`, `Synth`), Favorites strip, `All On` (with room exclusions + confirm) / `All Off`, Color/Kelvin/Effects popover, Light Theme Editor, Pop-out 2-column window, all 6 Skins, all 8 Menu Bar Icons, and `Synth` tab with **Demo Beat**.
   - Toggle *Office Desk* in Demo Mode and confirm the sample linked rule automatically switches *Monitor Backlight* and logs in `Recent Activity`.
2. Test with your **real Hue Bridge** (Exit Demo Mode → Pair):
   - Verify Bonjour `_hue._tcp` discovery, push-link pairing, Keychain save (`app_key` + `clientKey`), instant SSE updates when toggling a light from a wall switch/phone, creating/toggling a Bridge-native schedule, and **Light Synthesizer** with **System Audio** (`ScreenCaptureKit`) and **Microphone**.
   - Test **Global Keyboard Shortcuts** and **Apple Shortcuts** (`Shortcuts.app`).

### Step C — Capture 6 App Store Screenshots (Demo Mode)
Follow the 6-shot list in `MacAppStore/LAUNCH-KIT.md` §4 in **Demo Mode** (no personal room names!), save the raw PNGs into `MacAppStore/raw-screenshots/`, then ask AGY on macOS to composite them into **`2880×1800`** (16:10 Retina) localized marketing slides (EN + DE, or all 8 languages).

### Step D — Generate Xcode Project & Archive for Mac App Store
```bash
# Install XcodeGen if not installed: brew install xcodegen
cd MacAppStore && xcodegen generate
open MaprismaLights.xcodeproj
```
In Xcode:
1. Select your **Apple Developer Team** under *Signing & Capabilities* (`com.maprisma.lights`, Automatic Signing, App Sandbox enabled).
2. Confirm `AppIcon`, `PrivacyInfo.xcprivacy`, and `translations/bundled.json` are included in the target bundle.
3. Build destination: **Any Mac (Apple Silicon, Intel)** → **Product → Archive** → **Distribute App → App Store Connect → Upload**.

### Step E — App Store Connect & Pre-Launch Commercial Switch
1. Apply for the **Apple Small Business Program** (15% fee instead of 30%) if not already enrolled.
2. Paste metadata, ASO keywords, Privacy Policy URL (`https://maprisma.com/…`), and App Review Notes from `MacAppStore/LAUNCH-KIT.md`.
3. **Before releasing on the Mac App Store:**
   - Make `maprisma/macos-hue-lights` **private** on GitHub and delete the free public `v0.2.0` release.
   - Remove the free macOS Hue Lights download from `maprisma.com` (`maprisma/website`: `js/main.js`, `js/apps.js`, `index.html`) and replace it with the **Mac App Store** badge/link once approved.
4. Launch marketing using `MacAppStore/LAUNCH-KIT.md` §6 (Hueblog.de/com with promo codes, `r/Hue`, `r/macapps`, `r/MacOS`, Product Hunt, Show HN).

---

## 3. Ready-to-Paste Prompt for AGY on macOS

> Read `MacAppStore/HANDOFF-MACOS.md` and `MacAppStore/LAUNCH-KIT.md`. Start with Step A: run `swift test` and `./build-mac.sh`, fix any macOS Swift/SDK compiler errors or warnings, verify the app runs cleanly, and then guide me through Step B–D (live testing, screenshots, and Xcode archiving for the Mac App Store).
