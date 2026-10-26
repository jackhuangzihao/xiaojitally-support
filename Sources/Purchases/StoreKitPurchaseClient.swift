import StoreKit
import OSLog

struct PurchaseDelivery: Sendable {
    let grant: ProGrant
    let finish: @Sendable () async -> Void
}
enum PurchaseOutcome: Sendable {
    case purchased(PurchaseDelivery), pending, cancelled
}
enum PurchaseUpdate: Sendable { case verified(PurchaseDelivery), unverified }

/// Small StoreKit boundary: regression checks substitute synthetic purchases without touching an account.
@MainActor protocol PurchaseClient {
    func offers() async throws -> [PurchaseOffer]
    func entitlements() async throws -> [ProGrant]
    func purchase(_ product: ProProduct) async throws -> PurchaseOutcome
    func restore() async throws
    func updates() -> AsyncStream<PurchaseUpdate>
}

enum PurchaseFailure: LocalizedError {
    case verification, unavailable
    var errorDescription: String? {
        switch self {
        case .verification: L("暂时无法验证购买。请稍后重试或恢复购买。", "Unable to verify this purchase. Try again or restore purchases.")
        case .unavailable: L("商品暂不可用，请稍后重试。", "This product is unavailable. Please try again later.")
        }
    }
}

@MainActor final class StoreKitPurchaseClient: PurchaseClient {
    private static let log = Logger(subsystem: "local.jianshi", category: "Purchases")
    private var products: [ProProduct: Product] = [:]

    func offers() async throws -> [PurchaseOffer] {
        let fetched = try await Product.products(for: ProProduct.allCases.map(\.rawValue))
        products = Dictionary(uniqueKeysWithValues: fetched.compactMap { value in
            guard let id = ProProduct(rawValue: value.id), value.type == (id == .lifetime ? .nonConsumable : .autoRenewable) else { return nil }
            if id != .lifetime {
                guard let period = value.subscription?.subscriptionPeriod, period.value == 1,
                      period.unit == (id == .monthly ? .month : .year) else { return nil }
            }
            return (id, value)
        })
        return ProProduct.allCases.compactMap { id in products[id].map { PurchaseOffer(product: id, price: $0.displayPrice) } }
    }

    func entitlements() async throws -> [ProGrant] {
        try await Self.verifiedGrants(from: StoreKit.Transaction.currentEntitlements) { result in
            guard case .verified(let transaction) = result else { throw PurchaseFailure.verification }
            guard let id = ProProduct(rawValue: transaction.productID), !transaction.isUpgraded else { return nil }
            var grant = Self.grant(transaction, product: id)
            if id != .lifetime, !grant.active, transaction.revocationDate == nil {
                // A grace-period transaction can have an expired paid period. Verify the renewal info too.
                let product = try await self.product(id)
                if let subscription = product.subscription {
                    var failedVerification = false
                    for status in try await subscription.status where status.state == .inGracePeriod {
                        guard case .verified(let renewal) = status.renewalInfo,
                              case .verified(let current) = status.transaction else {
                            failedVerification = true
                            Self.log.error("Unverified subscription status ignored")
                            continue
                        }
                        if current.id == transaction.id, let end = renewal.gracePeriodExpirationDate {
                            grant = ProGrant(product: id, expires: end)
                        }
                    }
                    if failedVerification && !grant.active { throw PurchaseFailure.verification }
                }
            }
            return grant
        }
    }

    /// A bad record must not hide valid Pro; an incomplete read must not confirm a free plan.
    static func verifiedGrants<Results: AsyncSequence>(from results: Results,
        resolve: (Results.Element) async throws -> ProGrant?) async throws -> [ProGrant] {
        var grants: [ProGrant] = []
        var failedRead = false
        for try await result in results {
            try Task.checkCancellation()
            do {
                if let grant = try await resolve(result) { grants.append(grant) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedRead = true
                Self.log.error("Entitlement record could not be verified; continuing with other records")
            }
        }
        try Task.checkCancellation()
        if failedRead && !grants.contains(where: \.active) { throw PurchaseFailure.verification }
        return grants
    }

    private func product(_ id: ProProduct) async throws -> Product {
        if let value = products[id] { return value }
        _ = try await offers()
        guard let value = products[id] else { throw PurchaseFailure.unavailable }
        return value
    }

    func purchase(_ id: ProProduct) async throws -> PurchaseOutcome {
        let item = try await product(id)
        switch try await item.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result,
                  let product = ProProduct(rawValue: transaction.productID) else { throw PurchaseFailure.verification }
            return .purchased(Self.delivery(transaction, product: product))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw PurchaseFailure.unavailable
        }
    }
    func restore() async throws { try await AppStore.sync() }

    func updates() -> AsyncStream<PurchaseUpdate> {
        AsyncStream { continuation in
            let task = Task {
                // Resuming after a quit also delivers previously verified but unfinished transactions.
                for await result in StoreKit.Transaction.unfinished {
                    if Task.isCancelled { break }
                    Self.yield(result, to: continuation)
                }
                for await result in StoreKit.Transaction.updates {
                    if Task.isCancelled { break }
                    Self.yield(result, to: continuation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func yield(_ result: VerificationResult<StoreKit.Transaction>, to stream: AsyncStream<PurchaseUpdate>.Continuation) {
        guard case .verified(let transaction) = result else { stream.yield(.unverified); return }
        guard let product = ProProduct(rawValue: transaction.productID) else { return }
        stream.yield(.verified(delivery(transaction, product: product)))
    }
    private static func grant(_ transaction: StoreKit.Transaction, product: ProProduct) -> ProGrant {
        ProGrant(product: product, expires: transaction.expirationDate,
                 revoked: transaction.revocationDate != nil || transaction.isUpgraded)
    }
    private static func delivery(_ transaction: StoreKit.Transaction, product: ProProduct) -> PurchaseDelivery {
        PurchaseDelivery(grant: grant(transaction, product: product), finish: { await transaction.finish() })
    }
}
