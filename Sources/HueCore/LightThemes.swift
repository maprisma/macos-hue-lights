import Foundation

/// A reusable per-lamp lighting preset (color or Kelvin warmth, brightness, optional native Hue effect).
public struct HueLightTheme: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var hex: String
    /// Non-nil when the theme primarily targets a Kelvin color temperature (153...500 mirek).
    public var mirek: Int?
    public var brightness: Int
    public var effect: String
    public var palette: [String]
    public var isBuiltIn: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, hex, mirek, brightness, effect, palette
        case isBuiltIn = "is_built_in"
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        symbol: String = "lightbulb.fill",
        hex: String = "#ffd27a",
        mirek: Int? = nil,
        brightness: Int = 80,
        effect: String = "no_effect",
        palette: [String] = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.hex = hex
        self.mirek = mirek
        self.brightness = HueColorMath.clamp(brightness, 1, 100)
        self.effect = effect.isEmpty ? "no_effect" : effect
        self.palette = palette.isEmpty ? [hex] : palette
        self.isBuiltIn = isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Theme"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "lightbulb.fill"
        hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? HueColorMath.defaultWarmHex
        mirek = try c.decodeIfPresent(Int.self, forKey: .mirek)
        brightness = HueColorMath.clamp(try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 80, 1, 100)
        let eff = try c.decodeIfPresent(String.self, forKey: .effect) ?? "no_effect"
        effect = eff.isEmpty ? "no_effect" : eff
        let pal = try c.decodeIfPresent([String].self, forKey: .palette) ?? []
        palette = pal.isEmpty ? [hex] : pal
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// 8 curated built-in themes covering focus, warmth, mood, and vivid color.
    public static let builtIn: [HueLightTheme] = [
        HueLightTheme(
            id: "builtin-deep-focus",
            name: "Deep Focus",
            symbol: "brain.head.profile",
            hex: HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(4200)),
            mirek: HueColorMath.kelvinToMirek(4200),
            brightness: 90,
            effect: "no_effect",
            palette: ["#eef6ff", "#dbeafe"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-golden-hour",
            name: "Golden Hour",
            symbol: "sun.horizon.fill",
            hex: HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(2400)),
            mirek: HueColorMath.kelvinToMirek(2400),
            brightness: 75,
            effect: "no_effect",
            palette: ["#ffbe6b", "#ff9e44"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-cozy-candle",
            name: "Cozy Candle",
            symbol: "flame.fill",
            hex: HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(2000)),
            mirek: HueColorMath.kelvinToMirek(2000),
            brightness: 45,
            effect: "candle",
            palette: ["#ff9933", "#ff6b2b"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-cyberpunk-neon",
            name: "Cyberpunk Neon",
            symbol: "bolt.fill",
            hex: "#ff2e93",
            mirek: nil,
            brightness: 85,
            effect: "prism",
            palette: ["#ff2e93", "#00f0ff"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-ocean-calm",
            name: "Ocean Calm",
            symbol: "drop.fill",
            hex: "#0077b6",
            mirek: nil,
            brightness: 65,
            effect: "no_effect",
            palette: ["#0077b6", "#48cae4"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-sunset-glow",
            name: "Sunset Glow",
            symbol: "sunset.fill",
            hex: "#ff6b35",
            mirek: nil,
            brightness: 70,
            effect: "no_effect",
            palette: ["#ff6b35", "#ffb703"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-forest-canopy",
            name: "Forest Canopy",
            symbol: "leaf.fill",
            hex: "#2d6a4f",
            mirek: nil,
            brightness: 60,
            effect: "no_effect",
            palette: ["#2d6a4f", "#95d5b2"],
            isBuiltIn: true
        ),
        HueLightTheme(
            id: "builtin-nightlight",
            name: "Nightlight",
            symbol: "moon.stars.fill",
            hex: HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(2000)),
            mirek: HueColorMath.kelvinToMirek(2000),
            brightness: 10,
            effect: "no_effect",
            palette: ["#ff9436", "#5c2e0e"],
            isBuiltIn: true
        ),
    ]

    /// Captures a lamp's current state as a new custom `HueLightTheme`.
    public static func fromLight(_ light: HueLight, name: String? = nil) -> HueLightTheme {
        let title = HueColorMath.clean(name ?? light.name)
        return HueLightTheme(
            id: UUID().uuidString.lowercased(),
            name: title.isEmpty ? "Custom Theme" : title,
            symbol: light.effect != "no_effect" ? "sparkles" : "lightbulb.fill",
            hex: light.color,
            mirek: light.supportsCT && !light.supportsColor ? light.mirek : nil,
            brightness: HueColorMath.clamp(Int(light.bri.rounded()), 1, 100),
            effect: light.effect,
            palette: [light.color],
            isBuiltIn: false
        )
    }

    public static let availableSymbols: [String] = [
        "lightbulb.fill", "sparkles", "flame.fill", "sun.horizon.fill",
        "sunset.fill", "moon.stars.fill", "bolt.fill", "drop.fill",
        "leaf.fill", "heart.fill", "star.fill", "music.note",
    ]
}
