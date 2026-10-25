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
        product = try? await Product.products(for: [Self.productID]).first
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
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    purchased = true
                }
            case .pending, .userCancelled:
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
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
    }
}
