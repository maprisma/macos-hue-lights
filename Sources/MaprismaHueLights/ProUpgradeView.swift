import HueCore
import SwiftUI

/// App-Store-grade one-time Pro upgrade sheet (Non-Consumable IAP, zero subscription).
struct ProUpgradeView: View {
    @EnvironmentObject var store: HueStore
    @EnvironmentObject var proStore: ProStoreManager
    @Environment(\.dismiss) private var dismiss

    private struct FeatureItem: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
    }

    private var features: [FeatureItem] {
        [
            FeatureItem(
                id: "floorplan",
                symbol: "map.fill",
                tint: Color(hex: "#38bdf8"),
                title: store.tr("Visual Floorplan Studio & 12 custom lamp icons")
            ),
            FeatureItem(
                id: "rules",
                symbol: "link",
                tint: Color(hex: "#a855f7"),
                title: store.tr("Visual Rules & physical Hue Sensors")
            ),
            FeatureItem(
                id: "motionAware",
                symbol: "dot.radiowaves.left.and.right",
                tint: Color(hex: "#06b6d4"),
                title: store.tr("Hue Bridge Pro MotionAware™ controls")
            ),
            FeatureItem(
                id: "audioSynth",
                symbol: "waveform",
                tint: Color(hex: "#f97316"),
                title: store.tr("Audio Reactive Light Synth")
            ),
            FeatureItem(
                id: "skins",
                symbol: "paintpalette.fill",
                tint: Color(hex: "#ec4899"),
                title: store.tr("All 6 custom Skins")
            ),
            FeatureItem(
                id: "askAI",
                symbol: "sparkles",
                tint: Color(hex: "#10b981"),
                title: store.tr("Optional local-first Ask AI & local MCP server")
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [store.skinAccentColor.opacity(0.28), Color(hex: "#a855f7").opacity(0.22)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(store.skinAccentColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Maprisma Hue Lights Pro"))
                        .font(store.scaledFont(15, weight: .bold))
                    Text(store.tr("One-time purchase · No subscription"))
                        .font(store.scaledFont(11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    closeSheet()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(store.tr("Close"))
            }

            Divider()

            // Compact feature list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features) { item in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(item.tint.opacity(0.16))
                            Image(systemName: item.symbol)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(item.tint)
                        }
                        .frame(width: 24, height: 24)

                        Text(item.title)
                            .font(store.scaledFont(12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

            // Status / error banners
            if let status = proStore.statusMessage, !status.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: proStore.effectiveProUnlocked ? "checkmark.seal.fill" : "info.circle.fill")
                        .foregroundStyle(proStore.effectiveProUnlocked ? Color.green : store.skinAccentColor)
                    Text(status)
                        .font(store.scaledFont(11.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                        .fill((proStore.effectiveProUnlocked ? Color.green : store.skinAccentColor).opacity(0.12))
                )
            }

            if let error = proStore.errorMessage, !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(error)
                        .font(store.scaledFont(11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            // Actions
            VStack(spacing: 8) {
                if proStore.effectiveProUnlocked {
                    Button {
                        closeSheet()
                    } label: {
                        Label(store.tr("Pro unlocked!"), systemImage: "checkmark.seal.fill")
                            .font(store.scaledFont(13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.green)
                } else {
                    Button {
                        Task { await proStore.purchasePro() }
                    } label: {
                        HStack(spacing: 8) {
                            if proStore.isPurchasing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(store.trf("Unlock Pro — {0}", [proStore.formattedPrice]))
                                .font(store.scaledFont(13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(proStore.isPurchasing)
                }

                HStack(spacing: 8) {
                    if !store.isDemoMode && !proStore.effectiveProUnlocked {
                        Button {
                            closeSheet()
                            store.enterDemoMode(keepingTab: store.tab)
                        } label: {
                            Text(store.tr("Try free in Demo Mode"))
                                .font(store.scaledFont(11.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        Task { await proStore.restorePurchases() }
                    } label: {
                        Text(store.tr("Restore Purchases"))
                            .font(store.scaledFont(11.5))
                    }
                    .buttonStyle(.borderless)
                    .disabled(proStore.isPurchasing || proStore.isLoading)
                }
            }

            Text(store.tr("Rooms, lights, scenes, schedules, and Demo Mode remain free forever. Ask AI stays strictly optional and off by default."))
                .font(store.scaledFont(10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            proStore.clearMessages()
            if proStore.proProduct == nil {
                Task { await proStore.loadProductAndEntitlements() }
            }
        }
    }

    private func closeSheet() {
        store.showProUpgradeSheet = false
        dismiss()
    }
}

/// Subtle, non-nagging gate shown on Pro tabs when using a real Hue Bridge in Free mode.
/// Offers both a one-time Pro unlock and an instant 1-click Demo Mode preview of that exact feature.
struct ProLockedOverlay: View {
    @EnvironmentObject var store: HueStore
    @EnvironmentObject var proStore: ProStoreManager

    let feature: ProFeature
    let symbol: String
    let accentHex: String
    let title: String
    let description: String
    let highlights: [String]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                                .fill(Color(hex: accentHex).opacity(0.18))
                            Image(systemName: symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color(hex: accentHex))
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(store.scaledFont(14.5, weight: .semibold))
                                Text(store.tr("Pro"))
                                    .font(store.scaledFont(9.5, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(store.skinAccentColor)
                                    .background(Capsule().fill(store.skinAccentColor.opacity(0.16)))
                            }
                            Text(store.tr("One-time purchase · No subscription"))
                                .font(store.scaledFont(10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(description)
                        .font(store.scaledFont(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(highlights, id: \.self) { point in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(hex: accentHex))
                                        .padding(.top, 1.5)
                                    Text(point)
                                        .font(store.scaledFont(11.5))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            store.showProUpgradeSheet = true
                        } label: {
                            Label(store.tr("Unlock Pro"), systemImage: "crown.fill")
                                .font(store.scaledFont(12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            store.enterDemoMode(keepingTab: store.tab)
                        } label: {
                            Label(store.tr("Try in Demo Mode"), systemImage: "play.circle")
                                .font(store.scaledFont(12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
                .padding(18)
                .frame(maxWidth: 440, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                        .fill(store.cardBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                        .strokeBorder(store.cardBorderColor, lineWidth: 1)
                )

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact inline banner for secondary Pro features (e.g. MotionAware controls).
struct ProFeatureGateBanner: View {
    @EnvironmentObject var store: HueStore

    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 13))
                .foregroundStyle(store.skinAccentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(store.scaledFont(11.5, weight: .semibold))
                Text(message)
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(store.tr("Unlock Pro")) {
                store.showProUpgradeSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(store.skinAccentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(store.skinAccentColor.opacity(0.28), lineWidth: 1)
        )
    }
}
