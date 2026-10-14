import Foundation
import SwiftData

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

    private static func legacyMigrationDigests(require: (Bool, String) throws -> Void,
                                                rejects: (String, () throws -> Void) throws -> Void) throws {
        let (ledger, _, _) = try seedFinance()
        let current = TaskBackup(finance: ledger, lists: [], tasks: [TaskBackup.TaskRecord(seedTask())])
        var old = current; old.version = 13
        old.tasks[0].repeatTimeZoneID = nil
        old.finance!.version = 2; old.finance!.recurring![0].repeatTimeZoneID = nil
        let oldDigest = CloudMerge.digest(try CloudMerge.bytes(old, legacyMigrationFormat: true))
        let currentDigest = CloudMerge.digest(try CloudMerge.bytes(old))
        try require(try CloudMigration.matchesLegacyDigest(oldDigest, snapshot: old),
                    "an interrupted older migration still recognizes its sealed version 13/finance 2 snapshot")
        try require(try CloudMigration.matchesLegacyDigest(currentDigest, snapshot: old),
                    "current canonical migration digests remain accepted")
        var changed = old; changed.tasks[0].title = "Newer source data"
        try require(try !CloudMigration.matchesLegacyDigest(oldDigest, snapshot: changed),
                    "legacy compatibility never accepts changed source contents")
        try rejects("a new rule zone cannot be encoded as an older sealed migration snapshot") {
            _ = try CloudMerge.bytes(current, legacyMigrationFormat: true)
        }
        try require(try !CloudMigration.matchesLegacyDigest(oldDigest, snapshot: current),
                    "new timezone metadata cannot masquerade as legacy content")
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
                var tasks = json["tasks"] as! [[String: Any]]; tasks[0].removeValue(forKey: "repeatTimeZoneID"); json["tasks"] = tasks
                var finance = json["finance"] as! [String: Any]; finance["version"] = 2
                var bills = finance["recurring"] as! [[String: Any]]; bills[0].removeValue(forKey: "repeatTimeZoneID")
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
