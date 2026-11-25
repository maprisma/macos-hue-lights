import HueCore
import SwiftUI

/// Compact brand badge shown on non-Hue rooms and in the Devices list.
struct ProviderBadge: View {
    @EnvironmentObject var store: HueStore
    let providerRaw: String

    private var kind: LightProviderKind? {
        LightProviderKind.from(idPrefix: providerRaw)
    }

    var body: some View {
        if let kind = kind, kind != .hue {
            let tint = Color(hex: kind.accentHex)
            HStack(spacing: 3) {
                Image(systemName: kind.safeSFSymbol)
                    .font(.system(size: 8, weight: .semibold))
                Text(kind.shortBadge)
                    .font(store.scaledFont(8.5, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 0.5))
        }
    }
}

/// Sheet to discover, configure, pair, test, and save non-Hue local smart lighting devices & hubs.
struct AddProviderSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let editing: ProviderConnection?
    let preselectedKind: LightProviderKind?

    @State private var selectedKind: LightProviderKind = .homeAssistant
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var roomName: String = ""
    @State private var token: String = ""
    @State private var certFingerprint: String = ""
    @State private var useHTTPS: Bool = false
    @State private var testing: Bool = false
    @State private var pairing: Bool = false
    @State private var statusMessage: String? = nil
    @State private var statusIsError: Bool = false

    init(editing: ProviderConnection? = nil, preselectedKind: LightProviderKind? = nil) {
        self.editing = editing
        self.preselectedKind = preselectedKind
    }

    private var resolvedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let val = Int(trimmed), (1...65535).contains(val) else { return nil }
        return val
    }

    /// True only when editing an existing connection whose target `(kind, host, port)` has not changed.
    private var sameSavedTarget: Bool {
        guard let ed = editing else { return false }
        let curHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let edHost = ed.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let curPort = resolvedPort ?? selectedKind.defaultPort
        return ed.kind == selectedKind && curHost == edHost && curPort == ed.effectivePort && store.hasProviderSecret(for: ed.id)
    }

    private var draftConnection: ProviderConnection {
        let fp = sameSavedTarget && certFingerprint.isEmpty ? (editing?.certFingerprint ?? "") : certFingerprint
        return ProviderConnection(
            id: editing?.id ?? ProviderConnection.makeID(),
            kind: selectedKind,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? selectedKind.displayName : name,
            host: host,
            port: resolvedPort,
            useHTTPS: selectedKind == .dirigera ? true : (selectedKind == .homeAssistant ? useHTTPS : false),
            enabled: editing?.enabled ?? true,
            roomName: roomName,
            deviceID: editing?.deviceID ?? "",
            certFingerprint: fp
        )
    }

    private var canSave: Bool {
        guard draftConnection.isValidHost else { return false }
        if selectedKind.requiresToken {
            let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTok.isEmpty {
                return sameSavedTarget
            }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(editing == nil ? store.tr("Add Lighting Device") : store.tr("Edit Lighting Device"))
                    .font(store.scaledFont(14, weight: .semibold))
                Spacer()
                Button(store.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Ecosystem picker grid
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.tr("Device or Hub Type").uppercased())
                            .font(store.scaledFont(10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6),
                            ],
                            spacing: 6
                        ) {
                            ForEach(LightProviderKind.extraProviders) { kind in
                                let active = selectedKind == kind
                                let tint = Color(hex: kind.accentHex)
                                Button {
                                    selectKind(kind)
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: kind.safeSFSymbol)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(active ? Color.white : tint)
                                        Text(kind.shortBadge)
                                            .font(store.scaledFont(10, weight: active ? .semibold : .medium))
                                            .foregroundStyle(active ? Color.white : Color.primary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                            .fill(active ? tint : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                            .strokeBorder(active ? tint : Color.primary.opacity(0.1), lineWidth: active ? 1.2 : 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(editing != nil)
                            }
                        }
                        Text(providerHint(for: selectedKind))
                            .font(store.scaledFont(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Discovered LAN devices (Bonjour)
                    if editing == nil {
                        let existingTargets = Set(store.providerConnections.map {
                            "\($0.kind.rawValue)|\($0.host.lowercased())|\($0.effectivePort)"
                        })
                        let addableFree = store.discoveredProviders.filter { dev in
                            !dev.kind.requiresToken
                                && !existingTargets.contains("\(dev.kind.rawValue)|\(dev.host.lowercased())|\(dev.port)")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(store.tr("Discovered on local network").uppercased())
                                    .font(store.scaledFont(10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if addableFree.count >= 2 {
                                    Button(store.tr("Add all found")) {
                                        var added = 0
                                        for dev in addableFree {
                                            let c = ProviderConnection(
                                                kind: dev.kind,
                                                name: dev.name,
                                                host: dev.host,
                                                port: dev.port,
                                                useHTTPS: dev.kind.defaultUseHTTPS,
                                                roomName: roomName
                                            )
                                            if case .success = store.saveProvider(c, secret: nil) {
                                                added += 1
                                            }
                                        }
                                        if added > 0 {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                Button {
                                    store.discoverProviders()
                                } label: {
                                    HStack(spacing: 4) {
                                        if store.discoveringProviders {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 10))
                                        }
                                        Text(store.tr("Scan LAN"))
                                            .font(store.scaledFont(10.5))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(store.discoveringProviders)
                            }

                            if !store.discoveredProviders.isEmpty {
                                VStack(spacing: 4) {
                                    ForEach(store.discoveredProviders) { dev in
                                        let isAdded = existingTargets.contains("\(dev.kind.rawValue)|\(dev.host.lowercased())|\(dev.port)")
                                        Button {
                                            selectedKind = dev.kind
                                            name = dev.name
                                            host = dev.host
                                            portText = String(dev.port)
                                            useHTTPS = dev.kind.defaultUseHTTPS
                                            token = ""
                                            certFingerprint = ""
                                            statusMessage = nil
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: dev.kind.safeSFSymbol)
                                                    .foregroundStyle(Color(hex: dev.kind.accentHex))
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(dev.name)
                                                        .font(store.scaledFont(11.5, weight: .medium))
                                                        .lineLimit(1)
                                                    Text("\(dev.kind.displayName) · \(dev.host):\(dev.port)")
                                                        .font(store.scaledFont(10).monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Text(isAdded ? store.tr("Added") : store.tr("Use"))
                                                    .font(store.scaledFont(10.5, weight: .medium))
                                                    .foregroundStyle(isAdded ? Color.secondary : store.skinAccentColor)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                                    .fill(Color.primary.opacity(isAdded ? 0.025 : 0.05))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isAdded)
                                    }
                                }
                            } else if !store.discoveringProviders {
                                Text(store.tr("Nothing found — find the IP in your router or the brand's app."))
                                    .font(store.scaledFont(10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Connection form
                    VStack(alignment: .leading, spacing: 10) {
                        labeledField(store.tr("Name")) {
                            TextField(selectedKind.displayName, text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 8) {
                            labeledField(store.tr("Local IP or .local host")) {
                                TextField(hostPlaceholder(for: selectedKind), text: $host)
                                    .textFieldStyle(.roundedBorder)
                            }
                            labeledField(store.tr("Port")) {
                                TextField(String(selectedKind.defaultPort), text: $portText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 76)
                            }
                        }

                        if !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftConnection.isValidHost {
                            Text(store.tr("Only local network addresses (LAN IP or .local) are allowed."))
                                .font(store.scaledFont(10.5))
                                .foregroundStyle(Color.orange)
                        }

                        if !selectedKind.isHubProvider {
                            labeledField(store.tr("Room name (optional)")) {
                                TextField(store.tr("e.g. Living Room"), text: $roomName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        if selectedKind == .homeAssistant {
                            Toggle(store.tr("Use HTTPS (self-signed LAN cert allowed)"), isOn: $useHTTPS)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(store.scaledFont(11.5))
                        }

                        if selectedKind.requiresToken {
                            labeledField(tokenLabel(for: selectedKind)) {
                                SecureField(
                                    sameSavedTarget
                                        ? store.tr("Saved in Keychain (leave blank to keep)")
                                        : (selectedKind.supportsButtonPairing
                                            ? store.tr("Paste token or pair below")
                                            : store.tr("Paste long-lived access token")),
                                    text: $token
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                            if editing != nil && !sameSavedTarget && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(store.tr("Host or port changed — enter a token or re-pair before saving."))
                                    .font(store.scaledFont(10.5))
                                    .foregroundStyle(Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        // B4: Allow trusting a renewed TLS certificate without deleting the device or losing map/rules
                        if let ed = editing,
                           (selectedKind == .dirigera || useHTTPS),
                           (!ed.certFingerprint.isEmpty || (store.snapshot.providers.first(where: { $0.id == ed.id })?.error.lowercased().contains("certificate") == true)) {
                            HStack(spacing: 8) {
                                Button {
                                    let res = store.trustNewProviderCertificate(id: ed.id)
                                    switch res {
                                    case .success:
                                        certFingerprint = ""
                                        statusIsError = false
                                        statusMessage = store.tr("Certificate trusted — reconnecting.")
                                    case .failure(let err):
                                        statusIsError = true
                                        statusMessage = store.tr(MultiProviderCoordinator.friendlyErrorMessage(for: err))
                                    }
                                } label: {
                                    Label(store.tr("Trust new certificate"), systemImage: "checkmark.shield")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if selectedKind.supportsButtonPairing {
                            HStack(spacing: 8) {
                                Button {
                                    runButtonPairing()
                                } label: {
                                    HStack(spacing: 5) {
                                        if pairing {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "hand.tap.fill")
                                        }
                                        Text(selectedKind == .nanoleaf
                                             ? store.tr("Pair via Power Button")
                                             : store.tr("Pair via Action Button"))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!draftConnection.isValidHost || pairing)
                            }
                        }
                    }

                    if let msg = statusMessage, !msg.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(statusIsError ? Color.orange : Color.green)
                            Text(msg)
                                .font(store.scaledFont(11))
                                .foregroundStyle(statusIsError ? Color.orange : Color.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    runConnectionTest()
                } label: {
                    HStack(spacing: 5) {
                        if testing { ProgressView().controlSize(.mini) }
                        Text(store.tr("Test Connection"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canSave || testing || pairing)

                Spacer()

                Button(store.tr("Save Device")) {
                    let result = store.saveProvider(draftConnection, secret: token.isEmpty ? nil : token)
                    switch result {
                    case .success:
                        dismiss()
                    case .failure(let err):
                        statusIsError = true
                        statusMessage = store.tr(MultiProviderCoordinator.friendlyErrorMessage(for: err))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || pairing)
            }
            .padding(14)
        }
        .frame(width: 440, height: 560)
        .onAppear {
            if let ed = editing {
                selectedKind = ed.kind
                name = ed.name
                host = ed.host
                portText = ed.port.map(String.init) ?? String(ed.effectivePort)
                roomName = ed.roomName
                useHTTPS = ed.useHTTPS
                certFingerprint = ed.certFingerprint
            } else if let pre = preselectedKind {
                selectKind(pre)
                store.discoverProviders()
            } else {
                selectKind(.homeAssistant)
                store.discoverProviders()
            }
        }
    }

    private func selectKind(_ kind: LightProviderKind) {
        selectedKind = kind
        portText = String(kind.defaultPort)
        useHTTPS = kind.defaultUseHTTPS
        token = ""
        certFingerprint = ""
        statusMessage = nil
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(store.scaledFont(11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func hostPlaceholder(for kind: LightProviderKind) -> String {
        switch kind {
        case .homeAssistant: return "homeassistant.local or 192.168.1.10"
        case .wled: return "wled.local or 192.168.1.40"
        default: return "192.168.1.50"
        }
    }

    private func tokenLabel(for kind: LightProviderKind) -> String {
        switch kind {
        case .homeAssistant: return store.tr("Long-Lived Access Token")
        case .nanoleaf: return store.tr("Nanoleaf Auth Token")
        case .dirigera: return store.tr("DIRIGERA Access Token")
        default: return store.tr("Access Token")
        }
    }

    private func providerHint(for kind: LightProviderKind) -> String {
        switch kind {
        case .homeAssistant:
            return store.tr("In Home Assistant: Profile → Security → Long-lived access tokens. Controls Matter, Zigbee2MQTT, IKEA, Tuya, Aqara, ESPHome, and 100+ brands locally.")
        case .wled:
            return store.tr("Direct local HTTP control for WLED LED strips with color, effects, and presets — no hub required.")
        case .wiz:
            return store.tr("Direct local UDP control for WiZ bulbs and lamps on port 38899 — no pairing or cloud required.")
        case .lifx:
            return store.tr("Direct local LAN binary protocol on port 56700 for instant color and warmth control — no hub required.")
        case .govee:
            return store.tr("Enable LAN Control in the Govee Home app first, then enter the light's local IP address.")
        case .nanoleaf:
            return store.tr("Hold the Nanoleaf controller power button for 5–7 seconds until LEDs flash, then click Pair via Power Button.")
        case .shelly:
            return store.tr("Direct local HTTP control for Shelly Duo, Bulb RGBW, Dimmer, RGBW2, and Gen2/Gen3 light switches.")
        case .dirigera:
            return store.tr("Press the Action Button underneath your IKEA DIRIGERA hub when prompted to pair securely over local HTTPS.")
        case .hue:
            return ""
        }
    }

    private func runConnectionTest() {
        testing = true
        statusMessage = nil
        let conn = draftConnection
        let sec = token.isEmpty ? nil : token
        Task {
            let result = await store.testProvider(conn, secret: sec)
            await MainActor.run {
                testing = false
                switch result {
                case .success(let summary):
                    statusIsError = false
                    statusMessage = store.trf("Connected: {0}", [summary])
                case .failure(let err):
                    statusIsError = true
                    statusMessage = store.tr(MultiProviderCoordinator.friendlyErrorMessage(for: err))
                }
            }
        }
    }

    private func runButtonPairing() {
        pairing = true
        statusIsError = false
        statusMessage = selectedKind == .nanoleaf
            ? store.tr("Hold the Nanoleaf power button for 5–7 seconds now …")
            : store.tr("Press the Action Button underneath the DIRIGERA hub now …")
        let targetHost = draftConnection.host
        let targetPort = draftConnection.effectivePort
        let kind = selectedKind
        Task {
            if kind == .nanoleaf {
                let result = await store.pairNanoleaf(host: targetHost, port: targetPort)
                await MainActor.run {
                    pairing = false
                    switch result {
                    case .success(let newToken):
                        token = newToken
                        statusIsError = false
                        statusMessage = store.tr("Paired successfully! Click Save Device to connect.")
                    case .failure(let err):
                        statusIsError = true
                        statusMessage = store.tr(MultiProviderCoordinator.friendlyErrorMessage(for: err))
                    }
                }
            } else {
                let result = await store.pairDirigera(host: targetHost, port: targetPort)
                await MainActor.run {
                    pairing = false
                    switch result {
                    case .success(let paired):
                        token = paired.token
                        certFingerprint = paired.certFingerprint
                        statusIsError = false
                        statusMessage = store.tr("Paired successfully! Click Save Device to connect.")
                    case .failure(let err):
                        statusIsError = true
                        statusMessage = store.tr(MultiProviderCoordinator.friendlyErrorMessage(for: err))
                    }
                }
            }
        }
    }
}
