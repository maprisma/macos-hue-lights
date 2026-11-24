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

    enum Page { case main, settings }
    enum MainTab: String, CaseIterable, Identifiable {
        case lights, schedules, rules, synth
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

    // Launch at Login (SMAppService, macOS 13+)
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    // Quick-create & editor sheets
    @Published var showNewScheduleSheet: Bool = false
    @Published var schedulePrefillTarget: (kind: String, id: String)?
    @Published var showNewRuleSheet: Bool = false
    @Published var rulePrefillTrigger: (kind: String, id: String)?
    @Published var themeEditorLight: HueLight?

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
        cachedWindowFrame = settings.windowFrame()
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        let nativeClient = NativeHueBridgeClient(rules: savedRules, rulesPaused: savedPaused)
        client = nativeClient

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

        attachClient(nativeClient)
    }

    private func attachClient(_ newClient: HueBridgeControlling) {
        client = newClient
        client.onSnapshot = { [weak self] snapshot in
            self?.receive(snapshot)
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
    }

    // MARK: - Demo Mode

    func enterDemoMode() {
        stopSynth()
        client.stop()
        expanded.removeAll()
        allScenes.removeAll()
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
        tab = .lights
    }

    func exitDemoMode() {
        guard snapshot.isDemo else { return }
        stopSynth()
        client.stop()
        expanded.removeAll()
        allScenes.removeAll()
        synthSource = .systemAudio
        let savedRules = settings.loadRules()
        let savedPaused = settings.rulesPaused()
        rules = savedRules
        rulesPaused = savedPaused
        let native = NativeHueBridgeClient(rules: savedRules, rulesPaused: savedPaused)
        attachClient(native)
        native.start()
        page = .main
        tab = .lights
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
        case .tinted: return skinAccentColor.opacity(0.08)
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

    func setBackgroundStyle(_ style: BackgroundStyle) {
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
        if scheduleMode == .local {
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
                sceneID: "",
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
        if let light = snapshot.light(id) {
            return light.name
        }
        return id
    }

    // MARK: - Bridge

    func discover() { client.discover() }

    func pair(_ ip: String) {
        let ip = cleanedIP(ip)
        if !ip.isEmpty { client.pair(ip: ip) }
    }

    func cancelPair() { client.cancelPair() }

    func unpair() {
        stopSynth()
        confirmUnpair = false
        expanded.removeAll()
        allScenes.removeAll()
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
}
