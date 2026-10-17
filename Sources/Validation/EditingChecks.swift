import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif

@MainActor enum EditingChecks {
    static func run() throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Editors: " + label) }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try require(rejected, label)
        }
        try require(!TaskEditor.isCustomRepeat(nil) && !TaskEditor.isCustomRepeat("none"),
                    "New and nonrepeating tasks do not preselect custom repeat")
        try require(TaskEditor.repeatPresets.allSatisfy { !TaskEditor.isCustomRepeat($0) }
                    && TaskEditor.isCustomRepeat(RepeatRule(interval: 2, unit: .week).text),
                    "Saved preset and custom repeats retain their selection")
        #if os(macOS)
        let owner = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let eventView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        owner.contentView = eventView
        try require(LocalEventScope.accepts(window: owner, in: eventView)
                    && !LocalEventScope.accepts(window: otherWindow, in: eventView)
                    && !LocalEventScope.accepts(window: nil, in: eventView),
                    "Calendar and suggestion monitors only accept their own window")
        eventView.isHidden = true
        try require(!LocalEventScope.accepts(window: owner, in: eventView), "Hidden views cannot handle local events")
        eventView.isHidden = false; owner.contentView = nil
        try require(!LocalEventScope.accepts(window: owner, in: eventView), "Detached views cannot handle local events")
        #endif
        let container = try ModelContainer(for: TaskItem.self, TaskList.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(name: "Original list"), other = TaskList(name: "Unrelated list")
        context.insert(list); context.insert(other)
        let task = TaskItem(title: "Original task", list: list)
        task.notes = "Original note"; task.subtasks = [Subtask(title: "Original step")]
        context.insert(task); try context.save()
        let original = TaskBackup.TaskRecord(task), originalList = TaskBackup.ListRecord(list)
        try require(try EditorVersion.task(original, in: context) === task, "Unchanged task can be saved")
        try require(try EditorVersion.list(originalList, in: context) === list, "Unchanged list can be saved")
        try require(try EditorVersion.task(nil, in: context) == nil && EditorVersion.list(nil, in: context) == nil,
                    "New records do not need an existing target")
        other.name = "Changed elsewhere"; try context.save()
        try require(try EditorVersion.task(original, in: context) === task && EditorVersion.list(originalList, in: context) === list,
                    "Unrelated edits do not block this task or list")

        // Window A holds its opening snapshot. Window B commits while A still has unsaved text.
        let draft = TaskEditor.DraftState(title: "Window A title", notes: original.notes, pending: "Unsubmitted step",
            repeating: "none", repeatUntil: nil, end: nil, scheduled: nil, due: nil, reminder: nil,
            timed: false, dueTimed: false, preset: .none, listID: list.id, priority: 0,
            subtasks: original.subtasks, original: original)
        task.notes = "Window B note"; task.subtasks[0].isDone = true; try context.save()
        try rejects("Stale task editor is rejected before any mutation") {
            let target = try EditorVersion.task(draft.original, in: context)
            target?.title = draft.title; target?.notes = draft.notes; target?.subtasks = draft.subtasks
        }
        try require(task.title == "Original task" && task.notes == "Window B note" && task.subtasks[0].isDone,
                    "A failed save preserves B's note and completed subtask")
        try require(draft.title == "Window A title" && draft.pending == "Unsubmitted step" && draft.original == original,
                    "Recovery draft retains unsaved text and the opening version")
        var refreshed = TaskBackup.TaskRecord(task)
        task.isDone = true; task.completedAt = Date(); try context.save()
        try rejects("Completion from another window is not overwritten") { _ = try EditorVersion.task(refreshed, in: context) }
        refreshed = TaskBackup.TaskRecord(task)
        // The editor checks again after notification authorization, which is an async suspension.
        _ = try EditorVersion.task(refreshed, in: context)
        task.priority = 2; try context.save()
        try rejects("Second check catches changes after the first check") { _ = try EditorVersion.task(refreshed, in: context) }
        refreshed = TaskBackup.TaskRecord(task)
        task.deletedAt = Date(); try context.save()
        try rejects("Deletion during editing cannot accidentally restore a task") { _ = try EditorVersion.task(refreshed, in: context) }
        let deleted = TaskBackup.TaskRecord(task)
        let restorable = try EditorVersion.task(deleted, in: context)
        try require(restorable === task, "An editor intentionally opened from Recently deleted may restore the unchanged task")
        restorable?.deletedAt = nil; try context.save()
        try rejects("Another window restoring a task invalidates a stale trash editor") { _ = try EditorVersion.task(deleted, in: context) }

        let listDraft = ListEditor.DraftState(name: "Window A list", colorHex: nil, emoji: "📚", parentID: nil, original: originalList)
        list.emoji = "🏠"; list.name = "Window B list"; try context.save()
        try rejects("Stale list editor is rejected before changing its fields") {
            let target = try EditorVersion.list(listDraft.original, in: context)
            target?.name = listDraft.name; target?.emoji = listDraft.emoji
        }
        try require(list.name == "Window B list" && list.emoji == "🏠" && listDraft.original == originalList,
                    "List edit conflict preserves saved data and recovery baseline")
        let moved = TaskBackup.ListRecord(list)
        list.parentID = other.id; try context.save()
        try rejects("A move in another window cannot be overwritten") { _ = try EditorVersion.list(moved, in: context) }
        let finalTask = TaskBackup.TaskRecord(task), finalList = TaskBackup.ListRecord(list), listID = list.id
        context.delete(task); context.delete(list); try context.save()
        try rejects("Permanently deleted tasks are not silently recreated by old drafts") { _ = try EditorVersion.task(finalTask, in: context) }
        try rejects("Permanently deleted lists are not silently recreated by old drafts") { _ = try EditorVersion.list(finalList, in: context) }
        try rejects("Deleted task list or parent selection cannot create a dangling relationship") { _ = try EditorVersion.selectedList(listID, in: context) }
        try require(try EditorVersion.selectedList(nil, in: context) == nil, "An explicitly unfiled task or top-level list remains valid")
        try require(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty && context.fetch(FetchDescriptor<TaskList>()).count == 1,
                    "Rejected saves do not insert replacement records")
        // New-task bookkeeping uses the exact draft preparation and single-context commit used by the editor.
        let moneyContainer = try ModelContainer(for: TaskItem.self, TaskList.self, FinanceLedger.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let moneyContext = moneyContainer.mainContext
        moneyContext.autosaveEnabled = false
        var ledger = FinanceData.initial
        let bank = MoneyAccount(name: "Task account", currency: "CNY", opening: 100)
        ledger.accounts = [bank]; ledger.books[0].defaultAccountID = bank.id
        var moneyDraft = TaskFinanceDraft(ledger: ledger)
        moneyDraft.amount = "12.50"
        let freshTask = TaskItem(title: "Task with an entry")
        let prepared = try moneyDraft.preparedLedger(taskID: freshTask.id, title: freshTask.title, current: ledger)
        try require(try FinanceStore.read(moneyContext) == nil && !moneyContext.hasChanges,
                    "Preparing or cancelling a task finance draft creates no records")
        try require(prepared.entries.count == 1 && prepared.entries[0].taskID == freshTask.id
                    && prepared.entries[0].baseAmount == Decimal(string: "12.50") && prepared.balance(bank.id) == Decimal(string: "87.50"),
                    "Task entry has the linked UUID and posts the typed expense exactly once")
        moneyContext.insert(freshTask)
        try FinanceStore.stage(prepared, in: moneyContext)
        moneyContext.rollback()
        try require(try moneyContext.fetch(FetchDescriptor<TaskItem>()).isEmpty && FinanceStore.read(moneyContext) == nil,
                    "Rolling back a combined save removes both the task and staged ledger")
        let savedTask = TaskItem(title: "Task with an entry")
        let toSave = try moneyDraft.preparedLedger(taskID: savedTask.id, title: savedTask.title, current: ledger)
        moneyContext.insert(savedTask); try FinanceStore.stage(toSave, in: moneyContext); try Store.save(moneyContext)
        let savedLedger = try FinanceStore.read(moneyContext)!
        try require(savedLedger.entries.count == 1 && savedLedger.entries[0].taskID == savedTask.id,
                    "One commit saves both the task and linked Finance entry")
        try rejects("Submitting the same draft again cannot create a duplicate posting") {
            _ = try moneyDraft.preparedLedger(taskID: savedTask.id, title: savedTask.title, current: savedLedger)
        }
        let futureDay = Dates.calendar.date(byAdding: .day, value: 2, to: Date())!
        var plannedDraft = TaskFinanceDraft(ledger: ledger, scheduledAt: futureDay)
        plannedDraft.amount = "25"
        plannedDraft.entry.accountID = bank.id
        let planned = try plannedDraft.preparedLedger(taskID: savedTask.id, title: "Planned expense", current: ledger)
        try require(planned.entries[0].isPending && planned.balance(bank.id) == bank.opening
                    && Dates.sameDay(planned.entries[0].date, futureDay),
                    "Future task entry defaults to pending and preserves the planned day without posting")
        let todayDraft = TaskFinanceDraft(ledger: ledger, scheduledAt: Date())
        try require(!todayDraft.entry.isPending, "Same-day task entry retains immediate posting default")
        let separateDraft = TaskFinanceDraft(ledger: ledger)
        var unrelated = ledger
        var unrelatedEntry = toSave.entries[0]
        unrelatedEntry.id = UUID(); unrelatedEntry.title = "Saved by another window"
        unrelated.entries.append(unrelatedEntry)
        let mergedEntry = try moneyDraft.preparedLedger(taskID: UUID(), title: "This window", current: unrelated)
        try require(mergedEntry.entries.count == 2 && mergedEntry.entries.contains(unrelatedEntry)
                    && separateDraft.entry.id != moneyDraft.entry.id,
                    "A new task merges unrelated saved entries and separate drafts have independent posting IDs")
        var changed = ledger
        changed.accounts[0].currency = "AUD"
        try rejects("Account currency changes while task editing are rejected") {
            _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Stale", current: changed)
        }
        changed = ledger; changed.baseCurrency = "AUD"
        try rejects("Reporting currency changes while task editing are rejected") {
            _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Stale", current: changed)
        }
        changed = ledger; changed.books[0].archived = true
        try rejects("An archived book cannot receive a task entry") {
            _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Stale", current: changed)
        }
        changed = ledger; changed.accounts[0].archived = true
        try rejects("An archived account cannot receive a task entry") {
            _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Stale", current: changed)
        }
        changed = ledger
        if let category = changed.categories.firstIndex(where: { $0.id == moneyDraft.entry.categoryID }) {
            changed.categories[category].archived = true
            try rejects("An archived category cannot receive a task entry") {
                _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Stale", current: changed)
            }
        }
        moneyDraft.amount = "0"
        try rejects("Zero amounts cannot leave a partially saved task") {
            _ = try moneyDraft.preparedLedger(taskID: UUID(), title: "Invalid", current: ledger)
        }
        moneyDraft.amount = "2.50"; moneyDraft.entry.kind = .income
        moneyDraft.entry.categoryID = ledger.defaultCategory(income: true)
        let income = try moneyDraft.preparedLedger(taskID: UUID(), title: "Income", current: ledger)
        try require(income.entries[0].kind == .income && income.balance(bank.id) == Decimal(string: "102.50"),
                    "Task-linked income increases the selected account")
        var foreignLedger = ledger
        foreignLedger.accounts[0].currency = "USD"
        let quoteDay = ExchangeRates.dayString(Date())
        foreignLedger.rates = [MoneyRate(base: "USD", quote: "CNY", rate: 7, date: quoteDay)]
        var foreignDraft = TaskFinanceDraft(ledger: foreignLedger)
        foreignDraft.amount = "10"; foreignDraft.refreshConversion()
        try require(foreignDraft.converted == "70", "Task entries reuse dated reference conversions")
        foreignDraft.amount = "20"; foreignDraft.refreshConversion()
        try require(foreignDraft.converted == "140", "Automatic conversion follows amount edits")
        foreignDraft.converted = "141"; foreignDraft.amount = "30"; foreignDraft.refreshConversion()
        try require(foreignDraft.converted == "141", "Task finance conversion preserves a manual override")
        foreignDraft.entry.accountID = nil; foreignDraft.followAccountCurrency()
        try require(foreignDraft.entry.currency == "CNY" && foreignDraft.amount.isEmpty && foreignDraft.converted.isEmpty,
                    "Switching account denomination never reinterprets a typed amount")
        foreignLedger.rates[0].source = "Manual"
        var manualDraft = TaskFinanceDraft(ledger: foreignLedger)
        manualDraft.amount = "10"; manualDraft.refreshConversion()
        let unconverted = try manualDraft.preparedLedger(taskID: UUID(), title: "Foreign", current: foreignLedger)
        try require(manualDraft.converted.isEmpty && unconverted.entries[0].baseAmount == nil,
                    "Asset-only manual rates never become task posting rates")
        savedTask.scheduledAt = Dates.calendar.startOfDay(for: Date()); savedTask.repeatRule = "daily"
        savedTask.isDone = true; savedTask.ensureNextOccurrence(in: moneyContext); try Store.save(moneyContext)
        try require(try moneyContext.fetch(FetchDescriptor<TaskItem>()).count == 2 && FinanceStore.read(moneyContext)?.entries.count == 1,
                    "Completing a repeating task creates its next task without another financial posting")

        // Task ↔ entry links: one summary per task, posting on completion, no new links to deleted tasks,
        // unlinking on purge, and which tasks the picker offers.
        let linkTask = UUID(), otherTask = UUID()
        let now = Date()
        let yesterday = Dates.calendar.date(byAdding: .day, value: -1, to: now)!, inTwoDays = Dates.calendar.date(byAdding: .day, value: 2, to: now)!
        func linkedEntry(_ title: String, _ amount: Decimal, pending: Bool, on day: Date, task: UUID = linkTask) -> MoneyEntry {
            var entry = MoneyEntry(); entry.title = title; entry.date = MoneyEntry.timestamp(day); entry.amount = amount
            entry.accountID = bank.id; entry.accountAmount = amount; entry.baseAmount = amount
            entry.bookID = ledger.books[0].id; entry.categoryID = ledger.defaultCategory(income: false)
            entry.taskID = task; entry.pending = pending ? true : nil
            return entry
        }
        var links = ledger
        var foreignPending = linkedEntry("Visa fee", 80, pending: true, on: yesterday)
        foreignPending.currency = "USD"; foreignPending.accountID = nil; foreignPending.accountAmount = 0; foreignPending.baseAmount = nil
        links.entries = [linkedEntry("Flight", 4860, pending: false, on: yesterday), linkedEntry("Bags", 320, pending: false, on: now),
                         linkedEntry("Rent", 3200, pending: true, on: yesterday), linkedEntry("Checkup", 580, pending: true, on: inTwoDays),
                         foreignPending, linkedEntry("Other task", 10, pending: false, on: now, task: otherTask)]
        try links.validate()
        let index = TaskMoneyIndex(links)
        let summary = index.summary(for: linkTask)
        try require(summary?.count == 5 && summary?.pendingCount == 3 && summary?.net == nil && index.summary(for: otherTask)?.net == -10
                    && index.summary(for: UUID()) == nil, "Each task has one summary; an unconverted entry leaves its total open")
        try require(summary?.lines.first.map { Dates.sameDay($0.date, inTwoDays) } == true, "A task's entries are listed newest first")
        var settled = links
        let outcome = settled.settlePendingEntries(ofTask: linkTask, now: now)
        let rent = settled.entries.first { $0.title == "Rent" }, checkup = settled.entries.first { $0.title == "Checkup" }
        try require(outcome.posted.count == 2 && outcome.needsReview.map(\.title) == ["Visa fee"]
                    && rent?.isPending == false && Dates.sameDay(rent!.date, yesterday)
                    && checkup?.isPending == false && Dates.sameDay(checkup!.date, now)
                    && settled.entries.first { $0.title == "Visa fee" }?.isPending == true && (try? settled.validate()) != nil,
                    "Completing posts due entries on their date, future ones today, and leaves an unconverted one for review")
        try require(settled.balance(bank.id) == bank.opening - 4860 - 320 - 3200 - 580 - 10, "Posted task entries change the account once")
        var again = settled
        try require(again.settlePendingEntries(ofTask: linkTask, now: now).posted.isEmpty, "Entries posted in Finance meanwhile are not posted twice")
        if let category = links.categories.firstIndex(where: { $0.id == ledger.defaultCategory(income: false) }) {
            var blocked = links
            blocked.categories[category].archived = true
            let before = blocked
            let partial = blocked.settlePendingEntries(ofTask: linkTask, now: now)
            try require(partial.posted.isEmpty && partial.needsReview.count == 3 && blocked == before,
                        "An entry that cannot be posted as it stands is left for review, never half posted")
        }
        try rejects("A task in Recently deleted takes no new entries") {
            try TaskLinkRule.check(newTaskID: linkTask, previousTaskID: nil) { _ in false }
        }
        let keepsLink = (try? TaskLinkRule.check(newTaskID: linkTask, previousTaskID: linkTask) { _ in false }) != nil
        let removesLink = (try? TaskLinkRule.check(newTaskID: nil, previousTaskID: linkTask) { _ in false }) != nil
        let linksAvailable = (try? TaskLinkRule.check(newTaskID: otherTask, previousTaskID: nil) { _ in true }) != nil
        try require(keepsLink && removesLink && linksAvailable,
                    "An existing link to a deleted task can stay or be removed; an available task can be linked")
        var unlinked = links
        try require(unlinked.unlinkTasks([linkTask]) == 5 && unlinked.entries.filter { $0.taskID == linkTask }.isEmpty
                    && unlinked.entries.count == links.entries.count && unlinked.entries.first { $0.title == "Other task" }?.taskID == otherTask,
                    "Purging a task unlinks only its entries and keeps every entry")
        savedTask.deletedAt = Date()
        try Store.save(moneyContext)
        try FinanceStore.stageUnlinking([savedTask.id], in: moneyContext)
        moneyContext.delete(savedTask)
        try Store.save(moneyContext)
        try require(FinanceStore.read(moneyContext)?.entries.count == 1 && FinanceStore.read(moneyContext)?.entries[0].taskID == nil,
                    "A purge and the unlinking of its entries save together")
        func candidate(_ title: String, done: Bool = false, deleted: Bool = false, days: Int?, completedDays: Int? = nil) -> TaskLinkOptions.Candidate {
            .init(id: UUID(), title: title, done: done, deleted: deleted,
                  date: days.flatMap { Dates.calendar.date(byAdding: .day, value: $0, to: now) },
                  completedAt: completedDays.flatMap { Dates.calendar.date(byAdding: .day, value: $0, to: now) })
        }
        let candidates = [candidate("Pay rent", days: 0), candidate("Checkup", days: 2), candidate("Renew passport", days: 40),
                          candidate("Book flight", done: true, days: -1, completedDays: -1), candidate("Old receipt", done: true, days: -60, completedDays: -60),
                          candidate("Trashed errand", deleted: true, days: 1), candidate("No date", days: nil)]
        let recent = TaskLinkOptions.make(candidates, query: "", now: now)
        try require(recent.open.map(\.title) == ["Pay rent", "Checkup"] && recent.done.map(\.title) == ["Book flight"],
                    "Without a search the picker offers this week's unfinished tasks and recent completions")
        let errand = TaskLinkOptions.make(candidates, query: "errand", now: now)
        try require(TaskLinkOptions.make(candidates, query: "passport", now: now).open.map(\.title) == ["Renew passport"]
                    && TaskLinkOptions.make(candidates, query: "receipt", now: now).done.map(\.title) == ["Old receipt"]
                    && errand.open.isEmpty && errand.done.isEmpty,
                    "Searching finds any task by name, never a deleted one")
        let week = TaskLinkOptions.make([candidate("Last week", days: -6), candidate("Yesterday", days: -1), candidate("Today", days: 0),
                                         candidate("In five days", days: 5), candidate("Tomorrow", days: 1),
                                         candidate("Done today", done: true, days: 0, completedDays: 0),
                                         candidate("Done earlier", done: true, days: -3, completedDays: -3)], query: "", now: now)
        let short = TaskLinkOptions.shortList(week, now: now)
        try require(short.open.map(\.title) == ["Yesterday", "Today", "Tomorrow"] && short.done.map(\.title) == ["Done today"] && short.hidden == 3,
                    "The short link list keeps the tasks nearest today in date order and counts the rest")
        try require(TaskLinkOptions.shortList(([], []), now: now).hidden == 0, "An empty link list has nothing to show more of")
        // The UI recovers the complete request after the old context is discarded.
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-RecurringDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        for round in 0..<3 {
            let url = recoveryRoot.appendingPathComponent("draft-\(round).store")
            let db = try Store.make(url: url), context = db.mainContext
            var value = FinanceData.initial
            let bank = MoneyAccount(name: "Recovery card", opening: 1000)
            value.accounts = [bank]
            var entry = value.newEntry(preferredBook: nil); entry.title = "Recurring recovery"; entry.amount = 10
            entry.accountID = bank.id; entry.accountAmount = 10; entry.baseAmount = 10
            entry.bookID = value.books[0].id
            let bill = MoneyRecurring(repeating: entry, rule: "monthly", until: nil, in: value)
            try value.addRecurring(bill)
            try FinanceStore.stage(value, in: context); try Store.save(context)
            let preview = value.recurringPreviews[0]
            let kept = FinanceDraft(ledger: value, entry: preview, expected: nil, amount: "10", actual: "10", received: "",
                fee: "", converted: "10", convertedFee: "", balance: 1000, confirmingPending: true,
                occurrence: .init(bill: bill, scheduled: bill.nextDate))
            try rejects("an interrupted recurring confirmation is reported") {
                try Store.discardingOnFailure(context) {
                    var proposed = try FinanceStore.read(context)!
                    try kept.request.apply(kept.entry, to: &proposed, baseCurrency: kept.ledger.baseCurrency)
                    try FinanceStore.stage(proposed, in: context)
                    throw TaskBackup.invalid("Injected failure before committing occurrence and next date")
                }
            }
            let reopened = try Store.make(url: url), fresh = reopened.mainContext
            try require(FinanceStore.read(fresh) == value && !context.hasChanges,
                        "failed staging leaves both ledger and next occurrence unchanged on disk")
            try FinanceStore.update(fresh) {
                try kept.request.apply(kept.entry, to: &$0, baseCurrency: kept.ledger.baseCurrency)
            }
            let verified = try Store.make(url: url)
            let saved = try FinanceStore.read(verified.mainContext)!
            try require(saved.entries.count == 1 && !saved.entries[0].isPending && saved.balance(bank.id) == 990
                        && saved.recurringBill(bill.id)?.nextDate == bill.followingDate,
                        "restored draft confirms once, advances the rule and persists the correct balance")
            let snapshot = try TaskBackup.capture(verified.mainContext)
            try require(try TaskBackup.decode(snapshot.encoded()).finance == saved,
                        "recovered occurrence and next period survive the existing backup format")
        }
        print("Editor checks passed: \(checks)")
        return checks
    }
}
