import HueCore
import SwiftUI

/// Settings: Demo Mode banner, App Skins, Menu Bar Icons, Appearance & Personalization,
/// Schedule Execution Mode, Global Keyboard Shortcuts, General (Launch at Login, Confirm All On),
/// Language, Bridge info + Unpair, and Quit.
struct SettingsView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    store.page = .main
                } label: {
                    Label(store.tr("Back"), systemImage: "chevron.left")
                        .font(store.scaledFont(12.5))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(store.tr("Settings").uppercased())
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.snapshot.isDemo {
                        SettingsSection(
                            title: store.tr("Demo Mode"),
                            description: store.tr("You are exploring an interactive simulated Hue home. Exit to connect a real Philips Hue bridge.")
                        ) {
                            Button {
                                store.exitDemoMode()
                            } label: {
                                Label(store.tr("Exit Demo Mode"), systemImage: "xmark.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    SettingsSection(
                        title: store.tr("App Skin"),
                        description: skinDescription(store.skin)
                    ) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8),
                            ],
                            spacing: 8
                        ) {
                            ForEach(AppSkin.allCases) { skin in
                                let selected = store.skin == skin
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        store.setSkin(skin)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color(hex: skin.previewBackgroundHex))
                                            HStack(spacing: 3) {
                                                Circle()
                                                    .fill(Color(hex: skin.accentHex ?? "#0a84ff"))
                                                    .frame(width: 7, height: 7)
                                                Circle()
                                                    .fill(Color(hex: skin.secondaryHex))
                                                    .frame(width: 7, height: 7)
                                            }
                                        }
                                        .frame(width: 28, height: 22)
                                        Text(skinTitle(skin))
                                            .font(store.scaledFont(11.5, weight: selected ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(7)
                                    .background(
                                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                            .fill(selected ? store.skinAccentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                            .strokeBorder(selected ? store.skinAccentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    SettingsSection(
                        title: store.tr("Menu Bar Icon"),
                        description: store.tr("Pick the icon shown in your macOS menu bar and optionally display the number of lit lights beside it.")
                    ) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(MenuBarIconStyle.allCases) { style in
                                let selected = store.menuBarIcon == style
                                Button {
                                    store.setMenuBarIcon(style)
                                } label: {
                                    VStack(spacing: 3) {
                                        Image(systemName: style.onSymbol)
                                            .font(.system(size: 14))
                                        Text(iconTitle(style))
                                            .font(store.scaledFont(9.5))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .background(
                                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                            .fill(selected ? store.skinAccentColor : Color.primary.opacity(0.06))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Toggle(store.tr("Show lit light count in menu bar"), isOn: Binding(
                            get: { store.showMenuBarCount },
                            set: { store.setShowMenuBarCount($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(store.scaledFont(12))
                    }

                    SettingsSection(
                        title: store.tr("Appearance"),
                        description: store.tr("Customize corner roundness, window backdrop, typeface, and text size across the whole app.")
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            settingRow(
                                label: store.tr("Rounded corners"),
                                caption: store.tr("Controls how sharp or rounded cards and panels appear.")
                            ) {
                                Picker(store.tr("Rounded corners"), selection: Binding(
                                    get: { store.appearance.cornerStyle },
                                    set: { store.setCornerStyle($0) }
                                )) {
                                    Text(store.tr("Sharp")).tag(CornerStyle.sharp)
                                    Text(store.tr("Subtle")).tag(CornerStyle.subtle)
                                    Text(store.tr("Rounded")).tag(CornerStyle.rounded)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }

                            Divider()

                            settingRow(
                                label: store.tr("Background style"),
                                caption: store.tr("Choose the window color tone or follow your Mac's light and dark appearance.")
                            ) {
                                Picker(store.tr("Background style"), selection: Binding(
                                    get: { store.appearance.backgroundStyle },
                                    set: { store.setBackgroundStyle($0) }
                                )) {
                                    Text(store.tr("System")).tag(HueCore.BackgroundStyle.system)
                                    Text(store.tr("Tinted")).tag(HueCore.BackgroundStyle.tinted)
                                    Text(store.tr("Dark")).tag(HueCore.BackgroundStyle.dark)
                                    Text(store.tr("Light")).tag(HueCore.BackgroundStyle.light)
                                    Text(store.tr("Warm")).tag(HueCore.BackgroundStyle.warm)
                                    Text(store.tr("Midnight")).tag(HueCore.BackgroundStyle.midnight)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }

                            Divider()

                            settingRow(
                                label: store.tr("Font family"),
                                caption: store.tr("Switch between standard macOS typography, rounded, serif, or monospaced lettering.")
                            ) {
                                Picker(store.tr("Font family"), selection: Binding(
                                    get: { store.appearance.fontFamily },
                                    set: { store.setFontFamily($0) }
                                )) {
                                    Text(store.tr("System")).tag(FontFamily.system)
                                    Text(store.tr("Rounded")).tag(FontFamily.rounded)
                                    Text(store.tr("Serif")).tag(FontFamily.serif)
                                    Text(store.tr("Mono")).tag(FontFamily.mono)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }

                            Divider()

                            settingRow(
                                label: store.tr("Font size"),
                                caption: store.tr("Scale labels and captions for compact density or easier reading.")
                            ) {
                                Picker(store.tr("Font size"), selection: Binding(
                                    get: { store.appearance.fontSize },
                                    set: { store.setFontSize($0) }
                                )) {
                                    Text(store.tr("Small")).tag(FontSizeScale.small)
                                    Text(store.tr("Medium")).tag(FontSizeScale.medium)
                                    Text(store.tr("Large")).tag(FontSizeScale.large)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        }
                    }

                    SettingsSection(
                        title: store.tr("Schedule execution"),
                        description: store.scheduleMode == .bridge
                            ? store.tr("On Hue Bridge — runs 24/7 even while your Mac sleeps.")
                            : store.tr("On this Mac (live) — runs while Maprisma Lights is open in the menu bar; works with all lights and local actions.")
                    ) {
                        Picker(store.tr("Schedule execution"), selection: Binding(
                            get: { store.scheduleMode },
                            set: { store.setScheduleMode($0) }
                        )) {
                            Text(store.tr("On Hue Bridge")).tag(ScheduleMode.bridge)
                            Text(store.tr("On this Mac (live)")).tag(ScheduleMode.local)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    SettingsSection(
                        title: store.tr("Global Shortcuts"),
                        description: store.tr("Trigger Hue actions from any macOS app using system-wide hotkeys. No Accessibility permissions required.")
                    ) {
                        VStack(spacing: 8) {
                            hotKeyRow(.allOff, label: store.tr("All lights off"))
                            hotKeyRow(.allOn, label: store.tr("All lights on"))
                            hotKeyRow(.toggleSynth, label: store.tr("Toggle Light Synthesizer"))
                            hotKeyRow(.toggleFavorite, label: store.tr("Toggle Favorite / First Room"))
                        }
                    }

                    SettingsSection(
                        title: store.tr("General"),
                        description: store.tr("Startup behavior and safety confirmation for master light controls.")
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { store.launchAtLogin },
                                set: { store.setLaunchAtLogin($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.tr("Launch at Login"))
                                        .font(store.scaledFont(12.5, weight: .medium))
                                    Text(store.tr("Start Maprisma Lights automatically in the menu bar when you sign in to macOS."))
                                        .font(store.scaledFont(11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            if let err = store.launchAtLoginError {
                                Text(err)
                                    .font(store.scaledFont(10.5))
                                    .foregroundStyle(Color.red)
                            }

                            Divider()

                            Toggle(isOn: Binding(
                                get: { store.confirmAllOn },
                                set: { store.setConfirmAllOn($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.tr("Confirm before All On"))
                                        .font(store.scaledFont(12.5, weight: .medium))
                                    Text(store.tr("Ask for confirmation before switching every non-excluded room on at once."))
                                        .font(store.scaledFont(11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }

                    SettingsSection(
                        title: store.tr("Language"),
                        description: store.tr("Choose one of the 8 built-in interface languages or follow your macOS system language.")
                    ) {
                        Picker(store.tr("Language"), selection: Binding(
                            get: { store.languageSetting },
                            set: { store.setLanguage($0) }
                        )) {
                            Text(store.trf("System ({0})", [store.l10n.systemName])).tag("auto")
                            Divider()
                            ForEach(L10n.languages) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if store.languageError {
                            Text(store.tr("Could not save language setting."))
                                .font(store.scaledFont(11))
                                .foregroundStyle(Color.red)
                        }
                    }

                    SettingsSection(
                        title: store.tr("Bridge"),
                        description: store.tr("Connected Philips Hue Bridge on your local network. Credentials are stored securely in your macOS Keychain.")
                    ) {
                        bridge
                    }

                    Text(store.tr("Independent third-party app. Not affiliated with or endorsed by Signify Holding / Philips Hue."))
                        .font(store.scaledFont(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    store.quit()
                } label: {
                    Label(store.tr("Quit Maprisma Lights"), systemImage: "power")
                        .font(store.scaledFont(12))
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func hotKeyRow(_ action: HotKeyAction, label: String) -> some View {
        HStack {
            Text(label)
                .font(store.scaledFont(12))
                .lineLimit(1)
            Spacer()
            Picker(label, selection: Binding(
                get: { store.hotKeyPreset(for: action) },
                set: { store.setHotKey($0, for: action) }
            )) {
                ForEach(HotKeyPreset.allCases) { preset in
                    Text(preset == .none ? store.tr("Off") : preset.displayLabel).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private func skinTitle(_ skin: AppSkin) -> String {
        switch skin {
        case .system: return store.tr("System Native")
        case .synthwave: return store.tr("Neon Synthwave")
        case .cozyCabin: return store.tr("Cozy Cabin")
        case .retroTerminal: return store.tr("Retro Terminal")
        case .discoLava: return store.tr("Disco Lava")
        case .minimalZen: return store.tr("Minimal Zen")
        }
    }

    private func skinDescription(_ skin: AppSkin) -> String {
        switch skin {
        case .system: return store.tr("Clean native macOS look that adapts automatically to light and dark mode.")
        case .synthwave: return store.tr("Deep violet-black backdrop with electric magenta and cyan synthwave accents.")
        case .cozyCabin: return store.tr("Warm espresso surfaces, candlelight gold accents, and classic serif lettering.")
        case .retroTerminal: return store.tr("Phosphor green highlights on charcoal with crisp sharp corners and monospace text.")
        case .discoLava: return store.tr("Playful purple-coral gradient backdrop with vibrant bubbly rounded cards.")
        case .minimalZen: return store.tr("Calm, ultra-clean matte slate palette with subtle low-contrast surfaces.")
        }
    }

    private func iconTitle(_ style: MenuBarIconStyle) -> String {
        switch style {
        case .bulb: return store.tr("Bulb")
        case .deskLamp: return store.tr("Desk")
        case .tableLamp: return store.tr("Table")
        case .sun: return store.tr("Sun")
        case .sparkles: return store.tr("Sparkles")
        case .flame: return store.tr("Flame")
        case .star: return store.tr("Star")
        case .dot: return store.tr("Dot")
        }
    }

    private func settingRow<Control: View>(
        label: String,
        caption: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(store.scaledFont(12, weight: .medium))
            control()
            Text(caption)
                .font(store.scaledFont(10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var bridge: some View {
        let s = store.snapshot
        if s.isPaired, let info = s.bridge {
            HStack(spacing: 10) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 18))
                    .foregroundStyle(store.skinAccentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name.isEmpty ? "Hue Bridge" : info.name)
                        .font(store.scaledFont(12.5, weight: .medium))
                    Text(info.model.isEmpty ? info.ip : "\(info.ip) · \(info.model)")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !s.isDemo {
                Text(store.tr("Forget this bridge and its app key on this Mac"))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.confirmUnpair {
                    HStack {
                        Button(store.tr("Cancel")) { store.confirmUnpair = false }
                        Spacer()
                        Button(store.tr("Really unpair?"), role: .destructive) { store.unpair() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.red)
                    }
                } else {
                    Button(store.tr("Unpair")) { store.confirmUnpair = true }
                }
            }
        } else {
            Text(store.tr("No bridge paired"))
                .font(store.scaledFont(12))
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSection<Content: View>: View {
    @EnvironmentObject var store: HueStore
    let title: String
    var description: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(store.scaledFont(10, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            if !description.isEmpty {
                Text(description)
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}
