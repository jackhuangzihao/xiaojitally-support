import Foundation
import SwiftData
import SwiftUI
import CloudKit

extension CloudMerge {
    @MainActor static func check() throws -> Int {
        var count = try CloudSyncSettings.checkViewFootprint() + checkConflictChoices() + checkAutomaticSync() + SyncHistoryChecks.run() + PartialSyncChecks.run() + CausalSyncChecks.run()
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("SYNC CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var failed = false; do { try action() } catch { failed = true }
            try check(failed, label)
        }
        func requiresReview(_ label: String, _ action: () throws -> Void) throws {
            do {
                try action()
            } catch is Conflict {
                try check(true, label)
                return
            }
            throw TaskBackup.invalid("SYNC CHECK: " + label)
        }
        func tracked(_ snapshot: TaskBackup, from original: TaskBackup, at date: Date) throws -> TaskBackup {
            var snapshot = snapshot
            let old = try SyncChanges.fingerprints(original), new = try SyncChanges.fingerprints(snapshot)
            var changes: [String: String?] = [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] { changes[key] = .some(new[key]) }
            var revisions = snapshot.syncChanges ?? [:]
            SyncChanges.record(changes, in: &revisions, now: date)
            snapshot.syncChanges = revisions
            return snapshot
        }
        do {
            let first = TaskBackup.TaskRecord(TaskItem(title: "First", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let second = TaskBackup.TaskRecord(TaskItem(title: "Second"))
            let original = TaskBackup(lists: [], tasks: [first, second])
            let early = Date(timeIntervalSince1970: 1000), late = early.addingTimeInterval(60)
            var left = original, right = original
            left.tasks[0].title = "Mac title"; left.tasks[1].notes = "Mac note"
            left = try tracked(left, from: original, at: late)
            right.tasks[0].scheduledAt = first.scheduledAt!.addingTimeInterval(86400)
            right.tasks[1].priority = 2
            right = try tracked(right, from: original, at: early)
            let combined = try merge(local: left, cloud: right, base: original)
            let combinedFirst = combined.tasks.first { $0.id == first.id }!
            let combinedSecond = combined.tasks.first { $0.id == second.id }!
            try check(combinedFirst.title == "Mac title" && combinedFirst.scheduledAt == right.tasks[0].scheduledAt,
                      "independent title and schedule changes survive on the same task")
            try check(combinedSecond.notes == "Mac note" && combinedSecond.priority == 2,
                      "independent note and priority changes survive on the same task")
            try check(try bytes(merge(local: right, cloud: left, base: original)) == bytes(combined),
                      "field merge and its modification metadata converge in both directions")
            try check(try bytes(merge(local: combined, cloud: combined, base: original)) == bytes(combined),
                      "field merge retry preserves records and modification metadata")
            let key = SyncChanges.key("task", first.id)
            try check(try combined.syncChanges?[key]?.fingerprint == SyncChanges.fingerprint(combinedFirst)
                      && combined.syncChanges?[key]?.date == late,
                      "a composed task retains a matching fingerprint with a deterministic existing timestamp")
            var untrackedLeft = left, untrackedRight = right
            untrackedLeft.syncChanges = nil; untrackedRight.syncChanges = nil
            try check(try merge(local: untrackedLeft, cloud: untrackedRight, base: original).syncChanges == nil,
                      "legacy field merges do not manufacture wall-clock timestamps")

            var competing = right
            competing.tasks[0].title = "Phone title"; competing.tasks[0].notes = "Independent phone note"
            competing = try tracked(competing, from: original, at: early)
            for stamp in [early, late, Date(timeIntervalSince1970: -1000), Date().addingTimeInterval(3600)] {
                var timed = competing; timed.syncChanges![key]!.date = stamp
                for reverse in [false, true] {
                    try requiresReview("same-field edits require review regardless of clock or merge direction") {
                        _ = try merge(local: reverse ? timed : left, cloud: reverse ? left : timed, base: original)
                    }
                }
            }
            var legacy = competing; legacy.syncChanges = nil
            try requiresReview("missing modification times never select a conflicting field") { _ = try merge(local: left, cloud: legacy, base: original) }
            var stale = competing; stale.tasks[0].notes = "Changed without updating its stamp"
            try requiresReview("stale modification fingerprints never select a conflicting field") { _ = try merge(local: left, cloud: stale, base: original) }
            for choice in [Choice.local, .cloud] {
                let resolved = try merge(local: left, cloud: competing, base: original, choice: choice)
                let task = resolved.tasks.first { $0.id == first.id }!
                try check(task.title == (choice == .local ? "Mac title" : "Phone title")
                          && task.notes == "Independent phone note" && task.scheduledAt == competing.tasks[0].scheduledAt,
                          "manual field choice retains the other device's independent changes")
                try check(try resolved.syncChanges?[key]?.fingerprint == SyncChanges.fingerprint(task),
                          "manual field resolution records the combined contents")
            }
            try requiresReview("independent-looking edits without a shared baseline still require review") {
                _ = try merge(local: left, cloud: right, base: nil)
            }
            var rescheduled = original, reminderEdit = original
            rescheduled.tasks[0].scheduledAt = first.scheduledAt!.addingTimeInterval(86400)
            reminderEdit.tasks[0].reminderAt = first.scheduledAt!.addingTimeInterval(-600)
            reminderEdit.tasks[0].reminderKind = ReminderPreset.tenMinutes.rawValue
            try requiresReview("schedule and reminder changes remain one dependent group") {
                _ = try merge(local: rescheduled, cloud: reminderEdit, base: original)
            }
            var subtasksLeft = original, subtasksRight = original
            let step = Subtask(title: "Original step")
            var subtasksBase = original; subtasksBase.tasks[0].subtasks = [step]
            subtasksLeft = subtasksBase; subtasksRight = subtasksBase
            subtasksLeft.tasks[0].subtasks[0].title = "Renamed step"
            subtasksRight.tasks[0].subtasks[0].isDone = true
            let mergedSteps = try merge(local: subtasksLeft, cloud: subtasksRight, base: subtasksBase).tasks.first { $0.id == first.id }!.subtasks
            try check(mergedSteps[0].title == "Renamed step" && mergedSteps[0].isDone,
                      "independent subtask title and completion changes merge")
            var removed = original; removed.tasks.removeFirst()
            removed = try tracked(removed, from: original, at: late.addingTimeInterval(60))
            for reverse in [false, true] {
                try requiresReview("permanent deletion versus an edited task requires review") {
                    _ = try merge(local: reverse ? removed : left, cloud: reverse ? left : removed, base: original)
                }
            }
            let deletion = try merge(local: original, cloud: removed, base: original)
            try check(!deletion.tasks.contains { $0.id == first.id } && deletion.syncChanges?[key] != nil
                      && deletion.syncChanges?[key]?.fingerprint == nil, "one-sided deletion retains its tombstone")
            let restored = try merge(local: left, cloud: removed, base: original, choice: .local)
            try check(restored.syncChanges?[key]?.fingerprint == left.syncChanges?[key]?.fingerprint,
                      "manual restoration carries the selected record's matching stamp")
            var softDeleted = original; softDeleted.tasks[0].deletedAt = late
            for reverse in [false, true] {
                try requiresReview("moving to Recently deleted cannot silently hide the other device's edit") {
                    _ = try merge(local: reverse ? softDeleted : left, cloud: reverse ? left : softDeleted, base: original)
                }
            }
            let keepLive = try merge(local: left, cloud: softDeleted, base: original, choice: .local)
            try check(try SyncChanges.fingerprint(keepLive.tasks.first { $0.id == first.id }!) == SyncChanges.fingerprint(left.tasks[0]),
                      "manual deletion review retains the chosen whole task")
            var singleLeft = left, singleRemoved = removed
            singleLeft.tasks.removeAll { $0.id != first.id }; singleRemoved.tasks = []
            for stamp in [early, late.addingTimeInterval(60)] {
                var tombstone = singleRemoved; tombstone.syncChanges![key]!.date = stamp
                for reverse in [false, true] {
                    let a = reverse ? singleLeft : tombstone, b = reverse ? tombstone : singleLeft
                    try requiresReview("first-sync deletion needs review even with two timestamps") { _ = try merge(local: a, cloud: b, base: nil) }
                    let retained = try merge(local: a, cloud: b, base: nil, choice: reverse ? .local : .cloud)
                    let deleted = try merge(local: a, cloud: b, base: nil, choice: reverse ? .cloud : .local)
                    try check(try bytes(TaskBackup(lists: [], tasks: retained.tasks)) == bytes(TaskBackup(lists: [], tasks: singleLeft.tasks))
                              && deleted.tasks.isEmpty, "explicit first-sync choice can retain either the live task or deletion")
                }
            }
            var untrackedRow = singleLeft; untrackedRow.syncChanges = nil
            try requiresReview("a first-sync tombstone versus an untracked old row requires review") { _ = try merge(local: singleRemoved, cloud: untrackedRow, base: nil) }
            try requiresReview("a cloud tombstone cannot silently resurrect an untracked local row") { _ = try merge(local: untrackedRow, cloud: singleRemoved, base: nil) }
            var revisions = left.syncChanges!
            SyncChanges.record([key: try SyncChanges.fingerprint(competing.tasks[0])], in: &revisions, now: early)
            try check(revisions[key]!.date > left.syncChanges![key]!.date, "a backwards local clock cannot make the next saved edit older")
        }
        let report = (1...500).map { "Task \($0)\nLocal: open\nCloud: complete" }.joined(separator: "\n\n——\n\n")
        let reportSections = CloudMerge.Conflict.reportSections(report)
        try check(reportSections.count == 999 && reportSections.joined(separator: "\n\n") == report,
                  "long conflict review retains every item and separator in lazy paragraphs")
        try check(CloudMerge.Conflict.reportSections("").isEmpty,
                  "empty conflict details do not create an empty selectable row")
        do {
            var base = TaskBackup(weekTitles: [.init(week: "2026-09-28", title: "Week 11")], lists: [], tasks: [])
            var local = base, remote = base
            local.weekTitles![0].title = "Work week"
            remote.weekTitles!.append(.init(week: "2026-10-05", title: "Holiday"))
            let merged = try merge(local: local, cloud: remote, base: base)
            try check(merged.weekTitles?.count == 2 && merged.weekTitles?.first { $0.week == "2026-09-28" }?.title == "Work week", "independent week titles merge across devices")
            remote = base; remote.weekTitles![0].title = "Personal week"
            try rejects("same week's simultaneous title edits need a choice") { _ = try merge(local: local, cloud: remote, base: base) }
            try check(try merge(local: local, cloud: remote, base: base, choice: .cloud).weekTitles?[0].title == "Personal week", "week-title conflict honors explicit choice")
            remote = base; remote.weekTitles = []
            try rejects("title removal versus title edit cannot silently discard either") { _ = try merge(local: local, cloud: remote, base: base) }
            try check(try merge(local: base, cloud: remote, base: base).weekTitles?.isEmpty == true, "cleared week title stays cleared")
            var reversed = merged; reversed.weekTitles?.reverse()
            try check(try bytes(reversed) == bytes(merged) && BackupFiles.contentData(reversed) == BackupFiles.contentData(merged), "week-title ordering cannot create extra sync or backup revisions")
            base.weekTitles = nil
            try check(try merge(local: merged, cloud: base, base: nil).weekTitles == merged.weekTitles, "first sync with a legacy snapshot retains new week titles")
        }
        do {
            let manual = MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-01", fetchedAt: Date(timeIntervalSince1970: 1), source: "Manual")
            let fresh = MoneyRate(base: "USD", quote: "CNY", rate: 8, date: "2026-10-02", fetchedAt: Date(timeIntervalSince1970: 2), source: "ECB")
            var conflicts: [String] = []
            let report: (String) -> Void = { conflicts.append($0) }
            try check(try rateRows([], [manual], [manual], choice: nil, report: report).isEmpty, "reset manual rate does not resurrect the unchanged cloud quote")
            try check(try rateRows([manual], [fresh], [], choice: nil, report: report) == [manual], "concurrent provider update does not replace a manual quote")
            var historical = fresh; historical.date = "2026-09-01"; historical.fetchedAt = fresh.fetchedAt.addingTimeInterval(3600)
            try check(try rateRows([fresh], [historical], [], choice: nil, report: report) == [fresh], "a historical rate fetched later cannot replace a newer quote date")
            try check(try rateRows([fresh], [historical], [fresh], choice: nil, report: report) == [fresh], "an unchanged newer local quote survives an older historical cloud refresh")
            let inverse = MoneyRate(base: "CNY", quote: "USD", rate: Decimal(string: "0.15")!, date: "2026-10-02", source: "Manual")
            try check(try rateRows([inverse], [manual], [manual], choice: nil, report: report) == [inverse], "changing manual direction replaces both sides as one currency pair")
            _ = try rateRows([], [inverse], [manual], choice: nil, report: report)
            try check(conflicts.count == 1, "manual reset versus a concurrent manual edit prompts before data loss")
            let parent = MoneyCategory(name: "Travel")
            let child = MoneyCategory(name: "Flights", parentID: parent.id)
            var archived = parent; archived.archived = true
            let categories = try categoryRows([archived], [parent, child], [parent], choice: nil, report: report)
            try check(categories.count == 2 && categories.allSatisfy(\.archived), "archiving a parent retains and archives a concurrently added child")
            conflicts = []
            _ = try categoryRows([], [parent, child], [parent], choice: nil, report: report)
            try check(conflicts.count == 1, "parent deletion versus new child gives a resolvable family conflict")
            try check(try categoryRows([], [parent, child], [parent], choice: .cloud, report: report).count == 2, "choosing cloud restores the complete category family")
        }
        let item = TaskItem(title: "Original", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000))
        var base = TaskBackup(lists: [], tasks: [.init(item)])
        var local = base, remote = base
        local.tasks[0].title = "Mac edit"
        remote.tasks.append(.init(TaskItem(title: "iPhone new task")))
        var merged = try merge(local: local, cloud: remote, base: base)
        try check(merged.tasks.count == 2 && merged.tasks.contains { $0.title == "Mac edit" }, "independent edits survive")
        let retry = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue, userInfo: [CKErrorRetryAfterKey: 337])
        let now = Date(timeIntervalSince1970: 1000)
        try check(CloudSync.retryDate(retry, now: now) == now.addingTimeInterval(337), "server retry delay is respected")
        remote = base; remote.tasks[0].title = "iPhone edit"
        try rejects("same task conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        merged = try merge(local: local, cloud: remote, base: base, choice: .cloud)
        try check(merged.tasks[0].title == "iPhone edit", "explicit conflict choice")
        remote = base; remote.tasks = []
        try rejects("delete versus edit conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        try check(try merge(local: base, cloud: remote, base: base).tasks.isEmpty, "deletion propagates without resurrection")
        try check(try bytes(merge(local: local, cloud: local, base: base)) == bytes(local), "retry after upload before local commit is idempotent")
        let roundTrip = try TaskBackup.decode(bytes(local), allowLargeFile: true)
        try check(try bytes(local) == bytes(roundTrip), "date precision is stable across JSON")
        var ledger = FinanceData.initial
        let account = MoneyAccount(name: "AUD", currency: "AUD", opening: 1600)
        let destination = MoneyAccount(name: "Study", currency: "AUD")
        ledger.accounts = [account, destination]
        base.finance = ledger; local = base; remote = base
        var transfer = MoneyEntry(); transfer.title = "Transfer"; transfer.kind = .transfer; transfer.currency = "AUD"
        transfer.amount = 1500; transfer.accountAmount = 1500; transfer.accountID = account.id
        transfer.destinationID = destination.id; transfer.destinationAmount = 1500; transfer.bookID = ledger.books[0].id
        local.finance!.entries.append(transfer)
        var expense = MoneyEntry(); expense.title = "Expense"; expense.kind = .expense; expense.currency = "AUD"
        expense.amount = 20; expense.accountAmount = 20; expense.accountID = account.id; expense.bookID = ledger.books[0].id
        remote.finance!.entries.append(expense)
        merged = try merge(local: local, cloud: remote, base: base)
        try check(merged.finance!.balance(account.id) == 80 && merged.finance!.balance(destination.id) == 1500, "two-device posting and transfer balance")
        try check(try merge(local: merged, cloud: merged, base: base).finance!.entries.count == 2, "retries never double post")
        remote = base; remote.finance!.accounts.removeAll { $0.id == account.id }
        try rejects("delete account versus concurrent posting is blocked") { _ = try merge(local: local, cloud: remote, base: base) }
        remote = base; remote.finance!.baseCurrency = "AUD"
        try rejects("base currency conversion versus concurrent posting conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        remote = base; remote.finance!.entries = [transfer]; remote.finance!.entries[0].accountAmount = 1499
        try rejects("same posting does not silently win") { _ = try merge(local: local, cloud: remote, base: base) }
        do {
            var original = base; original.finance!.entries = [expense]
            var left = original, right = original
            left.finance!.entries[0].title = "Earlier note"
            right.finance!.entries[0].amount = 35; right.finance!.entries[0].accountAmount = 35
            left = try tracked(left, from: original, at: Date(timeIntervalSince1970: 1000))
            right = try tracked(right, from: original, at: Date(timeIntervalSince1970: 1100))
            let posted = try merge(local: left, cloud: right, base: original)
            try check(posted.finance!.entries.count == 1 && posted.finance!.entries[0].title == "Earlier note"
                      && posted.finance!.balance(account.id) == account.opening - 35,
                      "independent entry text and amount both survive with one computed posting")
            try check(try bytes(merge(local: right, cloud: left, base: original)) == bytes(posted),
                      "entry field merge converges in both directions")
            let entryKey = SyncChanges.key("entry", expense.id)
            try check(try posted.syncChanges?[entryKey]?.fingerprint == SyncChanges.fingerprint(posted.finance!.entries[0]),
                      "a composed entry retains a matching revision fingerprint")
            var competingAmount = left
            competingAmount.finance!.entries[0].amount = 30; competingAmount.finance!.entries[0].accountAmount = 30
            competingAmount = try tracked(competingAmount, from: original, at: Date(timeIntervalSince1970: 1200))
            try requiresReview("different concurrent amounts require review despite modification times") {
                _ = try merge(local: competingAmount, cloud: right, base: original)
            }
            let selectedAmount = try merge(local: competingAmount, cloud: right, base: original, choice: .cloud)
            try check(selectedAmount.finance!.entries[0].title == "Earlier note"
                      && selectedAmount.finance!.balance(account.id) == account.opening - 35,
                      "manual amount choice retains an independent entry title")
            var deletedEntry = original
            deletedEntry.finance!.entries[0].deletedAt = Date(timeIntervalSince1970: 1200)
            for reverse in [false, true] {
                try requiresReview("entry deletion versus text edit requires whole-entry review") {
                    _ = try merge(local: reverse ? deletedEntry : left, cloud: reverse ? left : deletedEntry, base: original)
                }
            }
            var currencyEdit = original; currencyEdit.finance!.baseCurrency = "AUD"
            currencyEdit = try tracked(currencyEdit, from: original, at: Date(timeIntervalSince1970: 1200))
            try rejects("timestamps do not bypass atomic base-currency and posting review") { _ = try merge(local: left, cloud: currencyEdit, base: original) }
            var pending = expense; pending.pending = true
            original.finance!.entries = [pending]
            left = original; right = original
            left.finance!.entries[0].notes = "Earlier pending edit"
            try right.finance!.confirmPending(pending, now: pending.date.addingTimeInterval(1))
            left = try tracked(left, from: original, at: Date(timeIntervalSince1970: 1300))
            right = try tracked(right, from: original, at: Date(timeIntervalSince1970: 1400))
            let confirmed = try merge(local: left, cloud: right, base: original)
            try check(confirmed.finance!.entries.count == 1 && confirmed.finance!.entries[0].id == pending.id && !confirmed.finance!.entries[0].isPending,
                      "pending confirmation preserves one entry with the original ID")
            try check(confirmed.finance!.entries[0].notes == "Earlier pending edit",
                      "pending confirmation retains the other device's independent note")
            try check(try bytes(merge(local: right, cloud: left, base: original)) == bytes(confirmed),
                      "pending confirmation and note merge converge in both directions")
            try check(confirmed.finance!.balance(account.id) == account.opening - expense.amount,
                      "pending confirmation enters the balance exactly once after sync")
            try check(try bytes(merge(local: confirmed, cloud: confirmed, base: original)) == bytes(confirmed),
                      "pending confirmation sync retries never duplicate the posted entry")
        }
        do {
            var money = FinanceData.initial
            let wallet = MoneyAccount(name: "Travel wallet", currency: "USD", opening: 100)
            let sender = MoneyAccount(name: "CNY sender", currency: "CNY", opening: 1000)
            let spare = MoneyAccount(name: "Spare", currency: "GBP", opening: 50)
            money.accounts = [wallet, sender, spare]
            let original = TaskBackup(finance: money, lists: [], tasks: [])
            var converted = original, changed = wallet; changed.currency = "EUR"
            try converted.finance!.updateAccount(changed, expected: wallet)
            var debit = MoneyEntry(); debit.title = "USD coffee"; debit.currency = "USD"; debit.amount = 10
            debit.accountID = wallet.id; debit.accountAmount = 10; debit.bookID = money.books[0].id; debit.baseAmount = 70
            var credit = debit; credit.id = UUID(); credit.kind = .income; credit.title = "USD income"
            var incoming = debit; incoming.id = UUID(); incoming.kind = .transfer; incoming.title = "Incoming transfer"
            incoming.currency = "CNY"; incoming.amount = 70; incoming.accountID = sender.id; incoming.accountAmount = 70
            incoming.destinationID = wallet.id; incoming.destinationAmount = 10; incoming.fee = 2; incoming.baseFee = 2; incoming.baseAmount = nil
            var outgoing = debit; outgoing.id = UUID(); outgoing.kind = .transfer; outgoing.title = "Outgoing transfer"
            outgoing.destinationID = sender.id; outgoing.destinationAmount = 70; outgoing.fee = 1; outgoing.baseFee = 7; outgoing.baseAmount = nil
            var adjustment = debit; adjustment.id = UUID(); adjustment.kind = .adjustment; adjustment.title = "USD correction"
            adjustment.amount = -10; adjustment.accountAmount = -10; adjustment.baseAmount = nil
            var unrelated = debit; unrelated.id = UUID(); unrelated.title = "Independent GBP posting"
            unrelated.currency = "GBP"; unrelated.accountID = spare.id; unrelated.baseAmount = 90
            for posting in [debit, credit, incoming, outgoing, adjustment] {
                var posted = original
                try posted.finance!.updateEntry(posting, expected: nil, baseCurrency: "CNY")
                try posted.finance!.updateEntry(unrelated, expected: nil, baseCurrency: "CNY")
                for reverse in [false, true] {
                    let left = reverse ? posted : converted, right = reverse ? converted : posted
                    do {
                        _ = try merge(local: left, cloud: right, base: original)
                        throw TaskBackup.invalid("Currency and concurrent posting must require an explicit choice")
                    } catch let conflict as Conflict {
                        try check(conflict.label.contains(wallet.name) && conflict.label.contains("USD") && conflict.label.contains("EUR"), "currency conflict identifies account and both denominations: \(posting.title)")
                    }
                    for choice in [Choice.local, .cloud] {
                        let selected = choice == .local ? left : right
                        let resolved = try merge(local: left, cloud: right, base: original, choice: choice)
                        try check(resolved.finance!.accounts.first { $0.id == wallet.id } == selected.finance!.accounts.first { $0.id == wallet.id } &&
                                  resolved.finance!.entries.first { $0.id == posting.id } == selected.finance!.entries.first { $0.id == posting.id }, "currency choice retains complete account and posting amounts/fees: \(posting.title)")
                        try check(resolved.finance!.entries.contains(unrelated), "currency choice preserves independent postings")
                        try check(try bytes(merge(local: resolved, cloud: resolved, base: original)) == bytes(resolved), "currency resolution retries are idempotent")
                    }
                }
            }
            // A refund to another account still depends on the selected original expense.
            var refunded = original, refund = debit; refund.id = UUID(); refund.kind = .refund; refund.refundOf = debit.id
            refund.title = "Refund to spare"; refund.accountID = spare.id; refund.accountAmount = 8
            refunded.finance!.entries = [debit, refund, unrelated]
            let keepCurrency = try merge(local: converted, cloud: refunded, base: original, choice: .local)
            let keepRefund = try merge(local: converted, cloud: refunded, base: original, choice: .cloud)
            try check(keepCurrency.finance!.entries == [unrelated] && keepRefund.finance!.entries.count == 3, "currency resolution keeps or removes expense and linked refund together")
            // Two accounts connected by a transfer must use one choice even if both currencies differ.
            var bothConverted = converted, convertedSender = sender; convertedSender.currency = "AUD"
            try bothConverted.finance!.updateAccount(convertedSender, expected: sender)
            var transferred = original; transferred.finance!.entries = [incoming, unrelated]
            for choice in [Choice.local, .cloud] {
                let resolved = try merge(local: bothConverted, cloud: transferred, base: original, choice: choice)
                try check(resolved.finance!.entries.count == (choice == .local ? 1 : 2), "connected currency changes resolve transfer exactly once")
                try check(resolved.finance!.accounts.first { $0.id == sender.id }?.currency == (choice == .local ? "AUD" : "CNY"), "connected currency changes keep both account denominations")
            }
            var independent = original; independent.finance!.entries = [unrelated]
            try check(try merge(local: converted, cloud: independent, base: original).finance!.entries == [unrelated], "currency edit merges with unrelated posting without conflict")
            var separate = original, changedSpare = spare; changedSpare.currency = "JPY"
            try separate.finance!.updateAccount(changedSpare, expected: spare)
            let separateResult = try merge(local: converted, cloud: separate, base: original)
            try check(separateResult.finance!.accounts.first { $0.id == wallet.id }?.currency == "EUR" && separateResult.finance!.accounts.first { $0.id == spare.id }?.currency == "JPY", "independent account currency edits merge without a false conflict")
            var oneSided = converted, newCurrencyDebit = debit; newCurrencyDebit.currency = "EUR"
            oneSided.finance!.entries = [newCurrencyDebit]
            try check(try bytes(merge(local: oneSided, cloud: original, base: original)) == bytes(oneSided), "one-sided currency edit and subsequent posting merge together")
            var renamed = original; renamed.finance!.accounts[0].name = "Renamed wallet"
            var ordinary = original; ordinary.finance!.entries = [debit]
            let ordinaryResult = try merge(local: renamed, cloud: ordinary, base: original)
            try check(ordinaryResult.finance!.entries == [debit] && ordinaryResult.finance!.accounts.first { $0.id == wallet.id }?.name == "Renamed wallet", "account rename and concurrent posting remain independent")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        do {
            let store = try Store.make(url: directory.appendingPathComponent("modification-times.store")), context = store.mainContext
            let task = TaskItem(title: "Tracked task")
            context.insert(task)
            try Store.save(context)
            let key = SyncChanges.key("task", task.id)
            let original = try TaskBackup.capture(context)
            try check(original.syncChanges?[key]?.fingerprint == SyncChanges.fingerprint(original.tasks[0]), "task save atomically records its matching content fingerprint")
            let initial = original.syncChanges
            task.notes = "Rolled back edit"
            try SyncChanges.trackModels(in: context)
            context.rollback()
            try check(try SyncChanges.read(context) == initial, "rollback restores timestamps with the edited data")
            var incoming = original; incoming.tasks[0].notes = "Remote saved note"
            incoming = try tracked(incoming, from: original, at: Date(timeIntervalSince1970: 1200))
            try stage(incoming, in: context)
            try Store.save(context, trackSyncChanges: false)
            try check(try TaskBackup.capture(context).syncChanges == incoming.syncChanges, "remote import preserves modification time instead of stamping its arrival")
            var finance = FinanceData.initial
            finance.accounts = [MoneyAccount(name: "Tracked account")]
            try FinanceStore.stage(finance, in: context); try Store.save(context)
            let accountKey = SyncChanges.key("account", finance.accounts[0].id)
            let saved = try SyncChanges.read(context)
            try check(saved?[accountKey]?.fingerprint == SyncChanges.fingerprint(finance.accounts[0]), "finance staging tracks changed account contents")
            finance.accounts[0].name = "Unsaved account"
            try FinanceStore.stage(finance, in: context)
            context.rollback()
            try check(try SyncChanges.read(context) == saved && FinanceStore.read(context)?.accounts[0].name == "Tracked account", "finance rollback restores both payload and modification metadata despite cached staged values")
            context.delete(task); try Store.save(context)
            let removed = try SyncChanges.read(context)
            try check(removed?[key] != nil && removed?[key]?.fingerprint == nil, "permanent task deletion stores a tombstone in the same save")
            let reopened = try Store.make(url: directory.appendingPathComponent("modification-times.store"))
            try check(try SyncChanges.read(reopened.mainContext) == removed, "modification times and deletion tombstones survive reopening the store")
            try incoming.restore(context, replace: true)
            let restored = try TaskBackup.capture(context)
            try check((restored.syncChanges?[key]?.date ?? .distantPast) > (incoming.syncChanges?[key]?.date ?? .distantPast),
                      "an explicit backup restore receives a new modification time")
            try check(restored.syncChanges?[key]?.fingerprint == SyncChanges.fingerprint(restored.tasks[0]),
                      "replace restore keeps the live replacement fingerprint instead of a deleted-object tombstone")
        }
        do {
            let source = try Store.make(url: directory.appendingPathComponent("restore-tombstone-source.store")), sourceContext = source.mainContext
            let task = TaskItem(title: "Deleted before export")
            sourceContext.insert(task)
            var ledger = FinanceData.initial
            let entry = MoneyEntry(title: "Deleted bill", amount: 12, bookID: ledger.books[0].id, baseAmount: 12)
            let keys = [SyncChanges.key("task", task.id), SyncChanges.key("entry", entry.id)]
            ledger.entries = [entry]
            try FinanceStore.stage(ledger, in: sourceContext); try Store.save(sourceContext)
            let oldCloud = try TaskBackup.capture(sourceContext)
            sourceContext.delete(task); ledger.entries = []
            try FinanceStore.stage(ledger, in: sourceContext); try Store.save(sourceContext)
            let incoming = try TaskBackup.decode(TaskBackup.capture(sourceContext).encoded())
            for replace in [false, true] {
                let restoreURL = directory.appendingPathComponent("restored-tombstones-\(replace).store")
                let target = try Store.make(url: restoreURL)
                try incoming.restore(target.mainContext, replace: replace)
                let reopened = try Store.make(url: restoreURL)
                let restored = try TaskBackup.capture(reopened.mainContext)
                try check(keys.allSatisfy { restored.syncChanges?[$0] == incoming.syncChanges?[$0] && restored.syncChanges?[$0]?.fingerprint == nil },
                          "fresh-device restore preserves task and bill deletion history after reopening")
                let firstSync = try merge(local: restored, cloud: oldCloud, base: nil)
                try check(firstSync.tasks.isEmpty && firstSync.finance?.entries.isEmpty == true,
                          "a restored causal deletion covers the exact older cloud record without resurrection")
                let resolved = try merge(local: restored, cloud: oldCloud, base: nil, choice: .local)
                try check(resolved.tasks.isEmpty && resolved.finance?.entries.isEmpty == true,
                          "review can retain both restored task and bill deletions")
            }
            let target = try Store.make(url: directory.appendingPathComponent("restore-tombstone-live.store"))
            try oldCloud.restore(target.mainContext, replace: true)
            let live = try TaskBackup.capture(target.mainContext)
            try incoming.restore(target.mainContext, replace: false)
            let retained = try TaskBackup.capture(target.mainContext)
            try check(retained.tasks.count == 1 && retained.finance?.entries.count == 1
                      && keys.allSatisfy { retained.syncChanges?[$0] == live.syncChanges?[$0] && retained.syncChanges?[$0]?.fingerprint != nil },
                      "merge restore never imports tombstones over retained live records or refreshes unchanged edits")
            try incoming.restore(target.mainContext, replace: true)
            let replaced = try TaskBackup.capture(target.mainContext)
            try check(keys.allSatisfy { replaced.syncChanges?[$0]?.fingerprint == nil
                      && (replaced.syncChanges?[$0]?.date ?? .distantPast) > (live.syncChanges?[$0]?.date ?? .distantPast) },
                      "replace restore records actual deletions as fresh edits instead of copying old tombstone times")
        }
        let container = try Store.make(url: url), context = container.mainContext
        try stage(base, in: context); try context.save()
        let existing = try context.fetch(FetchDescriptor<TaskItem>()).first!
        let state = CloudSyncState(); state.enabled = true; state.account = "fixture-account"; context.insert(state)
        try stage(merged, in: context); state.baseline = try bytes(merged); try context.save()
        try check(try FinanceStore.read(context)!.accounts.map(\.id) == base.finance!.accounts.map(\.id), "sync retains account display order")
        try check(try context.fetch(FetchDescriptor<TaskItem>()).first === existing, "remote import retains live object identity")
        let reopened = try Store.make(url: url)
        let savedState = try reopened.mainContext.fetch(FetchDescriptor<CloudSyncState>()).first!
        try check(try savedState.baseline == bytes(TaskBackup.capture(reopened.mainContext)), "merge base commits atomically with data")
        try check(savedState.account == "fixture-account" && savedState.enabled, "account binding survives restart")
        do {
            let cacheStore = try Store.make(url: directory.appendingPathComponent("cache.store")), cacheContext = cacheStore.mainContext
            try stage(base, in: cacheContext); try Store.save(cacheContext)
            let captured = try TaskBackup.capture(cacheContext), encoded = try bytes(captured)
            let cached = CloudSync.SnapshotCache(contextID: ObjectIdentifier(cacheContext), revision: Store.revision, baseline: encoded,
                                                local: captured, localBytes: encoded, base: try TaskBackup.decode(encoded))
            try check(cached.matches(cacheContext, baseline: encoded) && cached.matches(cacheContext, baseline: encoded), "unchanged sync polls reuse the same saved revision")
            try check(try cached.localBytes == bytes(TaskBackup.capture(cacheContext)) && bytes(cached.base!) == encoded, "cached local snapshot and merge base equal fresh captures and encoding")
            try check(!cached.matches(reopened.mainContext, baseline: encoded), "reloaded or attached context cannot reuse another context's sync cache")
            try check(!cached.matches(cacheContext, baseline: nil) && !cached.matches(cacheContext, baseline: Data("different baseline".utf8)), "baseline reset or replacement invalidates sync cache")
            let cachedTask = try cacheContext.fetch(FetchDescriptor<TaskItem>()).first!
            cachedTask.notes = "Unsaved editor draft"
            try check(!cached.matches(cacheContext, baseline: encoded), "unsaved drafts cannot reuse sync snapshot cache")
            cacheContext.rollback()
            try check(cached.matches(cacheContext, baseline: encoded), "rolled back draft retains the unchanged saved snapshot")
            cachedTask.notes = "Saved after snapshot preparation"; try Store.save(cacheContext)
            try check(!cached.matches(cacheContext, baseline: encoded) && cached.localBytes != bytes(TaskBackup.capture(cacheContext)), "saved edits reject an older prepared snapshot even when baseline is unchanged")
            let fresh = try TaskBackup.capture(cacheContext), freshBytes = try bytes(fresh)
            let reset = CloudSync.SnapshotCache(contextID: ObjectIdentifier(cacheContext), revision: Store.revision, baseline: nil,
                                               local: fresh, localBytes: freshBytes, base: nil)
            Store.invalidateHistory()
            try check(!reset.matches(cacheContext, baseline: nil), "explicit store invalidation expires first-sync cache without a baseline")
        }
        let backup = try TaskBackup.capture(context).encoded()
        try check(!String(decoding: backup, as: UTF8.self).contains("fixture-account"), "portable exports exclude sync credentials and baseline")
        let oldURL = directory.appendingPathComponent("previous.store")
        try autoreleasepool {
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: oldURL, cloudKitDatabase: .none)])
            var legacy = merged; legacy.weekTitles = nil
            try stage(legacy, in: old.mainContext); try old.mainContext.save()
        }
        let migrated = try Store.make(url: oldURL)
        try check(try bytes(TaskBackup.capture(migrated.mainContext)) == bytes(merged), "previous task/finance store migrates without data changes")
        try check(try migrated.mainContext.fetch(FetchDescriptor<CloudSyncState>()).isEmpty, "migration never enables upload without consent")
        item.repeatRule = "daily"; item.subtasks = [Subtask(title: "Repeat step", isDone: true)]
        let tomorrow = item.scheduledAt!.addingTimeInterval(86400)
        let a = item.occurrence(at: tomorrow), b = item.occurrence(at: tomorrow)
        try check(a.id == b.id && a.subtasks == b.subtasks && a.subtasks[0].id != item.subtasks[0].id, "offline completion creates stable next-task and fresh stable subtask IDs")
        let next = TaskBackup(lists: [], tasks: [.init(a)])
        try check(try merge(local: next, cloud: TaskBackup(lists: [], tasks: [.init(b)]), base: nil).tasks.count == 1, "simultaneous repeat completion never inserts duplicate next tasks")

        // First sync must not treat empty, automatically created lists as edits made by the user.
        let defaultList = TaskBackup.ListRecord(id: TaskItem.syncIdentity("tally-default-list-0"), name: "工作",
            createdAt: Date(timeIntervalSince1970: 0), colorHex: ListColor.presets[0].hex, sortOrder: 0)
        let fresh = TaskBackup(lists: [defaultList], tasks: [])
        var customized = fresh; customized.lists[0].name = "My renamed work"
        let empty = TaskBackup(lists: [], tasks: [])
        try check(try merge(local: fresh, cloud: customized, base: nil).lists[0].name == "My renamed work", "fresh device accepts a renamed cloud default")
        var english = fresh; english.lists[0].name = "Work"
        try check(try merge(local: english, cloud: fresh, base: nil).lists[0].name == "工作", "default list localization does not conflict")
        let returnedToDefault = try tracked(fresh, from: customized, at: Date(timeIntervalSince1970: 2500))
        for reverse in [false, true] {
            try requiresReview("a tracked list restored to its default appearance is not an unused first-sync seed") {
                _ = try merge(local: reverse ? customized : returnedToDefault, cloud: reverse ? returnedToDefault : customized, base: nil)
            }
        }
        try check(try merge(local: fresh, cloud: empty, base: nil).lists.isEmpty, "fresh device cannot resurrect deleted cloud defaults")
        try check(try merge(local: fresh, cloud: empty, base: nil, cloudExists: false).lists.count == 1, "first upload retains defaults when no cloud record exists")
        try check(try merge(local: customized, cloud: fresh, base: nil).lists[0].name == "My renamed work", "customized local default wins over unused remote seed")
        try check(try merge(local: customized, cloud: empty, base: nil).lists.count == 1, "locally renamed default is retained")
        var used = fresh; var usedTask = TaskBackup.TaskRecord(TaskItem(title: "Task using default")); usedTask.listID = defaultList.id; used.tasks = [usedTask]
        try check(try merge(local: used, cloud: empty, base: nil).lists.count == 1, "a used default and its task are retained")
        try rejects("used default vs renamed cloud default needs a choice") { _ = try merge(local: used, cloud: customized, base: nil) }
        var parent = fresh; parent.lists.append(.init(id: UUID(), name: "Child", createdAt: Date(), parentID: defaultList.id))
        try check(try merge(local: parent, cloud: empty, base: nil).lists.count == 2, "default with child list is retained")
        for field in 0..<3 {
            var edited = fresh
            if field == 0 { edited.lists[0].colorHex = "123456" }
            if field == 1 { edited.lists[0].sortOrder = 2 }
            if field == 2 { edited.lists[0].emoji = "⭐️" }
            try check(try merge(local: edited, cloud: empty, base: nil).lists.count == 1, "custom default appearance/order is retained \(field)")
        }
        var legacy = fresh; legacy.lists[0].id = UUID()
        try check(try merge(local: legacy, cloud: empty, base: nil).lists.count == 1, "legacy user list named Work is not treated as a seed")
        try check(try merge(local: fresh, cloud: empty, base: fresh).lists.isEmpty, "established sync propagates default deletion normally")
        var initialLedger = empty; initialLedger.finance = .initial
        var englishLedger = initialLedger; englishLedger.finance!.books[0].name = "Daily"
        try check(try bytes(merge(local: englishLedger, cloud: initialLedger, base: nil)) == bytes(initialLedger), "empty default book localization does not conflict")
        try check(try merge(local: initialLedger, cloud: empty, base: nil).finance == nil, "untouched default ledger does not reappear on first sync")
        try check(try merge(local: initialLedger, cloud: empty, base: nil, cloudExists: false).finance != nil, "first cloud upload retains the initial ledger")
        var editedLedger = initialLedger; editedLedger.finance!.books[0].name = "Household"
        try check(try merge(local: initialLedger, cloud: editedLedger, base: nil).finance!.books[0].name == "Household", "fresh ledger accepts customized cloud book")
        do {
            var lastEntry = MoneyEntry()
            lastEntry.title = "Last entry before deletion"; lastEntry.amount = 12; lastEntry.baseAmount = 12
            lastEntry.bookID = initialLedger.finance!.books[0].id
            var occupied = initialLedger; occupied.finance!.entries = [lastEntry]
            let retained = try tracked(occupied, from: initialLedger, at: Date(timeIntervalSince1970: 2600))
            let deleted = try tracked(initialLedger, from: retained, at: Date(timeIntervalSince1970: 2700))
            let key = SyncChanges.key("entry", lastEntry.id)
            try check(deleted.finance == initialLedger.finance && deleted.syncChanges?[key] != nil
                      && deleted.syncChanges?[key]?.fingerprint == nil,
                      "deleting the last entry leaves initial-shaped finance with an explicit tombstone")
            for reverse in [false, true] {
                let a = reverse ? retained : deleted, b = reverse ? deleted : retained
                try requiresReview("initial-shaped finance must not bypass first-sync deletion review") {
                    _ = try merge(local: a, cloud: b, base: nil)
                }
                let keepDeletion = try merge(local: a, cloud: b, base: nil, choice: reverse ? .cloud : .local)
                let keepEntry = try merge(local: a, cloud: b, base: nil, choice: reverse ? .local : .cloud)
                try check(keepDeletion.finance!.entries.isEmpty && keepDeletion.syncChanges?[key] != nil
                          && keepDeletion.syncChanges?[key]?.fingerprint == nil
                          && keepEntry.finance!.entries.count == 1 && keepEntry.finance!.entries[0].id == lastEntry.id,
                          "manual first-sync choice keeps the selected deletion or sole entry without resurrecting it")
            }
        }

        // Reproduce real offline completion on separate temporary stores, with different completion days.
        let day = Dates.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_553_600))
        let recurring = TaskItem(title: "Daily offline", scheduledAt: day.addingTimeInterval(9 * 3600))
        recurring.hasTime = true; recurring.repeatRule = "daily"
        let repeatBase = TaskBackup(lists: [], tasks: [.init(recurring)])
        let deviceA = try Store.make(url: directory.appendingPathComponent("device-a.store"))
        let deviceB = try Store.make(url: directory.appendingPathComponent("device-b.store"))
        try stage(repeatBase, in: deviceA.mainContext); try deviceA.mainContext.save()
        try stage(repeatBase, in: deviceB.mainContext); try deviceB.mainContext.save()
        let taskA = try deviceA.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        let taskB = try deviceB.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        taskA.toggleCompletion(in: deviceA.mainContext, now: day.addingTimeInterval(10 * 3600)); try deviceA.mainContext.save()
        taskB.toggleCompletion(in: deviceB.mainContext, now: day.addingTimeInterval(34 * 3600)); try deviceB.mainContext.save()
        let left = try TaskBackup.capture(deviceA.mainContext), right = try TaskBackup.capture(deviceB.mainContext)
        try check(taskA.nextOccurrenceID != taskB.nextOccurrenceID, "fixture has divergent successors from actual offline completions")
        let trackedLeft = try tracked(left, from: repeatBase, at: Date(timeIntervalSince1970: 2000))
        let trackedRight = try tracked(right, from: repeatBase, at: Date(timeIntervalSince1970: 2100))
        for reverse in [false, true] {
            try requiresReview("timestamps cannot automatically choose a divergent successor chain") {
                _ = try merge(local: reverse ? trackedRight : trackedLeft, cloud: reverse ? trackedLeft : trackedRight, base: repeatBase)
            }
        }
        let manuallySelectedChain = try merge(local: trackedLeft, cloud: trackedRight, base: repeatBase, choice: .cloud)
        try check(manuallySelectedChain.tasks == (try merge(local: right, cloud: right, base: repeatBase)).tasks
                  && manuallySelectedChain.tasks.filter { !$0.isDone }.count == 1,
                  "explicit recurrence choice keeps one complete successor chain")
        do {
            var occurrenceLeft = left, occurrenceRight = left
            let parent = occurrenceLeft.tasks.firstIndex { $0.id == recurring.id }!
            let successor = occurrenceRight.tasks.firstIndex { $0.id == taskA.nextOccurrenceID }!
            occurrenceLeft.tasks[parent].title = "Edited previous occurrence"
            occurrenceRight.tasks[successor].notes = "Edited next occurrence"
            occurrenceLeft = try tracked(occurrenceLeft, from: left, at: Date(timeIntervalSince1970: 2200))
            occurrenceRight = try tracked(occurrenceRight, from: left, at: Date(timeIntervalSince1970: 2300))
            let sharedChain = try merge(local: occurrenceLeft, cloud: occurrenceRight, base: left)
            try check(sharedChain.tasks.first { $0.id == recurring.id }?.title == "Edited previous occurrence"
                      && sharedChain.tasks.first { $0.id == taskA.nextOccurrenceID }?.notes == "Edited next occurrence",
                      "independent edits to existing occurrences survive within one unchanged chain")
            try check(try bytes(merge(local: occurrenceRight, cloud: occurrenceLeft, base: left)) == bytes(sharedChain),
                      "existing-occurrence merge converges in both directions")
            try check(try bytes(merge(local: sharedChain, cloud: sharedChain, base: left)) == bytes(sharedChain),
                      "existing-occurrence merge retry is idempotent")
            var laterParent = left, earlierSuccessor = left
            let parentDate = left.tasks[parent].scheduledAt!
            let interval = left.tasks[successor].scheduledAt!.timeIntervalSince(parentDate)
            laterParent.tasks[parent].scheduledAt = parentDate.addingTimeInterval(interval * 0.75)
            earlierSuccessor.tasks[successor].scheduledAt = parentDate.addingTimeInterval(interval * 0.25)
            for reverse in [false, true] {
                try requiresReview("separate occurrence reschedules cannot compose a backwards repeat chain") {
                    _ = try merge(local: reverse ? earlierSuccessor : laterParent,
                                  cloud: reverse ? laterParent : earlierSuccessor, base: left)
                }
            }
            var moved = occurrenceRight
            moved.tasks[successor].nextOccurrenceID = UUID()
            try requiresReview("chain topology changes are not mixed with independent occurrence edits") {
                _ = try merge(local: occurrenceLeft, cloud: moved, base: left)
            }
        }
        try rejects("divergent recurrence requires whole-series choice") { _ = try merge(local: left, cloud: right, base: repeatBase) }
        for choice in [Choice.local, .cloud] {
            let resolved = try merge(local: left, cloud: right, base: repeatBase, choice: choice)
            let selected = choice == .local ? left : right
            var resolvedValues = resolved, selectedValues = selected
            resolvedValues.syncChanges = nil; selectedValues.syncChanges = nil
            try check(try bytes(resolvedValues) == bytes(selectedValues), "recurrence choice keeps only the selected complete chain and records its confirmation")
            try check(resolved.tasks.filter { !$0.isDone && $0.deletedAt == nil }.count == 1, "resolved recurrence has one active successor")
            let other = choice == .local ? right : left
            try check(try bytes(merge(local: other, cloud: resolved, base: repeatBase)) == bytes(resolved),
                      "confirmed sequence choice propagates without resurrecting an unselected successor")
            try check(try bytes(merge(local: resolved, cloud: resolved, base: repeatBase)) == bytes(resolved), "resolved recurrence retry is idempotent")
            let resultStore = try Store.make(url: directory.appendingPathComponent(UUID().uuidString + ".store"))
            try stage(resolved, in: resultStore.mainContext); try resultStore.mainContext.save()
            let nextTask = try resultStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first { !$0.isDone }!
            nextTask.toggleCompletion(in: resultStore.mainContext, now: day.addingTimeInterval(58 * 3600)); try resultStore.mainContext.save()
            let nextGeneration = try TaskBackup.capture(resultStore.mainContext)
            try check(nextGeneration.tasks.filter { !$0.isDone }.count == 1, "further completion cannot fork into two daily tasks")
        }
        let nextB = try deviceB.mainContext.fetch(FetchDescriptor<TaskItem>()).first { !$0.isDone }!
        nextB.title = "Edited successor on phone"
        nextB.toggleCompletion(in: deviceB.mainContext, now: day.addingTimeInterval(58 * 3600)); try deviceB.mainContext.save()
        var longerRight = try TaskBackup.capture(deviceB.mainContext)
        let independent = TaskBackup.TaskRecord(TaskItem(title: "Unrelated phone task")); longerRight.tasks.append(independent)
        let keepLeft = try merge(local: left, cloud: longerRight, base: repeatBase, choice: .local)
        try check(keepLeft.tasks.count == left.tasks.count + 1 && keepLeft.tasks.contains { $0.id == independent.id }, "losing branch descendants removed, unrelated phone task retained")
        let keepRight = try merge(local: left, cloud: longerRight, base: repeatBase, choice: .cloud)
        var keptValues = keepRight, laterValues = longerRight
        keptValues.syncChanges = nil; laterValues.syncChanges = nil
        try check(try bytes(keptValues) == bytes(laterValues), "selected later branch retains edits and completed history")
        var deletedLeft = left; deletedLeft.tasks.removeAll()
        try rejects("deleting repeat history vs changed successor conflicts") { _ = try merge(local: deletedLeft, cloud: keepRight, base: left) }
        try check(try merge(local: deletedLeft, cloud: keepRight, base: left, choice: .local).tasks.map(\.id) == [independent.id], "base links preserve whole-chain deletion without orphan descendants")
        // Independent quick edits during a cloud upload are rebased rather than overwritten.
        var inFlightLocal = empty; inFlightLocal.tasks = [usedTask]
        inFlightLocal.lists = fresh.lists
        var cloudUpdate = inFlightLocal; cloudUpdate.tasks.append(independent)
        cloudUpdate.tasks[0].title = "Remote title received during upload"
        var newerLocal = inFlightLocal; newerLocal.tasks[0].notes = "Typed while upload was running"
        let rebased = try merge(local: newerLocal, cloud: cloudUpdate, base: inFlightLocal)
        try check(rebased.tasks.contains { $0.id == usedTask.id && $0.notes == "Typed while upload was running"
                      && $0.title == "Remote title received during upload" } && rebased.tasks.contains { $0.id == independent.id },
                  "in-flight local note, remote title on the same task and independent addition all survive")
        var multiLeft = fresh, multiRight = fresh
        multiLeft.lists[0].name = "Mac list"; multiRight.lists[0].name = "Phone list"
        multiLeft.tasks = [.init(TaskItem(title: "Same task"))]; multiRight.tasks = multiLeft.tasks
        multiLeft.tasks[0].notes = "Mac note"; multiRight.tasks[0].notes = "Phone note"
        var multiBase = fresh; multiBase.tasks = multiLeft.tasks; multiBase.tasks[0].notes = "Original note"
        do {
            _ = try merge(local: multiLeft, cloud: multiRight, base: multiBase)
            throw TaskBackup.invalid("Expected conflict details")
        } catch let conflict as Conflict {
            try check(conflict.label.contains("Mac list") && conflict.label.contains("Phone list") && conflict.label.contains("Same task"), "all collections contribute named conflict details")
            try check(conflict.label.contains(L("备注", "notes")), "conflict details identify changed task fields")
        }


        let raceStore = try Store.make(url: directory.appendingPathComponent("background-edit.store"))
        try stage(inFlightLocal, in: raceStore.mainContext)
        let raceState = CloudSyncState(); raceStore.mainContext.insert(raceState)
        // Seed the remote baseline exactly like CloudMerge.commit; it is not a new local creation.
        try Store.save(raceStore.mainContext, trackSyncChanges: false)
        let workerRevision = Store.revision
        let liveTask = try raceStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        liveTask.notes = "Saved after worker captured its input"; try Store.save(raceStore.mainContext)
        let workerBytes = try bytes(cloudUpdate)
        try check(try !commit(cloudUpdate, changed: true, baseline: workerBytes, state: raceState,
                              revision: workerRevision, in: raceStore.mainContext), "stale background result cannot commit over a newer saved edit")
        try check(liveTask.notes == "Saved after worker captured its input" && raceState.baseline == nil,
                  "rejected background result changes neither user data nor sync baseline")
        let draftRevision = Store.revision
        liveTask.notes = "Unsaved draft"
        try check(try !commit(cloudUpdate, changed: true, baseline: workerBytes, state: raceState,
                              revision: draftRevision, in: raceStore.mainContext), "background result cannot commit over an unsaved edit")
        try check(liveTask.notes == "Unsaved draft", "rejected background result leaves unsaved text intact")
        raceStore.mainContext.rollback()
        let currentSnapshot = try TaskBackup.capture(raceStore.mainContext)
        let refreshed = try merge(local: currentSnapshot, cloud: cloudUpdate, base: inFlightLocal)
        try check(try commit(refreshed, changed: true, baseline: workerBytes, state: raceState,
                             revision: Store.revision, in: raceStore.mainContext), "fresh rebase commits after retry")
        try check(liveTask.notes == "Saved after worker captured its input" && liveTask.title == "Remote title received during upload"
                  && raceState.baseline == workerBytes &&
                  (try raceStore.mainContext.fetchCount(FetchDescriptor<TaskItem>())) == 2, "successful retry preserves new local edit, remote task and uploaded baseline")

        print("SYNC PASS: \(count) merge and storage checks")
        return count
    }
}

extension CloudSync {
    #if os(macOS)
    /// Isolated synthetic record; never reads the user's snapshot or opens their local store.
    static func connectivityCheck() async throws {
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else { throw TaskBackup.invalid("iCloud account unavailable") }
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "tally-connectivity-check-" + UUID().uuidString)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = TaskBackup(lists: [], tasks: [.init(TaskItem(title: "Temporary sync verification"))])
        let bytes = try CloudMerge.bytes(snapshot)
        try bytes.write(to: file)
        let record = CKRecord(recordType: "TallySnapshot", recordID: id)
        record["snapshot"] = CKAsset(fileURL: file); record["formatVersion"] = Int64(1); record["digest"] = CloudMerge.digest(bytes)
        do {
            let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            _ = try saved.saveResults[id]!.get()
            let fetched = try await database.record(for: id)
            guard let url = (fetched["snapshot"] as? CKAsset)?.fileURL, try Data(contentsOf: url) == bytes else { throw TaskBackup.invalid("Cloud round trip differs") }
            let stale = try await database.record(for: id)
            fetched["digest"] = "new-revision"
            _ = try await database.modifyRecords(saving: [fetched], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults[id]!.get()
            stale["digest"] = "stale-revision"
            var rejected = false
            do { _ = try await database.modifyRecords(saving: [stale], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults[id]!.get() }
            catch let error as CKError where error.code == .serverRecordChanged { rejected = true }
            guard rejected else { throw TaskBackup.invalid("Cloud conflict was not rejected") }
            _ = try await database.deleteRecord(withID: id)
            print("CLOUD PASS: private asset upload, download, optimistic conflict rejection, cleanup")
        } catch {
            do { _ = try await database.deleteRecord(withID: id) }
            catch let cleanup as CKError where cleanup.code == .unknownItem { /* Nothing was created. */ }
            catch { print("CLOUD CLEANUP: verify temporary record \(id.recordName) in the development console") }
            print("CLOUD DIAGNOSTIC: \(error.localizedDescription)")
            throw error
        }
    }
    #endif
}

#if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
/// Synthetic review only: no model container, account, cloud request, or recovery file.
struct SyncConflictUIFixture: View {
    @State private var sync = CloudSync.conflictUIFixture()
    var body: some View {
        NavigationStack {
            Form { CloudSyncSettings(sync: sync) }.formStyle(.grouped)
                .navigationTitle(L("同步界面验证", "Sync review test"))
        }
    }
    static func requireSandbox() throws {
        guard let id = Bundle.main.bundleIdentifier,
              id.hasPrefix("local.jianshi.sandboxcheck.sync") else {
            throw TaskBackup.invalid("Sync fixture requires a disposable sandbox identity")
        }
        #if os(macOS)
        guard NSHomeDirectory().contains("/Containers/" + id + "/Data") else {
            throw TaskBackup.invalid("Sync fixture requires a disposable Mac sandbox")
        }
        #else
        guard NSHomeDirectory().contains("/CoreSimulator/Devices/"),
              NSHomeDirectory().contains("/Containers/Data/Application/") else {
            throw TaskBackup.invalid("Sync fixture requires a disposable simulator sandbox")
        }
        #endif
    }
}

#endif
