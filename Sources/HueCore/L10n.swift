import Foundation

/// The 8 bundled interface languages, read from translations/bundled.json (the same catalogs as
/// the Linux apps; regenerate with `python3 tools/gen-translations`). Keys are the English texts;
/// a missing key shows the key itself. Polish plurals are [few, many] arrays.
public struct L10n: Equatable {
    public struct Language: Identifiable, Equatable {
        public let code: String
        public let name: String
        public var id: String { code }
    }

    public static let languages: [Language] = [
        Language(code: "en", name: "English"), Language(code: "de", name: "Deutsch"),
        Language(code: "fr", name: "Français"), Language(code: "es", name: "Español"),
        Language(code: "it", name: "Italiano"), Language(code: "pt", name: "Português"),
        Language(code: "nl", name: "Nederlands"), Language(code: "pl", name: "Polski"),
    ]

    public typealias Catalogs = [String: [String: [String]]]

    public let catalogs: Catalogs
    /// "auto" or one of the language codes.
    public let setting: String
    /// The language actually shown.
    public let code: String
    public let systemCode: String

    public init(catalogs: Catalogs, setting: String, preferred: [String] = Locale.preferredLanguages) {
        self.catalogs = catalogs
        systemCode = L10n.systemLanguage(preferred)
        let valid = setting == "auto" || L10n.languages.contains { $0.code == setting }
        self.setting = valid ? setting : "auto"
        code = self.setting == "auto" ? systemCode : self.setting
    }

    /// First preferred language we have ("de-DE" → "de", "pt_BR" → "pt"), else English.
    public static func systemLanguage(_ preferred: [String]) -> String {
        for tag in preferred {
            let base = tag.split(whereSeparator: { "-_.@".contains($0) }).first.map(String.init)?.lowercased() ?? ""
            if languages.contains(where: { $0.code == base }) { return base }
        }
        return "en"
    }

    /// bundled.json: {code: {key: text | [text, ...]}}. Unreadable → empty (English keys shown).
    public static func loadCatalogs(from url: URL?) -> Catalogs {
        guard let url = url, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var catalogs: Catalogs = [:]
        for (code, value) in root {
            guard let entries = value as? [String: Any] else { continue }
            var catalog: [String: [String]] = [:]
            for (key, text) in entries {
                if let s = text as? String {
                    catalog[key] = [s]
                } else if let list = text as? [Any] {
                    let strings = list.compactMap { $0 as? String }
                    if !strings.isEmpty { catalog[key] = strings }
                }
            }
            catalogs[code] = catalog
        }
        return catalogs
    }

    public func tr(_ key: String) -> String {
        catalogs[code]?[key]?.last ?? key
    }

    public func trf(_ key: String, _ args: [String]) -> String {
        var text = tr(key)
        if code == "pl", let forms = catalogs[code]?[key], forms.count >= 2 {
            let n = UInt64(args.first ?? "") ?? 0
            let few = (2...4).contains(n % 10) && !(12...14).contains(n % 100)
            text = forms[few ? 0 : 1]
        }
        return L10n.format(text, args)
    }

    /// "{0}", "{1}" … replaced in one pass: inserted values are never formatted again.
    public static func format(_ text: String, _ args: [String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            rest = rest[open...]
            if let close = rest.firstIndex(of: "}"),
               let index = Int(rest[rest.index(after: rest.startIndex)..<close]),
               index >= 0, index < args.count {
                result += args[index]
                rest = rest[rest.index(after: close)...]
                continue
            }
            result += "{"
            rest = rest.dropFirst()
        }
        return result + rest
    }

    public var systemName: String {
        L10n.languages.first { $0.code == systemCode }?.name ?? "English"
    }

    // MARK: - texts built from a snapshot (same wording as the Linux panels)

    public func errorText(_ s: HueSnapshot) -> String {
        let a = s.errorArgs
        switch s.errorCode {
        case "errPairFailed": return trf("Pairing failed: {0}", a)
        case "errCannotReach": return trf("Cannot reach {0} ({1})", a)
        case "errReply": return tr("The bridge sent a reply this app does not understand.")
        case "errInternal": return trf("Something went wrong ({0})", a)
        case "errCommand": return trf("Command failed ({0})", a)
        case "errEnterIp": return tr("Enter the bridge's local IPv4 address")
        case "errNoPress": return tr("No button press seen. Press the round button on the bridge, then try again.")
        case "errCert": return tr("The bridge certificate changed. Unpair and pair again if you replaced the bridge.")
        case "errRejected": return tr("The bridge no longer accepts this app. Unpair and pair again.")
        case "errUnreachable": return trf("Bridge not reachable ({0})", a)
        case "errNotHue": return trf("{0} does not look like a Hue bridge", a)
        default: return tr(s.error)
        }
    }

    public func roomName(_ room: HueRoom) -> String {
        room.kind == "other" ? tr("Other lights") : room.name
    }

    public func roomStatus(_ room: HueRoom) -> String {
        var parts: [String] = []
        if room.kind == "zone" { parts.append(tr("Zone")) }
        let total = room.lights.count
        if room.on {
            parts.append(trf("{0} of {1} on", [String(room.onCount), String(total)]))
        } else if total == 1 {
            parts.append(tr("Off · 1 light"))
        } else {
            parts.append(trf("Off · {0} lights", [String(total)]))
        }
        if room.unreachableCount > 0 {
            parts.append(trf("{0} unreachable", [String(room.unreachableCount)]))
        }
        return parts.joined(separator: " · ")
    }

    /// The menu bar tooltip / accessibility text.
    public func summary(_ s: HueSnapshot) -> String {
        switch s.phase {
        case "unpaired", "pairing": return tr("No bridge paired yet: click to pair")
        case "error": return s.error.isEmpty ? tr("Bridge not reachable") : errorText(s)
        default: return trf("{0} of {1} on", [String(s.onCount), String(s.lightCount)])
        }
    }
}

/// SF Symbol for a room card: the name wins when it is telling (many rooms keep the Hue app's
/// default archetype), then the Hue archetype. Same word lists as the Linux panels.
public func roomSymbol(_ room: HueRoom) -> String {
    switch room.kind {
    case "zone": return "square.grid.2x2"
    case "other": return "lightbulb"
    default: break
    }
    let name = room.name.lowercased()
    let byName: [([String], String)] = [
        (["schlaf", "bed", "kinder", "gäste", "guest", "nursery"], "bed.double"),
        (["küche", "kueche", "kitchen", "ess", "dining"], "fork.knife"),
        (["bad", "bath", "wc", "toilet", "dusche", "shower"], "shower"),
        (["büro", "buero", "office", "arbeit", "studio"], "desktopcomputer"),
        (["flur", "diele", "treppe", "hall", "stair", "eingang"], "door.left.hand.open"),
        (["garage", "carport"], "car"),
        (["garten", "terrasse", "balkon", "garden", "terrace", "balcony", "patio", "außen", "outdoor"], "leaf"),
        (["wohn", "living", "lounge", "tv"], "sofa"),
    ]
    for (words, symbol) in byName where words.contains(where: { name.contains($0) }) {
        return symbol
    }
    switch room.archetype {
    case "living_room", "lounge", "tv": return "sofa"
    case "kitchen", "dining": return "fork.knife"
    case "bedroom", "kids_bedroom", "guest_room", "nursery": return "bed.double"
    case "bathroom", "toilet": return "shower"
    case "office", "computer", "studio": return "desktopcomputer"
    case "hallway", "staircase", "top_floor", "upstairs", "downstairs": return "door.left.hand.open"
    case "garage", "carport", "driveway": return "car"
    case "garden", "terrace", "balcony", "porch", "barbecue", "pool", "front_door": return "leaf"
    default: return "house"
    }
}

/// "#rrggbb" from the bridge as 0...1 components; anything else is the warm white the helper
/// uses for "no colour".
public func rgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
    let chars = Array(hex)
    guard chars.count == 7, chars[0] == "#", let value = UInt32(String(chars[1...]), radix: 16) else {
        return (1.0, 0xd2 / 255.0, 0x7a / 255.0)
    }
    return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
}

/// Dark glyph on light colours, white on dark ones.
public func prefersDarkGlyph(_ hex: String) -> Bool {
    let c = rgb(hex)
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6
}
