import AppKit
import HueCore
import SwiftUI
import UniformTypeIdentifiers

/// Interactive 2D Visual Floorplan & Spatial Light Studio (`Map` tab).
/// Supports 6 editable architectural prototypes, custom floorplan background image,
/// resizable Room/Zone boxes with inline Scenes & Scene Scheduling, glowing live Hue lamp nodes,
/// minimalist rotatable furniture stamps, Bezier dependency wires, and 1-click Bridge Sync.
struct MapView: View {
    enum MapTool: String, CaseIterable, Identifiable {
        case control, edit, wire
        var id: String { rawValue }
    }

    enum SidebarFilter: String, CaseIterable, Identifiable {
        case all, unplaced
        var id: String { rawValue }
    }

    struct WireEndpoint: Equatable, Hashable {
        let kind: String // "light" or "room"
        let id: String
    }

    struct PendingWireCreation: Identifiable {
        let id = UUID()
        let source: WireEndpoint
        let target: WireEndpoint
    }

    struct PendingSceneSchedule: Identifiable {
        let id = UUID()
        let room: HueRoom
        let scene: HueScene
    }

    @EnvironmentObject var store: HueStore
    @Environment(\.openWindow) private var openWindow
    var isCompact: Bool = false

    @State private var tool: MapTool = .control
    @State private var sidebarOpen: Bool = true
    @State private var sidebarFilter: SidebarFilter = .all
    @State private var lampSearch: String = ""
    @State private var showGrid: Bool = true
    @State private var showSynthOverlay: Bool = false

    @State private var selectedBoxID: String? = nil
    @State private var selectedLightID: String? = nil
    @State private var selectedStampID: String? = nil
    @State private var inspectedLightID: String? = nil
    @State private var inspectedBoxID: String? = nil
    @State private var scenesBoxID: String? = nil
    @State private var inspectedRuleID: String? = nil
    @State private var showBackgroundPopover: Bool = false

    @State private var canvasViewportSize: CGSize = CGSize(width: 720, height: 500)
    @State private var didInitialFit: Bool = false

    // Transient drag states
    @State private var panStart: CGPoint? = nil
    @State private var wireDraftSource: WireEndpoint? = nil
    @State private var wireDraftWorldPoint: CGPoint? = nil
    @State private var pendingWire: PendingWireCreation? = nil
    @State private var pendingSceneSchedule: PendingSceneSchedule? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            syncBannerIfNeeded
            statusToastIfNeeded

            HStack(spacing: 0) {
                if sidebarOpen {
                    lampSidebar
                        .frame(width: isCompact ? 175 : 215)
                    Divider()
                }
                canvasWorkspace
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            sidebarOpen = !isCompact
        }
        .sheet(item: $pendingWire) { wire in
            QuickWireRuleSheet(source: wire.source, target: wire.target)
                .environmentObject(store)
        }
        .sheet(item: $pendingSceneSchedule) { item in
            QuickSceneScheduleSheet(room: item.room, scene: item.scene)
                .environmentObject(store)
        }
    }

    // MARK: - Top Studio Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { sidebarOpen.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(store.tr("Toggle lamp sidebar"))

                // 6 Editable Starter Prototypes menu
                Menu {
                    ForEach(FloorplanTemplate.allCases) { tpl in
                        Button {
                            store.applyFloorplanTemplate(tpl)
                            fitCanvasToContent()
                        } label: {
                            Label(store.tr(tpl.titleKey), systemImage: tpl.symbol)
                        }
                    }
                } label: {
                    Label(store.tr("Prototypes"), systemImage: "square.grid.2x2")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .help(store.tr("Choose Floorplan Prototype"))

                // Tool mode selector
                Picker("", selection: $tool) {
                    Text(store.tr("Control")).tag(MapTool.control)
                    Text(store.tr("Edit")).tag(MapTool.edit)
                    Text(store.tr("Wire")).tag(MapTool.wire)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: isCompact ? 156 : 184)

                // Add Room / Zone / Furniture
                Button {
                    let c = visibleWorldCenter()
                    store.addFloorplanBox(
                        kind: "room",
                        name: store.tr("New Room"),
                        archetype: "other",
                        at: c.x - 160,
                        y: c.y - 120
                    )
                    tool = .edit
                } label: {
                    Label(store.tr("Room"), systemImage: "plus.rectangle")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(store.tr("Add Room"))

                Button {
                    let c = visibleWorldCenter()
                    store.addFloorplanBox(
                        kind: "zone",
                        name: store.tr("New Zone"),
                        archetype: "other",
                        at: c.x - 170,
                        y: c.y - 100
                    )
                    tool = .edit
                } label: {
                    Label(store.tr("Zone"), systemImage: "plus.square.dashed")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(store.tr("Add Zone"))

                Menu {
                    ForEach(FloorplanStamp.allKinds, id: \.self) { kind in
                        Button {
                            let c = visibleWorldCenter()
                            store.addStamp(kind: kind, at: c.x - 60, y: c.y - 30)
                            store.floorplan.showFurniture = true
                            store.persistFloorplan()
                            tool = .edit
                        } label: {
                            Label(stampLabel(for: kind), systemImage: stampSymbol(for: kind))
                        }
                    }
                } label: {
                    Label(store.tr("Furniture"), systemImage: "sofa")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .help(store.tr("Add Furniture"))

                // Custom Floorplan Background Image popover
                Button {
                    showBackgroundPopover.toggle()
                } label: {
                    Label(store.tr("Background"), systemImage: store.floorplanBackgroundImage == nil ? "photo" : "photo.fill")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showBackgroundPopover, arrowEdge: .bottom) {
                    backgroundPopover
                }

                // Layers & Auto-sync menu
                Menu {
                    Toggle(store.tr("Show grid"), isOn: $showGrid)
                    Toggle(store.tr("Snap to grid"), isOn: Binding(
                        get: { store.floorplan.canvas.snap },
                        set: { store.floorplan.canvas.snap = $0; store.persistFloorplan() }
                    ))
                    Toggle(store.tr("Show wires"), isOn: Binding(
                        get: { store.floorplan.showWires },
                        set: { store.floorplan.showWires = $0; store.persistFloorplan() }
                    ))
                    Toggle(store.tr("Light glows"), isOn: Binding(
                        get: { store.floorplan.showGlows },
                        set: { store.floorplan.showGlows = $0; store.persistFloorplan() }
                    ))
                    Toggle(store.tr("Show furniture"), isOn: Binding(
                        get: { store.floorplan.showFurniture },
                        set: { store.floorplan.showFurniture = $0; store.persistFloorplan() }
                    ))
                    Toggle(store.tr("Synth overlay"), isOn: $showSynthOverlay)
                    Divider()
                    Toggle(store.tr("Auto-sync to Bridge"), isOn: Binding(
                        get: { store.floorplan.autoSync },
                        set: { store.setFloorplanAutoSync($0) }
                    ))
                } label: {
                    Label(store.tr("Layers"), systemImage: "square.3.layers.3d")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)

                // 1-click Sync All to Bridge
                let pending = store.pendingFloorplanSyncPlan
                Button {
                    store.syncAllFloorplanToBridge()
                } label: {
                    HStack(spacing: 4) {
                        if store.floorplanSyncing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(store.tr("Sync All"))
                            .font(store.scaledFont(11, weight: .semibold))
                        if pending.totalChanges > 0 {
                            Text("\(pending.totalChanges)")
                                .font(store.scaledFont(9.5, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.28)))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(pending.hasRoomOrMetaChanges ? store.skinAccentColor : Color.secondary.opacity(0.5))
                .controlSize(.small)
                .disabled(store.floorplanSyncing)
                .help(store.tr("Sync All to Bridge"))

                // Zoom controls
                HStack(spacing: 2) {
                    Button { adjustZoom(by: -0.15) } label: {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        fitCanvasToContent()
                    } label: {
                        Text(store.tr("Fit"))
                            .font(store.scaledFont(10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button { adjustZoom(by: 0.15) } label: {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isCompact {
                    Button {
                        openWindow(id: "main-window")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(store.tr("Open in window"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Custom Floorplan Background Popover

    private var backgroundPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.tr("Floorplan Background"))
                    .font(store.scaledFont(12.5, weight: .semibold))
                Spacer()
                if store.floorplan.background.fileName != nil {
                    Button(role: .destructive) {
                        store.clearFloorplanBackground()
                    } label: {
                        Text(store.tr("Clear"))
                            .font(store.scaledFont(11))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button {
                chooseBackgroundImagePanel()
            } label: {
                Label(store.tr("Choose Image…"), systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if let err = store.floorplanBackgroundError {
                Text(err)
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.floorplanBackgroundImage != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(store.tr("Opacity"))
                            .font(store.scaledFont(11, weight: .medium))
                        Spacer()
                        Text("\(Int((store.floorplan.background.opacity * 100).rounded()))%")
                            .font(store.scaledFont(11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { store.floorplan.background.opacity },
                            set: { store.setFloorplanBackgroundOpacity($0) }
                        ),
                        in: FloorplanBackground.minOpacity...FloorplanBackground.maxOpacity
                    )
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.tr("Scaling"))
                        .font(store.scaledFont(11, weight: .medium))
                    Picker("", selection: Binding(
                        get: { store.floorplan.background.fit },
                        set: { store.setFloorplanBackgroundFit($0) }
                    )) {
                        Text(store.tr("Contain")).tag(BackgroundFit.contain)
                        Text(store.tr("Cover")).tag(BackgroundFit.cover)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
            } else {
                Text(store.tr("Place a PNG, JPEG, HEIC, or WebP floorplan behind your rooms and lamps."))
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 260)
        .fontDesign(store.fontDesign)
    }

    private func chooseBackgroundImagePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.png, .jpeg, .heic]
        if let webp = UTType(filenameExtension: "webp") {
            types.append(webp)
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            store.setFloorplanBackground(from: url)
        }
    }

    // MARK: - Sync Banner & Toast

    @ViewBuilder
    private var syncBannerIfNeeded: some View {
        let plan = store.pendingFloorplanSyncPlan
        let sig = store.floorplanDiffSignature
        if plan.hasRoomOrMetaChanges && !store.floorplan.autoSync && store.dismissedFloorplanDiffKey != sig {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(store.skinAccentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.trf("{0} floorplan change(s) ready to sync to Hue Bridge.", [String(plan.totalChanges)]))
                        .font(store.scaledFont(11, weight: .medium))
                    let multiFixture = plan.membershipDiffs.filter { !$0.sharedDeviceLightNames.isEmpty }
                    if !multiFixture.isEmpty {
                        Text(store.tr("Note: multi-bulb fixtures move together on the Hue Bridge."))
                            .font(store.scaledFont(10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button(store.tr("Sync All to Bridge")) {
                    store.syncAllFloorplanToBridge()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.floorplanSyncing)

                Button(store.tr("Keep visual only")) {
                    store.dismissedFloorplanDiffKey = sig
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(store.skinAccentColor.opacity(0.11))
            Divider()
        }
    }

    @ViewBuilder
    private var statusToastIfNeeded: some View {
        if let status = store.floorplanStatusMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text(status)
                    .font(store.scaledFont(11, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.10))
            Divider()
        }
    }

    // MARK: - Collapsible Left Lamp Sidebar

    private var filteredSidebarLights: [HueLight] {
        let query = lampSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.snapshot.allLights.filter { light in
            if sidebarFilter == .unplaced && store.floorplan.lamps[light.id] != nil {
                return false
            }
            if !query.isEmpty {
                return light.name.lowercased().contains(query)
            }
            return true
        }
    }

    private var lampSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(store.tr("Search lamps"), text: $lampSearch)
                        .textFieldStyle(.plain)
                        .font(store.scaledFont(11.5))
                    if !lampSearch.isEmpty {
                        Button { lampSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous).fill(Color.primary.opacity(0.06)))

                Picker("", selection: $sidebarFilter) {
                    Text(store.tr("All")).tag(SidebarFilter.all)
                    Text(store.tr("Unplaced")).tag(SidebarFilter.unplaced)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    let list = filteredSidebarLights
                    if list.isEmpty {
                        Text(sidebarFilter == .unplaced ? store.tr("All lamps placed.") : store.tr("No lamps match."))
                            .font(store.scaledFont(11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    } else {
                        ForEach(list) { light in
                            let placed = store.floorplan.lamps[light.id] != nil
                            sidebarLampRow(light: light, placed: placed)
                        }
                    }
                }
                .padding(6)
            }

            Divider()
            wireLegendFooter
                .padding(8)
        }
        .background(Color.primary.opacity(0.02))
    }

    private func sidebarLampRow(light: HueLight, placed: Bool) -> some View {
        let chosenIcon = store.floorplan.lamps[light.id]?.icon ?? LampIcon.inferred(for: light.name)
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(light.on ? Color(hex: light.color) : Color.primary.opacity(0.14))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.6))
                    .shadow(color: light.on ? Color(hex: light.color).opacity(0.55) : .clear, radius: 4)
                    .frame(width: 20, height: 20)
                Image(systemName: chosenIcon.sfSymbol(lit: light.on))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(light.on ? (prefersDarkGlyph(light.color) ? Color.black : Color.white) : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(light.name)
                    .font(store.scaledFont(11, weight: selectedLightID == light.id ? .semibold : .regular))
                    .lineLimit(1)
                Text(light.on ? "\(Int(light.bri.rounded()))%" : store.tr("Off"))
                    .font(store.scaledFont(9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            if placed {
                Button {
                    store.unplaceLamp(light.id)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(store.tr("Remove from map"))
            } else {
                Button {
                    placeLampSmartly(light)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(store.skinAccentColor)
                }
                .buttonStyle(.borderless)
                .help(store.tr("Place on map"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .fill(selectedLightID == light.id ? store.skinAccentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let placement = store.floorplan.lamps[light.id] {
                selectedLightID = light.id
                centerViewport(onWorld: CGPoint(x: placement.x, y: placement.y))
            } else {
                placeLampSmartly(light)
            }
        }
    }

    private func placeLampSmartly(_ light: HueLight) {
        // Drop inside its matching Bridge room box if present, else visible canvas center
        if let ownerRoom = store.snapshot.rooms.first(where: { $0.kind == "room" && $0.lights.contains(where: { $0.id == light.id }) }),
           let box = store.floorplan.boxes.first(where: { $0.hueID == ownerRoom.hueID }) {
            let offset = Double((store.floorplan.lamps.count % 5) - 2) * 28.0
            store.placeLamp(light.id, at: box.centerX + offset, y: box.centerY + 12)
            selectedLightID = light.id
            centerViewport(onWorld: CGPoint(x: box.centerX, y: box.centerY))
        } else {
            let c = visibleWorldCenter()
            store.placeLamp(light.id, at: c.x, y: c.y)
            selectedLightID = light.id
        }
    }

    private var wireLegendFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.tr("Wire Legend").uppercased())
                .font(store.scaledFont(9, weight: .semibold))
                .foregroundStyle(.secondary)
            legendItem(color: Color(hex: "#38d9c0"), dashed: false, dotted: false, label: store.tr("Follow / Mirror"))
            legendItem(color: Color(hex: "#ff5a6e"), dashed: true, dotted: false, label: store.tr("Exclusive"))
            legendItem(color: Color(hex: "#ffb84d"), dashed: false, dotted: true, label: store.tr("Companion"))
            legendItem(color: Color(hex: "#d946ef"), dashed: false, dotted: false, label: store.tr("Synth"))
        }
    }

    private func legendItem(color: Color, dashed: Bool, dotted: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Canvas { ctx, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                let dash: [CGFloat] = dashed ? [5, 3] : (dotted ? [2, 3] : [])
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            }
            .frame(width: 22, height: 8)
            Text(label)
                .font(store.scaledFont(9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Main Interactive 2D Canvas

    private var zoom: CGFloat { CGFloat(store.floorplan.canvas.zoom) }
    private var pan: CGPoint { CGPoint(x: store.floorplan.canvas.panX, y: store.floorplan.canvas.panY) }

    private func worldToScreen(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x * zoom + pan.x, y: pt.y * zoom + pan.y)
    }

    private func screenToWorld(_ pt: CGPoint) -> CGPoint {
        let z = max(0.2, zoom)
        return CGPoint(x: (pt.x - pan.x) / z, y: (pt.y - pan.y) / z)
    }

    private var canvasWorkspace: some View {
        GeometryReader { geo in
            let animatePulse = Date().timeIntervalSince(store.lastFiredRuleAt) < 2.0 || store.synthRunning
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animatePulse)) { timeline in
                ZStack(alignment: .topLeading) {
                    // 0. Backdrop & Optional Custom Floorplan Background Image
                    Rectangle()
                        .fill(Color.primary.opacity(0.03))
                        .contentShape(Rectangle())
                        .gesture(canvasPanGesture)
                        .onTapGesture {
                            selectedBoxID = nil
                            selectedLightID = nil
                            selectedStampID = nil
                        }

                    if let bgImage = store.floorplanBackgroundImage {
                        let bg = store.floorplan.background
                        let w = CGFloat(store.floorplan.canvas.width) * zoom
                        let h = CGFloat(store.floorplan.canvas.height) * zoom
                        Image(nsImage: bgImage)
                            .resizable()
                            .aspectRatio(contentMode: bg.fit == .cover ? .fill : .fit)
                            .frame(width: w, height: h)
                            .clipped()
                            .opacity(bg.opacity)
                            .position(x: pan.x + w / 2, y: pan.y + h / 2)
                            .allowsHitTesting(false)
                    }

                    // 1. GPU Canvas: Grid, Minimalist Furniture Stamps, Radial Light Halos, Bezier Dependency Wires
                    Canvas { ctx, size in
                        drawGrid(in: &ctx, size: size)
                        if store.floorplan.showFurniture {
                            drawFurnitureStamps(in: &ctx)
                        }
                        if store.floorplan.showGlows {
                            drawLightHalos(in: &ctx)
                        }
                        if store.floorplan.showWires {
                            drawDependencyWires(in: &ctx, now: timeline.date)
                        }
                        if showSynthOverlay || store.synthRunning {
                            drawSynthOverlay(in: &ctx, now: timeline.date)
                        }
                        if let src = wireDraftSource, let dstWorld = wireDraftWorldPoint,
                           let srcWorld = worldAnchor(for: src) {
                            drawWireDraft(in: &ctx, from: worldToScreen(srcWorld), to: worldToScreen(dstWorld))
                        }
                    }
                    .allowsHitTesting(false)

                    // 2. Interactive Furniture Stamp Handles (Edit mode)
                    if tool == .edit && store.floorplan.showFurniture {
                        ForEach(store.floorplan.stamps) { stamp in
                            stampEditOverlay(stamp)
                        }
                    }

                    // 3. Resizable & Movable Room / Zone Boxes
                    ForEach(store.floorplan.boxes) { box in
                        roomBoxLayer(box)
                    }

                    // 4. Interactive Lamp Nodes
                    ForEach(placedLights) { light in
                        if let placement = store.floorplan.lamps[light.id] {
                            lampNodeLayer(light: light, placement: placement)
                        }
                    }

                    // 5. Clickable Wire Midpoint Pills
                    if store.floorplan.showWires {
                        ForEach(visibleWireBadges) { badge in
                            wireMidpointPill(badge)
                        }
                    }

                    // Mode hint pill at bottom-right
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            modeHintPill
                                .padding(10)
                        }
                    }
                }
            }
            .coordinateSpace(name: "floorplanCanvas")
            .clipped()
            .onAppear {
                canvasViewportSize = geo.size
                if !didInitialFit {
                    didInitialFit = true
                    fitCanvasToContent(in: geo.size)
                }
            }
            .onChange(of: geo.size) { newSize in
                canvasViewportSize = newSize
            }
        }
    }

    private var placedLights: [HueLight] {
        store.snapshot.allLights.filter { store.floorplan.lamps[$0.id] != nil }
    }

    private var modeHintPill: some View {
        let text: String = {
            switch tool {
            case .control: return store.tr("Control: click lamps to toggle · drag empty space to pan")
            case .edit: return store.tr("Edit: drag lamps, rooms & resize handles · click to rename")
            case .wire: return store.tr("Wire: drag from ● connector to another lamp or room")
            }
        }()
        return Text(text)
            .font(store.scaledFont(10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .allowsHitTesting(false)
    }

    private var canvasPanGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil {
                    panStart = CGPoint(x: store.floorplan.canvas.panX, y: store.floorplan.canvas.panY)
                }
                if let start = panStart {
                    store.floorplan.canvas.panX = Double(start.x + value.translation.width)
                    store.floorplan.canvas.panY = Double(start.y + value.translation.height)
                }
            }
            .onEnded { _ in
                panStart = nil
                store.persistFloorplan()
            }
    }

    // MARK: - Canvas Drawing: Grid, Stamps, Halos, Wires

    private func drawGrid(in ctx: inout GraphicsContext, size: CGSize) {
        guard showGrid else { return }
        let step = max(12.0, CGFloat(store.floorplan.canvas.grid) * zoom)
        let majorStep = step * 5.0

        let startX = pan.x.truncatingRemainder(dividingBy: step)
        let startY = pan.y.truncatingRemainder(dividingBy: step)

        var minorPath = Path()
        var x = startX
        while x < size.width {
            if x >= 0 {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
            }
            x += step
        }
        var y = startY
        while y < size.height {
            if y >= 0 {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
            }
            y += step
        }
        ctx.stroke(minorPath, with: .color(Color.primary.opacity(0.05)), lineWidth: 0.5)

        var majorPath = Path()
        var mx = pan.x.truncatingRemainder(dividingBy: majorStep)
        while mx < size.width {
            if mx >= 0 {
                majorPath.move(to: CGPoint(x: mx, y: 0))
                majorPath.addLine(to: CGPoint(x: mx, y: size.height))
            }
            mx += majorStep
        }
        var my = pan.y.truncatingRemainder(dividingBy: majorStep)
        while my < size.height {
            if my >= 0 {
                majorPath.move(to: CGPoint(x: 0, y: my))
                majorPath.addLine(to: CGPoint(x: size.width, y: my))
            }
            my += majorStep
        }
        ctx.stroke(majorPath, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.75)
    }

    private func drawFurnitureStamps(in ctx: inout GraphicsContext) {
        let strokeColor = Color.primary.opacity(0.28)
        let fillColor = Color.primary.opacity(0.06)

        for stamp in store.floorplan.stamps {
            let center = worldToScreen(CGPoint(x: stamp.x + stamp.width / 2, y: stamp.y + stamp.height / 2))
            let w = CGFloat(stamp.width) * zoom
            let h = CGFloat(stamp.height) * zoom

            var local = ctx
            local.translateBy(x: center.x, y: center.y)
            local.rotate(by: .degrees(Double(stamp.rotation)))
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

            switch stamp.kind {
            case "door":
                var leaf = Path()
                leaf.move(to: CGPoint(x: rect.minX, y: rect.minY))
                leaf.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                local.stroke(leaf, with: .color(strokeColor), lineWidth: 2)
                var arc = Path()
                arc.addArc(
                    center: CGPoint(x: rect.minX, y: rect.minY),
                    radius: min(w, h),
                    startAngle: .degrees(0),
                    endAngle: .degrees(90),
                    clockwise: false
                )
                local.stroke(arc, with: .color(strokeColor), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

            case "window":
                let frame = Path(rect)
                local.fill(frame, with: .color(Color.cyan.opacity(0.16)))
                local.stroke(frame, with: .color(strokeColor), lineWidth: 1.4)
                var mid = Path()
                mid.move(to: CGPoint(x: rect.minX, y: 0))
                mid.addLine(to: CGPoint(x: rect.maxX, y: 0))
                local.stroke(mid, with: .color(strokeColor), lineWidth: 1)

            case "sofa":
                let body = Path(roundedRect: rect, cornerRadius: max(4, min(w, h) * 0.16))
                local.fill(body, with: .color(fillColor))
                local.stroke(body, with: .color(strokeColor), lineWidth: 1.3)
                let backH = h * 0.28
                let back = Path(roundedRect: CGRect(x: rect.minX + 2, y: rect.minY + 2, width: w - 4, height: backH), cornerRadius: 3)
                local.stroke(back, with: .color(strokeColor), lineWidth: 1)
                var seam = Path()
                seam.move(to: CGPoint(x: 0, y: rect.minY + backH + 2))
                seam.addLine(to: CGPoint(x: 0, y: rect.maxY - 2))
                local.stroke(seam, with: .color(strokeColor.opacity(0.7)), lineWidth: 1)

            case "tv":
                let bezel = Path(roundedRect: rect, cornerRadius: 3)
                local.fill(bezel, with: .color(Color.primary.opacity(0.18)))
                local.stroke(bezel, with: .color(strokeColor), lineWidth: 1.4)

            case "desk":
                let top = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.62), cornerRadius: 4)
                local.fill(top, with: .color(fillColor))
                local.stroke(top, with: .color(strokeColor), lineWidth: 1.3)
                let chairR = min(w * 0.18, h * 0.22)
                let chair = Path(ellipseIn: CGRect(x: -chairR, y: rect.minY + h * 0.68, width: chairR * 2, height: chairR * 1.4))
                local.stroke(chair, with: .color(strokeColor), lineWidth: 1.2)

            case "bed":
                let frame = Path(roundedRect: rect, cornerRadius: 5)
                local.fill(frame, with: .color(fillColor))
                local.stroke(frame, with: .color(strokeColor), lineWidth: 1.3)
                let pW = (w - 18) / 2
                let pH = h * 0.18
                let p1 = Path(roundedRect: CGRect(x: rect.minX + 6, y: rect.minY + 6, width: pW, height: pH), cornerRadius: 3)
                let p2 = Path(roundedRect: CGRect(x: rect.minX + 12 + pW, y: rect.minY + 6, width: pW, height: pH), cornerRadius: 3)
                local.stroke(p1, with: .color(strokeColor), lineWidth: 1)
                local.stroke(p2, with: .color(strokeColor), lineWidth: 1)
                var duvet = Path()
                duvet.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.34))
                duvet.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.34))
                local.stroke(duvet, with: .color(strokeColor), lineWidth: 1)

            case "dining":
                let table = Path(roundedRect: rect.insetBy(dx: w * 0.12, dy: h * 0.15), cornerRadius: 5)
                local.fill(table, with: .color(fillColor))
                local.stroke(table, with: .color(strokeColor), lineWidth: 1.3)
                let cSize = max(6, min(w, h) * 0.14)
                let spots = [
                    CGPoint(x: -w * 0.22, y: rect.minY + cSize * 0.4),
                    CGPoint(x: w * 0.22, y: rect.minY + cSize * 0.4),
                    CGPoint(x: -w * 0.22, y: rect.maxY - cSize * 0.4),
                    CGPoint(x: w * 0.22, y: rect.maxY - cSize * 0.4),
                ]
                for pt in spots {
                    let c = Path(roundedRect: CGRect(x: pt.x - cSize / 2, y: pt.y - cSize / 3, width: cSize, height: cSize * 0.66), cornerRadius: 2)
                    local.stroke(c, with: .color(strokeColor), lineWidth: 1)
                }

            case "kitchen":
                let counter = Path(roundedRect: rect, cornerRadius: 3)
                local.fill(counter, with: .color(fillColor))
                local.stroke(counter, with: .color(strokeColor), lineWidth: 1.3)
                // Sink basin
                let sink = Path(roundedRect: CGRect(x: rect.minX + w * 0.10, y: rect.minY + h * 0.20, width: w * 0.24, height: h * 0.60), cornerRadius: 3)
                local.stroke(sink, with: .color(strokeColor), lineWidth: 1)
                // 4 hob burners
                let r = min(w * 0.06, h * 0.16)
                for bx in [0.62, 0.78] {
                    for by in [0.34, 0.68] {
                        let burner = Path(ellipseIn: CGRect(x: rect.minX + w * bx - r, y: rect.minY + h * by - r, width: r * 2, height: r * 2))
                        local.stroke(burner, with: .color(strokeColor), lineWidth: 1)
                    }
                }

            default:
                let box = Path(roundedRect: rect, cornerRadius: 4)
                local.stroke(box, with: .color(strokeColor), lineWidth: 1.2)
            }
        }
    }

    private func drawLightHalos(in ctx: inout GraphicsContext) {
        for light in placedLights where light.on {
            guard let placement = store.floorplan.lamps[light.id] else { continue }
            let center = worldToScreen(CGPoint(x: placement.x, y: placement.y))
            let briFactor = max(0.18, min(1.0, light.bri / 100.0))
            let radius = CGFloat(48.0 + light.bri * 0.85) * zoom
            let base = Color(hex: light.color)
            let gradient = Gradient(stops: [
                .init(color: base.opacity(0.42 * briFactor), location: 0.0),
                .init(color: base.opacity(0.16 * briFactor), location: 0.45),
                .init(color: base.opacity(0.0), location: 1.0),
            ])
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(gradient, center: center, startRadius: 4, endRadius: radius)
            )
        }
    }

    private func worldAnchor(for endpoint: WireEndpoint) -> CGPoint? {
        if endpoint.kind == "light", let p = store.floorplan.lamps[endpoint.id] {
            return CGPoint(x: p.x, y: p.y)
        }
        if endpoint.kind == "room",
           let box = store.floorplan.boxes.first(where: { $0.hueID == endpoint.id || $0.id == endpoint.id }) {
            return CGPoint(x: box.centerX, y: box.minY + 18)
        }
        return nil
    }

    private func cubicControlPoints(from p0: CGPoint, to p1: CGPoint) -> (CGPoint, CGPoint) {
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let bend = max(42.0, min(180.0, hypot(dx, dy) * 0.35))
        let c1 = CGPoint(x: p0.x + (dx >= 0 ? bend : -bend * 0.5), y: p0.y + dy * 0.15)
        let c2 = CGPoint(x: p1.x - (dx >= 0 ? bend : -bend * 0.5), y: p1.y - dy * 0.15)
        return (c1, c2)
    }

    private func evalCubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * mt * p0.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p1.x
        let y = mt * mt * mt * p0.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p1.y
        return CGPoint(x: x, y: y)
    }

    private func drawDependencyWires(in ctx: inout GraphicsContext, now: Date) {
        let cycleNodes = Set(RuleEngine.detectCycles(store.rules).flatMap { $0 })

        for rule in store.rules {
            let srcEndpoint = WireEndpoint(kind: rule.triggerKind, id: rule.triggerID)
            guard let srcWorld = worldAnchor(for: srcEndpoint) else { continue }
            let p0 = worldToScreen(srcWorld)

            for target in rule.targets {
                let dstEndpoint = WireEndpoint(kind: target.kind, id: target.id)
                guard let dstWorld = worldAnchor(for: dstEndpoint) else { continue }
                let p1 = worldToScreen(dstWorld)
                let (c1, c2) = cubicControlPoints(from: p0, to: p1)

                var path = Path()
                path.move(to: p0)
                path.addCurve(to: p1, control1: c1, control2: c2)

                let inCycle = cycleNodes.contains("\(rule.triggerKind):\(rule.triggerID)")
                    && cycleNodes.contains("\(target.kind):\(target.id)")

                let baseColor: Color
                let dash: [CGFloat]
                if inCycle {
                    baseColor = Color(hex: "#ef4444")
                    dash = [9, 5]
                } else {
                    switch rule.kind {
                    case "exclusive":
                        baseColor = Color(hex: "#ff5a6e")
                        dash = [8, 5]
                    case "companion":
                        baseColor = Color(hex: "#ffb84d")
                        dash = [2, 5]
                    default:
                        baseColor = Color(hex: "#38d9c0")
                        dash = []
                    }
                }

                let activeOpacity: Double = (rule.enabled && !store.rulesPaused) ? 0.92 : 0.30
                let lineWidth: CGFloat = inCycle ? 3.2 : 2.5
                ctx.stroke(
                    path,
                    with: .color(baseColor.opacity(activeOpacity)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash)
                )

                // Endcap near target (t = 0.88 so it sits cleanly outside the lamp node)
                let tip = evalCubic(p0, c1, c2, p1, t: 0.88)
                let beforeTip = evalCubic(p0, c1, c2, p1, t: 0.82)
                let angle = atan2(tip.y - beforeTip.y, tip.x - beforeTip.x)

                if rule.kind == "exclusive" {
                    // Blunt T-bar ┤
                    let perp = angle + .pi / 2
                    var tbar = Path()
                    tbar.move(to: CGPoint(x: tip.x + cos(perp) * 7, y: tip.y + sin(perp) * 7))
                    tbar.addLine(to: CGPoint(x: tip.x - cos(perp) * 7, y: tip.y - sin(perp) * 7))
                    ctx.stroke(tbar, with: .color(baseColor.opacity(activeOpacity)), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
                } else if rule.kind == "companion" {
                    // Hollow diamond ◇
                    var diamond = Path()
                    let r: CGFloat = 6
                    diamond.move(to: CGPoint(x: tip.x + cos(angle) * r, y: tip.y + sin(angle) * r))
                    diamond.addLine(to: CGPoint(x: tip.x + cos(angle + .pi / 2) * r * 0.75, y: tip.y + sin(angle + .pi / 2) * r * 0.75))
                    diamond.addLine(to: CGPoint(x: tip.x - cos(angle) * r, y: tip.y - sin(angle) * r))
                    diamond.addLine(to: CGPoint(x: tip.x + cos(angle - .pi / 2) * r * 0.75, y: tip.y + sin(angle - .pi / 2) * r * 0.75))
                    diamond.closeSubpath()
                    ctx.stroke(diamond, with: .color(baseColor.opacity(activeOpacity)), lineWidth: 2.0)
                } else {
                    // Solid arrowhead ▶
                    drawArrowhead(in: &ctx, at: tip, angle: angle, color: baseColor.opacity(activeOpacity))
                    if rule.mirrorOff {
                        let revTip = evalCubic(p0, c1, c2, p1, t: 0.12)
                        let revPrev = evalCubic(p0, c1, c2, p1, t: 0.18)
                        let revAngle = atan2(revTip.y - revPrev.y, revTip.x - revPrev.x)
                        drawArrowhead(in: &ctx, at: revTip, angle: revAngle, color: baseColor.opacity(activeOpacity))
                    }
                }

                // Live firing pulse dot traveling along the wire
                if store.lastFiredRuleID == rule.id {
                    let elapsed = now.timeIntervalSince(store.lastFiredRuleAt)
                    if elapsed >= 0 && elapsed <= 1.6 {
                        let t = CGFloat(min(1.0, elapsed / 1.4))
                        let dot = evalCubic(p0, c1, c2, p1, t: t)
                        let halo = CGRect(x: dot.x - 10, y: dot.y - 10, width: 20, height: 20)
                        ctx.fill(Path(ellipseIn: halo), with: .color(baseColor.opacity(0.35)))
                        let core = CGRect(x: dot.x - 4.5, y: dot.y - 4.5, width: 9, height: 9)
                        ctx.fill(Path(ellipseIn: core), with: .color(Color.white))
                    }
                }
            }
        }
    }

    private func drawArrowhead(in ctx: inout GraphicsContext, at tip: CGPoint, angle: CGFloat, color: Color) {
        let len: CGFloat = 9
        let spread: CGFloat = 0.48
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread)))
        arrow.addLine(to: CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread)))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(color))
    }

    private func drawSynthOverlay(in ctx: inout GraphicsContext, now: Date) {
        let targets = store.synthTargetLights.filter { store.floorplan.lamps[$0.id] != nil }
        guard targets.count >= 1 else { return }
        let hubScreen = CGPoint(x: canvasViewportSize.width * 0.5, y: 24)
        let magenta = Color(hex: "#d946ef")
        let pulse = CGFloat(0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 4.0))

        for light in targets {
            guard let p = store.floorplan.lamps[light.id] else { continue }
            let dst = worldToScreen(CGPoint(x: p.x, y: p.y))
            let (c1, c2) = cubicControlPoints(from: hubScreen, to: dst)
            var path = Path()
            path.move(to: hubScreen)
            path.addCurve(to: dst, control1: c1, control2: c2)
            ctx.stroke(path, with: .color(magenta.opacity(0.22 + 0.25 * Double(pulse))), lineWidth: 5.5)
            ctx.stroke(path, with: .color(magenta.opacity(0.88)), style: StrokeStyle(lineWidth: 1.8, dash: [6, 4]))
        }
    }

    private func drawWireDraft(in ctx: inout GraphicsContext, from p0: CGPoint, to p1: CGPoint) {
        let (c1, c2) = cubicControlPoints(from: p0, to: p1)
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p1, control1: c1, control2: c2)
        ctx.stroke(
            path,
            with: .color(store.skinAccentColor),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4])
        )
    }

    // MARK: - Wire Midpoint Badges (Clickable to Inspect/Edit/Delete)

    private struct WireBadgeItem: Identifiable {
        let id: String
        let rule: HueRule
        let screenPosition: CGPoint
        let glyph: String
        let color: Color
    }

    private var visibleWireBadges: [WireBadgeItem] {
        let cycleNodes = Set(RuleEngine.detectCycles(store.rules).flatMap { $0 })
        var items: [WireBadgeItem] = []
        for rule in store.rules {
            guard let srcWorld = worldAnchor(for: WireEndpoint(kind: rule.triggerKind, id: rule.triggerID)) else { continue }
            let p0 = worldToScreen(srcWorld)
            for (idx, target) in rule.targets.enumerated() {
                guard let dstWorld = worldAnchor(for: WireEndpoint(kind: target.kind, id: target.id)) else { continue }
                let p1 = worldToScreen(dstWorld)
                let (c1, c2) = cubicControlPoints(from: p0, to: p1)
                let mid = evalCubic(p0, c1, c2, p1, t: 0.5)

                let inCycle = cycleNodes.contains("\(rule.triggerKind):\(rule.triggerID)")
                    && cycleNodes.contains("\(target.kind):\(target.id)")
                let glyph: String
                let color: Color
                if inCycle {
                    glyph = "⚠"
                    color = Color(hex: "#ef4444")
                } else if rule.kind == "exclusive" {
                    glyph = "⊘"
                    color = Color(hex: "#ff5a6e")
                } else if rule.kind == "companion" {
                    glyph = rule.timeStart.isEmpty ? "◇" : "◇⏱"
                    color = Color(hex: "#ffb84d")
                } else {
                    var g = rule.mirrorOff ? "◀▶" : "▶"
                    if rule.matchBri { g += "☀" }
                    glyph = g
                    color = Color(hex: "#38d9c0")
                }

                items.append(WireBadgeItem(
                    id: "\(rule.id)-\(idx)",
                    rule: rule,
                    screenPosition: mid,
                    glyph: glyph,
                    color: color
                ))
            }
        }
        return items
    }

    private func wireMidpointPill(_ item: WireBadgeItem) -> some View {
        Button {
            inspectedRuleID = item.rule.id
        } label: {
            Text(item.glyph)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(item.color.opacity(item.rule.enabled ? 0.92 : 0.45)))
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .position(item.screenPosition)
        .popover(isPresented: Binding(
            get: { inspectedRuleID == item.rule.id },
            set: { if !$0 && inspectedRuleID == item.rule.id { inspectedRuleID = nil } }
        )) {
            WireRuleInspectorPopover(rule: item.rule) {
                inspectedRuleID = nil
            }
            .environmentObject(store)
        }
    }

    // MARK: - Interactive Furniture Stamp Overlay (Edit Mode)

    private func stampEditOverlay(_ stamp: FloorplanStamp) -> some View {
        let center = worldToScreen(CGPoint(x: stamp.x + stamp.width / 2, y: stamp.y + stamp.height / 2))
        let w = max(32, CGFloat(stamp.width) * zoom)
        let h = max(24, CGFloat(stamp.height) * zoom)
        let isSelected = selectedStampID == stamp.id

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isSelected ? store.skinAccentColor : Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [4, 3])
                )
                .background(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedStampID = stamp.id
                    selectedBoxID = nil
                    selectedLightID = nil
                }
                .gesture(
                    DragGesture(coordinateSpace: .named("floorplanCanvas"))
                        .onChanged { value in
                            selectedStampID = stamp.id
                            let wPt = screenToWorld(value.location)
                            store.moveStamp(id: stamp.id, to: Double(wPt.x) - stamp.width / 2, y: Double(wPt.y) - stamp.height / 2, finalize: false)
                        }
                        .onEnded { value in
                            let wPt = screenToWorld(value.location)
                            store.moveStamp(id: stamp.id, to: Double(wPt.x) - stamp.width / 2, y: Double(wPt.y) - stamp.height / 2, finalize: true)
                        }
                )

            if isSelected {
                HStack(spacing: 3) {
                    Button { store.rotateStamp(id: stamp.id) } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(4)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .help(store.tr("Rotate 90°"))

                    Button {
                        store.deleteStamp(id: stamp.id)
                        selectedStampID = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .padding(4)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .help(store.tr("Delete"))
                }
                .offset(x: 8, y: -12)
            }
        }
        .frame(width: w, height: h)
        .position(center)
    }

    // MARK: - Resizable & Movable Room / Zone Box Layer

    private func roomBoxLayer(_ box: FloorplanBox) -> some View {
        let linkedRoom = box.hueID.flatMap { hid in store.snapshot.rooms.first(where: { $0.hueID == hid }) }
        let roomSchedules = box.hueID.map { store.schedulesForRoom($0) } ?? []
        let screenOrigin = worldToScreen(CGPoint(x: box.x, y: box.y))
        let w = CGFloat(box.width) * zoom
        let h = CGFloat(box.height) * zoom
        let center = CGPoint(x: screenOrigin.x + w / 2, y: screenOrigin.y + h / 2)
        let isSelected = selectedBoxID == box.id
        let lit = linkedRoom?.on ?? false
        let tintColor = lit ? Color(hex: linkedRoom?.color ?? HueColorMath.defaultWarmHex) : Color.primary

        return FloorplanRoomBoxView(
            box: box,
            linkedRoom: linkedRoom,
            schedules: roomSchedules,
            width: w,
            height: h,
            zoom: zoom,
            tool: tool,
            isSelected: isSelected,
            tintColor: tintColor,
            lit: lit,
            onSelect: {
                selectedBoxID = box.id
                selectedLightID = nil
                selectedStampID = nil
            },
            onOpenScenes: {
                scenesBoxID = box.id
            },
            onOpenInspector: {
                inspectedBoxID = box.id
            },
            onTogglePower: {
                if let room = linkedRoom {
                    store.setRoom(room, on: !room.on)
                } else {
                    let enclosed = store.snapshot.allLights.filter { light in
                        guard let p = store.floorplan.lamps[light.id] else { return false }
                        return box.contains(x: p.x, y: p.y)
                    }
                    let anyOn = enclosed.contains(where: \.on)
                    for l in enclosed {
                        store.setLight(l, on: !anyOn)
                    }
                }
            },
            onWireDragChanged: { location in
                let endpointID = box.hueID ?? box.id
                wireDraftSource = WireEndpoint(kind: "room", id: endpointID)
                wireDraftWorldPoint = screenToWorld(location)
            },
            onWireDragEnded: { location in
                let endpointID = box.hueID ?? box.id
                finishWireDrag(from: WireEndpoint(kind: "room", id: endpointID), atScreen: location)
            },
            scenesPopoverPresented: Binding(
                get: { scenesBoxID == box.id },
                set: { if !$0 && scenesBoxID == box.id { scenesBoxID = nil } }
            ),
            inspectorPopoverPresented: Binding(
                get: { inspectedBoxID == box.id },
                set: { if !$0 && inspectedBoxID == box.id { inspectedBoxID = nil } }
            ),
            onScheduleScene: { room, scene in
                scenesBoxID = nil
                pendingSceneSchedule = PendingSceneSchedule(room: room, scene: scene)
            }
        )
        .position(center)
    }

    // MARK: - Interactive Lamp Node Layer

    private func lampNodeLayer(light: HueLight, placement: FloorplanLampPlacement) -> some View {
        let pos = worldToScreen(CGPoint(x: placement.x, y: placement.y))
        let isSelected = selectedLightID == light.id

        return FloorplanLampNodeView(
            light: light,
            placement: placement,
            zoom: zoom,
            tool: tool,
            isSelected: isSelected,
            synthBand: (showSynthOverlay || store.synthRunning) ? store.synthLightBand(for: light.id) : nil,
            inspectorPresented: Binding(
                get: { inspectedLightID == light.id },
                set: { if !$0 && inspectedLightID == light.id { inspectedLightID = nil } }
            ),
            onTap: {
                selectedLightID = light.id
                selectedBoxID = nil
                selectedStampID = nil
                if tool == .control {
                    store.setLight(light, on: !light.on)
                } else {
                    inspectedLightID = light.id
                }
            },
            onInspect: {
                selectedLightID = light.id
                inspectedLightID = light.id
            },
            onMove: { screenPoint, finalize in
                let w = screenToWorld(screenPoint)
                store.moveLamp(light.id, to: Double(w.x), y: Double(w.y), finalize: finalize)
            },
            onWireDragChanged: { screenPoint in
                wireDraftSource = WireEndpoint(kind: "light", id: light.id)
                wireDraftWorldPoint = screenToWorld(screenPoint)
            },
            onWireDragEnded: { screenPoint in
                finishWireDrag(from: WireEndpoint(kind: "light", id: light.id), atScreen: screenPoint)
            }
        )
        .position(pos)
    }

    private func finishWireDrag(from source: WireEndpoint, atScreen screenPoint: CGPoint) {
        defer {
            wireDraftSource = nil
            wireDraftWorldPoint = nil
        }
        let worldPt = screenToWorld(screenPoint)

        // 1) Check placed lamps within hit radius
        var bestLight: (id: String, dist: Double)? = nil
        for light in placedLights {
            if source.kind == "light" && source.id == light.id { continue }
            guard let p = store.floorplan.lamps[light.id] else { continue }
            let d = hypot(p.x - Double(worldPt.x), p.y - Double(worldPt.y))
            if d <= 42.0, (bestLight == nil || d < bestLight!.dist) {
                bestLight = (light.id, d)
            }
        }
        if let hit = bestLight {
            pendingWire = PendingWireCreation(source: source, target: WireEndpoint(kind: "light", id: hit.id))
            return
        }

        // 2) Check linked Room boxes containing the drop point
        if let box = FloorplanSpatial.boxContaining(x: Double(worldPt.x), y: Double(worldPt.y), in: store.floorplan.boxes, kindFilter: nil),
           let hueID = box.hueID {
            let target = WireEndpoint(kind: "room", id: hueID)
            if target != source {
                pendingWire = PendingWireCreation(source: source, target: target)
            }
        }
    }

    // MARK: - Viewport Helpers (Pan, Zoom, Fit)

    private func visibleWorldCenter() -> CGPoint {
        let viewCenter = CGPoint(x: canvasViewportSize.width / 2, y: canvasViewportSize.height / 2)
        return screenToWorld(viewCenter)
    }

    private func centerViewport(onWorld worldPt: CGPoint) {
        let z = zoom
        withAnimation(.easeInOut(duration: 0.2)) {
            store.floorplan.canvas.panX = Double(canvasViewportSize.width / 2 - worldPt.x * z)
            store.floorplan.canvas.panY = Double(canvasViewportSize.height / 2 - worldPt.y * z)
        }
        store.persistFloorplan()
    }

    private func adjustZoom(by delta: Double) {
        let centerBefore = visibleWorldCenter()
        let next = HueColorMath.clamp(store.floorplan.canvas.zoom + delta, 0.35, 2.2)
        store.floorplan.canvas.zoom = next
        store.floorplan.canvas.panX = Double(canvasViewportSize.width / 2 - centerBefore.x * CGFloat(next))
        store.floorplan.canvas.panY = Double(canvasViewportSize.height / 2 - centerBefore.y * CGFloat(next))
        store.persistFloorplan()
    }

    private func fitCanvasToContent(in sizeOverride: CGSize? = nil) {
        let viewSize = sizeOverride ?? canvasViewportSize
        guard viewSize.width > 40, viewSize.height > 40 else { return }

        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for b in store.floorplan.boxes {
            minX = min(minX, b.minX)
            minY = min(minY, b.minY)
            maxX = max(maxX, b.maxX)
            maxY = max(maxY, b.maxY)
        }
        for p in store.floorplan.lamps.values {
            minX = min(minX, p.x - 40)
            minY = min(minY, p.y - 40)
            maxX = max(maxX, p.x + 40)
            maxY = max(maxY, p.y + 40)
        }
        if !minX.isFinite {
            minX = 0; minY = 0; maxX = 900; maxY = 600
        }

        let contentW = max(200, maxX - minX)
        let contentH = max(200, maxY - minY)
        let pad: Double = 36
        let fitZoom = HueColorMath.clamp(
            min((Double(viewSize.width) - pad * 2) / contentW, (Double(viewSize.height) - pad * 2) / contentH),
            0.35,
            1.4
        )
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        store.floorplan.canvas.zoom = fitZoom
        store.floorplan.canvas.panX = Double(viewSize.width) / 2 - cx * fitZoom
        store.floorplan.canvas.panY = Double(viewSize.height) / 2 - cy * fitZoom
        store.persistFloorplan()
    }

    private func stampLabel(for kind: String) -> String {
        switch kind {
        case "door": return store.tr("Door")
        case "window": return store.tr("Window")
        case "sofa": return store.tr("Sofa")
        case "tv": return store.tr("TV Wall")
        case "desk": return store.tr("Desk")
        case "bed": return store.tr("Bed")
        case "dining": return store.tr("Dining Table")
        case "kitchen": return store.tr("Kitchen Counter")
        default: return kind.capitalized
        }
    }

    private func stampSymbol(for kind: String) -> String {
        switch kind {
        case "door": return "door.left.hand.open"
        case "window": return "window.vertical.closed"
        case "sofa": return "sofa"
        case "tv": return "tv"
        case "desk": return "desktopcomputer"
        case "bed": return "bed.double"
        case "dining": return "fork.knife"
        case "kitchen": return "flame"
        default: return "square"
        }
    }
}

// MARK: - Resizable Room / Zone Box Component

private struct FloorplanRoomBoxView: View {
    enum ResizeEdge {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    @EnvironmentObject var store: HueStore

    let box: FloorplanBox
    let linkedRoom: HueRoom?
    let schedules: [HueSchedule]
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    let tool: MapView.MapTool
    let isSelected: Bool
    let tintColor: Color
    let lit: Bool

    let onSelect: () -> Void
    let onOpenScenes: () -> Void
    let onOpenInspector: () -> Void
    let onTogglePower: () -> Void
    let onWireDragChanged: (CGPoint) -> Void
    let onWireDragEnded: (CGPoint) -> Void
    @Binding var scenesPopoverPresented: Bool
    @Binding var inspectorPopoverPresented: Bool
    let onScheduleScene: (HueRoom, HueScene) -> Void

    @State private var dragStartBox: FloorplanBox? = nil
    @State private var dragEnclosedIDs: [String] = []
    @State private var dragStartLamps: [String: (Double, Double)] = [:]

    var body: some View {
        let isZone = box.kind == "zone"
        let borderStyle = StrokeStyle(
            lineWidth: isSelected ? 2.2 : (isZone ? 1.4 : 1.8),
            dash: isZone ? [7, 4] : []
        )

        ZStack(alignment: .topLeading) {
            // Room surface fill + architectural wall outline
            RoundedRectangle(cornerRadius: isZone ? 10 : 6, style: .continuous)
                .fill(lit ? tintColor.opacity(0.11) : Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: isZone ? 10 : 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? store.skinAccentColor : (lit ? tintColor.opacity(0.55) : Color.primary.opacity(0.24)),
                            style: borderStyle
                        )
                )

            // Header bar (name, schedule badge, scenes, inspector, power)
            HStack(spacing: 4) {
                Image(systemName: boxSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(lit ? tintColor : Color.secondary)

                Text(box.name)
                    .font(store.scaledFont(11, weight: .semibold))
                    .lineLimit(1)

                if let room = linkedRoom {
                    Text("\(room.onCount)/\(room.lights.count)")
                        .font(store.scaledFont(9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let firstSched = schedules.first {
                    HStack(spacing: 2) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 8.5))
                        Text(scheduleBadgeText(firstSched))
                            .font(store.scaledFont(9, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(store.skinAccentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(store.skinAccentColor.opacity(0.15)))
                }

                Spacer(minLength: 2)

                if linkedRoom != nil {
                    Button(action: onOpenScenes) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(store.tr("Scenes & Schedule"))
                    .popover(isPresented: $scenesPopoverPresented, arrowEdge: .bottom) {
                        if let room = linkedRoom {
                            RoomScenesPopover(room: room, schedules: schedules, onScheduleScene: { scene in
                                onScheduleScene(room, scene)
                            })
                            .environmentObject(store)
                        }
                    }
                }

                Button(action: onOpenInspector) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(store.tr("Edit Room / Zone"))
                .popover(isPresented: $inspectorPopoverPresented, arrowEdge: .bottom) {
                    RoomBoxInspectorPopover(box: box) {
                        inspectorPopoverPresented = false
                    }
                    .environmentObject(store)
                }

                Button(action: onTogglePower) {
                    Image(systemName: lit ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(lit ? tintColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(lit ? store.tr("Turn off") : store.tr("Turn on"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: isZone ? 9 : 5, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .gesture(moveBoxGesture, including: tool == .edit ? .all : .none)

            // 8 Resize Handles in Edit mode
            if tool == .edit {
                resizeHandlesOverlay
            }

            // Right-edge connector port in Wire mode (for linked Bridge rooms)
            if tool == .wire && box.hueID != nil {
                Circle()
                    .fill(store.skinAccentColor)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(x: width, y: 16)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("floorplanCanvas"))
                            .onChanged { onWireDragChanged($0.location) }
                            .onEnded { onWireDragEnded($0.location) }
                    )
            }
        }
        .frame(width: max(60, width), height: max(48, height))
    }

    private var boxSymbol: String {
        if let room = linkedRoom { return roomSymbol(room) }
        let dummy = HueRoom(
            hueID: "", kind: box.kind, name: box.name, groupedLight: "",
            on: false, bri: 0, onCount: 0, archetype: box.archetype,
            color: "", lights: [], scenes: []
        )
        return roomSymbol(dummy)
    }

    private func scheduleBadgeText(_ sched: HueSchedule) -> String {
        let timeLabel: String
        switch sched.triggerKind {
        case "sunrise": timeLabel = store.tr("Sunrise")
        case "sunset": timeLabel = store.tr("Sunset")
        default: timeLabel = sched.time
        }
        if sched.action == "scene", let sName = store.sceneName(for: sched.sceneID) {
            return "\(timeLabel) · \(sName)"
        }
        return timeLabel
    }

    private var moveBoxGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartBox == nil {
                    onSelect()
                    dragStartBox = box
                    dragEnclosedIDs = store.floorplan.lamps.compactMap { lid, p in
                        box.contains(x: p.x, y: p.y) ? lid : nil
                    }
                    var starts: [String: (Double, Double)] = [:]
                    for lid in dragEnclosedIDs {
                        if let p = store.floorplan.lamps[lid] { starts[lid] = (p.x, p.y) }
                    }
                    dragStartLamps = starts
                }
                guard let orig = dragStartBox else { return }
                let dx = Double(value.translation.width / max(0.2, zoom))
                let dy = Double(value.translation.height / max(0.2, zoom))
                var next = orig
                next.x = orig.x + dx
                next.y = orig.y + dy
                if let idx = store.floorplan.boxes.firstIndex(where: { $0.id == box.id }) {
                    store.floorplan.boxes[idx] = next
                }
                for (lid, startPos) in dragStartLamps {
                    if var lamp = store.floorplan.lamps[lid] {
                        lamp.x = startPos.0 + dx
                        lamp.y = startPos.1 + dy
                        store.floorplan.lamps[lid] = lamp
                    }
                }
            }
            .onEnded { value in
                guard let orig = dragStartBox else { return }
                let dx = Double(value.translation.width / max(0.2, zoom))
                let dy = Double(value.translation.height / max(0.2, zoom))
                var next = orig
                next.x = store.floorplan.snapped(orig.x + dx)
                next.y = store.floorplan.snapped(orig.y + dy)
                let snappedDX = next.x - orig.x
                let snappedDY = next.y - orig.y
                if let idx = store.floorplan.boxes.firstIndex(where: { $0.id == box.id }) {
                    store.floorplan.boxes[idx] = next
                }
                for (lid, startPos) in dragStartLamps {
                    if var lamp = store.floorplan.lamps[lid] {
                        lamp.x = startPos.0 + snappedDX
                        lamp.y = startPos.1 + snappedDY
                        store.floorplan.lamps[lid] = lamp
                    }
                }
                dragStartBox = nil
                dragEnclosedIDs = []
                dragStartLamps = [:]
                store.persistFloorplan()
            }
    }

    private var resizeHandlesOverlay: some View {
        let positions: [(ResizeEdge, CGPoint)] = [
            (.topLeft, CGPoint(x: 0, y: 0)),
            (.top, CGPoint(x: width / 2, y: 0)),
            (.topRight, CGPoint(x: width, y: 0)),
            (.right, CGPoint(x: width, y: height / 2)),
            (.bottomRight, CGPoint(x: width, y: height)),
            (.bottom, CGPoint(x: width / 2, y: height)),
            (.bottomLeft, CGPoint(x: 0, y: height)),
            (.left, CGPoint(x: 0, y: height / 2)),
        ]
        return ForEach(Array(positions.enumerated()), id: \.offset) { _, pair in
            resizeHandle(edge: pair.0)
                .position(pair.1)
        }
    }

    private func resizeHandle(edge: ResizeEdge) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? store.skinAccentColor : Color.primary.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                .frame(width: 9, height: 9)
        }
        .frame(width: 19, height: 19)
        .contentShape(Rectangle())
        .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartBox == nil {
                            onSelect()
                            dragStartBox = box
                        }
                        guard let orig = dragStartBox else { return }
                        applyResize(orig: orig, edge: edge, translation: value.translation, finalize: false)
                    }
                    .onEnded { value in
                        guard let orig = dragStartBox else { return }
                        applyResize(orig: orig, edge: edge, translation: value.translation, finalize: true)
                        dragStartBox = nil
                    }
            )
    }

    private func applyResize(orig: FloorplanBox, edge: ResizeEdge, translation: CGSize, finalize: Bool) {
        let dx = Double(translation.width / max(0.2, zoom))
        let dy = Double(translation.height / max(0.2, zoom))
        var next = orig

        switch edge {
        case .topLeft:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            next.x = finalize ? store.floorplan.snapped(newX) : newX
            next.y = finalize ? store.floorplan.snapped(newY) : newY
            next.width = max(FloorplanBox.minWidth, orig.maxX - next.x)
            next.height = max(FloorplanBox.minHeight, orig.maxY - next.y)
        case .top:
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            next.y = finalize ? store.floorplan.snapped(newY) : newY
            next.height = max(FloorplanBox.minHeight, orig.maxY - next.y)
        case .topRight:
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            next.y = finalize ? store.floorplan.snapped(newY) : newY
            next.height = max(FloorplanBox.minHeight, orig.maxY - next.y)
            next.width = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
        case .right:
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            next.width = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
        case .bottomRight:
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            next.width = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
            next.height = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .bottom:
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            next.height = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .bottomLeft:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            next.x = finalize ? store.floorplan.snapped(newX) : newX
            next.width = max(FloorplanBox.minWidth, orig.maxX - next.x)
            next.height = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .left:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            next.x = finalize ? store.floorplan.snapped(newX) : newX
            next.width = max(FloorplanBox.minWidth, orig.maxX - next.x)
        }
        store.updateFloorplanBox(next, finalize: finalize)
    }
}

// MARK: - Interactive Lamp Node Component

private struct FloorplanLampNodeView: View {
    @EnvironmentObject var store: HueStore

    let light: HueLight
    let placement: FloorplanLampPlacement
    let zoom: CGFloat
    let tool: MapView.MapTool
    let isSelected: Bool
    let synthBand: SynthBand?
    @Binding var inspectorPresented: Bool

    let onTap: () -> Void
    let onInspect: () -> Void
    let onMove: (CGPoint, Bool) -> Void
    let onWireDragChanged: (CGPoint) -> Void
    let onWireDragEnded: (CGPoint) -> Void

    var body: some View {
        let nodeSize = max(24, min(36, 30 * zoom))
        let fillColor = light.on ? Color(hex: light.color) : Color(NSColor.controlBackgroundColor)
        let glyphColor: Color = light.on ? (prefersDarkGlyph(light.color) ? .black : .white) : .secondary

        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? store.skinAccentColor : (light.on ? Color.white.opacity(0.85) : Color.primary.opacity(0.28)),
                            lineWidth: isSelected ? 2.4 : 1.4
                        )
                    )
                    .shadow(color: light.on ? Color(hex: light.color).opacity(0.55) : Color.black.opacity(0.18), radius: light.on ? 7 : 2)
                    .frame(width: nodeSize, height: nodeSize)

                Image(systemName: placement.icon.sfSymbol(lit: light.on))
                    .font(.system(size: nodeSize * 0.44, weight: .semibold))
                    .foregroundStyle(glyphColor)

                // Wire mode right-edge connector port
                if tool == .wire {
                    Circle()
                        .fill(store.skinAccentColor)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .offset(x: nodeSize / 2 + 2)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("floorplanCanvas"))
                                .onChanged { onWireDragChanged($0.location) }
                                .onEnded { onWireDragEnded($0.location) }
                        )
                }
            }
            .contentShape(Circle())
            .onTapGesture { onTap() }
            .contextMenu {
                Button(light.on ? store.tr("Turn off") : store.tr("Turn on")) {
                    store.setLight(light, on: !light.on)
                }
                Button(store.tr("Inspect & Rename…")) { onInspect() }
                Divider()
                Button(store.tr("Remove from map")) {
                    store.unplaceLamp(light.id)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("floorplanCanvas"))
                    .onChanged { value in
                        if tool == .edit {
                            onMove(value.location, false)
                        } else if tool == .wire {
                            onWireDragChanged(value.location)
                        }
                    }
                    .onEnded { value in
                        if tool == .edit {
                            onMove(value.location, true)
                        } else if tool == .wire {
                            onWireDragEnded(value.location)
                        }
                    },
                including: (tool == .edit || tool == .wire) ? .all : .none
            )
            .popover(isPresented: $inspectorPresented, arrowEdge: .bottom) {
                LampMapInspectorPopover(light: light, placement: placement) {
                    inspectorPresented = false
                }
                .environmentObject(store)
            }

            // Compact readable label pill below lamp node
            HStack(spacing: 3) {
                Text(light.name)
                    .font(store.scaledFont(9.5, weight: .medium))
                    .lineLimit(1)
                if light.on {
                    Text("\(Int(light.bri.rounded()))%")
                        .font(store.scaledFont(8.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let band = synthBand {
                    Text(band.rawValue.uppercased())
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color(hex: "#d946ef"))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .onTapGesture { onInspect() }
        }
    }
}

// MARK: - Room Scenes & Inline Scene Scheduling Popover

private struct RoomScenesPopover: View {
    @EnvironmentObject var store: HueStore

    let room: HueRoom
    let schedules: [HueSchedule]
    let onScheduleScene: (HueScene) -> Void

    @State private var newSceneName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(room.name)
                    .font(store.scaledFont(13, weight: .semibold))
                Spacer()
                Text(store.tr("Scenes"))
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
            }

            if room.scenes.isEmpty {
                Text(store.tr("No scenes in this room yet."))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(room.scenes) { scene in
                            let hasSched = schedules.contains { $0.sceneID == scene.id }
                            HStack(spacing: 6) {
                                Button {
                                    store.recall(scene)
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(scene.active ? store.skinAccentColor : Color.primary.opacity(0.2))
                                            .frame(width: 7, height: 7)
                                        Text(scene.name)
                                            .font(store.scaledFont(11.5, weight: scene.active ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    onScheduleScene(scene)
                                } label: {
                                    Image(systemName: hasSched ? "alarm.fill" : "alarm")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(hasSched ? store.skinAccentColor : Color.secondary)
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help(store.tr("Schedule scene"))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                    .fill(scene.active ? store.skinAccentColor.opacity(0.14) : Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(store.tr("Save current lighting as scene"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(store.tr("Scene name"), text: $newSceneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { saveCurrentScene() }
                    Button(store.tr("Save")) { saveCurrentScene() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .frame(width: 270)
        .fontDesign(store.fontDesign)
    }

    private func saveCurrentScene() {
        let trimmed = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !room.hueID.isEmpty else { return }
        store.createSceneFromRoom(roomID: room.hueID, name: trimmed)
        newSceneName = ""
    }
}

// MARK: - Room Box Inspector Popover

private struct RoomBoxInspectorPopover: View {
    @EnvironmentObject var store: HueStore
    let box: FloorplanBox
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var kind: String = "room"
    @State private var archetype: String = "other"
    @State private var linkedHueID: String = ""
    @State private var linkedEntID: String = ""

    private static let archetypes: [(id: String, label: String)] = [
        ("living_room", "Living Room"),
        ("office", "Office"),
        ("bedroom", "Bedroom"),
        ("kitchen", "Kitchen"),
        ("dining", "Dining"),
        ("hallway", "Hallway"),
        ("bathroom", "Bathroom"),
        ("guest_room", "Guest Room"),
        ("balcony", "Balcony"),
        ("terrace", "Terrace"),
        ("garage", "Garage"),
        ("other", "Other"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(store.tr("Edit Room / Zone"))
                .font(store.scaledFont(13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Name"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(store.tr("Room name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { saveChanges() }
            }

            HStack(spacing: 8) {
                Picker(store.tr("Type"), selection: $kind) {
                    Text(store.tr("Room")).tag("room")
                    Text(store.tr("Zone")).tag("zone")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(box.hueID != nil)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Archetype"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $archetype) {
                    ForEach(Self.archetypes, id: \.id) { arch in
                        Text(store.tr(arch.label)).tag(arch.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Hue Bridge Link"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $linkedHueID) {
                    Text(store.tr("Visual only (unlinked)")).tag("")
                    ForEach(store.snapshot.rooms.filter { !$0.hueID.isEmpty }) { r in
                        Text("\(r.name) (\(r.kind == "zone" ? store.tr("Zone") : store.tr("Room")))").tag(r.hueID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if linkedHueID.isEmpty {
                    Button(store.tr("Create on Hue Bridge")) {
                        var updated = updatedBox()
                        updated.hueID = nil
                        store.updateFloorplanBox(updated, finalize: true)
                        store.createBoxOnBridge(updated)
                        onClose()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !store.snapshot.entertainmentAreas.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.tr("Entertainment Area"))
                        .font(store.scaledFont(10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $linkedEntID) {
                        Text(store.tr("None")).tag("")
                        ForEach(store.snapshot.entertainmentAreas) { area in
                            Text(area.name).tag(area.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)

                    if !linkedEntID.isEmpty {
                        Button {
                            let updated = updatedBox()
                            store.updateFloorplanBox(updated, finalize: true)
                            store.syncEntertainmentBox(updated)
                        } label: {
                            Label(store.tr("Sync 2D/3D Positions"), systemImage: "cube.transparent")
                                .font(store.scaledFont(11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                Menu(store.tr("Delete")) {
                    Button(store.tr("Remove from map only")) {
                        store.deleteFloorplanBox(id: box.id, alsoDeleteOnBridge: false)
                        onClose()
                    }
                    if box.hueID != nil {
                        Button(role: .destructive) {
                            store.deleteFloorplanBox(id: box.id, alsoDeleteOnBridge: true)
                            onClose()
                        } label: {
                            Text(store.tr("Delete on Hue Bridge too"))
                        }
                    }
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)

                Spacer()

                Button(store.tr("Save")) { saveChanges() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 270)
        .fontDesign(store.fontDesign)
        .onAppear {
            name = box.name
            kind = box.kind
            archetype = box.archetype
            linkedHueID = box.hueID ?? ""
            linkedEntID = box.entertainmentAreaID ?? ""
        }
    }

    private func updatedBox() -> FloorplanBox {
        var copy = box
        let clean = HueColorMath.clean(name, limit: 32)
        if !clean.isEmpty { copy.name = clean }
        copy.kind = kind
        copy.archetype = archetype
        copy.hueID = linkedHueID.isEmpty ? nil : linkedHueID
        copy.entertainmentAreaID = linkedEntID.isEmpty ? nil : linkedEntID
        return copy
    }

    private func saveChanges() {
        let updated = updatedBox()
        store.renameOrUpdateBoxOnBridge(updated)
        onClose()
    }
}

// MARK: - Lamp Map Inspector Popover (Power, Brightness, Color, Themes, Rename, Z-Height)

private struct LampMapInspectorPopover: View {
    @EnvironmentObject var store: HueStore
    let light: HueLight
    let placement: FloorplanLampPlacement
    let onClose: () -> Void

    @State private var nameDraft: String = ""
    @State private var briDraft: Double = 80
    @State private var zDraft: Double = 0
    @State private var iconDraft: LampIcon = .bulb

    private static let quickSwatches: [String] = [
        "#ffd27a", "#ff8a3d", "#ff3b5c", "#38d9c0", "#38bdf8", "#a855f7", "#ffffff",
    ]

    var body: some View {
        let liveLight = store.snapshot.light(light.id) ?? light
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(store.tr("Lamp name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitRename() }
                Button(store.tr("Rename")) { commitRename() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameDraft == liveLight.name)
            }

            HStack {
                Toggle(isOn: Binding(
                    get: { liveLight.on },
                    set: { store.setLight(liveLight, on: $0) }
                )) {
                    Text(liveLight.on ? store.tr("On") : store.tr("Off"))
                        .font(store.scaledFont(11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if liveLight.dimmable {
                    Text("\(Int(briDraft.rounded()))%")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if liveLight.dimmable {
                Slider(value: $briDraft, in: 1...100, onEditingChanged: { editing in
                    if !editing {
                        store.setLight(liveLight, bri: Int(briDraft.rounded()))
                    }
                })
                .controlSize(.small)
            }

            if liveLight.supportsColor || liveLight.supportsCT {
                HStack(spacing: 7) {
                    ForEach(Self.quickSwatches, id: \.self) { hex in
                        Button {
                            if liveLight.supportsColor, let xy = HueColorMath.hexToXY(hex) {
                                store.setLight(liveLight, xy: (xy.x, xy.y))
                            } else if liveLight.supportsCT {
                                store.setLight(liveLight, mirek: hex == "#ffffff" ? liveLight.mirekMin : 370)
                            }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Quick Light Themes
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(store.tr("Themes").uppercased())
                        .font(store.scaledFont(9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.tr("Edit / Create Theme …")) {
                        onClose()
                        store.themeEditorLight = liveLight
                    }
                    .buttonStyle(.borderless)
                    .font(store.scaledFont(10))
                }
                FlowLayout(spacing: 4) {
                    ForEach(Array(store.allThemes.prefix(4))) { theme in
                        Button {
                            store.applyTheme(theme, to: liveLight)
                        } label: {
                            HStack(spacing: 3) {
                                Circle().fill(Color(hex: theme.hex)).frame(width: 7, height: 7)
                                Text(theme.name).font(store.scaledFont(10)).lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Spatial fixture icon grid (12 selectable macOS 13+ SF Symbols)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.tr("Lamp Icon").uppercased())
                    .font(store.scaledFont(9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(LampIcon.allCases) { icon in
                        let selected = iconDraft == icon
                        Button {
                            iconDraft = icon
                            store.updateLampPlacement(light.id, icon: icon)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: icon.sfSymbol(lit: true))
                                    .font(.system(size: 13, weight: .medium))
                                Text(store.tr(icon.titleKey))
                                    .font(store.scaledFont(8.5))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                    .fill(selected ? store.skinAccentColor : Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                        .help(store.tr(icon.titleKey))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(store.tr("3D Height (Entertainment)"))
                        .font(store.scaledFont(10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", zDraft))
                        .font(store.scaledFont(10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $zDraft, in: -1.0...1.0, step: 0.05)
                    .controlSize(.small)
                    .onChange(of: zDraft) { val in
                        store.updateLampPlacement(light.id, z: val)
                    }
            }

            HStack {
                Button(role: .destructive) {
                    store.unplaceLamp(light.id)
                    onClose()
                } label: {
                    Text(store.tr("Remove from map"))
                        .font(store.scaledFont(11))
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(store.tr("Done")) {
                    commitRename()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
        .fontDesign(store.fontDesign)
        .onAppear {
            nameDraft = light.name
            briDraft = max(1, light.bri)
            zDraft = placement.z
            iconDraft = placement.icon
        }
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != light.name else { return }
        store.renameLight(id: light.id, name: trimmed)
    }
}

// MARK: - Wire Rule Inspector Popover (Click any Wire on Canvas)

private struct WireRuleInspectorPopover: View {
    @EnvironmentObject var store: HueStore
    let rule: HueRule
    let onClose: () -> Void

    @State private var enabled: Bool = true
    @State private var kind: String = "follow"
    @State private var mirrorOff: Bool = false
    @State private var matchBri: Bool = false
    @State private var onlyIfOff: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rule.name.isEmpty ? store.tr("Linked Rule") : rule.name)
                    .font(store.scaledFont(12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Picker(store.tr("Rule type"), selection: $kind) {
                Text(store.tr("Follow / Mirror")).tag("follow")
                Text(store.tr("Exclusive")).tag("exclusive")
                Text(store.tr("Companion")).tag("companion")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            if kind != "exclusive" {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(store.tr("Mirror off"), isOn: $mirrorOff)
                    Toggle(store.tr("Match brightness"), isOn: $matchBri)
                    Toggle(store.tr("Only if target is off"), isOn: $onlyIfOff)
                }
                .font(store.scaledFont(11.5))
            } else {
                Text(store.tr("Automatically turns target off when trigger turns on."))
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button(role: .destructive) {
                    store.deleteRule(rule)
                    onClose()
                } label: {
                    Label(store.tr("Delete"), systemImage: "trash")
                        .font(store.scaledFont(11))
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(store.tr("Save")) {
                    var updated = rule
                    updated.enabled = enabled
                    updated.kind = kind
                    updated.mirrorOff = kind == "exclusive" ? false : mirrorOff
                    updated.matchBri = kind == "exclusive" ? false : matchBri
                    updated.onlyIfOff = kind == "exclusive" ? false : onlyIfOff
                    if kind == "exclusive" {
                        updated.targets = updated.targets.map {
                            HueRuleTarget(kind: $0.kind, id: $0.id, action: "off", bri: nil, sceneID: nil)
                        }
                    } else {
                        updated.targets = updated.targets.map {
                            HueRuleTarget(kind: $0.kind, id: $0.id, action: "on", bri: $0.bri, sceneID: $0.sceneID)
                        }
                    }
                    store.updateRule(updated)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 265)
        .fontDesign(store.fontDesign)
        .onAppear {
            enabled = rule.enabled
            kind = rule.kind
            mirrorOff = rule.mirrorOff
            matchBri = rule.matchBri
            onlyIfOff = rule.onlyIfOff
        }
    }
}

// MARK: - Quick Wire Creation Sheet (Drag Wire in Wire Mode)

private struct QuickWireRuleSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let source: MapView.WireEndpoint
    let target: MapView.WireEndpoint

    @State private var ruleKind: String = "follow"
    @State private var mirrorOff: Bool = true
    @State private var matchBri: Bool = false
    @State private var onlyIfOff: Bool = false

    var body: some View {
        let srcName = store.nameForTarget(kind: source.kind, id: source.id)
        let dstName = store.nameForTarget(kind: target.kind, id: target.id)

        VStack(alignment: .leading, spacing: 14) {
            Text(store.tr("Link on Floorplan"))
                .font(store.scaledFont(14, weight: .semibold))

            HStack(spacing: 8) {
                Text(srcName)
                    .font(store.scaledFont(12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(dstName)
                    .font(store.scaledFont(12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(store.tr("Rule type"))
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $ruleKind) {
                    Text(store.tr("Follow / Mirror")).tag("follow")
                    Text(store.tr("Exclusive")).tag("exclusive")
                    Text(store.tr("Companion")).tag("companion")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if ruleKind != "exclusive" {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(store.tr("Mirror off"), isOn: $mirrorOff)
                    Toggle(store.tr("Match brightness"), isOn: $matchBri)
                    Toggle(store.tr("Only if target is off"), isOn: $onlyIfOff)
                }
                .font(store.scaledFont(12))
            } else {
                Text(store.tr("Automatically turns target off when trigger turns on."))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.tr("Create Link")) {
                    let action = ruleKind == "exclusive" ? "off" : "on"
                    let rule = HueRule(
                        name: "\(srcName) → \(dstName)",
                        enabled: true,
                        kind: ruleKind,
                        triggerKind: source.kind,
                        triggerID: source.id,
                        triggerState: "on",
                        targets: [HueRuleTarget(kind: target.kind, id: target.id, action: action)],
                        mirrorOff: ruleKind == "exclusive" ? false : mirrorOff,
                        matchBri: ruleKind == "exclusive" ? false : matchBri,
                        onlyIfOff: ruleKind == "exclusive" ? false : onlyIfOff
                    )
                    store.addRule(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 290)
        .fontDesign(store.fontDesign)
    }
}

// MARK: - Quick Inline Scene Schedule Sheet (from Room Box Scenes Popover)

private struct QuickSceneScheduleSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let room: HueRoom
    let scene: HueScene

    @State private var name: String = ""
    @State private var triggerKind: String = "time"
    @State private var hour: Int = 20
    @State private var minute: Int = 0
    @State private var offsetMin: Int = 0
    @State private var selectedDays: Set<String> = []
    @State private var fadeMin: Int = 0

    private static let allDays: [(id: String, short: String)] = [
        ("monday", "M"), ("tuesday", "T"), ("wednesday", "W"), ("thursday", "T"),
        ("friday", "F"), ("saturday", "S"), ("sunday", "S"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Schedule Scene"))
                        .font(store.scaledFont(14, weight: .semibold))
                    Text("\(room.name) · \(scene.name)")
                        .font(store.scaledFont(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.scheduleMode == .bridge ? store.tr("Bridge") : store.tr("Mac"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(store.skinAccentColor.opacity(0.15)))
                    .foregroundStyle(store.skinAccentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Name"))
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(scene.name, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(store.tr("Trigger"))
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $triggerKind) {
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
                    Stepper(value: $offsetMin, in: -60...60, step: 5) {
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

            Spacer()

            HStack {
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.tr("Save")) {
                    let timeStr = String(format: "%02d:%02d", hour, minute)
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = trimmed.isEmpty ? "\(room.name): \(scene.name)" : trimmed
                    let draft = HueScheduleDraft(
                        name: finalName,
                        targetKind: room.kind == "zone" ? "zone" : "room",
                        targetID: room.hueID,
                        targetName: room.name,
                        triggerKind: triggerKind,
                        time: timeStr,
                        offsetMin: offsetMin,
                        days: Array(selectedDays).sorted(),
                        action: "scene",
                        bri: nil,
                        sceneID: scene.id,
                        fadeMin: fadeMin
                    )
                    store.createSchedule(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360, height: 390)
        .fontDesign(store.fontDesign)
        .onAppear {
            name = "\(room.name): \(scene.name)"
        }
    }
}
