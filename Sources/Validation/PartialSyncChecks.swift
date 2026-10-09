import Foundation
import SwiftData

@MainActor enum PartialSyncChecks {
    static func run() throws -> Int {
        var count = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("PARTIAL SYNC CHECK: " + label) }; count += 1
        }
        func persisted(_ snapshot: TaskBackup) throws -> TaskBackup {
            try TaskBackup.decode(CloudMerge.bytes(snapshot), allowLargeFile: true)
        }
        func exercise(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup?,
                      inspect: (PartialSyncMerge.Result, Bool) throws -> Void) throws {
            for reversed in [false, true] {
                let left = reversed ? cloud : local, right = reversed ? local : cloud
                let prepared = try PartialSyncMerge.prepare(local: left, cloud: right, base: base, now: now)
                try check(prepared.conflict != nil, "partial synchronization keeps the unresolved review")
                try inspect(prepared, reversed)
                let localBytes = try CloudMerge.bytes(prepared.localSnapshot)
                let cloudBytes = try CloudMerge.bytes(prepared.uploadSnapshot)
                let baseBytes = try CloudMerge.bytes(prepared.baselineSnapshot)
                var next = prepared
                for _ in 0..<3 {
                    next = try PartialSyncMerge.prepare(local: persisted(next.localSnapshot), cloud: persisted(next.uploadSnapshot),
                        base: persisted(next.baselineSnapshot), now: now)
                    try check(next.conflict != nil, "reloading a partial baseline does not swallow the unresolved conflict")
                    try check(try CloudMerge.bytes(next.localSnapshot) == localBytes && CloudMerge.bytes(next.uploadSnapshot) == cloudBytes,
                              "retries preserve each disputed side and already synchronized records")
                    try check(try CloudMerge.bytes(next.baselineSnapshot) == baseBytes,
                              "the unresolved group's original baseline survives retries")
                }
                let choices = Dictionary(uniqueKeysWithValues: prepared.conflict!.items.map { ($0.id, CloudMerge.Choice.local) })
                let resolved = try PartialSyncMerge.prepare(local: next.localSnapshot, cloud: next.uploadSnapshot,
                    base: next.baselineSnapshot, choices: choices, now: now)
                try check(resolved.conflict == nil, "manual review can finish after unrelated records have synchronized")
                try check(try CloudMerge.bytes(resolved.localSnapshot) == CloudMerge.bytes(resolved.uploadSnapshot)
                          && CloudMerge.bytes(resolved.uploadSnapshot) == CloudMerge.bytes(resolved.baselineSnapshot),
                          "a resolved review restores one common snapshot and baseline")
                // Another device may still hold the old cloud-side version and its own partial ancestor.
                let propagated = try PartialSyncMerge.prepare(local: persisted(prepared.uploadSnapshot),
                    cloud: persisted(resolved.uploadSnapshot), base: persisted(prepared.baselineSnapshot), now: now)
                try check(propagated.conflict == nil,
                          "a completed choice propagates to a device that still holds the old disputed version")
                try check(try CloudMerge.bytes(propagated.localSnapshot) == CloudMerge.bytes(resolved.uploadSnapshot),
                          "the other device adopts the reviewed result without discarding independent changes")
            }
        }

        for round in 0..<3 {
            let list = TaskBackup.ListRecord(id: UUID(), name: "Shared list", createdAt: now)
            var disputed = TaskBackup.TaskRecord(TaskItem(title: "Original task")); disputed.listID = list.id
            var independent = TaskBackup.TaskRecord(TaskItem(title: "Independent task")); independent.listID = list.id
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "Account", opening: 1000)
            ledger.accounts = [account]
            let purchase = MoneyEntry(title: "Purchase", date: now, amount: 100, accountID: account.id, accountAmount: 100,
                                      bookID: ledger.books[0].id, baseAmount: 100)
            let independentEntry = MoneyEntry(title: "Independent entry", date: now, amount: 50, accountID: account.id,
                accountAmount: 50, bookID: ledger.books[0].id, baseAmount: 50)
            ledger.entries = [purchase, independentEntry]
            let original = TaskBackup(finance: ledger, lists: [list], tasks: [disputed, independent])
            var local = original, cloud = original
            local.tasks[0].title = "Mac task \(round)"; cloud.tasks[0].title = "Phone task \(round)"
            local.tasks[1].notes = "Mac note"; cloud.tasks[1].priority = 2
            local.finance!.entries[0].notes = "Mac entry note"; cloud.finance!.entries[1].tags = "Phone tag"
            let taskKey = SyncChanges.key("task", disputed.id)
            // Legacy record dates cannot automatically settle the task, and must remain on their original sides.
            local.syncChanges = [taskKey: .init(date: now, fingerprint: try SyncChanges.fingerprint(local.tasks[0]))]
            cloud.syncChanges = [taskKey: .init(date: now, fingerprint: try SyncChanges.fingerprint(cloud.tasks[0]))]
            try exercise(local, cloud, original) { result, reversed in
                let left = reversed ? cloud : local, right = reversed ? local : cloud
                try check(result.localSnapshot.tasks.first { $0.id == disputed.id } == left.tasks[0]
                          && result.uploadSnapshot.tasks.first { $0.id == disputed.id } == right.tasks[0],
                          "disputed task contents remain on their original device and cloud sides")
                try check(result.baselineSnapshot.tasks.first { $0.id == disputed.id } == original.tasks[0],
                          "disputed task retains its shared ancestor")
                for snapshot in [result.localSnapshot, result.uploadSnapshot, result.baselineSnapshot] {
                    let task = snapshot.tasks.first { $0.id == independent.id }
                    try check(task?.notes == "Mac note" && task?.priority == 2, "other tasks in the same stable list continue syncing")
                    try check(snapshot.finance?.entries.first { $0.id == purchase.id }?.notes == "Mac entry note"
                              && snapshot.finance?.entries.first { $0.id == independentEntry.id }?.tags == "Phone tag",
                              "unrelated finance edits continue while a task awaits review")
                }
                try check(result.localSnapshot.syncChanges?[taskKey] == left.syncChanges?[taskKey]
                          && result.uploadSnapshot.syncChanges?[taskKey] == right.syncChanges?[taskKey]
                          && result.baselineSnapshot.syncChanges?[taskKey] == original.syncChanges?[taskKey],
                          "partial merge never joins disputed revision histories")
            }

            local = original; cloud = original
            local.finance!.entries[0].amount = 120; local.finance!.entries[0].accountAmount = 120; local.finance!.entries[0].baseAmount = 120
            cloud.finance!.entries[0].amount = 130; cloud.finance!.entries[0].accountAmount = 130; cloud.finance!.entries[0].baseAmount = 130
            local.finance!.entries[1].notes = "Continues in same account and book"
            cloud.tasks[1].notes = "Task continues"
            try exercise(local, cloud, original) { result, reversed in
                try check(result.localSnapshot.finance?.entries.first { $0.id == purchase.id }?.amount == (reversed ? 130 : 120)
                          && result.uploadSnapshot.finance?.entries.first { $0.id == purchase.id }?.amount == (reversed ? 120 : 130),
                          "disputed monetary postings do not leak to the other side")
                for snapshot in [result.localSnapshot, result.uploadSnapshot, result.baselineSnapshot] {
                    try check(snapshot.finance?.entries.first { $0.id == independentEntry.id }?.notes == "Continues in same account and book",
                              "another posting using stable shared accounts and books continues syncing")
                    try check(snapshot.tasks.first { $0.id == independent.id }?.notes == "Task continues",
                              "unrelated tasks continue through a monetary conflict")
                }
            }

            // Refunds depend on both the original purchase and every other refund in their family.
            let refund = MoneyEntry(kind: .refund, title: "Refund", date: now, amount: 20, accountID: account.id,
                accountAmount: 20, bookID: ledger.books[0].id, baseAmount: 20, refundOf: purchase.id)
            local.finance!.entries.append(refund)
            var otherRefund = refund; otherRefund.id = UUID(); otherRefund.amount = 30; otherRefund.accountAmount = 30; otherRefund.baseAmount = 30
            cloud.finance!.entries.append(otherRefund)
            try exercise(local, cloud, original) { result, reversed in
                let ownRefund = reversed ? otherRefund.id : refund.id, remoteRefund = reversed ? refund.id : otherRefund.id
                try check(result.localSnapshot.finance!.entries.contains { $0.id == ownRefund }
                          && !result.localSnapshot.finance!.entries.contains { $0.id == remoteRefund },
                          "local refund family stays intact")
                try check(result.uploadSnapshot.finance!.entries.contains { $0.id == remoteRefund }
                          && !result.uploadSnapshot.finance!.entries.contains { $0.id == ownRefund },
                          "cloud refund family stays intact")
                try check(!result.baselineSnapshot.finance!.entries.contains { $0.kind == .refund },
                          "unsynchronized refund additions do not enter the common baseline")
            }

            // A disputed list holds references to that list, but not tasks outside its hierarchy.
            local = original; cloud = original
            local.lists[0].name = "Mac list"; cloud.lists[0].name = "Phone list"
            local.tasks[1].notes = "Depends on held list"
            let outside = TaskBackup.TaskRecord(TaskItem(title: "Outside every list"))
            cloud.tasks.append(outside)
            try exercise(local, cloud, original) { result, reversed in
                try check(result.localSnapshot.lists[0].name == (reversed ? "Phone list" : "Mac list"),
                          "a disputed list stays on its original side")
                try check(result.localSnapshot.tasks.first { $0.id == independent.id }?.notes == (reversed ? "" : "Depends on held list"),
                          "dependent task edits wait with their disputed list")
                try check(result.localSnapshot.tasks.contains { $0.id == outside.id }
                          && result.uploadSnapshot.tasks.contains { $0.id == outside.id },
                          "tasks outside a held list hierarchy can still synchronize")
            }

            // Removing a parent while the other side adds a child holds the complete category family.
            local = original; cloud = original
            let parentCategory = ledger.categories[0]
            local.finance!.categories.removeAll { $0.id == parentCategory.id }
            let childCategory = MoneyCategory(name: "New child", parentID: parentCategory.id)
            cloud.finance!.categories.append(childCategory)
            local.tasks[1].notes = "Outside category family"
            try exercise(local, cloud, original) { result, reversed in
                try check(result.localSnapshot.finance!.categories.contains { $0.id == parentCategory.id } == reversed
                          && result.localSnapshot.finance!.categories.contains { $0.id == childCategory.id } == reversed,
                          "deleted parents and new children stay on their original sides together")
                try check(result.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Outside category family",
                          "a category family review does not stall unrelated task edits")
            }

            // Manual rate disputes are independent of existing postings, whose recorded amounts are locked.
            var rated = original
            rated.finance!.rates = [.init(base: "USD", quote: "CNY", rate: 7, date: "2026-10-09", source: "Manual")]
            local = rated; cloud = rated
            local.finance!.rates[0].rate = 8; cloud.finance!.rates[0].rate = 9
            let quoteKey = SyncChanges.rateKey("CNY/USD")
            local.syncChanges = [quoteKey: .init(date: now, fingerprint: try SyncChanges.financeSettings(local.finance)[quoteKey])]
            cloud.syncChanges = [quoteKey: .init(date: now, fingerprint: try SyncChanges.financeSettings(cloud.finance)[quoteKey])]
            local.finance!.entries[1].notes = "Posted amount remains independent"
            try exercise(local, cloud, rated) { result, reversed in
                try check(result.localSnapshot.finance!.rates[0].rate == (reversed ? 9 : 8),
                          "manual rates keep each disputed quote")
                try check(result.localSnapshot.syncChanges?[quoteKey] == (reversed ? cloud : local).syncChanges?[quoteKey]
                          && result.uploadSnapshot.syncChanges?[quoteKey] == (reversed ? local : cloud).syncChanges?[quoteKey]
                          && result.baselineSnapshot.syncChanges?[quoteKey] == rated.syncChanges?[quoteKey],
                          "held quote metadata is not joined into a reviewed causal history")
                try check(result.uploadSnapshot.finance!.entries.first { $0.id == independentEntry.id }?.notes == "Posted amount remains independent",
                          "a manual valuation quote conflict does not stop historical posting edits")
            }

            // First synchronization cannot infer that absence means deletion, even after creating a partial base.
            local = original; cloud = original
            local.tasks.removeFirst()
            local.syncChanges = [taskKey: .init(date: now, fingerprint: nil)]
            let firstSyncAddition = TaskBackup.TaskRecord(TaskItem(title: "First sync independent addition"))
            cloud.tasks.append(firstSyncAddition)
            try exercise(local, cloud, nil) { result, reversed in
                let absent = reversed ? result.uploadSnapshot : result.localSnapshot
                let present = reversed ? result.localSnapshot : result.uploadSnapshot
                try check(!absent.tasks.contains { $0.id == disputed.id } && present.tasks.contains { $0.id == disputed.id },
                          "first-sync deletion keeps both original interpretations")
                try check(!result.baselineSnapshot.tasks.contains { $0.id == disputed.id },
                          "partial first synchronization never invents an ancestor for a disputed deletion")
                try check(result.localSnapshot.tasks.contains { $0.id == firstSyncAddition.id }
                          && result.uploadSnapshot.tasks.contains { $0.id == firstSyncAddition.id },
                          "independent additions still synchronize during first-sync deletion review")
            }

            // A repeating chain is held together, including branches created on different devices.
            var recurringBase = original
            recurringBase.tasks[0].repeatRule = "daily"
            local = recurringBase; cloud = recurringBase
            var successor = disputed; successor.id = UUID(); successor.title = "Mac successor"
            var rival = successor; rival.id = UUID(); rival.title = "Phone successor"
            local.tasks[0].nextOccurrenceID = successor.id; local.tasks.append(successor)
            cloud.tasks[0].nextOccurrenceID = rival.id; cloud.tasks.append(rival)
            local.tasks[1].notes = "Outside repeat chain"
            try exercise(local, cloud, recurringBase) { result, reversed in
                let expected = reversed ? rival : successor
                try check(result.localSnapshot.tasks.contains { $0.id == expected.id }
                          && result.localSnapshot.tasks.first { $0.id == disputed.id }?.nextOccurrenceID == expected.id,
                          "repeat links and independently created successors stay in their own branch")
                try check(result.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Outside repeat chain",
                          "a repeat conflict does not stall an unrelated task")
            }

            // A changed account currency and its dependent postings cannot be partitioned separately.
            local = original; cloud = original
            local.finance!.accounts[0].currency = "USD"
            cloud.finance!.entries[0].notes = "Changed posting"
            local.tasks[1].notes = "Still independent"
            try exercise(local, cloud, original) { result, reversed in
                let expected = try persisted(reversed ? cloud : local).finance
                let actual = try persisted(result.localSnapshot).finance
                try check(actual?.accounts == expected?.accounts
                          && actual?.entries == expected?.entries,
                          "account currency and all affected postings remain a dependency group")
                try check(result.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Still independent",
                          "account currency review does not block unrelated task progress")
            }

            // The global reporting currency changes the meaning of every historical base amount.
            local = original; cloud = original
            local.finance!.baseCurrency = "USD"
            cloud.finance!.entries[0].notes = "Other device finance edit"
            local.syncChanges = [SyncChanges.currencyKey: .init(date: now,
                fingerprint: try SyncChanges.financeSettings(local.finance)[SyncChanges.currencyKey])]
            cloud.syncChanges = [SyncChanges.currencyKey: .init(date: now,
                fingerprint: try SyncChanges.financeSettings(cloud.finance)[SyncChanges.currencyKey])]
            local.tasks[1].notes = "Task outside ledger"
            try exercise(local, cloud, original) { result, reversed in
                try check(try persisted(result.localSnapshot).finance == persisted(reversed ? cloud : local).finance
                          && persisted(result.uploadSnapshot).finance == persisted(reversed ? local : cloud).finance,
                          "ledger currency disputes keep the complete original ledgers")
                try check(result.localSnapshot.syncChanges?[SyncChanges.currencyKey] == (reversed ? cloud : local).syncChanges?[SyncChanges.currencyKey]
                          && result.uploadSnapshot.syncChanges?[SyncChanges.currencyKey] == (reversed ? local : cloud).syncChanges?[SyncChanges.currencyKey]
                          && result.baselineSnapshot.syncChanges?[SyncChanges.currencyKey] == original.syncChanges?[SyncChanges.currencyKey],
                          "held reporting currency metadata remains separate on each side")
                try check(result.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Task outside ledger",
                          "whole-ledger review still permits unrelated task changes")
            }

            // A linked task and posting must stay together when the task is held.
            local = original; cloud = original
            local.tasks[0].title = "Task on Mac"; cloud.tasks[0].title = "Task on phone"
            local.finance!.entries[0].taskID = disputed.id; local.finance!.entries[0].notes = "Linked finance edit"
            cloud.tasks[1].notes = "Unrelated task still syncs"
            try exercise(local, cloud, original) { result, reversed in
                try check(result.localSnapshot.finance?.entries.first { $0.id == purchase.id } == (reversed ? cloud : local).finance?.entries[0],
                          "linked finance posting remains with the held task")
                try check(result.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Unrelated task still syncs",
                          "task-finance dependencies do not hold unrelated tasks")
            }
        }
        // Persist local contents and the partial ancestor atomically, then reopen before retrying.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-partial-sync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disputed = TaskBackup.TaskRecord(TaskItem(title: "Persistent conflict"))
        let independent = TaskBackup.TaskRecord(TaskItem(title: "Persistent independent task"))
        let baseline = TaskBackup(lists: [], tasks: [disputed, independent])
        var local = baseline, cloud = baseline
        local.tasks[0].title = "Local disputed title"; cloud.tasks[0].title = "Cloud disputed title"
        cloud.tasks[1].notes = "Remote note"
        let prepared = try PartialSyncMerge.prepare(local: local, cloud: cloud, base: baseline, now: now)
        let location = directory.appendingPathComponent("partial.store")
        let store = try Store.make(url: location)
        let state = CloudSyncState(); store.mainContext.insert(state); try store.mainContext.save()
        try check(try CloudMerge.commit(prepared.localSnapshot, changed: true,
            baseline: CloudMerge.bytes(prepared.baselineSnapshot), state: state, revision: Store.revision, in: store.mainContext),
            "a partial local import and its old disputed ancestor save atomically")
        let reopened = try Store.make(url: location)
        let reopenedState = try reopened.mainContext.fetch(FetchDescriptor<CloudSyncState>()).first!
        let restoredLocal = try TaskBackup.capture(reopened.mainContext)
        let restoredBase = try TaskBackup.decode(reopenedState.baseline!, allowLargeFile: true)
        let retried = try PartialSyncMerge.prepare(local: restoredLocal, cloud: prepared.uploadSnapshot, base: restoredBase, now: now)
        try check(retried.conflict != nil
                  && retried.localSnapshot.tasks.first { $0.id == disputed.id }?.title == "Local disputed title",
                  "process restart retains the local disputed version and review")
        try check(retried.uploadSnapshot.tasks.first { $0.id == independent.id }?.notes == "Remote note",
                  "process restart retains already synchronized independent changes")
        let staleRevision = Store.revision
        let liveTask = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == independent.id }!
        liveTask.notes = "Edited during upload"; try Store.save(reopened.mainContext)
        try check(try !CloudMerge.commit(prepared.localSnapshot, changed: true,
            baseline: CloudMerge.bytes(prepared.baselineSnapshot), state: reopenedState, revision: staleRevision, in: reopened.mainContext),
            "an in-flight partial import cannot overwrite a newer local save")
        try check(liveTask.notes == "Edited during upload", "the in-flight edit survives rejected stale commit")

        // Independent refunds can violate a shared total even if each device was valid by itself.
        var finance = FinanceData.initial
        let expense = MoneyEntry(title: "Expense", date: now, amount: 100, bookID: finance.books[0].id, baseAmount: 100)
        finance.entries = [expense]
        let refundBase = TaskBackup(finance: finance, lists: [], tasks: [])
        var leftRefund = refundBase, rightRefund = refundBase
        leftRefund.finance!.entries.append(MoneyEntry(kind: .refund, title: "Left refund", date: now, amount: 60,
            bookID: finance.books[0].id, baseAmount: 60, refundOf: expense.id))
        rightRefund.finance!.entries.append(MoneyEntry(kind: .refund, title: "Right refund", date: now, amount: 60,
            bookID: finance.books[0].id, baseAmount: 60, refundOf: expense.id))
        var rejected = false
        do { _ = try PartialSyncMerge.prepare(local: leftRefund, cloud: rightRefund, base: refundBase, now: now) }
        catch { rejected = true }
        try check(rejected, "a combined refund limit violation never produces a publishable partial result")
        print("Partial sync checks: \(count)")
        return count
    }
}
