import HueCore
import SwiftUI

/// Rooms, zones, pinned favorites strip, filter pills, search, and responsive 1/2-column layout.
struct RoomsView: View {
    @EnvironmentObject var store: HueStore

    private var favoriteItems: [FavoriteItem] {
        var items: [FavoriteItem] = []
        for room in store.snapshot.rooms {
            let rKey = HueStore.favoriteKey(room: room)
            if store.isFavorite(rKey) {
                items.append(FavoriteItem(
                    key: rKey,
                    name: store.l10n.roomName(room),
                    on: room.on,
                    color: room.color,
                    kind: .room(room)
                ))
            }
            for light in room.lights {
                let lKey = HueStore.favoriteKey(light: light)
                if store.isFavorite(lKey) && !items.contains(where: { $0.key == lKey }) {
                    items.append(FavoriteItem(
                        key: lKey,
                        name: light.name,
                        on: light.on,
                        color: light.color,
                        kind: .light(light)
                    ))
                }
            }
        }
        return items
    }

    private var filteredRooms: [HueRoom] {
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.snapshot.rooms.filter { room in
            switch store.filter {
            case .all: break
            case .on: guard room.on else { return false }
            case .rooms: guard room.kind == "room" else { return false }
            case .zones: guard room.kind == "zone" else { return false }
            case .favorites:
                let hasFavRoom = store.isFavorite(HueStore.favoriteKey(room: room))
                let hasFavLight = room.lights.contains { store.isFavorite(HueStore.favoriteKey(light: $0)) }
                guard hasFavRoom || hasFavLight else { return false }
            }
            if !query.isEmpty {
                let roomMatches = store.l10n.roomName(room).lowercased().contains(query)
                let lightMatches = room.lights.contains { $0.name.lowercased().contains(query) }
                return roomMatches || lightMatches
            }
            return true
        }
    }

    var body: some View {
        let rooms = store.snapshot.rooms
        if rooms.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if store.snapshot.phase != "ok" {
                    ProgressView().controlSize(.small)
                }
                Text(emptyText)
                    .font(store.scaledFont(12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        } else {
            VStack(spacing: 0) {
                if !favoriteItems.isEmpty {
                    FavoritesStrip(items: favoriteItems)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }

                FilterBar(showSearch: rooms.count > 5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                GeometryReader { geo in
                    let twoColumns = geo.size.width >= 680
                    let shown = filteredRooms
                    if shown.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                            Text(store.tr("No rooms match this filter."))
                                .font(store.scaledFont(12.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            if twoColumns {
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 12, alignment: .top),
                                        GridItem(.flexible(), spacing: 12, alignment: .top),
                                    ],
                                    alignment: .leading,
                                    spacing: 12
                                ) {
                                    ForEach(shown) { room in
                                        RoomCard(room: room)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(shown) { room in
                                        RoomCard(room: room)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if store.snapshot.phase == "ok" { return store.tr("No lights on this bridge yet.") }
        return store.tr("Connecting to the bridge …")
    }
}

private struct FavoriteItem: Identifiable {
    enum Kind {
        case room(HueRoom)
        case light(HueLight)
    }
    var id: String { key }
    let key: String
    let name: String
    let on: Bool
    let color: String
    let kind: Kind
}

private struct FavoritesStrip: View {
    @EnvironmentObject var store: HueStore
    let items: [FavoriteItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(store.scaledFont(10))
                    .foregroundStyle(Color.yellow)
                ForEach(items) { item in
                    Button {
                        switch item.kind {
                        case .room(let room): store.setRoom(room, on: !room.on)
                        case .light(let light): store.setLight(light, on: !light.on)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(item.on ? Color(hex: item.color) : Color.primary.opacity(0.18))
                                .frame(width: 8, height: 8)
                            Text(item.name)
                                .font(store.scaledFont(11, weight: item.on ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(item.on ? Color(hex: item.color).opacity(0.18) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                item.on ? Color(hex: item.color).opacity(0.5) : Color.primary.opacity(0.1),
                                lineWidth: 0.5
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct FilterBar: View {
    @EnvironmentObject var store: HueStore
    let showSearch: Bool

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill(.all, label: store.tr("All"))
                    filterPill(.on, label: store.tr("On"))
                    filterPill(.rooms, label: store.tr("Rooms"))
                    if store.snapshot.rooms.contains(where: { $0.kind == "zone" }) {
                        filterPill(.zones, label: store.tr("Zones"))
                    }
                    if !store.favorites.isEmpty {
                        filterPill(.favorites, label: store.tr("Favorites"))
                    }
                }
            }
            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(store.tr("Search rooms or lights"), text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(store.scaledFont(12))
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
        }
    }

    private func filterPill(_ filter: HueStore.RoomFilter, label: String) -> some View {
        let active = store.filter == filter
        return Button(label) {
            withAnimation(.easeInOut(duration: 0.12)) { store.filter = filter }
        }
        .buttonStyle(ChipStyle(active: active))
    }
}

struct RoomCard: View {
    @EnvironmentObject var store: HueStore
    let room: HueRoom

    private var tint: Color? { room.on ? Color(hex: room.color) : nil }

    private var cardFill: Color {
        if let tint = tint { return tint.opacity(0.14) }
        return store.cardBackgroundColor
    }

    private var cardBorder: Color {
        if let tint = tint { return tint.opacity(0.45) }
        return store.cardBorderColor
    }

    var body: some View {
        let open = store.expanded.contains(room.id)
        let favKey = HueStore.favoriteKey(room: room)
        let isFav = store.isFavorite(favKey)
        let isExcluded = store.isExcludedFromAllOn(room.id)
        let motionArea = store.motionArea(forRoom: room.hueID)
        let hasPresence = motionArea.map { $0.enabled && $0.motion } ?? false

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleExpanded(room) }
                } label: {
                    HStack(spacing: 10) {
                        RoomBadge(symbol: roomSymbol(room), tintHex: room.on ? room.color : nil, radius: store.smallRadius)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(store.l10n.roomName(room))
                                    .font(store.scaledFont(13, weight: .semibold))
                                    .lineLimit(1)
                                if isFav {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.yellow)
                                }
                                if isExcluded {
                                    Image(systemName: "moon.zzz")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .help(store.tr("Excluded from All On"))
                                }
                                if store.hasActiveSchedule(for: room.id) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                if store.hasActiveRule(for: room.id) {
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                if let area = motionArea, area.enabled {
                                    HStack(spacing: 3) {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .font(.system(size: 8.5, weight: .semibold))
                                        if hasPresence {
                                            Text(store.tr("Presence"))
                                                .font(store.scaledFont(9, weight: .semibold))
                                        }
                                    }
                                    .foregroundStyle(hasPresence ? Color(hex: "#10b981") : Color(hex: "#06b6d4"))
                                    .padding(.horizontal, hasPresence ? 5 : 3)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule().fill(
                                            (hasPresence ? Color(hex: "#10b981") : Color(hex: "#06b6d4")).opacity(hasPresence ? 0.16 : 0.10)
                                        )
                                    )
                                    .help(hasPresence ? store.tr("MotionAware presence detected") : store.tr("MotionAware active"))
                                }
                            }
                            Text(store.l10n.roomStatus(room))
                                .font(store.scaledFont(11))
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

                Menu {
                    Button(isFav ? store.tr("Remove from Favorites") : store.tr("Pin to Favorites")) {
                        store.toggleFavorite(favKey)
                    }
                    if room.kind == "room" {
                        Button(isExcluded ? store.tr("Include in All On") : store.tr("Exclude room from All On")) {
                            store.toggleExcludedFromAllOn(room.id)
                        }
                    }
                    if !room.hueID.isEmpty {
                        Divider()
                        Button(store.tr("Schedule this room …")) {
                            store.openScheduleFor(kind: "room", id: room.id)
                        }
                        Button(store.tr("Link with another light …")) {
                            store.openRuleFor(kind: "room", id: room.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)

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
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }
}

struct RoomBadge: View {
    let symbol: String
    let tintHex: String?
    var radius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
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
                    .font(store.scaledFont(11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

struct LightRow: View {
    @EnvironmentObject var store: HueStore
    let light: HueLight
    @State private var showColorPopover = false

    private var canPickColor: Bool {
        light.supportsColor || light.supportsCT || !light.availableEffects.isEmpty
    }

    var body: some View {
        let favKey = HueStore.favoriteKey(light: light)
        let isFav = store.isFavorite(favKey)

        HStack(spacing: 8) {
            Button {
                if canPickColor { showColorPopover = true }
            } label: {
                Circle()
                    .fill(light.on ? Color(hex: light.color) : Color.primary.opacity(0.1))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(canPickColor ? 0.35 : 0.2), lineWidth: 0.75))
                    .frame(width: 14, height: 14)
                    .opacity(light.reachable ? 1 : 0.4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(canPickColor ? store.tr("Color, warmth & effects") : light.name)
            .popover(isPresented: $showColorPopover, arrowEdge: .leading) {
                LightColorPopover(light: light)
                    .environmentObject(store)
            }

            HStack(spacing: 4) {
                Text(light.reachable ? light.name : "\(light.name) · \(store.tr("unreachable"))")
                    .font(store.scaledFont(12))
                    .foregroundStyle(light.on && light.reachable ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if isFav {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.yellow)
                }
                if store.hasActiveSchedule(for: light.id) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help(store.tr("Has active schedule"))
                }
                if store.hasActiveRule(for: light.id) {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help(store.tr("Linked by rule"))
                }
                if light.motionAware {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(light.motionActive ? Color(hex: "#10b981") : Color(hex: "#06b6d4"))
                        .help(light.motionActive ? store.tr("MotionAware presence detected") : store.tr("MotionAware™"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if light.dimmable {
                BrightnessSlider(target: HueStore.target(light: light), bridge: light.on ? light.bri : 1)
                    .frame(width: 105)
            }

            Menu {
                Button(store.tr("Themes …")) {
                    store.themeEditorLight = light
                }
                Button(store.tr("Schedule this light …")) {
                    store.openScheduleFor(kind: "light", id: light.id)
                }
                Button(store.tr("Link with another light …")) {
                    store.openRuleFor(kind: "light", id: light.id)
                }
                Divider()
                Button(isFav ? store.tr("Remove from Favorites") : store.tr("Pin to Favorites")) {
                    store.toggleFavorite(favKey)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)

            Toggle("", isOn: Binding(get: { light.on }, set: { store.setLight(light, on: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.vertical, 3)
        .padding(.leading, 4)
    }
}

/// Color, Kelvin warmth, and native Hue CLIP v2 effects popover for a single light.
struct LightColorPopover: View {
    @EnvironmentObject var store: HueStore
    let light: HueLight
    @State private var mirekValue: Double

    private static let colorSwatches: [String] = [
        "#ff4b4b", "#ff7a2f", "#ffb833", "#ffe66d",
        "#7be06b", "#2ec4b6", "#38bdf8", "#3b82f6",
        "#6366f1", "#a855f7", "#ec4899", "#ffffff",
    ]

    private struct WarmthPreset: Identifiable {
        let id: Int
        let kelvin: Int
        let mirek: Int
        let hex: String
    }

    private static let warmthPresets: [WarmthPreset] = [
        WarmthPreset(id: 2200, kelvin: 2200, mirek: 454, hex: HueColorMath.mirekToHex(454)),
        WarmthPreset(id: 2700, kelvin: 2700, mirek: 370, hex: HueColorMath.mirekToHex(370)),
        WarmthPreset(id: 4000, kelvin: 4000, mirek: 250, hex: HueColorMath.mirekToHex(250)),
        WarmthPreset(id: 6000, kelvin: 6000, mirek: 167, hex: HueColorMath.mirekToHex(167)),
    ]

    init(light: HueLight) {
        self.light = light
        let initial = light.mirek ?? 300
        _mirekValue = State(initialValue: Double(HueColorMath.clamp(initial, light.mirekMin, light.mirekMax)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(light.name)
                    .font(store.scaledFont(13, weight: .semibold))
                Spacer()
                if light.supportsCT {
                    Text("\(HueColorMath.mirekToKelvin(Int(mirekValue.rounded()))) K")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if light.supportsCT {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.tr("Warmth").uppercased())
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(Self.warmthPresets) { preset in
                            let clamped = HueColorMath.clamp(preset.mirek, light.mirekMin, light.mirekMax)
                            Button {
                                mirekValue = Double(clamped)
                                store.setLight(light, mirek: clamped)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(hex: preset.hex))
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                        .frame(width: 10, height: 10)
                                    Text("\(preset.kelvin)K")
                                        .font(store.scaledFont(10.5))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Slider(
                        value: $mirekValue,
                        in: Double(light.mirekMin)...Double(max(light.mirekMin + 1, light.mirekMax)),
                        onEditingChanged: { editing in
                            if !editing {
                                store.setLight(light, mirek: Int(mirekValue.rounded()))
                            }
                        }
                    )
                    .controlSize(.small)
                }
            }

            if light.supportsColor {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.tr("Color").uppercased())
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                        ForEach(Self.colorSwatches, id: \.self) { hex in
                            Button {
                                if let xy = HueColorMath.hexToXY(hex) {
                                    store.setLight(light, xy: (xy.x, xy.y))
                                }
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !light.availableEffects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.tr("Effects").uppercased())
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        Button(store.tr("None")) {
                            store.setLight(light, effect: "no_effect")
                        }
                        .buttonStyle(ChipStyle(active: light.effect == "no_effect" || light.effect.isEmpty))

                        ForEach(light.availableEffects, id: \.self) { eff in
                            Button(eff.replacingOccurrences(of: "_", with: " ").capitalized) {
                                store.setLight(light, effect: eff)
                            }
                            .buttonStyle(ChipStyle(active: light.effect == eff))
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(store.tr("Themes").uppercased())
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.tr("Edit / Create Theme …")) {
                        store.themeEditorLight = light
                    }
                    .buttonStyle(.borderless)
                    .font(store.scaledFont(10.5, weight: .medium))
                }
                FlowLayout(spacing: 5) {
                    ForEach(Array(store.allThemes.prefix(6))) { theme in
                        Button {
                            store.applyTheme(theme, to: light)
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: theme.hex))
                                    .frame(width: 8, height: 8)
                                Text(theme.name)
                                    .font(store.scaledFont(10.5))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .fontDesign(store.fontDesign)
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
        ChipBody(configuration: configuration, active: active, subtle: subtle)
    }

    private struct ChipBody: View {
        @EnvironmentObject var store: HueStore
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let subtle: Bool

        var body: some View {
            configuration.label
                .font(.caption.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(active ? Color.white : (subtle ? store.skinAccentColor : Color.primary))
                .background(Capsule().fill(active ? store.skinAccentColor : Color.primary.opacity(subtle ? 0 : 0.08)))
                .overlay(Capsule().strokeBorder(active ? Color.clear : store.cardBorderColor, lineWidth: 0.75))
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// Left-to-right rows that wrap, for scene & effect chips.
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
