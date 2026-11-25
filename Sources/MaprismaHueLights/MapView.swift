import AppKit
import HueCore
import SwiftUI
import UniformTypeIdentifiers

enum LampDialogSheet: Identifiable {
    case brightness(String)
    case rename(String)
    case icon(String)

    var id: String {
        switch self {
        case .brightness(let lightID): return "brightness:\(lightID)"
        case .rename(let lightID): return "rename:\(lightID)"
        case .icon(let lightID): return "icon:\(lightID)"
        }
    }
}

/// Interactive 2D Visual Floorplan & Spatial Light Studio (`Map` tab).
/// Supports 6 editable architectural prototypes, custom floorplan background image,
/// resizable Room/Zone boxes with inline Scenes & Scene Scheduling, glowing live Hue lamp nodes,
/// minimalist rotatable furniture stamps, Bezier dependency wires, and 1-click Bridge Sync.
struct MapView: View {
    enum MapMode: String, CaseIterable, Identifiable {
        case map, plan, rules
        var id: String { rawValue }
    }

    enum SidebarFilter: String, CaseIterable, Identifiable {
        case all, unplaced
        var id: String { rawValue }
    }

    struct WireEndpoint: Equatable, Hashable {
        let kind: String // "light", "room", "motion", "contact", "button", or "motion_area"
        let id: String
    }

    enum RuleDialogState: Identifiable {
        case create(source: WireEndpoint, target: WireEndpoint)
        case edit(HueRule)

        var id: String {
            switch self {
            case .create(let src, let dst): return "create:\(src.kind):\(src.id)->\(dst.kind):\(dst.id)"
            case .edit(let rule): return "edit:\(rule.id)"
            }
        }
    }

    struct PendingSceneSchedule: Identifiable {
        let id = UUID()
        let room: HueRoom
        let scene: HueScene
    }

    @EnvironmentObject var store: HueStore
    @EnvironmentObject var proStore: ProStoreManager

    @State private var mode: MapMode = .map
    @State private var sidebarOpen: Bool = true
    @State private var studioWidth: CGFloat = 840
    @State private var didApplyNarrowCollapse: Bool = false
    @State private var pinchBaseZoom: Double? = nil
    @State private var sidebarFilter: SidebarFilter = .all
    @State private var lampSearch: String = ""
    @State private var showGrid: Bool = true
    @State private var showSynthOverlay: Bool = false

    @State private var selectedBoxID: String? = nil
    @State private var selectedLightID: String? = nil
    @State private var selectedSensorID: String? = nil
    @State private var selectedStampID: String? = nil
    @State private var hoveredLightID: String? = nil
    @State private var hoveredSensorID: String? = nil
    @State private var hoveredStampID: String? = nil
    @State private var inspectedBoxID: String? = nil
    @State private var scenesBoxID: String? = nil
    @State private var showBackgroundSheet: Bool = false
    @State private var ambientMode: FloorplanAmbientMode = .day
    @State private var showGallerySheet: Bool = false
    @State private var showShoppingListSheet: Bool = false
    @State private var selectedPlannedID: String? = nil
    @State private var editingPlannedLightID: String? = nil

    @State private var canvasViewportSize: CGSize = CGSize(width: 720, height: 500)
    @State private var didInitialFit: Bool = false

    // Transient drag & dialog states
    @State private var panStart: CGPoint? = nil
    @State private var wireDraftSource: WireEndpoint? = nil
    @State private var wireDraftWorldPoint: CGPoint? = nil
    @State private var armedRuleSource: WireEndpoint? = nil
    @State private var activeLampDialog: LampDialogSheet? = nil
    @State private var activeRuleDialog: RuleDialogState? = nil
    @State private var pendingSceneSchedule: PendingSceneSchedule? = nil

    private var wiresVisible: Bool {
        store.floorplan.showWires || mode == .rules
    }

    var body: some View {
        if !proStore.isUnlocked(.floorplan, isDemoMode: store.isDemoMode) {
            ProLockedOverlay(
                feature: .floorplan,
                symbol: "map.fill",
                accentHex: "#38bdf8",
                title: store.tr("Visual Floorplan Studio"),
                description: store.tr("Arrange rooms, zones, furniture, and glowing lamps on an interactive 2D map, or place your own floorplan image behind them."),
                highlights: [
                    store.tr("6 editable apartment & house prototypes plus custom background images"),
                    store.tr("12 custom lamp icons, inline scenes & 1-click Hue Bridge sync"),
                    store.tr("Drag-to-connect visual rule wires & Hue sensors"),
                ]
            )
        } else {
            mapStudioBody
        }
    }

    private var mapStudioBody: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            FloorTabsBar(ambientMode: $ambientMode) {
                selectedBoxID = nil
                selectedLightID = nil
                selectedSensorID = nil
                selectedStampID = nil
                selectedPlannedID = nil
                fitCanvasToContent()
            }
            Divider()
            syncBannerIfNeeded
            statusToastIfNeeded
            if store.shouldShowMotionAwareSetupHint {
                MotionAwareSetupHintBanner()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }

            GeometryReader { studioGeo in
                let isNarrow = studioGeo.size.width < 680
                let sidebarW: CGFloat = studioGeo.size.width < 780 ? 178 : 215
                HStack(spacing: 0) {
                    if sidebarOpen {
                        lampSidebar
                            .frame(width: sidebarW)
                        Divider()
                    }
                    canvasWorkspace
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    studioWidth = studioGeo.size.width
                    if isNarrow {
                        sidebarOpen = false
                        didApplyNarrowCollapse = true
                    }
                }
                .onChange(of: studioGeo.size.width) { newW in
                    studioWidth = newW
                    if newW < 680 && !didApplyNarrowCollapse {
                        sidebarOpen = false
                        didApplyNarrowCollapse = true
                    } else if newW >= 740 && didApplyNarrowCollapse {
                        didApplyNarrowCollapse = false
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            consumePendingMapNavigation()
        }
        .onChange(of: store.pendingMapMode) { _ in
            consumePendingMapNavigation()
        }
        .onChange(of: store.pendingMapWireLightID) { _ in
            consumePendingMapNavigation()
        }
        .onChange(of: mode) { newMode in
            if newMode != .rules {
                armedRuleSource = nil
                wireDraftSource = nil
                wireDraftWorldPoint = nil
            }
        }
        .sheet(item: $activeRuleDialog) { state in
            MapRuleDialogSheet(state: state)
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(item: $activeLampDialog) { dialog in
            switch dialog {
            case .brightness(let lightID):
                LampBrightnessSheet(lightID: lightID)
                    .environmentObject(store)
                    .tint(store.skinAccentColor)
                    .preferredColorScheme(store.preferredColorScheme)
            case .rename(let lightID):
                LampRenameSheet(lightID: lightID)
                    .environmentObject(store)
                    .tint(store.skinAccentColor)
                    .preferredColorScheme(store.preferredColorScheme)
            case .icon(let lightID):
                LampIconPickerSheet(lightID: lightID)
                    .environmentObject(store)
                    .tint(store.skinAccentColor)
                    .preferredColorScheme(store.preferredColorScheme)
            }
        }
        .sheet(item: $pendingSceneSchedule) { item in
            QuickSceneScheduleSheet(room: item.room, scene: item.scene)
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: $showBackgroundSheet) {
            FloorplanBackgroundSheet()
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: $showGallerySheet) {
            FloorplanGallerySheet {
                fitCanvasToContent()
            }
            .environmentObject(store)
            .tint(store.skinAccentColor)
            .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: $showShoppingListSheet) {
            LightingShoppingListSheet()
                .environmentObject(store)
                .tint(store.skinAccentColor)
                .preferredColorScheme(store.preferredColorScheme)
        }
        .sheet(isPresented: Binding(
            get: { editingPlannedLightID != nil },
            set: { if !$0 { editingPlannedLightID = nil } }
        )) {
            if let pid = editingPlannedLightID {
                PlannedLightInspectorSheet(plannedID: pid)
                    .environmentObject(store)
                    .tint(store.skinAccentColor)
                    .preferredColorScheme(store.preferredColorScheme)
            }
        }
    }

    // MARK: - Top Studio Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 1. Sidebar toggle
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

                // 2. Map | Plan | Rules sub-tab switcher
                Picker("", selection: $mode) {
                    Text(store.tr("Map")).tag(MapMode.map)
                    Text(store.tr("Plan")).tag(MapMode.plan)
                    Text(store.tr("Rules")).tag(MapMode.rules)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: studioWidth < 680 ? 168 : 196)

                if mode == .map {
                    // 3. + Add menu (Room shapes, Zone, Furniture stamps including Stairs)
                    Menu {
                        Button {
                            let c = visibleWorldCenter()
                            store.addFloorplanBox(kind: "room", name: store.tr("New Room"), archetype: "other", shape: .rectangle, at: c.x - 160, y: c.y - 120)
                        } label: {
                            Label(store.tr("Add Room"), systemImage: "plus.rectangle")
                        }

                        Button {
                            let c = visibleWorldCenter()
                            store.addFloorplanBox(kind: "room", name: store.tr("L-Shape Room"), archetype: "living_room", shape: .lShape, at: c.x - 160, y: c.y - 120)
                        } label: {
                            Label(store.tr("Add L-Shape Room"), systemImage: "l.square")
                        }

                        Button {
                            let c = visibleWorldCenter()
                            store.addFloorplanBox(kind: "room", name: store.tr("Bay Window Room"), archetype: "living_room", shape: .bayWindow, at: c.x - 160, y: c.y - 120)
                        } label: {
                            Label(store.tr("Add Bay Window Room"), systemImage: "pentagon")
                        }

                        Button {
                            let c = visibleWorldCenter()
                            store.addFloorplanBox(kind: "zone", name: store.tr("New Zone"), archetype: "other", shape: .rectangle, at: c.x - 170, y: c.y - 100)
                        } label: {
                            Label(store.tr("Add Zone"), systemImage: "plus.square.dashed")
                        }

                        Divider()

                        ForEach(FloorplanStamp.allKinds, id: \.self) { kind in
                            Button {
                                let c = visibleWorldCenter()
                                store.addStamp(kind: kind, at: c.x - 60, y: c.y - 30)
                                store.floorplan.showFurniture = true
                                store.persistFloorplan()
                            } label: {
                                Label(stampLabel(for: kind), systemImage: stampSymbol(for: kind))
                            }
                        }
                    } label: {
                        Label(store.tr("Add"), systemImage: "plus")
                            .font(store.scaledFont(11, weight: .medium))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    // 4. Visual Floorplan Gallery button
                    Button {
                        showGallerySheet = true
                    } label: {
                        Label(store.tr("Gallery…"), systemImage: "square.grid.2x2")
                            .font(store.scaledFont(11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(store.tr("Open visual apartment & house floorplan gallery"))
                } else if mode == .plan {
                    // Plan Mode: Add Planned Fixture / LED Lightstrip
                    Menu {
                        ForEach(PlannedLightPreset.all) { preset in
                            Button {
                                let c = visibleWorldCenter()
                                let created = store.addPlannedLight(preset: preset, at: FloorplanPoint(x: c.x, y: c.y))
                                selectedPlannedID = created.id
                                if ambientMode == .day { ambientMode = .dusk }
                            } label: {
                                Label("\(store.tr(preset.titleKey)) (\(preset.lumens) lm)", systemImage: preset.icon.sfSymbol(lit: true))
                            }
                        }
                    } label: {
                        Label(store.tr("Add Fixture"), systemImage: "lightbulb.max")
                            .font(store.scaledFont(11, weight: .medium))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    Button {
                        showShoppingListSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.clipboard")
                            Text(store.tr("Plan List"))
                                .font(store.scaledFont(11, weight: .medium))
                            if !store.floorplan.plannedLights.isEmpty {
                                Text("\(store.floorplan.plannedLights.count)")
                                    .font(store.scaledFont(9.5, weight: .bold).monospacedDigit())
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(store.skinAccentColor.opacity(0.2)))
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showGallerySheet = true
                    } label: {
                        Label(store.tr("Gallery…"), systemImage: "square.grid.2x2")
                            .font(store.scaledFont(11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if mode == .map {

                    // 5. View menu (Background… + layers + Auto-sync)
                    Menu {
                        Button {
                            showBackgroundSheet = true
                        } label: {
                            Label(
                                store.tr("Background…"),
                                systemImage: store.floorplanBackgroundImage == nil ? "photo" : "photo.fill"
                            )
                        }
                        Divider()
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
                        if store.snapshot.hueBridgePaired || store.snapshot.isDemo {
                            Divider()
                            Toggle(store.tr("Auto-sync to Bridge"), isOn: Binding(
                                get: { store.floorplan.autoSync },
                                set: { store.setFloorplanAutoSync($0) }
                            ))
                        }
                    } label: {
                        Label(store.tr("View"), systemImage: "eye")
                            .font(store.scaledFont(11, weight: .medium))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    // 6. Sync All button with pending count badge (only when a Hue Bridge or Demo is active)
                    if store.snapshot.hueBridgePaired || store.snapshot.isDemo {
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
                    }
                }

                // 7. Compact Zoom (-, Fit, +)
                HStack(spacing: 2) {
                    Button { adjustZoom(by: -0.15) } label: {
                        Image(systemName: "minus.magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(store.tr("Zoom out"))
                    .help(store.tr("Zoom out"))

                    Button {
                        fitCanvasToContent()
                    } label: {
                        Text(store.tr("Fit"))
                            .font(store.scaledFont(10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(store.tr("Fit"))
                    .help(store.tr("Fit"))

                    Button { adjustZoom(by: 0.15) } label: {
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(store.tr("Zoom in"))
                    .help(store.tr("Zoom in"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    // MARK: - Sync Banner & Toast

    @ViewBuilder
    private var syncBannerIfNeeded: some View {
        let plan = store.pendingFloorplanSyncPlan
        let sig = store.floorplanDiffSignature
        if plan.hasRoomOrMetaChanges && !store.floorplan.autoSync && store.dismissedFloorplanDiffKey != sig {
            let narrow = studioWidth < 640
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(store.skinAccentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.trf("{0} floorplan change(s) ready to sync to Hue Bridge.", [String(plan.totalChanges)]))
                            .font(store.scaledFont(11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        let multiFixture = plan.membershipDiffs.filter { !$0.sharedDeviceLightNames.isEmpty }
                        if !multiFixture.isEmpty {
                            Text(store.tr("Note: multi-bulb fixtures move together on the Hue Bridge."))
                                .font(store.scaledFont(10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !narrow {
                        Spacer(minLength: 4)
                        syncBannerActions(sig: sig)
                    }
                }
                if narrow {
                    HStack(spacing: 8) {
                        syncBannerActions(sig: sig)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(store.skinAccentColor.opacity(0.11))
            Divider()
        }
    }

    @ViewBuilder
    private func syncBannerActions(sig: String) -> some View {
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

    private var filteredSidebarSensors: [HueSensor] {
        let query = lampSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.snapshot.sensors.filter { sensor in
            if sidebarFilter == .unplaced && store.floorplan.sensors[sensor.id] != nil {
                return false
            }
            if !query.isEmpty {
                return sensor.name.lowercased().contains(query)
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
                    if list.isEmpty && filteredSidebarSensors.isEmpty {
                        Text(sidebarFilter == .unplaced ? store.tr("All lamps placed.") : store.tr("No lamps match."))
                            .font(store.scaledFont(11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                    } else {
                        ForEach(list) { light in
                            let placed = store.floorplan.lamps[light.id] != nil
                            sidebarLampRow(light: light, placed: placed)
                        }

                        if !store.snapshot.sensors.isEmpty {
                            let sensorList = filteredSidebarSensors
                            if !sensorList.isEmpty {
                                HStack {
                                    Text(store.tr("Sensors").uppercased())
                                        .font(store.scaledFont(9.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 5)
                                .padding(.top, list.isEmpty ? 2 : 8)
                                .padding(.bottom, 2)

                                ForEach(sensorList) { sensor in
                                    let placed = store.floorplan.sensors[sensor.id] != nil
                                    sidebarSensorRow(sensor: sensor, placed: placed)
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }

            if mode == .rules {
                Divider()
                wireLegendFooter
                    .padding(8)
            }
        }
        .background(store.cardBackgroundColor.opacity(0.6))
    }

    private func sidebarLampRow(light: HueLight, placed: Bool) -> some View {
        let chosenIcon = store.lampIcon(for: light)
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(light.on ? Color(hex: light.color) : Color.primary.opacity(0.14))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.6))
                    .shadow(color: light.on ? Color(hex: light.color).opacity(0.55) : .clear, radius: 4)
                    .frame(width: 22, height: 22)
                Image(systemName: chosenIcon.sfSymbol(lit: light.on))
                    .font(.system(size: 10.5, weight: .semibold))
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

            if !placed {
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

            Menu {
                if placed {
                    Button(light.on ? store.tr("Turn off") : store.tr("Turn on")) {
                        store.setLight(light, on: !light.on)
                    }
                    Button(store.tr("Brightness…")) {
                        activeLampDialog = .brightness(light.id)
                    }
                    Button(store.tr("Rename…")) {
                        activeLampDialog = .rename(light.id)
                    }
                    Button(store.tr("Lamp icon…")) {
                        activeLampDialog = .icon(light.id)
                    }
                    if let p = store.floorplan.lamps[light.id], p.floorID != store.floorplan.activeFloorID {
                        Button(store.tr("Move to this floor")) {
                            store.moveLampToActiveFloor(light.id)
                        }
                    }
                    Divider()
                    Button(store.tr("Wire from here")) {
                        mode = .rules
                        selectedLightID = light.id
                        armedRuleSource = WireEndpoint(kind: "light", id: light.id)
                        if let placement = store.floorplan.lamps[light.id] {
                            centerViewport(onWorld: CGPoint(x: placement.x, y: placement.y))
                        }
                    }
                    Button(store.tr("Remove from map"), role: .destructive) {
                        store.unplaceLamp(light.id)
                    }
                } else {
                    Button(store.tr("Place on map")) {
                        placeLampSmartly(light)
                    }
                    Button(light.on ? store.tr("Turn off") : store.tr("Turn on")) {
                        store.setLight(light, on: !light.on)
                    }
                    Button(store.tr("Brightness…")) {
                        activeLampDialog = .brightness(light.id)
                    }
                    Button(store.tr("Rename…")) {
                        activeLampDialog = .rename(light.id)
                    }
                    Button(store.tr("Lamp icon…")) {
                        activeLampDialog = .icon(light.id)
                    }
                    if let p = store.floorplan.lamps[light.id], p.floorID != store.floorplan.activeFloorID {
                        Button(store.tr("Move to this floor")) {
                            store.moveLampToActiveFloor(light.id)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .fill(selectedLightID == light.id ? store.skinAccentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .strokeBorder(selectedLightID == light.id ? store.skinAccentColor.opacity(0.45) : Color.clear, lineWidth: 0.75)
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

    private func consumePendingMapNavigation() {
        if let requested = store.pendingMapMode {
            store.pendingMapMode = nil
            mode = (requested == "rules") ? .rules : .map
        }
        if let wireLightID = store.pendingMapWireLightID {
            store.pendingMapWireLightID = nil
            mode = .rules
            selectedLightID = wireLightID
            selectedSensorID = nil
            if let placement = store.floorplan.lamps[wireLightID] {
                armedRuleSource = WireEndpoint(kind: "light", id: wireLightID)
                centerViewport(onWorld: CGPoint(x: placement.x, y: placement.y))
            } else {
                sidebarOpen = true
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
            selectedSensorID = nil
            centerViewport(onWorld: CGPoint(x: box.centerX, y: box.centerY))
        } else {
            let c = visibleWorldCenter()
            store.placeLamp(light.id, at: c.x, y: c.y)
            selectedLightID = light.id
            selectedSensorID = nil
        }
    }

    private func placeSensorSmartly(_ sensor: HueSensor) {
        if !sensor.roomID.isEmpty,
           let box = store.floorplan.boxes.first(where: { $0.hueID == sensor.roomID }) {
            let offset = Double((store.floorplan.sensors.count % 4)) * 34.0
            let px = HueColorMath.clamp(box.maxX - 36.0 - offset, box.minX + 26, box.maxX - 24)
            let py = HueColorMath.clamp(box.maxY - 34.0, box.minY + 46, box.maxY - 24)
            store.placeSensor(sensor.id, at: px, y: py)
            selectedSensorID = sensor.id
            selectedLightID = nil
            centerViewport(onWorld: CGPoint(x: px, y: py))
        } else {
            let c = visibleWorldCenter()
            store.placeSensor(sensor.id, at: c.x, y: c.y)
            selectedSensorID = sensor.id
            selectedLightID = nil
        }
    }

    private func sensorSymbol(for sensor: HueSensor) -> String {
        switch sensor.kind {
        case "contact":
            return sensor.open ? "door.left.hand.open" : "door.left.hand.closed"
        case "button":
            return "switch.2"
        default:
            return "figure.walk"
        }
    }

    private func sensorAccentColor(for sensor: HueSensor) -> Color {
        if !sensor.enabled { return Color.secondary }
        if sensor.kind == "motion" && sensor.motion { return Color(hex: "#10b981") }
        if sensor.kind == "contact" && sensor.open { return Color(hex: "#f59e0b") }
        return Color(hex: "#06b6d4")
    }

    private func sensorStatusText(for sensor: HueSensor) -> String {
        var parts: [String] = []
        if !sensor.enabled {
            parts.append(store.tr("Disabled"))
        } else if sensor.kind == "motion" {
            parts.append(sensor.motion ? store.tr("Motion") : store.tr("Clear"))
        } else if sensor.kind == "contact" {
            parts.append(sensor.open ? store.tr("Open") : store.tr("Closed"))
        } else if sensor.kind == "button" {
            parts.append(store.tr("Switch"))
        }
        if let temp = sensor.temperature {
            parts.append(String(format: "%.1f°C", temp))
        }
        if let bat = sensor.battery {
            parts.append("\(bat)%")
        }
        return parts.joined(separator: " · ")
    }

    private func sidebarSensorRow(sensor: HueSensor, placed: Bool) -> some View {
        let tint = sensorAccentColor(for: sensor)
        let isActive = sensor.enabled && ((sensor.kind == "motion" && sensor.motion) || (sensor.kind == "contact" && sensor.open))

        return HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? tint : tint.opacity(sensor.enabled ? 0.16 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(sensor.enabled ? 0.55 : 0.25), lineWidth: 0.75)
                    )
                    .frame(width: 22, height: 22)
                Image(systemName: sensorSymbol(for: sensor))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.name)
                    .font(store.scaledFont(11, weight: selectedSensorID == sensor.id ? .semibold : .regular))
                    .lineLimit(1)
                Text(sensorStatusText(for: sensor))
                    .font(store.scaledFont(9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if !placed {
                Button {
                    placeSensorSmartly(sensor)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(store.skinAccentColor)
                }
                .buttonStyle(.borderless)
                .help(store.tr("Place on map"))
            }

            Menu {
                if !placed {
                    Button(store.tr("Place on map")) {
                        placeSensorSmartly(sensor)
                    }
                }
                if sensor.kind == "motion" || sensor.kind == "contact" {
                    Button(sensor.enabled ? store.tr("Disable") : store.tr("Enable")) {
                        store.setSensorEnabled(sensor, enabled: !sensor.enabled)
                    }
                }
                Button(store.tr("Wire from here")) {
                    if !placed {
                        placeSensorSmartly(sensor)
                    }
                    mode = .rules
                    selectedSensorID = sensor.id
                    selectedLightID = nil
                    armedRuleSource = WireEndpoint(kind: sensor.kind, id: sensor.id)
                    if let placement = store.floorplan.sensors[sensor.id] {
                        centerViewport(onWorld: CGPoint(x: placement.x, y: placement.y))
                    }
                }
                if placed {
                    Divider()
                    Button(store.tr("Remove from map"), role: .destructive) {
                        store.unplaceSensor(sensor.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .fill(selectedSensorID == sensor.id ? store.skinAccentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                .strokeBorder(selectedSensorID == sensor.id ? store.skinAccentColor.opacity(0.45) : Color.clear, lineWidth: 0.75)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let placement = store.floorplan.sensors[sensor.id] {
                selectedSensorID = sensor.id
                selectedLightID = nil
                centerViewport(onWorld: CGPoint(x: placement.x, y: placement.y))
            } else {
                placeSensorSmartly(sensor)
            }
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
                    // 0. Backdrop, Click-Line Hit Testing & Pan
                    Rectangle()
                        .fill(Color.primary.opacity(0.03))
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    if wiresVisible, let hitRule = hitTestRule(at: value.location) {
                                        activeRuleDialog = .edit(hitRule)
                                        return
                                    }
                                    selectedBoxID = nil
                                    selectedLightID = nil
                                    selectedSensorID = nil
                                    selectedStampID = nil
                                    selectedPlannedID = nil
                                    armedRuleSource = nil
                                }
                        )
                        .simultaneousGesture(canvasPanGesture)

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

                    // 1. GPU Canvas: Ambient Dusk/Night, Grid, Furniture Stamps, Wall-Clipped Light Halos, LED Strips, Wires
                    Canvas { ctx, size in
                        if ambientMode.dimOpacity > 0 {
                            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.black.opacity(ambientMode.dimOpacity)))
                        }
                        drawGrid(in: &ctx, size: size)
                        if store.floorplan.showFurniture {
                            drawFurnitureStamps(in: &ctx)
                        }
                        if store.floorplan.showGlows || mode == .plan {
                            drawLightHalos(in: &ctx)
                            drawPlannedLightsAndStrips(in: &ctx)
                        }
                        if wiresVisible {
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

                    // 2. Direct-Manipulation Furniture Stamp Handles (Map mode)
                    if mode == .map && store.floorplan.showFurniture {
                        ForEach(activeFloorStamps) { stamp in
                            stampEditOverlay(stamp)
                        }
                    }

                    // 3. Resizable, Reshapable Polygon Room / Zone Boxes
                    ForEach(activeFloorBoxes) { box in
                        roomBoxLayer(box)
                    }

                    // 4. Interactive Lamp Nodes
                    ForEach(placedLights) { light in
                        if let placement = store.floorplan.lamps[light.id] {
                            lampNodeLayer(light: light, placement: placement)
                        }
                    }

                    // 4b. Interactive Physical Hue Sensor Nodes (rounded squares)
                    ForEach(placedSensors) { sensor in
                        if let placement = store.floorplan.sensors[sensor.id] {
                            sensorNodeLayer(sensor: sensor, placement: placement)
                        }
                    }

                    // 4c. Interactive Planned Lighting Fixtures & Bendable LED Strip Nodes
                    if mode == .plan || !activeFloorPlannedLights.isEmpty {
                        ForEach(activeFloorPlannedLights) { planned in
                            plannedLightNodeLayer(planned)
                        }
                    }

                    // 5. Clickable Wire Midpoint Pills
                    if wiresVisible {
                        ForEach(visibleWireBadges) { badge in
                            wireMidpointPill(badge)
                        }
                    }

                    // 6. Clean 1-line Mode Hint Pill at top of canvas
                    if mode == .rules {
                        VStack {
                            rulesHintPill
                                .padding(.top, 10)
                                .padding(.horizontal, 12)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else if mode == .plan {
                        VStack {
                            Text(store.tr("Plan Mode: place future fixtures & LED strips, drag corners to reshape rooms, and toggle Day/Dusk/Night."))
                                .font(store.scaledFont(10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                                .allowsHitTesting(false)
                                .padding(.top, 10)
                                .padding(.horizontal, 12)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .coordinateSpace(name: "floorplanCanvas")
            .clipped()
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBaseZoom == nil {
                            pinchBaseZoom = store.floorplan.canvas.zoom
                        }
                        if let base = pinchBaseZoom {
                            let next = min(2.4, max(0.35, base * Double(value)))
                            store.floorplan.canvas.zoom = next
                        }
                    }
                    .onEnded { _ in
                        pinchBaseZoom = nil
                        store.persistFloorplan()
                    }
            )
            .onDeleteCommand {
                if let stampID = selectedStampID {
                    store.deleteStamp(id: stampID)
                    selectedStampID = nil
                } else if let plannedID = selectedPlannedID {
                    store.deletePlannedLight(id: plannedID)
                    selectedPlannedID = nil
                } else if let boxID = selectedBoxID {
                    store.deleteFloorplanBox(id: boxID, alsoDeleteOnBridge: false)
                    selectedBoxID = nil
                }
            }
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

    private var activeFloorBoxes: [FloorplanBox] {
        store.floorplan.boxes(onFloor: store.floorplan.activeFloorID)
    }

    private var activeFloorStamps: [FloorplanStamp] {
        store.floorplan.stamps(onFloor: store.floorplan.activeFloorID)
    }

    private var activeFloorPlannedLights: [PlannedLight] {
        store.floorplan.plannedLights(onFloor: store.floorplan.activeFloorID)
    }

    private var placedLights: [HueLight] {
        let fid = store.floorplan.activeFloorID
        return store.snapshot.allLights.filter {
            guard let p = store.floorplan.lamps[$0.id] else { return false }
            return p.floorID == fid
        }
    }

    private var placedSensors: [HueSensor] {
        let fid = store.floorplan.activeFloorID
        return store.snapshot.sensors.filter {
            guard let p = store.floorplan.sensors[$0.id] else { return false }
            return p.floorID == fid
        }
    }

    @ViewBuilder
    private var rulesHintPill: some View {
        if let armed = armedRuleSource {
            let srcName = store.nameForTarget(kind: armed.kind, id: armed.id)
            HStack(spacing: 8) {
                Circle()
                    .fill(store.skinAccentColor)
                    .frame(width: 7, height: 7)
                Text(store.trf("Click another lamp or room to link with {0}", [srcName]))
                    .font(store.scaledFont(10.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Button(store.tr("Cancel")) {
                    armedRuleSource = nil
                }
                .buttonStyle(.borderless)
                .font(store.scaledFont(10.5, weight: .semibold))
                .foregroundStyle(store.skinAccentColor)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(store.skinAccentColor.opacity(0.45), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
        } else {
            Text(store.tr("Drag from a lamp or sensor to a lamp to create a rule, or click any line to edit or delete."))
                .font(store.scaledFont(10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                .allowsHitTesting(false)
        }
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

        for stamp in activeFloorStamps {
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

            case "stairs":
                let frame = Path(rect)
                local.fill(frame, with: .color(fillColor))
                local.stroke(frame, with: .color(strokeColor), lineWidth: 1.3)
                let steps = 7
                for i in 1..<steps {
                    let sy = rect.minY + (rect.height * CGFloat(i) / CGFloat(steps))
                    var stepLine = Path()
                    stepLine.move(to: CGPoint(x: rect.minX, y: sy))
                    stepLine.addLine(to: CGPoint(x: rect.maxX, y: sy))
                    local.stroke(stepLine, with: .color(strokeColor), lineWidth: 1)
                }
                var arrow = Path()
                arrow.move(to: CGPoint(x: 0, y: rect.maxY - 6))
                arrow.addLine(to: CGPoint(x: 0, y: rect.minY + 6))
                arrow.addLine(to: CGPoint(x: -5, y: rect.minY + 12))
                arrow.move(to: CGPoint(x: 0, y: rect.minY + 6))
                arrow.addLine(to: CGPoint(x: 5, y: rect.minY + 12))
                local.stroke(arrow, with: .color(strokeColor), lineWidth: 1.2)

            default:
                let box = Path(roundedRect: rect, cornerRadius: 4)
                local.stroke(box, with: .color(strokeColor), lineWidth: 1.2)
            }
        }
    }

    private func screenPolygonPath(for box: FloorplanBox) -> Path {
        var path = Path()
        let pts = box.effectivePoints
        for (idx, p) in pts.enumerated() {
            let sp = worldToScreen(CGPoint(x: p.x, y: p.y))
            if idx == 0 { path.move(to: sp) } else { path.addLine(to: sp) }
        }
        path.closeSubpath()
        return path
    }

    private func drawLightHalos(in ctx: inout GraphicsContext) {
        let boost = ambientMode == .night ? 1.45 : (ambientMode == .dusk ? 1.20 : 1.0)
        for light in placedLights where light.on {
            guard let placement = store.floorplan.lamps[light.id] else { continue }
            let center = worldToScreen(CGPoint(x: placement.x, y: placement.y))
            let briFactor = max(0.18, min(1.0, light.bri / 100.0))
            let radius = CGFloat(54.0 + light.bri * 0.95) * zoom
            let base = Color(hex: light.color)
            let gradient = Gradient(stops: [
                .init(color: base.opacity(min(0.85, 0.44 * briFactor * boost)), location: 0.0),
                .init(color: base.opacity(min(0.55, 0.18 * briFactor * boost)), location: 0.48),
                .init(color: base.opacity(0.0), location: 1.0),
            ])
            let enclosing = FloorplanSpatial.boxContaining(x: placement.x, y: placement.y, in: activeFloorBoxes, kindFilter: "room")
            var local = ctx
            if let roomBox = enclosing {
                local.clip(to: screenPolygonPath(for: roomBox))
            }
            local.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(gradient, center: center, startRadius: 4, endRadius: radius)
            )
        }
    }

    private func drawPlannedLightsAndStrips(in ctx: inout GraphicsContext) {
        let boost = ambientMode == .night ? 1.55 : (ambientMode == .dusk ? 1.25 : 1.0)
        let pxPerM = store.floorplan.pxPerMeter
        for planned in activeFloorPlannedLights {
            let base = Color(hex: planned.colorHex)
            let lumenScale = max(0.35, min(1.2, Double(planned.lumens) / 1400.0))
            let radius = CGFloat(planned.beamRadius * pxPerM) * zoom
            let anchor = planned.anchorPoint
            let enclosing = FloorplanSpatial.boxContaining(x: anchor.x, y: anchor.y, in: activeFloorBoxes, kindFilter: "room")

            if let strip = planned.stripPoints, strip.count >= 2 {
                var stripPath = Path()
                for (i, pt) in strip.enumerated() {
                    let sp = worldToScreen(CGPoint(x: pt.x, y: pt.y))
                    if i == 0 { stripPath.move(to: sp) } else { stripPath.addLine(to: sp) }
                }
                if planned.on {
                    var glowCtx = ctx
                    if let roomBox = enclosing { glowCtx.clip(to: screenPolygonPath(for: roomBox)) }
                    glowCtx.stroke(
                        stripPath,
                        with: .color(base.opacity(min(0.65, 0.24 * lumenScale * boost))),
                        style: StrokeStyle(lineWidth: max(18, radius * 0.42), lineCap: .round, lineJoin: .round)
                    )
                    glowCtx.stroke(
                        stripPath,
                        with: .color(base.opacity(min(0.9, 0.55 * lumenScale * boost))),
                        style: StrokeStyle(lineWidth: max(8, 12 * zoom), lineCap: .round, lineJoin: .round)
                    )
                }
                ctx.stroke(
                    stripPath,
                    with: .color(planned.on ? base : Color.secondary.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round, dash: [6, 4])
                )
            } else if planned.on {
                let center = worldToScreen(CGPoint(x: planned.x, y: planned.y))
                let gradient = Gradient(stops: [
                    .init(color: base.opacity(min(0.85, 0.42 * lumenScale * boost)), location: 0.0),
                    .init(color: base.opacity(min(0.50, 0.16 * lumenScale * boost)), location: 0.50),
                    .init(color: base.opacity(0.0), location: 1.0),
                ])
                var local = ctx
                if let roomBox = enclosing { local.clip(to: screenPolygonPath(for: roomBox)) }
                local.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(gradient, center: center, startRadius: 4, endRadius: radius)
                )
            }
        }
    }

    private func worldAnchor(for endpoint: WireEndpoint) -> CGPoint? {
        if endpoint.kind == "light", let p = store.floorplan.lamps[endpoint.id] {
            return CGPoint(x: p.x, y: p.y)
        }
        if (endpoint.kind == "motion" || endpoint.kind == "contact" || endpoint.kind == "button"),
           let p = store.floorplan.sensors[endpoint.id] {
            return CGPoint(x: p.x, y: p.y)
        }
        if endpoint.kind == "motion_area",
           let area = store.snapshot.motionArea(endpoint.id),
           let box = store.floorplan.boxes.first(where: { $0.hueID == area.roomID }) {
            return CGPoint(x: box.centerX, y: box.minY + 18)
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
            activeRuleDialog = .edit(item.rule)
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
        .help(item.rule.name.isEmpty ? store.tr("Edit Rule") : item.rule.name)
    }

    /// Finds the closest visible dependency rule whose Bezier curve passes within `maxDistance` points
    /// of `screenPoint`, using sampled cubic curve segments so clicking anywhere along a line works.
    private func hitTestRule(at screenPoint: CGPoint, maxDistance: CGFloat = 12.0) -> HueRule? {
        var best: (rule: HueRule, dist: CGFloat)? = nil
        let segments = 24
        for rule in store.rules {
            guard let srcWorld = worldAnchor(for: WireEndpoint(kind: rule.triggerKind, id: rule.triggerID)) else { continue }
            let p0 = worldToScreen(srcWorld)
            for target in rule.targets {
                guard let dstWorld = worldAnchor(for: WireEndpoint(kind: target.kind, id: target.id)) else { continue }
                let p1 = worldToScreen(dstWorld)
                let (c1, c2) = cubicControlPoints(from: p0, to: p1)
                var prev = p0
                for i in 1...segments {
                    let t = CGFloat(i) / CGFloat(segments)
                    let curr = evalCubic(p0, c1, c2, p1, t: t)
                    let d = distanceFromPoint(screenPoint, toSegment: prev, curr)
                    if d <= maxDistance, (best == nil || d < best!.dist) {
                        best = (rule, d)
                    }
                    prev = curr
                }
            }
        }
        return best?.rule
    }

    private func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        if lenSq <= 0.0001 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq))
        let projX = a.x + t * abx
        let projY = a.y + t * aby
        return hypot(p.x - projX, p.y - projY)
    }

    // MARK: - Interactive Furniture Stamp Overlay (Map Mode)

    private func stampEditOverlay(_ stamp: FloorplanStamp) -> some View {
        let center = worldToScreen(CGPoint(x: stamp.x + stamp.width / 2, y: stamp.y + stamp.height / 2))
        let w = max(32, CGFloat(stamp.width) * zoom)
        let h = max(24, CGFloat(stamp.height) * zoom)
        let isSelected = selectedStampID == stamp.id
        let isHovered = hoveredStampID == stamp.id

        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isSelected ? store.skinAccentColor : (isHovered ? Color.primary.opacity(0.22) : Color.clear),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: [4, 3])
                )
                .background(Color.clear)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredStampID = stamp.id
                    } else if hoveredStampID == stamp.id {
                        hoveredStampID = nil
                    }
                }
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
        let roomMotionArea = box.hueID.flatMap { store.motionArea(forRoom: $0) }
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
            motionArea: roomMotionArea,
            width: w,
            height: h,
            zoom: zoom,
            mode: mode,
            isSelected: isSelected,
            tintColor: tintColor,
            lit: lit,
            onSelect: {
                if mode == .rules, let hueID = box.hueID {
                    let endpoint = WireEndpoint(kind: "room", id: hueID)
                    if let armed = armedRuleSource, armed != endpoint {
                        activeRuleDialog = .create(source: armed, target: endpoint)
                        armedRuleSource = nil
                        return
                    }
                }
                selectedBoxID = box.id
                selectedLightID = nil
                selectedSensorID = nil
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
                        guard let p = store.floorplan.lamps[light.id], p.floorID == box.floorID else { return false }
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
        let isArmed = mode == .rules && armedRuleSource == WireEndpoint(kind: "light", id: light.id)

        return FloorplanLampNodeView(
            light: light,
            placement: placement,
            zoom: zoom,
            mode: mode,
            isSelected: isSelected,
            isArmedSource: isArmed,
            onTap: {
                selectedLightID = light.id
                selectedSensorID = nil
                selectedBoxID = nil
                selectedStampID = nil
                if mode == .rules {
                    let tapped = WireEndpoint(kind: "light", id: light.id)
                    if let armed = armedRuleSource {
                        if armed == tapped {
                            armedRuleSource = nil
                        } else {
                            activeRuleDialog = .create(source: armed, target: tapped)
                            armedRuleSource = nil
                        }
                    } else {
                        armedRuleSource = tapped
                    }
                }
            },
            onHoverChanged: { hovering in
                if hovering {
                    hoveredLightID = light.id
                } else if hoveredLightID == light.id {
                    hoveredLightID = nil
                }
            },
            onOpenBrightness: {
                activeLampDialog = .brightness(light.id)
            },
            onOpenRename: {
                activeLampDialog = .rename(light.id)
            },
            onOpenIcon: {
                activeLampDialog = .icon(light.id)
            },
            onMove: { screenPoint, finalize in
                let w = screenToWorld(screenPoint)
                store.moveLamp(light.id, to: Double(w.x), y: Double(w.y), finalize: finalize)
            },
            onWireDragChanged: { screenPoint in
                armedRuleSource = nil
                wireDraftSource = WireEndpoint(kind: "light", id: light.id)
                wireDraftWorldPoint = screenToWorld(screenPoint)
            },
            onWireDragEnded: { screenPoint in
                finishWireDrag(from: WireEndpoint(kind: "light", id: light.id), atScreen: screenPoint)
            }
        )
        .position(pos)
        .zIndex(hoveredLightID == light.id ? 100 : (isSelected || isArmed ? 10 : 1))
    }

    private func sensorNodeLayer(sensor: HueSensor, placement: FloorplanSensorPlacement) -> some View {
        let pos = worldToScreen(CGPoint(x: placement.x, y: placement.y))
        let isSelected = selectedSensorID == sensor.id
        let isArmed = mode == .rules && armedRuleSource == WireEndpoint(kind: sensor.kind, id: sensor.id)

        return FloorplanSensorNodeView(
            sensor: sensor,
            symbol: sensorSymbol(for: sensor),
            accentColor: sensorAccentColor(for: sensor),
            statusText: sensorStatusText(for: sensor),
            zoom: zoom,
            mode: mode,
            isSelected: isSelected,
            isArmedSource: isArmed,
            onTap: {
                selectedSensorID = sensor.id
                selectedLightID = nil
                selectedBoxID = nil
                selectedStampID = nil
                if mode == .rules {
                    let tapped = WireEndpoint(kind: sensor.kind, id: sensor.id)
                    if armedRuleSource == tapped {
                        armedRuleSource = nil
                    } else {
                        armedRuleSource = tapped
                    }
                }
            },
            onHoverChanged: { hovering in
                if hovering {
                    hoveredSensorID = sensor.id
                } else if hoveredSensorID == sensor.id {
                    hoveredSensorID = nil
                }
            },
            onWireFromHere: {
                mode = .rules
                selectedSensorID = sensor.id
                selectedLightID = nil
                armedRuleSource = WireEndpoint(kind: sensor.kind, id: sensor.id)
            },
            onMove: { screenPoint, finalize in
                let w = screenToWorld(screenPoint)
                store.moveSensor(sensor.id, to: Double(w.x), y: Double(w.y), finalize: finalize)
            },
            onWireDragChanged: { screenPoint in
                armedRuleSource = nil
                wireDraftSource = WireEndpoint(kind: sensor.kind, id: sensor.id)
                wireDraftWorldPoint = screenToWorld(screenPoint)
            },
            onWireDragEnded: { screenPoint in
                finishWireDrag(from: WireEndpoint(kind: sensor.kind, id: sensor.id), atScreen: screenPoint)
            }
        )
        .position(pos)
        .zIndex(hoveredSensorID == sensor.id ? 100 : (isSelected || isArmed ? 12 : 2))
    }

    // MARK: - Interactive Planned Light & Bendable LED Strip Nodes

    @ViewBuilder
    private func plannedLightNodeLayer(_ planned: PlannedLight) -> some View {
        let isSelected = selectedPlannedID == planned.id
        let anchor = planned.anchorPoint
        let pos = worldToScreen(CGPoint(x: anchor.x, y: anchor.y))
        let base = Color(hex: planned.colorHex)

        // Draggable LED strip vertices + midpoint '+' handles when selected
        if let strip = planned.stripPoints, strip.count >= 2, (isSelected || mode == .plan) {
            ForEach(Array(strip.enumerated()), id: \.offset) { idx, pt in
                let sp = worldToScreen(CGPoint(x: pt.x, y: pt.y))
                Circle()
                    .fill(isSelected ? store.skinAccentColor : base)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(sp)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("floorplanCanvas"))
                            .onChanged { val in
                                selectedPlannedID = planned.id
                                var copy = planned
                                if var pts = copy.stripPoints, pts.indices.contains(idx) {
                                    let w = screenToWorld(val.location)
                                    pts[idx] = FloorplanPoint(x: Double(w.x), y: Double(w.y))
                                    copy.stripPoints = pts
                                    store.updatePlannedLight(copy, finalize: false)
                                }
                            }
                            .onEnded { val in
                                var copy = planned
                                if var pts = copy.stripPoints, pts.indices.contains(idx) {
                                    let w = screenToWorld(val.location)
                                    pts[idx] = FloorplanPoint(x: store.floorplan.snapped(Double(w.x)), y: store.floorplan.snapped(Double(w.y)))
                                    copy.stripPoints = pts
                                    store.updatePlannedLight(copy, finalize: true)
                                }
                            }
                    )
                    .contextMenu {
                        if strip.count > 2 {
                            Button(store.tr("Remove Corner"), role: .destructive) {
                                var copy = planned
                                if var pts = copy.stripPoints, pts.count > 2, pts.indices.contains(idx) {
                                    pts.remove(at: idx)
                                    copy.stripPoints = pts
                                    store.updatePlannedLight(copy, finalize: true)
                                }
                            }
                        }
                    }
            }
            if isSelected {
                ForEach(0..<(strip.count - 1), id: \.self) { edgeIdx in
                    let a = strip[edgeIdx]
                    let b = strip[edgeIdx + 1]
                    let mid = worldToScreen(CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5))
                    Button {
                        var copy = planned
                        if var pts = copy.stripPoints, pts.count < 24 {
                            pts.insert(FloorplanPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5), at: edgeIdx + 1)
                            copy.stripPoints = pts
                            store.updatePlannedLight(copy, finalize: true)
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(store.skinAccentColor))
                    }
                    .buttonStyle(.plain)
                    .position(mid)
                }
            }
        }

        // Main planned fixture badge (dashed blueprint circle + lumen tag)
        let size: CGFloat = max(26, min(36, 30 * zoom))
        ZStack {
            Circle()
                .fill(planned.on ? base.opacity(0.88) : Color(NSColor.controlBackgroundColor).opacity(0.9))
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? store.skinAccentColor : Color.white.opacity(0.9),
                        style: StrokeStyle(lineWidth: isSelected ? 2.4 : 1.6, dash: [4, 2.5])
                    )
                )
                .frame(width: size, height: size)
            Image(systemName: planned.icon.sfSymbol(lit: planned.on))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(planned.on ? Color.black.opacity(0.85) : Color.secondary)
        }
        .overlay(alignment: .bottom) {
            Text("\(planned.lumens) lm")
                .font(store.scaledFont(8.5, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(.regularMaterial))
                .offset(y: 12)
                .allowsHitTesting(false)
        }
        .position(pos)
        .help("\(planned.name) · \(planned.lumens) lm · \(planned.kelvin) K")
        .onTapGesture(count: 2) {
            editingPlannedLightID = planned.id
        }
        .onTapGesture {
            selectedPlannedID = planned.id
            selectedBoxID = nil
            store.togglePlannedLight(id: planned.id)
        }
        .contextMenu {
            Button(planned.on ? store.tr("Turn off") : store.tr("Turn on")) {
                store.togglePlannedLight(id: planned.id)
            }
            Button(store.tr("Edit Planned Fixture")) {
                editingPlannedLightID = planned.id
            }
            Divider()
            Button(store.tr("Delete"), role: .destructive) {
                store.deletePlannedLight(id: planned.id)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("floorplanCanvas"))
                .onChanged { val in
                    selectedPlannedID = planned.id
                    let w = screenToWorld(val.location)
                    let dx = Double(w.x) - anchor.x
                    let dy = Double(w.y) - anchor.y
                    store.updatePlannedLight(planned.translated(dx: dx, dy: dy), finalize: false)
                }
                .onEnded { val in
                    let w = screenToWorld(val.location)
                    let dx = store.floorplan.snapped(Double(w.x)) - anchor.x
                    let dy = store.floorplan.snapped(Double(w.y)) - anchor.y
                    store.updatePlannedLight(planned.translated(dx: dx, dy: dy), finalize: true)
                }
        )
        .zIndex(isSelected ? 16 : 6)
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
            if d <= 44.0, (bestLight == nil || d < bestLight!.dist) {
                bestLight = (light.id, d)
            }
        }
        if let hit = bestLight {
            activeRuleDialog = .create(source: source, target: WireEndpoint(kind: "light", id: hit.id))
            return
        }

        // 2) Check linked Room boxes containing the drop point on the active floor
        if let box = FloorplanSpatial.boxContaining(x: Double(worldPt.x), y: Double(worldPt.y), in: activeFloorBoxes, kindFilter: nil),
           let hueID = box.hueID {
            let target = WireEndpoint(kind: "room", id: hueID)
            if target != source {
                activeRuleDialog = .create(source: source, target: target)
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

        for b in activeFloorBoxes {
            minX = min(minX, b.minX)
            minY = min(minY, b.minY)
            maxX = max(maxX, b.maxX)
            maxY = max(maxY, b.maxY)
        }
        for p in store.floorplan.lamps.values where p.floorID == store.floorplan.activeFloorID {
            minX = min(minX, p.x - 40)
            minY = min(minY, p.y - 40)
            maxX = max(maxX, p.x + 40)
            maxY = max(maxY, p.y + 40)
        }
        for p in store.floorplan.sensors.values where p.floorID == store.floorplan.activeFloorID {
            minX = min(minX, p.x - 40)
            minY = min(minY, p.y - 40)
            maxX = max(maxX, p.x + 40)
            maxY = max(maxY, p.y + 40)
        }
        for pl in activeFloorPlannedLights {
            let a = pl.anchorPoint
            minX = min(minX, a.x - 40)
            minY = min(minY, a.y - 40)
            maxX = max(maxX, a.x + 40)
            maxY = max(maxY, a.y + 40)
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
        case "stairs": return store.tr("Stairs")
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
        case "stairs": return "stairs"
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
    let motionArea: HueMotionArea?
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    let mode: MapView.MapMode
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
    @State private var dragStartSensors: [String: (Double, Double)] = [:]

    var body: some View {
        let isZone = box.kind == "zone"
        let borderStyle = StrokeStyle(
            lineWidth: isSelected ? 2.2 : (isZone ? 1.4 : 1.8),
            dash: isZone ? [7, 4] : []
        )
        let polyShape = FloorplanPolygonShape(
            points: box.effectivePoints,
            minX: box.x,
            minY: box.y,
            width: box.width,
            height: box.height
        )
        let lightingStats = mode == .plan
            ? RoomLightingAnalysis.compute(for: box, floorplan: store.floorplan, snapshot: store.snapshot, includePlanned: true)
            : nil

        ZStack(alignment: .topLeading) {
            // Room surface fill + architectural polygon wall outline (pass-through so wires & canvas panning work cleanly)
            if box.isPolygon {
                polyShape
                    .fill(lit ? tintColor.opacity(0.11) : Color.primary.opacity(0.035))
                    .overlay(
                        polyShape.stroke(
                            isSelected ? store.skinAccentColor : (lit ? tintColor.opacity(0.55) : Color.primary.opacity(0.28)),
                            style: borderStyle
                        )
                    )
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: isZone ? 10 : 6, style: .continuous)
                    .fill(lit ? tintColor.opacity(0.11) : Color.primary.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: isZone ? 10 : 6, style: .continuous)
                            .strokeBorder(
                                isSelected ? store.skinAccentColor : (lit ? tintColor.opacity(0.55) : Color.primary.opacity(0.24)),
                                style: borderStyle
                            )
                    )
                    .allowsHitTesting(false)
            }

            // Header bar (name, m², Plan-mode lux badge, schedule badge, scenes, inspector, power)
            let screenBoxW = CGFloat(box.width) * zoom
            HStack(spacing: 4) {
                Image(systemName: boxSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(lit ? tintColor : Color.secondary)

                Text(box.name)
                    .font(store.scaledFont(11, weight: .semibold))
                    .lineLimit(1)

                if screenBoxW >= 155, let room = linkedRoom {
                    Text("\(room.onCount)/\(room.lights.count)")
                        .font(store.scaledFont(9.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if screenBoxW >= 200 {
                    Text(String(format: "%.0f m²", box.areaSquareMeters(pxPerMeter: store.floorplan.pxPerMeter)))
                        .font(store.scaledFont(8.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                if screenBoxW >= 180, let stats = lightingStats {
                    let lxColor: Color = stats.rating == "balanced" ? .green : (stats.rating == "dim" ? .orange : .cyan)
                    Text("\(stats.lux) lx")
                        .font(store.scaledFont(8.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(lxColor)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(lxColor.opacity(0.16)))
                }

                if screenBoxW >= 170, let area = motionArea, area.enabled {
                    let active = area.motion
                    HStack(spacing: 2.5) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 8.5, weight: .semibold))
                        if active {
                            Circle()
                                .fill(Color(hex: "#10b981"))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(active ? Color(hex: "#10b981") : Color(hex: "#06b6d4"))
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill((active ? Color(hex: "#10b981") : Color(hex: "#06b6d4")).opacity(active ? 0.18 : 0.10))
                    )
                    .help(active ? store.tr("MotionAware presence detected") : store.tr("MotionAware active"))
                }

                if screenBoxW >= 230, let firstSched = schedules.first {
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
                    .accessibilityLabel(store.tr("Scenes & Schedule"))
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
                .accessibilityLabel(store.tr("Edit Room / Zone"))
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
                .accessibilityLabel(lit ? store.tr("Turn off") : store.tr("Turn on"))
                .help(lit ? store.tr("Turn off") : store.tr("Turn on"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: isZone ? 9 : 5, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .gesture(moveBoxGesture, including: (mode == .map || mode == .plan) ? .all : .none)

            // Polygon Vertex & Wall-Split '+' Handles + Bounding Resize Handles when selected in Map/Plan mode
            if (mode == .map || mode == .plan) && isSelected {
                if box.isPolygon {
                    polygonHandlesOverlay
                } else {
                    resizeHandlesOverlay
                    wallMidpointSplitOverlay
                }
            }

            // Right-edge connector port in Rules mode (for linked Bridge rooms)
            if mode == .rules && box.hueID != nil {
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
                        (p.floorID == box.floorID && box.contains(x: p.x, y: p.y)) ? lid : nil
                    }
                    var starts: [String: (Double, Double)] = [:]
                    for lid in dragEnclosedIDs {
                        if let p = store.floorplan.lamps[lid] { starts[lid] = (p.x, p.y) }
                    }
                    dragStartLamps = starts
                    var sensorStarts: [String: (Double, Double)] = [:]
                    for (sid, p) in store.floorplan.sensors where p.floorID == box.floorID && box.contains(x: p.x, y: p.y) {
                        sensorStarts[sid] = (p.x, p.y)
                    }
                    dragStartSensors = sensorStarts
                }
                guard let orig = dragStartBox else { return }
                let dx = Double(value.translation.width / max(0.2, zoom))
                let dy = Double(value.translation.height / max(0.2, zoom))
                let next = orig.translated(dx: dx, dy: dy)
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
                for (sid, startPos) in dragStartSensors {
                    if var sensor = store.floorplan.sensors[sid] {
                        sensor.x = startPos.0 + dx
                        sensor.y = startPos.1 + dy
                        store.floorplan.sensors[sid] = sensor
                    }
                }
            }
            .onEnded { value in
                guard let orig = dragStartBox else { return }
                let dx = Double(value.translation.width / max(0.2, zoom))
                let dy = Double(value.translation.height / max(0.2, zoom))
                let snappedX = store.floorplan.snapped(orig.x + dx)
                let snappedY = store.floorplan.snapped(orig.y + dy)
                let snappedDX = snappedX - orig.x
                let snappedDY = snappedY - orig.y
                let next = orig.translated(dx: snappedDX, dy: snappedDY)
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
                for (sid, startPos) in dragStartSensors {
                    if var sensor = store.floorplan.sensors[sid] {
                        sensor.x = startPos.0 + snappedDX
                        sensor.y = startPos.1 + snappedDY
                        store.floorplan.sensors[sid] = sensor
                    }
                }
                dragStartBox = nil
                dragEnclosedIDs = []
                dragStartLamps = [:]
                dragStartSensors = [:]
                store.persistFloorplan()
            }
    }

    private func localPoint(for world: FloorplanPoint) -> CGPoint {
        let sx = CGFloat(world.x - box.x) * (width / max(1.0, CGFloat(box.width)))
        let sy = CGFloat(world.y - box.y) * (height / max(1.0, CGFloat(box.height)))
        return CGPoint(x: sx, y: sy)
    }

    /// Wall midpoint '+' handles & wall length tags for splitting any wall into a bendable corner.
    private var wallMidpointSplitOverlay: some View {
        let segs = box.wallSegments
        let pxPerM = store.floorplan.pxPerMeter
        return ForEach(segs, id: \.index) { seg in
            let mp = localPoint(for: seg.mid)
            if seg.lengthPx * Double(zoom) >= 44 {
                VStack(spacing: 1) {
                    Button {
                        store.insertBoxVertex(boxID: box.id, afterEdge: seg.index, at: seg.mid)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(store.skinAccentColor.opacity(0.88)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .help(store.tr("Add wall corner here"))

                    Text(String(format: "%.1f m", seg.lengthPx / max(10.0, pxPerM)))
                        .font(store.scaledFont(8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .allowsHitTesting(false)
                }
                .position(mp)
            }
        }
    }

    /// Draggable polygon corner vertices + wall midpoint '+' split handles (double-click or right-click vertex to remove).
    private var polygonHandlesOverlay: some View {
        let pts = box.effectivePoints
        return ZStack {
            wallMidpointSplitOverlay
            ForEach(Array(pts.enumerated()), id: \.offset) { idx, pt in
                let lp = localPoint(for: pt)
                ZStack {
                    Circle()
                        .fill(store.skinAccentColor)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .position(lp)
                .accessibilityLabel(store.trf("Corner {0}", [String(idx + 1)]))
                .help(store.tr("Drag corner to reshape room (right-click to delete corner)"))
                .onTapGesture(count: 2) {
                    if pts.count > 3 {
                        store.removeBoxVertex(boxID: box.id, vertexIndex: idx)
                    }
                }
                .contextMenu {
                    if pts.count > 3 {
                        Button(store.tr("Remove Corner"), role: .destructive) {
                            store.removeBoxVertex(boxID: box.id, vertexIndex: idx)
                        }
                    }
                    Button(store.tr("Reset to Rectangle")) {
                        store.reshapeBox(id: box.id, shape: .rectangle)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { val in
                            if dragStartBox == nil { dragStartBox = box }
                            guard let orig = dragStartBox else { return }
                            let origPts = orig.effectivePoints
                            guard origPts.indices.contains(idx) else { return }
                            let dx = Double(val.translation.width / max(0.2, zoom))
                            let dy = Double(val.translation.height / max(0.2, zoom))
                            let target = FloorplanPoint(x: origPts[idx].x + dx, y: origPts[idx].y + dy)
                            store.moveBoxVertex(boxID: box.id, vertexIndex: idx, to: target, finalize: false)
                        }
                        .onEnded { val in
                            guard let orig = dragStartBox else { return }
                            let origPts = orig.effectivePoints
                            guard origPts.indices.contains(idx) else { dragStartBox = nil; return }
                            let dx = Double(val.translation.width / max(0.2, zoom))
                            let dy = Double(val.translation.height / max(0.2, zoom))
                            let target = FloorplanPoint(x: origPts[idx].x + dx, y: origPts[idx].y + dy)
                            store.moveBoxVertex(boxID: box.id, vertexIndex: idx, to: target, finalize: true)
                            dragStartBox = nil
                        }
                )
            }
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
        var nextX = orig.x
        var nextY = orig.y
        var nextW = orig.width
        var nextH = orig.height

        switch edge {
        case .topLeft:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            nextX = finalize ? store.floorplan.snapped(newX) : newX
            nextY = finalize ? store.floorplan.snapped(newY) : newY
            nextW = max(FloorplanBox.minWidth, orig.maxX - nextX)
            nextH = max(FloorplanBox.minHeight, orig.maxY - nextY)
        case .top:
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            nextY = finalize ? store.floorplan.snapped(newY) : newY
            nextH = max(FloorplanBox.minHeight, orig.maxY - nextY)
        case .topRight:
            let newY = min(orig.maxY - FloorplanBox.minHeight, orig.y + dy)
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            nextY = finalize ? store.floorplan.snapped(newY) : newY
            nextH = max(FloorplanBox.minHeight, orig.maxY - nextY)
            nextW = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
        case .right:
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            nextW = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
        case .bottomRight:
            let newW = max(FloorplanBox.minWidth, orig.width + dx)
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            nextW = finalize ? max(FloorplanBox.minWidth, store.floorplan.snapped(newW)) : newW
            nextH = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .bottom:
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            nextH = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .bottomLeft:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            let newH = max(FloorplanBox.minHeight, orig.height + dy)
            nextX = finalize ? store.floorplan.snapped(newX) : newX
            nextW = max(FloorplanBox.minWidth, orig.maxX - nextX)
            nextH = finalize ? max(FloorplanBox.minHeight, store.floorplan.snapped(newH)) : newH
        case .left:
            let newX = min(orig.maxX - FloorplanBox.minWidth, orig.x + dx)
            nextX = finalize ? store.floorplan.snapped(newX) : newX
            nextW = max(FloorplanBox.minWidth, orig.maxX - nextX)
        }
        let next = orig.scaledTo(x: nextX, y: nextY, width: nextW, height: nextH)
        store.updateFloorplanBox(next, finalize: finalize)
    }
}

// MARK: - Interactive Lamp Node Component

private struct FloorplanLampNodeView: View {
    @EnvironmentObject var store: HueStore

    let light: HueLight
    let placement: FloorplanLampPlacement
    let zoom: CGFloat
    let mode: MapView.MapMode
    let isSelected: Bool
    let isArmedSource: Bool

    let onTap: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onOpenBrightness: () -> Void
    let onOpenRename: () -> Void
    let onOpenIcon: () -> Void
    let onMove: (CGPoint, Bool) -> Void
    let onWireDragChanged: (CGPoint) -> Void
    let onWireDragEnded: (CGPoint) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let nodeSize = max(28, min(40, 34 * zoom))
        let fillColor = light.on ? Color(hex: light.color) : Color(NSColor.controlBackgroundColor)
        let glyphColor: Color = light.on ? (prefersDarkGlyph(light.color) ? .black : .white) : .secondary

        ZStack {
            if isArmedSource {
                Circle()
                    .strokeBorder(store.skinAccentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: nodeSize + 10, height: nodeSize + 10)
            }

            Circle()
                .fill(fillColor)
                .overlay(
                    Circle().strokeBorder(
                        (isSelected || isArmedSource) ? store.skinAccentColor : (light.on ? Color.white.opacity(0.88) : Color.primary.opacity(0.28)),
                        lineWidth: (isSelected || isArmedSource) ? 2.5 : 1.5
                    )
                )
                .shadow(color: light.on ? Color(hex: light.color).opacity(0.55) : Color.black.opacity(0.18), radius: light.on ? 7 : 2)
                .frame(width: nodeSize, height: nodeSize)

            Image(systemName: placement.icon.sfSymbol(lit: light.on))
                .font(.system(size: nodeSize * 0.48, weight: .semibold))
                .foregroundStyle(glyphColor)

            if light.motionAware {
                let badgeSize = max(13, min(16, nodeSize * 0.42))
                let badgeColor = light.motionActive ? Color(hex: "#10b981") : Color(hex: "#06b6d4")
                ZStack {
                    Circle()
                        .fill(badgeColor)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 1.1))
                        .shadow(color: light.motionActive ? badgeColor.opacity(0.75) : Color.black.opacity(0.22), radius: light.motionActive ? 5 : 2)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: badgeSize * 0.56, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: badgeSize, height: badgeSize)
                .offset(x: nodeSize * 0.36, y: -nodeSize * 0.36)
                .allowsHitTesting(false)
            }
        }
        .frame(width: nodeSize, height: nodeSize)
        .contentShape(Circle())
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
        .overlay(alignment: .top) {
            if isHovered {
                Text(light.name)
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
                    .shadow(color: Color.black.opacity(0.16), radius: 4, y: 2)
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
        .help(light.name)
        .onTapGesture { onTap() }
        .contextMenu {
            Button(light.on ? store.tr("Turn off") : store.tr("Turn on")) {
                store.setLight(light, on: !light.on)
            }
            Button(store.tr("Brightness…")) { onOpenBrightness() }
            Button(store.tr("Rename…")) { onOpenRename() }
            Button(store.tr("Lamp icon…")) { onOpenIcon() }
            Divider()
            Button(store.tr("Remove from map"), role: .destructive) {
                store.unplaceLamp(light.id)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("floorplanCanvas"))
                .onChanged { value in
                    switch mode {
                    case .map, .plan:
                        onMove(value.location, false)
                    case .rules:
                        onWireDragChanged(value.location)
                    }
                }
                .onEnded { value in
                    switch mode {
                    case .map, .plan:
                        onMove(value.location, true)
                    case .rules:
                        onWireDragEnded(value.location)
                    }
                }
        )
    }
}

// MARK: - Interactive Physical Hue Sensor Node Component (Rounded Square)

private struct FloorplanSensorNodeView: View {
    @EnvironmentObject var store: HueStore

    let sensor: HueSensor
    let symbol: String
    let accentColor: Color
    let statusText: String
    let zoom: CGFloat
    let mode: MapView.MapMode
    let isSelected: Bool
    let isArmedSource: Bool

    let onTap: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onWireFromHere: () -> Void
    let onMove: (CGPoint, Bool) -> Void
    let onWireDragChanged: (CGPoint) -> Void
    let onWireDragEnded: (CGPoint) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let nodeSize = max(26, min(36, 30 * zoom))
        let isActive = sensor.enabled && ((sensor.kind == "motion" && sensor.motion) || (sensor.kind == "contact" && sensor.open))
        let bgFill: Color = isActive ? accentColor : Color(NSColor.controlBackgroundColor)
        let fgColor: Color = isActive ? Color.white : accentColor
        let cornerRadius: CGFloat = 8

        ZStack {
            if isArmedSource {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(store.skinAccentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: nodeSize + 10, height: nodeSize + 10)
            }

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bgFill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            (isSelected || isArmedSource) ? store.skinAccentColor : (isActive ? Color.white.opacity(0.9) : accentColor.opacity(sensor.enabled ? 0.65 : 0.30)),
                            lineWidth: (isSelected || isArmedSource) ? 2.4 : 1.5
                        )
                )
                .shadow(color: isActive ? accentColor.opacity(0.6) : Color.black.opacity(0.18), radius: isActive ? 7 : 2)
                .frame(width: nodeSize, height: nodeSize)

            Image(systemName: symbol)
                .font(.system(size: nodeSize * 0.46, weight: .semibold))
                .foregroundStyle(fgColor)
                .opacity(sensor.enabled ? 1.0 : 0.5)
        }
        .frame(width: nodeSize, height: nodeSize)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
        .overlay(alignment: .top) {
            if isHovered {
                VStack(spacing: 1) {
                    Text(sensor.name)
                        .font(store.scaledFont(10.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(store.scaledFont(9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
                .shadow(color: Color.black.opacity(0.16), radius: 4, y: 2)
                .offset(y: -36)
                .allowsHitTesting(false)
                .zIndex(100)
            }
        }
        .help(statusText.isEmpty ? sensor.name : "\(sensor.name) · \(statusText)")
        .onTapGesture { onTap() }
        .contextMenu {
            if sensor.kind == "motion" || sensor.kind == "contact" {
                Button(sensor.enabled ? store.tr("Disable") : store.tr("Enable")) {
                    store.setSensorEnabled(sensor, enabled: !sensor.enabled)
                }
            }
            Button(store.tr("Wire from here")) {
                onWireFromHere()
            }
            Divider()
            Button(store.tr("Remove from map"), role: .destructive) {
                store.unplaceSensor(sensor.id)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("floorplanCanvas"))
                .onChanged { value in
                    switch mode {
                    case .map, .plan:
                        onMove(value.location, false)
                    case .rules:
                        onWireDragChanged(value.location)
                    }
                }
                .onEnded { value in
                    switch mode {
                    case .map, .plan:
                        onMove(value.location, true)
                    case .rules:
                        onWireDragEnded(value.location)
                    }
                }
        )
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
    @State private var floorID: String = "eg"
    @State private var confirmDeleteOnBridge: Bool = false

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
        ScrollView {
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
                    .labelsHidden()
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
                Text(store.tr("Room Shape"))
                    .font(store.scaledFont(10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(FloorplanRoomShape.allCases) { shape in
                        Button(store.tr(shape.titleKey)) {
                            store.reshapeBox(id: box.id, shape: shape)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }

            if store.floorplan.floors.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.tr("Floor"))
                        .font(store.scaledFont(10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $floorID) {
                        ForEach(store.floorplan.floors) { f in
                            Text(f.name).tag(f.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
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

            if let roomID = box.hueID, let area = store.motionArea(forRoom: roomID) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(area.enabled && area.motion ? Color(hex: "#10b981") : Color(hex: "#06b6d4"))
                        Text(store.tr("MotionAware™"))
                            .font(store.scaledFont(10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if area.enabled && area.motion {
                            Text(store.tr("Presence"))
                                .font(store.scaledFont(9.5, weight: .semibold))
                                .foregroundStyle(Color(hex: "#10b981"))
                        }
                    }

                    Toggle(store.tr("Enabled"), isOn: Binding(
                        get: { area.enabled },
                        set: { store.updateMotionArea(area, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(store.scaledFont(11.5))

                    if let sens = area.sensitivity {
                        let maxSens = max(1, area.sensitivityMax ?? 4)
                        Stepper(value: Binding(
                            get: { sens },
                            set: { store.updateMotionArea(area, sensitivity: $0) }
                        ), in: 0...maxSens) {
                            Text(store.trf("Sensitivity: {0}/{1}", [String(sens), String(maxSens)]))
                                .font(store.scaledFont(11.5))
                        }
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
                            confirmDeleteOnBridge = true
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

            if confirmDeleteOnBridge {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.tr("Delete on Bridge?"))
                        .font(store.scaledFont(11, weight: .semibold))
                        .foregroundStyle(Color.red)
                    Text(store.tr("This permanently removes the room or zone from your Philips Hue Bridge."))
                        .font(store.scaledFont(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(store.tr("Cancel")) { confirmDeleteOnBridge = false }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        Spacer()
                        Button(store.tr("Delete"), role: .destructive) {
                            store.deleteFloorplanBox(id: box.id, alsoDeleteOnBridge: true)
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.red)
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.red.opacity(0.08)))
            }
            }
            .padding(14)
        }
        .frame(width: 280)
        .frame(maxHeight: 480)
        .fontDesign(store.fontDesign)
        .onAppear {
            name = box.name
            kind = box.kind
            archetype = box.archetype
            linkedHueID = box.hueID ?? ""
            linkedEntID = box.entertainmentAreaID ?? ""
            floorID = box.floorID
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
        copy.floorID = floorID
        return copy
    }

    private func saveChanges() {
        let updated = updatedBox()
        store.renameOrUpdateBoxOnBridge(updated)
        onClose()
    }
}

// MARK: - Floorplan Background Sheet

private struct FloorplanBackgroundSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.tr("Floorplan Background"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
                if store.floorplan.background.fileName != nil {
                    Button(role: .destructive) {
                        store.clearFloorplanBackground()
                    } label: {
                        Text(store.tr("Clear"))
                            .font(store.scaledFont(11.5))
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
            .controlSize(.regular)

            if let err = store.floorplanBackgroundError {
                Text(err)
                    .font(store.scaledFont(11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.floorplanBackgroundImage != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(store.tr("Opacity"))
                            .font(store.scaledFont(11.5, weight: .medium))
                        Spacer()
                        Text("\(Int((store.floorplan.background.opacity * 100).rounded()))%")
                            .font(store.scaledFont(11.5).monospacedDigit())
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

                VStack(alignment: .leading, spacing: 5) {
                    Text(store.tr("Scaling"))
                        .font(store.scaledFont(11.5, weight: .medium))
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
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            HStack {
                Spacer()
                Button(store.tr("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 310)
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
}

// MARK: - Focused Lamp Dialog Sheets (Brightness, Rename, Icon)

struct LampBrightnessSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let lightID: String
    @State private var briDraft: Double = 80

    var body: some View {
        let light = store.snapshot.light(lightID)
        let chosenIcon = store.floorplan.lamps[lightID]?.icon ?? LampIcon.inferred(for: light?.name ?? "")

        VStack(alignment: .leading, spacing: 14) {
            if let light = light {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(light.on ? Color(hex: light.color) : Color.primary.opacity(0.14))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.75))
                            .shadow(color: light.on ? Color(hex: light.color).opacity(0.5) : .clear, radius: 5)
                            .frame(width: 34, height: 34)
                        Image(systemName: chosenIcon.sfSymbol(lit: light.on))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(light.on ? (prefersDarkGlyph(light.color) ? Color.black : Color.white) : Color.secondary)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(light.name)
                            .font(store.scaledFont(13.5, weight: .semibold))
                            .lineLimit(1)
                        Text(light.on ? store.tr("On") : store.tr("Off"))
                            .font(store.scaledFont(11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { light.on },
                        set: { store.setLight(light, on: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }

                Divider()

                if light.dimmable {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(store.tr("Brightness"))
                                .font(store.scaledFont(11.5, weight: .medium))
                            Spacer()
                            Text("\(Int(briDraft.rounded()))%")
                                .font(store.scaledFont(12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { briDraft },
                                set: { val in
                                    briDraft = val
                                    store.drag(HueStore.target(light: light), to: val)
                                }
                            ),
                            in: 1...100,
                            onEditingChanged: { editing in
                                if !editing {
                                    store.release(HueStore.target(light: light))
                                    store.setLight(light, on: true, bri: Int(briDraft.rounded()))
                                }
                            }
                        )
                    }
                } else {
                    Text(store.tr("This light only supports on and off."))
                        .font(store.scaledFont(11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(store.tr("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 310)
        .fontDesign(store.fontDesign)
        .onAppear {
            if let light = store.snapshot.light(lightID) {
                briDraft = max(1, light.bri)
            }
        }
    }
}

struct LampRenameSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let lightID: String
    @State private var nameDraft: String = ""

    var body: some View {
        let light = store.snapshot.light(lightID)
        let chosenIcon = store.floorplan.lamps[lightID]?.icon ?? LampIcon.inferred(for: light?.name ?? "")
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canRename = !trimmed.isEmpty && trimmed != (light?.name ?? "")

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((light?.on ?? false) ? Color(hex: light?.color ?? HueColorMath.defaultWarmHex) : Color.primary.opacity(0.14))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.75))
                        .frame(width: 32, height: 32)
                    Image(systemName: chosenIcon.sfSymbol(lit: light?.on ?? false))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle((light?.on ?? false) ? (prefersDarkGlyph(light?.color ?? HueColorMath.defaultWarmHex) ? Color.black : Color.white) : Color.secondary)
                }
                Text(store.tr("Rename Lamp"))
                    .font(store.scaledFont(14, weight: .semibold))
            }

            TextField(store.tr("Lamp name"), text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename() }

            HStack {
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.tr("Rename")) { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRename)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 310)
        .fontDesign(store.fontDesign)
        .onAppear {
            nameDraft = store.snapshot.light(lightID)?.name ?? ""
        }
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != (store.snapshot.light(lightID)?.name ?? "") else { return }
        store.renameLight(id: lightID, name: trimmed)
        dismiss()
    }
}

struct LampIconPickerSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let lightID: String

    var body: some View {
        let light = store.snapshot.light(lightID)
        let currentIcon = store.floorplan.lamps[lightID]?.icon ?? LampIcon.inferred(for: light?.name ?? "")
        let isLit = light?.on ?? false
        let lightHex = light?.color ?? HueColorMath.defaultWarmHex

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isLit ? Color(hex: lightHex) : Color.primary.opacity(0.14))
                        .overlay(Circle().strokeBorder(store.skinAccentColor.opacity(0.6), lineWidth: 1.5))
                        .shadow(color: isLit ? Color(hex: lightHex).opacity(0.55) : .clear, radius: 6)
                        .frame(width: 40, height: 40)
                    Image(systemName: currentIcon.sfSymbol(lit: isLit))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isLit ? (prefersDarkGlyph(lightHex) ? Color.black : Color.white) : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(light?.name ?? store.tr("Lamp Icon"))
                        .font(store.scaledFont(13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(store.tr(currentIcon.titleKey))
                        .font(store.scaledFont(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(LampIcon.allCases) { icon in
                    let selected = currentIcon == icon
                    Button {
                        store.setLampIcon(lightID, icon: icon)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon.sfSymbol(lit: true))
                                .font(.system(size: 16, weight: .medium))
                            Text(store.tr(icon.titleKey))
                                .font(store.scaledFont(9.5, weight: selected ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                .fill(selected ? store.skinAccentColor : store.cardBackgroundColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                .strokeBorder(selected ? store.skinAccentColor : store.cardBorderColor, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(store.tr(icon.titleKey))
                }
            }

            HStack {
                Spacer()
                Button(store.tr("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .fontDesign(store.fontDesign)
    }
}

// MARK: - Unified Map Rule Dialog Sheet (Create by Drag/Click & Edit/Delete by Clicking Any Line)

private struct MapRuleDialogSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let state: MapView.RuleDialogState

    @State private var enabled: Bool = true
    @State private var ruleKind: String = "follow"
    @State private var triggerState: String = "on"
    @State private var mirrorOff: Bool = true
    @State private var matchBri: Bool = false
    @State private var onlyIfOff: Bool = false
    @State private var useTimeWindow: Bool = false
    @State private var timeStart: String = "22:00"
    @State private var timeEnd: String = "06:00"
    @State private var name: String = ""

    private var existingRule: HueRule? {
        if case .edit(let rule) = state { return rule }
        return nil
    }

    private var endpoints: (source: MapView.WireEndpoint, target: MapView.WireEndpoint) {
        switch state {
        case .create(let src, let dst):
            return (src, dst)
        case .edit(let rule):
            let src = MapView.WireEndpoint(kind: rule.triggerKind, id: rule.triggerID)
            let firstTarget = rule.targets.first
            let dst = MapView.WireEndpoint(kind: firstTarget?.kind ?? "light", id: firstTarget?.id ?? "")
            return (src, dst)
        }
    }

    private var wouldCreateCycle: Bool {
        let draft = buildRule()
        let others = store.rules.filter { $0.id != draft.id }
        return !RuleEngine.detectCycles(others + [draft]).isEmpty
    }

    private var isSensorSource: Bool {
        ["motion", "motion_area", "contact", "button"].contains(endpoints.source.kind)
    }

    private func defaultTriggerState(for kind: String) -> String {
        switch kind {
        case "motion", "motion_area": return "motion"
        case "contact": return "open"
        case "button": return "press"
        default: return "on"
        }
    }

    var body: some View {
        let ep = endpoints
        let srcName = store.nameForTarget(kind: ep.source.kind, id: ep.source.id)
        let dstName = ep.target.id.isEmpty ? "" : store.nameForTarget(kind: ep.target.kind, id: ep.target.id)

        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text(existingRule == nil ? store.tr("New Rule") : store.tr("Edit Rule"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
                if existingRule != nil {
                    Toggle("", isOn: $enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .help(store.tr("Enabled"))
                }
            }

            // Source -> Target badge strip
            HStack(spacing: 8) {
                Text(srcName)
                    .font(store.scaledFont(12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(dstName)
                    .font(store.scaledFont(12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 0)
            }

            // Rule type
            VStack(alignment: .leading, spacing: 5) {
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

            // Trigger state
            if ruleKind != "exclusive" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.tr("When"))
                        .font(store.scaledFont(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $triggerState) {
                        switch ep.source.kind {
                        case "motion", "motion_area":
                            Text(store.tr("Motion detected")).tag("motion")
                            Text(store.tr("No motion")).tag("clear")
                        case "contact":
                            Text(store.tr("Opens")).tag("open")
                            Text(store.tr("Closes")).tag("closed")
                        case "button":
                            Text(store.tr("Pressed")).tag("press")
                            Text(store.tr("Long press")).tag("long_press")
                        default:
                            Text(store.tr("Turns on")).tag("on")
                            Text(store.tr("Turns off")).tag("off")
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if ep.source.kind != "button" {
                        Toggle(store.tr("Also turn off together"), isOn: $mirrorOff)
                    }
                    if !isSensorSource {
                        Toggle(store.tr("Match brightness"), isOn: $matchBri)
                    }
                    Toggle(store.tr("Only if target is off"), isOn: $onlyIfOff)
                }
                .font(store.scaledFont(12))
            } else {
                Text(store.tr("Automatically turns target off when trigger turns on."))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
            }

            // Optional HH:MM active time window
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

            // Optional Name
            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Name"))
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("\(srcName) → \(dstName)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if wouldCreateCycle {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(store.tr("This rule creates a cycle with existing rules."))
                        .font(store.scaledFont(11))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack {
                if let rule = existingRule {
                    Button(role: .destructive) {
                        store.deleteRule(rule)
                        dismiss()
                    } label: {
                        Label(store.tr("Delete"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(store.tr("Save")) {
                    let rule = buildRule()
                    if existingRule != nil {
                        store.updateRule(rule)
                    } else {
                        store.addRule(rule)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .fontDesign(store.fontDesign)
        .onAppear {
            let srcKind = endpoints.source.kind
            if let rule = existingRule {
                enabled = rule.enabled
                ruleKind = (rule.kind == "exclusive" || rule.kind == "companion") ? rule.kind : "follow"
                triggerState = rule.triggerState.isEmpty ? defaultTriggerState(for: srcKind) : rule.triggerState
                mirrorOff = rule.mirrorOff
                matchBri = rule.matchBri
                onlyIfOff = rule.onlyIfOff
                useTimeWindow = !rule.timeStart.isEmpty && !rule.timeEnd.isEmpty
                if !rule.timeStart.isEmpty { timeStart = rule.timeStart }
                if !rule.timeEnd.isEmpty { timeEnd = rule.timeEnd }
                name = rule.name
            } else {
                enabled = true
                ruleKind = "follow"
                triggerState = defaultTriggerState(for: srcKind)
                mirrorOff = srcKind != "button"
                matchBri = false
                onlyIfOff = false
                useTimeWindow = false
                name = ""
            }
        }
    }

    private func buildRule() -> HueRule {
        let ep = endpoints
        let srcName = store.nameForTarget(kind: ep.source.kind, id: ep.source.id)
        let dstName = store.nameForTarget(kind: ep.target.kind, id: ep.target.id)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "\(srcName) → \(dstName)" : trimmedName
        let finalAction = ruleKind == "exclusive" ? "off" : "on"
        let activeState = defaultTriggerState(for: ep.source.kind)
        let finalTriggerState = ruleKind == "exclusive" ? activeState : triggerState
        let startStr = useTimeWindow ? timeStart.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let endStr = useTimeWindow ? timeEnd.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let allowMirrorOff = ruleKind != "exclusive" && ep.source.kind != "button"
        let allowMatchBri = ruleKind != "exclusive" && !isSensorSource

        if var updated = existingRule {
            updated.name = finalName
            updated.enabled = enabled
            updated.kind = ruleKind
            updated.triggerState = finalTriggerState
            updated.mirrorOff = allowMirrorOff ? mirrorOff : false
            updated.matchBri = allowMatchBri ? matchBri : false
            updated.onlyIfOff = ruleKind == "exclusive" ? false : onlyIfOff
            updated.timeStart = startStr
            updated.timeEnd = endStr
            updated.targets = updated.targets.map {
                HueRuleTarget(
                    kind: $0.kind,
                    id: $0.id,
                    action: finalAction,
                    bri: ruleKind == "exclusive" ? nil : $0.bri,
                    sceneID: ruleKind == "exclusive" ? nil : $0.sceneID
                )
            }
            return updated
        }

        return HueRule(
            name: finalName,
            enabled: true,
            kind: ruleKind,
            triggerKind: ep.source.kind,
            triggerID: ep.source.id,
            triggerState: finalTriggerState,
            targets: [HueRuleTarget(kind: ep.target.kind, id: ep.target.id, action: finalAction)],
            mirrorOff: allowMirrorOff ? mirrorOff : false,
            matchBri: allowMatchBri ? matchBri : false,
            timeStart: startStr,
            timeEnd: endStr,
            onlyIfOff: ruleKind == "exclusive" ? false : onlyIfOff
        )
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
