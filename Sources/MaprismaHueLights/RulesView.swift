import HueCore
import SwiftUI

/// Dependency & linked-light rules (Follow/Mirror, Exclusive, Companion, Mac Wake/Sleep)
/// with global pause switch, cycle warning, sentence cards, and expandable activity log.
struct RulesView: View {
    @EnvironmentObject var store: HueStore
    @State private var showActivityLog = false

    private var cycles: [[String]] {
        RuleEngine.detectCycles(store.rules)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { store.rulesPaused },
                    set: { store.setRulesPaused($0) }
                )) {
                    Text(store.tr("Pause all rules"))
                        .font(store.scaledFont(12, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button {
                    store.rulePrefillTrigger = nil
                    store.showNewRuleSheet = true
                } label: {
                    Label(store.tr("New Rule"), systemImage: "plus")
                        .font(store.scaledFont(12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if !cycles.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(store.tr("Cycle detected between enabled rules. Echo suppression and depth limits will prevent loops, but consider simplifying."))
                        .font(store.scaledFont(11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            if store.rules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "link")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(store.tr("No rules yet."))
                        .font(store.scaledFont(13, weight: .medium))
                    Text(store.tr("Link lights together or react automatically when your Mac wakes or sleeps."))
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
                        ForEach(store.rules) { rule in
                            RuleCard(rule: rule)
                        }

                        if !store.snapshot.ruleLog.isEmpty {
                            DisclosureGroup(
                                isExpanded: $showActivityLog,
                                content: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(store.snapshot.ruleLog) { entry in
                                            HStack(spacing: 6) {
                                                Text(Self.timeFormatter.string(from: entry.timestamp))
                                                    .font(store.scaledFont(10.5).monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                Text(entry.message)
                                                    .font(store.scaledFont(11))
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                        }
                                    }
                                    .padding(.top, 6)
                                },
                                label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "list.bullet.rectangle")
                                            .font(.caption)
                                        Text(store.trf("Recent activity ({0})", [String(store.snapshot.ruleLog.count)]))
                                            .font(store.scaledFont(11.5, weight: .semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            )
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .sheet(isPresented: $store.showNewRuleSheet) {
            NewRuleSheet(prefill: store.rulePrefillTrigger)
                .environmentObject(store)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct RuleCard: View {
    @EnvironmentObject var store: HueStore
    let rule: HueRule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                    .fill(activeTint.opacity(0.15))
                Image(systemName: kindSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activeTint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? kindLabel : rule.name)
                        .font(store.scaledFont(12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(kindLabel)
                        .font(store.scaledFont(9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .foregroundStyle(activeTint)
                        .background(Capsule().fill(activeTint.opacity(0.14)))
                }

                Text(sentenceSummary)
                    .font(store.scaledFont(11.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !optionTags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(optionTags, id: \.self) { tag in
                            Text(tag)
                                .font(store.scaledFont(9.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(.secondary)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { store.toggleRule(rule, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)

            Button(role: .destructive) {
                store.deleteRule(rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(store.tr("Delete"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .opacity(rule.enabled && !store.rulesPaused ? 1 : 0.65)
    }

    private var activeTint: Color {
        guard rule.enabled && !store.rulesPaused else { return .secondary }
        switch rule.kind {
        case "exclusive": return .orange
        case "desktop": return .purple
        case "companion": return .teal
        default: return .accentColor
        }
    }

    private var kindSymbol: String {
        switch rule.kind {
        case "exclusive": return "arrow.left.arrow.right"
        case "desktop": return "laptopcomputer"
        case "companion": return "sparkles"
        default: return "link"
        }
    }

    private var kindLabel: String {
        switch rule.kind {
        case "exclusive": return store.tr("Exclusive")
        case "desktop": return store.tr("Mac")
        case "companion": return store.tr("Companion")
        default: return store.tr("Follow")
        }
    }

    private var sentenceSummary: String {
        let targetNames = rule.targets.map { target -> String in
            let name = store.nameForTarget(kind: target.kind, id: target.id)
            let act = target.action == "off" ? store.tr("Turn off") : store.tr("Turn on")
            return "\(act) \(name)"
        }.joined(separator: ", ")

        if rule.kind == "desktop" || rule.triggerKind == "desktop" {
            let trig = rule.triggerState == "sleep" ? store.tr("Mac sleeps") : store.tr("Mac wakes")
            return store.trf("When {0} → {1}", [trig, targetNames])
        }
        let trigName = store.nameForTarget(kind: rule.triggerKind, id: rule.triggerID)
        let trigState = rule.triggerState == "off" ? store.tr("turns off") : store.tr("turns on")
        return store.trf("When {0} {1} → {2}", [trigName, trigState, targetNames])
    }

    private var optionTags: [String] {
        var tags: [String] = []
        if rule.mirrorOff { tags.append(store.tr("Mirror off")) }
        if rule.matchBri { tags.append(store.tr("Match brightness")) }
        if rule.onlyIfOff { tags.append(store.tr("Only if off")) }
        if !rule.timeStart.isEmpty && !rule.timeEnd.isEmpty {
            tags.append("\(rule.timeStart)–\(rule.timeEnd)")
        }
        return tags
    }
}

private struct RuleEntityOption: Identifiable, Hashable {
    let key: String
    let kind: String
    let entityID: String
    let label: String
    var id: String { key }
}

private struct NewRuleSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let prefill: (kind: String, id: String)?

    @State private var name: String = ""
    @State private var ruleKind: String = "follow"
    @State private var triggerKey: String = ""
    @State private var triggerState: String = "on"
    @State private var desktopEvent: String = "wake"
    @State private var targetKey: String = ""
    @State private var targetAction: String = "on"
    @State private var mirrorOff: Bool = true
    @State private var matchBri: Bool = false
    @State private var onlyIfOff: Bool = false
    @State private var useTimeWindow: Bool = false
    @State private var timeStart: String = "22:00"
    @State private var timeEnd: String = "06:00"

    private var entityOptions: [RuleEntityOption] {
        var opts: [RuleEntityOption] = []
        for light in store.snapshot.allLights {
            opts.append(RuleEntityOption(key: "light:\(light.id)", kind: "light", entityID: light.id, label: light.name))
        }
        for room in store.snapshot.rooms where !room.hueID.isEmpty {
            opts.append(RuleEntityOption(
                key: "room:\(room.id)",
                kind: "room",
                entityID: room.id,
                label: "\(store.l10n.roomName(room)) (\(store.tr("Room")))"
            ))
        }
        return opts
    }

    private var targetOptions: [RuleEntityOption] {
        if ruleKind == "desktop" { return entityOptions }
        return entityOptions.filter { $0.key != triggerKey }
    }

    private var wouldCreateCycle: Bool {
        guard let draft = buildRule() else { return false }
        return !RuleEngine.detectCycles(store.rules + [draft]).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.tr("New Rule"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Name"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField(store.tr("e.g. Desk syncs Backlight"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Rule type"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Rule type"), selection: $ruleKind) {
                            Text(store.tr("Follow / Mirror")).tag("follow")
                            Text(store.tr("Exclusive")).tag("exclusive")
                            Text(store.tr("Companion")).tag("companion")
                            Text(store.tr("Mac Wake / Sleep")).tag("desktop")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("When"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if ruleKind == "desktop" {
                            Picker(store.tr("Event"), selection: $desktopEvent) {
                                Text(store.tr("Mac wakes")).tag("wake")
                                Text(store.tr("Mac sleeps")).tag("sleep")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        } else {
                            Picker(store.tr("Trigger"), selection: $triggerKey) {
                                ForEach(entityOptions) { opt in
                                    Text(opt.label).tag(opt.key)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)

                            if ruleKind != "exclusive" {
                                Picker(store.tr("State"), selection: $triggerState) {
                                    Text(store.tr("Turns on")).tag("on")
                                    Text(store.tr("Turns off")).tag("off")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Then"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(store.tr("Target"), selection: $targetKey) {
                            ForEach(targetOptions) { opt in
                                Text(opt.label).tag(opt.key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        if ruleKind != "exclusive" {
                            Picker(store.tr("Action"), selection: $targetAction) {
                                Text(store.tr("Turn on")).tag("on")
                                Text(store.tr("Turn off")).tag("off")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        } else {
                            Text(store.tr("Automatically turns target off when trigger turns on."))
                                .font(store.scaledFont(11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if ruleKind == "follow" || ruleKind == "companion" {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(store.tr("Mirror off"), isOn: $mirrorOff)
                            Toggle(store.tr("Match brightness"), isOn: $matchBri)
                            Toggle(store.tr("Only if target is off"), isOn: $onlyIfOff)
                        }
                        .font(store.scaledFont(12))
                    } else if ruleKind == "desktop" {
                        Toggle(store.tr("Only if target is off"), isOn: $onlyIfOff)
                            .font(store.scaledFont(12))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(store.tr("Active only during time window"), isOn: $useTimeWindow)
                            .font(store.scaledFont(12))
                        if useTimeWindow {
                            HStack(spacing: 8) {
                                TextField("22:00", text: $timeStart)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Text("–")
                                TextField("06:00", text: $timeEnd)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                        }
                    }

                    if wouldCreateCycle {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                            Text(store.tr("This rule creates a cycle with existing rules."))
                                .font(store.scaledFont(11))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.tr("Save")) {
                    if let rule = buildRule() {
                        store.addRule(rule)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(buildRule() == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 410, height: 530)
        .fontDesign(store.fontDesign)
        .onAppear {
            if let prefill = prefill {
                let key = "\(prefill.kind):\(prefill.id)"
                if entityOptions.contains(where: { $0.key == key }) {
                    triggerKey = key
                }
            }
            if triggerKey.isEmpty, let first = entityOptions.first {
                triggerKey = first.key
            }
            if targetKey.isEmpty, let firstTarget = targetOptions.first {
                targetKey = firstTarget.key
            }
        }
        .onChange(of: triggerKey) { _ in
            if targetKey == triggerKey || targetKey.isEmpty {
                targetKey = targetOptions.first?.key ?? ""
            }
        }
    }

    private func buildRule() -> HueRule? {
        guard let targetOpt = targetOptions.first(where: { $0.key == targetKey }) else { return nil }
        let finalAction = ruleKind == "exclusive" ? "off" : targetAction
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if ruleKind == "desktop" {
            let finalName = title.isEmpty ? "\(desktopEvent == "sleep" ? store.tr("Mac sleeps") : store.tr("Mac wakes")) → \(targetOpt.label)" : title
            return HueRule(
                name: finalName,
                enabled: true,
                kind: "desktop",
                triggerKind: "desktop",
                triggerID: "desktop",
                triggerState: desktopEvent,
                targets: [HueRuleTarget(kind: targetOpt.kind, id: targetOpt.entityID, action: finalAction)],
                mirrorOff: false,
                matchBri: false,
                timeStart: useTimeWindow ? timeStart : "",
                timeEnd: useTimeWindow ? timeEnd : "",
                onlyIfOff: onlyIfOff
            )
        }

        guard let trigOpt = entityOptions.first(where: { $0.key == triggerKey }) else { return nil }
        let finalName = title.isEmpty ? "\(trigOpt.label) → \(targetOpt.label)" : title
        return HueRule(
            name: finalName,
            enabled: true,
            kind: ruleKind,
            triggerKind: trigOpt.kind,
            triggerID: trigOpt.entityID,
            triggerState: ruleKind == "exclusive" ? "on" : triggerState,
            targets: [HueRuleTarget(kind: targetOpt.kind, id: targetOpt.entityID, action: finalAction)],
            mirrorOff: (ruleKind == "follow" || ruleKind == "companion") ? mirrorOff : false,
            matchBri: (ruleKind == "follow" || ruleKind == "companion") ? matchBri : false,
            timeStart: useTimeWindow ? timeStart : "",
            timeEnd: useTimeWindow ? timeEnd : "",
            onlyIfOff: (ruleKind == "follow" || ruleKind == "companion") ? onlyIfOff : false
        )
    }
}
