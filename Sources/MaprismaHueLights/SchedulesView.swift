import HueCore
import SwiftUI

/// Lists Hue Bridge schedules and Mac-local schedules, with enable/disable, delete, and creation sheet.
struct SchedulesView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let schedules = store.allSchedules
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Schedules"))
                        .font(store.scaledFont(13, weight: .semibold))
                    Text(store.scheduleMode == .bridge
                         ? store.tr("New schedules run on your Hue Bridge 24/7.")
                         : store.tr("New schedules run on this Mac while the app is open."))
                        .font(store.scaledFont(10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    store.schedulePrefillTarget = nil
                    store.showNewScheduleSheet = true
                } label: {
                    Label(store.tr("New Schedule"), systemImage: "plus")
                        .font(store.scaledFont(12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if schedules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(store.tr("No schedules yet."))
                        .font(store.scaledFont(13, weight: .medium))
                    Text(store.tr("Create a schedule to turn lights or rooms on and off automatically."))
                        .font(store.scaledFont(11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(schedules) { schedule in
                            ScheduleCard(schedule: schedule)
                        }
                    }
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                }
            }
        }
        .sheet(isPresented: $store.showNewScheduleSheet) {
            NewScheduleSheet(prefill: store.schedulePrefillTarget)
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
    }
}

private struct ScheduleCard: View {
    @EnvironmentObject var store: HueStore
    let schedule: HueSchedule
    @State private var confirmDelete: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                    .fill(schedule.enabled ? store.skinAccentColor.opacity(0.16) : Color.primary.opacity(0.06))
                Image(systemName: triggerSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(schedule.enabled ? store.skinAccentColor : Color.secondary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(schedule.name)
                        .font(store.scaledFont(13, weight: .semibold))
                        .lineLimit(1)
                    Text(schedule.source == "local" ? store.tr("Mac") : store.tr("Bridge"))
                        .font(store.scaledFont(9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(schedule.source == "local" ? Color.orange : store.skinAccentColor)
                        .background(
                            Capsule().fill((schedule.source == "local" ? Color.orange : store.skinAccentColor).opacity(0.15))
                        )
                }
                Text(summaryLine)
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Toggle(schedule.name, isOn: Binding(
                get: { schedule.enabled },
                set: { store.toggleSchedule(schedule, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)

            if confirmDelete {
                HStack(spacing: 4) {
                    Button(store.tr("Delete"), role: .destructive) {
                        confirmDelete = false
                        store.deleteSchedule(schedule)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.red)
                    .controlSize(.mini)
                    Button(store.tr("Cancel")) {
                        confirmDelete = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(store.tr("Delete")) \(schedule.name)")
                .help(store.tr("Delete"))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(store.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(store.cardBorderColor, lineWidth: 1)
        )
        .opacity(schedule.enabled ? 1 : 0.72)
    }

    private var triggerSymbol: String {
        switch schedule.triggerKind {
        case "sunrise": return "sunrise.fill"
        case "sunset": return "sunset.fill"
        default: return "clock.fill"
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if !schedule.targetName.isEmpty {
            parts.append(schedule.targetName)
        }
        parts.append(triggerText)
        parts.append(daysText)
        parts.append(actionText)
        if schedule.fadeMin > 0 {
            parts.append(store.trf("{0} min fade", [String(schedule.fadeMin)]))
        }
        return parts.joined(separator: " · ")
    }

    private var triggerText: String {
        switch schedule.triggerKind {
        case "sunrise":
            return offsetLabel(base: store.tr("Sunrise"), offset: schedule.offsetMin)
        case "sunset":
            return offsetLabel(base: store.tr("Sunset"), offset: schedule.offsetMin)
        default:
            return schedule.time
        }
    }

    private func offsetLabel(base: String, offset: Int) -> String {
        if offset == 0 { return base }
        return offset > 0 ? "\(base) +\(offset)m" : "\(base) \(offset)m"
    }

    private var daysText: String {
        let set = Set(schedule.days.map { $0.lowercased() })
        if set.isEmpty || set.count == 7 { return store.tr("Daily") }
        let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday"]
        let weekend: Set<String> = ["saturday", "sunday"]
        if set == weekdays { return store.tr("Weekdays") }
        if set == weekend { return store.tr("Weekends") }
        let order = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let syms = Calendar.current.shortWeekdaySymbols // Sun..Sat
        let monFirst: [String] = syms.count == 7 ? Array(syms[1...6]) + [syms[0]] : order.map { String($0.prefix(3)).capitalized }
        return zip(order, monFirst).filter { set.contains($0.0) }.map(\.1).joined(separator: ", ")
    }

    private var actionText: String {
        if schedule.action == "off" { return store.tr("Off") }
        if schedule.action == "scene" {
            if let sceneName = store.sceneName(for: schedule.sceneID) {
                return "\(store.tr("Scene")): \(sceneName)"
            }
            return store.tr("Scene")
        }
        if let bri = schedule.bri {
            return "\(store.tr("On")) \(bri)%"
        }
        return store.tr("On")
    }
}

private struct ScheduleTargetOption: Identifiable, Hashable {
    let key: String
    let kind: String
    let targetID: String
    let label: String
    var id: String { key }
}

private struct NewScheduleSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let prefill: (kind: String, id: String)?

    @State private var name: String = ""
    @State private var selectedTargetKey: String = ""
    @State private var triggerKind: String = "time"
    @State private var hour: Int = 7
    @State private var minute: Int = 30
    @State private var offsetMin: Int = 0
    @State private var selectedDays: Set<String> = []
    @State private var action: String = "on"
    @State private var brightness: Double = 80
    @State private var fadeMin: Int = 0

    private static var allDays: [(id: String, short: String)] {
        let keys = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let syms = Calendar.current.shortWeekdaySymbols // Sun..Sat
        let labels: [String] = syms.count == 7
            ? (Array(syms[1...6]) + [syms[0]]).map { String($0.prefix(2)) }
            : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        return Array(zip(keys, labels)).map { (id: $0.0, short: $0.1) }
    }

    private var targetOptions: [ScheduleTargetOption] {
        var opts: [ScheduleTargetOption] = []
        for room in store.snapshot.rooms where !room.hueID.isEmpty {
            opts.append(ScheduleTargetOption(
                key: "room:\(room.id)",
                kind: room.kind == "zone" ? "zone" : "room",
                targetID: room.id,
                label: "\(store.l10n.roomName(room)) (\(store.tr("Room")))"
            ))
        }
        for light in store.snapshot.allLights {
            opts.append(ScheduleTargetOption(
                key: "light:\(light.id)",
                kind: "light",
                targetID: light.id,
                label: light.name
            ))
        }
        return opts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.tr("New Schedule"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
                Text(store.scheduleMode == .bridge ? store.tr("Bridge") : store.tr("Mac"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(store.skinAccentColor.opacity(0.15)))
                    .foregroundStyle(store.skinAccentColor)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Name"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField(store.tr("e.g. Morning Wake-Up"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Target"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Target"), selection: $selectedTargetKey) {
                            ForEach(targetOptions) { opt in
                                Text(opt.label).tag(opt.key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Trigger"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Trigger"), selection: $triggerKind) {
                            Text(store.tr("Fixed time")).tag("time")
                            Text(store.tr("Sunrise")).tag("sunrise")
                            Text(store.tr("Sunset")).tag("sunset")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        if triggerKind == "time" {
                            HStack(spacing: 8) {
                                Picker(store.tr("Hour"), selection: $hour) {
                                    ForEach(0..<24, id: \.self) { h in
                                        Text(String(format: "%02d", h)).tag(h)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 72)
                                Text(":")
                                Picker(store.tr("Minute"), selection: $minute) {
                                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                        Text(String(format: "%02d", m)).tag(m)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 72)
                            }
                        } else {
                            Stepper(
                                value: $offsetMin,
                                in: -60...60,
                                step: 5
                            ) {
                                Text(store.trf("Offset: {0} min", [offsetMin > 0 ? "+\(offsetMin)" : "\(offsetMin)"]))
                                    .font(store.scaledFont(12))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Repeat"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(Self.allDays, id: \.id) { day in
                                let active = selectedDays.contains(day.id)
                                Button(day.short) {
                                    if active { selectedDays.remove(day.id) }
                                    else { selectedDays.insert(day.id) }
                                }
                                .buttonStyle(ChipStyle(active: active))
                            }
                        }
                        Text(selectedDays.isEmpty ? store.tr("Runs every day") : store.tr("Runs on selected days"))
                            .font(store.scaledFont(10.5))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Action"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Action"), selection: $action) {
                            Text(store.tr("Turn on")).tag("on")
                            Text(store.tr("Turn off")).tag("off")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        if action == "on" {
                            HStack {
                                Text(store.tr("Brightness"))
                                    .font(store.scaledFont(11.5))
                                Slider(value: $brightness, in: 5...100, step: 5)
                                Text("\(Int(brightness))%")
                                    .font(store.scaledFont(11.5).monospacedDigit())
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Fade duration"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Fade duration"), selection: $fadeMin) {
                            Text(store.tr("Instant")).tag(0)
                            Text(store.trf("{0} min", ["1"])).tag(1)
                            Text(store.trf("{0} min", ["5"])).tag(5)
                            Text(store.trf("{0} min", ["10"])).tag(10)
                            Text(store.trf("{0} min", ["15"])).tag(15)
                            Text(store.trf("{0} min", ["30"])).tag(30)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.tr("Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTargetKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 360, idealWidth: 410, maxWidth: 520, minHeight: 380, idealHeight: 500, maxHeight: 680)
        .fontDesign(store.fontDesign)
        .onAppear {
            if let prefill = prefill {
                let candidate = "\(prefill.kind):\(prefill.id)"
                if targetOptions.contains(where: { $0.key == candidate }) {
                    selectedTargetKey = candidate
                }
            }
            if selectedTargetKey.isEmpty, let first = targetOptions.first {
                selectedTargetKey = first.key
            }
        }
    }

    private func save() {
        guard let opt = targetOptions.first(where: { $0.key == selectedTargetKey }) else { return }
        let timeStr = String(format: "%02d:%02d", hour, minute)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = title.isEmpty ? "\(opt.label) \(triggerKind == "time" ? timeStr : triggerKind.capitalized)" : title
        let draft = HueScheduleDraft(
            name: finalName,
            targetKind: opt.kind,
            targetID: opt.targetID,
            targetName: opt.label,
            triggerKind: triggerKind,
            time: timeStr,
            offsetMin: offsetMin,
            days: Array(selectedDays).sorted(),
            action: action,
            bri: action == "on" ? Int(brightness) : nil,
            fadeMin: fadeMin
        )
        store.createSchedule(draft)
        dismiss()
    }
}
