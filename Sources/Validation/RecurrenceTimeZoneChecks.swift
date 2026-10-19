import Foundation
import SwiftData
import SwiftUI

/// Offline fixtures only: a saved rule has one calendar even when devices use different time zones.
@MainActor enum RecurrenceTimeZoneChecks {
    private static let zones = ["Asia/Shanghai", "Australia/Sydney", "Australia/Perth", "Europe/London", "America/New_York", "America/Los_Angeles"]
    private enum InjectedFailure: Error { case beforeCommit }

    static func run() throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Recurrence time zone: " + label) }
            checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try require(rejected, label)
        }
        let callback = Store.didSave
        Store.didSave = nil
        defer { Store.didSave = callback }
        try require(Dates.recurrenceCalendar(timeZoneID: nil) == nil
                    && Dates.recurrenceCalendar(timeZoneID: "not/a-time-zone") == nil,
                    "unknown time zones are never guessed")
        for round in 0..<3 {
            try dateRules(require: require)
            try taskOperations(round: round, require: require, rejects: rejects)
            try financeOperations(require: require, rejects: rejects)
            try persistenceRetry(round: round, require: require, rejects: rejects)
            try daylightSavingGaps(require: require, rejects: rejects)
            try editorClockIntents(require: require, rejects: rejects)
            try editorOperationOrders(require: require)
            try editorReminderRecovery(require: require)
        }
        for zone in TimeZone.knownTimeZoneIdentifiers {
            try inZone(zone) {
                let cal = Calendar(identifier: .gregorian)
                for hour in 0..<24 {
                    let input = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: hour, minute: 30))!
                    let field = TimeWheel.fieldDate(for: input, calendar: cal)
                    try require(Dates.clock(of: field, calendar: cal) == hour * 3600 + 1800,
                                "neutral native clock input preserves every hour in \(zone)")
                }
            }
        }
        try editorPreservation(require: require)
        try editedDraftRecovery(require: require)
        try codingAndConflicts(require: require, rejects: rejects)
        try legacyMigrationDigests(require: require, rejects: rejects)
        print("Recurrence time-zone checks passed: \(checks)")
        return checks
    }

    // These synchronous tests run on the main actor; no task is suspended while the process zone changes.
    private static func inZone<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = saved }
        return try body()
    }
    private static func calendar(_ zone: String) -> Calendar { Dates.recurrenceCalendar(timeZoneID: zone)! }
    private static func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private static func memoryStore() throws -> ModelContainer {
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private static func dateRules(require: (Bool, String) throws -> Void) throws {
        for origin in zones {
            let cal = calendar(origin)
            let cases: [(Date, String, Int, Date)] = [
                (date(cal, 2026, 11, 1), "monthly", 1, date(cal, 2026, 12, 1)),
                (date(cal, 2026, 1, 31, 9), "monthly", 31, date(cal, 2026, 2, 28, 9)),
                (date(cal, 2028, 2, 29, 9), "yearly", 29, date(cal, 2029, 2, 28, 9)),
                (date(cal, 2026, 12, 31, 9), "daily", 31, date(cal, 2027, 1, 1, 9)),
                (date(cal, 2026, 10, 30, 9), RepeatRule.workdays.text, 30, date(cal, 2026, 11, 2, 9)),
                (date(cal, 2026, 10, 26, 9), RepeatRule(interval: 2, unit: .week, weekdays: [2, 4]).text, 26, date(cal, 2026, 10, 28, 9)),
                (date(cal, 2026, 10, 30, 9), "weekly", 30, date(cal, 2026, 11, 6, 9))
            ]
            for device in zones {
                try inZone(device) {
                    try require(Dates.calendar.timeZone.identifier == device, "fixture really changes device calendar")
                    for (base, rule, anchor, expected) in cases {
                        let next = Dates.nextRepeat(base, rule: rule, anchorDay: anchor, after: base, calendar: cal)
                        try require(next == expected, "\(origin) rule \(rule) stays fixed while viewed in \(device)")
                        try require(Dates.nextRepeat(base, rule: rule, anchorDay: anchor, after: base,
                            until: cal.startOfDay(for: expected), calendar: cal) == expected,
                            "repeat-until includes the final day in the rule's zone")
                        try require(Dates.nextRepeat(base, rule: rule, anchorDay: anchor, after: expected,
                            until: cal.startOfDay(for: expected), calendar: cal) == nil,
                            "repeat-until stops after its last day in every device zone")
                    }
                }
            }
        }
        for (zone, month, day, hours) in [("Australia/Sydney", 10, 3, 23), ("America/New_York", 3, 7, 23),
                                         ("Europe/London", 10, 24, 25), ("America/Los_Angeles", 10, 31, 25)] {
            let cal = calendar(zone), start = date(calendar(zone), 2026, month, day, 9)
            for device in zones {
                try inZone(device) {
                    let next = Dates.nextRepeat(start, rule: "daily", anchorDay: day, after: start, calendar: cal)!
                    try require(cal.component(.hour, from: next) == 9 && next.timeIntervalSince(start) == Double(hours * 3600),
                                "daily rule follows \(zone) daylight saving, not elapsed 24-hour steps")
                }
            }
        }
        let shanghai = calendar("Asia/Shanghai"), november = date(calendar("Asia/Shanghai"), 2026, 11, 1)
        try inZone("Europe/London") {
            try require(Dates.nextRepeat(november, rule: "monthly", anchorDay: 1, after: november) != date(shanghai, 2026, 12, 1),
                        "fixture reproduces the old month-first bug before testing the saved rule zone")
        }
    }

    private static func seedTask(zone: String = "Asia/Shanghai") -> TaskItem {
        let cal = calendar(zone), base = date(calendar(zone), 2030, 11, 1)
        let task = TaskItem(title: "Isolated repeating task", scheduledAt: base)
        // Keep the fixture exact through millisecond JSON dates; Date() can round below one microsecond.
        task.createdAt = date(cal, 2030, 10, 1)
        task.hasTime = true; task.endAt = base.addingTimeInterval(3600)
        task.repeatRule = "monthly"; task.repeatAnchorDay = 1; task.repeatTimeZoneID = zone
        task.dueAt = date(cal, 2030, 11, 3, 9); task.dueHasTime = true
        task.reminderKind = "custom"; task.reminderAt = date(cal, 2030, 10, 31, 9)
        task.subtasks = [Subtask(title: "One"), Subtask(title: "Two")]
        return task
    }

    private static func taskOperations(round: Int, require: (Bool, String) throws -> Void,
                                       rejects: (String, () throws -> Void) throws -> Void) throws {
        let cal = calendar("Asia/Shanghai"), source = seedTask(), record = TaskBackup.TaskRecord(seedTask())
        let baseline = TaskBackup(lists: [], tasks: [record]), base = record.scheduledAt!
        let expected = date(cal, 2030, 12, 1), nextDue = date(cal, 2030, 12, 3, 9)
        let reminder = date(cal, 2030, 11, 30, 9)
        var completed: [TaskBackup] = []
        for zone in zones {
            try inZone(zone) {
                let db = try memoryStore(), context = db.mainContext, task = record.model(list: nil)
                context.insert(task); try Store.save(context, trackSyncChanges: false)
                try require(task.nextRepeat(after: base) == expected, "task domain uses stored zone")
                let range = DateInterval(start: expected, end: date(cal, 2031, 2, 1))
                let preview = RepeatPreview().items([task], in: range, now: base)
                try require(preview.map(\.scheduledAt) == [expected, date(cal, 2031, 1, 1)],
                            "calendar projections share the stored recurrence calendar")
                task.toggleCompletion(in: context, now: base.addingTimeInterval(60))
                try Store.save(context, trackSyncChanges: false)
                let snapshot = try TaskBackup.capture(context)
                let next = snapshot.tasks.first { $0.id == task.nextOccurrenceID }!
                try require(snapshot.tasks.count == 2 && next.scheduledAt == expected && next.dueAt == nextDue
                    && next.reminderAt == reminder && next.repeatTimeZoneID == record.repeatTimeZoneID,
                    "completion preserves schedule, deadline, custom reminder and zone on every device")
                try require(next.subtasks.allSatisfy { !$0.isDone } && next.subtasks.map(\.title) == record.subtasks.map(\.title),
                            "successor retains subtask content without completion status")
                task.ensureNextOccurrence(in: context, now: base.addingTimeInterval(60))
                try require(try context.fetchCount(FetchDescriptor<TaskItem>()) == 2, "completion retry cannot create another successor")
                completed.append(snapshot)
            }
        }
        let merged = try completed.dropFirst().reduce(completed[0]) { result, cloud in
            try CloudMerge.merge(local: result, cloud: cloud, base: baseline)
        }
        try require(merged.tasks.count == 2 && merged.tasks.filter { !$0.isDone }.first?.scheduledAt == expected,
                    "six offline devices completing one occurrence merge to one successor, round \(round)")
        let ids = completed.map { Set($0.tasks.map(\.id)) }
        try require(ids.allSatisfy { $0 == ids[0] }, "devices agree on original and successor identities")
        var legacy = TaskBackup.TaskRecord(source); legacy.repeatTimeZoneID = nil
        for zone in zones {
            try inZone(zone) {
                let restored = legacy.model(list: nil)
                try require(restored.repeatTimeZoneID == nil && TaskBackup.TaskRecord(restored).repeatTimeZoneID == nil,
                            "restoring a legacy rule does not bind it to whichever device opens first")
                try require(restored.nextRepeat(after: base) == Dates.nextRepeat(restored.calendarDate!, rule: restored.repeatRule,
                    anchorDay: restored.repeatAnchorDay, after: base, until: restored.repeatUntil),
                    "unconfirmed legacy recurrence retains existing behavior")
            }
        }
        let sharedPreview = RepeatPreview(), legacyModel = legacy.model(list: nil)
        let range = DateInterval(start: base, end: date(cal, 2031, 2, 1))
        for zone in zones {
            try inZone(zone) {
                let cached = sharedPreview.items([legacyModel], in: range, now: base)
                let fresh = RepeatPreview().items([legacyModel], in: range, now: base)
                try require(cached.map(\.scheduledAt) == fresh.map(\.scheduledAt),
                            "legacy preview cache invalidates when the device time zone changes")
            }
        }
        let invalid = seedTask(); invalid.repeatTimeZoneID = "invalid-zone"
        try require(invalid.nextRepeat(after: base) == nil, "invalid task zone cannot generate a guessed successor")
        try rejects("backup validation rejects unknown task zones") {
            try TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(invalid)]).validate()
        }
    }

    private static func seedFinance() throws -> (FinanceData, MoneyRecurring, MoneyAccount) {
        var ledger = FinanceData.initial
        let account = MoneyAccount(name: "Isolated bank", opening: 1000)
        ledger.accounts = [account]
        var entry = ledger.newEntry(preferredBook: nil)
        entry.title = "Isolated rent"; entry.amount = 10; entry.accountAmount = 10; entry.baseAmount = 10
        entry.date = date(calendar("Asia/Shanghai"), 2030, 11, 1)
        entry.accountID = account.id; entry.bookID = ledger.books[0].id
        let bill = inZone("Asia/Shanghai") { MoneyRecurring(repeating: entry, rule: "monthly", until: nil, in: ledger) }
        try ledger.addRecurring(bill)
        return (ledger, bill, account)
    }

    private static func financeOperations(require: (Bool, String) throws -> Void,
                                           rejects: (String, () throws -> Void) throws -> Void) throws {
        let (ledger, bill, bank) = try seedFinance(), cal = calendar("Asia/Shanghai")
        let next = date(cal, 2030, 12, 1), baseline = TaskBackup(finance: ledger, lists: [], tasks: [])
        try require(bill.repeatTimeZoneID == "Asia/Shanghai", "new bill captures creation zone automatically")
        var posted: [TaskBackup] = [], skipped: [TaskBackup] = []
        for zone in zones {
            try inZone(zone) {
                let originalEntry = ledger.occurrenceEntry(bill, on: bill.nextDate)!
                let created = MoneyRecurring(repeating: originalEntry, rule: "monthly", until: nil, in: ledger)
                try require(created.repeatTimeZoneID == zone, "new bills capture the actual device zone without UI")
                var legacy = MoneyRecurring(repeating: originalEntry, rule: "monthly", until: nil, in: ledger, repeatTimeZoneID: nil)
                try legacy.validate(in: ledger)
                legacy.title = "Edited legacy title"
                try require(legacy.repeatTimeZoneID == nil && legacy.followingDate == Dates.nextRepeat(legacy.nextDate,
                    rule: legacy.rule, anchorDay: legacy.anchorDay, after: legacy.nextDate),
                    "explicit legacy bills remain unbound and keep their previous next-date behavior")
                var legacyLedger = ledger; legacyLedger.recurring = [legacy]
                try legacyLedger.postOccurrence(of: legacy.id, scheduled: legacy.nextDate)
                try require(legacyLedger.entries.count == 1, "legacy nil is valid and still permits confirmation")
                legacyLedger = ledger; legacyLedger.recurring = [legacy]
                try legacyLedger.skipOccurrence(of: legacy.id, scheduled: legacy.nextDate)
                try require(legacyLedger.entries.isEmpty, "legacy nil still permits skip without posting")
                try require(bill.followingDate == next, "bill next period uses creation zone")
                var local = ledger
                try local.postOccurrence(of: bill.id, scheduled: bill.nextDate)
                let once = local
                try require(local.entries.count == 1 && local.entries[0].id == bill.entryID(for: bill.nextDate)
                    && local.balance(bank.id) == 990 && local.recurringBill(bill.id)?.nextDate == next,
                    "confirmation keeps existing posting identity and advances one anchored month")
                try rejects("confirmation retry refuses the already settled period") {
                    try local.postOccurrence(of: bill.id, scheduled: bill.nextDate)
                }
                try require(local == once, "rejected duplicate confirmation leaves balance and rule unchanged")
                posted.append(TaskBackup(finance: local, lists: [], tasks: []))
                var skip = ledger
                try skip.skipOccurrence(of: bill.id, scheduled: bill.nextDate)
                try require(skip.entries.isEmpty && skip.recurringBill(bill.id)?.nextDate == next, "skip advances one anchored month without a debit")
                let skippedOnce = skip
                try rejects("skip retry refuses the already skipped period") { try skip.skipOccurrence(of: bill.id, scheduled: bill.nextDate) }
                try require(skip == skippedOnce, "rejected duplicate skip preserves the new next date")
                skipped.append(TaskBackup(finance: skip, lists: [], tasks: []))
                var ending = bill; ending.until = cal.startOfDay(for: next)
                try require(ending.followingDate == next && !ending.hasEnded, "bill until is inclusive in saved zone")
                ending.nextDate = next
                try require(ending.followingDate == nil && !ending.hasEnded, "last bill occurrence is allowed and has no successor")
                var moved = bill; moved.reschedule(to: date(cal, 2030, 12, 1))
                try require(moved.anchorDay == 1 && moved.repeatTimeZoneID == bill.repeatTimeZoneID
                    && moved.followingDate == date(cal, 2031, 1, 1), "rescheduling abroad retains the rule's zone and month anchor")
            }
        }
        let confirmed = try posted.dropFirst().reduce(posted[0]) { try CloudMerge.merge(local: $0, cloud: $1, base: baseline) }
        try require(confirmed.finance?.entries.count == 1 && confirmed.finance?.balance(bank.id) == 990
                    && confirmed.finance?.recurringBill(bill.id)?.nextDate == next,
                    "simultaneous cross-zone confirmations merge into one debit and next period")
        let ignored = try CloudMerge.merge(local: skipped[0], cloud: skipped[1], base: baseline)
        try require(ignored.finance?.entries.isEmpty == true && ignored.finance?.recurringBill(bill.id)?.nextDate == next,
                    "simultaneous skips advance only once")
        let mixed = try CloudMerge.merge(local: posted[0], cloud: skipped[1], base: baseline)
        try require(mixed.finance?.entries.count == 1 && mixed.finance?.recurringBill(bill.id)?.nextDate == next,
                    "confirm racing skip retains the recorded receipt and a single period advance")
        var changed = ledger
        var entry = changed.occurrenceEntry(bill, on: bill.nextDate)!
        entry.amount = 11; entry.accountAmount = 11; entry.baseAmount = 11
        try changed.postOccurrence(of: bill.id, scheduled: bill.nextDate, entry: entry)
        let other = TaskBackup(finance: changed, lists: [], tasks: [])
        try rejects("different simultaneous confirmation amounts still require review") {
            _ = try CloudMerge.merge(local: posted[0], cloud: other, base: baseline)
        }
        for choice in [CloudMerge.Choice.local, .cloud] {
            let chosen = try CloudMerge.merge(local: posted[0], cloud: other, base: baseline, choice: choice)
            try require(chosen.finance?.entries.count == 1 && chosen.finance?.balance(bank.id) == (choice == .local ? 990 : 989),
                        "manual confirmation choice retains exactly one posting")
        }
    }

    private static func persistenceRetry(round: Int, require: (Bool, String) throws -> Void,
                                         rejects: (String, () throws -> Void) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-RecurrenceZone-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("retry.store"), db = try Store.make(url: url), context = db.mainContext
        let task = seedTask(), taskID = task.id, base = task.calendarDate!
        let (ledger, bill, bank) = try seedFinance()
        context.insert(task); try FinanceStore.stage(ledger, in: context, trackSyncChanges: false)
        try Store.save(context, trackSyncChanges: false)
        let before = try TaskBackup.capture(context)
        try inZone("Europe/London") {
            try rejects("failure after staging task and bill is reported") {
                try Store.discardingOnFailure(context) {
                    task.toggleCompletion(in: context, now: base.addingTimeInterval(60))
                    var proposed = ledger
                    try proposed.postOccurrence(of: bill.id, scheduled: bill.nextDate)
                    try FinanceStore.stage(proposed, in: context, trackSyncChanges: false)
                    throw InjectedFailure.beforeCommit
                }
            }
        }
        // Also reject a real SQLite write, after both changes have been staged, then recover normally.
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url,
            allowsSave: false, cloudKitDatabase: .none)])
        readOnly.mainContext.autosaveEnabled = false
        try inZone("Australia/Sydney") {
            try rejects("real write failure cannot commit one side of the occurrence") {
                let rejected = try readOnly.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == taskID }!
                rejected.toggleCompletion(in: readOnly.mainContext, now: base.addingTimeInterval(60))
                var proposed = ledger
                try proposed.postOccurrence(of: bill.id, scheduled: bill.nextDate)
                try FinanceStore.stage(proposed, in: readOnly.mainContext, trackSyncChanges: false)
                try Store.save(readOnly.mainContext, trackSyncChanges: false)
            }
        }
        try require(Store.recovery.failure != nil && Store.recovery.reload(), "failed SQLite save can recover from the last committed store")
        let reopened = try Store.make(url: url), fresh = reopened.mainContext
        let after = try TaskBackup.capture(fresh)
        try require(!context.hasChanges && after.tasks == before.tasks && after.finance == before.finance,
                    "interrupted save leaves both original occurrence and balance unchanged on disk")
        try inZone("America/New_York") {
            let restored = try fresh.fetch(FetchDescriptor<TaskItem>()).first { $0.id == taskID }!
            restored.toggleCompletion(in: fresh, now: base.addingTimeInterval(60))
            var retry = try FinanceStore.read(fresh)!
            try retry.postOccurrence(of: bill.id, scheduled: bill.nextDate)
            try FinanceStore.stage(retry, in: fresh, trackSyncChanges: false)
            try Store.save(fresh, trackSyncChanges: false)
        }
        let verified = try Store.make(url: url), result = try TaskBackup.capture(verified.mainContext)
        let next = date(calendar("Asia/Shanghai"), 2030, 12, 1)
        try require(result.tasks.count == 2 && result.tasks.first { !$0.isDone }?.scheduledAt == next
                    && result.finance?.balance(bank.id) == 990 && result.finance?.entries.count == 1
                    && result.finance?.recurringBill(bill.id)?.nextDate == next,
                    "retry from a third time zone commits one successor and one receipt, round \(round)")
        try require(try TaskBackup.decode(result.encoded()).tasks == result.tasks,
                    "successful retry preserves anchored tasks through portable backup")
    }

    private static func editorPreservation(require: (Bool, String) throws -> Void) throws {
        let task = seedTask()
        task.hasTime = false; task.endAt = nil; task.dueHasTime = false
        task.repeatUntil = date(calendar("Asia/Shanghai"), 2031, 12, 1)
        let original = TaskBackup.TaskRecord(task)
        for zone in zones {
            try inZone(zone) {
                let editor = TaskEditor(request: EditorRequest(task: task))
                try require(editor.savedScheduledDate == task.scheduledAt && editor.savedDueDate == task.dueAt
                    && editor.savedRepeatUntil == task.repeatUntil && editor.effectiveReminder == task.reminderAt,
                    "opening an all-day editor abroad does not renormalize unchanged stored dates or reminder")
                var draft = editor.draftState
                try require(draft.repeatTimeZoneID == task.repeatTimeZoneID, "editor draft retains recurrence zone")
                draft = TaskEditor.DraftState(title: "Recovered edit", notes: draft.notes, pending: draft.pending,
                    repeating: draft.repeating, repeatUntil: draft.repeatUntil, end: draft.end,
                    scheduled: draft.scheduled, due: draft.due, reminder: task.reminderAt!.addingTimeInterval(300),
                    timed: draft.timed, dueTimed: draft.dueTimed, preset: .custom, listID: draft.listID,
                    priority: draft.priority, subtasks: draft.subtasks, original: original, repeatTimeZoneID: draft.repeatTimeZoneID)
                let recovered = TaskEditor(request: EditorRequest(task: task), draft: draft)
                try require(recovered.effectiveReminder == draft.reminder && recovered.draftState.repeatTimeZoneID == task.repeatTimeZoneID,
                            "recovered custom reminder edits are applied without changing recurrence zone")
                let newEditor = TaskEditor(request: EditorRequest(date: task.scheduledAt))
                try require(newEditor.draftState.repeatTimeZoneID == zone, "new task draft captures device time zone")
                let pending = TaskEditor.DraftState(title: "New unsaved repeat", notes: "", pending: "", repeating: "monthly",
                    repeatUntil: task.repeatUntil, end: nil, scheduled: task.scheduledAt,
                    due: date(calendar("Asia/Shanghai"), 2030, 11, 3), reminder: nil,
                    timed: false, dueTimed: false, preset: .none, listID: nil, priority: 0, subtasks: [],
                    repeatTimeZoneID: "Asia/Shanghai", normalizedScheduledDate: task.scheduledAt,
                    normalizedDueDate: date(calendar("Asia/Shanghai"), 2030, 11, 3))
                let reopened = TaskEditor(request: EditorRequest(), draft: pending)
                try require(reopened.savedScheduledDate == pending.scheduled && reopened.savedDueDate == pending.due
                    && reopened.savedRepeatUntil == pending.repeatUntil,
                    "recovering a new repeating all-day draft abroad preserves its original day anchors")
                let legacy = original.model(list: nil); legacy.repeatTimeZoneID = nil
                try require(TaskEditor(request: EditorRequest(task: legacy)).draftState.repeatTimeZoneID == nil,
                            "opening a legacy repeating task never confirms a time zone implicitly")
            }
        }
    }

    private static func editedDraftRecovery(require: (Bool, String) throws -> Void) throws {
        let origin = calendar("Asia/Shanghai")
        let selected = date(origin, 2030, 11, 14, 15), selectedDue = date(origin, 2030, 11, 16, 20)
        let expected = origin.startOfDay(for: selected), expectedDue = origin.startOfDay(for: selectedDue)
        for wasRepeating in [false, true] {
            let task = seedTask(); task.hasTime = false; task.endAt = nil; task.dueHasTime = false
            if !wasRepeating { task.repeatRule = "none"; task.repeatTimeZoneID = nil }
            let opening = TaskBackup.TaskRecord(task)
            // Build the saved draft through the real editor, as a date picker edit does before a failed save.
            let kept = inZone("Asia/Shanghai") {
                let changed = TaskEditor.DraftState(title: "Edited dates before failure", notes: opening.notes, pending: "",
                    repeating: "monthly", repeatUntil: nil, end: nil, scheduled: selected, due: selectedDue,
                    reminder: nil, timed: false, dueTimed: false, preset: .none, listID: nil,
                    priority: 0, subtasks: opening.subtasks, original: opening, repeatTimeZoneID: "Asia/Shanghai")
                return TaskEditor(request: EditorRequest(task: task), draft: changed).draftState
            }
            try require(kept.normalizedScheduledDate == expected && kept.normalizedDueDate == expectedDue,
                        "editing an existing task captures the intended all-day dates before recovery")
            for zone in zones {
                try inZone(zone) {
                    let restored = TaskEditor(request: EditorRequest(task: task), draft: kept)
                    try require(restored.savedScheduledDate == expected && restored.savedDueDate == expectedDue
                        && restored.draftState.repeatTimeZoneID == "Asia/Shanghai",
                        "recovering edited dates preserves their source meaning for both new and existing repeat rules")
                    let again = TaskEditor(request: EditorRequest(task: task), draft: restored.draftState)
                    try require(again.savedScheduledDate == expected && again.savedDueDate == expectedDue,
                                "repeated recovery never renormalizes a preserved all-day draft")
                    let anchor = TaskEditor.AllDayDraftDate(input: selected, normalized: expected, timed: false)!
                    try require(anchor.value(for: selected, timed: false) == expected
                        && anchor.value(for: selected.addingTimeInterval(86400), timed: false) == nil
                        && anchor.value(for: selected, timed: true) == nil,
                        "an explicit date or timed-mode edit invalidates the restored date anchor")
                    try require(TaskEditor.AllDayDraftDate(input: selected, normalized: expected, timed: true) == nil
                        && TaskEditor.AllDayDraftDate(input: selected, normalized: nil, timed: false) == nil,
                        "timed and older drafts without a normalized date never acquire a restored all-day anchor")
                    // After invalidation the editor records a new local day, including returning to the old picker input.
                    let localEdit = TaskEditor.DraftState(title: kept.title, notes: kept.notes, pending: kept.pending,
                        repeating: kept.repeating, repeatUntil: kept.repeatUntil, end: nil,
                        scheduled: selected, due: selectedDue, reminder: nil, timed: false, dueTimed: false,
                        preset: .none, listID: nil, priority: 0, subtasks: kept.subtasks, original: opening,
                        repeatTimeZoneID: kept.repeatTimeZoneID)
                    let reselected = TaskEditor(request: EditorRequest(task: task), draft: localEdit)
                    try require(reselected.savedScheduledDate == Dates.calendar.startOfDay(for: selected)
                        && reselected.savedDueDate == Dates.calendar.startOfDay(for: selectedDue),
                        "selecting a day again uses the device's current local day instead of the old restored value")
                    let timed = TaskEditor.DraftState(title: kept.title, notes: kept.notes, pending: kept.pending,
                        repeating: kept.repeating, repeatUntil: kept.repeatUntil, end: nil,
                        scheduled: selected, due: selectedDue, reminder: nil, timed: true, dueTimed: true,
                        preset: .none, listID: nil, priority: 0, subtasks: kept.subtasks, original: opening,
                        repeatTimeZoneID: kept.repeatTimeZoneID,
                        normalizedScheduledDate: expected, normalizedDueDate: expectedDue)
                    let explicitTimes = TaskEditor(request: EditorRequest(task: task), draft: timed)
                    try require(explicitTimes.savedScheduledDate == selected && explicitTimes.savedDueDate == selectedDue,
                                "switching to explicit time preserves exact moments and discards old all-day normalization")
                }
            }
        }
    }

    /// Uses the editor's retained draft and the same clock application invoked by commit, not a second save formula.
    private static func editorClockIntents(require: (Bool, String) throws -> Void,
                                            rejects: (String, () throws -> Void) throws -> Void) throws {
        let fixtures = [("America/New_York", 3, 8, 30), ("Australia/Sydney", 10, 4, 30),
                        ("Australia/Lord_Howe", 10, 4, 15)]
        for (zone, month, day, minute) in fixtures {
            let cal = calendar(zone)
            func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
                cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
            }
            let originalTime = at(day - 1, 2, minute), intended = 7200 + minute * 60
            let gap = Dates.placing(clock: intended, onDayOf: at(day, 12, 0), calendar: cal)!
            let shifted = Dates.clock(of: gap, calendar: cal)
            func task(dueOnly: Bool = false, legacy: Bool = false) -> TaskItem {
                let task = TaskItem(title: "Editor clock fixture", scheduledAt: dueOnly ? nil : originalTime)
                task.hasTime = !dueOnly; task.dueAt = dueOnly ? originalTime : at(day + 1, 12, 0); task.dueHasTime = true
                task.repeatRule = "daily"; task.repeatTimeZoneID = legacy ? nil : zone; task.repeatAnchorDay = day - 1
                if !legacy { task.refreshRepeatClock() }
                return task
            }
            func edited(_ source: TaskItem, start: Date?, due: Date?, startIntent: TaskEditor.ClockIntent?,
                        dueIntent: TaskEditor.ClockIntent?, timed: Bool = true, repeating: String = "daily") -> TaskEditor.DraftState {
                TaskEditor.DraftState(title: source.title, notes: "", pending: "", repeating: repeating,
                    repeatUntil: nil, end: nil, scheduled: start, due: due, reminder: nil,
                    timed: timed, dueTimed: true, preset: .none, listID: nil, priority: 0, subtasks: [],
                    original: TaskBackup.TaskRecord(source), repeatTimeZoneID: source.repeatTimeZoneID,
                    startClockIntent: startIntent, dueClockIntent: dueIntent)
            }
            func apply(_ draft: TaskEditor.DraftState, to target: TaskItem) {
                target.scheduledAt = draft.scheduled; target.hasTime = draft.timed
                target.dueAt = draft.due; target.dueHasTime = draft.dueTimed; target.repeatRule = draft.repeating
                draft.applyRepeatClock(to: target)
            }
            try inZone(zone) {
                let original = task(), opening = TaskEditor(request: EditorRequest(task: original)).draftState
                // A: choosing the shifted time deliberately must survive repeated model/editor reconstruction abroad.
                let explicitTime = at(day - 1, shifted / 3600, (shifted % 3600) / 60)
                let choice = TaskEditor.ClockIntent(explicitTime)
                var draft = edited(original, start: gap, due: original.dueAt, startIntent: choice, dueIntent: opening.dueClockIntent)
                for device in zones {
                    try inZone(device) {
                        for _ in 0..<2 {
                            let recovered = TaskEditor(request: EditorRequest(task: original), draft: draft)
                            draft = recovered.draftState
                            let saved = TaskBackup.TaskRecord(original).model(list: nil)
                            apply(draft, to: saved)
                            try require(draft.startClockIntent == choice && saved.repeatClock == shifted
                                && Dates.clock(of: saved.nextRepeat(after: gap)!, calendar: cal) == shifted,
                                "explicit start choice survives recovery in \(device), rule \(zone)")
                        }
                    }
                }
                // B: a deadline edit cannot replace the start's intended time; this includes a nil-clock old rule.
                for missingClock in [false, true] {
                    let source = task(); if missingClock { source.repeatClock = nil }
                    let initial = TaskEditor(request: EditorRequest(task: source)).draftState
                    let changed = edited(source, start: gap, due: at(day + 1, 13, 0), startIntent: initial.startClockIntent,
                                         dueIntent: TaskEditor.ClockIntent(at(day + 1, 13, 0)))
                    let saved = TaskBackup.TaskRecord(source).model(list: nil); apply(changed, to: saved)
                    try require(saved.repeatClock == intended && Dates.clock(of: saved.nextRepeat(after: gap)!, calendar: cal) == intended,
                                "date-only start plus changed deadline preserves original time, missing clock \(missingClock)")
                }
                // C: a chosen 02:xx followed by the gap date retains the choice, including new tasks.
                let earlier = task(); earlier.scheduledAt = at(day - 1, 1, minute); earlier.refreshRepeatClock()
                for isNew in [false, true] {
                    var changed = edited(earlier, start: gap, due: nil, startIntent: TaskEditor.ClockIntent(originalTime), dueIntent: nil)
                    if isNew { changed.original = nil }
                    let saved = TaskBackup.TaskRecord(earlier).model(list: nil); apply(changed, to: saved)
                    try require(saved.repeatClock == intended && Dates.clock(of: saved.nextRepeat(after: gap)!, calendar: cal) == intended,
                                "time then day preserves raw choice for new/existing tasks")
                }
                // Selecting the missing time directly on the gap day goes through the real wheel callback.
                var picked = at(day, 1, minute), selectedIntent: TaskEditor.ClockIntent?
                let wheel = TimeWheel(date: Binding(get: { picked }, set: { picked = $0 }),
                    clock: Binding(get: { selectedIntent?.clock(in: cal, on: picked) ?? Dates.clock(of: picked, calendar: cal) },
                                   set: { selectedIntent = TaskEditor.ClockIntent(picked, requestedClock: $0) }))
                wheel.set(hour: 2, minute: minute)
                try require(picked == gap && selectedIntent?.requestedClock == intended, "wheel exposes the raw time before normalization")
                var direct = edited(original, start: picked, due: nil, startIntent: selectedIntent, dueIntent: nil)
                let directSave = task(); apply(direct, to: directSave)
                try require(directSave.repeatClock == intended, "day then missing time preserves the same intended clock")
                wheel.set(fieldDate: TimeWheel.fieldDate(for: originalTime, calendar: cal))
                try require(picked == gap && selectedIntent?.requestedClock == intended
                    && Dates.clock(of: TimeWheel.fieldDate(for: gap, calendar: cal), calendar: Calendar(identifier: .gregorian)) == shifted,
                    "native time field preserves raw missing time and displays the normalized clock")
                // A valid explicit choice may resolve to the same Date; it still replaces the earlier missing clock.
                wheel.set(hour: shifted / 3600, minute: (shifted % 3600) / 60)
                direct.startClockIntent = selectedIntent; apply(direct, to: directSave)
                try require(directSave.repeatClock == shifted, "choosing valid shifted time at identical instant is an explicit change")
                direct.startClockIntent = TaskEditor.ClockIntent(originalTime); apply(direct, to: directSave)
                try require(directSave.repeatClock == intended, "reverting an explicit clock edit restores its intended value")
                // Deadline-only tasks use the deadline's independent intent; removal of a start changes the source.
                let dueOnly = task(dueOnly: true), dueOpening = TaskEditor(request: EditorRequest(task: dueOnly)).draftState
                for explicit in [false, true] {
                    let changed = edited(dueOnly, start: nil, due: gap, startIntent: TaskEditor.ClockIntent(at(day, 15, 0)),
                                         dueIntent: explicit ? TaskEditor.ClockIntent(explicitTime) : dueOpening.dueClockIntent)
                    let saved = task(dueOnly: true); apply(changed, to: saved)
                    try require(saved.repeatClock == (explicit ? shifted : intended), "deadline-only task uses only its own clock intent")
                }
                let removedStart = edited(original, start: nil, due: original.dueAt, startIntent: opening.startClockIntent,
                                          dueIntent: opening.dueClockIntent)
                let switched = task(); apply(removedStart, to: switched)
                try require(switched.repeatClock == 43200, "removing start adopts existing deadline time instead of prior start")
                let legacy = task(legacy: true), legacyOpening = TaskEditor(request: EditorRequest(task: legacy)).draftState
                let legacyDraft = edited(legacy, start: gap, due: nil, startIntent: legacyOpening.startClockIntent, dueIntent: nil)
                apply(legacyDraft, to: legacy)
                try require(legacy.repeatTimeZoneID == nil && legacy.repeatClock == nil, "rules without a timezone are not migrated")
                for (timed, rule) in [(false, "daily"), (true, "none")] {
                    let changed = edited(original, start: gap, due: nil, startIntent: choice, dueIntent: nil, timed: timed, repeating: rule)
                    let saved = task(); apply(changed, to: saved)
                    try require(saved.repeatClock == nil && saved.repeatReminderOffset == nil, "all-day or disabled repeats discard unused clock metadata")
                }
                // An unchanged gap occurrence retains both its intended time and custom reminder distance.
                let alreadyShifted = task(); alreadyShifted.scheduledAt = gap; alreadyShifted.repeatClock = intended
                alreadyShifted.reminderKind = ReminderPreset.custom.rawValue
                alreadyShifted.reminderAt = gap.addingTimeInterval(-900); alreadyShifted.repeatReminderOffset = -900
                let unchanged = TaskEditor(request: EditorRequest(task: alreadyShifted)).draftState
                unchanged.applyRepeatClock(to: alreadyShifted)
                try require(alreadyShifted.repeatClock == intended && alreadyShifted.repeatReminderOffset == -900,
                            "unchanged gap occurrence retains intended time and reminder offset")
                alreadyShifted.reminderAt = gap.addingTimeInterval(-1800)
                unchanged.applyRepeatClock(to: alreadyShifted)
                // On Lord Howe, going back 30 elapsed minutes crosses the skipped half-hour: 02:45 -> 01:45.
                let reminderOffset = zone == "Australia/Lord_Howe" ? -3600 : -1800
                try require(alreadyShifted.repeatClock == intended && alreadyShifted.repeatReminderOffset == reminderOffset,
                            "reminder-only change updates its offset without changing time intent")
                // Real SQLite save rejection, draft reconstruction, retry and re-open.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-EditorClock-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("retry.store"), db = try Store.make(url: url)
                let stored = task(); db.mainContext.insert(stored); try Store.save(db.mainContext, trackSyncChanges: false)
                let baseline = TaskBackup.TaskRecord(stored)
                let pending = edited(stored, start: gap, due: stored.dueAt, startIntent: choice, dueIntent: opening.dueClockIntent)
                let drafts = EditorDrafts(); drafts.taskID = stored.id; drafts.task = pending
                let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
                let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url,
                    allowsSave: false, cloudKitDatabase: .none)])
                readOnly.mainContext.autosaveEnabled = false
                let rejected = try readOnly.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
                apply(pending, to: rejected)
                try rejects("clock edit write rejection is surfaced") { try Store.save(readOnly.mainContext, trackSyncChanges: false) }
                try require(drafts.task == pending && Store.recovery.reload(), "rejected clock edit retains its full draft through reload")
                let fresh = Store.recovery.container!.mainContext
                let committed = try fresh.fetch(FetchDescriptor<TaskItem>()).first!
                try require(TaskBackup.TaskRecord(committed) == baseline, "failed save leaves original date and clock on disk")
                let recovered = TaskEditor(request: EditorRequest(task: committed), draft: drafts.task).draftState
                apply(recovered, to: committed); try Store.save(fresh, trackSyncChanges: false)
                let reopened = try Store.make(url: url)
                let rows = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
                try require(rows.count == 1 && rows[0].scheduledAt == gap && rows[0].repeatClock == shifted,
                            "retry stores the intended explicit time once and survives reopening")
            }
        }
    }

    /// Every path uses the retained draft clock and the production picker, including sequential component edits.
    private static func editorOperationOrders(require: (Bool, String) throws -> Void) throws {
        let gaps = [("America/New_York", 3, 8, 2, 30), ("Australia/Sydney", 10, 4, 2, 30),
                    ("Australia/Lord_Howe", 10, 4, 2, 15), ("Europe/London", 3, 29, 1, 30)]
        for (zone, month, gapDay, hour, minute) in gaps {
            try inZone(zone) {
                let cal = calendar(zone), intended = hour * 3600 + minute * 60
                @MainActor func at(_ day: Int, _ clock: Int) -> Date {
                    Dates.placing(clock: clock, onDayOf: date(cal, 2026, month, day, 12), calendar: cal)!
                }
                for dueOnly in [false, true] {
                    let task = TaskItem(title: "Order regression", scheduledAt: dueOnly ? nil : at(gapDay - 1, intended))
                    task.hasTime = !dueOnly; task.dueAt = dueOnly ? at(gapDay - 1, intended) : nil; task.dueHasTime = dueOnly
                    task.repeatRule = "daily"; task.repeatTimeZoneID = zone; task.refreshRepeatClock()
                    let opening = TaskEditor(request: EditorRequest(task: task)).draftState
                    var intent = (dueOnly ? opening.dueClockIntent : opening.startClockIntent)!
                    var selected = task.clockDate!
                    @MainActor func draft(_ value: Date, _ clock: TaskEditor.ClockIntent, rule: String = "daily") -> TaskEditor.DraftState {
                        TaskEditor.DraftState(title: task.title, notes: "", pending: "", repeating: rule,
                            repeatUntil: nil, end: nil, scheduled: dueOnly ? nil : value, due: dueOnly ? value : nil,
                            reminder: nil, timed: !dueOnly, dueTimed: dueOnly, preset: .none, listID: nil, priority: 0, subtasks: [],
                            original: opening.original, repeatTimeZoneID: zone,
                            startClockIntent: dueOnly ? nil : clock, dueClockIntent: dueOnly ? clock : nil)
                    }
                    @MainActor func saved(_ draft: TaskEditor.DraftState) -> TaskItem {
                        let copy = TaskBackup.TaskRecord(task).model(list: nil)
                        copy.scheduledAt = draft.scheduled; copy.dueAt = draft.due; copy.repeatRule = draft.repeating
                        draft.applyRepeatClock(to: copy)
                        return copy
                    }
                    // Forward, backward and round-trip edits never carry a temporary shifted clock to the next date.
                    for day in [gapDay, gapDay + 1, gapDay, gapDay - 1, gapDay + 1] {
                        selected = intent.moving(toDay: at(day, 43200), from: selected)
                        try require(selected == at(day, intended), "continuous date moves keep intended time: \(zone), due \(dueOnly)")
                        let restored = TaskEditor(request: EditorRequest(task: task), draft: draft(selected, intent)).draftState
                        intent = (dueOnly ? restored.dueClockIntent : restored.startClockIntent)!
                        let copy = saved(restored)
                        try require(copy.clockDate == selected && copy.repeatClock == intended
                            && copy.nextRepeat(after: selected) == at(day + 1, intended),
                            "recovery between each date move preserves current and next occurrences")
                    }
                    // Hour-first, minute-first and the Mac field agree, even when setters fire before View redraw.
                    var results: [(Date, Int)] = []
                    for order in 0..<3 {
                        var value = at(gapDay, (hour - 1) * 3600 + 30 * 60)
                        var input = TaskEditor.ClockIntent(value)
                        let wheel = TimeWheel(date: Binding(get: { value }, set: { value = $0 }),
                            clock: Binding(get: { input.clock(in: cal, on: value) },
                                           set: { input = TaskEditor.ClockIntent(value, requestedClock: $0) }))
                        if order == 0 { wheel.set(hour: hour); wheel.set(minute: 15) }
                        else if order == 1 { wheel.set(minute: 15); wheel.set(hour: hour) }
                        else {
                            wheel.set(fieldDate: TimeWheel.fieldDate(for: value, clock: hour * 3600 + 30 * 60))
                            wheel.set(fieldDate: TimeWheel.fieldDate(for: value, clock: input.requestedClock / 3600 * 3600 + 900))
                        }
                        let clock = hour * 3600 + 900
                        let restored = TaskEditor(request: EditorRequest(task: task), draft: draft(value, input)).draftState
                        let copy = saved(restored)
                        try require(value == at(gapDay, clock) && copy.repeatClock == clock,
                                    "hour/minute/native input order retains raw intent: \(zone), order \(order)")
                        let field = TimeWheel.fieldDate(for: value, clock: input.clock(in: cal, on: value))
                        try require(Dates.clock(of: field, calendar: Calendar(identifier: .gregorian)) == clock,
                                    "time field shows raw selected components instead of the normalized gap time")
                        results.append((value, copy.repeatClock!))
                        var recoveredInput = (dueOnly ? restored.dueClockIntent : restored.startClockIntent)!
                        value = recoveredInput.moving(toDay: at(gapDay + 1, 43200), from: value)
                        try require(value == at(gapDay + 1, clock), "continued date editing after recovery returns to raw time")
                        wheel.set(hour: 24); wheel.set(minute: -1)
                        try require(value == at(gapDay + 1, clock), "invalid component input leaves the selection intact")
                    }
                    try require(results.allSatisfy { $0 == results[0] }, "all component orders save the same instant and recurrence clock")
                    // Frequency changes are independent of the schedule's clock, including already shifted occurrences.
                    let shifted = saved(draft(at(gapDay, intended), intent))
                    shifted.repeatClock = intended
                    let shiftedOpening = TaskEditor(request: EditorRequest(task: shifted)).draftState
                    let shiftedIntent = (dueOnly ? shiftedOpening.dueClockIntent : shiftedOpening.startClockIntent)!
                    try require(shiftedIntent.requestedClock == intended, "opening an existing shifted occurrence restores its known input time")
                    for rule in ["daily", "weekly", "monthly", "yearly", RepeatRule(interval: 2, unit: .week, weekdays: [2, 4]).text] {
                        var change = draft(shifted.clockDate!, shiftedIntent, rule: rule)
                        change.original = TaskBackup.TaskRecord(shifted)
                        let copy = saved(change)
                        try require(copy.clockDate == shifted.clockDate && copy.repeatClock == intended,
                                    "frequency-only edit preserves known intended time: \(zone), \(rule)")
                    }
                    // Legacy nil-clock records preserve their original clock, without inventing a past intended time.
                    shifted.repeatClock = nil
                    let legacyOpening = TaskEditor(request: EditorRequest(task: shifted)).draftState
                    let legacyIntent = (dueOnly ? legacyOpening.dueClockIntent : legacyOpening.startClockIntent)!
                    var legacyChange = draft(shifted.clockDate!, legacyIntent, rule: "weekly")
                    legacyChange.original = TaskBackup.TaskRecord(shifted)
                    try require(saved(legacyChange).repeatClock == Dates.clock(of: shifted.clockDate!, calendar: cal),
                                "missing historical intent is not guessed when frequency changes")
                }
            }
        }
        // After a foreign-zone date edit, conversion must use the final day and its offsets in both zones.
        let foreign = [("America/New_York", "Asia/Shanghai", 3, 7, 9),
                       ("America/New_York", "Australia/Sydney", 3, 7, 9),
                       ("Australia/Sydney", "Asia/Shanghai", 10, 3, 5),
                       ("Europe/London", "Australia/Perth", 3, 28, 30)]
        for (ruleZone, device, month, first, last) in foreign {
            try inZone(device) {
                let cal = calendar(device), ruleCal = calendar(ruleZone)
                @MainActor func at(_ day: Int, _ hour: Int) -> Date { date(cal, 2026, month, day, hour) }
                for dueOnly in [false, true] {
                    var clocks: [Int] = [], instants: [Date] = []
                    for order in 0..<2 {
                        var selected = at(first, 10), intent = TaskEditor.ClockIntent(selected, explicit: false)
                        if order == 0 { selected = at(first, 18); intent = TaskEditor.ClockIntent(selected) }
                        selected = intent.moving(toDay: at(last, 12), from: selected)
                        if order == 1 { selected = at(last, 18); intent = TaskEditor.ClockIntent(selected) }
                        let source = TaskItem(title: "Foreign clock", scheduledAt: dueOnly ? nil : at(first, 10))
                        source.hasTime = !dueOnly; source.dueAt = dueOnly ? at(first, 10) : nil; source.dueHasTime = dueOnly
                        source.repeatRule = "daily"; source.repeatTimeZoneID = ruleZone; source.refreshRepeatClock()
                        let pending = TaskEditor.DraftState(title: source.title, notes: "", pending: "", repeating: "daily",
                            repeatUntil: nil, end: nil, scheduled: dueOnly ? nil : selected, due: dueOnly ? selected : nil,
                            reminder: nil, timed: !dueOnly, dueTimed: dueOnly, preset: .none, listID: nil, priority: 0, subtasks: [],
                            original: TaskBackup.TaskRecord(source), repeatTimeZoneID: ruleZone,
                            startClockIntent: dueOnly ? nil : intent, dueClockIntent: dueOnly ? intent : nil)
                        // Recover in the rule's zone before applying; merely opening abroad cannot reinterpret the draft.
                        let recovered = inZone(ruleZone) { TaskEditor(request: EditorRequest(task: source), draft: pending).draftState }
                        source.scheduledAt = recovered.scheduled; source.dueAt = recovered.due
                        recovered.applyRepeatClock(to: source)
                        try require(source.clockDate == at(last, 18) && source.repeatClock == Dates.clock(of: selected, calendar: ruleCal),
                                    "foreign-zone conversion uses final date after recovery: \(ruleZone), \(device)")
                        clocks.append(source.repeatClock!); instants.append(source.clockDate!)
                    }
                    try require(clocks[0] == clocks[1] && instants[0] == instants[1], "foreign date-first and time-first paths agree")
                }
            }
        }
        for (canonical, alias, month, day, clock) in [("America/New_York", "US/Eastern", 3, 8, 9000),
                                                     ("Australia/Sydney", "Australia/NSW", 10, 4, 9000),
                                                     ("Europe/London", "GB", 3, 29, 5400)] {
            let cal = calendar(canonical), aliasCal = calendar(alias)
            let gap = Dates.placing(clock: clock, onDayOf: date(cal, 2026, month, day, 12), calendar: cal)!
            let intent = TaskEditor.ClockIntent(gap, requestedClock: clock, calendar: cal)
            try require(intent.clock(in: aliasCal, on: gap) == clock, "timezone aliases retain the same raw clock")
        }
        try require(!TaskEditor.ClockIntent.sameTimeZone("America/Lima", calendar("America/New_York").timeZone),
                    "zones that only share a winter offset are not treated as aliases")
        // A recovered gap draft must not lose its raw clock just because the already-selected date is tapped abroad.
        let nyGap = calendar("America/New_York"), shanghai = calendar("Asia/Shanghai")
        let gapDate = Dates.placing(clock: 9000, onDayOf: date(nyGap, 2026, 3, 8, 12), calendar: nyGap)!
        let gapInput = TaskEditor.ClockIntent(gapDate, requestedClock: 9000, calendar: nyGap)
        var recoveredInput = gapInput
        let unchangedDate = recoveredInput.moving(toDay: shanghai.startOfDay(for: gapDate), from: gapDate, calendar: shanghai)
        try require(unchangedDate == gapDate && recoveredInput == gapInput
                    && recoveredInput.clock(in: nyGap, on: unchangedDate) == 9000,
                    "same-day selection abroad preserves the entire recovered gap intent")
        let movedDate = recoveredInput.moving(toDay: date(shanghai, 2026, 3, 9, 12), from: gapDate, calendar: shanghai)
        try require(Dates.clock(of: movedDate, calendar: shanghai) == Dates.clock(of: gapDate, calendar: shanghai)
                    && recoveredInput.clock(in: nyGap, on: movedDate) == Dates.clock(of: movedDate, calendar: nyGap),
                    "an actual foreign date move rebases the input to the newly chosen day")
        // Preserve the later repeated autumn hour on a no-op date selection, but use the chosen day for real moves.
        let ny = calendar("America/New_York")
        let first = Dates.placing(clock: 5400, onDayOf: date(ny, 2026, 11, 1, 12), calendar: ny)!
        let second = first.addingTimeInterval(3600)
        var intent = TaskEditor.ClockIntent(second, explicit: false, calendar: ny)
        try require(intent.moving(toDay: date(ny, 2026, 11, 1, 12), from: second, calendar: ny) == second,
                    "selecting the same autumn day preserves the later occurrence")
        try require(intent.moving(toDay: date(ny, 2026, 11, 2, 12), from: second, calendar: ny)
                    == Dates.placing(clock: 5400, onDayOf: date(ny, 2026, 11, 2, 12), calendar: ny),
                    "moving out of the autumn fold restores the intended clock")
    }

    /// The same final inputs must retain the same reminders, including recovery in either timezone direction.
    private static func editorReminderRecovery(require: (Bool, String) throws -> Void) throws {
        @MainActor func seed(_ when: Date, zone: String, dueOnly: Bool) -> TaskItem {
            let task = TaskItem(title: "Reminder recovery", scheduledAt: dueOnly ? nil : when)
            task.hasTime = !dueOnly; task.dueAt = dueOnly ? when : nil; task.dueHasTime = dueOnly
            task.repeatRule = "daily"; task.repeatTimeZoneID = zone
            task.reminderKind = "custom"; task.reminderAt = when.addingTimeInterval(-900)
            task.refreshRepeatClock()
            return task
        }
        @MainActor func draft(_ source: TaskItem, date: Date, intent: TaskEditor.ClockIntent) -> TaskEditor.DraftState {
            let dueOnly = source.scheduledAt == nil
            return TaskEditor.DraftState(title: source.title, notes: "", pending: "", repeating: source.repeatRule,
                repeatUntil: nil, end: nil, scheduled: dueOnly ? nil : date, due: dueOnly ? date : nil,
                reminder: source.reminderAt, timed: !dueOnly, dueTimed: dueOnly, preset: .custom, listID: nil,
                priority: 0, subtasks: [], original: TaskBackup.TaskRecord(source), repeatTimeZoneID: source.repeatTimeZoneID,
                startClockIntent: dueOnly ? nil : intent, dueClockIntent: dueOnly ? intent : nil)
        }
        @MainActor func apply(_ pending: TaskEditor.DraftState, source: TaskItem) -> TaskItem {
            let task = TaskBackup.TaskRecord(source).model(list: nil)
            task.scheduledAt = pending.scheduled; task.hasTime = pending.timed
            task.dueAt = pending.due; task.dueHasTime = pending.dueTimed
            task.reminderAt = pending.reminder; task.reminderKind = pending.preset.rawValue
            task.repeatRule = pending.repeating; task.repeatTimeZoneID = pending.repeatTimeZoneID
            pending.applyRepeatClock(to: task)
            return task
        }
        @MainActor func roundTripClock(_ when: Date, intent: TaskEditor.ClockIntent) -> TaskEditor.ClockIntent {
            var selected = when, input = intent
            let wheel = TimeWheel(date: Binding(get: { selected }, set: { selected = $0; input = TaskEditor.ClockIntent($0) }),
                clock: Binding(get: { input.clock(in: Dates.calendar, on: selected) },
                               set: { input = TaskEditor.ClockIntent(selected, requestedClock: $0) }))
            let hour = input.clock(in: Dates.calendar, on: selected) / 3600
            wheel.set(hour: (hour + 1) % 24); wheel.set(hour: hour)
            return input
        }
        @MainActor func reload(_ task: TaskItem) throws -> TaskItem {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-ReminderRecovery-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("synthetic.store"), store = try Store.make(url: url)
            store.mainContext.insert(TaskBackup.TaskRecord(task).model(list: nil))
            try Store.save(store.mainContext, trackSyncChanges: false)
            let reopened = try Store.make(url: url), tasks = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(tasks.count == 1, "reminder edits persist exactly one task")
            return TaskBackup.TaskRecord(tasks[0]).model(list: nil)
        }
        for zone in ["Asia/Shanghai", "America/New_York", "Australia/Sydney", "Australia/Lord_Howe"] {
            try inZone(zone) {
                let cal = calendar(zone)
                for dueOnly in [false, true] {
                    let source = seed(date(cal, 2030, 11, 12, 9), zone: zone, dueOnly: dueOnly)
                    let opening = TaskEditor(request: EditorRequest(task: source)).draftState
                    var intent = (dueOnly ? opening.dueClockIntent : opening.startClockIntent)!
                    let selected = intent.moving(toDay: date(cal, 2030, 11, 13, 12), from: source.clockDate!)
                    let dateOnly = apply(draft(source, date: selected, intent: intent), source: source)
                    let changedBack = apply(draft(source, date: selected, intent: roundTripClock(selected, intent: intent)), source: source)
                    let next = dateOnly.nextRepeat(after: selected)!, reminder = date(cal, 2030, 11, 13, 9).addingTimeInterval(-900)
                    try require(dateOnly.repeatReminderOffset == -87300 && changedBack.repeatReminderOffset == -87300,
                                "date-only and clock round-trip edits retain the same custom reminder distance: \(zone), due \(dueOnly)")
                    try require(dateOnly.reminderDate(forOccurrenceAt: next) == reminder
                                && changedBack.reminderDate(forOccurrenceAt: next) == reminder,
                                "same final dates and reminder produce the same next reminder")
                    let pending = draft(source, date: selected, intent: intent)
                    let recovered = inZone("Europe/London") { TaskEditor(request: EditorRequest(task: source), draft: pending).draftState }
                    let saved = try reload(apply(recovered, source: source))
                    try require(saved.clockDate == selected && saved.repeatReminderOffset == -87300
                                && saved.reminderDate(forOccurrenceAt: next) == reminder,
                                "reminder meaning survives foreign draft recovery, save and reopen")
                    let later = date(cal, 2030, 11, 13, 10)
                    let clockChanged = apply(draft(source, date: later, intent: TaskEditor.ClockIntent(later)), source: source)
                    try require(clockChanged.repeatReminderOffset == -90900
                                && clockChanged.reminderDate(forOccurrenceAt: clockChanged.nextRepeat(after: later)!) == reminder,
                                "an actual clock change retains an unchanged custom reminder's local meaning")
                    let tooFar = date(cal, 2033, 11, 13, 9)
                    let far = apply(draft(source, date: tooFar, intent: TaskEditor.ClockIntent(tooFar)), source: source)
                    try require(far.repeatReminderOffset == nil, "a reminder more than a year away never stores an invalid offset")
                    let older = TaskBackup.TaskRecord(source).model(list: nil); older.repeatReminderOffset = nil
                    let old = apply(draft(older, date: selected, intent: intent), source: older)
                    try require(old.repeatReminderOffset == old.currentReminderOffset(), "missing historical reminder intent retains the existing fallback")
                }
            }
        }
        for (zone, month, day, clock) in [("America/New_York", 3, 8, 9000),
                                         ("Australia/Sydney", 10, 4, 9000), ("Australia/Lord_Howe", 10, 4, 8100)] {
            let cal = calendar(zone)
            try inZone(zone) {
                for dueOnly in [false, true] {
                    let before = Dates.placing(clock: clock, onDayOf: date(cal, 2026, month, day - 1, 12), calendar: cal)!
                    let source = seed(before, zone: zone, dueOnly: dueOnly)
                    source.reminderAt = Dates.placing(clock: 6300, onDayOf: before, calendar: cal); source.refreshRepeatClock()
                    let gap = Dates.placing(clock: clock, onDayOf: date(cal, 2026, month, day, 12), calendar: cal)!
                    let shifted = source.occurrence(at: gap), opening = TaskEditor(request: EditorRequest(task: shifted)).draftState
                    let intent = (dueOnly ? opening.dueClockIntent : opening.startClockIntent)!
                    let unchanged = apply(opening, source: shifted)
                    let changedBack = apply(draft(shifted, date: gap, intent: roundTripClock(gap, intent: intent)), source: shifted)
                    let next = changedBack.nextRepeat(after: gap)!
                    let expected = Dates.placing(clock: 6300, onDayOf: date(cal, 2026, month, day + 1, 12), calendar: cal)
                    try require(unchanged.repeatReminderOffset == changedBack.repeatReminderOffset
                                && changedBack.reminderDate(forOccurrenceAt: next) == expected,
                                "clock edits reverted on a DST gap retain the next custom reminder: \(zone), due \(dueOnly)")
                    let persisted = try reload(changedBack)
                    try require(persisted.reminderDate(forOccurrenceAt: next) == expected, "gap reminder survives persistence without drift")
                    // A real reminder change keeps the pre-existing relative-distance semantics.
                    let changed = TaskBackup.TaskRecord(shifted).model(list: nil); changed.reminderAt = gap.addingTimeInterval(-900)
                    opening.applyRepeatClock(to: changed)
                    try require(changed.repeatReminderOffset == -900, "editing the reminder still recalculates its actual distance")
                    let olderKind = TaskBackup.TaskRecord(shifted).model(list: nil); olderKind.reminderKind = ""
                    let normalizedKind = apply(draft(olderKind, date: gap, intent: roundTripClock(gap, intent: intent)), source: olderKind)
                    try require(normalizedKind.reminderDate(forOccurrenceAt: next) == expected,
                                "older custom-reminder kind normalization preserves known reminder intent")
                    if zone == "America/New_York" {
                        let alias = TaskBackup.TaskRecord(shifted).model(list: nil); alias.repeatTimeZoneID = "US/Eastern"
                        var canonical = draft(alias, date: gap, intent: roundTripClock(gap, intent: intent))
                        canonical.repeatTimeZoneID = zone
                        let saved = apply(canonical, source: alias)
                        try require(saved.reminderDate(forOccurrenceAt: next) == expected,
                                    "equivalent rule-zone names cannot change the reminder when the rule is saved again")
                    }
                    let preset = TaskBackup.TaskRecord(shifted).model(list: nil)
                    preset.reminderKind = ReminderPreset.tenMinutes.rawValue; preset.reminderAt = gap.addingTimeInterval(-600)
                    opening.applyRepeatClock(to: preset)
                    try require(preset.repeatReminderOffset == nil, "switching to a preset discards the custom offset")
                    // Both opening directions retain known rule-zone input, including repeated recovery abroad.
                    for firstZone in [zone, "Asia/Shanghai"] {
                        let opened = inZone(firstZone) { TaskEditor(request: EditorRequest(task: shifted)).draftState }
                        let abroad = inZone("Asia/Shanghai") { TaskEditor(request: EditorRequest(task: shifted), draft: opened).draftState }
                        let restored = TaskEditor(request: EditorRequest(task: shifted), draft: abroad).draftState
                        var input = (dueOnly ? restored.dueClockIntent : restored.startClockIntent)!
                        let selected = input.moving(toDay: date(cal, 2026, month, day + 1, 12), from: shifted.clockDate!)
                        let expected = Dates.placing(clock: clock, onDayOf: date(cal, 2026, month, day + 1, 12), calendar: cal)
                        try require(selected == expected, "both timezone recovery directions retain known intended clock: \(zone), \(firstZone)")
                        let saved = apply(draft(shifted, date: selected, intent: input), source: shifted)
                        try require(saved.repeatClock == clock, "date selection after foreign recovery preserves recurrence time")
                        try require(saved.repeatReminderOffset == shifted.repeatReminderOffset! - 86_400,
                                    "foreign recovery date edits also preserve the reminder's calendar-day meaning")
                        let editedAbroad = inZone("Asia/Shanghai") {
                            var value = (dueOnly ? abroad.dueClockIntent : abroad.startClockIntent)!
                            let nextForeignDay = Dates.calendar.date(byAdding: .day, value: 1, to: shifted.clockDate!)!
                            let selected = value.moving(toDay: nextForeignDay, from: shifted.clockDate!)
                            return draft(shifted, date: selected, intent: value)
                        }
                        let afterForeignEdit = TaskEditor(request: EditorRequest(task: shifted), draft: editedAbroad).draftState
                        var retained = (dueOnly ? afterForeignEdit.dueClockIntent : afterForeignEdit.startClockIntent)!
                        let current = dueOnly ? afterForeignEdit.due! : afterForeignEdit.scheduled!
                        let target = date(cal, 2026, month, day + 2, 12)
                        try require(retained.moving(toDay: target, from: current)
                            == Dates.placing(clock: clock, onDayOf: target, calendar: cal),
                            "a date-only edit abroad cannot erase the original clock before returning home")
                    }
                }
            }
        }
    }

    private static func legacyMigrationDigests(require: (Bool, String) throws -> Void,
                                                rejects: (String, () throws -> Void) throws -> Void) throws {
        let (ledger, _, _) = try seedFinance()
        let current = TaskBackup(finance: ledger, lists: [], tasks: [TaskBackup.TaskRecord(seedTask())])
        var old = current; old.version = 13
        old.tasks[0].repeatTimeZoneID = nil
        old.finance!.version = 2; old.finance!.recurring![0].repeatTimeZoneID = nil
        old.finance!.recurring![0].repeatClock = nil // Format 2 predates intended repeat times.
        let oldDigest = CloudMerge.digest(try CloudMerge.bytes(old, canonical: .beforeTimeZones))
        let currentDigest = CloudMerge.digest(try CloudMerge.bytes(old))
        try require(try CloudMigration.matchesLegacyDigest(oldDigest, snapshot: old),
                    "an interrupted older migration still recognizes its sealed version 13/finance 2 snapshot")
        try require(try CloudMigration.matchesLegacyDigest(currentDigest, snapshot: old),
                    "current canonical migration digests remain accepted")
        var changed = old; changed.tasks[0].title = "Newer source data"
        try require(try !CloudMigration.matchesLegacyDigest(oldDigest, snapshot: changed),
                    "legacy compatibility never accepts changed source contents")
        try rejects("a new rule zone cannot be encoded as an older sealed migration snapshot") {
            _ = try CloudMerge.bytes(current, canonical: .beforeTimeZones)
        }
        try require(try !CloudMigration.matchesLegacyDigest(oldDigest, snapshot: current),
                    "new timezone metadata cannot masquerade as legacy content")
    }

    /// A rule's intended time survives the hour skipped by daylight saving: that day moves forward by the gap
    /// (02:30 → 03:30) and later occurrences return to 02:30. Rules without a time zone keep their old behavior.
    private static func daylightSavingGaps(require: (Bool, String) throws -> Void,
                                           rejects: (String, () throws -> Void) throws -> Void) throws {
        func at(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
        }
        func clockLabel(_ cal: Calendar, _ date: Date?) -> String {
            guard let date else { return "nil" }
            let p = cal.dateComponents([.month, .day, .hour, .minute], from: date)
            return String(format: "%d/%d %02d:%02d", p.month!, p.day!, p.hour!, p.minute!)
        }
        func series(_ base: Date, _ rule: String, _ anchor: Int, _ cal: Calendar, clock: Int?, count: Int) -> [String] {
            var dates = [base]
            for _ in 0..<count {
                guard let next = Dates.nextRepeat(dates.last!, rule: rule, anchorDay: anchor, after: dates.last!, calendar: cal, clock: clock) else { break }
                dates.append(next)
            }
            return dates.map { clockLabel(cal, $0) }
        }
        let ny = calendar("America/New_York"), sydney = calendar("Australia/Sydney"), santiago = calendar("America/Santiago")
        let halfPastTwo = 2 * 3600 + 30 * 60
        try require(Dates.placing(clock: halfPastTwo, onDayOf: at(ny, 2026, 3, 8, 12, 0), calendar: ny) == at(ny, 2026, 3, 8, 3, 30)
                    && Dates.placing(clock: 86_400, onDayOf: at(ny, 2026, 3, 8, 12, 0), calendar: ny) == nil,
                    "a skipped 02:30 is placed at 03:30 and out-of-range times are refused")
        // The same skipped hour under every rule shape, viewed from any device zone.
        for device in ["Asia/Shanghai", "Europe/London", "America/Los_Angeles"] {
            try inZone(device) {
                try require(series(at(ny, 2026, 3, 6, 2, 30), "daily", 6, ny, clock: halfPastTwo, count: 4)
                            == ["3/6 02:30", "3/7 02:30", "3/8 03:30", "3/9 02:30", "3/10 02:30"],
                            "daily 02:30 moves only on the skipped day and returns afterwards (device \(device))")
                try require(series(at(ny, 2026, 3, 6, 2, 30), "daily", 6, ny, clock: nil, count: 4)
                            == ["3/6 02:30", "3/7 02:30", "3/8 03:30", "3/9 03:30", "3/10 03:30"],
                            "rules without an intended time keep their previous behavior (device \(device))")
                try require(series(at(ny, 2026, 3, 1, 2, 30), "weekly", 1, ny, clock: halfPastTwo, count: 2)
                            == ["3/1 02:30", "3/8 03:30", "3/15 02:30"], "weekly rule returns to its intended time")
                let sundays = RepeatRule(interval: 1, unit: .week, weekdays: [1]).text
                try require(series(at(ny, 2026, 3, 1, 2, 30), sundays, 1, ny, clock: halfPastTwo, count: 2)
                            == ["3/1 02:30", "3/8 03:30", "3/15 02:30"], "chosen-weekday rule returns to its intended time")
                try require(series(at(ny, 2026, 2, 8, 2, 30), "monthly", 8, ny, clock: halfPastTwo, count: 2)
                            == ["2/8 02:30", "3/8 03:30", "4/8 02:30"], "monthly rule returns to its intended time")
                let yearly = [at(ny, 2025, 3, 8, 2, 30)] + [Dates.nextRepeat(at(ny, 2025, 3, 8, 2, 30), rule: "yearly", anchorDay: 8, after: at(ny, 2025, 3, 8, 2, 30), calendar: ny, clock: halfPastTwo)!]
                let thirdYear = Dates.nextRepeat(yearly[1], rule: "yearly", anchorDay: 8, after: yearly[1], calendar: ny, clock: halfPastTwo)
                try require(yearly[1] == at(ny, 2026, 3, 8, 3, 30) && thirdYear == at(ny, 2027, 3, 8, 2, 30),
                            "yearly rule moves only in the year its day is skipped")
                // The repeated autumn hour takes its first instance and never produces two occurrences.
                let autumn = series(at(ny, 2026, 10, 31, 1, 30), "daily", 31, ny, clock: 5400, count: 2)
                try require(autumn == ["10/31 01:30", "11/1 01:30", "11/2 01:30"]
                            && Dates.nextRepeat(at(ny, 2026, 10, 31, 1, 30), rule: "daily", anchorDay: 31, after: at(ny, 2026, 10, 31, 1, 30), calendar: ny, clock: 5400)
                                == ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30)),
                            "a repeated hour uses its first instance once")
                try require(series(at(sydney, 2026, 10, 2, 2, 30), "daily", 2, sydney, clock: halfPastTwo, count: 3)
                            == ["10/2 02:30", "10/3 02:30", "10/4 03:30", "10/5 02:30"], "Sydney's October gap behaves the same")
                // Santiago skips midnight: an all-day rule (midnight) is 01:00 on that day only.
                try require(series(at(santiago, 2026, 9, 5, 0, 0), "daily", 5, santiago, clock: 0, count: 2)
                            == ["9/5 00:00", "9/6 01:00", "9/7 00:00"], "an all-day rule returns to midnight after a midnight gap")
            }
        }
        // Tasks keep and carry the intended time.
        func repeating(_ start: Date, zone: String?, timed: Bool = true) -> TaskItem {
            let task = TaskItem(title: "Night routine", scheduledAt: start)
            task.hasTime = timed; task.endAt = timed ? start.addingTimeInterval(900) : nil
            task.repeatRule = "daily"; task.repeatAnchorDay = ny.component(.day, from: start); task.repeatTimeZoneID = zone
            return task
        }
        func complete(_ task: TaskItem, times: Int) -> [TaskItem] {
            var items = [task]
            for _ in 0..<times {
                let last = items.last!
                guard let next = last.nextRepeat(after: last.calendarDate!) else { break }
                items.append(last.occurrence(at: next))
            }
            return items
        }
        let night = repeating(at(ny, 2026, 3, 6, 2, 30), zone: "America/New_York")
        night.refreshRepeatClock()
        let nights = complete(night, times: 4)
        try require(night.repeatClock == halfPastTwo && nights.map { clockLabel(ny, $0.scheduledAt) } == ["3/6 02:30", "3/7 02:30", "3/8 03:30", "3/9 02:30", "3/10 02:30"]
                    && nights.allSatisfy { $0.repeatClock == halfPastTwo } && nights.allSatisfy { $0.endAt == $0.scheduledAt!.addingTimeInterval(900) },
                    "completing a 02:30 task keeps 02:30 after the skipped day, with its length")
        let older = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
        try require(older.repeatClock == nil && complete(older, times: 2).map { clockLabel(ny, $0.scheduledAt) } == ["3/7 02:30", "3/8 03:30", "3/9 02:30"],
                    "a rule saved before intended times records its time before the skipped day")
        let legacy = repeating(at(ny, 2026, 3, 7, 2, 30), zone: nil)
        legacy.refreshRepeatClock()
        try inZone("America/New_York") {
            try require(legacy.repeatClock == nil && legacy.effectiveRepeatClock == nil
                        && complete(legacy, times: 2).map { clockLabel(ny, $0.scheduledAt) } == ["3/7 02:30", "3/8 03:30", "3/9 03:30"],
                        "a rule without a time zone is left exactly as before")
        }
        let allDay = repeating(ny.startOfDay(for: at(ny, 2026, 3, 7, 12, 0)), zone: "America/New_York", timed: false)
        allDay.refreshRepeatClock()
        try require(allDay.repeatClock == nil && allDay.effectiveRepeatClock == 0, "all-day rules store no time and use midnight")
        let deadline = TaskItem(title: "Night deadline", scheduledAt: nil)
        deadline.dueAt = at(ny, 2026, 3, 7, 2, 30); deadline.dueHasTime = true
        deadline.repeatRule = "daily"; deadline.repeatAnchorDay = 7; deadline.repeatTimeZoneID = "America/New_York"
        deadline.refreshRepeatClock()
        try require(deadline.repeatClock == halfPastTwo
                    && complete(deadline, times: 2).map { clockLabel(ny, $0.dueAt) } == ["3/7 02:30", "3/8 03:30", "3/9 02:30"],
                    "an unscheduled timed deadline follows the intended time too")
        let moved = repeating(at(ny, 2026, 3, 6, 2, 30), zone: "America/New_York")
        moved.refreshRepeatClock()
        let before = TaskSchedule(moved)
        moved.schedule(at: at(ny, 2026, 3, 6, 4, 0))
        try require(moved.repeatClock == 4 * 3600, "moving a task to a new time updates its intended time")
        before.restore(moved)
        try require(moved.repeatClock == halfPastTwo && moved.scheduledAt == at(ny, 2026, 3, 6, 2, 30), "undo restores the intended time")
        moved.makeAllDay(on: at(ny, 2026, 3, 6, 12, 0))
        try require(moved.repeatClock == nil, "making a task all-day clears its intended time")
        // A custom reminder is derived from each occurrence's intended time, so it never drifts past its task.
        func reminded(_ reminder: Date) -> TaskItem {
            let task = repeating(at(ny, 2026, 3, 6, 2, 30), zone: "America/New_York")
            task.reminderKind = ReminderPreset.custom.rawValue; task.reminderAt = reminder
            task.refreshRepeatClock()
            return task
        }
        for (reminder, expected, label) in [
            (at(ny, 2026, 3, 6, 2, 15), ["3/7 02:15", "3/8 03:15", "3/9 02:15", "3/10 02:15"], "inside the skipped hour"),
            (at(ny, 2026, 3, 6, 1, 45), ["3/7 01:45", "3/8 01:45", "3/9 01:45", "3/10 01:45"], "before the skipped hour"),
            (at(ny, 2026, 3, 5, 21, 0), ["3/6 21:00", "3/7 21:00", "3/8 21:00", "3/9 21:00"], "on the previous evening")
        ] {
            let task = reminded(reminder)
            let items = Array(complete(task, times: 4).dropFirst())
            try require(items.map { clockLabel(ny, $0.reminderAt) } == expected
                        && items.allSatisfy { $0.reminderAt! <= $0.scheduledAt! && $0.repeatReminderOffset == task.repeatReminderOffset },
                        "a custom reminder \(label) keeps its distance and stays before its task")
        }
        let olderReminder = reminded(at(ny, 2026, 3, 6, 2, 15))
        olderReminder.repeatClock = nil; olderReminder.repeatReminderOffset = nil
        try require(complete(olderReminder, times: 4).dropFirst().map { clockLabel(ny, $0.reminderAt) } == ["3/7 02:15", "3/8 03:15", "3/9 02:15", "3/10 02:15"],
                    "a reminder saved before reminder offsets records its distance before the skipped day")
        let presetTask = repeating(at(ny, 2026, 3, 6, 2, 30), zone: "America/New_York")
        presetTask.reminderKind = ReminderPreset.tenMinutes.rawValue; presetTask.reminderAt = at(ny, 2026, 3, 6, 2, 20)
        presetTask.refreshRepeatClock()
        try require(presetTask.repeatReminderOffset == nil, "preset reminders keep their own rule and store no offset")
        // Moving only to another day keeps the intended time, even from the occurrence shown at 03:30.
        // Moves happen on the device calendar, so this models a device that is in New York.
        try inZone("America/New_York") {
            let shifted = nights[2]
            try require(clockLabel(ny, shifted.scheduledAt) == "3/8 03:30", "fixture is the occurrence moved by daylight saving")
            shifted.reschedule(to: at(ny, 2026, 3, 12, 12, 0))
            try require(clockLabel(ny, shifted.scheduledAt) == "3/12 03:30" && shifted.repeatClock == halfPastTwo
                        && clockLabel(ny, shifted.nextRepeat(after: shifted.scheduledAt!)) == "3/13 02:30",
                        "moving the 03:30 occurrence to another day keeps 02:30 for later ones")
            let dragged = nights[2].occurrence(at: at(ny, 2026, 3, 9, 2, 30))
            dragged.scheduledAt = at(ny, 2026, 3, 8, 3, 30); dragged.endAt = dragged.scheduledAt!.addingTimeInterval(900)
            dragged.schedule(at: at(ny, 2026, 3, 14, 3, 30))
            try require(dragged.repeatClock == halfPastTwo, "dragging to the same time on another day keeps the intended time")
            dragged.schedule(at: at(ny, 2026, 3, 14, 5, 0))
            try require(dragged.repeatClock == 5 * 3600, "dragging to a new time records it")
            let movedReminder = reminded(at(ny, 2026, 3, 6, 2, 15))
            let offsetBefore = movedReminder.repeatReminderOffset
            movedReminder.reschedule(to: at(ny, 2026, 3, 9, 12, 0))
            try require(movedReminder.repeatReminderOffset == offsetBefore && movedReminder.repeatClock == halfPastTwo,
                        "moving to another day keeps the reminder's distance")
        }
        var gapBill = MoneyRecurring(title: "Night bill", amount: 10, currency: "USD", rule: "daily", anchorDay: 8,
                                     nextDate: at(ny, 2026, 3, 8, 3, 30), repeatTimeZoneID: "America/New_York", repeatClock: halfPastTwo)
        gapBill.reschedule(to: at(ny, 2026, 3, 12, 3, 30))
        _ = gapBill.advance()
        try require(gapBill.repeatClock == halfPastTwo && gapBill.nextDate == at(ny, 2026, 3, 13, 2, 30),
                    "moving the 03:30 bill to another day keeps 02:30 for later occurrences")
        var offsetRecord = TaskBackup.TaskRecord(reminded(at(ny, 2026, 3, 6, 2, 15)))
        try require(offsetRecord.repeatReminderOffset == -900
                    && (try TaskBackup.decode(TaskBackup(lists: [], tasks: [offsetRecord]).encoded())).tasks[0].repeatReminderOffset == -900,
                    "backups keep the reminder offset")
        offsetRecord.repeatReminderOffset = 367 * 86_400
        try rejects("an out-of-range reminder offset is refused") { try TaskBackup(lists: [], tasks: [offsetRecord]).validate() }
        var olderOffset = TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(reminded(at(ny, 2026, 3, 6, 2, 15)))]); olderOffset.version = 14
        olderOffset.tasks[0].repeatClock = nil
        try rejects("a format 14 backup cannot carry a reminder offset") { try olderOffset.validate() }
        var reminderOnly = TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(reminded(at(ny, 2026, 3, 6, 2, 15)))])
        let reminderKey = SyncChanges.key("task", reminderOnly.tasks[0].id)
        let withOffset = try SyncFields.snapshot(reminderOnly)
        reminderOnly.tasks[0].repeatReminderOffset = -1800
        try require(try SyncFields.snapshot(reminderOnly)[reminderKey]?["timing"] != withOffset[reminderKey]?["timing"],
                    "the reminder offset merges with the task's timing")
        // Edge cases: damaged values are refused safely, a skipped reminder time stays before its task, moving onto
        // the skipped day keeps the intended time, and a reminder over a year ahead stays savable.
        for damaged in [Int.min, Int.max, 366 * 86_400 + 1, -366 * 86_400 - 1] {
            var record = TaskBackup.TaskRecord(reminded(at(ny, 2026, 3, 6, 2, 15))); record.repeatReminderOffset = damaged
            try rejects("damaged reminder offset \(damaged) is refused without crashing") { try TaskBackup(lists: [], tasks: [record]).validate() }
            let task = reminded(at(ny, 2026, 3, 6, 2, 15)); task.repeatReminderOffset = damaged
            try require(task.effectiveReminderOffset == -900, "a damaged stored offset is ignored, offset \(damaged)")
        }
        for damaged in [Int.min, Int.max, -1, 86_400] {
            var record = TaskBackup.TaskRecord(night); record.repeatClock = damaged
            try rejects("damaged intended time \(damaged) is refused without crashing") { try TaskBackup(lists: [], tasks: [record]).validate() }
            var (damagedLedger, _, _) = try seedFinance(); damagedLedger.recurring![0].repeatClock = damaged
            try rejects("damaged bill intended time \(damaged) is refused without crashing") { try damagedLedger.validate() }
        }
        let tenPast = repeating(at(ny, 2026, 3, 6, 3, 10), zone: "America/New_York")
        tenPast.reminderKind = ReminderPreset.custom.rawValue; tenPast.reminderAt = at(ny, 2026, 3, 6, 2, 50)
        tenPast.refreshRepeatClock()
        let tenPastItems = Array(complete(tenPast, times: 3).dropFirst())
        try require(tenPastItems.allSatisfy { $0.reminderAt! < $0.scheduledAt! }
                    && tenPastItems[1].reminderAt == tenPastItems[1].scheduledAt!.addingTimeInterval(-1200)
                    && clockLabel(ny, tenPastItems[1].scheduledAt) == "3/8 03:10" && clockLabel(ny, tenPastItems[2].reminderAt) == "3/9 02:50",
                    "a reminder time skipped by daylight saving is counted back from its task, not moved after it")
        try inZone("America/New_York") {
            let ordinary = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
            ordinary.reminderKind = ReminderPreset.custom.rawValue; ordinary.reminderAt = at(ny, 2026, 3, 7, 2, 15)
            ordinary.refreshRepeatClock()
            ordinary.reschedule(to: at(ny, 2026, 3, 8, 12, 0))
            try require(clockLabel(ny, ordinary.scheduledAt) == "3/8 03:30" && ordinary.repeatClock == halfPastTwo && ordinary.repeatReminderOffset == -900
                        && clockLabel(ny, ordinary.nextRepeat(after: ordinary.scheduledAt!)) == "3/9 02:30",
                        "moving a 02:30 task onto the skipped day keeps 02:30 for later occurrences")
            // A time the user chooses is recorded, even 03:30 on the skipped day; the move kind says so, not the time.
            let threeThirty = 3 * 3600 + 30 * 60
            let droppedOnGap = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
            droppedOnGap.refreshRepeatClock()
            try require(TaskMove(droppedOnGap, to: Dates.clockTime(on: at(ny, 2026, 3, 8, 12, 0), minute: 210), kind: .timed)
                            .apply(to: droppedOnGap, shiftDeadline: false)
                        && clockLabel(ny, droppedOnGap.scheduledAt) == "3/8 03:30" && droppedOnGap.repeatClock == threeThirty
                        && clockLabel(ny, droppedOnGap.nextRepeat(after: droppedOnGap.scheduledAt!)) == "3/9 03:30",
                        "dragging to 03:30 on the skipped day makes 03:30 the time of later occurrences")
            let droppedOnDay = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
            droppedOnDay.refreshRepeatClock()
            try require(TaskMove(droppedOnDay, to: at(ny, 2026, 3, 8, 12, 0), kind: .day).apply(to: droppedOnDay, shiftDeadline: false)
                        && clockLabel(ny, droppedOnDay.scheduledAt) == "3/8 03:30" && droppedOnDay.repeatClock == halfPastTwo
                        && clockLabel(ny, droppedOnDay.nextRepeat(after: droppedOnDay.scheduledAt!)) == "3/9 02:30",
                        "dragging onto the skipped day itself keeps 02:30 for later occurrences")
            let resized = repeating(at(ny, 2026, 3, 8, 3, 30), zone: "America/New_York")
            resized.repeatClock = halfPastTwo; resized.endAt = at(ny, 2026, 3, 8, 4, 30)
            try require(TaskMove(resized, to: at(ny, 2026, 3, 8, 3, 45), kind: .resizeStart).apply(to: resized, shiftDeadline: false)
                        && resized.repeatClock == threeThirty + 900, "changing the start by resizing records the new time")
            // The editor: a new day alone keeps the intended time, a turned time wheel records the chosen time.
            let gapDay = Dates.replacingDay(of: at(ny, 2026, 3, 7, 2, 30), with: at(ny, 2026, 3, 8, 12, 0))
            try require(clockLabel(ny, gapDay) == "3/8 03:30", "date-only input resolves the skipped clock on its chosen day")
            let edited = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
            edited.refreshRepeatClock()
            edited.scheduledAt = gapDay; edited.endAt = gapDay.addingTimeInterval(900)
            edited.updateRepeatClock(previousClock: halfPastTwo, dateOnly: true)
            try require(edited.repeatClock == halfPastTwo, "an editor save of a new day alone keeps 02:30")
            edited.updateRepeatClock(previousClock: halfPastTwo)
            try require(edited.repeatClock == threeThirty, "an editor save with a chosen 03:30 records 03:30")
            let legacy = repeating(at(ny, 2026, 3, 7, 2, 30), zone: "America/New_York")
            legacy.reschedule(to: at(ny, 2026, 3, 8, 12, 0))
            try require(legacy.repeatClock == halfPastTwo, "a rule saved before intended times locks in its time before a move onto the skipped day")
        }
        // Bills: the next-date picker changes the day alone; a chosen time is recorded.
        for (zone, gap) in [("America/New_York", (2026, 3, 8)), ("Australia/Sydney", (2026, 10, 4))] {
            let cal = calendar(zone)
            var picked = MoneyRecurring(title: "Night bill", amount: 10, currency: "USD", rule: "daily", anchorDay: gap.2 - 1,
                                        nextDate: at(cal, gap.0, gap.1, gap.2 - 1, 2, 30), repeatTimeZoneID: zone, repeatClock: halfPastTwo)
            // The picker hands over the chosen day at the old time of day, already moved by the gap.
            picked.reschedule(toDay: cal.date(bySettingHour: 2, minute: 30, second: 0, of: at(cal, gap.0, gap.1, gap.2, 12, 0))!)
            let onGap = clockLabel(cal, picked.nextDate)
            _ = picked.advance()
            try require(onGap == "\(gap.1)/\(gap.2) 03:30" && picked.repeatClock == halfPastTwo
                        && clockLabel(cal, picked.nextDate) == "\(gap.1)/\(gap.2 + 1) 02:30",
                        "moving a 02:30 bill onto the skipped day shows 03:30 and keeps 02:30 afterwards (\(zone))")
            picked.reschedule(toDay: at(cal, gap.0, gap.1, gap.2 + 5, 12, 0))
            try require(clockLabel(cal, picked.nextDate) == "\(gap.1)/\(gap.2 + 5) 02:30" && picked.repeatClock == halfPastTwo,
                        "moving the bill on to an ordinary day places it at 02:30 (\(zone))")
            var chosen = MoneyRecurring(title: "Night bill", amount: 10, currency: "USD", rule: "daily", anchorDay: gap.2 - 1,
                                        nextDate: at(cal, gap.0, gap.1, gap.2 - 1, 2, 30), repeatTimeZoneID: zone, repeatClock: halfPastTwo)
            chosen.reschedule(to: at(cal, gap.0, gap.1, gap.2, 3, 30))
            _ = chosen.advance()
            try require(chosen.repeatClock == 3 * 3600 + 30 * 60 && clockLabel(cal, chosen.nextDate) == "\(gap.1)/\(gap.2 + 1) 03:30",
                        "a bill moved to a chosen 03:30 keeps 03:30 (\(zone))")
        }
        var timelessBill = MoneyRecurring(title: "Night bill", amount: 10, currency: "USD", rule: "daily", anchorDay: 7,
                                          nextDate: at(ny, 2026, 3, 7, 2, 30), repeatTimeZoneID: nil)
        try inZone("America/New_York") {
            timelessBill.reschedule(toDay: at(ny, 2026, 3, 10, 12, 0))
            try require(timelessBill.repeatClock == nil && timelessBill.nextDate == at(ny, 2026, 3, 10, 2, 30),
                        "a bill without a time zone keeps its hour and minute on the new day")
        }
        // Lord Howe moves by half an hour: 02:15 is 02:45 on the gap day only, and a reminder stays before its task.
        let howe = calendar("Australia/Lord_Howe")
        let quarterPastTwo = 2 * 3600 + 15 * 60
        try require(series(at(howe, 2026, 10, 2, 2, 15), "daily", 2, howe, clock: quarterPastTwo, count: 3)
                    == ["10/2 02:15", "10/3 02:15", "10/4 02:45", "10/5 02:15"]
                    && series(at(howe, 2026, 4, 3, 1, 45), "daily", 3, howe, clock: 6300, count: 3)
                    == ["4/3 01:45", "4/4 01:45", "4/5 01:45", "4/6 01:45"]
                    && Dates.nextRepeat(at(howe, 2026, 4, 4, 1, 45), rule: "daily", anchorDay: 4, after: at(howe, 2026, 4, 4, 1, 45), calendar: howe, clock: 6300)
                        == howe.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 1, minute: 45)),
                    "Lord Howe's half-hour gap and repeated half hour keep the intended time")
        let howeTask = TaskItem(title: "Lord Howe", scheduledAt: at(howe, 2026, 10, 3, 2, 15))
        howeTask.hasTime = true; howeTask.endAt = howeTask.scheduledAt!.addingTimeInterval(900)
        howeTask.repeatRule = "daily"; howeTask.repeatAnchorDay = 3; howeTask.repeatTimeZoneID = "Australia/Lord_Howe"
        howeTask.reminderKind = ReminderPreset.custom.rawValue; howeTask.reminderAt = at(howe, 2026, 10, 3, 2, 0)
        howeTask.refreshRepeatClock()
        let howeItems = Array(complete(howeTask, times: 2).dropFirst())
        try require(howeItems.map { clockLabel(howe, $0.scheduledAt) } == ["10/4 02:45", "10/5 02:15"]
                    && howeItems.map { clockLabel(howe, $0.reminderAt) } == ["10/4 02:30", "10/5 02:00"]
                    && howeItems.allSatisfy { $0.reminderAt! < $0.scheduledAt! },
                    "a Lord Howe task and its reminder keep their times around the half-hour gap")
        // A custom reminder more than a year early: no unsavable offset, and the full save → backup → sync path works.
        let farAhead = repeating(at(ny, 2030, 3, 6, 9, 0), zone: "America/New_York")
        farAhead.reminderKind = ReminderPreset.custom.rawValue; farAhead.reminderAt = at(ny, 2028, 3, 6, 9, 0)
        farAhead.refreshRepeatClock()
        try require(farAhead.repeatClock == 9 * 3600 && farAhead.repeatReminderOffset == nil
                    && farAhead.occurrence(at: farAhead.nextRepeat(after: farAhead.scheduledAt!)!).reminderAt == at(ny, 2028, 3, 7, 9, 0),
                    "a reminder over a year early stores no offset and keeps the whole-day rule")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tally-ReminderOffset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store.make(url: directory.appendingPathComponent("offset.store")), context = store.mainContext
        let saved = repeating(at(ny, 2030, 3, 6, 9, 0), zone: "America/New_York")
        saved.reminderKind = ReminderPreset.custom.rawValue; saved.reminderAt = at(ny, 2028, 3, 6, 9, 0)
        saved.refreshRepeatClock()
        context.insert(saved); try Store.save(context)
        let captured = try TaskBackup.capture(context)
        try require(try TaskBackup.decode(captured.encoded()).tasks.count == 1 && (try? CloudMerge.bytes(captured)) != nil,
                    "a task with a reminder over a year early saves, backs up and syncs")
        // Bills place each occurrence on their intended time.
        var bill = MoneyRecurring(title: "Night bill", amount: 10, currency: "USD", rule: "daily", anchorDay: 6,
                                  nextDate: at(ny, 2026, 3, 6, 2, 30), repeatTimeZoneID: "America/New_York", repeatClock: halfPastTwo)
        var billDates = [clockLabel(ny, bill.nextDate)]
        for _ in 0..<4 { _ = bill.advance(); billDates.append(clockLabel(ny, bill.nextDate)) }
        try require(billDates == ["3/6 02:30", "3/7 02:30", "3/8 03:30", "3/9 02:30", "3/10 02:30"] && bill.repeatClock == halfPastTwo,
                    "a 02:30 bill returns to 02:30 after the skipped day")
        var olderBill = bill; olderBill.nextDate = at(ny, 2026, 3, 7, 2, 30); olderBill.repeatClock = nil
        _ = olderBill.advance(); let gapDay = olderBill.nextDate; _ = olderBill.advance()
        try require(olderBill.repeatClock == halfPastTwo && gapDay == at(ny, 2026, 3, 8, 3, 30) && olderBill.nextDate == at(ny, 2026, 3, 9, 2, 30),
                    "a bill saved before intended times records its time before the skipped day")
        var legacyBill = bill; legacyBill.repeatTimeZoneID = nil; legacyBill.repeatClock = nil; legacyBill.nextDate = at(ny, 2026, 3, 7, 2, 30)
        try inZone("America/New_York") {
            _ = legacyBill.advance(); _ = legacyBill.advance()
            try require(legacyBill.repeatClock == nil && legacyBill.nextDate == at(ny, 2026, 3, 9, 3, 30), "a bill without a time zone keeps its old behavior")
        }
        bill.reschedule(to: at(ny, 2026, 3, 20, 4, 15))
        try require(bill.repeatClock == 4 * 3600 + 15 * 60, "rescheduling a bill updates its intended time")
        var (ledger, seeded, _) = try seedFinance()
        try require(seeded.repeatClock == 0 && ledger.version == 4, "a new bill records its creation time and needs ledger format 4")
        ledger.version = 3
        try rejects("ledger format 3 cannot hide intended times from older clients") { try ledger.validate() }
        ledger.version = 4; ledger.recurring![0].repeatClock = 86_400
        try rejects("an out-of-range intended time is refused") { try ledger.validate() }
        // Backups and sync carry the field without disturbing rules that don't have it.
        let record = TaskBackup.TaskRecord(night)
        let backup = TaskBackup(lists: [], tasks: [record])
        let decoded = try TaskBackup.decode(backup.encoded())
        try require(decoded.version == 15 && decoded.tasks[0].repeatClock == halfPastTwo && decoded.tasks[0].model(list: nil).repeatClock == halfPastTwo,
                    "format 15 backups keep the intended time")
        var asFourteen = backup; asFourteen.version = 14
        try rejects("a format 14 backup cannot carry an intended time") { try asFourteen.validate() }
        var plain = backup; plain.tasks[0].repeatClock = nil; plain.version = 14
        try require((try? plain.validate()) != nil, "format 14 backups without intended times remain readable")
        let rows = try CloudRecordCodec.items(plain)
        try require(rows.values.allSatisfy { $0.payload.map { !String(decoding: $0, as: UTF8.self).contains("repeatClock") } ?? true },
                    "rules without an intended time sync unchanged bytes")
        let withClock = try SyncFields.snapshot(backup), withoutClock = try SyncFields.snapshot(plain)
        let key = SyncChanges.key("task", night.id)
        try require(withClock[key]?["timing"] != withoutClock[key]?["timing"], "the intended time merges with the task's timing")
        var titled = ledger; titled.recurring![0].repeatClock = 0; titled.recurring![0].title = "Retitled"
        var retimed = ledger; retimed.recurring![0].repeatClock = 0
        retimed.recurring![0].reschedule(to: retimed.recurring![0].nextDate.addingTimeInterval(3600))
        var base = ledger; base.recurring![0].repeatClock = 0
        let merged = try CloudMerge.recurringFields(retimed.recurring![0], titled.recurring![0], base.recurring![0],
                                                          choice: nil, report: { _ in }, review: nil)
        try require(merged.title == "Retitled" && merged.repeatClock == 3600 && merged.nextDate == retimed.recurring![0].nextDate,
                    "a bill's intended time merges together with its schedule")
        try require(CloudCommitProtocol.format == 17, "protocol 17 fences clients that would drop intended times")
        // Migration markers sealed by protocol 14–16 used the 14/3 canonical encoding.
        var sealed = TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(seedTask())]); sealed.version = 14
        let sealedDigest = CloudMerge.digest(try CloudMerge.bytes(sealed, canonical: .beforeIntendedTimes))
        try require(try CloudMigration.matchesLegacyDigest(sealedDigest, snapshot: sealed),
                    "an interrupted protocol 14–16 migration still recognizes its sealed snapshot")
        try rejects("an intended time cannot be encoded as a protocol 14–16 snapshot") {
            _ = try CloudMerge.bytes(backup, canonical: .beforeIntendedTimes)
        }
    }

    private static func codingAndConflicts(require: (Bool, String) throws -> Void,
                                            rejects: (String, () throws -> Void) throws -> Void) throws {
        let task = seedTask(), record = TaskBackup.TaskRecord(task)
        let (ledger, bill, _) = try seedFinance()
        let original = TaskBackup(finance: ledger, lists: [], tasks: [record])
        for zone in zones {
            try inZone(zone) {
                var encoded = try original.encoded()
                for _ in 0..<3 {
                    let decoded = try TaskBackup.decode(encoded)
                    try require(decoded.tasks == original.tasks && decoded.finance == original.finance,
                                "new backup keeps zone, IDs and amounts across device zones")
                    encoded = try decoded.encoded()
                }
                var json = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
                json["version"] = 13
                var tasks = json["tasks"] as! [[String: Any]]; tasks[0].removeValue(forKey: "repeatTimeZoneID"); tasks[0].removeValue(forKey: "repeatClock"); json["tasks"] = tasks
                var finance = json["finance"] as! [String: Any]; finance["version"] = 2
                var bills = finance["recurring"] as! [[String: Any]]; bills[0].removeValue(forKey: "repeatTimeZoneID"); bills[0].removeValue(forKey: "repeatClock")
                finance["recurring"] = bills; json["finance"] = finance
                let legacy = try TaskBackup.decode(JSONSerialization.data(withJSONObject: json))
                try require(legacy.tasks[0].repeatTimeZoneID == nil && legacy.finance?.recurringBill(bill.id)?.repeatTimeZoneID == nil,
                            "old payload without zone remains unbound after upgrade")
                try require(legacy.tasks[0].id == task.id && legacy.tasks[0].scheduledAt == record.scheduledAt
                    && legacy.finance?.recurringBill(bill.id)?.id == bill.id && legacy.finance?.recurringBill(bill.id)?.nextDate == bill.nextDate,
                    "legacy decoding does not migrate original IDs or dates")
                try require(try TaskBackup.decode(legacy.encoded()).tasks[0].repeatTimeZoneID == nil,
                            "saving legacy data does not silently confirm a time zone")
            }
        }
        var invalid = ledger; invalid.recurring![0].repeatTimeZoneID = "invalid-zone"
        try rejects("unknown bill zone fails validation before persistence") { try invalid.validate() }
        var unbound = original
        unbound.tasks[0].repeatTimeZoneID = nil
        unbound.finance!.recurring![0].repeatTimeZoneID = nil
        var bound = unbound, titled = unbound
        bound.tasks[0].repeatTimeZoneID = "Asia/Shanghai"
        bound.finance!.recurring![0].repeatTimeZoneID = "Asia/Shanghai"
        titled.tasks[0].title = "Concurrent task title"
        titled.finance!.recurring![0].title = "Concurrent bill title"
        for (left, right) in [(bound, titled), (titled, bound)] {
            let combined = try CloudMerge.merge(local: left, cloud: right, base: unbound)
            try require(combined.tasks[0].title == "Concurrent task title" && combined.tasks[0].repeatTimeZoneID == "Asia/Shanghai"
                && combined.finance?.recurringBill(bill.id)?.title == "Concurrent bill title"
                && combined.finance?.recurringBill(bill.id)?.repeatTimeZoneID == "Asia/Shanghai",
                "independent title edit cannot erase a confirmed recurrence zone in either merge direction")
        }
        var local = original, cloud = original
        local.tasks[0].repeatTimeZoneID = "Europe/London"; cloud.tasks[0].repeatTimeZoneID = "Australia/Sydney"
        local.finance!.recurring![0].repeatTimeZoneID = "Europe/London"
        cloud.finance!.recurring![0].repeatTimeZoneID = "Australia/Sydney"
        try rejects("concurrent incompatible rule zones require review") { _ = try CloudMerge.merge(local: local, cloud: cloud, base: original) }
        for choice in [CloudMerge.Choice.local, .cloud] {
            let merged = try CloudMerge.merge(local: local, cloud: cloud, base: original, choice: choice)
            let expected = choice == .local ? "Europe/London" : "Australia/Sydney"
            try require(merged.tasks[0].repeatTimeZoneID == expected && merged.finance?.recurringBill(bill.id)?.repeatTimeZoneID == expected,
                        "manual rule choice preserves selected recurrence zone on task and bill")
        }
    }
}
