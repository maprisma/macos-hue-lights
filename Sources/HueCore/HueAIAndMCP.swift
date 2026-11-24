import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Sendable JSON Value Representation

/// Strict-concurrency (`Sendable`) JSON value container shared by `HueAskAIEngine` and `HueMCPServer`.
public enum HueJSONValue: Equatable, Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([HueJSONValue])
    case object([String: HueJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([HueJSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: HueJSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d.isFinite ? d : 0.0)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int(d.rounded())
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d) where d.isFinite: return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var arrayValue: [HueJSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: HueJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public func toFoundation() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : 0.0
        case .string(let s): return s
        case .array(let a): return a.map { $0.toFoundation() }
        case .object(let o):
            var dict: [String: Any] = [:]
            for (k, v) in o { dict[k] = v.toFoundation() }
            return dict
        }
    }

    public static func fromFoundation(_ raw: Any) -> HueJSONValue {
        switch raw {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return d.isFinite ? .double(d) : .double(0)
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            #if canImport(CoreFoundation)
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            #endif
            let d = n.doubleValue
            if d.isFinite && d.rounded() == d && abs(d) <= Double(Int.max / 2) {
                return .int(Int(d))
            }
            return .double(d.isFinite ? d : 0)
        case let arr as [Any]:
            return .array(arr.map { fromFoundation($0) })
        case let dict as [String: Any]:
            var out: [String: HueJSONValue] = [:]
            for (k, v) in dict {
                out[k] = fromFoundation(v)
            }
            return .object(out)
        default:
            return .string(String(describing: raw))
        }
    }

    public static func encodeCompactString(_ value: HueJSONValue) -> String {
        let obj = value.toFoundation()
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    public static func encodePrettyString(_ value: HueJSONValue) -> String {
        let obj = value.toFoundation()
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - Tool Call & Response Models

public struct HueToolCall: Equatable, Hashable, Sendable {
    public var name: String
    public var arguments: [String: HueJSONValue]

    public init(name: String, arguments: [String: HueJSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct HueToolExecutionResult: Equatable, Sendable {
    public var ok: Bool
    public var summary: String
    public var payload: HueJSONValue

    public init(ok: Bool, summary: String, payload: HueJSONValue) {
        self.ok = ok
        self.summary = summary
        self.payload = payload
    }
}

public struct HueExecutedAction: Identifiable, Equatable, Sendable {
    public var id: String
    public var tool: String
    public var summary: String
    public var ok: Bool

    public init(id: String = UUID().uuidString.lowercased(), tool: String, summary: String, ok: Bool) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.ok = ok
    }
}

public struct HueAskAIPlan: Equatable, Sendable {
    public var calls: [HueToolCall]
    public var replyHint: String
    public var isStatusQuery: Bool

    public init(calls: [HueToolCall], replyHint: String = "", isStatusQuery: Bool = false) {
        self.calls = calls
        self.replyHint = replyHint
        self.isStatusQuery = isStatusQuery
    }
}

public struct HueAskAIResponse: Equatable, Sendable {
    public var reply: String
    public var actions: [HueExecutedAction]
    public var source: String
    public var matched: Bool

    public init(reply: String, actions: [HueExecutedAction] = [], source: String = "local", matched: Bool = true) {
        self.reply = reply
        self.actions = actions
        self.source = source
        self.matched = matched
    }
}

public struct HueAskAIConfig: Equatable, Sendable {
    public var ollamaURL: String
    public var model: String
    public var timeoutSeconds: TimeInterval

    public init(
        ollamaURL: String = AppSettings.defaultAskAIOllamaURL,
        model: String = "",
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.ollamaURL = ollamaURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - Unified Tool Backend Protocol & Dispatcher

/// Abstraction over `HueStore` (GUI) and headless CLI (`--mcp`) so both Ask AI and MCP share the exact same tools.
@MainActor
public protocol HueToolBackend: AnyObject {
    var currentSnapshot: HueSnapshot { get }
    var currentThemes: [HueLightTheme] { get }
    var currentRules: [HueRule] { get }
    var currentSchedules: [HueSchedule] { get }
    var currentFloorplan: FloorplanDocument? { get }

    func setLight(id: String, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?)
    func setRoom(room: HueRoom, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?)
    func recallScene(id: String)
    func applyTheme(_ theme: HueLightTheme, to light: HueLight)
    func turnAllOn()
    func turnAllOff()
    func setSensorEnabled(sensor: HueSensor, enabled: Bool)
    func updateMotionArea(area: HueMotionArea, enabled: Bool?, sensitivity: Int?)
    func addRule(_ rule: HueRule)
    func toggleRule(id: String, enabled: Bool) -> Bool
    func deleteRule(id: String) -> Bool
    func createSchedule(_ draft: HueScheduleDraft)
}

/// Executes all 20 Hue tools consistently, resolving UUIDs or case-insensitive names and NEVER exposing secrets.
@MainActor
public final class HueToolDispatcher {
    private let backend: HueToolBackend

    public init(backend: HueToolBackend) {
        self.backend = backend
    }

    // MARK: - Tool Schema Catalog (for MCP tools/list)

    public static func toolDefinitions() -> [HueJSONValue] {
        func prop(_ type: String, _ desc: String) -> HueJSONValue {
            .object(["type": .string(type), "description": .string(desc)])
        }
        func tool(
            _ name: String,
            _ description: String,
            properties: [String: HueJSONValue] = [:],
            required: [String] = []
        ) -> HueJSONValue {
            var schema: [String: HueJSONValue] = [
                "type": .string("object"),
                "properties": .object(properties),
            ]
            if !required.isEmpty {
                schema["required"] = .array(required.map { .string($0) })
            }
            return .object([
                "name": .string(name),
                "description": .string(description),
                "inputSchema": .object(schema),
            ])
        }

        return [
            tool("hue_status", "Return current Hue Bridge connection status, light counts, and which lights are currently on."),
            tool("hue_list_rooms", "List all Hue rooms and zones with their lights, scenes, brightness, and MotionAware presence."),
            tool("hue_list_lights", "List all Hue lights with on/off state, brightness, color, color temperature, effects, and MotionAware badge."),
            tool("hue_list_sensors", "List all physical Hue sensors (motion, contact, switch/button) and Bridge Pro MotionAware areas."),
            tool("hue_list_themes", "List all built-in and custom per-lamp Light Themes."),
            tool("hue_list_rules", "List all automation rules (light/room/sensor/MotionAware/Mac wake & sleep rules)."),
            tool("hue_list_schedules", "List all bridge and local Hue schedules."),
            tool("hue_get_floorplan", "Return the saved 2D spatial floorplan rooms, lamp placements, sensor placements, and furniture stamps."),
            tool(
                "hue_set_light",
                "Control an individual Hue light by UUID or case-insensitive name.",
                properties: [
                    "target": prop("string", "Light UUID or name"),
                    "on": prop("boolean", "Turn light on (true) or off (false)"),
                    "bri": prop("integer", "Brightness 1..100"),
                    "kelvin": prop("integer", "Color temperature in Kelvin (2000..6500)"),
                    "mirek": prop("integer", "Color temperature in mirek (153..500)"),
                    "color": prop("string", "Hex color #rrggbb or named color (red, blue, warm, etc.)"),
                    "effect": prop("string", "Native Hue effect: candle, fire, sparkle, prism, opal, glisten, no_effect"),
                ],
                required: ["target"]
            ),
            tool(
                "hue_set_room",
                "Control a Hue room or zone by UUID or case-insensitive name.",
                properties: [
                    "target": prop("string", "Room or zone UUID or name"),
                    "on": prop("boolean", "Turn room on (true) or off (false)"),
                    "bri": prop("integer", "Brightness 1..100"),
                    "kelvin": prop("integer", "Color temperature in Kelvin (2000..6500)"),
                    "mirek": prop("integer", "Color temperature in mirek (153..500)"),
                    "color": prop("string", "Hex color #rrggbb or named color"),
                    "effect": prop("string", "Native Hue effect name"),
                ],
                required: ["target"]
            ),
            tool(
                "hue_recall_scene",
                "Recall a Hue scene by UUID or name (optionally scoped to a room).",
                properties: [
                    "scene": prop("string", "Scene UUID or name"),
                    "room": prop("string", "Optional room UUID or name"),
                ],
                required: ["scene"]
            ),
            tool(
                "hue_apply_theme",
                "Apply a built-in or custom Light Theme to a light or all lights in a room.",
                properties: [
                    "theme": prop("string", "Theme ID or name (e.g. Cyberpunk Neon, Golden Hour)"),
                    "target": prop("string", "Light or room UUID or name"),
                ],
                required: ["theme", "target"]
            ),
            tool("hue_all_on", "Turn on all non-excluded Hue lights."),
            tool("hue_all_off", "Turn off all Hue lights."),
            tool(
                "hue_set_sensor",
                "Enable or disable a physical Hue sensor (motion or contact) by UUID or name.",
                properties: [
                    "target": prop("string", "Sensor UUID or name"),
                    "enabled": prop("boolean", "Whether the sensor is enabled"),
                ],
                required: ["target", "enabled"]
            ),
            tool(
                "hue_set_motion_area",
                "Enable, disable, or adjust sensitivity of a Bridge Pro MotionAware area by UUID or name.",
                properties: [
                    "target": prop("string", "MotionAware area UUID, room name, or area name"),
                    "enabled": prop("boolean", "Whether MotionAware detection is enabled"),
                    "sensitivity": prop("integer", "Optional sensitivity value"),
                ],
                required: ["target"]
            ),
            tool(
                "hue_create_rule",
                "Create a new Hue automation rule triggered by a light, room, physical sensor, MotionAware area, or Mac wake/sleep.",
                properties: [
                    "name": prop("string", "Human-readable rule name"),
                    "kind": prop("string", "Rule kind: follow, exclusive, companion, or desktop"),
                    "trigger_kind": prop("string", "light, room, motion, contact, button, motion_area, or desktop"),
                    "trigger": prop("string", "Trigger UUID or name (or 'desktop')"),
                    "trigger_state": prop("string", "on, off, motion, clear, open, closed, press, long_press, wake, or sleep"),
                    "target_kind": prop("string", "light, room, or scene"),
                    "target": prop("string", "Target UUID or name"),
                    "action": prop("string", "on, off, or scene"),
                    "bri": prop("integer", "Optional brightness 1..100 when action is on"),
                    "mirror_off": prop("boolean", "Also turn target off when trigger turns off / clears"),
                ],
                required: ["trigger", "target"]
            ),
            tool(
                "hue_toggle_rule",
                "Enable or disable an existing automation rule by ID or name.",
                properties: [
                    "rule": prop("string", "Rule ID or name"),
                    "enabled": prop("boolean", "New enabled state"),
                ],
                required: ["rule", "enabled"]
            ),
            tool(
                "hue_delete_rule",
                "Delete an existing automation rule by ID or name.",
                properties: [
                    "rule": prop("string", "Rule ID or name"),
                ],
                required: ["rule"]
            ),
            tool(
                "hue_create_schedule",
                "Create a new Hue schedule by fixed clock time, sunrise, or sunset.",
                properties: [
                    "name": prop("string", "Schedule name"),
                    "target_kind": prop("string", "room or light"),
                    "target": prop("string", "Room or light UUID or name"),
                    "trigger_kind": prop("string", "time, sunrise, or sunset"),
                    "time": prop("string", "Clock time HH:MM when trigger_kind is time"),
                    "offset_min": prop("integer", "Offset minutes -60..60 for sunrise/sunset"),
                    "days": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Weekday names (monday..sunday); empty means daily"),
                    ]),
                    "action": prop("string", "on, off, or scene"),
                    "bri": prop("integer", "Optional brightness 1..100"),
                    "scene": prop("string", "Optional scene UUID or name when action is scene"),
                ],
                required: ["target"]
            ),
        ]
    }

    // MARK: - Execution

    public func execute(_ call: HueToolCall) -> HueToolExecutionResult {
        let snap = backend.currentSnapshot
        let args = call.arguments

        switch call.name {
        case "hue_status":
            return executeStatus(snap: snap)
        case "hue_list_rooms":
            return executeListRooms(snap: snap)
        case "hue_list_lights":
            return executeListLights(snap: snap)
        case "hue_list_sensors":
            return executeListSensors(snap: snap)
        case "hue_list_themes":
            return executeListThemes()
        case "hue_list_rules":
            return executeListRules()
        case "hue_list_schedules":
            return executeListSchedules()
        case "hue_get_floorplan":
            return executeGetFloorplan()
        case "hue_set_light":
            return executeSetLight(args: args, snap: snap)
        case "hue_set_room":
            return executeSetRoom(args: args, snap: snap)
        case "hue_recall_scene":
            return executeRecallScene(args: args, snap: snap)
        case "hue_apply_theme":
            return executeApplyTheme(args: args, snap: snap)
        case "hue_all_on":
            backend.turnAllOn()
            return HueToolExecutionResult(ok: true, summary: "All lights on", payload: .object(["ok": .bool(true), "action": .string("all_on")]))
        case "hue_all_off":
            backend.turnAllOff()
            return HueToolExecutionResult(ok: true, summary: "All lights off", payload: .object(["ok": .bool(true), "action": .string("all_off")]))
        case "hue_set_sensor":
            return executeSetSensor(args: args, snap: snap)
        case "hue_set_motion_area":
            return executeSetMotionArea(args: args, snap: snap)
        case "hue_create_rule":
            return executeCreateRule(args: args, snap: snap)
        case "hue_toggle_rule":
            return executeToggleRule(args: args)
        case "hue_delete_rule":
            return executeDeleteRule(args: args)
        case "hue_create_schedule":
            return executeCreateSchedule(args: args, snap: snap)
        default:
            return HueToolExecutionResult(
                ok: false,
                summary: "Unknown tool: \(call.name)",
                payload: .object(["error": .string("Unknown tool: \(call.name)")])
            )
        }
    }

    public func stateResourceJSON() -> HueJSONValue {
        let snap = backend.currentSnapshot
        return .object([
            "phase": .string(snap.phase),
            "is_demo": .bool(snap.isDemo),
            "bridge": sanitizedBridgeJSON(snap.bridge),
            "light_count": .int(snap.lightCount),
            "on_count": .int(snap.onCount),
            "rooms": .array(snap.rooms.map { roomJSON($0, snap: snap) }),
            "sensors": .array(snap.sensors.map(sensorJSON)),
            "motion_areas": .array(snap.motionAreas.map(motionAreaJSON)),
            "rules_count": .int(backend.currentRules.count),
            "schedules_count": .int(backend.currentSchedules.count),
        ])
    }

    // MARK: - Individual Tool Handlers

    private func executeStatus(snap: HueSnapshot) -> HueToolExecutionResult {
        let litLights = snap.allLights.filter(\.on)
        let litNames = litLights.map(\.name)
        let summary: String
        if litNames.isEmpty {
            summary = "All \(snap.lightCount) lights are off."
        } else {
            summary = "\(litNames.count) of \(snap.lightCount) on: \(litNames.joined(separator: ", "))"
        }
        let payload: HueJSONValue = .object([
            "phase": .string(snap.phase),
            "is_demo": .bool(snap.isDemo),
            "bridge": sanitizedBridgeJSON(snap.bridge),
            "light_count": .int(snap.lightCount),
            "on_count": .int(snap.onCount),
            "lit_lights": .array(litLights.map { .object(["id": .string($0.id), "name": .string($0.name), "bri": .int(Int($0.bri.rounded()))]) }),
            "rules_count": .int(backend.currentRules.count),
            "schedules_count": .int(backend.currentSchedules.count),
            "sensors_count": .int(snap.sensors.count),
            "motion_areas_count": .int(snap.motionAreas.count),
        ])
        return HueToolExecutionResult(ok: true, summary: summary, payload: payload)
    }

    private func executeListRooms(snap: HueSnapshot) -> HueToolExecutionResult {
        let items = snap.rooms.map { roomJSON($0, snap: snap) }
        return HueToolExecutionResult(
            ok: true,
            summary: "\(snap.rooms.count) room(s)",
            payload: .object(["rooms": .array(items)])
        )
    }

    private func executeListLights(snap: HueSnapshot) -> HueToolExecutionResult {
        let lights = snap.allLights
        return HueToolExecutionResult(
            ok: true,
            summary: "\(lights.count) light(s)",
            payload: .object(["lights": .array(lights.map(lightJSON))])
        )
    }

    private func executeListSensors(snap: HueSnapshot) -> HueToolExecutionResult {
        return HueToolExecutionResult(
            ok: true,
            summary: "\(snap.sensors.count) sensor(s), \(snap.motionAreas.count) MotionAware area(s)",
            payload: .object([
                "sensors": .array(snap.sensors.map(sensorJSON)),
                "motion_areas": .array(snap.motionAreas.map(motionAreaJSON)),
            ])
        )
    }

    private func executeListThemes() -> HueToolExecutionResult {
        let themes = backend.currentThemes
        let arr: [HueJSONValue] = themes.map { t in
            var obj: [String: HueJSONValue] = [
                "id": .string(t.id),
                "name": .string(t.name),
                "hex": .string(t.hex),
                "brightness": .int(t.brightness),
                "effect": .string(t.effect),
                "is_built_in": .bool(t.isBuiltIn),
            ]
            if let m = t.mirek { obj["mirek"] = .int(m) }
            return .object(obj)
        }
        return HueToolExecutionResult(ok: true, summary: "\(themes.count) theme(s)", payload: .object(["themes": .array(arr)]))
    }

    private func executeListRules() -> HueToolExecutionResult {
        let rules = backend.currentRules
        let arr: [HueJSONValue] = rules.map { r in
            .object([
                "id": .string(r.id),
                "name": .string(r.name),
                "enabled": .bool(r.enabled),
                "kind": .string(r.kind),
                "trigger_kind": .string(r.triggerKind),
                "trigger_id": .string(r.triggerID),
                "trigger_state": .string(r.triggerState),
                "mirror_off": .bool(r.mirrorOff),
                "targets": .array(r.targets.map { t in
                    var o: [String: HueJSONValue] = ["kind": .string(t.kind), "id": .string(t.id), "action": .string(t.action)]
                    if let b = t.bri { o["bri"] = .int(b) }
                    if let s = t.sceneID { o["scene_id"] = .string(s) }
                    return .object(o)
                }),
            ])
        }
        return HueToolExecutionResult(ok: true, summary: "\(rules.count) rule(s)", payload: .object(["rules": .array(arr)]))
    }

    private func executeListSchedules() -> HueToolExecutionResult {
        let schedules = backend.currentSchedules
        let arr: [HueJSONValue] = schedules.map { s in
            var obj: [String: HueJSONValue] = [
                "id": .string(s.id),
                "name": .string(s.name),
                "enabled": .bool(s.enabled),
                "target_kind": .string(s.targetKind),
                "target_id": .string(s.targetID),
                "target_name": .string(s.targetName),
                "trigger_kind": .string(s.triggerKind),
                "time": .string(s.time),
                "offset_min": .int(s.offsetMin),
                "days": .array(s.days.map { .string($0) }),
                "action": .string(s.action),
                "source": .string(s.source),
            ]
            if let b = s.bri { obj["bri"] = .int(b) }
            if !s.sceneID.isEmpty { obj["scene_id"] = .string(s.sceneID) }
            return .object(obj)
        }
        return HueToolExecutionResult(ok: true, summary: "\(schedules.count) schedule(s)", payload: .object(["schedules": .array(arr)]))
    }

    private func executeGetFloorplan() -> HueToolExecutionResult {
        guard let fp = backend.currentFloorplan else {
            return HueToolExecutionResult(ok: true, summary: "No saved floorplan", payload: .object(["floorplan": .null]))
        }
        let boxes: [HueJSONValue] = fp.boxes.map { b in
            .object([
                "id": .string(b.id),
                "kind": .string(b.kind),
                "hue_id": b.hueID.map { .string($0) } ?? .null,
                "name": .string(b.name),
                "x": .double(b.x),
                "y": .double(b.y),
                "width": .double(b.width),
                "height": .double(b.height),
            ])
        }
        var lamps: [String: HueJSONValue] = [:]
        for (k, v) in fp.lamps {
            lamps[k] = .object(["x": .double(v.x), "y": .double(v.y), "z": .double(v.z), "icon": .string(v.icon.rawValue)])
        }
        var sensors: [String: HueJSONValue] = [:]
        for (k, v) in fp.sensors {
            sensors[k] = .object(["x": .double(v.x), "y": .double(v.y)])
        }
        return HueToolExecutionResult(
            ok: true,
            summary: "\(fp.boxes.count) room box(es), \(fp.lamps.count) placed lamp(s)",
            payload: .object([
                "template_id": .string(fp.templateID),
                "boxes": .array(boxes),
                "lamps": .object(lamps),
                "sensors": .object(sensors),
            ])
        )
    }

    private func executeSetLight(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let target = args["target"]?.stringValue ?? args["id"]?.stringValue ?? args["name"]?.stringValue,
              let light = Self.resolveLight(target, in: snap) else {
            return HueToolExecutionResult(ok: false, summary: "Light not found", payload: .object(["error": .string("Light not found")]))
        }
        let parsed = parseLightParams(args: args)
        let mirek = parsed.mirek.map { HueColorMath.clamp($0, light.mirekMin, light.mirekMax) }
        backend.setLight(id: light.id, on: parsed.on, bri: parsed.bri, mirek: mirek, xy: parsed.xy, effect: parsed.effect)

        let desc = describeLightMutation(name: light.name, parsed: parsed)
        return HueToolExecutionResult(
            ok: true,
            summary: desc,
            payload: .object(["ok": .bool(true), "light_id": .string(light.id), "name": .string(light.name), "summary": .string(desc)])
        )
    }

    private func executeSetRoom(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let target = args["target"]?.stringValue ?? args["id"]?.stringValue ?? args["name"]?.stringValue,
              let room = Self.resolveRoom(target, in: snap) else {
            return HueToolExecutionResult(ok: false, summary: "Room not found", payload: .object(["error": .string("Room not found")]))
        }
        let parsed = parseLightParams(args: args)
        backend.setRoom(room: room, on: parsed.on, bri: parsed.bri, mirek: parsed.mirek, xy: parsed.xy, effect: parsed.effect)

        let desc = describeLightMutation(name: room.name, parsed: parsed)
        return HueToolExecutionResult(
            ok: true,
            summary: desc,
            payload: .object(["ok": .bool(true), "room_id": .string(room.id), "name": .string(room.name), "summary": .string(desc)])
        )
    }

    private func executeRecallScene(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let sceneQuery = args["scene"]?.stringValue ?? args["id"]?.stringValue ?? args["name"]?.stringValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing scene", payload: .object(["error": .string("Missing scene")]))
        }
        let roomQuery = args["room"]?.stringValue
        guard let match = Self.resolveScene(sceneQuery, roomQuery: roomQuery, in: snap) else {
            return HueToolExecutionResult(ok: false, summary: "Scene not found: \(sceneQuery)", payload: .object(["error": .string("Scene not found")]))
        }
        backend.recallScene(id: match.scene.id)
        let summary = "\(match.scene.name) (\(match.room.name))"
        return HueToolExecutionResult(
            ok: true,
            summary: summary,
            payload: .object(["ok": .bool(true), "scene_id": .string(match.scene.id), "scene": .string(match.scene.name), "room": .string(match.room.name)])
        )
    }

    private func executeApplyTheme(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let themeQuery = args["theme"]?.stringValue,
              let theme = Self.resolveTheme(themeQuery, in: backend.currentThemes) else {
            return HueToolExecutionResult(ok: false, summary: "Theme not found", payload: .object(["error": .string("Theme not found")]))
        }
        guard let targetQuery = args["target"]?.stringValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing target", payload: .object(["error": .string("Missing target")]))
        }
        if let light = Self.resolveLight(targetQuery, in: snap) {
            backend.applyTheme(theme, to: light)
            let summary = "\(theme.name) → \(light.name)"
            return HueToolExecutionResult(ok: true, summary: summary, payload: .object(["ok": .bool(true), "theme": .string(theme.name), "target": .string(light.name)]))
        }
        if let room = Self.resolveRoom(targetQuery, in: snap) {
            for light in room.lights {
                backend.applyTheme(theme, to: light)
            }
            let summary = "\(theme.name) → \(room.name)"
            return HueToolExecutionResult(ok: true, summary: summary, payload: .object(["ok": .bool(true), "theme": .string(theme.name), "target": .string(room.name), "lights": .int(room.lights.count)]))
        }
        return HueToolExecutionResult(ok: false, summary: "Target not found: \(targetQuery)", payload: .object(["error": .string("Target not found")]))
    }

    private func executeSetSensor(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let target = args["target"]?.stringValue ?? args["id"]?.stringValue,
              let enabled = args["enabled"]?.boolValue,
              let sensor = Self.resolveSensor(target, in: snap) else {
            return HueToolExecutionResult(ok: false, summary: "Sensor not found", payload: .object(["error": .string("Sensor not found or missing enabled flag")]))
        }
        backend.setSensorEnabled(sensor: sensor, enabled: enabled)
        let summary = "\(sensor.name): \(enabled ? "enabled" : "disabled")"
        return HueToolExecutionResult(ok: true, summary: summary, payload: .object(["ok": .bool(true), "sensor_id": .string(sensor.id), "enabled": .bool(enabled)]))
    }

    private func executeSetMotionArea(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let target = args["target"]?.stringValue ?? args["id"]?.stringValue,
              let area = Self.resolveMotionArea(target, in: snap) else {
            return HueToolExecutionResult(ok: false, summary: "MotionAware area not found", payload: .object(["error": .string("MotionAware area not found")]))
        }
        let enabled = args["enabled"]?.boolValue
        let sensitivity = args["sensitivity"]?.intValue
        backend.updateMotionArea(area: area, enabled: enabled, sensitivity: sensitivity)
        var parts: [String] = []
        if let e = enabled { parts.append(e ? "enabled" : "disabled") }
        if let s = sensitivity { parts.append("sensitivity \(s)") }
        let summary = "\(area.name): \(parts.isEmpty ? "updated" : parts.joined(separator: ", "))"
        return HueToolExecutionResult(ok: true, summary: summary, payload: .object(["ok": .bool(true), "area_id": .string(area.id), "name": .string(area.name)]))
    }

    private func executeCreateRule(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let triggerQuery = args["trigger"]?.stringValue,
              let targetQuery = args["target"]?.stringValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing trigger or target", payload: .object(["error": .string("Missing trigger or target")]))
        }

        let requestedTriggerKind = (args["trigger_kind"]?.stringValue ?? "").lowercased()
        let resolvedTrigger: (kind: String, id: String, name: String)? = {
            if requestedTriggerKind == "desktop" || triggerQuery.lowercased() == "desktop" || triggerQuery.lowercased() == "mac" {
                return ("desktop", "desktop", "This Mac")
            }
            if requestedTriggerKind == "motion_area", let a = Self.resolveMotionArea(triggerQuery, in: snap) {
                return ("motion_area", a.id, a.name)
            }
            if ["motion", "contact", "button"].contains(requestedTriggerKind), let s = Self.resolveSensor(triggerQuery, in: snap) {
                return (s.kind, s.id, s.name)
            }
            if requestedTriggerKind == "light", let l = Self.resolveLight(triggerQuery, in: snap) {
                return ("light", l.id, l.name)
            }
            if requestedTriggerKind == "room", let r = Self.resolveRoom(triggerQuery, in: snap) {
                return ("room", r.id, r.name)
            }
            // Auto-resolve across all trigger entity types
            if let a = Self.resolveMotionArea(triggerQuery, in: snap) { return ("motion_area", a.id, a.name) }
            if let s = Self.resolveSensor(triggerQuery, in: snap) { return (s.kind, s.id, s.name) }
            if let l = Self.resolveLight(triggerQuery, in: snap) { return ("light", l.id, l.name) }
            if let r = Self.resolveRoom(triggerQuery, in: snap) { return ("room", r.id, r.name) }
            return nil
        }()

        guard let trig = resolvedTrigger else {
            return HueToolExecutionResult(ok: false, summary: "Trigger not found: \(triggerQuery)", payload: .object(["error": .string("Trigger not found")]))
        }

        let requestedTargetKind = (args["target_kind"]?.stringValue ?? "").lowercased()
        let actionRaw = (args["action"]?.stringValue ?? "on").lowercased()
        let bri = args["bri"]?.intValue.map { HueColorMath.clamp($0, 1, 100) }

        let resolvedTarget: (target: HueRuleTarget, name: String)? = {
            if requestedTargetKind == "scene" || actionRaw == "scene" {
                if let match = Self.resolveScene(targetQuery, roomQuery: nil, in: snap) {
                    return (HueRuleTarget(kind: "scene", id: match.scene.id, action: "scene", bri: nil, sceneID: match.scene.id), match.scene.name)
                }
            }
            if requestedTargetKind == "room", let r = Self.resolveRoom(targetQuery, in: snap) {
                return (HueRuleTarget(kind: "room", id: r.id, action: actionRaw == "off" ? "off" : "on", bri: bri), r.name)
            }
            if requestedTargetKind == "light", let l = Self.resolveLight(targetQuery, in: snap) {
                return (HueRuleTarget(kind: "light", id: l.id, action: actionRaw == "off" ? "off" : "on", bri: bri), l.name)
            }
            if let l = Self.resolveLight(targetQuery, in: snap) {
                return (HueRuleTarget(kind: "light", id: l.id, action: actionRaw == "off" ? "off" : "on", bri: bri), l.name)
            }
            if let r = Self.resolveRoom(targetQuery, in: snap) {
                return (HueRuleTarget(kind: "room", id: r.id, action: actionRaw == "off" ? "off" : "on", bri: bri), r.name)
            }
            return nil
        }()

        guard let tgt = resolvedTarget else {
            return HueToolExecutionResult(ok: false, summary: "Target not found: \(targetQuery)", payload: .object(["error": .string("Target not found")]))
        }

        let defaultTriggerState: String = {
            switch trig.kind {
            case "motion", "motion_area": return "motion"
            case "contact": return "open"
            case "button": return "press"
            case "desktop": return "wake"
            default: return "on"
            }
        }()
        let triggerState = (args["trigger_state"]?.stringValue?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? defaultTriggerState
        let kind: String = {
            if let k = args["kind"]?.stringValue?.lowercased(), ["follow", "exclusive", "companion", "desktop"].contains(k) {
                return k
            }
            if trig.kind == "desktop" { return "desktop" }
            if tgt.target.action == "off" && triggerState == "on" { return "exclusive" }
            return "follow"
        }()
        let mirrorOff = args["mirror_off"]?.boolValue ?? false
        let rawName = args["name"]?.stringValue ?? ""
        let ruleName = HueColorMath.clean(rawName.isEmpty ? "\(trig.name) → \(tgt.name)" : rawName, limit: 50)

        let rule = HueRule(
            name: ruleName,
            enabled: true,
            kind: kind,
            triggerKind: trig.kind,
            triggerID: trig.id,
            triggerState: triggerState,
            targets: [tgt.target],
            mirrorOff: mirrorOff
        )
        backend.addRule(rule)

        let summary = "Rule created: \(rule.name)"
        return HueToolExecutionResult(
            ok: true,
            summary: summary,
            payload: .object([
                "ok": .bool(true),
                "rule_id": .string(rule.id),
                "name": .string(rule.name),
                "trigger_kind": .string(rule.triggerKind),
                "trigger_state": .string(rule.triggerState),
            ])
        )
    }

    private func executeToggleRule(args: [String: HueJSONValue]) -> HueToolExecutionResult {
        guard let query = args["rule"]?.stringValue ?? args["id"]?.stringValue,
              let enabled = args["enabled"]?.boolValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing rule or enabled", payload: .object(["error": .string("Missing rule or enabled")]))
        }
        guard let rule = Self.resolveRule(query, in: backend.currentRules) else {
            return HueToolExecutionResult(ok: false, summary: "Rule not found: \(query)", payload: .object(["error": .string("Rule not found")]))
        }
        let ok = backend.toggleRule(id: rule.id, enabled: enabled)
        return HueToolExecutionResult(
            ok: ok,
            summary: "\(rule.name): \(enabled ? "enabled" : "disabled")",
            payload: .object(["ok": .bool(ok), "rule_id": .string(rule.id), "enabled": .bool(enabled)])
        )
    }

    private func executeDeleteRule(args: [String: HueJSONValue]) -> HueToolExecutionResult {
        guard let query = args["rule"]?.stringValue ?? args["id"]?.stringValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing rule", payload: .object(["error": .string("Missing rule")]))
        }
        guard let rule = Self.resolveRule(query, in: backend.currentRules) else {
            return HueToolExecutionResult(ok: false, summary: "Rule not found: \(query)", payload: .object(["error": .string("Rule not found")]))
        }
        let ok = backend.deleteRule(id: rule.id)
        return HueToolExecutionResult(
            ok: ok,
            summary: "Deleted rule: \(rule.name)",
            payload: .object(["ok": .bool(ok), "rule_id": .string(rule.id)])
        )
    }

    private func executeCreateSchedule(args: [String: HueJSONValue], snap: HueSnapshot) -> HueToolExecutionResult {
        guard let targetQuery = args["target"]?.stringValue else {
            return HueToolExecutionResult(ok: false, summary: "Missing target", payload: .object(["error": .string("Missing target")]))
        }
        let requestedKind = (args["target_kind"]?.stringValue ?? "").lowercased()
        let resolved: (kind: String, id: String, name: String)? = {
            if requestedKind == "room", let r = Self.resolveRoom(targetQuery, in: snap) { return ("room", r.id, r.name) }
            if requestedKind == "light", let l = Self.resolveLight(targetQuery, in: snap) { return ("light", l.id, l.name) }
            if let r = Self.resolveRoom(targetQuery, in: snap) { return ("room", r.id, r.name) }
            if let l = Self.resolveLight(targetQuery, in: snap) { return ("light", l.id, l.name) }
            return nil
        }()
        guard let target = resolved else {
            return HueToolExecutionResult(ok: false, summary: "Target not found: \(targetQuery)", payload: .object(["error": .string("Target not found")]))
        }

        let triggerKind: String = {
            let raw = (args["trigger_kind"]?.stringValue ?? "time").lowercased()
            return ["time", "sunrise", "sunset"].contains(raw) ? raw : "time"
        }()
        let time = args["time"]?.stringValue ?? "07:30"
        let offsetMin = HueColorMath.clamp(args["offset_min"]?.intValue ?? 0, -60, 60)
        let days = args["days"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let actionRaw = (args["action"]?.stringValue ?? "on").lowercased()
        var sceneID = ""
        var action = ["on", "off", "scene"].contains(actionRaw) ? actionRaw : "on"
        if let sceneQuery = args["scene"]?.stringValue, !sceneQuery.isEmpty,
           let match = Self.resolveScene(sceneQuery, roomQuery: target.kind == "room" ? target.name : nil, in: snap) {
            sceneID = match.scene.id
            action = "scene"
        }
        let bri = args["bri"]?.intValue.map { HueColorMath.clamp($0, 1, 100) }
        let rawName = args["name"]?.stringValue ?? ""
        let whenLabel = triggerKind == "time" ? time : triggerKind
        let name = HueColorMath.clean(rawName.isEmpty ? "\(target.name) \(whenLabel)" : rawName, limit: 50)

        let draft = HueScheduleDraft(
            name: name,
            targetKind: target.kind,
            targetID: target.id,
            targetName: target.name,
            triggerKind: triggerKind,
            time: time,
            offsetMin: offsetMin,
            days: days,
            action: action,
            bri: action == "on" ? (bri ?? 80) : nil,
            sceneID: sceneID,
            fadeMin: 0
        )
        backend.createSchedule(draft)
        let summary = "Schedule created: \(draft.name) (\(whenLabel))"
        return HueToolExecutionResult(
            ok: true,
            summary: summary,
            payload: .object([
                "ok": .bool(true),
                "name": .string(draft.name),
                "target": .string(draft.targetName),
                "trigger_kind": .string(draft.triggerKind),
                "time": .string(draft.time),
                "days": .array(draft.days.map { .string($0) }),
                "action": .string(draft.action),
            ])
        )
    }

    // MARK: - Resolution & Sanitization Helpers

    private struct ParsedLightParams {
        var on: Bool?
        var bri: Int?
        var mirek: Int?
        var xy: (Double, Double)?
        var colorLabel: String?
        var effect: String?
    }

    private func parseLightParams(args: [String: HueJSONValue]) -> ParsedLightParams {
        let on = args["on"]?.boolValue
        let bri = args["bri"]?.intValue.map { HueColorMath.clamp($0, 1, 100) }
        var mirek = args["mirek"]?.intValue.map { HueColorMath.clamp($0, 153, 500) }
        if mirek == nil, let k = args["kelvin"]?.intValue {
            mirek = HueColorMath.kelvinToMirek(HueColorMath.clamp(k, 2000, 6500))
        }
        var xy: (Double, Double)? = nil
        var colorLabel: String? = nil
        if let rawColor = args["color"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawColor.isEmpty {
            if let hex = HueAskAIEngine.resolveColorHex(rawColor), let conv = HueColorMath.hexToXY(hex) {
                xy = (conv.x, conv.y)
                colorLabel = rawColor
            } else if let m = HueAskAIEngine.resolveWarmthMirek(rawColor) {
                mirek = m
                colorLabel = rawColor
            }
        }
        let effect = args["effect"]?.stringValue.flatMap { e -> String? in
            let clean = e.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        return ParsedLightParams(on: on, bri: bri, mirek: mirek, xy: xy, colorLabel: colorLabel, effect: effect)
    }

    private func describeLightMutation(name: String, parsed: ParsedLightParams) -> String {
        var parts: [String] = []
        if let on = parsed.on { parts.append(on ? "on" : "off") }
        if let bri = parsed.bri { parts.append("\(bri)%") }
        if let m = parsed.mirek { parts.append("\(HueColorMath.mirekToKelvin(m))K") }
        if let c = parsed.colorLabel, parsed.xy != nil { parts.append(c) }
        if let e = parsed.effect, e != "no_effect" { parts.append(e) }
        return parts.isEmpty ? name : "\(name): \(parts.joined(separator: ", "))"
    }

    private func sanitizedBridgeJSON(_ bridge: BridgeInfo?) -> HueJSONValue {
        guard let b = bridge else { return .null }
        // NEVER include appKey, clientKey, or TLS fingerprint
        return .object([
            "name": .string(b.name),
            "ip": .string(b.ip),
            "model": .string(b.model),
            "is_pro": .bool(b.isPro),
            "motion_area_candidates": .int(b.motionAreaCandidates),
        ])
    }

    private func lightJSON(_ l: HueLight) -> HueJSONValue {
        var obj: [String: HueJSONValue] = [
            "id": .string(l.id),
            "name": .string(l.name),
            "on": .bool(l.on),
            "bri": .int(Int(l.bri.rounded())),
            "color": .string(l.color),
            "reachable": .bool(l.reachable),
            "supports_color": .bool(l.supportsColor),
            "supports_ct": .bool(l.supportsCT),
            "effect": .string(l.effect),
            "motion_aware": .bool(l.motionAware),
            "motion_active": .bool(l.motionActive),
        ]
        if let m = l.mirek { obj["mirek"] = .int(m) }
        return .object(obj)
    }

    private func roomJSON(_ r: HueRoom, snap: HueSnapshot) -> HueJSONValue {
        let presence = snap.motionAreas.contains { $0.roomID == r.id && $0.enabled && $0.motion }
        return .object([
            "id": .string(r.id),
            "kind": .string(r.kind),
            "name": .string(r.name),
            "on": .bool(r.on),
            "bri": .int(Int(r.bri.rounded())),
            "on_count": .int(r.onCount),
            "light_count": .int(r.lights.count),
            "motion_presence": .bool(presence),
            "lights": .array(r.lights.map(lightJSON)),
            "scenes": .array(r.scenes.map { .object(["id": .string($0.id), "name": .string($0.name), "active": .bool($0.active)]) }),
        ])
    }

    private func sensorJSON(_ s: HueSensor) -> HueJSONValue {
        var obj: [String: HueJSONValue] = [
            "id": .string(s.id),
            "kind": .string(s.kind),
            "name": .string(s.name),
            "room_id": .string(s.roomID),
            "enabled": .bool(s.enabled),
            "motion": .bool(s.motion),
            "open": .bool(s.open),
        ]
        if let t = s.temperature { obj["temperature"] = .double(t) }
        if let l = s.lux { obj["lux"] = .double(l) }
        if let b = s.battery { obj["battery"] = .int(b) }
        if !s.lastEvent.isEmpty { obj["last_event"] = .string(s.lastEvent) }
        return .object(obj)
    }

    private func motionAreaJSON(_ a: HueMotionArea) -> HueJSONValue {
        var obj: [String: HueJSONValue] = [
            "id": .string(a.id),
            "name": .string(a.name),
            "room_id": .string(a.roomID),
            "enabled": .bool(a.enabled),
            "motion": .bool(a.motion),
            "health": .string(a.health),
            "light_ids": .array(a.lightIDs.map { .string($0) }),
        ]
        if let s = a.sensitivity { obj["sensitivity"] = .int(s) }
        if let m = a.sensitivityMax { obj["sensitivity_max"] = .int(m) }
        return .object(obj)
    }

    public static func resolveLight(_ query: String, in snap: HueSnapshot) -> HueLight? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        let lights = snap.allLights
        if let exactID = lights.first(where: { $0.id.lowercased() == lower }) { return exactID }
        if let exactName = lights.first(where: { $0.name.lowercased() == lower }) { return exactName }
        return lights
            .filter { $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }

    public static func resolveRoom(_ query: String, in snap: HueSnapshot) -> HueRoom? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        if let exactID = snap.rooms.first(where: { $0.id.lowercased() == lower || $0.hueID.lowercased() == lower }) { return exactID }
        if let exactName = snap.rooms.first(where: { $0.name.lowercased() == lower }) { return exactName }
        if let partial = snap.rooms
            .filter({ !$0.name.isEmpty && ($0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased())) })
            .max(by: { $0.name.count < $1.name.count }) {
            return partial
        }
        // Cross-language EN/DE room synonym fallback
        for (synonym, archetype) in HueAskAIEngine.roomSynonyms {
            if lower == synonym || lower.contains(synonym) {
                if let byArch = snap.rooms.first(where: { $0.archetype.lowercased() == archetype || $0.name.lowercased().contains(archetype.replacingOccurrences(of: "_", with: " ")) }) {
                    return byArch
                }
            }
        }
        return nil
    }

    public static func resolveScene(_ query: String, roomQuery: String?, in snap: HueSnapshot) -> (room: HueRoom, scene: HueScene)? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let scopedRooms: [HueRoom]
        if let rq = roomQuery, !rq.isEmpty, let matchedRoom = resolveRoom(rq, in: snap) {
            scopedRooms = [matchedRoom]
        } else {
            scopedRooms = snap.rooms
        }
        for room in scopedRooms {
            if let exact = room.scenes.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) {
                return (room, exact)
            }
        }
        for room in scopedRooms {
            if let partial = room.scenes.first(where: { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }) {
                return (room, partial)
            }
        }
        return nil
    }

    public static func resolveTheme(_ query: String, in themes: [HueLightTheme]) -> HueLightTheme? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = themes.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) { return exact }
        return themes
            .filter { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }

    public static func resolveSensor(_ query: String, in snap: HueSnapshot) -> HueSensor? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = snap.sensors.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) { return exact }
        return snap.sensors
            .filter { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }

    public static func resolveMotionArea(_ query: String, in snap: HueSnapshot) -> HueMotionArea? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = snap.motionAreas.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) { return exact }
        if let partial = snap.motionAreas
            .filter({ $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return partial
        }
        if let room = resolveRoom(q, in: snap) {
            return snap.motionAreas.first { $0.roomID == room.id }
        }
        return nil
    }

    public static func resolveRule(_ query: String, in rules: [HueRule]) -> HueRule? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = rules.first(where: { $0.id.lowercased() == q || $0.name.lowercased() == q }) { return exact }
        return rules
            .filter { $0.name.lowercased().contains(q) || q.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }
}

// MARK: - Local-First Natural-Language Ask AI Engine (Offline EN & DE + Optional Local Ollama)

public struct HueAskAIEngine: Sendable {
    public init() {}

    /// Future on-device Apple FoundationModels hook (macOS 26+ Apple Intelligence).
    /// Compiles cleanly on macOS 13–15 where `FoundationModels` is not present.
    public static var supportsAppleFoundationModels: Bool {
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }

    /// Strict loopback guard: plain HTTP is ONLY allowed for `127.0.0.1`, `localhost`, or `::1`,
    /// with no embedded credentials. Prevents accidental exfiltration of home data to remote servers.
    public static func validatedLocalOllamaEndpoint(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard components.user == nil && components.password == nil else { return nil }
        guard let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return nil
        }
        var base = trimmed
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/api/chat") {
            base += "/api/chat"
        }
        return URL(string: base)
    }

    public static func isValidLoopbackURL(_ raw: String) -> Bool {
        validatedLocalOllamaEndpoint(raw) != nil
    }

    // MARK: - Lookup Tables (EN & DE)

    static let roomSynonyms: [(String, String)] = [
        ("wohnzimmer", "living_room"),
        ("living room", "living_room"),
        ("livingroom", "living_room"),
        ("arbeitszimmer", "office"),
        ("büro", "office"),
        ("buero", "office"),
        ("office", "office"),
        ("schlafzimmer", "bedroom"),
        ("bedroom", "bedroom"),
        ("flur", "hallway"),
        ("diele", "hallway"),
        ("eingang", "hallway"),
        ("hallway", "hallway"),
        ("küche", "kitchen"),
        ("kueche", "kitchen"),
        ("kitchen", "kitchen"),
        ("badezimmer", "bathroom"),
        ("bad", "bathroom"),
        ("bathroom", "bathroom"),
        ("esszimmer", "dining"),
        ("dining", "dining"),
        ("terrasse", "terrace"),
        ("balkon", "balcony"),
    ]

    private static let namedColors: [(String, String)] = [
        ("crimson", "#dc143c"),
        ("magenta", "#ff00cc"),
        ("turquoise", "#14b8a6"),
        ("türkis", "#14b8a6"),
        ("tuerkis", "#14b8a6"),
        ("violet", "#8b5cf6"),
        ("violett", "#8b5cf6"),
        ("purple", "#9333ea"),
        ("orange", "#ff7a00"),
        ("yellow", "#facc15"),
        ("green", "#22c55e"),
        ("white", "#fff8ee"),
        ("amber", "#ffaa22"),
        ("coral", "#ff6b6b"),
        ("cyan", "#00d4ff"),
        ("blue", "#2563eb"),
        ("blau", "#2563eb"),
        ("pink", "#ec4899"),
        ("rosa", "#ec4899"),
        ("lila", "#9333ea"),
        ("grün", "#22c55e"),
        ("gruen", "#22c55e"),
        ("gelb", "#facc15"),
        ("weiß", "#fff8ee"),
        ("weiss", "#fff8ee"),
        ("red", "#ef4444"),
        ("rot", "#ef4444"),
    ]

    private static let warmthKeywords: [(String, Int)] = [
        ("candlelight", HueColorMath.kelvinToMirek(2000)),
        ("kerzenlicht", HueColorMath.kelvinToMirek(2000)),
        ("warm white", HueColorMath.kelvinToMirek(2700)),
        ("warmweiß", HueColorMath.kelvinToMirek(2700)),
        ("warmweiss", HueColorMath.kelvinToMirek(2700)),
        ("tageslicht", HueColorMath.kelvinToMirek(5500)),
        ("daylight", HueColorMath.kelvinToMirek(5500)),
        ("cool white", HueColorMath.kelvinToMirek(4800)),
        ("kaltweiß", HueColorMath.kelvinToMirek(4800)),
        ("kaltweiss", HueColorMath.kelvinToMirek(4800)),
        ("gemütlich", HueColorMath.kelvinToMirek(2400)),
        ("gemuetlich", HueColorMath.kelvinToMirek(2400)),
        ("neutral", HueColorMath.kelvinToMirek(4000)),
        ("cozy", HueColorMath.kelvinToMirek(2400)),
        ("warm", HueColorMath.kelvinToMirek(2700)),
        ("cool", HueColorMath.kelvinToMirek(4800)),
        ("kalt", HueColorMath.kelvinToMirek(4800)),
    ]

    private static let effectKeywords: [(String, String)] = [
        ("candle", "candle"),
        ("kerze", "candle"),
        ("fireplace", "fire"),
        ("kamin", "fire"),
        ("fire", "fire"),
        ("feuer", "fire"),
        ("sparkle", "sparkle"),
        ("funkeln", "sparkle"),
        ("prism", "prism"),
        ("prisma", "prism"),
        ("opal", "opal"),
        ("glisten", "glisten"),
        ("no effect", "no_effect"),
        ("kein effekt", "no_effect"),
    ]

    public static func resolveColorHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("#") && trimmed.count == 7 && HueColorMath.hexToXY(trimmed) != nil {
            return trimmed
        }
        for (name, hex) in namedColors {
            if trimmed == name { return hex }
        }
        return nil
    }

    public static func resolveWarmthMirek(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (kw, mirek) in warmthKeywords {
            if trimmed == kw { return mirek }
        }
        return nil
    }

    // MARK: - Built-in Offline Parser (EN & DE)

    public func parse(
        _ prompt: String,
        snapshot: HueSnapshot,
        themes: [HueLightTheme] = HueLightTheme.builtIn
    ) -> HueAskAIPlan {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return HueAskAIPlan(calls: []) }
        let lower = clean.lowercased()

        // 1. Status queries
        if isStatusQuery(lower) {
            return HueAskAIPlan(calls: [HueToolCall(name: "hue_status")], replyHint: "Status", isStatusQuery: true)
        }

        // 2. Rule creation ("when ...", "if ...", "wenn ...", "sobald ...")
        if let ruleCall = parseRuleCreation(lower: lower, snapshot: snapshot) {
            return HueAskAIPlan(calls: [ruleCall], replyHint: "Rule created")
        }

        // 3. Schedule creation ("... at 07:30 weekdays", "... um 07:30 werktags", "... at sunset")
        if let scheduleCall = parseScheduleCreation(lower: lower, snapshot: snapshot) {
            return HueAskAIPlan(calls: [scheduleCall], replyHint: "Schedule created")
        }

        // 4. Sensor / MotionAware enable or disable
        if let sensorCall = parseSensorOrMotionAreaToggle(lower: lower, snapshot: snapshot) {
            return HueAskAIPlan(calls: [sensorCall], replyHint: "Sensor updated")
        }

        // 5. All lights on / off
        if isAllOff(lower) {
            return HueAskAIPlan(calls: [HueToolCall(name: "hue_all_off")], replyHint: "All lights off")
        }
        if isAllOn(lower) {
            return HueAskAIPlan(calls: [HueToolCall(name: "hue_all_on")], replyHint: "All lights on")
        }

        // 6. Theme application (check matched theme + target)
        let matchedRoom = findBestRoom(in: lower, snapshot: snapshot)
        let matchedLight = findBestLight(in: lower, snapshot: snapshot)
        let matchedTheme = findBestTheme(in: lower, themes: themes)
        let matchedScene = findBestScene(in: lower, room: matchedRoom, snapshot: snapshot)

        let wantsThemeExplicitly = containsWord(lower, "theme") || containsWord(lower, "thema") || containsWord(lower, "apply")
        let wantsSceneExplicitly = containsWord(lower, "scene") || containsWord(lower, "szene")

        if let theme = matchedTheme, (!wantsSceneExplicitly || wantsThemeExplicitly) {
            let exactThemeMention = lower.contains(theme.name.lowercased())
            if let sceneMatch = matchedScene, !wantsThemeExplicitly && (!exactThemeMention || sceneMatch.scene.name.lowercased() == theme.name.lowercased()) {
                return HueAskAIPlan(
                    calls: [HueToolCall(name: "hue_recall_scene", arguments: [
                        "scene": .string(sceneMatch.scene.id),
                        "room": .string(sceneMatch.room.id),
                    ])],
                    replyHint: "Scene recalled"
                )
            }
            if let targetName = matchedLight?.id ?? matchedRoom?.id ?? snapshot.rooms.first?.id {
                return HueAskAIPlan(
                    calls: [HueToolCall(name: "hue_apply_theme", arguments: [
                        "theme": .string(theme.id),
                        "target": .string(targetName),
                    ])],
                    replyHint: "Theme applied"
                )
            }
        }

        // 7. Scene recall
        if let sceneMatch = matchedScene {
            return HueAskAIPlan(
                calls: [HueToolCall(name: "hue_recall_scene", arguments: [
                    "scene": .string(sceneMatch.scene.id),
                    "room": .string(sceneMatch.room.id),
                ])],
                replyHint: "Scene recalled"
            )
        }

        // 8. Individual light or room control (on/off, brightness, kelvin/warmth, color, hex, effect)
        let args = extractLightAttributes(lower: lower)
        if !args.isEmpty {
            if let light = matchedLight {
                var full = args
                full["target"] = .string(light.id)
                return HueAskAIPlan(calls: [HueToolCall(name: "hue_set_light", arguments: full)])
            }
            if let room = matchedRoom {
                var full = args
                full["target"] = .string(room.id)
                return HueAskAIPlan(calls: [HueToolCall(name: "hue_set_room", arguments: full)])
            }
        }

        return HueAskAIPlan(calls: [])
    }

    // MARK: - Full Execution (Built-in Offline First + Optional Local Ollama Fallback)

    public func ask(
        _ prompt: String,
        snapshot: HueSnapshot,
        themes: [HueLightTheme] = HueLightTheme.builtIn,
        config: HueAskAIConfig = HueAskAIConfig(),
        executor: @escaping @Sendable (HueToolCall) async -> HueToolExecutionResult
    ) async -> HueAskAIResponse {
        let plan = parse(prompt, snapshot: snapshot, themes: themes)
        if !plan.calls.isEmpty {
            var actions: [HueExecutedAction] = []
            var summaries: [String] = []
            for call in plan.calls {
                let res = await executor(call)
                actions.append(HueExecutedAction(tool: call.name, summary: res.summary, ok: res.ok))
                summaries.append(res.summary)
            }
            let reply = summaries.joined(separator: "\n")
            return HueAskAIResponse(reply: reply, actions: actions, source: "local", matched: true)
        }

        // Optional local-only Ollama fallback (loopback only, never sends credentials)
        if let endpoint = Self.validatedLocalOllamaEndpoint(config.ollamaURL) {
            let modelName = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ollamaResult = await queryLocalOllama(
                endpoint: endpoint,
                model: modelName.isEmpty ? "llama3.2" : modelName,
                prompt: prompt,
                snapshot: snapshot,
                themes: themes,
                timeout: config.timeoutSeconds
            ) {
                var actions: [HueExecutedAction] = []
                var summaries: [String] = []
                for call in ollamaResult.calls {
                    let res = await executor(call)
                    actions.append(HueExecutedAction(tool: call.name, summary: res.summary, ok: res.ok))
                    summaries.append(res.summary)
                }
                let replyText = ollamaResult.reply.isEmpty ? summaries.joined(separator: "\n") : ollamaResult.reply
                return HueAskAIResponse(
                    reply: replyText.isEmpty ? "Done." : replyText,
                    actions: actions,
                    source: "ollama",
                    matched: !actions.isEmpty || !ollamaResult.reply.isEmpty
                )
            }
        }

        return HueAskAIResponse(
            reply: "Try: \"All lights off\", \"Dim Living Room to 40% warm\", \"Apply Cyberpunk Neon to Office\", \"Turn on Hallway at 07:30 weekdays\", or \"When Hallway Motion detects motion, turn on Hallway\".",
            actions: [],
            source: "none",
            matched: false
        )
    }

    // MARK: - Optional Loopback-Only Ollama Client

    private struct OllamaParsedReply: Sendable {
        var reply: String
        var calls: [HueToolCall]
    }

    private func queryLocalOllama(
        endpoint: URL,
        model: String,
        prompt: String,
        snapshot: HueSnapshot,
        themes: [HueLightTheme],
        timeout: TimeInterval
    ) async -> OllamaParsedReply? {
        // Build minimal non-secret home context (NEVER includes appKey, clientKey, or bridge IP)
        let roomNames = snapshot.rooms.map(\.name).filter { !$0.isEmpty }
        let lightNames = snapshot.allLights.map(\.name)
        let sceneNames = snapshot.rooms.flatMap { r in r.scenes.map { "\($0.name) (\(r.name))" } }
        let themeNames = themes.map(\.name)
        let sensorNames = snapshot.sensors.map(\.name) + snapshot.motionAreas.map(\.name)

        let systemPrompt = """
        You are a local Philips Hue lighting assistant. Respond ONLY with strict JSON:
        {"reply":"short reply","calls":[{"name":"<tool>","arguments":{...}}]}
        Available tools: hue_status, hue_all_on, hue_all_off, hue_set_light, hue_set_room, hue_recall_scene, hue_apply_theme, hue_set_sensor, hue_set_motion_area, hue_create_rule, hue_create_schedule.
        Rooms: \(roomNames.joined(separator: ", "))
        Lights: \(lightNames.joined(separator: ", "))
        Scenes: \(sceneNames.joined(separator: ", "))
        Themes: \(themeNames.joined(separator: ", "))
        Sensors: \(sensorNames.joined(separator: ", "))
        """

        let bodyObj: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj) else { return nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout + 4.0
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        do {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = root["message"] as? [String: Any],
                  let content = msg["content"] as? String,
                  let contentData = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                return nil
            }
            let reply = (parsed["reply"] as? String) ?? ""
            var calls: [HueToolCall] = []
            if let rawCalls = parsed["calls"] as? [[String: Any]] {
                for item in rawCalls {
                    guard let name = item["name"] as? String, !name.isEmpty else { continue }
                    let rawArgs = (item["arguments"] as? [String: Any]) ?? [:]
                    var typedArgs: [String: HueJSONValue] = [:]
                    for (k, v) in rawArgs { typedArgs[k] = HueJSONValue.fromFoundation(v) }
                    calls.append(HueToolCall(name: name, arguments: typedArgs))
                }
            }
            return OllamaParsedReply(reply: reply, calls: calls)
        } catch {
            return nil
        }
    }

    // MARK: - Parser Sub-Routines

    private func isStatusQuery(_ lower: String) -> Bool {
        let phrases = [
            "which lights are on", "what lights are on", "what is on", "which lamps are on",
            "lights status", "hue status", "status",
            "welche lichter sind an", "welche lampen sind an", "was ist an", "wie ist der status",
        ]
        return phrases.contains { lower.contains($0) }
    }

    private func isAllOff(_ lower: String) -> Bool {
        let phrases = [
            "all lights off", "turn off all", "switch off all", "turn all lights off", "switch all lights off",
            "everything off", "all off", "lights out",
            "alle lichter aus", "alle lampen aus", "alles aus", "licht aus überall", "alle aus",
        ]
        return phrases.contains { lower.contains($0) }
    }

    private func isAllOn(_ lower: String) -> Bool {
        let phrases = [
            "all lights on", "turn on all", "switch on all", "turn all lights on", "switch all lights on",
            "everything on", "all on",
            "alle lichter an", "alle lichter ein", "alle lampen an", "alle lampen ein", "alles an", "alles ein",
        ]
        return phrases.contains { lower.contains($0) }
    }

    private func parseRuleCreation(lower: String, snapshot: HueSnapshot) -> HueToolCall? {
        let prefixes = ["when ", "whenever ", "if ", "wenn ", "sobald ", "falls "]
        guard prefixes.contains(where: { lower.hasPrefix($0) || lower.contains(" " + $0) }) else {
            return nil
        }

        // Split trigger clause and action clause
        let separators = [" -> ", " → ", " then ", " dann ", ", "]
        var triggerClause = ""
        var actionClause = ""
        for sep in separators {
            if let range = lower.range(of: sep) {
                triggerClause = String(lower[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                actionClause = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !triggerClause.isEmpty, !actionClause.isEmpty else { return nil }

        // Resolve trigger entity & state
        var triggerKind = ""
        var triggerID = ""
        var triggerState = ""

        if containsWord(triggerClause, "mac") || containsWord(triggerClause, "computer") || containsWord(triggerClause, "desktop") {
            triggerKind = "desktop"
            triggerID = "desktop"
            if triggerClause.contains("sleep") || triggerClause.contains("lock") || triggerClause.contains("schläf") || triggerClause.contains("ruhezustand") || triggerClause.contains("sperr") {
                triggerState = "sleep"
            } else {
                triggerState = "wake"
            }
        } else if let area = findBestMotionArea(in: triggerClause, snapshot: snapshot) {
            triggerKind = "motion_area"
            triggerID = area.id
            triggerState = (triggerClause.contains("no motion") || triggerClause.contains("clear") || triggerClause.contains("keine bewegung")) ? "clear" : "motion"
        } else if let sensor = findBestSensor(in: triggerClause, snapshot: snapshot) {
            triggerKind = sensor.kind
            triggerID = sensor.id
            switch sensor.kind {
            case "motion":
                triggerState = (triggerClause.contains("no motion") || triggerClause.contains("clear") || triggerClause.contains("keine bewegung")) ? "clear" : "motion"
            case "contact":
                triggerState = (triggerClause.contains("close") || triggerClause.contains("schließ") || triggerClause.contains("schliess") || triggerClause.contains("zu")) ? "closed" : "open"
            case "button":
                triggerState = (triggerClause.contains("long") || triggerClause.contains("lang")) ? "long_press" : "press"
            default:
                triggerState = "motion"
            }
        } else if let light = findBestLight(in: triggerClause, snapshot: snapshot) {
            triggerKind = "light"
            triggerID = light.id
            triggerState = detectsOff(triggerClause) ? "off" : "on"
        } else if let room = findBestRoom(in: triggerClause, snapshot: snapshot) {
            triggerKind = "room"
            triggerID = room.id
            triggerState = detectsOff(triggerClause) ? "off" : "on"
        } else {
            return nil
        }

        // Resolve action target & state
        var targetKind = ""
        var targetID = ""
        var action = detectsOff(actionClause) ? "off" : "on"

        if let light = findBestLight(in: actionClause, snapshot: snapshot) {
            targetKind = "light"
            targetID = light.id
        } else if let room = findBestRoom(in: actionClause, snapshot: snapshot) {
            targetKind = "room"
            targetID = room.id
        } else if let sceneMatch = findBestScene(in: actionClause, room: nil, snapshot: snapshot) {
            targetKind = "scene"
            targetID = sceneMatch.scene.id
            action = "scene"
        } else {
            return nil
        }

        var args: [String: HueJSONValue] = [
            "trigger_kind": .string(triggerKind),
            "trigger": .string(triggerID),
            "trigger_state": .string(triggerState),
            "target_kind": .string(targetKind),
            "target": .string(targetID),
            "action": .string(action),
        ]
        if let bri = extractBrightness(actionClause) {
            args["bri"] = .int(bri)
        }
        if lower.contains("mirror") || lower.contains("together") || lower.contains("wieder aus") || lower.contains("auch aus") {
            args["mirror_off"] = .bool(true)
        }
        if triggerKind == "desktop" {
            args["kind"] = .string("desktop")
        } else if action == "off" && triggerState == "on" {
            args["kind"] = .string("exclusive")
        } else {
            args["kind"] = .string("follow")
        }
        return HueToolCall(name: "hue_create_rule", arguments: args)
    }

    private func parseScheduleCreation(lower: String, snapshot: HueSnapshot) -> HueToolCall? {
        let timeStr = extractClockTime(lower)
        let isSunrise = lower.contains("sunrise") || lower.contains("sonnenaufgang")
        let isSunset = lower.contains("sunset") || lower.contains("sonnenuntergang")
        guard timeStr != nil || isSunrise || isSunset else { return nil }

        // Avoid colliding with plain "Sunset" / "Sunset Glow" scene or theme recall unless schedule cues exist
        if timeStr == nil && (isSunrise || isSunset) {
            let hasScheduleCue = lower.contains("at sunset") || lower.contains("at sunrise")
                || lower.contains("bei sonnenuntergang") || lower.contains("bei sonnenaufgang")
                || lower.contains("zum sonnenuntergang") || lower.contains("zum sonnenaufgang")
                || containsWord(lower, "schedule") || containsWord(lower, "zeitplan")
                || containsWord(lower, "turn") || containsWord(lower, "switch")
                || containsWord(lower, "schalte") || containsWord(lower, "ausschalten") || containsWord(lower, "einschalten")
                || containsWord(lower, "daily") || containsWord(lower, "täglich") || containsWord(lower, "weekdays") || containsWord(lower, "werktags")
            if !hasScheduleCue { return nil }
        }

        let targetRoom = findBestRoom(in: lower, snapshot: snapshot)
        let targetLight = findBestLight(in: lower, snapshot: snapshot)
        guard targetRoom != nil || targetLight != nil else { return nil }

        let targetKind = targetLight != nil ? "light" : "room"
        let targetID = targetLight?.id ?? targetRoom!.id

        let triggerKind = isSunrise ? "sunrise" : (isSunset ? "sunset" : "time")
        let action = detectsOff(lower) ? "off" : "on"
        let days = extractWeekdays(lower)

        var args: [String: HueJSONValue] = [
            "target_kind": .string(targetKind),
            "target": .string(targetID),
            "trigger_kind": .string(triggerKind),
            "time": .string(timeStr ?? "07:30"),
            "days": .array(days.map { .string($0) }),
            "action": .string(action),
        ]
        if let bri = extractBrightness(lower) {
            args["bri"] = .int(bri)
        }
        return HueToolCall(name: "hue_create_schedule", arguments: args)
    }

    private func parseSensorOrMotionAreaToggle(lower: String, snapshot: HueSnapshot) -> HueToolCall? {
        let wantsDisable = lower.contains("disable") || lower.contains("deaktivier") || detectsOff(lower)
        let wantsEnable = lower.contains("enable") || lower.contains("aktivier") || detectsOn(lower)
        guard wantsDisable || wantsEnable else { return nil }
        let enabled = wantsDisable ? false : true

        if let area = findBestMotionArea(in: lower, snapshot: snapshot) {
            return HueToolCall(name: "hue_set_motion_area", arguments: [
                "target": .string(area.id),
                "enabled": .bool(enabled),
            ])
        }
        if let sensor = findBestSensor(in: lower, snapshot: snapshot) {
            return HueToolCall(name: "hue_set_sensor", arguments: [
                "target": .string(sensor.id),
                "enabled": .bool(enabled),
            ])
        }
        return nil
    }

    private func extractLightAttributes(lower: String) -> [String: HueJSONValue] {
        var args: [String: HueJSONValue] = [:]

        if let bri = extractBrightness(lower) {
            args["bri"] = .int(bri)
            args["on"] = .bool(true)
        }
        if let kelvin = extractKelvin(lower) {
            args["kelvin"] = .int(kelvin)
            args["on"] = .bool(true)
        } else {
            for (kw, mirek) in Self.warmthKeywords {
                if containsWord(lower, kw) {
                    args["mirek"] = .int(mirek)
                    args["on"] = .bool(true)
                    break
                }
            }
        }
        if let hex = extractHexColor(lower) {
            args["color"] = .string(hex)
            args["on"] = .bool(true)
        } else {
            for (name, hex) in Self.namedColors {
                if containsWord(lower, name) {
                    args["color"] = .string(hex)
                    args["on"] = .bool(true)
                    break
                }
            }
        }
        for (kw, effect) in Self.effectKeywords {
            if containsWord(lower, kw) {
                args["effect"] = .string(effect)
                if effect != "no_effect" { args["on"] = .bool(true) }
                break
            }
        }

        if detectsOff(lower) {
            args["on"] = .bool(false)
        } else if detectsOn(lower) && args["on"] == nil {
            args["on"] = .bool(true)
        }
        return args
    }

    // MARK: - Entity Matchers

    private func findBestLight(in lower: String, snapshot: HueSnapshot) -> HueLight? {
        snapshot.allLights
            .filter { !$0.name.isEmpty && lower.contains($0.name.lowercased()) }
            .max { $0.name.count < $1.name.count }
    }

    private func findBestRoom(in lower: String, snapshot: HueSnapshot) -> HueRoom? {
        if let direct = snapshot.rooms
            .filter({ !$0.name.isEmpty && $0.kind != "other" && lower.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return direct
        }
        for (synonym, archetype) in Self.roomSynonyms {
            if containsWord(lower, synonym) {
                if let match = snapshot.rooms.first(where: {
                    $0.archetype.lowercased() == archetype
                        || $0.name.lowercased().contains(archetype.replacingOccurrences(of: "_", with: " "))
                }) {
                    return match
                }
            }
        }
        return nil
    }

    private func findBestTheme(in lower: String, themes: [HueLightTheme]) -> HueLightTheme? {
        if let direct = themes
            .filter({ !$0.name.isEmpty && lower.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return direct
        }
        // Short alias match (e.g. "cyberpunk" -> "Cyberpunk Neon", "ocean" -> "Ocean Calm")
        for theme in themes {
            let firstWord = theme.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
            if firstWord.count >= 5 && containsWord(lower, firstWord) {
                return theme
            }
        }
        return nil
    }

    private func findBestScene(in lower: String, room: HueRoom?, snapshot: HueSnapshot) -> (room: HueRoom, scene: HueScene)? {
        let candidates = room.map { [$0] } ?? snapshot.rooms
        var best: (room: HueRoom, scene: HueScene)? = nil
        for r in candidates {
            for s in r.scenes where !s.name.isEmpty {
                let sLower = s.name.lowercased()
                if containsWord(lower, sLower) {
                    if best == nil || s.name.count > best!.scene.name.count {
                        best = (r, s)
                    }
                }
            }
        }
        return best
    }

    private func findBestSensor(in lower: String, snapshot: HueSnapshot) -> HueSensor? {
        if let direct = snapshot.sensors
            .filter({ !$0.name.isEmpty && lower.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return direct
        }
        let wantsMotion = lower.contains("motion") || lower.contains("bewegung")
        let wantsContact = lower.contains("contact") || lower.contains("door") || lower.contains("tür") || lower.contains("kontakt")
        let wantsButton = lower.contains("button") || lower.contains("switch") || lower.contains("schalter")
        if wantsMotion || wantsContact || wantsButton {
            let wantedKind = wantsMotion ? "motion" : (wantsContact ? "contact" : "button")
            if let room = findBestRoom(in: lower, snapshot: snapshot),
               let inRoom = snapshot.sensors.first(where: { $0.kind == wantedKind && $0.roomID == room.id }) {
                return inRoom
            }
            return snapshot.sensors.first { $0.kind == wantedKind }
        }
        return nil
    }

    private func findBestMotionArea(in lower: String, snapshot: HueSnapshot) -> HueMotionArea? {
        if let direct = snapshot.motionAreas
            .filter({ !$0.name.isEmpty && lower.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return direct
        }
        if lower.contains("motionaware") || lower.contains("motion aware") || lower.contains("presence") || lower.contains("präsenz") || lower.contains("motion area") {
            if let room = findBestRoom(in: lower, snapshot: snapshot),
               let area = snapshot.motionAreas.first(where: { $0.roomID == room.id }) {
                return area
            }
            return snapshot.motionAreas.first
        }
        return nil
    }

    // MARK: - Token Extractors

    private func detectsOff(_ lower: String) -> Bool {
        let cues = ["turn off", "switch off", "power off", "shut off", "ausschalten", "ausmachen", "abschalten"]
        if cues.contains(where: { lower.contains($0) }) { return true }
        return containsWord(lower, "off") || containsWord(lower, "aus")
    }

    private func detectsOn(_ lower: String) -> Bool {
        let cues = ["turn on", "switch on", "power on", "einschalten", "anmachen", "anschalten"]
        if cues.contains(where: { lower.contains($0) }) { return true }
        return containsWord(lower, "on") || containsWord(lower, "an") || containsWord(lower, "ein")
    }

    private func extractBrightness(_ lower: String) -> Int? {
        let pattern = #"(\d{1,3})\s*(%|percent|prozent)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower),
              let val = Int(lower[range]) else { return nil }
        return HueColorMath.clamp(val, 1, 100)
    }

    private func extractKelvin(_ lower: String) -> Int? {
        let pattern = #"(\d{4})\s*k\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower),
              let val = Int(lower[range]) else { return nil }
        return HueColorMath.clamp(val, 2000, 6500)
    }

    private func extractHexColor(_ lower: String) -> String? {
        let pattern = #"#[0-9a-f]{6}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range, in: lower) else { return nil }
        return String(lower[range])
    }

    private func extractClockTime(_ lower: String) -> String? {
        let pattern = #"\b(\d{1,2}):(\d{2})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let hRange = Range(match.range(at: 1), in: lower),
           let mRange = Range(match.range(at: 2), in: lower),
           let h = Int(lower[hRange]), let m = Int(lower[mRange]),
           (0...23).contains(h), (0...59).contains(m) {
            return String(format: "%02d:%02d", h, m)
        }
        let ampmPattern = #"\b(\d{1,2})\s*(am|pm)\b"#
        if let regex = try? NSRegularExpression(pattern: ampmPattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let hRange = Range(match.range(at: 1), in: lower),
           let apRange = Range(match.range(at: 2), in: lower),
           let rawH = Int(lower[hRange]), (1...12).contains(rawH) {
            let ap = lower[apRange]
            let h = (ap == "pm") ? (rawH == 12 ? 12 : rawH + 12) : (rawH == 12 ? 0 : rawH)
            return String(format: "%02d:00", h)
        }
        let uhrPattern = #"\bum\s+(\d{1,2})\s*uhr\b"#
        if let regex = try? NSRegularExpression(pattern: uhrPattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let hRange = Range(match.range(at: 1), in: lower),
           let h = Int(lower[hRange]), (0...23).contains(h) {
            return String(format: "%02d:00", h)
        }
        return nil
    }

    private func extractWeekdays(_ lower: String) -> [String] {
        if lower.contains("weekday") || lower.contains("werktag") || lower.contains("wochentag") {
            return ["monday", "tuesday", "wednesday", "thursday", "friday"]
        }
        if lower.contains("weekend") || lower.contains("wochenend") {
            return ["saturday", "sunday"]
        }
        if lower.contains("daily") || lower.contains("every day") || lower.contains("everyday") || lower.contains("täglich") || lower.contains("taeglich") || lower.contains("jeden tag") {
            return []
        }
        let map: [(String, String)] = [
            ("monday", "monday"), ("montag", "monday"),
            ("tuesday", "tuesday"), ("dienstag", "tuesday"),
            ("wednesday", "wednesday"), ("mittwoch", "wednesday"),
            ("thursday", "thursday"), ("donnerstag", "thursday"),
            ("friday", "friday"), ("freitag", "friday"),
            ("saturday", "saturday"), ("samstag", "saturday"),
            ("sunday", "sunday"), ("sonntag", "sunday"),
        ]
        var days: [String] = []
        for (token, canonical) in map {
            if containsWord(lower, token), !days.contains(canonical) {
                days.append(canonical)
            }
        }
        return days
    }

    private func containsWord(_ haystack: String, _ needle: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        let pattern = "(?i)(?:^|[^\\p{L}\\p{N}_])" + escaped + "(?:$|[^\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return haystack.contains(needle)
        }
        return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }
}

// MARK: - Headless Backend for Native `--mcp` Stdio Server

@MainActor
public final class HeadlessHueToolBackend: HueToolBackend {
    private let client: HueBridgeControlling
    private let settings: SettingsStore
    private var snapshot: HueSnapshot
    private var rules: [HueRule]
    private var localSchedules: [HueSchedule]
    private var customThemes: [HueLightTheme]

    public init(client: HueBridgeControlling, settings: SettingsStore = SettingsStore(), initialSnapshot: HueSnapshot) {
        self.client = client
        self.settings = settings
        self.snapshot = initialSnapshot
        self.rules = initialSnapshot.isDemo ? initialSnapshot.rules : settings.loadRules()
        self.localSchedules = initialSnapshot.isDemo ? [] : settings.loadLocalSchedules()
        self.customThemes = settings.loadCustomThemes()
        self.client.onSnapshot = { [weak self] newSnap in
            self?.snapshot = newSnap
            if newSnap.isDemo {
                self?.rules = newSnap.rules
            }
        }
    }

    public var currentSnapshot: HueSnapshot { snapshot }
    public var currentThemes: [HueLightTheme] { HueLightTheme.builtIn + customThemes }
    public var currentRules: [HueRule] { rules }
    public var currentSchedules: [HueSchedule] {
        (snapshot.schedules + localSchedules).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public var currentFloorplan: FloorplanDocument? {
        let key = snapshot.isDemo ? "demo" : (client.bridgeID.isEmpty ? (snapshot.bridge?.ip ?? "default") : client.bridgeID)
        return settings.loadFloorplan(bridgeID: key)
    }

    public func setLight(id: String, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?) {
        client.setLight(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
    }

    public func setRoom(room: HueRoom, on: Bool?, bri: Int?, mirek: Int?, xy: (Double, Double)?, effect: String?) {
        if !room.groupedLight.isEmpty {
            client.setGroup(id: room.groupedLight, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        } else {
            for light in room.lights {
                client.setLight(id: light.id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
            }
        }
    }

    public func recallScene(id: String) {
        client.recallScene(id: id)
    }

    public func applyTheme(_ theme: HueLightTheme, to light: HueLight) {
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
        client.setLight(id: light.id, on: true, bri: theme.brightness, mirek: mirek, xy: xy, effect: eff)
    }

    public func turnAllOn() {
        client.allOn(excludeRooms: Set(settings.excludedFromAllOn()))
    }

    public func turnAllOff() {
        client.allOff()
    }

    public func setSensorEnabled(sensor: HueSensor, enabled: Bool) {
        client.setSensorEnabled(kind: sensor.kind, id: sensor.id, enabled: enabled)
    }

    public func updateMotionArea(area: HueMotionArea, enabled: Bool?, sensitivity: Int?) {
        client.updateMotionArea(
            id: area.id,
            convenienceID: area.convenienceID.isEmpty ? nil : area.convenienceID,
            enabled: enabled,
            sensitivity: sensitivity
        )
    }

    public func addRule(_ rule: HueRule) {
        rules.append(rule)
        if !snapshot.isDemo { try? settings.saveRules(rules) }
        client.setRules(rules, paused: settings.rulesPaused())
    }

    public func toggleRule(id: String, enabled: Bool) -> Bool {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return false }
        rules[idx].enabled = enabled
        if !snapshot.isDemo { try? settings.saveRules(rules) }
        client.setRules(rules, paused: settings.rulesPaused())
        return true
    }

    public func deleteRule(id: String) -> Bool {
        let before = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != before else { return false }
        if !snapshot.isDemo { try? settings.saveRules(rules) }
        client.setRules(rules, paused: settings.rulesPaused())
        return true
    }

    public func createSchedule(_ draft: HueScheduleDraft) {
        if !snapshot.isDemo && settings.scheduleMode() == .local {
            let sched = HueSchedule(
                id: UUID().uuidString.lowercased(),
                name: draft.name,
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
            localSchedules.append(sched)
            try? settings.saveLocalSchedules(localSchedules)
        } else {
            client.createSchedule(draft)
        }
    }
}

// MARK: - Native Swift MCP JSON-RPC 2.0 Stdio Server

/// Pure-Foundation Model Context Protocol (MCP) JSON-RPC 2.0 stdio server (`MaprismaHueLights --mcp`).
/// Zero external packages, local-only, never exposes Hue Bridge credentials (`appKey` / `clientKey` / `fingerprint`).
@MainActor
public final class HueMCPServer {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "maprisma-hue-lights"
    public static let serverVersion = "1.0.0"
    public static let stateResourceURI = "hue://state"
    public static let maxRequestLineBytes = 512 * 1024

    private let dispatcher: HueToolDispatcher
    private let refreshHook: (() async -> Void)?

    public init(backend: HueToolBackend, refreshHook: (() async -> Void)? = nil) {
        self.dispatcher = HueToolDispatcher(backend: backend)
        self.refreshHook = refreshHook
    }

    /// Processes a single JSON-RPC 2.0 line and returns the compact JSON reply line, or `nil` for notifications.
    public func handleRequestLine(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= Self.maxRequestLineBytes else {
            return encodeError(id: .null, code: -32600, message: "Request exceeds maximum size")
        }
        guard let data = trimmed.data(using: .utf8),
              let rawObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encodeError(id: .null, code: -32700, message: "Parse error")
        }
        let message = HueJSONValue.fromFoundation(rawObj).objectValue ?? [:]
        guard let reply = await handleMessage(message) else { return nil }
        return HueJSONValue.encodeCompactString(.object(reply))
    }

    public func handleMessage(_ message: [String: HueJSONValue]) async -> [String: HueJSONValue]? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            guard let id = id else { return nil }
            return makeError(id: id, code: -32600, message: "Invalid Request: missing method")
        }
        let params = message["params"]?.objectValue ?? [:]

        switch method {
        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "initialize":
            let result: HueJSONValue = .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([
                    "tools": .object([:]),
                    "resources": .object([:]),
                ]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(Self.serverVersion),
                ]),
            ])
            return makeResult(id: id ?? .null, result: result)

        case "ping":
            return makeResult(id: id ?? .null, result: .object([:]))

        case "tools/list":
            let result: HueJSONValue = .object([
                "tools": .array(HueToolDispatcher.toolDefinitions()),
            ])
            return makeResult(id: id ?? .null, result: result)

        case "tools/call":
            guard let toolName = params["name"]?.stringValue, !toolName.isEmpty else {
                return makeError(id: id ?? .null, code: -32602, message: "Invalid params: missing tool name")
            }
            let toolArgs = params["arguments"]?.objectValue ?? [:]
            if toolName == "hue_status" || toolName == "hue_list_rooms" || toolName == "hue_list_lights" || toolName == "hue_list_sensors" {
                await refreshHook?()
            }
            let exec = dispatcher.execute(HueToolCall(name: toolName, arguments: toolArgs))
            let jsonText = HueJSONValue.encodeCompactString(exec.payload)
            let result: HueJSONValue = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(jsonText),
                    ]),
                ]),
                "isError": .bool(!exec.ok),
            ])
            return makeResult(id: id ?? .null, result: result)

        case "resources/list":
            let result: HueJSONValue = .object([
                "resources": .array([
                    .object([
                        "uri": .string(Self.stateResourceURI),
                        "name": .string("Hue Home State"),
                        "description": .string("Current sanitized Philips Hue bridge rooms, lights, scenes, sensors, and MotionAware presence."),
                        "mimeType": .string("application/json"),
                    ]),
                ]),
            ])
            return makeResult(id: id ?? .null, result: result)

        case "resources/read":
            guard let uri = params["uri"]?.stringValue else {
                return makeError(id: id ?? .null, code: -32602, message: "Invalid params: missing uri")
            }
            guard uri == Self.stateResourceURI else {
                return makeError(id: id ?? .null, code: -32002, message: "Resource not found: \(uri)")
            }
            await refreshHook?()
            let stateText = HueJSONValue.encodePrettyString(dispatcher.stateResourceJSON())
            let result: HueJSONValue = .object([
                "contents": .array([
                    .object([
                        "uri": .string(Self.stateResourceURI),
                        "mimeType": .string("application/json"),
                        "text": .string(stateText),
                    ]),
                ]),
            ])
            return makeResult(id: id ?? .null, result: result)

        default:
            guard let id = id else { return nil }
            return makeError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Runs the blocking JSON-RPC 2.0 stdio loop until stdin reaches EOF.
    /// Does not start AppKit / SwiftUI windows or steal macOS focus.
    public static func runStdio(demo: Bool = false) async {
        let settings = SettingsStore()
        let server: HueMCPServer
        let stopClient: () -> Void

        if demo {
            let demoClient = DemoBridgeClient()
            demoClient.start()
            let backend = HeadlessHueToolBackend(client: demoClient, settings: settings, initialSnapshot: demoClient.currentSnapshot())
            server = HueMCPServer(backend: backend)
            stopClient = { demoClient.stop() }
        } else {
            #if canImport(Security) && canImport(Network) && canImport(CryptoKit)
            let nativeClient = NativeHueBridgeClient(
                keychain: KeychainStore(),
                rules: settings.loadRules(),
                rulesPaused: settings.rulesPaused()
            )
            let initialSnap = await nativeClient.refreshNow()
            let backend = HeadlessHueToolBackend(client: nativeClient, settings: settings, initialSnapshot: initialSnap)
            server = HueMCPServer(backend: backend, refreshHook: {
                _ = await nativeClient.refreshNow()
            })
            stopClient = { nativeClient.stop() }
            #else
            let demoClient = DemoBridgeClient()
            demoClient.start()
            let backend = HeadlessHueToolBackend(client: demoClient, settings: settings, initialSnapshot: demoClient.currentSnapshot())
            server = HueMCPServer(backend: backend)
            stopClient = { demoClient.stop() }
            #endif
        }

        defer { stopClient() }

        for await line in Self.standardInputLines() {
            if let reply = await server.handleRequestLine(line) {
                Self.writeStandardOutputLine(reply)
            }
        }
    }

    private func makeResult(id: HueJSONValue, result: HueJSONValue) -> [String: HueJSONValue] {
        [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ]
    }

    private func makeError(id: HueJSONValue, code: Int, message: String) -> [String: HueJSONValue] {
        [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ]
    }

    private func encodeError(id: HueJSONValue, code: Int, message: String) -> String {
        HueJSONValue.encodeCompactString(.object(makeError(id: id, code: code, message: message)))
    }

    private nonisolated static func standardInputLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.maprisma.lights.mcp.stdin")
            queue.async {
                while let line = Swift.readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    private nonisolated static func writeStandardOutputLine(_ text: String) {
        if let data = (text + "\n").data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }
}
