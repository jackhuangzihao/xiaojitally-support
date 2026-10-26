import Foundation
import StoreKit
import StoreKitTest
import XCTest

// The isolated XCTest host compiles production purchase code without the app's storage entry point.
func L(_ chinese: String, _ english: String) -> String { english }

@MainActor final class NativePurchaseCheck: XCTestCase {
    private func require(_ value: Bool, _ message: String) throws {
        guard value else {
            throw NSError(domain: "StoreKitCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func session() async throws -> SKTestSession {
        guard Bundle.main.bundleIdentifier?.hasPrefix("local.jianshi.sandboxcheck.") == true,
              let configuration = Bundle(for: Self.self).url(forResource: "TallyPro", withExtension: "storekit") else {
            throw PurchaseFailure.unavailable
        }
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.timeRate = .realTime
        session.clearTransactions()
        let offers = try await StoreKitPurchaseClient().offers()
        try require(Set(offers.map(\.product)) == Set(ProProduct.allCases), "All three local products load")
        try require(offers.allSatisfy { !$0.price.isEmpty }, "Localized prices are present")
        // Stop before a purchase or restore if Xcode did not activate its local test environment.
        guard case .verified(let app) = try await AppTransaction.shared,
              app.environment == .xcode, app.bundleID == Bundle.main.bundleIdentifier else {
            throw NSError(domain: "StoreKitCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local Xcode environment is not active"])
        }
        return session
    }

    private func waitFor(_ store: PurchaseStore, _ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            await store.refresh()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "StoreKitCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func waitForFinishedTransactions() async throws {
        for _ in 0..<100 {
            var unfinished = false
            for await _ in StoreKit.Transaction.unfinished { unfinished = true }
            if !unfinished { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "StoreKitCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Verified transactions were not finished"])
    }

    func testPurchasesRestoreAndExpiry() async throws {
        let session = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        for round in 1...2 {
            for product in ProProduct.allCases {
                session.clearTransactions()
                let store = PurchaseStore(client: StoreKitPurchaseClient())
                store.start()
                try await waitFor(store, "Previous test entitlement was not cleared") { !store.isPro }
                await store.buy(product)
                try await waitFor(store, "Purchase did not unlock \(product)") { store.isPro }
                let restored = PurchaseStore(client: StoreKitPurchaseClient())
                await restored.restore()
                try require(restored.isPro, "New client restores \(product)")
                try require(restored.verificationError == nil && restored.message?.contains("restored") == true,
                            "Restore actually verifies the current purchase")
                try await waitForFinishedTransactions()
                if product == .lifetime {
                    guard let transaction = session.allTransactions().last else { throw PurchaseFailure.unavailable }
                    try session.refundTransaction(identifier: transaction.identifier)
                } else {
                    try session.expireSubscription(productIdentifier: product.rawValue)
                }
                try await waitFor(store, "Expiration/refund did not remove Pro") { !store.isPro }
                for quota in ProQuota.allCases {
                    try require(!ProAccess.permitsCreation(quota, count: quota.limit, isPro: store.isPro),
                                "Free new-item limits return after expiration")
                }
                await restored.restore()
                try require(!restored.isPro, "Restore cannot revive an expired/refunded purchase")
                print("NATIVE STOREKIT CASE PASS: purchase/restore/expiry \(product) round \(round)")
            }
        }
    }

    func testPendingApproval() async throws {
        let session = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let store = PurchaseStore(client: StoreKitPurchaseClient())
        store.start()
        session.askToBuyEnabled = true
        await store.buy(.monthly)
        try require(!store.isPro && store.pendingProduct == .monthly, "Ask to Buy waits without granting access")
        guard let pending = session.allTransactions().last else { throw PurchaseFailure.unavailable }
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitFor(store, "Approved purchase did not unlock Pro") { store.isPro }
        try require(store.pendingProduct == nil, "Approval clears the pending state")
        try await waitForFinishedTransactions()
        print("NATIVE STOREKIT CASE PASS: pending approval and transaction delivery")
    }

    func testFailedPurchaseRetry() async throws {
        let session = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let store = PurchaseStore(client: StoreKitPurchaseClient())
        store.start()
        try await session.setSimulatedError(.generic(.notAvailableInStorefront), forAPI: .purchase)
        await store.buy(.annual)
        try require(!store.isPro && store.message != nil && !store.busy, "Failed purchase is recoverable")
        try await session.setSimulatedError(nil, forAPI: .purchase)
        session.resetToDefaultState()
        session.disableDialogs = true
        let simulatedError = await session.simulatedError(forAPI: .purchase)
        try require(simulatedError == nil, "The injected purchase failure is cleared before retry")
        await store.buy(.annual)
        try await waitFor(store, "Purchase retry did not unlock Pro after clearing the injected failure") { store.isPro }
        try await waitForFinishedTransactions()
        print("NATIVE STOREKIT CASE PASS: purchase failure then retry")
    }

    func testRestoreFailureAndRetry() async throws {
        let session = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let store = PurchaseStore(client: StoreKitPurchaseClient())
        store.start()
        await store.buy(.lifetime)
        try await waitFor(store, "Lifetime purchase did not unlock Pro") { store.isPro }
        try await waitForFinishedTransactions()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        await store.restore()
        try require(store.isPro && !store.busy && store.message?.contains("Unable to restore") == true,
                    "Restore failure keeps verified lifetime access")
        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        session.resetToDefaultState()
        session.disableDialogs = true
        await store.restore()
        try require(store.isPro && store.message?.contains("restored") == true, "Restore retry succeeds")
        print("NATIVE STOREKIT CASE PASS: restore failure preserves access then retry")
    }
}
