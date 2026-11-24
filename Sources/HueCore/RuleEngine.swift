import Foundation

/// A concrete light/room/scene command emitted by `RuleEngine`.
public struct RuleAction: Equatable, Hashable, Sendable {
    public let kind: String
    public let id: String
    public let on: Bool?
    public let bri: Int?
    public let sceneID: String?
    public let ruleID: String
    public let ruleName: String

    public init(
        kind: String,
        id: String,
        on: Bool? = nil,
        bri: Int? = nil,
        sceneID: String? = nil,
        ruleID: String,
        ruleName: String
    ) {
        self.kind = kind
        self.id = id
        self.on = on
        self.bri = bri
        self.sceneID = sceneID
        self.ruleID = ruleID
        self.ruleName = ruleName
    }
}

/// Pure-Swift automation rule engine supporting Follow/Mirror, Exclusive, Companion, and Desktop
/// (Mac wake/sleep) rules with echo suppression, per-rule cooldowns, cascade depth limiting,
/// overnight time windows, static cycle detection, and a 20-entry activity log.
public final class RuleEngine {
    public static let echoWindow: TimeInterval = 1.5
    public static let cooldownWindow: TimeInterval = 2.0
    public static let maxCascadeDepth: Int = 3
    public static let maxLogEntries: Int = 20

    public var rules: [HueRule]
    public var paused: Bool
    public private(set) var log: [HueRuleLogEntry] = []

    private struct OutgoingEcho {
        let expectedOn: Bool?
        let sentAt: Date
    }

    private let now: () -> Date
    private let calendar: Calendar
    private var outgoingRecords: [String: OutgoingEcho] = [:]
    private var ruleCooldowns: [String: Date] = [:]

    public init(
        rules: [HueRule] = [],
        paused: Bool = false,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.rules = rules
        self.paused = paused
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Echo Suppression

    public func recordOutgoing(kind: String, id: String, expectedOn: Bool? = nil) {
        outgoingRecords[Self.key(kind, id)] = OutgoingEcho(expectedOn: expectedOn, sentAt: now())
    }

    public func isEcho(kind: String, id: String, isOn: Bool? = nil) -> Bool {
        let current = now()
        guard let record = outgoingRecords[Self.key(kind, id)] else { return false }
        let elapsed = current.timeIntervalSince(record.sentAt)
        if elapsed >= Self.echoWindow || elapsed < 0 {
            outgoingRecords.removeValue(forKey: Self.key(kind, id))
            return false
        }
        if let expected = record.expectedOn, let actual = isOn, expected != actual {
            return false
        }
        return true
    }

    // MARK: - Evaluation

    /// Evaluates rules for a light or room state change (from SSE or local user toggle).
    public func evaluateChange(
        kind: String,
        id: String,
        isOn: Bool,
        bri: Double? = nil,
        snapshot: HueSnapshot,
        depth: Int = 0,
        bypassEcho: Bool = false
    ) -> [RuleAction] {
        guard !paused, depth < Self.maxCascadeDepth else { return [] }
        if !bypassEcho && isEcho(kind: kind, id: id, isOn: isOn) {
            return []
        }

        let current = now()
        var emitted: [RuleAction] = []

        for rule in rules where rule.enabled {
            guard rule.triggerKind == kind && rule.triggerID == id else { continue }
            guard Self.isWithinTimeWindow(start: rule.timeStart, end: rule.timeEnd, at: current, calendar: calendar) else {
                continue
            }
            if let last = ruleCooldowns[rule.id], current.timeIntervalSince(last) < Self.cooldownWindow {
                continue
            }

            let ruleActions = buildActions(for: rule, isOn: isOn, bri: bri, snapshot: snapshot)
            if !ruleActions.isEmpty {
                ruleCooldowns[rule.id] = current
                for action in ruleActions {
                    recordOutgoingAction(action, snapshot: snapshot)
                }
                appendLog(rule: rule, summary: Self.logMessage(rule: rule, triggerState: isOn ? "on" : "off", count: ruleActions.count), at: current)
                emitted.append(contentsOf: ruleActions)
            }
        }
        return emitted
    }

    private func recordOutgoingAction(_ action: RuleAction, snapshot: HueSnapshot) {
        if action.kind == "scene", let sceneID = action.sceneID {
            recordOutgoing(kind: "scene", id: sceneID, expectedOn: true)
            if let room = snapshot.rooms.first(where: { $0.scenes.contains(where: { $0.id == sceneID }) }) {
                recordOutgoing(kind: "room", id: room.id, expectedOn: true)
                for light in room.lights {
                    recordOutgoing(kind: "light", id: light.id, expectedOn: true)
                }
            }
            return
        }
        recordOutgoing(kind: action.kind, id: action.id, expectedOn: action.on)
        if action.kind == "room", let room = snapshot.room(action.id) {
            for light in room.lights {
                recordOutgoing(kind: "light", id: light.id, expectedOn: action.on)
            }
        }
    }

    /// Evaluates desktop rules for `"wake"` or `"sleep"`.
    public func evaluateDesktopEvent(_ event: String, snapshot: HueSnapshot) -> [RuleAction] {
        guard !paused else { return [] }
        let normalized = event.lowercased()
        guard normalized == "wake" || normalized == "sleep" else { return [] }

        let current = now()
        var emitted: [RuleAction] = []

        for rule in rules where rule.enabled {
            guard (rule.kind == "desktop" || rule.triggerKind == "desktop"),
                  rule.triggerState.lowercased() == normalized else { continue }
            guard Self.isWithinTimeWindow(start: rule.timeStart, end: rule.timeEnd, at: current, calendar: calendar) else {
                continue
            }
            if let last = ruleCooldowns[rule.id], current.timeIntervalSince(last) < Self.cooldownWindow {
                continue
            }

            var actions: [RuleAction] = []
            for target in rule.targets {
                if rule.onlyIfOff && target.action == "on" && Self.isTargetOn(target, in: snapshot) {
                    continue
                }
                if let scene = target.sceneID, !scene.isEmpty {
                    actions.append(RuleAction(kind: "scene", id: scene, sceneID: scene, ruleID: rule.id, ruleName: rule.name))
                } else {
                    let desiredOn = target.action != "off"
                    actions.append(RuleAction(
                        kind: target.kind,
                        id: target.id,
                        on: desiredOn,
                        bri: desiredOn ? target.bri : nil,
                        ruleID: rule.id,
                        ruleName: rule.name
                    ))
                }
            }

            if !actions.isEmpty {
                ruleCooldowns[rule.id] = current
                for action in actions {
                    recordOutgoingAction(action, snapshot: snapshot)
                }
                appendLog(rule: rule, summary: Self.logMessage(rule: rule, triggerState: normalized, count: actions.count), at: current)
                emitted.append(contentsOf: actions)
            }
        }
        return emitted
    }

    private func buildActions(for rule: HueRule, isOn: Bool, bri: Double?, snapshot: HueSnapshot) -> [RuleAction] {
        let stateStr = isOn ? "on" : "off"
        var actions: [RuleAction] = []

        switch rule.kind {
        case "exclusive":
            guard rule.triggerState == stateStr else { return [] }
            for target in rule.targets {
                if target.kind == rule.triggerKind && target.id == rule.triggerID { continue }
                actions.append(RuleAction(kind: target.kind, id: target.id, on: false, ruleID: rule.id, ruleName: rule.name))
            }

        case "follow", "companion":
            if rule.triggerState == stateStr {
                for target in rule.targets {
                    if target.kind == rule.triggerKind && target.id == rule.triggerID { continue }
                    if rule.onlyIfOff && target.action == "on" && Self.isTargetOn(target, in: snapshot) {
                        continue
                    }
                    if let scene = target.sceneID, !scene.isEmpty {
                        actions.append(RuleAction(kind: "scene", id: scene, sceneID: scene, ruleID: rule.id, ruleName: rule.name))
                    } else {
                        let desiredOn = target.action != "off"
                        let desiredBri: Int?
                        if desiredOn && rule.matchBri, let b = bri {
                            desiredBri = HueColorMath.clamp(Int(b.rounded()), 1, 100)
                        } else if desiredOn {
                            desiredBri = target.bri
                        } else {
                            desiredBri = nil
                        }
                        actions.append(RuleAction(
                            kind: target.kind,
                            id: target.id,
                            on: desiredOn,
                            bri: desiredBri,
                            ruleID: rule.id,
                            ruleName: rule.name
                        ))
                    }
                }
            } else if rule.mirrorOff && rule.triggerState == "on" && !isOn {
                for target in rule.targets {
                    if target.kind == rule.triggerKind && target.id == rule.triggerID { continue }
                    actions.append(RuleAction(kind: target.kind, id: target.id, on: false, ruleID: rule.id, ruleName: rule.name))
                }
            }

        default:
            break
        }
        return actions
    }

    private static func isTargetOn(_ target: HueRuleTarget, in snapshot: HueSnapshot) -> Bool {
        if target.kind == "room" {
            return snapshot.rooms.first(where: { $0.id == target.id || $0.hueID == target.id || $0.groupedLight == target.id })?.on ?? false
        }
        return snapshot.light(target.id)?.on ?? false
    }

    private func appendLog(rule: HueRule, summary: String, at date: Date) {
        let entry = HueRuleLogEntry(timestamp: date, ruleID: rule.id, ruleName: rule.name, message: summary)
        log.insert(entry, at: 0)
        if log.count > Self.maxLogEntries {
            log.removeLast(log.count - Self.maxLogEntries)
        }
    }

    private static func logMessage(rule: HueRule, triggerState: String, count: Int) -> String {
        let label = rule.name.isEmpty ? rule.kind.capitalized : rule.name
        return "\(label) (\(triggerState) → \(count))"
    }

    private static func key(_ kind: String, _ id: String) -> String {
        "\(kind):\(id)"
    }

    // MARK: - Time Window

    /// Checks if `date` falls within `[start, end]` (`"HH:MM"`). Supports overnight windows (e.g. `"22:00"` to `"06:00"`).
    public static func isWithinTimeWindow(
        start: String,
        end: String,
        at date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard !start.isEmpty, !end.isEmpty,
              let startMin = parseMinutes(start),
              let endMin = parseMinutes(end) else {
            return true
        }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMin <= endMin {
            return nowMin >= startMin && nowMin <= endMin
        }
        // Overnight window (e.g. 22:00 -> 06:00)
        return nowMin >= startMin || nowMin <= endMin
    }

    private static func parseMinutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    // MARK: - Static Cycle Detection

    /// Detects directed dependency cycles across enabled light/room rules.
    /// Each returned cycle is a list of node keys `"kind:id"`.
    public static func detectCycles(_ rules: [HueRule]) -> [[String]] {
        var adjacency: [String: [String]] = [:]
        var nodes = Set<String>()

        for rule in rules where rule.enabled {
            guard rule.kind != "desktop" && rule.triggerKind != "desktop",
                  !rule.triggerID.isEmpty else { continue }
            let src = key(rule.triggerKind, rule.triggerID)
            nodes.insert(src)
            for target in rule.targets where !target.id.isEmpty {
                let dst = key(target.kind, target.id)
                nodes.insert(dst)
                adjacency[src, default: []].append(dst)
            }
        }

        // 0 = unvisited, 1 = visiting (on stack), 2 = done
        var color: [String: Int] = [:]
        var stack: [String] = []
        var cycles: [[String]] = []
        var seenSignatures = Set<String>()

        func dfs(_ u: String) {
            color[u] = 1
            stack.append(u)
            for v in adjacency[u] ?? [] {
                let state = color[v] ?? 0
                if state == 1 {
                    if let idx = stack.firstIndex(of: v) {
                        let cycle = Array(stack[idx...]) + [v]
                        let sig = cycle.dropLast().sorted().joined(separator: "|")
                        if seenSignatures.insert(sig).inserted {
                            cycles.append(cycle)
                        }
                    }
                } else if state == 0 {
                    dfs(v)
                }
            }
            stack.removeLast()
            color[u] = 2
        }

        for node in nodes.sorted() {
            if (color[node] ?? 0) == 0 {
                dfs(node)
            }
        }
        return cycles
    }
}
