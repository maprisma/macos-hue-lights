import HueCore
import SwiftUI

/// 4th tab: Audio-Reactive Light Synthesizer with live Bass/Mids/Treble + Beat spectrum meters,
/// System Audio / Microphone / Demo Beat capture, Entertainment v2 25 Hz or CLIP v2 Fast Sync,
/// modes, palettes, sensitivity/smoothness sliders, and per-lamp frequency band mapping.
struct SynthView: View {
    @EnvironmentObject var store: HueStore

    private var targetLights: [HueLight] {
        store.synthTargetLights
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard

                if let perm = store.synthPermissionIssue {
                    permissionBanner(kind: perm.kind, message: perm.message)
                }

                spectrumCard

                controlsCard

                targetsCard
            }
            .padding(12)
        }
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                    .fill(store.synthRunning ? store.skinAccentColor.opacity(0.22) : Color.primary.opacity(0.08))
                Image(systemName: store.synthRunning ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.synthRunning ? store.skinAccentColor : Color.secondary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(store.tr("Light Synthesizer"))
                        .font(store.scaledFont(13.5, weight: .semibold))
                    Text(store.synthEngineLabel)
                        .font(store.scaledFont(9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(store.synthUsingEntertainment ? Color.green : store.skinAccentColor)
                        .background(
                            Capsule().fill((store.synthUsingEntertainment ? Color.green : store.skinAccentColor).opacity(0.15))
                        )
                }
                Text(store.tr("Sync your Hue lights live to music, movies, or microphone audio."))
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Button {
                store.toggleSynth()
            } label: {
                Label(
                    store.synthRunning ? store.tr("Stop") : store.tr("Start"),
                    systemImage: store.synthRunning ? "stop.fill" : "play.fill"
                )
                .font(store.scaledFont(12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(store.synthRunning ? Color.red : store.skinAccentColor)
            .disabled(targetLights.isEmpty && !store.synthRunning)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(store.synthRunning ? store.skinAccentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func permissionBanner(kind: AudioPermissionKind, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .screenRecording
                         ? store.tr("System Audio permission needed")
                         : store.tr("Microphone permission needed"))
                        .font(store.scaledFont(12, weight: .semibold))
                    Text(kind == .screenRecording
                         ? store.tr("Allow Screen & System Audio Recording in System Settings to react to music and movies. Audio is analyzed in memory only and never recorded.")
                         : store.tr("Allow Microphone access in System Settings to react to room audio. Audio is analyzed in memory only and never recorded."))
                        .font(store.scaledFont(10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !message.isEmpty {
                        Text(message)
                            .font(store.scaledFont(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(store.tr("Open System Settings")) {
                    AudioCaptureManager.openPrivacySettings(for: kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button(store.tr("Use Demo Beat")) {
                    store.synthSource = .demoBeat
                    store.clearSynthPermissionError()
                    store.startSynth()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var spectrumCard: some View {
        let levels = store.synthLevels
        let colors = store.synthPalette.colors
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.tr("Live Spectrum").uppercased())
                    .font(store.scaledFont(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(levels.isBeat ? Color(hex: colors[0]) : Color.primary.opacity(0.18))
                        .frame(width: 9, height: 9)
                        .scaleEffect(levels.isBeat ? 1.35 : 1.0)
                        .animation(.easeOut(duration: 0.12), value: levels.isBeat)
                    Text(store.tr("Beat"))
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(levels.isBeat ? Color.primary : Color.secondary)
                }
            }

            VStack(spacing: 7) {
                BandMeterRow(label: store.tr("Bass"), range: "20–250 Hz", level: levels.bass, color: Color(hex: colors[0]))
                BandMeterRow(label: store.tr("Mids"), range: "250–2k Hz", level: levels.mids, color: Color(hex: colors[1]))
                BandMeterRow(label: store.tr("Treble"), range: "2k–16k Hz", level: levels.treble, color: Color(hex: colors[2]))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.tr("Audio Source").uppercased())
                    .font(store.scaledFont(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker(store.tr("Audio Source"), selection: Binding(
                    get: { store.synthSource },
                    set: { store.setSynthSource($0) }
                )) {
                    Text(store.tr("System Audio")).tag(AudioCaptureSource.systemAudio)
                    Text(store.tr("Microphone")).tag(AudioCaptureSource.microphone)
                    Text(store.tr("Demo Beat")).tag(AudioCaptureSource.demoBeat)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(store.tr("Mode").uppercased())
                    .font(store.scaledFont(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    modeChip(.pulse, title: store.tr("Pulse"))
                    modeChip(.colorWave, title: store.tr("Color Wave"))
                    modeChip(.club, title: store.tr("Club"))
                    modeChip(.chillAmbient, title: store.tr("Chill Ambient"))
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(store.tr("Palette").uppercased())
                    .font(store.scaledFont(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(SynthPalette.allCases) { pal in
                        let selected = store.synthPalette == pal
                        Button {
                            store.synthPalette = pal
                        } label: {
                            HStack(spacing: 5) {
                                HStack(spacing: 2) {
                                    ForEach(pal.colors, id: \.self) { hex in
                                        Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                                    }
                                }
                                Text(paletteLabel(pal))
                                    .font(store.scaledFont(11, weight: selected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(selected ? store.skinAccentColor.opacity(0.22) : Color.primary.opacity(0.07))
                            )
                            .overlay(
                                Capsule().strokeBorder(selected ? store.skinAccentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.2 : 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 8) {
                HStack {
                    Text(store.tr("Sensitivity"))
                        .font(store.scaledFont(11.5))
                        .frame(width: 86, alignment: .leading)
                    Slider(value: $store.synthSensitivity, in: 0.4...2.2)
                        .controlSize(.small)
                    Text("\(Int((store.synthSensitivity * 100).rounded()))%")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text(store.tr("Smoothness"))
                        .font(store.scaledFont(11.5))
                        .frame(width: 86, alignment: .leading)
                    Slider(value: $store.synthSmoothness, in: 0.0...0.85)
                        .controlSize(.small)
                    Text("\(Int((store.synthSmoothness * 100).rounded()))%")
                        .font(store.scaledFont(11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var targetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.tr("Target Lights").uppercased())
                    .font(store.scaledFont(10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(store.tr("Room"), selection: $store.synthTargetRoomID) {
                    Text(store.tr("All Rooms")).tag("")
                    ForEach(store.snapshot.rooms) { room in
                        Text(store.l10n.roomName(room)).tag(room.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }

            if !store.snapshot.entertainmentAreas.isEmpty {
                HStack {
                    Text(store.tr("Entertainment Area"))
                        .font(store.scaledFont(11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(store.tr("Entertainment Area"), selection: $store.synthEntertainmentAreaID) {
                        Text(store.tr("Standard Sync")).tag("")
                        ForEach(store.snapshot.entertainmentAreas) { area in
                            Text(area.name).tag(area.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                }
            }

            if targetLights.isEmpty {
                Text(store.tr("No lights available in the selected room."))
                    .font(store.scaledFont(11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(targetLights) { light in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: light.color))
                                .frame(width: 10, height: 10)
                            Text(light.name)
                                .font(store.scaledFont(12))
                                .lineLimit(1)
                            Spacer()
                            Picker(store.tr("Band"), selection: Binding(
                                get: { store.synthLightBand(for: light.id) },
                                set: { store.setSynthLightBand($0, for: light.id) }
                            )) {
                                Text(store.tr("All")).tag(SynthBand.all)
                                Text(store.tr("Bass")).tag(SynthBand.bass)
                                Text(store.tr("Mids")).tag(SynthBand.mids)
                                Text(store.tr("Treble")).tag(SynthBand.treble)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 92)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func modeChip(_ mode: SynthMode, title: String) -> some View {
        Button(title) {
            store.synthMode = mode
        }
        .buttonStyle(ChipStyle(active: store.synthMode == mode))
    }

    private func paletteLabel(_ palette: SynthPalette) -> String {
        switch palette {
        case .neon: return store.tr("Neon")
        case .sunset: return store.tr("Sunset")
        case .ocean: return store.tr("Ocean")
        case .fire: return store.tr("Fire")
        case .forest: return store.tr("Forest")
        case .rainbow: return store.tr("Rainbow")
        }
    }
}

private struct BandMeterRow: View {
    @EnvironmentObject var store: HueStore
    let label: String
    let range: String
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(store.scaledFont(11, weight: .semibold))
                Text(range)
                    .font(store.scaledFont(9))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 68, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, geo.size.width * CGFloat(HueColorMath.clamp(level, 0.0, 1.0))))
                        .animation(.linear(duration: 0.06), value: level)
                }
            }
            .frame(height: 10)

            Text("\(Int((level * 100).rounded()))%")
                .font(store.scaledFont(10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
