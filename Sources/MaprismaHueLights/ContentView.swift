import AppKit
import HueCore
import SwiftUI

/// The menu bar window: header, then pairing, rooms or settings, then the action row.
struct ContentView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            Group {
                switch store.page {
                case .settings:
                    SettingsView()
                case .main:
                    MainView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 430, height: 600)
        .background(WindowObserver { open in store.setPanel(open: open) })
        .onAppear { store.setPanel(open: true) }
        .onDisappear { store.setPanel(open: false) }
    }
}

struct HeaderView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let s = store.snapshot
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(s.anyLightOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                Image(systemName: s.anyLightOn ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(s.anyLightOn ? Color.accentColor : Color.secondary)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.tr("Maprisma Hue Lights"))
                    .font(.headline)
                Text(s.isPaired ? (s.bridge?.text ?? "Hue Bridge") : store.tr("No bridge paired"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if s.phase == "ok" {
                Text(store.trf("{0} of {1} on", [String(s.onCount), String(s.lightCount)]))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Button {
                store.page = store.page == .settings ? .main : .settings
            } label: {
                Image(systemName: store.page == .settings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(store.tr("Settings"))
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                ProblemBanner(text: problem)
            }
            if store.snapshot.isPaired {
                RoomsView()
                Divider()
                FooterView()
            } else {
                ScrollView {
                    PairingView()
                        .padding(16)
                }
            }
        }
    }
}

struct ProblemBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

struct FooterView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.allOff()
            } label: {
                Label(store.tr("All lights off"), systemImage: "power")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.red)
            .disabled(!store.snapshot.anyLightOn)
            .help(store.tr("Switch every light off"))
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(store.tr("Refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Tells the store when the menu bar window becomes key (shown) or resigns key (closed), which is
/// more reliable for MenuBarExtra windows than onAppear/onDisappear alone.
struct WindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private weak var observed: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let old = observed {
                center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: old)
                center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
            }
            observed = window
            guard let window = window else { return }
            center.addObserver(self, selector: #selector(becameKey(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(resignedKey(_:)),
                               name: NSWindow.didResignKeyNotification, object: window)
            if window.isKeyWindow {
                Task { @MainActor [weak self] in self?.onChange?(true) }
            }
        }

        @objc private func becameKey(_ note: Notification) { onChange?(true) }
        @objc private func resignedKey(_ note: Notification) { onChange?(false) }
    }
}

extension Color {
    /// "#rrggbb" from the bridge; anything else is the helper's warm white.
    init(hex: String) {
        let c = rgb(hex)
        self.init(red: c.r, green: c.g, blue: c.b)
    }
}
