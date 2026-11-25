import Foundation
#if canImport(Security)
import Security
#endif

/// Supported local-first smart lighting ecosystems.
public enum LightProviderKind: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case hue = "hue"
    case homeAssistant = "home_assistant"
    case wled = "wled"
    case wiz = "wiz"
    case lifx = "lifx"
    case govee = "govee"
    case nanoleaf = "nanoleaf"
    case shelly = "shelly"
    case dirigera = "dirigera"

    public var id: String { rawValue }

    /// Extra (non-Hue) providers configurable alongside or instead of a Philips Hue Bridge.
    public static var extraProviders: [LightProviderKind] {
        [.homeAssistant, .wled, .wiz, .lifx, .govee, .nanoleaf, .shelly, .dirigera]
    }

    /// Resource ID namespace prefix used in `HueLight.id`, `HueRoom.id`, `HueScene.id`, `HueSensor.id`.
    public var idPrefix: String {
        switch self {
        case .hue: return "hue"
        case .homeAssistant: return "ha"
        case .wled: return "wled"
        case .wiz: return "wiz"
        case .lifx: return "lifx"
        case .govee: return "govee"
        case .nanoleaf: return "nanoleaf"
        case .shelly: return "shelly"
        case .dirigera: return "dirigera"
        }
    }

    public static func from(idPrefix raw: String) -> LightProviderKind? {
        let lower = raw.lowercased()
        return Self.allCases.first { $0.idPrefix == lower || $0.rawValue == lower }
    }

    public var displayName: String {
        switch self {
        case .hue: return "Philips Hue"
        case .homeAssistant: return "Home Assistant"
        case .wled: return "WLED"
        case .wiz: return "WiZ"
        case .lifx: return "LIFX"
        case .govee: return "Govee LAN"
        case .nanoleaf: return "Nanoleaf"
        case .shelly: return "Shelly"
        case .dirigera: return "IKEA DIRIGERA"
        }
    }

    public var shortBadge: String {
        switch self {
        case .hue: return "Hue"
        case .homeAssistant: return "HA"
        case .wled: return "WLED"
        case .wiz: return "WiZ"
        case .lifx: return "LIFX"
        case .govee: return "Govee"
        case .nanoleaf: return "Nanoleaf"
        case .shelly: return "Shelly"
        case .dirigera: return "IKEA"
        }
    }

    /// Safe SF Symbol guaranteed to exist on macOS 13.0+.
    public var safeSFSymbol: String {
        switch self {
        case .hue: return "wifi.router"
        case .homeAssistant: return "house.fill"
        case .wled: return "wand.and.stars"
        case .wiz: return "lightbulb.fill"
        case .lifx: return "sun.max.fill"
        case .govee: return "sparkles"
        case .nanoleaf: return "hexagon.fill"
        case .shelly: return "powerplug.fill"
        case .dirigera: return "cube.box.fill"
        }
    }

    public var accentHex: String {
        switch self {
        case .hue: return "#f59e0b"
        case .homeAssistant: return "#03a9f4"
        case .wled: return "#ec4899"
        case .wiz: return "#8b5cf6"
        case .lifx: return "#10b981"
        case .govee: return "#3b82f6"
        case .nanoleaf: return "#22c55e"
        case .shelly: return "#06b6d4"
        case .dirigera: return "#eab308"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .hue: return 443
        case .homeAssistant: return 8123
        case .wled: return 80
        case .wiz: return 38899
        case .lifx: return 56700
        case .govee: return 4003
        case .nanoleaf: return 16021
        case .shelly: return 80
        case .dirigera: return 8443
        }
    }

    public var bonjourService: String? {
        switch self {
        case .hue: return "_hue._tcp"
        case .homeAssistant: return "_home-assistant._tcp"
        case .wled: return "_wled._tcp"
        case .nanoleaf: return "_nanoleafapi._tcp"
        case .shelly: return "_shelly._tcp"
        case .dirigera: return "_ihsp._tcp"
        case .wiz, .lifx, .govee: return nil
        }
    }

    public var defaultUseHTTPS: Bool {
        self == .hue || self == .dirigera
    }

    public var requiresToken: Bool {
        self == .homeAssistant || self == .nanoleaf || self == .dirigera
    }

    public var supportsButtonPairing: Bool {
        self == .nanoleaf || self == .dirigera
    }

    public var allowsLoopbackHost: Bool {
        self == .homeAssistant
    }

    public var isHubProvider: Bool {
        self == .hue || self == .homeAssistant || self == .dirigera
    }
}

/// Persisted configuration for a non-Hue lighting provider (secrets live separately in Keychain).
public struct ProviderConnection: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: LightProviderKind
    public var name: String
    public var host: String
    public var port: Int?
    public var useHTTPS: Bool
    public var enabled: Bool
    public var roomName: String
    public var deviceID: String
    public var certFingerprint: String

    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, port
        case useHTTPS = "use_https"
        case enabled
        case roomName = "room_name"
        case deviceID = "device_id"
        case certFingerprint = "cert_fingerprint"
    }

    public init(
        id: String = Self.makeID(),
        kind: LightProviderKind,
        name: String = "",
        host: String,
        port: Int? = nil,
        useHTTPS: Bool? = nil,
        enabled: Bool = true,
        roomName: String = "",
        deviceID: String = "",
        certFingerprint: String = ""
    ) {
        self.id = Self.sanitizeID(id)
        self.kind = kind
        let cleanedName = HueColorMath.clean(name, limit: 40)
        self.name = cleanedName.isEmpty ? kind.displayName : cleanedName
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = port, (1...65535).contains(p) {
            self.port = p
        } else {
            self.port = nil
        }
        self.useHTTPS = useHTTPS ?? kind.defaultUseHTTPS
        self.enabled = enabled
        self.roomName = HueColorMath.clean(roomName, limit: 40)
        self.deviceID = HueColorMath.clean(deviceID, limit: 64)
        self.certFingerprint = Self.sanitizeFingerprint(certFingerprint)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.makeID()
        let kind = try c.decode(LightProviderKind.self, forKey: .kind)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        let port = try c.decodeIfPresent(Int.self, forKey: .port)
        let useHTTPS = try c.decodeIfPresent(Bool.self, forKey: .useHTTPS)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? ""
        let deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        let certFingerprint = try c.decodeIfPresent(String.self, forKey: .certFingerprint) ?? ""
        self.init(
            id: id,
            kind: kind,
            name: name,
            host: host,
            port: port,
            useHTTPS: useHTTPS,
            enabled: enabled,
            roomName: roomName,
            deviceID: deviceID,
            certFingerprint: certFingerprint
        )
    }

    public static func sanitizeFingerprint(_ raw: String) -> String {
        let cleaned = raw.lowercased().filter { c in
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f")
        }
        return cleaned.count == 64 ? cleaned : ""
    }

    public var effectivePort: Int {
        if let p = port, (1...65535).contains(p) { return p }
        return kind.defaultPort
    }

    public var isValidHost: Bool {
        HueColorMath.validLocalHost(host, allowLoopback: kind.allowsLoopbackHost)
    }

    public var scheme: String {
        useHTTPS ? "https" : "http"
    }

    public func baseURL(path: String = "") -> URL? {
        guard isValidHost else { return nil }
        let cleanPath = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/\(path)")
        return URL(string: "\(scheme)://\(host):\(effectivePort)\(cleanPath)")
    }

    public static func makeID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    public static func sanitizeID(_ raw: String) -> String {
        let filtered = raw.lowercased().unicodeScalars.filter { scalar in
            let v = scalar.value
            return (0x30...0x39).contains(v) || (0x61...0x7A).contains(v) || v == 0x2D || v == 0x5F
        }
        let s = String(String(String.UnicodeScalarView(filtered)).prefix(24))
        return s.isEmpty ? makeID() : s
    }
}

/// Live connection status summary for each configured provider (shown in Settings & header).
public struct ProviderStatus: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: LightProviderKind
    public var name: String
    public var host: String
    public var connected: Bool
    public var enabled: Bool
    public var lightCount: Int
    public var error: String

    enum CodingKeys: String, CodingKey {
        case id, kind, name, host, connected, enabled
        case lightCount = "light_count"
        case error
    }

    public init(
        id: String,
        kind: LightProviderKind,
        name: String,
        host: String,
        connected: Bool,
        enabled: Bool = true,
        lightCount: Int = 0,
        error: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.connected = connected
        self.enabled = enabled
        self.lightCount = max(0, lightCount)
        self.error = error
    }

    public init(json: [String: Any]) {
        id = JSONValue.string(json, "id")
        kind = LightProviderKind(rawValue: JSONValue.string(json, "kind")) ?? .hue
        name = JSONValue.string(json, "name")
        host = JSONValue.string(json, "host")
        connected = JSONValue.bool(json, "connected")
        enabled = (json["enabled"] as? Bool) ?? true
        lightCount = max(0, JSONValue.optionalInt(json, "light_count") ?? 0)
        error = JSONValue.string(json, "error")
    }
}

/// A local device discovered via Bonjour or UDP LAN scan.
public struct DiscoveredProviderDevice: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(host):\(port)" }
    public let kind: LightProviderKind
    public let name: String
    public let host: String
    public let port: Int
    public let deviceID: String
    public let model: String

    public init(
        kind: LightProviderKind,
        name: String,
        host: String,
        port: Int? = nil,
        deviceID: String = "",
        model: String = ""
    ) {
        self.kind = kind
        let cleaned = HueColorMath.clean(name, limit: 48)
        self.name = cleaned.isEmpty ? kind.displayName : cleaned
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port ?? kind.defaultPort
        self.deviceID = HueColorMath.clean(deviceID, limit: 64)
        self.model = HueColorMath.clean(model, limit: 48)
    }
}

/// Normalized state fetched from a single non-Hue provider.
public struct ProviderFetchResult: Equatable, Sendable {
    public var rooms: [HueRoom]
    public var sensors: [HueSensor]
    public var lightCount: Int
    public var onCount: Int
    public var deviceLabel: String
    public var certFingerprint: String

    public init(
        rooms: [HueRoom],
        sensors: [HueSensor] = [],
        deviceLabel: String = "",
        certFingerprint: String = ""
    ) {
        self.rooms = rooms
        self.sensors = sensors
        var seen = Set<String>()
        var total = 0
        var lit = 0
        for room in rooms {
            for light in room.lights where seen.insert(light.id).inserted {
                total += 1
                if light.on { lit += 1 }
            }
        }
        self.lightCount = total
        self.onCount = lit
        self.deviceLabel = deviceLabel
        self.certFingerprint = ProviderConnection.sanitizeFingerprint(certFingerprint)
    }
}

// MARK: - Provider Secret Storage (Keychain on macOS, in-memory fallback on Linux/tests)

public protocol ProviderSecretStoring: Sendable {
    func loadSecret(for connectionID: String) -> String?
    func saveSecret(_ secret: String, for connectionID: String) throws
    func deleteSecret(for connectionID: String) throws
}

public final class ProviderSecretStore: ProviderSecretStoring, @unchecked Sendable {
    public let service: String
    #if !canImport(Security)
    private let lock = NSLock()
    private var memory: [String: String] = [:]
    #endif

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    private func account(for connectionID: String) -> String {
        "provider-secret-\(ProviderConnection.sanitizeID(connectionID))"
    }

    public func loadSecret(for connectionID: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: connectionID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        lock.lock()
        defer { lock.unlock() }
        return memory[connectionID]
        #endif
    }

    public func saveSecret(_ secret: String, for connectionID: String) throws {
        let trimmed = secret
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteSecret(for: connectionID)
            return
        }
        #if canImport(Security)
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: connectionID),
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
        #else
        lock.lock()
        defer { lock.unlock() }
        memory[connectionID] = trimmed
        #endif
    }

    public func deleteSecret(for connectionID: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: connectionID),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
        #else
        lock.lock()
        defer { lock.unlock() }
        memory.removeValue(forKey: connectionID)
        #endif
    }
}

public final class InMemoryProviderSecretStore: ProviderSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    public init(initial: [String: String] = [:]) {
        self.secrets = initial
    }

    public func loadSecret(for connectionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[connectionID]
    }

    public func saveSecret(_ secret: String, for connectionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if secret.isEmpty {
            secrets.removeValue(forKey: connectionID)
        } else {
            secrets[connectionID] = secret
        }
    }

    public func deleteSecret(for connectionID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: connectionID)
    }
}
