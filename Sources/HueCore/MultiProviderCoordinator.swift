import Foundation

/// Multi-device coordinator implementing `HueBridgeControlling`.
/// Combines the native Philips Hue Bridge client with any number of local-first extra providers
/// (Home Assistant, WLED, WiZ, LIFX, Govee LAN, Nanoleaf, Shelly, IKEA DIRIGERA) into a single
/// unified `HueSnapshot` so rooms, Floorplan, Rules, Schedules, Synth, Ask AI, and MCP work
/// seamlessly across ALL lighting brands simultaneously — even with zero Hue Bridges paired.
@MainActor
public final class MultiProviderBridgeClient: HueBridgeControlling {
    public var onSnapshot: ((HueSnapshot) -> Void)?
    public var onProvidersChanged: (([ProviderConnection], [DiscoveredProviderDevice], Bool) -> Void)?

    public var bridgeID: String {
        let hueID = hueClient.bridgeID
        if !hueID.isEmpty { return hueID }
        if !connections.isEmpty {
            return "multi-home"
        }
        return ""
    }

    public var entertainmentCredentials: BridgeCredentials? {
        hueClient.entertainmentCredentials
    }

    public private(set) var connections: [ProviderConnection]
    public private(set) var discoveredProviders: [DiscoveredProviderDevice] = []
    public private(set) var discoveringProviders: Bool = false

    private let hueClient: HueBridgeControlling
    private let settings: SettingsStore
    private let secretStore: ProviderSecretStoring
    private let ruleEngine: RuleEngine

    private var hueSnapshot: HueSnapshot = .initial
    private var providerResults: [String: ProviderFetchResult] = [:]
    private var providerErrors: [String: String] = [:]
    private var providerConnected: [String: Bool] = [:]
    private var secretCache: [String: String] = [:]
    private var connGenerations: [String: UInt64] = [:]
    private var refreshHoldUntil: [String: Date] = [:]
    private var pendingLightTasks: [String: Task<Void, Never>] = [:]
    private var wledEffectsByConn: [String: [String]] = [:]
    private var nanoleafSceneMap: [String: [String: String]] = [:]
    private var shellyMetaByLightID: [String: ShellyParser.ChannelMeta] = [:]
    private var lifxStateByConn: [String: LIFXCodec.DecodedState] = [:]
    private var dirigeraKelvinBounds: [String: (minK: Int, maxK: Int)] = [:]
    private var lastLightOnState: [String: Bool] = [:]
    private var lastHueLightOnState: [String: Bool] = [:]
    private var lastHueSensorState: [String: (motion: Bool, open: Bool)] = [:]
    private var lastSensorState: [String: (motion: Bool, open: Bool)] = [:]
    private var hueDiffSeeded: Bool = false

    private var pollTask: Task<Void, Never>?
    private var panelOpen: Bool = false
    private var started: Bool = false
    #if canImport(Network)
    private let providerDiscovery = MultiProviderBonjourDiscovery()
    #endif

    public init(
        hueClient: HueBridgeControlling,
        settings: SettingsStore = SettingsStore(),
        secretStore: ProviderSecretStoring = ProviderSecretStore(),
        rules: [HueRule] = [],
        rulesPaused: Bool = false
    ) {
        self.hueClient = hueClient
        self.settings = settings
        self.secretStore = secretStore
        self.connections = settings.loadProviders()
        self.ruleEngine = RuleEngine(rules: rules, paused: rulesPaused)
        self.hueClient.onSnapshot = { [weak self] snap in
            self?.handleHueSnapshot(snap)
        }
    }

    /// Convenience factory using `NativeHueBridgeClient` on macOS.
    #if canImport(Security) && canImport(Network) && canImport(CryptoKit)
    public convenience init(
        keychain: KeychainStoring = KeychainStore(),
        settings: SettingsStore = SettingsStore(),
        secretStore: ProviderSecretStoring = ProviderSecretStore(),
        rules: [HueRule] = [],
        rulesPaused: Bool = false
    ) {
        let native = NativeHueBridgeClient(keychain: keychain, rules: rules, rulesPaused: rulesPaused)
        self.init(hueClient: native, settings: settings, secretStore: secretStore, rules: rules, rulesPaused: rulesPaused)
    }
    #endif

    // MARK: - Lifecycle

    public func start() {
        started = true
        hueClient.start()
        if !enabledConnections.isEmpty {
            refreshExtraProviders()
            startPollLoop()
        }
        emitMergedSnapshot()
    }

    public func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
        #if canImport(Network)
        providerDiscovery.stop()
        #endif
        discoveringProviders = false
        hueClient.stop()
    }

    public func setPanelOpen(_ open: Bool) {
        panelOpen = open
        hueClient.setPanelOpen(open)
        if open && !enabledConnections.isEmpty {
            refreshExtraProviders()
        }
    }

    public func refresh() {
        hueClient.refresh()
        if !enabledConnections.isEmpty {
            refreshExtraProviders()
        }
    }

    /// Awaits an immediate refresh across Hue + all enabled extra providers (used by `--mcp`).
    @discardableResult
    public func refreshNow() async -> HueSnapshot {
        #if canImport(Security) && canImport(Network) && canImport(CryptoKit)
        if let native = hueClient as? NativeHueBridgeClient {
            hueSnapshot = await native.refreshNow()
        }
        #endif
        await refreshExtraProvidersAsync()
        return buildMergedSnapshot()
    }

    public func discover() {
        hueClient.discover()
        discoverProviders()
    }

    public func pair(ip: String) { hueClient.pair(ip: ip) }
    public func cancelPair() { hueClient.cancelPair() }
    public func unpair() { hueClient.unpair() }

    // MARK: - Extra Provider Management

    private var enabledConnections: [ProviderConnection] {
        connections.filter(\.enabled)
    }

    private func cachedSecret(for connectionID: String) -> String? {
        if let cached = secretCache[connectionID] {
            return cached.isEmpty ? nil : cached
        }
        if let loaded = secretStore.loadSecret(for: connectionID), !loaded.isEmpty {
            secretCache[connectionID] = loaded
            return loaded
        }
        secretCache[connectionID] = ""
        return nil
    }

    public func hasSecret(for connectionID: String) -> Bool {
        guard let s = cachedSecret(for: connectionID) else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func discoverProviders() {
        #if canImport(Network)
        discoveringProviders = true
        notifyProvidersChanged()
        providerDiscovery.start(
            onUpdate: { [weak self] list in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.discoveredProviders = list
                    self.notifyProvidersChanged()
                }
            },
            onComplete: { [weak self] list in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.discoveredProviders = list
                    self.discoveringProviders = false
                    self.notifyProvidersChanged()
                }
            }
        )
        #endif
    }

    public func addProvider(_ connection: ProviderConnection, secret: String? = nil) throws {
        var clean = connection
        if clean.id.isEmpty { clean.id = ProviderConnection.makeID() }
        guard clean.isValidHost else {
            throw ProviderClientError.invalidHost
        }

        let trimmedSecret = secret?
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let existing = connections.first(where: { $0.id == clean.id })
        let sameTarget: Bool = {
            guard let ex = existing else { return false }
            return ex.kind == clean.kind
                && ex.host.lowercased() == clean.host.lowercased()
                && ex.effectivePort == clean.effectivePort
        }()

        // Never silently reuse a saved token or pinned cert if the user changed kind/host/port
        if !sameTarget {
            if trimmedSecret.isEmpty && clean.kind.requiresToken {
                throw ProviderClientError.missingToken
            }
            if existing != nil && clean.certFingerprint == existing?.certFingerprint {
                clean.certFingerprint = ""
            }
        } else if clean.certFingerprint.isEmpty, let exFP = existing?.certFingerprint, !exFP.isEmpty {
            clean.certFingerprint = exFP
        }

        var nextConnections = connections
        if let idx = nextConnections.firstIndex(where: { $0.id == clean.id }) {
            nextConnections[idx] = clean
        } else {
            nextConnections.append(clean)
        }

        // Persist secret and settings BEFORE mutating in-memory state so failures never lie to the UI
        if !trimmedSecret.isEmpty {
            try secretStore.saveSecret(trimmedSecret, for: clean.id)
        } else if !sameTarget && existing != nil {
            try? secretStore.deleteSecret(for: clean.id)
        }
        try settings.saveProviders(nextConnections)

        connections = nextConnections
        if !trimmedSecret.isEmpty {
            secretCache[clean.id] = trimmedSecret
        } else if !sameTarget {
            secretCache.removeValue(forKey: clean.id)
        }
        connGenerations[clean.id, default: 0] &+= 1
        providerErrors.removeValue(forKey: clean.id)
        notifyProvidersChanged()
        if started {
            startPollLoop()
            refreshExtraProviders()
        }
        emitMergedSnapshot()
    }

    public func setProviderEnabled(id: String, enabled: Bool) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].enabled = enabled
        connGenerations[id, default: 0] &+= 1
        if !enabled {
            providerResults.removeValue(forKey: id)
            providerConnected[id] = false
            providerErrors.removeValue(forKey: id)
            refreshHoldUntil.removeValue(forKey: id)
        }
        try? settings.saveProviders(connections)
        notifyProvidersChanged()
        if enabled && started {
            startPollLoop()
            refreshExtraProviders()
        }
        emitMergedSnapshot()
    }

    public func removeProvider(id: String) {
        connections.removeAll { $0.id == id }
        connGenerations[id, default: 0] &+= 1
        providerResults.removeValue(forKey: id)
        providerConnected.removeValue(forKey: id)
        providerErrors.removeValue(forKey: id)
        secretCache.removeValue(forKey: id)
        refreshHoldUntil.removeValue(forKey: id)
        wledEffectsByConn.removeValue(forKey: id)
        nanoleafSceneMap.removeValue(forKey: id)
        lifxStateByConn.removeValue(forKey: id)
        for (lid, task) in pendingLightTasks where lid.contains(":\(id):") {
            task.cancel()
            pendingLightTasks.removeValue(forKey: lid)
        }
        try? secretStore.deleteSecret(for: id)
        try? settings.saveProviders(connections)
        if enabledConnections.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
        notifyProvidersChanged()
        emitMergedSnapshot()
    }

    public func testProvider(_ connection: ProviderConnection, secret: String? = nil) async -> Result<String, Error> {
        let existing = connections.first(where: { $0.id == connection.id })
        let sameTarget: Bool = {
            guard let ex = existing else { return false }
            return ex.kind == connection.kind
                && ex.host.lowercased() == connection.host.lowercased()
                && ex.effectivePort == connection.effectivePort
        }()
        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveSecret: String?
        if !trimmed.isEmpty {
            effectiveSecret = trimmed
        } else if sameTarget {
            effectiveSecret = cachedSecret(for: connection.id)
        } else {
            effectiveSecret = nil
        }
        do {
            let res = try await fetchSingleProvider(connection, secret: effectiveSecret)
            return .success("\(res.deviceLabel.isEmpty ? connection.name : res.deviceLabel) · \(res.lightCount)")
        } catch {
            return .failure(error)
        }
    }

    public func pairNanoleaf(host: String, port: Int = 16021) async -> Result<String, Error> {
        do {
            let token = try await NanoleafDriver.pair(host: host, port: port)
            return .success(token)
        } catch {
            return .failure(error)
        }
    }

    public func pairDirigera(host: String, port: Int = 8443) async -> Result<(token: String, certFingerprint: String), Error> {
        do {
            let paired = try await DirigeraDriver.pair(host: host, port: port)
            return .success(paired)
        } catch {
            return .failure(error)
        }
    }

    private func notifyProvidersChanged() {
        onProvidersChanged?(connections, discoveredProviders, discoveringProviders)
    }

    // MARK: - Polling & Fetching Extra Providers

    private func startPollLoop() {
        pollTask?.cancel()
        guard !enabledConnections.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let intervalNs: UInt64 = await MainActor.run {
                    (self?.panelOpen ?? false) ? 4_000_000_000 : 18_000_000_000
                }
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { return }
                await self?.refreshExtraProvidersAsync()
            }
        }
    }

    private func refreshExtraProviders() {
        Task { [weak self] in
            await self?.refreshExtraProvidersAsync()
        }
    }

    private func refreshExtraProvidersAsync() async {
        let active = enabledConnections
        guard !active.isEmpty else {
            emitMergedSnapshot()
            return
        }
        let workItems: [(conn: ProviderConnection, secret: String?, generation: UInt64, startedAt: Date)] = active.map { conn in
            (conn, cachedSecret(for: conn.id), connGenerations[conn.id, default: 0], Date())
        }

        // Fetch all enabled providers concurrently so one slow/offline hub never blocks the rest
        await withTaskGroup(of: (ProviderConnection, UInt64, Date, Result<SingleFetchOutcome, Error>).self) { group in
            for item in workItems {
                group.addTask {
                    do {
                        let outcome = try await Self.fetchProviderOffMain(item.conn, secret: item.secret)
                        return (item.conn, item.generation, item.startedAt, .success(outcome))
                    } catch {
                        return (item.conn, item.generation, item.startedAt, .failure(error))
                    }
                }
            }
            for await (conn, gen, startedAt, outcomeResult) in group {
                // Ignore stale results if this provider was edited, disabled, or removed mid-flight
                guard connGenerations[conn.id, default: 0] == gen,
                      let currentIdx = connections.firstIndex(where: { $0.id == conn.id && $0.enabled }) else {
                    continue
                }
                switch outcomeResult {
                case .success(let outcome):
                    if !outcome.wledEffects.isEmpty { wledEffectsByConn[conn.id] = outcome.wledEffects }
                    if let lifx = outcome.lifxState { lifxStateByConn[conn.id] = lifx }
                    if !outcome.nanoleafScenes.isEmpty { nanoleafSceneMap[conn.id] = outcome.nanoleafScenes }
                    for (lid, meta) in outcome.shellyMeta { shellyMetaByLightID[lid] = meta }
                    for (did, bounds) in outcome.dirigeraBounds { dirigeraKelvinBounds[did] = bounds }

                    // Persist first-seen TOFU TLS certificate fingerprint automatically
                    if !outcome.result.certFingerprint.isEmpty && connections[currentIdx].certFingerprint.isEmpty {
                        connections[currentIdx].certFingerprint = outcome.result.certFingerprint
                        try? settings.saveProviders(connections)
                    }

                    // Respect optimistic-update hold window so an in-flight poll doesn't cause UI flicker
                    if let hold = refreshHoldUntil[conn.id], startedAt < hold {
                        providerConnected[conn.id] = true
                        providerErrors[conn.id] = ""
                        continue
                    }

                    let previous = providerResults[conn.id]
                    providerResults[conn.id] = outcome.result
                    providerConnected[conn.id] = true
                    providerErrors[conn.id] = ""
                    if previous != nil {
                        evaluateCrossBrandDiffs(newResult: outcome.result)
                    } else {
                        seedDiffState(from: outcome.result)
                    }
                case .failure(let error):
                    providerConnected[conn.id] = false
                    providerErrors[conn.id] = error.localizedDescription
                }
            }
        }
        emitMergedSnapshot()
    }

    private struct SingleFetchOutcome: Sendable {
        var result: ProviderFetchResult
        var wledEffects: [String] = []
        var lifxState: LIFXCodec.DecodedState? = nil
        var nanoleafScenes: [String: String] = [:]
        var shellyMeta: [String: ShellyParser.ChannelMeta] = [:]
        var dirigeraBounds: [String: (minK: Int, maxK: Int)] = [:]
    }

    private nonisolated static func fetchProviderOffMain(
        _ conn: ProviderConnection,
        secret: String?
    ) async throws -> SingleFetchOutcome {
        switch conn.kind {
        case .hue:
            throw ProviderClientError.unsupported
        case .homeAssistant:
            let res = try await HomeAssistantDriver.fetchState(connection: conn, secret: secret)
            return SingleFetchOutcome(result: res)
        case .wled:
            let (res, effects) = try await WLEDDriver.fetchState(connection: conn)
            return SingleFetchOutcome(result: res, wledEffects: effects)
        case .wiz:
            let res = try await WiZDriver.fetchState(connection: conn)
            return SingleFetchOutcome(result: res)
        case .lifx:
            let (res, state) = try await LIFXDriver.fetchState(connection: conn)
            return SingleFetchOutcome(result: res, lifxState: state)
        case .govee:
            let res = try await GoveeDriver.fetchState(connection: conn)
            return SingleFetchOutcome(result: res)
        case .nanoleaf:
            let (res, sceneMap) = try await NanoleafDriver.fetchState(connection: conn, secret: secret)
            return SingleFetchOutcome(result: res, nanoleafScenes: sceneMap)
        case .shelly:
            let (res, metaMap) = try await ShellyDriver.fetchState(connection: conn)
            return SingleFetchOutcome(result: res, shellyMeta: metaMap)
        case .dirigera:
            let (res, bounds) = try await DirigeraDriver.fetchState(connection: conn, secret: secret)
            return SingleFetchOutcome(result: res, dirigeraBounds: bounds)
        }
    }

    private func fetchSingleProvider(_ conn: ProviderConnection, secret: String?) async throws -> ProviderFetchResult {
        let outcome = try await Self.fetchProviderOffMain(conn, secret: secret)
        if !outcome.wledEffects.isEmpty { wledEffectsByConn[conn.id] = outcome.wledEffects }
        if let lifx = outcome.lifxState { lifxStateByConn[conn.id] = lifx }
        if !outcome.nanoleafScenes.isEmpty { nanoleafSceneMap[conn.id] = outcome.nanoleafScenes }
        for (lid, meta) in outcome.shellyMeta { shellyMetaByLightID[lid] = meta }
        for (did, bounds) in outcome.dirigeraBounds { dirigeraKelvinBounds[did] = bounds }
        return outcome.result
    }

    private func seedDiffState(from res: ProviderFetchResult) {
        for room in res.rooms {
            for light in room.lights {
                lastLightOnState[light.id] = light.on
            }
        }
        for sensor in res.sensors {
            lastSensorState[sensor.id] = (sensor.motion, sensor.open)
        }
    }

    private func evaluateCrossBrandDiffs(newResult: ProviderFetchResult) {
        let snap = buildMergedSnapshot()
        for room in newResult.rooms {
            for light in room.lights {
                let prev = lastLightOnState[light.id]
                lastLightOnState[light.id] = light.on
                if let prev = prev, prev != light.on {
                    let actions = ruleEngine.evaluateChange(
                        kind: "light",
                        id: light.id,
                        isOn: light.on,
                        bri: light.bri,
                        snapshot: snap
                    )
                    executeRuleActions(actions, snapshot: snap)
                }
            }
        }
        for sensor in newResult.sensors {
            let prev = lastSensorState[sensor.id]
            lastSensorState[sensor.id] = (sensor.motion, sensor.open)
            if let prev = prev {
                if sensor.kind == "motion" && prev.motion != sensor.motion {
                    let actions = ruleEngine.evaluateSensorEvent(
                        kind: "motion",
                        id: sensor.id,
                        state: sensor.motion ? "motion" : "clear",
                        snapshot: snap
                    )
                    executeRuleActions(actions, snapshot: snap)
                } else if sensor.kind == "contact" && prev.open != sensor.open {
                    let actions = ruleEngine.evaluateSensorEvent(
                        kind: "contact",
                        id: sensor.id,
                        state: sensor.open ? "open" : "closed",
                        snapshot: snap
                    )
                    executeRuleActions(actions, snapshot: snap)
                }
            }
        }
    }

    private func executeRuleActions(_ actions: [RuleAction], snapshot: HueSnapshot) {
        for action in actions {
            if let sceneID = action.sceneID, !sceneID.isEmpty {
                recallScene(id: sceneID)
            } else if action.kind == "room", let room = snapshot.room(action.id) {
                if !room.groupedLight.isEmpty {
                    setGroup(id: room.groupedLight, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                } else {
                    for light in room.lights {
                        setLight(id: light.id, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                    }
                }
            } else if action.kind == "light" {
                setLight(id: action.id, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
            }
        }
    }

    // MARK: - Snapshot Merging

    private func handleHueSnapshot(_ snap: HueSnapshot) {
        hueSnapshot = snap
        // Evaluate Hue -> non-Hue cross-brand rules when Hue lights or sensors change
        if !enabledConnections.isEmpty && snap.isPaired {
            if !hueDiffSeeded {
                for room in snap.rooms {
                    for light in room.lights { lastHueLightOnState[light.id] = light.on }
                }
                for sensor in snap.sensors { lastHueSensorState[sensor.id] = (sensor.motion, sensor.open) }
                hueDiffSeeded = true
            } else {
                let merged = buildMergedSnapshot()
                for room in snap.rooms {
                    for light in room.lights {
                        let prev = lastHueLightOnState[light.id]
                        lastHueLightOnState[light.id] = light.on
                        if let prev = prev, prev != light.on {
                            let actions = ruleEngine.evaluateChange(
                                kind: "light",
                                id: light.id,
                                isOn: light.on,
                                bri: light.bri,
                                snapshot: merged
                            )
                            let nonHue = actions.filter { HueColorMath.providerPrefix(of: $0.id) != "hue" }
                            executeRuleActions(nonHue, snapshot: merged)
                        }
                    }
                }
                for sensor in snap.sensors {
                    let prev = lastHueSensorState[sensor.id]
                    lastHueSensorState[sensor.id] = (sensor.motion, sensor.open)
                    if let prev = prev {
                        if sensor.kind == "motion" && prev.motion != sensor.motion {
                            let actions = ruleEngine.evaluateSensorEvent(
                                kind: "motion",
                                id: sensor.id,
                                state: sensor.motion ? "motion" : "clear",
                                snapshot: merged
                            )
                            let nonHue = actions.filter { HueColorMath.providerPrefix(of: $0.id) != "hue" }
                            executeRuleActions(nonHue, snapshot: merged)
                        } else if sensor.kind == "contact" && prev.open != sensor.open {
                            let actions = ruleEngine.evaluateSensorEvent(
                                kind: "contact",
                                id: sensor.id,
                                state: sensor.open ? "open" : "closed",
                                snapshot: merged
                            )
                            let nonHue = actions.filter { HueColorMath.providerPrefix(of: $0.id) != "hue" }
                            executeRuleActions(nonHue, snapshot: merged)
                        }
                    }
                }
            }
        }
        emitMergedSnapshot()
    }

    private func emitMergedSnapshot() {
        onSnapshot?(buildMergedSnapshot())
    }

    public func buildMergedSnapshot() -> HueSnapshot {
        var merged = hueSnapshot
        let activeConns = enabledConnections

        var providerStatuses: [ProviderStatus] = []
        if let bridge = hueSnapshot.bridge {
            providerStatuses.append(ProviderStatus(
                id: "hue-bridge",
                kind: .hue,
                name: bridge.name.isEmpty ? "Hue Bridge" : bridge.name,
                host: bridge.ip,
                connected: hueSnapshot.phase == "ok",
                enabled: true,
                lightCount: hueSnapshot.lightCount,
                error: hueSnapshot.error
            ))
        }

        var extraRooms: [HueRoom] = []
        var extraSensors: [HueSensor] = []
        var extraLights = 0
        var extraOn = 0

        for conn in connections {
            let res = conn.enabled ? providerResults[conn.id] : nil
            let isConnected = conn.enabled && (providerConnected[conn.id] ?? false)
            let err = conn.enabled ? (providerErrors[conn.id] ?? "") : ""
            providerStatuses.append(ProviderStatus(
                id: conn.id,
                kind: conn.kind,
                name: conn.name,
                host: conn.host,
                connected: isConnected,
                enabled: conn.enabled,
                lightCount: res?.lightCount ?? 0,
                error: err
            ))
            if let res = res {
                extraRooms.append(contentsOf: res.rooms)
                extraSensors.append(contentsOf: res.sensors)
                extraLights += res.lightCount
                extraOn += res.onCount
            }
        }

        merged.providers = providerStatuses
        merged.hueBridgePaired = hueSnapshot.isPaired
        if !activeConns.isEmpty {
            merged.rooms = hueSnapshot.rooms + extraRooms
            merged.sensors = hueSnapshot.sensors + extraSensors
            merged.lightCount = hueSnapshot.lightCount + extraLights
            merged.onCount = hueSnapshot.onCount + extraOn

            // If no Hue Bridge is paired, having enabled extra providers still unlocks the full app!
            if !hueSnapshot.isPaired && !hueSnapshot.isPairing {
                let anyLoaded = activeConns.contains { providerResults[$0.id] != nil }
                let allErrored = activeConns.allSatisfy { !(providerErrors[$0.id] ?? "").isEmpty }
                if anyLoaded {
                    merged.phase = "ok"
                    merged.error = ""
                } else if allErrored {
                    merged.phase = "error"
                    merged.error = activeConns.compactMap { providerErrors[$0.id] }.first(where: { !$0.isEmpty }) ?? ""
                } else {
                    merged.phase = "connecting"
                }
                let labels = Array(Set(activeConns.map { $0.kind.shortBadge })).sorted().joined(separator: ", ")
                let title = activeConns.count == 1 ? activeConns[0].name : "\(activeConns.count) Devices"
                merged.bridge = BridgeInfo(
                    ip: activeConns.count == 1 ? activeConns[0].host : labels,
                    name: title,
                    model: labels
                )
            }
        }

        if !ruleEngine.log.isEmpty {
            merged.ruleLog = (merged.ruleLog + ruleEngine.log)
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(RuleEngine.maxLogEntries)
                .map { $0 }
        }
        return merged
    }

    // MARK: - Command Routing across ALL Providers

    public func setLight(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        let prefix = HueColorMath.providerPrefix(of: id)
        if prefix == "hue" {
            hueClient.setLight(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
            return
        }

        ruleEngine.recordOutgoing(kind: "light", id: id, expectedOn: on)
        applyOptimisticLightUpdate(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        if let on = on {
            lastLightOnState[id] = on
        }
        let idParts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        if idParts.count >= 2 {
            refreshHoldUntil[String(idParts[1])] = Date().addingTimeInterval(2.5)
        }
        emitMergedSnapshot()

        // Evaluate cross-brand rules triggered by this non-Hue light toggle
        if let on = on {
            let snap = buildMergedSnapshot()
            let actions = ruleEngine.evaluateChange(
                kind: "light",
                id: id,
                isOn: on,
                bri: bri.map(Double.init),
                snapshot: snap,
                bypassEcho: true
            )
            executeRuleActions(actions, snapshot: snap)
        }

        // Cancel any superseded in-flight command for the same light so slider drags land on the latest value
        pendingLightTasks[id]?.cancel()
        pendingLightTasks[id] = Task { [weak self] in
            guard let self = self else { return }
            await self.dispatchSetLight(prefix: prefix, id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        }
    }

    private func dispatchSetLight(
        prefix: String,
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) async {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let connID = String(parts[1])
        let rest = String(parts[2])
        guard let conn = connections.first(where: { $0.id == connID && $0.enabled }) else { return }
        let secret = cachedSecret(for: conn.id)

        do {
            switch conn.kind {
            case .homeAssistant:
                try await HomeAssistantDriver.setLight(connection: conn, secret: secret, entityID: rest, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
            case .wled:
                try await WLEDDriver.setLight(connection: conn, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect, effectsList: wledEffectsByConn[conn.id] ?? [])
            case .wiz:
                try await WiZDriver.setLight(connection: conn, on: on, bri: bri, mirek: mirek, xy: xy)
            case .lifx:
                try await LIFXDriver.setLight(connection: conn, cachedState: lifxStateByConn[conn.id], on: on, bri: bri, mirek: mirek, xy: xy)
            case .govee:
                try await GoveeDriver.setLight(connection: conn, on: on, bri: bri, mirek: mirek, xy: xy)
            case .nanoleaf:
                try await NanoleafDriver.setLight(connection: conn, secret: secret, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
            case .shelly:
                if let meta = shellyMetaByLightID[id] {
                    try await ShellyDriver.setLight(connection: conn, meta: meta, on: on, bri: bri, mirek: mirek, xy: xy)
                }
            case .dirigera:
                try await DirigeraDriver.setLight(
                    connection: conn,
                    secret: secret,
                    deviceID: rest,
                    on: on,
                    bri: bri,
                    mirek: mirek,
                    xy: xy,
                    kelvinBounds: dirigeraKelvinBounds[rest]
                )
            case .hue:
                break
            }
            providerErrors[conn.id] = ""
        } catch {
            providerErrors[conn.id] = error.localizedDescription
            emitMergedSnapshot()
        }
    }

    public func setGroup(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        if HueColorMath.providerPrefix(of: id) == "hue" {
            hueClient.setGroup(id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        }
    }

    public func recallScene(id: String) {
        let prefix = HueColorMath.providerPrefix(of: id)
        if prefix == "hue" {
            hueClient.recallScene(id: id)
            return
        }
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let connID = String(parts[1])
        let rest = String(parts[2])
        guard let conn = connections.first(where: { $0.id == connID && $0.enabled }) else { return }
        let secret = cachedSecret(for: conn.id)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                switch conn.kind {
                case .homeAssistant:
                    try await HomeAssistantDriver.recallScene(connection: conn, secret: secret, entityID: rest)
                case .wled:
                    if rest.hasPrefix("ps:"), let pid = Int(rest.dropFirst(3)) {
                        try await WLEDDriver.recallPreset(connection: conn, presetID: pid)
                    }
                case .wiz:
                    if rest.hasPrefix("scene:"), let sid = Int(rest.dropFirst(6)) {
                        try await WiZDriver.setLight(connection: conn, on: true, bri: nil, mirek: nil, xy: nil, sceneID: sid)
                    }
                case .nanoleaf:
                    if let fx = self.nanoleafSceneMap[conn.id]?[id] {
                        try await NanoleafDriver.setLight(connection: conn, secret: secret, on: true, bri: nil, mirek: nil, xy: nil, effect: fx)
                    }
                case .dirigera:
                    if rest.hasPrefix("scene:") {
                        try await DirigeraDriver.recallScene(connection: conn, secret: secret, sceneID: String(rest.dropFirst(6)))
                    }
                default:
                    break
                }
                await self.refreshExtraProvidersAsync()
            } catch {
                self.providerErrors[conn.id] = error.localizedDescription
                self.emitMergedSnapshot()
            }
        }
    }

    public func allOn(excludeRooms: Set<String>) {
        if hueSnapshot.isPaired {
            hueClient.allOn(excludeRooms: excludeRooms)
        }
        let activeIDs = Set(enabledConnections.map(\.id))
        for (connID, res) in providerResults where activeIDs.contains(connID) {
            for room in res.rooms where !excludeRooms.contains(room.id) && !excludeRooms.contains(room.hueID) {
                for light in room.lights {
                    setLight(id: light.id, on: true, bri: nil, mirek: nil, xy: nil, effect: nil)
                }
            }
        }
    }

    public func allOff() {
        if hueSnapshot.isPaired {
            hueClient.allOff()
        }
        let activeIDs = Set(enabledConnections.map(\.id))
        for (connID, res) in providerResults where activeIDs.contains(connID) {
            for room in res.rooms {
                for light in room.lights where light.on {
                    setLight(id: light.id, on: false, bri: nil, mirek: nil, xy: nil, effect: nil)
                }
            }
        }
    }

    public func createSchedule(_ draft: HueScheduleDraft) { hueClient.createSchedule(draft) }
    public func toggleSchedule(id: String, enabled: Bool) { hueClient.toggleSchedule(id: id, enabled: enabled) }
    public func deleteSchedule(id: String) { hueClient.deleteSchedule(id: id) }

    public func setRules(_ rules: [HueRule], paused: Bool) {
        ruleEngine.rules = rules
        ruleEngine.paused = paused
        // Only pass pure-Hue rules to hueClient so desktop/cross-brand rules are never double-evaluated or double-logged
        let hueOnly = rules.filter { rule in
            HueColorMath.providerPrefix(of: rule.targetID) == "hue"
                && (rule.triggerKind == "desktop" || HueColorMath.providerPrefix(of: rule.triggerID) == "hue")
        }
        hueClient.setRules(hueOnly, paused: paused)
    }

    public func triggerDesktopEvent(_ event: String) {
        if hueSnapshot.isPaired {
            hueClient.triggerDesktopEvent(event)
        }
        let snap = buildMergedSnapshot()
        let nonHueRules = ruleEngine.rules.filter { HueColorMath.providerPrefix(of: $0.targetID) != "hue" }
        guard !nonHueRules.isEmpty else { return }
        let savedRules = ruleEngine.rules
        ruleEngine.rules = nonHueRules
        let actions = ruleEngine.evaluateDesktopEvent(event, snapshot: snap)
        ruleEngine.rules = savedRules
        executeRuleActions(actions, snapshot: snap)
    }

    public func renameLight(id: String, name: String) {
        if HueColorMath.providerPrefix(of: id) == "hue" {
            hueClient.renameLight(id: id, name: name)
        } else {
            let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2, let idx = connections.firstIndex(where: { $0.id == String(parts[1]) }) {
                let clean = HueColorMath.clean(name, limit: 40)
                if !clean.isEmpty {
                    connections[idx].name = clean
                    try? settings.saveProviders(connections)
                    notifyProvidersChanged()
                    refreshExtraProviders()
                }
            }
        }
    }

    @discardableResult
    public func createRoom(kind: String, name: String, archetype: String, deviceIDs: [String]) async -> String? {
        await hueClient.createRoom(kind: kind, name: name, archetype: archetype, deviceIDs: deviceIDs)
    }

    @discardableResult
    public func updateRoom(id: String, kind: String, name: String?, archetype: String?, deviceIDs: [String]?) async -> Bool {
        guard HueColorMath.validUUID(id) else { return false }
        return await hueClient.updateRoom(id: id, kind: kind, name: name, archetype: archetype, deviceIDs: deviceIDs)
    }

    @discardableResult
    public func deleteRoom(id: String, kind: String) async -> Bool {
        guard HueColorMath.validUUID(id) else { return false }
        return await hueClient.deleteRoom(id: id, kind: kind)
    }

    @discardableResult
    public func createSceneFromRoom(roomID: String, name: String) async -> String? {
        guard HueColorMath.validUUID(roomID) else { return nil }
        return await hueClient.createSceneFromRoom(roomID: roomID, name: name)
    }

    @discardableResult
    public func updateEntertainmentLocations(areaID: String, positions: [String: (Double, Double, Double)]) async -> Bool {
        await hueClient.updateEntertainmentLocations(areaID: areaID, positions: positions)
    }

    public func setEntertainmentActive(areaID: String, active: Bool) async -> Bool {
        await hueClient.setEntertainmentActive(areaID: areaID, active: active)
    }

    public func setSensorEnabled(kind: String, id: String, enabled: Bool) {
        if HueColorMath.validUUID(id) {
            hueClient.setSensorEnabled(kind: kind, id: id, enabled: enabled)
        }
    }

    public func updateMotionArea(id: String, convenienceID: String?, enabled: Bool?, sensitivity: Int?) {
        hueClient.updateMotionArea(id: id, convenienceID: convenienceID, enabled: enabled, sensitivity: sensitivity)
    }

    // MARK: - Optimistic Local State Update for Instant UI Feedback

    private func applyOptimisticLightUpdate(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        for (connID, res) in providerResults {
            var updatedRooms: [HueRoom] = []
            var changed = false
            for room in res.rooms {
                var updatedLights: [HueLight] = []
                for light in room.lights {
                    if light.id == id {
                        changed = true
                        let newOn = on ?? light.on
                        let newBri = bri.map(Double.init) ?? light.bri
                        let newColor: String = {
                            if let xy = xy { return HueColorMath.xyToHex(x: xy.0, y: xy.1) }
                            if let m = mirek { return HueColorMath.mirekToHex(m) }
                            return light.color
                        }()
                        updatedLights.append(HueLight(
                            id: light.id,
                            deviceID: light.deviceID,
                            name: light.name,
                            on: newOn,
                            bri: newBri,
                            dimmable: light.dimmable,
                            color: newColor,
                            reachable: light.reachable,
                            supportsColor: light.supportsColor,
                            supportsCT: light.supportsCT,
                            mirek: mirek ?? light.mirek,
                            mirekMin: light.mirekMin,
                            mirekMax: light.mirekMax,
                            effect: effect ?? light.effect,
                            availableEffects: light.availableEffects,
                            motionAware: light.motionAware,
                            motionActive: light.motionActive,
                            provider: light.provider
                        ))
                    } else {
                        updatedLights.append(light)
                    }
                }
                let onMembers = updatedLights.filter(\.on)
                let avgBri = onMembers.isEmpty ? 0.0 : (onMembers.map(\.bri).reduce(0, +) / Double(onMembers.count)).rounded()
                updatedRooms.append(HueRoom(
                    hueID: room.hueID,
                    kind: room.kind,
                    name: room.name,
                    groupedLight: room.groupedLight,
                    on: !onMembers.isEmpty,
                    bri: avgBri,
                    onCount: onMembers.count,
                    archetype: room.archetype,
                    color: HueColorMath.blendColors(onMembers.map(\.color)),
                    lights: updatedLights,
                    scenes: room.scenes,
                    provider: room.provider
                ))
            }
            if changed {
                providerResults[connID] = ProviderFetchResult(
                    rooms: updatedRooms,
                    sensors: res.sensors,
                    deviceLabel: res.deviceLabel
                )
            }
        }
    }
}
