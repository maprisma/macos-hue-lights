import Foundation

// The helper's snapshot (one JSON object per stdout line), see scripts/hue-lights.py `snapshot()`.
// Every field is read defensively: a missing or mistyped value becomes the neutral default.

public struct HueLight: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let on: Bool
    public let bri: Double
    public let dimmable: Bool
    public let color: String
    public let reachable: Bool

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        name = JSONValue.string(json, "name")
        on = JSONValue.bool(json, "on")
        bri = JSONValue.number(json, "bri")
        dimmable = JSONValue.bool(json, "dimmable")
        color = JSONValue.string(json, "color")
        reachable = (json["reachable"] as? Bool) ?? true
    }
}

public struct HueScene: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let active: Bool

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        name = JSONValue.string(json, "name")
        active = JSONValue.bool(json, "active")
    }
}

public struct HueRoom: Identifiable, Equatable {
    /// Stable key for the UI: the room/zone id, or the kind ("other") for lights in no room.
    public let id: String
    public let hueID: String
    public let kind: String
    public let name: String
    public let groupedLight: String
    public let on: Bool
    public let bri: Double
    public let onCount: Int
    public let archetype: String
    public let color: String
    public let lights: [HueLight]
    public let scenes: [HueScene]

    public init(json: [String: Any]) {
        hueID = JSONValue.string(json, "id")
        kind = JSONValue.string(json, "kind")
        id = hueID.isEmpty ? kind : hueID
        name = JSONValue.string(json, "name")
        groupedLight = JSONValue.string(json, "grouped_light")
        on = JSONValue.bool(json, "on")
        bri = JSONValue.number(json, "bri")
        onCount = Int(JSONValue.number(json, "on_count"))
        archetype = JSONValue.string(json, "archetype")
        color = JSONValue.string(json, "color")
        lights = JSONValue.objects(json, "lights").map(HueLight.init(json:))
        scenes = JSONValue.objects(json, "scenes").map(HueScene.init(json:))
    }

    public var unreachableCount: Int { lights.filter { !$0.reachable }.count }
}

public struct BridgeCandidate: Identifiable, Equatable {
    public var id: String { ip }
    public let ip: String
    public let bridgeID: String
    public let name: String

    public init(json: [String: Any]) {
        ip = JSONValue.string(json, "ip")
        bridgeID = JSONValue.string(json, "bridge_id")
        let n = JSONValue.string(json, "name")
        name = n.isEmpty ? "Hue Bridge" : n
    }
}

public struct BridgeInfo: Equatable {
    public let ip: String
    public let name: String
    public let model: String

    /// "Name · 192.168.1.2", as in the Linux panels.
    public var text: String {
        let shown = name.isEmpty ? "Hue Bridge" : name
        return ip.isEmpty ? shown : "\(shown) · \(ip)"
    }
}

public struct HueSnapshot: Equatable {
    public var phase: String
    public var error: String
    public var errorCode: String
    public var errorArgs: [String]
    public var bridge: BridgeInfo?
    public var rooms: [HueRoom]
    public var lightCount: Int
    public var onCount: Int
    public var candidates: [BridgeCandidate]
    public var discovering: Bool
    public var pairIP: String
    public var pairRemaining: Int

    /// Before the helper's first line: no bridge known yet, nothing on.
    public static let initial = HueSnapshot(json: ["phase": "connecting"])

    public init(json: [String: Any]) {
        let p = JSONValue.string(json, "phase")
        phase = p.isEmpty ? "connecting" : p
        error = JSONValue.string(json, "error")
        errorCode = JSONValue.string(json, "error_code")
        errorArgs = ((json["error_args"] as? [Any]) ?? []).map { value in
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return String(describing: value)
        }
        if let b = json["bridge"] as? [String: Any], !b.isEmpty {
            bridge = BridgeInfo(ip: JSONValue.string(b, "ip"), name: JSONValue.string(b, "name"),
                                model: JSONValue.string(b, "model"))
        } else {
            bridge = nil
        }
        rooms = JSONValue.objects(json, "rooms").map(HueRoom.init(json:))
        lightCount = Int(JSONValue.number(json, "light_count"))
        onCount = Int(JSONValue.number(json, "on_count"))
        candidates = JSONValue.objects(json, "candidates").map(BridgeCandidate.init(json:))
        discovering = JSONValue.bool(json, "discovering")
        pairIP = JSONValue.string(json, "pair_ip")
        pairRemaining = Int(JSONValue.number(json, "pair_remaining"))
    }

    /// One stdout line of the helper; nil for anything that is not a JSON object (a partial
    /// line while the helper exits, stray output).
    public static func parse(line: String) -> HueSnapshot? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return HueSnapshot(json: dict)
    }

    /// A bridge is saved (connected, connecting or failing): show rooms, not pairing.
    public var isPaired: Bool { ["ok", "error", "connecting"].contains(phase) }
    public var isPairing: Bool { phase == "pairing" }
    /// The menu bar bulb is lit while any light is on.
    public var anyLightOn: Bool { onCount > 0 }

    public func room(_ key: String) -> HueRoom? { rooms.first { $0.id == key } }
}

enum JSONValue {
    static func string(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }

    static func bool(_ d: [String: Any], _ k: String) -> Bool { (d[k] as? Bool) == true }

    static func number(_ d: [String: Any], _ k: String) -> Double {
        let v: Double
        switch d[k] {
        case let n as NSNumber: v = n.doubleValue
        case let n as Double: v = n
        case let n as Int: v = Double(n)
        default: return 0
        }
        return v.isFinite ? v : 0
    }

    static func objects(_ d: [String: Any], _ k: String) -> [[String: Any]] {
        ((d[k] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }
}
