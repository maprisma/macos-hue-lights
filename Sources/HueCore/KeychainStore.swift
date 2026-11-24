import Foundation
#if canImport(Security)
import Security
#endif

/// Credentials & TLS pin for a paired Philips Hue Bridge.
public struct BridgeCredentials: Codable, Equatable, Sendable {
    public var ip: String
    public var bridgeID: String
    public var fingerprint: String
    public var appKey: String
    public var clientKey: String
    public var name: String
    public var model: String

    public init(
        ip: String,
        bridgeID: String,
        fingerprint: String,
        appKey: String,
        clientKey: String = "",
        name: String,
        model: String
    ) {
        self.ip = ip
        self.bridgeID = bridgeID
        self.fingerprint = fingerprint
        self.appKey = appKey
        self.clientKey = clientKey
        self.name = name
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decode(String.self, forKey: .ip)
        bridgeID = try c.decode(String.self, forKey: .bridgeID)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        appKey = try c.decode(String.self, forKey: .appKey)
        clientKey = try c.decodeIfPresent(String.self, forKey: .clientKey) ?? ""
        name = try c.decode(String.self, forKey: .name)
        model = try c.decode(String.self, forKey: .model)
    }
}

public enum KeychainError: Error, Equatable {
    case encodingFailed
    case osStatus(Int32)
}

public protocol KeychainStoring: Sendable {
    func load() -> BridgeCredentials?
    func save(_ credentials: BridgeCredentials) throws
    func delete() throws
}

/// Stores bridge credentials (app key, bridge ID, certificate SHA-256 fingerprint, IP) in the
/// macOS Keychain (`kSecClassGenericPassword`). Falls back to an in-memory store on non-Darwin platforms.
public final class KeychainStore: KeychainStoring, @unchecked Sendable {
    public static let defaultService = "com.maprisma.lights"
    public static let defaultAccount = "bridge-credentials"

    public let service: String
    public let account: String

    #if !canImport(Security)
    private let lock = NSLock()
    private var memoryValue: BridgeCredentials?
    #endif

    public init(service: String = KeychainStore.defaultService, account: String = KeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    public func load() -> BridgeCredentials? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BridgeCredentials.self, from: data)
        #else
        lock.lock()
        defer { lock.unlock() }
        return memoryValue
        #endif
    }

    public func save(_ credentials: BridgeCredentials) throws {
        #if canImport(Security)
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw KeychainError.encodingFailed
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
        memoryValue = credentials
        #endif
    }

    public func delete() throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
        #else
        lock.lock()
        defer { lock.unlock() }
        memoryValue = nil
        #endif
    }
}

/// Deterministic in-memory credential store for unit tests.
public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BridgeCredentials?

    public init(initial: BridgeCredentials? = nil) {
        self.stored = initial
    }

    public func load() -> BridgeCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func save(_ credentials: BridgeCredentials) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = credentials
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
