import Foundation
#if canImport(Security) && canImport(Network) && canImport(CryptoKit)
import CryptoKit
import Network
import Security

/// Native macOS App Sandbox-compliant Philips Hue CLIP v2 client.
/// - Pinned HTTPS `URLSession` verifying leaf certificate SHA-256 fingerprint + Subject CN == bridgeID
/// - Native Bonjour discovery (`NWBrowser` for `_hue._tcp`)
/// - Keychain credential storage (`KeychainStore`)
/// - Live `/eventstream/clip/v2` SSE updates with exponential backoff + periodic reconciliation
/// - Local automation `RuleEngine` execution on real-time SSE & desktop wake/sleep events
@MainActor
public final class NativeHueBridgeClient: HueBridgeControlling {
    public var onSnapshot: ((HueSnapshot) -> Void)?

    private let keychain: KeychainStoring
    private let ruleEngine: RuleEngine

    private var credentials: BridgeCredentials?
    private var pinnedSession: URLSession?
    private var sseSession: URLSession?
    private var pinnedDelegate: HuePinnedSessionDelegate?

    private var phase: String = "unpaired"
    private var errorText: String = ""
    private var errorCode: String = ""
    private var errorArgs: [String] = []
    private var rooms: [HueRoom] = []
    private var lightCount: Int = 0
    private var onCount: Int = 0
    private var bridgeHomeGroupedLight: String = ""
    private var scheduleScriptID: String = HueModelBuilder.defaultScheduleScriptID
    private var schedules: [HueSchedule] = []
    private var entertainmentAreas: [HueEntertainmentArea] = []
    private var entertainmentServiceByLight: [String: String] = [:]
    private var candidates: [BridgeCandidate] = []
    private var discovering: Bool = false
    private var pairIP: String = ""
    private var pairRemaining: Int = 0

    private var panelOpen: Bool = false
    private var connGeneration: Int = 0
    private var pairGeneration: Int = 0
    private var discoveryGeneration: Int = 0

    private var sseTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var manualRefreshTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>?
    private var browser: NWBrowser?
    private var pendingCommandTasks: [String: Task<Void, Never>] = [:]
    private let networkQueue = DispatchQueue(label: "com.maprisma.lights.network")

    public init(keychain: KeychainStoring = KeychainStore(), rules: [HueRule] = [], rulesPaused: Bool = false) {
        self.keychain = keychain
        self.ruleEngine = RuleEngine(rules: rules, paused: rulesPaused)
        if let saved = keychain.load(),
           HueColorMath.validBridgeIP(saved.ip),
           HueColorMath.validBridgeID(saved.bridgeID),
           saved.fingerprint.count == 64,
           !saved.appKey.isEmpty {
            self.credentials = saved
            self.phase = "connecting"
            rebuildPinnedSessions(for: saved)
        } else {
            self.credentials = nil
            self.phase = "unpaired"
        }
    }

    // MARK: - Lifecycle

    public func start() {
        emit()
        if credentials != nil {
            startConnectedLoops()
        } else {
            discover()
        }
    }

    public func stop() {
        connGeneration += 1
        pairGeneration += 1
        discoveryGeneration += 1
        discovering = false
        sseTask?.cancel()
        sseTask = nil
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        pairTask?.cancel()
        pairTask = nil
        discoverTask?.cancel()
        discoverTask = nil
        browser?.cancel()
        browser = nil
        for task in pendingCommandTasks.values { task.cancel() }
        pendingCommandTasks.removeAll()
        teardownPinnedSessions()
    }

    public func setPanelOpen(_ open: Bool) {
        let changed = panelOpen != open
        panelOpen = open
        guard changed, open else { return }
        if credentials != nil {
            refresh()
        } else if candidates.isEmpty && !discovering {
            discover()
        }
    }

    public func refresh() {
        guard let creds = credentials else { return }
        let gen = connGeneration
        manualRefreshTask?.cancel()
        manualRefreshTask = Task { [weak self] in
            await self?.performRefresh(credentials: creds, generation: gen)
        }
    }

    // MARK: - Native Bonjour Discovery (NWBrowser)

    public func discover() {
        guard !discovering else { return }
        discoveryGeneration += 1
        let discGen = discoveryGeneration
        discovering = true
        emit()

        browser?.cancel()
        discoverTask?.cancel()

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let newBrowser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: "local."), using: params)
        browser = newBrowser

        let collector = DiscoveryCollector()
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            for result in results {
                self.resolveBonjourResult(result, collector: collector, discoveryGen: discGen)
            }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in
                    self?.finishDiscovery(collector: collector, discoveryGen: discGen)
                }
            }
        }
        newBrowser.start(queue: networkQueue)

        discoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishDiscovery(collector: collector, discoveryGen: discGen)
            }
        }
    }

    private nonisolated func resolveBonjourResult(_ result: NWBrowser.Result, collector: DiscoveryCollector, discoveryGen: Int) {
        let resolvedName: String = {
            if case .service(let svcName, _, _, _) = result.endpoint {
                let cleaned = HueColorMath.clean(svcName)
                if !cleaned.isEmpty { return cleaned }
            }
            return "Hue Bridge"
        }()
        let resolvedBridgeID: String = {
            if case .bonjour(let txt) = result.metadata, let raw = txt["bridgeid"] {
                let upper = raw.uppercased()
                if HueColorMath.validBridgeID(upper) { return upper }
            }
            return ""
        }()

        let conn = NWConnection(to: result.endpoint, using: .tcp)
        let resolvedFlag = AtomicFlag()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if resolvedFlag.setOnce(),
                   case .hostPort(host: let host, port: _) = conn.currentPath?.remoteEndpoint,
                   let ip = Self.extractIPv4(from: host),
                   HueColorMath.validBridgeIP(ip) {
                    let cand = BridgeCandidate(ip: ip, bridgeID: resolvedBridgeID, name: resolvedName)
                    let updated = collector.add(cand)
                    Task { @MainActor [weak self] in
                        guard let self = self, self.discovering, self.discoveryGeneration == discoveryGen else { return }
                        self.candidates = updated
                        self.emit()
                    }
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: networkQueue)
        networkQueue.asyncAfter(deadline: .now() + 2.5) {
            if resolvedFlag.setOnce() {
                conn.cancel()
            }
        }
    }

    private nonisolated static func extractIPv4(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr):
            let bytes = Array(addr.rawValue)
            guard bytes.count == 4 else { return nil }
            return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
        case .ipv6(let addr):
            let bytes = Array(addr.rawValue)
            guard bytes.count == 16,
                  bytes[0..<10].allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        default:
            return nil
        }
    }

    private func finishDiscovery(collector: DiscoveryCollector, discoveryGen: Int) {
        guard discoveryGeneration == discoveryGen else { return }
        discoveryGeneration += 1
        browser?.cancel()
        browser = nil
        discoverTask?.cancel()
        discoverTask = nil
        let found = collector.snapshot()
        if !found.isEmpty {
            candidates = found
        }
        discovering = false
        emit()
    }

    // MARK: - Pairing

    public func pair(ip rawIP: String) {
        let ip = cleanedIP(rawIP)
        guard HueColorMath.validBridgeIP(ip) else {
            setError(code: "errEnterIp", text: "Enter the bridge's local IPv4 address")
            emit()
            return
        }

        pairTask?.cancel()
        sseTask?.cancel()
        refreshLoopTask?.cancel()

        pairGeneration += 1
        connGeneration += 1
        let gen = pairGeneration

        pairIP = ip
        pairRemaining = 35
        phase = "pairing"
        clearError()
        emit()

        pairTask = Task { [weak self] in
            await self?.runPairLoop(ip: ip, generation: gen)
        }
    }

    public func cancelPair() {
        pairGeneration += 1
        pairTask?.cancel()
        pairTask = nil
        pairIP = ""
        pairRemaining = 0
        clearError()
        phase = credentials != nil ? "connecting" : "unpaired"
        emit()
        if credentials != nil {
            startConnectedLoops()
        }
    }

    public func unpair() {
        pairGeneration += 1
        connGeneration += 1
        pairTask?.cancel()
        pairTask = nil
        sseTask?.cancel()
        sseTask = nil
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        teardownPinnedSessions()

        credentials = nil
        rooms = []
        lightCount = 0
        onCount = 0
        bridgeHomeGroupedLight = ""
        schedules = []
        entertainmentAreas = []
        entertainmentServiceByLight = [:]
        pairIP = ""
        pairRemaining = 0
        phase = "unpaired"
        clearError()

        do {
            try keychain.delete()
        } catch {
            setError(code: "errInternal", text: "Something went wrong (\(error.localizedDescription))", args: [error.localizedDescription])
        }
        emit()
        discover()
    }

    private func runPairLoop(ip: String, generation: Int) async {
        let deadline = Date().addingTimeInterval(35.0)
        var lastAttempt = Date.distantPast

        while !Task.isCancelled && pairGeneration == generation {
            let remaining = Int(ceil(deadline.timeIntervalSinceNow))
            if remaining <= 0 {
                pairIP = ""
                pairRemaining = 0
                phase = credentials != nil ? "connecting" : "unpaired"
                setError(code: "errNoPress", text: "No button press seen. Press the round button on the bridge, then try again.")
                emit()
                return
            }
            pairRemaining = remaining
            emit()

            if Date().timeIntervalSince(lastAttempt) >= 2.0 {
                lastAttempt = Date()
                let done = await attemptPairOnce(ip: ip, generation: generation)
                if done { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Returns `true` when pairing ended (succeeded or terminal error).
    private func attemptPairOnce(ip: String, generation: Int) async -> Bool {
        // 1) GET /api/0/config capturing leaf cert fingerprint & CN
        let configResult = await Self.probeConfig(ip: ip)
        guard pairGeneration == generation, !Task.isCancelled else { return true }

        let bridgeID: String
        let bridgeName: String
        let bridgeModel: String
        let peerFingerprint: String

        switch configResult {
        case .success(let info):
            guard HueColorMath.validBridgeID(info.bridgeID),
                  info.peerCN.uppercased() == info.bridgeID.uppercased() else {
                pairIP = ""
                pairRemaining = 0
                phase = "unpaired"
                setError(code: "errNotHue", text: "\(ip) does not look like a Hue bridge", args: [ip])
                emit()
                return true
            }
            bridgeID = info.bridgeID.uppercased()
            bridgeName = info.name
            bridgeModel = info.model
            peerFingerprint = info.peerFingerprint
        case .failure(let err):
            setError(code: "errCannotReach", text: "Cannot reach \(ip) (\(err.message))", args: [ip, err.message])
            emit()
            return false
        }

        // 2) POST /api pinned to the exact same certificate seen in step 1
        let hostRaw = ProcessInfo.processInfo.hostName
        let host = HueColorMath.clean(hostRaw, limit: 19)
        let deviceType = "maprisma_hue_mac#" + (host.isEmpty ? "mac" : host)

        let postResult = await Self.requestAppKey(
            ip: ip,
            deviceType: deviceType,
            fingerprint: peerFingerprint,
            bridgeID: bridgeID
        )
        guard pairGeneration == generation, !Task.isCancelled else { return true }

        switch postResult {
        case .success(let outcome):
            switch outcome {
            case .paired(let appKey, let clientKey):
                let creds = BridgeCredentials(
                    ip: ip,
                    bridgeID: bridgeID,
                    fingerprint: peerFingerprint,
                    appKey: appKey,
                    clientKey: clientKey,
                    name: bridgeName,
                    model: bridgeModel
                )
                do {
                    try keychain.save(creds)
                } catch {
                    setError(code: "errInternal", text: "Something went wrong (\(error.localizedDescription))", args: [error.localizedDescription])
                    emit()
                    return true
                }
                credentials = creds
                rebuildPinnedSessions(for: creds)
                connGeneration += 1
                pairIP = ""
                pairRemaining = 0
                phase = "connecting"
                clearError()
                emit()
                startConnectedLoops()
                return true

            case .linkButtonNotPressed:
                clearError()
                emit()
                return false

            case .bridgeError(let detail):
                setError(code: "errPairFailed", text: "Pairing failed: \(detail)", args: [detail])
                emit()
                return false
            }

        case .failure(let err):
            setError(code: "errCannotReach", text: "Cannot reach \(ip) (\(err.message))", args: [ip, err.message])
            emit()
            return false
        }
    }

    // MARK: - Commands

    public func setLight(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        guard HueColorMath.validUUID(id) else { return }
        let body = Self.makeLightBody(on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        guard !body.isEmpty else { return }
        let effectiveOn = on ?? (bri != nil || mirek != nil || xy != nil ? true : nil)
        ruleEngine.recordOutgoing(kind: "light", id: id, expectedOn: effectiveOn)
        applyOptimistic(kind: "light", id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        if let on = effectiveOn {
            let actions = ruleEngine.evaluateChange(
                kind: "light", id: id, isOn: on, bri: bri.map(Double.init),
                snapshot: currentSnapshot(), depth: 0, bypassEcho: true
            )
            executeRuleActions(actions)
        }
        emit()
        sendResourcePUT(kind: "light", id: id, body: body)
    }

    public func setGroup(
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        guard HueColorMath.validUUID(id) else { return }
        let body = Self.makeLightBody(on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        guard !body.isEmpty else { return }
        let effectiveOn = on ?? (bri != nil || mirek != nil || xy != nil ? true : nil)
        if let room = rooms.first(where: { $0.groupedLight == id || $0.id == id }) {
            ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: effectiveOn)
            for light in room.lights {
                ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: effectiveOn)
            }
        }
        applyOptimistic(kind: "grouped_light", id: id, on: on, bri: bri, mirek: mirek, xy: xy, effect: effect)
        if let room = rooms.first(where: { $0.groupedLight == id || $0.id == id }),
           let on = effectiveOn {
            let actions = ruleEngine.evaluateChange(
                kind: "room", id: room.id, isOn: on, bri: bri.map(Double.init),
                snapshot: currentSnapshot(), depth: 0, bypassEcho: true
            )
            executeRuleActions(actions)
        }
        emit()
        sendResourcePUT(kind: "grouped_light", id: id, body: body)
    }

    public func recallScene(id: String) {
        guard HueColorMath.validUUID(id) else { return }
        if let room = rooms.first(where: { $0.scenes.contains(where: { $0.id == id }) }) {
            ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: true)
            for light in room.lights {
                ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: true)
            }
        }
        sendResourcePUT(kind: "scene", id: id, body: ["recall": ["action": "active"]])
    }

    public func allOn(excludeRooms: Set<String>) {
        if excludeRooms.isEmpty && HueColorMath.validUUID(bridgeHomeGroupedLight) {
            for room in rooms {
                ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: true)
                for light in room.lights { ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: true) }
            }
            applyAllOptimistic(on: true, excludeRooms: [])
            emit()
            sendResourcePUT(kind: "grouped_light", id: bridgeHomeGroupedLight, body: ["on": ["on": true]])
            return
        }
        var targets: [(String, String)] = []
        for room in rooms {
            if excludeRooms.contains(room.id) || room.kind == "zone" { continue }
            ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: true)
            for light in room.lights { ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: true) }
            if !room.groupedLight.isEmpty && HueColorMath.validUUID(room.groupedLight) {
                targets.append(("grouped_light", room.groupedLight))
            } else {
                for light in room.lights where HueColorMath.validUUID(light.id) {
                    targets.append(("light", light.id))
                }
            }
        }
        guard !targets.isEmpty else { return }
        applyAllOptimistic(on: true, excludeRooms: excludeRooms)
        emit()
        for (kind, id) in targets {
            sendResourcePUT(kind: kind, id: id, body: ["on": ["on": true]])
        }
    }

    public func allOff() {
        if HueColorMath.validUUID(bridgeHomeGroupedLight) {
            for room in rooms {
                ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: false)
                for light in room.lights { ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: false) }
            }
            applyAllOptimistic(on: false, excludeRooms: [])
            emit()
            sendResourcePUT(kind: "grouped_light", id: bridgeHomeGroupedLight, body: ["on": ["on": false]])
            return
        }
        var targets: [(String, String)] = []
        for room in rooms {
            if room.kind == "room" && room.on && HueColorMath.validUUID(room.groupedLight) {
                ruleEngine.recordOutgoing(kind: "room", id: room.id, expectedOn: false)
                for light in room.lights { ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: false) }
                targets.append(("grouped_light", room.groupedLight))
            } else if room.kind == "other" {
                for light in room.lights where light.on && HueColorMath.validUUID(light.id) {
                    ruleEngine.recordOutgoing(kind: "light", id: light.id, expectedOn: false)
                    targets.append(("light", light.id))
                }
            }
        }
        guard !targets.isEmpty else { return }
        applyAllOptimistic(on: false, excludeRooms: [])
        emit()
        for (kind, id) in targets {
            sendResourcePUT(kind: kind, id: id, body: ["on": ["on": false]])
        }
    }

    // MARK: - Schedules (CLIP v2 behavior_instance)

    public func createSchedule(_ draft: HueScheduleDraft) {
        guard let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return }
        let gen = connGeneration
        let body = Self.makeScheduleBody(draft: draft, scriptID: scheduleScriptID)
        Task { [weak self] in
            guard let self = self else { return }
            let result = await Self.performRequest(
                session: session,
                delegate: delegate,
                credentials: creds,
                method: "POST",
                path: "/clip/v2/resource/behavior_instance",
                bodyData: Self.encodeJSON(body)
            )
            await MainActor.run {
                guard self.connGeneration == gen else { return }
                if case .failure(let err) = result {
                    self.setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
                    self.emit()
                } else {
                    self.refresh()
                }
            }
        }
    }

    public func toggleSchedule(id: String, enabled: Bool) {
        guard HueColorMath.validUUID(id),
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return }
        let gen = connGeneration
        if let idx = schedules.firstIndex(where: { $0.id == id }) {
            schedules[idx].enabled = enabled
            emit()
        }
        Task { [weak self] in
            guard let self = self else { return }
            let result = await Self.performRequest(
                session: session,
                delegate: delegate,
                credentials: creds,
                method: "PUT",
                path: "/clip/v2/resource/behavior_instance/\(id)",
                bodyData: Self.encodeJSON(["enabled": enabled])
            )
            await MainActor.run {
                guard self.connGeneration == gen else { return }
                if case .failure(let err) = result {
                    self.setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
                    self.emit()
                } else {
                    self.refresh()
                }
            }
        }
    }

    public func deleteSchedule(id: String) {
        guard HueColorMath.validUUID(id),
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return }
        let gen = connGeneration
        schedules.removeAll { $0.id == id }
        emit()
        Task { [weak self] in
            guard let self = self else { return }
            let result = await Self.performRequest(
                session: session,
                delegate: delegate,
                credentials: creds,
                method: "DELETE",
                path: "/clip/v2/resource/behavior_instance/\(id)",
                bodyData: nil
            )
            await MainActor.run {
                guard self.connGeneration == gen else { return }
                if case .failure(let err) = result {
                    self.setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
                    self.emit()
                } else {
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Rules

    public func setRules(_ rules: [HueRule], paused: Bool) {
        ruleEngine.rules = rules
        ruleEngine.paused = paused
        emit()
    }

    public func triggerDesktopEvent(_ event: String) {
        guard credentials != nil else { return }
        let actions = ruleEngine.evaluateDesktopEvent(event, snapshot: currentSnapshot())
        executeRuleActions(actions)
        if !actions.isEmpty {
            emit()
        }
    }

    public var bridgeID: String {
        credentials?.bridgeID ?? ""
    }

    public var entertainmentCredentials: BridgeCredentials? {
        guard let creds = credentials, !creds.clientKey.isEmpty else { return nil }
        return creds
    }

    // MARK: - Two-Way Spatial & Organization CLIP v2 Mutations

    public func renameLight(id: String, name: String) {
        guard HueColorMath.validUUID(id) else { return }
        let clean = HueColorMath.clean(name, limit: 32)
        guard !clean.isEmpty else { return }

        var matchedDeviceID = ""
        rooms = rooms.map { room in
            var changed = false
            let newLights = room.lights.map { light -> HueLight in
                guard light.id == id else { return light }
                changed = true
                if !light.deviceID.isEmpty { matchedDeviceID = light.deviceID }
                return HueLight(
                    id: light.id, deviceID: light.deviceID, name: clean, on: light.on, bri: light.bri,
                    dimmable: light.dimmable, color: light.color, reachable: light.reachable,
                    supportsColor: light.supportsColor, supportsCT: light.supportsCT,
                    mirek: light.mirek, mirekMin: light.mirekMin, mirekMax: light.mirekMax,
                    effect: light.effect, availableEffects: light.availableEffects
                )
            }
            guard changed else { return room }
            return HueRoom(
                hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                on: room.on, bri: room.bri, onCount: room.onCount, archetype: room.archetype,
                color: room.color, lights: newLights, scenes: room.scenes
            )
        }
        emit()

        let metaBody: [String: Any] = ["metadata": ["name": clean]]
        sendResourcePUT(kind: "light", id: id, body: metaBody)
        if HueColorMath.validUUID(matchedDeviceID) {
            sendResourcePUT(kind: "device", id: matchedDeviceID, body: metaBody)
        }
    }

    @discardableResult
    public func createRoom(kind: String, name: String, archetype: String, deviceIDs: [String]) async -> String? {
        guard (kind == "room" || kind == "zone"),
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return nil }
        let gen = connGeneration
        let cleanName = HueColorMath.clean(name, limit: 32)
        let finalName = cleanName.isEmpty ? (kind == "zone" ? "Zone" : "Room") : cleanName
        let cleanArch = HueColorMath.clean(archetype, limit: 30)
        let finalArch = cleanArch.isEmpty ? "other" : cleanArch
        let children = buildGroupChildren(kind: kind, ids: deviceIDs)
        let body: [String: Any] = [
            "metadata": ["name": finalName, "archetype": finalArch],
            "children": children,
        ]
        let result = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "POST",
            path: "/clip/v2/resource/\(kind)",
            bodyData: Self.encodeJSON(body)
        )
        guard connGeneration == gen else { return nil }
        switch result {
        case .success(let data):
            let createdID = Self.extractCreatedRID(from: data)
            refresh()
            return createdID
        case .failure(let err):
            setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
            emit()
            return nil
        }
    }

    @discardableResult
    public func updateRoom(
        id: String,
        kind: String,
        name: String?,
        archetype: String?,
        deviceIDs: [String]?
    ) async -> Bool {
        guard HueColorMath.validUUID(id),
              (kind == "room" || kind == "zone"),
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return false }
        let gen = connGeneration

        var body: [String: Any] = [:]
        var metadata: [String: Any] = [:]
        if let name = name {
            let clean = HueColorMath.clean(name, limit: 32)
            if !clean.isEmpty { metadata["name"] = clean }
        }
        if let archetype = archetype {
            let cleanArch = HueColorMath.clean(archetype, limit: 30)
            if !cleanArch.isEmpty { metadata["archetype"] = cleanArch }
        }
        if !metadata.isEmpty {
            body["metadata"] = metadata
        }
        if let deviceIDs = deviceIDs {
            body["children"] = buildGroupChildren(kind: kind, ids: deviceIDs)
        }
        guard !body.isEmpty else { return true }

        // Optimistic metadata update
        if !metadata.isEmpty {
            let nextName = metadata["name"] as? String
            let nextArch = metadata["archetype"] as? String
            rooms = rooms.map { room in
                guard room.hueID == id else { return room }
                return HueRoom(
                    hueID: room.hueID, kind: room.kind,
                    name: nextName ?? room.name,
                    groupedLight: room.groupedLight,
                    on: room.on, bri: room.bri, onCount: room.onCount,
                    archetype: nextArch ?? room.archetype,
                    color: room.color, lights: room.lights, scenes: room.scenes
                )
            }
            emit()
        }

        let result = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "PUT",
            path: "/clip/v2/resource/\(kind)/\(id)",
            bodyData: Self.encodeJSON(body)
        )
        guard connGeneration == gen else { return false }
        switch result {
        case .success:
            refresh()
            return true
        case .failure(let err):
            setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
            emit()
            return false
        }
    }

    @discardableResult
    public func deleteRoom(id: String, kind: String) async -> Bool {
        guard HueColorMath.validUUID(id),
              (kind == "room" || kind == "zone"),
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return false }
        let gen = connGeneration
        let result = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "DELETE",
            path: "/clip/v2/resource/\(kind)/\(id)",
            bodyData: nil
        )
        guard connGeneration == gen else { return false }
        switch result {
        case .success:
            rooms.removeAll { $0.hueID == id }
            emit()
            refresh()
            return true
        case .failure(let err):
            setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
            emit()
            return false
        }
    }

    @discardableResult
    public func createSceneFromRoom(roomID: String, name: String) async -> String? {
        guard HueColorMath.validUUID(roomID),
              let room = rooms.first(where: { $0.hueID == roomID }),
              !room.lights.isEmpty,
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return nil }
        let gen = connGeneration
        let cleanName = HueColorMath.clean(name, limit: 32)
        let finalName = cleanName.isEmpty ? "Scene" : cleanName

        var actions: [[String: Any]] = []
        for light in room.lights where HueColorMath.validUUID(light.id) {
            var act: [String: Any] = ["on": ["on": light.on]]
            if light.on {
                if light.dimmable {
                    act["dimming"] = ["brightness": HueColorMath.clamp(light.bri, 1.0, 100.0)]
                }
                if light.supportsColor, let xy = HueColorMath.hexToXY(light.color) {
                    act["color"] = ["xy": ["x": xy.x, "y": xy.y]]
                } else if light.supportsCT, let m = light.mirek {
                    act["color_temperature"] = ["mirek": HueColorMath.clamp(m, light.mirekMin, light.mirekMax)]
                }
            }
            actions.append([
                "target": ["rid": light.id, "rtype": "light"],
                "action": act,
            ])
        }
        guard !actions.isEmpty else { return nil }

        let groupType = room.kind == "zone" ? "zone" : "room"
        let body: [String: Any] = [
            "metadata": ["name": finalName],
            "group": ["rid": roomID, "rtype": groupType],
            "actions": actions,
        ]
        let result = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "POST",
            path: "/clip/v2/resource/scene",
            bodyData: Self.encodeJSON(body)
        )
        guard connGeneration == gen else { return nil }
        switch result {
        case .success(let data):
            let createdID = Self.extractCreatedRID(from: data)
            refresh()
            return createdID
        case .failure(let err):
            setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
            emit()
            return nil
        }
    }

    @discardableResult
    public func updateEntertainmentLocations(
        areaID: String,
        positions: [String: (Double, Double, Double)]
    ) async -> Bool {
        guard HueColorMath.validUUID(areaID),
              !positions.isEmpty,
              let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return false }
        let gen = connGeneration

        // Map incoming light IDs to entertainment service IDs when known
        var byServiceID: [String: (Double, Double, Double)] = [:]
        for (key, pos) in positions {
            let clamped = (
                HueColorMath.clamp(pos.0.isFinite ? pos.0 : 0.0, -1.0, 1.0),
                HueColorMath.clamp(pos.1.isFinite ? pos.1 : 0.5, 0.0, 1.0),
                HueColorMath.clamp(pos.2.isFinite ? pos.2 : 0.0, -1.0, 1.0)
            )
            let svcID = entertainmentServiceByLight[key] ?? key
            if HueColorMath.validUUID(svcID) {
                byServiceID[svcID] = clamped
            }
            if HueColorMath.validUUID(key) {
                byServiceID[key] = clamped
            }
        }
        guard !byServiceID.isEmpty else { return false }

        // Fetch existing entertainment_configuration so we preserve every service_location entry
        let getRes = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "GET",
            path: "/clip/v2/resource/entertainment_configuration/\(areaID)",
            bodyData: nil
        )
        guard connGeneration == gen else { return false }
        guard case .success(let data) = getRes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]],
              let areaDict = entries.first,
              let locations = areaDict["locations"] as? [String: Any],
              let existing = locations["service_locations"] as? [[String: Any]],
              !existing.isEmpty else {
            return false
        }

        var updatedLocations: [[String: Any]] = []
        var anyUpdated = false
        for loc in existing {
            guard let svc = loc["service"] as? [String: Any],
                  let rid = svc["rid"] as? String,
                  let rtype = svc["rtype"] as? String else { continue }
            if let pos = byServiceID[rid] {
                anyUpdated = true
                updatedLocations.append([
                    "service": ["rid": rid, "rtype": rtype],
                    "positions": [["x": pos.0, "y": pos.1, "z": pos.2]],
                ])
            } else if let prevPositions = loc["positions"] as? [[String: Any]], !prevPositions.isEmpty {
                updatedLocations.append([
                    "service": ["rid": rid, "rtype": rtype],
                    "positions": prevPositions,
                ])
            }
        }
        guard anyUpdated, !updatedLocations.isEmpty else { return false }

        let putBody: [String: Any] = [
            "locations": ["service_locations": updatedLocations],
        ]
        let putRes = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "PUT",
            path: "/clip/v2/resource/entertainment_configuration/\(areaID)",
            bodyData: Self.encodeJSON(putBody)
        )
        guard connGeneration == gen else { return false }
        if case .success = putRes {
            refresh()
            return true
        }
        return false
    }

    private func buildGroupChildren(kind: String, ids: [String]) -> [[String: Any]] {
        let knownLightIDs = Set(rooms.flatMap(\.lights).map(\.id))
        var seen = Set<String>()
        var children: [[String: Any]] = []
        for rawID in ids where HueColorMath.validUUID(rawID) && seen.insert(rawID).inserted {
            let rtype: String
            if kind == "zone" && knownLightIDs.contains(rawID) {
                rtype = "light"
            } else {
                rtype = "device"
            }
            children.append(["rid": rawID, "rtype": rtype])
        }
        return children
    }

    private nonisolated static func extractCreatedRID(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let rid = first["rid"] as? String,
              HueColorMath.validUUID(rid) else { return nil }
        return rid
    }

    public func setEntertainmentActive(areaID: String, active: Bool) async -> Bool {
        guard HueColorMath.validUUID(areaID),
              let creds = credentials,
              let session = pinnedSession,
              let delegate = pinnedDelegate else { return false }
        let result = await Self.performRequest(
            session: session,
            delegate: delegate,
            credentials: creds,
            method: "PUT",
            path: "/clip/v2/resource/entertainment_configuration/\(areaID)",
            bodyData: Self.encodeJSON(["action": active ? "active" : "inactive"])
        )
        if case .success = result { return true }
        return false
    }

    private func executeRuleActions(_ actions: [RuleAction]) {
        for action in actions {
            if let sceneID = action.sceneID, !sceneID.isEmpty, HueColorMath.validUUID(sceneID) {
                sendResourcePUT(kind: "scene", id: sceneID, body: ["recall": ["action": "active"]])
            } else if action.kind == "room" {
                if let room = rooms.first(where: { $0.id == action.id || $0.groupedLight == action.id }) {
                    let body = Self.makeLightBody(on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                    if !room.groupedLight.isEmpty {
                        applyOptimistic(kind: "grouped_light", id: room.groupedLight, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                        sendResourcePUT(kind: "grouped_light", id: room.groupedLight, body: body)
                    } else {
                        for light in room.lights {
                            applyOptimistic(kind: "light", id: light.id, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                            sendResourcePUT(kind: "light", id: light.id, body: body)
                        }
                    }
                }
            } else if action.kind == "light", HueColorMath.validUUID(action.id) {
                let body = Self.makeLightBody(on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                applyOptimistic(kind: "light", id: action.id, on: action.on, bri: action.bri, mirek: nil, xy: nil, effect: nil)
                sendResourcePUT(kind: "light", id: action.id, body: body)
            }
        }
    }

    // MARK: - Connected Loops (Refresh + SSE Eventstream)

    private func startConnectedLoops() {
        sseTask?.cancel()
        refreshLoopTask?.cancel()
        guard let creds = credentials else { return }
        let gen = connGeneration

        refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.performRefresh(credentials: creds, generation: gen)
                let delaySec: UInt64 = self.panelOpen ? 30 : 120
                try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            }
        }

        sseTask = Task { [weak self] in
            await self?.runSSELoop(credentials: creds, generation: gen)
        }
    }

    private func performRefresh(credentials creds: BridgeCredentials, generation: Int) async {
        guard let session = pinnedSession, let delegate = pinnedDelegate else { return }
        let result = await Self.fetchModel(session: session, delegate: delegate, credentials: creds)
        guard connGeneration == generation, !Task.isCancelled else { return }

        switch result {
        case .success(let model):
            rooms = model.rooms
            lightCount = model.lightCount
            onCount = model.onCount
            bridgeHomeGroupedLight = model.bridgeHomeGroupedLight
            scheduleScriptID = model.scheduleScriptID
            schedules = model.schedules
            entertainmentAreas = model.entertainmentAreas
            entertainmentServiceByLight = model.entertainmentServiceByLight
            phase = "ok"
            clearError()
            emit()
        case .failure(let err):
            phase = "error"
            switch err {
            case .pinMismatch:
                setError(code: "errCert", text: "The bridge certificate changed. Unpair and pair again if you replaced the bridge.")
            case .unauthorized:
                setError(code: "errRejected", text: "The bridge no longer accepts this app. Unpair and pair again.")
            case .badReply:
                setError(code: "errReply", text: "The bridge sent a reply this app does not understand.")
            case .network(let msg):
                setError(code: "errUnreachable", text: "Bridge not reachable (\(msg))", args: [msg])
            }
            emit()
        }
    }

    private func runSSELoop(credentials creds: BridgeCredentials, generation: Int) async {
        var backoffSeconds: Double = 2.0
        while !Task.isCancelled && connGeneration == generation {
            guard let session = sseSession,
                  let url = URL(string: "https://\(creds.ip)/eventstream/clip/v2") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue(creds.appKey, forHTTPHeaderField: "hue-application-key")

            do {
                let (bytes, response) = try await session.bytes(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    backoffSeconds = 2.0
                    var parser = SSEParser()
                    var chunk = Data()
                    chunk.reserveCapacity(1024)
                    for try await byte in bytes {
                        if Task.isCancelled || connGeneration != generation { break }
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4096 {
                            let updates = parser.feed(chunk)
                            chunk.removeAll(keepingCapacity: true)
                            if !updates.isEmpty {
                                applySSEUpdates(updates)
                            }
                        }
                    }
                }
            } catch {
                // Stream ended or failed; reconnect after backoff.
            }

            guard !Task.isCancelled && connGeneration == generation else { return }
            let waitNs = UInt64(backoffSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: waitNs)
            backoffSeconds = min(30.0, backoffSeconds * 2.0)
            if !Task.isCancelled && connGeneration == generation {
                await performRefresh(credentials: creds, generation: generation)
            }
        }
    }

    private func applySSEUpdates(_ updates: [HueSSEUpdate]) {
        var needsFullRefresh = false
        var ruleActions: [RuleAction] = []

        for update in updates {
            switch update.resourceType {
            case "light":
                if update.eventType == "add" || update.eventType == "delete" {
                    needsFullRefresh = true
                    continue
                }
                applyLightDelta(update)
                if let isOn = update.on {
                    let actions = ruleEngine.evaluateChange(
                        kind: "light",
                        id: update.resourceID,
                        isOn: isOn,
                        bri: update.brightness,
                        snapshot: currentSnapshot()
                    )
                    ruleActions.append(contentsOf: actions)
                }

            case "grouped_light":
                if update.eventType == "add" || update.eventType == "delete" {
                    needsFullRefresh = true
                    continue
                }
                applyGroupDelta(update)
                if let isOn = update.on,
                   let room = rooms.first(where: { $0.groupedLight == update.resourceID }) {
                    let actions = ruleEngine.evaluateChange(
                        kind: "room",
                        id: room.id,
                        isOn: isOn,
                        bri: update.brightness,
                        snapshot: currentSnapshot()
                    )
                    ruleActions.append(contentsOf: actions)
                }

            case "scene":
                if let active = update.sceneActive {
                    applySceneDelta(id: update.resourceID, active: active)
                }

            case "behavior_instance", "room", "zone":
                needsFullRefresh = true

            default:
                break
            }
        }

        if !ruleActions.isEmpty {
            executeRuleActions(ruleActions)
        }
        emit()
        if needsFullRefresh {
            refresh()
        }
    }

    private func applyLightDelta(_ update: HueSSEUpdate) {
        var updatedRooms: [HueRoom] = []
        updatedRooms.reserveCapacity(rooms.count)
        for room in rooms {
            var changed = false
            let newLights = room.lights.map { light -> HueLight in
                guard light.id == update.resourceID else { return light }
                changed = true
                return HueLight(
                    id: light.id,
                    deviceID: light.deviceID,
                    name: update.name ?? light.name,
                    on: update.on ?? light.on,
                    bri: update.brightness.map { ($0 * 10.0).rounded() / 10.0 } ?? light.bri,
                    dimmable: light.dimmable,
                    color: update.colorHex ?? light.color,
                    reachable: light.reachable,
                    supportsColor: light.supportsColor,
                    supportsCT: light.supportsCT,
                    mirek: update.mirek ?? light.mirek,
                    mirekMin: light.mirekMin,
                    mirekMax: light.mirekMax,
                    effect: update.effect ?? light.effect,
                    availableEffects: light.availableEffects
                )
            }
            if changed {
                let onMembers = newLights.filter(\.on)
                let bri = onMembers.isEmpty ? room.bri
                    : ((onMembers.map(\.bri).reduce(0.0, +) / Double(onMembers.count)) * 10.0).rounded() / 10.0
                updatedRooms.append(HueRoom(
                    hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                    on: !onMembers.isEmpty, bri: bri, onCount: onMembers.count, archetype: room.archetype,
                    color: HueColorMath.blendColors(onMembers.map(\.color)), lights: newLights, scenes: room.scenes
                ))
            } else {
                updatedRooms.append(room)
            }
        }
        rooms = updatedRooms
        recomputeCounts()
    }

    private func applyGroupDelta(_ update: HueSSEUpdate) {
        rooms = rooms.map { room in
            guard room.groupedLight == update.resourceID else { return room }
            let newLights = room.lights.map { light -> HueLight in
                HueLight(
                    id: light.id, deviceID: light.deviceID, name: light.name,
                    on: update.on ?? light.on,
                    bri: update.brightness.map { ($0 * 10.0).rounded() / 10.0 } ?? light.bri,
                    dimmable: light.dimmable, color: light.color, reachable: light.reachable,
                    supportsColor: light.supportsColor, supportsCT: light.supportsCT,
                    mirek: light.mirek, mirekMin: light.mirekMin, mirekMax: light.mirekMax,
                    effect: light.effect, availableEffects: light.availableEffects
                )
            }
            let onMembers = newLights.filter(\.on)
            return HueRoom(
                hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                on: update.on ?? !onMembers.isEmpty,
                bri: update.brightness.map { ($0 * 10.0).rounded() / 10.0 } ?? room.bri,
                onCount: onMembers.count, archetype: room.archetype,
                color: HueColorMath.blendColors(onMembers.map(\.color)), lights: newLights, scenes: room.scenes
            )
        }
        recomputeCounts()
    }

    private func applySceneDelta(id: String, active: Bool) {
        rooms = rooms.map { room in
            guard room.scenes.contains(where: { $0.id == id }) else { return room }
            let newScenes = room.scenes.map { scene -> HueScene in
                if scene.id == id {
                    return HueScene(id: scene.id, name: scene.name, active: active)
                }
                return active ? HueScene(id: scene.id, name: scene.name, active: false) : scene
            }
            return HueRoom(
                hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                on: room.on, bri: room.bri, onCount: room.onCount, archetype: room.archetype,
                color: room.color, lights: room.lights, scenes: newScenes
            )
        }
    }

    // MARK: - Optimistic Updates & PUT Sending

    private func sendResourcePUT(kind: String, id: String, body: [String: Any]) {
        guard let creds = credentials, let session = pinnedSession, let delegate = pinnedDelegate else { return }
        let gen = connGeneration
        let key = "\(kind):\(id)"
        let data = Self.encodeJSON(body)
        pendingCommandTasks[key]?.cancel()
        pendingCommandTasks[key] = Task { [weak self] in
            guard let self = self else { return }
            let result = await Self.performRequest(
                session: session,
                delegate: delegate,
                credentials: creds,
                method: "PUT",
                path: "/clip/v2/resource/\(kind)/\(id)",
                bodyData: data
            )
            await MainActor.run {
                guard self.connGeneration == gen else { return }
                if case .failure(let err) = result {
                    self.setError(code: "errCommand", text: "Command failed (\(err.message))", args: [err.message])
                    self.emit()
                }
            }
        }
    }

    private func applyOptimistic(
        kind: String,
        id: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) {
        let newColor: String?
        if let m = mirek {
            newColor = HueColorMath.mirekToHex(m)
        } else if let xy = xy {
            newColor = HueColorMath.xyToHex(x: xy.0, y: xy.1)
        } else {
            newColor = nil
        }

        rooms = rooms.map { room in
            let matchesGroup = (kind == "grouped_light" && room.groupedLight == id)
            let newLights = room.lights.map { light -> HueLight in
                guard matchesGroup || (kind == "light" && light.id == id) else { return light }
                let nextOn = on ?? (bri != nil || mirek != nil || xy != nil || (effect != nil && effect != "no_effect") ? true : light.on)
                let nextBri = bri.map { Double(HueColorMath.clamp($0, 1, 100)) } ?? light.bri
                return HueLight(
                    id: light.id, deviceID: light.deviceID, name: light.name, on: nextOn, bri: nextBri, dimmable: light.dimmable,
                    color: newColor ?? light.color, reachable: light.reachable,
                    supportsColor: light.supportsColor, supportsCT: light.supportsCT,
                    mirek: mirek ?? light.mirek, mirekMin: light.mirekMin, mirekMax: light.mirekMax,
                    effect: effect ?? light.effect, availableEffects: light.availableEffects
                )
            }
            let onMembers = newLights.filter(\.on)
            let nextBri: Double
            if matchesGroup, let b = bri {
                nextBri = Double(HueColorMath.clamp(b, 1, 100))
            } else if !onMembers.isEmpty {
                nextBri = ((onMembers.map(\.bri).reduce(0.0, +) / Double(onMembers.count)) * 10.0).rounded() / 10.0
            } else {
                nextBri = room.bri
            }
            return HueRoom(
                hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                on: matchesGroup ? (on ?? !onMembers.isEmpty) : !onMembers.isEmpty,
                bri: nextBri, onCount: onMembers.count, archetype: room.archetype,
                color: HueColorMath.blendColors(onMembers.map(\.color)),
                lights: newLights, scenes: room.scenes
            )
        }
        recomputeCounts()
    }

    private func applyAllOptimistic(on: Bool, excludeRooms: Set<String>) {
        rooms = rooms.map { room in
            if on && excludeRooms.contains(room.id) { return room }
            let newLights = room.lights.map { light -> HueLight in
                HueLight(
                    id: light.id, deviceID: light.deviceID, name: light.name, on: on, bri: light.bri, dimmable: light.dimmable,
                    color: light.color, reachable: light.reachable, supportsColor: light.supportsColor,
                    supportsCT: light.supportsCT, mirek: light.mirek, mirekMin: light.mirekMin,
                    mirekMax: light.mirekMax, effect: light.effect, availableEffects: light.availableEffects
                )
            }
            let onMembers = newLights.filter(\.on)
            return HueRoom(
                hueID: room.hueID, kind: room.kind, name: room.name, groupedLight: room.groupedLight,
                on: !onMembers.isEmpty, bri: room.bri, onCount: onMembers.count, archetype: room.archetype,
                color: HueColorMath.blendColors(onMembers.map(\.color)), lights: newLights, scenes: room.scenes
            )
        }
        recomputeCounts()
    }

    private func recomputeCounts() {
        var seen = Set<String>()
        var total = 0
        var lit = 0
        for room in rooms where room.kind != "zone" {
            for light in room.lights where seen.insert(light.id).inserted {
                total += 1
                if light.on { lit += 1 }
            }
        }
        if total == 0 {
            for room in rooms {
                for light in room.lights where seen.insert(light.id).inserted {
                    total += 1
                    if light.on { lit += 1 }
                }
            }
        }
        lightCount = total
        onCount = lit
    }

    // MARK: - Sessions & Snapshot

    private func rebuildPinnedSessions(for creds: BridgeCredentials) {
        teardownPinnedSessions()
        let delegate = HuePinnedSessionDelegate(mode: .pinned(fingerprint: creds.fingerprint, bridgeID: creds.bridgeID))
        pinnedDelegate = delegate

        let restConfig = URLSessionConfiguration.ephemeral
        restConfig.timeoutIntervalForRequest = 6.0
        restConfig.timeoutIntervalForResource = 10.0
        restConfig.waitsForConnectivity = false
        pinnedSession = URLSession(configuration: restConfig, delegate: delegate, delegateQueue: nil)

        let sseConfig = URLSessionConfiguration.ephemeral
        sseConfig.timeoutIntervalForRequest = 60 * 60 * 24
        sseConfig.timeoutIntervalForResource = 60 * 60 * 24
        sseConfig.waitsForConnectivity = false
        sseSession = URLSession(configuration: sseConfig, delegate: delegate, delegateQueue: nil)
    }

    private func teardownPinnedSessions() {
        pinnedSession?.invalidateAndCancel()
        pinnedSession = nil
        sseSession?.invalidateAndCancel()
        sseSession = nil
        pinnedDelegate = nil
    }

    private func setError(code: String, text: String, args: [String] = []) {
        errorCode = code
        errorText = text
        errorArgs = args
    }

    private func clearError() {
        errorCode = ""
        errorText = ""
        errorArgs = []
    }

    private func currentSnapshot() -> HueSnapshot {
        let info = credentials.map { BridgeInfo(ip: $0.ip, name: $0.name, model: $0.model) }
        return HueSnapshot(
            phase: phase,
            error: errorText,
            errorCode: errorText.isEmpty ? "" : errorCode,
            errorArgs: errorText.isEmpty ? [] : errorArgs,
            bridge: info,
            rooms: rooms,
            lightCount: lightCount,
            onCount: onCount,
            candidates: candidates,
            discovering: discovering,
            pairIP: pairIP,
            pairRemaining: pairRemaining,
            bridgeHomeGroupedLight: bridgeHomeGroupedLight,
            schedules: schedules,
            rules: ruleEngine.rules,
            rulesPaused: ruleEngine.paused,
            ruleLog: ruleEngine.log,
            entertainmentAreas: entertainmentAreas,
            isDemo: false
        )
    }

    private func emit() {
        onSnapshot?(currentSnapshot())
    }

    // MARK: - Static CLIP v2 Payloads & Nonisolated Networking

    private static func makeLightBody(
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) -> [String: Any] {
        var body: [String: Any] = [:]
        if let on = on {
            body["on"] = ["on": on]
        }
        if let bri = bri {
            body["dimming"] = ["brightness": Double(HueColorMath.clamp(bri, 1, 100))]
            body["on"] = ["on": true]
        }
        if let mirek = mirek {
            body["color_temperature"] = ["mirek": HueColorMath.clamp(mirek, 153, 500)]
            body["on"] = ["on": true]
        }
        if let xy = xy {
            body["color"] = ["xy": ["x": HueColorMath.clamp(xy.0, 0.0, 1.0), "y": HueColorMath.clamp(xy.1, 0.0, 1.0)]]
            body["on"] = ["on": true]
        }
        if let effect = effect, !effect.isEmpty {
            body["effects"] = ["effect": effect]
            if effect != "no_effect" {
                body["on"] = ["on": true]
            }
        }
        return body
    }

    private static func makeScheduleBody(draft: HueScheduleDraft, scriptID: String) -> [String: Any] {
        let timePoint: [String: Any]
        if draft.triggerKind == "sunrise" || draft.triggerKind == "sunset" {
            timePoint = [
                "type": draft.triggerKind,
                "offset": HueColorMath.clamp(draft.offsetMin, -60, 60),
            ]
        } else {
            let parts = draft.time.split(separator: ":")
            let hour = parts.count == 2 ? HueColorMath.clamp(Int(parts[0]) ?? 7, 0, 23) : 7
            let minute = parts.count == 2 ? HueColorMath.clamp(Int(parts[1]) ?? 0, 0, 59) : 0
            timePoint = [
                "type": "time",
                "time": ["hour": hour, "minute": minute],
            ]
        }

        var when: [String: Any] = ["time_point": timePoint]
        if !draft.days.isEmpty {
            when["recurrence_days"] = draft.days
        }

        var config: [String: Any] = [
            "when": when,
            "where": [["group": ["rid": draft.targetID, "rtype": draft.targetKind]]],
        ]
        if draft.action == "scene", HueColorMath.validUUID(draft.sceneID) {
            config["recall"] = ["rid": draft.sceneID, "rtype": "scene"]
            if draft.fadeMin > 0 {
                config["fade_in_duration"] = ["seconds": draft.fadeMin * 60]
            }
        } else if draft.action == "off" {
            config["on"] = ["on": false]
            if draft.fadeMin > 0 {
                config["fade_out_duration"] = ["seconds": draft.fadeMin * 60]
            }
        } else {
            config["on"] = ["on": true]
            if let bri = draft.bri {
                config["dimming"] = ["brightness": Double(HueColorMath.clamp(bri, 1, 100))]
            }
            if draft.fadeMin > 0 {
                config["fade_in_duration"] = ["seconds": draft.fadeMin * 60]
            }
        }

        let name = HueColorMath.clean(draft.name).isEmpty ? "Schedule" : HueColorMath.clean(draft.name)
        return [
            "type": "behavior_instance",
            "script_id": scriptID,
            "enabled": true,
            "metadata": ["name": name],
            "configuration": config,
        ]
    }

    private nonisolated static func encodeJSON(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [])
    }

    private enum NetworkFailure: Error, Sendable {
        case pinMismatch
        case unauthorized
        case badReply
        case network(String)

        var message: String {
            switch self {
            case .pinMismatch: return "bridge certificate changed"
            case .unauthorized: return "unauthorized"
            case .badReply: return "invalid bridge reply"
            case .network(let m): return m
            }
        }
    }

    private struct ProbeResult: Sendable {
        let bridgeID: String
        let name: String
        let model: String
        let peerFingerprint: String
        let peerCN: String
    }

    private enum PairOutcome: Sendable {
        case paired(appKey: String, clientKey: String)
        case linkButtonNotPressed
        case bridgeError(String)
    }

    private nonisolated static func probeConfig(ip: String) async -> Result<ProbeResult, NetworkFailure> {
        guard let url = URL(string: "https://\(ip)/api/0/config") else {
            return .failure(.network("invalid URL"))
        }
        let delegate = HuePinnedSessionDelegate(mode: .capture)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await session.data(for: req)
            guard let peer = delegate.capturedPeer,
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.badReply)
            }
            let bridgeID = (dict["bridgeid"] as? String ?? "").uppercased()
            let name = HueColorMath.clean((dict["name"] as? String) ?? "Hue Bridge")
            let model = HueColorMath.clean((dict["modelid"] as? String) ?? "")
            return .success(ProbeResult(
                bridgeID: bridgeID,
                name: name.isEmpty ? "Hue Bridge" : name,
                model: model,
                peerFingerprint: peer.fingerprint,
                peerCN: peer.commonName
            ))
        } catch {
            return .failure(.network(HueColorMath.clean(error.localizedDescription, limit: 60)))
        }
    }

    private nonisolated static func requestAppKey(
        ip: String,
        deviceType: String,
        fingerprint: String,
        bridgeID: String
    ) async -> Result<PairOutcome, NetworkFailure> {
        guard let url = URL(string: "https://\(ip)/api") else {
            return .failure(.network("invalid URL"))
        }
        let delegate = HuePinnedSessionDelegate(mode: .pinned(fingerprint: fingerprint, bridgeID: bridgeID))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = encodeJSON(["devicetype": deviceType, "generateclientkey": true])

        do {
            let (data, _) = try await session.data(for: req)
            if delegate.didFailPin { return .failure(.pinMismatch) }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let entry = arr.first else {
                return .failure(.badReply)
            }
            if let success = entry["success"] as? [String: Any],
               let key = success["username"] as? String,
               !key.isEmpty, key.count <= 100 {
                let rawClientKey = (success["clientkey"] as? String) ?? ""
                let validClientKey = rawClientKey.count == 32 ? rawClientKey : ""
                return .success(.paired(appKey: key, clientKey: validClientKey))
            }
            if let err = entry["error"] as? [String: Any] {
                if let code = err["type"] as? Int {
                    if code == 101 { return .success(.linkButtonNotPressed) }
                    return .success(.bridgeError("bridge error \(code)"))
                }
            }
            return .success(.bridgeError("bridge error"))
        } catch {
            if delegate.didFailPin { return .failure(.pinMismatch) }
            return .failure(.network(HueColorMath.clean(error.localizedDescription, limit: 60)))
        }
    }

    private nonisolated static func fetchModel(
        session: URLSession,
        delegate: HuePinnedSessionDelegate,
        credentials: BridgeCredentials
    ) async -> Result<HueBuiltModel, NetworkFailure> {
        let result = await performRequest(
            session: session,
            delegate: delegate,
            credentials: credentials,
            method: "GET",
            path: "/clip/v2/resource",
            bodyData: nil
        )
        switch result {
        case .failure(let err):
            return .failure(err)
        case .success(let data):
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resources = root["data"] as? [[String: Any]] else {
                return .failure(.badReply)
            }
            return .success(HueModelBuilder.build(from: resources))
        }
    }

    private nonisolated static func performRequest(
        session: URLSession,
        delegate: HuePinnedSessionDelegate,
        credentials: BridgeCredentials,
        method: String,
        path: String,
        bodyData: Data?
    ) async -> Result<Data, NetworkFailure> {
        guard let url = URL(string: "https://\(credentials.ip)\(path)") else {
            return .failure(.network("invalid URL"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(credentials.appKey, forHTTPHeaderField: "hue-application-key")
        if let bodyData = bodyData {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }
        do {
            let (data, response) = try await session.data(for: req)
            if delegate.didFailPin { return .failure(.pinMismatch) }
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .failure(.unauthorized)
                }
                if http.statusCode >= 400 {
                    return .failure(.network("HTTP \(http.statusCode)"))
                }
            }
            return .success(data)
        } catch {
            if delegate.didFailPin { return .failure(.pinMismatch) }
            return .failure(.network(HueColorMath.clean(error.localizedDescription, limit: 80)))
        }
    }
}

// MARK: - Pinned TLS Session Delegate

final class HuePinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    enum Mode {
        case capture
        case pinned(fingerprint: String, bridgeID: String)
    }

    struct PeerInfo: Sendable {
        let fingerprint: String
        let commonName: String
    }

    private let mode: Mode
    private let lock = NSLock()
    private var _capturedPeer: PeerInfo?
    private var _didFailPin = false

    init(mode: Mode) {
        self.mode = mode
    }

    var capturedPeer: PeerInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _capturedPeer
    }

    var didFailPin: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didFailPin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            markPinFailed()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        var cnRef: CFString?
        let cnStatus = SecCertificateCopyCommonName(leaf, &cnRef)
        let cn = (cnStatus == errSecSuccess ? (cnRef as String?) : nil) ?? ""

        switch mode {
        case .capture:
            lock.lock()
            _capturedPeer = PeerInfo(fingerprint: fp, commonName: cn)
            lock.unlock()
            completionHandler(.useCredential, URLCredential(trust: serverTrust))

        case .pinned(let expectedFP, let expectedBridgeID):
            let fpOK = fp.lowercased() == expectedFP.lowercased()
            let cnOK = expectedBridgeID.isEmpty || cn.uppercased() == expectedBridgeID.uppercased()
            if fpOK && cnOK {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                markPinFailed()
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private func markPinFailed() {
        lock.lock()
        _didFailPin = true
        lock.unlock()
    }
}

// MARK: - Thread-safe Discovery Helpers

private final class DiscoveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var byIP: [String: BridgeCandidate] = [:]

    func add(_ candidate: BridgeCandidate) -> [BridgeCandidate] {
        lock.lock()
        defer { lock.unlock() }
        byIP[candidate.ip] = candidate
        return byIP.values.sorted { $0.ip < $1.ip }
    }

    func snapshot() -> [BridgeCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return byIP.values.sorted { $0.ip < $1.ip }
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}
#endif
