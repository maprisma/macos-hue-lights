import AppKit
import Combine
import HueCore
import ServiceManagement
import SwiftUI

/// Central UI state and action coordinator for Maprisma Hue Lights.
/// Drives either `NativeHueBridgeClient` (real Philips Hue Bridge via pinned HTTPS + Bonjour + SSE)
/// or `DemoBridgeClient` (interactive preview for App Store Review & hardware-free trials).
@MainActor
final class HueStore: ObservableObject {
    static let shared = HueStore()

    enum Page { case main, settings, help }
    enum MainTab: String, CaseIterable, Identifiable {
        case lights, map, schedules, rules, synth
        var id: String { rawValue }
    }
    enum RoomFilter: String, CaseIterable, Identifiable {
        case all, on, rooms, zones, favorites
        var id: String { rawValue }
    }

    @Published private(set) var snapshot = HueSnapshot.initial
    @Published private(set) var l10n: L10n
    @Published private(set) var dragging: [String: Double] = [:]
    @Published var expanded: Set<String> = []
    @Published var allScenes: Set<String> = []
    @Published var page: Page = .main
    @Published var tab: MainTab = .lights
    @Published var filter: RoomFilter = .all
    @Published var searchText: String = ""
    @Published var manualIP: String = ""
    @Published var confirmUnpair: Bool = false
    @Published var confirmAllOnPrompt: Bool = false
    @Published private(set) var languageError: Bool = false

    // Persisted preferences
    @Published private(set) var favorites: Set<String>
    @Published private(set) var excludedFromAllOn: Set<String>
    @Published private(set) var confirmAllOn: Bool
    @Published private(set) var scheduleMode: ScheduleMode
    @Published private(set) var appearance: AppearanceSettings
    @Published private(set) var skin: AppSkin
    @Published private(set) var menuBarIcon: MenuBarIconStyle
    @Published private(set) var showMenuBarCount: Bool
    @Published private(set) var hotKeys: [HotKeyAction: HotKeyPreset]
    @Published private(set) var customThemes: [HueLightTheme]
    @Published private(set) var rules: [HueRule]
    @Published private(set) var rulesPaused: Bool
    @Published private(set) var localSchedules: [HueSchedule]
    @Published private(set) var askAIEnabled: Bool
    @Published private(set) var askAIOllamaURL: String
    @Published private(set) var askAIModel: String

    // Launch at Login (SMAppService, macOS 13+)
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    // Quick-create & editor sheets
    @Published var showNewScheduleSheet: Bool = false
    @Published var schedulePrefillTarget: (kind: String, id: String)?
    @Published var showNewRuleSheet: Bool = false
    @Published var rulePrefillTrigger: (kind: String, id: String)?
    @Published var themeEditorLight: HueLight?
    @Published var showAskAISheet: Bool = false
    @Published var showProUpgradeSheet: Bool = false
    @Published var showAddProviderSheet: Bool = false
    @Published var editingProvider: ProviderConnection? = nil
    @Published var preselectedProviderKind: LightProviderKind? = nil
    @Published var showPairHueSheet: Bool = false

    // Multi-Device Providers (Home Assistant, WLED, WiZ, LIFX, Govee, Nanoleaf, Shelly, IKEA DIRIGERA)
    @Published private(set) var providerConnections: [ProviderConnection] = []
    @Published private(set) var discoveredProviders: [DiscoveredProviderDevice] = []
    @Published private(set) var discoveringProviders: Bool = false

    // Visual Floorplan & Spatial Light Studio
    @Published var floorplan: FloorplanDocument = FloorplanDocument()
    @Published var lastUndoFloorplan: FloorplanDocument? = nil
    @Published private(set) var floorplanBackgroundImage: NSImage? = nil
    @Published private(set) var floorplanSyncing: Bool = false
    @Published var floorplanStatusMessage: String? = nil
    @Published var floorplanBackgroundError: String? = nil
    @Published var dismissedFloorplanDiffKey: String = ""
    @Published var motionAwareHintDismissed: Bool = false
    @Published var pendingMapMode: String? = nil
    @Published var pendingMapWireLightID: String? = nil
    @Published private(set) var lastFiredRuleID: String? = nil
    @Published private(set) var lastFiredRuleAt: Date = .distantPast
    private var floorplanLoadedForBridgeID: String = ""
    private var lastRuleLogID: String = ""

    // Audio-Reactive Light Synthesizer
    @Published private(set) var synthRunning: Bool = false
    @Published var synthSource: AudioCaptureSource = .systemAudio
    @Published var synthMode: SynthMode = .pulse
    @Published var synthPalette: SynthPalette = .neon
    @Published var synthSensitivity: Double = 1.25
    @Published var synthSmoothness: Double = 0.45
    @Published var synthTargetRoomID: String = ""
    @Published var synthEntertainmentAreaID: String = ""
    @Published private(set) var synthLightBands: [String: SynthBand] = [:]
    @Published private(set) var synthLevels: AudioBandLevels = .zero
    @Published private(set) var synthUsingEntertainment: Bool = false
    @Published private(set) var synthPermissionIssue: (kind: AudioPermissionKind, message: String)?

    private let settings = SettingsStore()
    private let catalogs: L10n.Catalogs
    private let localScheduler = LocalScheduler()
    private let audioCapture = AudioCaptureManager()
    private let synthMapper = SynthFrameMapper()
    private let entertainmentStreamer = EntertainmentStreamer()
    private let hotKeyManager = GlobalHotKeyManager()
    private var client: HueBridgeControlling
    private var multiClient: MultiProviderBridgeClient?
    private var debouncer: BrightnessDebouncer?
    private var localScheduleTask: Task<Void, Never>?
    private var synthPhase: Double = 0.0
    private var lastSynthOutputTime: Date = .distantPast
    private var activeEntertainmentAreaID: String?
    private var cachedWindowFrame: SavedWindowFrame?
    private(set) var panelOpen = false

    init() {
        let locator = ResourceLocator()
        let loaded = L10n.loadCatalogs(from: locator.translations)
        catalogs = loaded
        l10n = L10n(catalogs: loaded, setting: settings.language())

        favorites = Set(settings.favorites())
        excludedFromAllOn = Set(settings.excludedFromAllOn())
        confirmAllOn = settings.confirmAllOn()
        scheduleMode = settings.scheduleMode()
        appearance = settings.appearance()
        skin = settings.skin()
        menuBarIcon = settings.menuBarIcon()
        showMenuBarCount = settings.showMenuBarCount()
        hotKeys = settings.hotKeys()
        customThemes = settings.loadCustomThemes()
        let savedRules = settings.loadRules()
        let savedPaused = settings.rulesPaused()
        rules = savedRules
        rulesPaused = savedPaused
        localSchedules = settings.loadLocalSchedules()
        askAIEnabled = settings.askAIEnabled()
        askAIOllamaURL = settings.askAIOllamaURL()
        askAIModel = settings.askAIModel()
        cachedWindowFrame = settings.windowFrame()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        let multi = MultiProviderBridgeClient(settings: settings, rules: savedRules, rulesPaused: savedPaused)
        client = multi
        multiClient = multi
        providerConnections = multi.connections

        debouncer = BrightnessDebouncer(interval: 0.15, send: { [weak self] target, value in
            Task { @MainActor [weak self] in
                self?.sendBrightness(target, value)
            }
        })

        audioCapture.onLevels = { [weak self] levels in
            self?.handleSynthLevels(levels)
        }
        audioCapture.onPermissionError = { [weak self] kind, message in
            self?.synthPermissionIssue = (kind, message)
            self?.stopSynth()
        }
        audioCapture.onStreamStopped = { [weak self] _ in
            self?.stopSynth()
        }
        hotKeyManager.onAction = { [weak self] action in
            self?.handleHotKeyAction(action)
        }

        attachClient(multi)
    }

    private func attachClient(_ newClient: HueBridgeControlling) {
        client = newClient
        multiClient = newClient as? MultiProviderBridgeClient
        client.onSnapshot = { [weak self] snapshot in
            self?.receive(snapshot)
        }
        multiClient?.onProvidersChanged = { [weak self] conns, discovered, scanning in
            self?.providerConnections = conns
            self?.discoveredProviders = discovered
            self?.discoveringProviders = scanning
        }
    }

    // MARK: - Lifecycle

    func start() {
        client.start()
        hotKeyManager.update(bindings: hotKeys)
        startLocalScheduleLoop()
    }

    func shutdown() {
        stopSynth()
        hotKeyManager.unregisterAll()
        localScheduleTask?.cancel()
        localScheduleTask = nil
        client.stop()
    }

    func setPanel(open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        client.setPanelOpen(open)
        if !open {
            confirmUnpair = false
            confirmAllOnPrompt = false
        }
    }

    private func receive(_ new: HueSnapshot) {
        if !new.isPaired {
            confirmUnpair = false
            confirmAllOnPrompt = false
            if synthRunning { stopSynth() }
        }
        snapshot = new
        if new.isDemo {
            rules = new.rules
            rulesPaused = new.rulesPaused
        }
        if let latest = new.ruleLog.first, latest.id != lastRuleLogID {
            lastRuleLogID = latest.id
            lastFiredRuleID = latest.ruleID
            lastFiredRuleAt = Date()
        }
        if new.isPaired && new.phase == "ok" {
            ensureFloorplanLoaded(for: new)
        }
    }

    // MARK: - Demo Mode & Free Access Fallbacks

    var isDemoMode: Bool { snapshot.isDemo }

    func enterDemoMode(keepingTab: MainTab? = nil) {
        stopSynth()
        client.stop()
        expanded.removeAll()
        allScenes.removeAll()
        motionAwareHintDismissed = false
        pendingMapMode = nil
        pendingMapWireLightID = nil
        filter = .all
        searchText = ""
        synthSource = .demoBeat
        synthTargetRoomID = ""
        synthEntertainmentAreaID = ""
        let demo = DemoBridgeClient()
        attachClient(demo)
        rules = demo.currentRules
        rulesPaused = false
        demo.start()
        page = .main
        tab = keepingTab ?? .lights
    }

    func exitDemoMode() {
        guard snapshot.isDemo else { return }
        stopSynth()
        client.stop()
        expanded.removeAll()
        allScenes.removeAll()
        motionAwareHintDismissed = false
        pendingMapMode = nil
        pendingMapWireLightID = nil
        synthSource = .systemAudio
        let savedRules = settings.loadRules()
        let savedPaused = settings.rulesPaused()
        rules = savedRules
        rulesPaused = savedPaused
        let multi = MultiProviderBridgeClient(settings: settings, rules: savedRules, rulesPaused: savedPaused)
        attachClient(multi)
        providerConnections = multi.connections
        multi.start()
        page = .main
        tab = .lights
    }

    /// Ensures Free mode on a real Hue Bridge falls back cleanly to the free native skin
    /// and stops Pro-only live sessions (e.g. after leaving Demo Mode without a Pro unlock).
    func enforceFreeAccessFallbacks(isProUnlocked: Bool) {
        guard !isProUnlocked && !isDemoMode else { return }
        if !ProAccessPolicy.isSkinFree(skin) {
            setSkin(.system)
        }
        if synthRunning {
            stopSynth()
        }
        if showAskAISheet {
            showAskAISheet = false
        }
    }

    // MARK: - Texts & Localization

    func tr(_ key: String) -> String { l10n.tr(key) }
    func trf(_ key: String, _ args: [String]) -> String { l10n.trf(key, args) }

    var problem: String? {
        snapshot.error.isEmpty ? nil : l10n.errorText(snapshot)
    }

    var languageSetting: String { l10n.setting }

    func setLanguage(_ code: String) {
        do {
            try settings.setLanguage(code)
            languageError = false
        } catch {
            languageError = true
        }
        l10n = L10n(catalogs: catalogs, setting: code)
    }

    // MARK: - Skin, Menu Bar Icon & Appearance Helpers

    var cardRadius: CGFloat { CGFloat(appearance.cornerStyle.cardRadius) }
    var smallRadius: CGFloat { CGFloat(appearance.cornerStyle.smallRadius) }
    var fontScale: CGFloat { CGFloat(appearance.fontSize.multiplier) }

    var fontDesign: Font.Design {
        switch appearance.fontFamily {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    var skinAccentColor: Color {
        if let hex = skin.accentHex {
            return Color(hex: hex)
        }
        return Color.accentColor
    }

    var skinSecondaryColor: Color {
        Color(hex: skin.secondaryHex)
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance.backgroundStyle {
        case .system, .tinted: return nil
        case .dark, .midnight: return .dark
        case .light, .warm: return .light
        }
    }

    var windowBackground: Color {
        switch appearance.backgroundStyle {
        case .system: return Color.clear
        case .tinted:
            return skin == .minimalZen ? Color(hex: "#64748b").opacity(0.14) : skinAccentColor.opacity(0.10)
        case .dark:
            switch skin {
            case .cozyCabin: return Color(red: 0.14, green: 0.10, blue: 0.08)
            case .retroTerminal: return Color(red: 0.05, green: 0.07, blue: 0.05)
            default: return Color(red: 0.11, green: 0.11, blue: 0.13)
            }
        case .light: return Color(red: 0.96, green: 0.96, blue: 0.98)
        case .warm: return Color(red: 0.98, green: 0.95, blue: 0.90)
        case .midnight:
            switch skin {
            case .synthwave: return Color(red: 0.08, green: 0.04, blue: 0.16)
            case .discoLava: return Color(red: 0.15, green: 0.07, blue: 0.20)
            default: return Color(red: 0.06, green: 0.09, blue: 0.16)
            }
        }
    }

    var cardBackgroundColor: Color {
        let isDarkBackdrop = (appearance.backgroundStyle == .dark || appearance.backgroundStyle == .midnight)
        switch skin {
        case .system:
            return Color.primary.opacity(0.05)
        case .synthwave:
            return isDarkBackdrop ? Color(hex: "#1f103a").opacity(0.74) : Color(hex: "#ff2e93").opacity(0.06)
        case .cozyCabin:
            return isDarkBackdrop ? Color(hex: "#2d1f16").opacity(0.78) : Color(hex: "#e59838").opacity(0.07)
        case .retroTerminal:
            return isDarkBackdrop ? Color(hex: "#0d1910").opacity(0.84) : Color(hex: "#16a34a").opacity(0.07)
        case .discoLava:
            return isDarkBackdrop ? Color(hex: "#2e1440").opacity(0.74) : Color(hex: "#a855f7").opacity(0.07)
        case .minimalZen:
            return Color(hex: "#64748b").opacity(0.10)
        }
    }

    var cardBorderColor: Color {
        switch skin {
        case .system: return Color.primary.opacity(0.08)
        case .synthwave: return Color(hex: "#00f0ff").opacity(0.28)
        case .cozyCabin: return Color(hex: "#e59838").opacity(0.26)
        case .retroTerminal: return Color(hex: "#33ff66").opacity(0.32)
        case .discoLava: return Color(hex: "#ff5e7e").opacity(0.30)
        case .minimalZen: return Color(hex: "#94a3b8").opacity(0.24)
        }
    }

    func scaledFont(_ baseSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: baseSize * fontScale, weight: weight, design: fontDesign)
    }

    func setSkin(_ newSkin: AppSkin) {
        skin = newSkin
        let rec = newSkin.recommendedAppearance
        appearance = rec
        try? settings.setSkin(newSkin)
        try? settings.setCornerStyle(rec.cornerStyle)
        try? settings.setBackgroundStyle(rec.backgroundStyle)
        try? settings.setFontFamily(rec.fontFamily)
        try? settings.setFontSize(rec.fontSize)
    }

    func setMenuBarIcon(_ style: MenuBarIconStyle) {
        menuBarIcon = style
        try? settings.setMenuBarIcon(style)
    }

    func setShowMenuBarCount(_ value: Bool) {
        showMenuBarCount = value
        try? settings.setShowMenuBarCount(value)
    }

    func setCornerStyle(_ style: CornerStyle) {
        appearance.cornerStyle = style
        try? settings.setCornerStyle(style)
    }

    func setBackgroundStyle(_ style: HueCore.BackgroundStyle) {
        appearance.backgroundStyle = style
        try? settings.setBackgroundStyle(style)
    }

    func setFontFamily(_ family: FontFamily) {
        appearance.fontFamily = family
        try? settings.setFontFamily(family)
    }

    func setFontSize(_ size: FontSizeScale) {
        appearance.fontSize = size
        try? settings.setFontSize(size)
    }

    func setScheduleMode(_ mode: ScheduleMode) {
        scheduleMode = mode
        try? settings.setScheduleMode(mode)
    }

    func setConfirmAllOn(_ value: Bool) {
        confirmAllOn = value
        try? settings.setConfirmAllOn(value)
    }

    // MARK: - Optional Ask AI (OFF by default)

    func setAskAIEnabled(_ enabled: Bool) {
        askAIEnabled = enabled
        if !enabled {
            showAskAISheet = false
        }
        try? settings.setAskAIEnabled(enabled)
    }

    func setAskAIOllamaURL(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        askAIOllamaURL = trimmed.isEmpty ? AppSettings.defaultAskAIOllamaURL : trimmed
        try? settings.setAskAIOllamaURL(askAIOllamaURL)
    }

    func setAskAIModel(_ model: String) {
        askAIModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try? settings.setAskAIModel(askAIModel)
    }

    func runAskAIPrompt(_ prompt: String) async -> HueAskAIResponse {
        guard askAIEnabled else {
            return HueAskAIResponse(reply: "", actions: [], source: "none", matched: false)
        }
        let engine = HueAskAIEngine()
        let dispatcher = HueToolDispatcher(backend: self)
        let config = HueAskAIConfig(ollamaURL: askAIOllamaURL, model: askAIModel)
        return await engine.ask(
            prompt,
            snapshot: snapshot,
            themes: allThemes,
            config: config,
            executor: { call in
                await dispatcher.execute(call)
            }
        )
    }

    // MARK: - Global Hotkeys

    func hotKeyPreset(for action: HotKeyAction) -> HotKeyPreset {
        hotKeys[action] ?? .none
    }

    func setHotKey(_ preset: HotKeyPreset, for action: HotKeyAction) {
        if preset == .none {
            hotKeys.removeValue(forKey: action)
        } else {
            // Avoid two actions claiming the exact same shortcut
            for (otherAction, otherPreset) in hotKeys where otherPreset == preset {
                hotKeys.removeValue(forKey: otherAction)
            }
            hotKeys[action] = preset
        }
        try? settings.setHotKeys(hotKeys)
        hotKeyManager.update(bindings: hotKeys)
    }

    private func handleHotKeyAction(_ action: HotKeyAction) {
        guard snapshot.isPaired else { return }
        switch action {
        case .allOff:
            allOff()
        case .allOn:
            allOn(confirmed: true)
        case .toggleSynth:
            toggleSynth()
        case .toggleFavorite:
            togglePrimaryFavoriteOrFirstRoom()
        }
    }

    private func togglePrimaryFavoriteOrFirstRoom() {
        for room in snapshot.rooms where favorites.contains(Self.favoriteKey(room: room)) {
            setRoom(room, on: !room.on)
            return
        }
        for light in snapshot.allLights where favorites.contains(Self.favoriteKey(light: light)) {
            setLight(light, on: !light.on)
            return
        }
        if let first = snapshot.rooms.first {
            setRoom(first, on: !first.on)
        }
    }

    // MARK: - Per-Lamp Light Themes

    var allThemes: [HueLightTheme] {
        HueLightTheme.builtIn + customThemes
    }

    func saveTheme(_ theme: HueLightTheme) {
        var copy = theme
        copy.isBuiltIn = false
        if let idx = customThemes.firstIndex(where: { $0.id == copy.id }) {
            customThemes[idx] = copy
        } else {
            customThemes.append(copy)
        }
        try? settings.saveCustomThemes(customThemes)
    }

    func deleteTheme(_ theme: HueLightTheme) {
        guard !theme.isBuiltIn else { return }
        customThemes.removeAll { $0.id == theme.id }
        try? settings.saveCustomThemes(customThemes)
    }

    func applyTheme(_ theme: HueLightTheme, to light: HueLight) {
        let mirek: Int?
        let xy: (Double, Double)?
        if let m = theme.mirek, light.supportsCT {
            mirek = HueColorMath.clamp(m, light.mirekMin, light.mirekMax)
            xy = nil
        } else if light.supportsColor, let converted = HueColorMath.hexToXY(theme.hex) {
            mirek = nil
            xy = (converted.x, converted.y)
        } else if light.supportsCT {
            mirek = theme.mirek ?? 320
            xy = nil
        } else {
            mirek = nil
            xy = nil
        }
        let eff: String? = (theme.effect == "no_effect" || light.availableEffects.contains(theme.effect)) ? theme.effect : nil
        setLight(light, on: true, bri: theme.brightness, mirek: mirek, xy: xy, effect: eff)
    }

    // MARK: - Audio-Reactive Light Synthesizer

    var synthTargetLights: [HueLight] {
        if !synthTargetRoomID.isEmpty, let room = snapshot.room(synthTargetRoomID) {
            return room.lights
        }
        return snapshot.allLights
    }

    var synthEngineLabel: String {
        synthUsingEntertainment ? tr("Entertainment 25 Hz") : tr("Standard Sync")
    }

    func synthLightBand(for lightID: String) -> SynthBand {
        synthLightBands[lightID] ?? .all
    }

    func setSynthLightBand(_ band: SynthBand, for lightID: String) {
        synthLightBands[lightID] = band
    }

    func setSynthSource(_ source: AudioCaptureSource) {
        let wasRunning = synthRunning
        synthSource = source
        synthPermissionIssue = nil
        if wasRunning {
            startSynth()
        }
    }

    func clearSynthPermissionError() {
        synthPermissionIssue = nil
    }

    func toggleSynth() {
        if synthRunning {
            stopSynth()
        } else {
            startSynth()
        }
    }

    func toggleSynthFromIntent() async -> Bool {
        if synthRunning {
            stopSynth()
            return false
        }
        return await startSynthAsync()
    }

    func startSynth() {
        Task { [weak self] in
            _ = await self?.startSynthAsync()
        }
    }

    private var synthStartGeneration: Int = 0
    private var requestedEntertainmentAreaID: String?
    private var entertainmentDeactivationTask: Task<Void, Never>?

    @discardableResult
    private func startSynthAsync() async -> Bool {
        guard snapshot.isPaired, !synthTargetLights.isEmpty else { return false }
        synthStartGeneration += 1
        let gen = synthStartGeneration
        let areaID = synthEntertainmentAreaID
        requestedEntertainmentAreaID = areaID.isEmpty ? nil : areaID

        audioCapture.stop()
        stopEntertainmentIfNeeded()
        if let pendingDeactivation = entertainmentDeactivationTask {
            await pendingDeactivation.value
            guard synthStartGeneration == gen else { return false }
        }

        synthPermissionIssue = nil
        synthMapper.reset()
        synthPhase = 0.0
        lastSynthOutputTime = .distantPast

        // Try Entertainment v2 DTLS-PSK if an area is chosen and clientKey is available
        synthUsingEntertainment = false
        if !areaID.isEmpty,
           let creds = client.entertainmentCredentials,
           !creds.clientKey.isEmpty {
            let activated = await client.setEntertainmentActive(areaID: areaID, active: true)
            guard synthStartGeneration == gen else {
                if activated && activeEntertainmentAreaID != areaID && requestedEntertainmentAreaID != areaID {
                    _ = await client.setEntertainmentActive(areaID: areaID, active: false)
                }
                return false
            }
            if activated && entertainmentStreamer.start(
                ip: creds.ip,
                appKey: creds.appKey,
                clientKeyHex: creds.clientKey,
                areaID: areaID
            ) {
                activeEntertainmentAreaID = areaID
                synthUsingEntertainment = true
            } else if activated {
                _ = await client.setEntertainmentActive(areaID: areaID, active: false)
            }
        }

        let started = await audioCapture.start(source: synthSource)
        // If superseded by stopSynth() or a newer startSynthAsync(), that caller already stopped
        // our audioCapture and entertainment session; never clobber the newer session.
        guard synthStartGeneration == gen else {
            return false
        }
        if started {
            synthRunning = true
            return true
        } else {
            requestedEntertainmentAreaID = nil
            stopEntertainmentIfNeeded()
            synthRunning = false
            return false
        }
    }

    func stopSynth() {
        synthStartGeneration += 1
        requestedEntertainmentAreaID = nil
        audioCapture.stop()
        stopEntertainmentIfNeeded()
        synthRunning = false
        synthUsingEntertainment = false
        synthLevels = .zero
    }

    private func stopEntertainmentIfNeeded() {
        entertainmentStreamer.stop()
        if let areaID = activeEntertainmentAreaID {
            activeEntertainmentAreaID = nil
            let previous = entertainmentDeactivationTask
            entertainmentDeactivationTask = Task { [weak self] in
                await previous?.value
                _ = await self?.client.setEntertainmentActive(areaID: areaID, active: false)
            }
        }
    }

    private func handleSynthLevels(_ levels: AudioBandLevels) {
        synthLevels = levels
        guard synthRunning else { return }

        let now = Date()
        let minInterval: TimeInterval = synthUsingEntertainment ? 0.04 : 0.22 // 25 Hz Entertainment vs ~4.5 Hz CLIP v2
        guard now.timeIntervalSince(lastSynthOutputTime) >= minInterval else { return }
        lastSynthOutputTime = now
        synthPhase += minInterval * 2.2

        let targets = synthTargetLights
        guard !targets.isEmpty else { return }

        var framesByID: [String: SynthLightFrame] = [:]
        for (idx, light) in targets.enumerated() {
            let frame = synthMapper.map(
                lightID: light.id,
                lightIndex: idx,
                levels: levels,
                mode: synthMode,
                palette: synthPalette,
                band: synthLightBand(for: light.id),
                sensitivity: synthSensitivity,
                smoothness: synthSmoothness,
                phase: synthPhase
            )
            framesByID[light.id] = frame
        }

        if synthUsingEntertainment,
           let areaID = activeEntertainmentAreaID,
           let area = snapshot.entertainmentAreas.first(where: { $0.id == areaID }) {
            var channels: [HueStreamPacket.ChannelValue] = []
            for (idx, ch) in area.channels.enumerated() {
                let frame = ch.lightIDs.compactMap { framesByID[$0] }.first
                    ?? synthMapper.map(
                        lightID: "ch-\(ch.channelID)",
                        lightIndex: idx,
                        levels: levels,
                        mode: synthMode,
                        palette: synthPalette,
                        band: .all,
                        sensitivity: synthSensitivity,
                        smoothness: synthSmoothness,
                        phase: synthPhase
                    )
                channels.append(HueStreamPacket.ChannelValue(
                    channelID: ch.channelID,
                    c1: frame.r16,
                    c2: frame.g16,
                    c3: frame.b16
                ))
            }
            entertainmentStreamer.send(channels: channels)
        } else {
            // CLIP v2 Fast Sync (cap per tick to keep bridge Zigbee queue smooth)
            let batch = Array(targets.prefix(6))
            for light in batch {
                guard let frame = framesByID[light.id] else { continue }
                let xy: (Double, Double)? = light.supportsColor ? (frame.xyX, frame.xyY) : nil
                client.setLight(id: light.id, on: true, bri: frame.brightness, mirek: nil, xy: xy, effect: nil)
            }
        }
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            launchAtLoginError = error.localizedDescription
        }
    }

    // MARK: - Favorites & All On Exclusions

    static func favoriteKey(room: HueRoom) -> String { "room:" + room.id }
    static func favoriteKey(light: HueLight) -> String { "light:" + light.id }

    func isFavorite(_ key: String) -> Bool {
        favorites.contains(key)
    }

    func toggleFavorite(_ key: String) {
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
        }
        try? settings.setFavorites(Array(favorites).sorted())
    }

    func isExcludedFromAllOn(_ roomID: String) -> Bool {
        excludedFromAllOn.contains(roomID)
    }

    func toggleExcludedFromAllOn(_ roomID: String) {
        if excludedFromAllOn.contains(roomID) {
            excludedFromAllOn.remove(roomID)
        } else {
            excludedFromAllOn.insert(roomID)
        }
        try? settings.setExcludedFromAllOn(Array(excludedFromAllOn).sorted())
    }

    // MARK: - Lights & Rooms

    func setRoom(
        _ room: HueRoom,
        on: Bool? = nil,
        bri: Int? = nil,
        mirek: Int? = nil,
        xy: (Double, Double)? = nil,
        effect: String? = nil
    ) {
        if !room.groupedLight.isEmpty {
            client.setGroup(id: room.groupedLight, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        } else {
            for light in room.lights {
                client.setLight(id: light.id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
            }
        }
    }

    func setLight(
        _ light: HueLight,
        on: Bool? = nil,
        bri: Int? = nil,
        mirek: Int? = nil,
        xy: (Double, Double)? = nil,
        effect: String? = nil
    ) {
        client.setLight(id: light.id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
    }

    func recall(_ scene: HueScene) {
        client.recallScene(id: scene.id)
    }

    func allOn(confirmed: Bool = false) {
        if confirmAllOn && !confirmed {
            confirmAllOnPrompt = true
            return
        }
        confirmAllOnPrompt = false
        client.allOn(excludeRooms: excludedFromAllOn)
    }

    func allOff() {
        if synthRunning { stopSynth() }
        if snapshot.anyLightOn {
            client.allOff()
        }
    }

    func refresh() {
        client.refresh()
    }

    static func target(room: HueRoom) -> String { "room:" + room.id }
    static func target(light: HueLight) -> String { "light:" + light.id }

    func brightness(_ target: String, bridge: Double) -> Double {
        dragging[target] ?? max(1, bridge)
    }

    func drag(_ target: String, to value: Double) {
        dragging[target] = value
        debouncer?.update(target, brightnessStep(value))
    }

    func release(_ target: String) {
        debouncer?.finish(target)
        dragging.removeValue(forKey: target)
    }

    private func sendBrightness(_ target: String, _ value: Int) {
        if target.hasPrefix("room:") {
            let key = String(target.dropFirst(5))
            if let room = snapshot.room(key) {
                setRoom(room, bri: value)
            }
        } else if target.hasPrefix("light:") {
            client.setLight(id: String(target.dropFirst(6)), on: nil, bri: value, mirek: nil, xy: nil, effect: nil)
        }
    }

    func toggleExpanded(_ room: HueRoom) {
        if expanded.remove(room.id) == nil { expanded.insert(room.id) }
    }

    func toggleAllScenes(_ room: HueRoom) {
        if allScenes.remove(room.id) == nil { allScenes.insert(room.id) }
    }

    // MARK: - Schedules (Bridge + Local)

    var allSchedules: [HueSchedule] {
        (snapshot.schedules + localSchedules)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func createSchedule(_ draft: HueScheduleDraft) {
        let targetIsNonHue = HueColorMath.providerPrefix(of: draft.targetID) != "hue"
            || (!draft.sceneID.isEmpty && HueColorMath.providerPrefix(of: draft.sceneID) != "hue")
        if scheduleMode == .local || !snapshot.hueBridgePaired || targetIsNonHue {
            let schedule = HueSchedule(
                id: UUID().uuidString.lowercased(),
                name: HueColorMath.clean(draft.name).isEmpty ? tr("Schedule") : HueColorMath.clean(draft.name),
                enabled: true,
                targetKind: draft.targetKind,
                targetID: draft.targetID,
                targetName: draft.targetName,
                triggerKind: draft.triggerKind,
                time: draft.time,
                offsetMin: draft.offsetMin,
                days: draft.days,
                action: draft.action,
                bri: draft.action == "on" ? draft.bri : nil,
                sceneID: draft.action == "scene" ? draft.sceneID : "",
                fadeMin: draft.fadeMin,
                source: "local"
            )
            localSchedules.append(schedule)
            try? settings.saveLocalSchedules(localSchedules)
        } else {
            client.createSchedule(draft)
        }
    }

    func toggleSchedule(_ schedule: HueSchedule, enabled: Bool) {
        if schedule.source == "local" {
            if let idx = localSchedules.firstIndex(where: { $0.id == schedule.id }) {
                localSchedules[idx].enabled = enabled
                try? settings.saveLocalSchedules(localSchedules)
            }
        } else {
            client.toggleSchedule(id: schedule.id, enabled: enabled)
        }
    }

    func deleteSchedule(_ schedule: HueSchedule) {
        if schedule.source == "local" {
            localSchedules.removeAll { $0.id == schedule.id }
            try? settings.saveLocalSchedules(localSchedules)
        } else {
            client.deleteSchedule(id: schedule.id)
        }
    }

    func hasActiveSchedule(for targetID: String) -> Bool {
        allSchedules.contains { $0.enabled && $0.targetID == targetID }
    }

    func openScheduleFor(kind: String, id: String) {
        schedulePrefillTarget = (kind, id)
        tab = .schedules
        showNewScheduleSheet = true
    }

    private func startLocalScheduleLoop() {
        localScheduleTask?.cancel()
        localScheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.evaluateLocalSchedulesNow()
                }
            }
        }
    }

    private func evaluateLocalSchedulesNow() {
        guard snapshot.isPaired else { return }
        let due = localScheduler.dueActions(for: localSchedules, at: Date())
        for action in due {
            if !action.sceneID.isEmpty {
                client.recallScene(id: action.sceneID)
            } else if action.targetKind == "room" {
                if let room = snapshot.rooms.first(where: { $0.id == action.targetID || $0.hueID == action.targetID }) {
                    let on = action.action != "off"
                    setRoom(room, on: on, bri: on ? action.bri : nil)
                }
            } else {
                let on = action.action != "off"
                client.setLight(id: action.targetID, on: on, bri: on ? action.bri : nil, mirek: nil, xy: nil, effect: nil)
            }
        }
    }

    // MARK: - Rules

    func addRule(_ rule: HueRule) {
        rules.append(rule)
        syncRules()
    }

    func updateRule(_ rule: HueRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
            syncRules()
        }
    }

    func toggleRule(_ rule: HueRule, enabled: Bool) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx].enabled = enabled
            syncRules()
        }
    }

    func deleteRule(_ rule: HueRule) {
        rules.removeAll { $0.id == rule.id }
        syncRules()
    }

    func setRulesPaused(_ paused: Bool) {
        rulesPaused = paused
        if !snapshot.isDemo {
            try? settings.setRulesPaused(paused)
        }
        client.setRules(rules, paused: paused)
    }

    private func syncRules() {
        if !snapshot.isDemo {
            try? settings.saveRules(rules)
        }
        client.setRules(rules, paused: rulesPaused)
    }

    func hasActiveRule(for targetID: String) -> Bool {
        guard !rulesPaused else { return false }
        return rules.contains { rule in
            guard rule.enabled else { return false }
            if rule.triggerID == targetID { return true }
            return rule.targets.contains { $0.id == targetID }
        }
    }

    func openRuleFor(kind: String, id: String) {
        rulePrefillTrigger = (kind, id)
        tab = .rules
        showNewRuleSheet = true
    }

    func handleDesktopEvent(_ event: String) {
        client.triggerDesktopEvent(event)
    }

    func nameForTarget(kind: String, id: String) -> String {
        if kind == "desktop" { return tr("This Mac") }
        if kind == "room" {
            if let room = snapshot.rooms.first(where: { $0.id == id || $0.hueID == id }) {
                return l10n.roomName(room)
            }
        }
        if kind == "motion" || kind == "contact" || kind == "button" {
            if let sensor = snapshot.sensor(id) {
                return sensor.name
            }
        }
        if kind == "motion_area" {
            if let area = snapshot.motionArea(id) {
                return area.name
            }
        }
        if let light = snapshot.light(id) {
            return light.name
        }
        return id
    }

    // MARK: - Sensors & Bridge Pro MotionAware™

    func setSensorEnabled(_ sensor: HueSensor, enabled: Bool) {
        client.setSensorEnabled(kind: sensor.kind, id: sensor.id, enabled: enabled)
    }

    func updateMotionArea(_ area: HueMotionArea, enabled: Bool? = nil, sensitivity: Int? = nil) {
        client.updateMotionArea(
            id: area.id,
            convenienceID: area.convenienceID.isEmpty ? nil : area.convenienceID,
            enabled: enabled,
            sensitivity: sensitivity
        )
    }

    func motionArea(forRoom roomID: String) -> HueMotionArea? {
        guard !roomID.isEmpty else { return nil }
        return snapshot.motionAreas.first { $0.roomID == roomID }
    }

    func roomHasPresence(_ roomID: String) -> Bool {
        guard !roomID.isEmpty else { return false }
        return snapshot.motionAreas.contains { $0.roomID == roomID && $0.enabled && $0.motion }
    }

    var shouldShowMotionAwareSetupHint: Bool {
        snapshot.bridge?.isPro == true && snapshot.motionAreas.isEmpty && !motionAwareHintDismissed
    }

    var motionAwareEligibleRooms: [HueRoom] {
        snapshot.rooms.filter { $0.kind == "room" && $0.lights.count >= 3 }
    }

    func dismissMotionAwareHint() {
        motionAwareHintDismissed = true
    }

    func openMapInRulesMode(wiringLightID: String? = nil) {
        page = .main
        tab = .map
        pendingMapMode = "rules"
        pendingMapWireLightID = wiringLightID
    }

    // MARK: - Bridge

    func discover() { client.discover() }

    func pair(_ ip: String) {
        let ip = cleanedIP(ip)
        if !ip.isEmpty { client.pair(ip: ip) }
    }

    // MARK: - Multi-Device Providers

    func openAddProvider(kind: LightProviderKind? = nil) {
        editingProvider = nil
        preselectedProviderKind = kind
        showAddProviderSheet = true
    }

    func openEditProvider(_ connection: ProviderConnection) {
        editingProvider = connection
        preselectedProviderKind = connection.kind
        showAddProviderSheet = true
    }

    func discoverProviders() {
        multiClient?.discoverProviders()
    }

    @discardableResult
    func saveProvider(_ connection: ProviderConnection, secret: String?) -> Result<Void, Error> {
        guard let mc = multiClient else { return .failure(ProviderClientError.unsupported) }
        do {
            try mc.addProvider(connection, secret: secret)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func setProviderEnabled(id: String, enabled: Bool) {
        multiClient?.setProviderEnabled(id: id, enabled: enabled)
    }

    func removeProvider(id: String) {
        multiClient?.removeProvider(id: id)
    }

    @discardableResult
    func trustNewProviderCertificate(id: String) -> Result<Void, Error> {
        guard let mc = multiClient else { return .failure(ProviderClientError.unsupported) }
        do {
            try mc.trustNewCertificate(id: id)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func hasProviderSecret(for connectionID: String) -> Bool {
        multiClient?.hasSecret(for: connectionID) ?? false
    }

    func testProvider(_ connection: ProviderConnection, secret: String?) async -> Result<String, Error> {
        guard let mc = multiClient else { return .failure(ProviderClientError.unsupported) }
        return await mc.testProvider(connection, secret: secret)
    }

    func pairNanoleaf(host: String, port: Int) async -> Result<String, Error> {
        guard let mc = multiClient else { return .failure(ProviderClientError.unsupported) }
        return await mc.pairNanoleaf(host: host, port: port)
    }

    func pairDirigera(host: String, port: Int) async -> Result<(token: String, certFingerprint: String), Error> {
        guard let mc = multiClient else { return .failure(ProviderClientError.unsupported) }
        return await mc.pairDirigera(host: host, port: port)
    }

    func cancelPair() { client.cancelPair() }

    func unpair() {
        stopSynth()
        confirmUnpair = false
        expanded.removeAll()
        allScenes.removeAll()
        motionAwareHintDismissed = false
        pendingMapMode = nil
        pendingMapWireLightID = nil
        client.unpair()
        page = .main
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: - Detached Window Frame

    func savedWindowFrame() -> SavedWindowFrame? {
        cachedWindowFrame
    }

    func saveWindowFrame(_ frame: SavedWindowFrame) {
        guard cachedWindowFrame != frame else { return }
        cachedWindowFrame = frame
        try? settings.setWindowFrame(frame)
    }

    // MARK: - Visual Floorplan & Spatial Studio

    var currentBridgeID: String {
        if snapshot.isDemo { return "demo" }
        let id = client.bridgeID
        return id.isEmpty ? (snapshot.bridge?.ip ?? "default") : id
    }

    var pendingFloorplanSyncPlan: FloorplanSyncPlan {
        FloorplanSpatial.buildSyncPlan(floorplan: floorplan, snapshot: snapshot)
    }

    var pendingRoomDiffs: [RoomMembershipDiff] {
        FloorplanSpatial.pendingRoomMembershipDiffs(floorplan: floorplan, snapshot: snapshot)
    }

    var floorplanDiffSignature: String {
        let plan = pendingFloorplanSyncPlan
        let d1 = plan.membershipDiffs.map { "\($0.lightID)->\($0.toBoxID)" }.joined(separator: ",")
        let d2 = plan.boxesToCreate.map(\.id).joined(separator: ",")
        let d3 = plan.boxesToUpdateMeta.map { "\($0.id):\($0.name):\($0.archetype)" }.joined(separator: ",")
        return "\(d1)|\(d2)|\(d3)"
    }

    private func ensureFloorplanLoaded(for snap: HueSnapshot) {
        let key = currentBridgeID
        let needsLoad = (floorplanLoadedForBridgeID != key)
            || (floorplan.boxes.isEmpty && floorplan.lamps.isEmpty && !snap.rooms.isEmpty)
        guard needsLoad else { return }
        floorplanLoadedForBridgeID = key
        dismissedFloorplanDiffKey = ""
        if let saved = settings.loadFloorplan(bridgeID: key) {
            floorplan = saved
            floorplanBackgroundImage = settings.loadFloorplanBackgroundImage(fileName: saved.background.fileName)
        } else if key != "multi-home", key != "demo",
                  var migrated = settings.loadFloorplan(bridgeID: "multi-home") {
            // D2: Migrate an existing multi-home floorplan when the user pairs a Hue Bridge for the first time
            migrated.bridgeID = key
            floorplan = migrated
            floorplanBackgroundImage = settings.loadFloorplanBackgroundImage(fileName: migrated.background.fileName)
            persistFloorplan()
        } else {
            floorplan = FloorplanTemplate.build(template: .autoBridge, snapshot: snap, bridgeID: key)
            floorplanBackgroundImage = nil
            persistFloorplan()
        }
    }

    func persistFloorplan() {
        var doc = floorplan
        if doc.bridgeID.isEmpty {
            doc.bridgeID = currentBridgeID
            floorplan.bridgeID = doc.bridgeID
        }
        try? settings.saveFloorplan(doc)
    }

    func applyFloorplanTemplate(_ template: FloorplanTemplate) {
        let prevBg = floorplan.background
        let prevAuto = floorplan.autoSync
        var built = FloorplanTemplate.build(template: template, snapshot: snapshot, bridgeID: currentBridgeID)
        built.background = prevBg
        built.autoSync = prevAuto
        floorplan = built
        dismissedFloorplanDiffKey = ""
        persistFloorplan()
    }

    func setFloorplanAutoSync(_ enabled: Bool) {
        floorplan.autoSync = enabled
        persistFloorplan()
        if enabled && pendingFloorplanSyncPlan.hasRoomOrMetaChanges {
            syncAllFloorplanToBridge()
        }
    }

    func placeLamp(_ lightID: String, at x: Double, y: Double) {
        let lightName = snapshot.light(lightID)?.name ?? ""
        let sx = floorplan.snapped(x)
        let sy = floorplan.snapped(y)
        let existing = floorplan.lamps[lightID]
        floorplan.lamps[lightID] = FloorplanLampPlacement(
            x: sx,
            y: sy,
            z: existing?.z ?? 0.0,
            icon: existing?.icon ?? LampIcon.inferred(for: lightName)
        )
        persistFloorplan()
        triggerAutoSyncIfEnabled()
    }

    func moveLamp(_ lightID: String, to x: Double, y: Double, finalize: Bool) {
        guard var placement = floorplan.lamps[lightID] else { return }
        placement.x = finalize ? floorplan.snapped(x) : x
        placement.y = finalize ? floorplan.snapped(y) : y
        floorplan.lamps[lightID] = placement
        if finalize {
            persistFloorplan()
            triggerAutoSyncIfEnabled()
        }
    }

    func unplaceLamp(_ lightID: String) {
        floorplan.lamps.removeValue(forKey: lightID)
        persistFloorplan()
    }

    func placeSensor(_ sensorID: String, at x: Double, y: Double) {
        let sx = floorplan.snapped(x)
        let sy = floorplan.snapped(y)
        floorplan.sensors[sensorID] = FloorplanSensorPlacement(x: sx, y: sy)
        persistFloorplan()
    }

    func moveSensor(_ sensorID: String, to x: Double, y: Double, finalize: Bool) {
        guard var placement = floorplan.sensors[sensorID] else { return }
        placement.x = finalize ? floorplan.snapped(x) : x
        placement.y = finalize ? floorplan.snapped(y) : y
        floorplan.sensors[sensorID] = placement
        if finalize {
            persistFloorplan()
        }
    }

    func unplaceSensor(_ sensorID: String) {
        floorplan.sensors.removeValue(forKey: sensorID)
        persistFloorplan()
    }

    func lampIcon(for light: HueLight) -> LampIcon {
        floorplan.lamps[light.id]?.icon ?? LampIcon.inferred(for: light.name)
    }

    func updateLampPlacement(_ lightID: String, z: Double? = nil, icon: LampIcon? = nil) {
        guard var placement = floorplan.lamps[lightID] else { return }
        if let z = z { placement.z = HueColorMath.clamp(z, -1.0, 1.0) }
        if let icon = icon { placement.icon = icon }
        floorplan.lamps[lightID] = placement
        persistFloorplan()
    }

    func setLampIcon(_ lightID: String, icon: LampIcon) {
        if var placement = floorplan.lamps[lightID] {
            placement.icon = icon
            floorplan.lamps[lightID] = placement
            persistFloorplan()
            return
        }
        let pos: (Double, Double)
        if let ownerRoom = snapshot.rooms.first(where: { $0.kind == "room" && $0.lights.contains(where: { $0.id == lightID }) }),
           let box = floorplan.boxes.first(where: { $0.hueID == ownerRoom.hueID }) {
            let offset = Double((floorplan.lamps.count % 5) - 2) * 28.0
            pos = (floorplan.snapped(box.centerX + offset), floorplan.snapped(box.centerY + 12))
        } else {
            pos = (floorplan.snapped(floorplan.canvas.width / 2), floorplan.snapped(floorplan.canvas.height / 2))
        }
        floorplan.lamps[lightID] = FloorplanLampPlacement(x: pos.0, y: pos.1, z: 0.0, icon: icon, floorID: floorplan.activeFloorID)
        persistFloorplan()
    }

    func renameLight(id: String, name: String) {
        let clean = HueColorMath.clean(name, limit: 32)
        guard !clean.isEmpty else { return }
        client.renameLight(id: id, name: clean)
    }

    func addFloorplanBox(
        kind: String,
        name: String,
        archetype: String,
        shape: FloorplanRoomShape = .rectangle,
        at x: Double,
        y: Double
    ) {
        let sx = floorplan.snapped(x)
        let sy = floorplan.snapped(y)
        let w: Double = kind == "zone" ? 340 : 320
        let h: Double = kind == "zone" ? 200 : 240
        let box = FloorplanBox(
            kind: kind,
            hueID: nil,
            name: name,
            archetype: archetype,
            x: sx,
            y: sy,
            width: w,
            height: h,
            points: shape.makePoints(x: sx, y: sy, width: w, height: h),
            floorID: floorplan.activeFloorID
        )
        floorplan.boxes.append(box)
        persistFloorplan()
    }

    // MARK: - Floorplan Studio v2 (Polygons, Multi-Floor, Gallery, Lighting Planner)

    func selectFloor(_ floorID: String) {
        guard floorplan.floors.contains(where: { $0.id == floorID }) else { return }
        floorplan.activeFloorID = floorID
        persistFloorplan()
    }

    func addFloor(name: String, level: Int? = nil) {
        let nextLevel = level ?? ((floorplan.floors.map(\.level).max() ?? 0) + 1)
        let baseID = nextLevel == 0 ? "eg" : (nextLevel > 0 ? "og\(nextLevel)" : "ug\(abs(nextLevel))")
        var candidate = baseID
        var suffix = 2
        while floorplan.floors.contains(where: { $0.id == candidate }) {
            candidate = "\(baseID)_\(suffix)"
            suffix += 1
        }
        let floor = FloorplanFloor(id: candidate, name: name, level: nextLevel)
        floorplan.floors.append(floor)
        floorplan.floors.sort { $0.level < $1.level }
        floorplan.activeFloorID = floor.id
        persistFloorplan()
    }

    func renameFloor(id: String, name: String) {
        guard let idx = floorplan.floors.firstIndex(where: { $0.id == id }) else { return }
        let clean = HueColorMath.clean(name, limit: 32)
        guard !clean.isEmpty else { return }
        floorplan.floors[idx].name = clean
        persistFloorplan()
    }

    func deleteFloor(id: String) {
        guard floorplan.floors.count > 1,
              let idx = floorplan.floors.firstIndex(where: { $0.id == id }) else { return }
        lastUndoFloorplan = floorplan
        floorplan.floors.remove(at: idx)
        let fallback = floorplan.floors[0].id
        floorplan.boxes.removeAll { $0.floorID == id }
        floorplan.stamps.removeAll { $0.floorID == id }
        floorplan.plannedLights.removeAll { $0.floorID == id }
        for (lid, p) in floorplan.lamps where p.floorID == id {
            var moved = p
            moved.floorID = fallback
            floorplan.lamps[lid] = moved
        }
        for (sid, p) in floorplan.sensors where p.floorID == id {
            var moved = p
            moved.floorID = fallback
            floorplan.sensors[sid] = moved
        }
        if floorplan.activeFloorID == id {
            floorplan.activeFloorID = fallback
        }
        persistFloorplan()
    }

    func undoLastFloorplanChange() {
        guard let prev = lastUndoFloorplan else { return }
        lastUndoFloorplan = nil
        floorplan = prev
        floorplanBackgroundImage = settings.loadFloorplanBackgroundImage(fileName: prev.background.fileName)
        persistFloorplan()
    }

    func moveLampToActiveFloor(_ lightID: String) {
        guard var p = floorplan.lamps[lightID] else { return }
        p.floorID = floorplan.activeFloorID
        floorplan.lamps[lightID] = p
        persistFloorplan()
    }

    func applyGalleryPreset(id: String, includeSamplePlan: Bool) {
        lastUndoFloorplan = floorplan
        var doc: FloorplanDocument
        if id == "bungalow_l_shape" {
            doc = FloorplanTemplate.buildLShapedBungalow(snapshot: snapshot, bridgeID: currentBridgeID)
        } else if let tpl = FloorplanTemplate(rawValue: id) {
            doc = FloorplanTemplate.build(template: tpl, snapshot: snapshot, bridgeID: currentBridgeID)
        } else {
            doc = FloorplanTemplate.build(template: .threeRoomApartment, snapshot: snapshot, bridgeID: currentBridgeID)
        }
        if includeSamplePlan {
            doc.plannedLights = FloorplanTemplate.samplePlannedLights(for: doc)
        }
        doc.autoSync = floorplan.autoSync
        doc.background = floorplan.background
        floorplan = doc
        persistFloorplan()
    }

    func reshapeBox(id: String, shape: FloorplanRoomShape) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == id }) else { return }
        floorplan.boxes[idx] = floorplan.boxes[idx].applyingShape(shape)
        persistFloorplan()
    }

    func moveBoxVertex(boxID: String, vertexIndex: Int, to point: FloorplanPoint, finalize: Bool) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == boxID }) else { return }
        let pt = finalize
            ? FloorplanPoint(x: floorplan.snapped(point.x), y: floorplan.snapped(point.y))
            : point
        floorplan.boxes[idx] = floorplan.boxes[idx].movingVertex(at: vertexIndex, to: pt)
        if finalize {
            persistFloorplan()
            triggerAutoSyncIfEnabled()
        }
    }

    func insertBoxVertex(boxID: String, afterEdge edgeIndex: Int, at point: FloorplanPoint) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == boxID }) else { return }
        let pt = FloorplanPoint(x: floorplan.snapped(point.x), y: floorplan.snapped(point.y))
        floorplan.boxes[idx] = floorplan.boxes[idx].insertingVertex(afterEdge: edgeIndex, at: pt)
        persistFloorplan()
    }

    func removeBoxVertex(boxID: String, vertexIndex: Int) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == boxID }) else { return }
        floorplan.boxes[idx] = floorplan.boxes[idx].removingVertex(at: vertexIndex)
        persistFloorplan()
        triggerAutoSyncIfEnabled()
    }

    func addPlannedLight(preset: PlannedLightPreset, at center: FloorplanPoint) -> PlannedLight {
        let sx = floorplan.snapped(center.x)
        let sy = floorplan.snapped(center.y)
        let strip: [FloorplanPoint]? = preset.isStrip
            ? [FloorplanPoint(x: sx - 80, y: sy), FloorplanPoint(x: sx + 80, y: sy)]
            : nil
        let light = PlannedLight(
            floorID: floorplan.activeFloorID,
            name: tr(preset.titleKey),
            icon: preset.icon,
            x: sx,
            y: sy,
            stripPoints: strip,
            lumens: preset.lumens,
            beamRadius: preset.beamRadius,
            kelvin: preset.kelvin,
            on: true,
            modelNote: "",
            price: preset.defaultPrice
        )
        floorplan.plannedLights.append(light)
        persistFloorplan()
        return light
    }

    func updatePlannedLight(_ light: PlannedLight, finalize: Bool = true) {
        guard let idx = floorplan.plannedLights.firstIndex(where: { $0.id == light.id }) else { return }
        floorplan.plannedLights[idx] = light
        if finalize { persistFloorplan() }
    }

    func togglePlannedLight(id: String) {
        guard let idx = floorplan.plannedLights.firstIndex(where: { $0.id == id }) else { return }
        floorplan.plannedLights[idx].on.toggle()
        persistFloorplan()
    }

    func deletePlannedLight(id: String) {
        floorplan.plannedLights.removeAll { $0.id == id }
        persistFloorplan()
    }

    func bindPlannedLight(plannedID: String, toRealLightID realLightID: String) {
        guard let idx = floorplan.plannedLights.firstIndex(where: { $0.id == plannedID }) else { return }
        let planned = floorplan.plannedLights[idx]
        let anchor = planned.anchorPoint
        floorplan.lamps[realLightID] = FloorplanLampPlacement(
            x: anchor.x,
            y: anchor.y,
            z: 0.0,
            icon: planned.icon,
            floorID: planned.floorID
        )
        floorplan.plannedLights.remove(at: idx)
        persistFloorplan()
        showTransientFloorplanStatus(tr("Bound planned fixture to real light"))
    }

    func updateFloorplanBox(
        _ updated: FloorplanBox,
        moveEnclosedLampIDs: [String] = [],
        delta: (dx: Double, dy: Double)? = nil,
        finalize: Bool = true
    ) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == updated.id }) else { return }
        floorplan.boxes[idx] = updated
        if let delta = delta, !moveEnclosedLampIDs.isEmpty {
            for lid in moveEnclosedLampIDs {
                if var lamp = floorplan.lamps[lid] {
                    lamp.x = finalize ? floorplan.snapped(lamp.x + delta.dx) : (lamp.x + delta.dx)
                    lamp.y = finalize ? floorplan.snapped(lamp.y + delta.dy) : (lamp.y + delta.dy)
                    floorplan.lamps[lid] = lamp
                }
            }
        }
        if finalize {
            persistFloorplan()
            triggerAutoSyncIfEnabled()
        }
    }

    func renameOrUpdateBoxOnBridge(_ box: FloorplanBox) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == box.id }) else { return }
        floorplan.boxes[idx] = box
        persistFloorplan()
        guard let hueID = box.hueID, HueColorMath.validUUID(hueID) else { return }
        Task { [weak self] in
            guard let self = self else { return }
            _ = await self.client.updateRoom(
                id: hueID,
                kind: box.kind,
                name: box.name,
                archetype: box.archetype,
                deviceIDs: nil
            )
        }
    }

    func createBoxOnBridge(_ box: FloorplanBox) {
        guard box.hueID == nil else { return }
        let enclosedIDs = deviceOrLightIDs(in: box)
        Task { [weak self] in
            guard let self = self else { return }
            if let created = await self.client.createRoom(
                kind: box.kind,
                name: box.name,
                archetype: box.archetype,
                deviceIDs: enclosedIDs
            ), let idx = self.floorplan.boxes.firstIndex(where: { $0.id == box.id }) {
                self.floorplan.boxes[idx].hueID = created
                self.persistFloorplan()
            }
        }
    }

    func deleteFloorplanBox(id: String, alsoDeleteOnBridge: Bool) {
        guard let idx = floorplan.boxes.firstIndex(where: { $0.id == id }) else { return }
        let removed = floorplan.boxes.remove(at: idx)
        persistFloorplan()
        if alsoDeleteOnBridge, let hueID = removed.hueID, HueColorMath.validUUID(hueID) {
            Task { [weak self] in
                guard let self = self else { return }
                _ = await self.client.deleteRoom(id: hueID, kind: removed.kind)
            }
        }
    }

    func addStamp(kind: String, at x: Double, y: Double) {
        let stamp = FloorplanStamp(
            kind: kind,
            x: floorplan.snapped(x),
            y: floorplan.snapped(y),
            floorID: floorplan.activeFloorID
        )
        floorplan.stamps.append(stamp)
        persistFloorplan()
    }

    func moveStamp(id: String, to x: Double, y: Double, finalize: Bool) {
        guard let idx = floorplan.stamps.firstIndex(where: { $0.id == id }) else { return }
        floorplan.stamps[idx].x = finalize ? floorplan.snapped(x) : x
        floorplan.stamps[idx].y = finalize ? floorplan.snapped(y) : y
        if finalize { persistFloorplan() }
    }

    func rotateStamp(id: String) {
        guard let idx = floorplan.stamps.firstIndex(where: { $0.id == id }) else { return }
        floorplan.stamps[idx].rotation = (floorplan.stamps[idx].rotation + 90) % 360
        persistFloorplan()
    }

    func deleteStamp(id: String) {
        floorplan.stamps.removeAll { $0.id == id }
        persistFloorplan()
    }

    func createSceneFromRoom(roomID: String, name: String) {
        let clean = HueColorMath.clean(name, limit: 32)
        guard !clean.isEmpty else { return }
        Task { [weak self] in
            guard let self = self else { return }
            let created = await self.client.createSceneFromRoom(roomID: roomID, name: clean)
            if created != nil {
                self.showTransientFloorplanStatus(self.trf("Saved scene \"{0}\"", [clean]))
            }
        }
    }

    func syncEntertainmentBox(_ box: FloorplanBox) {
        guard let areaID = box.entertainmentAreaID ?? floorplan.entertainmentAreaID,
              HueColorMath.validUUID(areaID) else { return }
        let positions = FloorplanSpatial.entertainmentPositions(forBox: box, floorplan: floorplan, snapshot: snapshot)
        guard !positions.isEmpty else { return }
        Task { [weak self] in
            guard let self = self else { return }
            let ok = await self.client.updateEntertainmentLocations(areaID: areaID, positions: positions)
            if ok {
                self.showTransientFloorplanStatus(self.tr("Synced Entertainment 2D/3D positions"))
            }
        }
    }

    func schedulesForRoom(_ roomID: String) -> [HueSchedule] {
        guard !roomID.isEmpty else { return [] }
        return allSchedules.filter { $0.enabled && $0.targetID == roomID }
    }

    func sceneName(for sceneID: String) -> String? {
        guard !sceneID.isEmpty else { return nil }
        for room in snapshot.rooms {
            if let s = room.scenes.first(where: { $0.id == sceneID }) {
                return s.name
            }
        }
        return nil
    }

    /// 1-click "Sync All to Bridge": creates missing rooms/zones, updates renamed/re-typed rooms,
    /// moves devices between rooms (1-room-per-device rule), updates zone memberships, and syncs
    /// linked Entertainment Area 2D/3D coordinates.
    func syncAllFloorplanToBridge() {
        guard !floorplanSyncing, (snapshot.hueBridgePaired || snapshot.isDemo) else { return }
        floorplanSyncing = true
        dismissedFloorplanDiffKey = ""

        Task { [weak self] in
            guard let self = self else { return }
            defer { self.floorplanSyncing = false }

            let plan = FloorplanSpatial.buildSyncPlan(floorplan: self.floorplan, snapshot: self.snapshot)

            // 1) Create any unlinked Room/Zone boxes that have lamps or need creation
            for box in plan.boxesToCreate {
                let initialIDs = self.deviceOrLightIDs(in: box)
                if let created = await self.client.createRoom(
                    kind: box.kind,
                    name: box.name,
                    archetype: box.archetype,
                    deviceIDs: initialIDs
                ), let idx = self.floorplan.boxes.firstIndex(where: { $0.id == box.id }) {
                    self.floorplan.boxes[idx].hueID = created
                }
            }
            self.persistFloorplan()

            // 2) Update renamed / re-archetyped rooms & zones
            for box in plan.boxesToUpdateMeta {
                guard let hueID = box.hueID else { continue }
                _ = await self.client.updateRoom(
                    id: hueID,
                    kind: box.kind,
                    name: box.name,
                    archetype: box.archetype,
                    deviceIDs: nil
                )
            }

            // 3) Coordinate 1-room-per-device membership moves
            let currentDiffs = FloorplanSpatial.pendingRoomMembershipDiffs(floorplan: self.floorplan, snapshot: self.snapshot)
            if !currentDiffs.isEmpty {
                // Build current device lists per bridge room
                var roomDevices: [String: [String]] = [:]
                for room in self.snapshot.rooms where room.kind == "room" && !room.hueID.isEmpty {
                    var seen = Set<String>()
                    var ids: [String] = []
                    for light in room.lights {
                        let key = light.deviceID.isEmpty ? light.id : light.deviceID
                        if seen.insert(key).inserted { ids.append(key) }
                    }
                    roomDevices[room.hueID] = ids
                }

                let initialRoomDevices = roomDevices
                var movedOutBySource: [String: Set<String>] = [:]
                var affectedDestRooms = Set<String>()

                for diff in currentDiffs {
                    guard let destBox = self.floorplan.boxes.first(where: { $0.id == diff.toBoxID }),
                          let destRoomID = destBox.hueID else { continue }
                    let devKey = diff.deviceID.isEmpty ? diff.lightID : diff.deviceID
                    if let srcRoomID = diff.fromRoomID, srcRoomID != destRoomID {
                        roomDevices[srcRoomID]?.removeAll { $0 == devKey }
                        movedOutBySource[srcRoomID, default: []].insert(devKey)
                    }
                    var destList = roomDevices[destRoomID] ?? []
                    if !destList.contains(devKey) {
                        destList.append(devKey)
                    }
                    roomDevices[destRoomID] = destList
                    affectedDestRooms.insert(destRoomID)
                }

                // Phase A: detach moved devices from EVERY source room first (handles A<->B swaps cleanly)
                for (srcID, movedOut) in movedOutBySource {
                    let pruned = (initialRoomDevices[srcID] ?? []).filter { !movedOut.contains($0) }
                    _ = await self.client.updateRoom(id: srcID, kind: "room", name: nil, archetype: nil, deviceIDs: pruned)
                }
                // Phase B: attach final membership to every destination room
                for dstID in affectedDestRooms {
                    _ = await self.client.updateRoom(id: dstID, kind: "room", name: nil, archetype: nil, deviceIDs: roomDevices[dstID] ?? [])
                }
            }

            // 4) Sync overlapping Zone boxes that are linked to a Bridge zone (including clearing empty zones)
            for box in self.floorplan.boxes where box.kind == "zone" {
                guard let hueID = box.hueID, HueColorMath.validUUID(hueID) else { continue }
                let enclosed = self.deviceOrLightIDs(in: box)
                let currentMembers: [String] = self.snapshot.rooms
                    .first(where: { $0.kind == "zone" && $0.hueID == hueID })?
                    .lights
                    .filter { HueColorMath.validUUID($0.id) }
                    .map(\.id) ?? []
                if Set(enclosed) != Set(currentMembers) {
                    _ = await self.client.updateRoom(id: hueID, kind: "zone", name: nil, archetype: nil, deviceIDs: enclosed)
                }
            }

            // 5) Sync linked Entertainment Area 2D/3D spatial positions
            var syncedAreaIDs = Set<String>()
            for box in self.floorplan.boxes {
                guard let areaID = box.entertainmentAreaID,
                      HueColorMath.validUUID(areaID),
                      syncedAreaIDs.insert(areaID).inserted else { continue }
                let positions = FloorplanSpatial.entertainmentPositions(forBox: box, floorplan: self.floorplan, snapshot: self.snapshot)
                if !positions.isEmpty {
                    _ = await self.client.updateEntertainmentLocations(areaID: areaID, positions: positions)
                }
            }
            if let docAreaID = self.floorplan.entertainmentAreaID,
               HueColorMath.validUUID(docAreaID),
               syncedAreaIDs.insert(docAreaID).inserted {
                let canvasBox = FloorplanBox(
                    kind: "room",
                    name: "Canvas",
                    x: 0,
                    y: 0,
                    width: self.floorplan.canvas.width,
                    height: self.floorplan.canvas.height,
                    entertainmentAreaID: docAreaID
                )
                let positions = FloorplanSpatial.entertainmentPositions(forBox: canvasBox, floorplan: self.floorplan, snapshot: self.snapshot)
                if !positions.isEmpty {
                    _ = await self.client.updateEntertainmentLocations(areaID: docAreaID, positions: positions)
                }
            }

            self.showTransientFloorplanStatus(self.tr("Synced floorplan to Hue Bridge"))
        }
    }

    private func triggerAutoSyncIfEnabled() {
        guard floorplan.autoSync, pendingFloorplanSyncPlan.hasRoomOrMetaChanges else { return }
        syncAllFloorplanToBridge()
    }

    private func deviceOrLightIDs(in box: FloorplanBox) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for (lightID, placement) in floorplan.lamps
            where placement.floorID == box.floorID
                && HueColorMath.validUUID(lightID)
                && box.contains(x: placement.x, y: placement.y) {
            if let light = snapshot.light(lightID) {
                let key = (box.kind == "zone") ? light.id : (light.deviceID.isEmpty ? light.id : light.deviceID)
                if seen.insert(key).inserted {
                    ids.append(key)
                }
            }
        }
        return ids
    }

    private func showTransientFloorplanStatus(_ message: String) {
        floorplanStatusMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if self?.floorplanStatusMessage == message {
                    self?.floorplanStatusMessage = nil
                }
            }
        }
    }

    // MARK: - Custom Floorplan Background Image

    func setFloorplanBackground(from url: URL) {
        do {
            let fileName = try settings.saveFloorplanBackground(from: url, bridgeID: currentBridgeID)
            floorplan.background.fileName = fileName
            floorplanBackgroundImage = settings.loadFloorplanBackgroundImage(fileName: fileName)
            floorplanBackgroundError = nil
            persistFloorplan()
        } catch SettingsError.fileTooLarge {
            floorplanBackgroundError = tr("Image is larger than 15 MB.")
        } catch {
            floorplanBackgroundError = tr("Unsupported image format. Choose PNG, JPEG, HEIC, or WebP.")
        }
    }

    func setFloorplanBackgroundOpacity(_ opacity: Double) {
        floorplan.background.opacity = HueColorMath.clamp(opacity, FloorplanBackground.minOpacity, FloorplanBackground.maxOpacity)
        persistFloorplan()
    }

    func setFloorplanBackgroundFit(_ fit: BackgroundFit) {
        floorplan.background.fit = fit
        persistFloorplan()
    }

    func clearFloorplanBackground() {
        settings.clearFloorplanBackground(fileName: floorplan.background.fileName)
        floorplan.background.fileName = nil
        floorplanBackgroundImage = nil
        floorplanBackgroundError = nil
        persistFloorplan()
    }
}

extension HueStore: HueToolBackend {
    var currentSnapshot: HueSnapshot { snapshot }
    var currentThemes: [HueLightTheme] { allThemes }
    var currentRules: [HueRule] { rules }
    var currentSchedules: [HueSchedule] { allSchedules }
    var currentFloorplan: FloorplanDocument? { floorplan }

    func setLight(id: String, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?) {
        client.setLight(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
    }

    func setRoom(room: HueRoom, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?) {
        setRoom(room, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
    }

    func recallScene(id: String) {
        client.recallScene(id: id)
    }

    func turnAllOn() {
        allOn(confirmed: true)
    }

    func turnAllOff() {
        allOff()
    }

    func setSensorEnabled(sensor: HueSensor, enabled: Bool) {
        setSensorEnabled(sensor, enabled: enabled)
    }

    func updateMotionArea(area: HueMotionArea, enabled: Bool?, sensitivity: Int?) {
        updateMotionArea(area, enabled: enabled, sensitivity: sensitivity)
    }

    func toggleRule(id: String, enabled: Bool) -> Bool {
        guard let rule = rules.first(where: { $0.id == id }) else { return false }
        toggleRule(rule, enabled: enabled)
        return true
    }

    func deleteRule(id: String) -> Bool {
        guard let rule = rules.first(where: { $0.id == id }) else { return false }
        deleteRule(rule)
        return true
    }
}
