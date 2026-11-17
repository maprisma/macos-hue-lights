import AppKit
import HueCore
import SwiftUI

/// Maprisma Hue Lights for macOS: a menu bar bulb (lit while any light is on, outlined when all are
/// off or no bridge is paired) that opens a ~430×600 pt window with pairing, rooms, zones, lights,
/// scenes and settings. No Dock icon (LSUIElement in Info.plist, accessory policy here as well).
@main
struct MaprismaHueLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = HueStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            MenuBarIcon(lit: store.snapshot.anyLightOn, summary: store.l10n.summary(store.snapshot))
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let lit: Bool
    let summary: String

    var body: some View {
        Image(systemName: lit ? "lightbulb.fill" : "lightbulb")
            .accessibilityLabel(Text("Maprisma Hue Lights: \(summary)"))
            .help(summary)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // SIGTERM (logout, `kill`, launchd) quits like the Quit button, so the helper is ended too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        source.resume()
        termination = source
        HueStore.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HueStore.shared.shutdown()
    }
}
