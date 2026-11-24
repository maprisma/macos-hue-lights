import Carbon.HIToolbox
import Foundation
import HueCore

/// App Sandbox-safe global keyboard shortcut manager using Carbon `RegisterEventHotKey`.
/// Requires zero Accessibility permissions and works cleanly in the Mac App Store sandbox.
@MainActor
final class GlobalHotKeyManager {
    private static let signature: OSType = 0x4D485545 // "MHUE"

    var onAction: ((HotKeyAction) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]

    init() {
        installHandlerIfNeeded()
    }

    func update(bindings: [HotKeyAction: HotKeyPreset]) {
        unregisterAll()
        for (action, preset) in bindings {
            guard let keyCode = preset.keyCode, preset != .none else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.carbonID)
            let status = RegisterEventHotKey(
                keyCode,
                preset.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let registered = ref {
                hotKeyRefs[action] = registered
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                return noErr
            }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let firedID = hotKeyID.id
            Task { @MainActor in
                manager.dispatch(carbonID: firedID)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func dispatch(carbonID: UInt32) {
        guard let action = HotKeyAction.allCases.first(where: { $0.carbonID == carbonID }) else { return }
        onAction?(action)
    }
}
