import HueCore
import SwiftUI

/// No bridge yet: bridges the helper found (mDNS, N-UPnP, subnet scan) with Pair, an IP field, and
/// while pairing the push-link countdown.
struct PairingView: View {
    @EnvironmentObject var store: HueStore

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            Text(store.tr("Pair a Hue bridge"))
                .font(.title3.weight(.semibold))
            if s.isPairing {
                progress(s)
            } else {
                chooser(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
    }

    private func progress(_ s: HueSnapshot) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.tap")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            Text(store.trf("Press the round link button on top of the bridge now. Waiting {0} s for {1} …",
                           [String(s.pairRemaining), s.pairIP]))
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
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if s.candidates.isEmpty {
            HStack(spacing: 8) {
                if s.discovering {
                    ProgressView().controlSize(.small)
                }
                Text(s.discovering ? store.tr("Searching the network for Hue bridges …")
                                   : store.tr("No bridge found automatically. Enter its IP address:"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(store.tr("Found bridges").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(s.candidates) { candidate in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.router")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(candidate.ip)
                                .font(.caption.monospacedDigit())
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
                .font(.callout)
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
    }
}
