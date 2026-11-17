import Foundation

/// The helper's stdin commands, one JSON object per line (see `Hue.handle` in hue-lights.py).
public enum HueCommand: Equatable {
    /// Popover shown / hidden: the helper polls every 2 s while open, every 20 s while closed.
    case panelOpen
    case panelClosed
    case refresh
    case discover
    case pair(ip: String)
    case cancelPair
    case unpair
    case light(id: String, on: Bool? = nil, bri: Int? = nil)
    case group(id: String, on: Bool? = nil, bri: Int? = nil)
    case scene(id: String)
    case allOff

    public var json: [String: Any] {
        switch self {
        case .panelOpen: return ["cmd": "panel_open"]
        case .panelClosed: return ["cmd": "panel_closed"]
        case .refresh: return ["cmd": "refresh"]
        case .discover: return ["cmd": "discover"]
        case .pair(let ip): return ["cmd": "pair", "ip": ip]
        case .cancelPair: return ["cmd": "cancel_pair"]
        case .unpair: return ["cmd": "unpair"]
        case .allOff: return ["cmd": "all_off"]
        case .scene(let id): return ["cmd": "scene", "id": id]
        case .light(let id, let on, let bri): return Self.control("light", id, on, bri)
        case .group(let id, let on, let bri): return Self.control("group", id, on, bri)
        }
    }

    /// The line written to the helper's stdin (no trailing newline), keys sorted.
    public var line: String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func control(_ cmd: String, _ id: String, _ on: Bool?, _ bri: Int?) -> [String: Any] {
        var object: [String: Any] = ["cmd": cmd, "id": id]
        if let on = on { object["on"] = on }
        if let bri = bri { object["bri"] = bri }
        return object
    }

    /// A whole room / zone: one grouped-light command when the bridge has a group for it, else
    /// one command per light ("Other lights"), as the Linux panels do.
    public static func room(_ room: HueRoom, on: Bool? = nil, bri: Int? = nil) -> [HueCommand] {
        if !room.groupedLight.isEmpty {
            return [.group(id: room.groupedLight, on: on, bri: bri)]
        }
        return room.lights.map { .light(id: $0.id, on: on, bri: bri) }
    }
}

/// Brightness 1...100 % in steps of 5 (1 at the bottom), like the Linux sliders.
public func brightnessStep(_ value: Double) -> Int {
    guard value.isFinite else { return 1 }
    return Int(min(100, max(1, (value / 5).rounded() * 5)))
}

/// Bridge IP the user typed: trimmed and at most 64 characters (the helper validates it).
public func cleanedIP(_ text: String) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
}
