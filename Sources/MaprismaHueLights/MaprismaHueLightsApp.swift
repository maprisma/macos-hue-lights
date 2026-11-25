import AppKit
import Carbon
import Combine
import Dispatch
import Foundation
import HueCore
import SwiftUI

/// Entrypoint that cleanly branches into the headless `--mcp` stdio JSON-RPC 2.0 server
/// BEFORE SwiftUI / `NSApplication` starts, so AI agent invocations never open a window or steal focus.
/// Both `--demo --mcp` and local `--mcp` are free to use (never gated on StoreKit).
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

/// Maprisma Lights for macOS: a 100% pure-Swift, App Sandbox-compliant native macOS window app
/// (freely movable, resizable, and compatible with tiling window managers) with a menu bar
/// quick-toggle icon, Floorplan Studio v2, Light Synthesizer, Light Themes, App Skins, global
/// hotkeys, optional local-first Ask AI, native `--mcp` server, and Apple Shortcuts (`AppIntents`).
struct MaprismaHueLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = HueStore.shared

    var body: some Scene {
        Window("Maprisma Lights", id: "main-window") {
            ContentView(mode: .detached)
                .environmentObject(store)
        }
        .defaultSize(width: 840, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(store.tr("Settings")) {
                    appDelegate.showMainWindow()
                    store.page = store.page == .settings ? .main : .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(store.tr("Help & Guide")) {
                    appDelegate.showMainWindow()
                    store.page = .help
                }
            }
            CommandMenu(store.tr("Lights")) {
                Button(store.tr("Refresh")) {
                    store.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(store.tr("Lights")) {
                    appDelegate.showMainWindow()
                    store.page = .main
                    store.tab = .lights
                }
                .keyboardShortcut("1", modifiers: .command)

                Button(store.tr("Map")) {
                    appDelegate.showMainWindow()
                    store.page = .main
                    store.tab = .map
                }
                .keyboardShortcut("2", modifiers: .command)

                Button(store.tr("Schedules")) {
                    appDelegate.showMainWindow()
                    store.page = .main
                    store.tab = .schedules
                }
                .keyboardShortcut("3", modifiers: .command)

                Button(store.tr("Rules")) {
                    appDelegate.showMainWindow()
                    store.page = .main
                    store.tab = .rules
                }
                .keyboardShortcut("4", modifiers: .command)

                Button(store.tr("Synth")) {
                    appDelegate.showMainWindow()
                    store.page = .main
                    store.tab = .synth
                }
                .keyboardShortcut("5", modifiers: .command)

                Divider()

                Button(store.tr("All lights on")) {
                    store.allOn(confirmed: true)
                }
                .disabled(store.snapshot.lightCount == 0)

                Button(store.tr("All lights off")) {
                    store.allOff()
                }
                .disabled(!store.snapshot.anyLightOn)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var openMainWindowAction: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private var termination: DispatchSourceSignal?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
        source.resume()
        termination = source

        registerDesktopEventObservers()
        setupStatusBarItem()
        HueStore.shared.start()

        let launchedAtLogin = Self.isLaunchedAsLoginItem()
        DispatchQueue.main.async { [weak self] in
            if launchedAtLogin {
                self?.existingMainWindow()?.orderOut(nil)
            } else {
                self?.showMainWindow()
            }
        }
    }

    private static func isLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == DescType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
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

    // MARK: - Main Window Control

    private func existingMainWindow() -> NSWindow? {
        NSApp.windows.first { win in
            win.identifier?.rawValue.hasPrefix("main-window") == true || win.title == "Maprisma Lights"
        }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = existingMainWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    func toggleMainWindow() {
        if let window = existingMainWindow(), window.isVisible && !window.isMiniaturized && NSApp.isActive {
            window.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    // MARK: - Menu Bar Status Item (Left-Click Toggle, Right-Click Quick Menu)

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let store = HueStore.shared
        store.$snapshot
            .combineLatest(store.$menuBarIcon, store.$showMenuBarCount, store.$synthRunning)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshStatusBarAppearance()
            }
            .store(in: &cancellables)
        refreshStatusBarAppearance()
    }

    private func refreshStatusBarAppearance() {
        guard let button = statusItem?.button else { return }
        let store = HueStore.shared
        let lit = store.snapshot.anyLightOn
        let style = store.menuBarIcon
        let symbolName = style == .bulb ? (lit ? "lightbulb.fill" : "lightbulb") : style.symbol(lit: lit)
        let summary = store.l10n.summary(store.snapshot)

        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Maprisma Lights: \(summary)") {
            img.isTemplate = true
            button.image = img
        }
        button.imagePosition = .imageLeading

        var parts: [String] = []
        if store.synthRunning { parts.append("♫") }
        if store.showMenuBarCount && store.snapshot.onCount > 0 {
            parts.append("\(store.snapshot.onCount)")
        }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        button.toolTip = "Maprisma Lights — \(summary)"
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            presentStatusContextMenu(from: sender)
        } else {
            toggleMainWindow()
        }
    }

    private func presentStatusContextMenu(from button: NSStatusBarButton) {
        let store = HueStore.shared
        let menu = NSMenu()
        let showTitle = (existingMainWindow()?.isVisible == true && NSApp.isActive)
            ? store.tr("Close")
            : store.tr("Open in window")
        let showItem = NSMenuItem(title: showTitle, action: #selector(menuToggleWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: store.tr("Settings"), action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if store.isDemoMode {
            let exitDemoItem = NSMenuItem(title: store.tr("Connect Bridge"), action: #selector(menuExitDemo), keyEquivalent: "")
            exitDemoItem.target = self
            menu.addItem(exitDemoItem)
        } else if !store.snapshot.isPaired {
            let demoItem = NSMenuItem(title: store.tr("Try Demo Home"), action: #selector(menuEnterDemo), keyEquivalent: "")
            demoItem.target = self
            menu.addItem(demoItem)
        }

        menu.addItem(.separator())

        let allOnItem = NSMenuItem(title: store.tr("All lights on"), action: #selector(menuAllOn), keyEquivalent: "")
        allOnItem.target = self
        allOnItem.isEnabled = store.snapshot.lightCount > 0
        menu.addItem(allOnItem)

        let allOffItem = NSMenuItem(title: store.tr("All lights off"), action: #selector(menuAllOff), keyEquivalent: "")
        allOffItem.target = self
        allOffItem.isEnabled = store.snapshot.anyLightOn
        menu.addItem(allOffItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: store.tr("Quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuToggleWindow() { toggleMainWindow() }
    @objc private func menuOpenSettings() {
        showMainWindow()
        HueStore.shared.page = .settings
    }
    @objc private func menuEnterDemo() {
        showMainWindow()
        HueStore.shared.enterDemoMode()
    }
    @objc private func menuExitDemo() {
        showMainWindow()
        HueStore.shared.exitDemoMode()
    }
    @objc private func menuAllOn() { HueStore.shared.allOn(confirmed: true) }
    @objc private func menuAllOff() { HueStore.shared.allOff() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Desktop Wake / Sleep / Lock Observers

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
