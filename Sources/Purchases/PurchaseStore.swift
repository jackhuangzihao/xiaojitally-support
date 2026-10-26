import Foundation
import Observation
import OSLog

@MainActor @Observable final class PurchaseStore {
    static let shared: PurchaseStore = {
        #if JIANSHI_DEVELOPER_PRO && !JIANSHI_APP_STORE
        PurchaseStore(client: StoreKitPurchaseClient(), developerUnlocked: true)
        #else
        PurchaseStore(client: StoreKitPurchaseClient())
        #endif
    }()
    private static let log = Logger(subsystem: "local.jianshi", category: "Purchases")
    private(set) var offers: [PurchaseOffer] = []
    private(set) var grants: [ProGrant] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var loadingOffers = false
    private(set) var message: String?
    private(set) var verificationError: String?
    private(set) var offerError: String?
    private(set) var pendingProduct: ProProduct?
    private(set) var clock = Date()
    let developerUnlocked: Bool
    @ObservationIgnored private let client: any PurchaseClient
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var verifiedGeneration = 0
    @ObservationIgnored private var refreshesInFlight = 0

    init(client: any PurchaseClient, developerUnlocked: Bool = false) {
        self.client = client; self.developerUnlocked = developerUnlocked
    }
    deinit { listener?.cancel(); expiryTask?.cancel() }
    var isPro: Bool { _ = clock; return developerUnlocked || ProAccess.hasPro(grants, at: Date()) }
    var lifetime: Bool { grants.contains { $0.product == .lifetime && $0.active } }
    var expiry: Date? { grants.filter(\.active).compactMap(\.expires).max() }
    /// Whether this launch knows the plan: verified Pro, or verified rights that include no active Pro.
    /// Unknown is neither Pro nor free: it never unlocks and never shows a free-plan limit or upsell.
    var accessConfirmed: Bool { developerUnlocked || isPro || loaded }
    /// Verification failed before any verified result this launch.
    var accessUnavailable: Bool { !accessConfirmed && verificationError != nil }

    func start() {
        guard !developerUnlocked, listener == nil else { return }
        let updates = client.updates()
        listener = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { break }
                await self?.receive(update)
            }
        }
    }
    private func receive(_ update: PurchaseUpdate) async {
        switch update {
        case .verified(let delivery):
            deliver(delivery.grant)
            await delivery.finish()
            _ = await refresh()
        case .unverified:
            verificationError = PurchaseFailure.verification.localizedDescription
            Self.log.error("Unverified purchase update ignored")
        }
    }
    private func deliver(_ grant: ProGrant) {
        refreshGeneration += 1 // An older in-flight snapshot must not undo this delivery.
        grants.removeAll { $0.product == grant.product }
        grants.append(grant)
        if grant.active { pendingProduct = nil; message = nil }
        loaded = true; clock = Date()
        scheduleExpiry()
        Self.log.notice("Verified entitlement delivered; product=\(grant.product.rawValue, privacy: .public), revoked=\(grant.revoked)")
    }
    @discardableResult func refresh() async -> Bool {
        if developerUnlocked { loaded = true; return true }
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let next = try await client.entitlements()
            guard generation == refreshGeneration, !Task.isCancelled else { return false }
            if next != grants { message = nil }
            grants = next; loaded = true; verificationError = nil; clock = Date()
            verifiedGeneration = generation
            if next.contains(where: \.active) { pendingProduct = nil }
            scheduleExpiry()
            return true
        } catch {
            guard generation == refreshGeneration else { return false }
            // Keep only the already verified, still-valid rights on a transient failure.
            verificationError = L("购买状态暂时无法验证，请重试。", "Purchase status could not be verified. Please retry.")
            clock = Date()
            Self.log.error("Entitlement refresh failed; existing verified rights retained until expiry")
            return false
        }
    }
    func loadOffers() async {
        guard !developerUnlocked, !loadingOffers else { return }
        loadingOffers = true
        defer { loadingOffers = false }
        do {
            offers = try await client.offers()
            offerError = offers.isEmpty ? PurchaseFailure.unavailable.localizedDescription : nil
        } catch { offerError = PurchaseFailure.unavailable.localizedDescription }
    }
    func buy(_ product: ProProduct) async {
        guard !busy, !developerUnlocked, !lifetime, pendingProduct == nil else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await client.purchase(product) {
            case .purchased(let delivery):
                deliver(delivery.grant)
                await delivery.finish()
                _ = await refresh()
                message = isPro ? L("购买已完成，Pro 已解锁。", "Purchase complete. Pro is unlocked.")
                    : L("交易已处理，请重试验证购买状态。", "Transaction processed. Please retry purchase verification.")
            case .pending:
                pendingProduct = product
                message = L("购买正在等待批准，批准后会自动解锁。请勿重复购买。", "Purchase is awaiting approval and will unlock automatically. Please do not purchase again.")
            case .cancelled: break
            }
        } catch {
            message = L("购买未完成，请重试或恢复购买。", "Purchase was not completed. Retry or restore purchases.")
            Self.log.error("Purchase failed; no unverified rights granted")
        }
    }
    func restore() async {
        guard !busy, !developerUnlocked else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await client.restore()
            let beforeVerification = refreshGeneration
            var refreshed = await refresh()
            if !refreshed {
                // A foreground/update refresh may supersede ours. Only its completed, verified result is usable.
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while verifiedGeneration != refreshGeneration, refreshesInFlight > 0, ContinuousClock.now < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(50))
                }
                refreshed = !Task.isCancelled && verifiedGeneration > beforeVerification && verifiedGeneration == refreshGeneration
            }
            // Explicit restore also lets a declined/cancelled approval be retried. Apple still owns any pending request.
            if refreshed { pendingProduct = nil }
            message = !refreshed ? (verificationError ?? L("购买状态暂时无法验证，请重试。", "Purchase status could not be verified. Please retry.")) : isPro
                ? L("购买已恢复，Pro 已解锁。", "Purchases restored. Pro is unlocked.")
                : L("此 App Store 账号没有有效的 Pro 购买。现有数据不受影响。", "No active Pro purchase was found for this App Store account. Your data is unaffected.")
        } catch {
            message = L("暂时无法恢复购买，请检查网络和 App Store 账号后重试。", "Unable to restore purchases. Check your connection and App Store account, then retry.")
            Self.log.error("Restore purchases failed; user data untouched")
        }
    }
    func requireCreation(_ quota: ProQuota, count: Int) throws {
        switch ProAccess.creationDecision(quota, count: count, isPro: isPro, confirmed: accessConfirmed) {
        case .allowed: return
        case .limit: throw ProLimitError(quota: quota)
        case .unconfirmed:
            let failed = accessUnavailable
            if refreshesInFlight == 0 { startRefresh() }
            throw ProStatusUnconfirmedError(failed: failed)
        }
    }
    /// Wait only for over-limit creation. A book and its new budget share one bounded wait.
    /// The save must still recheck every quota against current data after this returns.
    func confirmCreation(_ quotas: [(ProQuota, Int)], timeout: Duration = .seconds(3)) async {
        guard quotas.contains(where: {
            ProAccess.creationDecision($0.0, count: $0.1, isPro: isPro, confirmed: accessConfirmed) == .unconfirmed
        }) else { return }
        if refreshesInFlight == 0 { startRefresh() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !accessConfirmed, refreshesInFlight > 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    /// Counted before the task starts, so a waiter never misses a refresh that has not begun yet.
    private func startRefresh() {
        refreshesInFlight += 1
        Task { [weak self] in
            _ = await self?.refresh()
            self?.refreshesInFlight -= 1
        }
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = grants.filter(\.active).compactMap(\.expires).min() else { return }
        let seconds = max(0.05, next.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            self.clock = Date()
            _ = await self.refresh()
        }
    }
}
