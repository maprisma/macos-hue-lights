import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs scripts/hue-lights.py as `/usr/bin/env python3 -I <script>` (PATH with Homebrew first),
/// streams its JSON snapshot lines from stdout on a background thread, writes JSON commands to its
/// stdin, and starts it again `restartDelay` seconds after it exits. `stop()` closes stdin (the
/// helper exits on EOF), then sends SIGTERM and finally SIGKILL, so no helper outlives the app.
///
/// All state lives on one serial queue; callbacks arrive on `callbackQueue` (main by default).
public final class HelperSupervisor {
    public enum Status: Equatable {
        case starting
        case running
        /// The helper exited; a new one starts after the restart delay.
        case restarting
        /// `/usr/bin/env python3` could not run it (no python3 on PATH, or the macOS stub that
        /// asks for the Command Line Tools) and it never printed a snapshot.
        case pythonMissing
        case scriptMissing
        case stopped
    }

    public static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public var onSnapshot: ((HueSnapshot) -> Void)?
    public var onStatus: ((Status) -> Void)?
    /// A new helper is up: the app re-sends what the helper must know (popover open).
    public var onStarted: (() -> Void)?

    public let scriptURL: URL?
    public let launcher: URL
    public let python: String
    public let restartDelay: TimeInterval
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "io.github.ubruckhaus.MaprismaHueLights.helper")

    private var process: Process?
    private var stdin: FileHandle?
    private var generation = 0
    private var stopping = false
    private var sawOutput = false
    private var launchedAt = Date()
    private var restartScheduled = false

    public init(scriptURL: URL?, launcher: URL = URL(fileURLWithPath: "/usr/bin/env"), python: String = "python3",
                restartDelay: TimeInterval = 5, callbackQueue: DispatchQueue = .main) {
        self.scriptURL = scriptURL
        self.launcher = launcher
        self.python = python
        self.restartDelay = restartDelay
        self.callbackQueue = callbackQueue
        // A write to a helper that just died must be an error, not a SIGPIPE that ends the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// PATH with Homebrew (Apple silicon, Intel) and the system folders first, the rest of the
    /// inherited PATH after them, each folder once. Apps started from Finder get a minimal PATH.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var seen = Set<String>()
        let parts = (searchPath + ":" + (base["PATH"] ?? "")).split(separator: ":").map(String.init)
        env["PATH"] = parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env
    }

    public var arguments: [String] {
        [python, "-I", scriptURL?.path ?? ""]
    }

    public func start() {
        queue.async {
            self.stopping = false
            if self.process == nil { self.launch() }
        }
    }

    public func send(_ command: HueCommand) {
        let data = Data((command.line + "\n").utf8)
        queue.async {
            guard let handle = self.stdin else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Broken pipe: the termination handler restarts the helper.
            }
        }
    }

    public var isRunning: Bool { queue.sync { process?.isRunning ?? false } }

    /// Ends the helper and waits up to `timeout` (+0.5 s after SIGTERM) for it; no restart.
    public func stop(timeout: TimeInterval = 1.5) {
        let child: Process? = queue.sync {
            stopping = true
            generation += 1
            try? stdin?.close()
            stdin = nil
            let p = process
            process = nil
            return p
        }
        report(.stopped)
        guard let child = child else { return }
        if wait(child, timeout) { return }
        child.terminate()
        if wait(child, 0.5) { return }
        kill(child.processIdentifier, SIGKILL)
        _ = wait(child, 0.5)
    }

    private func wait(_ process: Process, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        return !process.isRunning
    }

    // MARK: - on `queue`

    private func launch() {
        restartScheduled = false
        guard !stopping else { return }
        guard let script = scriptURL, FileManager.default.isReadableFile(atPath: script.path) else {
            report(.scriptMissing)
            scheduleRestart()
            return
        }
        report(.starting)
        generation += 1
        let current = generation
        sawOutput = false
        launchedAt = Date()

        let child = Process()
        child.executableURL = launcher
        child.arguments = arguments
        child.environment = HelperSupervisor.environment()
        child.currentDirectoryURL = script.deletingLastPathComponent()
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.queue.async { self.exited(current) }
        }
        do {
            try child.run()
        } catch {
            report(.pythonMissing)
            scheduleRestart()
            return
        }
        process = child
        stdin = input.fileHandleForWriting
        report(.running)
        let reader = output.fileHandleForReading
        let thread = Thread { [weak self] in self?.read(reader, current) }
        thread.name = "hue-lights helper stdout"
        thread.start()
        callbackQueue.async { self.onStarted?() }
    }

    private func exited(_ which: Int) {
        guard which == generation, !stopping else { return }
        try? stdin?.close()
        stdin = nil
        process = nil
        // No snapshot and gone within seconds: python3 itself did not run.
        let ranLong = Date().timeIntervalSince(launchedAt) > 3
        report(sawOutput || ranLong ? .restarting : .pythonMissing)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopping, !restartScheduled else { return }
        restartScheduled = true
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in
            guard let self = self, self.process == nil else { return }
            self.launch()
        }
    }

    private func report(_ status: Status) {
        callbackQueue.async { self.onStatus?(status) }
    }

    // MARK: - reader thread

    private func read(_ handle: FileHandle, _ which: Int) {
        var buffer = LineBuffer()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // EOF: the helper closed stdout or exited
            for line in buffer.append(chunk) {
                guard let snapshot = HueSnapshot.parse(line: line) else { continue }
                queue.async {
                    guard which == self.generation else { return }
                    self.sawOutput = true
                    self.callbackQueue.async { self.onSnapshot?(snapshot) }
                }
            }
        }
        try? handle.close()
    }
}

/// Splits a byte stream into "\n"-terminated UTF-8 lines; an unfinished line waits for more. A line
/// over `limit` bytes (no helper snapshot is that big) is dropped instead of growing forever.
public struct LineBuffer {
    private var pending = Data()
    public let limit: Int

    public init(limit: Int = 16 * 1024 * 1024) { self.limit = limit }

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty { lines.append(text) }
        }
        if pending.count > limit { pending.removeAll() }
        return lines
    }
}
