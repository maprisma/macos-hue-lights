import AppKit
import HueCore
import SwiftUI

// MARK: - Polygon Room Shape (renders both rectangles & arbitrary polygons)

struct FloorplanPolygonShape: Shape {
    let points: [FloorplanPoint]
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 3 else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
            return path
        }
        let scaleX = rect.width / max(1.0, CGFloat(width))
        let scaleY = rect.height / max(1.0, CGFloat(height))
        for (idx, pt) in points.enumerated() {
            let sx = rect.minX + CGFloat(pt.x - minX) * scaleX
            let sy = rect.minY + CGFloat(pt.y - minY) * scaleY
            if idx == 0 {
                path.move(to: CGPoint(x: sx, y: sy))
            } else {
                path.addLine(to: CGPoint(x: sx, y: sy))
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Multi-Floor Tabs + Scale + Ambient Day/Dusk/Night Bar

struct FloorTabsBar: View {
    @EnvironmentObject var store: HueStore
    @Binding var ambientMode: FloorplanAmbientMode
    let onFloorSwitched: () -> Void

    @State private var showAddFloorPopover: Bool = false
    @State private var newFloorName: String = ""
    @State private var newFloorLevel: Int = 1

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.floorplan.floors) { floor in
                        let active = store.floorplan.activeFloorID == floor.id
                        let litCount = litCountOnFloor(floor.id)
                        Button {
                            store.selectFloor(floor.id)
                            onFloorSwitched()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: floor.level < 0 ? "arrow.down.square" : (floor.level == 0 ? "house" : "square.stack.3d.up"))
                                    .font(.system(size: 10, weight: .semibold))
                                Text(floor.name)
                                    .font(store.scaledFont(10.5, weight: active ? .semibold : .medium))
                                    .lineLimit(1)
                                if litCount > 0 {
                                    Text("\(litCount)")
                                        .font(store.scaledFont(9, weight: .bold).monospacedDigit())
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(active ? Color.white.opacity(0.28) : store.skinAccentColor.opacity(0.22)))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .background(
                                Capsule().fill(active ? store.skinAccentColor : Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if store.floorplan.floors.count > 1 {
                                Button(store.tr("Delete Floor"), role: .destructive) {
                                    store.deleteFloor(id: floor.id)
                                    onFloorSwitched()
                                }
                            }
                        }
                    }

                    Button {
                        newFloorLevel = (store.floorplan.floors.map(\.level).max() ?? 0) + 1
                        newFloorName = defaultFloorName(for: newFloorLevel)
                        showAddFloorPopover = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9.5, weight: .bold))
                            Text(store.tr("Floor"))
                                .font(store.scaledFont(10.5, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(.secondary)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAddFloorPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.tr("Add Floor"))
                                .font(store.scaledFont(12.5, weight: .semibold))
                            TextField(store.tr("Floor name"), text: $newFloorName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            Stepper(value: $newFloorLevel, in: -2...5) {
                                Text(store.trf("Level: {0}", [String(newFloorLevel)]))
                                    .font(store.scaledFont(11.5))
                            }
                            .controlSize(.small)
                            HStack {
                                Spacer()
                                Button(store.tr("Add")) {
                                    store.addFloor(name: newFloorName.isEmpty ? defaultFloorName(for: newFloorLevel) : newFloorName, level: newFloorLevel)
                                    showAddFloorPopover = false
                                    onFloorSwitched()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .frame(width: 220)
                    }
                }
            }

            Spacer(minLength: 4)

            // Ambient Light Simulation (Day / Dusk / Night)
            Picker("", selection: $ambientMode) {
                ForEach(FloorplanAmbientMode.allCases) { m in
                    Text(store.tr(m.titleKey)).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 152)
            .help(store.tr("Simulate Day, Dusk, or Night lighting"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.025))
    }

    private func litCountOnFloor(_ floorID: String) -> Int {
        var count = 0
        for (lightID, p) in store.floorplan.lamps where p.floorID == floorID {
            if store.snapshot.light(lightID)?.on == true { count += 1 }
        }
        return count
    }

    private func defaultFloorName(for level: Int) -> String {
        switch level {
        case ..<0: return store.tr("Basement")
        case 0: return store.tr("Ground Floor")
        case 1: return store.tr("Upper Floor")
        case 2: return store.tr("Attic")
        default: return store.trf("Floor {0}", [String(level)])
        }
    }
}

// MARK: - Visual Floorplan Gallery Sheet (Live Rendered Polygon Thumbnails)

struct FloorplanGallerySheet: View {
    struct GalleryEntry: Identifiable {
        let id: String
        let titleKey: String
        let subtitleKey: String
        let badgeKey: String
        let previewDoc: FloorplanDocument
    }

    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss
    let onApplied: () -> Void

    @State private var includeSamplePlan: Bool = false

    private var entries: [GalleryEntry] {
        let emptySnap = HueSnapshot(phase: "ok")
        return [
            GalleryEntry(
                id: FloorplanTemplate.threeRoomApartment.rawValue,
                titleKey: "Altbau 3-Room Apartment",
                subtitleKey: "Erker bay window, L-shaped hallway, 2 bedrooms, office & bath",
                badgeKey: "Bay Window",
                previewDoc: FloorplanTemplate.build(template: .threeRoomApartment, snapshot: emptySnap)
            ),
            GalleryEntry(
                id: FloorplanTemplate.familyHouse.rawValue,
                titleKey: "2-Story Family House",
                subtitleKey: "Ground & upper floor with stairs, L-shaped living/dining & terrace",
                badgeKey: "2 Floors",
                previewDoc: FloorplanTemplate.build(template: .familyHouse, snapshot: emptySnap)
            ),
            GalleryEntry(
                id: "bungalow_l_shape",
                titleKey: "L-Shaped Bungalow",
                subtitleKey: "Wrap-around living/dining, kitchen, bedroom & courtyard terrace",
                badgeKey: "L-Shape",
                previewDoc: FloorplanTemplate.buildLShapedBungalow(snapshot: emptySnap)
            ),
            GalleryEntry(
                id: FloorplanTemplate.studioLoft.rawValue,
                titleKey: "Open-Plan Loft",
                subtitleKey: "L-shaped studio living/sleeping, kitchenette, bath & balcony",
                badgeKey: "Open Plan",
                previewDoc: FloorplanTemplate.build(template: .studioLoft, snapshot: emptySnap)
            ),
            GalleryEntry(
                id: FloorplanTemplate.oneBedApartment.rawValue,
                titleKey: "2-Room Apartment",
                subtitleKey: "Living/dining corner, kitchen, hallway, bedroom, bath & balcony",
                badgeKey: "Apartment",
                previewDoc: FloorplanTemplate.build(template: .oneBedApartment, snapshot: emptySnap)
            ),
            GalleryEntry(
                id: FloorplanTemplate.deskStudio.rawValue,
                titleKey: "Desk & Gaming Studio",
                subtitleKey: "Close-up single room for desk, monitor & TV lights",
                badgeKey: "Studio",
                previewDoc: FloorplanTemplate.build(template: .deskStudio, snapshot: emptySnap)
            ),
            GalleryEntry(
                id: FloorplanTemplate.autoBridge.rawValue,
                titleKey: "Auto from My Lights",
                subtitleKey: "Connected layout automatically generated from your live rooms",
                badgeKey: "Auto",
                previewDoc: FloorplanTemplate.build(template: .autoBridge, snapshot: store.snapshot)
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Floorplan Gallery"))
                        .font(store.scaledFont(15, weight: .semibold))
                    Text(store.tr("Pick a realistic apartment or house drawing — every wall & corner is editable."))
                        .font(store.scaledFont(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.tr("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            Toggle(store.tr("Include starter lighting plan (suggested fixtures & LED strips)"), isOn: $includeSamplePlan)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(store.scaledFont(11.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.03))

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(entries) { entry in
                        let isCurrent = store.floorplan.templateID == entry.id
                        Button {
                            store.applyGalleryPreset(id: entry.id, includeSamplePlan: includeSamplePlan)
                            onApplied()
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FloorplanThumbnailCanvas(doc: entry.previewDoc, accent: store.skinAccentColor)
                                    .frame(height: 112)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(isCurrent ? store.skinAccentColor : Color.primary.opacity(0.12), lineWidth: isCurrent ? 1.8 : 0.8)
                                    )

                                HStack(spacing: 5) {
                                    Text(store.tr(entry.titleKey))
                                        .font(store.scaledFont(12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(store.tr(entry.badgeKey))
                                        .font(store.scaledFont(9, weight: .semibold))
                                        .foregroundStyle(store.skinAccentColor)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(store.skinAccentColor.opacity(0.14)))
                                }

                                Text(store.tr(entry.subtitleKey))
                                    .font(store.scaledFont(10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 8) {
                                    let roomCount = entry.previewDoc.boxes.filter { $0.kind == "room" }.count
                                    let areaStr = String(format: "%.0f m²", entry.previewDoc.totalAreaM2)
                                    Text("\(roomCount) \(store.tr("Rooms")) · \(areaStr)")
                                        .font(store.scaledFont(9.5).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if entry.previewDoc.floors.count > 1 {
                                        Text("· \(entry.previewDoc.floors.count) \(store.tr("Floors"))")
                                            .font(store.scaledFont(9.5, weight: .medium))
                                            .foregroundStyle(store.skinAccentColor)
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                                    .fill(store.cardBackgroundColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                                    .strokeBorder(isCurrent ? store.skinAccentColor : store.cardBorderColor, lineWidth: isCurrent ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 580, height: 540)
        .fontDesign(store.fontDesign)
    }
}

/// Renders a crisp miniature architectural preview of a floorplan document's ground floor polygons.
struct FloorplanThumbnailCanvas: View {
    let doc: FloorplanDocument
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let floorID = doc.floors.first?.id ?? "eg"
            let boxes = doc.boxes(onFloor: floorID)
            guard !boxes.isEmpty else { return }

            let minX = boxes.map(\.minX).min() ?? 0
            let minY = boxes.map(\.minY).min() ?? 0
            let maxX = boxes.map(\.maxX).max() ?? 800
            let maxY = boxes.map(\.maxY).max() ?? 600
            let spanW = max(100, maxX - minX)
            let spanH = max(100, maxY - minY)
            let pad: CGFloat = 10
            let scale = min((size.width - pad * 2) / CGFloat(spanW), (size.height - pad * 2) / CGFloat(spanH))
            let ox = (size.width - CGFloat(spanW) * scale) * 0.5 - CGFloat(minX) * scale
            let oy = (size.height - CGFloat(spanH) * scale) * 0.5 - CGFloat(minY) * scale

            for box in boxes {
                let pts = box.effectivePoints
                guard pts.count >= 3 else { continue }
                var path = Path()
                for (i, p) in pts.enumerated() {
                    let pt = CGPoint(x: ox + CGFloat(p.x) * scale, y: oy + CGFloat(p.y) * scale)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                let isZone = box.kind == "zone"
                ctx.fill(path, with: .color(isZone ? accent.opacity(0.08) : accent.opacity(0.16)))
                ctx.stroke(
                    path,
                    with: .color(isZone ? accent.opacity(0.55) : accent.opacity(0.85)),
                    style: StrokeStyle(lineWidth: isZone ? 1.0 : 1.4, dash: isZone ? [3, 2] : [])
                )
            }
        }
    }
}

// MARK: - Planned Light Inspector & Bind-to-Real-Light Sheet

struct PlannedLightInspectorSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss
    let plannedID: String

    @State private var name: String = ""
    @State private var icon: LampIcon = .bulb
    @State private var lumens: Double = 800
    @State private var beamRadius: Double = 2.6
    @State private var kelvin: Double = 2700
    @State private var useCustomColor: Bool = false
    @State private var customColor: Color = Color(hex: "#ffd27a")
    @State private var modelNote: String = ""
    @State private var priceText: String = ""
    @State private var bindLightID: String = ""

    private var current: PlannedLight? {
        store.floorplan.plannedLights.first(where: { $0.id == plannedID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.tr("Edit Planned Fixture"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Name"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField(store.tr("Planned Light"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.tr("Fixture Type"))
                            .font(store.scaledFont(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6), spacing: 5) {
                            ForEach(LampIcon.allCases) { ic in
                                Button {
                                    icon = ic
                                } label: {
                                    Image(systemName: ic.sfSymbol(lit: true))
                                        .font(.system(size: 13))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 28)
                                        .foregroundStyle(icon == ic ? Color.white : Color.primary)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(icon == ic ? store.skinAccentColor : Color.primary.opacity(0.06))
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(store.tr(ic.titleKey))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.tr("Brightness (Lumens)"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(lumens)) lm")
                                .font(store.scaledFont(11, weight: .semibold).monospacedDigit())
                        }
                        Slider(value: $lumens, in: 150...4000, step: 50)
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.tr("Beam Spread"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f m", beamRadius))
                                .font(store.scaledFont(11, weight: .semibold).monospacedDigit())
                        }
                        Slider(value: $beamRadius, in: 1.0...6.0, step: 0.2)
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.tr("Color Temperature"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(kelvin)) K")
                                .font(store.scaledFont(11, weight: .semibold).monospacedDigit())
                        }
                        Slider(value: $kelvin, in: 2000...6500, step: 100)
                            .controlSize(.small)
                        Toggle(store.tr("Use custom RGB color"), isOn: $useCustomColor)
                            .font(store.scaledFont(11))
                        if useCustomColor {
                            ColorPicker(store.tr("Color"), selection: $customColor, supportsOpacity: false)
                                .font(store.scaledFont(11))
                        }
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.tr("Product / Note"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Hue Ensis / WLED Strip", text: $modelNote)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.tr("Est. Price"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("0", text: $priceText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                        }
                    }

                    // 1-Click Bind to Real Paired Light
                    if !store.snapshot.allLights.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.tr("Replace with real paired light"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Picker("", selection: $bindLightID) {
                                    Text(store.tr("Select a real light…")).tag("")
                                    ForEach(store.snapshot.allLights) { l in
                                        Text(l.name).tag(l.id)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                Button(store.tr("Bind")) {
                                    guard !bindLightID.isEmpty else { return }
                                    store.bindPlannedLight(plannedID: plannedID, toRealLightID: bindLightID)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(bindLightID.isEmpty)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    store.deletePlannedLight(id: plannedID)
                    dismiss()
                } label: {
                    Label(store.tr("Delete"), systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(store.tr("Save")) {
                    guard var copy = current else { dismiss(); return }
                    copy.name = HueColorMath.clean(name, limit: 40)
                    if copy.name.isEmpty { copy.name = store.tr("Planned Light") }
                    copy.icon = icon
                    copy.lumens = Int(lumens.rounded())
                    copy.beamRadius = beamRadius
                    copy.kelvin = Int(kelvin.rounded())
                    if useCustomColor, let ns = NSColor(customColor).usingColorSpace(.sRGB) {
                        copy.colorHex = HueColorMath.rgbToHex(
                            r: Int((ns.redComponent * 255).rounded()),
                            g: Int((ns.greenComponent * 255).rounded()),
                            b: Int((ns.blueComponent * 255).rounded())
                        )
                    } else {
                        copy.colorHex = HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(copy.kelvin))
                    }
                    copy.modelNote = HueColorMath.clean(modelNote, limit: 80)
                    copy.price = max(0, Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? 0)
                    store.updatePlannedLight(copy, finalize: true)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 390, height: 510)
        .fontDesign(store.fontDesign)
        .onAppear {
            if let item = current {
                name = item.name
                icon = item.icon
                lumens = Double(item.lumens)
                beamRadius = item.beamRadius
                kelvin = Double(item.kelvin)
                let ctHex = HueColorMath.mirekToHex(HueColorMath.kelvinToMirek(item.kelvin))
                useCustomColor = item.colorHex.lowercased() != ctHex.lowercased()
                customColor = Color(hex: item.colorHex)
                modelNote = item.modelNote
                priceText = item.price > 0 ? String(format: "%.0f", item.price) : ""
            }
        }
    }
}

// MARK: - Lighting Plan & Shopping List Sheet

struct LightingShoppingListSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    private var planned: [PlannedLight] { store.floorplan.plannedLights }
    private var totalLumens: Int { planned.map(\.lumens).reduce(0, +) }
    private var totalPrice: Double { planned.map(\.price).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Lighting Plan & Shopping List"))
                        .font(store.scaledFont(15, weight: .semibold))
                    Text("\(planned.count) \(store.tr("Planned Fixtures")) · \(totalLumens) lm · \(String(format: "%.0f", totalPrice))")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.tr("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Room Lux / m² readiness summary
                    let rooms = store.floorplan.boxes.filter { $0.kind == "room" }
                    if !rooms.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.tr("Room Illuminance Preview").uppercased())
                                .font(store.scaledFont(10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(rooms) { box in
                                let stats = RoomLightingAnalysis.compute(for: box, floorplan: store.floorplan, snapshot: store.snapshot, includePlanned: true)
                                let tint: Color = stats.rating == "balanced" ? .green : (stats.rating == "dim" ? .orange : .cyan)
                                HStack(spacing: 8) {
                                    Text(box.name)
                                        .font(store.scaledFont(11.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(String(format: "%.1f m²", stats.areaM2))
                                        .font(store.scaledFont(10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(stats.lux) / \(stats.targetLux) lx")
                                        .font(store.scaledFont(10.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(tint)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                            }
                        }
                    }

                    // Planned fixture list
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Planned Fixtures").uppercased())
                            .font(store.scaledFont(10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if planned.isEmpty {
                            Text(store.tr("No planned fixtures yet. Switch to Plan mode to place virtual lights or LED strips."))
                                .font(store.scaledFont(11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(planned) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.icon.sfSymbol(lit: item.on))
                                        .foregroundStyle(Color(hex: item.colorHex))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name)
                                            .font(store.scaledFont(11.5, weight: .medium))
                                        let sub = [
                                            "\(item.lumens) lm",
                                            "\(item.kelvin) K",
                                            item.modelNote.isEmpty ? nil : item.modelNote,
                                        ].compactMap { $0 }.joined(separator: " · ")
                                        Text(sub)
                                            .font(store.scaledFont(10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.price > 0 {
                                        Text(String(format: "%.0f", item.price))
                                            .font(store.scaledFont(11, weight: .semibold).monospacedDigit())
                                    }
                                    Button {
                                        store.deletePlannedLight(id: item.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                            }
                        }
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button {
                    copyShoppingList()
                } label: {
                    Label(copied ? store.tr("Copied!") : store.tr("Copy Shopping List"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(planned.isEmpty)
                Spacer()
                Button(store.tr("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 460, height: 500)
        .fontDesign(store.fontDesign)
    }

    private func copyShoppingList() {
        var lines: [String] = ["# Lighting Plan (\(planned.count) fixtures, \(totalLumens) lm, est. \(Int(totalPrice.rounded())))"]
        for item in planned {
            let roomName = FloorplanSpatial.boxContaining(
                x: item.anchorPoint.x,
                y: item.anchorPoint.y,
                in: store.floorplan.boxes(onFloor: item.floorID),
                kindFilter: nil
            )?.name ?? item.floorID.uppercased()
            let note = item.modelNote.isEmpty ? "" : " — \(item.modelNote)"
            let price = item.price > 0 ? " (\(Int(item.price.rounded())))" : ""
            lines.append("- [\(roomName)] \(item.name): \(item.lumens) lm, \(item.kelvin) K\(note)\(price)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
