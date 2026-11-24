import AppKit
import Dispatch
import Foundation
import HueCore
import SwiftUI

/// Entrypoint that cleanly branches into the headless `--mcp` stdio JSON-RPC 2.0 server
/// BEFORE SwiftUI / `NSApplication` starts, so AI agent invocations never open a window or steal focus.
@main
enum MaprismaHueLightsEntrypoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            let demo = CommandLine.arguments.contains("--demo")
            Task { @MainActor in
                await HueMCPServer.runStdio(demo: demo)
                Foundation.exit(0)
            }
            dispatchMain()
        } else {
            MaprismaHueLightsApp.main()
        }
    }
}

/// Maprisma Hue Lights for macOS: a 100% pure-Swift, App Sandbox-compliant menu bar app
/// with an optional detachable resizable window, Light Synthesizer, Light Themes, App Skins,
/// global hotkeys, optional local-first Ask AI, native `--mcp` server, and Apple Shortcuts (`AppIntents`).
struct MaprismaHueLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = HueStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(mode: .popover)
                .environmentObject(store)
        } label: {
            MenuBarIcon(
                style: store.menuBarIcon,
                lit: store.snapshot.anyLightOn,
                onCount: store.snapshot.onCount,
                showCount: store.showMenuBarCount,
                synthRunning: store.synthRunning,
                summary: store.l10n.summary(store.snapshot)
            )
        }
        .menuBarExtraStyle(.window)

        Window("Maprisma Lights", id: "main-window") {
            ContentView(mode: .detached)
                .environmentObject(store)
        }
        .defaultSize(width: 760, height: 640)
    }
}

struct MenuBarIcon: View {
    let style: MenuBarIconStyle
    let lit: Bool
    let onCount: Int
    let showCount: Bool
    let synthRunning: Bool
    let summary: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: style == .bulb ? (lit ? "lightbulb.fill" : "lightbulb") : style.symbol(lit: lit))
            if synthRunning {
                Image(systemName: "waveform")
            }
            if showCount && onCount > 0 {
                Text("\(onCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(Text("Maprisma Lights: \(summary)"))
        .help(summary)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        source.resume()
        termination = source

        registerDesktopEventObservers()
        HueStore.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { ws.removeObserver(token) }
        workspaceObservers.removeAll()

        let dist = DistributedNotificationCenter.default()
        for token in distributedObservers { dist.removeObserver(token) }
        distributedObservers.removeAll()

        HueStore.shared.shutdown()
    }

    private func registerDesktopEventObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in HueStore.shared.handleDesktopEvent("wake") }
            }
        )
        workspaceObservers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in HueStore.shared.handleDesktopEvent("sleep") }
            }
        )

        let dist = DistributedNotificationCenter.default()
        distributedObservers.append(
            dist.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                Task { @MainActor in HueStore.shared.handleDesktopEvent("wake") }
            }
        )
        distributedObservers.append(
            dist.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                Task { @MainActor in HueStore.shared.handleDesktopEvent("sleep") }
            }
        )
    }
}
