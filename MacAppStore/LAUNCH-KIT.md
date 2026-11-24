# Maprisma Lights — Mac App Store Launch Kit (Free + One-Time Pro Unlock)

![Maprisma Lights macOS App Icon](AppIcon-1024.png)

*(Vector SVG source: [app_icon_1024.svg](AppIcon.svg) — exported into [AppIcon.appiconset](Assets.xcassets/AppIcon.appiconset/) for Xcode & `build-mac.sh`.)*

---

## 1. App Store Connect Metadata (Ready to Paste)

- **App Name:** **`Maprisma Lights`** *(15 chars — clean, DPMA/EUIPO & App Store clear, no "Hue" in brand title)*
- **Bundle ID:** **`com.maprisma.lights`**
- **Primary Category:** Utilities · **Secondary Category:** Lifestyle
- **Pricing Model (Option A — Zero Subscription):**
  - **Base App Download:** **Free**
  - **Non-Consumable IAP Product ID:** **`com.maprisma.huelights.pro`** (`Maprisma Hue Lights Pro`, Family Sharing enabled)
  - **Price Tier:** **$7.99 / €7.99** launch offer → **$9.99 / €9.99** standard one-time purchase *(NO subscription)*
- **Age Rating:** 4+ (no objectionable content)
- **App Privacy Nutrition Label:** **Data Not Collected** (all bridge traffic stays on the local LAN; audio for the Light Synthesizer is analyzed strictly in memory and never recorded or transmitted).
- **Export Compliance (`ITSAppUsesNonExemptEncryption`):** `NO` (uses only standard Apple OS TLS/HTTPS on the local network).

### Free vs. Demo vs. Pro Feature Matrix

| Feature | Free (Real Hue Bridge) | Demo Mode (Simulated Home) | Pro (One-Time IAP `com.maprisma.huelights.pro`) |
| :--- | :---: | :---: | :---: |
| Menu bar popover & resizable desktop window | ✅ Free | ✅ Unlocked | ✅ Unlocked |
| Rooms, Zones, Lights (power, brightness, color/warmth, scenes, rename, favorites) | ✅ Free | ✅ Unlocked | ✅ Unlocked |
| Bridge discovery, pairing & pinned HTTPS | ✅ Free | ✅ Unlocked | ✅ Unlocked |
| Animated Help & Guide (`?`), Native skin, 8 languages | ✅ Free | ✅ Unlocked | ✅ Unlocked |
| Schedules (Bridge & Mac) | ✅ Free | ✅ Unlocked | ✅ Unlocked |
| Visual Floorplan Studio & 12 custom lamp icons (`Map` tab) | 🔒 Preview in Demo | ✅ Unlocked | ✅ Unlocked |
| Visual Rules & physical Hue Sensors (`Rules` tab) | 🔒 Preview in Demo | ✅ Unlocked | ✅ Unlocked |
| Hue Bridge Pro MotionAware™ controls | 🔒 Preview in Demo | ✅ Unlocked | ✅ Unlocked |
| Audio Reactive Light Synth (`Synth` tab) | 🔒 Preview in Demo | ✅ Unlocked | ✅ Unlocked |
| All 6 custom Skins (5 custom + Native) | Native free / 5 🔒 | ✅ Unlocked | ✅ Unlocked |
| Optional local-first Ask AI (default OFF) & local MCP server (`--mcp`) | 🔒 Preview in Demo | ✅ Unlocked (`--demo --mcp`) | ✅ Unlocked |

### Local StoreKit 2 Testing in Xcode
1. Open the generated Xcode project (`MacAppStore/project.yml` → `xcodegen generate`).
2. Add `MacAppStore/MaprismaHueLights.storekit` to the project (if not already referenced).
3. Go to **Product → Scheme → Edit Scheme… → Run → Options → StoreKit Configuration** and select **`MaprismaHueLights.storekit`**.
4. Run the app in Debug mode to test real StoreKit 2 **Purchase**, **Restore Purchases**, **Transaction.updates**, and **Revocation** locally without an App Store Connect sandbox account.
5. In Debug builds, **Settings → Pro / License → Debug License Simulation** also lets you switch instantly between **StoreKit Live**, **Simulate Free**, and **Simulate Pro** (stripped out completely in Release builds).

### English (`en-US` / `en-GB`)
- **Name (30 chars max):** `Maprisma Lights` *(15 chars)*
- **Subtitle (30 chars max):** `Floorplan, Rules & Music Hue` *(28 chars)*
- **Promotional Text (170 chars max):**
  > Native macOS Hue controller with Visual Floorplan Studio, 6 prototypes, 12 lamp icons, wired rules, room scene schedules, Light Themes & Music Sync. Zero subscription.
- **Keywords (100 chars max):**
  `philips hue,floorplan,smart home,menu bar,music sync,lights,schedule,automation,ambient,lamp,scenes`
- **Description:**
  > **Take full control of your Philips Hue lights straight from your Mac menu bar — fast, native, private, and with zero subscription.**
  >
  > Maprisma Lights is built natively in Swift for macOS. No browser tabs, no cloud accounts, no monthly fees: it talks directly to your Philips Hue Bridge on your local network over certificate-pinned HTTPS.
  >
  > **NEW: Interactive Visual Floorplan & Spatial Light Studio**
  > - Place your Hue lamps freely on a live 2D home canvas — start from **6 editable house/apartment prototypes** with draggable, rotatable furniture stamps or import your own **custom floorplan background image**.
  > - Pick from **12 lamp icons**, rename lights inline, surround lamps with **resizable Room & Zone boxes**, recall or save **Room Scenes**, and schedule scenes in one click (**⏰ Schedule scene**).
  > - Draw **visual dependency wires** directly between lamps (Follow/Mirror, Exclusive, Companion) and push rooms, zones, names, and **Entertainment Area 2D/3D positions** to your Hue Bridge with **1-click Sync All** or **Auto-sync**.
  >
  > **Instant Menu Bar + Resizable Window**
  > - Toggle rooms, zones, and individual lights in one click — or pop out a full 2-column window when organizing your home.
  > - Master **All On / All Off** with per-room exclusions (keep the bedroom dark when hitting All On) and optional confirmation.
  > - Pin your favorite lights, rooms, and scenes to the top strip, and filter by On, Rooms, Zones, or Favorites.
  >
  > **Per-Lamp Light Themes, Colors & Native Effects**
  > - Click any lamp's color dot to dial in Kelvin warmth, full color, or native Hue effects (Candle, Fire, Sparkle, Prism, Opal, Glisten).
  > - Create and save your own **Light Themes** per lamp — or pick from 8 built-in themes (*Deep Focus, Golden Hour, Cozy Candle, Cyberpunk Neon, Ocean Calm, Sunset Glow, Forest Canopy, Nightlight*).
  >
  > **Schedules: On Your Hue Bridge or Live on Your Mac**
  > - Schedule any individual light or room by clock time or **Sunrise / Sunset** (± offset), weekdays, brightness, and smooth fade.
  > - Choose in Settings whether schedules run **natively on your Hue Bridge** (24/7 even while your Mac sleeps) or **live on your Mac**.
  >
  > **Smart Linked-Light Rules, Sensors, Bridge Pro MotionAware™ & Mac Automation**
  > - Link lights, rooms, **physical Hue sensors & switches** (motion, contact, buttons), and **Bridge Pro MotionAware™** radar presence areas together in real time via Hue's live event stream: *"When Hallway Motion detects motion → turn ON Hallway"* or *"When TV Strip turns ON → turn OFF Ceiling"*.
  > - Add time windows or *"only if off"* conditions, plus **Mac wake, sleep, and screen lock** triggers.
  > - Built-in cycle detection and echo suppression prevent flickering loops.
  >
  > **Built-in Animated Visual Help Guide, Optional Ask AI (Off by Default) & Local MCP Server**
  > - Open the built-in **animated Help & Guide** (`?`) anytime for a calm visual tour of every feature.
  > - **Ask AI is strictly optional and OFF by default:** prefer a pure, non-AI native Hue app? You will never see an AI button unless you turn it on in Settings. When enabled (`⌘K`), switch lights, apply themes, and create rules or schedules in plain English or German completely offline (with optional loopback-only local Ollama support).
  > - **Local MCP Server (`--mcp`):** Power users can connect any local MCP-compatible AI agent over stdio directly to their Mac — zero cloud, bridge keys stay safely in macOS Keychain.
  >
  > **Live Audio Light Synthesizer**
  > - Sync your Hue lights to **streamed system music** (Spotify, Apple Music, YouTube) or your **microphone** using real-time 3-band FFT (Bass, Mids, Treble) and beat detection.
  > - Supports both zero-setup standard sync and ultra-low-latency **Hue Entertainment v2** streaming, with Pulse, Color Wave, Club, and Chill modes.
  >
  > **Make It Yours**
  > - **6 Fun App Skins:** System Native, Neon Synthwave, Cozy Cabin, Retro Terminal, Disco Lava, and Minimal Zen.
  > - **8 Selectable Menu Bar Icons** + optional lit-count badge.
  > - Custom corners, background style, font family, font size, **Global Keyboard Shortcuts**, **Apple Shortcuts & Siri**, **Launch at Login**, and **8 interface languages** (English, Deutsch, Français, Español, Italiano, Português, Nederlands, Polski).
  > - **Interactive Demo Home** built in so you can explore every feature even before pairing a Hue Bridge.
  >
  > *One-time purchase. Zero subscriptions. Zero cloud. Zero tracking.*
  > *Independent third-party app. Not affiliated with or endorsed by Signify Holding / Philips Hue.*

### German (`de-DE`) — Top European Hue Market
- **Name:** `Maprisma Lights`
- **Subtitle (30 chars max):** `Grundriss, Regeln & Musik Hue` *(29 chars)*
- **Promotional Text:**
  > Native macOS-App für Philips Hue: Visuelles Grundriss-Studio mit 6 Vorlagen & 12 Lampen-Icons, Raumszenen-Zeitpläne, gekoppelte Regeln, Lichtthemen & Musik-Sync. Kein Abo.
- **Keywords (100 chars max):**
  `philips hue,grundriss,smart home,menüleiste,musik sync,licht,zeitplan,automation,lampen,szenen,farbe`
- **Description (summary highlights ready for App Store Connect):**
  > Steuere deine Philips-Hue-Lampen direkt aus der macOS-Menüleiste — blitzschnell, nativ in Swift, 100 % lokal und ohne Abo.
  > - **Visuelles Grundriss-Studio (Map-Tab):** Platziere Lampen frei auf deiner Wohnungskarte — starte mit **6 bearbeitbaren Grundriss-Vorlagen** inkl. Möbel-Symbolen oder eigenem Hintergrundbild, wähle aus **12 Lampen-Icons**, zeichne skalierbare **Raum- & Zonenboxen** mit direkten Raumszenen & **⏰ Szenen-Zeitplänen**, ziehe **Abhängigkeits-Leitungen** zwischen Lampen und synchronisiere Räume, Namen & Entertainment-Positionen per **1-Klick-Sync** mit deiner Hue Bridge.
  > - **Menüleiste + eigenes Fenster:** Räume, Zonen, Einzellampen, Favoriten, Filter sowie „Alle an / Alle aus" mit Raum-Ausnahmen.
  > - **Lichtthemen-Editor pro Lampe:** Farbtemperatur, Farben, native Hue-Effekte (Kerze, Feuer, Funkeln, Prisma) und eigene Themen speichern.
  > - **Zeitpläne pro Lampe & Raum:** Wahlweise **nativ auf der Hue Bridge** (läuft auch im Ruhezustand) oder **live auf dem Mac** — mit Uhrzeit, Sonnenauf-/-untergang, Wochentagen & sanftem Überblenden.
  > - **Abhängigkeits-Regeln, Sensoren, Bridge Pro MotionAware™ & Mac-Automation:** Verbinde Lampen, Räume, physische Hue-Bewegungs-, Kontakt- & Schaltsensoren sowie **Bridge Pro MotionAware™**-Präsenzbereiche direkt auf dem Grundriss — plus Auslösen bei Mac-Aufwachen/Ruhezustand/Sperren.
  > - **Animierte Hilfe-Übersicht, optionales „Ask AI" (standardmäßig AUS) & lokaler MCP-Server:** Interaktive Feature-Tour über `?`; wer eine reine, KI-freie Hue-App möchte, sieht keinerlei KI-Funktionen. Optional in den Einstellungen aktivierbar (`⌘K`, offline auf Deutsch & Englisch + lokales Ollama nur auf Loopback) sowie nativer `--mcp`-Stdio-Server für lokale KI-Agenten.
  > - **Musik-Licht-Synthesizer:** Reagiert live auf gestreamte Systemmusik oder Mikrofon (Bass/Mitten/Höhen + Beat-Erkennung, Hue Entertainment v2 & Standard-Sync).
  > - **Persönlicher Stil:** 6 App-Skins (u. a. Neon Synthwave, Cozy Cabin, Retro Terminal, Disco Lava), 8 wählbare Menüleisten-Icons, abgerundete Ecken, Schriftart & -größe, globale Tastenkürzel, Apple Kurzbefehle & Siri, 8 Sprachen und eingebauter Demo-Modus.

### Compact Localized Subtitles & Keywords (FR / ES / IT / PT / NL / PL)
| Locale | Subtitle (≤30 chars) | Keywords (≤100 chars) |
| :--- | :--- | :--- |
| **fr-FR** | `Hue, Règles & Sync Musique` | `philips hue,domotique,barre menus,musique,lumières,horaires,automatisation,lampes,scènes,couleurs` |
| **es-ES** | `Hue, Reglas y Sync Musical` | `philips hue,domótica,barra menús,música,luces,horarios,automatización,lámparas,escenas,colores` |
| **it-IT** | `Hue, Regole e Sync Musica` | `philips hue,domotica,barra menu,musica,luci,programmazione,automazione,lampade,scene,colori` |
| **pt-BR / pt-PT** | `Hue, Regras e Sync Musical` | `philips hue,casa inteligente,barra menu,música,luzes,agendamento,automação,lâmpadas,cenas,cores` |
| **nl-NL** | `Hue, Regels & Muzieksync` | `philips hue,smart home,menubalk,muziek,lampen,schema,automatisering,scènes,kleuren,verlichting` |
| **pl-PL** | `Hue, Reguły i Sync Muzyki` | `philips hue,smart home,pasek menu,muzyka,światła,harmonogram,automatyzacja,lampy,sceny,kolory` |

---

## 2. App Review Notes (Paste into App Store Connect → App Review Information)

> **Testing without a Philips Hue Bridge (Built-in Demo Mode):**
> This app controls Philips Hue smart lighting hardware on the user's local network. Because a physical Hue Bridge is not required to review the app, please click **"Try Demo Home"** on the initial pairing screen. Demo Mode simulates a complete 4-room Hue home (9 color/white lights, scenes, schedules, live dependency rules, Light Theme Editor, and the Audio Light Synthesizer with a built-in **"Demo Beat"** source) entirely in memory.
>
> **Permissions explained:**
> - **Local Network / Bonjour (`_hue._tcp`):** Used solely to discover and communicate with the user's Philips Hue Bridge on their LAN over certificate-pinned HTTPS.
> - **Screen & System Audio Recording (`ScreenCaptureKit`):** Used exclusively for audio-only capture (`capturesAudio = true`) when the user explicitly starts the **Light Synthesizer** with "System Audio" selected so lights react to playing music. No screen video or audio is ever recorded, saved, or sent off-device.
> - **Microphone (`AVAudioEngine`):** Optional alternative input for the Light Synthesizer when the user selects "Microphone". Audio is analyzed in memory only and never recorded or transmitted.
> - **No account, no cloud, no analytics, no tracking.**

---

## 3. Privacy Policy Text (Host at `https://maprisma.com/hue-privacy.html` or `legal.html#hue`)

> **Maprisma Hue Lights — Privacy Policy**
> Maprisma Hue Lights does not collect, store, share, or sell any personal data.
> - **Local Network Only:** The app communicates exclusively with your Philips Hue Bridge on your local network over certificate-pinned HTTPS. Your Hue Bridge application key is stored locally in the macOS Keychain.
> - **Audio Analysis:** When you start the Light Synthesizer with System Audio or Microphone input, audio samples are analyzed strictly in memory on your Mac to compute light brightness and color. Audio is never recorded, written to disk, or transmitted over the network.
> - **No Analytics or Tracking:** There are no third-party SDKs, ads, telemetry, or cloud servers.
> - **Contact:** Uwe Bruckhaus — `support@maprisma.com` (or your preferred contact email).

---

## 4. App Store Screenshot Shot List (Take 6 Raw Shots on Your Mac in Demo Mode)

Apple Mac App Store accepts **16:10** images at **`2880×1800`** (best) or **`2560×1600`** / **`1440×900`** / **`1280×800`**.

Take these 7 clean screenshots on your Mac in **Demo Mode** (so zero private room names appear), and send them here — I will frame & composite them into localized marketing slides:
1. **Hero Shot #1 — Visual Floorplan Studio (`Map` tab, detached wide window):** 3-Room Apartment prototype glowing with live lamp halos, custom SF Symbol lamp icons, furniture stamps, typed Bezier dependency wires, `⏰` badges on Living Room & Office, and the 1-click **Sync All** toolbar. → Headline: *"Map Your Home. Wire Your Lights. Sync in 1 Click."*
2. **Hero Shot #2 (`Lights` tab, detached 2-column window):** Office & Living Room glowing in rich warm/neon colors, Favorites strip visible, `All On / All Off` footer, menu bar icon visible. → Headline: *"Every Hue Light, One Click Away"*
3. **Per-Lamp Light Theme Editor & Color Popover:** Open on a Living Room light showing the Color/Kelvin wheel, Hue Effects, and custom Light Themes. → Headline: *"Custom Themes & Native Effects per Lamp"*
4. **Audio Light Synthesizer (`Synth` tab, Demo Beat active):** Live Bass/Mids/Treble spectrum pulsing, Color Wave / Neon palette selected. → Headline: *"Sync Your Lights to Music — No Extra App"*
5. **Dependency & Linked-Light Rules (`Rules` tab):** Showing `"When Office Desk turns ON → Monitor Backlight ON"` + `"When Mac wakes → Office ON"`. → Headline: *"Smart Rules & Mac Wake/Sleep Triggers"*
6. **Per-Light & Room Scene Schedules (`Schedules` tab):** Showing Sunrise/Sunset + Room Scene schedules with `"Bridge"` / `"Mac"` badges. → Headline: *"Schedules That Run Right on Your Bridge"*
7. **Fun Skins & Customization (`Settings` / side-by-side Skins):** Showing *Neon Synthwave*, *Cozy Cabin*, and *Retro Terminal* skins + selectable Menu Bar Icons. → Headline: *"6 Skins, 8 Menu Bar Icons, 8 Languages"*

---

## 5. Step-by-Step Submission Checklist (With Your Apple Developer Membership)

1. **Apply for Apple Small Business Program** *(if not enrolled yet — takes 5 min at `developer.apple.com/app-store/small-business-program/`)*: cuts Apple's fee from 30% → **15%** (at $4.99 you keep **~$4.24/sale**).
2. **Choose your permanent Bundle ID** in Apple Developer Portal → *Certificates, Identifiers & Profiles* (e.g. `com.maprisma.HueLights` or `io.github.ubruckhaus.MaprismaHueLights`).
3. **Create the app record** in **App Store Connect** → *My Apps → New App (macOS)*, set pricing ($4.99 / €4.99), paste metadata, upload App Icon & 2880×1800 screenshots, add Privacy Policy URL & App Review Notes.
4. **Archive & Upload from Xcode on your Mac:**
   - Open the Xcode project (we'll generate an XcodeGen `project.yml` / `.xcodeproj` with `MaprismaHueLights.entitlements`, `PrivacyInfo.xcprivacy`, and `AppIcon.appiconset`).
   - Select **Any Mac (Apple Silicon, Intel)** → **Product → Archive** → **Distribute App → App Store Connect → Upload**.
5. **Pre-Launch Commercial Switch (right before clicking "Release"):**
   - Make `maprisma/macos-hue-lights` **private** on GitHub and delete the public `v0.2.0` release.
   - Remove the free macOS Hue Lights GitHub download from `maprisma.com` and add the **Mac App Store** badge/link once approved.
   - Ensure `NSHumanReadableCopyright` in `Info.plist` is `© 2026 Uwe Bruckhaus. All rights reserved.` (no MIT `LICENSE` bundled in the paid MAS app).

---

## 6. Marketing & Launch Playbook

### Best-ROI Channels (in order)
1. **Hueblog.de & Hueblog.com (Highest conversion for Hue apps!):**
   - Email Fabian (`info@hueblog.de`) with a short personal note (in German!), 3 screenshots, a 15-second screen recording of the Music Synthesizer + linked desk lights, and **2–3 free App Store promo codes** (App Store Connect gives you 100 free promo codes per version!). Hueblog readers are hardcore Philips Hue owners who happily pay €4.99 for a clean, no-subscription Mac app.
2. **Reddit (`r/Hue`, `r/macapps`, `r/MacOS`, `r/shortcuts`):**
   - Lead with the story & craft, not a hard ad: *"I built a native SwiftUI Philips Hue menu bar app for macOS because I wanted per-light schedules, linked desk lights, Mac wake/sleep triggers, and music sync in one lightweight app — no Electron, no cloud, no subscription."*
   - Include a crisp 15-second GIF/video showing: clicking menu bar bulb → toggling Desk Lamp (Monitor Backlight follows automatically!) → starting Music Synth → flipping from System to Neon Synthwave skin.
   - Give away 5–10 promo codes in the comments on `r/macapps` (drives massive engagement and early 5-star reviews!).
3. **Product Hunt & Hacker News (`Show HN`):**
   - Angle for HN: *"Built a 100% pure-Swift, sandboxed Mac menu bar controller for Philips Hue (CLIP v2 SSE, DTLS-PSK Entertainment streaming, ScreenCaptureKit vDSP FFT music sync, pinned self-signed bridge TLS, zero cloud)."* — technical depth plays super well on HN.
4. **In-App Review Prompt (v1.0.1 / nice touch):**
   - Trigger Apple's native `SKStoreReviewController.requestReview()` once after e.g. 7 days & 15 successful light toggles (never on first launch, never after an error) — this is the #1 driver of App Store ranking over time.
