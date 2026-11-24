import Foundation

/// Draft input for creating a new Hue Bridge schedule (`behavior_instance`).
public struct HueScheduleDraft: Equatable, Sendable {
    public var name: String
    /// "light" or "room"
    public var targetKind: String
    public var targetID: String
    public var targetName: String
    /// "time", "sunrise", or "sunset"
    public var triggerKind: String
    /// "HH:MM"
    public var time: String
    /// Offset in minutes for sunrise/sunset (-60...60)
    public var offsetMin: Int
    /// Weekday names (e.g. ["monday", "tuesday"]), empty = daily
    public var days: [String]
    /// "on", "off", or "scene"
    public var action: String
    public var bri: Int?
    public var sceneID: String
    public var fadeMin: Int

    public init(
        name: String,
        targetKind: String,
        targetID: String,
        targetName: String,
        triggerKind: String = "time",
        time: String = "07:00",
        offsetMin: Int = 0,
        days: [String] = [],
        action: String = "on",
        bri: Int? = 80,
        sceneID: String = "",
        fadeMin: Int = 0
    ) {
        self.name = name
        self.targetKind = targetKind
        self.targetID = targetID
        self.targetName = targetName
        self.triggerKind = triggerKind
        self.time = time
        self.offsetMin = offsetMin
        self.days = days
        self.action = action
        self.bri = bri
        self.sceneID = sceneID
        self.fadeMin = fadeMin
    }
}

/// Unified controller interface implemented by both `NativeHueBridgeClient` and `DemoBridgeClient`,
/// allowing `HueStore` to seamlessly switch between a real Philips Hue Bridge and Demo Mode.
@MainActor
public protocol HueBridgeControlling: AnyObject {
    var onSnapshot: ((HueSnapshot) -> Void)? { get set }
    var bridgeID: String { get }

    func start()
    func stop()
    func setPanelOpen(_ open: Bool)
    func refresh()
    func discover()
    func pair(ip: String)
    func cancelPair()
    func unpair()

    func setLight(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    )

    func setGroup(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    )

    func recallScene(id: String)
    func allOn(excludeRooms: Set<String>)
    func allOff()

    func createSchedule(_ draft: HueScheduleDraft)
    func toggleSchedule(id: String, enabled: Bool)
    func deleteSchedule(id: String)

    func setRules(_ rules: [HueRule], paused: Bool)
    func triggerDesktopEvent(_ event: String)

    // Two-way Hue Bridge CLIP v2 spatial & organization mutations
    func renameLight(id: String, name: String)
    @discardableResult
    func createRoom(kind: String, name: String, archetype: String, deviceIDs: [String]) async -> String?
    @discardableResult
    func updateRoom(id: String, kind: String, name: String?, archetype: String?, deviceIDs: [String]?) async -> Bool
    @discardableResult
    func deleteRoom(id: String, kind: String) async -> Bool
    @discardableResult
    func createSceneFromRoom(roomID: String, name: String) async -> String?
    @discardableResult
    func updateEntertainmentLocations(areaID: String, positions: [String: (Double, Double, Double)]) async -> Bool

    /// Bridge credentials for optional Entertainment v2 DTLS streaming (nil in Demo Mode or unpaired).
    var entertainmentCredentials: BridgeCredentials? { get }
    func setEntertainmentActive(areaID: String, active: Bool) async -> Bool

    // Physical Hue sensors & Bridge Pro MotionAware™ controls
    func setSensorEnabled(kind: String, id: String, enabled: Bool)
    func updateMotionArea(id: String, convenienceID: String?, enabled: Bool?, sensitivity: Int?)
}
