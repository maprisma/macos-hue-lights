import HueCore
import SwiftUI

/// Settings: Demo Mode banner, App Skins, Menu Bar Icons, Appearance & Personalization,
/// Schedule Execution Mode, Global Keyboard Shortcuts, General (Launch at Login, Confirm All On),
/// Language, Bridge info + Unpair, and Quit.
struct SettingsView: View {
    @EnvironmentObject var store: HueStore
    @EnvironmentObject var proStore: ProStoreManager

    #if DEBUG
    private enum DebugProSimulation: Int, CaseIterable, Identifiable {
        case live = 0
        case simulateFree = 1
        case simulatePro = 2
        var id: Int { rawValue }
    }

    private var debugSimSelection: Binding<DebugProSimulation> {
        Binding(
            get: {
                switch proStore.debugOverridePro {
                case nil: return .live
                case false: return .simulateFree
                case true: return .simulatePro
                }
            },
            set: { newValue in
                switch newValue {
                case .live: proStore.debugOverridePro = nil
                case .simulateFree: proStore.debugOverridePro = false
                case .simulatePro: proStore.debugOverridePro = true
                }
            }
        )
    }
    #endif

    private var accessBadge: (text: String, symbol: String, color: Color) {
        switch proStore.accessMode(isDemoMode: store.isDemoMode) {
        case .pro:
            return (store.tr("Pro — Unlocked"), "checkmark.seal.fill", Color.green)
        case .demo:
            return (store.tr("Demo Mode (All Pro features preview)"), "play.circle.fill", store.skinAccentColor)
        case .free:
            return (store.tr("Free — Rooms & Lights"), "lightbulb.fill", Color.secondary)
        }
    }

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
                        title: store.tr("Pro / License"),
                        description: store.tr("One-time purchase · No subscription. Rooms, lights, scenes, schedules, and Demo Mode stay free forever.")
                    ) {
                        let badge = accessBadge
                        HStack(spacing: 7) {
                            Image(systemName: badge.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(badge.color)
                            Text(badge.text)
                                .font(store.scaledFont(12, weight: .semibold))
                                .foregroundStyle(badge.color == .secondary ? Color.primary : badge.color)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(badge.color.opacity(0.14))
                        )

                        HStack(spacing: 8) {
                            if !proStore.effectiveProUnlocked {
                                Button {
                                    store.showProUpgradeSheet = true
                                } label: {
                                    Label(store.tr("Unlock Pro…"), systemImage: "crown.fill")
                                        .font(store.scaledFont(12, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button {
                                Task { await proStore.restorePurchases() }
                            } label: {
                                Text(store.tr("Restore Purchases"))
                                    .font(store.scaledFont(12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(proStore.isPurchasing || proStore.isLoading)
                        }

                        if let status = proStore.statusMessage, !status.isEmpty {
                            Text(status)
                                .font(store.scaledFont(11, weight: .medium))
                                .foregroundStyle(proStore.effectiveProUnlocked ? Color.green : Color.secondary)
                        }
                        if let error = proStore.errorMessage, !error.isEmpty {
                            Text(error)
                                .font(store.scaledFont(11))
                                .foregroundStyle(Color.orange)
                        }

                        #if DEBUG
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.tr("Debug License Simulation"))
                                .font(store.scaledFont(11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Picker(store.tr("Debug License Simulation"), selection: debugSimSelection) {
                                Text(store.tr("StoreKit Live")).tag(DebugProSimulation.live)
                                Text(store.tr("Simulate Free")).tag(DebugProSimulation.simulateFree)
                                Text(store.tr("Simulate Pro")).tag(DebugProSimulation.simulatePro)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                        }
                        #endif
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
                                let skinLocked = !proStore.isSkinUnlocked(skin, isDemoMode: store.isDemoMode)
                                Button {
                                    if skinLocked {
                                        store.showProUpgradeSheet = true
                                    } else {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            store.setSkin(skin)
                                        }
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
                                        if skinLocked {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(7)
                                    .opacity(skinLocked ? 0.78 : 1.0)
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
                        title: store.tr("Ask AI"),
                        description: store.tr("Optional local-first assistant to switch lights, create rules, and schedule in plain language. Off by default — turn on anytime.")
                    ) {
                        let askAILocked = !proStore.isUnlocked(.askAI, isDemoMode: store.isDemoMode)
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { store.askAIEnabled && !askAILocked },
                                set: { enabled in
                                    if enabled && askAILocked {
                                        store.showProUpgradeSheet = true
                                    } else {
                                        store.setAskAIEnabled(enabled)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(store.tr("Enable Ask AI"))
                                            .font(store.scaledFont(12.5, weight: .medium))
                                        if askAILocked {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(store.tr("Shows the ✨ Ask AI button (⌘K) in the header. When off, Ask AI is completely hidden and inactive."))
                                        .font(store.scaledFont(11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            if store.askAIEnabled && !askAILocked {
                                Divider()

                                settingRow(
                                    label: store.tr("Local Ollama URL (optional)"),
                                    caption: store.tr("Loopback only (127.0.0.1 or localhost). Used only if the built-in offline parser finds no direct match.")
                                ) {
                                    TextField(
                                        AppSettings.defaultAskAIOllamaURL,
                                        text: Binding(
                                            get: { store.askAIOllamaURL },
                                            set: { store.setAskAIOllamaURL($0) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(store.scaledFont(11.5))
                                }

                                if !HueAskAIEngine.isValidLoopbackURL(store.askAIOllamaURL) {
                                    Text(store.tr("Only local loopback URLs (127.0.0.1 or localhost) are permitted."))
                                        .font(store.scaledFont(10.5))
                                        .foregroundStyle(Color.orange)
                                }

                                settingRow(
                                    label: store.tr("Local Ollama model (optional)"),
                                    caption: store.tr("Leave empty to use llama3.2 when Ollama is running locally.")
                                ) {
                                    TextField(
                                        "llama3.2",
                                        text: Binding(
                                            get: { store.askAIModel },
                                            set: { store.setAskAIModel($0) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(store.scaledFont(11.5))
                                }
                            }
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
                        title: store.tr("Bridges & Devices"),
                        description: store.tr("Connect a Philips Hue Bridge plus Home Assistant, WLED, WiZ, LIFX, Govee LAN, Nanoleaf, Shelly, or IKEA DIRIGERA on your local network. Tokens are stored securely in your macOS Keychain.")
                    ) {
                        bridge
                        if !store.snapshot.isDemo {
                            Divider()
                            extraProvidersSection
                        }
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
        if s.hueBridgePaired, let info = s.bridge {
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
            HStack {
                Text(store.tr("No bridge paired"))
                    .font(store.scaledFont(12))
                    .foregroundStyle(.secondary)
                Spacer()
                if s.isPaired && !s.isDemo {
                    Button(store.tr("Pair a Hue bridge")) {
                        store.showPairHueSheet = true
                        store.discover()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var extraProvidersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.tr("Other smart lights & hubs"))
                    .font(store.scaledFont(12, weight: .medium))
                Spacer()
                Button {
                    store.openAddProvider()
                } label: {
                    Label(store.tr("Add Device…"), systemImage: "plus")
                        .font(store.scaledFont(11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if store.providerConnections.isEmpty {
                Text(store.tr("No extra devices added yet. Mix Hue with WLED, WiZ, LIFX, Govee, Nanoleaf, Shelly, IKEA DIRIGERA, or Home Assistant."))
                    .font(store.scaledFont(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.providerConnections) { conn in
                        let status = store.snapshot.providers.first(where: { $0.id == conn.id })
                        let connected = status?.connected ?? false
                        let errText = status?.error ?? ""
                        let lightCount = status?.lightCount ?? 0
                        HStack(spacing: 8) {
                            Image(systemName: conn.kind.safeSFSymbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: conn.kind.accentHex))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(!conn.enabled ? Color.secondary.opacity(0.4) : (connected ? Color.green : Color.orange))
                                        .frame(width: 6, height: 6)
                                    Text(conn.name)
                                        .font(store.scaledFont(12, weight: .medium))
                                        .lineLimit(1)
                                    ProviderBadge(providerRaw: conn.kind.rawValue)
                                }
                                Text("\(conn.host):\(conn.effectivePort)" + (lightCount > 0 ? " · \(lightCount)" : ""))
                                    .font(store.scaledFont(10.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !errText.isEmpty && conn.enabled {
                                    Text(errText)
                                        .font(store.scaledFont(10))
                                        .foregroundStyle(Color.orange)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            Toggle("", isOn: Binding(
                                get: { conn.enabled },
                                set: { store.setProviderEnabled(id: conn.id, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Button {
                                store.openEditProvider(conn)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help(store.tr("Edit Lighting Device"))
                            Button(role: .destructive) {
                                store.removeProvider(id: conn.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.red.opacity(0.85))
                            }
                            .buttonStyle(.borderless)
                            .help(store.tr("Remove Device"))
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
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
                    .fill(store.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                    .strokeBorder(store.cardBorderColor, lineWidth: 1)
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
