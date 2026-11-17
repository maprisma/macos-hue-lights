import Foundation

/// Where the helper script and the translation catalogs are: inside the .app
/// (Contents/Resources/scripts, Contents/Resources/translations), or - in dev mode, e.g. `swift run`
/// from the checkout - ./scripts and ./translations of the working directory or of a folder
/// above the executable (.build/<config>/MaprismaHueLights → the repository root).
public struct ResourceLocator {
    public let resourceURL: URL?
    public let executableURL: URL?
    public let currentDirectory: URL
    public let environment: [String: String]

    public init(resourceURL: URL? = Bundle.main.resourceURL,
                executableURL: URL? = Bundle.main.executableURL,
                currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.resourceURL = resourceURL
        self.executableURL = executableURL
        self.currentDirectory = currentDirectory
        self.environment = environment
    }

    public var helperScript: URL? {
        var extra: [URL] = []
        if let dir = environment["HUE_LIGHTS_SCRIPTS"], !dir.isEmpty {
            extra.append(URL(fileURLWithPath: dir).appendingPathComponent("hue-lights.py"))
        }
        return find(extra: extra, relative: "scripts/hue-lights.py")
    }

    public var translations: URL? {
        find(extra: [], relative: "translations/bundled.json")
    }

    public func candidates(relative: String) -> [URL] {
        var list: [URL] = []
        if let res = resourceURL { list.append(res.appendingPathComponent(relative)) }
        list.append(currentDirectory.appendingPathComponent(relative))
        if var dir = executableURL?.deletingLastPathComponent() {
            for _ in 0..<6 {
                list.append(dir.appendingPathComponent(relative))
                dir = dir.deletingLastPathComponent()
            }
        }
        return list
    }

    private func find(extra: [URL], relative: String) -> URL? {
        var isDir: ObjCBool = false
        return (extra + candidates(relative: relative)).first {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }
}
