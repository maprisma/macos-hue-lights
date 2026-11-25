import AppKit
import HueCore
import SwiftUI

/// Root view for the resizable, movable Maprisma Lights desktop window.
struct ContentView: View {
    enum DisplayMode { case detached }

    @EnvironmentObject var store: HueStore
    @Environment(\.openWindow) private var openWindow
    var mode: DisplayMode = .detached

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(mode: mode)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if store.page == .main && store.snapshot.isPaired {
                TabBarView()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Divider()
            Group {
                switch store.page {
                case .settings:
                    SettingsView()
                case .help:
                    HelpView(onTryFeature: { feature in
                        handleTryHelpFeature(feature)
                    })
                case .main:
                    MainView(mode: mode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .modifier(WindowSizeModifier(mode: mode))
        .background(WindowBackdropView())
        .tint(store.skinAccentColor)
        .fontDesign(store.fontDesign)
        .preferredColorScheme(store.preferredColorScheme)
        .sheet(item: $store.themeEditorLight) { light in
            LightThemesSheet(light: light)
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: $store.showAskAISheet) {
            if store.askAIEnabled {
                AskAIView()
                    .environmentObject(store)
                    .tint(store.skinAccentColor)
                    .fontDesign(store.fontDesign)
                    .preferredColorScheme(store.preferredColorScheme)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { store.showAskAISheet = false }
            }
        }
        .sheet(isPresented: $store.showAddProviderSheet) {
            AddProviderSheet(editing: store.editingProvider, preselectedKind: store.preselectedProviderKind)
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .fontDesign(store.fontDesign)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: $store.showPairHueSheet) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(store.tr("Close")) { store.showPairHueSheet = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                ScrollView {
                    PairingView()
                        .padding(16)
                }
            }
            .frame(minWidth: 380, idealWidth: 440, maxWidth: 560, minHeight: 380, idealHeight: 500, maxHeight: 680)
            .environmentObject(store)
            .tint(store.skinAccentColor)
            .fontDesign(store.fontDesign)
            .preferredColorScheme(store.preferredColorScheme)
            .onChange(of: store.snapshot.hueBridgePaired) { paired in
                if paired { store.showPairHueSheet = false }
            }
        }
        .background(
            WindowObserver(
                mode: mode,
                savedFrame: store.savedWindowFrame(),
                preferredColorScheme: store.preferredColorScheme,
                onChange: { open in store.setPanel(open: open) },
                onFrameChange: { frame in store.saveWindowFrame(frame) }
            )
        )
        .onAppear {
            AppDelegate.shared?.openMainWindowAction = { openWindow(id: "main-window") }
            store.setPanel(open: true)
        }
        .onDisappear { store.setPanel(open: false) }
    }

    private func handleTryHelpFeature(_ feature: HelpFeature) {
        switch feature {
        case .lights:
            store.page = .main
            store.tab = .lights
        case .floorplan:
            store.page = .main
            store.tab = .map
            store.pendingMapMode = "map"
        case .rules:
            store.openMapInRulesMode()
        case .motionAware:
            store.page = .main
            store.tab = .map
            store.pendingMapMode = "map"
        case .schedules:
            store.page = .main
            store.tab = .schedules
        case .synth:
            store.page = .main
            store.tab = .synth
        case .skins:
            store.page = .settings
        case .askAI:
            if store.askAIEnabled {
                store.page = .main
                store.showAskAISheet = true
            } else {
                store.page = .settings
            }
        case .mcpServer:
            store.page = .settings
        }
    }
}

private struct WindowBackdropView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        ZStack {
            store.windowBackground
            if store.skin == .synthwave {
                LinearGradient(
                    colors: [Color(hex: "#ff2e93").opacity(0.16), Color.clear, Color(hex: "#00f0ff").opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if store.skin == .discoLava {
                LinearGradient(
                    colors: [Color(hex: "#ff5e7e").opacity(0.18), Color(hex: "#a855f7").opacity(0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if store.skin == .cozyCabin {
                LinearGradient(
                    colors: [Color(hex: "#e59838").opacity(0.12), Color(hex: "#a45a2a").opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if store.skin == .retroTerminal {
                LinearGradient(
                    colors: [Color(hex: "#33ff66").opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else if store.skin == .minimalZen {
                LinearGradient(
                    colors: [Color(hex: "#94a3b8").opacity(0.10), Color(hex: "#64748b").opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

private struct WindowSizeModifier: ViewModifier {
    let mode: ContentView.DisplayMode

    func body(content: Content) -> some View {
        content.frame(
            minWidth: 460,
            idealWidth: 840,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: 660,
            maxHeight: .infinity
        )
    }
}

struct HeaderView: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.openWindow) private var openWindow
    let mode: ContentView.DisplayMode

    var body: some View {
        let s = store.snapshot
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(s.anyLightOn ? store.skinAccentColor.opacity(0.20) : Color.primary.opacity(0.06))
                Image(systemName: store.menuBarIcon.symbol(lit: s.anyLightOn))
                    .font(store.scaledFont(16, weight: .semibold))
                    .foregroundStyle(s.anyLightOn ? store.skinAccentColor : Color.secondary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.tr("Maprisma Lights"))
                        .font(store.scaledFont(13.5, weight: .semibold))
                        .lineLimit(1)
                    if s.isDemo {
                        Menu {
                            Button {
                                store.exitDemoMode()
                            } label: {
                                Label(store.tr("Connect Bridge"), systemImage: "wifi.router")
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(store.tr("Demo"))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7.5, weight: .bold))
                            }
                            .font(store.scaledFont(10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(store.skinAccentColor)
                            .background(Capsule().fill(store.skinAccentColor.opacity(0.15)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(store.tr("Demo Mode"))
                    }
                }
                Text(s.isPaired ? (s.bridge?.text ?? "Hue Bridge") : store.tr("No bridge paired"))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if s.phase == "ok" {
                Text(store.trf("{0} of {1} on", [String(s.onCount), String(s.lightCount)]))
                    .font(store.scaledFont(11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if store.askAIEnabled {
                Button {
                    store.showAskAISheet = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13.5))
                        .foregroundStyle(store.skinAccentColor)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel(store.tr("Ask AI (⌘K)"))
                .help(store.tr("Ask AI (⌘K)"))
            }

            Button {
                store.page = store.page == .help ? .main : .help
            } label: {
                Image(systemName: store.page == .help ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.tr("Help & Guide"))
            .help(store.tr("Help & Guide"))

            Button {
                store.page = store.page == .settings ? .main : .settings
            } label: {
                Image(systemName: store.page == .settings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.tr("Settings"))
            .help(store.tr("Settings"))
        }
    }
}

struct TabBarView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 520
            HStack(spacing: compact ? 2 : 4) {
                tabButton(.lights, title: store.tr("Lights"), symbol: "lightbulb", badge: nil, activeDot: false, compact: compact)
                tabButton(.map, title: store.tr("Map"), symbol: "map", badge: nil,
                          activeDot: store.pendingFloorplanSyncPlan.hasRoomOrMetaChanges, compact: compact)
                tabButton(.schedules, title: store.tr("Schedules"), symbol: "clock",
                          badge: store.allSchedules.isEmpty ? nil : store.allSchedules.count, activeDot: false, compact: compact)
                tabButton(.rules, title: store.tr("Rules"), symbol: "link",
                          badge: store.rules.isEmpty ? nil : store.rules.count, activeDot: false, compact: compact)
                tabButton(.synth, title: store.tr("Synth"), symbol: "waveform", badge: nil,
                          activeDot: store.synthRunning, compact: compact)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: store.smallRadius + 2, style: .continuous)
                    .fill(store.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: store.smallRadius + 2, style: .continuous)
                    .strokeBorder(store.cardBorderColor, lineWidth: 0.75)
            )
        }
        .frame(height: 32)
    }

    private func tabButton(_ tab: HueStore.MainTab, title: String, symbol: String, badge: Int?, activeDot: Bool, compact: Bool) -> some View {
        let selected = store.tab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { store.tab = tab }
        } label: {
            HStack(spacing: compact ? 3 : 4) {
                if !compact {
                    Image(systemName: symbol)
                        .font(store.scaledFont(10.5, weight: .medium))
                }
                Text(title)
                    .font(store.scaledFont(compact ? 11 : 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let badge = badge {
                    Text("\(badge)")
                        .font(store.scaledFont(9.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1)))
                }
                if activeDot {
                    Circle()
                        .fill(selected ? Color.white : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                    .fill(selected ? store.skinAccentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

struct MainView: View {
    @EnvironmentObject var store: HueStore
    var mode: ContentView.DisplayMode = .detached

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                ProblemBanner(text: problem)
            }
            if store.snapshot.isPaired {
                switch store.tab {
                case .lights:
                    RoomsView()
                    Divider()
                    FooterView()
                case .map:
                    MapView()
                case .schedules:
                    SchedulesView()
                case .rules:
                    RulesView()
                case .synth:
                    SynthView()
                }
            } else {
                ScrollView {
                    PairingView()
                        .frame(maxWidth: 740)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
            }
        }
    }
}

struct ProblemBanner: View {
    @EnvironmentObject var store: HueStore
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(text)
                .font(store.scaledFont(11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct FooterView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let allOnDisabled = store.snapshot.lightCount == 0
        HStack(spacing: 8) {
            Button {
                store.allOn()
            } label: {
                Label(store.tr("All lights on"), systemImage: "sun.max.fill")
                    .font(store.scaledFont(12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .disabled(allOnDisabled)
            .accessibilityLabel(store.tr("All lights on"))
            .help(store.tr("Switch every light on"))
            .popover(isPresented: $store.confirmAllOnPrompt, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.tr("Turn all lights on?"))
                        .font(store.scaledFont(13, weight: .semibold))
                    if !store.excludedFromAllOn.isEmpty {
                        Text(store.trf("{0} room(s) excluded from All On.", [String(store.excludedFromAllOn.count)]))
                            .font(store.scaledFont(11))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(store.tr("Cancel")) { store.confirmAllOnPrompt = false }
                        Spacer()
                        Button(store.tr("Turn on")) { store.allOn(confirmed: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .frame(width: 240)
                .fontDesign(store.fontDesign)
            }

            Button {
                store.allOff()
            } label: {
                Label(store.tr("All lights off"), systemImage: "power")
                    .font(store.scaledFont(12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.red)
            .disabled(!store.snapshot.anyLightOn)
            .accessibilityLabel(store.tr("All lights off"))
            .help(store.tr("Switch every light off"))

            Spacer()

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.tr("Refresh"))
            .help(store.tr("Refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Tells the store when the window becomes key (shown) or resigns key (closed), and
/// restores/saves size and screen position for the detached resizable window.
struct WindowObserver: NSViewRepresentable {
    let mode: ContentView.DisplayMode
    let savedFrame: SavedWindowFrame?
    let preferredColorScheme: ColorScheme?
    let onChange: (Bool) -> Void
    let onFrameChange: ((SavedWindowFrame) -> Void)?

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.mode = mode
        view.savedFrame = savedFrame
        view.preferredColorScheme = preferredColorScheme
        view.onChange = onChange
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.mode = mode
        nsView.preferredColorScheme = preferredColorScheme
        nsView.onChange = onChange
        nsView.onFrameChange = onFrameChange
        nsView.applyWindowAppearance()
    }

    final class ObserverView: NSView {
        var mode: ContentView.DisplayMode = .detached
        var savedFrame: SavedWindowFrame?
        var preferredColorScheme: ColorScheme?
        var onChange: ((Bool) -> Void)?
        var onFrameChange: ((SavedWindowFrame) -> Void)?
        private weak var observed: NSWindow?
        private var restoredWindow = false
        private var saveWorkItem: DispatchWorkItem?

        func applyWindowAppearance() {
            guard let window = observed ?? self.window else { return }
            let target: NSAppearance?
            switch preferredColorScheme {
            case .dark:
                target = NSAppearance(named: .darkAqua)
            case .light:
                target = NSAppearance(named: .aqua)
            case nil:
                target = nil
            @unknown default:
                target = nil
            }
            if window.appearance != target {
                window.appearance = target
            }
        }

        deinit {
            saveWorkItem?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let old = observed {
                center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: old)
                center.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: old)
                center.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: old)
                center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
                center.removeObserver(self, name: NSWindow.didResizeNotification, object: old)
                center.removeObserver(self, name: NSWindow.didMoveNotification, object: old)
                center.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            }
            center.removeObserver(self, name: NSApplication.willTerminateNotification, object: nil)
            observed = window
            guard let window = window else { return }
            applyWindowAppearance()
            window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovable = true
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 460, height: 460)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.isRestorable = false
            window.setFrameAutosaveName("")

            center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                               name: NSWindow.didMiniaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                               name: NSWindow.didDeminiaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.addObserver(self, selector: #selector(frameChanged(_:)),
                               name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(frameChanged(_:)),
                               name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(willClose(_:)),
                               name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(willClose(_:)),
                               name: NSApplication.willTerminateNotification, object: nil)

            if !restoredWindow, let saved = savedFrame {
                restoredWindow = true
                let screens = NSScreen.screens.map { s in
                    let vf = s.visibleFrame
                    return SavedWindowFrame(
                        x: Double(vf.origin.x),
                        y: Double(vf.origin.y),
                        width: Double(vf.size.width),
                        height: Double(vf.size.height)
                    )
                }
                let clamped = saved.clamped(to: screens, minWidth: 460, minHeight: 460)
                let rect = NSRect(x: clamped.x, y: clamped.y, width: clamped.width, height: clamped.height)
                window.setFrame(rect, display: true)
            }
            notifyVisibility(for: window)
        }

        private func notifyVisibility(for window: NSWindow) {
            let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            Task { @MainActor [weak self] in self?.onChange?(visible) }
        }

        @objc private func visibilityChanged(_ note: Notification) {
            guard let window = observed else { return }
            notifyVisibility(for: window)
        }

        @objc private func frameChanged(_ note: Notification) {
            guard let window = observed else { return }
            let f = window.frame
            let snapshot = SavedWindowFrame(
                x: Double(f.origin.x),
                y: Double(f.origin.y),
                width: Double(f.size.width),
                height: Double(f.size.height)
            )
            saveWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.onFrameChange?(snapshot)
            }
            saveWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }

        @objc private func willClose(_ note: Notification) {
            guard let window = observed else { return }
            onChange?(false)
            saveWorkItem?.cancel()
            saveWorkItem = nil
            let f = window.frame
            onFrameChange?(SavedWindowFrame(
                x: Double(f.origin.x),
                y: Double(f.origin.y),
                width: Double(f.size.width),
                height: Double(f.size.height)
            ))
        }
    }
}

extension Color {
    /// "#rrggbb" from the bridge; anything else is warm white.
    init(hex: String) {
        let c = rgb(hex)
        self.init(red: c.r, green: c.g, blue: c.b)
    }
}
