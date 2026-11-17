import HueCore
import SwiftUI

/// Settings: interface language (8 languages or the system's), the paired bridge with Unpair
/// (asks again before it acts), and Quit.
struct SettingsView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    store.page = .main
                } label: {
                    Label(store.tr("Back"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(store.tr("Settings").uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSection(title: store.tr("Language")) {
                        Picker(store.tr("Language"), selection: Binding(get: { store.languageSetting },
                                                                       set: { store.setLanguage($0) })) {
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
                                .font(.caption)
                                .foregroundStyle(Color.red)
                        }
                    }
                    SettingsSection(title: store.tr("Bridge")) {
                        bridge
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    store.quit()
                } label: {
                    Label(store.tr("Quit Maprisma Hue Lights"), systemImage: "power")
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var bridge: some View {
        let s = store.snapshot
        if s.isPaired, let info = s.bridge {
            HStack(spacing: 10) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name.isEmpty ? "Hue Bridge" : info.name)
                        .font(.callout.weight(.medium))
                    Text(info.model.isEmpty ? info.ip : "\(info.ip) · \(info.model)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text(store.tr("Forget this bridge and its app key on this Mac"))
                .font(.caption)
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
        } else {
            Text(store.tr("No bridge paired"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}
