import AppKit
import Combine
import HueCore
import SwiftUI

/// The app's state: the helper's latest snapshot, the UI's own state (expanded cards, sliders being
/// dragged, the settings page) and every action, which become helper commands. Used from the
/// main actor only (SwiftUI views, the app delegate, main-queue callbacks of the supervisor).
@MainActor
final class HueStore: ObservableObject {
    static let shared = HueStore()

    enum Page { case main, settings }

    @Published private(set) var snapshot = HueSnapshot.initial
    @Published private(set) var helperStatus: HelperSupervisor.Status = .starting
    @Published private(set) var l10n: L10n
    @Published private(set) var dragging: [String: Double] = [:]
    @Published var expanded: Set<String> = []
    @Published var allScenes: Set<String> = []
    @Published var page: Page = .main
    @Published var manualIP = ""
    @Published var confirmUnpair = false
    @Published private(set) var languageError = false

    private let settings = SettingsStore()
    private let catalogs: L10n.Catalogs
    private let supervisor: HelperSupervisor
    private var debouncer: BrightnessDebouncer?
    private(set) var panelOpen = false

    init() {
        let locator = ResourceLocator()
        let loaded = L10n.loadCatalogs(from: locator.translations)
        catalogs = loaded
        l10n = L10n(catalogs: loaded, setting: SettingsStore().language())
        supervisor = HelperSupervisor(scriptURL: locator.helperScript)
        debouncer = BrightnessDebouncer(interval: 0.15, send: { [weak self] target, value in
            self?.sendBrightness(target, value)
        })
        supervisor.onSnapshot = { [weak self] snapshot in self?.receive(snapshot) }
        supervisor.onStatus = { [weak self] status in self?.helperStatus = status }
        supervisor.onStarted = { [weak self] in
            guard let self = self else { return }
            self.supervisor.send(self.panelOpen ? .panelOpen : .panelClosed)
        }
    }

    // MARK: - lifecycle

    func start() { supervisor.start() }

    /// App quits: the helper ends with it (stdin closed, then SIGTERM, then SIGKILL).
    func shutdown() { supervisor.stop() }

    /// The popover was shown or hidden: the helper polls every 2 s while open, every 20 s closed.
    func setPanel(open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        supervisor.send(open ? .panelOpen : .panelClosed)
        if !open {
            confirmUnpair = false
            page = .main
        }
    }

    private func receive(_ new: HueSnapshot) {
        if !new.isPaired { confirmUnpair = false }
        snapshot = new
    }

    // MARK: - texts

    func tr(_ key: String) -> String { l10n.tr(key) }
    func trf(_ key: String, _ args: [String]) -> String { l10n.trf(key, args) }

    /// The one line shown above the content when something is wrong, else nil.
    var problem: String? {
        switch helperStatus {
        case .pythonMissing:
            return tr("Python 3 was not found. Install the Xcode Command Line Tools (xcode-select --install) or Homebrew python3.")
        case .scriptMissing:
            return tr("The helper script is missing from the app.")
        case .restarting:
            return tr("The Hue helper stopped. Restarting in 5 s …")
        default:
            return snapshot.error.isEmpty ? nil : l10n.errorText(snapshot)
        }
    }

    var helperReady: Bool { helperStatus == .running }

    // MARK: - language

    var languageSetting: String { l10n.setting }

    func setLanguage(_ code: String) {
        do {
            try settings.setLanguage(code)
            languageError = false
        } catch {
            languageError = true
        }
        l10n = L10n(catalogs: catalogs, setting: code)
    }

    // MARK: - lights

    func setRoom(_ room: HueRoom, on: Bool) {
        HueCommand.room(room, on: on).forEach(supervisor.send)
    }

    func setLight(_ light: HueLight, on: Bool) {
        supervisor.send(.light(id: light.id, on: on))
    }

    func recall(_ scene: HueScene) { supervisor.send(.scene(id: scene.id)) }

    func allOff() {
        if snapshot.anyLightOn { supervisor.send(.allOff) }
    }

    func refresh() { supervisor.send(.refresh) }

    static func target(room: HueRoom) -> String { "room:" + room.id }
    static func target(light: HueLight) -> String { "light:" + light.id }

    /// The slider's value: the dragged one, else the bridge's (at least 1 %).
    func brightness(_ target: String, bridge: Double) -> Double {
        dragging[target] ?? max(1, bridge)
    }

    func drag(_ target: String, to value: Double) {
        dragging[target] = value
        debouncer?.update(target, brightnessStep(value))
    }

    func release(_ target: String) {
        debouncer?.finish(target)
        dragging.removeValue(forKey: target)
    }

    private func sendBrightness(_ target: String, _ value: Int) {
        if target.hasPrefix("room:") {
            let key = String(target.dropFirst(5))
            if let room = snapshot.room(key) {
                HueCommand.room(room, bri: value).forEach(supervisor.send)
            }
        } else if target.hasPrefix("light:") {
            supervisor.send(.light(id: String(target.dropFirst(6)), bri: value))
        }
    }

    func toggleExpanded(_ room: HueRoom) {
        if expanded.remove(room.id) == nil { expanded.insert(room.id) }
    }

    func toggleAllScenes(_ room: HueRoom) {
        if allScenes.remove(room.id) == nil { allScenes.insert(room.id) }
    }

    // MARK: - bridge

    func discover() { supervisor.send(.discover) }

    func pair(_ ip: String) {
        let ip = cleanedIP(ip)
        if !ip.isEmpty { supervisor.send(.pair(ip: ip)) }
    }

    func cancelPair() { supervisor.send(.cancelPair) }

    func unpair() {
        confirmUnpair = false
        expanded.removeAll()
        allScenes.removeAll()
        supervisor.send(.unpair)
        page = .main
    }

    func quit() { NSApp.terminate(nil) }
}
