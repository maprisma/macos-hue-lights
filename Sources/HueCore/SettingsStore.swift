import Foundation
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

/// App Sandbox-safe preferences, local schedules & rules store.
/// On macOS, defaults to `Application Support/MaprismaLights` (automatically inside the app
/// sandbox container). Stores `settings.json`, `rules.json`, and `schedules.json` with atomic 0600 writes.
public struct SettingsStore {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("settings.json") }
    public var rulesFile: URL { directory.appendingPathComponent("rules.json") }
    public var localSchedulesFile: URL { directory.appendingPathComponent("schedules.json") }
    public var themesFile: URL { directory.appendingPathComponent("themes.json") }

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
