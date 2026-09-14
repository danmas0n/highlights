import Foundation
import StoreKit

/// A tip jar and nothing more.
///
/// Deliberately gates nothing. The app was built for one family and shared because other families
/// might like it; asking people to pay for features they've already started relying on would sour
/// exactly the relationship that makes a tip worth giving. Every product here is a consumable —
/// buy one, say thanks, done.
@MainActor
@Observable
final class TipJar {

    /// Ordered smallest to largest. These must match App Store Connect exactly, and the local
    /// `Highlights.storekit` configuration mirrors them for testing before they exist there.
    static let productIDs = [
        "me.jpsj.highlights.tip.small",
        "me.jpsj.highlights.tip.medium",
        "me.jpsj.highlights.tip.large",
    ]

    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchasing: Product.ID?
    /// Set briefly after a successful tip, for a thank-you the UI can show.
    private(set) var thanks: String?
    private(set) var loadError: String?

    /// How many tips this install has given. Kept only so the app can say thank you twice as
    /// warmly the second time; it never leaves the device.
    private(set) var tipCount: Int {
        didSet { UserDefaults.standard.set(tipCount, forKey: "tipjar.count") }
    }

    private var updates: Task<Void, Never>?

    init() {
        tipCount = UserDefaults.standard.integer(forKey: "tipjar.count")
        // Finish anything that completed while the app wasn't running, so a tip interrupted by
        // a phone call still gets its thank-you next time.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result else { continue }
                await transaction.finish()
                self.recordTip()
            }
        }
    }

    func load() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            // StoreKit returns them in arbitrary order; keep the small-to-large order above.
            products = Self.productIDs.compactMap { id in fetched.first { $0.id == id } }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func tip(_ product: Product) async {
        purchasing = product.id
        defer { purchasing = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return }
                await transaction.finish()
                recordTip()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func recordTip() {
        tipCount += 1
        thanks = tipCount == 1
            ? "Thank you. Genuinely — that made my day."
            : "Again? You're very kind. Thank you."
        Task {
            try? await Task.sleep(for: .seconds(4))
            thanks = nil
        }
    }
}
