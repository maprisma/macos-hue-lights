import Foundation

/// Playful, coordinated visual skins for the macOS app.
/// Selecting a skin sets coordinated defaults (backdrop, accent, corners, font), while
/// individual Appearance controls remain customizable afterwards.
public enum AppSkin: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case system
    case synthwave
    case cozyCabin
    case retroTerminal
    case discoLava
    case minimalZen

    public var id: String { rawValue }

    /// Primary accent hex (nil = native macOS accent color).
    public var accentHex: String? {
        switch self {
        case .system: return nil
        case .synthwave: return "#ff2e93"
        case .cozyCabin: return "#e59838"
        case .retroTerminal: return "#33ff66"
        case .discoLava: return "#ff5e7e"
        case .minimalZen: return "#64748b"
        }
    }

    /// Secondary decorative / glow hex for previews and subtle borders.
    public var secondaryHex: String {
        switch self {
        case .system: return "#0a84ff"
        case .synthwave: return "#00f0ff"
        case .cozyCabin: return "#a45a2a"
        case .retroTerminal: return "#16a34a"
        case .discoLava: return "#a855f7"
        case .minimalZen: return "#94a3b8"
        }
    }

    /// Preview backdrop hex for the skin picker swatch.
    public var previewBackgroundHex: String {
        switch self {
        case .system: return "#2c2c2e"
        case .synthwave: return "#130924"
        case .cozyCabin: return "#241913"
        case .retroTerminal: return "#0d120e"
        case .discoLava: return "#261233"
        case .minimalZen: return "#1f242c"
        }
    }

    /// Coordinated default appearance settings applied when switching to this skin.
    public var recommendedAppearance: AppearanceSettings {
        switch self {
        case .system:
            return AppearanceSettings(cornerStyle: .rounded, backgroundStyle: .system, fontFamily: .system, fontSize: .medium)
        case .synthwave:
            return AppearanceSettings(cornerStyle: .rounded, backgroundStyle: .midnight, fontFamily: .rounded, fontSize: .medium)
        case .cozyCabin:
            return AppearanceSettings(cornerStyle: .subtle, backgroundStyle: .dark, fontFamily: .serif, fontSize: .medium)
        case .retroTerminal:
            return AppearanceSettings(cornerStyle: .sharp, backgroundStyle: .dark, fontFamily: .mono, fontSize: .small)
        case .discoLava:
            return AppearanceSettings(cornerStyle: .rounded, backgroundStyle: .midnight, fontFamily: .rounded, fontSize: .medium)
        case .minimalZen:
            return AppearanceSettings(cornerStyle: .subtle, backgroundStyle: .tinted, fontFamily: .system, fontSize: .medium)
        }
    }
}

/// 8 selectable SF Symbol styles for the macOS menu bar item.
public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case bulb
    case deskLamp
    case tableLamp
    case sun
    case sparkles
    case flame
    case star
    case dot

    public var id: String { rawValue }

    public var offSymbol: String {
        switch self {
        case .bulb: return "lightbulb"
        case .deskLamp: return "lamp.desk"
        case .tableLamp: return "lamp.table"
        case .sun: return "sun.max"
        case .sparkles: return "sparkles"
        case .flame: return "flame"
        case .star: return "star"
        case .dot: return "circle"
        }
    }

    public var onSymbol: String {
        switch self {
        case .bulb: return "lightbulb.fill"
        case .deskLamp: return "lamp.desk.fill"
        case .tableLamp: return "lamp.table.fill"
        case .sun: return "sun.max.fill"
        case .sparkles: return "sparkles"
        case .flame: return "flame.fill"
        case .star: return "star.fill"
        case .dot: return "circle.fill"
        }
    }

    public func symbol(lit: Bool) -> String {
        lit ? onSymbol : offSymbol
    }
}

/// Actions bindable to App Sandbox-safe global macOS hotkeys (Carbon `RegisterEventHotKey`).
public enum HotKeyAction: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case allOff
    case allOn
    case toggleSynth
    case toggleFavorite

    public var id: String { rawValue }

    /// Stable numeric Carbon EventHotKeyID.
    public var carbonID: UInt32 {
        switch self {
        case .allOff: return 1001
        case .allOn: return 1002
        case .toggleSynth: return 1003
        case .toggleFavorite: return 1004
        }
    }
}

/// Curated conflict-free global hotkey presets (off by default).
public enum HotKeyPreset: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case none
    case ctrlOpt0
    case ctrlOpt1
    case ctrlOptM
    case ctrlOptF
    case cmdShiftOpt0
    case cmdShiftOpt1
    case cmdShiftOptM
    case cmdShiftOptF

    public var id: String { rawValue }

    public var displayLabel: String {
        switch self {
        case .none: return "Off"
        case .ctrlOpt0: return "⌃⌥0"
        case .ctrlOpt1: return "⌃⌥1"
        case .ctrlOptM: return "⌃⌥M"
        case .ctrlOptF: return "⌃⌥F"
        case .cmdShiftOpt0: return "⌘⇧⌥0"
        case .cmdShiftOpt1: return "⌘⇧⌥1"
        case .cmdShiftOptM: return "⌘⇧⌥M"
        case .cmdShiftOptF: return "⌘⇧⌥F"
        }
    }

    /// Carbon ANSI virtual key code (`kVK_ANSI_*`).
    public var keyCode: UInt32? {
        switch self {
        case .none: return nil
        case .ctrlOpt0, .cmdShiftOpt0: return 29 // kVK_ANSI_0
        case .ctrlOpt1, .cmdShiftOpt1: return 18 // kVK_ANSI_1
        case .ctrlOptM, .cmdShiftOptM: return 46 // kVK_ANSI_M
        case .ctrlOptF, .cmdShiftOptF: return 3  // kVK_ANSI_F
        }
    }

    /// Carbon modifier flags (`controlKey = 4096`, `optionKey = 2048`, `shiftKey = 512`, `cmdKey = 256`).
    public var carbonModifiers: UInt32 {
        switch self {
        case .none: return 0
        case .ctrlOpt0, .ctrlOpt1, .ctrlOptM, .ctrlOptF:
            return 4096 | 2048 // controlKey | optionKey
        case .cmdShiftOpt0, .cmdShiftOpt1, .cmdShiftOptM, .cmdShiftOptF:
            return 256 | 512 | 2048 // cmdKey | shiftKey | optionKey
        }
    }
}
