import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Provider Errors

public enum ProviderClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidHost
    case missingToken
    case unsupported
    case networkFailure(String)
    case httpStatus(Int, String)
    case invalidResponse
    case pairingTimedOut
    case certificateMismatch
    case duplicateHost

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "Only local network addresses (LAN IP or .local) are allowed."
        case .missingToken: return "An access token is required for this device."
        case .unsupported: return "Operation is not supported on this platform."
        case .networkFailure(let msg): return msg
        case .httpStatus(let code, let msg): return msg.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(msg)"
        case .invalidResponse: return "Unexpected response from device."
        case .pairingTimedOut: return "Button press timed out. Press the button on the device and try again."
        case .certificateMismatch: return "The device's security certificate changed. If you renewed it, choose Trust new certificate."
        case .duplicateHost: return "A device with this address is already added."
        }
    }
}

// MARK: - Local-Only HTTP & UDP Transport Helpers

/// Validates URL path segments (Nanoleaf token, DIRIGERA device/scene IDs) against path traversal.
func isSafeURLPathSegment(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128, value != ".", value != ".." else { return false }
    return value.utf8.allSatisfy { b in
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x2D || b == 0x5F || b == 0x2E
    }
}

/// Blocks all HTTP redirects and pins self-signed TLS certificates (TOFU SHA-256)
/// ONLY for validated local LAN/loopback hosts.
final class LocalLANTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let allowLoopback: Bool
    let allowSelfSignedLocalTLS: Bool
    let expectedFingerprint: String
    private let lock = NSLock()
    private var _observedFingerprint: String = ""
    private var _certMismatched: Bool = false

    var observedFingerprint: String {
        lock.lock()
        defer { lock.unlock() }
        return _observedFingerprint
    }

    var certMismatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _certMismatched
    }

    init(allowLoopback: Bool, allowSelfSignedLocalTLS: Bool = false, expectedFingerprint: String = "") {
        self.allowLoopback = allowLoopback
        self.allowSelfSignedLocalTLS = allowSelfSignedLocalTLS
        self.expectedFingerprint = ProviderConnection.sanitizeFingerprint(expectedFingerprint)
    }

    /// Block all HTTP redirects so a LAN endpoint cannot bounce requests or Bearer tokens to external hosts.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    #if canImport(Security) && canImport(CryptoKit)
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard allowSelfSignedLocalTLS,
              let trust = challenge.protectionSpace.serverTrust,
              HueColorMath.validLocalHost(challenge.protectionSpace.host, allowLoopback: allowLoopback),
              let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certs.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let fp = digest.map { String(format: "%02x", $0) }.joined()
        if !expectedFingerprint.isEmpty && fp != expectedFingerprint {
            lock.lock()
            _certMismatched = true
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.lock()
        _observedFingerprint = fp
        lock.unlock()
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    #endif
}

enum LocalHTTPTransport {
    static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 5.0,
        allowSelfSignedLocalTLS: Bool = false,
        allowLoopback: Bool = false,
        expectedFingerprint: String = ""
    ) async throws -> (Data, Int, String) {
        guard let host = url.host, HueColorMath.validLocalHost(host, allowLoopback: allowLoopback) else {
            throw ProviderClientError.invalidHost
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers {
            let cleanV = v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            req.setValue(cleanV, forHTTPHeaderField: k)
        }
        if let body = body {
            req.httpBody = body
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2.0
        config.waitsForConnectivity = false

        let isHTTPS = url.scheme?.lowercased() == "https"
        let delegate = LocalLANTrustDelegate(
            allowLoopback: allowLoopback,
            allowSelfSignedLocalTLS: allowSelfSignedLocalTLS && isHTTPS,
            expectedFingerprint: expectedFingerprint
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if delegate.certMismatched {
                throw ProviderClientError.certificateMismatch
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse
        }
        if (300...399).contains(http.statusCode) {
            throw ProviderClientError.httpStatus(http.statusCode, "HTTP redirects are blocked for local devices")
        }
        return (data, http.statusCode, delegate.observedFingerprint)
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum LocalUDPTransport {
    /// Sends a single UDP datagram to a validated private LAN host and optionally awaits one reply.
    /// Uses Apple `Network.NWConnection` on macOS (100% App Sandbox-compliant under `network.client`).
    static func exchange(
        host: String,
        port: Int,
        payload: Data,
        expectReply: Bool = true,
        timeout: TimeInterval = 2.0
    ) async throws -> Data? {
        guard HueColorMath.validLocalHost(host, allowLoopback: false), (1...65535).contains(port) else {
            throw ProviderClientError.invalidHost
        }
        #if canImport(Network)
        return try await withCheckedThrowingContinuation { continuation in
            let nwHost = NWEndpoint.Host(host)
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(throwing: ProviderClientError.invalidHost)
                return
            }
            let conn = NWConnection(host: nwHost, port: nwPort, using: .udp)
            let queue = DispatchQueue(label: "com.maprisma.lights.udp.\(port)")
            let flag = OnceFlag()
            func complete(_ result: Result<Data?, Error>) {
                guard flag.tryClaim() else { return }
                conn.cancel()
                continuation.resume(with: result)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { sendErr in
                        if let sendErr = sendErr {
                            complete(.failure(ProviderClientError.networkFailure(sendErr.localizedDescription)))
                            return
                        }
                        if !expectReply {
                            complete(.success(nil))
                            return
                        }
                        conn.receiveMessage { data, _, _, recvErr in
                            if let data = data, !data.isEmpty {
                                complete(.success(data))
                            } else if let recvErr = recvErr {
                                complete(.failure(ProviderClientError.networkFailure(recvErr.localizedDescription)))
                            } else {
                                complete(.success(nil))
                            }
                        }
                    })
                case .failed(let err):
                    complete(.failure(ProviderClientError.networkFailure(err.localizedDescription)))
                case .cancelled:
                    complete(.success(nil))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                complete(.success(nil))
            }
        }
        #else
        throw ProviderClientError.unsupported
        #endif
    }

    /// Sends a UDP packet to `targetHost:targetPort` while listening for a reply on `replyPort`
    /// (required by Govee LAN, which receives commands on 4003 and sends `devStatus` replies to 4002).
    static func exchangeListeningOn(
        replyPort: Int,
        targetHost: String,
        targetPort: Int,
        payload: Data,
        timeout: TimeInterval = 2.0
    ) async throws -> Data? {
        guard HueColorMath.validLocalHost(targetHost, allowLoopback: false),
              (1...65535).contains(replyPort),
              (1...65535).contains(targetPort) else {
            throw ProviderClientError.invalidHost
        }
        #if canImport(Network)
        return try await withCheckedThrowingContinuation { continuation in
            guard let nwReplyPort = NWEndpoint.Port(rawValue: UInt16(replyPort)),
                  let nwTargetPort = NWEndpoint.Port(rawValue: UInt16(targetPort)) else {
                continuation.resume(throwing: ProviderClientError.invalidHost)
                return
            }
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: params, on: nwReplyPort)
            } catch {
                continuation.resume(throwing: ProviderClientError.networkFailure("Could not bind UDP port \(replyPort): \(error.localizedDescription)"))
                return
            }
            let queue = DispatchQueue(label: "com.maprisma.lights.udp.listen.\(replyPort)")
            let flag = OnceFlag()
            let sender = NWConnection(host: NWEndpoint.Host(targetHost), port: nwTargetPort, using: .udp)
            let expectedIP = HueColorMath.validBridgeIP(targetHost) ? targetHost : nil

            func complete(_ result: Result<Data?, Error>) {
                guard flag.tryClaim() else { return }
                listener.cancel()
                sender.cancel()
                continuation.resume(with: result)
            }

            listener.newConnectionHandler = { incoming in
                incoming.stateUpdateHandler = { st in
                    if case .ready = st {
                        incoming.receiveMessage { data, _, _, _ in
                            if let data = data, !data.isEmpty {
                                if let expected = expectedIP,
                                   case .hostPort(let rHost, _) = incoming.currentPath?.remoteEndpoint,
                                   let ip = Self.extractIPv4String(from: rHost),
                                   ip != expected {
                                    incoming.cancel()
                                    return
                                }
                                incoming.cancel()
                                complete(.success(data))
                            } else {
                                incoming.cancel()
                            }
                        }
                    }
                }
                incoming.start(queue: queue)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sender.stateUpdateHandler = { sState in
                        if case .ready = sState {
                            sender.send(content: payload, completion: .contentProcessed { err in
                                if let err = err {
                                    complete(.failure(ProviderClientError.networkFailure(err.localizedDescription)))
                                }
                            })
                        } else if case .failed(let err) = sState {
                            complete(.failure(ProviderClientError.networkFailure(err.localizedDescription)))
                        }
                    }
                    sender.start(queue: queue)
                case .failed(let err):
                    complete(.failure(ProviderClientError.networkFailure(err.localizedDescription)))
                default:
                    break
                }
            }

            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                complete(.success(nil))
            }
        }
        #else
        throw ProviderClientError.unsupported
        #endif
    }

    #if canImport(Network)
    private static func extractIPv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let addr):
            let b = Array(addr.rawValue)
            guard b.count == 4 else { return nil }
            return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        case .ipv6(let addr):
            let b = Array(addr.rawValue)
            guard b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF else { return nil }
            return "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
        default:
            return nil
        }
    }
    #endif
}

// MARK: - 1. Home Assistant (REST + Area Grouping + Sensors + Scenes)

public enum HomeAssistantParser {
    public static func makeLightID(connectionID: String, entityID: String) -> String {
        "ha:\(connectionID):\(entityID)"
    }

    public static func makeRoomID(connectionID: String, roomSlug: String) -> String {
        "ha:\(connectionID):room:\(roomSlug)"
    }

    public static func makeSceneID(connectionID: String, entityID: String) -> String {
        "ha:\(connectionID):\(entityID)"
    }

    public static func makeSensorID(connectionID: String, entityID: String) -> String {
        "ha:\(connectionID):\(entityID)"
    }

    /// Extracts `(connectionID, entityID)` from `"ha:<connID>:<entityID>"`.
    public static func parseResourceID(_ id: String) -> (connectionID: String, entityID: String)? {
        guard id.hasPrefix("ha:") else { return nil }
        let rest = id.dropFirst(3)
        guard let sep = rest.firstIndex(of: ":") else { return nil }
        let connID = String(rest[..<sep])
        let entityID = String(rest[rest.index(after: sep)...])
        guard !connID.isEmpty, !entityID.isEmpty else { return nil }
        return (connID, entityID)
    }

    /// Parses Home Assistant `/api/states` JSON array into normalized `HueRoom`s, `HueLight`s, `HueScene`s, and `HueSensor`s.
    public static func parseStates(
        connection: ProviderConnection,
        states: [[String: Any]],
        entityAreas: [String: String] = [:]
    ) -> ProviderFetchResult {
        var lightsByRoom: [String: [HueLight]] = [:]
        var scenes: [HueScene] = []
        var sensors: [HueSensor] = []

        let fallbackRoom = connection.roomName.isEmpty ? connection.name : connection.roomName

        for item in states {
            let entityID = JSONValue.string(item, "entity_id")
            guard !entityID.isEmpty else { continue }
            let stateStr = JSONValue.string(item, "state").lowercased()
            let attrs = item["attributes"] as? [String: Any] ?? [:]
            let friendly = HueColorMath.clean(JSONValue.string(attrs, "friendly_name"), limit: 50)
            let displayName = friendly.isEmpty ? entityID : friendly

            if entityID.hasPrefix("light.") {
                let reachable = stateStr != "unavailable" && stateStr != "unknown"
                let isOn = stateStr == "on"
                let rawBri = HueColorMath.finite(attrs["brightness"], low: 0, high: 255)
                let briPct = rawBri.map { (($0 / 255.0) * 100.0).rounded() } ?? (isOn ? 100.0 : 0.0)

                let modes = Set(JSONValue.strings(attrs, "supported_color_modes").map { $0.lowercased() })
                let supportsColor = !modes.intersection(["rgb", "rgbw", "rgbww", "hs", "xy"]).isEmpty
                    || attrs["rgb_color"] != nil || attrs["hs_color"] != nil || attrs["xy_color"] != nil
                let supportsCT = modes.contains("color_temp")
                    || attrs["color_temp_kelvin"] != nil
                    || attrs["color_temp"] != nil
                    || attrs["min_color_temp_kelvin"] != nil
                let dimmable = !modes.isEmpty ? !(modes == ["onoff"]) : true

                let minK = JSONValue.optionalInt(attrs, "min_color_temp_kelvin") ?? 2000
                let maxK = JSONValue.optionalInt(attrs, "max_color_temp_kelvin") ?? 6500
                let mirekMin = HueColorMath.kelvinToMirek(max(minK, maxK))
                let mirekMax = HueColorMath.kelvinToMirek(min(minK, maxK))

                var mirek: Int? = nil
                if let k = JSONValue.optionalInt(attrs, "color_temp_kelvin"), k > 0 {
                    mirek = HueColorMath.kelvinToMirek(k)
                } else if let m = JSONValue.optionalInt(attrs, "color_temp"), m > 0 {
                    mirek = HueColorMath.clamp(m, 153, 500)
                }

                let colorHex: String = {
                    if let rgb = attrs["rgb_color"] as? [Any], rgb.count >= 3,
                       let r = HueColorMath.finite(rgb[0], low: 0, high: 255),
                       let g = HueColorMath.finite(rgb[1], low: 0, high: 255),
                       let b = HueColorMath.finite(rgb[2], low: 0, high: 255) {
                        return HueColorMath.rgbToHex(r: Int(r), g: Int(g), b: Int(b))
                    }
                    if let xy = attrs["xy_color"] as? [Any], xy.count >= 2,
                       let x = HueColorMath.finite(xy[0], low: 0, high: 1),
                       let y = HueColorMath.finite(xy[1], low: 0.0001, high: 1) {
                        return HueColorMath.xyToHex(x: x, y: y)
                    }
                    if let hs = attrs["hs_color"] as? [Any], hs.count >= 2,
                       let h = HueColorMath.finite(hs[0], low: 0, high: 360),
                       let s = HueColorMath.finite(hs[1], low: 0, high: 100) {
                        return HueColorMath.hsbToHex(hue: h, sat: s, bri: 100)
                    }
                    if let m = mirek {
                        return HueColorMath.mirekToHex(m)
                    }
                    return HueColorMath.defaultWarmHex
                }()

                let effectList = JSONValue.strings(attrs, "effect_list").prefix(20).map { HueColorMath.clean($0, limit: 32) }.filter { !$0.isEmpty }
                let activeEffectRaw = HueColorMath.clean(JSONValue.string(attrs, "effect"), limit: 32)
                let activeEffect = activeEffectRaw.isEmpty ? "no_effect" : activeEffectRaw

                let light = HueLight(
                    id: makeLightID(connectionID: connection.id, entityID: entityID),
                    deviceID: entityID,
                    name: displayName,
                    on: isOn,
                    bri: briPct,
                    dimmable: dimmable,
                    color: colorHex,
                    reachable: reachable,
                    supportsColor: supportsColor,
                    supportsCT: supportsCT,
                    mirek: mirek,
                    mirekMin: min(mirekMin, mirekMax),
                    mirekMax: max(mirekMin, mirekMax),
                    effect: activeEffect,
                    availableEffects: effectList,
                    provider: LightProviderKind.homeAssistant.rawValue
                )
                let roomName = HueColorMath.clean(entityAreas[entityID] ?? JSONValue.string(attrs, "area_name"), limit: 40)
                let bucket = roomName.isEmpty ? fallbackRoom : roomName
                lightsByRoom[bucket, default: []].append(light)
            } else if entityID.hasPrefix("scene.") {
                scenes.append(HueScene(
                    id: makeSceneID(connectionID: connection.id, entityID: entityID),
                    name: String(displayName.prefix(30)),
                    active: false,
                    provider: LightProviderKind.homeAssistant.rawValue
                ))
            } else if entityID.hasPrefix("binary_sensor.") {
                let devClass = JSONValue.string(attrs, "device_class").lowercased()
                let isActive = stateStr == "on"
                if devClass == "motion" || devClass == "occupancy" || devClass == "presence" {
                    let area = entityAreas[entityID] ?? fallbackRoom
                    sensors.append(HueSensor(
                        id: makeSensorID(connectionID: connection.id, entityID: entityID),
                        deviceID: entityID,
                        kind: "motion",
                        name: displayName,
                        roomID: makeRoomID(connectionID: connection.id, roomSlug: slug(area)),
                        enabled: stateStr != "unavailable",
                        motion: isActive,
                        provider: LightProviderKind.homeAssistant.rawValue
                    ))
                } else if devClass == "door" || devClass == "window" || devClass == "opening" || devClass == "garage_door" {
                    let area = entityAreas[entityID] ?? fallbackRoom
                    sensors.append(HueSensor(
                        id: makeSensorID(connectionID: connection.id, entityID: entityID),
                        deviceID: entityID,
                        kind: "contact",
                        name: displayName,
                        roomID: makeRoomID(connectionID: connection.id, roomSlug: slug(area)),
                        enabled: stateStr != "unavailable",
                        open: isActive,
                        provider: LightProviderKind.homeAssistant.rawValue
                    ))
                }
            }
        }

        let sortedScenes = scenes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let sortedRoomNames = lightsByRoom.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var rooms: [HueRoom] = []
        var usedRoomIDs = Set<String>()
        for (idx, rName) in sortedRoomNames.enumerated() {
            let members = (lightsByRoom[rName] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !members.isEmpty else { continue }
            let onMembers = members.filter(\.on)
            let avgBri = onMembers.isEmpty ? 0.0 : (onMembers.map(\.bri).reduce(0, +) / Double(onMembers.count)).rounded()
            var candidateID = makeRoomID(connectionID: connection.id, roomSlug: slug(rName))
            var suffix = 2
            while !usedRoomIDs.insert(candidateID).inserted {
                candidateID = makeRoomID(connectionID: connection.id, roomSlug: "\(slug(rName))_\(suffix)")
                suffix += 1
            }
            rooms.append(HueRoom(
                hueID: candidateID,
                kind: "room",
                name: rName,
                groupedLight: "",
                on: !onMembers.isEmpty,
                bri: avgBri,
                onCount: onMembers.count,
                archetype: "home_assistant",
                color: HueColorMath.blendColors(onMembers.map(\.color)),
                lights: members,
                scenes: idx == 0 ? Array(sortedScenes.prefix(24)) : [],
                provider: LightProviderKind.homeAssistant.rawValue
            ))
        }
        return ProviderFetchResult(rooms: rooms, sensors: sensors, deviceLabel: connection.name)
    }

    private static func slug(_ raw: String) -> String {
        let lower = raw.lowercased()
        let chars = lower.unicodeScalars.map { s -> Character in
            let v = s.value
            if (0x30...0x39).contains(v) || (0x61...0x7A).contains(v) { return Character(s) }
            return "_"
        }
        let collapsed = String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? "lights" : String(collapsed.prefix(32))
    }
}

enum HomeAssistantDriver {
    private static let areaTemplate =
        "{%- set ns = namespace(m={}) -%}" +
        "{%- for s in states -%}" +
        "{%- set a = area_name(s.entity_id) -%}" +
        "{%- if a -%}{%- set ns.m = dict(ns.m, **{s.entity_id: a}) -%}{%- endif -%}" +
        "{%- endfor -%}{{ ns.m | tojson }}"

    static func fetchState(connection: ProviderConnection, secret: String?) async throws -> ProviderFetchResult {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard let url = connection.baseURL(path: "/api/states") else {
            throw ProviderClientError.invalidHost
        }
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let (data, status, fp) = try await LocalHTTPTransport.request(
            url: url,
            headers: headers,
            timeout: 6.0,
            allowSelfSignedLocalTLS: true,
            allowLoopback: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(status) else {
            throw ProviderClientError.httpStatus(status, status == 401 ? "Invalid Home Assistant token" : "")
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProviderClientError.invalidResponse
        }

        // Best-effort area lookup via Home Assistant's local template endpoint
        var entityAreas: [String: String] = [:]
        if let tplURL = connection.baseURL(path: "/api/template"),
           let tplBody = try? JSONSerialization.data(withJSONObject: ["template": areaTemplate]),
           let (tData, tStatus, _) = try? await LocalHTTPTransport.request(
               url: tplURL,
               method: "POST",
               headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
               body: tplBody,
               timeout: 3.0,
               allowSelfSignedLocalTLS: true,
               allowLoopback: true,
               expectedFingerprint: fp.isEmpty ? connection.certFingerprint : fp
           ),
           (200...299).contains(tStatus),
           let parsed = try? JSONSerialization.jsonObject(with: tData) as? [String: String] {
            entityAreas = parsed
        }

        var result = HomeAssistantParser.parseStates(connection: connection, states: arr, entityAreas: entityAreas)
        result.certFingerprint = fp.isEmpty ? connection.certFingerprint : fp
        return result
    }

    static func setLight(
        connection: ProviderConnection,
        secret: String?,
        entityID: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) async throws {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        let turnOff = (on == false)
        let service = turnOff ? "turn_off" : "turn_on"
        guard let url = connection.baseURL(path: "/api/services/light/\(service)") else {
            throw ProviderClientError.invalidHost
        }
        var payload: [String: Any] = ["entity_id": entityID]
        if !turnOff {
            if let bri = bri {
                payload["brightness_pct"] = HueColorMath.clamp(bri, 1, 100)
            }
            if let xy = xy {
                let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
                payload["rgb_color"] = [rgb.r, rgb.g, rgb.b]
            } else if let mirek = mirek {
                payload["color_temp_kelvin"] = HueColorMath.mirekToKelvin(mirek)
            }
            if let effect = effect, !effect.isEmpty, effect != "no_effect" {
                payload["effect"] = effect
            }
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, status, _) = try await LocalHTTPTransport.request(
            url: url,
            method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: body,
            timeout: 5.0,
            allowSelfSignedLocalTLS: true,
            allowLoopback: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(status) else {
            throw ProviderClientError.httpStatus(status, "")
        }
    }

    static func recallScene(connection: ProviderConnection, secret: String?, entityID: String) async throws {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard let url = connection.baseURL(path: "/api/services/scene/turn_on") else {
            throw ProviderClientError.invalidHost
        }
        let body = try JSONSerialization.data(withJSONObject: ["entity_id": entityID])
        let (_, status, _) = try await LocalHTTPTransport.request(
            url: url,
            method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: body,
            timeout: 5.0,
            allowSelfSignedLocalTLS: true,
            allowLoopback: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(status) else {
            throw ProviderClientError.httpStatus(status, "")
        }
    }
}

// MARK: - 2. WLED (Direct Local HTTP JSON + Effects + Presets)

public enum WLEDParser {
    public static func makeLightID(connectionID: String, segment: Int = 0) -> String {
        "wled:\(connectionID):\(segment)"
    }

    public static func makeRoomID(connectionID: String) -> String {
        "wled:\(connectionID):room"
    }

    public static func makeSceneID(connectionID: String, presetID: Int) -> String {
        "wled:\(connectionID):ps:\(presetID)"
    }

    public static func parse(
        connection: ProviderConnection,
        json: [String: Any],
        presets: [String: Any] = [:]
    ) -> ProviderFetchResult {
        let state = json["state"] as? [String: Any] ?? [:]
        let info = json["info"] as? [String: Any] ?? [:]
        let effects = JSONValue.strings(json, "effects")
        let deviceName = HueColorMath.clean(JSONValue.string(info, "name"), limit: 40)
        let lightName = deviceName.isEmpty ? connection.name : deviceName
        let roomName = connection.roomName.isEmpty ? lightName : connection.roomName

        let isOn = JSONValue.bool(state, "on")
        let briRaw = HueColorMath.finite(state["bri"], low: 0, high: 255) ?? 128
        let briPct = ((briRaw / 255.0) * 100.0).rounded()
        let activePreset = JSONValue.optionalInt(state, "ps") ?? -1

        var colorHex = HueColorMath.defaultWarmHex
        var activeEffect = "no_effect"
        if let segs = state["seg"] as? [[String: Any]], let seg0 = segs.first {
            if let cols = seg0["col"] as? [[Any]], let primary = cols.first, primary.count >= 3,
               let r = HueColorMath.finite(primary[0], low: 0, high: 255),
               let g = HueColorMath.finite(primary[1], low: 0, high: 255),
               let b = HueColorMath.finite(primary[2], low: 0, high: 255) {
                colorHex = HueColorMath.rgbToHex(r: Int(r), g: Int(g), b: Int(b))
            }
            if let fxIdx = JSONValue.optionalInt(seg0, "fx"), fxIdx > 0, fxIdx < effects.count {
                activeEffect = HueColorMath.clean(effects[fxIdx], limit: 32)
            }
        }

        let curatedEffects = Array(effects.dropFirst().prefix(16).map { HueColorMath.clean($0, limit: 32) }.filter { !$0.isEmpty })

        var scenes: [HueScene] = []
        for (key, value) in presets {
            guard let pid = Int(key), pid > 0, let obj = value as? [String: Any] else { continue }
            let pName = HueColorMath.clean(JSONValue.string(obj, "n"), limit: 30)
            guard !pName.isEmpty else { continue }
            scenes.append(HueScene(
                id: makeSceneID(connectionID: connection.id, presetID: pid),
                name: pName,
                active: pid == activePreset,
                provider: LightProviderKind.wled.rawValue
            ))
        }
        scenes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let light = HueLight(
            id: makeLightID(connectionID: connection.id),
            deviceID: JSONValue.string(info, "mac"),
            name: lightName,
            on: isOn,
            bri: briPct,
            dimmable: true,
            color: colorHex,
            reachable: true,
            supportsColor: true,
            supportsCT: true,
            mirek: nil,
            effect: activeEffect,
            availableEffects: curatedEffects,
            provider: LightProviderKind.wled.rawValue
        )

        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: isOn,
            bri: isOn ? briPct : 0,
            onCount: isOn ? 1 : 0,
            archetype: "wled",
            color: colorHex,
            lights: [light],
            scenes: scenes,
            provider: LightProviderKind.wled.rawValue
        )
        return ProviderFetchResult(rooms: [room], deviceLabel: lightName)
    }

    public static func buildStatePayload(
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?,
        effectsList: [String] = []
    ) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let on = on { payload["on"] = on }
        if let bri = bri {
            let scaled = Int((Double(HueColorMath.clamp(bri, 1, 100)) * 255.0 / 100.0).rounded())
            payload["bri"] = HueColorMath.clamp(scaled, 1, 255)
        }
        var seg0: [String: Any] = [:]
        if let xy = xy {
            let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
            seg0["col"] = [[rgb.r, rgb.g, rgb.b]]
        } else if let mirek = mirek, let rgb = HueColorMath.hexToRGB(HueColorMath.mirekToHex(mirek)) {
            seg0["col"] = [[rgb.r, rgb.g, rgb.b]]
        }
        if let effect = effect {
            if effect == "no_effect" || effect.isEmpty {
                seg0["fx"] = 0
            } else if let idx = effectsList.firstIndex(where: { $0.caseInsensitiveCompare(effect) == .orderedSame }) {
                seg0["fx"] = idx
            }
        }
        if !seg0.isEmpty {
            payload["seg"] = [seg0]
        }
        return payload
    }

    public static func effectIndexMap(from effects: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, raw) in effects.enumerated() {
            let clean = HueColorMath.clean(raw, limit: 32).lowercased()
            if !clean.isEmpty, map[clean] == nil {
                map[clean] = idx
            }
        }
        return map
    }
}

enum WLEDDriver {
    static func fetchState(connection: ProviderConnection) async throws -> (ProviderFetchResult, [String]) {
        guard let url = connection.baseURL(path: "/json") else { throw ProviderClientError.invalidHost }
        let (data, status, _) = try await LocalHTTPTransport.request(url: url, timeout: 4.5)
        guard (200...299).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse
        }
        var presets: [String: Any] = [:]
        if let pURL = connection.baseURL(path: "/presets.json"),
           let (pData, pStatus, _) = try? await LocalHTTPTransport.request(url: pURL, timeout: 2.5),
           (200...299).contains(pStatus),
           let parsed = try? JSONSerialization.jsonObject(with: pData) as? [String: Any] {
            presets = parsed
        }
        // Full 0-indexed WLED effects array (index 0 = "Solid") so fx IDs always match firmware IDs
        let effects = JSONValue.strings(json, "effects").map { HueColorMath.clean($0, limit: 32) }
        return (WLEDParser.parse(connection: connection, json: json, presets: presets), effects)
    }

    static func setLight(
        connection: ProviderConnection,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?,
        effectsList: [String]
    ) async throws {
        guard let url = connection.baseURL(path: "/json/state") else { throw ProviderClientError.invalidHost }
        let payload = WLEDParser.buildStatePayload(on: on, bri: bri, mirek: mirek, xy: xy, effect: effect, effectsList: effectsList)
        guard !payload.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, status, _) = try await LocalHTTPTransport.request(url: url, method: "POST", body: body, timeout: 4.0)
        guard (200...299).contains(status) else { throw ProviderClientError.httpStatus(status, "") }
    }

    static func recallPreset(connection: ProviderConnection, presetID: Int) async throws {
        guard let url = connection.baseURL(path: "/json/state") else { throw ProviderClientError.invalidHost }
        let body = try JSONSerialization.data(withJSONObject: ["on": true, "ps": presetID])
        let (_, status, _) = try await LocalHTTPTransport.request(url: url, method: "POST", body: body, timeout: 4.0)
        guard (200...299).contains(status) else { throw ProviderClientError.httpStatus(status, "") }
    }
}

// MARK: - 3. WiZ (Local UDP Port 38899 JSON)

public enum WiZCodec {
    public static let builtInScenes: [(id: Int, name: String)] = [
        (6, "Cozy"), (11, "Warm White"), (12, "Daylight"), (1, "Ocean"),
        (2, "Romance"), (3, "Sunset"), (4, "Party"), (5, "Fireplace"),
        (7, "Forest"), (14, "Night Light"), (15, "Focus"), (16, "Relax"),
    ]

    public static func makeLightID(connectionID: String) -> String { "wiz:\(connectionID):light" }
    public static func makeRoomID(connectionID: String) -> String { "wiz:\(connectionID):room" }
    public static func makeSceneID(connectionID: String, sceneID: Int) -> String { "wiz:\(connectionID):scene:\(sceneID)" }

    public static func encodeGetPilot() -> Data {
        Data(#"{"method":"getPilot","params":{}}"#.utf8)
    }

    public static func encodeSetPilot(
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        sceneID: Int? = nil
    ) -> Data {
        var params: [String: Any] = [:]
        if let on = on { params["state"] = on }
        if let bri = bri { params["dimming"] = HueColorMath.clamp(bri, 10, 100) }
        if let sceneID = sceneID {
            params["state"] = true
            params["sceneId"] = sceneID
        } else if let xy = xy {
            let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
            params["r"] = rgb.r
            params["g"] = rgb.g
            params["b"] = rgb.b
        } else if let mirek = mirek {
            params["temp"] = HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), 2200, 6500)
        }
        let obj: [String: Any] = ["method": "setPilot", "params": params]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    public static func parsePilot(connection: ProviderConnection, json: [String: Any]) -> ProviderFetchResult {
        let res = json["result"] as? [String: Any] ?? json
        let isOn = JSONValue.bool(res, "state")
        let bri = Double(HueColorMath.clamp(JSONValue.optionalInt(res, "dimming") ?? (isOn ? 100 : 0), 0, 100))
        let tempK = JSONValue.optionalInt(res, "temp")
        let mirek = tempK.map { HueColorMath.kelvinToMirek($0) }
        let activeSceneID = JSONValue.optionalInt(res, "sceneId") ?? 0
        let mac = JSONValue.string(res, "mac")

        let colorHex: String = {
            if let r = JSONValue.optionalInt(res, "r"),
               let g = JSONValue.optionalInt(res, "g"),
               let b = JSONValue.optionalInt(res, "b"),
               (r > 0 || g > 0 || b > 0) {
                return HueColorMath.rgbToHex(r: r, g: g, b: b)
            }
            if let m = mirek { return HueColorMath.mirekToHex(m) }
            return HueColorMath.defaultWarmHex
        }()

        let light = HueLight(
            id: makeLightID(connectionID: connection.id),
            deviceID: mac.isEmpty ? connection.deviceID : mac,
            name: connection.name,
            on: isOn,
            bri: bri,
            dimmable: true,
            color: colorHex,
            reachable: true,
            supportsColor: true,
            supportsCT: true,
            mirek: mirek,
            mirekMin: 154,
            mirekMax: 454,
            provider: LightProviderKind.wiz.rawValue
        )
        let scenes = builtInScenes.map { item in
            HueScene(
                id: makeSceneID(connectionID: connection.id, sceneID: item.id),
                name: item.name,
                active: item.id == activeSceneID,
                provider: LightProviderKind.wiz.rawValue
            )
        }
        let roomName = connection.roomName.isEmpty ? connection.name : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: isOn,
            bri: isOn ? bri : 0,
            onCount: isOn ? 1 : 0,
            archetype: "wiz",
            color: colorHex,
            lights: [light],
            scenes: scenes,
            provider: LightProviderKind.wiz.rawValue
        )
        return ProviderFetchResult(rooms: [room], deviceLabel: connection.name)
    }
}

enum WiZDriver {
    static func fetchState(connection: ProviderConnection) async throws -> ProviderFetchResult {
        guard let reply = try await LocalUDPTransport.exchange(
            host: connection.host,
            port: connection.effectivePort,
            payload: WiZCodec.encodeGetPilot(),
            expectReply: true,
            timeout: 2.0
        ) else {
            throw ProviderClientError.networkFailure("No reply from WiZ device (offline or blocked on LAN)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw ProviderClientError.invalidResponse
        }
        return WiZCodec.parsePilot(connection: connection, json: json)
    }

    static func setLight(
        connection: ProviderConnection,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        sceneID: Int? = nil
    ) async throws {
        let payload = WiZCodec.encodeSetPilot(on: on, bri: bri, mirek: mirek, xy: xy, sceneID: sceneID)
        _ = try await LocalUDPTransport.exchange(
            host: connection.host,
            port: connection.effectivePort,
            payload: payload,
            expectReply: false,
            timeout: 1.5
        )
    }
}

// MARK: - 4. LIFX (Local LAN Binary UDP Protocol Port 56700)

public enum LIFXCodec {
    public static let msgGetColor: UInt16 = 101
    public static let msgSetColor: UInt16 = 102
    public static let msgLightState: UInt16 = 107
    public static let msgSetPower: UInt16 = 117

    public static func makeLightID(connectionID: String) -> String { "lifx:\(connectionID):light" }
    public static func makeRoomID(connectionID: String) -> String { "lifx:\(connectionID):room" }

    /// Builds a 36-byte LIFX LAN v2 header + payload (little-endian).
    public static func encodePacket(type: UInt16, payload: Data = Data(), source: UInt32 = 0x4D415052, resRequired: Bool = true) -> Data {
        let totalSize = UInt16(36 + payload.count)
        var data = Data(capacity: Int(totalSize))
        // Frame (8 bytes): size (2), protocol=1024 | addressable(0x1000) | tagged(0x2000) = 0x3400 (2), source (4)
        appendLE(&data, totalSize)
        appendLE(&data, UInt16(0x3400))
        appendLE(&data, source)
        // Frame Address (16 bytes): target (8 zero = all), reserved (6 zero), flags (1), sequence (1)
        data.append(Data(count: 14))
        data.append(resRequired ? 0x01 : 0x00)
        data.append(0x01)
        // Protocol Header (12 bytes): reserved (8), type (2), reserved (2)
        data.append(Data(count: 8))
        appendLE(&data, type)
        appendLE(&data, UInt16(0))
        data.append(payload)
        return data
    }

    public static func encodeGetColor() -> Data {
        encodePacket(type: msgGetColor, resRequired: true)
    }

    public static func encodeSetPower(on: Bool, durationMs: UInt32 = 250) -> Data {
        var payload = Data(capacity: 6)
        appendLE(&payload, UInt16(on ? 65535 : 0))
        appendLE(&payload, durationMs)
        return encodePacket(type: msgSetPower, payload: payload, resRequired: false)
    }

    public static func encodeSetColor(hue: UInt16, saturation: UInt16, brightness: UInt16, kelvin: UInt16, durationMs: UInt32 = 250) -> Data {
        var payload = Data(capacity: 13)
        payload.append(0x00) // reserved
        appendLE(&payload, hue)
        appendLE(&payload, saturation)
        appendLE(&payload, brightness)
        appendLE(&payload, kelvin)
        appendLE(&payload, durationMs)
        return encodePacket(type: msgSetColor, payload: payload, resRequired: false)
    }

    public struct DecodedState: Equatable, Sendable {
        public let hue: Double        // 0...360
        public let saturation: Double // 0...100
        public let brightness: Double // 0...100
        public let kelvin: Int        // 1500...9000
        public let powerOn: Bool
        public let label: String
    }

    public static func decodeLightState(_ data: Data) -> DecodedState? {
        guard data.count >= 36 + 52 else { return nil }
        let msgType = readLE16(data, at: 32)
        guard msgType == msgLightState else { return nil }
        let base = 36
        let hRaw = readLE16(data, at: base)
        let sRaw = readLE16(data, at: base + 2)
        let bRaw = readLE16(data, at: base + 4)
        let kRaw = readLE16(data, at: base + 6)
        let powerRaw = readLE16(data, at: base + 10)
        let labelBytes = data[(base + 12)..<(base + 44)]
        let trimmedBytes = labelBytes.prefix { $0 != 0 }
        let label = HueColorMath.clean(String(decoding: trimmedBytes, as: UTF8.self), limit: 40)
        return DecodedState(
            hue: (Double(hRaw) / 65535.0) * 360.0,
            saturation: (Double(sRaw) / 65535.0) * 100.0,
            brightness: (Double(bRaw) / 65535.0) * 100.0,
            kelvin: Int(HueColorMath.clamp(Int(kRaw), 1500, 9000)),
            powerOn: powerRaw > 0,
            label: label
        )
    }

    public static func toFetchResult(connection: ProviderConnection, decoded: DecodedState) -> ProviderFetchResult {
        let name = decoded.label.isEmpty ? connection.name : decoded.label
        let mirek = HueColorMath.kelvinToMirek(decoded.kelvin)
        let colorHex = decoded.saturation >= 4.0
            ? HueColorMath.hsbToHex(hue: decoded.hue, sat: decoded.saturation, bri: 100.0)
            : HueColorMath.mirekToHex(mirek)
        let light = HueLight(
            id: makeLightID(connectionID: connection.id),
            deviceID: connection.deviceID,
            name: name,
            on: decoded.powerOn,
            bri: decoded.brightness.rounded(),
            dimmable: true,
            color: colorHex,
            reachable: true,
            supportsColor: true,
            supportsCT: true,
            mirek: mirek,
            mirekMin: 111,
            mirekMax: 666,
            provider: LightProviderKind.lifx.rawValue
        )
        let roomName = connection.roomName.isEmpty ? name : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: decoded.powerOn,
            bri: decoded.powerOn ? decoded.brightness.rounded() : 0,
            onCount: decoded.powerOn ? 1 : 0,
            archetype: "lifx",
            color: colorHex,
            lights: [light],
            scenes: [],
            provider: LightProviderKind.lifx.rawValue
        )
        return ProviderFetchResult(rooms: [room], deviceLabel: name)
    }

    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}

enum LIFXDriver {
    static func fetchState(connection: ProviderConnection) async throws -> (ProviderFetchResult, LIFXCodec.DecodedState) {
        guard let reply = try await LocalUDPTransport.exchange(
            host: connection.host,
            port: connection.effectivePort,
            payload: LIFXCodec.encodeGetColor(),
            expectReply: true,
            timeout: 2.0
        ) else {
            throw ProviderClientError.networkFailure("No reply from LIFX device (offline or blocked on LAN)")
        }
        guard let decoded = LIFXCodec.decodeLightState(reply) else {
            throw ProviderClientError.invalidResponse
        }
        return (LIFXCodec.toFetchResult(connection: connection, decoded: decoded), decoded)
    }

    static func setLight(
        connection: ProviderConnection,
        cachedState: LIFXCodec.DecodedState?,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?
    ) async throws {
        if let on = on {
            _ = try await LocalUDPTransport.exchange(
                host: connection.host,
                port: connection.effectivePort,
                payload: LIFXCodec.encodeSetPower(on: on),
                expectReply: false,
                timeout: 1.5
            )
        }
        if bri != nil || mirek != nil || xy != nil {
            let baseBri = bri.map(Double.init) ?? cachedState?.brightness ?? 80.0
            var hue = cachedState?.hue ?? 0.0
            var sat = cachedState?.saturation ?? 0.0
            var kelvin = cachedState?.kelvin ?? 3200
            if let xy = xy {
                let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
                let hsb = HueColorMath.rgbToHSB(r: rgb.r, g: rgb.g, b: rgb.b)
                hue = hsb.hue
                sat = hsb.sat
            } else if let mirek = mirek {
                sat = 0.0
                kelvin = HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), 1500, 9000)
            }
            let h16 = UInt16(HueColorMath.clamp(Int(((hue / 360.0) * 65535.0).rounded()), 0, 65535))
            let s16 = UInt16(HueColorMath.clamp(Int(((sat / 100.0) * 65535.0).rounded()), 0, 65535))
            let b16 = UInt16(HueColorMath.clamp(Int(((baseBri / 100.0) * 65535.0).rounded()), 1, 65535))
            let k16 = UInt16(HueColorMath.clamp(kelvin, 1500, 9000))
            _ = try await LocalUDPTransport.exchange(
                host: connection.host,
                port: connection.effectivePort,
                payload: LIFXCodec.encodeSetColor(hue: h16, saturation: s16, brightness: b16, kelvin: k16),
                expectReply: false,
                timeout: 1.5
            )
        }
    }
}

// MARK: - 5. Govee LAN (Local UDP Port 4003 JSON)

public enum GoveeCodec {
    public static func makeLightID(connectionID: String) -> String { "govee:\(connectionID):light" }
    public static func makeRoomID(connectionID: String) -> String { "govee:\(connectionID):room" }

    public static func encodeDevStatus() -> Data {
        Data(#"{"msg":{"cmd":"devStatus","data":{}}}"#.utf8)
    }

    public static func encodeCommands(
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?
    ) -> [Data] {
        var cmds: [Data] = []
        if let on = on {
            let obj: [String: Any] = ["msg": ["cmd": "turn", "data": ["value": on ? 1 : 0]]]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { cmds.append(d) }
        }
        if let bri = bri {
            let obj: [String: Any] = ["msg": ["cmd": "brightness", "data": ["value": HueColorMath.clamp(bri, 1, 100)]]]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { cmds.append(d) }
        }
        if let xy = xy {
            let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
            let obj: [String: Any] = ["msg": ["cmd": "colorwc", "data": ["color": ["r": rgb.r, "g": rgb.g, "b": rgb.b], "colorTemInKelvin": 0]]]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { cmds.append(d) }
        } else if let mirek = mirek {
            let k = HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), 2000, 9000)
            let obj: [String: Any] = ["msg": ["cmd": "colorwc", "data": ["color": ["r": 0, "g": 0, "b": 0], "colorTemInKelvin": k]]]
            if let d = try? JSONSerialization.data(withJSONObject: obj) { cmds.append(d) }
        }
        return cmds
    }

    public static func parseStatus(connection: ProviderConnection, json: [String: Any]) -> ProviderFetchResult {
        let msg = json["msg"] as? [String: Any] ?? json
        let data = msg["data"] as? [String: Any] ?? msg
        let isOn = (JSONValue.optionalInt(data, "onOff") ?? 0) != 0
        let bri = Double(HueColorMath.clamp(JSONValue.optionalInt(data, "brightness") ?? (isOn ? 100 : 0), 0, 100))
        let kelvin = JSONValue.optionalInt(data, "colorTemInKelvin") ?? 0
        let mirek = kelvin >= 1500 ? HueColorMath.kelvinToMirek(kelvin) : nil

        let colorHex: String = {
            if let col = data["color"] as? [String: Any],
               let r = JSONValue.optionalInt(col, "r"),
               let g = JSONValue.optionalInt(col, "g"),
               let b = JSONValue.optionalInt(col, "b"),
               (r > 0 || g > 0 || b > 0) {
                return HueColorMath.rgbToHex(r: r, g: g, b: b)
            }
            if let m = mirek { return HueColorMath.mirekToHex(m) }
            return HueColorMath.defaultWarmHex
        }()

        let light = HueLight(
            id: makeLightID(connectionID: connection.id),
            deviceID: connection.deviceID,
            name: connection.name,
            on: isOn,
            bri: bri,
            dimmable: true,
            color: colorHex,
            reachable: true,
            supportsColor: true,
            supportsCT: true,
            mirek: mirek,
            mirekMin: 111,
            mirekMax: 500,
            provider: LightProviderKind.govee.rawValue
        )
        let roomName = connection.roomName.isEmpty ? connection.name : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: isOn,
            bri: isOn ? bri : 0,
            onCount: isOn ? 1 : 0,
            archetype: "govee",
            color: colorHex,
            lights: [light],
            scenes: [],
            provider: LightProviderKind.govee.rawValue
        )
        return ProviderFetchResult(rooms: [room], deviceLabel: connection.name)
    }
}

/// D3: Serializes all Govee LAN UDP port 4002 listens so multiple Govee devices or overlapping
/// refreshes never contend on port 4002 and drop replies.
private actor GoveePortSerializer {
    static let shared = GoveePortSerializer()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                let next = waiters.removeFirst()
                next.resume()
            }
        }
        return try await operation()
    }
}

enum GoveeDriver {
    /// Govee LAN receives `devStatus` on UDP 4003 and sends the JSON reply back to client UDP port 4002.
    static func fetchState(connection: ProviderConnection) async throws -> ProviderFetchResult {
        try await GoveePortSerializer.shared.withLock {
            guard let reply = try await LocalUDPTransport.exchangeListeningOn(
                replyPort: 4002,
                targetHost: connection.host,
                targetPort: connection.effectivePort,
                payload: GoveeCodec.encodeDevStatus(),
                timeout: 2.2
            ) else {
                throw ProviderClientError.networkFailure("No reply from Govee light on UDP port 4002 (ensure LAN Control is enabled)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                throw ProviderClientError.invalidResponse
            }
            return GoveeCodec.parseStatus(connection: connection, json: json)
        }
    }

    static func setLight(
        connection: ProviderConnection,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?
    ) async throws {
        for cmd in GoveeCodec.encodeCommands(on: on, bri: bri, mirek: mirek, xy: xy) {
            _ = try await LocalUDPTransport.exchange(
                host: connection.host,
                port: connection.effectivePort,
                payload: cmd,
                expectReply: false,
                timeout: 1.5
            )
        }
    }
}

// MARK: - 6. Nanoleaf (Local OpenAPI HTTP Port 16021 + 5-sec Power Button Pairing)

public enum NanoleafParser {
    public static func makeLightID(connectionID: String) -> String { "nanoleaf:\(connectionID):panel" }
    public static func makeRoomID(connectionID: String) -> String { "nanoleaf:\(connectionID):room" }
    public static func makeSceneID(connectionID: String, effectName: String) -> String {
        let safe = effectName.unicodeScalars.map { s -> Character in
            let v = s.value
            if (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || v == 0x2D || v == 0x5F {
                return Character(s)
            }
            return "_"
        }
        return "nanoleaf:\(connectionID):fx:\(String(safe).prefix(48))"
    }

    public static func parse(connection: ProviderConnection, json: [String: Any]) -> (ProviderFetchResult, [String: String]) {
        let state = json["state"] as? [String: Any] ?? [:]
        let effectsObj = json["effects"] as? [String: Any] ?? [:]
        let name = HueColorMath.clean(JSONValue.string(json, "name"), limit: 40)
        let displayName = name.isEmpty ? connection.name : name
        let serial = JSONValue.string(json, "serialNo")

        let isOn = JSONValue.bool(state["on"] as? [String: Any] ?? [:], "value")
        let bri = Double(HueColorMath.clamp(JSONValue.optionalInt(state["brightness"] as? [String: Any] ?? [:], "value") ?? (isOn ? 100 : 0), 0, 100))
        let hue = Double(JSONValue.optionalInt(state["hue"] as? [String: Any] ?? [:], "value") ?? 0)
        let sat = Double(JSONValue.optionalInt(state["sat"] as? [String: Any] ?? [:], "value") ?? 0)
        let ctK = JSONValue.optionalInt(state["ct"] as? [String: Any] ?? [:], "value") ?? 3200
        let mirek = HueColorMath.kelvinToMirek(ctK)
        let colorMode = JSONValue.string(state, "colorMode")
        let colorHex = (colorMode == "ct" || sat < 3) ? HueColorMath.mirekToHex(mirek) : HueColorMath.hsbToHex(hue: hue, sat: sat, bri: 100)

        let selectedFx = HueColorMath.clean(JSONValue.string(effectsObj, "select"), limit: 40)
        let rawList = JSONValue.strings(effectsObj, "effectsList")
        var sceneIDToEffect: [String: String] = [:]
        var scenes: [HueScene] = []
        for fx in rawList.prefix(24) {
            let cleanFx = HueColorMath.clean(fx, limit: 30)
            guard !cleanFx.isEmpty else { continue }
            let sid = makeSceneID(connectionID: connection.id, effectName: cleanFx)
            sceneIDToEffect[sid] = fx
            scenes.append(HueScene(
                id: sid,
                name: cleanFx,
                active: fx == selectedFx,
                provider: LightProviderKind.nanoleaf.rawValue
            ))
        }

        let light = HueLight(
            id: makeLightID(connectionID: connection.id),
            deviceID: serial,
            name: displayName,
            on: isOn,
            bri: bri,
            dimmable: true,
            color: colorHex,
            reachable: true,
            supportsColor: true,
            supportsCT: true,
            mirek: mirek,
            mirekMin: 154,
            mirekMax: 833,
            effect: selectedFx.isEmpty || selectedFx.hasPrefix("*") ? "no_effect" : selectedFx,
            availableEffects: Array(rawList.prefix(16)),
            provider: LightProviderKind.nanoleaf.rawValue
        )
        let roomName = connection.roomName.isEmpty ? displayName : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: isOn,
            bri: isOn ? bri : 0,
            onCount: isOn ? 1 : 0,
            archetype: "nanoleaf",
            color: colorHex,
            lights: [light],
            scenes: scenes,
            provider: LightProviderKind.nanoleaf.rawValue
        )
        return (ProviderFetchResult(rooms: [room], deviceLabel: displayName), sceneIDToEffect)
    }
}

enum NanoleafDriver {
    /// Hold the Nanoleaf controller power button for 5–7 s until LEDs flash, then call `pair`.
    static func pair(host: String, port: Int = 16021) async throws -> String {
        guard HueColorMath.validLocalHost(host), (1...65535).contains(port),
              let url = URL(string: "http://\(host):\(port)/api/v1/new") else {
            throw ProviderClientError.invalidHost
        }
        for _ in 0..<12 {
            let (data, status, _) = try await LocalHTTPTransport.request(url: url, method: "POST", timeout: 3.0)
            if (200...299).contains(status),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["auth_token"] as? String, isSafeURLPathSegment(token) {
                return token
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ProviderClientError.pairingTimedOut
    }

    static func fetchState(connection: ProviderConnection, secret: String?) async throws -> (ProviderFetchResult, [String: String]) {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard isSafeURLPathSegment(token) else {
            throw ProviderClientError.invalidResponse
        }
        guard let url = connection.baseURL(path: "/api/v1/\(token)/") else { throw ProviderClientError.invalidHost }
        let (data, status, _) = try await LocalHTTPTransport.request(url: url, timeout: 4.5)
        guard (200...299).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.httpStatus(status, "")
        }
        return NanoleafParser.parse(connection: connection, json: json)
    }

    static func setLight(
        connection: ProviderConnection,
        secret: String?,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        effect: String?
    ) async throws {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard isSafeURLPathSegment(token) else {
            throw ProviderClientError.invalidResponse
        }
        var sentEffect = false
        if let effect = effect, !effect.isEmpty, effect != "no_effect" {
            guard let fxURL = connection.baseURL(path: "/api/v1/\(token)/effects") else { throw ProviderClientError.invalidHost }
            let fxBody = try JSONSerialization.data(withJSONObject: ["select": effect])
            let (_, fxStatus, _) = try await LocalHTTPTransport.request(url: fxURL, method: "PUT", body: fxBody, timeout: 4.0)
            guard (200...299).contains(fxStatus) else { throw ProviderClientError.httpStatus(fxStatus, "") }
            sentEffect = true
        }
        var payload: [String: Any] = [:]
        if let on = on { payload["on"] = ["value": on] }
        if let bri = bri { payload["brightness"] = ["value": HueColorMath.clamp(bri, 0, 100)] }
        if !sentEffect {
            if let xy = xy {
                let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
                let hsb = HueColorMath.rgbToHSB(r: rgb.r, g: rgb.g, b: rgb.b)
                payload["hue"] = ["value": HueColorMath.clamp(Int(hsb.hue.rounded()), 0, 360)]
                payload["sat"] = ["value": HueColorMath.clamp(Int(hsb.sat.rounded()), 0, 100)]
            } else if let mirek = mirek {
                payload["ct"] = ["value": HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), 1200, 6500)]
            }
        }
        guard !payload.isEmpty, let url = connection.baseURL(path: "/api/v1/\(token)/state") else { return }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, status, _) = try await LocalHTTPTransport.request(url: url, method: "PUT", body: body, timeout: 4.0)
        guard (200...299).contains(status) else { throw ProviderClientError.httpStatus(status, "") }
    }
}

// MARK: - 7. Shelly (Local HTTP Gen2/Gen3 RPC + Gen1 Fallback)

public enum ShellyParser {
    public struct ChannelMeta: Equatable, Sendable {
        public let gen: Int        // 1 or 2
        public let kind: String    // "light" | "rgb" | "rgbw" | "switch" | "color" | "relay"
        public let channel: Int
    }

    public static func makeLightID(connectionID: String, kind: String, channel: Int) -> String {
        "shelly:\(connectionID):\(kind):\(channel)"
    }

    public static func makeRoomID(connectionID: String) -> String {
        "shelly:\(connectionID):room"
    }

    public static func parseGen2(
        connection: ProviderConnection,
        info: [String: Any],
        status: [String: Any]
    ) -> (ProviderFetchResult, [String: ChannelMeta]) {
        let baseName = HueColorMath.clean(JSONValue.string(info, "name"), limit: 36)
        let label = baseName.isEmpty ? connection.name : baseName
        var lights: [HueLight] = []
        var metaMap: [String: ChannelMeta] = [:]

        for (key, value) in status.sorted(by: { $0.key < $1.key }) {
            guard let obj = value as? [String: Any],
                  let colon = key.firstIndex(of: ":"),
                  let ch = Int(key[key.index(after: colon)...]) else { continue }
            let comp = String(key[..<colon]).lowercased()
            guard ["light", "rgb", "rgbw", "switch"].contains(comp) else { continue }

            let isOn = JSONValue.bool(obj, "output")
            let bri = HueColorMath.finite(obj["brightness"], low: 0, high: 100) ?? (isOn ? 100.0 : 0.0)
            let dimmable = comp != "switch"
            let supportsColor = comp == "rgb" || comp == "rgbw"
            let colorHex: String = {
                if let rgb = obj["rgb"] as? [Any], rgb.count >= 3,
                   let r = HueColorMath.finite(rgb[0], low: 0, high: 255),
                   let g = HueColorMath.finite(rgb[1], low: 0, high: 255),
                   let b = HueColorMath.finite(rgb[2], low: 0, high: 255) {
                    return HueColorMath.rgbToHex(r: Int(r), g: Int(g), b: Int(b))
                }
                return HueColorMath.defaultWarmHex
            }()
            let lid = makeLightID(connectionID: connection.id, kind: comp, channel: ch)
            let chName = ch == 0 ? label : "\(label) \(ch + 1)"
            metaMap[lid] = ChannelMeta(gen: 2, kind: comp, channel: ch)
            lights.append(HueLight(
                id: lid,
                deviceID: JSONValue.string(info, "mac"),
                name: chName,
                on: isOn,
                bri: bri.rounded(),
                dimmable: dimmable,
                color: colorHex,
                reachable: true,
                supportsColor: supportsColor,
                supportsCT: false,
                provider: LightProviderKind.shelly.rawValue
            ))
        }

        let onLights = lights.filter(\.on)
        let avgBri = onLights.isEmpty ? 0.0 : (onLights.map(\.bri).reduce(0, +) / Double(onLights.count)).rounded()
        let roomName = connection.roomName.isEmpty ? label : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: !onLights.isEmpty,
            bri: avgBri,
            onCount: onLights.count,
            archetype: "shelly",
            color: HueColorMath.blendColors(onLights.map(\.color)),
            lights: lights,
            scenes: [],
            provider: LightProviderKind.shelly.rawValue
        )
        return (ProviderFetchResult(rooms: lights.isEmpty ? [] : [room], deviceLabel: label), metaMap)
    }

    public static func parseGen1(
        connection: ProviderConnection,
        status: [String: Any]
    ) -> (ProviderFetchResult, [String: ChannelMeta]) {
        var lights: [HueLight] = []
        var metaMap: [String: ChannelMeta] = [:]

        if let rawLights = status["lights"] as? [[String: Any]], !rawLights.isEmpty {
            for (idx, item) in rawLights.enumerated() {
                let isOn = JSONValue.bool(item, "ison")
                let bri = Double(HueColorMath.clamp(JSONValue.optionalInt(item, "brightness") ?? JSONValue.optionalInt(item, "gain") ?? 100, 0, 100))
                let mode = JSONValue.string(item, "mode").lowercased()
                let isColor = (mode == "color") || (mode != "white" && item["red"] != nil && item["green"] != nil && item["blue"] != nil)
                let tempK = JSONValue.optionalInt(item, "temp")
                let mirek = tempK.map { HueColorMath.kelvinToMirek($0) }
                let colorHex: String = {
                    if isColor,
                       let r = JSONValue.optionalInt(item, "red"),
                       let g = JSONValue.optionalInt(item, "green"),
                       let b = JSONValue.optionalInt(item, "blue") {
                        return HueColorMath.rgbToHex(r: r, g: g, b: b)
                    }
                    if let m = mirek { return HueColorMath.mirekToHex(m) }
                    return HueColorMath.defaultWarmHex
                }()
                let comp = isColor ? "color" : (mode == "white" ? "white" : "light")
                let lid = makeLightID(connectionID: connection.id, kind: comp, channel: idx)
                metaMap[lid] = ChannelMeta(gen: 1, kind: comp, channel: idx)
                lights.append(HueLight(
                    id: lid,
                    name: idx == 0 ? connection.name : "\(connection.name) \(idx + 1)",
                    on: isOn,
                    bri: bri,
                    dimmable: true,
                    color: colorHex,
                    reachable: true,
                    supportsColor: isColor,
                    supportsCT: tempK != nil,
                    mirek: mirek,
                    provider: LightProviderKind.shelly.rawValue
                ))
            }
        } else if let rawRelays = status["relays"] as? [[String: Any]] {
            for (idx, item) in rawRelays.enumerated() {
                let isOn = JSONValue.bool(item, "ison")
                let lid = makeLightID(connectionID: connection.id, kind: "relay", channel: idx)
                metaMap[lid] = ChannelMeta(gen: 1, kind: "relay", channel: idx)
                lights.append(HueLight(
                    id: lid,
                    name: idx == 0 ? connection.name : "\(connection.name) \(idx + 1)",
                    on: isOn,
                    bri: isOn ? 100 : 0,
                    dimmable: false,
                    color: HueColorMath.defaultWarmHex,
                    reachable: true,
                    supportsColor: false,
                    supportsCT: false,
                    provider: LightProviderKind.shelly.rawValue
                ))
            }
        }

        let onLights = lights.filter(\.on)
        let avgBri = onLights.isEmpty ? 0.0 : (onLights.map(\.bri).reduce(0, +) / Double(onLights.count)).rounded()
        let roomName = connection.roomName.isEmpty ? connection.name : connection.roomName
        let room = HueRoom(
            hueID: makeRoomID(connectionID: connection.id),
            kind: "room",
            name: roomName,
            groupedLight: "",
            on: !onLights.isEmpty,
            bri: avgBri,
            onCount: onLights.count,
            archetype: "shelly",
            color: HueColorMath.blendColors(onLights.map(\.color)),
            lights: lights,
            scenes: [],
            provider: LightProviderKind.shelly.rawValue
        )
        return (ProviderFetchResult(rooms: lights.isEmpty ? [] : [room], deviceLabel: connection.name), metaMap)
    }
}

enum ShellyDriver {
    static func fetchState(connection: ProviderConnection) async throws -> (ProviderFetchResult, [String: ShellyParser.ChannelMeta]) {
        if let infoURL = connection.baseURL(path: "/rpc/Shelly.GetDeviceInfo"),
           let statusURL = connection.baseURL(path: "/rpc/Shelly.GetStatus"),
           let (infoData, iCode, _) = try? await LocalHTTPTransport.request(url: infoURL, timeout: 3.5) {
            if iCode == 401 {
                throw ProviderClientError.httpStatus(401, "Shelly requires local authentication (disable auth or connect via Home Assistant)")
            }
            if (200...299).contains(iCode),
               let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let (statusData, sCode, _) = try? await LocalHTTPTransport.request(url: statusURL, timeout: 3.5) {
                if sCode == 401 {
                    throw ProviderClientError.httpStatus(401, "Shelly requires local authentication (disable auth or connect via Home Assistant)")
                }
                if (200...299).contains(sCode),
                   let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] {
                    return ShellyParser.parseGen2(connection: connection, info: info, status: status)
                }
            }
        }
        guard let url = connection.baseURL(path: "/status") else { throw ProviderClientError.invalidHost }
        let (data, code, _) = try await LocalHTTPTransport.request(url: url, timeout: 4.0)
        if code == 401 {
            throw ProviderClientError.httpStatus(401, "Shelly requires local authentication")
        }
        guard (200...299).contains(code),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.invalidResponse
        }
        return ShellyParser.parseGen1(connection: connection, status: status)
    }

    static func setLight(
        connection: ProviderConnection,
        meta: ShellyParser.ChannelMeta,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?
    ) async throws {
        if meta.gen == 2 {
            let rpcMethod: String
            switch meta.kind {
            case "rgb": rpcMethod = "RGB.Set"
            case "rgbw": rpcMethod = "RGBW.Set"
            case "switch":
                guard on != nil else { return }
                rpcMethod = "Switch.Set"
            default: rpcMethod = "Light.Set"
            }
            guard let url = connection.baseURL(path: "/rpc/\(rpcMethod)") else { throw ProviderClientError.invalidHost }
            var bodyObj: [String: Any] = ["id": meta.channel]
            if let on = on { bodyObj["on"] = on }
            if let bri = bri, meta.kind != "switch" { bodyObj["brightness"] = HueColorMath.clamp(bri, 0, 100) }
            if let xy = xy, (meta.kind == "rgb" || meta.kind == "rgbw") {
                let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
                bodyObj["rgb"] = [rgb.r, rgb.g, rgb.b]
            }
            guard bodyObj.count > 1 else { return }
            let body = try JSONSerialization.data(withJSONObject: bodyObj)
            let (_, code, _) = try await LocalHTTPTransport.request(url: url, method: "POST", body: body, timeout: 4.0)
            guard (200...299).contains(code) else { throw ProviderClientError.httpStatus(code, "") }
        } else {
            var q: [String] = []
            if let on = on { q.append("turn=\(on ? "on" : "off")") }
            if let bri = bri, meta.kind != "relay" {
                let key = meta.kind == "color" ? "gain" : "brightness"
                q.append("\(key)=\(HueColorMath.clamp(bri, 0, 100))")
            }
            if let xy = xy, meta.kind == "color" {
                let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
                q.append("red=\(rgb.r)&green=\(rgb.g)&blue=\(rgb.b)")
            } else if let mirek = mirek, (meta.kind == "light" || meta.kind == "white") {
                q.append("temp=\(HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), 2700, 6500))")
            }
            guard !q.isEmpty else { return }
            let queryStr = "?\(q.joined(separator: "&"))"
            guard let url = connection.baseURL(path: "/\(meta.kind)/\(meta.channel)\(queryStr)") else {
                throw ProviderClientError.invalidHost
            }
            let (_, code, _) = try await LocalHTTPTransport.request(url: url, timeout: 4.0)
            guard (200...299).contains(code) else { throw ProviderClientError.httpStatus(code, "") }
        }
    }
}

// MARK: - 8. IKEA DIRIGERA (Local HTTPS Port 8443 + OAuth2 PKCE Action-Button Pairing)

public enum DirigeraParser {
    public static func makeLightID(connectionID: String, deviceID: String) -> String { "dirigera:\(connectionID):\(deviceID)" }
    public static func makeRoomID(connectionID: String, roomID: String) -> String { "dirigera:\(connectionID):room:\(roomID)" }
    public static func makeSceneID(connectionID: String, sceneID: String) -> String { "dirigera:\(connectionID):scene:\(sceneID)" }
    public static func makeSensorID(connectionID: String, deviceID: String) -> String { "dirigera:\(connectionID):sensor:\(deviceID)" }

    public static func parse(
        connection: ProviderConnection,
        devices: [[String: Any]],
        scenes rawScenes: [[String: Any]] = []
    ) -> ProviderFetchResult {
        var lightsByRoom: [String: (name: String, lights: [HueLight])] = [:]
        var sensors: [HueSensor] = []

        for dev in devices {
            let devID = JSONValue.string(dev, "id")
            guard !devID.isEmpty else { continue }
            let type = JSONValue.string(dev, "type").lowercased()
            let deviceType = JSONValue.string(dev, "deviceType").lowercased()
            let attrs = dev["attributes"] as? [String: Any] ?? [:]
            let caps = dev["capabilities"] as? [String: Any] ?? [:]
            let canReceive = Set(JSONValue.strings(caps, "canReceive"))
            let reachable = (dev["isReachable"] as? Bool) ?? true
            let customName = HueColorMath.clean(JSONValue.string(attrs, "customName"), limit: 50)
            let name = customName.isEmpty ? (HueColorMath.clean(JSONValue.string(attrs, "model"), limit: 40)) : customName
            let displayName = name.isEmpty ? "IKEA Light" : name

            let roomObj = dev["room"] as? [String: Any]
            let rawRoomID = JSONValue.string(roomObj ?? [:], "id")
            let rawRoomName = HueColorMath.clean(JSONValue.string(roomObj ?? [:], "name"), limit: 40)
            let roomKey = rawRoomID.isEmpty ? "unassigned" : rawRoomID
            let roomDisplay = rawRoomName.isEmpty ? (connection.roomName.isEmpty ? connection.name : connection.roomName) : rawRoomName

            if type == "light" || deviceType == "light" {
                let isOn = JSONValue.bool(attrs, "isOn")
                let bri = Double(HueColorMath.clamp(JSONValue.optionalInt(attrs, "lightLevel") ?? (isOn ? 100 : 0), 0, 100))
                let supportsColor = canReceive.contains("colorHue") || attrs["colorHue"] != nil
                let supportsCT = canReceive.contains("colorTemperature") || attrs["colorTemperature"] != nil
                let dimmable = canReceive.contains("lightLevel") || attrs["lightLevel"] != nil
                let ctK = JSONValue.optionalInt(attrs, "colorTemperature")
                let mirek = ctK.map { HueColorMath.kelvinToMirek($0) }
                let minK = JSONValue.optionalInt(attrs, "colorTemperatureMin") ?? 2200
                let maxK = JSONValue.optionalInt(attrs, "colorTemperatureMax") ?? 4000

                let colorHex: String = {
                    if let h = HueColorMath.finite(attrs["colorHue"], low: 0, high: 360),
                       let s = HueColorMath.finite(attrs["colorSaturation"], low: 0, high: 1),
                       s >= 0.04 {
                        return HueColorMath.hsbToHex(hue: h, sat: s * 100.0, bri: 100.0)
                    }
                    if let m = mirek { return HueColorMath.mirekToHex(m) }
                    return HueColorMath.defaultWarmHex
                }()

                let light = HueLight(
                    id: makeLightID(connectionID: connection.id, deviceID: devID),
                    deviceID: devID,
                    name: displayName,
                    on: isOn,
                    bri: bri,
                    dimmable: dimmable,
                    color: colorHex,
                    reachable: reachable,
                    supportsColor: supportsColor,
                    supportsCT: supportsCT,
                    mirek: mirek,
                    mirekMin: HueColorMath.kelvinToMirek(max(minK, maxK)),
                    mirekMax: HueColorMath.kelvinToMirek(min(minK, maxK)),
                    provider: LightProviderKind.dirigera.rawValue
                )
                var entry = lightsByRoom[roomKey] ?? (name: roomDisplay, lights: [])
                entry.lights.append(light)
                lightsByRoom[roomKey] = entry
            } else if type == "sensor" {
                let kind: String?
                if deviceType.contains("motion") || attrs["isDetected"] != nil {
                    kind = "motion"
                } else if deviceType.contains("openclose") || attrs["isOpen"] != nil {
                    kind = "contact"
                } else {
                    kind = nil
                }
                if let kind = kind {
                    sensors.append(HueSensor(
                        id: makeSensorID(connectionID: connection.id, deviceID: devID),
                        deviceID: devID,
                        kind: kind,
                        name: displayName,
                        roomID: makeRoomID(connectionID: connection.id, roomID: roomKey),
                        enabled: reachable,
                        motion: JSONValue.bool(attrs, "isDetected"),
                        open: JSONValue.bool(attrs, "isOpen"),
                        temperature: HueColorMath.finite(attrs["currentTemperature"], low: -50, high: 120),
                        lux: HueColorMath.finite(attrs["illuminance"], low: 0, high: 200_000),
                        battery: JSONValue.optionalInt(attrs, "batteryPercentage"),
                        provider: LightProviderKind.dirigera.rawValue
                    ))
                }
            }
        }

        let scenes: [HueScene] = rawScenes.compactMap { sc in
            let sid = JSONValue.string(sc, "id")
            let info = sc["info"] as? [String: Any] ?? [:]
            let sName = HueColorMath.clean(JSONValue.string(info, "name"), limit: 30)
            guard !sid.isEmpty, !sName.isEmpty else { return nil }
            return HueScene(
                id: makeSceneID(connectionID: connection.id, sceneID: sid),
                name: sName,
                active: false,
                provider: LightProviderKind.dirigera.rawValue
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let sortedRooms = lightsByRoom.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
        var rooms: [HueRoom] = []
        for (idx, (roomKey, entry)) in sortedRooms.enumerated() {
            let members = entry.lights.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !members.isEmpty else { continue }
            let onMembers = members.filter(\.on)
            let avgBri = onMembers.isEmpty ? 0.0 : (onMembers.map(\.bri).reduce(0, +) / Double(onMembers.count)).rounded()
            rooms.append(HueRoom(
                hueID: makeRoomID(connectionID: connection.id, roomID: roomKey),
                kind: "room",
                name: entry.name,
                groupedLight: "",
                on: !onMembers.isEmpty,
                bri: avgBri,
                onCount: onMembers.count,
                archetype: "dirigera",
                color: HueColorMath.blendColors(onMembers.map(\.color)),
                lights: members,
                scenes: idx == 0 ? Array(scenes.prefix(24)) : [],
                provider: LightProviderKind.dirigera.rawValue
            ))
        }
        return ProviderFetchResult(rooms: rooms, sensors: sensors, deviceLabel: connection.name)
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum DirigeraDriver {
    /// Initiates DIRIGERA OAuth2 PKCE pairing and polls while user presses the Action Button underneath the hub.
    /// Returns `(accessToken, certFingerprint)` so the hub's TLS certificate is pinned immediately on first pair.
    static func pair(host: String, port: Int = 8443) async throws -> (token: String, certFingerprint: String) {
        #if canImport(CryptoKit)
        guard HueColorMath.validLocalHost(host), (1...65535).contains(port) else {
            throw ProviderClientError.invalidHost
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = DirigeraParser.base64URLEncode(Data(digest))

        guard let authURL = URL(string: "https://\(host):\(port)/v1/oauth/authorize?audience=homesmart.local&response_type=code&code_challenge=\(challenge)&code_challenge_method=S256") else {
            throw ProviderClientError.invalidHost
        }
        let (authData, authCode, pinnedFP) = try await LocalHTTPTransport.request(
            url: authURL,
            timeout: 5.0,
            allowSelfSignedLocalTLS: true
        )
        guard (200...299).contains(authCode),
              let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let code = authJSON["code"] as? String, !code.isEmpty else {
            throw ProviderClientError.httpStatus(authCode, "Could not start DIRIGERA pairing")
        }

        guard let tokenURL = URL(string: "https://\(host):\(port)/v1/oauth/token") else {
            throw ProviderClientError.invalidHost
        }
        let form = "code=\(code)&name=MaprismaLights&grant_type=authorization_code&code_verifier=\(verifier)"
        for _ in 0..<15 {
            let (tokData, tokStatus, fp2) = try await LocalHTTPTransport.request(
                url: tokenURL,
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(form.utf8),
                timeout: 4.0,
                allowSelfSignedLocalTLS: true,
                expectedFingerprint: pinnedFP
            )
            if (200...299).contains(tokStatus),
               let tokJSON = try? JSONSerialization.jsonObject(with: tokData) as? [String: Any],
               let access = tokJSON["access_token"] as? String, !access.isEmpty {
                return (access, fp2.isEmpty ? pinnedFP : fp2)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ProviderClientError.pairingTimedOut
        #else
        throw ProviderClientError.unsupported
        #endif
    }

    static func fetchState(connection: ProviderConnection, secret: String?) async throws -> (ProviderFetchResult, [String: (minK: Int, maxK: Int)]) {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard let devURL = connection.baseURL(path: "/v1/devices") else { throw ProviderClientError.invalidHost }
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let (data, code, fp) = try await LocalHTTPTransport.request(
            url: devURL,
            headers: headers,
            timeout: 5.5,
            allowSelfSignedLocalTLS: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(code),
              let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProviderClientError.httpStatus(code, "")
        }
        var rawScenes: [[String: Any]] = []
        if let scURL = connection.baseURL(path: "/v1/scenes"),
           let (scData, scCode, _) = try? await LocalHTTPTransport.request(
               url: scURL,
               headers: headers,
               timeout: 3.5,
               allowSelfSignedLocalTLS: true,
               expectedFingerprint: fp.isEmpty ? connection.certFingerprint : fp
           ),
           (200...299).contains(scCode),
           let parsed = try? JSONSerialization.jsonObject(with: scData) as? [[String: Any]] {
            rawScenes = parsed
        }
        var ctBounds: [String: (minK: Int, maxK: Int)] = [:]
        for dev in devices {
            let did = JSONValue.string(dev, "id")
            guard !did.isEmpty else { continue }
            let attrs = dev["attributes"] as? [String: Any] ?? [:]
            let rawMin = JSONValue.optionalInt(attrs, "colorTemperatureMin") ?? 2200
            let rawMax = JSONValue.optionalInt(attrs, "colorTemperatureMax") ?? 4000
            ctBounds[did] = (min(rawMin, rawMax), max(rawMin, rawMax))
        }
        var result = DirigeraParser.parse(connection: connection, devices: devices, scenes: rawScenes)
        result.certFingerprint = fp.isEmpty ? connection.certFingerprint : fp
        return (result, ctBounds)
    }

    static func setLight(
        connection: ProviderConnection,
        secret: String?,
        deviceID: String,
        on: Bool?,
        bri: Int?,
        mirek: Int?,
        xy: (Double, Double)?,
        kelvinBounds: (minK: Int, maxK: Int)? = nil
    ) async throws {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard isSafeURLPathSegment(deviceID) else { throw ProviderClientError.invalidHost }
        guard let url = connection.baseURL(path: "/v1/devices/\(deviceID)") else { throw ProviderClientError.invalidHost }
        var patches: [[String: Any]] = []
        if let on = on {
            patches.append(["attributes": ["isOn": on]])
        }
        var attrs: [String: Any] = [:]
        if let bri = bri { attrs["lightLevel"] = HueColorMath.clamp(bri, 1, 100) }
        if let xy = xy {
            let rgb = HueColorMath.xyToRGB(x: xy.0, y: xy.1)
            let hsb = HueColorMath.rgbToHSB(r: rgb.r, g: rgb.g, b: rgb.b)
            attrs["colorHue"] = hsb.hue
            attrs["colorSaturation"] = HueColorMath.clamp(hsb.sat / 100.0, 0.0, 1.0)
        } else if let mirek = mirek {
            let lo = kelvinBounds?.minK ?? 2200
            let hi = kelvinBounds?.maxK ?? 4000
            attrs["colorTemperature"] = HueColorMath.clamp(HueColorMath.mirekToKelvin(mirek), lo, hi)
        }
        if !attrs.isEmpty {
            patches.append(["attributes": attrs])
        }
        guard !patches.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: patches)
        let (_, code, _) = try await LocalHTTPTransport.request(
            url: url,
            method: "PATCH",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: body,
            timeout: 4.5,
            allowSelfSignedLocalTLS: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(code) else { throw ProviderClientError.httpStatus(code, "") }
    }

    static func recallScene(connection: ProviderConnection, secret: String?, sceneID: String) async throws {
        guard let token = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ProviderClientError.missingToken
        }
        guard isSafeURLPathSegment(sceneID) else { throw ProviderClientError.invalidHost }
        guard let url = connection.baseURL(path: "/v1/scenes/\(sceneID)/trigger") else { throw ProviderClientError.invalidHost }
        let (_, code, _) = try await LocalHTTPTransport.request(
            url: url,
            method: "POST",
            headers: ["Authorization": "Bearer \(token)"],
            timeout: 4.0,
            allowSelfSignedLocalTLS: true,
            expectedFingerprint: connection.certFingerprint
        )
        guard (200...299).contains(code) else { throw ProviderClientError.httpStatus(code, "") }
    }
}

// MARK: - Unified Bonjour Multi-Device Discovery

#if canImport(Network)
final class MultiProviderBonjourDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.maprisma.lights.provider.discovery")
    private let lock = NSLock()
    private var browsers: [NWBrowser] = []
    private var found: [String: DiscoveredProviderDevice] = [:]
    private var scanGeneration: UInt64 = 0

    func start(
        kinds: [LightProviderKind] = LightProviderKind.extraProviders.filter { $0.bonjourService != nil },
        duration: TimeInterval = 4.5,
        onUpdate: @escaping @Sendable ([DiscoveredProviderDevice]) -> Void,
        onComplete: @escaping @Sendable ([DiscoveredProviderDevice]) -> Void
    ) {
        stop()
        lock.lock()
        scanGeneration &+= 1
        let gen = scanGeneration
        found.removeAll()
        lock.unlock()

        for kind in kinds {
            guard let service = kind.bonjourService else { continue }
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: "local."), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                for result in results {
                    self.resolve(result: result, kind: kind, generation: gen, onUpdate: onUpdate)
                }
            }
            lock.lock()
            browsers.append(browser)
            lock.unlock()
            browser.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let isCurrent = (self.scanGeneration == gen)
            self.lock.unlock()
            guard isCurrent else { return }
            let list = self.snapshotList()
            self.stop()
            onComplete(list)
        }
    }

    func stop() {
        lock.lock()
        let active = browsers
        browsers.removeAll()
        lock.unlock()
        for b in active { b.cancel() }
    }

    private func snapshotList() -> [DiscoveredProviderDevice] {
        lock.lock()
        defer { lock.unlock() }
        return found.values.sorted {
            if $0.kind.displayName != $1.kind.displayName {
                return $0.kind.displayName < $1.kind.displayName
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func resolve(
        result: NWBrowser.Result,
        kind: LightProviderKind,
        generation: UInt64,
        onUpdate: @escaping @Sendable ([DiscoveredProviderDevice]) -> Void
    ) {
        let svcName: String = {
            if case .service(let name, _, _, _) = result.endpoint {
                return HueColorMath.clean(name, limit: 48)
            }
            return kind.displayName
        }()
        let conn = NWConnection(to: result.endpoint, using: .tcp)
        let flag = OnceFlag()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if flag.tryClaim(),
                   case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint,
                   let ip = Self.extractIPv4(from: host),
                   HueColorMath.validLocalHost(ip, allowLoopback: kind.allowsLoopbackHost) {
                    let device = DiscoveredProviderDevice(
                        kind: kind,
                        name: svcName,
                        host: ip,
                        port: Int(port.rawValue),
                        deviceID: "",
                        model: kind.displayName
                    )
                    self.lock.lock()
                    guard self.scanGeneration == generation else {
                        self.lock.unlock()
                        conn.cancel()
                        return
                    }
                    self.found[device.id] = device
                    let list = self.found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.lock.unlock()
                    onUpdate(list)
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2.5) {
            if flag.tryClaim() { conn.cancel() }
        }
    }

    private static func extractIPv4(from host: NWEndpoint.Host) -> String? {
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
}
#endif
