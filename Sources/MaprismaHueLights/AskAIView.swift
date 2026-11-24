import HueCore
import SwiftUI

/// Optional, local-first natural-language assistant sheet (only accessible when `store.askAIEnabled` is ON).
struct AskAIView: View {
    @EnvironmentObject var store: HueStore
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var isRunning: Bool = false
    @State private var entries: [AskAIEntry] = []
    @FocusState private var inputFocused: Bool

    private struct AskAIEntry: Identifiable, Equatable {
        let id = UUID()
        let prompt: String
        let response: HueAskAIResponse
    }

    private var exampleChips: [String] {
        [
            store.tr("All lights off"),
            store.tr("Dim Living Room to 40% warm"),
            store.tr("When Hallway Motion detects motion, turn on Hallway"),
            store.tr("Turn on Hallway at 07:30 weekdays"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(store.skinAccentColor)
                Text(store.tr("Ask AI"))
                    .font(store.scaledFont(13.5, weight: .semibold))
                Text(store.tr("Local"))
                    .font(store.scaledFont(9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(store.skinAccentColor)
                    .background(Capsule().fill(store.skinAccentColor.opacity(0.14)))
                Spacer()
                if !entries.isEmpty {
                    Button {
                        entries.removeAll()
                    } label: {
                        Text(store.tr("Clear"))
                            .font(store.scaledFont(11))
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(store.tr("Close"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Prompt input bar
            HStack(spacing: 8) {
                TextField(
                    store.tr("Switch lights, set warmth, create a rule or schedule…"),
                    text: $prompt
                )
                .textFieldStyle(.roundedBorder)
                .font(store.scaledFont(12))
                .focused($inputFocused)
                .disabled(isRunning)
                .onSubmit { submitCurrentPrompt() }

                Button {
                    submitCurrentPrompt()
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canSubmit ? store.skinAccentColor : Color.secondary.opacity(0.4))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canSubmit)
                .help(store.tr("Run"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Quick-example chips
            VStack(alignment: .leading, spacing: 6) {
                Text(store.tr("Examples").uppercased())
                    .font(store.scaledFont(9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 6),
                        GridItem(.flexible(), spacing: 6),
                    ],
                    spacing: 6
                ) {
                    ForEach(exampleChips, id: \.self) { chip in
                        Button {
                            runPrompt(chip)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(store.skinAccentColor)
                                Text(chip)
                                    .font(store.scaledFont(10.5))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                    .fill(store.cardBackgroundColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: store.smallRadius, style: .continuous)
                                    .strokeBorder(store.cardBorderColor, lineWidth: 0.75)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            // Replies & executed actions
            ScrollView {
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 24))
                            .foregroundStyle(store.skinAccentColor.opacity(0.65))
                        Text(store.tr("Ask in plain English or German to control rooms, lamps, themes, scenes, rules, sensors, or schedules."))
                            .font(store.scaledFont(11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            entryCard(entry)
                        }
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Calm footer note
            HStack {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(store.tr("Optional · Local-first · Turn off anytime in Settings"))
                    .font(store.scaledFont(10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 400, idealHeight: 470)
        .onAppear {
            inputFocused = true
        }
    }

    private var canSubmit: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitCurrentPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        prompt = ""
        runPrompt(text)
    }

    private func runPrompt(_ text: String) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let response = await store.runAskAIPrompt(text)
            await MainActor.run {
                entries.insert(AskAIEntry(prompt: text, response: response), at: 0)
                isRunning = false
            }
        }
    }

    private func entryCard(_ entry: AskAIEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(entry.prompt)
                    .font(store.scaledFont(11.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if entry.response.source == "ollama" {
                    Text("Ollama")
                        .font(store.scaledFont(9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
            }

            if !entry.response.reply.isEmpty {
                Text(entry.response.reply)
                    .font(store.scaledFont(11.5))
                    .foregroundStyle(entry.response.matched ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !entry.response.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.response.actions) { action in
                        HStack(spacing: 5) {
                            Image(systemName: action.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(action.ok ? Color.green : Color.orange)
                            Text(action.summary)
                                .font(store.scaledFont(10.5, weight: .medium))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((action.ok ? Color.green : Color.orange).opacity(0.12))
                        )
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .fill(store.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: store.cardRadius, style: .continuous)
                .strokeBorder(store.cardBorderColor, lineWidth: 0.75)
        )
    }
}
