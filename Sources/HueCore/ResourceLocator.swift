import Foundation

/// Locates bundled app resources (such as `translations/bundled.json`) inside the `.app` bundle
/// or, during development (`swift run` / `swift test`), relative to the working directory or executable.
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
