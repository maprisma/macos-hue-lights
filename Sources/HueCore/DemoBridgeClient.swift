import Foundation

/// Fully interactive, in-memory Philips Hue home for Apple App Store Review (Guideline 2.1)
/// and hardware-free user trials. Supports lights, brightness, warmth/color/effects, scenes,
/// All On/Off (with exclusions), bridge schedules, and live dependency rule execution.
@MainActor
public final class DemoBridgeClient: HueBridgeControlling {
    public static let livingRoomID = "10000000-0000-0000-0000-000000000001"
    public static let livingGroupID = "20000000-0000-0000-0000-000000000001"
    public static let officeRoomID = "10000000-0000-0000-0000-000000000002"
    public static let officeGroupID = "20000000-0000-0000-0000-000000000002"
    public static let bedroomRoomID = "10000000-0000-0000-0000-000000000003"
    public static let bedroomGroupID = "20000000-0000-0000-0000-000000000003"
    public static let hallwayRoomID = "10000000-0000-0000-0000-000000000004"
    public static let hallwayGroupID = "20000000-0000-0000-0000-000000000004"

    public static let deskLampID = "30000000-0000-0000-0000-000000000004"
    public static let monitorBacklightID = "30000000-0000-0000-0000-000000000005"

    public var onSnapshot: ((HueSnapshot) -> Void)?

    private struct MutableLight {
        var id: String
        var name: String
        var on: Bool
        var bri: Double
        var dimmable: Bool
        var color: String
        var reachable: Bool
        var supportsColor: Bool
        var supportsCT: Bool
        var mirek: Int?
        var mirekMin: Int
        var mirekMax: Int
        var effect: String
        var availableEffects: [String]

        func toModel() -> HueLight {
            HueLight(
                id: id, name: name, on: on, bri: bri, dimmable: dimmable, color: color,
                reachable: reachable, supportsColor: supportsColor, supportsCT: supportsCT,
                mirek: mirek, mirekMin: mirekMin, mirekMax: mirekMax, effect: effect,
                availableEffects: availableEffects
            )
        }
    }

    private struct MutableScene {
        var id: String
        var name: String
        var active: Bool
        var color: String
        var bri: Double
    }

    private struct MutableRoom {
        var id: String
        var kind: String
        var name: String
        var groupedLight: String
        var archetype: String
        var lights: [MutableLight]
        var scenes: [MutableScene]
    }

    private var rooms: [MutableRoom]
    private var schedules: [HueSchedule]
    private let ruleEngine: RuleEngine

    public init(now: @escaping () -> Date = Date.init) {
        self.rooms = [
            MutableRoom(
                id: Self.livingRoomID,
                kind: "room",
                name: "Living Room",
                groupedLight: Self.livingGroupID,
                archetype: "living_room",
                lights: [
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000001",
                        name: "Ceiling Pendant",
                        on: true, bri: 80, dimmable: true,
                        color: HueColorMath.mirekToHex(320), reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 320, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["candle", "fire", "prism", "sparkle"]
                    ),
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000002",
                        name: "Floor Lamp",
                        on: true, bri: 55, dimmable: true,
                        color: "#ffaa44", reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 400, mirekMin: 153, mirekMax: 500,
                        effect: "candle", availableEffects: ["candle", "fire", "opal", "glisten"]
                    ),
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000003",
                        name: "TV Play Bars",
                        on: false, bri: 40, dimmable: true,
                        color: "#6677ff", reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 250, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["prism", "sparkle", "underwater"]
                    ),
                ],
                scenes: [
                    MutableScene(id: "40000000-0000-0000-0000-000000000001", name: "Relax", active: true, color: "#ffd27a", bri: 60),
                    MutableScene(id: "40000000-0000-0000-0000-000000000002", name: "Concentrate", active: false, color: "#eef6ff", bri: 95),
                    MutableScene(id: "40000000-0000-0000-0000-000000000003", name: "Sunset", active: false, color: "#ff7a45", bri: 50),
                ]
            ),
            MutableRoom(
                id: Self.officeRoomID,
                kind: "room",
                name: "Office",
                groupedLight: Self.officeGroupID,
                archetype: "office",
                lights: [
                    MutableLight(
                        id: Self.deskLampID,
                        name: "Desk Lamp",
                        on: true, bri: 90, dimmable: true,
                        color: HueColorMath.mirekToHex(250), reachable: true,
                        supportsColor: false, supportsCT: true, mirek: 250, mirekMin: 153, mirekMax: 454,
                        effect: "no_effect", availableEffects: []
                    ),
                    MutableLight(
                        id: Self.monitorBacklightID,
                        name: "Monitor Backlight",
                        on: true, bri: 65, dimmable: true,
                        color: "#66ccff", reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 220, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["prism", "opal"]
                    ),
                ],
                scenes: [
                    MutableScene(id: "40000000-0000-0000-0000-000000000004", name: "Focus", active: true, color: "#eaf4ff", bri: 90),
                    MutableScene(id: "40000000-0000-0000-0000-000000000005", name: "Energize", active: false, color: "#d8ecff", bri: 100),
                ]
            ),
            MutableRoom(
                id: Self.bedroomRoomID,
                kind: "room",
                name: "Bedroom",
                groupedLight: Self.bedroomGroupID,
                archetype: "bedroom",
                lights: [
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000006",
                        name: "Bedside Left",
                        on: false, bri: 30, dimmable: true,
                        color: HueColorMath.mirekToHex(420), reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 420, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["candle", "fire"]
                    ),
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000007",
                        name: "Bedside Right",
                        on: false, bri: 30, dimmable: true,
                        color: HueColorMath.mirekToHex(420), reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 420, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["candle", "fire"]
                    ),
                ],
                scenes: [
                    MutableScene(id: "40000000-0000-0000-0000-000000000006", name: "Nightlight", active: false, color: "#ff9d42", bri: 15),
                    MutableScene(id: "40000000-0000-0000-0000-000000000007", name: "Warm Glow", active: false, color: "#ffc978", bri: 45),
                ]
            ),
            MutableRoom(
                id: Self.hallwayRoomID,
                kind: "room",
                name: "Hallway",
                groupedLight: Self.hallwayGroupID,
                archetype: "hallway",
                lights: [
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000008",
                        name: "Entryway Spot",
                        on: false, bri: 70, dimmable: true,
                        color: HueColorMath.mirekToHex(300), reachable: true,
                        supportsColor: false, supportsCT: true, mirek: 300, mirekMin: 153, mirekMax: 454,
                        effect: "no_effect", availableEffects: []
                    ),
                    MutableLight(
                        id: "30000000-0000-0000-0000-000000000009",
                        name: "Staircase Strip",
                        on: false, bri: 45, dimmable: true,
                        color: "#ffd27a", reachable: true,
                        supportsColor: true, supportsCT: true, mirek: 350, mirekMin: 153, mirekMax: 500,
                        effect: "no_effect", availableEffects: ["sparkle"]
                    ),
                ],
                scenes: [
                    MutableScene(id: "40000000-0000-0000-0000-000000000008", name: "Welcome Home", active: false, color: "#ffe0a3", bri: 75),
                ]
            ),
        ]

        self.schedules = [
            HueSchedule(
                id: "50000000-0000-0000-0000-000000000001",
                name: "Morning Wake-Up",
                enabled: true,
                targetKind: "room",
                targetID: Self.officeRoomID,
                targetName: "Office",
                triggerKind: "time",
                time: "07:30",
                offsetMin: 0,
                days: ["monday", "tuesday", "wednesday", "thursday", "friday"],
                action: "on",
                bri: 80,
                sceneID: "",
                fadeMin: 10,
                source: "bridge"
            ),
            HueSchedule(
                id: "50000000-0000-0000-0000-000000000002",
                name: "Evening Wind-Down",
                enabled: true,
                targetKind: "room",
                targetID: Self.livingRoomID,
                targetName: "Living Room",
                triggerKind: "sunset",
                time: "20:00",
                offsetMin: 30,
                days: [],
                action: "off",
                bri: nil,
                sceneID: "",
                fadeMin: 5,
                source: "bridge"
            ),
        ]

        let defaultRules: [HueRule] = [
            HueRule(
                id: "60000000-0000-0000-0000-000000000001",
                name: "Desk syncs Monitor Backlight",
                enabled: true,
                kind: "follow",
                triggerKind: "light",
                triggerID: Self.deskLampID,
                triggerState: "on",
                targets: [HueRuleTarget(kind: "light", id: Self.monitorBacklightID, action: "on")],
                mirrorOff: true,
                matchBri: true
            ),
            HueRule(
                id: "60000000-0000-0000-0000-000000000002",
                name: "Mac Sleep turns off Office",
                enabled: true,
                kind: "desktop",
                triggerKind: "desktop",
                triggerID: "desktop",
                triggerState: "sleep",
                targets: [HueRuleTarget(kind: "room", id: Self.officeRoomID, action: "off")]
            ),
        ]
        self.ruleEngine = RuleEngine(rules: defaultRules, paused: false, now: now)
    }

    /// The built-in demo rules so `HueStore` can display them immediately when entering Demo Mode.
    public var currentRules: [HueRule] { ruleEngine.rules }

    public func currentSnapshot() -> HueSnapshot {
        buildSnapshot()
    }

    public func start() {
        emit()
    }

    public func stop() {}
    public func setPanelOpen(_ open: Bool) {}
    public func refresh() { emit() }
    public func discover() { emit() }
    public func pair(ip: String) { emit() }
    public func cancelPair() { emit() }
    public func unpair() { emit() }

    public func setLight(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        var newOn: Bool? = nil
        var newBri: Double? = nil
        mutateLight(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect, resultOn: &newOn, resultBri: &newBri)
        if let finalOn = newOn {
            let snap = buildSnapshot()
            let actions = ruleEngine.evaluateChange(
                kind: "light", id: id, isOn: finalOn, bri: newBri, snapshot: snap, depth: 0, bypassEcho: true
            )
            executeRuleActions(actions, depth: 1)
        }
        emit()
    }

    public func setGroup(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        guard let idx = rooms.firstIndex(where: { $0.groupedLight == id || $0.id == id }) else { return }
        let roomID = rooms[idx].id
        for i in rooms[idx].lights.indices {
            if let on = on { rooms[idx].lights[i].on = on }
            if let bri = bri {
                rooms[idx].lights[i].bri = Double(HueColorMath.clamp(bri, 1, 100))
                rooms[idx].lights[i].on = true
            }
            if let mirek = mirek, rooms[idx].lights[i].supportsCT {
                let m = HueColorMath.clamp(mirek, rooms[idx].lights[i].mirekMin, rooms[idx].lights[i].mirekMax)
                rooms[idx].lights[i].mirek = m
                rooms[idx].lights[i].color = HueColorMath.mirekToHex(m)
                rooms[idx].lights[i].on = true
            }
            if let xy = xy, rooms[idx].lights[i].supportsColor {
                rooms[idx].lights[i].color = HueColorMath.xyToHex(x: xy.0, y: xy.1)
                rooms[idx].lights[i].on = true
            }
            if let effect = effect {
                rooms[idx].lights[i].effect = effect
                if effect != "no_effect" { rooms[idx].lights[i].on = true }
            }
        }
        if on == false {
            for sIdx in rooms[idx].scenes.indices { rooms[idx].scenes[sIdx].active = false }
        }
        let roomNowOn = rooms[idx].lights.contains(where: \.on)
        let onLights = rooms[idx].lights.filter(\.on)
        let avgBri = onLights.isEmpty ? nil : onLights.map(\.bri).reduce(0, +) / Double(onLights.count)
        let snap = buildSnapshot()
        let actions = ruleEngine.evaluateChange(
            kind: "room", id: roomID, isOn: roomNowOn, bri: avgBri, snapshot: snap, depth: 0, bypassEcho: true
        )
        executeRuleActions(actions, depth: 1)
        emit()
    }

    public func recallScene(id: String) {
        for rIdx in rooms.indices {
            if let sIdx = rooms[rIdx].scenes.firstIndex(where: { $0.id == id }) {
                for j in rooms[rIdx].scenes.indices {
                    rooms[rIdx].scenes[j].active = (j == sIdx)
                }
                let scene = rooms[rIdx].scenes[sIdx]
                for lIdx in rooms[rIdx].lights.indices {
                    rooms[rIdx].lights[lIdx].on = true
                    rooms[rIdx].lights[lIdx].bri = scene.bri
                    rooms[rIdx].lights[lIdx].color = scene.color
                    rooms[rIdx].lights[lIdx].effect = "no_effect"
                }
                break
            }
        }
        emit()
    }

    public func allOn(excludeRooms: Set<String>) {
        for rIdx in rooms.indices {
            if excludeRooms.contains(rooms[rIdx].id) { continue }
            for lIdx in rooms[rIdx].lights.indices {
                rooms[rIdx].lights[lIdx].on = true
            }
        }
        emit()
    }

    public func allOff() {
        for rIdx in rooms.indices {
            for lIdx in rooms[rIdx].lights.indices {
                rooms[rIdx].lights[lIdx].on = false
            }
            for sIdx in rooms[rIdx].scenes.indices {
                rooms[rIdx].scenes[sIdx].active = false
            }
        }
        emit()
    }

    public func createSchedule(_ draft: HueScheduleDraft) {
        let schedule = HueSchedule(
            id: UUID().uuidString.lowercased(),
            name: HueColorMath.clean(draft.name).isEmpty ? "Schedule" : HueColorMath.clean(draft.name),
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
            source: "bridge"
        )
        schedules.append(schedule)
        schedules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        emit()
    }

    public func toggleSchedule(id: String, enabled: Bool) {
        if let idx = schedules.firstIndex(where: { $0.id == id }) {
            schedules[idx].enabled = enabled
            emit()
        }
    }

    public func deleteSchedule(id: String) {
        schedules.removeAll { $0.id == id }
        emit()
    }

    public func setRules(_ rules: [HueRule], paused: Bool) {
        ruleEngine.rules = rules
        ruleEngine.paused = paused
        emit()
    }

    public func triggerDesktopEvent(_ event: String) {
        let snap = buildSnapshot()
        let actions = ruleEngine.evaluateDesktopEvent(event, snapshot: snap)
        executeRuleActions(actions, depth: 1)
        emit()
    }

    public var entertainmentCredentials: BridgeCredentials? { nil }

    public func setEntertainmentActive(areaID: String, active: Bool) async -> Bool {
        false
    }

    // MARK: - Helpers

    private func mutateLight(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?,
        resultOn: inout Bool?,
        resultBri: inout Double?
    ) {
        for rIdx in rooms.indices {
            if let lIdx = rooms[rIdx].lights.firstIndex(where: { $0.id == id }) {
                if let on = on { rooms[rIdx].lights[lIdx].on = on }
                if let bri = bri {
                    rooms[rIdx].lights[lIdx].bri = Double(HueColorMath.clamp(bri, 1, 100))
                    rooms[rIdx].lights[lIdx].on = true
                }
                if let mirek = mirek, rooms[rIdx].lights[lIdx].supportsCT {
                    let m = HueColorMath.clamp(mirek, rooms[rIdx].lights[lIdx].mirekMin, rooms[rIdx].lights[lIdx].mirekMax)
                    rooms[rIdx].lights[lIdx].mirek = m
                    rooms[rIdx].lights[lIdx].color = HueColorMath.mirekToHex(m)
                    rooms[rIdx].lights[lIdx].on = true
                }
                if let xy = xy, rooms[rIdx].lights[lIdx].supportsColor {
                    rooms[rIdx].lights[lIdx].color = HueColorMath.xyToHex(x: xy.0, y: xy.1)
                    rooms[rIdx].lights[lIdx].on = true
                }
                if let effect = effect {
                    rooms[rIdx].lights[lIdx].effect = effect
                    if effect != "no_effect" { rooms[rIdx].lights[lIdx].on = true }
                }
                resultOn = rooms[rIdx].lights[lIdx].on
                resultBri = rooms[rIdx].lights[lIdx].bri
                return
            }
        }
    }

    private func executeRuleActions(_ actions: [RuleAction], depth: Int) {
        guard depth <= RuleEngine.maxCascadeDepth else { return }
        for action in actions {
            if let sceneID = action.sceneID, !sceneID.isEmpty {
                recallScene(id: sceneID)
            } else if action.kind == "room" {
                if let idx = rooms.firstIndex(where: { $0.id == action.id || $0.groupedLight == action.id }) {
                    for lIdx in rooms[idx].lights.indices {
                        if let on = action.on { rooms[idx].lights[lIdx].on = on }
                        if let bri = action.bri {
                            rooms[idx].lights[lIdx].bri = Double(HueColorMath.clamp(bri, 1, 100))
                            rooms[idx].lights[lIdx].on = true
                        }
                    }
                }
            } else if action.kind == "light" {
                var rOn: Bool? = nil
                var rBri: Double? = nil
                mutateLight(id: action.id, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil, resultOn: &rOn, resultBri: &rBri)
            }
        }
    }

    private func buildSnapshot() -> HueSnapshot {
        var builtRooms: [HueRoom] = []
        var totalLights = 0
        var totalOn = 0
        for r in rooms {
            let lights = r.lights.map { $0.toModel() }
            let onLights = lights.filter(\.on)
            totalLights += lights.count
            totalOn += onLights.count
            let avgBri = onLights.isEmpty ? 0.0
                : ((onLights.map(\.bri).reduce(0.0, +) / Double(onLights.count)) * 10.0).rounded() / 10.0
            let scenes = r.scenes.map { HueScene(id: $0.id, name: $0.name, active: $0.active) }
            builtRooms.append(HueRoom(
                hueID: r.id,
                kind: r.kind,
                name: r.name,
                groupedLight: r.groupedLight,
                on: !onLights.isEmpty,
                bri: avgBri,
                onCount: onLights.count,
                archetype: r.archetype,
                color: HueColorMath.blendColors(onLights.map(\.color)),
                lights: lights,
                scenes: scenes
            ))
        }
        return HueSnapshot(
            phase: "ok",
            error: "",
            errorCode: "",
            errorArgs: [],
            bridge: BridgeInfo(ip: "Demo Mode", name: "Demo Hue Bridge", model: "BSB002"),
            rooms: builtRooms,
            lightCount: totalLights,
            onCount: totalOn,
            candidates: [],
            discovering: false,
            pairIP: "",
            pairRemaining: 0,
            bridgeHomeGroupedLight: "20000000-0000-0000-0000-000000000000",
            schedules: schedules,
            rules: ruleEngine.rules,
            rulesPaused: ruleEngine.paused,
            ruleLog: ruleEngine.log,
            entertainmentAreas: [
                HueEntertainmentArea(
                    id: "70000000-0000-0000-0000-000000000001",
                    name: "Living Room Entertainment",
                    channels: [
                        HueEntertainmentChannel(channelID: 0, lightIDs: ["30000000-0000-0000-0000-000000000001"]),
                        HueEntertainmentChannel(channelID: 1, lightIDs: ["30000000-0000-0000-0000-000000000002"]),
                        HueEntertainmentChannel(channelID: 2, lightIDs: ["30000000-0000-0000-0000-000000000003"]),
                    ]
                ),
            ],
            isDemo: true
        )
    }

    private func emit() {
        onSnapshot?(buildSnapshot())
    }
}
