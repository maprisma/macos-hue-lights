import Foundation

/// Action produced when a Mac-local schedule (`source == "local"`) becomes due.
public struct LocalScheduleAction: Equatable, Sendable {
    public let scheduleID: String
    public let scheduleName: String
    public let targetKind: String
    public let targetID: String
    public let action: String
    public let bri: Int?
    public let sceneID: String

    public init(
        scheduleID: String,
        scheduleName: String,
        targetKind: String,
        targetID: String,
        action: String,
        bri: Int? = nil,
        sceneID: String = ""
    ) {
        self.scheduleID = scheduleID
        self.scheduleName = scheduleName
        self.targetKind = targetKind
        self.targetID = targetID
        self.action = action
        self.bri = bri
        self.sceneID = sceneID
    }
}

/// Evaluates Mac-local schedules (`schedule.source == "local"`) on a periodic tick (e.g. every 30 s)
/// while Maprisma Hue Lights is running in the menu bar. Deduplicates by minute bucket so each
/// schedule fires at most once per scheduled minute.
public final class LocalScheduler {
    private let calendar: Calendar
    private var lastFiredBucket: [String: String] = [:]

    /// Fallback sunrise/sunset minutes when running locally without Location Services (privacy-first).
    public var defaultSunriseMinute: Int
    public var defaultSunsetMinute: Int

    public init(
        calendar: Calendar = .current,
        defaultSunriseMinute: Int = 6 * 60 + 30,
        defaultSunsetMinute: Int = 19 * 60 + 30
    ) {
        self.calendar = calendar
        self.defaultSunriseMinute = defaultSunriseMinute
        self.defaultSunsetMinute = defaultSunsetMinute
    }

    public func dueActions(for schedules: [HueSchedule], at date: Date = Date()) -> [LocalScheduleAction] {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let hour = comps.hour, let minute = comps.minute, let weekday = comps.weekday else {
            return []
        }
        let nowMinutes = hour * 60 + minute
        let bucket = String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
        let dayName = Self.weekdayName(for: weekday)

        var actions: [LocalScheduleAction] = []
        for schedule in schedules where schedule.enabled && schedule.source == "local" {
            if !schedule.days.isEmpty {
                let lowered = schedule.days.map { $0.lowercased() }
                guard lowered.contains(dayName) else { continue }
            }

            let targetMinutes: Int
            switch schedule.triggerKind {
            case "sunrise":
                targetMinutes = Self.wrapMinutes(defaultSunriseMinute + schedule.offsetMin)
            case "sunset":
                targetMinutes = Self.wrapMinutes(defaultSunsetMinute + schedule.offsetMin)
            default:
                guard let parsed = Self.parseMinutes(schedule.time) else { continue }
                targetMinutes = parsed
            }

            guard targetMinutes == nowMinutes else { continue }
            if lastFiredBucket[schedule.id] == bucket { continue }
            lastFiredBucket[schedule.id] = bucket

            actions.append(LocalScheduleAction(
                scheduleID: schedule.id,
                scheduleName: schedule.name,
                targetKind: schedule.targetKind,
                targetID: schedule.targetID,
                action: schedule.action,
                bri: schedule.action == "on" ? schedule.bri : nil,
                sceneID: schedule.sceneID
            ))
        }
        return actions
    }

    public func resetHistory() {
        lastFiredBucket.removeAll()
    }

    private static func parseMinutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    private static func wrapMinutes(_ minutes: Int) -> Int {
        let mod = minutes % 1440
        return mod < 0 ? mod + 1440 : mod
    }

    private static func weekdayName(for calendarWeekday: Int) -> String {
        switch calendarWeekday {
        case 1: return "sunday"
        case 2: return "monday"
        case 3: return "tuesday"
        case 4: return "wednesday"
        case 5: return "thursday"
        case 6: return "friday"
        case 7: return "saturday"
        default: return ""
        }
    }
}
