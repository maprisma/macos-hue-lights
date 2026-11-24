# Mac App Store Strategy & Commercialization Notes — Hue Lights (macOS)

*Last updated: 2026-11-24*

## 1. Distribution & Privacy Policy
- **Target channel:** Apple Mac App Store (commercial, paid / freemium one-time unlock — **no subscription**).
- **Private repositories:** All Hue repositories remain **PRIVATE** (`maprisma/hue-lights`, `maprisma/macos-hue-lights`, `uBruckhaus/macos-hue-lights`, `uBruckhaus/omarchy-hue-lights`).
- **Linux / public channels:** Withdrawn from Omarchy Plugin Marketplace (`#15836` closed, `#15875` removal request opened) and removed from `https://maprisma.com`. Do not publicly expose Hue Lights on the website or open plugin stores while selling the Mac App Store edition.

## 2. Core Marketing & Product Positioning

### Unique Selling Points (USPs vs. Mac App Store Competition)
The official Philips Hue app is mobile-only (iOS/iPadOS) and not offered as a native Mac App Store desktop app. Existing Mac App Store competitors fall mostly into two buckets:
- **Simple menu bar switches** (`Hue in the Menu` free, `HueMenu` ~€3.99, `Colors for Hue` free): basic room toggles, no floorplan, no visual rules, no audio sync, no Bridge Pro MotionAware™.
- **High-priced / complex tools** (`HueCommand` ~$19.99, `Hue Sync` standalone entertainment tool): expensive or single-purpose.

**Our differentiation:**
1. **Interactive Floorplan Studio (`Map | Rules`)**: Drag & drop lamps, rooms, furniture stamps, custom floorplan images, 1:1 lamp icons, hover-only clean labels, and visual line-drawing rules (`sensor / lamp → lamp`).
2. **Complete Hue Ecosystem**: Native CLIP v2 + SSE live updates, **Hue Bridge Pro (`BSB003`) MotionAware™** RF presence badges & sensitivity controls, plus physical **Motion, Contact, and Switch/Dial sensors**.
3. **Built-in Audio Reactive Light Sync** (without needing a separate Hue Sync app).
4. **6 Distinct Visual Skins** + native macOS menu bar & desktop window UX + **8 interface languages** (EN, DE, FR, ES, IT, PT, JA, ZH).
5. **Animated Built-in Help Guide (`?`)** & **Zero-hardware Demo Mode** (lets buyers & App Review test every feature immediately).
6. **Optional Local-First "Ask AI" & Local MCP Server (`--mcp`)**: Power-user bonuses that never get in the way of regular users.

### CRITICAL Marketing Rule — "Ask AI" Positioning
> **Always market "Ask AI" as strictly OPTIONAL (opt-in, default OFF) and 100% local-first.**
- **Default state in all apps:** `askAIEnabled = false` (**OFF**). When OFF, **zero AI buttons, badges, or prompts** appear in the UI.
- **Why:** Many macOS users actively dislike forced AI features, subscriptions, and cloud data collection.
- **Messaging angle:** *"No forced AI, no cloud account, no subscription. If you want natural-language lamp control, rules, or schedules, you can optionally switch on Ask AI in Settings — it works locally right on your Mac (with optional local Ollama support)."*

## 3. Chosen Mac App Store Pricing Model (DECISION LOCKED: Option A — Free + One-Time Pro Unlock)

### ✅ DECIDED MODEL: Option A — Free Download + One-Time "Pro Unlock" IAP (No Subscription!)
*Confirmed by Uwe on 2026-11-24.*
- **Download:** **Free**
  - Includes: Menu Bar quick control, Rooms/Lamps/Scenes control with the user's real Hue Bridge, plus full interactive **Demo Mode** so anyone can test Floorplan, Visual Rules, MotionAware™, and Audio Sync risk-free.
- **One-Time Pro Unlock (Non-Consumable IAP via StoreKit 2):**
  - **Launch offer:** **7,99 € / $7.99** (first 2–4 weeks)
  - **Standard price:** **9,99 € / $9.99** (optional step-up to **12,99 €** later)
  - Unlocks full live Bridge control for: Floorplan Studio, Visual Rules & Sensors, Bridge Pro MotionAware™, Audio Light Synth, all 6 Skins, optional Ask AI, and MCP server.
  - Includes a standard **"Restore Purchases"** button in Settings & Paywall sheet.
- **Why this model was chosen:**
  - Hardware-app buyers want to verify Hue Bridge connectivity in 10 seconds before paying → much higher trust and conversion.
  - Free downloads rank significantly better in Mac App Store search.
  - 100% **one-time purchase, zero subscription**, avoiding subscription fatigue.

### Rejected Alternative (for reference only): Paid Upfront
- Direct paid app (€6.99 launch / €9.99 regular) — rejected in favor of Option A so users can verify Bridge compatibility before unlocking Pro.

### Live Mac App Store Competitor Snapshot (2026-11-24, Apple iTunes Search API)
*Apple does not publish exact download counts — only rating counts (macOS rule of thumb: ~1 rating per 50–150 downloads; universal iOS+macOS apps pool iPhone/iPad ratings).*
- **Pure macOS paid apps (all struggling for traction):**
  - *We Love Lights* (€7.99 / $6.99, since 2019): 0 ratings (DE & US)
  - *Hue Menu Bar* (€3.99 / $3.99, since 2020): 0 ratings (DE & US)
  - *Quick Manager for Hue* (€3.99, since 2026): 0 ratings (DE)
- **Pure macOS Free + IAP:**
  - *Command for Philips Hue* (Free + IAP, since 2026-03): 4 ratings (US, 5.0 ★), 0 ratings (DE)
  - *Hue in the Menu* (Free, since 2020): 0 ratings in Storefront API (mostly direct website downloads)
- **Universal iOS + macOS apps (ratings mostly from iOS/iPadOS):**
  - *Hue Essentials* (Free + IAP): 225 ratings DE (4.1 ★) / 146 US (4.2 ★)
  - *all 4 hue* (Free + IAP): 207 ratings DE (4.1 ★) / 58 US (3.8 ★)
  - *Hue Party* (Free + IAP, since 2013): 1,380 DE / 2,475 US (3.8–3.9 ★)
- **Takeaway:** Every Hue app with meaningful App Store traction uses **Free Download + IAP (Option A)**; upfront-paid Mac Hue apps almost all sit at 0 ratings. Because pure-macOS competition has tiny rating counts, a polished launch (Hueblog.de, r/Hue, r/macapps) + Option A + in-app review prompt (`SKStoreReviewController`) can quickly capture a top search rank for `"Philips Hue"` on macOS.

### Apple Small Business Program
- Enroll in the **App Store Small Business Program** before launch: reduces Apple's commission from **30 % to 15 %** (up to $1M/year net proceeds).
- At **9,99 €** (incl. ~19% DE VAT → ~8,39 € net), 15 % Apple fee leaves **~7,13 € per sale** (vs. ~5,87 € at 30 %).

## 4. Mac App Store Review & Technical Checklist
- **Entitlements & Privacy Strings:**
  - `NSLocalNetworkUsageDescription` (clear explanation: discovers and controls Philips Hue Bridge on the local LAN).
  - `NSBonjourServices`: `["_hue._tcp"]`.
  - `NSMicrophoneUsageDescription` (only if Audio Sync captures mic/system input — explain clearly and request lazily only when Audio Sync is started).
  - App Sandbox enabled (`com.apple.security.app-sandbox`, `com.apple.security.network.client`).
- **App Review Demo Account / Hardware:** Highlight **Demo Mode** prominently in "App Review Notes" so Apple reviewers without a physical Hue Bridge can test Rooms, Floorplan, Rules, MotionAware™, Sensors, Skins, Help, and optional Ask AI immediately.
- **MCP CLI (`--mcp`):** Note that inside the Mac App Store sandbox, GUI launch is primary; document `--mcp` clearly for power users / direct CLI invocation or optional helper.
- **App Store Screenshots (5–6 high-impact frames):**
  1. Floorplan Studio with glowing lamps + hover tooltip + 1:1 icons
  2. Visual Rules mode (`Map | Rules`) with live sensor/lamp lines & Rule editor
  3. Rooms & Scenes + Bridge Pro MotionAware™ presence badge
  4. Audio Reactive Light Sync + Skin showcase
  5. Clean Menu Bar popover for quick daily access
  6. Optional local-first Ask AI & Animated Help (explicitly captioned *"Optional — Off by default"*)
