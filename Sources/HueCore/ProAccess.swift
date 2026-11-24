import Foundation

/// High-level access tier for Maprisma Hue Lights:
/// - `free`: Real Philips Hue Bridge connected without Pro unlock (Rooms, Zones, Lights, Scenes, Pairing, Help, Native skin).
/// - `demo`: Interactive simulated Hue home where ALL Pro features are unlocked for risk-free evaluation & App Store Review.
/// - `pro`: Verified one-time StoreKit 2 Non-Consumable Pro unlock (`com.maprisma.huelights.pro`).
public enum AppAccessMode: String, Codable, Sendable, Equatable {
    case free
    case demo
    case pro
}

/// Features unlocked by the one-time Maprisma Hue Lights Pro purchase (and freely previewable in Demo Mode).
public enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    case floorplan
    case rules
    case motionAware
    case audioSynth
    case skins
    case askAI
    case mcp

    public var id: String { rawValue }
}

/// Pure, `Sendable` Free / Demo / Pro access policy.
/// In GUI builds, `isProUnlocked` must be sourced strictly from StoreKit 2 (`Transaction.currentEntitlements`).
public struct ProAccessPolicy: Sendable {
    /// Non-Consumable In-App Purchase Product ID in App Store Connect & `MaprismaHueLights.storekit`.
    public static let proProductID = "com.maprisma.huelights.pro"

    /// Resolves the active access mode. Pro takes precedence over Demo, which takes precedence over Free.
    public static func mode(isProUnlocked: Bool, isDemoMode: Bool) -> AppAccessMode {
        if isProUnlocked {
            return .pro
        }
        if isDemoMode {
            return .demo
        }
        return .free
    }

    /// Returns `true` whenever Pro is unlocked OR the user is in Demo Mode (all Pro features previewable).
    /// Returns `false` only in Free mode on a real Philips Hue Bridge.
    public static func isUnlocked(_ feature: ProFeature, isProUnlocked: Bool, isDemoMode: Bool) -> Bool {
        let _ = feature
        return isProUnlocked || isDemoMode
    }

    /// Returns `true` for the free native macOS skin (`"native"`, `"system"`, or empty).
    public static func isSkinFree(_ skin: String) -> Bool {
        let normalized = skin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "native" || normalized == "system"
    }

    /// Typed convenience check for `AppSkin`.
    public static func isSkinFree(_ skin: AppSkin) -> Bool {
        skin == .system
    }
}
