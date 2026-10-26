import Foundation
import SwiftData
import SwiftUI

@MainActor enum PurchaseChecks {
    /// A controllable store double verifies the production coordinator, not a second entitlement implementation.
    final class Client: PurchaseClient {
        var rights: [ProGrant] = []
        var failRead = false, failOffers = false, failRestore = false, failPurchase = false
        var outcome: PurchaseOutcome = .cancelled
        var purchases = 0, restores = 0, finishes = 0, reads = 0
        var heldPurchase: CheckedContinuation<Void, Never>?
        var holdPurchase = false
        var heldRead: CheckedContinuation<[ProGrant], Error>?
        var holdRead = false
        var stream: AsyncStream<PurchaseUpdate>.Continuation?
        func offers() async throws -> [PurchaseOffer] {
            if failOffers { throw PurchaseFailure.unavailable }
            return ProProduct.allCases.map { PurchaseOffer(product: $0, price: "Test price") }
        }
        func entitlements() async throws -> [ProGrant] {
            reads += 1
            if holdRead { holdRead = false; return try await withCheckedThrowingContinuation { heldRead = $0 } }
            if failRead { throw PurchaseFailure.verification }
            return rights
        }
        func purchase(_ product: ProProduct) async throws -> PurchaseOutcome {
            purchases += 1
            if holdPurchase { await withCheckedContinuation { heldPurchase = $0 } }
            if failPurchase { throw PurchaseFailure.unavailable }
            return outcome
        }
        func restore() async throws { restores += 1; if failRestore { throw PurchaseFailure.unavailable } }
        func updates() -> AsyncStream<PurchaseUpdate> { AsyncStream { stream = $0 } }
        private func finished() { finishes += 1 }
        func delivery(_ grant: ProGrant) -> PurchaseDelivery {
            PurchaseDelivery(grant: grant, finish: { [weak self] in await self?.finished() })
        }
    }

    /// Free statistics: exactly this month and the previous one, by the user's calendar and zone.
    private static func freeStatisticsWindow(require: (Bool, String) throws -> Void) throws {
        for zone in ["Australia/Sydney", "Asia/Shanghai", "America/New_York", "Europe/London", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!; calendar.firstWeekday = 2
            func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
                calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
            }
            func month(_ date: Date) -> DateComponents { calendar.dateComponents([.year, .month], from: date) }
            // Year change, leap February, both daylight-saving transitions and an ordinary month.
            for (now, previous) in [(at(2026, 1, 15), (2025, 12)), (at(2024, 3, 1, 0), (2024, 2)), (at(2026, 10, 4), (2026, 9)),
                                    (at(2026, 4, 5), (2026, 3)), (at(2026, 11, 30, 23), (2026, 10)), (at(2026, 3, 29), (2026, 2))] {
                let months = ProAccess.freeStatisticsMonths(now: now, calendar: calendar)
                try require(months.current.contains(now) && month(months.current.start) == month(now), "\(zone): current month holds now")
                try require(month(months.previous.start) == DateComponents(year: previous.0, month: previous.1), "\(zone): previous month")
                try require(months.previous.end == months.current.start && calendar.component(.day, from: months.previous.start) == 1
                            && calendar.component(.hour, from: months.previous.start) == 0, "\(zone): months are adjacent and start at midnight")
                func shown(_ date: Date) -> DateInterval { ProAccess.freeStatisticsMonth(for: date, now: now, calendar: calendar) }
                try require(shown(now) == months.current, "\(zone): today shows this month")
                try require(shown(months.previous.start) == months.previous, "\(zone): first instant of last month is allowed")
                try require(shown(months.current.start.addingTimeInterval(-1)) == months.previous, "\(zone): last second of last month is allowed")
                try require(shown(months.current.start) == months.current, "\(zone): month boundary belongs to this month")
                try require(shown(months.previous.start.addingTimeInterval(-1)) == months.current, "\(zone): two months ago is Pro only")
                try require(shown(months.current.end) == months.current && shown(months.current.end.addingTimeInterval(86_400 * 40)) == months.current,
                            "\(zone): future months are Pro only")
            }
        }
    }

    /// Before this launch verifies the plan, over-limit creation is neither unlocked nor reported as a free limit.
    private static func unconfirmedAccess(require: (Bool, String) throws -> Void) async throws {
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TaskBackup.invalid("Purchase: unconfirmed access timed out")
        }
        func outcome(_ store: PurchaseStore, _ quota: ProQuota, _ count: Int) -> String {
            do { try store.requireCreation(quota, count: count); return "allowed" }
            catch let error as ProStatusUnconfirmedError { return error.failed ? "failed" : "checking" }
            catch is ProLimitError { return "limit" }
            catch { return "other" }
        }
        let later = Date().addingTimeInterval(3600)
        for round in 1...3 {
            // Exercise the editor preflight itself, rather than just its synchronous decision helper.
            let withinLimit = Client(); withinLimit.failRead = true
            let freeSave = PurchaseStore(client: withinLimit)
            for quota in ProQuota.allCases {
                await freeSave.confirmCreation([(quota, quota.limit - 1)])
                try require(withinLimit.reads == 0 && !freeSave.accessConfirmed,
                            "free-sized save never starts verification (\(round))")
                for confirmed in [false, true] {
                    try require(ProAccess.creationDecision(quota, count: quota.limit - 1, isPro: false, confirmed: confirmed) == .allowed, "within the free limit never waits (\(round))")
                    try require(ProAccess.creationDecision(quota, count: quota.limit, isPro: true, confirmed: confirmed) == .allowed, "verified Pro is not capped (\(round))")
                }
                try require(ProAccess.creationDecision(quota, count: quota.limit, isPro: false, confirmed: false) == .unconfirmed, "unknown plan is not a free limit (\(round))")
                try require(ProAccess.creationDecision(quota, count: quota.limit, isPro: false, confirmed: true) == .limit, "verified free plan keeps its limit (\(round))")
            }
            // Launch before the first verification: free-sized creation proceeds, over-limit asks to retry, never upsells.
            let free = Client()
            let launching = PurchaseStore(client: free)
            try require(!launching.accessConfirmed && !launching.accessUnavailable && !launching.isPro, "launch starts unconfirmed (\(round))")
            try require(outcome(launching, .lists, ProQuota.lists.limit - 1) == "allowed", "free-sized creation needs no verification (\(round))")
            try require(outcome(launching, .lists, ProQuota.lists.limit) == "checking", "over-limit before verification is not a free-plan error (\(round))")
            try await until { launching.accessConfirmed }
            try require(!launching.isPro && outcome(launching, .lists, ProQuota.lists.limit) == "limit", "the triggered check settles a verified free plan (\(round))")

            // Verification failure at launch keeps free limits, never unlocks, and says the status is unknown.
            let broken = Client(); broken.failRead = true; broken.rights = [ProGrant(product: .lifetime, expires: nil)]
            let offline = PurchaseStore(client: broken)
            await offline.refresh()
            try require(offline.accessUnavailable && !offline.isPro, "failed verification is unknown, not Pro (\(round))")
            try require(outcome(offline, .accounts, ProQuota.accounts.limit) == "failed", "failure explains the unconfirmed status (\(round))")
            try require(outcome(offline, .accounts, ProQuota.accounts.limit - 1) == "allowed", "failure does not block free-sized creation (\(round))")
            broken.failRead = false
            await offline.refresh()
            try require(offline.isPro && outcome(offline, .accounts, ProQuota.accounts.limit + 3) == "allowed", "retry restores verified Pro (\(round))")

            // A save waits for the in-flight check, then sees verified Pro.
            let paid = Client(); paid.rights = [ProGrant(product: .annual, expires: later)]; paid.holdRead = true
            let waiting = PurchaseStore(client: paid)
            let waiter = Task { @MainActor in await waiting.confirmCreation([(.books, ProQuota.books.limit)], timeout: .seconds(5)); return waiting.isPro }
            try await until { paid.heldRead != nil }
            try require(!waiting.accessConfirmed, "held verification is still unconfirmed (\(round))")
            let freeSaveStarted = ContinuousClock.now
            await waiting.confirmCreation([(.accounts, 0), (.books, 0), (.budgets, 0), (.recurringBills, 0)])
            try require(ContinuousClock.now - freeSaveStarted < .seconds(1) && paid.heldRead != nil && paid.reads == 1,
                        "free save does not wait behind an in-flight verification (\(round))")
            paid.heldRead?.resume(returning: paid.rights); paid.heldRead = nil
            let unlocked = await waiter.value
            try require(unlocked && outcome(waiting, .books, ProQuota.books.limit) == "allowed", "the save proceeds after Pro is verified (\(round))")

            // The wait is bounded and does not unlock by timing out.
            let slow = Client(); slow.rights = [ProGrant(product: .lifetime, expires: nil)]; slow.holdRead = true
            let stalled = PurchaseStore(client: slow)
            let started = ContinuousClock.now
            await stalled.confirmCreation([(.books, ProQuota.books.limit), (.budgets, ProQuota.budgets.limit)], timeout: .milliseconds(200))
            try require(ContinuousClock.now - started < .seconds(2), "confirmation wait is bounded (\(round))")
            try require(!stalled.isPro && !stalled.accessConfirmed && outcome(stalled, .recurringBills, ProQuota.recurringBills.limit) == "checking", "a timeout never unlocks (\(round))")
            try await until { slow.heldRead != nil }
            try require(slow.reads == 1, "multiple exceeded quotas share one verification (\(round))")
            slow.heldRead?.resume(returning: []); slow.heldRead = nil
            try await until { stalled.accessConfirmed }
            try require(!stalled.isPro, "late empty rights settle the free plan (\(round))")
        }
    }

    private static func privacyLinks(require: (Bool, String) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "appLanguage")
        defer {
            if let previous { defaults.set(previous, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }
        for (language, key) in [("zh", "TallyPrivacyPolicyURL"), ("en", "TallyPrivacyPolicyEnglishURL")] {
            defaults.set(language, forKey: "appLanguage")
            let configured = Bundle.main.object(forInfoDictionaryKey: key) as? String
            try require(configured != nil && PurchaseCatalog.privacyURL?.scheme == "https", "public privacy link is configured for \(language)")
            try require(PurchaseCatalog.privacyURL?.absoluteString == configured, "privacy link follows the selected app language")
        }
    }

    private static func mixedEntitlements(require: (Bool, String) throws -> Void) async throws {
        typealias Record = Result<ProGrant, PurchaseFailure>
        func read(_ records: [Record]) async throws -> [ProGrant] {
            let stream = AsyncStream<Record> { continuation in
                for record in records { continuation.yield(record) }
                continuation.finish()
            }
            return try await StoreKitPurchaseClient.verifiedGrants(from: stream) { try $0.get() }
        }
        let lifetime = ProGrant(product: .lifetime, expires: nil)
        let annual = ProGrant(product: .annual, expires: Date().addingTimeInterval(3600))
        let expired = ProGrant(product: .monthly, expires: Date().addingTimeInterval(-3600))
        let revoked = ProGrant(product: .lifetime, expires: nil, revoked: true)
        for valid in [lifetime, annual] {
            for failure in [PurchaseFailure.verification, .unavailable] {
                let mixtures: [[Record]] = [[.failure(failure), .success(valid)], [.success(valid), .failure(failure)]]
                for records in mixtures {
                    let grants = try await read(records)
                    try require(grants == [valid], "a failed record cannot discard valid Pro in either order")
                    let client = Client(); client.rights = grants
                    let store = PurchaseStore(client: client)
                    await store.refresh()
                    try require(store.isPro && store.accessConfirmed && store.verificationError == nil,
                                "a fresh launch recognizes verified Pro despite a bad record")
                }
            }
        }
        let incomplete: [[Record]] = [[.failure(.verification)], [.failure(.unavailable), .success(expired)],
                                     [.success(revoked), .failure(.verification)]]
        for records in incomplete {
            do {
                _ = try await read(records)
                try require(false, "incomplete verification must not confirm a free plan")
            } catch PurchaseFailure.verification {
                try require(true, "incomplete verification remains unknown without active verified Pro")
            }
        }
        let empty = try await read([])
        try require(empty.isEmpty, "a successful empty read confirms no entitlement")
        let inactive = try await read([.success(expired), .success(revoked)])
        try require(inactive == [expired, revoked] && !ProAccess.hasPro(inactive, at: Date()),
                    "verified expiry and refund still remove Pro")
        let both = try await read([.success(annual), .failure(.verification), .success(lifetime)])
        try require(both == [annual, lifetime], "all valid rights survive a failed middle record")
        let cancelled = Task { @MainActor in
            let stream = AsyncStream<Record> { $0.yield(.success(lifetime)); $0.finish() }
            return try await StoreKitPurchaseClient.verifiedGrants(from: stream) { _ in throw CancellationError() }
        }
        do {
            _ = try await cancelled.value
            try require(false, "cancellation must not be treated as a failed record")
        } catch is CancellationError {
            try require(true, "cancellation propagates without changing rights")
        }
    }

    static func run() async throws {
        var count = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TaskBackup.invalid("Purchase: " + message) }; count += 1
        }
        func until(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TaskBackup.invalid("Purchase: asynchronous delivery timed out")
        }
        try await mixedEntitlements(require: require)
        #if JIANSHI_APP_STORE
        try require(!PurchaseStore.shared.developerUnlocked, "App Store build cannot inherit developer unlock")
        #endif
        let now = Date(), later = now.addingTimeInterval(3600)
        for _ in 0..<3 {
            for quota in ProQuota.allCases {
                for n in [0, quota.limit - 1, quota.limit, quota.limit + 1, 1001] {
                    try require(ProAccess.permitsCreation(quota, count: n, isPro: false) == (n < quota.limit), "free quota boundary")
                    try require(ProAccess.permitsCreation(quota, count: n, isPro: true), "Pro does not add a payment cap")
                }
            }
            for product in ProProduct.allCases {
                let client = Client(), store = PurchaseStore(client: Client())
                try require(!store.isPro, "loading is never an unverified unlock")
                let grant = ProGrant(product: product, expires: product == .lifetime ? nil : later)
                client.rights = [grant]; client.outcome = .purchased(client.delivery(grant))
                let purchase = PurchaseStore(client: client)
                await purchase.buy(product)
                try require(purchase.isPro && client.purchases == 1 && client.finishes == 1 && !purchase.busy, "verified purchase grants before finish")
                // New coordinator models a reinstall or the other platform reading the same App Store rights.
                let restored = PurchaseStore(client: client)
                await restored.restore()
                try require(restored.isPro && client.restores == 1, "restore on another client")
                client.failOffers = true; await restored.loadOffers()
                try require(restored.isPro && restored.offerError != nil, "catalog failure must not expire rights")
                client.failRead = true
                await restored.refresh()
                try require(restored.isPro && restored.verificationError != nil, "verification failure retains still-valid rights")
                client.failRestore = true; await restored.restore()
                try require(restored.isPro && restored.message != nil, "restore failure preserves current entitlement")
                client.failRead = false; client.rights = []
                await restored.refresh()
                try require(!restored.isPro && restored.loaded, "verified empty rights revoke prior entitlement")
                let revoked = ProGrant(product: product, expires: later, revoked: true)
                try require(!revoked.active(at: now), "refund never grants access")
                if product != .lifetime {
                    try require(!grant.active(at: later) && grant.active(at: now), "expiry boundary is exclusive")
                    client.rights = [ProGrant(product: product, expires: later.addingTimeInterval(86400))]
                    await restored.refresh()
                    try require(restored.isPro, "verified grace-period end grants access")
                }
            }
        }
        let client = Client(), store = PurchaseStore(client: Client())
        await store.restore()
        try require(!store.isPro && store.message != nil, "restore without a purchase is a clear result")
        let active = ProGrant(product: .annual, expires: later)
        let lifetime = ProGrant(product: .lifetime, expires: nil)
        client.rights = [ProGrant(product: .annual, expires: later, revoked: true), lifetime]
        let combined = PurchaseStore(client: client)
        await combined.refresh()
        try require(combined.isPro && combined.lifetime, "refunding subscription leaves lifetime intact")
        await combined.buy(.monthly)
        try require(client.purchases == 0, "lifetime owner is not sold another subscription")
        client.rights = [active, ProGrant(product: .lifetime, expires: nil, revoked: true)]
        await combined.refresh()
        try require(combined.isPro && !combined.lifetime, "refunding lifetime leaves paid subscription intact")

        let interrupted = Client(), coordinator = PurchaseStore(client: Client())
        await coordinator.buy(.annual)
        try require(!coordinator.isPro && !coordinator.busy && coordinator.message == nil, "cancel is not an error or unlock")
        let flow = PurchaseStore(client: interrupted)
        interrupted.failPurchase = true; await flow.buy(.monthly)
        try require(!flow.isPro && !flow.busy && flow.message != nil, "failed purchase can be retried")
        interrupted.failPurchase = false; interrupted.holdPurchase = true
        interrupted.rights = [active]; interrupted.outcome = .purchased(interrupted.delivery(active))
        let first = Task { await flow.buy(.annual) }
        try await until { interrupted.heldPurchase != nil }
        let before = interrupted.purchases
        await flow.buy(.annual); await flow.restore()
        try require(interrupted.purchases == before && interrupted.restores == 0, "rapid buy and restore are serialized")
        interrupted.heldPurchase?.resume(); interrupted.heldPurchase = nil
        await first.value
        try require(flow.isPro && !flow.busy, "purchase finishes after its view closes")

        let pending = Client(), waiting = PurchaseStore(client: Client())
        await waiting.refresh()
        pending.outcome = .pending
        let pendingStore = PurchaseStore(client: pending)
        pendingStore.start(); await pendingStore.buy(.monthly); await pendingStore.buy(.monthly)
        try require(!pendingStore.isPro && pendingStore.pendingProduct == .monthly && pending.purchases == 1, "Ask to Buy does not unlock or purchase twice")
        pending.rights = [active]
        pending.stream?.yield(.verified(pending.delivery(active)))
        try await until { pendingStore.isPro && pending.finishes == 1 }
        try require(pendingStore.pendingProduct == nil && pendingStore.message == nil, "approval clears pending feedback while no purchase page is open")
        pending.stream?.yield(.unverified)
        try await until { pendingStore.verificationError != nil }
        try require(pendingStore.isPro, "unverified update cannot overwrite verified valid rights")
        pending.stream?.finish()
        let declined = Client(), retryApproval = PurchaseStore(client: Client())
        await retryApproval.refresh()
        declined.outcome = .pending
        let approval = PurchaseStore(client: declined)
        await approval.buy(.monthly)
        await approval.restore()
        try require(!approval.isPro && approval.pendingProduct == nil, "explicit restore permits retry after declined approval without granting access")
        declined.rights = [active]; declined.outcome = .purchased(declined.delivery(active))
        await approval.buy(.annual)
        try require(approval.isPro && declined.purchases == 2, "a declined approval does not permanently disable purchases")

        let race = Client(), racingStore = PurchaseStore(client: Client())
        await racingStore.refresh()
        let racing = PurchaseStore(client: race)
        race.holdRead = true
        let oldRead = Task { await racing.refresh() }
        try await until { race.heldRead != nil }
        race.rights = [lifetime]
        await racing.refresh()
        race.heldRead?.resume(returning: []); race.heldRead = nil
        _ = await oldRead.value
        try require(racing.isPro, "late old snapshot cannot erase a newer entitlement")

        let expiringClient = Client(), expiring = PurchaseStore(client: Client())
        await expiring.refresh()
        expiringClient.rights = [ProGrant(product: .monthly, expires: Date().addingTimeInterval(0.08))]
        let expiryStore = PurchaseStore(client: expiringClient)
        await expiryStore.refresh()
        try require(expiryStore.isPro, "paid period initially active")
        expiringClient.failRead = true
        try await until { expiryStore.verificationError != nil }
        try require(!expiryStore.isPro, "known expiry is honoured even when renewal verification fails")

        try await restoreFeedback(require: require)
        try await unconfirmedAccess(require: require)
        try freeStatisticsWindow(require: require)
        try privacyLinks(require: require)
        // Weekly drag scheduling is part of the free plan: the real drag engine needs no entitlement.
        let week = WeekDrag()
        let task = TaskItem(title: "Synthetic schedule")
        var drops = 0
        week.allDay = CGRect(x: 0, y: 0, width: 700, height: 50)
        week.canvas = CGRect(x: 0, y: 50, width: 700, height: 1000)
        week.viewport = week.canvas
        week.layout = TimelineLayout.make(blocks: [], fullDay: true, density: 1)
        week.begin(task, color: .blue, grabOffset: 0) { _, _ in drops += 1 }
        week.move(to: CGPoint(x: 100, y: 20))
        try require(week.isDragging && week.zone != .none, "free week drag reaches all-day")
        week.complete()
        try require(drops == 1 && week.taskID == nil, "free week drop commits")
        week.begin(task, color: .blue, grabOffset: 0) { _, _ in drops += 1 }
        week.move(to: CGPoint(x: 100, y: 100)); week.complete(); week.complete()
        try require(drops == 2, "free week drop commits once per release")
        try dataProtection(require: require)
        try await creationProtection(require: require)
        print("PURCHASE PASS: \(count) checks — purchases, restore, expiry, quotas, free weekly scheduling, data protection")
    }

    private static func restoreFeedback(require: (Bool, String) throws -> Void) async throws {
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw TaskBackup.invalid("Purchase: restore feedback timed out")
        }
        let grant = ProGrant(product: .annual, expires: Date().addingTimeInterval(3600))
        let success = L("购买已恢复，Pro 已解锁。", "Purchases restored. Pro is unlocked.")
        let empty = L("此 App Store 账号没有有效的 Pro 购买。现有数据不受影响。", "No active Pro purchase was found for this App Store account. Your data is unaffected.")
        for round in 1...3 {
            for result in ["pro", "empty", "failure", "cancelled"] {
                let client = Client()
                let subject = PurchaseStore(client: client)
                client.rights = [grant]; await subject.refresh()
                client.holdRead = true
                let restoring = Task { await subject.restore() }
                try await until { client.heldRead != nil }
                let older = client.heldRead; client.heldRead = nil
                client.rights = result == "empty" ? [] : [grant]
                client.failRead = result == "failure"
                if result == "cancelled" {
                    client.holdRead = true
                    let checking = Task { await subject.refresh() }
                    try await until { client.heldRead != nil }
                    checking.cancel()
                    client.heldRead?.resume(returning: [grant]); client.heldRead = nil
                    _ = await checking.value
                } else { await subject.refresh() }
                older?.resume(returning: [])
                await restoring.value
                try require(!subject.busy && subject.message != nil, "superseded restore always reports a result (\(result), \(round))")
                if result == "pro" { try require(subject.isPro && subject.message == success, "newer verified Pro reports restore success") }
                else if result == "empty" { try require(!subject.isPro && subject.message == empty, "newer verified empty rights report no purchase") }
                else {
                    try require(subject.isPro && subject.message != success && subject.message != empty,
                                "failed/cancelled verification cannot turn cached Pro into restore success")
                    client.failRead = false; await subject.restore()
                    try require(subject.isPro && subject.message == success, "restore retry clears the failed result")
                }
            }
            // The newer read is still pending when restore's own stale read finishes.
            let client = Client()
            let waiting = PurchaseStore(client: client)
            client.holdRead = true
            let restoring = Task { await waiting.restore() }
            try await until { client.heldRead != nil }
            let older = client.heldRead; client.heldRead = nil
            client.holdRead = true
            let checking = Task { await waiting.refresh() }
            try await until { client.heldRead != nil }
            older?.resume(returning: [])
            try await Task.sleep(for: .milliseconds(80))
            try require(waiting.busy && !waiting.isPro, "restore waits for newer verification without granting access")
            client.heldRead?.resume(returning: [grant]); client.heldRead = nil
            _ = await checking.value; await restoring.value
            try require(waiting.isPro && !waiting.busy && waiting.message == success, "pending newer verification completes restore feedback")
        }
    }

    private static func creationProtection(require: (Bool, String) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-quota-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for round in 1...3 {
            let container = try Store.make(url: directory.appendingPathComponent("synthetic-\(round).sqlite"))
            let context = container.mainContext
            let client = Client(), store = PurchaseStore(client: client)
            await store.refresh()
            for (index, id) in ListTree.defaultListIDs.enumerated() {
                try require(id == TaskItem.syncIdentity("tally-default-list-\(index)"), "default identity stays compatible")
                let list = TaskList(name: "Renamed default \(index)"); list.id = id; context.insert(list)
            }
            try Store.save(context)
            // The free plan counts every list, including the three created on first launch (renamed or not).
            for index in 0..<2 {
                let lists = try context.fetch(FetchDescriptor<TaskList>())
                try require(lists.count == 3 + index, "renamed defaults count toward the list quota")
                try store.requireCreation(.lists, count: lists.count)
                let list = TaskList(name: index == 0 ? "Work" : "Custom \(index)")
                list.parentID = ListTree.defaultListIDs[0]
                context.insert(list); try Store.save(context)
            }
            let all = try context.fetch(FetchDescriptor<TaskList>())
            var deniedList = false
            do { try store.requireCreation(.lists, count: all.count) }
            catch is ProLimitError { deniedList = true }
            try require(all.count == 5 && deniedList, "three defaults plus two new lists fill the free quota; a sixth list does not fit")
            context.delete(all.first { $0.id == ListTree.defaultListIDs[1] }!); try Store.save(context)
            let afterDelete = try context.fetch(FetchDescriptor<TaskList>())
            try require(afterDelete.count == 4, "deleting a default list frees its slot")
            try store.requireCreation(.lists, count: afterDelete.count)
            let refill = TaskList(name: "Refill"); context.insert(refill); try Store.save(context)

            var ledger = FinanceData.initial
            ledger.books = (0..<3).map { MoneyBook(name: "Budget book \($0)") }
            try FinanceStore.update(context) { $0 = ledger }
            let first = ledger.books[0].id, second = ledger.books[1].id, third = ledger.books[2].id
            func setBudget(_ id: UUID, _ amount: Decimal?) throws {
                try FinanceStore.update(context) { data in
                    let original = data.books.first { $0.id == id }!
                    var changed = original; changed.budget = amount
                    try store.requireBudget(amount, for: id, books: data.books)
                    try data.updateBook(changed, expected: original, baseCurrency: data.baseCurrency)
                }
            }
            // Two editors both saw no budgets. Only the first successful commit consumes the free slot.
            let initialIDs = Set(ledger.books.filter { $0.budget != nil }.map(\.id))
            try require(ProAccess.budgetCreationCount(for: first, budgetedBookIDs: initialIDs) == 0
                        && ProAccess.budgetCreationCount(for: second, budgetedBookIDs: initialIDs) == 0, "two initial budget previews are allowed")
            try setBudget(first, 100)
            let beforeDenied = try FinanceStore.read(context)!
            var deniedBudget = false
            do { try setBudget(second, 200) } catch is ProLimitError { deniedBudget = true }
            try require(deniedBudget && (try FinanceStore.read(context) == beforeDenied), "fresh budget count blocks concurrent second save atomically")
            try setBudget(first, 150)
            try setBudget(second, nil)
            try require(try FinanceStore.read(context)?.books.first { $0.id == first }?.budget == 150,
                        "editing an existing budget and clearing an unset budget remain allowed")
            try setBudget(first, nil); try setBudget(second, 200)
            try require(try FinanceStore.read(context)?.books.first { $0.id == second }?.budget == 200,
                        "clearing the first budget releases its slot for retry")

            client.rights = [ProGrant(product: .annual, expires: Date().addingTimeInterval(3600))]
            await store.refresh(); try setBudget(first, 100)
            client.rights = []; await store.refresh()
            try setBudget(first, 175); try setBudget(second, 250)
            try FinanceStore.update(context) { data in data.books[0].archived = true }
            try setBudget(first, 180)
            deniedBudget = false
            var holderMessage = ""
            do { try setBudget(third, 300) } catch let error as ProLimitError { deniedBudget = true; holderMessage = error.localizedDescription }
            try require(deniedBudget, "archived budgets still count; expiry protects existing budgets only")
            try require(holderMessage.contains("Budget book 0") && holderMessage.contains("Budget book 1")
                        && holderMessage.contains(L("（已归档）", " (archived)")) && !holderMessage.contains("Budget book 2"),
                        "the limit names every book using a budget and marks the archived one")
            try require(ProAccess.budgetHolders(excluding: first, books: try FinanceStore.read(context)!.books) == "“Budget book 1”",
                        "the book being edited is not listed as its own blocker")
            // Import/sync/recovery write the ledger directly, outside user-creation quota checks.
            try FinanceStore.update(context) { data in data.books[2].budget = 300 }
            let snapshot = try TaskBackup.capture(context)
            let restored = try Store.make(url: directory.appendingPathComponent("restored-\(round).sqlite"))
            try snapshot.restore(restored.mainContext, replace: true)
            try require(try FinanceStore.read(restored.mainContext)?.books.filter { $0.budget != nil }.count == 3,
                        "over-limit budgets survive backup restore")
            try require(try restored.mainContext.fetch(FetchDescriptor<TaskList>()).count == 5,
                        "every list survives backup restore")
            try setBudget(first, nil); try setBudget(second, nil); try setBudget(third, nil)
            try setBudget(first, 50)
            try require(try FinanceStore.read(context)?.books.filter { $0.budget != nil }.count == 1,
                        "after clearing excess budgets the free slot can be used again")

            let unknown = PurchaseStore(client: Client())
            let budgetedBooks = [first, second].map { id in var book = MoneyBook(name: "Budgeted"); book.id = id; book.budget = 1; return book }
            try unknown.requireBudget(150, for: first, books: budgetedBooks)
            try unknown.requireBudget(nil, for: third, books: budgetedBooks)
            try require(!unknown.accessConfirmed, "editing and clearing budgets require no purchase verification")
        }
    }

    private static func dataProtection(require: (Bool, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-purchase-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try Store.make(url: directory.appendingPathComponent("synthetic.sqlite"))
        let context = container.mainContext
        var ledger = FinanceData.initial
        ledger.accounts = (0..<8).map { MoneyAccount(name: "Test \($0)", opening: 100) }
        ledger.books += (0..<3).map { MoneyBook(name: "Test book \($0)") }
        try FinanceStore.update(context) { $0 = ledger }
        try require(try FinanceStore.read(context)?.accounts.count == 8, "over-quota import/sync-shaped ledger still saves")
        var denied = false
        do {
            try FinanceStore.update(context) { data in
                try ProAccess.requireCreation(.accounts, count: data.accounts.filter { !$0.archived }.count, isPro: false)
                data.accounts.append(MoneyAccount(name: "Denied"))
            }
        } catch is ProLimitError { denied = true }
        try require(denied && (try FinanceStore.read(context)?.accounts.count == 8), "denied creation is atomic")
        try FinanceStore.update(context) { data in
            data.accounts[7].name = "Edited after expiry"
            var entry = MoneyEntry(); entry.title = "Still usable"; entry.amount = 10; entry.baseAmount = 10
            entry.accountID = data.accounts[7].id; entry.bookID = data.books[0].id; entry.accountAmount = 10
            data.entries.append(entry)
        }
        let saved = try FinanceStore.read(context)!
        try require(saved.balance(ledger.accounts[7].id) == 90 && saved.accounts.count == 8, "all eight accounts still accept entries after expiry")
        let snapshot = try TaskBackup.capture(context)
        let restored = try Store.make(url: directory.appendingPathComponent("restored.sqlite"))
        try snapshot.restore(restored.mainContext, replace: true)
        try require(try FinanceStore.read(restored.mainContext)?.accounts.count == 8, "backup restore never applies purchase quotas")
        try FinanceStore.update(context) { data in data.accounts[7].archived = true }
        try FinanceStore.update(context) { data in data.accounts[7].archived = false }
        try require(try FinanceStore.read(context)?.accounts.filter { !$0.archived }.count == 8, "unarchive never locks existing over-limit data")
        var template = MoneyEntry(); template.title = "Existing recurring"; template.amount = 1; template.baseAmount = 1
        template.accountID = ledger.accounts[0].id; template.accountAmount = 1; template.bookID = ledger.books[0].id
        template.date = MoneyEntry.timestamp(Date().addingTimeInterval(-86400))
        try FinanceStore.update(context) { data in
            for _ in 0..<4 { try data.addRecurring(MoneyRecurring(repeating: template, rule: "daily", until: nil, in: data)) }
        }
        let recurring = try FinanceStore.read(context)!.recurringBills[3]
        try FinanceStore.update(context) { data in try data.postOccurrence(of: recurring.id, scheduled: recurring.nextDate) }
        let afterPosting = try FinanceStore.read(context)!
        try require(afterPosting.recurringBills.count == 4 && afterPosting.entries.contains { $0.id == recurring.entryID(for: recurring.nextDate) }, "existing over-limit recurring bills continue posting after expiry")
        let backup = try snapshot.encoded()
        try require(!String(decoding: backup, as: UTF8.self).contains("isPro"), "purchase state is absent from user backups")
    }
}

/// Visual checks use synthetic entitlement values and never start StoreKit, storage or cloud services.
struct PurchaseUIFixture: View {
    @AppStorage("appLanguage") private var language = "en"
    @State private var showing = true
    @State private var store: PurchaseStore
    private let client: PurchaseChecks.Client
    init() {
        let client = PurchaseChecks.Client()
        self.client = client
        _store = State(initialValue: PurchaseStore(client: client))
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("LOCAL TEST • Synthetic purchases").font(.headline)
            Picker("Language", selection: $language) {
                Text("English").tag("en"); Text("简体中文").tag("zh")
            }.pickerStyle(.segmented)
            Button("Free / expired") { client.rights = []; Task { await store.refresh() } }
            Button("Annual") {
                client.rights = [ProGrant(product: .annual, expires: Date().addingTimeInterval(86400))]
                Task { await store.refresh() }
            }
            Button("Lifetime") {
                client.rights = [ProGrant(product: .lifetime, expires: nil)]
                Task { await store.refresh() }
            }
            Button("Open Pro") { showing = true }
        }.padding(24)
        .sheet(isPresented: $showing) { ProView(store: store) }
    }
}
