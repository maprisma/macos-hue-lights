import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SettingsError: Error {
    case unknownLanguage
    case invalidSetting
    /// Settings directory is not a real folder owned by this user.
    case notPrivate
    case writeFailed
    case invalidImage
    case fileTooLarge
}

public enum ScheduleMode: String, CaseIterable, Identifiable, Equatable, Sendable {
    case bridge
    case local
    public var id: String { rawValue }
}

public enum CornerStyle: String, CaseIterable, Identifiable, Equatable, Sendable {
    case sharp
    case subtle
    case rounded

    public var id: String { rawValue }

    public var cardRadius: Double {
        switch self {
        case .sharp: return 4
        case .subtle: return 8
        case .rounded: return 12
        }
    }

    public var smallRadius: Double {
        switch self {
        case .sharp: return 3
        case .subtle: return 6
        case .rounded: return 8
        }
    }
}

public enum BackgroundStyle: String, CaseIterable, Identifiable, Equatable, Sendable {
    case system
    case tinted
    case dark
    case light
    case warm
    case midnight

    public var id: String { rawValue }
}

public enum FontFamily: String, CaseIterable, Identifiable, Equatable, Sendable {
    case system
    case rounded
    case serif
    case mono

    public var id: String { rawValue }
}

public enum FontSizeScale: String, CaseIterable, Identifiable, Equatable, Sendable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var multiplier: Double {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.15
        }
    }
}

public struct SavedWindowFrame: Equatable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 300 && height >= 300
    }

    /// Clamps this frame so it fits cleanly inside the best matching visible screen rectangle.
    public func clamped(
        to visibleScreens: [SavedWindowFrame],
        minWidth: Double = 460,
        minHeight: Double = 460
    ) -> SavedWindowFrame {
        guard !visibleScreens.isEmpty else {
            return SavedWindowFrame(
                x: x,
                y: y,
                width: max(minWidth, width),
                height: max(minHeight, height)
            )
        }
        let target = visibleScreens.max { a, b in
            intersectionArea(with: a) < intersectionArea(with: b)
        } ?? visibleScreens[0]
        let effectiveMinW = min(minWidth, max(0, target.width))
        let effectiveMinH = min(minHeight, max(0, target.height))
        let w = min(max(effectiveMinW, width), max(0, target.width))
        let h = min(max(effectiveMinH, height), max(0, target.height))
        let clampedX = min(max(x, target.x), target.x + max(0, target.width - w))
        let clampedY = min(max(y, target.y), target.y + max(0, target.height - h))
        return SavedWindowFrame(x: clampedX, y: clampedY, width: w, height: h)
    }

    private func intersectionArea(with other: SavedWindowFrame) -> Double {
        let overlapW = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let overlapH = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return overlapW * overlapH
    }
}

public struct AppearanceSettings: Equatable, Sendable {
    public var cornerStyle: CornerStyle
    public var backgroundStyle: BackgroundStyle
    public var fontFamily: FontFamily
    public var fontSize: FontSizeScale

    public static let `default` = AppearanceSettings(
        cornerStyle: .rounded,
        backgroundStyle: .system,
        fontFamily: .system,
        fontSize: .medium
    )

    public init(
        cornerStyle: CornerStyle = .rounded,
        backgroundStyle: BackgroundStyle = .system,
        fontFamily: FontFamily = .system,
        fontSize: FontSizeScale = .medium
    ) {
        self.cornerStyle = cornerStyle
        self.backgroundStyle = backgroundStyle
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// Codable snapshot of optional app-level preferences (including opt-in Ask AI settings).
/// Backwards-compatible: missing keys decode safely with `askAIEnabled = false`.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultAskAIOllamaURL = "http://127.0.0.1:11434"

    public var askAIEnabled: Bool = false
    public var askAIOllamaURL: String = AppSettings.defaultAskAIOllamaURL
    public var askAIModel: String = ""

    enum CodingKeys: String, CodingKey {
        case askAIEnabled
        case askAIOllamaURL
        case askAIModel
    }

    public init(
        askAIEnabled: Bool = false,
        askAIOllamaURL: String = AppSettings.defaultAskAIOllamaURL,
        askAIModel: String = ""
    ) {
        self.askAIEnabled = askAIEnabled
        self.askAIOllamaURL = askAIOllamaURL
        self.askAIModel = askAIModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        askAIEnabled = try c.decodeIfPresent(Bool.self, forKey: .askAIEnabled) ?? false
        let rawURL = try c.decodeIfPresent(String.self, forKey: .askAIOllamaURL) ?? AppSettings.defaultAskAIOllamaURL
        askAIOllamaURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettings.defaultAskAIOllamaURL
            : rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        askAIModel = (try c.decodeIfPresent(String.self, forKey: .askAIModel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// App Sandbox-safe preferences, local schedules & rules store.
/// On macOS, defaults to `Application Support/MaprismaLights` (automatically inside the app
/// sandbox container). Stores `settings.json`, `rules.json`, and `schedules.json` with atomic 0600 writes.
public struct SettingsStore {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("settings.json") }
    public var rulesFile: URL { directory.appendingPathComponent("rules.json") }
    public var localSchedulesFile: URL { directory.appendingPathComponent("schedules.json") }
    public var themesFile: URL { directory.appendingPathComponent("themes.json") }
    public var providersFile: URL { directory.appendingPathComponent("providers.json") }

    public init(directory: URL = SettingsStore.defaultDirectory()) {
        self.directory = directory
    }

    /// Sandbox-safe Application Support folder on macOS; XDG/home fallback on Linux.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if os(macOS)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("MaprismaLights", isDirectory: true)
        }
        #endif
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("hue-lights")
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config").appendingPathComponent("hue-lights")
    }

    public func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: file), data.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: - Per-Light Display Aliases (D1: rename hub-backed lights without renaming the hub connection)

    public func lightAliases() -> [String: String] {
        guard let raw = read()["light_aliases"] as? [String: String] else { return [:] }
        return raw
    }

    public func setLightAlias(_ alias: String, for lightID: String) throws {
        var settings = read()
        var map = (settings["light_aliases"] as? [String: String]) ?? [:]
        let clean = HueColorMath.clean(alias, limit: 40)
        if clean.isEmpty {
            map.removeValue(forKey: lightID)
        } else {
            map[lightID] = clean
        }
        settings["light_aliases"] = map
        try write(settings)
    }

    // MARK: - Language

    /// "auto" unless a known language code is saved.
    public func language() -> String {
        let saved = read()["language"] as? String ?? "auto"
        return saved == "auto" || L10n.languages.contains { $0.code == saved } ? saved : "auto"
    }

    public func setLanguage(_ code: String) throws {
        guard code == "auto" || L10n.languages.contains(where: { $0.code == code }) else {
            throw SettingsError.unknownLanguage
        }
        var settings = read()
        settings["language"] = code
        try write(settings)
    }

    // MARK: - Schedule Mode

    public func scheduleMode() -> ScheduleMode {
        guard let raw = read()["scheduleMode"] as? String,
              let mode = ScheduleMode(rawValue: raw) else { return .bridge }
        return mode
    }

    public func setScheduleMode(_ mode: ScheduleMode) throws {
        var settings = read()
        settings["scheduleMode"] = mode.rawValue
        try write(settings)
    }

    // MARK: - Appearance & Personalization

    public func cornerStyle() -> CornerStyle {
        guard let raw = read()["cornerStyle"] as? String,
              let style = CornerStyle(rawValue: raw) else { return .rounded }
        return style
    }

    public func setCornerStyle(_ style: CornerStyle) throws {
        var settings = read()
        settings["cornerStyle"] = style.rawValue
        try write(settings)
    }

    public func backgroundStyle() -> BackgroundStyle {
        guard let raw = read()["backgroundStyle"] as? String,
              let style = BackgroundStyle(rawValue: raw) else { return .system }
        return style
    }

    public func setBackgroundStyle(_ style: BackgroundStyle) throws {
        var settings = read()
        settings["backgroundStyle"] = style.rawValue
        try write(settings)
    }

    public func fontFamily() -> FontFamily {
        guard let raw = read()["fontFamily"] as? String,
              let family = FontFamily(rawValue: raw) else { return .system }
        return family
    }

    public func setFontFamily(_ family: FontFamily) throws {
        var settings = read()
        settings["fontFamily"] = family.rawValue
        try write(settings)
    }

    public func fontSize() -> FontSizeScale {
        guard let raw = read()["fontSize"] as? String,
              let size = FontSizeScale(rawValue: raw) else { return .medium }
        return size
    }

    public func setFontSize(_ size: FontSizeScale) throws {
        var settings = read()
        settings["fontSize"] = size.rawValue
        try write(settings)
    }

    public func appearance() -> AppearanceSettings {
        AppearanceSettings(
            cornerStyle: cornerStyle(),
            backgroundStyle: backgroundStyle(),
            fontFamily: fontFamily(),
            fontSize: fontSize()
        )
    }

    // MARK: - Skin, Menu Bar Icon & Global Hotkeys

    public func skin() -> AppSkin {
        guard let raw = read()["skin"] as? String,
              let s = AppSkin(rawValue: raw) else { return .system }
        return s
    }

    public func setSkin(_ skin: AppSkin) throws {
        var settings = read()
        settings["skin"] = skin.rawValue
        try write(settings)
    }

    public func menuBarIcon() -> MenuBarIconStyle {
        guard let raw = read()["menuBarIcon"] as? String,
              let style = MenuBarIconStyle(rawValue: raw) else { return .bulb }
        return style
    }

    public func setMenuBarIcon(_ style: MenuBarIconStyle) throws {
        var settings = read()
        settings["menuBarIcon"] = style.rawValue
        try write(settings)
    }

    public func showMenuBarCount() -> Bool {
        (read()["showMenuBarCount"] as? Bool) ?? false
    }

    public func setShowMenuBarCount(_ value: Bool) throws {
        var settings = read()
        settings["showMenuBarCount"] = value
        try write(settings)
    }

    public func hotKeys() -> [HotKeyAction: HotKeyPreset] {
        guard let raw = read()["hotKeys"] as? [String: String] else { return [:] }
        var result: [HotKeyAction: HotKeyPreset] = [:]
        for (k, v) in raw {
            if let action = HotKeyAction(rawValue: k), let preset = HotKeyPreset(rawValue: v), preset != .none {
                result[action] = preset
            }
        }
        return result
    }

    public func setHotKeys(_ map: [HotKeyAction: HotKeyPreset]) throws {
        var settings = read()
        var encoded: [String: String] = [:]
        for (action, preset) in map where preset != .none {
            encoded[action.rawValue] = preset.rawValue
        }
        settings["hotKeys"] = encoded
        try write(settings)
    }

    // MARK: - Custom Light Themes persistence

    public func loadCustomThemes() -> [HueLightTheme] {
        guard let data = try? Data(contentsOf: themesFile), data.count <= 512 * 1024 else { return [] }
        return (try? JSONDecoder().decode([HueLightTheme].self, from: data)) ?? []
    }

    public func saveCustomThemes(_ themes: [HueLightTheme]) throws {
        let customOnly = themes.filter { !$0.isBuiltIn }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(customOnly)
        try writeAtomic(data: data, to: themesFile, prefix: ".themes.")
    }

    // MARK: - Favorites, All On exclusions & preferences

    public func favorites() -> [String] {
        (read()["favorites"] as? [String]) ?? []
    }

    public func setFavorites(_ ids: [String]) throws {
        var settings = read()
        settings["favorites"] = ids
        try write(settings)
    }

    public func excludedFromAllOn() -> [String] {
        (read()["excludedFromAllOn"] as? [String]) ?? []
    }

    public func setExcludedFromAllOn(_ roomIDs: [String]) throws {
        var settings = read()
        settings["excludedFromAllOn"] = roomIDs
        try write(settings)
    }

    public func confirmAllOn() -> Bool {
        (read()["confirmAllOn"] as? Bool) ?? false
    }

    public func setConfirmAllOn(_ value: Bool) throws {
        var settings = read()
        settings["confirmAllOn"] = value
        try write(settings)
    }

    public func rulesPaused() -> Bool {
        (read()["rulesPaused"] as? Bool) ?? false
    }

    public func setRulesPaused(_ value: Bool) throws {
        var settings = read()
        settings["rulesPaused"] = value
        try write(settings)
    }

    // MARK: - Optional Ask AI (OFF by default)

    public func askAIEnabled() -> Bool {
        (read()["askAIEnabled"] as? Bool) ?? false
    }

    public func setAskAIEnabled(_ value: Bool) throws {
        var settings = read()
        settings["askAIEnabled"] = value
        try write(settings)
    }

    public func askAIOllamaURL() -> String {
        let raw = (read()["askAIOllamaURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? AppSettings.defaultAskAIOllamaURL : raw
    }

    public func setAskAIOllamaURL(_ value: String) throws {
        var settings = read()
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        settings["askAIOllamaURL"] = cleaned.isEmpty ? AppSettings.defaultAskAIOllamaURL : cleaned
        try write(settings)
    }

    public func askAIModel() -> String {
        (read()["askAIModel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setAskAIModel(_ value: String) throws {
        var settings = read()
        settings["askAIModel"] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(settings)
    }

    public func appSettings() -> AppSettings {
        AppSettings(
            askAIEnabled: askAIEnabled(),
            askAIOllamaURL: askAIOllamaURL(),
            askAIModel: askAIModel()
        )
    }

    // MARK: - Non-Authoritative Pro Cache (Headless CLI Hint Only)

    /// Informational cache written after StoreKit 2 verifies `Transaction.currentEntitlements`.
    /// IMPORTANT: GUI builds must NEVER trust this flag for unlocking Pro features — always verify
    /// directly via StoreKit 2 (`Transaction.currentEntitlements`). This exists solely as a
    /// non-crashing hint for headless CLI tools (`--mcp`).
    public func lastVerifiedPro() -> Bool {
        (read()["lastVerifiedPro"] as? Bool) ?? false
    }

    public func setLastVerifiedPro(_ value: Bool) throws {
        var settings = read()
        settings["lastVerifiedPro"] = value
        try write(settings)
    }

    // MARK: - Detached Window Frame (size & screen position)

    public func windowFrame() -> SavedWindowFrame? {
        guard let dict = read()["windowFrame"] as? [String: Any] else { return nil }
        func num(_ key: String) -> Double? {
            if let d = dict[key] as? Double { return d }
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let x = num("x"), let y = num("y"), let w = num("width"), let h = num("height") else {
            return nil
        }
        let frame = SavedWindowFrame(x: x, y: y, width: w, height: h)
        return frame.isValid ? frame : nil
    }

    public func setWindowFrame(_ frame: SavedWindowFrame) throws {
        guard frame.isValid else { return }
        var settings = read()
        settings["windowFrame"] = [
            "x": frame.x.rounded(),
            "y": frame.y.rounded(),
            "width": frame.width.rounded(),
            "height": frame.height.rounded(),
        ]
        try write(settings)
    }

    // MARK: - Rules & Local Schedules persistence

    public func loadRules() -> [HueRule] {
        guard let data = try? Data(contentsOf: rulesFile), data.count <= 512 * 1024 else { return [] }
        return (try? JSONDecoder().decode([HueRule].self, from: data)) ?? []
    }

    public func saveRules(_ rules: [HueRule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try writeAtomic(data: data, to: rulesFile, prefix: ".rules.")
    }

    public func loadLocalSchedules() -> [HueSchedule] {
        guard let data = try? Data(contentsOf: localSchedulesFile), data.count <= 512 * 1024 else { return [] }
        return (try? JSONDecoder().decode([HueSchedule].self, from: data)) ?? []
    }

    public func saveLocalSchedules(_ schedules: [HueSchedule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(schedules)
        try writeAtomic(data: data, to: localSchedulesFile, prefix: ".schedules.")
    }

    // MARK: - Multi-Device Providers persistence (`providers.json`)

    public func loadProviders() -> [ProviderConnection] {
        guard let data = try? Data(contentsOf: providersFile), data.count <= 256 * 1024 else { return [] }
        return (try? JSONDecoder().decode([ProviderConnection].self, from: data)) ?? []
    }

    public func saveProviders(_ providers: [ProviderConnection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(providers)
        try writeAtomic(data: data, to: providersFile, prefix: ".providers.")
    }

    // MARK: - Spatial Floorplan & Custom Background Image persistence

    public static let maxFloorplanBytes: Int = 1024 * 1024
    public static let maxBackgroundImageBytes: Int = 15 * 1024 * 1024

    public func floorplanFile(for bridgeID: String) -> URL {
        let safe = Self.safeBridgeSlug(bridgeID)
        if safe.isEmpty {
            return directory.appendingPathComponent("floorplan.json")
        }
        return directory.appendingPathComponent("floorplan-\(safe).json")
    }

    public func loadFloorplan(bridgeID: String) -> FloorplanDocument? {
        let target = floorplanFile(for: bridgeID)
        if let data = try? Data(contentsOf: target),
           data.count <= Self.maxFloorplanBytes,
           let doc = try? JSONDecoder().decode(FloorplanDocument.self, from: data) {
            return doc
        }
        // Fallback to legacy unkeyed floorplan.json if bridgeID matches
        let legacy = directory.appendingPathComponent("floorplan.json")
        if legacy != target,
           let data = try? Data(contentsOf: legacy),
           data.count <= Self.maxFloorplanBytes,
           let doc = try? JSONDecoder().decode(FloorplanDocument.self, from: data),
           doc.bridgeID.caseInsensitiveCompare(bridgeID) == .orderedSame {
            return doc
        }
        return nil
    }

    public func saveFloorplan(_ document: FloorplanDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let target = floorplanFile(for: document.bridgeID)
        try writeAtomic(data: data, to: target, prefix: ".floorplan.")
    }

    /// Validates `.png/.jpg/.jpeg/.heic/.webp` and max 15 MB, copies bytes into the sandboxed
    /// Application Support directory with `0600` permissions, and returns the safe basename.
    public func saveFloorplanBackground(from sourceURL: URL, bridgeID: String = "") throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        guard FloorplanBackground.allowedExtensions.contains(ext) else {
            throw SettingsError.invalidImage
        }
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        if let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size > Self.maxBackgroundImageBytes {
            throw SettingsError.fileTooLarge
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw SettingsError.invalidImage }
        guard data.count <= Self.maxBackgroundImageBytes else { throw SettingsError.fileTooLarge }

        let slug = Self.safeBridgeSlug(bridgeID)
        let prefix = slug.isEmpty ? "floorplan-bg" : "floorplan-bg-\(slug)"
        let fileName = "\(prefix).\(ext)"
        guard let safeName = FloorplanBackground.sanitizeFileName(fileName) else {
            throw SettingsError.invalidImage
        }

        // Remove any previous background with a different extension for this bridge
        let fm = FileManager.default
        for oldExt in FloorplanBackground.allowedExtensions where oldExt != ext {
            let oldURL = directory.appendingPathComponent("\(prefix).\(oldExt)")
            try? fm.removeItem(at: oldURL)
        }

        let destination = directory.appendingPathComponent(safeName)
        try writeAtomic(data: data, to: destination, prefix: ".floorplan-bg.")
        return safeName
    }

    /// Strictly resolves a validated basename inside `directory`, preventing any path traversal.
    public func floorplanBackgroundURL(fileName: String?) -> URL? {
        guard let safeName = FloorplanBackground.sanitizeFileName(fileName) else { return nil }
        let url = directory.appendingPathComponent(safeName)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return url
    }

    public func clearFloorplanBackground(fileName: String?) {
        guard let url = floorplanBackgroundURL(fileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    #if canImport(AppKit)
    public func loadFloorplanBackgroundImage(fileName: String?) -> NSImage? {
        guard let url = floorplanBackgroundURL(fileName: fileName),
              let data = try? Data(contentsOf: url),
              data.count <= Self.maxBackgroundImageBytes else { return nil }
        return NSImage(data: data)
    }
    #endif

    private static func safeBridgeSlug(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            return (0x30...0x39).contains(v)
                || (0x41...0x5A).contains(v)
                || (0x61...0x7A).contains(v)
                || v == 0x2D
                || v == 0x5F
        }
        return String(String(String.UnicodeScalarView(filtered)).prefix(32))
    }

    // MARK: - Low-level atomic write

    public func write(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try writeAtomic(data: data, to: file, prefix: ".settings.")
    }

    private func writeAtomic(data: Data, to destination: URL, prefix: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw SettingsError.notPrivate
        }
        if info.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        let temp = directory.appendingPathComponent("\(prefix)\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SettingsError.writeFailed
        }
        if rename(temp.path, destination.path) != 0 {
            try? fm.removeItem(at: temp)
            throw SettingsError.writeFailed
        }
    }
}
