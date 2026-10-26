import Foundation
import SwiftData
import UserNotifications
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor enum TaskLifecycleChecks {
    static func notificationPlans(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let now = date(2035, 1, 1)
            let ordinary = (1...60).map { offset -> TaskItem in
                let task = TaskItem(title: "Ordinary", scheduledAt: now.addingTimeInterval(Double(offset) * 3600))
                task.reminderAt = task.scheduledAt; return task
            }
            let early = TaskItem(title: "Later task, earlier reminder", scheduledAt: now.addingTimeInterval(100 * 86400))
            early.reminderAt = now.addingTimeInterval(60)
            let plan = ReminderEntry.upcoming(ordinary + [early], now: now)
            try require(plan.count == 61 && plan.first?.id == early.id && plan.prefix(60).contains { $0.id == early.id },
                        "Queue capacity uses reminder time, never the task's scheduled date")
            let refilled = ReminderEntry.upcoming(ordinary + [early], now: now.addingTimeInterval(61))
            try require(refilled.count == 60 && refilled.last?.id == ordinary.last?.id,
                        "Refilling after the first reminder admits the previously deferred task")
            let snapshot = plan[0]
            early.title = "Edited"; early.reminderAt = now.addingTimeInterval(120)
            try require(snapshot.title != early.title && snapshot.date == now.addingTimeInterval(60),
                        "Async scheduler snapshots cannot mix an old ID with edited fields")
            let request = snapshot.request
            let trigger = request.trigger as! UNCalendarNotificationTrigger
            try require(trigger.dateComponents.calendar?.identifier == .gregorian && trigger.dateComponents.timeZone?.secondsFromGMT() == 0,
                        "Notification trigger uses an explicit Gregorian UTC calendar")
            try require(abs(trigger.nextTriggerDate()!.timeIntervalSince(snapshot.date)) < 1 && !trigger.repeats,
                        "Notification trigger fires at the saved instant, without implicit repeats")
            try require(snapshot.matches(request, desired: snapshot.request), "Unchanged reminder does not get requeued")
            let renamed = ReminderEntry(id: snapshot.id, title: "New title", date: snapshot.date)
            try require(!renamed.matches(request, desired: renamed.request), "Renaming refreshes the notification text")
            let moved = ReminderEntry(id: snapshot.id, title: snapshot.title, date: snapshot.date.addingTimeInterval(3600))
            try require(moved.identifier == snapshot.identifier && !moved.matches(request, desired: moved.request),
                        "Rescheduling replaces the same notification ID rather than adding a duplicate")
            let fractional = ReminderEntry(id: UUID(), title: "Fractional second", date: now.addingTimeInterval(60.8))
            let triggerTime = (fractional.request.trigger as! UNCalendarNotificationTrigger).nextTriggerDate()!
            try require(triggerTime >= fractional.date && triggerTime.timeIntervalSince(fractional.date) < 1,
                        "Rounding seconds never schedules a notification early")
            early.isDone = true
            try require(ReminderEntry.upcoming([early], now: now).isEmpty, "Completed tasks cannot keep pending reminders")
            early.isDone = false; early.deletedAt = now
            try require(ReminderEntry.upcoming([early], now: now).isEmpty, "Deleted tasks cannot keep pending reminders")
            early.deletedAt = nil; early.reminderAt = nil
            try require(ReminderEntry.upcoming([early], now: now).isEmpty, "Clearing a reminder removes it from the plan")
            early.reminderAt = now
            try require(ReminderEntry.upcoming([early], now: now).isEmpty, "Past reminders are not silently moved to a new time")
            early.reminderAt = now.addingTimeInterval(60); early.previewSourceID = UUID()
            try require(ReminderEntry.upcoming([early], now: now).isEmpty, "Calendar-only recurrence previews never send duplicate reminders")
            do {
                // A daily "take medicine" at 09:00, reminded on time; yesterday's was never ticked off.
                let container = try Store.make(url: FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-repeat-remind-\(UUID()).store"))
                let context = container.mainContext
                let start = Dates.calendar.date(from: DateComponents(year: 2035, month: 3, day: 5, hour: 9))!
                let pill = TaskItem(title: "吃药", scheduledAt: start)
                pill.hasTime = true; pill.repeatRule = "daily"
                pill.reminderKind = ReminderPreset.atTime.rawValue; pill.reminderAt = start
                context.insert(pill)
                let nextMorning = start.addingTimeInterval(86_400 - 3600)   // 08:00 the next day
                let plan = ReminderEntry.upcoming([pill], now: nextMorning)
                try require(plan.first?.date == start.addingTimeInterval(86_400) && plan.first?.id == pill.id && plan.first?.occurrence != nil,
                            "A repeating task is still reminded at its next time when the last one was not ticked off")
                try require(plan.count == 30 && Set(plan.map(\.identifier)).count == plan.count && plan.allSatisfy { !$0.early },
                            "Later times are distinct reminders, capped per series, and on-time ones are not treated as early")
                try require(ReminderNavigation.taskID(request: plan[0].identifier) == pill.id
                            && ReminderNavigation.taskID(request: ReminderNavigation.snoozePrefix + pill.id.uuidString + "-123") == pill.id
                            && ReminderNavigation.taskID(request: ReminderNavigation.prefix + pill.id.uuidString + "x") == nil,
                            "Reminders for later times and snoozed copies still open their task")
                try require(plan[0].request.content.categoryIdentifier == ReminderAction.dueCategory,
                            "An on-time reminder offers marking the task completed")
                pill.toggleCompletion(in: context, now: nextMorning)
                let after = ReminderEntry.upcoming(try context.fetch(FetchDescriptor<TaskItem>()), now: nextMorning)
                try require(after.filter { $0.date == start.addingTimeInterval(86_400) }.count == 1 && after.allSatisfy { $0.id != pill.id },
                            "Ticking it off hands reminders to the new instance without doubling any time")
                pill.isDone = false; pill.nextOccurrenceID = nil
                pill.repeatUntil = start.addingTimeInterval(2 * 86_400)
                try require(ReminderEntry.later(pill, now: nextMorning).count == 2, "Later reminders stop after the repeat's end day")
                let meeting = TaskItem(title: "Meeting", scheduledAt: start)
                meeting.hasTime = true; meeting.reminderKind = ReminderPreset.oneHour.rawValue; meeting.reminderAt = start.addingTimeInterval(-3600)
                let heads = ReminderEntry.upcoming([meeting], now: start.addingTimeInterval(-7200))
                try require(heads.first?.early == true && heads.first?.request.content.categoryIdentifier == ReminderAction.earlyCategory,
                            "A reminder before the task starts offers \"Got it\" rather than completing it")
                let old = heads[0].request
                let changed = UNMutableNotificationContent(); changed.title = old.content.title; changed.body = old.content.body
                try require(!heads[0].matches(UNNotificationRequest(identifier: old.identifier, content: changed, trigger: old.trigger), desired: old),
                            "Reminders queued before the buttons existed are replaced so they gain them")
            }
            for preset in [ReminderPreset.morning, .dayBefore] {
                let task = TaskItem(title: "All-day reminder", scheduledAt: now.addingTimeInterval(3 * 86400))
                task.reminderKind = preset.rawValue
                task.reminderAt = preset.date(base: task.scheduledAt, timed: false)
                let original = task.reminderAt
                task.schedule(at: task.scheduledAt!.addingTimeInterval(3600))
                try require(task.reminderAt == original && task.resolvedReminderPreset == .custom,
                            "Dragging an all-day reminder onto a time never silently erases it: " + preset.rawValue)
                task.reschedule(to: now.addingTimeInterval(5 * 86400))
                try require(task.reminderAt == original, "Converted custom reminder retains its exact moment on later moves")
            }
            let timedTask = TaskItem(title: "Relative reminder", scheduledAt: now.addingTimeInterval(86400))
            timedTask.hasTime = true; timedTask.reminderKind = "oneHour"; timedTask.reminderAt = timedTask.scheduledAt!.addingTimeInterval(-3600)
            timedTask.schedule(at: now.addingTimeInterval(90000))
            try require(timedTask.reminderAt == timedTask.scheduledAt!.addingTimeInterval(-3600), "Timed dragging preserves the relative reminder's lead time")
            let oldReminder = timedTask.reminderAt
            timedTask.makeAllDay(on: now.addingTimeInterval(2 * 86400))
            try require(timedTask.reminderAt == oldReminder && timedTask.resolvedReminderPreset == .custom,
                        "Removing the task's time preserves an existing reminder as custom")
            let test = ReminderScheduler.testRequest()
            let testDate = (test.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            try require(!test.identifier.hasPrefix(ReminderNavigation.prefix) && testDate.map { $0 > Date() && $0.timeIntervalSinceNow <= 6 } == true,
                        "Test notification is isolated and uses the same calendar trigger as task reminders")
            var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
            func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 30) -> Date {
                ny.date(from: DateComponents(year: 2030, month: month, day: day, hour: hour, minute: minute))!
            }
            // Both the missing spring hour and the repeated autumn hour used to distort the lead time.
            for (base, next) in [(local(3, 9, 3), local(3, 10, 3)), (local(11, 2, 2), local(11, 3, 2))] {
                let task = TaskItem(title: "DST repeat", scheduledAt: base)
                task.hasTime = true; task.repeatRule = "daily"
                for preset in [ReminderPreset.atTime, .tenMinutes, .oneHour] {
                    task.reminderKind = preset.rawValue
                    task.reminderAt = preset.date(base: base, timed: true, calendar: ny)
                    let occurrence = task.occurrence(at: next, calendar: ny)
                    let seconds = preset == .oneHour ? 3600.0 : preset == .tenMinutes ? 600.0 : 0
                    try require(occurrence.reminderAt == next.addingTimeInterval(-seconds),
                                "Repeating relative reminder keeps its exact lead time across DST: " + preset.rawValue)
                    let entry = ReminderEntry(id: UUID(), title: "DST", date: occurrence.reminderAt!)
                    try require(abs((entry.request.trigger as! UNCalendarNotificationTrigger).nextTriggerDate()!.timeIntervalSince(entry.date)) < 1,
                                "DST notification trigger preserves the absolute reminder time")
                }
                task.reminderKind = "custom"; task.reminderAt = base.addingTimeInterval(-3600)
                try require(task.occurrence(at: next, calendar: ny).reminderAt == ny.date(byAdding: .day, value: 1, to: task.reminderAt!),
                            "Custom recurring reminders retain their chosen wall-clock time")
            }
        }
    }

    static func reminderNavigation(require: (Bool, String) throws -> Void) throws {
        do {
            let id = UUID(), later = UUID()
            try require(ReminderNavigation.taskID(request: ReminderNavigation.prefix + id.uuidString) == id, "Existing notification request identifiers still resolve")
            try require(ReminderNavigation.taskID(request: "other-" + id.uuidString) == nil, "Unrelated notifications do not navigate")
            try require(ReminderNavigation.taskID(request: ReminderNavigation.prefix + "invalid") == nil, "Malformed notification identifiers are ignored")
            try require(ReminderNavigation.taskID(url: ReminderNavigation.url(id)) == id, "Reminder URL preserves task identity")
            for value in ["https://reminder/", "jianshi://task/", "jianshi://reminder/user/", "jianshi://user@reminder/"] {
                try require(ReminderNavigation.taskID(url: URL(string: value + id.uuidString)!) == nil, "Reject unrelated or malformed reminder link: \(value)")
            }
            var route = ReminderNavigation(pendingTaskID: id)
            try require(route.take(blocked: true) == nil && route.pendingTaskID == id, "Cold startup or editing keeps pending notification navigation")
            route.pendingTaskID = later
            try require(route.take(blocked: false) == later && route.pendingTaskID == nil, "After editing open the most recently selected notification once")
            try require(route.take(blocked: false) == nil, "Consumed notification cannot reopen an editor")
            let inbox = ReminderInbox()
            let financePresentation = EditorDrafts()
            try require(!financePresentation.financePresentationActive, "A new window has no finance presentation blocking reminders")
            financePresentation.financePresentationGeneration = Store.recovery.generation
            try require(financePresentation.financePresentationActive, "Open finance dialogs defer reminder navigation")
            financePresentation.financePresentationGeneration = Store.recovery.generation - 1
            try require(!financePresentation.financePresentationActive, "Recovered windows ignore obsolete finance presentation state")
            let finance = FinanceData.initial
            var entry = MoneyEntry(); entry.amount = 10; entry.bookID = finance.books[0].id
            let recurring = MoneyRecurring(repeating: entry, rule: "monthly", until: nil, in: finance)
            financePresentation.financeRecurring = FinanceRecurringDraft(original: recurring, source: nil, bill: recurring,
                                                                         amount: "10.00", accountAmount: "")
            route.pendingTaskID = id
            try require(financePresentation.hasFinanceDraft && financePresentation.financeNavigationBlocked
                        && route.take(blocked: financePresentation.financeNavigationBlocked) == nil,
                        "recurring draft blocks reminder navigation even while a recovered sheet is not yet presented")
            financePresentation.financePresentationGeneration = Store.recovery.generation
            financePresentation.clearRecurringDraft(id: recurring.id, generation: Store.recovery.generation)
            try require(route.take(blocked: financePresentation.financeNavigationBlocked) == nil,
                        "cleared draft waits until the recurring sheet has closed")
            financePresentation.financePresentationGeneration = nil
            try require(route.take(blocked: financePresentation.financeNavigationBlocked) == id
                        && route.take(blocked: false) == nil,
                        "saving or discarding a recurring draft allows the queued reminder exactly once")
            inbox.receive(id)
            try require(inbox.navigation.take(blocked: true) == nil && inbox.navigation.pendingTaskID == id,
                        "Notification tap survives delivery before an active iOS window exists")
            inbox.receive(later)
            route.pendingTaskID = inbox.navigation.take(blocked: false)
            try require(route.pendingTaskID == later && inbox.navigation.pendingTaskID == nil,
                        "An active window accepts the latest notification exactly once")
            try require(route.take(blocked: true) == nil && route.pendingTaskID == later,
                        "Accepted notification waits while a task or finance draft is open")
            try require(route.take(blocked: false) == later && inbox.navigation.take(blocked: false) == nil,
                        "Closing the editor opens the accepted notification without redelivery")
        }
    }

    static func financeEntityDrafts(require: (Bool, String) throws -> Void) throws {
        let drafts = EditorDrafts()
        var ledger = FinanceData.initial
        ledger.books[0].budget = 100
        let book = ledger.books[0]
        var draft = FinanceEntityDraft(original: ledger, kind: .book, id: book.id, name: book.name,
            currency: ledger.baseCurrency, opening: "0", symbol: "", archived: false, accountID: nil, budget: "200")
        // Cover both callback orders: reopen before/after the previous sheet disappears.
        for _ in 0..<3 {
            for disappearsFirst in [false, true] {
                let oldOwner = UUID(), newOwner = UUID(), generation = Store.recovery.generation
                try require(drafts.beginEntityDraft(owner: oldOwner, kind: .book, id: book.id) == nil,
                            "a fresh budget editor has no completed or discarded draft")
                drafts.keepEntityDraft(draft, owner: oldOwner, generation: generation)
                drafts.clearEntityDraft(owner: oldOwner, generation: generation)
                if disappearsFirst { drafts.clearEntityDraft(owner: oldOwner, generation: generation) }
                try require(drafts.beginEntityDraft(owner: newOwner, kind: .book, id: book.id) == nil,
                            "rapid reopen cannot restore the previous editor's baseline")
                var fresh = draft; fresh.original.books[0].budget = 200; fresh.budget = "250"
                drafts.keepEntityDraft(fresh, owner: newOwner, generation: generation)
                drafts.keepEntityDraft(draft, owner: oldOwner, generation: generation)
                drafts.clearEntityDraft(owner: oldOwner, generation: generation)
                try require(drafts.financeEntity?.budget == "250" && drafts.financeEntity?.original.books[0].budget == 200,
                            "late change and dismissal callbacks cannot replace or clear the new budget draft")
                drafts.clearEntityDraft(owner: newOwner, generation: generation)
                drafts.keepEntityDraft(fresh, owner: newOwner, generation: generation)
                try require(drafts.financeEntity == nil, "a closing editor cannot recreate its discarded draft")
            }
        }
        // Account → balance entry → book retains each level, including delayed dismissal callbacks.
        let rootOwner = UUID(), innerOwner = UUID(), entryID = UUID()
        let currentGeneration = Store.recovery.generation
        var rootDraft = draft; rootDraft.kind = .account; rootDraft.name = "Outer account input"
        _ = drafts.beginEntityDraft(owner: rootOwner, kind: .account, id: rootDraft.id)
        drafts.keepEntityDraft(rootDraft, owner: rootOwner, generation: currentGeneration)
        _ = drafts.beginEntityDraft(owner: innerOwner, kind: .book, id: draft.id, parentEntryID: entryID)
        drafts.keepEntityDraft(draft, owner: innerOwner, generation: currentGeneration, parentEntryID: entryID)
        try require(drafts.entityDraft()?.name == rootDraft.name && drafts.entityDraft(parentEntryID: entryID)?.budget == "200",
                    "nested entity input cannot overwrite its outer account draft")
        try require(drafts.entityDraft(parentEntryID: entryID)?.request.existingID == book.id,
                    "nested presentation restores the original identity")
        let unrelatedOwner = UUID()
        _ = drafts.beginEntityDraft(owner: unrelatedOwner, kind: .category, id: nil, parentEntryID: entryID)
        drafts.keepEntityDraft(rootDraft, owner: unrelatedOwner, generation: currentGeneration, parentEntryID: entryID)
        drafts.clearEntityDraft(owner: unrelatedOwner, generation: currentGeneration, parentEntryID: entryID)
        try require(drafts.entityDraft(parentEntryID: entryID)?.kind == .book,
                    "a different editor cannot claim or erase an interrupted inner draft")
        drafts.clearEntityDraft(owner: innerOwner, generation: currentGeneration, parentEntryID: entryID)
        try require(drafts.entityDraft(parentEntryID: entryID) == nil && drafts.entityDraft()?.name == rootDraft.name,
                    "closing the inner editor preserves its outer draft")
        drafts.clearEntityDraft(owner: rootOwner, generation: currentGeneration)
        try require(!drafts.hasFinanceDraft, "explicit closing releases every retained entity draft")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-EntityDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let container = try Store.make(url: url)
        try FinanceStore.update(container.mainContext) { $0 = ledger }
        let entry = MoneyEntry()
        drafts.finance = FinanceDraft(ledger: ledger, entry: entry, expected: nil, amount: "004321.00",
            actual: "", received: "", fee: "", converted: "", convertedFee: "", balance: 0)
        var owner = UUID(), generation = Store.recovery.generation
        _ = drafts.beginEntityDraft(owner: owner, kind: .book, id: book.id)
        draft.budget = "00250.00"
        drafts.keepEntityDraft(draft, owner: owner, generation: generation)
        for _ in 0..<2 {
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
            let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url,
                allowsSave: false, cloudKitDatabase: .none)])
            readOnly.mainContext.autosaveEnabled = false
            var failed = false
            do { try FinanceStore.update(readOnly.mainContext) { $0.books[0].budget = 250 } }
            catch { failed = true }
            try require(failed && Store.recovery.failure != nil, "entity draft recovery uses a real isolated save failure")
            drafts.clearEntityDraft(owner: owner, generation: generation)
            try require(drafts.financeEntity?.budget == "00250.00", "save failure preserves exact budget input")
            try require(Store.recovery.reload(), "entity draft failure reloads only the isolated database")
            let previousOwner = owner, previousGeneration = generation
            owner = UUID(); generation = Store.recovery.generation
            let kept = drafts.beginEntityDraft(owner: owner, kind: .book, id: book.id)
            try require(kept?.budget == "00250.00" && kept?.original == ledger, "recovery adopts input and its original version together")
            drafts.keepEntityDraft(draft, owner: owner, generation: generation)
            drafts.clearEntityDraft(owner: previousOwner, generation: previousGeneration)
            drafts.keepEntityDraft(draft, owner: previousOwner, generation: previousGeneration)
            try require(drafts.financeEntity?.budget == "00250.00" && drafts.finance?.amount == "004321.00",
                        "retired nested editor callbacks preserve both inner and outer recovery drafts")
            try require(try FinanceStore.read(Store.recovery.container!.mainContext) == ledger,
                        "failed budget save leaves the committed ledger unchanged")
        }
        var updated = book; updated.budget = 250
        try FinanceStore.update(Store.recovery.container!.mainContext) {
            try $0.updateBook(updated, expected: drafts.financeEntity!.original.books[0], baseCurrency: ledger.baseCurrency)
        }
        drafts.clearEntityDraft(owner: owner, generation: generation)
        try require(drafts.financeEntity == nil && drafts.finance?.amount == "004321.00",
                    "successful inner save clears only its own draft")
        let reopened = try Store.make(url: url)
        try require(try FinanceStore.read(reopened.mainContext)?.books[0].budget == 250,
                    "retry commits the recovered budget and survives reopening")
    }

    static func suggestionTemplates(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let source = TaskItem(title: "Template", scheduledAt: date(2026, 9, 10))
            source.hasTime = true; source.endAt = source.scheduledAt!.addingTimeInterval(7200)
            source.dueAt = date(2026, 9, 12); source.dueHasTime = true
            source.notes = "Full notes"; source.priority = 2
            source.subtasks = [Subtask(title: "Step", isDone: true)]
            source.isDone = true; source.repeatRule = "daily"
            source.reminderKind = "custom"; source.reminderAt = date(2026, 9, 9)
            let template = TaskSuggestions.Template(source, day: date(2026, 10, 1), scheduled: true)
            try require(template.title == source.title && template.notes == source.notes && template.priority == 2, "Template copies task details")
            try require(template.start == date(2026, 10, 1) && template.end == date(2026, 10, 1).addingTimeInterval(7200), "Template preserves clock and duration on new date")
            try require(template.due == date(2026, 10, 3) && template.reminder == date(2026, 9, 30), "Template shifts deadline and custom reminder across months")
            try require(template.subtasks.count == 1 && !template.subtasks[0].isDone && template.subtasks[0].id != source.subtasks[0].id, "Template gives incomplete subtasks fresh identities")
            try require(source.isDone && source.subtasks[0].isDone && source.scheduledAt == date(2026, 9, 10), "Template leaves source history untouched")
            source.reminderKind = "oneHour"
            let relative = TaskSuggestions.Template(source, day: date(2026, 10, 1), scheduled: true)
            try require(relative.reminder == relative.start!.addingTimeInterval(-3600), "Template recalculates relative reminder")
            let plain = TaskSuggestions.Template(TaskItem(title: "Undated"), day: date(2026, 10, 1), scheduled: false)
            try require(plain.start == nil && plain.end == nil && plain.due == nil && plain.reminder == nil && plain.listID == nil && plain.subtasks.isEmpty, "Plain template clears previously entered optional fields")
        }
    }

    static func taskOrdering(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let earlyDone = TaskItem(title: "Done", scheduledAt: date(2026, 9, 20))
            earlyDone.hasTime = true; earlyDone.isDone = true
            let late = TaskItem(title: "Later", scheduledAt: earlyDone.scheduledAt!.addingTimeInterval(7200)); late.hasTime = true
            let early = TaskItem(title: "Earlier", scheduledAt: earlyDone.scheduledAt!.addingTimeInterval(3600)); early.hasTime = true
            let ordered = [earlyDone, late, early].sorted(by: TaskItem.incompleteFirst)
            try require(ordered.map(\.id) == [early.id, late.id, earlyDone.id], "Month shows unfinished first, preserving time order within each status")
            late.isDone = true
            try require([late, earlyDone, early].sorted(by: TaskItem.incompleteFirst).map(\.id) == [early.id, earlyDone.id, late.id],
                        "Completing a month task moves it after unfinished tasks without hiding it")
            let allDay = TaskItem(title: "All-day", scheduledAt: date(2026, 9, 20))
            let deadline = TaskItem(title: "Deadline"); deadline.dueAt = early.scheduledAt; deadline.dueHasTime = true; deadline.priority = 2
            let undated = TaskItem(title: "Undated")
            let nextDay = TaskItem(title: "Tomorrow", scheduledAt: date(2026, 9, 21))
            let input = [undated, allDay, nextDay, late, early, deadline, earlyDone]
            try require(TaskItem.ordered(input).map(\.id) == [earlyDone, deadline, early, late, allDay, nextDay, undated].map(\.id),
                        "Bulk calendar order keeps civil date, clock, priority and undated ordering")
            try require(TaskItem.ordered(input, incompleteFirst: true).map(\.id) == [deadline, early, allDay, nextDay, undated, earlyDone, late].map(\.id),
                        "Bulk month order moves completed tasks after every unfinished task")
            early.isDone = true; early.scheduledAt = date(2026, 9, 22)
            try require(TaskItem.ordered(input, incompleteFirst: true).last?.id == early.id,
                        "Bulk ordering immediately reflects completion and schedule edits")
            early.scheduledAt = late.scheduledAt; early.createdAt = late.createdAt; early.priority = late.priority
            early.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            late.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            try require(TaskItem.ordered([late, early]).map(\.id) == [early.id, late.id], "Equal schedule keys keep deterministic identity order")
        }
    }

    static func sidebarOrdering(require: (Bool, String) throws -> Void) throws {
        do {
            let parent = TaskList(name: "Parent"), child = TaskList(name: "Child"), sibling = TaskList(name: "Sibling")
            parent.sortOrder = 0; sibling.sortOrder = 1; child.parentID = parent.id
            let lists = [sibling, child, parent]
            let closed: Set<UUID> = [], opened: Set<UUID> = [parent.id]
            try require(ListNode.visibleIDs(ListNode.roots(lists), expanded: closed) == [parent.id, sibling.id], "Sidebar keyboard skips collapsed children")
            try require(ListNode.visibleIDs(ListNode.roots(lists), expanded: opened) == [parent.id, child.id, sibling.id], "Sidebar keyboard follows visible nested order")
            try require(TaskScope.trash.adjacentSidebarScope(direction: 1, lists: lists, expanded: closed) == .list(parent.id), "Down enters custom lists from native sections")
            try require(TaskScope.list(parent.id).adjacentSidebarScope(direction: -1, lists: lists, expanded: closed) == .trash, "Up returns to native sidebar sections")
            try require(TaskScope.list(parent.id).adjacentSidebarScope(direction: 1, lists: lists, expanded: closed) == .list(sibling.id), "Down skips hidden child")
            try require(TaskScope.list(parent.id).adjacentSidebarScope(direction: 1, lists: lists, expanded: opened) == .list(child.id), "Down enters expanded group")
            try require(TaskScope.calendar.adjacentSidebarScope(direction: -1, lists: [], expanded: closed) == .calendar && TaskScope.trash.adjacentSidebarScope(direction: 1, lists: [], expanded: closed) == .trash, "Empty-list navigation stops safely at bounds")
            try require(TaskScope.list(sibling.id).adjacentSidebarScope(direction: 1, lists: lists, expanded: opened) == .list(sibling.id), "Down at the last visible list does not wrap")
        }
    }

    static func taskCopies(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let start = date(2030, 9, 16)
            let source = TaskItem(title: "Copy planning", scheduledAt: start)
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            let occupied = [CGRect(x: 44, y: layout.y(900), width: 98, height: 72)]
            func slot(_ x: Double, _ minute: Double, _ scale: TimelineLayout? = nil) -> PlanSlot? {
                let grid = scale ?? layout
                return PlanSlot.emptyPoint(CGPoint(x: x, y: grid.y(minute)), column: 100, gutter: 44, layout: grid, occupied: occupied)
            }
            try require(slot(294, 976) == PlanSlot(day: 2, minute: 975), "Right-click targets the clicked day and quarter hour")
            try require(slot(80, 930) == nil, "Right-click on a task must keep its task menu, not paste underneath")
            try require(slot(43, 900) == nil && slot(744, 900) == nil && slot(80, -1) == nil && slot(80, 1440) == nil,
                        "Paste rejects gutter, outside columns and outside the day")
            try require(slot(743, 1439) == PlanSlot(day: 6, minute: 1425), "Last column and final quarter hour remain pasteable")
            try require(slot(344, 615, TimelineLayout(startMinute: 0, endMinute: 1440, scale: 0.3)) == PlanSlot(day: 3, minute: 615),
                        "Paste location follows timeline zoom")
            source.notes = "Keep notes"; source.hasTime = true; source.endAt = start.addingTimeInterval(3600)
            source.dueAt = source.endAt; source.dueHasTime = true; source.priority = 2
            source.reminderAt = start.addingTimeInterval(-900); source.reminderKind = ReminderPreset.custom.rawValue
            source.isDone = true; source.completedAt = start; source.repeatRule = "weekly"; source.repeatUntil = date(2031, 1, 1)
            source.nextOccurrenceID = UUID(); source.subtasks = [Subtask(title: "Done step", isDone: true)]
            let original = TaskBackup.TaskRecord(source), next = original.nextCopyDate!
            let destination = date(2030, 9, 18)
            let dayPaste = TaskCopyRequest(record: original, on: destination)
            try require(dayPaste.timed && Dates.sameDay(dayPaste.moment, destination)
                        && Dates.clockMinute(dayPaste.moment) == floor(Dates.clockMinute(start)) && dayPaste.record == original,
                        "Phone day paste targets the selected date with the copied start time, without changing the snapshot")
            let slotPaste = TaskCopyRequest(record: original, on: destination, minute: 975)
            try require(slotPaste.timed && Dates.sameDay(slotPaste.moment, destination) && Dates.clockMinute(slotPaste.moment) == 975,
                        "Phone week paste confirms the tapped quarter-hour instead of the next interval")
            let dayOnlyPaste = TaskCopyRequest(record: original, on: destination, minute: 975, allDay: true)
            try require(!dayOnlyPaste.timed && dayOnlyPaste.moment == Dates.calendar.startOfDay(for: destination),
                        "Explicit all-day paste overrides a copied timed task and clears its time")
            let undatedRecord = TaskBackup.TaskRecord(TaskItem(title: "Undated copy"))
            let undatedPaste = TaskCopyRequest(record: undatedRecord, on: destination)
            try require(!undatedPaste.timed && undatedPaste.moment == Dates.calendar.startOfDay(for: destination),
                        "Undated copies default to the chosen day without inventing a time")
            let undatedSlot = TaskCopyRequest(record: undatedRecord, on: destination, minute: 600)
            try require(undatedSlot.timed && Dates.clockMinute(undatedSlot.moment) == 600,
                        "An explicit week slot can schedule an undated copied task")
            let dueOnly = TaskItem(title: "Due-only copy"); dueOnly.dueAt = start; dueOnly.dueHasTime = true
            let duePaste = TaskCopyRequest(record: TaskBackup.TaskRecord(dueOnly), on: destination)
            try require(duePaste.timed && Dates.sameDay(duePaste.moment, destination)
                        && Dates.clockMinute(duePaste.moment) == floor(Dates.clockMinute(start)),
                        "A due-only copied task retains its deadline clock when choosing another day")
            let duplicate = original.duplicate(at: next, timed: true, list: nil)
            try require(duplicate.id != source.id && duplicate.subtasks[0].id != source.subtasks[0].id && !duplicate.isDone && !duplicate.subtasks[0].isDone,
                        "Copy makes independent task and subtask identities, resetting completion")
            try require(duplicate.repeatRule == "none" && duplicate.repeatUntil == nil && duplicate.nextOccurrenceID == nil && duplicate.previewSourceID == nil,
                        "Copy cannot fork an existing repeat sequence")
            try require(duplicate.scheduledAt == source.endAt && duplicate.duration == 3600 && duplicate.dueAt == next.addingTimeInterval(3600)
                        && duplicate.reminderAt == next.addingTimeInterval(-900) && duplicate.priority == 2 && duplicate.notes == source.notes,
                        "Next-interval copy keeps length, notes, priority and relative deadline/custom reminder")
            try require(TaskBackup.TaskRecord(source) == original, "Copy never changes the source task")
            let again = original.duplicate(at: next, timed: true, list: nil)
            try require(again.id != duplicate.id, "Repeated paste creates a new independent task each time")
            source.reminderKind = ReminderPreset.oneHour.rawValue; source.reminderAt = start.addingTimeInterval(-3600)
            let relative = TaskBackup.TaskRecord(source).duplicate(at: next, timed: true, list: nil)
            try require(relative.reminderAt == next.addingTimeInterval(-3600), "Preset reminder follows the pasted time")
            let allDay = original.duplicate(at: date(2030, 9, 18), timed: false, list: nil)
            try require(!allDay.hasTime && allDay.endAt == nil && allDay.scheduledAt == Dates.calendar.startOfDay(for: date(2030, 9, 18)), "Pasting in the all-day row removes clock duration")
            var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
            let beforeDST = ny.date(from: DateComponents(year: 2030, month: 3, day: 10, hour: 1, minute: 30))!
            source.scheduledAt = beforeDST; source.endAt = beforeDST.addingTimeInterval(3600); source.dueAt = source.endAt
            source.reminderKind = ReminderPreset.custom.rawValue; source.reminderAt = beforeDST.addingTimeInterval(-900)
            let copiedDST = TaskBackup.TaskRecord(source).duplicate(at: source.endAt!, timed: true, list: nil)
            try require(ny.component(.hour, from: copiedDST.scheduledAt!) == 3 && copiedDST.duration == 3600
                        && copiedDST.reminderAt == copiedDST.scheduledAt!.addingTimeInterval(-900), "Timed copy preserves elapsed duration and reminder across the missing DST hour")
        }
    }

    static func listMoveUndo(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let url = directory.appendingPathComponent("task-list-move.store")
            let container = try Store.make(url: url), context = container.mainContext
            let work = TaskList(name: "Work"), study = TaskList(name: "Study"), child = TaskList(name: "Course")
            child.parentID = study.id
            [work, study, child].forEach { context.insert($0) }
            let task = TaskItem(title: "Move one task", scheduledAt: date(2026, 9, 20), list: work)
            task.hasTime = true; task.endAt = task.scheduledAt!.addingTimeInterval(3600)
            task.notes = "Keep notes"; task.priority = 2; task.subtasks = [Subtask(title: "Keep subtask", isDone: true)]
            task.dueAt = date(2026, 9, 22); task.repeatRule = "weekly"
            task.reminderKind = "custom"; task.reminderAt = date(2026, 9, 19)
            context.insert(task); try Store.save(context)
            func details(_ item: TaskItem) throws -> Data {
                var record = TaskBackup.TaskRecord(item); record.listID = nil
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return try encoder.encode(record)
            }
            let before = try details(task)
            try require(task.changeList(to: study) && task.list?.id == study.id, "Task drag changes destination list")
            try require(try details(task) == before, "List move preserves every other task field and identity")
            try require(!task.changeList(to: study), "Dropping into current list is a no-op")
            try require(task.changeList(to: child) && child.parentID == study.id && work.parentID == nil,
                        "Task can enter a nested list without moving the list hierarchy")
            try Store.save(context)
            let reopened = try Store.make(url: url)
            let persisted = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
            try require(persisted.list?.id == child.id && (try? details(persisted)) == before, "Task category survives relaunch with all other data intact")
            let backup = try TaskBackup.capture(context)
            try require(backup.tasks.first?.listID == child.id, "Backup records moved task category")
            task.isDone = true; task.completedAt = date(2026, 9, 21)
            let completed = try details(task)
            try require(task.changeList(to: work) && (try? details(task)) == completed, "Completed task can change list without losing history")
            try require(task.changeList(to: nil) && task.list == nil, "Undo can restore an originally unclassified task")
            task.deletedAt = Date()
            try require(!task.changeList(to: study) && task.list == nil, "Trash tasks cannot be recategorized through drag")
            task.deletedAt = nil
            try require(task.changeList(to: work) && task.list?.id == work.id, "Undo restores original list")
        }
    }

    static func deletedListChildren(directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let container = try Store.make(url: directory.appendingPathComponent("promote-lists.store")), context = container.mainContext
            let parent = TaskList(name: "Work"), sibling = TaskList(name: "Meetings"), numbered = TaskList(name: "meetings (2)"), child = TaskList(name: "meetings")
            let grandchild = TaskList(name: "Notes"); grandchild.parentID = child.id; child.parentID = parent.id
            let task = TaskItem(title: "Keep my category", list: child)
            for list in [parent, sibling, numbered, child, grandchild] { context.insert(list) }; context.insert(task)
            try Store.save(context)
            ListTree.promoteChildren(of: parent, lists: [parent,sibling,numbered,child,grandchild]); context.delete(parent); try Store.save(context)
            try require(child.name == "meetings (3)" && child.parentID == nil && grandchild.parentID == child.id && task.list?.id == child.id,
                        "Deleting parent resolves names case-insensitively and keeps task and descendant identities")
            let longParent = TaskList(name: "Parent"), longSibling = TaskList(name: String(repeating: "a", count: 40)), longChild = TaskList(name: String(repeating: "a", count: 40))
            longChild.parentID = longParent.id
            ListTree.promoteChildren(of: longParent, lists: [longParent,longSibling,longChild])
            try require(longChild.name.count == 40 && longChild.name.hasSuffix(" (2)"), "Renamed child stays within the exportable name length")
        }
    }

    static func moveDeadlineProposals(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let task = TaskItem(title: "Move with deadline", scheduledAt: date(2026, 9, 20))
            task.hasTime = true; task.endAt = date(2026, 9, 20).addingTimeInterval(3600)
            task.dueAt = date(2026, 9, 22); task.dueHasTime = true
            task.reminderAt = task.scheduledAt!.addingTimeInterval(-3600); task.reminderKind = "oneHour"
            let original = TaskSchedule(task)
            let future = TaskMove(task, to: date(2026, 10, 20), kind: .day)
            try require(TaskSchedule(task) == original && !future.canKeepDeadline && future.shiftedDeadline == date(2026, 10, 22), "Cross-month proposal changes nothing before confirmation and preserves deadline spacing")
            try require(!future.apply(to: task, shiftDeadline: false) && TaskSchedule(task) == original, "A conflicting deadline cannot be silently retained")
            try require(future.apply(to: task, shiftDeadline: true) && task.scheduledAt == date(2026, 10, 20) && task.dueAt == date(2026, 10, 22), "Confirmed move shifts the deadline and schedule together")
            let earlier = TaskMove(task, to: date(2026, 9, 20), kind: .day)
            try require(earlier.canKeepDeadline && earlier.shiftedDeadline == date(2026, 9, 22), "Moving back offers both retaining and moving the deadline back")
            try require(earlier.apply(to: task, shiftDeadline: true) && task.dueAt == original.dueAt && task.reminderAt == original.reminderAt && task.endAt == original.endAt, "Forward then backward with deadline preserves original times and relative reminder")
            let keep = TaskMove(task, to: date(2026, 9, 19), kind: .day)
            try require(keep.apply(to: task, shiftDeadline: false) && task.dueAt == original.dueAt, "Retain option moves schedule without changing deadline")
            try require(!TaskMove(task, to: date(2026, 9, 19), kind: .day).changesSchedule, "Dropping on the existing day has no confirmation or mutation")
            let stale = TaskMove(task, to: date(2026, 9, 18), kind: .allDay)
            task.dueHasTime = false
            try require(!stale.apply(to: task, shiftDeadline: true), "A stale confirmation cannot overwrite another deadline edit")
            original.restore(task)
            let timed = TaskMove(task, to: task.scheduledAt!.addingTimeInterval(-7200), kind: .timed)
            try require(timed.shiftedDeadline == task.dueAt!.addingTimeInterval(-7200), "A timed move shifts timed deadlines by the same clock interval")
            let allDay = TaskMove(task, to: date(2026, 10, 20), kind: .allDay)
            try require(allDay.apply(to: task, shiftDeadline: true) && !task.hasTime && task.endAt == nil && Dates.sameDay(task.dueAt!, date(2026, 10, 22)), "All-day drop uses the same deadline confirmation policy")
            let onlyDue = TaskItem(title: "Deadline only"); onlyDue.dueAt = date(2026, 9, 22); onlyDue.dueHasTime = true
            let dueMove = TaskMove(onlyDue, to: date(2026, 9, 21), kind: .day)
            try require(dueMove.apply(to: onlyDue, shiftDeadline: false) && onlyDue.scheduledAt == date(2026, 9, 21) && onlyDue.dueAt == date(2026, 9, 22), "Deadline-only task can receive an earlier schedule without moving its deadline")
        }
    }

    static func planningOrder(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let base = date(2026, 9, 30)
            let morning = TaskItem(title: "Morning", scheduledAt: Dates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base)); morning.hasTime = true
            let evening = TaskItem(title: "Evening", scheduledAt: Dates.calendar.date(bySettingHour: 18, minute: 30, second: 0, of: base)); evening.hasTime = true; evening.priority = 2
            let untimed = TaskItem(title: "Untimed", scheduledAt: base); untimed.priority = 2
            let dueOnly = TaskItem(title: "Deadline"); dueOnly.dueAt = Dates.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: base); dueOnly.dueHasTime = true
            try require([untimed, evening, dueOnly, morning].sorted(by: TaskItem.plannedBefore).map(\.title) == ["Morning", "Deadline", "Evening", "Untimed"], "Clock order precedes priority, untimed last")
            try require(untimed.clockDate == nil && dueOnly.clockDate == dueOnly.dueAt, "Clock position respects explicit time flags")
            let nextMonth = TaskItem(title: "Next month", scheduledAt: date(2026, 10, 1))
            try require(TaskItem.plannedBefore(untimed, nextMonth), "Date order is before time order")
            let exact = Dates.calendar.date(bySettingHour: 14, minute: 15, second: 0, of: base)!
            let floating = TaskItem(title: "Floating"); floating.schedule(at: exact)
            try require(floating.scheduledAt == exact && floating.hasTime, "Undated task acquires exact quarter-hour start")
            let limit = Dates.calendar.date(bySettingHour: 13, minute: 0, second: 0, of: base)!
            floating.dueAt = limit; floating.dueHasTime = true
            let original = floating.scheduledAt; floating.schedule(at: exact.addingTimeInterval(3600))
            try require(floating.scheduledAt == original && floating.dueAt == limit, "Conflicting schedule cannot change task without confirmation")
            floating.schedule(at: exact, extendingDeadline: true)
            try require(floating.dueAt == exact.addingTimeInterval(3600) && floating.scheduledAt == exact, "Confirmed schedule extends deadline only as far as needed")
            morning.reminderAt = morning.scheduledAt!.addingTimeInterval(-3600); morning.reminderKind = "oneHour"
            morning.schedule(at: exact)
            try require(morning.reminderAt == exact.addingTimeInterval(-3600), "Exact scheduling recomputes relative reminder")
            morning.reminderKind = "custom"; let fixed = morning.reminderAt; morning.schedule(at: exact.addingTimeInterval(3600))
            try require(morning.reminderAt == fixed, "Exact scheduling preserves custom reminder")
            let deadline = dueOnly.dueAt; dueOnly.schedule(at: Dates.calendar.date(bySettingHour: 8, minute: 15, second: 0, of: base)!)
            try require(dueOnly.dueAt == deadline && dueOnly.hasTime && dueOnly.scheduledAt != nil, "Scheduling deadline-only task preserves its deadline")
            try require(Dates.weekCells(date(2026, 12, 31)).contains { Dates.sameDay($0, date(2027, 1, 1)) }, "Overview week continues across year boundary")
            evening.isDone = true; let complete = evening.isDone; evening.schedule(at: exact)
            try require(evening.isDone == complete, "Moving task does not change completion")
        }
    }

    static func resizeUndo(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let day = Dates.calendar.startOfDay(for: date(2026, 9, 21))
            func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
            let task = TaskItem(title: "Across days", scheduledAt: at(14)); task.hasTime = true; task.endAt = at(16)
            let before = TaskSchedule(task)
            let bottom = TaskResize(task: task, day: day, top: false)!, top = TaskResize(task: task, day: day, top: true)!
            try require(bottom.date(at: 600, dayIndex: 1) == at(34), "End handle reaches Tuesday 10 while keeping Monday start")
            try require(top.date(at: 600, dayIndex: 6, weekOffset: -1) == at(-14), "Start handle reaches previous Sunday across a week boundary")
            try require(bottom.date(at: 600, dayIndex: 0, weekOffset: 1) == at(178), "Next-week endpoint uses original week anchor")
            try require(top.date(at: 600, dayIndex: 2) == at(15.75) && bottom.date(at: 600, dayIndex: 6, weekOffset: -1) == at(14.25), "Cross-day resize cannot invert the interval")
            let interval = bottom.interval(at: 600, dayIndex: 2, weekOffset: 0)
            let slices = (0..<4).compactMap { PlanBlock.segment(from: interval.start, to: interval.end, on: at(Double($0 * 24))) }
            try require(slices.count == 3 && slices.map(\.duration).reduce(0, +) == interval.duration, "Multi-day preview segments preserve total duration")
            try require(PlanBlock.segment(from: at(14), to: at(24), on: at(24)) == nil, "Midnight endpoint creates no empty next-day block")
            let other = TaskItem(title: "Overlap", scheduledAt: at(33)); other.hasTime = true; other.endAt = at(35)
            let completed = TaskItem(title: "Completed", scheduledAt: at(30)); completed.hasTime = true; completed.isDone = true
            let deleted = TaskItem(title: "Deleted", scheduledAt: at(31)); deleted.hasTime = true; deleted.deletedAt = day
            let allDay = TaskItem(title: "All day", scheduledAt: day)
            let occupied = PlanBlock.occupied([task, other, completed, deleted, allDay], excluding: task.id)
            try require(occupied.count == 1 && PlanBlock.overlaps(DateInterval(start: at(14), end: at(34)), others: occupied), "Cross-day overlap excludes self, done, deleted and all-day tasks")
            try require(!PlanBlock.overlaps(DateInterval(start: at(14), end: at(33)), others: occupied), "Adjacent intervals do not show an overlap warning")
            #if os(macOS)
            let session = WeekDrag()
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 0.3)
            session.canvas = CGRect(x: 0, y: 0, width: 764, height: 432); session.viewport = session.canvas
            session.layout = layout; session.trailing = 20
            var endpoint: Date?, offset: Int?, drops = 0
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 194, y: 180), others: [task, other]) { value, page in endpoint = value; offset = page; drops += 1 }
            try require(session.zone == .timed(day: 1, minute: 600) && session.resizeInterval?.duration == 20 * 3600 && session.overlaps, "Resize preview follows horizontal date, duration and overlap without writing")
            try require(TaskSchedule(task) == before, "Cross-day preview does not mutate stored fields")
            session.move(to: CGPoint(x: 194, y: 162))
            try require(!session.overlaps, "Overlap warning disappears when endpoint no longer conflicts")
            session.move(to: CGPoint(x: 755, y: 180)); session.tick(now: 0); session.tick(now: 0.3)
            try require(session.weekOffset == 0 && session.zone == .none, "Resize edge waits before paging and cannot save on navigation strip")
            session.tick(now: 1)
            try require(session.weekOffset == 1 && session.isDragging, "Resize can page to next week while the original source is absent")
            session.move(to: CGPoint(x: 94, y: 180)); session.complete(); session.complete()
            try require(drops == 1 && endpoint == at(178) && offset == 1, "Release after paging sends absolute endpoint and page exactly once")
            let proposal = TaskMove(task, to: endpoint!, kind: .resizeEnd)
            try require(proposal.apply(to: task, shiftDeadline: false) && task.scheduledAt == at(14) && task.endAt == at(178), "Cross-week resize saves only the selected endpoint")
            try require(task.timeLabel == Dates.label(at(14), pattern: "M月d日 HH:mm") + "–" + Dates.label(at(178), pattern: "M月d日 HH:mm"), "Cross-day time label names both dates on continuation cards and details")
            before.restore(task)
            session.updateResize(task, color: .blue, range: top, point: CGPoint(x: 10, y: 180)) { _, _ in drops += 1 }
            session.tick(now: 0); session.tick(now: 1)
            try require(session.weekOffset == -1, "Start handle can page to previous week")
            session.move(to: CGPoint(x: 694, y: 180))
            try require(session.resizeInterval?.start == at(-14) && session.resizeInterval?.end == at(16), "Previous-week preview leaves end fixed")
            session.cancel(); session.move(to: CGPoint(x: 694, y: 200)); session.complete()
            try require(drops == 1 && TaskSchedule(task) == before && session.weekOffset == 0, "Esc after cross-week resizing restores page and prevents late save")
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 755, y: 180)) { _, _ in drops += 1 }
            session.tick(now: 0); session.tick(now: 1); session.complete()
            try require(drops == 1 && session.weekOffset == 0 && TaskSchedule(task) == before, "Releasing on resize paging edge cancels without a hidden change")
            #if os(macOS)
            final class ResizeDocument: NSView { override var isFlipped: Bool { true } }
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 764, height: 400))
            scroll.documentView = ResizeDocument(frame: CGRect(x: 0, y: 0, width: 764, height: 1728))
            session.scrollView = scroll
            session.canvas = CGRect(x: 0, y: 0, width: 764, height: 1728)
            session.viewport = CGRect(x: 0, y: 0, width: 764, height: 400)
            session.layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 194, y: 430)) { _, _ in drops += 1 }
            session.tick(now: 0); session.tick(now: 0.1)
            try require(scroll.contentView.bounds.minY == 0, "Resize briefly touching bottom edge does not scroll")
            for frame in 0..<100 { session.tick(now: 0.3 + Double(frame) * 0.016) }
            let scrolled = scroll.contentView.bounds.minY
            try require(scrolled > 720, "Holding resize at bottom edge scrolls to later hours")
            session.move(to: CGPoint(x: 194, y: 1)); session.tick(now: 2.1)
            try require(scroll.contentView.bounds.minY < scrolled, "Holding resize at top edge scrolls back toward earlier hours")
            let stopped = scroll.contentView.bounds.minY
            session.cancel(); session.tick(now: 3); session.complete()
            try require(scroll.contentView.bounds.minY == stopped && TaskSchedule(task) == before && drops == 1, "Cancel stops resize scrolling without saving")
            #endif
            #endif
            task.dueAt = at(30); task.dueHasTime = true
            let deadlineSnapshot = TaskSchedule(task)
            let conflict = TaskMove(task, to: at(34), kind: .resizeEnd)
            try require(!conflict.canKeepDeadline && !conflict.apply(to: task, shiftDeadline: false) && TaskSchedule(task) == deadlineSnapshot, "Cross-day resize still waits for conflicting deadline approval")
            try require(conflict.apply(to: task, shiftDeadline: true) && task.dueAt == at(34), "Confirmed cross-day resize extends deadline to new end")
            deadlineSnapshot.restore(task)
            try require(TaskSchedule(task) == deadlineSnapshot, "Undo restores cross-day range and deadline together")
        }
    }

    static func leapRepeatAndListMoves(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            var leap = date(2024, 2, 29)
            for year in 2025...2028 {
                leap = Dates.nextRepeat(leap, rule: "yearly", anchorDay: 29, after: leap)!
                try require(Dates.sameDay(leap, date(year, 2, year == 2028 ? 29 : 28)), "Annual repeat keeps the original leap-day anchor")
            }
            let task = TaskItem(title: "Reminder", scheduledAt: date(2030, 9, 22))
            task.hasTime = true; task.endAt = task.scheduledAt!.addingTimeInterval(3600)
            task.reminderKind = "custom"; task.reminderAt = task.scheduledAt!.addingTimeInterval(-3600)
            let reminder = task.reminderAt
            task.schedule(at: task.scheduledAt!.addingTimeInterval(-7200))
            try require(task.reminderAt == reminder && task.reminderNeedsAttention && task.reminderWarning != nil, "Moving earlier preserves custom reminder but warns when it is after the start")
            task.schedule(at: date(2030, 9, 22))
            try require(!task.reminderNeedsAttention && task.reminderWarning == nil, "Moving back clears the reminder warning")
            let area = CGRect(x: 0, y: 0, width: 180, height: 600)
            let header = CGRect(x: 0, y: 70, width: 180, height: 24)
            let row = UUID(), rows = [row: CGRect(x: 0, y: 100, width: 180, height: 28)]
            let top = ListTree.dropTarget(pointer: CGPoint(x: 50, y: 20), rows: rows, header: header, area: area, blocked: { _ in false })
            let bottom = ListTree.dropTarget(pointer: CGPoint(x: 50, y: 450), rows: rows, header: header, area: area, blocked: { _ in false })
            try require(top?.list == nil && top?.placement == .before && bottom?.list == nil && bottom?.placement == .after, "Sidebar top pins to front; blank bottom moves to root end")
            let band = ListTree.dropTarget(pointer: CGPoint(x: 50, y: 97), rows: rows, header: header, area: area, blocked: { _ in false })
            try require(band?.list == nil && band?.placement == .before, "The strip between the header and the first row still lands at the top")
            let a = TaskList(name: "A"), b = TaskList(name: "B"), child = TaskList(name: "Child")
            b.sortOrder = 1; child.parentID = a.id
            try ListTree.move(child, to: nil, placement: .after, lists: [a,b,child])
            try require(child.parentID == nil && child.sortOrder > b.sortOrder, "Dropping a child into blank space moves it out at the bottom")
            try ListTree.move(child, to: nil, placement: .before, lists: [a,b,child])
            try require(child.parentID == nil && child.sortOrder < a.sortOrder, "Dropping at top puts a list first")
        }
    }

    static func repeatPreviewAndHistory(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-Preview-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try Store.make(url: root.appendingPathComponent("test.store")), context = store.mainContext
            let list = TaskList(name: "Preview list"); context.insert(list)
            let base = date(2030, 1, 31)
            let task = TaskItem(title: "Monthly", scheduledAt: base, list: list)
            task.hasTime = true; task.endAt = base.addingTimeInterval(7200)
            task.repeatRule = "monthly"; task.repeatAnchorDay = 31; task.priority = 2
            task.reminderAt = base.addingTimeInterval(-3600); task.reminderKind = "oneHour"
            context.insert(task); try Store.save(context)
            let range = DateInterval(start: date(2030, 2, 1), end: date(2030, 4, 1))
            let preview = RepeatPreview(), items = preview.items([task], in: range, now: base)
            try require(items.count == 2 && Dates.sameDay(items[0].scheduledAt!, date(2030, 2, 28)) && Dates.sameDay(items[1].scheduledAt!, date(2030, 3, 31)), "Calendar preview retains monthly anchor across short months")
            try require(items.allSatisfy { $0.modelContext == nil && $0.reminderAt == nil && $0.previewSourceID == task.id && $0.calendarList?.id == list.id && $0.duration == 7200 }, "Previews have duration and list but no persisted context or notifications")
            let previewBackup = try TaskBackup.capture(context)
            try require(list.tasks?.count == 1 && previewBackup.tasks.count == 1, "Preview creation never changes list relationships or backup contents")
            try require(preview.items([task], in: range, now: base)[0] === items[0], "Unchanged calendar state reuses preview objects")
            var filter = TaskFilter(); filter.list = .list(list.id); filter.priority = 2
            try require(items.allSatisfy { filter.matches($0, lists: [list], today: base) }, "Calendar list and priority filters match previews")
            task.toggleCompletion(in: context, now: base); try Store.save(context)
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let next = all.first { $0.id == task.nextOccurrenceID }!
            let projected = preview.items(all, in: range, now: base)
            try require(projected.count == 1 && Dates.sameDay(projected[0].calendarDate!, date(2030,3,31)), "Generated next task replaces its preview without duplication")
            // A completed occurrence was dragged beyond its old successor; the old successor was made one-off.
            let movedDaily = TaskItem(title: "Moved daily", scheduledAt: date(2030, 3, 10))
            movedDaily.repeatRule = "daily"; movedDaily.isDone = true; movedDaily.repeatAnchorDay = 10
            let oldNext = TaskItem(title: "Old independent occurrence", scheduledAt: date(2030, 3, 1))
            movedDaily.nextOccurrenceID = oldNext.id
            context.insert(movedDaily); context.insert(oldNext); try Store.save(context)
            let days = DateInterval(start: date(2030, 3, 10), end: date(2030, 3, 14))
            let repeats = RepeatPreview()
            let countBeforePreview = try context.fetchCount(FetchDescriptor<TaskItem>())
            let daily = repeats.items([movedDaily, oldNext], in: days, now: date(2030, 3, 9))
            try require(daily.count == 3 && daily.allSatisfy { $0.previewSourceID == movedDaily.id }, "completed daily task with a stale successor shows every following day")
            try require(try context.fetchCount(FetchDescriptor<TaskItem>()) == countBeforePreview && movedDaily.nextOccurrenceID == oldNext.id, "repairing calendar previews never rewrites history or persists virtual tasks")
            oldNext.scheduledAt = date(2030,3,11)
            try require(repeats.items([movedDaily, oldNext], in: days, now: date(2030,3,9)).isEmpty, "a valid future successor with repeats stopped does not restart the old series")
            oldNext.scheduledAt = date(2030,3,1); oldNext.deletedAt = date(2030,3,9)
            try require(repeats.items([movedDaily, oldNext], in: days, now: date(2030,3,9)).isEmpty, "a deleted successor does not silently restart a series")
            oldNext.deletedAt = nil
            try require(repeats.items([movedDaily], in: days, now: date(2030,3,9)).isEmpty, "a permanently missing successor retains the stop marker")
            movedDaily.ensureNextOccurrence(in: context, now: date(2030,3,9)); try Store.save(context)
            let newID = movedDaily.nextOccurrenceID
            let generated = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == newID }!
            try require(newID != oldNext.id && generated.calendarDate == date(2030,3,11) && oldNext.calendarDate == date(2030,3,1) && oldNext.repeatRule == "none", "normal save repairs a stale link by creating one new successor without changing the old task")
            movedDaily.ensureNextOccurrence(in: context, now: date(2030,3,9))
            try require(movedDaily.nextOccurrenceID == newID && (try context.fetchCount(FetchDescriptor<TaskItem>())) == countBeforePreview + 1, "repair is idempotent and cannot duplicate the next task")
            let active = repeats.items([movedDaily, oldNext, generated], in: days, now: date(2030,3,9))
            try require(active.count == 2 && active.allSatisfy { $0.previewSourceID == generated.id }, "real successor replaces its preview without a duplicate")
            let completedOnly = TaskItem(title: "Completed then repeated", scheduledAt: date(2030,3,10)); completedOnly.isDone = true; completedOnly.repeatRule = "daily"
            completedOnly.repeatUntil = date(2030,3,12)
            try require(repeats.items([completedOnly], in: days, now: date(2030,3,9)).count == 2, "completed task without a successor previews through its repeat end day")
            let cells = Dates.monthCells(date(2030, 2, 15)), index = CalendarIndex.byDay(all + projected, days: cells)
            try require(cells.allSatisfy { day in Set((index[day] ?? []).map(\.id)) == Set((all + projected).filter { $0.appearsInCalendar(on: day, wholeMonth: false) }.map(\.id)) }, "Calendar index matches interval filtering on every visible day")
            let other = TaskList(name: "Other"); context.insert(other); try Store.save(context)
            let before = TaskSchedule(next), history = TaskHistory()
            next.schedule(at: next.scheduledAt!.addingTimeInterval(3600)); try Store.save(context)
            let moved = TaskSchedule(next)
            history.record(next, before: .schedule(before), after: .schedule(moved), name: "Move")
            history.undo()
            try require(TaskSchedule(next) == before && history.canRedo, "Keyboard undo restores and saves schedule")
            history.redo()
            try require(TaskSchedule(next) == moved && history.canUndo, "Keyboard redo restores changed schedule")
            next.list = other; try Store.save(context)
            history.record(next, before: .list(list.id), after: .list(other.id), name: "List")
            history.undo(); history.undo()
            try require(next.list?.id == list.id && TaskSchedule(next) == before, "Consecutive undo restores classification then time")
            history.redo(); history.redo()
            try require(next.list?.id == other.id && TaskSchedule(next) == moved, "Consecutive redo restores both actions")
            next.schedule(at: date(2031, 1, 1)); try Store.save(context)
            history.undo() // A new saved edit invalidates earlier drag history.
            history.undo()
            try require(next.scheduledAt == date(2031, 1, 1) && !history.canUndo, "Undo never overwrites a newer unrelated schedule edit")
            let coalesced = TaskHistory(), original = TaskSchedule(next)
            next.schedule(at: date(2031, 1, 2)); try Store.save(context)
            coalesced.record(next, before: .schedule(original), after: .schedule(TaskSchedule(next)), name: "Move")
            next.dueAt = date(2031, 1, 5); try Store.save(context)
            coalesced.record(next, before: .schedule(original), after: .schedule(TaskSchedule(next)), name: "Move", coalesce: true)
            let withDeadline = TaskSchedule(next)
            coalesced.undo()
            try require(TaskSchedule(next) == original && !coalesced.canUndo, "Optional deadline shift and move undo as one action")
            coalesced.redo()
            try require(TaskSchedule(next) == withDeadline, "Redo restores both the moved schedule and deadline")
            // Copy uses the same guarded undo stack as moves on Mac and iPhone.
            let sourceRecord = TaskBackup.TaskRecord(next)
            let copied = sourceRecord.duplicate(at: date(2031, 1, 7), timed: true, list: other)
            context.insert(copied); try Store.save(context)
            let copyHistory = TaskHistory(), createdCopy = TaskBackup.TaskRecord(copied)
            copyHistory.recordCopy(copied)
            let undoBegan = Date()
            copyHistory.undo()
            try require(copied.deletedAt.map { $0 >= undoBegan && $0 <= Date() } == true, "Copy deletion is dated at Undo, not when the copy was created")
            try require(copied.deletedAt != nil && copyHistory.canRedo && TaskBackup.TaskRecord(next) == sourceRecord,
                        "Undo copy removes only the new task and leaves the source intact")
            copyHistory.redo()
            try require(TaskBackup.TaskRecord(copied) == createdCopy && copyHistory.canUndo,
                        "Redo copy restores the same task ID, subtask IDs and schedule without creating another copy")
            let copySchedule = TaskSchedule(copied)
            copied.schedule(at: date(2031, 1, 8)); try Store.save(context)
            copyHistory.record(copied, before: .schedule(copySchedule), after: .schedule(TaskSchedule(copied)), name: "Move copy")
            let secondUndoBegan = Date()
            copyHistory.undo(); copyHistory.undo()
            try require(copied.deletedAt.map { $0 >= secondUndoBegan } == true, "A second copy undo records a fresh deletion time for redo and sync")
            try require(copied.deletedAt != nil && TaskSchedule(copied) == copySchedule,
                        "Undo can reverse a copy's move then its creation in order")
            copyHistory.redo(); copyHistory.redo()
            try require(copied.deletedAt == nil && copied.calendarDate == date(2031, 1, 8),
                        "Redo restores copy then its move in order")
            copied.notes = "Edited after copy"; try Store.save(context)
            copyHistory.undo()
            try require(copied.deletedAt == nil && copied.notes == "Edited after copy" && !copyHistory.canUndo,
                        "Undo copy history never removes a subsequently edited task")
            let unsavedCopy = sourceRecord.duplicate(at: date(2031, 1, 9), timed: false, list: other)
            context.insert(unsavedCopy); try Store.save(context)
            let unsavedHistory = TaskHistory(); unsavedHistory.recordCopy(unsavedCopy)
            unsavedCopy.title = "Pending edit"
            unsavedHistory.undo()
            try require(unsavedCopy.deletedAt == nil && unsavedCopy.title == "Pending edit" && !unsavedHistory.canUndo,
                        "Copy undo also preserves pending unsaved edits by checking the complete task snapshot")
            try Store.save(context)
            next.repeatUntil = next.calendarDate
            try require(preview.items([next], in: DateInterval(start: date(2031,1,1), end: date(2032,1,1)), now: base).isEmpty, "Preview respects the final repeat day")
        }
    }
}
