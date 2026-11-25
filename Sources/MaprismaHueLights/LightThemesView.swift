import AppKit
import HueCore
import SwiftUI

/// Per-lamp Light Theme selector & editor sheet:
/// 1-click apply for 8 built-in + custom themes, 1-click capture of the lamp's current state,
/// and full custom theme creator/editor (color/warmth, brightness, Hue effect, SF Symbol).
struct LightThemesSheet: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    let light: HueLight

    @State private var editingID: String? = nil
    @State private var name: String = ""
    @State private var useWarmth: Bool = false
    @State private var pickedColor: Color = Color(hex: "#ff6b35")
    @State private var pickedHex: String = "#ff6b35"
    @State private var kelvin: Double = 2700
    @State private var brightness: Double = 80
    @State private var effect: String = "no_effect"
    @State private var symbol: String = "sparkles"
    @State private var showEditor: Bool = false

    private static let presetHexes: [String] = [
        "#ff2e93", "#ff6b35", "#ffb703", "#ffd27a",
        "#00f0ff", "#0077b6", "#2d6a4f", "#9b5de5",
    ]

    private static let knownEffects: [String] = [
        "no_effect", "candle", "fire", "prism", "sparkle", "opal", "glisten", "underwater",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tr("Light Themes"))
                        .font(store.scaledFont(14, weight: .semibold))
                    Text(light.name)
                        .font(store.scaledFont(11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let captured = HueLightTheme.fromLight(light, name: "\(light.name) \(store.tr("Preset"))")
                    store.saveTheme(captured)
                } label: {
                    Label(store.tr("Save current state"), systemImage: "square.and.arrow.down")
                        .font(store.scaledFont(11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.tr("Apply a theme").uppercased())
                        .font(store.scaledFont(10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                        ],
                        spacing: 8
                    ) {
                        ForEach(store.allThemes) { theme in
                            ThemeTile(
                                theme: theme,
                                onApply: { store.applyTheme(theme, to: light) },
                                onEdit: theme.isBuiltIn ? nil : { beginEdit(theme) },
                                onDelete: theme.isBuiltIn ? nil : { store.deleteTheme(theme) }
                            )
                        }
                    }

                    Divider()

                    HStack {
                        Text(editingID == nil ? store.tr("Create custom theme") : store.tr("Edit custom theme"))
                            .font(store.scaledFont(12.5, weight: .semibold))
                        Spacer()
                        Button(showEditor ? store.tr("Hide") : store.tr("New Theme")) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if !showEditor { resetEditor() }
                                showEditor.toggle()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if showEditor {
                        editorForm
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Spacer()
                Button(store.tr("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 380, idealWidth: 440, maxWidth: 580, minHeight: 380, idealHeight: 540, maxHeight: 700)
        .fontDesign(store.fontDesign)
    }

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(store.tr("Theme name"), text: $name)
                .textFieldStyle(.roundedBorder)

            Picker(store.tr("Mode"), selection: $useWarmth) {
                Text(store.tr("Color")).tag(false)
                Text(store.tr("Warmth")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if useWarmth {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(store.tr("Warmth"))
                            .font(store.scaledFont(11.5))
                        Spacer()
                        Text("\(Int(kelvin)) K")
                            .font(store.scaledFont(11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $kelvin, in: 2000...6500, step: 100)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    ColorPicker(store.tr("Color"), selection: $pickedColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: pickedColor) { newColor in
                            pickedHex = Self.hexFromColor(newColor)
                        }
                    ForEach(Self.presetHexes, id: \.self) { hex in
                        Button {
                            pickedHex = hex
                            pickedColor = Color(hex: hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .overlay(
                                    Circle().strokeBorder(
                                        pickedHex.lowercased() == hex ? Color.white : Color.primary.opacity(0.25),
                                        lineWidth: pickedHex.lowercased() == hex ? 2 : 0.75
                                    )
                                )
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Text(store.tr("Brightness"))
                    .font(store.scaledFont(11.5))
                Slider(value: $brightness, in: 5...100, step: 5)
                    .controlSize(.small)
                Text("\(Int(brightness))%")
                    .font(store.scaledFont(11.5).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }

            HStack {
                Text(store.tr("Effects"))
                    .font(store.scaledFont(11.5))
                Spacer()
                Picker(store.tr("Effects"), selection: $effect) {
                    ForEach(Self.knownEffects, id: \.self) { eff in
                        Text(eff == "no_effect" ? store.tr("None") : eff.capitalized).tag(eff)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.tr("Icon"))
                    .font(store.scaledFont(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), spacing: 6) {
                    ForEach(HueLightTheme.availableSymbols, id: \.self) { sym in
                        Button {
                            symbol = sym
                        } label: {
                            Image(systemName: sym)
                                .font(.system(size: 13))
                                .frame(width: 26, height: 26)
                                .foregroundStyle(symbol == sym ? Color.white : Color.primary)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(symbol == sym ? store.skinAccentColor : Color.primary.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button(store.tr("Cancel")) {
                    withAnimation { showEditor = false }
                    resetEditor()
                }
                Spacer()
                Button(store.tr("Save Theme")) {
                    saveEditedTheme()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func resetEditor() {
        editingID = nil
        name = ""
        useWarmth = !light.supportsColor && light.supportsCT
        pickedHex = light.color
        pickedColor = Color(hex: light.color)
        kelvin = Double(HueColorMath.mirekToKelvin(light.mirek ?? 370))
        brightness = max(10, light.bri)
        effect = light.effect
        symbol = "sparkles"
    }

    private func beginEdit(_ theme: HueLightTheme) {
        editingID = theme.id
        name = theme.name
        useWarmth = (theme.mirek != nil)
        pickedHex = theme.hex
        pickedColor = Color(hex: theme.hex)
        if let m = theme.mirek {
            kelvin = Double(HueColorMath.mirekToKelvin(m))
        }
        brightness = Double(theme.brightness)
        effect = theme.effect
        symbol = theme.symbol
        withAnimation { showEditor = true }
    }

    private func saveEditedTheme() {
        let cleaned = HueColorMath.clean(name)
        let finalName = cleaned.isEmpty ? store.tr("Custom Theme") : cleaned
        let mirekVal = useWarmth ? HueColorMath.kelvinToMirek(Int(kelvin)) : nil
        let finalHex = useWarmth ? HueColorMath.mirekToHex(mirekVal ?? 370) : pickedHex
        let theme = HueLightTheme(
            id: editingID ?? UUID().uuidString.lowercased(),
            name: finalName,
            symbol: symbol,
            hex: finalHex,
            mirek: mirekVal,
            brightness: Int(brightness),
            effect: effect,
            palette: [finalHex],
            isBuiltIn: false
        )
        store.saveTheme(theme)
        store.applyTheme(theme, to: light)
        withAnimation { showEditor = false }
        resetEditor()
    }

    private static func hexFromColor(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.orange
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x",
                      HueColorMath.clamp(r, 0, 255),
                      HueColorMath.clamp(g, 0, 255),
                      HueColorMath.clamp(b, 0, 255))
    }
}

private struct ThemeTile: View {
    @EnvironmentObject var store: HueStore
    let theme: HueLightTheme
    let onApply: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onApply) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                            .fill(Color(hex: theme.hex))
                        Image(systemName: theme.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(prefersDarkGlyph(theme.hex) ? Color.black.opacity(0.8) : Color.white)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(theme.name)
                            .font(store.scaledFont(11.5, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(store.scaledFont(9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onEdit = onEdit, let onDelete = onDelete {
                Menu {
                    Button(store.tr("Edit")) { onEdit() }
                    Button(store.tr("Delete"), role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(Color(hex: theme.hex).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(Color(hex: theme.hex).opacity(0.35), lineWidth: 1)
        )
    }

    private var subtitle: String {
        var parts: [String] = ["\(theme.brightness)%"]
        if let m = theme.mirek {
            parts.append("\(HueColorMath.mirekToKelvin(m))K")
        }
        if theme.effect != "no_effect" {
            parts.append(theme.effect.capitalized)
        }
        return parts.joined(separator: " · ")
    }
}
