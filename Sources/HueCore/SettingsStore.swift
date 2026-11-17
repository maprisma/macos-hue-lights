import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SettingsError: Error {
    case unknownLanguage
    /// ~/.config/hue-lights is not a real folder of this user.
    case notPrivate
    case writeFailed
}

/// Interface preferences of the macOS app (just the language for now), in
/// ~/.config/hue-lights/settings.json beside the helper's 0600 config.json. The folder is
/// created 0700 (the helper insists on that too); the file is written atomically as 0600.
/// Unpairing deletes only config.json, so the language survives it.
public struct SettingsStore {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("settings.json") }

    public init(directory: URL = SettingsStore.defaultDirectory()) {
        self.directory = directory
    }

    /// $XDG_CONFIG_HOME/hue-lights when that is absolute (as the helper reads it), else
    /// ~/.config/hue-lights.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg).appendingPathComponent("hue-lights")
        }
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config").appendingPathComponent("hue-lights")
    }

    public func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: file), data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// "auto" unless a known language code is saved.
    public func language() -> String {
        let saved = read()["language"] as? String ?? "auto"
        return saved == "auto" || L10n.languages.contains { $0.code == saved } ? saved : "auto"
    }

    public func setLanguage(_ code: String) throws {
        guard code == "auto" || L10n.languages.contains(where: { $0.code == code }) else {
            throw SettingsError.unknownLanguage
        }
        var settings = read()
        settings["language"] = code
        try write(settings)
    }

    public func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw SettingsError.notPrivate
        }
        if info.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let temp = directory.appendingPathComponent(".settings.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SettingsError.writeFailed
        }
        if rename(temp.path, file.path) != 0 {
            try? fm.removeItem(at: temp)
            throw SettingsError.writeFailed
        }
    }
}
