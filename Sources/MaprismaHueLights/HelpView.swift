import HueCore
import SwiftUI

enum HelpFeature: Int, CaseIterable, Identifiable, Equatable, Sendable {
    case lights, floorplan, rules, motionAware, schedules, synth, skins, askAI, mcpServer
    var id: Int { rawValue }
}

/// Animated visual feature guide accessible from the header `?` button.
/// Uses a single `TimelineView` that runs ONLY while `HelpView` is visible (zero idle CPU cost).
struct HelpView: View {
    @EnvironmentObject var store: HueStore
    var onTryFeature: ((HelpFeature) -> Void)? = nil

    @State private var selectedFeature: HelpFeature? = nil
    @State private var hoveredFeature: HelpFeature? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider()

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                if let feature = selectedFeature {
                    detailView(for: feature, time: t)
                } else {
                    overviewList(time: t)
                }
            }
        }
    }

    // MARK: - Top Navigation Bar

    private var headerBar: some View {
        HStack {
            if let feature = selectedFeature {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedFeature = nil
                    }
                } label: {
                    Label(store.tr("All features"), systemImage: "chevron.left")
                        .font(store.scaledFont(12.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: 8)

                Text(title(for: feature))
                    .font(store.scaledFont(11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button {
                    store.page = .main
                } label: {
                    Label(store.tr("Back"), systemImage: "chevron.left")
                        .font(store.scaledFont(12.5))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text(store.tr("Help & Guide").uppercased())
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Overview List (9 Clickable Feature Cards)

    private func overviewList(time: TimeInterval) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.tr("Click any feature for a larger visual walkthrough"))
                    .font(store.scaledFont(11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                ForEach(HelpFeature.allCases) { feature in
                    featureCard(feature, time: time)
                }
            }
            .padding(14)
        }
    }

    private func featureCard(_ feature: HelpFeature, time: TimeInterval) -> some View {
        let isHovered = hoveredFeature == feature
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedFeature = feature
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                featureCanvas(feature, time: time)
                    .frame(width: 124, height: 84)
                    .background(
                        RoundedRectangle(cornerRadius: store.smallRadius + 2, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.09, blue: 0.13))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: store.smallRadius + 2, style: .continuous)
                            .strokeBorder(isHovered ? store.skinAccentColor.opacity(0.65) : store.cardBorderColor, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: store.smallRadius + 2, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: feature))
                        .font(store.scaledFont(12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(description(for: feature))
                        .font(store.scaledFont(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 4) {
                        Text(store.tr("Tap for step-by-step guide"))
                            .font(store.scaledFont(10, weight: .medium))
                            .foregroundStyle(store.skinAccentColor)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(store.skinAccentColor)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? store.skinAccentColor : Color.secondary.opacity(0.65))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                    .fill(isHovered ? store.skinAccentColor.opacity(0.08) : store.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                    .strokeBorder(isHovered ? store.skinAccentColor.opacity(0.55) : store.cardBorderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredFeature = feature
            } else if hoveredFeature == feature {
                hoveredFeature = nil
            }
        }
    }

    // MARK: - Interactive Step-by-Step Detail View

    private func detailView(for feature: HelpFeature, time: TimeInterval) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Large crisp scaled vector animation preview
                featureCanvas(feature, time: time)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(
                        RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.09, blue: 0.13))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                            .strokeBorder(store.cardBorderColor, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous))

                // Title & plain-language overview
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(for: feature))
                        .font(store.scaledFont(15, weight: .semibold))
                    Text(description(for: feature))
                        .font(store.scaledFont(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Numbered "How to do it" walkthrough
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.tr("How to do it").uppercased())
                        .font(store.scaledFont(10.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    let stepList = steps(for: feature)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(stepList.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)")
                                    .font(store.scaledFont(10.5, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Color.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(store.skinAccentColor))

                                Text(step)
                                    .font(store.scaledFont(11.5))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(11)
                    .background(
                        RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                            .fill(store.cardBackgroundColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                            .strokeBorder(store.cardBorderColor, lineWidth: 1)
                    )
                }

                // Highlighted Quick Tip callout
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(store.skinAccentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.tr("Quick Tip"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(store.skinAccentColor)
                        Text(tip(for: feature))
                            .font(store.scaledFont(11.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                        .fill(store.skinAccentColor.opacity(0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                        .strokeBorder(store.skinAccentColor.opacity(0.35), lineWidth: 1)
                )

                // Try it now primary action
                HStack {
                    Button {
                        if let onTryFeature = onTryFeature {
                            onTryFeature(feature)
                        } else {
                            store.page = .main
                        }
                    } label: {
                        Label(store.tr("Try it now"), systemImage: "arrow.right.circle.fill")
                            .font(store.scaledFont(12.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    // MARK: - Feature Copy (Titles, Descriptions, Numbered Steps & Quick Tips)

    private func title(for feature: HelpFeature) -> String {
        switch feature {
        case .lights: return store.tr("Lights, Color & Themes")
        case .floorplan: return store.tr("Visual Floorplan Map")
        case .rules: return store.tr("Visual Rules")
        case .motionAware: return store.tr("Bridge Pro MotionAware & Sensors")
        case .schedules: return store.tr("Schedules")
        case .synth: return store.tr("Audio Light Synth")
        case .skins: return store.tr("Skins, Icons & Shortcuts")
        case .askAI: return store.tr("Ask AI (Optional)")
        case .mcpServer: return store.tr("MCP Server for AI Agents")
        }
    }

    private func description(for feature: HelpFeature) -> String {
        switch feature {
        case .lights:
            return store.tr("Control rooms and lamps with live brightness sliders, color & warmth pickers, native effects, and custom per-lamp themes.")
        case .floorplan:
            return store.tr("Arrange rooms, zones, furniture, and glowing lamps on an interactive 2D map, or place your own floorplan image behind them.")
        case .rules:
            return store.tr("Link lamps, rooms, sensors, or Mac wake/sleep events visually with drag-to-connect Bezier wires and automatic loop protection.")
        case .motionAware:
            return store.tr("See MotionAware™ radar badges on compatible lamps, monitor room presence, and wire Hue motion, contact, and switch sensors on the map.")
        case .schedules:
            return store.tr("Automate lights and scenes by fixed time, sunrise, or sunset — running 24/7 on your Hue Bridge or live on your Mac.")
        case .synth:
            return store.tr("Sync your lights in real time to music, movies, or microphone audio with 3-band Bass, Mids & Treble analysis and 25 Hz Entertainment streaming.")
        case .skins:
            return store.tr("Personalize the look with 6 coordinated skins, 8 menu bar icons, and system-wide global keyboard shortcuts.")
        case .askAI:
            return store.tr("Optional local-first assistant for switching lights, creating rules, and scheduling in plain language. Off by default — enable or hide anytime in Settings.")
        case .mcpServer:
            return store.tr("Built-in local stdio MCP server (--mcp) so any MCP-compatible AI agent can inspect and control your Hue lights, rooms, rules, and sensors privately on your Mac.")
        }
    }

    private func steps(for feature: HelpFeature) -> [String] {
        switch feature {
        case .lights:
            return [
                store.tr("Click any room card to expand its individual lamps, or flip the room switch to toggle the whole room."),
                store.tr("Drag the brightness slider, or click a lamp's colored icon to pick warmth (Kelvin), colors, and native Hue effects."),
                store.tr("Open the ⋯ menu on any lamp card for Brightness, Color & Warmth, Rename, 12 Lamp Icons, Themes, or Wire rule on Map."),
                store.tr("Pin your favorite rooms or lamps to show a 1-click Favorites strip at the top of Lights."),
            ]
        case .floorplan:
            return [
                store.tr("Open the Map tab and pick a starter layout from Prototypes, or load your own floorplan image under View → Background…."),
                store.tr("Drag room boxes by their header to arrange your home, and pull the corner handles to resize them."),
                store.tr("Click any lamp in the left sidebar to place it on the map, then drag it into the room where it sits."),
                store.tr("Click Sync All in the toolbar when you want to push renamed or moved rooms to your Hue Bridge."),
            ]
        case .rules:
            return [
                store.tr("Open the Map tab and switch the top toggle from Map to Rules."),
                store.tr("Drag from a lamp, room connector, or sensor onto another lamp — or click one lamp, then click the target."),
                store.tr("Choose Follow / Mirror, Exclusive, or Companion and optionally add an active time window."),
                store.tr("Click any colored wire or its midpoint badge anytime to edit, toggle, or delete the rule."),
            ]
        case .motionAware:
            return [
                store.tr("With a Philips Hue Bridge Pro, open the Philips Hue mobile app → Settings → MotionAware and calibrate any room with 3+ lights once."),
                store.tr("Compatible lamps automatically show a live radar badge in Lights and on the Map, glowing green when presence is detected."),
                store.tr("Click the slider button on a room box in Map to enable or disable MotionAware and tune sensitivity."),
                store.tr("Place physical Hue motion, contact, or switch sensors from the Map sidebar and wire them to lamps in Rules mode."),
            ]
        case .schedules:
            return [
                store.tr("Open the Schedules tab and click + New Schedule."),
                store.tr("Select a room or lamp and choose a Fixed time, Sunrise, or Sunset trigger with optional weekday repeats."),
                store.tr("Pick Turn on, Turn off, or a saved Scene, plus an optional fade duration."),
                store.tr("Choose On Hue Bridge (runs 24/7) or On this Mac (live) anytime in Settings."),
            ]
        case .synth:
            return [
                store.tr("Open the Synth tab and select System Audio (music/movies), Microphone, or Demo Beat."),
                store.tr("Choose a room or Hue Entertainment Area, then pick an animation Mode and Color Palette."),
                store.tr("Optionally assign Bass, Mids, or Treble to individual lamps for multi-band effects."),
                store.tr("Press Start to sync your lights live — audio is analyzed in memory only and never recorded."),
            ]
        case .skins:
            return [
                store.tr("Open Settings (gear icon) and choose from 6 coordinated App Skins or customize corners, backdrop, and font."),
                store.tr("Pick one of 8 Menu Bar Icons and optionally display the lit light count beside it."),
                store.tr("Assign Global Shortcuts to control lights or toggle Synth from any macOS app."),
            ]
        case .askAI:
            return [
                store.tr("Ask AI is off by default — turn it on anytime under Settings → Ask AI."),
                store.tr("Click the ✨ button in the header or press ⌘K to open the command bar."),
                store.tr("Type natural requests like \"Dim Living Room to 40% warm\" or \"Turn on Hallway at 07:30 weekdays\"."),
                store.tr("Offline parsing runs locally first; you can optionally connect a local Ollama server on 127.0.0.1."),
            ]
        case .mcpServer:
            return [
                store.tr("Start Maprisma Lights from Terminal or an AI client with the --mcp argument to expose the local stdio MCP server."),
                store.tr("Connect any MCP-compatible AI agent to read rooms, lights, sensors, rules, schedules, and floorplans."),
                store.tr("Every command stays on your local network over your pinned Hue Bridge connection — credentials are never exposed."),
            ]
        }
    }

    private func tip(for feature: HelpFeature) -> String {
        switch feature {
        case .lights:
            return store.tr("Lamp icons you choose in Lights sync 1:1 with your Visual Floorplan Map!")
        case .floorplan:
            return store.tr("Click the expand button in the top-right corner to open the Map in a full resizable desktop window.")
        case .rules:
            return store.tr("You can also open any lamp's ⋯ menu in the Lights tab and pick \"Wire rule on Map\" to jump straight into wiring it.")
        case .motionAware:
            return store.tr("MotionAware™ works with your existing Hue bulbs — no separate motion sensor hardware needed once calibrated on Bridge Pro.")
        case .schedules:
            return store.tr("Bridge schedules keep running even when your Mac is asleep or turned off.")
        case .synth:
            return store.tr("Link a Hue Entertainment Area for ultra-smooth 25 Hz light sync, or try Demo Beat first with zero permissions.")
        case .skins:
            return store.tr("Global shortcuts use native macOS hotkeys and need zero Accessibility permissions.")
        case .askAI:
            return store.tr("Want a completely minimal UI? Leave Ask AI turned off in Settings and the ✨ button stays hidden.")
        case .mcpServer:
            return store.tr("Read the hue://state resource for a complete snapshot of rooms, lights, themes, rules, and MotionAware status in one call.")
        }
    }

    // MARK: - Scalable Vector Canvas

    @ViewBuilder
    private func featureCanvas(_ feature: HelpFeature, time: TimeInterval) -> some View {
        Canvas { ctx, size in
            drawPreview(feature, in: &ctx, size: size, t: time)
        }
    }

    private func drawPreview(_ feature: HelpFeature, in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let baseSize = CGSize(width: 124, height: 84)
        let scale = min(size.width / baseSize.width, size.height / baseSize.height)
        let offsetX = (size.width - baseSize.width * scale) / 2.0
        let offsetY = (size.height - baseSize.height * scale) / 2.0

        var scaled = ctx
        scaled.translateBy(x: offsetX, y: offsetY)
        scaled.scaleBy(x: scale, y: scale)

        switch feature {
        case .lights:
            drawLightsPreview(in: &scaled, size: baseSize, t: t)
        case .floorplan:
            drawFloorplanPreview(in: &scaled, size: baseSize, t: t)
        case .rules:
            drawRulesPreview(in: &scaled, size: baseSize, t: t)
        case .motionAware:
            drawMotionAwarePreview(in: &scaled, size: baseSize, t: t)
        case .schedules:
            drawSchedulesPreview(in: &scaled, size: baseSize, t: t)
        case .synth:
            drawSynthPreview(in: &scaled, size: baseSize, t: t)
        case .skins:
            drawSkinsPreview(in: &scaled, size: baseSize, t: t)
        case .askAI:
            drawAskAIPreview(in: &scaled, size: baseSize, t: t)
        case .mcpServer:
            drawMCPPreview(in: &scaled, size: baseSize, t: t)
        }
    }

    // MARK: - 1. Lights, Color & Themes

    private func drawLightsPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = (t.truncatingRemainder(dividingBy: 6.0)) / 6.0
        let palette: [(Double, Double, Double)] = [
            (1.00, 0.78, 0.30), // warm amber
            (1.00, 0.42, 0.28), // sunset
            (0.22, 0.78, 0.98), // cyan
        ]
        let scaled = cycle * Double(palette.count)
        let idx = Int(scaled) % palette.count
        let nextIdx = (idx + 1) % palette.count
        let frac = scaled - floor(scaled)
        let c0 = palette[idx]
        let c1 = palette[nextIdx]
        let r = c0.0 + (c1.0 - c0.0) * frac
        let g = c0.1 + (c1.1 - c0.1) * frac
        let b = c0.2 + (c1.2 - c0.2) * frac
        let activeColor = Color(red: r, green: g, blue: b)
        let bri = 0.45 + 0.45 * (0.5 + 0.5 * sin(t * 1.9))

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.40)
        let glowR = CGFloat(24 + bri * 18)
        let grad = Gradient(stops: [
            .init(color: activeColor.opacity(0.65 * bri), location: 0.0),
            .init(color: activeColor.opacity(0.18 * bri), location: 0.55),
            .init(color: activeColor.opacity(0.0), location: 1.0),
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2)),
            with: .radialGradient(grad, center: center, startRadius: 2, endRadius: glowR)
        )

        // Bulb glass + filament cap
        let bulbR: CGFloat = 13
        let bulbRect = CGRect(x: center.x - bulbR, y: center.y - bulbR, width: bulbR * 2, height: bulbR * 2)
        ctx.fill(Path(ellipseIn: bulbRect), with: .color(activeColor))
        ctx.stroke(Path(ellipseIn: bulbRect), with: .color(Color.white.opacity(0.75)), lineWidth: 1.2)
        let baseRect = CGRect(x: center.x - 5.5, y: center.y + bulbR - 1, width: 11, height: 5)
        ctx.fill(Path(roundedRect: baseRect, cornerRadius: 2), with: .color(Color.white.opacity(0.65)))

        // Animated brightness bar
        let barRect = CGRect(x: 16, y: size.height - 17, width: size.width - 32, height: 6)
        ctx.fill(Path(roundedRect: barRect, cornerRadius: 3), with: .color(Color.white.opacity(0.16)))
        let fillW = max(8, barRect.width * CGFloat(bri))
        let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillW, height: barRect.height)
        ctx.fill(Path(roundedRect: fillRect, cornerRadius: 3), with: .color(activeColor))
        let knob = CGRect(x: barRect.minX + fillW - 4.5, y: barRect.midY - 4.5, width: 9, height: 9)
        ctx.fill(Path(ellipseIn: knob), with: .color(Color.white))
    }

    // MARK: - 2. Visual Floorplan Map

    private func drawFloorplanPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        // Subtle grid
        var grid = Path()
        for x in stride(from: CGFloat(12), to: size.width, by: 16) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat(12), to: size.height, by: 16) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(Color.white.opacity(0.06)), lineWidth: 0.6)

        // 2-room plan
        let leftRoom = CGRect(x: 10, y: 12, width: 56, height: 60)
        let rightRoom = CGRect(x: 66, y: 12, width: 48, height: 60)
        ctx.fill(Path(roundedRect: leftRoom, cornerRadius: 4), with: .color(Color(hex: "#ffd27a").opacity(0.10)))
        ctx.fill(Path(roundedRect: rightRoom, cornerRadius: 4), with: .color(Color(hex: "#38bdf8").opacity(0.08)))
        ctx.stroke(Path(roundedRect: leftRoom, cornerRadius: 4), with: .color(Color.white.opacity(0.32)), lineWidth: 1.2)
        ctx.stroke(Path(roundedRect: rightRoom, cornerRadius: 4), with: .color(Color.white.opacity(0.28)), lineWidth: 1.2)

        // Static right lamp
        let staticPt = CGPoint(x: 90, y: 44)
        let cyanHalo = Gradient(stops: [
            .init(color: Color(hex: "#38bdf8").opacity(0.45), location: 0.0),
            .init(color: Color(hex: "#38bdf8").opacity(0.0), location: 1.0),
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: staticPt.x - 16, y: staticPt.y - 16, width: 32, height: 32)),
            with: .radialGradient(cyanHalo, center: staticPt, startRadius: 2, endRadius: 16)
        )
        ctx.fill(Path(ellipseIn: CGRect(x: staticPt.x - 5.5, y: staticPt.y - 5.5, width: 11, height: 11)), with: .color(Color(hex: "#38bdf8")))

        // Gliding lamp in left room + hover name tooltip
        let glide = 0.5 + 0.5 * sin(t * 1.4)
        let lampPt = CGPoint(x: 26 + CGFloat(glide) * 24, y: 48 - CGFloat(sin(t * 2.8)) * 6)
        let warmHalo = Gradient(stops: [
            .init(color: Color(hex: "#ffb833").opacity(0.55), location: 0.0),
            .init(color: Color(hex: "#ffb833").opacity(0.0), location: 1.0),
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: lampPt.x - 20, y: lampPt.y - 20, width: 40, height: 40)),
            with: .radialGradient(warmHalo, center: lampPt, startRadius: 2, endRadius: 20)
        )
        ctx.fill(Path(ellipseIn: CGRect(x: lampPt.x - 6.5, y: lampPt.y - 6.5, width: 13, height: 13)), with: .color(Color(hex: "#ffb833")))
        ctx.stroke(Path(ellipseIn: CGRect(x: lampPt.x - 6.5, y: lampPt.y - 6.5, width: 13, height: 13)), with: .color(Color.white.opacity(0.9)), lineWidth: 1.2)

        // Floating tooltip capsule above gliding lamp
        let tipAlpha = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 1.4 - 0.5))
        let tipRect = CGRect(x: lampPt.x - 18, y: lampPt.y - 22, width: 36, height: 12)
        ctx.fill(Path(roundedRect: tipRect, cornerRadius: 6), with: .color(Color.white.opacity(0.88 * tipAlpha)))
        ctx.draw(
            Text("Lamp").font(.system(size: 7.5, weight: .semibold)).foregroundColor(Color.black.opacity(tipAlpha)),
            at: CGPoint(x: tipRect.midX, y: tipRect.midY)
        )
    }

    // MARK: - 3. Visual Rules

    private func drawRulesPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = t.truncatingRemainder(dividingBy: 3.0) / 3.0
        let drawProgress = min(1.0, cycle / 0.65)
        let targetLit = cycle >= 0.60

        let p0 = CGPoint(x: 24, y: 46)
        let p1 = CGPoint(x: size.width - 24, y: 38)
        let c1 = CGPoint(x: 56, y: 18)
        let c2 = CGPoint(x: size.width - 56, y: 66)

        var fullCurve = Path()
        fullCurve.move(to: p0)
        fullCurve.addCurve(to: p1, control1: c1, control2: c2)

        // Dim guide track
        ctx.stroke(fullCurve, with: .color(Color(hex: "#38d9c0").opacity(0.22)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))

        // Animated active stroke
        let activeCurve = fullCurve.trimmedPath(from: 0, to: CGFloat(drawProgress))
        ctx.stroke(activeCurve, with: .color(Color(hex: "#38d9c0")), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        // Travel pulse dot
        let mt = CGFloat(1.0 - drawProgress)
        let tt = CGFloat(drawProgress)
        let dotX = mt * mt * mt * p0.x + 3 * mt * mt * tt * c1.x + 3 * mt * tt * tt * c2.x + tt * tt * tt * p1.x
        let dotY = mt * mt * mt * p0.y + 3 * mt * mt * tt * c1.y + 3 * mt * tt * tt * c2.y + tt * tt * tt * p1.y
        ctx.fill(Path(ellipseIn: CGRect(x: dotX - 5, y: dotY - 5, width: 10, height: 10)), with: .color(Color(hex: "#38d9c0").opacity(0.4)))
        ctx.fill(Path(ellipseIn: CGRect(x: dotX - 2.5, y: dotY - 2.5, width: 5, height: 5)), with: .color(Color.white))

        // Source node (rounded square sensor/switch)
        let srcRect = CGRect(x: p0.x - 10, y: p0.y - 10, width: 20, height: 20)
        ctx.fill(Path(roundedRect: srcRect, cornerRadius: 5), with: .color(Color(hex: "#10b981")))
        ctx.stroke(Path(roundedRect: srcRect, cornerRadius: 5), with: .color(Color.white.opacity(0.85)), lineWidth: 1.2)

        // Target lamp node (lights up when pulse arrives)
        if targetLit {
            let halo = Gradient(stops: [
                .init(color: Color(hex: "#ffd27a").opacity(0.65), location: 0.0),
                .init(color: Color(hex: "#ffd27a").opacity(0.0), location: 1.0),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: p1.x - 22, y: p1.y - 22, width: 44, height: 44)),
                with: .radialGradient(halo, center: p1, startRadius: 3, endRadius: 22)
            )
        }
        let dstRect = CGRect(x: p1.x - 10, y: p1.y - 10, width: 20, height: 20)
        ctx.fill(Path(ellipseIn: dstRect), with: .color(targetLit ? Color(hex: "#ffd27a") : Color.white.opacity(0.16)))
        ctx.stroke(Path(ellipseIn: dstRect), with: .color(Color.white.opacity(targetLit ? 0.9 : 0.35)), lineWidth: 1.2)
    }

    // MARK: - 4. Bridge Pro MotionAware & Sensors

    private func drawMotionAwarePreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = t.truncatingRemainder(dividingBy: 3.2) / 3.2
        let presenceActive = cycle > 0.35 && cycle < 0.90

        // Mini room outline
        let room = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
        ctx.fill(
            Path(roundedRect: room, cornerRadius: 6),
            with: .color(presenceActive ? Color(hex: "#10b981").opacity(0.16) : Color(hex: "#06b6d4").opacity(0.07))
        )
        ctx.stroke(
            Path(roundedRect: room, cornerRadius: 6),
            with: .color(presenceActive ? Color(hex: "#10b981").opacity(0.65) : Color.white.opacity(0.25)),
            lineWidth: 1.2
        )

        let lamp1 = CGPoint(x: 38, y: 42)
        let lamp2 = CGPoint(x: 86, y: 42)
        let waveColor = presenceActive ? Color(hex: "#10b981") : Color(hex: "#06b6d4")

        // Expanding radar ripples from MotionAware lamps
        for i in 0..<2 {
            let phase = (t * 0.75 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.0)
            let radius = CGFloat(8.0 + phase * 24.0)
            let alpha = (1.0 - phase) * 0.75
            for pt in [lamp1, lamp2] {
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(waveColor.opacity(alpha)),
                    lineWidth: 1.4
                )
            }
        }

        // Lamp nodes with tiny radar badge
        for pt in [lamp1, lamp2] {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16)), with: .color(presenceActive ? Color(hex: "#ffd27a") : Color.white.opacity(0.25)))
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x + 3, y: pt.y - 10, width: 7, height: 7)), with: .color(waveColor))
        }

        // Physical sensor square node at bottom center
        let sensorRect = CGRect(x: size.width * 0.5 - 6, y: size.height - 23, width: 12, height: 12)
        ctx.fill(Path(roundedRect: sensorRect, cornerRadius: 3), with: .color(waveColor))
        ctx.stroke(Path(roundedRect: sensorRect, cornerRadius: 3), with: .color(Color.white.opacity(0.85)), lineWidth: 1)
    }

    // MARK: - 5. Schedules

    private func drawSchedulesPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = t.truncatingRemainder(dividingBy: 5.0) / 5.0
        let isNight = cycle > 0.5
        let arcProgress = isNight ? (cycle - 0.5) * 2.0 : cycle * 2.0
        let angle = Double.pi * (1.0 - arcProgress)

        // Subtle arc trajectory
        var arc = Path()
        let arcCenter = CGPoint(x: size.width * 0.5, y: 54)
        let arcR: CGFloat = 44
        arc.addArc(center: arcCenter, radius: arcR, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        ctx.stroke(arc, with: .color(Color.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // Sun or moon body along arc
        let orbX = arcCenter.x + CGFloat(cos(angle)) * arcR
        let orbY = arcCenter.y - CGFloat(sin(angle)) * arcR
        let orbColor = isNight ? Color(hex: "#a5b4fc") : Color(hex: "#fbbf24")
        ctx.fill(Path(ellipseIn: CGRect(x: orbX - 7, y: orbY - 7, width: 14, height: 14)), with: .color(orbColor))
        if isNight {
            // Crescent cutout
            ctx.fill(Path(ellipseIn: CGRect(x: orbX - 4, y: orbY - 8, width: 11, height: 11)), with: .color(Color(red: 0.08, green: 0.09, blue: 0.13)))
        }

        // Minimalist house silhouette
        var roof = Path()
        roof.move(to: CGPoint(x: 34, y: 52))
        roof.addLine(to: CGPoint(x: 62, y: 34))
        roof.addLine(to: CGPoint(x: 90, y: 52))
        roof.closeSubpath()
        ctx.fill(roof, with: .color(Color.white.opacity(0.18)))
        let body = CGRect(x: 40, y: 52, width: 44, height: 24)
        ctx.fill(Path(roundedRect: body, cornerRadius: 2), with: .color(Color.white.opacity(0.14)))

        // Glowing windows at dusk/night
        let winColor = isNight ? Color(hex: "#ffd27a") : Color.white.opacity(0.18)
        let w1 = CGRect(x: 47, y: 58, width: 11, height: 11)
        let w2 = CGRect(x: 66, y: 58, width: 11, height: 11)
        ctx.fill(Path(roundedRect: w1, cornerRadius: 2), with: .color(winColor))
        ctx.fill(Path(roundedRect: w2, cornerRadius: 2), with: .color(winColor))
    }

    // MARK: - 6. Audio Light Synth

    private func drawSynthPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let beatPhase = (t * 2.0).truncatingRemainder(dividingBy: 1.0)
        let beatFlash = max(0.0, 1.0 - beatPhase * 3.0)

        let bass = 0.25 + 0.70 * beatFlash
        let mids = 0.25 + 0.55 * (0.5 + 0.5 * sin(t * 5.2 + 1.0))
        let treble = 0.20 + 0.60 * (0.5 + 0.5 * sin(t * 7.8 + 2.3))

        // Beat pulse halo at top
        if beatFlash > 0.05 {
            let center = CGPoint(x: size.width * 0.5, y: 18)
            let r = CGFloat(6 + (1.0 - beatFlash) * 18)
            ctx.stroke(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r * 0.55, width: r * 2, height: r * 1.1)),
                with: .color(Color(hex: "#ff2e93").opacity(beatFlash * 0.85)),
                lineWidth: 1.6
            )
        }

        let bands: [(Double, Color)] = [
            (bass, Color(hex: "#ff2e93")),
            (mids, Color(hex: "#a855f7")),
            (treble, Color(hex: "#00f0ff")),
        ]
        let barW: CGFloat = 22
        let gap: CGFloat = 12
        let startX = (size.width - (barW * 3 + gap * 2)) / 2
        let baseY = size.height - 14
        let maxH: CGFloat = 46

        for (i, band) in bands.enumerated() {
            let h = max(8, CGFloat(band.0) * maxH)
            let x = startX + CGFloat(i) * (barW + gap)
            let rect = CGRect(x: x, y: baseY - h, width: barW, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(band.1))
            ctx.fill(
                Path(roundedRect: CGRect(x: x, y: baseY - h, width: barW, height: 3), cornerRadius: 1.5),
                with: .color(Color.white.opacity(0.65))
            )
        }
    }

    // MARK: - 7. Skins, Icons & Shortcuts

    private func drawSkinsPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let skins = AppSkin.allCases
        let idx = Int((t / 1.4).rounded(.down)) % max(1, skins.count)
        let skin = skins[idx]
        let bg = Color(hex: skin.previewBackgroundHex)
        let accent = Color(hex: skin.accentHex ?? "#0a84ff")
        let secondary = Color(hex: skin.secondaryHex)

        // Mini app card
        let card = CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24)
        ctx.fill(Path(roundedRect: card, cornerRadius: 8), with: .color(bg))
        ctx.stroke(Path(roundedRect: card, cornerRadius: 8), with: .color(accent.opacity(0.75)), lineWidth: 1.4)

        // Accent header dots
        ctx.fill(Path(ellipseIn: CGRect(x: 22, y: 22, width: 10, height: 10)), with: .color(accent))
        ctx.fill(Path(ellipseIn: CGRect(x: 36, y: 22, width: 10, height: 10)), with: .color(secondary))

        // Mini room bars
        ctx.fill(Path(roundedRect: CGRect(x: 22, y: 39, width: 52, height: 7), cornerRadius: 3.5), with: .color(Color.white.opacity(0.22)))
        ctx.fill(Path(roundedRect: CGRect(x: 22, y: 50, width: 38, height: 7), cornerRadius: 3.5), with: .color(accent.opacity(0.45)))

        // Keycap shortcut badge
        let keyRect = CGRect(x: size.width - 52, y: size.height - 32, width: 34, height: 16)
        ctx.fill(Path(roundedRect: keyRect, cornerRadius: 4), with: .color(Color.white.opacity(0.16)))
        ctx.stroke(Path(roundedRect: keyRect, cornerRadius: 4), with: .color(Color.white.opacity(0.45)), lineWidth: 0.9)
        ctx.draw(
            Text("⌃⌥0").font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundColor(Color.white),
            at: CGPoint(x: keyRect.midX, y: keyRect.midY)
        )
    }

    // MARK: - 8. Ask AI (Optional)

    private func drawAskAIPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = t.truncatingRemainder(dividingBy: 3.4) / 3.4
        let pulse = 0.5 + 0.5 * sin(t * 3.0)
        let roomLit = cycle > 0.48

        // Glowing 4-point sparkle on left
        let sparkCenter = CGPoint(x: 24, y: 30)
        let sparkHaloR = CGFloat(14 + pulse * 6)
        let sparkGrad = Gradient(stops: [
            .init(color: Color(hex: "#a855f7").opacity(0.60), location: 0.0),
            .init(color: Color(hex: "#38bdf8").opacity(0.18), location: 0.55),
            .init(color: Color.clear, location: 1.0),
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: sparkCenter.x - sparkHaloR, y: sparkCenter.y - sparkHaloR, width: sparkHaloR * 2, height: sparkHaloR * 2)),
            with: .radialGradient(sparkGrad, center: sparkCenter, startRadius: 1, endRadius: sparkHaloR)
        )

        var star = Path()
        let outerR: CGFloat = 9.0 + CGFloat(pulse) * 2.0
        let innerR: CGFloat = 3.2
        for i in 0..<8 {
            let angle = Double(i) * Double.pi / 4.0
            let r = (i % 2 == 0) ? outerR : innerR
            let pt = CGPoint(x: sparkCenter.x + CGFloat(cos(angle)) * r, y: sparkCenter.y + CGFloat(sin(angle)) * r)
            if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
        }
        star.closeSubpath()
        ctx.fill(star, with: .color(Color(hex: "#e9d5ff")))

        // Animated chat command wave travelling toward room card
        let waveProgress = min(1.0, cycle / 0.55)
        for idx in 0..<3 {
            let y = CGFloat(24 + idx * 10)
            let maxW: CGFloat = idx == 1 ? 30 : 22
            let w = max(6, maxW * CGFloat(max(0.25, sin(t * 2.6 - Double(idx) * 0.7) * 0.5 + 0.5)))
            let bar = CGRect(x: 42, y: y, width: w, height: 4.5)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 2.2), with: .color(Color(hex: "#38bdf8").opacity(0.75)))
        }

        // Traveling command spark
        let sparkX = 42 + CGFloat(waveProgress) * 44
        let sparkY: CGFloat = 36 - CGFloat(sin(waveProgress * Double.pi)) * 8
        ctx.fill(Path(ellipseIn: CGRect(x: sparkX - 3, y: sparkY - 3, width: 6, height: 6)), with: .color(Color(hex: "#ffd27a")))

        // Target mini room & glowing lamp on right
        let roomRect = CGRect(x: size.width - 42, y: 16, width: 32, height: 38)
        ctx.fill(
            Path(roundedRect: roomRect, cornerRadius: 6),
            with: .color(roomLit ? Color(hex: "#ffd27a").opacity(0.22) : Color.white.opacity(0.08))
        )
        ctx.stroke(
            Path(roundedRect: roomRect, cornerRadius: 6),
            with: .color(roomLit ? Color(hex: "#ffd27a").opacity(0.85) : Color.white.opacity(0.28)),
            lineWidth: 1.2
        )
        let lampCenter = CGPoint(x: roomRect.midX, y: roomRect.midY)
        if roomLit {
            let glow = Gradient(stops: [
                .init(color: Color(hex: "#ffd27a").opacity(0.65), location: 0.0),
                .init(color: Color.clear, location: 1.0),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: lampCenter.x - 16, y: lampCenter.y - 16, width: 32, height: 32)),
                with: .radialGradient(glow, center: lampCenter, startRadius: 2, endRadius: 16)
            )
        }
        ctx.fill(
            Path(ellipseIn: CGRect(x: lampCenter.x - 6, y: lampCenter.y - 6, width: 12, height: 12)),
            with: .color(roomLit ? Color(hex: "#ffd27a") : Color.white.opacity(0.22))
        )

        // Bottom prompt pill
        let pill = CGRect(x: 12, y: size.height - 20, width: size.width - 24, height: 12)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 6), with: .color(Color.white.opacity(0.10)))
        ctx.draw(
            Text("40% warm · Local").font(.system(size: 7.5, weight: .medium, design: .rounded)).foregroundColor(Color.white.opacity(0.82)),
            at: CGPoint(x: pill.midX, y: pill.midY)
        )
    }

    // MARK: - 9. MCP Server for AI Agents

    private func drawMCPPreview(in ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let cycle = t.truncatingRemainder(dividingBy: 2.6) / 2.6

        // Left: AI agent / terminal node
        let termRect = CGRect(x: 10, y: 20, width: 32, height: 42)
        ctx.fill(Path(roundedRect: termRect, cornerRadius: 6), with: .color(Color(hex: "#111827")))
        ctx.stroke(Path(roundedRect: termRect, cornerRadius: 6), with: .color(Color(hex: "#38d9c0").opacity(0.85)), lineWidth: 1.2)
        ctx.draw(
            Text("MCP").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(Color(hex: "#38d9c0")),
            at: CGPoint(x: termRect.midX, y: termRect.minY + 14)
        )
        ctx.draw(
            Text(">_").font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundColor(Color.white.opacity(0.75)),
            at: CGPoint(x: termRect.midX, y: termRect.minY + 29)
        )

        // Middle: Local Hue Bridge hub
        let hubCenter = CGPoint(x: size.width * 0.54, y: size.height * 0.50)
        let hubRect = CGRect(x: hubCenter.x - 12, y: hubCenter.y - 12, width: 24, height: 24)
        ctx.fill(Path(roundedRect: hubRect, cornerRadius: 6), with: .color(Color(hex: "#1e293b")))
        ctx.stroke(Path(roundedRect: hubRect, cornerRadius: 6), with: .color(Color(hex: "#38bdf8").opacity(0.8)), lineWidth: 1.2)
        ctx.fill(Path(ellipseIn: CGRect(x: hubCenter.x - 3.5, y: hubCenter.y - 3.5, width: 7, height: 7)), with: .color(Color(hex: "#38bdf8")))

        // Line from terminal to bridge hub + animated packet
        let linkStart = CGPoint(x: termRect.maxX, y: hubCenter.y)
        let linkEnd = CGPoint(x: hubRect.minX, y: hubCenter.y)
        var inLine = Path()
        inLine.move(to: linkStart)
        inLine.addLine(to: linkEnd)
        ctx.stroke(inLine, with: .color(Color(hex: "#38d9c0").opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))

        let p1 = min(1.0, cycle * 2.0)
        let pkt1X = linkStart.x + (linkEnd.x - linkStart.x) * CGFloat(p1)
        ctx.fill(Path(ellipseIn: CGRect(x: pkt1X - 2.8, y: hubCenter.y - 2.8, width: 5.6, height: 5.6)), with: .color(Color(hex: "#38d9c0")))

        // Right: 3 lamp nodes wired from bridge hub
        let lamps: [(CGPoint, Color)] = [
            (CGPoint(x: size.width - 18, y: 20), Color(hex: "#ffd27a")),
            (CGPoint(x: size.width - 18, y: 42), Color(hex: "#ff6b9d")),
            (CGPoint(x: size.width - 18, y: 64), Color(hex: "#38bdf8")),
        ]
        let p2 = max(0.0, (cycle - 0.45) / 0.55)
        let lampsLit = cycle > 0.55

        for (pt, color) in lamps {
            var branch = Path()
            branch.move(to: CGPoint(x: hubRect.maxX, y: hubCenter.y))
            branch.addLine(to: pt)
            ctx.stroke(branch, with: .color(color.opacity(0.4)), lineWidth: 1.2)

            if cycle >= 0.45 {
                let bx = hubRect.maxX + (pt.x - hubRect.maxX) * CGFloat(min(1.0, p2))
                let by = hubCenter.y + (pt.y - hubCenter.y) * CGFloat(min(1.0, p2))
                ctx.fill(Path(ellipseIn: CGRect(x: bx - 2.2, y: by - 2.2, width: 4.4, height: 4.4)), with: .color(Color.white))
            }

            if lampsLit {
                let halo = Gradient(stops: [
                    .init(color: color.opacity(0.55), location: 0.0),
                    .init(color: Color.clear, location: 1.0),
                ])
                ctx.fill(
                    Path(ellipseIn: CGRect(x: pt.x - 11, y: pt.y - 11, width: 22, height: 22)),
                    with: .radialGradient(halo, center: pt, startRadius: 1, endRadius: 11)
                )
            }
            ctx.fill(
                Path(ellipseIn: CGRect(x: pt.x - 5.5, y: pt.y - 5.5, width: 11, height: 11)),
                with: .color(lampsLit ? color : Color.white.opacity(0.22))
            )
        }
    }
}
