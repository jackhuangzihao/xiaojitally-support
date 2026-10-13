import Foundation
import SwiftData

extension SelfCheck {
    /// Repeatable release benchmark. Uses its own store; never reads the user's database.
    static func performance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-Performance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.make(url: root.appendingPathComponent("source.store")), context = store.mainContext
        let day = Dates.calendar.startOfDay(for: Date())
        let lists = (0..<20).map { TaskList(name: "List \($0)") }
        lists.forEach { context.insert($0) }
        var tasks: [TaskItem] = []
        for index in 0..<5000 {
            let start = day.addingTimeInterval(Double(index % 90 - 30) * 86400 + Double(index % 12 + 7) * 3600)
            let task = TaskItem(title: "Task \(index)", scheduledAt: start, list: lists[index % lists.count])
            task.notes = "Searchable note \(index)"; task.priority = index % 3
            task.hasTime = true; task.endAt = start.addingTimeInterval(Double(index % 4 + 1) * 900)
            if index < 20 { task.repeatRule = "weekly" }
            context.insert(task); tasks.append(task)
        }
        func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try work()
            print(String(format: "PERF %@: %.1f ms", name, (ProcessInfo.processInfo.systemUptime - start) * 1000))
            return result
        }
        try measure("save 5000 tasks") { try Store.save(context) }
        try measure("edit one of 5000 tasks") { tasks[0].notes = "Edited note"; try Store.save(context) }
        let week = Dates.weekCells(day), month = Dates.monthCells(day)
        _ = measure("week layout 5000 tasks") { let indexed = CalendarIndex.byDay(tasks, days: week); return week.map { PlanBlock.layout(indexed[$0] ?? [], day: $0) } }
        _ = measure("month grouping 5000 tasks") { CalendarIndex.byDay(tasks, days: month).mapValues { TaskItem.ordered($0, incompleteFirst: true) } }
        _ = measure("list calendar dots 5000 tasks") { CalendarIndex.byDay(tasks, days: month).mapValues { $0.filter { !$0.isDone }.count } }
        var filter = TaskFilter(); filter.priority = 2
        _ = measure("search and filters 5000 tasks") { tasks.filter { CalendarTaskSearch.matches($0, query: "note") && filter.matches($0, lists: lists, today: day) } }
        let cache = RepeatPreview(), range = DateInterval(start: month[0], end: month.last!.addingTimeInterval(86400))
        _ = measure("repeat projections first") { cache.items(tasks, in: range) }
        _ = measure("repeat projections cached") { cache.items(tasks, in: range) }
        let backup = try measure("backup snapshot 5000 tasks") { try TaskBackup.capture(context) }
        let encoded = try measure("backup encode and validate 5000 tasks") { try backup.encoded() }
        let decoded = try measure("backup decode 5000 tasks") { try TaskBackup.decode(encoded, allowLargeFile: true) }
        let restored = try Store.make(url: root.appendingPathComponent("restored.store"))
        try measure("restore 5000 tasks") { try decoded.restore(restored.mainContext, replace: true) }
        let result = try TaskBackup.capture(restored.mainContext)
        guard Set(result.tasks.map(\.id)) == Set(backup.tasks.map(\.id)), result.tasks.count == 5000 else { throw TaskBackup.invalid("Performance restore lost records") }
        var finance = FinanceData.initial
        let account = MoneyAccount(name: "Performance", opening: 100000)
        finance.accounts = [account]
        finance.entries = (0..<5000).map { index in
            var entry = MoneyEntry(); entry.title = "Entry \(index)"; entry.amount = 10; entry.accountAmount = 10; entry.baseAmount = 10
            entry.accountID = account.id; entry.bookID = finance.books[0].id; return entry
        }
        try measure("save 5000 money entries") { try FinanceStore.stage(finance, in: context); try Store.save(context) }
        try measure("edit one of 5000 money entries") { try FinanceStore.update(context) { $0.entries[0].title = "Edited" } }
        let historyCount = try SyncChanges.read(context)?.count
        let evictionStore = try Store.make(url: root.appendingPathComponent("history-cache-eviction.store"))
        let evictionKey = SyncChanges.key("task", UUID())
        try SyncChanges.stage([evictionKey: .init(date: day, fingerprint: try SyncChanges.fingerprint("Cache eviction"))], in: evictionStore.mainContext)
        try Store.save(evictionStore.mainContext, trackSyncChanges: false)
        try measure("edit one of 5000 money entries, cold sync-history cache") {
            try FinanceStore.update(context) { $0.entries[0].notes = "Cold cache edit" }
        }
        for round in 1...3 {
            try SyncChanges.stage([evictionKey: .init(date: day, fingerprint: try SyncChanges.fingerprint("Evict \(round)"))], in: evictionStore.mainContext)
            try Store.save(evictionStore.mainContext, trackSyncChanges: false)
            var ticks = 0, maximumGap = 0.0
            let heartbeat = Task { @MainActor in
                var previous = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumGap = max(maximumGap, now - previous); previous = now; ticks += 1
                }
            }
            let start = ProcessInfo.processInfo.systemUptime
            try await SyncChanges.withPreparedHistory(in: context) {
                try measure("prepared foreground commit, round \(round)") {
                    try FinanceStore.update(context) { $0.entries[0].notes = "Responsive cold save \(round)" }
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            try await Task.sleep(for: .milliseconds(10))
            heartbeat.cancel(); await heartbeat.value
            guard ticks > 1, try FinanceStore.read(context)?.entries[0].notes == "Responsive cold save \(round)" else {
                throw TaskBackup.invalid("Cold save blocked the main actor or lost the edit")
            }
            print(String(format: "PERF prepared cold save round %d: total %.1f ms; main-actor maximum gap %.1f ms; heartbeat %d ticks",
                         round, elapsed * 1000, maximumGap * 1000, ticks))
        }
        try SyncChanges.stage([evictionKey: .init(date: day, fingerprint: try SyncChanges.fingerprint("Second cache eviction"))], in: evictionStore.mainContext)
        try Store.save(evictionStore.mainContext, trackSyncChanges: false)
        let preparationStart = ProcessInfo.processInfo.systemUptime
        guard try await SyncChanges.prepareHistory(in: context) else { throw TaskBackup.invalid("Performance history preparation was not cold") }
        print(String(format: "PERF background sync-history preparation, 5000 tasks/5000 entries: %.1f ms", (ProcessInfo.processInfo.systemUptime - preparationStart) * 1000))
        try measure("first edit of 5000 money entries after background preparation") {
            try FinanceStore.update(context) { $0.entries[0].notes = "Prepared cache edit" }
        }
        try measure("lightweight backup capture with 5000 money entries") { _ = try TaskBackup.capture(context, includeFinance: false); _ = try FinanceStore.payload(context) }
        let money = try FinanceStore.read(context)!
        let history = try SyncChanges.read(context), editedKey = SyncChanges.key("entry", money.entries[0].id)
        guard money.entries.count == 5000, money.balance(account.id) == 50000,
              history?.count == historyCount,
              try history?[editedKey]?.fingerprint == SyncChanges.fingerprint(money.entries[0]),
              try history?[editedKey]?.fields?["notes"]?.fingerprint == SyncChanges.fingerprint("Prepared cache edit"),
              history?[editedKey]?.fields?["notes"]?.date != nil else {
            throw TaskBackup.invalid("Performance edit changed ledger totals or lost sync history")
        }
        let payload = try FinanceStore.payload(context)!
        try measure("20 uncached decode+validate reads, 5000 entries") {
            for _ in 0..<20 {
                let value = try JSONDecoder().decode(FinanceData.self, from: payload)
                try value.validate()
                guard value.entries.count == 5000 else { throw TaskBackup.invalid("Uncached ledger read lost entries") }
            }
        }
        try measure("20 cached store reads, 5000 entries") {
            for _ in 0..<20 {
                guard try FinanceStore.read(context) == money else { throw TaskBackup.invalid("Cached ledger read changed entries") }
            }
        }
        try FinanceChecks.performance()
        try CloudSync.snapshotPerformance(in: context)
        print("PERF PASS: 5000-task and 5000-entry save, layout, search, preview and backup restore")
    }
}

extension FinanceChecks {
    /// Compare the actual old asset-page scans with the shared snapshot. Never opens user data.
    static func performance() throws {
        var ledger = FinanceData.initial
        ledger.accounts = (0..<100).map { MoneyAccount(name: "Account \($0)", opening: Decimal($0 * 100), archived: $0 % 9 == 0) }
        ledger.entries = (0..<5000).map { index in
            var entry = MoneyEntry(); entry.amount = 10; entry.accountAmount = 10; entry.baseAmount = 10
            entry.accountID = ledger.accounts[index % 100].id
            switch index % 5 {
            case 0: entry.kind = .transfer; entry.destinationID = ledger.accounts[(index + 1) % 100].id; entry.destinationAmount = 10; entry.fee = 1
            case 1: entry.kind = .income
            case 2: entry.kind = .refund
            case 3: entry.kind = .adjustment; entry.accountAmount = -10
            default: break
            }
            if index % 7 == 0 { entry.deletedAt = Date() }
            return entry
        }
        let start = ProcessInfo.processInfo.systemUptime
        let expected = Dictionary(uniqueKeysWithValues: ledger.accounts.map { ($0.id, ledger.balance($0.id)) })
        let scanned = ProcessInfo.processInfo.systemUptime
        let balances = ledger.accountBalances()
        let aggregated = ProcessInfo.processInfo.systemUptime
        guard balances == expected else { throw TaskBackup.invalid("Asset aggregation differs from account history") }
        print(String(format: "PERF assets 100 accounts / 5000 entries: repeated scans %.1f ms; one pass %.1f ms", (scanned - start) * 1000, (aggregated - scanned) * 1000))
    }

}

extension CloudSync {
    /// Called only with the performance check's disposable store; no CloudKit or user data access.
    @MainActor static func snapshotPerformance(in context: ModelContext) throws {
        let local = try TaskBackup.capture(context), baseline = try CloudMerge.bytes(local)
        let cached = SnapshotCache(contextID: ObjectIdentifier(context), revision: Store.revision, baseline: baseline,
                                   local: local, localBytes: baseline, base: try TaskBackup.decode(baseline, allowLargeFile: true))
        guard let historyBytes = try context.fetch(FetchDescriptor<CloudSyncState>()).first?.changeHistory else {
            throw TaskBackup.invalid("Performance snapshot is missing persisted sync history")
        }
        let history = try JSONDecoder().decode(SyncChanges.Revisions.self, from: historyBytes)
        print("PERF sync payload, \(local.tasks.count) tasks/\(local.finance?.entries.count ?? 0) entries: snapshot \(baseline.count) bytes; stored history \(historyBytes.count) bytes; upload limit \(maximumSnapshotBytes) bytes")
        guard baseline.count <= maximumSnapshotBytes, history == local.syncChanges,
              cached.base?.syncChanges == local.syncChanges,
              try cached.base.map({ try CloudMerge.bytes($0) }) == baseline else {
            throw TaskBackup.invalid("Performance snapshot exceeds the upload limit or changes metadata during serialization")
        }
        print("PERF sync metadata round-trip: \(history.count) records; stored and cloud metadata preserved")
        var uncached: [Double] = [], reused: [Double] = []
        for _ in 0..<3 {
            var start = ProcessInfo.processInfo.systemUptime
            let captured = try TaskBackup.capture(context), encoded = try CloudMerge.bytes(captured)
            let base = try TaskBackup.decode(baseline, allowLargeFile: true)
            uncached.append(ProcessInfo.processInfo.systemUptime - start)
            guard encoded == cached.localBytes, try CloudMerge.bytes(base) == baseline else {
                throw TaskBackup.invalid("Sync cache differs from uncached preparation")
            }
            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1000 {
                guard cached.matches(context, baseline: baseline), cached.localBytes == baseline else {
                    throw TaskBackup.invalid("Unchanged sync poll did not reuse its prepared snapshot")
                }
            }
            reused.append((ProcessInfo.processInfo.systemUptime - start) / 1000)
        }
        print(String(format: "PERF unchanged sync snapshot, %d tasks/%d entries: uncached %.3f ms/poll, cached %.6f ms/poll (median of 3)",
                     local.tasks.count, local.finance?.entries.count ?? 0, uncached.sorted()[1] * 1000, reused.sorted()[1] * 1000))
    }
}
