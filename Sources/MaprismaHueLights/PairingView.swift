import HueCore
import SwiftUI

/// Bridge discovery (native Bonjour `_hue._tcp`), manual IP entry, push-link countdown,
/// and interactive Demo Home entry for users without a bridge nearby (and App Store Review).
struct PairingView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            Text(store.tr("Pair a Hue bridge"))
                .font(store.scaledFont(16, weight: .semibold))
            if s.isPairing {
                progress(s)
            } else {
                chooser(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
            .fill(store.cardBackgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                    .strokeBorder(store.cardBorderColor, lineWidth: 1)
            )
    }

    private func progress(_ s: HueSnapshot) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.tap")
                .font(.system(size: 34))
                .foregroundStyle(store.skinAccentColor)
            Text(store.trf("Press the round link button on top of the bridge now. Waiting {0} s for {1} …",
                           [String(s.pairRemaining), s.pairIP]))
                .font(store.scaledFont(12.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: Double(min(35, max(0, s.pairRemaining))), total: 35)
            Button(store.tr("Cancel")) { store.cancelPair() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(card)
    }

    @ViewBuilder
    private func chooser(_ s: HueSnapshot) -> some View {
        Text(store.tr("Click Pair, then press the round link button on top of the bridge within 30 seconds."))
            .font(store.scaledFont(12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if s.candidates.isEmpty {
            HStack(spacing: 8) {
                if s.discovering {
                    ProgressView().controlSize(.small)
                }
                Text(s.discovering ? store.tr("Searching the network for Hue bridges …")
                                   : store.tr("No bridge found automatically. Enter its IP address:"))
                    .font(store.scaledFont(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(store.tr("Found bridges").uppercased())
                .font(store.scaledFont(10, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(s.candidates) { candidate in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.router")
                            .foregroundStyle(store.skinAccentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name)
                                .font(store.scaledFont(12.5, weight: .medium))
                                .lineLimit(1)
                            Text(candidate.ip)
                                .font(store.scaledFont(11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(store.tr("Pair")) { store.pair(candidate.ip) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                    if candidate.id != s.candidates.last?.id {
                        Divider()
                    }
                }
            }
            .background(card)
            Text(store.tr("Or enter the bridge's IP address:"))
                .font(store.scaledFont(12))
        }

        HStack(spacing: 8) {
            TextField(store.tr("Bridge IP, e.g. 192.168.178.106"), text: $store.manualIP)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.pair(store.manualIP) }
            Button(store.tr("Pair")) { store.pair(store.manualIP) }
                .disabled(cleanedIP(store.manualIP).isEmpty)
        }

        Button {
            store.discover()
        } label: {
            Label(store.tr("Search again"), systemImage: "arrow.clockwise")
        }
        .disabled(s.discovering)

        Divider()
            .padding(.vertical, 4)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(store.skinAccentColor)
                Text(store.tr("Other smart lights & hubs"))
                    .font(store.scaledFont(12.5, weight: .semibold))
            }
            Text(store.tr("Connect Home Assistant, WLED, WiZ, LIFX, Govee LAN, Nanoleaf, Shelly, or IKEA DIRIGERA directly over your local network — with or without a Hue Bridge."))
                .font(store.scaledFont(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Button {
                        store.openAddProvider(kind: kind)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.safeSFSymbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(hex: kind.accentHex))
                            Text(kind.shortBadge)
                                .font(store.scaledFont(10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(store.skinAccentColor)
                Text(store.tr("Interactive preview"))
                    .font(store.scaledFont(12.5, weight: .semibold))
            }
            Text(store.tr("No Philips Hue bridge nearby? Explore rooms, colors, schedules, and linked-light rules with a simulated smart home."))
                .font(store.scaledFont(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.enterDemoMode()
            } label: {
                Label(store.tr("Try Demo Home"), systemImage: "house.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }
}
