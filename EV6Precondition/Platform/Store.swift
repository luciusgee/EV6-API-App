import Foundation
import StoreKit

/// The one-off Pro unlock.
@MainActor
@Observable
final class Store {
    static let shared = Store()

    /// The non-consumable in App Store Connect.
    static let productID = "com.luciusgee.ev6precondition.pro"
    /// Off until the in-app purchase exists in App Store Connect: until then everything is unlocked, so
    /// TestFlight builds aren't locked out of anything.
    static let paywallEnabled = false

    private(set) var product: Product?
    private(set) var purchased = false
    private(set) var busy = false
    var error: String?
    @ObservationIgnored private var updates: Task<Void, Never>?

    var isPro: Bool { !Self.paywallEnabled || purchased }

    func start() async {
        guard Self.paywallEnabled else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        await refresh()
        await loadProduct()
    }

    /// Fetches the Pro product; nil when the App Store can't be reached or doesn't list it.
    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product != nil { error = nil }
        } catch {
            product = nil
        }
    }

    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        purchased = owned
    }

    func buy() async {
        guard let product else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let t):
                    await t.finish()
                    purchased = true
                case .unverified:
                    error = "The App Store couldn't verify this purchase. Try Restore purchase, or try again later."
                }
            case .pending:
                // Ask to Buy, or the bank's confirmation: it finishes later through Transaction.updates.
                error = "Waiting for approval. Pro unlocks once the purchase is approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restore() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            self.error = error.localizedDescription
            return
        }
        await refresh()
        if !purchased { error = "No previous Pro purchase was found for this Apple ID." }
    }
}
