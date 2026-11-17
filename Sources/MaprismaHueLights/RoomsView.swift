import HueCore
import SwiftUI

/// One card per room and zone (and "Other lights"): switch, brightness while on, scenes, and the
/// single lights when the card is opened.
struct RoomsView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let rooms = store.snapshot.rooms
        if rooms.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if store.snapshot.phase != "ok" {
                    ProgressView().controlSize(.small)
                }
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rooms) { room in
                        RoomCard(room: room)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyText: String {
        if store.snapshot == HueSnapshot.initial { return store.tr("Starting the Hue helper …") }
        if store.snapshot.phase == "ok" { return store.tr("No lights on this bridge yet.") }
        return store.tr("Connecting to the bridge …")
    }
}

struct RoomCard: View {
    @EnvironmentObject var store: HueStore
    let room: HueRoom

    private var tint: Color? { room.on ? Color(hex: room.color) : nil }

    private var cardFill: Color {
        if let tint = tint { return tint.opacity(0.14) }
        return Color.primary.opacity(0.05)
    }

    private var cardBorder: Color {
        if let tint = tint { return tint.opacity(0.45) }
        return Color.primary.opacity(0.08)
    }

    var body: some View {
        let open = store.expanded.contains(room.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleExpanded(room) }
                } label: {
                    HStack(spacing: 10) {
                        RoomBadge(symbol: roomSymbol(room), tintHex: room.on ? room.color : nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.l10n.roomName(room))
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(store.l10n.roomStatus(room))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.tr("Lights"))
                Toggle("", isOn: Binding(get: { room.on }, set: { store.setRoom(room, on: $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if room.on {
                BrightnessSlider(target: HueStore.target(room: room), bridge: room.bri, showsValue: true)
            }
            if !room.scenes.isEmpty {
                SceneChips(room: room)
            }
            if open {
                Divider()
                VStack(spacing: 2) {
                    ForEach(room.lights) { light in
                        LightRow(light: light)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }
}

struct RoomBadge: View {
    let symbol: String
    let tintHex: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(glyph)
        }
        .frame(width: 32, height: 32)
    }

    private var fill: Color {
        guard let hex = tintHex else { return Color.primary.opacity(0.08) }
        return Color(hex: hex)
    }

    private var glyph: Color {
        guard let hex = tintHex else { return Color.secondary }
        return prefersDarkGlyph(hex) ? Color.black.opacity(0.8) : Color.white
    }
}

/// A brightness slider: smooth while dragging, commands at most every 150 ms (HueStore's
/// debouncer), the last value when released.
struct BrightnessSlider: View {
    @EnvironmentObject var store: HueStore
    let target: String
    let bridge: Double
    var showsValue = false

    var body: some View {
        let value = store.brightness(target, bridge: bridge)
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { value }, set: { store.drag(target, to: $0) }),
                in: 1...100,
                onEditingChanged: { editing in
                    if !editing { store.release(target) }
                }
            )
            .controlSize(.small)
            if showsValue {
                Text("\(brightnessStep(value))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

struct LightRow: View {
    @EnvironmentObject var store: HueStore
    let light: HueLight

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(light.on ? Color(hex: light.color) : Color.primary.opacity(0.08))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 12, height: 12)
                .opacity(light.reachable ? 1 : 0.4)
            Text(light.reachable ? light.name : "\(light.name) · \(store.tr("unreachable"))")
                .font(.callout)
                .foregroundStyle(light.on && light.reachable ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if light.dimmable {
                BrightnessSlider(target: HueStore.target(light: light), bridge: light.on ? light.bri : 1)
                    .frame(width: 120)
            }
            Toggle("", isOn: Binding(get: { light.on }, set: { store.setLight(light, on: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
    }
}

/// The room's scenes as chips: the first 6 (and the active one), then "+N more" / "less".
struct SceneChips: View {
    @EnvironmentObject var store: HueStore
    let room: HueRoom
    static let limit = 6

    var body: some View {
        let all = store.allScenes.contains(room.id)
        let shown = room.scenes.enumerated()
            .filter { all || $0.offset < SceneChips.limit || $0.element.active }
            .map { $0.element }
        FlowLayout(spacing: 6) {
            ForEach(shown) { scene in
                Button(scene.name) { store.recall(scene) }
                    .buttonStyle(ChipStyle(active: scene.active))
                    .help(store.tr("Recall scene"))
            }
            if room.scenes.count > SceneChips.limit && (all || shown.count < room.scenes.count) {
                Button(all ? store.tr("less") : store.trf("+{0} more", [String(room.scenes.count - shown.count)])) {
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleAllScenes(room) }
                }
                .buttonStyle(ChipStyle(active: false, subtle: true))
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    var active: Bool
    var subtle = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(active ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(active ? Color.white : (subtle ? Color.accentColor : Color.primary))
            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(subtle ? 0 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(active ? 0 : 0.1), lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Left-to-right rows that wrap, for the scene chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = fitted(view, maxWidth)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = fitted(view, bounds.width)
            if x > 0 && x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func fitted(_ view: LayoutSubview, _ maxWidth: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}
