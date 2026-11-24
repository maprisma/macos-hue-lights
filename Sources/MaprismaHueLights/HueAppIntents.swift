#if canImport(AppIntents)
import AppIntents
import Foundation
import HueCore

@available(macOS 13.0, *)
struct AllLightsOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off All Hue Lights"
    static var description = IntentDescription("Switches off every Philips Hue light connected to Maprisma Lights.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            HueStore.shared.allOff()
        }
        return .result(dialog: "Turned off all Hue lights.")
    }
}

@available(macOS 13.0, *)
struct AllLightsOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn On All Hue Lights"
    static var description = IntentDescription("Switches on all non-excluded Philips Hue rooms.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            HueStore.shared.allOn(confirmed: true)
        }
        return .result(dialog: "Turned on all Hue lights.")
    }
}

@available(macOS 13.0, *)
struct ToggleRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Hue Room"
    static var description = IntentDescription("Toggles a Philips Hue room or zone by name.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Room Name")
    var roomName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = roomName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resultText: String = await MainActor.run {
            let store = HueStore.shared
            guard let room = store.snapshot.rooms.first(where: {
                $0.name.lowercased() == query || $0.name.lowercased().contains(query)
            }) else {
                return "Could not find a room named \(roomName)."
            }
            let nextOn = !room.on
            store.setRoom(room, on: nextOn)
            return nextOn ? "Turned on \(room.name)." : "Turned off \(room.name)."
        }
        return .result(dialog: IntentDialog(stringLiteral: resultText))
    }
}

@available(macOS 13.0, *)
struct RecallSceneIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Hue Scene"
    static var description = IntentDescription("Activates a Philips Hue scene by name.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Scene Name")
    var sceneName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let query = sceneName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resultText: String = await MainActor.run {
            let store = HueStore.shared
            for room in store.snapshot.rooms {
                if let scene = room.scenes.first(where: {
                    $0.name.lowercased() == query || $0.name.lowercased().contains(query)
                }) {
                    store.recall(scene)
                    return "Activated scene \(scene.name) in \(room.name)."
                }
            }
            return "Could not find a scene named \(sceneName)."
        }
        return .result(dialog: IntentDialog(stringLiteral: resultText))
    }
}

@available(macOS 13.0, *)
struct ToggleSynthIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Hue Light Synthesizer"
    static var description = IntentDescription("Starts or stops the audio-reactive Light Synthesizer.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let running = await HueStore.shared.toggleSynthFromIntent()
        return .result(dialog: running ? "Started the Light Synthesizer." : "Stopped the Light Synthesizer.")
    }
}

@available(macOS 13.0, *)
struct HueAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: [
                "Turn off all lights in \(.applicationName)",
                "All Hue lights off in \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: AllLightsOnIntent(),
            phrases: [
                "Turn on all lights in \(.applicationName)",
                "All Hue lights on in \(.applicationName)",
            ]
        )
        AppShortcut(
            intent: ToggleSynthIntent(),
            phrases: [
                "Toggle Light Synthesizer in \(.applicationName)",
                "Sync lights to music in \(.applicationName)",
            ]
        )
    }
}
#endif
