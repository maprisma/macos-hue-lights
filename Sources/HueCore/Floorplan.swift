import Foundation

// MARK: - Portable Spatial Floorplan Schema (`floorplan.json`)

public struct FloorplanCanvasSettings: Equatable, Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public var grid: Double
    public var snap: Bool
    public var zoom: Double
    public var panX: Double
    public var panY: Double

    enum CodingKeys: String, CodingKey {
        case width, height, grid, snap, zoom
        case panX = "pan_x"
        case panY = "pan_y"
    }

    public init(
        width: Double = 1600,
        height: Double = 1000,
        grid: Double = 20,
        snap: Bool = true,
        zoom: Double = 1.0,
        panX: Double = 0,
        panY: Double = 0
    ) {
        self.width = HueColorMath.clamp(width.isFinite ? width : 1600, 400, 4000)
        self.height = HueColorMath.clamp(height.isFinite ? height : 1000, 300, 3000)
        self.grid = HueColorMath.clamp(grid.isFinite ? grid : 20, 10, 100)
        self.snap = snap
        self.zoom = HueColorMath.clamp(zoom.isFinite ? zoom : 1.0, 0.35, 2.5)
        self.panX = panX.isFinite ? panX : 0
        self.panY = panY.isFinite ? panY : 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1600
        let h = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1000
        let g = try c.decodeIfPresent(Double.self, forKey: .grid) ?? 20
        let s = try c.decodeIfPresent(Bool.self, forKey: .snap) ?? true
        let z = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        let px = try c.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        let py = try c.decodeIfPresent(Double.self, forKey: .panY) ?? 0
        self.init(width: w, height: h, grid: g, snap: s, zoom: z, panX: px, panY: py)
    }
}

public enum BackgroundFit: String, CaseIterable, Identifiable, Codable, Equatable, Hashable, Sendable {
    case contain
    case cover

    public var id: String { rawValue }
}

public struct FloorplanBackground: Equatable, Hashable, Codable, Sendable {
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    public static let minOpacity: Double = 0.05
    public static let maxOpacity: Double = 1.0
    public static let defaultOpacity: Double = 0.35

    public var fileName: String?
    public var opacity: Double
    public var fit: BackgroundFit

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case opacity
        case fit
    }

    public static let empty = FloorplanBackground(fileName: nil, opacity: defaultOpacity, fit: .contain)

    public init(
        fileName: String? = nil,
        opacity: Double = defaultOpacity,
        fit: BackgroundFit = .contain
    ) {
        self.fileName = Self.sanitizeFileName(fileName)
        let finiteOpacity = opacity.isFinite ? opacity : Self.defaultOpacity
        self.opacity = HueColorMath.clamp(finiteOpacity, Self.minOpacity, Self.maxOpacity)
        self.fit = fit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try c.decodeIfPresent(String.self, forKey: .fileName)
        let rawOpacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        let rawFit = try c.decodeIfPresent(BackgroundFit.self, forKey: .fit) ?? .contain
        self.init(fileName: rawName, opacity: rawOpacity, fit: rawFit)
    }

    /// Ensures the stored image filename is strictly a safe basename with an allowed image extension.
    /// Rejects path traversal (`..`, `/`, `\`), hidden dotfiles, control chars, and disallowed extensions.
    public static func sanitizeFileName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.contains("/") || raw.contains("\\") || raw.contains("..") || raw.hasPrefix(".") {
            return nil
        }
        let cleaned = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            return (0x30...0x39).contains(v)
                || (0x41...0x5A).contains(v)
                || (0x61...0x7A).contains(v)
                || v == 0x2D // '-'
                || v == 0x5F // '_'
                || v == 0x2E // '.'
        }
        let name = String(String.UnicodeScalarView(cleaned))
        guard name == raw, name.count <= 80 else { return nil }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let ext = parts[1].lowercased()
        guard allowedExtensions.contains(ext) else { return nil }
        return name
    }
}

public struct FloorplanBox: Identifiable, Equatable, Hashable, Codable, Sendable {
    public static let minWidth: Double = 100
    public static let minHeight: Double = 80

    public var id: String
    /// "room" or "zone"
    public var kind: String
    public var hueID: String?
    public var name: String
    public var archetype: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var entertainmentAreaID: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case hueID = "hue_id"
        case name, archetype, x, y
        case width = "w"
        case height = "h"
        case entertainmentAreaID = "entertainment_area_id"
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: String = "room",
        hueID: String? = nil,
        name: String,
        archetype: String = "other",
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        entertainmentAreaID: String? = nil
    ) {
        self.id = id.isEmpty ? UUID().uuidString.lowercased() : id
        self.kind = (kind == "zone") ? "zone" : "room"
        self.hueID = hueID.flatMap { HueColorMath.validUUID($0) ? $0 : nil }
        let cleanName = HueColorMath.clean(name, limit: 32)
        self.name = cleanName.isEmpty ? (self.kind == "zone" ? "Zone" : "Room") : cleanName
        let cleanArch = HueColorMath.clean(archetype, limit: 30)
        self.archetype = cleanArch.isEmpty ? "other" : cleanArch
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
        self.width = max(Self.minWidth, width.isFinite ? width : 320)
        self.height = max(Self.minHeight, height.isFinite ? height : 240)
        self.entertainmentAreaID = entertainmentAreaID.flatMap { HueColorMath.validUUID($0) ? $0 : nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "room"
        let hueID = try c.decodeIfPresent(String.self, forKey: .hueID)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Room"
        let archetype = try c.decodeIfPresent(String.self, forKey: .archetype) ?? "other"
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let w = try c.decodeIfPresent(Double.self, forKey: .width) ?? 320
        let h = try c.decodeIfPresent(Double.self, forKey: .height) ?? 240
        let ent = try c.decodeIfPresent(String.self, forKey: .entertainmentAreaID)
        self.init(
            id: id, kind: kind, hueID: hueID, name: name, archetype: archetype,
            x: x, y: y, width: w, height: h, entertainmentAreaID: ent
        )
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }
    public var area: Double { width * height }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }
}

public struct FloorplanStamp: Identifiable, Equatable, Hashable, Codable, Sendable {
    public static let allKinds: [String] = [
        "door", "window", "sofa", "tv", "desk", "bed", "dining", "kitchen",
    ]

    public var id: String
    /// "door" | "window" | "sofa" | "tv" | "desk" | "bed" | "dining" | "kitchen"
    public var kind: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// 0, 90, 180, or 270 degrees
    public var rotation: Int

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y
        case width = "w"
        case height = "h"
        case rotation = "rot"
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: String,
        x: Double,
        y: Double,
        width: Double? = nil,
        height: Double? = nil,
        rotation: Int = 0
    ) {
        let safeKind = Self.allKinds.contains(kind) ? kind : "sofa"
        let def = Self.defaultSize(for: safeKind)
        self.id = id.isEmpty ? UUID().uuidString.lowercased() : id
        self.kind = safeKind
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
        let w = width ?? def.width
        let h = height ?? def.height
        self.width = HueColorMath.clamp(w.isFinite ? w : def.width, 14, 600)
        self.height = HueColorMath.clamp(h.isFinite ? h : def.height, 10, 600)
        let norm = ((rotation % 360) + 360) % 360
        self.rotation = (norm / 90) * 90
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "sofa"
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let w = try c.decodeIfPresent(Double.self, forKey: .width)
        let h = try c.decodeIfPresent(Double.self, forKey: .height)
        let rot = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        self.init(id: id, kind: kind, x: x, y: y, width: w, height: h, rotation: rot)
    }

    public static func defaultSize(for kind: String) -> (width: Double, height: Double) {
        switch kind {
        case "door": return (48, 48)
        case "window": return (110, 14)
        case "sofa": return (150, 66)
        case "tv": return (130, 18)
        case "desk": return (120, 68)
        case "bed": return (140, 160)
        case "dining": return (130, 86)
        case "kitchen": return (180, 56)
        default: return (100, 60)
        }
    }
}

public enum LampIcon: String, CaseIterable, Identifiable, Codable, Equatable, Hashable, Sendable {
    case bulb
    case spot
    case strip
    case floor
    case table
    case pendant
    case ceiling
    case wall
    case bar
    case desk
    case outdoor
    case candle

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .bulb: return "Bulb"
        case .spot: return "Spot"
        case .strip: return "Lightstrip"
        case .floor: return "Floor Lamp"
        case .table: return "Table Lamp"
        case .pendant: return "Pendant"
        case .ceiling: return "Ceiling"
        case .wall: return "Wall Sconce"
        case .bar: return "Light Bar"
        case .desk: return "Desk Lamp"
        case .outdoor: return "Outdoor"
        case .candle: return "Candle"
        }
    }

    /// Strictly macOS 13+ (SF Symbols 4.0) safe symbol names.
    public func sfSymbol(lit: Bool = true) -> String {
        switch self {
        case .bulb: return lit ? "lightbulb.fill" : "lightbulb"
        case .spot: return lit ? "light.recessed.fill" : "light.recessed"
        case .strip: return "light.strip.2"
        case .floor: return lit ? "lamp.floor.fill" : "lamp.floor"
        case .table: return lit ? "lamp.table.fill" : "lamp.table"
        case .pendant: return lit ? "lamp.ceiling.fill" : "lamp.ceiling"
        case .ceiling: return lit ? "chandelier.fill" : "chandelier"
        case .wall: return lit ? "light.panel.fill" : "light.panel"
        case .bar: return "rectangle.fill"
        case .desk: return lit ? "lamp.desk.fill" : "lamp.desk"
        case .outdoor: return lit ? "sun.max.fill" : "sun.max"
        case .candle: return lit ? "flame.fill" : "flame"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self.parse(raw)
    }

    public static func parse(_ raw: String?) -> LampIcon {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .bulb
        }
        if let exact = LampIcon(rawValue: raw) { return exact }
        switch raw {
        case "floor_lamp": return .floor
        case "desk_lamp": return .desk
        case "table_lamp": return .table
        case "lightstrip": return .strip
        case "light_bar": return .bar
        case "sconce", "wall_sconce": return .wall
        default: return .bulb
        }
    }

    public static func inferred(for lightName: String) -> LampIcon {
        let lower = lightName.lowercased()
        if lower.contains("bar") || lower.contains("backlight") || lower.contains("play") {
            return .bar
        }
        if lower.contains("strip") || lower.contains("gradient") {
            return .strip
        }
        if lower.contains("desk") || lower.contains("schreibtisch") {
            return .desk
        }
        if lower.contains("table") || lower.contains("bedside") || lower.contains("nacht") || lower.contains("tisch") {
            return .table
        }
        if lower.contains("floor") || lower.contains("steh") || lower.contains("arc") {
            return .floor
        }
        if lower.contains("pendant") || lower.contains("pendel") {
            return .pendant
        }
        if lower.contains("ceiling") || lower.contains("decke") || lower.contains("chandelier") {
            return .ceiling
        }
        if lower.contains("wall") || lower.contains("wand") || lower.contains("sconce") {
            return .wall
        }
        if lower.contains("spot") || lower.contains("downlight") {
            return .spot
        }
        if lower.contains("garden") || lower.contains("terrace") || lower.contains("balcony") || lower.contains("outdoor") || lower.contains("außen") {
            return .outdoor
        }
        if lower.contains("candle") || lower.contains("kerze") {
            return .candle
        }
        return .bulb
    }
}

public typealias FloorplanLamp = FloorplanLampPlacement

public struct FloorplanLampPlacement: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    /// Vertical height in Hue Entertainment normalized space `[-1.0, 1.0]`
    public var z: Double
    public var icon: LampIcon

    public init(x: Double, y: Double, z: Double = 0.0, icon: LampIcon = .bulb) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
        self.z = HueColorMath.clamp(z.isFinite ? z : 0.0, -1.0, 1.0)
        self.icon = icon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let z = try c.decodeIfPresent(Double.self, forKey: .z) ?? 0.0
        let rawIcon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.init(x: x, y: y, z: z, icon: LampIcon.parse(rawIcon))
    }
}

public struct FloorplanSensorPlacement: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        self.init(x: x, y: y)
    }
}

public struct FloorplanDocument: Equatable, Hashable, Codable, Sendable {
    public var version: Int
    public var bridgeID: String
    public var templateID: String
    public var canvas: FloorplanCanvasSettings
    public var showWires: Bool
    public var showGlows: Bool
    public var showFurniture: Bool
    public var autoSync: Bool
    public var entertainmentAreaID: String?
    public var background: FloorplanBackground
    public var boxes: [FloorplanBox]
    public var stamps: [FloorplanStamp]
    public var lamps: [String: FloorplanLampPlacement]
    public var sensors: [String: FloorplanSensorPlacement]

    /// Alias kept for clarity with the schema's `auto_sync_rooms` semantics.
    public var autoSyncRooms: Bool {
        get { autoSync }
        set { autoSync = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case bridgeID = "bridge_id"
        case templateID = "template_id"
        case canvas
        case showWires = "show_wires"
        case showGlows = "show_glows"
        case showFurniture = "show_furniture"
        case autoSync = "auto_sync_rooms"
        case entertainmentAreaID = "entertainment_area_id"
        case background
        case boxes
        case stamps
        case lamps
        case sensors
    }

    public init(
        version: Int = 1,
        bridgeID: String = "",
        templateID: String = FloorplanTemplate.autoBridge.rawValue,
        canvas: FloorplanCanvasSettings = FloorplanCanvasSettings(),
        showWires: Bool = true,
        showGlows: Bool = true,
        showFurniture: Bool = true,
        autoSync: Bool = false,
        entertainmentAreaID: String? = nil,
        background: FloorplanBackground = .empty,
        boxes: [FloorplanBox] = [],
        stamps: [FloorplanStamp] = [],
        lamps: [String: FloorplanLampPlacement] = [:],
        sensors: [String: FloorplanSensorPlacement] = [:]
    ) {
        self.version = max(1, version)
        self.bridgeID = HueColorMath.clean(bridgeID, limit: 40)
        self.templateID = templateID.isEmpty ? FloorplanTemplate.autoBridge.rawValue : templateID
        self.canvas = canvas
        self.showWires = showWires
        self.showGlows = showGlows
        self.showFurniture = showFurniture
        self.autoSync = autoSync
        self.entertainmentAreaID = entertainmentAreaID.flatMap { HueColorMath.validUUID($0) ? $0 : nil }
        self.background = background
        self.boxes = boxes
        self.stamps = stamps
        self.lamps = lamps
        self.sensors = sensors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let bridgeID = try c.decodeIfPresent(String.self, forKey: .bridgeID) ?? ""
        let templateID = try c.decodeIfPresent(String.self, forKey: .templateID) ?? FloorplanTemplate.autoBridge.rawValue
        let canvas = try c.decodeIfPresent(FloorplanCanvasSettings.self, forKey: .canvas) ?? FloorplanCanvasSettings()
        let showWires = try c.decodeIfPresent(Bool.self, forKey: .showWires) ?? true
        let showGlows = try c.decodeIfPresent(Bool.self, forKey: .showGlows) ?? true
        let showFurniture = try c.decodeIfPresent(Bool.self, forKey: .showFurniture) ?? true
        let autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
        let entAreaID = try c.decodeIfPresent(String.self, forKey: .entertainmentAreaID)
        let bg = try c.decodeIfPresent(FloorplanBackground.self, forKey: .background) ?? .empty
        let boxes = try c.decodeIfPresent([FloorplanBox].self, forKey: .boxes) ?? []
        let stamps = try c.decodeIfPresent([FloorplanStamp].self, forKey: .stamps) ?? []
        let lamps = try c.decodeIfPresent([String: FloorplanLampPlacement].self, forKey: .lamps) ?? [:]
        let sensors = try c.decodeIfPresent([String: FloorplanSensorPlacement].self, forKey: .sensors) ?? [:]
        self.init(
            version: version,
            bridgeID: bridgeID,
            templateID: templateID,
            canvas: canvas,
            showWires: showWires,
            showGlows: showGlows,
            showFurniture: showFurniture,
            autoSync: autoSync,
            entertainmentAreaID: entAreaID,
            background: bg,
            boxes: boxes,
            stamps: stamps,
            lamps: lamps,
            sensors: sensors
        )
    }

    public func snapped(_ value: Double) -> Double {
        guard canvas.snap, canvas.grid >= 1 else { return value.rounded() }
        return (value / canvas.grid).rounded() * canvas.grid
    }
}

// MARK: - 6 Built-in Editable Starter Prototypes

public enum FloorplanTemplate: String, CaseIterable, Identifiable, Equatable, Sendable {
    case autoBridge = "auto_bridge"
    case studioLoft = "studio_loft"
    case oneBedApartment = "one_bed_apartment"
    case threeRoomApartment = "three_room_apartment"
    case familyHouse = "family_house"
    case deskStudio = "desk_studio"

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .autoBridge: return "Auto from My Hue Bridge"
        case .studioLoft: return "Studio / Loft"
        case .oneBedApartment: return "1-Bedroom Apartment"
        case .threeRoomApartment: return "3-Room Apartment"
        case .familyHouse: return "Family House + Terrace"
        case .deskStudio: return "Desk & Gaming Studio"
        }
    }

    public var subtitleKey: String {
        switch self {
        case .autoBridge: return "Connected grid generated from your Hue rooms"
        case .studioLoft: return "Open living/sleeping, kitchenette, bath, balcony"
        case .oneBedApartment: return "Living room, bedroom, kitchen, hallway, bath, balcony"
        case .threeRoomApartment: return "Living/dining, office, 2 bedrooms, kitchen, hall, bath"
        case .familyHouse: return "Living/dining, kitchen, office, bedroom, hall, terrace"
        case .deskStudio: return "Close-up single room for desk, monitor & TV lights"
        }
    }

    public var symbol: String {
        switch self {
        case .autoBridge: return "wand.and.stars"
        case .studioLoft: return "rectangle.split.2x2"
        case .oneBedApartment: return "building"
        case .threeRoomApartment: return "building.2"
        case .familyHouse: return "house"
        case .deskStudio: return "desktopcomputer"
        }
    }

    /// Generates an editable architectural starter floorplan and auto-matches existing Hue Bridge rooms.
    public static func build(
        template: FloorplanTemplate,
        snapshot: HueSnapshot,
        bridgeID: String = ""
    ) -> FloorplanDocument {
        switch template {
        case .autoBridge:
            return buildAutoFromBridge(snapshot: snapshot, bridgeID: bridgeID)
        case .studioLoft:
            let boxes = [
                FloorplanBox(id: "tpl-studio-living", kind: "room", name: "Living & Sleeping", archetype: "living_room", x: 100, y: 100, width: 520, height: 380),
                FloorplanBox(id: "tpl-studio-kitchen", kind: "room", name: "Kitchenette", archetype: "kitchen", x: 620, y: 100, width: 260, height: 200),
                FloorplanBox(id: "tpl-studio-bath", kind: "room", name: "Bathroom", archetype: "bathroom", x: 620, y: 300, width: 260, height: 180),
                FloorplanBox(id: "tpl-studio-balcony", kind: "zone", name: "Balcony", archetype: "balcony", x: 100, y: 480, width: 520, height: 140),
            ]
            let stamps = [
                FloorplanStamp(id: "st-studio-tv", kind: "tv", x: 160, y: 112, width: 140, height: 16, rotation: 0),
                FloorplanStamp(id: "st-studio-sofa", kind: "sofa", x: 155, y: 210, width: 150, height: 64, rotation: 0),
                FloorplanStamp(id: "st-studio-bed", kind: "bed", x: 430, y: 130, width: 150, height: 170, rotation: 0),
                FloorplanStamp(id: "st-studio-desk", kind: "desk", x: 440, y: 360, width: 120, height: 66, rotation: 0),
                FloorplanStamp(id: "st-studio-kitchen", kind: "kitchen", x: 650, y: 115, width: 200, height: 54, rotation: 0),
                FloorplanStamp(id: "st-studio-door", kind: "door", x: 620, y: 330, width: 48, height: 48, rotation: 90),
                FloorplanStamp(id: "st-studio-win", kind: "window", x: 240, y: 474, width: 160, height: 14, rotation: 0),
            ]
            return applyAutoMatching(template: template, boxes: boxes, stamps: stamps, snapshot: snapshot, bridgeID: bridgeID)

        case .oneBedApartment:
            let boxes = [
                FloorplanBox(id: "tpl-1b-living", kind: "room", name: "Living Room", archetype: "living_room", x: 80, y: 80, width: 460, height: 320),
                FloorplanBox(id: "tpl-1b-kitchen", kind: "room", name: "Kitchen", archetype: "kitchen", x: 540, y: 80, width: 280, height: 200),
                FloorplanBox(id: "tpl-1b-hall", kind: "room", name: "Hallway", archetype: "hallway", x: 540, y: 280, width: 280, height: 120),
                FloorplanBox(id: "tpl-1b-bed", kind: "room", name: "Bedroom", archetype: "bedroom", x: 80, y: 400, width: 360, height: 280),
                FloorplanBox(id: "tpl-1b-bath", kind: "room", name: "Bathroom", archetype: "bathroom", x: 440, y: 400, width: 220, height: 280),
                FloorplanBox(id: "tpl-1b-balcony", kind: "zone", name: "Balcony", archetype: "balcony", x: 660, y: 400, width: 160, height: 280),
            ]
            let stamps = [
                FloorplanStamp(id: "st-1b-tv", kind: "tv", x: 140, y: 94, width: 130, height: 16, rotation: 0),
                FloorplanStamp(id: "st-1b-sofa", kind: "sofa", x: 130, y: 210, width: 150, height: 64, rotation: 0),
                FloorplanStamp(id: "st-1b-dining", kind: "dining", x: 360, y: 150, width: 120, height: 84, rotation: 0),
                FloorplanStamp(id: "st-1b-kitchen", kind: "kitchen", x: 570, y: 94, width: 220, height: 54, rotation: 0),
                FloorplanStamp(id: "st-1b-bed", kind: "bed", x: 120, y: 450, width: 140, height: 160, rotation: 0),
                FloorplanStamp(id: "st-1b-door1", kind: "door", x: 760, y: 315, width: 48, height: 48, rotation: 180),
                FloorplanStamp(id: "st-1b-win1", kind: "window", x: 200, y: 74, width: 140, height: 14, rotation: 0),
            ]
            return applyAutoMatching(template: template, boxes: boxes, stamps: stamps, snapshot: snapshot, bridgeID: bridgeID)

        case .threeRoomApartment:
            let boxes = [
                FloorplanBox(id: "tpl-3r-living", kind: "room", name: "Living & Dining", archetype: "living_room", x: 60, y: 60, width: 480, height: 320),
                FloorplanBox(id: "tpl-3r-kitchen", kind: "room", name: "Kitchen", archetype: "kitchen", x: 540, y: 60, width: 260, height: 200),
                FloorplanBox(id: "tpl-3r-office", kind: "room", name: "Office", archetype: "office", x: 800, y: 60, width: 320, height: 260),
                FloorplanBox(id: "tpl-3r-hall", kind: "room", name: "Hallway", archetype: "hallway", x: 540, y: 260, width: 260, height: 120),
                FloorplanBox(id: "tpl-3r-bed1", kind: "room", name: "Bedroom", archetype: "bedroom", x: 60, y: 380, width: 380, height: 280),
                FloorplanBox(id: "tpl-3r-bath", kind: "room", name: "Bathroom", archetype: "bathroom", x: 440, y: 380, width: 220, height: 280),
                FloorplanBox(id: "tpl-3r-bed2", kind: "room", name: "Guest Room", archetype: "guest_room", x: 660, y: 380, width: 460, height: 280),
            ]
            let stamps = [
                FloorplanStamp(id: "st-3r-tv", kind: "tv", x: 110, y: 74, width: 140, height: 16, rotation: 0),
                FloorplanStamp(id: "st-3r-sofa", kind: "sofa", x: 105, y: 190, width: 150, height: 66, rotation: 0),
                FloorplanStamp(id: "st-3r-dining", kind: "dining", x: 340, y: 140, width: 130, height: 86, rotation: 0),
                FloorplanStamp(id: "st-3r-kitchen", kind: "kitchen", x: 570, y: 74, width: 200, height: 54, rotation: 0),
                FloorplanStamp(id: "st-3r-desk", kind: "desk", x: 890, y: 110, width: 130, height: 68, rotation: 0),
                FloorplanStamp(id: "st-3r-bed1", kind: "bed", x: 100, y: 430, width: 140, height: 160, rotation: 0),
                FloorplanStamp(id: "st-3r-bed2", kind: "bed", x: 720, y: 430, width: 130, height: 155, rotation: 0),
                FloorplanStamp(id: "st-3r-door", kind: "door", x: 640, y: 320, width: 48, height: 48, rotation: 0),
                FloorplanStamp(id: "st-3r-win", kind: "window", x: 200, y: 54, width: 140, height: 14, rotation: 0),
            ]
            return applyAutoMatching(template: template, boxes: boxes, stamps: stamps, snapshot: snapshot, bridgeID: bridgeID)

        case .familyHouse:
            let boxes = [
                FloorplanBox(id: "tpl-fh-living", kind: "room", name: "Living & Dining", archetype: "living_room", x: 60, y: 80, width: 480, height: 340),
                FloorplanBox(id: "tpl-fh-kitchen", kind: "room", name: "Kitchen", archetype: "kitchen", x: 540, y: 80, width: 300, height: 220),
                FloorplanBox(id: "tpl-fh-hall", kind: "room", name: "Hallway", archetype: "hallway", x: 540, y: 300, width: 300, height: 120),
                FloorplanBox(id: "tpl-fh-office", kind: "room", name: "Home Office", archetype: "office", x: 840, y: 80, width: 320, height: 240),
                FloorplanBox(id: "tpl-fh-wc", kind: "room", name: "Guest WC", archetype: "bathroom", x: 840, y: 320, width: 180, height: 100),
                FloorplanBox(id: "tpl-fh-bed", kind: "room", name: "Bedroom", archetype: "bedroom", x: 60, y: 420, width: 360, height: 260),
                FloorplanBox(id: "tpl-fh-terrace", kind: "zone", name: "Terrace & Garden", archetype: "terrace", x: 420, y: 420, width: 740, height: 260),
            ]
            let stamps = [
                FloorplanStamp(id: "st-fh-tv", kind: "tv", x: 110, y: 94, width: 150, height: 16, rotation: 0),
                FloorplanStamp(id: "st-fh-sofa", kind: "sofa", x: 105, y: 220, width: 160, height: 68, rotation: 0),
                FloorplanStamp(id: "st-fh-dining", kind: "dining", x: 340, y: 170, width: 130, height: 86, rotation: 0),
                FloorplanStamp(id: "st-fh-kitchen", kind: "kitchen", x: 580, y: 96, width: 220, height: 56, rotation: 0),
                FloorplanStamp(id: "st-fh-desk", kind: "desk", x: 930, y: 120, width: 130, height: 68, rotation: 0),
                FloorplanStamp(id: "st-fh-bed", kind: "bed", x: 110, y: 465, width: 140, height: 160, rotation: 0),
                FloorplanStamp(id: "st-fh-patio", kind: "dining", x: 680, y: 500, width: 140, height: 88, rotation: 0),
                FloorplanStamp(id: "st-fh-door", kind: "door", x: 660, y: 365, width: 48, height: 48, rotation: 270),
                FloorplanStamp(id: "st-fh-win", kind: "window", x: 180, y: 74, width: 160, height: 14, rotation: 0),
            ]
            return applyAutoMatching(template: template, boxes: boxes, stamps: stamps, snapshot: snapshot, bridgeID: bridgeID)

        case .deskStudio:
            let boxes = [
                FloorplanBox(id: "tpl-desk-main", kind: "room", name: "Desk & Gaming Studio", archetype: "office", x: 120, y: 80, width: 840, height: 540),
            ]
            let stamps = [
                FloorplanStamp(id: "st-ds-tv", kind: "tv", x: 420, y: 98, width: 240, height: 18, rotation: 0),
                FloorplanStamp(id: "st-ds-desk", kind: "desk", x: 430, y: 160, width: 220, height: 84, rotation: 0),
                FloorplanStamp(id: "st-ds-sofa", kind: "sofa", x: 410, y: 450, width: 240, height: 80, rotation: 0),
                FloorplanStamp(id: "st-ds-win", kind: "window", x: 114, y: 240, width: 160, height: 14, rotation: 90),
                FloorplanStamp(id: "st-ds-door", kind: "door", x: 912, y: 480, width: 48, height: 48, rotation: 180),
            ]
            return applyDeskStudioMatching(boxes: boxes, stamps: stamps, snapshot: snapshot, bridgeID: bridgeID)
        }
    }

    // MARK: - Auto Layout & Smart Hue Room Matching

    private static func buildAutoFromBridge(snapshot: HueSnapshot, bridgeID: String) -> FloorplanDocument {
        let realRooms = snapshot.rooms.filter { $0.kind == "room" && !$0.hueID.isEmpty }
        let realZones = snapshot.rooms.filter { $0.kind == "zone" && !$0.hueID.isEmpty }
        let looseLights = snapshot.rooms.filter { $0.kind == "other" }.flatMap(\.lights)

        var boxes: [FloorplanBox] = []
        var lamps: [String: FloorplanLampPlacement] = [:]

        if realRooms.isEmpty && realZones.isEmpty {
            let living = FloorplanBox(id: "auto-living", kind: "room", name: "Living Room", archetype: "living_room", x: 80, y: 80, width: 420, height: 300)
            let office = FloorplanBox(id: "auto-office", kind: "room", name: "Office", archetype: "office", x: 500, y: 80, width: 380, height: 300)
            boxes = [living, office]
            placeLights(looseLights, inside: living, into: &lamps)
            return FloorplanDocument(
                bridgeID: bridgeID,
                templateID: FloorplanTemplate.autoBridge.rawValue,
                entertainmentAreaID: snapshot.entertainmentAreas.first?.id,
                boxes: boxes,
                stamps: [],
                lamps: lamps
            )
        }

        let cols = realRooms.count <= 2 ? max(1, realRooms.count) : (realRooms.count <= 4 ? 2 : 3)
        let boxW: Double = 380
        let boxH: Double = 280
        let originX: Double = 80
        let originY: Double = 80

        for (idx, room) in realRooms.enumerated() {
            let col = idx % cols
            let row = idx / cols
            let entID = matchingEntertainmentAreaID(for: room, areas: snapshot.entertainmentAreas)
            let box = FloorplanBox(
                id: "box-\(room.hueID)",
                kind: "room",
                hueID: room.hueID,
                name: room.name,
                archetype: room.archetype.isEmpty ? inferArchetype(from: room.name) : room.archetype,
                x: originX + Double(col) * boxW,
                y: originY + Double(row) * boxH,
                width: boxW,
                height: boxH,
                entertainmentAreaID: entID
            )
            boxes.append(box)
            placeLights(room.lights, inside: box, into: &lamps)
        }

        let roomRows = realRooms.isEmpty ? 0 : ((realRooms.count + cols - 1) / cols)
        let zoneOriginY = originY + Double(roomRows) * boxH + (roomRows > 0 ? 40 : 0)
        for (idx, zone) in realZones.enumerated() {
            let col = idx % max(1, cols)
            let row = idx / max(1, cols)
            let entID = matchingEntertainmentAreaID(for: zone, areas: snapshot.entertainmentAreas)
            let box = FloorplanBox(
                id: "box-\(zone.hueID)",
                kind: "zone",
                hueID: zone.hueID,
                name: zone.name,
                archetype: zone.archetype.isEmpty ? "other" : zone.archetype,
                x: originX + Double(col) * boxW,
                y: zoneOriginY + Double(row) * 200,
                width: boxW,
                height: 180,
                entertainmentAreaID: entID
            )
            boxes.append(box)
            for light in zone.lights where lamps[light.id] == nil {
                placeLights([light], inside: box, into: &lamps)
            }
        }

        // Place any unassigned loose lights cleanly along the bottom strip
        if !looseLights.isEmpty {
            let looseY = zoneOriginY + (realZones.isEmpty ? 40 : Double(((realZones.count + cols - 1) / cols) * 200 + 40))
            for (idx, light) in looseLights.enumerated() where lamps[light.id] == nil {
                lamps[light.id] = FloorplanLampPlacement(
                    x: originX + 60 + Double(idx) * 110,
                    y: looseY,
                    z: 0.0,
                    icon: LampIcon.inferred(for: light.name)
                )
            }
        }

        let maxX = (boxes.map(\.maxX).max() ?? 1000) + 160
        let maxY = (boxes.map(\.maxY).max() ?? 700) + 160
        let sensorPlacements = autoPlaceSensors(snapshot.sensors, into: boxes)
        return FloorplanDocument(
            bridgeID: bridgeID,
            templateID: FloorplanTemplate.autoBridge.rawValue,
            canvas: FloorplanCanvasSettings(width: max(1200, maxX), height: max(800, maxY)),
            entertainmentAreaID: snapshot.entertainmentAreas.first?.id,
            boxes: boxes,
            stamps: [],
            lamps: lamps,
            sensors: sensorPlacements
        )
    }

    private static func applyAutoMatching(
        template: FloorplanTemplate,
        boxes initialBoxes: [FloorplanBox],
        stamps: [FloorplanStamp],
        snapshot: HueSnapshot,
        bridgeID: String
    ) -> FloorplanDocument {
        var boxes = initialBoxes
        var lamps: [String: FloorplanLampPlacement] = [:]
        var claimedBoxIndices = Set<Int>()
        var unmatchedRooms: [HueRoom] = []

        let bridgeRooms = snapshot.rooms.filter { ($0.kind == "room" || $0.kind == "zone") && !$0.hueID.isEmpty }

        // Pass 1: match by canonical archetype / multilingual room name
        for room in bridgeRooms {
            let canon = canonicalArchetype(room: room)
            if let idx = boxes.indices.first(where: { i in
                !claimedBoxIndices.contains(i)
                    && boxes[i].kind == room.kind
                    && canonicalArchetype(archetype: boxes[i].archetype, name: boxes[i].name) == canon
            }) {
                claimedBoxIndices.insert(idx)
                bind(room: room, to: &boxes[idx], areas: snapshot.entertainmentAreas, lamps: &lamps)
            } else if let idx = boxes.indices.first(where: { i in
                !claimedBoxIndices.contains(i)
                    && canonicalArchetype(archetype: boxes[i].archetype, name: boxes[i].name) == canon
            }) {
                claimedBoxIndices.insert(idx)
                boxes[idx].kind = room.kind
                bind(room: room, to: &boxes[idx], areas: snapshot.entertainmentAreas, lamps: &lamps)
            } else {
                unmatchedRooms.append(room)
            }
        }

        // Pass 2: assign any remaining bridge rooms to unclaimed boxes of the same kind, else append
        var overflowIndex = 0
        let rightEdge = (boxes.map(\.maxX).max() ?? 1000) + 40
        let topEdge = boxes.map(\.minY).min() ?? 80
        for room in unmatchedRooms {
            if let idx = boxes.indices.first(where: { !claimedBoxIndices.contains($0) && boxes[$0].kind == room.kind }) {
                claimedBoxIndices.insert(idx)
                bind(room: room, to: &boxes[idx], areas: snapshot.entertainmentAreas, lamps: &lamps)
            } else {
                let extra = FloorplanBox(
                    id: "box-\(room.hueID)",
                    kind: room.kind,
                    hueID: room.hueID,
                    name: room.name,
                    archetype: room.archetype.isEmpty ? inferArchetype(from: room.name) : room.archetype,
                    x: rightEdge,
                    y: topEdge + Double(overflowIndex) * 240,
                    width: 320,
                    height: 220,
                    entertainmentAreaID: matchingEntertainmentAreaID(for: room, areas: snapshot.entertainmentAreas)
                )
                overflowIndex += 1
                boxes.append(extra)
                placeLights(room.lights, inside: extra, into: &lamps)
            }
        }

        let maxX = (boxes.map(\.maxX).max() ?? 1200) + 160
        let maxY = (boxes.map(\.maxY).max() ?? 800) + 160
        let sensorPlacements = autoPlaceSensors(snapshot.sensors, into: boxes)
        return FloorplanDocument(
            bridgeID: bridgeID,
            templateID: template.rawValue,
            canvas: FloorplanCanvasSettings(width: max(1280, maxX), height: max(820, maxY)),
            entertainmentAreaID: snapshot.entertainmentAreas.first?.id,
            boxes: boxes,
            stamps: stamps,
            lamps: lamps,
            sensors: sensorPlacements
        )
    }

    private static func autoPlaceSensors(
        _ sensors: [HueSensor],
        into boxes: [FloorplanBox]
    ) -> [String: FloorplanSensorPlacement] {
        var placed: [String: FloorplanSensorPlacement] = [:]
        var countByBox: [String: Int] = [:]
        for sensor in sensors {
            guard !sensor.roomID.isEmpty,
                  let box = boxes.first(where: { $0.hueID == sensor.roomID }) else { continue }
            let idx = countByBox[box.id, default: 0]
            countByBox[box.id] = idx + 1
            let px = HueColorMath.clamp(((box.maxX - 36.0 - Double(idx) * 42.0) / 20.0).rounded() * 20.0, box.minX + 26, box.maxX - 24)
            let py = HueColorMath.clamp(((box.maxY - 34.0) / 20.0).rounded() * 20.0, box.minY + 46, box.maxY - 24)
            placed[sensor.id] = FloorplanSensorPlacement(x: px, y: py)
        }
        return placed
    }

    private static func applyDeskStudioMatching(
        boxes initialBoxes: [FloorplanBox],
        stamps: [FloorplanStamp],
        snapshot: HueSnapshot,
        bridgeID: String
    ) -> FloorplanDocument {
        var boxes = initialBoxes
        var lamps: [String: FloorplanLampPlacement] = [:]

        let preferredRoom = snapshot.rooms.first(where: { $0.kind == "room" && canonicalArchetype(room: $0) == "office" })
            ?? snapshot.rooms.first(where: { $0.kind == "room" && canonicalArchetype(room: $0) == "living_room" })
            ?? snapshot.rooms.first(where: { $0.kind == "room" && !$0.hueID.isEmpty })

        if let room = preferredRoom, !boxes.isEmpty {
            boxes[0].hueID = room.hueID
            boxes[0].name = room.name
            boxes[0].archetype = room.archetype.isEmpty ? "office" : room.archetype
            boxes[0].entertainmentAreaID = matchingEntertainmentAreaID(for: room, areas: snapshot.entertainmentAreas)
                ?? snapshot.entertainmentAreas.first?.id
            placeLights(room.lights, inside: boxes[0], into: &lamps)
        } else if !boxes.isEmpty {
            boxes[0].entertainmentAreaID = snapshot.entertainmentAreas.first?.id
            placeLights(Array(snapshot.allLights.prefix(8)), inside: boxes[0], into: &lamps)
        }

        return FloorplanDocument(
            bridgeID: bridgeID,
            templateID: FloorplanTemplate.deskStudio.rawValue,
            canvas: FloorplanCanvasSettings(width: 1120, height: 720),
            entertainmentAreaID: boxes.first?.entertainmentAreaID ?? snapshot.entertainmentAreas.first?.id,
            boxes: boxes,
            stamps: stamps,
            lamps: lamps
        )
    }

    private static func bind(
        room: HueRoom,
        to box: inout FloorplanBox,
        areas: [HueEntertainmentArea],
        lamps: inout [String: FloorplanLampPlacement]
    ) {
        box.hueID = room.hueID
        box.name = room.name
        if !room.archetype.isEmpty {
            box.archetype = room.archetype
        }
        box.entertainmentAreaID = matchingEntertainmentAreaID(for: room, areas: areas)
        placeLights(room.lights, inside: box, into: &lamps)
    }

    private static func placeLights(
        _ lights: [HueLight],
        inside box: FloorplanBox,
        into lamps: inout [String: FloorplanLampPlacement]
    ) {
        let toPlace = lights.filter { lamps[$0.id] == nil }
        guard !toPlace.isEmpty else { return }
        let padX = min(56.0, box.width * 0.18)
        let padTop = min(68.0, box.height * 0.25)
        let padBottom = min(46.0, box.height * 0.18)
        let usableW = max(40.0, box.width - padX * 2)
        let usableH = max(40.0, box.height - padTop - padBottom)
        let cols = max(1, Int(ceil(sqrt(Double(toPlace.count)))))
        let rows = max(1, Int(ceil(Double(toPlace.count) / Double(cols))))

        for (idx, light) in toPlace.enumerated() {
            let c = idx % cols
            let r = idx / cols
            let fx = cols == 1 ? 0.5 : (Double(c) + 0.5) / Double(cols)
            let fy = rows == 1 ? 0.5 : (Double(r) + 0.5) / Double(rows)
            let px = ((box.x + padX + usableW * fx) / 20.0).rounded() * 20.0
            let py = ((box.y + padTop + usableH * fy) / 20.0).rounded() * 20.0
            lamps[light.id] = FloorplanLampPlacement(
                x: HueColorMath.clamp(px, box.minX + 24, box.maxX - 24),
                y: HueColorMath.clamp(py, box.minY + 42, box.maxY - 24),
                z: 0.0,
                icon: LampIcon.inferred(for: light.name)
            )
        }
    }

    private static func matchingEntertainmentAreaID(for room: HueRoom, areas: [HueEntertainmentArea]) -> String? {
        guard !areas.isEmpty else { return nil }
        let lightIDs = Set(room.lights.map(\.id))
        for area in areas {
            let areaLights = Set(area.channels.flatMap(\.lightIDs))
            if !lightIDs.isDisjoint(with: areaLights) {
                return area.id
            }
            if area.name.localizedCaseInsensitiveContains(room.name) {
                return area.id
            }
        }
        return nil
    }

    public static func canonicalArchetype(room: HueRoom) -> String {
        canonicalArchetype(archetype: room.archetype, name: room.name)
    }

    public static func canonicalArchetype(archetype: String, name: String) -> String {
        let lower = name.lowercased()
        let byName: [([String], String)] = [
            (["living", "wohn", "salon", "salón", "soggiorno", "sala", "lounge", "tv"], "living_room"),
            (["office", "büro", "buero", "arbeit", "bureau", "oficina", "ufficio", "escritório", "kantoor", "biuro", "studio", "desk"], "office"),
            (["guest", "gäste", "kinder", "kids", "nursery"], "guest_room"),
            (["bed", "schlaf", "chambre", "dormitorio", "camera", "quarto", "slaap", "sypialnia"], "bedroom"),
            (["kitchen", "küche", "kueche", "cuisine", "cocina", "cucina", "cozinha", "keuken", "kuchnia"], "kitchen"),
            (["hall", "flur", "diele", "eingang", "couloir", "pasillo", "corridoio", "corredor", "gang", "korytarz", "stair", "treppe"], "hallway"),
            (["bath", "bad", "wc", "toilet", "dusche", "shower", "baño", "bagno", "banheiro", "łazienka"], "bathroom"),
            (["terrace", "terrasse", "garten", "garden", "patio", "outdoor", "außen", "jardin"], "terrace"),
            (["balcony", "balkon", "balcon", "balcón", "balcone", "varanda"], "balcony"),
            (["dining", "ess"], "dining"),
            (["garage", "carport"], "garage"),
        ]
        for (keywords, canonical) in byName where keywords.contains(where: { lower.contains($0) }) {
            return canonical
        }
        switch archetype.lowercased() {
        case "living_room", "lounge", "tv", "recreation": return "living_room"
        case "office", "computer", "studio": return "office"
        case "bedroom": return "bedroom"
        case "kids_bedroom", "guest_room", "nursery": return "guest_room"
        case "kitchen": return "kitchen"
        case "dining": return "dining"
        case "hallway", "staircase", "front_door": return "hallway"
        case "bathroom", "toilet": return "bathroom"
        case "terrace", "garden", "porch", "barbecue", "pool": return "terrace"
        case "balcony": return "balcony"
        case "garage", "carport", "driveway": return "garage"
        default: return "other"
        }
    }

    private static func inferArchetype(from name: String) -> String {
        canonicalArchetype(archetype: "", name: name)
    }
}

// MARK: - Spatial Containment, Room Diffs & Entertainment Normalization

public struct RoomMembershipDiff: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { lightID }
    public let lightID: String
    public let lightName: String
    public let deviceID: String
    public let fromRoomID: String?
    public let fromRoomName: String
    public let toBoxID: String
    public let toRoomID: String?
    public let toRoomName: String
    public let sharedDeviceLightNames: [String]

    public init(
        lightID: String,
        lightName: String,
        deviceID: String,
        fromRoomID: String?,
        fromRoomName: String,
        toBoxID: String,
        toRoomID: String?,
        toRoomName: String,
        sharedDeviceLightNames: [String] = []
    ) {
        self.lightID = lightID
        self.lightName = lightName
        self.deviceID = deviceID
        self.fromRoomID = fromRoomID
        self.fromRoomName = fromRoomName
        self.toBoxID = toBoxID
        self.toRoomID = toRoomID
        self.toRoomName = toRoomName
        self.sharedDeviceLightNames = sharedDeviceLightNames
    }
}

public struct FloorplanSyncPlan: Equatable, Sendable {
    public let boxesToCreate: [FloorplanBox]
    public let boxesToUpdateMeta: [FloorplanBox]
    public let membershipDiffs: [RoomMembershipDiff]
    public let entertainmentBoxes: [FloorplanBox]

    public var hasRoomOrMetaChanges: Bool {
        !boxesToCreate.isEmpty || !boxesToUpdateMeta.isEmpty || !membershipDiffs.isEmpty
    }

    public var totalChanges: Int {
        boxesToCreate.count + boxesToUpdateMeta.count + membershipDiffs.count
    }

    public init(
        boxesToCreate: [FloorplanBox] = [],
        boxesToUpdateMeta: [FloorplanBox] = [],
        membershipDiffs: [RoomMembershipDiff] = [],
        entertainmentBoxes: [FloorplanBox] = []
    ) {
        self.boxesToCreate = boxesToCreate
        self.boxesToUpdateMeta = boxesToUpdateMeta
        self.membershipDiffs = membershipDiffs
        self.entertainmentBoxes = entertainmentBoxes
    }
}

public enum FloorplanSpatial {
    /// Returns the smallest-area box containing `(x, y)` matching `kindFilter` (default `"room"`).
    public static func boxContaining(
        x: Double,
        y: Double,
        in boxes: [FloorplanBox],
        kindFilter: String? = "room"
    ) -> FloorplanBox? {
        boxes
            .filter { box in
                if let filter = kindFilter, box.kind != filter { return false }
                return box.contains(x: x, y: y)
            }
            .min(by: { $0.area < $1.area })
    }

    /// Convenience tuple overload matching `(Double, Double)`.
    public static func boxContaining(
        point: (x: Double, y: Double),
        in boxes: [FloorplanBox],
        kindFilter: String? = "room"
    ) -> FloorplanBox? {
        boxContaining(x: point.x, y: point.y, in: boxes, kindFilter: kindFilter)
    }

    /// Detects every placed lamp whose canvas Room box differs from its current Hue Bridge room.
    public static func pendingRoomMembershipDiffs(
        floorplan: FloorplanDocument,
        snapshot: HueSnapshot
    ) -> [RoomMembershipDiff] {
        var currentRoomByLight: [String: (id: String?, name: String)] = [:]
        var lightsByDevice: [String: [HueLight]] = [:]
        var lightByID: [String: HueLight] = [:]

        for room in snapshot.rooms where room.kind != "zone" {
            for light in room.lights {
                lightByID[light.id] = light
                let rid: String? = room.kind == "room" && !room.hueID.isEmpty ? room.hueID : nil
                currentRoomByLight[light.id] = (rid, room.name)
                if !light.deviceID.isEmpty {
                    lightsByDevice[light.deviceID, default: []].append(light)
                }
            }
        }

        var diffs: [RoomMembershipDiff] = []
        for (lightID, placement) in floorplan.lamps {
            guard let light = lightByID[lightID] else { continue }
            guard let targetBox = boxContaining(x: placement.x, y: placement.y, in: floorplan.boxes, kindFilter: "room") else {
                continue
            }
            let current = currentRoomByLight[lightID] ?? (nil, "Other lights")
            if targetBox.hueID == current.id && targetBox.hueID != nil {
                continue
            }
            let siblings = light.deviceID.isEmpty ? [] : (lightsByDevice[light.deviceID] ?? [])
                .filter { $0.id != light.id }
                .map(\.name)
                .sorted()
            diffs.append(RoomMembershipDiff(
                lightID: light.id,
                lightName: light.name,
                deviceID: light.deviceID,
                fromRoomID: current.id,
                fromRoomName: current.name,
                toBoxID: targetBox.id,
                toRoomID: targetBox.hueID,
                toRoomName: targetBox.name,
                sharedDeviceLightNames: siblings
            ))
        }
        return diffs.sorted { $0.lightName.localizedCaseInsensitiveCompare($1.lightName) == .orderedAscending }
    }

    /// Computes a full Bridge sync plan: new room/zone creations, renamed/re-typed rooms,
    /// room membership moves, and boxes linked to Hue Entertainment Areas.
    public static func buildSyncPlan(
        floorplan: FloorplanDocument,
        snapshot: HueSnapshot
    ) -> FloorplanSyncPlan {
        let diffs = pendingRoomMembershipDiffs(floorplan: floorplan, snapshot: snapshot)
        let diffsByBox = Set(diffs.map(\.toBoxID))
        var toCreate: [FloorplanBox] = []
        var toUpdateMeta: [FloorplanBox] = []
        var entBoxes: [FloorplanBox] = []

        for box in floorplan.boxes {
            if let hueID = box.hueID, let room = snapshot.rooms.first(where: { $0.hueID == hueID }) {
                let nameChanged = HueColorMath.clean(box.name, limit: 32) != HueColorMath.clean(room.name, limit: 32)
                let archChanged = !box.archetype.isEmpty && box.archetype != room.archetype && !room.archetype.isEmpty
                if nameChanged || archChanged {
                    toUpdateMeta.append(box)
                }
            } else {
                // Only propose creating unlinked boxes that either contain lamps or were explicitly drawn
                let hasAnyLamp = floorplan.lamps.values.contains { box.contains(x: $0.x, y: $0.y) }
                if hasAnyLamp || diffsByBox.contains(box.id) {
                    toCreate.append(box)
                }
            }
            if let entID = box.entertainmentAreaID, HueColorMath.validUUID(entID) {
                entBoxes.append(box)
            }
        }
        return FloorplanSyncPlan(
            boxesToCreate: toCreate,
            boxesToUpdateMeta: toUpdateMeta,
            membershipDiffs: diffs,
            entertainmentBoxes: entBoxes
        )
    }

    /// Maps every placed lamp inside `box` (or belonging to `box`'s linked room/entertainment area)
    /// into Philips Hue Entertainment 2D/3D coordinates: `x ∈ [-1, 1]`, `y ∈ [0, 1]`, `z ∈ [-1, 1]`.
    public static func entertainmentPositions(
        forBox box: FloorplanBox,
        floorplan: FloorplanDocument,
        snapshot: HueSnapshot
    ) -> [String: (Double, Double, Double)] {
        let entAreaID = box.entertainmentAreaID ?? floorplan.entertainmentAreaID
        var allowedLightIDs = Set<String>()
        if let entID = entAreaID,
           let area = snapshot.entertainmentAreas.first(where: { $0.id == entID }) {
            allowedLightIDs.formUnion(area.channels.flatMap(\.lightIDs))
        }
        if let hueID = box.hueID,
           let room = snapshot.rooms.first(where: { $0.hueID == hueID }) {
            allowedLightIDs.formUnion(room.lights.map(\.id))
        }

        var result: [String: (Double, Double, Double)] = [:]
        for (lightID, placement) in floorplan.lamps {
            let inside = box.contains(x: placement.x, y: placement.y)
            guard inside || allowedLightIDs.contains(lightID) else { continue }
            let nx = HueColorMath.clamp(((placement.x - box.x) / max(1.0, box.width)) * 2.0 - 1.0, -1.0, 1.0)
            let ny = HueColorMath.clamp(1.0 - ((placement.y - box.y) / max(1.0, box.height)), 0.0, 1.0)
            let nz = HueColorMath.clamp(placement.z, -1.0, 1.0)
            let rx = (nx * 10000.0).rounded() / 10000.0
            let ry = (ny * 10000.0).rounded() / 10000.0
            let rz = (nz * 10000.0).rounded() / 10000.0
            result[lightID] = (rx, ry, rz)
        }
        return result
    }
}
