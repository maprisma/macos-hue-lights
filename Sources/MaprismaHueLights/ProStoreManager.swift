import Combine
import Foundation
import HueCore
import StoreKit

/// StoreKit 2 manager for the one-time Non-Consumable Pro unlock (`com.maprisma.huelights.pro`).
/// 100% macOS 13+ compatible using `ObservableObject` and `@Published`.
/// Entitlement status is verified cryptographically via `Transaction.currentEntitlements` and `Transaction.updates`.
@MainActor
public final class ProStoreManager: ObservableObject {
    public enum VerificationError: Error {
        case failedVerification
    }

    @Published public private(set) var isProUnlocked: Bool = false
    @Published public private(set) var proProduct: Product? = nil
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isPurchasing: Bool = false
    @Published public private(set) var statusMessage: String? = nil
    @Published public private(set) var errorMessage: String? = nil

    #if DEBUG
    /// Developer-only override in Xcode Debug builds to test Free vs. Pro UX without touching Release security.
    @Published public var debugOverridePro: Bool? = nil
    #endif

    /// Effective Pro unlock state. Strictly `isProUnlocked` (StoreKit 2 verified) in Release builds.
    public var effectiveProUnlocked: Bool {
        #if DEBUG
        if let override = debugOverridePro {
            return override
        }
        #endif
        return isProUnlocked
    }

    /// Localized StoreKit price once loaded, or `nil` while loading / unavailable.
    public var formattedPrice: String? {
        proProduct?.displayPrice
    }

    public var isProductLoaded: Bool {
        proProduct != nil
    }

    private var updatesTask: Task<Void, Never>?
    private var started: Bool = false
    private let tr: @MainActor (String) -> String

    public init(translator: (@MainActor (String) -> String)? = nil) {
        self.tr = translator ?? { HueStore.shared.tr($0) }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Policy Helpers

    public func accessMode(isDemoMode: Bool) -> AppAccessMode {
        ProAccessPolicy.mode(isProUnlocked: effectiveProUnlocked, isDemoMode: isDemoMode)
    }

    public func isUnlocked(_ feature: ProFeature, isDemoMode: Bool) -> Bool {
        ProAccessPolicy.isUnlocked(feature, isProUnlocked: effectiveProUnlocked, isDemoMode: isDemoMode)
    }

    public func isSkinUnlocked(_ skin: AppSkin, isDemoMode: Bool) -> Bool {
        ProAccessPolicy.isSkinFree(skin)
            || ProAccessPolicy.isUnlocked(.skins, isProUnlocked: effectiveProUnlocked, isDemoMode: isDemoMode)
    }

    public func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    // MARK: - StoreKit 2 Lifecycle

    /// Idempotently loads the Pro product, checks current entitlements, and listens for live transaction updates.
    public func start() {
        guard !started else { return }
        started = true

        Task { [weak self] in
            await self?.loadProductAndEntitlements()
        }

        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { break }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    public func loadProductAndEntitlements() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let products = try await Product.products(for: [ProAccessPolicy.proProductID])
            proProduct = products.first
        } catch {
            // Keep fallback price silently at startup (e.g. offline or local dev builds).
            proProduct = nil
        }

        await refreshEntitlements()
    }

    /// Verifies active StoreKit 2 entitlements via `Transaction.currentEntitlements`.
    public func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result),
               transaction.productID == ProAccessPolicy.proProductID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isProUnlocked = unlocked
        try? SettingsStore().setLastVerifiedPro(unlocked)
    }

    /// Runs the one-time Non-Consumable purchase flow with graceful handling of cancellation, pending, and errors.
    public func purchasePro() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        statusMessage = nil
        errorMessage = nil
        defer { isPurchasing = false }

        if proProduct == nil {
            do {
                let products = try await Product.products(for: [ProAccessPolicy.proProductID])
                proProduct = products.first
            } catch {
                errorMessage = tr("Could not load the Pro product from the App Store.")
                return
            }
        }

        guard let product = proProduct else {
            errorMessage = tr("Could not load the Pro product from the App Store.")
            return
        }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                if transaction.productID == ProAccessPolicy.proProductID && transaction.revocationDate == nil {
                    isProUnlocked = true
                    try? SettingsStore().setLastVerifiedPro(true)
                    statusMessage = tr("Pro unlocked!")
                }
                await transaction.finish()
            case .userCancelled:
                break
            case .pending:
                statusMessage = tr("Purchase is pending approval.")
            @unknown default:
                break
            }
        } catch VerificationError.failedVerification {
            errorMessage = tr("Purchase could not be verified.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Syncs with the App Store and re-checks current entitlements (Apple App Review requirement).
    public func restorePurchases() async {
        guard !isPurchasing else { return }
        isLoading = true
        statusMessage = nil
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = isProUnlocked
                ? tr("Pro unlocked!")
                : tr("No previous purchase found.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }
        if transaction.productID == ProAccessPolicy.proProductID {
            let active = (transaction.revocationDate == nil)
            isProUnlocked = active
            try? SettingsStore().setLastVerifiedPro(active)
        }
        await transaction.finish()
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw VerificationError.failedVerification
        case .verified(let safe):
            return safe
        }
    }
}
