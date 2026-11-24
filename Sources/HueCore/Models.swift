import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// Pure-Swift Hue domain models, color math, and CLIP v2 resource builder.
// Every JSON field is read defensively so malformed bridge replies degrade safely.

public struct HueLight: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public var deviceID: String = ""
    public let name: String
    public let on: Bool
    public let bri: Double
    public let dimmable: Bool
    public let color: String
    public let reachable: Bool
    public let supportsColor: Bool
    public let supportsCT: Bool
    public let mirek: Int?
    public let mirekMin: Int
    public let mirekMax: Int
    public let effect: String
    public let availableEffects: [String]
    public var motionAware: Bool = false
    public var motionActive: Bool = false

    public init(
        id: String,
        deviceID: String = "",
        name: String,
        on: Bool,
        bri: Double,
        dimmable: Bool,
        color: String,
        reachable: Bool = true,
        supportsColor: Bool = false,
        supportsCT: Bool = false,
        mirek: Int? = nil,
        mirekMin: Int = 153,
        mirekMax: Int = 500,
        effect: String = "no_effect",
        availableEffects: [String] = [],
        motionAware: Bool = false,
        motionActive: Bool = false
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.on = on
        self.bri = bri
        self.dimmable = dimmable
        self.color = color
        self.reachable = reachable
        self.supportsColor = supportsColor
        self.supportsCT = supportsCT
        self.mirek = mirek
        self.mirekMin = mirekMin
        self.mirekMax = mirekMax
        self.effect = effect
        self.availableEffects = availableEffects
        self.motionAware = motionAware
        self.motionActive = motionActive
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        deviceID = JSONValue.string(json, "device_id")
        name = JSONValue.string(json, "name")
        on = JSONValue.bool(json, "on")
        bri = JSONValue.number(json, "bri")
        dimmable = JSONValue.bool(json, "dimmable")
        color = JSONValue.string(json, "color")
        reachable = (json["reachable"] as? Bool) ?? true
        supportsColor = JSONValue.bool(json, "supports_color")
        supportsCT = JSONValue.bool(json, "supports_ct")
        mirek = JSONValue.optionalInt(json, "mirek")
        let minM = JSONValue.optionalInt(json, "mirek_min") ?? 153
        let maxM = JSONValue.optionalInt(json, "mirek_max") ?? 500
        mirekMin = min(minM, maxM)
        mirekMax = max(minM, maxM)
        let eff = JSONValue.string(json, "effect")
        effect = eff.isEmpty ? "no_effect" : eff
        availableEffects = JSONValue.strings(json, "available_effects")
        motionAware = JSONValue.bool(json, "motion_aware")
        motionActive = JSONValue.bool(json, "motion_active")
    }
}

public struct HueScene: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let active: Bool

    public init(id: String, name: String, active: Bool) {
        self.id = id
        self.name = name
        self.active = active
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        name = JSONValue.string(json, "name")
        active = JSONValue.bool(json, "active")
    }
}

public struct HueRoom: Identifiable, Equatable, Hashable, Sendable {
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

    public init(
        hueID: String,
        kind: String,
        name: String,
        groupedLight: String,
        on: Bool,
        bri: Double,
        onCount: Int,
        archetype: String,
        color: String,
        lights: [HueLight],
        scenes: [HueScene]
    ) {
        self.hueID = hueID
        self.kind = kind
        self.id = hueID.isEmpty ? kind : hueID
        self.name = name
        self.groupedLight = groupedLight
        self.on = on
        self.bri = bri
        self.onCount = onCount
        self.archetype = archetype
        self.color = color
        self.lights = lights
        self.scenes = scenes
    }

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

public struct BridgeCandidate: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { ip }
    public let ip: String
    public let bridgeID: String
    public let name: String

    public init(ip: String, bridgeID: String, name: String) {
        self.ip = ip
        self.bridgeID = bridgeID
        self.name = name.isEmpty ? "Hue Bridge" : name
    }

    public init(json: [String: Any]) {
        ip = JSONValue.string(json, "ip")
        bridgeID = JSONValue.string(json, "bridge_id")
        let n = JSONValue.string(json, "name")
        name = n.isEmpty ? "Hue Bridge" : n
    }
}

public struct BridgeInfo: Equatable, Hashable, Codable, Sendable {
    public let ip: String
    public let name: String
    public let model: String
    public var modelID: String = ""
    public var isPro: Bool = false
    public var motionAreaCandidates: Int = 0

    enum CodingKeys: String, CodingKey {
        case ip, name, model
        case modelID = "model_id"
        case isPro = "is_pro"
        case motionAreaCandidates = "motion_area_candidates"
    }

    public init(
        ip: String,
        name: String,
        model: String,
        modelID: String = "",
        isPro: Bool = false,
        motionAreaCandidates: Int = 0
    ) {
        self.ip = ip
        self.name = name
        self.model = model
        let resolvedModelID = modelID.isEmpty ? model : modelID
        self.modelID = resolvedModelID
        self.isPro = isPro || resolvedModelID.uppercased() == "BSB003"
        self.motionAreaCandidates = max(0, motionAreaCandidates)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        let modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        let isPro = try c.decodeIfPresent(Bool.self, forKey: .isPro) ?? false
        let candidates = try c.decodeIfPresent(Int.self, forKey: .motionAreaCandidates) ?? 0
        self.init(
            ip: ip,
            name: name,
            model: model,
            modelID: modelID,
            isPro: isPro,
            motionAreaCandidates: candidates
        )
    }

    /// "Name · 192.168.1.2", as in the Linux panels.
    public var text: String {
        let shown = name.isEmpty ? "Hue Bridge" : name
        return ip.isEmpty ? shown : "\(shown) · \(ip)"
    }
}

public struct HueMotionArea: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var roomID: String
    public var motion: Bool
    public var motionValid: Bool
    public var sensitivity: Int?
    public var sensitivityMax: Int?
    public var convenienceID: String
    public var lightIDs: [String]
    public var health: String

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case roomID = "room_id"
        case motion
        case motionValid = "motion_valid"
        case sensitivity
        case sensitivityMax = "sensitivity_max"
        case convenienceID = "convenience_id"
        case lightIDs = "light_ids"
        case health
    }

    public init(
        id: String,
        name: String,
        enabled: Bool = true,
        roomID: String = "",
        motion: Bool = false,
        motionValid: Bool = true,
        sensitivity: Int? = nil,
        sensitivityMax: Int? = nil,
        convenienceID: String = "",
        lightIDs: [String] = [],
        health: String = "ready"
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.roomID = roomID
        self.motion = motion
        self.motionValid = motionValid
        self.sensitivity = sensitivity
        self.sensitivityMax = sensitivityMax
        self.convenienceID = convenienceID
        self.lightIDs = lightIDs
        self.health = health
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        name = JSONValue.string(json, "name")
        enabled = (json["enabled"] as? Bool) ?? true
        roomID = JSONValue.string(json, "room_id")
        motion = JSONValue.bool(json, "motion")
        motionValid = (json["motion_valid"] as? Bool) ?? true
        sensitivity = JSONValue.optionalInt(json, "sensitivity")
        sensitivityMax = JSONValue.optionalInt(json, "sensitivity_max")
        convenienceID = JSONValue.string(json, "convenience_id")
        lightIDs = JSONValue.strings(json, "light_ids")
        let h = JSONValue.string(json, "health")
        health = h.isEmpty ? "ready" : h
    }
}

public struct HueSensor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var deviceID: String
    /// "motion" | "contact" | "button"
    public var kind: String
    public var name: String
    public var roomID: String
    public var enabled: Bool
    public var motion: Bool
    public var open: Bool
    public var temperature: Double?
    public var lux: Double?
    public var battery: Int?
    public var batteryState: String
    public var sensitivity: Int?
    public var sensitivityMax: Int?
    public var buttonIDs: [String]
    public var lastEvent: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case kind, name
        case roomID = "room_id"
        case enabled, motion, open, temperature, lux, battery
        case batteryState = "battery_state"
        case sensitivity
        case sensitivityMax = "sensitivity_max"
        case buttonIDs = "button_ids"
        case lastEvent = "last_event"
    }

    public init(
        id: String,
        deviceID: String = "",
        kind: String,
        name: String,
        roomID: String = "",
        enabled: Bool = true,
        motion: Bool = false,
        open: Bool = false,
        temperature: Double? = nil,
        lux: Double? = nil,
        battery: Int? = nil,
        batteryState: String = "",
        sensitivity: Int? = nil,
        sensitivityMax: Int? = nil,
        buttonIDs: [String] = [],
        lastEvent: String = ""
    ) {
        self.id = id
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.roomID = roomID
        self.enabled = enabled
        self.motion = motion
        self.open = open
        self.temperature = temperature
        self.lux = lux
        self.battery = battery
        self.batteryState = batteryState
        self.sensitivity = sensitivity
        self.sensitivityMax = sensitivityMax
        self.buttonIDs = buttonIDs
        self.lastEvent = lastEvent
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        deviceID = JSONValue.string(json, "device_id")
        kind = JSONValue.string(json, "kind")
        name = JSONValue.string(json, "name")
        roomID = JSONValue.string(json, "room_id")
        enabled = (json["enabled"] as? Bool) ?? true
        motion = JSONValue.bool(json, "motion")
        open = JSONValue.bool(json, "open")
        temperature = HueColorMath.finite(json["temperature"], low: -50.0, high: 120.0)
        lux = HueColorMath.finite(json["lux"], low: 0.0, high: 200_000.0)
        battery = JSONValue.optionalInt(json, "battery")
        batteryState = JSONValue.string(json, "battery_state")
        sensitivity = JSONValue.optionalInt(json, "sensitivity")
        sensitivityMax = JSONValue.optionalInt(json, "sensitivity_max")
        buttonIDs = JSONValue.strings(json, "button_ids")
        lastEvent = JSONValue.string(json, "last_event")
    }
}

public struct HueSchedule: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// "light", "room", "zone", or "bridge_home"
    public var targetKind: String
    public var targetID: String
    public var targetName: String
    /// "time", "sunrise", or "sunset"
    public var triggerKind: String
    /// "HH:MM" when triggerKind == "time"
    public var time: String
    /// Offset in minutes for sunrise/sunset (-60...60)
    public var offsetMin: Int
    /// Weekday names: ["monday", "tuesday", ...], empty = daily
    public var days: [String]
    /// "on", "off", or "scene"
    public var action: String
    public var bri: Int?
    public var sceneID: String
    public var fadeMin: Int
    /// Always "bridge" for schedules stored on the Hue Bridge.
    public var source: String

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case targetKind = "target_kind"
        case targetID = "target_id"
        case targetName = "target_name"
        case triggerKind = "trigger_kind"
        case time
        case offsetMin = "offset_min"
        case days, action, bri
        case sceneID = "scene_id"
        case fadeMin = "fade_min"
        case source
    }

    public init(
        id: String,
        name: String,
        enabled: Bool = true,
        targetKind: String,
        targetID: String,
        targetName: String,
        triggerKind: String = "time",
        time: String = "07:00",
        offsetMin: Int = 0,
        days: [String] = [],
        action: String = "on",
        bri: Int? = 80,
        sceneID: String = "",
        fadeMin: Int = 0,
        source: String = "bridge"
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.targetKind = targetKind
        self.targetID = targetID
        self.targetName = targetName
        self.triggerKind = triggerKind
        self.time = time
        self.offsetMin = offsetMin
        self.days = days
        self.action = action
        self.bri = bri
        self.sceneID = sceneID
        self.fadeMin = fadeMin
        self.source = source
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        name = JSONValue.string(json, "name")
        enabled = (json["enabled"] as? Bool) ?? true
        targetKind = JSONValue.string(json, "target_kind")
        targetID = JSONValue.string(json, "target_id")
        targetName = JSONValue.string(json, "target_name")
        let tk = JSONValue.string(json, "trigger_kind")
        triggerKind = tk.isEmpty ? "time" : tk
        time = JSONValue.string(json, "time")
        offsetMin = JSONValue.optionalInt(json, "offset_min") ?? 0
        days = JSONValue.strings(json, "days")
        let act = JSONValue.string(json, "action")
        action = act.isEmpty ? "on" : act
        bri = JSONValue.optionalInt(json, "bri")
        sceneID = JSONValue.string(json, "scene_id")
        fadeMin = JSONValue.optionalInt(json, "fade_min") ?? 0
        let src = JSONValue.string(json, "source")
        source = src.isEmpty ? "bridge" : src
    }
}

public struct HueRuleTarget: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var kind: String
    public var id: String
    public var action: String
    public var bri: Int?
    public var sceneID: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, action, bri
        case sceneID = "scene_id"
    }

    public init(
        kind: String,
        id: String,
        action: String = "on",
        bri: Int? = nil,
        sceneID: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.action = action
        self.bri = bri
        self.sceneID = sceneID
    }
}

public struct HueRule: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// "follow", "exclusive", "companion", or "desktop"
    public var kind: String
    /// "light", "room", or "desktop"
    public var triggerKind: String
    public var triggerID: String
    /// "on", "off", "wake", or "sleep"
    public var triggerState: String
    public var targets: [HueRuleTarget]
    public var mirrorOff: Bool
    public var matchBri: Bool
    public var timeStart: String
    public var timeEnd: String
    public var onlyIfOff: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind
        case triggerKind = "trigger_kind"
        case triggerID = "trigger_id"
        case triggerState = "trigger_state"
        case targets
        case mirrorOff = "mirror_off"
        case matchBri = "match_bri"
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case onlyIfOff = "only_if_off"
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        enabled: Bool = true,
        kind: String = "follow",
        triggerKind: String = "light",
        triggerID: String,
        triggerState: String = "on",
        targets: [HueRuleTarget],
        mirrorOff: Bool = false,
        matchBri: Bool = false,
        timeStart: String = "",
        timeEnd: String = "",
        onlyIfOff: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.triggerKind = triggerKind
        self.triggerID = triggerID
        self.triggerState = triggerState
        self.targets = targets
        self.mirrorOff = mirrorOff
        self.matchBri = matchBri
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.onlyIfOff = onlyIfOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "follow"
        triggerKind = try c.decodeIfPresent(String.self, forKey: .triggerKind) ?? "light"
        triggerID = try c.decodeIfPresent(String.self, forKey: .triggerID) ?? ""
        triggerState = try c.decodeIfPresent(String.self, forKey: .triggerState) ?? "on"
        targets = try c.decodeIfPresent([HueRuleTarget].self, forKey: .targets) ?? []
        mirrorOff = try c.decodeIfPresent(Bool.self, forKey: .mirrorOff) ?? false
        matchBri = try c.decodeIfPresent(Bool.self, forKey: .matchBri) ?? false
        timeStart = try c.decodeIfPresent(String.self, forKey: .timeStart) ?? ""
        timeEnd = try c.decodeIfPresent(String.self, forKey: .timeEnd) ?? ""
        onlyIfOff = try c.decodeIfPresent(Bool.self, forKey: .onlyIfOff) ?? false
    }
}

public struct HueRuleLogEntry: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var timestamp: Date
    public var ruleID: String
    public var ruleName: String
    public var message: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        timestamp: Date = Date(),
        ruleID: String,
        ruleName: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.message = message
    }
}

public struct HueSnapshot: Equatable, Sendable {
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
    public var bridgeHomeGroupedLight: String
    public var schedules: [HueSchedule]
    public var rules: [HueRule]
    public var rulesPaused: Bool
    public var ruleLog: [HueRuleLogEntry]
    public var entertainmentAreas: [HueEntertainmentArea]
    public var motionAreas: [HueMotionArea]
    public var sensors: [HueSensor]
    public var isDemo: Bool

    /// Before the first bridge state arrives: no bridge known yet, nothing on.
    public static let initial = HueSnapshot(phase: "connecting")

    public init(
        phase: String = "connecting",
        error: String = "",
        errorCode: String = "",
        errorArgs: [String] = [],
        bridge: BridgeInfo? = nil,
        rooms: [HueRoom] = [],
        lightCount: Int = 0,
        onCount: Int = 0,
        candidates: [BridgeCandidate] = [],
        discovering: Bool = false,
        pairIP: String = "",
        pairRemaining: Int = 0,
        bridgeHomeGroupedLight: String = "",
        schedules: [HueSchedule] = [],
        rules: [HueRule] = [],
        rulesPaused: Bool = false,
        ruleLog: [HueRuleLogEntry] = [],
        entertainmentAreas: [HueEntertainmentArea] = [],
        motionAreas: [HueMotionArea] = [],
        sensors: [HueSensor] = [],
        isDemo: Bool = false
    ) {
        self.phase = phase.isEmpty ? "connecting" : phase
        self.error = error
        self.errorCode = errorCode
        self.errorArgs = errorArgs
        self.bridge = bridge
        self.rooms = rooms
        self.lightCount = lightCount
        self.onCount = onCount
        self.candidates = candidates
        self.discovering = discovering
        self.pairIP = pairIP
        self.pairRemaining = pairRemaining
        self.bridgeHomeGroupedLight = bridgeHomeGroupedLight
        self.schedules = schedules
        self.rules = rules
        self.rulesPaused = rulesPaused
        self.ruleLog = ruleLog
        self.entertainmentAreas = entertainmentAreas
        self.motionAreas = motionAreas
        self.sensors = sensors
        self.isDemo = isDemo
    }

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
            bridge = BridgeInfo(
                ip: JSONValue.string(b, "ip"),
                name: JSONValue.string(b, "name"),
                model: JSONValue.string(b, "model"),
                modelID: JSONValue.string(b, "model_id"),
                isPro: JSONValue.bool(b, "is_pro"),
                motionAreaCandidates: JSONValue.optionalInt(b, "motion_area_candidates") ?? 0
            )
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
        bridgeHomeGroupedLight = JSONValue.string(json, "bridge_home_grouped_light")
        schedules = JSONValue.objects(json, "schedules").map(HueSchedule.init(json:))
        rules = []
        rulesPaused = JSONValue.bool(json, "rules_paused")
        ruleLog = []
        entertainmentAreas = []
        motionAreas = JSONValue.objects(json, "motion_areas").map(HueMotionArea.init(json:))
        sensors = JSONValue.objects(json, "sensors").map(HueSensor.init(json:))
        isDemo = JSONValue.bool(json, "is_demo")
    }

    /// Parses a JSON snapshot line; nil for anything that is not a JSON object.
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

    public func light(_ id: String) -> HueLight? {
        for room in rooms {
            if let found = room.lights.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    public func sensor(_ id: String) -> HueSensor? {
        sensors.first { $0.id == id || $0.buttonIDs.contains(id) }
    }

    public func motionArea(_ id: String) -> HueMotionArea? {
        motionAreas.first { $0.id == id || (!$0.convenienceID.isEmpty && $0.convenienceID == id) }
    }

    public func motionAreas(forRoom roomID: String) -> [HueMotionArea] {
        guard !roomID.isEmpty else { return [] }
        return motionAreas.filter { $0.roomID == roomID }
    }

    /// Unique lights across non-zone rooms (each light appears once).
    public var allLights: [HueLight] {
        var seen = Set<String>()
        var result: [HueLight] = []
        for room in rooms where room.kind != "zone" {
            for light in room.lights where seen.insert(light.id).inserted {
                result.append(light)
            }
        }
        if result.isEmpty {
            for room in rooms {
                for light in room.lights where seen.insert(light.id).inserted {
                    result.append(light)
                }
            }
        }
        return result
    }
}

// MARK: - Color Math, Validation & Sanitization

public enum HueColorMath {
    public static let defaultWarmHex = "#ffd27a"

    public static func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
        min(high, max(low, value))
    }

    public static func finite(_ value: Any?, low: Double, high: Double) -> Double? {
        let number: Double
        switch value {
        case is Bool: return nil
        case let d as Double: number = d
        case let f as Float: number = Double(f)
        case let i as Int: number = Double(i)
        case let n as NSNumber:
            #if canImport(CoreFoundation)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            #endif
            number = n.doubleValue
        case let s as String:
            guard let parsed = Double(s) else { return nil }
            number = parsed
        default:
            return nil
        }
        guard number.isFinite else { return nil }
        return clamp(number, low, high)
    }

    /// Names come from the bridge or mDNS: strip control chars and markup characters.
    public static func clean(_ text: String, limit: Int = 60) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            if scalar == "<" || scalar == ">" || scalar == "&" { return false }
            let v = scalar.value
            if v < 0x20 || v == 0x7F { return false }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        let trimmed = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    public static func validUUID(_ value: String?) -> Bool {
        guard let s = value, s.count == 36 else { return false }
        let bytes = Array(s.utf8)
        for (idx, b) in bytes.enumerated() {
            if idx == 8 || idx == 13 || idx == 18 || idx == 23 {
                if b != 0x2D { return false } // '-'
            } else {
                let isDigit = (0x30...0x39).contains(b)
                let isLowerHex = (0x61...0x66).contains(b)
                if !isDigit && !isLowerHex { return false }
            }
        }
        return true
    }

    public static func validBridgeID(_ value: String?) -> Bool {
        guard let s = value, s.count == 16 else { return false }
        return s.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
        }
    }

    /// Only private or link-local IPv4 literals (RFC1918 + 169.254.0.0/16): the bridge lives on the LAN.
    public static func validBridgeIP(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), (0...255).contains(n) else { return false }
            if part.count > 1 && part.first == "0" { return false }
            octets.append(n)
        }
        let (a, b) = (octets[0], octets[1])
        if a == 10 { return true }                              // 10.0.0.0/8
        if a == 172 && (16...31).contains(b) { return true }    // 172.16.0.0/12
        if a == 192 && b == 168 { return true }                 // 192.168.0.0/16
        if a == 169 && b == 254 { return true }                 // 169.254.0.0/16 link-local
        return false
    }

    private static func srgbGamma(_ c: Double) -> Double {
        let clamped = clamp(c, 0.0, 1.0)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }

    private static func inverseGamma(_ c: Double) -> Double {
        let clamped = clamp(c, 0.0, 1.0)
        return clamped > 0.04045 ? pow((clamped + 0.055) / 1.055, 2.4) : clamped / 12.92
    }

    /// CIE xy (Hue colour) to an sRGB "#rrggbb" hex string at full brightness.
    public static func xyToHex(x: Double, y: Double) -> String {
        guard x.isFinite, y.isFinite, x >= 0.0, x <= 1.0, y > 0.0, y <= 1.0 else {
            return defaultWarmHex
        }
        let z = 1.0 - x - y
        let bigY = 1.0
        let bigX = (bigY / y) * x
        let bigZ = (bigY / y) * z
        var r = bigX * 1.656492 - bigY * 0.354851 - bigZ * 0.255038
        var g = -bigX * 0.707196 + bigY * 1.655397 + bigZ * 0.036152
        var b = bigX * 0.051713 - bigY * 0.121364 + bigZ * 1.011530
        let peak = max(r, max(g, b))
        if peak > 1.0 {
            r /= peak
            g /= peak
            b /= peak
        }
        let ri = Int((srgbGamma(r) * 255.0).rounded())
        let gi = Int((srgbGamma(g) * 255.0).rounded())
        let bi = Int((srgbGamma(b) * 255.0).rounded())
        return String(format: "#%02x%02x%02x", clamp(ri, 0, 255), clamp(gi, 0, 255), clamp(bi, 0, 255))
    }

    /// sRGB "#rrggbb" hex string to CIE xy for Hue CLIP v2 color commands.
    public static func hexToXY(_ hex: String) -> (x: Double, y: Double)? {
        let chars = Array(hex)
        guard chars.count == 7, chars[0] == "#",
              let value = UInt32(String(chars[1...]), radix: 16) else { return nil }
        let r = inverseGamma(Double((value >> 16) & 0xFF) / 255.0)
        let g = inverseGamma(Double((value >> 8) & 0xFF) / 255.0)
        let b = inverseGamma(Double(value & 0xFF) / 255.0)
        let bigX = r * 0.664511 + g * 0.154324 + b * 0.162028
        let bigY = r * 0.283881 + g * 0.668433 + b * 0.047685
        let bigZ = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = bigX + bigY + bigZ
        guard sum > 0 else { return nil }
        let x = clamp(bigX / sum, 0.0, 1.0)
        let y = clamp(bigY / sum, 0.0, 1.0)
        return ((x * 10000.0).rounded() / 10000.0, (y * 10000.0).rounded() / 10000.0)
    }

    /// Colour temperature (mirek) to approximate sRGB hex (Tanner Helland fit).
    public static func mirekToHex(_ mirek: Int) -> String {
        guard mirek >= 1 && mirek <= 1_000_000 else { return defaultWarmHex }
        let kelvin = 1_000_000.0 / Double(mirek)
        let t = clamp(kelvin, 1000.0, 40000.0) / 100.0
        let r: Double
        let g: Double
        let b: Double
        if t <= 66.0 {
            r = 255.0
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19.0 ? 0.0 : 138.5177312231 * log(t - 10.0) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60.0, -0.1332047592)
            g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
            b = 255.0
        }
        return String(format: "#%02x%02x%02x",
                      Int(clamp(r, 0.0, 255.0)),
                      Int(clamp(g, 0.0, 255.0)),
                      Int(clamp(b, 0.0, 255.0)))
    }

    public static func mirekToKelvin(_ mirek: Int) -> Int {
        guard mirek > 0 else { return 2700 }
        return Int((1_000_000.0 / Double(mirek)).rounded())
    }

    public static func kelvinToMirek(_ kelvin: Int) -> Int {
        guard kelvin > 0 else { return 370 }
        return clamp(Int((1_000_000.0 / Double(kelvin)).rounded()), 153, 500)
    }

    /// Average of "#rrggbb" strings (room swatch), warm white when empty.
    public static func blendColors(_ colors: [String]) -> String {
        var rSum = 0, gSum = 0, bSum = 0, count = 0
        for c in colors {
            let chars = Array(c)
            guard chars.count == 7, chars[0] == "#",
                  let v = UInt32(String(chars[1...]), radix: 16) else { continue }
            rSum += Int((v >> 16) & 0xFF)
            gSum += Int((v >> 8) & 0xFF)
            bSum += Int(v & 0xFF)
            count += 1
        }
        guard count > 0 else { return defaultWarmHex }
        let r = Int((Double(rSum) / Double(count)).rounded())
        let g = Int((Double(gSum) / Double(count)).rounded())
        let b = Int((Double(bSum) / Double(count)).rounded())
        return String(format: "#%02x%02x%02x", clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255))
    }
}

// MARK: - CLIP v2 Resource Model Builder

public struct HueBuiltModel: Equatable, Sendable {
    public let rooms: [HueRoom]
    public let lightCount: Int
    public let onCount: Int
    public let bridgeHomeGroupedLight: String
    public let scheduleScriptID: String
    public let schedules: [HueSchedule]
    public let entertainmentAreas: [HueEntertainmentArea]
    public let entertainmentServiceByLight: [String: String]
    public let bridgeModelID: String
    public let isPro: Bool
    public let motionAreaCandidates: Int
    public let motionAreas: [HueMotionArea]
    public let sensors: [HueSensor]
    public let sensorServiceToSensorID: [String: String]
    public let securityMotionToAreaID: [String: String]

    public init(
        rooms: [HueRoom],
        lightCount: Int,
        onCount: Int,
        bridgeHomeGroupedLight: String,
        scheduleScriptID: String,
        schedules: [HueSchedule],
        entertainmentAreas: [HueEntertainmentArea] = [],
        entertainmentServiceByLight: [String: String] = [:],
        bridgeModelID: String = "",
        isPro: Bool = false,
        motionAreaCandidates: Int = 0,
        motionAreas: [HueMotionArea] = [],
        sensors: [HueSensor] = [],
        sensorServiceToSensorID: [String: String] = [:],
        securityMotionToAreaID: [String: String] = [:]
    ) {
        self.rooms = rooms
        self.lightCount = lightCount
        self.onCount = onCount
        self.bridgeHomeGroupedLight = bridgeHomeGroupedLight
        self.scheduleScriptID = scheduleScriptID
        self.schedules = schedules
        self.entertainmentAreas = entertainmentAreas
        self.entertainmentServiceByLight = entertainmentServiceByLight
        self.bridgeModelID = bridgeModelID
        self.isPro = isPro
        self.motionAreaCandidates = max(0, motionAreaCandidates)
        self.motionAreas = motionAreas
        self.sensors = sensors
        self.sensorServiceToSensorID = sensorServiceToSensorID
        self.securityMotionToAreaID = securityMotionToAreaID
    }
}

public enum HueModelBuilder {
    public static let maxGroupLights = 150
    public static let maxMemberships = 1000
    public static let maxGroupScenes = 100
    public static let maxScenes = 1000
    /// Hue Bridge built-in schedule / timer behavior_script UUID.
    public static let defaultScheduleScriptID = "ff8957e3-2eb9-4699-a0c8-ad2cb3ede704"

    public static func build(from resources: [[String: Any]]) -> HueBuiltModel {
        var byType: [String: [[String: Any]]] = [:]
        for res in resources {
            if let type = res["type"] as? String {
                byType[type, default: []].append(res)
            }
        }

        var lights: [String: [String: Any]] = [:]
        for r in byType["light"] ?? [] {
            if let id = r["id"] as? String, HueColorMath.validUUID(id) {
                lights[id] = r
            }
        }

        var grouped: [String: [String: Any]] = [:]
        for r in byType["grouped_light"] ?? [] {
            if let id = r["id"] as? String, HueColorMath.validUUID(id) {
                grouped[id] = r
            }
        }

        var devices: [String: [String: Any]] = [:]
        for r in byType["device"] ?? [] {
            if let id = r["id"] as? String, HueColorMath.validUUID(id) {
                devices[id] = r
            }
        }

        var connectivity: [String: Bool] = [:]
        for zc in byType["zigbee_connectivity"] ?? [] {
            if let owner = (zc["owner"] as? [String: Any])?["rid"] as? String {
                connectivity[owner] = (zc["status"] as? String) == "connected"
            }
        }

        func lightColor(_ light: [String: Any]) -> String {
            let ct = light["color_temperature"] as? [String: Any] ?? [:]
            if (ct["mirek_valid"] as? Bool) == true,
               let m = JSONValue.optionalInt(ct, "mirek"), m > 0 {
                return HueColorMath.mirekToHex(m)
            }
            if let xy = (light["color"] as? [String: Any])?["xy"] as? [String: Any],
               let x = HueColorMath.finite(xy["x"], low: 0.0, high: 1.0),
               let y = HueColorMath.finite(xy["y"], low: 0.0, high: 1.0) {
                return HueColorMath.xyToHex(x: x, y: y)
            }
            if let m = JSONValue.optionalInt(ct, "mirek"), m > 0 {
                return HueColorMath.mirekToHex(m)
            }
            return HueColorMath.defaultWarmHex
        }

        var motionAwareLights = Set<String>()
        var motionActiveLights = Set<String>()

        func makeLight(_ light: [String: Any]) -> HueLight {
            let id = light["id"] as? String ?? ""
            let meta = light["metadata"] as? [String: Any] ?? [:]
            let name = HueColorMath.clean((meta["name"] as? String) ?? "Light")
            let isOn = ((light["on"] as? [String: Any])?["on"] as? Bool) ?? false
            let dimming = light["dimming"] as? [String: Any]
            let briRaw = HueColorMath.finite(dimming?["brightness"], low: 0.0, high: 100.0) ?? 100.0
            let bri = (briRaw * 10.0).rounded() / 10.0
            let owner = (light["owner"] as? [String: Any])?["rid"] as? String
            let reachable = owner.flatMap { connectivity[$0] } ?? true

            let supportsColor = light["color"] is [String: Any]
            let ct = light["color_temperature"] as? [String: Any]
            let schema = ct?["mirek_schema"] as? [String: Any]
            let mirek = ct.flatMap { JSONValue.optionalInt($0, "mirek") }
            let mirekMin = schema.flatMap { JSONValue.optionalInt($0, "mirek_minimum") } ?? 153
            let mirekMax = schema.flatMap { JSONValue.optionalInt($0, "mirek_maximum") } ?? 500
            let supportsCT = schema != nil || mirek != nil

            let effects = light["effects"] as? [String: Any]
            let currentEffect = (effects?["status"] as? String) ?? "no_effect"
            let rawEffects = (effects?["status_values"] as? [String]) ??
                ((effects?["effect_values"] as? [String]) ?? [])
            let availableEffects = rawEffects.filter { $0 != "no_effect" && !$0.isEmpty }

            return HueLight(
                id: id,
                deviceID: owner ?? "",
                name: name.isEmpty ? "Light" : name,
                on: isOn,
                bri: bri,
                dimmable: dimming != nil,
                color: lightColor(light),
                reachable: reachable,
                supportsColor: supportsColor,
                supportsCT: supportsCT,
                mirek: mirek,
                mirekMin: min(mirekMin, mirekMax),
                mirekMax: max(mirekMin, mirekMax),
                effect: currentEffect.isEmpty ? "no_effect" : currentEffect,
                availableEffects: availableEffects,
                motionAware: motionAwareLights.contains(id),
                motionActive: motionActiveLights.contains(id)
            )
        }

        // Map each device to its light service IDs (deduped, capped) and optional entertainment service ID
        var deviceLights: [String: [String]] = [:]
        var entertainmentServiceByLight: [String: String] = [:]
        for (did, device) in devices {
            var found: [String] = []
            var seen = Set<String>()
            var entServiceID: String? = nil
            for svc in (device["services"] as? [[String: Any]]) ?? [] {
                let rtype = svc["rtype"] as? String
                let rid = svc["rid"] as? String
                if rtype == "light",
                   let rid = rid,
                   lights[rid] != nil,
                   seen.insert(rid).inserted {
                    found.append(rid)
                    if found.count >= maxGroupLights { break }
                } else if rtype == "entertainment",
                          let rid = rid,
                          HueColorMath.validUUID(rid) {
                    entServiceID = rid
                }
            }
            deviceLights[did] = found
            if let entID = entServiceID {
                for lid in found {
                    entertainmentServiceByLight[lid] = entID
                }
            }
        }

        // Detect Hue Bridge model_id (Bridge Pro = BSB003) from the bridge device
        var bridgeModelID = ""
        var bridgeDeviceIDs = Set<String>()
        for br in byType["bridge"] ?? [] {
            if let owner = (br["owner"] as? [String: Any])?["rid"] as? String {
                bridgeDeviceIDs.insert(owner)
            }
        }
        for (did, device) in devices {
            let pdata = device["product_data"] as? [String: Any] ?? [:]
            let mid = HueColorMath.clean((pdata["model_id"] as? String) ?? "", limit: 30)
            if bridgeDeviceIDs.contains(did) && !mid.isEmpty {
                bridgeModelID = mid
                break
            }
            if bridgeModelID.isEmpty && mid.uppercased().hasPrefix("BSB") {
                bridgeModelID = mid
            }
        }

        // Bridge Pro MotionAware™: motion_area_candidate, convenience_area_motion, security_area_motion, motion_area_configuration
        var candidateLights: [String: [String]] = [:]
        for cand in byType["motion_area_candidate"] ?? [] {
            guard let cid = cand["id"] as? String, HueColorMath.validUUID(cid) else { continue }
            var found: [String] = []
            if let owner = cand["owner"] as? [String: Any],
               let rid = owner["rid"] as? String,
               let rtype = owner["rtype"] as? String {
                if rtype == "device" {
                    found.append(contentsOf: deviceLights[rid] ?? [])
                } else if rtype == "light", lights[rid] != nil {
                    found.append(rid)
                }
            }
            if found.isEmpty {
                for svc in (cand["services"] as? [[String: Any]]) ?? [] {
                    if let rid = svc["rid"] as? String, let rtype = svc["rtype"] as? String {
                        if rtype == "light", lights[rid] != nil {
                            found.append(rid)
                        } else if rtype == "device" {
                            found.append(contentsOf: deviceLights[rid] ?? [])
                        }
                    }
                }
            }
            candidateLights[cid] = found
        }

        var convenienceByID: [String: [String: Any]] = [:]
        var convenienceByConfigID: [String: String] = [:]
        for conv in byType["convenience_area_motion"] ?? [] {
            guard let cid = conv["id"] as? String, HueColorMath.validUUID(cid) else { continue }
            convenienceByID[cid] = conv
            if let owner = (conv["owner"] as? [String: Any])?["rid"] as? String, HueColorMath.validUUID(owner) {
                convenienceByConfigID[owner] = cid
            }
        }

        var securityByID: [String: [String: Any]] = [:]
        var securityByConfigID: [String: String] = [:]
        var securityMotionToAreaID: [String: String] = [:]
        for sec in byType["security_area_motion"] ?? [] {
            guard let sid = sec["id"] as? String, HueColorMath.validUUID(sid) else { continue }
            securityByID[sid] = sec
            if let owner = (sec["owner"] as? [String: Any])?["rid"] as? String, HueColorMath.validUUID(owner) {
                securityByConfigID[owner] = sid
                securityMotionToAreaID[sid] = owner
            }
        }

        func parseSensitivity(_ dict: [String: Any]?) -> (Int?, Int?) {
            guard let dict = dict else { return (nil, nil) }
            if let sDict = dict["sensitivity"] as? [String: Any] {
                return (JSONValue.optionalInt(sDict, "sensitivity"), JSONValue.optionalInt(sDict, "sensitivity_max"))
            }
            if let sDict = dict["motion_area_sensitivity"] as? [String: Any] {
                return (JSONValue.optionalInt(sDict, "sensitivity"), JSONValue.optionalInt(sDict, "sensitivity_max"))
            }
            if let val = JSONValue.optionalInt(dict, "sensitivity") {
                return (val, JSONValue.optionalInt(dict, "sensitivity_max"))
            }
            return (nil, nil)
        }

        func parseMotionFlag(_ dict: [String: Any]?) -> (motion: Bool?, valid: Bool?) {
            guard let mDict = dict?["motion"] as? [String: Any] else { return (nil, nil) }
            let val = (mDict["motion"] as? Bool) ?? ((mDict["motion_report"] as? [String: Any])?["motion"] as? Bool)
            let valid = mDict["motion_valid"] as? Bool
            return (val, valid)
        }

        var motionAreas: [HueMotionArea] = []
        for cfg in byType["motion_area_configuration"] ?? [] {
            guard let cfgID = cfg["id"] as? String, HueColorMath.validUUID(cfgID) else { continue }
            let meta = cfg["metadata"] as? [String: Any] ?? [:]
            let rawName = HueColorMath.clean((cfg["name"] as? String) ?? (meta["name"] as? String) ?? "MotionAware")
            let areaName = rawName.isEmpty ? "MotionAware" : rawName
            let enabled = (cfg["enabled"] as? Bool) ?? true

            var roomID = ""
            if let group = cfg["group"] as? [String: Any], let rid = group["rid"] as? String, HueColorMath.validUUID(rid) {
                roomID = rid
            } else if let room = cfg["room"] as? [String: Any], let rid = room["rid"] as? String, HueColorMath.validUUID(rid) {
                roomID = rid
            } else if let whereList = cfg["where"] as? [[String: Any]], let first = whereList.first {
                let g = (first["group"] as? [String: Any]) ?? first
                if let rid = g["rid"] as? String, HueColorMath.validUUID(rid) {
                    roomID = rid
                }
            }

            let convID = ((cfg["convenience_area_motion"] as? [String: Any])?["rid"] as? String)
                ?? convenienceByConfigID[cfgID] ?? ""
            let secID = ((cfg["security_area_motion"] as? [String: Any])?["rid"] as? String)
                ?? securityByConfigID[cfgID] ?? ""
            if !secID.isEmpty {
                securityMotionToAreaID[secID] = cfgID
            }

            let conv = convenienceByID[convID]
            let sec = securityByID[secID]
            let convMotion = parseMotionFlag(conv)
            let secMotion = parseMotionFlag(sec)
            let cfgMotion = parseMotionFlag(cfg)
            let isMotion = convMotion.motion ?? secMotion.motion ?? cfgMotion.motion ?? false
            let isValid = convMotion.valid ?? secMotion.valid ?? cfgMotion.valid ?? true

            let cfgSens = parseSensitivity(cfg)
            let convSens = parseSensitivity(conv)
            let sensitivity = cfgSens.0 ?? convSens.0
            let sensitivityMax = cfgSens.1 ?? convSens.1 ?? (sensitivity != nil ? 4 : nil)

            let rawHealth = HueColorMath.clean((cfg["status"] as? String) ?? (cfg["health"] as? String) ?? "ready", limit: 30)
            let health = rawHealth.isEmpty ? "ready" : rawHealth

            var areaLightIDs: [String] = []
            var seenAreaLights = Set<String>()
            let participants = (cfg["participants"] as? [[String: Any]])
                ?? (cfg["motion_area_participants"] as? [[String: Any]])
                ?? []
            for p in participants {
                let target = (p["service"] as? [String: Any]) ?? p
                guard let rid = target["rid"] as? String, let rtype = target["rtype"] as? String else { continue }
                let resolved: [String]
                if rtype == "motion_area_candidate" {
                    resolved = candidateLights[rid] ?? []
                } else if rtype == "device" {
                    resolved = deviceLights[rid] ?? []
                } else if rtype == "light", lights[rid] != nil {
                    resolved = [rid]
                } else {
                    resolved = []
                }
                for lid in resolved where seenAreaLights.insert(lid).inserted {
                    areaLightIDs.append(lid)
                }
            }

            for lid in areaLightIDs {
                motionAwareLights.insert(lid)
                if enabled && isMotion {
                    motionActiveLights.insert(lid)
                }
            }

            motionAreas.append(HueMotionArea(
                id: cfgID,
                name: areaName,
                enabled: enabled,
                roomID: roomID,
                motion: isMotion,
                motionValid: isValid,
                sensitivity: sensitivity,
                sensitivityMax: sensitivityMax,
                convenienceID: convID,
                lightIDs: areaLightIDs,
                health: health
            ))
        }
        motionAreas.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let motionAreaCandidatesCount = candidateLights.count
        let isPro = bridgeModelID.uppercased() == "BSB003" || !motionAreas.isEmpty || motionAreaCandidatesCount > 0

        // Physical Hue Sensors (motion, contact, button grouped per device + temperature, light_level, device_power)
        var roomByDeviceID: [String: String] = [:]
        for group in byType["room"] ?? [] {
            guard let gid = group["id"] as? String, HueColorMath.validUUID(gid) else { continue }
            for child in (group["children"] as? [[String: Any]]) ?? [] {
                if (child["rtype"] as? String) == "device",
                   let rid = child["rid"] as? String,
                   HueColorMath.validUUID(rid) {
                    roomByDeviceID[rid] = gid
                }
            }
        }

        var tempByDevice: [String: Double] = [:]
        var auxServicesByDevice: [String: [String]] = [:]
        for tRes in byType["temperature"] ?? [] {
            guard let tid = tRes["id"] as? String, HueColorMath.validUUID(tid),
                  let devID = (tRes["owner"] as? [String: Any])?["rid"] as? String,
                  HueColorMath.validUUID(devID) else { continue }
            auxServicesByDevice[devID, default: []].append(tid)
            if let tDict = tRes["temperature"] as? [String: Any] {
                let raw = tDict["temperature"] ?? (tDict["temperature_report"] as? [String: Any])?["temperature"]
                if let val = HueColorMath.finite(raw, low: -50.0, high: 120.0) {
                    tempByDevice[devID] = (val * 10.0).rounded() / 10.0
                }
            }
        }

        var luxByDevice: [String: Double] = [:]
        for llRes in byType["light_level"] ?? [] {
            guard let llid = llRes["id"] as? String, HueColorMath.validUUID(llid),
                  let devID = (llRes["owner"] as? [String: Any])?["rid"] as? String,
                  HueColorMath.validUUID(devID) else { continue }
            auxServicesByDevice[devID, default: []].append(llid)
            if let lDict = llRes["light"] as? [String: Any] {
                let raw = lDict["light_level"] ?? (lDict["light_level_report"] as? [String: Any])?["light_level"]
                if let ll = HueColorMath.finite(raw, low: 0.0, high: 65535.0) {
                    if ll <= 0 {
                        luxByDevice[devID] = 0.0
                    } else {
                        let val = pow(10.0, (ll - 1.0) / 10000.0)
                        luxByDevice[devID] = (val * 10.0).rounded() / 10.0
                    }
                }
            }
        }

        var powerByDevice: [String: (level: Int?, state: String)] = [:]
        for dpRes in byType["device_power"] ?? [] {
            guard let dpid = dpRes["id"] as? String, HueColorMath.validUUID(dpid),
                  let devID = (dpRes["owner"] as? [String: Any])?["rid"] as? String,
                  HueColorMath.validUUID(devID) else { continue }
            auxServicesByDevice[devID, default: []].append(dpid)
            if let pState = dpRes["power_state"] as? [String: Any] {
                let lvl = JSONValue.optionalInt(pState, "battery_level").map { HueColorMath.clamp($0, 0, 100) }
                let st = HueColorMath.clean((pState["battery_state"] as? String) ?? "", limit: 24)
                powerByDevice[devID] = (lvl, st)
            }
        }

        func sensorDeviceName(_ deviceID: String, fallback: String) -> String {
            if let dev = devices[deviceID] {
                if let meta = dev["metadata"] as? [String: Any], let n = meta["name"] as? String {
                    let clean = HueColorMath.clean(n)
                    if !clean.isEmpty { return clean }
                }
                if let pd = dev["product_data"] as? [String: Any], let pn = pd["product_name"] as? String {
                    let clean = HueColorMath.clean(pn)
                    if !clean.isEmpty { return clean }
                }
            }
            return fallback
        }

        var sensors: [HueSensor] = []
        var sensorServiceToSensorID: [String: String] = [:]

        for mRes in byType["motion"] ?? [] {
            guard let mid = mRes["id"] as? String, HueColorMath.validUUID(mid) else { continue }
            let devID = (mRes["owner"] as? [String: Any])?["rid"] as? String ?? ""
            let enabled = (mRes["enabled"] as? Bool) ?? true
            let mFlag = parseMotionFlag(mRes).motion ?? false
            let sens = parseSensitivity(mRes)
            let power = powerByDevice[devID]
            let sensor = HueSensor(
                id: mid,
                deviceID: devID,
                kind: "motion",
                name: sensorDeviceName(devID, fallback: "Motion Sensor"),
                roomID: roomByDeviceID[devID] ?? "",
                enabled: enabled,
                motion: mFlag,
                open: false,
                temperature: tempByDevice[devID],
                lux: luxByDevice[devID],
                battery: power?.level,
                batteryState: power?.state ?? "",
                sensitivity: sens.0,
                sensitivityMax: sens.1,
                buttonIDs: [],
                lastEvent: ""
            )
            sensors.append(sensor)
            sensorServiceToSensorID[mid] = mid
            for auxID in auxServicesByDevice[devID] ?? [] {
                sensorServiceToSensorID[auxID] = mid
            }
        }

        for cRes in byType["contact"] ?? [] {
            guard let cid = cRes["id"] as? String, HueColorMath.validUUID(cid) else { continue }
            let devID = (cRes["owner"] as? [String: Any])?["rid"] as? String ?? ""
            let enabled = (cRes["enabled"] as? Bool) ?? true
            let state = ((cRes["contact_report"] as? [String: Any])?["state"] as? String) ?? ""
            let isOpen = (state == "no_contact")
            let power = powerByDevice[devID]
            let sensor = HueSensor(
                id: cid,
                deviceID: devID,
                kind: "contact",
                name: sensorDeviceName(devID, fallback: "Contact Sensor"),
                roomID: roomByDeviceID[devID] ?? "",
                enabled: enabled,
                motion: false,
                open: isOpen,
                temperature: tempByDevice[devID],
                lux: luxByDevice[devID],
                battery: power?.level,
                batteryState: power?.state ?? "",
                sensitivity: nil,
                sensitivityMax: nil,
                buttonIDs: [],
                lastEvent: ""
            )
            sensors.append(sensor)
            sensorServiceToSensorID[cid] = cid
            for auxID in auxServicesByDevice[devID] ?? [] {
                sensorServiceToSensorID[auxID] = cid
            }
        }

        var buttonsByDevice: [String: [[String: Any]]] = [:]
        for bRes in byType["button"] ?? [] {
            guard let bid = bRes["id"] as? String, HueColorMath.validUUID(bid) else { continue }
            let devID = (bRes["owner"] as? [String: Any])?["rid"] as? String ?? bid
            buttonsByDevice[devID, default: []].append(bRes)
        }
        for (devID, btnList) in buttonsByDevice {
            let sorted = btnList.sorted { lhs, rhs in
                let lc = JSONValue.optionalInt((lhs["metadata"] as? [String: Any]) ?? [:], "control_id") ?? 999
                let rc = JSONValue.optionalInt((rhs["metadata"] as? [String: Any]) ?? [:], "control_id") ?? 999
                if lc != rc { return lc < rc }
                return ((lhs["id"] as? String) ?? "") < ((rhs["id"] as? String) ?? "")
            }
            guard let primaryID = sorted.first?["id"] as? String else { continue }
            let allIDs = sorted.compactMap { $0["id"] as? String }
            var lastEvent = ""
            for b in sorted {
                if let bDict = b["button"] as? [String: Any] {
                    if let rep = bDict["button_report"] as? [String: Any], let ev = rep["event"] as? String, !ev.isEmpty {
                        lastEvent = ev
                        break
                    } else if let ev = bDict["last_event"] as? String, !ev.isEmpty {
                        lastEvent = ev
                        break
                    }
                }
            }
            let power = powerByDevice[devID]
            let sensor = HueSensor(
                id: primaryID,
                deviceID: devID,
                kind: "button",
                name: sensorDeviceName(devID, fallback: "Switch"),
                roomID: roomByDeviceID[devID] ?? "",
                enabled: true,
                motion: false,
                open: false,
                temperature: tempByDevice[devID],
                lux: luxByDevice[devID],
                battery: power?.level,
                batteryState: power?.state ?? "",
                sensitivity: nil,
                sensitivityMax: nil,
                buttonIDs: allIDs,
                lastEvent: lastEvent
            )
            sensors.append(sensor)
            for bid in allIDs {
                sensorServiceToSensorID[bid] = primaryID
            }
            for auxID in auxServicesByDevice[devID] ?? [] {
                sensorServiceToSensorID[auxID] = primaryID
            }
        }
        sensors.sort {
            let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
            return cmp == .orderedSame ? ($0.id < $1.id) : (cmp == .orderedAscending)
        }

        var budget = maxMemberships
        func lightsOf(_ group: [String: Any]) -> [String] {
            var ids: [String] = []
            var seen = Set<String>()
            let limit = min(maxGroupLights, budget)

            func add(_ rid: String) {
                if lights[rid] != nil && ids.count < limit && seen.insert(rid).inserted {
                    ids.append(rid)
                }
            }

            for child in (group["children"] as? [[String: Any]]) ?? [] {
                if ids.count >= limit { break }
                guard let rid = child["rid"] as? String,
                      let rtype = child["rtype"] as? String else { continue }
                if rtype == "light" {
                    add(rid)
                } else if rtype == "device" {
                    for lid in deviceLights[rid] ?? [] {
                        add(lid)
                    }
                }
            }
            budget -= ids.count
            return ids
        }

        // Scenes grouped by room/zone ID
        var scenesByGroup: [String: [HueScene]] = [:]
        var seenScenes = Set<String>()
        for scene in byType["scene"] ?? [] {
            if seenScenes.count >= maxScenes { break }
            guard let sid = scene["id"] as? String,
                  let gid = (scene["group"] as? [String: Any])?["rid"] as? String,
                  HueColorMath.validUUID(sid),
                  HueColorMath.validUUID(gid),
                  !seenScenes.contains(sid) else { continue }
            if (scenesByGroup[gid]?.count ?? 0) >= maxGroupScenes { continue }
            seenScenes.insert(sid)
            let name = HueColorMath.clean(((scene["metadata"] as? [String: Any])?["name"] as? String) ?? "Scene", limit: 30)
            let activeState = ((scene["status"] as? [String: Any])?["active"] as? String) ?? "inactive"
            scenesByGroup[gid, default: []].append(HueScene(
                id: sid,
                name: name.isEmpty ? "Scene" : name,
                active: activeState != "inactive"
            ))
        }
        for gid in scenesByGroup.keys {
            scenesByGroup[gid]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // Rooms & Zones
        var rooms: [HueRoom] = []
        var assigned = Set<String>()
        var seenGroups = Set<String>()
        var nameByID: [String: String] = [:]

        for (lid, light) in lights {
            let n = HueColorMath.clean(((light["metadata"] as? [String: Any])?["name"] as? String) ?? "Light")
            nameByID[lid] = n.isEmpty ? "Light" : n
        }

        for kind in ["room", "zone"] {
            for group in byType[kind] ?? [] {
                guard let gid = group["id"] as? String,
                      HueColorMath.validUUID(gid),
                      seenGroups.insert(gid).inserted else { continue }
                var glID = ""
                for svc in (group["services"] as? [[String: Any]]) ?? [] {
                    if (svc["rtype"] as? String) == "grouped_light",
                       let rid = svc["rid"] as? String,
                       grouped[rid] != nil {
                        glID = rid
                    }
                }
                let ids = lightsOf(group)
                if ids.isEmpty { continue }
                if kind == "room" {
                    assigned.formUnion(ids)
                }
                let members = ids.compactMap { lights[$0].map(makeLight) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let onMembers = members.filter(\.on)
                let gl = grouped[glID]
                let glBri = (gl?["dimming"] as? [String: Any]).flatMap { HueColorMath.finite($0["brightness"], low: 0.0, high: 100.0) }
                let briValue: Double
                if let b = glBri {
                    briValue = (b * 10.0).rounded() / 10.0
                } else if !onMembers.isEmpty {
                    let avg = onMembers.map(\.bri).reduce(0.0, +) / Double(onMembers.count)
                    briValue = (avg * 10.0).rounded() / 10.0
                } else {
                    briValue = 0.0
                }
                let meta = group["metadata"] as? [String: Any] ?? [:]
                let rawName = HueColorMath.clean((meta["name"] as? String) ?? kind.capitalized)
                let groupName = rawName.isEmpty ? kind.capitalized : rawName
                nameByID[gid] = groupName
                let archetype = HueColorMath.clean((meta["archetype"] as? String) ?? "", limit: 30)
                let room = HueRoom(
                    hueID: gid,
                    kind: kind,
                    name: groupName,
                    groupedLight: glID,
                    on: !onMembers.isEmpty,
                    bri: briValue,
                    onCount: onMembers.count,
                    archetype: archetype,
                    color: HueColorMath.blendColors(onMembers.map(\.color)),
                    lights: members,
                    scenes: scenesByGroup.removeValue(forKey: gid) ?? []
                )
                rooms.append(room)
            }
        }

        // Loose lights ("Other lights")
        var loose: [HueLight] = []
        let looseLimit = min(maxGroupLights, budget)
        for (lid, light) in lights {
            if loose.count >= looseLimit { break }
            if !assigned.contains(lid) {
                loose.append(makeLight(light))
            }
        }
        if !loose.isEmpty {
            loose.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let onMembers = loose.filter(\.on)
            let bri = onMembers.isEmpty ? 0.0
                : ((onMembers.map(\.bri).reduce(0.0, +) / Double(onMembers.count)) * 10.0).rounded() / 10.0
            rooms.append(HueRoom(
                hueID: "",
                kind: "other",
                name: "Other lights",
                groupedLight: "",
                on: !onMembers.isEmpty,
                bri: bri,
                onCount: onMembers.count,
                archetype: "",
                color: HueColorMath.blendColors(onMembers.map(\.color)),
                lights: loose,
                scenes: []
            ))
        }

        rooms.sort { a, b in
            let aRank = a.kind == "room" ? 0 : (a.kind == "zone" ? 1 : 2)
            let bRank = b.kind == "room" ? 0 : (b.kind == "zone" ? 1 : 2)
            if aRank != bRank { return aRank < bRank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        // bridge_home grouped_light
        var bridgeHomeGL = ""
        for home in byType["bridge_home"] ?? [] {
            for svc in (home["services"] as? [[String: Any]]) ?? [] {
                if (svc["rtype"] as? String) == "grouped_light",
                   let rid = svc["rid"] as? String,
                   HueColorMath.validUUID(rid) {
                    bridgeHomeGL = rid
                    break
                }
            }
            if !bridgeHomeGL.isEmpty { break }
        }

        // behavior_script for schedules
        var scheduleScriptID = ""
        for script in byType["behavior_script"] ?? [] {
            guard let sid = script["id"] as? String, HueColorMath.validUUID(sid) else { continue }
            if sid == defaultScheduleScriptID {
                scheduleScriptID = sid
                break
            }
            let meta = script["metadata"] as? [String: Any] ?? [:]
            let category = (meta["category"] as? String ?? "").lowercased()
            let sname = (meta["name"] as? String ?? "").lowercased()
            if scheduleScriptID.isEmpty && (category == "automation" || sname.contains("schedule") || sname.contains("timer")) {
                scheduleScriptID = sid
            }
        }
        if scheduleScriptID.isEmpty {
            scheduleScriptID = defaultScheduleScriptID
        }

        // behavior_instance -> HueSchedule
        var schedules: [HueSchedule] = []
        for inst in byType["behavior_instance"] ?? [] {
            guard let id = inst["id"] as? String, HueColorMath.validUUID(id),
                  let config = inst["configuration"] as? [String: Any] else { continue }
            let when = (config["when"] as? [String: Any]) ?? (config["when_extended"] as? [String: Any])
            guard let whenDict = when else { continue }

            let meta = inst["metadata"] as? [String: Any] ?? [:]
            let rawName = HueColorMath.clean((meta["name"] as? String) ?? "Schedule")
            let name = rawName.isEmpty ? "Schedule" : rawName
            let enabled = (inst["enabled"] as? Bool) ?? true

            // Target
            var targetKind = "room"
            var targetID = ""
            if let whereList = config["where"] as? [[String: Any]], let first = whereList.first {
                let group = (first["group"] as? [String: Any]) ?? first
                targetKind = (group["rtype"] as? String) ?? "room"
                targetID = (group["rid"] as? String) ?? ""
            }
            let targetName = nameByID[targetID] ?? (targetKind == "bridge_home" ? "Home" : targetID)

            // Trigger time / sunrise / sunset
            var triggerKind = "time"
            var timeStr = "07:00"
            var offsetMin = 0
            let timePoint = (whenDict["time_point"] as? [String: Any])
                ?? ((whenDict["start_at"] as? [String: Any])?["time_point"] as? [String: Any])
                ?? [:]
            let tpType = (timePoint["type"] as? String) ?? "time"
            if tpType == "sunrise" || tpType == "sunset" {
                triggerKind = tpType
                offsetMin = JSONValue.optionalInt(timePoint, "offset") ?? 0
            } else {
                triggerKind = "time"
                let t = (timePoint["time"] as? [String: Any]) ?? [:]
                let hour = HueColorMath.clamp(JSONValue.optionalInt(t, "hour") ?? 7, 0, 23)
                let minute = HueColorMath.clamp(JSONValue.optionalInt(t, "minute") ?? 0, 0, 59)
                timeStr = String(format: "%02d:%02d", hour, minute)
            }

            let days = (whenDict["recurrence_days"] as? [String]) ?? []

            // Action & brightness & fade
            var action = "on"
            var bri: Int? = nil
            var sceneID = ""
            if let recall = config["recall"] as? [String: Any],
               let rid = recall["rid"] as? String, !rid.isEmpty {
                action = "scene"
                sceneID = rid
            } else if let onDict = config["on"] as? [String: Any], (onDict["on"] as? Bool) == false {
                action = "off"
            } else if (config["turn_lights_off_after"] != nil) && (config["on"] == nil) && (config["dimming"] == nil) {
                action = "off"
            } else {
                action = "on"
                if let dim = config["dimming"] as? [String: Any],
                   let b = HueColorMath.finite(dim["brightness"], low: 1.0, high: 100.0) {
                    bri = Int(b.rounded())
                }
            }
            var fadeMin = 0
            if let fade = config["fade_in_duration"] as? [String: Any],
               let secs = JSONValue.optionalInt(fade, "seconds") {
                fadeMin = max(0, secs / 60)
            } else if let fade = config["fade_out_duration"] as? [String: Any],
                      let secs = JSONValue.optionalInt(fade, "seconds") {
                fadeMin = max(0, secs / 60)
            }

            schedules.append(HueSchedule(
                id: id,
                name: name,
                enabled: enabled,
                targetKind: targetKind,
                targetID: targetID,
                targetName: targetName,
                triggerKind: triggerKind,
                time: timeStr,
                offsetMin: offsetMin,
                days: days,
                action: action,
                bri: bri,
                sceneID: sceneID,
                fadeMin: fadeMin,
                source: "bridge"
            ))
        }
        schedules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // entertainment_configuration -> HueEntertainmentArea
        var entertainmentAreas: [HueEntertainmentArea] = []
        for area in byType["entertainment_configuration"] ?? [] {
            guard let aid = area["id"] as? String, HueColorMath.validUUID(aid) else { continue }
            let meta = area["metadata"] as? [String: Any] ?? [:]
            let rawName = HueColorMath.clean((meta["name"] as? String) ?? (area["name"] as? String) ?? "Entertainment Area")
            let areaName = rawName.isEmpty ? "Entertainment Area" : rawName
            var parsedChannels: [HueEntertainmentChannel] = []
            for ch in (area["channels"] as? [[String: Any]]) ?? [] {
                guard let chID = JSONValue.optionalInt(ch, "channel_id"),
                      (0...255).contains(chID) else { continue }
                var memberLights: [String] = []
                for member in (ch["members"] as? [[String: Any]]) ?? [] {
                    if let svc = member["service"] as? [String: Any],
                       let rid = svc["rid"] as? String,
                       HueColorMath.validUUID(rid) {
                        memberLights.append(rid)
                    }
                }
                parsedChannels.append(HueEntertainmentChannel(channelID: UInt8(chID), lightIDs: memberLights))
            }
            parsedChannels.sort { $0.channelID < $1.channelID }
            if !parsedChannels.isEmpty {
                entertainmentAreas.append(HueEntertainmentArea(id: aid, name: areaName, channels: parsedChannels))
            }
        }
        entertainmentAreas.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let totalOn = lights.values.filter { (($0["on"] as? [String: Any])?["on"] as? Bool) == true }.count
        return HueBuiltModel(
            rooms: rooms,
            lightCount: lights.count,
            onCount: totalOn,
            bridgeHomeGroupedLight: bridgeHomeGL,
            scheduleScriptID: scheduleScriptID,
            schedules: schedules,
            entertainmentAreas: entertainmentAreas,
            entertainmentServiceByLight: entertainmentServiceByLight,
            bridgeModelID: bridgeModelID,
            isPro: isPro,
            motionAreaCandidates: motionAreaCandidatesCount,
            motionAreas: motionAreas,
            sensors: sensors,
            sensorServiceToSensorID: sensorServiceToSensorID,
            securityMotionToAreaID: securityMotionToAreaID
        )
    }
}

enum JSONValue {
    static func string(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }

    private static func isJSONBool(_ raw: Any) -> Bool {
        if type(of: raw) == Bool.self { return true }
        #if canImport(CoreFoundation)
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return true
        }
        #endif
        return false
    }

    static func bool(_ d: [String: Any], _ k: String) -> Bool {
        guard let raw = d[k], isJSONBool(raw) else { return false }
        return (raw as? Bool) == true
    }

    static func optionalInt(_ d: [String: Any], _ k: String) -> Int? {
        guard let raw = d[k], !isJSONBool(raw) else { return nil }
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber {
            let v = n.doubleValue
            return v.isFinite ? Int(v.rounded()) : nil
        }
        if let dbl = raw as? Double {
            return dbl.isFinite ? Int(dbl.rounded()) : nil
        }
        return nil
    }

    static func number(_ d: [String: Any], _ k: String) -> Double {
        guard let raw = d[k], !isJSONBool(raw) else { return 0 }
        let v: Double
        if let n = raw as? NSNumber {
            v = n.doubleValue
        } else if let dbl = raw as? Double {
            v = dbl
        } else if let i = raw as? Int {
            v = Double(i)
        } else {
            return 0
        }
        return v.isFinite ? v : 0
    }

    static func strings(_ d: [String: Any], _ k: String) -> [String] {
        ((d[k] as? [Any]) ?? []).compactMap { $0 as? String }
    }

    static func objects(_ d: [String: Any], _ k: String) -> [[String: Any]] {
        ((d[k] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }
}
