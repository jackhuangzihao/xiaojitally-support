import Foundation
import SwiftData
import UserNotifications
#if os(macOS)
import AppKit
#endif

@MainActor enum SelfCheck {
    #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
    /// UI examples are allowed only inside a disposable, empty test container.
    static func seedDayTimelineUI() throws {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("local.jianshi.sandboxcheck.day") else {
            throw TaskBackup.invalid("Day fixture requires a disposable sandbox identity")
        }
        #if os(macOS)
        guard NSHomeDirectory().contains("/Containers/" + id + "/Data") else {
            throw TaskBackup.invalid("Day fixture requires a disposable Mac sandbox")
        }
        #else
        guard NSHomeDirectory().contains("/CoreSimulator/Devices/"), NSHomeDirectory().contains("/Containers/Data/Application/") else {
            throw TaskBackup.invalid("Day fixture requires a disposable iOS simulator sandbox")
        }
        #endif
        let container = try Store.make(), context = container.mainContext
        guard container.configurations.allSatisfy({ $0.url.path.hasPrefix(NSHomeDirectory() + "/") }),
              try context.fetch(FetchDescriptor<TaskItem>()).isEmpty,
              try context.fetch(FetchDescriptor<TaskList>()).isEmpty,
              try context.fetch(FetchDescriptor<CalendarWeekTitle>()).isEmpty,
              try context.fetch(FetchDescriptor<CloudSyncState>()).isEmpty,
              try FinanceStore.read(context) == nil else {
            throw TaskBackup.invalid("Day fixture requires an empty store inside its own sandbox")
        }
        let today = Dates.calendar.startOfDay(for: Date())
        func time(_ minute: Int, offset: Int = 0) -> Date {
            Dates.clockTime(on: Dates.calendar.date(byAdding: .day, value: offset, to: today)!, minute: minute)
        }
        let life = TaskList(name: "生活"), study = TaskList(name: "学习"), work = TaskList(name: "工作")
        life.colorHex = "549981"; study.colorHex = "548FA8"; work.colorHex = "9C8464"
        for (index, list) in [life, study, work].enumerated() { list.sortOrder = Double(index); context.insert(list) }
        let lunch = TaskItem(title: "午餐与整理房间", scheduledAt: time(705), list: life)
        lunch.hasTime = true; lunch.endAt = time(765); lunch.notes = "先吃午餐，再简单整理一下书桌。"
        lunch.subtasks = [Subtask(title: "整理书桌")]
        let game = TaskItem(title: "我要打游戏", scheduledAt: time(825), list: study)
        game.hasTime = true; game.endAt = time(1170); game.priority = 2
        game.notes = "记得叫上队友，提前约好时间。"
        game.subtasks = [Subtask(title: "Apex"), Subtask(title: "王者荣耀"), Subtask(title: "炉石传说")]
        if CommandLine.arguments.contains("--large-day-details") {
            game.notes = String(repeating: "长备注展开检查：内容换行后仍然完整显示，收起后不能遮挡下一条任务。\n", count: 120)
            game.subtasks = (1...100).map { Subtask(title: "步骤 \($0)：检查长标题换行与完成状态是否正确") }
        }
        game.dueAt = time(0, offset: 8)
        game.reminderAt = Date().addingTimeInterval(-3600); game.reminderKind = "custom"; game.reminderNeedsAttention = true
        let pending = TaskItem(title: "整理下周计划", scheduledAt: today, list: work)
        let done = TaskItem(title: "回复邮件", scheduledAt: time(540), list: work)
        done.hasTime = true; done.endAt = time(555); done.isDone = true; done.completedAt = Date()
        let earlier = TaskItem(title: "读完这一章", scheduledAt: time(0, offset: -1), list: study)
        let overnight = TaskItem(title: "跨日安排", scheduledAt: time(1410, offset: 1), list: work)
        overnight.hasTime = true; overnight.endAt = time(75, offset: 2)
        let earlierTwo = TaskItem(title: "整理旧笔记", scheduledAt: time(0, offset: -2), list: study)
        let earlierThree = TaskItem(title: "检查出行安排", scheduledAt: time(0, offset: -3), list: life)
        let earlierFour = TaskItem(title: "回复上周的邮件", scheduledAt: time(0, offset: -4), list: work)
        for task in [lunch, game, pending, done, earlier, overnight, earlierTwo, earlierThree, earlierFour] { context.insert(task) }
        try Store.save(context)
        UserDefaults.standard.set("zh", forKey: "appLanguage")
        UserDefaults.standard.set("list", forKey: "planningView")
        UserDefaults.standard.set(false, forKey: "showDayFreeTime")
        print("DAY UI fixture created in disposable sandbox: \(id)")
    }
    #endif

    #if os(macOS) && JIANSHI_APP_STORE
    /// Run only from a separately signed, disposable test identity; never the user's app.
    static func sandbox() throws {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasPrefix("local.jianshi.sandboxcheck."),
              NSHomeDirectory().contains("/Containers/" + identifier + "/Data") else {
            throw TaskBackup.invalid("Sandbox check requires a dedicated sandboxcheck app container")
        }
        try run()
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TaskBackup.invalid(message) }
            checks += 1
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let old = try Store.make(url: support.appendingPathComponent("Jianshi.store"))
        let parent = TaskList(name: "Sandbox fixture"); parent.emoji = "📚"
        let child = TaskList(name: "Nested fixture"); child.parentID = parent.id
        old.mainContext.insert(parent); old.mainContext.insert(child)
        let task = TaskItem(title: "Sandbox task", scheduledAt: Date().addingTimeInterval(86400), list: child)
        task.notes = "Portable migration"; task.hasTime = true
        task.endAt = task.scheduledAt!.addingTimeInterval(7200)
        task.priority = 2; task.repeatRule = "weekly"
        task.subtasks = [Subtask(title: "Finished step", isDone: true)]
        old.mainContext.insert(task)
        let completed = TaskItem(title: "Completed fixture"); completed.isDone = true; completed.completedAt = Date()
        old.mainContext.insert(completed)
        let deleted = TaskItem(title: "Deleted fixture"); deleted.deletedAt = Date()
        old.mainContext.insert(deleted)
        try Store.save(old.mainContext)
        let before = try TaskBackup.capture(old.mainContext)
        let encoded = try before.encoded()
        let destination = try Store.make()
        let fresh = try TaskBackup.capture(destination.mainContext)
        try require(fresh.tasks.isEmpty && fresh.lists.isEmpty, "App Store must not open the stale legacy container store")
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let export = documents.appendingPathComponent("sandbox-fixture.json")
        try encoded.write(to: export, options: .atomic)
        let imported = try TaskBackup.decode(Data(contentsOf: export))
        try imported.restore(destination.mainContext, replace: true)
        let after = try TaskBackup.capture(destination.mainContext)
        try require(try BackupFiles.contentData(before) == BackupFiles.contentData(after), "Import must preserve all fields, IDs, nested lists, completion and deletion")
        let reopened = try Store.make()
        try require(try BackupFiles.contentData(TaskBackup.capture(reopened.mainContext)) == BackupFiles.contentData(before), "Sandbox data must survive closing and reopening the store")
        try require(try BackupFiles.contentData(TaskBackup.capture(old.mainContext)) == BackupFiles.contentData(before), "Import must leave the legacy source unchanged")
        let recovery = try TaskBackup.recoveryURL()
        try encoded.write(to: recovery, options: .atomic)
        try require(try TaskBackup.decode(Data(contentsOf: recovery)).tasks.count == 3, "Pre-restore backup remains readable in sandbox")
        let directory = try BackupFiles.localDirectory()
        _ = try BackupFiles.save(before, directory: directory, owner: "sandbox-check", force: true)
        try require(directory.path.hasPrefix(NSHomeDirectory() + "/"), "Automatic backups stay in the sandbox")
        try require(try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Automatic backup actually writes a file")
        var invalid = imported; invalid.tasks.append(invalid.tasks[0])
        var rejected = false
        do { try invalid.restore(destination.mainContext, replace: true) } catch { rejected = true }
        try require(rejected, "Invalid duplicate backup is rejected")
        try require(try BackupFiles.contentData(TaskBackup.capture(destination.mainContext)) == BackupFiles.contentData(before), "Invalid import leaves existing sandbox data unchanged")
        print("SANDBOX PASS: \(checks) storage and migration checks; \(identifier)")
    }
    #endif

    static func run() throws {
        var checkCount = 0
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Jianshi.SelfCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checkCount += 1
        }
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            Dates.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        // Minute ticks should leave layouts alone, without losing midnight/reminder/overnight transitions.
        do {
            let noon = date(2030, 9, 23), later = noon.addingTimeInterval(60)
            let task = TaskItem(title: "Clock boundary", scheduledAt: noon)
            task.dueAt = noon.addingTimeInterval(30); task.dueHasTime = true
            try require(!CalendarClock.needsRefresh(from: noon, to: later, tasks: [task]), "A deadline label ticks without rebuilding the calendar layout")
            task.reminderAt = noon.addingTimeInterval(30)
            try require(CalendarClock.needsRefresh(from: noon, to: later, tasks: [task]), "A newly expired reminder refreshes its available actions")
            task.isDone = true
            try require(!CalendarClock.needsRefresh(from: noon, to: later, tasks: [task]), "Completed reminders do not trigger layout refreshes")
            task.isDone = false; task.reminderAt = nil
            task.scheduledAt = noon.addingTimeInterval(-86400); task.hasTime = true; task.endAt = noon.addingTimeInterval(30)
            try require(CalendarClock.needsRefresh(from: noon, to: later, tasks: [task]), "An overnight task becomes overdue when it ends")
            task.deletedAt = noon
            try require(!CalendarClock.needsRefresh(from: noon, to: later, tasks: [task]), "Deleted tasks do not trigger clock layout refreshes")
            try require(CalendarClock.needsRefresh(from: noon, to: noon.addingTimeInterval(86400), tasks: []), "Midnight still refreshes the calendar")
            try require(CalendarClock.needsRefresh(from: later, to: noon, tasks: []), "Moving the system clock backwards refreshes the calendar")
            let layout = TimelineLayout.make(blocks: [], fullDay: true, density: 1)
            try require(PlanSlot.emptyPoint(CGPoint(x: 120, y: 615), column: 300, gutter: 44, layout: layout, occupied: [], dayCount: 1) == PlanSlot(day: 0, minute: 615), "Phone timeline taps address the selected day")
            try require(PlanSlot.emptyPoint(CGPoint(x: 345, y: 615), column: 300, gutter: 44, layout: layout, occupied: [], dayCount: 1) == nil, "Phone timeline ignores taps past its single day")
        }
        // A disappearing popover must not close the different card/day just opened by the user.
        do {
            let presentation = CalendarPresentation()
            let first = date(2030, 9, 23), second = date(2030, 9, 24)
            let task = UUID(), firstKey = "\(task)|first-day|true", secondKey = "\(task)|second-day|true"
            presentation.showTask(firstKey)
            presentation.showTask(secondKey)
            presentation.dismissTask(firstKey)
            try require(presentation.taskKey == secondKey, "Dismissing the first segment preserves the next segment of the same task")
            presentation.dismissTask(secondKey)
            try require(presentation.taskKey == nil, "Dismissing the active task closes its popover")
            presentation.showDay(first)
            presentation.expandedTask = task
            presentation.updateRowsHeight(500, for: first)
            presentation.showDay(second)
            presentation.dismissDay(first)
            presentation.updateRowsHeight(200, for: first)
            try require(presentation.isDay(second) && presentation.expandedTask == nil && presentation.rowsHeight == 44,
                        "A new day starts collapsed and ignores the previous day's dismiss and measurement callbacks")
            presentation.updateRowsHeight(124.25, for: second)
            try require(presentation.rowsHeight == 125, "Day popover measurement rounds up to avoid fractional height churn")
            presentation.updateRowsHeight(500, for: second)
            try require(presentation.rowsHeight == 360, "Long day details scroll within the popover height limit")
            presentation.dismissDay(second)
            try require(presentation.day == nil, "Dismissing the active day closes its popover")
            presentation.showDay(first); presentation.showTask(secondKey)
            try require(presentation.day == nil && presentation.taskKey == secondKey, "Opening a task closes the day popover")
            presentation.inlineDelete = task
            presentation.close()
            try require(presentation.taskKey == nil && presentation.day == nil && presentation.inlineDelete == nil,
                        "Opening an editor or changing calendar pages clears active popover and delete confirmation")
        }
        // A wall-clock timeline stays 0–24 even on a 23/25-hour day.
        do {
            for zone in ["Australia/Sydney", "America/New_York", "Asia/Shanghai"] {
                var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
                for (month, day) in [(10, 4), (4, 5), (3, 8), (11, 1)] {
                    let start = c.date(from: DateComponents(year: 2026, month: month, day: day))!
                    let noon = c.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
                    let task = TaskItem(title: "DST clock", scheduledAt: noon); task.hasTime = true; task.endAt = noon.addingTimeInterval(3600)
                    let block = PlanBlock.layout([task], day: start, calendar: c).first
                    try require(block?.start == 720 && block?.end == 780, "Noon stays at 12–13 in the week grid: " + zone)
                    try require(Dates.clockTime(on: start, minute: 720, calendar: c) == noon, "Dropping at noon saves noon: " + zone)
                    let next = c.date(byAdding: .day, value: 1, to: start)!
                    let span = Dates.clockSpan(from: start, to: next, on: start, calendar: c)
                    try require(span.start == 0 && span.end == 1440 && Dates.clockTime(on: start, minute: 1440, calendar: c) == next,
                                "Midnight clipping and 24:00 use the next calendar day: " + zone)
                }
            }
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Australia/Sydney")!
            let spring = c.date(from: DateComponents(year: 2026, month: 10, day: 4))!
            let missing = Dates.clockTime(on: spring, minute: 135, calendar: c)
            try require(Dates.clockMinute(missing, calendar: c) == 195 && c.isDate(missing, inSameDayAs: spring), "Missing 02:15 resolves to 03:15 on the same day")
            let autumn = c.date(from: DateComponents(year: 2026, month: 4, day: 5))!
            let first = Dates.clockTime(on: autumn, minute: 150, calendar: c), second = first.addingTimeInterval(3600)
            try require(Dates.clockMinute(first, calendar: c) == 150 && Dates.clockMinute(second, calendar: c) == 150,
                        "Both autumn occurrences have the same wall-clock coordinate")
            try require(Dates.clockTime(on: autumn, minute: 150, reference: second, calendar: c) == second,
                        "Resizing an existing repeated-hour task keeps its original occurrence")
            let backwards = Dates.clockSpan(from: first.addingTimeInterval(900), to: second.addingTimeInterval(-900), on: autumn, calendar: c)
            try require(backwards.end > backwards.start, "Task crossing the repeated hour never has a negative frame")
        }
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
        do {
            for zone in ["Australia/Sydney", "America/New_York", "Asia/Shanghai"] {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
                for (month, day) in [(10, 4), (4, 5), (3, 8), (11, 1)] {
                    let midnight = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
                    let days = (-1...2).map { calendar.date(byAdding: .day, value: $0, to: midnight)! }
                    let span = TaskItem(title: "Across clock change", scheduledAt: days[0].addingTimeInterval(23 * 3600))
                    span.hasTime = true; span.endAt = days[2]
                    let done = TaskItem(title: "Done", scheduledAt: midnight); done.isDone = true
                    let deadline = TaskItem(title: "Deadline"); deadline.dueAt = days[2]; deadline.dueHasTime = true
                    let deleted = TaskItem(title: "Trash", scheduledAt: midnight); deleted.deletedAt = midnight
                    let tasks = [span, done, deadline, deleted, TaskItem(title: "Undated")]
                    let index = CalendarIndex.byDay(tasks, days: days, calendar: calendar)
                    for date in days {
                        let range = calendar.dateInterval(of: .day, for: date)!
                        try require(Set((index[date] ?? []).map(\.id)) == Set(tasks.filter { $0.overlaps(range) }.map(\.id)),
                                    "Calendar bucketing matches interval membership across midnight and DST: " + zone)
                    }
                    try require(index[days[2]]?.map(\.id) == [deadline.id], "Midnight end is exclusive even across 23/25-hour days: " + zone)
                }
            }
            try require(CalendarIndex.byDay([], days: []).isEmpty, "Empty calendar range produces no buckets")
        }
        do {
            let day = Dates.calendar.startOfDay(for: date(2030, 9, 26))
            func timed(_ start: Int, _ end: Int?, done: Bool = false) -> TaskItem {
                let task = TaskItem(title: "Agenda", scheduledAt: day.addingTimeInterval(Double(start * 60)))
                task.hasTime = true; task.endAt = end.map { day.addingTimeInterval(Double($0 * 60)) }; task.isDone = done
                return task
            }
            let done = timed(780, 840, done: true)
            try require(DaySchedule([done], day: day).gaps.isEmpty, "Single task has no leading or trailing gap")
            try require(DaySchedule([], day: day).gaps.isEmpty, "Empty day does not assume working hours")
            let items = [timed(480, 600), timed(540, 660, done: true), timed(650, 780)]
            let joined = DaySchedule(items, day: day)
            try require(joined.clusters.count == 1 && joined.gaps.isEmpty, "Chained overlaps have no internal free time")
            let span = DaySchedule.span(joined.clusters[0], day: day)!
            try require(span.start == 480 && span.end == 780 && span.end - span.start == 300, "Overlap label spans connected tasks without double-counting")
            let separate = DaySchedule([items[0], items[2]], day: day)
            try require(separate.clusters.count == 2 && separate.gaps[1] == 50, "Gap lies strictly between task end and next start")
            for minutes in [1, 5, 15, 29, 30] {
                let small = DaySchedule([timed(540, 600), timed(600 + minutes, 690)], day: day)
                try require(small.gaps[1] == minutes, "Any positive gap is visible: \(minutes) minutes")
            }
            try require(DaySchedule([timed(540, 600), timed(600, 660)], day: day).gaps.isEmpty, "Touching tasks have no gap")
            let point = timed(600, nil)
            try require(DaySchedule([point, timed(660, 720)], day: day).gaps.isEmpty, "No invented finish or free time after a start-only task")
            try require(DaySchedule.span([point], day: day) == nil, "Start-only task has no occupied span")
            let deadline = TaskItem(title: "Timed deadline")
            deadline.dueAt = day.addingTimeInterval(630 * 60); deadline.dueHasTime = true
            let untimed = TaskItem(title: "Time pending", scheduledAt: day)
            let undated = TaskItem(title: "No date")
            let deadlineSchedule = DaySchedule([untimed, undated, deadline], day: day)
            try require(deadlineSchedule.clusters.flatMap { $0 }.map(\.id) == [deadline.id], "A timed deadline belongs on the timeline; time-pending and undated tasks do not")
            try require(DaySchedule.span([deadline], day: day) == nil && DaySchedule([deadline, timed(660, 720)], day: day).gaps.isEmpty,
                        "A deadline-only task has no invented duration or following free interval")
            deadline.scheduledAt = day
            try require(DaySchedule([deadline], day: day).clusters.isEmpty, "An untimed schedule stays time-pending even when its deadline has a time")
            let ordinary = timed(540, 600), important = timed(540, 570), earlier = timed(480, 500)
            important.priority = 2
            try require(DaySchedule([ordinary, important, earlier], day: day).clusters.flatMap { $0 }.map(\.id) == [earlier.id, important.id, ordinary.id],
                        "Day timeline orders by start time, then priority within the same start")
            let early = DaySchedule([timed(60, 120), timed(125, 180)], day: day)
            try require(early.gaps[1] == 5, "Early-morning gaps do not depend on a 07:00 boundary")
            let late = DaySchedule([timed(1380, 1395), timed(1400, 1430)], day: day)
            try require(late.gaps[1] == 5, "Late-night gaps do not depend on a 23:00 boundary")
            let overnight = timed(-60, 480, done: true)
            let night = DaySchedule([overnight, timed(490, 540)], day: day)
            try require(night.gaps[1] == 10, "Completed overnight task retains its occupied morning")
            try require(DaySchedule.span([overnight], day: day)?.start == 0, "Cross-day group begins at day boundary")
            try require(DaySchedule.span([timed(1380, 1500)], day: day)?.end == 1440, "Cross-day group ends at day boundary")
            let before = timed(540, 600), after = timed(660, 720), hidden = timed(605, 650, done: true)
            try require(DaySchedule([before, after], day: day, occupying: [before, hidden, after]).gaps[1] == 15, "Hidden completed task remains occupied when filtering")
            hidden.endAt = day.addingTimeInterval(660 * 60); hidden.scheduledAt = day.addingTimeInterval(600 * 60)
            try require(DaySchedule([before, after], day: day, occupying: [before, hidden, after]).gaps.isEmpty, "Fully occupied hidden gap is not labelled free")
            hidden.deletedAt = day
            try require(DaySchedule([before, after], day: day, occupying: [before, hidden, after]).gaps[1] == 60, "Deleted task no longer occupies time")
            try require(1440 - PlanBlock.freeTime(PlanBlock.layout(items, day: day), from: 0, to: 1440).free == 300, "Week occupied-time calculation remains unchanged")

        }
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
        let span = TaskItem(title: "Multi-day", scheduledAt: date(2026, 9, 30))
        span.hasTime = true; span.endAt = date(2026, 10, 2)
        let editedEnd = Dates.changingEndClock(Dates.calendar.date(bySettingHour: 15, minute: 30, second: 0, of: date(2026, 10, 2))!, start: span.scheduledAt!, end: span.endAt!)
        try require(Dates.sameDay(editedEnd, span.endAt!) && Dates.calendar.component(.minute, from: editedEnd) == 30, "End clock preserves multi-day end date")
        let nextMorning = Dates.changingEndClock(Dates.calendar.date(bySettingHour: 2, minute: 0, second: 0, of: date(2026, 9, 30))!, start: span.scheduledAt!, end: span.scheduledAt!)
        try require(Dates.sameDay(nextMorning, date(2026, 10, 1)), "Earlier end clock rolls to next day")
        try require(span.appearsInCalendar(on: date(2026, 10, 1), wholeMonth: false)
                    && span.appearsInCalendar(on: date(2026, 10, 2), wholeMonth: false)
                    && span.appearsInCalendar(on: date(2026, 10, 15), wholeMonth: true), "Intervals appear on every occupied day and month")
        try require(!span.appearsInCalendar(on: date(2026, 9, 29), wholeMonth: false)
                    && !span.appearsInCalendar(on: date(2026, 10, 3), wholeMonth: false), "Intervals stay inside their date range")
        var spanFilter = TaskFilter(); spanFilter.span = .today
        try require(spanFilter.matches(span, lists: [], today: date(2026, 10, 1)), "Today filter includes ongoing interval")
        span.endAt = Dates.calendar.startOfDay(for: date(2026, 10, 2))
        try require(!span.appearsInCalendar(on: date(2026, 10, 2), wholeMonth: false)
                    && PlanBlock.layout([span], day: date(2026, 10, 2)).isEmpty, "Midnight end is exclusive in list and timeline")
        span.isDone = true
        try require(span.appearsInCalendar(on: date(2026, 10, 1), wholeMonth: false), "Completion preserves occupied dates")
        span.deletedAt = Date()
        try require(!span.appearsInCalendar(on: date(2026, 10, 1), wholeMonth: false), "Trash excluded on continuation dates")
        try require(TaskList.validColor("12aBcF") && !TaskList.validColor("#FFFFFF")
                    && !TaskList.validColor("zzzzzz") && !TaskList.validColor("12345"), "RGB color validation")

        try require(ListColor.presets.count == 48 && Set(ListColor.presets.map(\.hex)).count == 48
                    && ListColor.presets.allSatisfy { TaskList.validColor($0.hex) && !$0.zh.isEmpty && !$0.en.isEmpty },
                    "Preset colors are distinct, valid, and labelled")
        var clearedDrop = false
        let drop = TimelineDrop(update: { _ in }, exit: { clearedDrop = true }, receive: { _, _ in })
        try require(drop.load(NSItemProvider(object: "jianshi-task:test" as NSString), at: .zero) && clearedDrop,
                    "Drop clears preview synchronously before loading its payload")
        clearedDrop = false
        try require(!drop.load(NSItemProvider(), at: .zero) && clearedDrop,
                    "Unsupported drop also clears preview immediately")
        let feedback = DragFeedback(), firstTarget = UUID(), secondTarget = UUID()
        feedback.begin(UUID()); feedback.enter(firstTarget); feedback.enter(secondTarget)
        try require(feedback.target == secondTarget, "Only the latest drag target is highlighted")
        feedback.leave(firstTarget)
        try require(feedback.target == secondTarget, "Late exit from an old target does not clear the current one")
        feedback.end()
        try require(feedback.target == nil && feedback.payload == nil, "Ending or cancelling drag clears every hover")
        feedback.enter(firstTarget)
        try require(feedback.target == nil, "Late hover callback after release is ignored")
        feedback.begin(UUID()); feedback.cancel(); feedback.begin(UUID()); feedback.enter(firstTarget)
        try require(feedback.blockedUntilMouseDown && feedback.payload == nil && feedback.target == nil,
                    "Calendar list Escape cannot restart from continued motion")
        let cancelledDrop = TimelineDrop(update: { _ in }, exit: {}, receive: { _, _ in }, localValue: { feedback.payload })
        try require(!cancelledDrop.acceptLocal(at: .zero), "Cancelled list drag has no acceptable local payload")
        feedback.newPress(); feedback.begin(UUID())
        try require(feedback.payload != nil && !feedback.blockedUntilMouseDown, "A new physical press enables the next calendar list drag")
        feedback.end()
        feedback.begin(UUID())
        let previousSession = feedback.sessionID!
        feedback.begin(UUID()); feedback.enter(secondTarget)
        let currentSession = feedback.sessionID!
        feedback.end(session: previousSession)
        try require(feedback.sessionID == currentSession && feedback.target == secondTarget,
                    "Late native completion cannot clear a newer drag or its highlight")
        // No physical mouse button is held during self-check: the native session owns its lifetime.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try require(feedback.sessionID == currentSession && feedback.payload != nil && feedback.target == secondTarget,
                    "Trackpad physical button-up does not expire an active drag or its highlight")
        feedback.leave(secondTarget); feedback.enter(firstTarget)
        try require(feedback.target == firstTarget, "An active drag can re-enter another date after button-up")
        feedback.end(session: currentSession)
        try require(feedback.payload == nil && feedback.target == nil, "Native session end clears payload and highlight")
        feedback.begin(UUID()); feedback.enter(firstTarget)
        #if os(macOS)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try require(feedback.payload == nil && feedback.target == nil && feedback.blockedUntilMouseDown,
                    "System interruption cancels the drag and prevents stale drops")
        #endif
        feedback.newPress(); feedback.begin(UUID())
        var received = 0
        let once = TimelineDrop(update: { _ in }, exit: {}, receive: { _, _ in received += 1; feedback.end() },
                                localValue: { feedback.payload })
        try require(once.acceptLocal(at: .zero) && !once.acceptLocal(at: .zero) && received == 1,
                    "A native drag is consumed only once and late drops cannot move the old task")
        var localOrder: [String] = []
        let localDrop = TimelineDrop(update: { _ in }, exit: { localOrder.append("clear") },
                                     receive: { _, _ in localOrder.append("receive") },
                                     localValue: { "jianshi-task:test" })
        try require(localDrop.acceptLocal(at: .zero) && localOrder == ["clear", "receive"],
                    "Internal drop clears then receives synchronously")
        try require(PageSwipe.direction(CGSize(width: -140, height: 12)) == 1
                    && PageSwipe.direction(CGSize(width: 140, height: -12)) == -1,
                    "Calendar swipes page in either horizontal direction")
        try require(PageSwipe.direction(CGSize(width: 15, height: 300)) == nil
                    && PageSwipe.direction(CGSize(width: -90, height: 100)) == nil
                    && PageSwipe.direction(CGSize(width: 50, height: 0)) == nil,
                    "Vertical scrolling, diagonal pans and short drags never page the calendar")
        let september = Dates.monthCells(date(2026, 9, 19))
        try require(Dates.sameDay(september[0], date(2026, 8, 31)), "Monday-first calendar")
        try require(september.count == 35, "September grid")
        try require(Dates.monthCells(date(2026, 3, 1)).count == 42, "Six-week month")
        try require(Dates.monthCells(date(2024, 2, 1)).contains { Dates.sameDay($0, date(2024, 2, 29)) }, "Leap day")
        try require(Dates.sameDay(Dates.shiftMonth(date(2026, 12, 31), by: 1), date(2027, 1, 1)), "Year boundary")
        try require(!Dates.matches(nil, selected: date(2026, 9, 19), wholeMonth: false), "Undated task")
        try require(Dates.matches(date(2026, 9, 23), selected: date(2026, 9, 19), wholeMonth: true), "Whole month includes future task")
        try require(!Dates.matches(date(2026, 10, 1), selected: date(2026, 9, 19), wholeMonth: true), "Month boundary")
        let week = Dates.weekCells(date(2026, 10, 1))
        try require(week.count == 7 && Dates.sameDay(week[0], date(2026, 9, 28)) && Dates.sameDay(week[6], date(2026, 10, 4)), "Compact week spans months")
        let timed = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 18, minute: 45))!
        let moved = Dates.replacingDay(of: timed, with: date(2026, 10, 3))
        try require(Dates.sameDay(moved, date(2026, 10, 3)) && Dates.calendar.component(.hour, from: moved) == 18 && Dates.calendar.component(.minute, from: moved) == 45, "Date buttons preserve scheduled time")
        let overdue = TaskItem(title: "昨天的工作", scheduledAt: date(2026, 9, 18))
        let today = date(2026, 9, 19)
        try require(overdue.isOverdue(today: today) && !overdue.appearsInCalendar(on: today, wholeMonth: false), "Unfinished earlier task is overdue, listed under the calendar rather than on today")
        overdue.isDone = true; overdue.completedAt = today
        try require(!overdue.isOverdue(today: today), "Completed task is no longer overdue")
        try require(overdue.appearsInCalendar(on: date(2026, 9, 18), wholeMonth: false), "Completed task remains on original date")
        overdue.deletedAt = today
        try require(!overdue.isOverdue(today: today) && !overdue.appearsInCalendar(on: date(2026, 9, 18), wholeMonth: false), "Deleted task stays out of calendar and overdue list")
        overdue.deletedAt = nil; overdue.isDone = false
        try require(overdue.isOverdue(today: today), "Reopening an earlier task makes it overdue again")
        try require(!overdue.isOverdue(today: date(2026, 9, 18)), "A task is not overdue on its own day")
        let noon = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 12))!
        try require(DeadlineCountdown(due: date(2026, 9, 29), timed: false, now: noon).level == .normal
                    && DeadlineCountdown(due: date(2026, 9, 22), timed: false, now: noon).level == .soon
                    && DeadlineCountdown(due: date(2026, 9, 22), timed: false, now: noon).short == "还剩 3 天"
                    && DeadlineCountdown(due: date(2026, 9, 19), timed: false, now: noon).level == .today
                    && DeadlineCountdown(due: Dates.calendar.date(bySettingHour: 18, minute: 0, second: 0, of: noon)!, timed: true, now: noon).short == "今天 18:00 截止"
                    && DeadlineCountdown(due: Dates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: noon)!, timed: true, now: noon).level == .overdue
                    && DeadlineCountdown(due: date(2026, 9, 17), timed: false, now: noon).short == "已逾期 2 天", "Deadline countdown follows the agreed table")
        try require(UISettings.resolvedLanguage(nil, preferredLanguages: ["en-AU", "zh-Hans"]) == "en", "New users follow English system language")
        try require(UISettings.resolvedLanguage("system", preferredLanguages: ["zh-Hant-HK", "en"]) == "zh", "System mode supports Chinese variants")
        try require(UISettings.resolvedLanguage("system", preferredLanguages: ["fr-FR", "en-GB", "zh"]) == "en", "System mode uses first supported preferred language")
        try require(UISettings.resolvedLanguage("system", preferredLanguages: ["ja-JP"]) == "en", "Unsupported system language falls back to English")
        try require(UISettings.resolvedLanguage("zh", preferredLanguages: ["en"]) == "zh" && UISettings.resolvedLanguage("en", preferredLanguages: ["zh"]) == "en", "Explicit language choice is preserved")
        try require(UISettings.backupFailure("自动备份未完成：disk", language: "en") == "Automatic backup failed: disk", "Cached Chinese backup prefix switches to English")
        try require(UISettings.backupFailure("Automatic backup failed: disk", language: "zh") == "自动备份未完成：disk", "Cached English backup prefix switches to Chinese")
        try require(UISettings.backupFailure("", language: "en").isEmpty, "Successful backup has no failure text")
        try require(L("日历", "Calendar", language: "en") == "Calendar" && L("日历", "Calendar", language: "zh") == "日历", "Language choice")
        try require(Dates.formatPattern("yyyy年M月", language: "en") == "MMMM yyyy", "English dates")
        try require(["M月d日 EEEE", "yyyy年M月", "M月安排", "yyyy年M月d日", "M月d日 E", "M月d日", "M月d日 HH:mm", "M月d日 E HH:mm"]
                        .allSatisfy { !Dates.formatPattern($0, language: "en").contains("月") }, "Every date format has an English version")
        try require(UISettings.colorScheme("system") == nil && UISettings.colorScheme("dark") == .dark && UISettings.colorScheme("light") == .light, "Three appearance modes")
        try require(TaskScope.unscheduled.localizedTitle("zh") == "无日期任务" && TaskScope.unscheduled.icon != TaskScope.calendar.icon, "Undated tasks entry has its own name and icon")
        do {
            let defaults = UserDefaults.standard, saved = UserDefaults.standard.object(forKey: "appLanguage")
            defer { if let saved { defaults.set(saved, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") } }
            let day = date(2026, 10, 1)
            defaults.set("zh", forKey: "appLanguage")
            let chinese = Dates.label(day, pattern: "yyyy年M月d日")
            defaults.set("en", forKey: "appLanguage")
            let english = Dates.label(day, pattern: "yyyy年M月d日")
            try require(chinese.contains("年") && !english.contains("年") && english.contains("2026"), "Cached dates immediately follow language changes")
            defaults.set("zh", forKey: "appLanguage")
            try require(Dates.label(day, pattern: "yyyy年M月d日") == chinese, "Switching language back reuses the correct formatter")
            try require(Money.format(Decimal(string: "1234.56")!, "CNY") == "¥1,234.56" && Money.format(1234, "JPY") == "JP¥1,234", "Money formatting keeps currency precision across cached formatters")
            try require(UISettings.locale(for: "system", preferredLanguages: ["en-AU"]).identifier == "en_US"
                        && UISettings.locale(for: nil, preferredLanguages: ["zh-Hans"]).identifier == "zh_CN", "System locale defaults resolve correctly")
        }
        let timedBase = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 15, minute: 0))!
        try require(ReminderPreset.tenMinutes.date(base: timedBase, timed: true) == timedBase.addingTimeInterval(-600)
                    && ReminderPreset.oneHour.date(base: timedBase, timed: true) == timedBase.addingTimeInterval(-3600)
                    && ReminderPreset.atTime.date(base: timedBase, timed: true) == timedBase, "Relative reminders follow task time")
        let dayBase = date(2026, 9, 19)
        try require(Dates.calendar.component(.hour, from: ReminderPreset.morning.date(base: dayBase, timed: false)!) == 9
                    && Dates.sameDay(ReminderPreset.dayBefore.date(base: dayBase, timed: false)!, date(2026, 9, 18)), "Day reminders use 9:00")
        try require(ReminderPreset.tenMinutes.date(base: dayBase, timed: false) == nil && ReminderPreset.options(base: nil, timed: false) == [.none, .custom], "Relative reminders need a time or date")
        try require(ReminderPreset.infer(reminder: timedBase.addingTimeInterval(-600), base: timedBase, timed: true) == .tenMinutes
                    && ReminderPreset.infer(reminder: timedBase.addingTimeInterval(-900), base: timedBase, timed: true) == .custom
                    && ReminderPreset.infer(reminder: nil, base: timedBase, timed: true) == .none, "Saved reminder reopens as the matching option")
        try require(ReminderPreset.latest(base: timedBase, timed: true) == timedBase
                    && Dates.sameDay(ReminderPreset.latest(base: dayBase, timed: false)!, dayBase)
                    && ReminderPreset.options(base: timedBase, timed: true).compactMap { $0.date(base: timedBase, timed: true) }.allSatisfy { $0 <= timedBase }
                    && ReminderPreset.options(base: dayBase, timed: false).compactMap { $0.date(base: dayBase, timed: false) }.allSatisfy { $0 <= ReminderPreset.latest(base: dayBase, timed: false)! }, "Reminder options never come after the task")
        let evening = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 18))!
        try require(Dates.deadlineAllowed(due: evening, dueTimed: true, scheduled: timedBase, scheduledTimed: true)
                    && !Dates.deadlineAllowed(due: timedBase.addingTimeInterval(-60), dueTimed: true, scheduled: timedBase, scheduledTimed: true)
                    && Dates.deadlineAllowed(due: dayBase, dueTimed: false, scheduled: timedBase, scheduledTimed: true)
                    && !Dates.deadlineAllowed(due: date(2026, 9, 18), dueTimed: false, scheduled: dayBase, scheduledTimed: false)
                    && Dates.deadlineAllowed(due: date(2026, 9, 1), dueTimed: false, scheduled: nil, scheduledTimed: false), "Deadline can't be before the scheduled time")
        let dragged = TaskItem(title: "拖动", scheduledAt: date(2026, 9, 20))
        dragged.dueAt = Dates.calendar.startOfDay(for: date(2026, 9, 25))
        dragged.reschedule(to: date(2026, 9, 10))
        try require(!dragged.deadlineConflict(movingTo: date(2026, 9, 24)) && dragged.deadlineConflict(movingTo: date(2026, 9, 30)), "Drag detects moves past the deadline")
        dragged.reschedule(to: date(2026, 9, 30), extendingDeadline: true)
        try require(Dates.sameDay(dragged.dueAt!, date(2026, 9, 30)), "Extending a deadline moves it only onto the new day, not by the whole drag distance")
        let timedDrag = TaskItem(title: "拖动带时间", scheduledAt: timedBase)
        timedDrag.hasTime = true; timedDrag.dueAt = Dates.calendar.date(byAdding: .hour, value: -3, to: timedBase)!; timedDrag.dueHasTime = true
        timedDrag.reschedule(to: date(2026, 9, 22), extendingDeadline: true)
        try require(timedDrag.dueAt! >= timedDrag.scheduledAt!, "Extended timed deadline is not before the scheduled time")
        try require(Set(TaskScope.standard.map { $0.localizedTitle("en") }).count == 5 && TaskScope.calendar.localizedTitle("zh") == "日历", "Distinct translated navigation labels")
        let sameDay = TaskItem(title: "今天的工作", scheduledAt: today)
        sameDay.isDone = true; sameDay.completedAt = today
        try require(sameDay.appearsInCalendar(on: today, wholeMonth: false), "Normal completion remains visible")

        try require(Dates.sameDay(Dates.selectionAfterDayChange(today, previousToday: today, now: date(2026, 9, 20)), date(2026, 9, 20)), "Today selection advances after midnight")
        try require(Dates.sameDay(Dates.selectionAfterDayChange(date(2026, 10, 1), previousToday: today, now: date(2026, 9, 20)), date(2026, 10, 1)), "Browsing another date survives midnight")
        try require(Dates.groupLabel(today, today: today) == L("今天", "Today"), "Compact today group")
        let older = TaskItem(title: "Old schedule, recent completion", scheduledAt: date(2025, 1, 1))
        older.completedAt = today
        sameDay.completedAt = date(2026, 9, 18)
        try require(older.completionSortDate > sameDay.completionSortDate, "Completion sorting ignores schedule")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let week = CalendarWeekTitle.key(for: date(2027, 1, 1))
            try require(week == "2026-12-28" && CalendarWeekTitle.validKey(week), "Week title key uses the Monday across year boundaries")
            try require(!CalendarWeekTitle.validKey("2026-12-29") && !CalendarWeekTitle.validKey("2026-02-30"), "Week-title import rejects non-Mondays and impossible dates")
            for zone in ["Australia/Sydney", "America/New_York", "Asia/Shanghai"] {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
                let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
                try require(CalendarWeekTitle.key(for: sunday, calendar: calendar) == "2026-09-28", "Civil week key survives DST: " + zone)
            }
            let db = try Store.make(url: directory.appendingPathComponent("week-titles.store"))
            db.mainContext.insert(CalendarWeekTitle(week: week, title: "Week 11")); try Store.save(db.mainContext)
            let snapshot = try TaskBackup.capture(db.mainContext)
            try require(snapshot.version == 7 && snapshot.weekTitles == [.init(week: week, title: "Week 11")], "Full backup contains week titles and protects old clients with a new version")
            let copied = try TaskBackup.decode(snapshot.encoded())
            let restored = try Store.make(url: directory.appendingPathComponent("week-titles-restored.store"))
            try copied.restore(restored.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("week-titles-restored.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<CalendarWeekTitle>()).first?.title == "Week 11", "Week title survives import and database reopen")
            var legacyJSON = try JSONSerialization.jsonObject(with: snapshot.encoded()) as! [String: Any]
            legacyJSON["version"] = 6; legacyJSON.removeValue(forKey: "weekTitles")
            let legacy = try TaskBackup.decode(JSONSerialization.data(withJSONObject: legacyJSON))
            try require(legacy.weekTitles == nil && (try legacy.merging(into: snapshot, replace: true)).weekTitles == snapshot.weekTitles,
                        "Restoring a v52 backup preserves week titles absent from its older format")
            var cleared = snapshot; cleared.weekTitles = []
            try cleared.restore(restored.mainContext, replace: true)
            try require(try restored.mainContext.fetchCount(FetchDescriptor<CalendarWeekTitle>()) == 0, "New backups explicitly restore an empty title collection")
        }
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
        #if os(macOS)
        do {
            let db = try Store.make(url: directory.appendingPathComponent("widget.store")), context = db.mainContext
            let today = Dates.calendar.startOfDay(for: date(2030, 9, 23))
            let list = TaskList(name: "Widget list"); context.insert(list)
            let timed = TaskItem(title: "Timed", scheduledAt: today.addingTimeInterval(36000), list: list); timed.hasTime = true
            let allDay = TaskItem(title: "All day", scheduledAt: today)
            let overdue = TaskItem(title: "Earlier", scheduledAt: today.addingTimeInterval(-86400))
            let ongoing = TaskItem(title: "Overnight", scheduledAt: today.addingTimeInterval(-3600)); ongoing.hasTime = true; ongoing.endAt = today.addingTimeInterval(3600)
            let midnight = TaskItem(title: "Ends at midnight", scheduledAt: today.addingTimeInterval(-7200)); midnight.hasTime = true; midnight.endAt = today
            let tomorrow = TaskItem(title: "Tomorrow", scheduledAt: today.addingTimeInterval(86400))
            let done = TaskItem(title: "Done", scheduledAt: today); done.isDone = true
            let trash = TaskItem(title: "Trash", scheduledAt: today); trash.deletedAt = today
            let undated = TaskItem(title: "No date")
            for task in [timed,allDay,overdue,ongoing,midnight,tomorrow,done,trash,undated] { context.insert(task) }
            try Store.save(context)
            if !WidgetBridge.isEnabled {
                let pending = WidgetBridge.pendingWrites
                WidgetBridge.publish(context)
                try require(WidgetBridge.pendingWrites == pending, "Disabled widgets never enqueue a publish, including direct callers")
            }
            let data = try WidgetBridge.snapshot(context)
            try require(data.today(today, calendar: Dates.calendar).map(\.id) == [ongoing.id,timed.id,allDay.id], "Widget uses today's real unfinished tasks, timed first, with continuing intervals")
            try require(data.overdue(today, calendar: Dates.calendar) == 2, "Widget counts earlier work without counting ongoing tasks twice")
            try require(data.today(today.addingTimeInterval(86400), calendar: Dates.calendar).map(\.id) == [tomorrow.id], "Widget date rollover uses saved future tasks even if app is closed")
            try require(!data.tasks.contains { $0.id == trash.id } && data.tasks.contains { $0.id == done.id && $0.isDone } && data.tasks.contains { $0.id == undated.id }, "Widget snapshot preserves completion state and undated work but excludes deleted tasks")
            try require(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(data)) == data, "Shared widget snapshot round trips without changing identifiers or dates")
            try require(WidgetSnapshot.taskID(from: URL(string: "jianshi://task/" + timed.id.uuidString)!) == timed.id,
                        "Widget task links resolve the exact stored identity")
            try require(["https://task/"+timed.id.uuidString,"jianshi://task/not-an-id","jianshi://task/"+timed.id.uuidString+"/extra","jianshi://today"].allSatisfy { WidgetSnapshot.taskID(from: URL(string: $0)!) == nil }, "Widget ignores malformed and unrelated task links")
            try require(data.rows(source: "today", date: today, showCompleted: false, calendar: Dates.calendar).map(\.id) == [midnight.id,overdue.id,ongoing.id,timed.id,allDay.id], "Today widget pins earlier unfinished work without duplicates")
            try require(data.rows(source: "all", date: today, showCompleted: false, calendar: Dates.calendar).last?.id == undated.id, "All widget includes undated work after dated tasks")
            try require(data.rows(source: list.id.uuidString, date: today).map(\.id) == [timed.id], "List widget filters by stable ID")
            try require(data.rows(source: UUID().uuidString, date: today).isEmpty, "Removed widget lists do not silently show every task")
            let child = TaskList(name: "Child"); child.parentID = list.id; context.insert(child); undated.list = child
            let nested = try WidgetBridge.snapshot(context)
            try require(Set(nested.rows(source: list.id.uuidString, date: today).map(\.id)) == Set([timed.id,undated.id]), "Widget parent lists include nested lists and undated tasks")
            try require(WidgetSnapshot.identifier(from: WidgetSnapshot.sourceURL(list.id.uuidString), host: "list") == list.id, "View all links preserve the configured list")
            try require(WidgetSnapshot.sourceURL("all").host == "all" && WidgetSnapshot.sourceURL("today").host == "today", "View all links preserve built-in scopes")
            let legacy = Data("{\"tasks\":[],\"english\":false}".utf8)
            try require(try JSONDecoder().decode(WidgetSnapshot.self, from: legacy).lists == nil, "Previous widget snapshot format stays readable")
            try require(data.rows(source: "today", date: today, calendar: Dates.calendar).last?.id == done.id, "Completed tasks remain visible after unfinished tasks by default")
            overdue.isDone = true; overdue.completedAt = today
            let finishedEarlier = try WidgetBridge.snapshot(context)
            try require(finishedEarlier.rows(source: "today", date: today, calendar: Dates.calendar).contains { $0.id == overdue.id }, "Earlier task completed today stays on today's widget")
            try require(!finishedEarlier.rows(source: "today", date: today, showCompleted: false, calendar: Dates.calendar).contains { $0.id == overdue.id }, "Hiding completed tasks removes them only after completion is saved")
            try require(!finishedEarlier.rows(source: "today", date: today.addingTimeInterval(86400), calendar: Dates.calendar).contains { $0.id == overdue.id }, "Yesterday's completed earlier task leaves today's scope at midnight")
            let noFlags = Data("{\"id\":\"\(UUID().uuidString)\",\"title\":\"Legacy\",\"timed\":false,\"priority\":0,\"list\":\"\",\"color\":\"799B80\"}".utf8)
            try require(try !JSONDecoder().decode(WidgetTask.self, from: noFlags).isDone, "Old widget rows without completion fields decode as unfinished")
            try require(WidgetPaging.page(99, count: 0, limit: 3) == 0 && WidgetPaging.page(-1, count: 8, limit: 3) == 0, "Empty and negative widget pages clamp safely")
            try require(WidgetPaging.page(2, count: 6, limit: 3) == 1 && WidgetPaging.page(1, count: 5, limit: 3) == 1, "An empty last page falls back, but a nonempty current page stays selected")
            let paged = data.rows(source: "all", date: today, calendar: Dates.calendar)
            let reunited = stride(from: 0, to: paged.count, by: 3).flatMap { Array(paged.dropFirst($0).prefix(3)) }
            try require(reunited.map(\.id) == paged.map(\.id), "Widget pagination reaches every task once, including completed and undated tasks")
            try require(WidgetPaging.key(source: "today", large: false, compact: false, showCompleted: true) != WidgetPaging.key(source: "all", large: false, compact: false, showCompleted: true), "Widget page selection stays scoped to its task range")
            timed.repeatRule = "daily"; try Store.save(context)
            try WidgetBridge.complete(timed.id, in: context)
            let count = try context.fetchCount(FetchDescriptor<TaskItem>())
            try WidgetBridge.complete(timed.id, in: context)
            try require(timed.isDone && timed.nextOccurrenceID != nil && (try context.fetchCount(FetchDescriptor<TaskItem>())) == count, "Repeated widget completion is idempotent and generates only one next occurrence")
            try WidgetBridge.complete(trash.id, in: context)
            try WidgetBridge.complete(UUID(), in: context)
            try require(!trash.isDone && trash.deletedAt != nil, "Stale widget actions never revive or complete deleted tasks")
            let reopened = try Store.make(url: directory.appendingPathComponent("widget.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<TaskItem>()).first(where: { $0.id == timed.id })?.isDone == true, "Widget completion persists to the app's own database")
        }
        #endif
        do {
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
            let relationships = schema.entities.flatMap(\.relationships)
            try require(!relationships.isEmpty && relationships.allSatisfy { $0.isOptional && !$0.isUnique && $0.deleteRule != .deny },
                        "Cloud preparation: relationships are optional, non-unique and never deny deletion")
            let attributes = schema.entities.flatMap(\.attributes).filter { !$0.isTransient }
            try require(attributes.allSatisfy { !$0.isUnique && ($0.isOptional || $0.defaultValue != nil) },
                        "Cloud preparation: persisted attributes have defaults or allow nil, with no unique constraints")
            let url = directory.appendingPathComponent("cloud-schema.store")
            let container = try Store.make(url: url), context = container.mainContext
            let list = TaskList(name: "Optional relationship"); list.tasks = nil; context.insert(list)
            let item = TaskItem(title: "Preserved task", list: list)
            item.notes = "Snapshot includes committed WAL records"; item.subtasks = [Subtask(title: "Step", isDone: true)]
            context.insert(item); try Store.save(context)
            let expected = try BackupFiles.contentData(TaskBackup.capture(context))
            let snapshot = try StoreUpgradeSnapshot.prepare(url)!
            let copy = try Store.make(url: snapshot)
            try require(try BackupFiles.contentData(TaskBackup.capture(copy.mainContext)) == expected,
                        "Pre-upgrade snapshot includes committed data while source connection is open")
            try require(try copy.mainContext.fetch(FetchDescriptor<TaskList>()).first?.tasks?.count == 1,
                        "Optional inverse relationship survives persistence and snapshot")
            let originalSnapshot = try Data(contentsOf: snapshot)
            item.title = "Later edit"; try Store.save(context)
            try require(try StoreUpgradeSnapshot.prepare(url) == snapshot && Data(contentsOf: snapshot) == originalSnapshot,
                        "Subsequent opens retain the original pre-upgrade copy")
            let nextSnapshot = try StoreUpgradeSnapshot.prepare(url, generation: "schema-next-check")!
            let nextCopy = try Store.make(url: nextSnapshot)
            try require(try nextCopy.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == "Later edit",
                        "A new schema generation captures the most recently committed data")
            try require(nextSnapshot != snapshot && (try Data(contentsOf: snapshot)) == originalSnapshot,
                        "New schema snapshots preserve earlier generations for recovery")
            context.delete(list); try Store.save(context)
            let reopened = try Store.make(url: url)
            let retained = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(retained.count == 1 && retained[0].list == nil && retained[0].subtasks == item.subtasks,
                        "Deleting an optional list preserves its task and subtasks")
            let absent = directory.appendingPathComponent("not-created.store")
            try require(try StoreUpgradeSnapshot.prepare(absent) == nil && !FileManager.default.fileExists(atPath: absent.path),
                        "Snapshot preparation never creates a missing source database")
            let corrupt = directory.appendingPathComponent("corrupt.store")
            try Data("not a database".utf8).write(to: corrupt)
            var rejected = false
            do { _ = try StoreUpgradeSnapshot.prepare(corrupt) } catch { rejected = true }
            try require(rejected && (try Data(contentsOf: corrupt)) == Data("not a database".utf8),
                        "Invalid source fails safely without modifying original bytes")
            try require(try FileManager.default.contentsOfDirectory(atPath: snapshot.deletingLastPathComponent().path).allSatisfy { !$0.contains(".partial") },
                        "Failed snapshot leaves no incomplete copy")
        }
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
        do {
            let container = try Store.make(url: directory.appendingPathComponent("large-backup.store"))
            let currentList = TaskList(name: "Existing")
            container.mainContext.insert(currentList); try Store.save(container.mainContext)
            let largeLists = (0..<1000).map { TaskBackup.ListRecord(id: UUID(), name: "List \($0)", createdAt: Date()) }
            let incoming = TaskBackup(lists: largeLists, tasks: [])
            try incoming.restore(container.mainContext, replace: false)
            try require(try TaskBackup.decode(TaskBackup.capture(container.mainContext).encoded()).lists.count == 1001,
                        "More than one thousand lists can merge, save and round-trip through backup")
            let prototype = TaskBackup.TaskRecord(TaskItem(title: "Boundary"))
            var many = (0..<10000).map { _ -> TaskBackup.TaskRecord in var record = prototype; record.id = UUID(); return record }
            let merged = try TaskBackup(lists: [], tasks: many).merging(into: TaskBackup(lists: [], tasks: [prototype]), replace: false)
            let decoded = try TaskBackup.decode(merged.encoded())
            try require(decoded.tasks.count == 10001, "More than ten thousand tasks round-trip through backup")
            let taskContainer = try Store.make(url: directory.appendingPathComponent("many-tasks.store"))
            try decoded.restore(taskContainer.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("many-tasks.store"))
            try require(try TaskBackup.capture(reopened.mainContext).tasks.count == 10001, "Large backup restores and survives database reload")
            many[0] = prototype
            try require(try TaskBackup(lists: [], tasks: many).merging(into: TaskBackup(lists: [], tasks: [prototype]), replace: false).tasks.count == 10000,
                        "Merge still deduplicates existing task identities")
            let longNote = String(repeating: "中", count: 9500)
            let bigRecords = (0..<800).map { _ -> TaskBackup.TaskRecord in var record = prototype; record.id = UUID(); record.notes = longNote; return record }
            let big = try TaskBackup(lists: [], tasks: Array(bigRecords.prefix(400))).merging(into: TaskBackup(lists: [], tasks: Array(bigRecords.suffix(400))), replace: false)
            let data = try big.encoded()
            try require(data.count > TaskBackup.largeFileThreshold, "Export is not blocked by the external large-file confirmation threshold")
            var rejected = false
            do { _ = try TaskBackup.decode(data) } catch { rejected = true }
            try require(rejected, "Unconfirmed large external files remain bounded")
            try require(try TaskBackup.decode(data, allowLargeFile: true).tasks.count == 800, "Confirmed large files decode without dropping records")
            let largeContainer = try Store.make(url: directory.appendingPathComponent("large-file-restore.store"))
            try big.restore(largeContainer.mainContext, replace: true)
            let roundTrip = try TaskBackup.capture(largeContainer.mainContext).encoded()
            try require(try TaskBackup.decode(roundTrip, allowLargeFile: true).tasks.allSatisfy { $0.notes == longNote }, "Large-file restore and re-export preserve all notes")
            let url = try BackupFiles.write(data, directory: directory.appendingPathComponent("large-automatic"), owner: "test")
            try require(try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true).tasks.count == 800, "Automatic backup accepts and verifies a file over twenty MB")
            var invalid = prototype; invalid.title = ""
            rejected = false
            do { _ = try TaskBackup(lists: [], tasks: [invalid]).merging(into: big, replace: false) } catch { rejected = true }
            try require(rejected, "Larger capacity still validates incoming records before merge")
        }
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
        do {
            let a = TaskList(name: "A"), b = TaskList(name: "B"), c = TaskList(name: "C")
            a.createdAt = Date(timeIntervalSince1970: 1); b.createdAt = Date(timeIntervalSince1970: 2)
            a.colorHex = "12abcf"; b.colorHex = "12ABCF"; c.colorHex = ListColor.presets[0].hex
            let items = [a, b, c]
            ListColor.normalize(items)
            try require(a.colorHex == "12abcf" && c.colorHex == ListColor.presets[0].hex && b.colorHex != nil, "Existing distinct colors remain; duplicate color reassigned")
            try require(Set(items.compactMap { $0.colorHex?.uppercased() }).count == 3, "Colors unique ignoring letter case")
            let colors = items.map(\.colorHex); ListColor.normalize(items)
            try require(items.map(\.colorHex) == colors, "Color normalization is stable")
            let many = (0..<60).map { TaskList(name: "List \($0)") }; ListColor.normalize(many)
            try require(Set(many.compactMap(\.colorHex)).count == 60, "Color allocation continues beyond the palette")
            try ListTree.move(c, to: a, placement: .before, lists: items)
            try require(ListNode.roots(items).map(\.id) == [c.id, a.id, b.id], "Dragging above reorders siblings")
            try ListTree.move(c, to: b, placement: .after, lists: items)
            try require(ListNode.roots(items).map(\.id) == [a.id, b.id, c.id], "Dragging below reorders siblings")
            try ListTree.move(b, to: a, placement: .inside, lists: items)
            try ListTree.move(c, to: b, placement: .inside, lists: items)
            try require(c.parentID == b.id && ListTree.path(c, lists: items) == "A / B / C", "Dragging into lists supports nested groups")
            var rejected = false
            do { try ListTree.move(a, to: c, placement: .inside, lists: items) } catch { rejected = true }
            try require(rejected && a.parentID == nil, "Cycle drop rejected without changing data")
            try ListTree.move(c, to: nil, placement: .inside, lists: items)
            try require(c.parentID == nil, "Dragging to header returns list to top level")
            c.name = "B"; rejected = false
            do { try ListTree.move(c, to: a, placement: .inside, lists: items) } catch { rejected = true }
            try require(rejected && c.parentID == nil, "Duplicate destination name rejected before mutation")
            let listURL = directory.appendingPathComponent("ordered.store")
            let container = try Store.make(url: listURL)
            items.forEach { container.mainContext.insert($0) }
            try Store.save(container.mainContext)
            let reopened = try Store.make(url: listURL)
            let persisted = try reopened.mainContext.fetch(FetchDescriptor<TaskList>())
            try require(ListNode.roots(persisted).map(\.id) == [a.id, c.id] && persisted.first { $0.id == b.id }?.parentID == a.id, "Order and hierarchy survive reopening")
            let backup = try TaskBackup.decode(TaskBackup.capture(reopened.mainContext).encoded())
            let restored = try Store.make(url: directory.appendingPathComponent("ordered-restored.store"))
            try backup.restore(restored.mainContext, replace: true)
            let copied = try restored.mainContext.fetch(FetchDescriptor<TaskList>())
            try require(ListNode.roots(copied).map(\.id) == [a.id, c.id] && copied.allSatisfy { item in persisted.first { $0.id == item.id }?.colorHex == item.colorHex }, "Backup restores ordering and distinct colors")
            let start = date(2026, 9, 20)
            let first = TaskItem(title: "Short A", scheduledAt: start); first.hasTime = true; first.endAt = start.addingTimeInterval(300)
            let second = TaskItem(title: "Short B", scheduledAt: start.addingTimeInterval(3600)); second.hasTime = true; second.endAt = start.addingTimeInterval(3900)
            try require(PlanBlock.layout([first, second], day: start).allSatisfy { $0.columns == 1 }, "Separated short tasks do not invent overlap to fit text")
            try require(PlanBlock.layout([first, second], day: start).allSatisfy { $0.end - $0.start == 5 }, "Short task layout retains actual duration")
        }
        let url = directory.appendingPathComponent("check.store")
        let taskID: UUID
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let list = TaskList(name: "测试清单")
            context.insert(list)
            let task = TaskItem(title: "查看23号的工作", scheduledAt: date(2026, 9, 23), list: list)
            task.subtasks = [Subtask(title: "准备资料")]
            task.notes = "第一行备注\n第二行备注"
            taskID = task.id
            context.insert(task)
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let task = try context.fetch(FetchDescriptor<TaskItem>()).first!
            try require(task.id == taskID && task.title == "查看23号的工作", "Persistent reload")
            try require(task.list?.name == "测试清单" && task.subtasks.first?.title == "准备资料", "Relationships and subtasks reload")
            try require(task.notes == "第一行备注\n第二行备注", "Multiline notes persist")
            task.title = "已编辑"
            task.isDone = true
            task.completedAt = Date()
            task.subtasks[0].isDone = true
            task.deletedAt = Date()
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let task = try context.fetch(FetchDescriptor<TaskItem>()).first!
            try require(task.title == "已编辑" && task.isDone && task.deletedAt != nil && task.subtasks[0].isDone, "Edit, completion, soft-delete persist")
            task.deletedAt = nil
            task.isDone = false
            context.delete(task.list!)
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let tasks = try context.fetch(FetchDescriptor<TaskItem>())
            try require(tasks.count == 1 && tasks[0].list == nil && tasks[0].deletedAt == nil && !tasks[0].isDone, "Restore and deleting list preserves tasks")
            tasks[0].title = "未保存的修改"
            context.processPendingChanges()
            context.rollback()
        }
        do {
            let container = try Store.make(url: url)
            let restored = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(restored[0].title == "已编辑", "Discarded changes do not overwrite stored data")
        }
        let january = date(2026, 1, 31)
        let february = Dates.nextRepeat(january, rule: "monthly", anchorDay: 31, after: january)!
        try require(Dates.sameDay(february, date(2026, 2, 28)), "Monthly clamps short month")
        try require(Dates.sameDay(Dates.nextRepeat(february, rule: "monthly", anchorDay: 31, after: february)!, date(2026, 3, 31)), "Monthly restores original day")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19))!, date(2026, 9, 22)), "Weekly skips missed occurrences")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "daily", anchorDay: 1, after: today)!, date(2026, 9, 20)), "Daily skips backlog")
        try require(RepeatRule("weekly")?.text == "weekly" && RepeatRule("every:2:w:4,2")?.text == "every:2:w:2,4"
                    && RepeatRule.workdays.text == "every:1:w:2,3,4,5,6" && RepeatRule("every:1:d")?.text == "daily",
                    "Repeat rules read and write old and new forms")
        try require(RepeatRule("every:0:d") == nil && RepeatRule("every:2:m:1") == nil && RepeatRule("every:1:w:") == nil
                    && RepeatRule.isValid("none") && !RepeatRule.isValid("hourly"),
                    "Malformed repeat rules are refused")
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date { Dates.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
        let friday = at(2026, 9, 18, 9)
        try require(Dates.nextRepeat(friday, rule: RepeatRule.workdays.text, anchorDay: 18, after: friday.addingTimeInterval(3600)) == at(2026, 9, 21, 9),
                    "Weekdays skip the weekend and keep the time")
        let monday = at(2026, 9, 14, 9), everyOther = "every:2:w:2,4"
        try require(Dates.nextRepeat(monday, rule: everyOther, anchorDay: 14, after: monday.addingTimeInterval(3600)) == at(2026, 9, 16, 9)
                    && Dates.nextRepeat(monday, rule: everyOther, anchorDay: 14, after: at(2026, 9, 16, 10)) == at(2026, 9, 28, 9),
                    "Every other week on Monday and Wednesday skips the week between")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "every:3:d", anchorDay: 1, after: date(2026, 9, 19))!, date(2026, 9, 22))
                    && Dates.sameDay(Dates.nextRepeat(january, rule: "every:2:m", anchorDay: 31, after: january)!, date(2026, 3, 31))
                    && Dates.sameDay(Dates.nextRepeat(date(2024, 2, 29), rule: "yearly", anchorDay: 29, after: date(2024, 2, 29))!, date(2025, 2, 28)),
                    "Every n days, every n months and yearly land on the right days")
        try require(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19), until: date(2026, 9, 20)) == nil
                    && Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19), until: date(2026, 9, 22))!, date(2026, 9, 22)),
                    "A repeat stops after its last day, which itself still counts")
        do {
            let container = try Store.make(url: directory.appendingPathComponent("until.store"))
            let context = container.mainContext
            let first = TaskItem(title: "Until", scheduledAt: date(2026, 9, 18))
            first.repeatRule = "daily"; first.repeatUntil = date(2026, 9, 19)
            context.insert(first)
            first.toggleCompletion(in: context, now: date(2026, 9, 18))
            let second = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == first.nextOccurrenceID }
            try require(second.map { Dates.sameDay($0.scheduledAt!, date(2026, 9, 19)) && $0.repeatUntil == first.repeatUntil } == true,
                        "The next time carries the end day")
            second?.toggleCompletion(in: context, now: date(2026, 9, 19))
            try require(second?.nextOccurrenceID == nil && (try context.fetchCount(FetchDescriptor<TaskItem>())) == 2, "Nothing is created past the end day")
            try Store.save(context)
            let reopened = try Store.make(url: directory.appendingPathComponent("until.store"))
            let reread = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(reread.allSatisfy { $0.repeatUntil.map { Dates.sameDay($0, date(2026, 9, 19)) } == true }, "The end day is saved")
            first.repeatRule = everyOther
            let backup = try TaskBackup.decode(try TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(first)]).encoded())
            try require(backup.tasks.first.map { $0.repeatRule == everyOther && $0.repeatUntil == first.repeatUntil } == true, "Backups keep custom repeats and end days")

            let work = TaskList(name: "Work"), home = TaskList(name: "Home")
            context.insert(work); context.insert(home)
            func add(_ title: String, _ day: Date, _ list: TaskList?, deleted: Bool = false) {
                let task = TaskItem(title: title, scheduledAt: day, list: list)
                if deleted { task.deletedAt = day }
                context.insert(task)
            }
            add("Group Meeting", date(2026, 9, 10), work)
            add("group meeting", date(2026, 9, 17), home)
            add("Meeting", date(2026, 9, 18), work)
            add("Lecture notes", date(2026, 9, 18), work, deleted: true)
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let found = TaskSuggestions.find("meet", in: all, preferredList: work.id).map(\.title)
            try require(found == ["Meeting", "group meeting"], "Suggestions keep the latest of each title, this list first")
            try require(TaskSuggestions.find("MEETING", in: all, preferredList: nil).first?.title == "Meeting"
                        && TaskSuggestions.find("lecture", in: all, preferredList: nil).isEmpty
                        && TaskSuggestions.find("  ", in: all, preferredList: nil).isEmpty,
                        "Suggestions ignore case and leave out deleted tasks")
        }
        do {
            let container = try Store.make(url: directory.appendingPathComponent("repeat.store"))
            let context = container.mainContext
            let task = TaskItem(title: "Recurring", scheduledAt: january)
            task.repeatRule = "monthly"; task.repeatAnchorDay = 31
            task.reminderAt = january.addingTimeInterval(-3600)
            task.hasTime = true; task.reminderKind = ReminderPreset.oneHour.rawValue
            task.dueAt = january.addingTimeInterval(3600); task.dueHasTime = true
            task.subtasks = [Subtask(title: "Step", isDone: true)]
            context.insert(task)
            task.toggleCompletion(in: context, now: january)
            try Store.save(context)
            let next = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == task.nextOccurrenceID }!
            try require(next.subtasks.count == 1 && !next.subtasks[0].isDone && next.repeatRule == "monthly", "Next occurrence copies and resets subtasks")
            try require(Dates.sameDay(next.reminderAt!, february) && Dates.calendar.component(.hour, from: next.reminderAt!) == 11, "Recurring reminder shifts with schedule")
            try require(next.dueHasTime && Dates.sameDay(next.dueAt!, february) && Dates.calendar.component(.hour, from: next.dueAt!) == Dates.calendar.component(.hour, from: task.dueAt!), "Deadline time persists and repeats")
            task.toggleCompletion(in: context, now: january)
            task.toggleCompletion(in: context, now: january)
            try Store.save(context)
            let count = try context.fetchCount(FetchDescriptor<TaskItem>())
            try require(count == 2, "Re-completion does not duplicate next occurrence")
            next.reschedule(to: date(2026, 3, 5), extendingDeadline: true)
            try require(Dates.sameDay(next.calendarDate!, date(2026, 3, 5)) && Dates.calendar.component(.hour, from: next.calendarDate!) == 12 && Dates.sameDay(next.reminderAt!, date(2026, 3, 5)), "Reschedule preserves time and moves reminder")
            next.deletedAt = today; try Store.save(context)
            next.deletedAt = nil; try Store.save(context)
            let reloaded = try Store.make(url: directory.appendingPathComponent("repeat.store"))
            let saved = try reloaded.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(saved.count == 2 && saved.allSatisfy { $0.deletedAt == nil } && saved.contains { $0.nextOccurrenceID != nil }, "Undo and repeat linkage persist")
        }
        do {
            let c = try Store.make(url: directory.appendingPathComponent("regressions.store"))
            let context = c.mainContext
            let base = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9))!
            let done = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 8, minute: 30))!
            let task = TaskItem(title: "Daily", scheduledAt: base)
            task.hasTime = true; task.repeatRule = "daily"; task.reminderAt = base.addingTimeInterval(-3600); task.reminderKind = "oneHour"
            context.insert(task); task.toggleCompletion(in: context, now: done); try Store.save(context)
            let next = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == task.nextOccurrenceID }!
            try require(next.reminderNeedsAttention && next.reminderAt! < done && next.calendarDate! > done, "Past next reminder explicitly requires attention")
            let custom = TaskItem(title: "Custom", scheduledAt: base)
            custom.reminderAt = ReminderPreset.morning.date(base: base, timed: false); custom.reminderKind = "custom"
            context.insert(custom); try Store.save(context)
            let reload = try Store.make(url: directory.appendingPathComponent("regressions.store"))
            let read = try reload.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == custom.id }!
            try require(read.resolvedReminderPreset == .custom, "Custom reminder choice persists even when matching a preset")
            let originalReminder = read.reminderAt
            read.reschedule(to: date(2026, 9, 20))
            try require(read.reminderAt == originalReminder, "Dragging preserves fixed custom reminder")
            let monthly = TaskItem(title: "Month", scheduledAt: february)
            monthly.repeatRule = "monthly"; monthly.repeatAnchorDay = 31
            let preview = Dates.nextRepeat(february, rule: "monthly", anchorDay: monthly.repeatAnchor(for: february, rule: "monthly"), after: february)
            try require(Dates.sameDay(preview!, date(2026, 3, 31)), "Monthly hint uses saved anchor")
            let deadline = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 14))!
            try require(DeadlineCountdown(due: deadline, timed: true, now: deadline.addingTimeInterval(-1)).level == .today && DeadlineCountdown(due: deadline, timed: true, now: deadline.addingTimeInterval(1)).level == .overdue, "Deadline transitions without changing task data")
            let nextDue = Dates.nextRepeat(deadline, rule: "daily", anchorDay: 17, after: Dates.calendar.date(byAdding: .hour, value: 20, to: deadline)!)!
            try require(Dates.sameDay(nextDue, date(2026, 9, 18)) && Dates.calendar.component(.hour, from: nextDue) == 14, "Deadline-only recurrence retains time")

            let list = TaskList(name: "Backup list"); list.colorHex = "12ABCF"; context.insert(list)
            task.list = list; task.notes = "Notes\nline two"; task.subtasks = [Subtask(title: "Step", isDone: true)]; task.deletedAt = done
            try Store.save(context)
            let backup = try TaskBackup.capture(context)
            let data = try backup.encoded()
            let automatic = directory.appendingPathComponent("automatic-versions")
            try FileManager.default.createDirectory(at: automatic, withIntermediateDirectories: true)
            let manual = automatic.appendingPathComponent("manual.json")
            try data.write(to: manual)
            let other = try BackupFiles.write(data, directory: automatic, owner: "another-device")
            var latest: URL?
            for _ in 0..<35 { latest = try BackupFiles.write(data, directory: automatic, owner: "test-device") }
            let owned = try FileManager.default.contentsOfDirectory(at: automatic, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Jianshi-Auto-test-device-") }
            try require(owned.count == 1 && owned.contains { $0.lastPathComponent == latest!.lastPathComponent }, "Rapid saves retain only the latest version in an hour")
            try require(FileManager.default.fileExists(atPath: manual.path) && FileManager.default.fileExists(atPath: other.path),
                        "Automatic retention preserves manual backups and other devices")
            let legacyExtra = automatic.appendingPathComponent(latest!.lastPathComponent.replacingOccurrences(of: ".json", with: "-old.json"))
            try data.write(to: legacyExtra)
            let stableDate = try BackupFiles.save(backup, directory: automatic, owner: "test-device")
            var reordered = backup; reordered.createdAt = Date().addingTimeInterval(100)
            reordered.tasks.reverse(); reordered.lists.reverse()
            let duplicateDate = try BackupFiles.save(reordered, directory: automatic, owner: "test-device")
            try require(stableDate == duplicateDate && (try? BackupFiles.ownedFiles(directory: automatic, owner: "test-device").count) == 1,
                        "Relaunch deduplication ignores capture date and fetch order using the on-disk snapshot")
            latest = try BackupFiles.ownedFiles(directory: automatic, owner: "test-device").first?.url
            let now = Dates.calendar.date(bySettingHour: 23, minute: 50, second: 0, of: date(2026, 9, 20))!
            var history: [(url: URL, date: Date)] = []
            for age in 0..<16 {
                let day = Dates.calendar.date(byAdding: .day, value: -age, to: now)!
                for hour in 0..<24 {
                    for minute in [10, 40] {
                        let stamp = Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
                        history.append((directory.appendingPathComponent("\(age)-\(hour)-\(minute).json"), stamp))
                    }
                }
            }
            let newest = history[47].url
            let keep = BackupFiles.retained(history, now: now, newest: newest, calendar: Dates.calendar)
            let kept = history.filter { keep.contains($0.url.lastPathComponent) }
            try require(kept.count == 23 && kept.filter { Dates.sameDay($0.date, now) }.count == 10,
                        "Time retention keeps ten hourly versions today plus thirteen daily versions")
            try require(Set(kept.map { Dates.calendar.startOfDay(for: $0.date) }).count == 14,
                        "A burst of edits cannot evict the previous thirteen days")
            try require(kept.allSatisfy { $0.date >= Dates.calendar.startOfDay(for: date(2026, 9, 7)) }
                        && kept.allSatisfy { Dates.calendar.component(.minute, from: $0.date) == 40 },
                        "Retention picks the newest version per time bucket and excludes days older than fourteen days")
            let sole = history.last!
            try require(BackupFiles.retained([sole], now: now, newest: sole.url).contains(sole.url.lastPathComponent),
                        "The only known good backup is not discarded after a long inactive period")
            let boundary = date(2027, 1, 1)
            let monthBoundary = [(directory.appendingPathComponent("yesterday.json"), date(2026, 12, 31)),
                                 (directory.appendingPathComponent("today.json"), boundary)]
            try require(BackupFiles.retained(monthBoundary, now: boundary, newest: monthBoundary[1].0).count == 2,
                        "Daily history survives year and month boundaries")
            let automaticDecoded = try TaskBackup.decode(Data(contentsOf: latest!))
            try require(automaticDecoded.tasks.count == backup.tasks.count && automaticDecoded.lists.count == backup.lists.count,
                        "Automatic files use the complete portable restore format")
            let external = directory.appendingPathComponent("external-folder")
            let externalFile = try BackupFiles.write(data, directory: external, owner: "test-device")
            try require(try Data(contentsOf: externalFile) == data, "External copy has exactly the same portable bytes")
            var rejectedAuto = false
            do { _ = try BackupFiles.write(Data("broken".utf8), directory: automatic, owner: "test-device") }
            catch { rejectedAuto = true }
            try require(rejectedAuto && (try? Data(contentsOf: latest!)) == data, "Invalid snapshot never prunes a previous backup")
            var failedExternal = false
            do { _ = try BackupFiles.write(data, directory: manual, owner: "test-device") }
            catch { failedExternal = true }
            try require(failedExternal && (try? Data(contentsOf: latest!)) == data, "External write failure leaves local history readable")

            let decoded = try TaskBackup.decode(data)
            try require(decoded.tasks.count == 3 && decoded.lists.count == 1, "Backup roundtrip counts")
            try require(decoded.lists.first?.colorHex == "12ABCF", "Backup captures custom list color")
            var legacyJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var legacyLists = legacyJSON["lists"] as! [[String: Any]]
            legacyLists[0].removeValue(forKey: "colorHex"); legacyJSON["lists"] = legacyLists
            let legacyColor = try TaskBackup.decode(JSONSerialization.data(withJSONObject: legacyJSON))
            try require(legacyColor.lists.first?.colorHex == nil, "Old backups without colors remain compatible")
            var invalidColor = decoded; invalidColor.lists[0].colorHex = "not-rgb"
            var colorRejected = false
            do { try invalidColor.validate() } catch { colorRejected = true }
            try require(colorRejected, "Invalid backup colors rejected before restore")
            let target = try Store.make(url: directory.appendingPathComponent("restored.store"))
            try decoded.restore(target.mainContext, replace: true)
            let restoredContainer = try Store.make(url: directory.appendingPathComponent("restored.store"))
            let restored = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            let restoredTask = restored.first { $0.id == task.id }!
            try require(restoredTask.notes == task.notes && restoredTask.subtasks == task.subtasks && restoredTask.list?.id == list.id && restoredTask.deletedAt != nil && restoredTask.isDone && restoredTask.nextOccurrenceID == next.id, "Full restore retains metadata, relationships, history and trash")
            try require(restored.first { $0.id == custom.id }?.reminderKind == "custom", "Backup retains reminder choice")
            try require(restoredTask.list?.colorHex == "12ABCF", "Custom color survives restore and store reopening")
            restoredTask.title = "Local edit"; try Store.save(restoredContainer.mainContext)
            try decoded.restore(restoredContainer.mainContext, replace: false)
            let merged = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(merged.count == 3 && merged.first { $0.id == task.id }?.title == "Local edit", "Merge is idempotent and keeps local changes")
            let extra = TaskItem(title: "Extra"); restoredContainer.mainContext.insert(extra); try Store.save(restoredContainer.mainContext)
            try decoded.restore(restoredContainer.mainContext, replace: true)
            let replaced = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(replaced.count == 3 && !replaced.contains { $0.id == extra.id }, "Replacement removes extra items")
            var invalid = decoded; invalid.version = 999
            var rejected = false
            do { try invalid.restore(restoredContainer.mainContext, replace: true) } catch { rejected = true }
            try require(rejected, "Unknown version rejected")
            invalid = decoded; invalid.tasks.append(invalid.tasks[0])
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Duplicate identifiers rejected")
            invalid = decoded; invalid.tasks[0].listID = UUID()
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Missing list reference rejected")
            rejected = false
            do { _ = try TaskBackup.decode(Data("{broken".utf8)) } catch { rejected = true }
            try require(rejected, "Malformed JSON rejected")
            invalid = decoded; invalid.tasks[0].createdAt = Date(timeIntervalSince1970: 1e200)
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Out-of-range dates rejected before rendering")
            let afterInvalid = try restoredContainer.mainContext.fetchCount(FetchDescriptor<TaskItem>())
            try require(afterInvalid == 3, "Rejected imports leave stored data intact")
        }
        // Planning views use the same ordering and scheduling rules as task lists.
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
        do {
            let root = TaskList(name: "Work"), child = TaskList(name: "Project"), leaf = TaskList(name: "Sprint")
            child.parentID = root.id; leaf.parentID = child.id
            let tree = [root, child, leaf]
            try require(ListTree.contains(leaf.id, in: root.id, lists: tree), "Group includes nested descendants")
            try require(!ListTree.contains(root.id, in: leaf.id, lists: tree), "Group membership is directional")
            try require(ListTree.path(leaf, lists: tree) == "Work / Project / Sprint", "Nested path disambiguates list names")
            try ListTree.validate(Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0.parentID) }))
            var rejected = false
            do { try ListTree.validate([root.id: child.id, child.id: root.id]) } catch { rejected = true }
            try require(rejected, "Hierarchy cycles rejected")
            rejected = false
            do { try ListTree.validate([root.id: UUID()]) } catch { rejected = true }
            try require(rejected, "Orphan hierarchy rejected")
            let start = date(2026, 9, 20)
            let task = TaskItem(title: "Three hours", scheduledAt: start); task.hasTime = true; task.endAt = start.addingTimeInterval(10800)
            let originalSchedule = TaskSchedule(task)
            task.schedule(at: start.addingTimeInterval(7200))
            task.title = "Edited title"
            originalSchedule.restore(task)
            try require(TaskSchedule(task) == originalSchedule && task.title == "Edited title", "Undo restores schedule without overwriting other task fields")
            task.schedule(at: start.addingTimeInterval(3600))
            try require(task.duration == 10800 && task.endAt == start.addingTimeInterval(14400), "Time drag preserves duration")
            task.reschedule(to: date(2026, 9, 22))
            try require(task.duration == 10800 && Dates.sameDay(task.endAt!, date(2026, 9, 22)), "Date drag preserves duration")
            task.dueAt = task.scheduledAt!.addingTimeInterval(7200); task.dueHasTime = true
            try require(task.timeConflict(at: task.scheduledAt!), "Deadline checks ending, not only start")
            let overnight = TaskItem(title: "Overnight", scheduledAt: Dates.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: start)); overnight.hasTime = true; overnight.endAt = overnight.scheduledAt!.addingTimeInterval(10800)
            let blocks = PlanBlock.layout([overnight], day: date(2026, 9, 21))
            try require(blocks.count == 1 && blocks[0].start == 0 && blocks[0].end == 120, "Overnight clipped onto following day")
            let firstSegment = PlanBlock.layout([overnight], day: start)[0]
            try require(!firstSegment.canResize(on: start) && blocks[0].canResize(on: date(2026, 9, 21)), "Only the real ending segment can resize an overnight task")
            let midnight = Dates.calendar.startOfDay(for: date(2026, 9, 21))
            try require(!overnight.isOverdue(today: midnight.addingTimeInterval(3600)), "An ongoing overnight task is not overdue at 01:00")
            try require(overnight.isOverdue(today: midnight.addingTimeInterval(10800)), "An unfinished overnight task becomes overdue after ending")
            let shortA = TaskItem(title: "Short A", scheduledAt: start); shortA.hasTime = true; shortA.endAt = start.addingTimeInterval(300)
            let shortB = TaskItem(title: "Short B", scheduledAt: start.addingTimeInterval(900)); shortB.hasTime = true; shortB.endAt = start.addingTimeInterval(1200)
            let shortBlocks = PlanBlock.layout([shortA, shortB], day: start)
            try require(shortBlocks.allSatisfy { $0.column == 0 && $0.columns == 1 }, "Nonoverlapping short intervals share a full-width lane")
            let point = TaskItem(title: "A point, not a booked interval", scheduledAt: start); point.hasTime = true
            let pointBlocks = PlanBlock.layout([point], day: start)
            try require(PlanBlock.freeTime(pointBlocks, from: 0, to: 1440).free == 1440, "Start-only tasks do not invent occupied time")
            shortA.isDone = true
            try require(PlanBlock.freeTime(PlanBlock.layout([shortA], day: start), from: 0, to: 1440).free == 1435, "Completing a task retains its booked interval")
            let a = TaskItem(title: "A", scheduledAt: start); a.hasTime = true; a.endAt = start.addingTimeInterval(10800)
            let b = TaskItem(title: "B", scheduledAt: start.addingTimeInterval(3600)); b.hasTime = true; b.endAt = start.addingTimeInterval(7200)
            let overlap = PlanBlock.layout([a,b], day: start)
            try require(overlap.count == 2 && overlap.allSatisfy { $0.columns == 2 } && overlap[0].column != overlap[1].column, "Overlapping blocks have distinct lanes")
            b.scheduledAt = a.endAt; b.endAt = b.scheduledAt!.addingTimeInterval(3600)
            try require(PlanBlock.layout([a,b], day: start).allSatisfy { $0.columns == 1 }, "Touching intervals do not overlap")
            let backup = TaskBackup(lists: tree.map { TaskBackup.ListRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID) }, tasks: [TaskBackup.TaskRecord(overnight)])
            let decoded = try TaskBackup.decode(backup.encoded())
            try require(decoded.lists.last?.parentID == child.id && decoded.tasks.first?.endAt == overnight.endAt, "Backup preserves nested lists and intervals")
            let intervalURL = directory.appendingPathComponent("intervals.store")
            let intervalStore = try Store.make(url: intervalURL)
            try decoded.restore(intervalStore.mainContext, replace: true)
            let restoredStore = try Store.make(url: intervalURL)
            let restoredLists = try restoredStore.mainContext.fetch(FetchDescriptor<TaskList>())
            let restoredTask = try restoredStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
            try require(restoredLists.first { $0.id == leaf.id }?.parentID == child.id && restoredTask.duration == 10800, "Restored hierarchy and interval survive reload")
            restoredTask.repeatRule = "daily"; restoredTask.toggleCompletion(in: restoredStore.mainContext, now: restoredTask.scheduledAt!)
            try Store.save(restoredStore.mainContext)
            let next = try restoredStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == restoredTask.nextOccurrenceID }!
            try require(next.duration == 10800, "Repeated task preserves overnight duration")
            var old = backup; old.version = 1; old.lists = []; old.tasks[0].endAt = nil
            let oldDecoded = try TaskBackup.decode(old.encoded())
            try require(oldDecoded.version == 1 && oldDecoded.tasks.first?.endAt == nil, "Legacy backup still accepted")
            var broken = backup; broken.tasks[0].endAt = overnight.scheduledAt
            rejected = false; do { try broken.validate() } catch { rejected = true }
            try require(rejected, "Backup rejects non-positive interval")
        }
        do {
            // --- timeline span, density and the "now" mapping ---
            let day = date(2026, 9, 20)
            func block(_ fromHour: Int, _ fromMinute: Int, _ hours: Double) -> PlanBlock {
                let begin = Dates.calendar.date(bySettingHour: fromHour, minute: fromMinute, second: 0, of: day)!
                let task = TaskItem(title: "Block", scheduledAt: begin)
                task.hasTime = true; task.endAt = begin.addingTimeInterval(hours * 3600)
                return PlanBlock.layout([task], day: day)[0]
            }
            let empty = TimelineLayout.make(blocks: [], fullDay: false, density: 1.2)
            try require(empty.startMinute == 360 && empty.endMinute == 1320, "An empty day shows 6:00–22:00 instead of all 24 hours")
            try require(empty.height < 1200, "A standard day is shorter than one screen and a half")
            try require(TimelineLayout.make(blocks: [], fullDay: true, density: 1.2).startMinute == 0
                        && TimelineLayout.make(blocks: [], fullDay: true, density: 1.2).endMinute == 1440, "Full day still available")
            let early = TimelineLayout.make(blocks: [block(5, 30, 1)], fullDay: false, density: 1.2)
            try require(early.startMinute == 300, "The span widens to hold an early task")
            let late = TimelineLayout.make(blocks: [block(22, 0, 1)], fullDay: false, density: 1.2)
            try require(late.endMinute == 1440, "The span widens to hold a late task, with room to drag it longer")
            let night = TimelineLayout.make(blocks: [block(23, 0, 0.5)], fullDay: false, density: 1.2)
            try require(night.endMinute == 1440, "Headroom never runs past midnight")
            let withNow = TimelineLayout.make(blocks: [], fullDay: false, density: 1.2, nowMinute: 5 * 60 + 10)
            try require(withNow.startMinute <= 300, "The current hour is always inside the span")
            try require(empty.hours.first == 360 && empty.hours.allSatisfy { $0 % 60 == 0 && $0 >= empty.startMinute && $0 < empty.endMinute }, "Hour labels stay inside the span")
            try require(empty.y(Double(empty.startMinute)) == 0 && empty.y(Double(empty.startMinute + 60)) == 72, "A minute maps to a fixed height")
            try require(empty.snapped(empty.y(Double(7 * 60 + 8))) == 7 * 60, "A tap lands on the quarter hour above it")
            try require(empty.snapped(-500) == empty.startMinute && empty.snapped(99999) == empty.endMinute - 15, "Taps outside the canvas stay inside the day")
            let dense = TimelineLayout.make(blocks: [], fullDay: true, density: 0.6)
            try require(dense.height < TimelineLayout.make(blocks: [], fullDay: true, density: 2.0).height, "Compact is shorter than roomy")

            // --- free time under the timeline ---
            let busy = [block(9, 0, 2), block(13, 0, 1)]
            let free = PlanBlock.freeTime(busy, from: 360, to: 1320)
            try require(free.free == 960 - 180, "Free minutes exclude every planned block")
            try require(free.longest.map { $0.start == 14 * 60 && $0.end == 22 * 60 } == true, "The longest gap is the one after the last block")
            let backToBack = PlanBlock.freeTime([block(9, 0, 1), block(9, 30, 1)], from: 540, to: 660)
            try require(backToBack.free == 30, "Overlapping blocks are not counted twice")
            try require(PlanBlock.freeTime([], from: 360, to: 1320).longest.map { $0.end - $0.start } == 960, "An empty day is one long gap")
            try require(Dates.durationLabel(minutes: 210) == "3 小时 30 分" && Dates.durationLabel(minutes: 45) == "45 分钟" && Dates.durationLabel(minutes: 120) == "2 小时", "Duration reads as hours and minutes")

            // --- dragging the lower edge of a block ---
            let start = Dates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
            let meeting = TaskItem(title: "Meeting", scheduledAt: start); meeting.hasTime = true; meeting.endAt = start.addingTimeInterval(3600)
            try require(meeting.resize(to: start.addingTimeInterval(5400)) && meeting.duration == 5400, "Dragging the edge changes the length")
            try require(!meeting.resize(to: start) && !meeting.resize(to: start.addingTimeInterval(-600)) && meeting.duration == 5400, "A block cannot end before it starts")
            meeting.dueAt = start.addingTimeInterval(7200); meeting.dueHasTime = true
            try require(!meeting.resize(to: start.addingTimeInterval(10800)) && meeting.duration == 5400, "A block cannot be dragged past its deadline")
            try require(meeting.resize(to: start.addingTimeInterval(7200)) && meeting.duration == 7200, "Up to the deadline is allowed")
            let allDay = TaskItem(title: "All day", scheduledAt: day)
            try require(!allDay.resize(to: day.addingTimeInterval(3600)), "A task without a time has no edge to drag")

            // --- search filters ---
            let work = TaskList(name: "Work"), project = TaskList(name: "Project")
            project.parentID = work.id
            let catalogue = [work, project]
            let filed = TaskItem(title: "Filed", scheduledAt: date(2026, 9, 20)); filed.list = project; filed.priority = 2
            let loose = TaskItem(title: "Loose")
            var chosen = TaskFilter()
            try require(!chosen.isActive && chosen.matches(filed, lists: catalogue, today: day) && chosen.matches(loose, lists: catalogue, today: day), "No filter hides nothing")
            chosen.list = .list(work.id)
            try require(chosen.matches(filed, lists: catalogue, today: day) && !chosen.matches(loose, lists: catalogue, today: day), "A group filter includes its child lists")
            chosen.list = .unfiled
            try require(!chosen.matches(filed, lists: catalogue, today: day) && chosen.matches(loose, lists: catalogue, today: day), "Unfiled finds tasks without a list")
            chosen = TaskFilter(); chosen.priority = 2
            try require(chosen.matches(filed, lists: catalogue, today: day) && !chosen.matches(loose, lists: catalogue, today: day), "Priority filter")
            chosen = TaskFilter(); chosen.span = .today
            try require(chosen.matches(filed, lists: catalogue, today: day) && !chosen.matches(filed, lists: catalogue, today: date(2026, 9, 21)), "Today filter follows the day")
            chosen.span = .week
            try require(chosen.matches(filed, lists: catalogue, today: date(2026, 9, 16)) && !chosen.matches(filed, lists: catalogue, today: date(2026, 9, 28)), "This week covers Monday to Sunday")
            chosen.span = .month
            try require(chosen.matches(filed, lists: catalogue, today: date(2026, 9, 1)) && !chosen.matches(filed, lists: catalogue, today: date(2026, 10, 1)), "This month filter")
            chosen.span = .undated
            try require(chosen.matches(loose, lists: catalogue, today: day) && !chosen.matches(filed, lists: catalogue, today: day), "Undated filter")
            chosen.span = .overdue
            try require(chosen.matches(filed, lists: catalogue, today: date(2026, 9, 22)) && !chosen.matches(filed, lists: catalogue, today: day), "Overdue filter")
            try require(TaskFilter(list: .unfiled, priority: 1, span: .today).count == 3, "The badge counts every active filter")
        }
        do {
            // --- dragging a task out of the timeline ---
            let day = date(2026, 9, 21)
            let start = Dates.calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day)!
            let timed = TaskItem(title: "Timed", scheduledAt: start); timed.hasTime = true; timed.endAt = start.addingTimeInterval(3600)
            timed.reminderAt = start.addingTimeInterval(-600); timed.reminderKind = ReminderPreset.tenMinutes.rawValue
            timed.makeAllDay(on: date(2026, 9, 22))
            try require(!timed.hasTime && timed.endAt == nil && timed.clockDate == nil && Dates.sameDay(timed.scheduledAt!, date(2026, 9, 22)), "All-day row keeps the day and removes the time")
            try require(timed.reminderAt == start.addingTimeInterval(-600) && timed.resolvedReminderPreset == .custom, "A reminder that no longer fits is kept as a custom time")
            let morning = TaskItem(title: "Morning", scheduledAt: start); morning.hasTime = true
            morning.reminderAt = Dates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day); morning.reminderKind = ReminderPreset.morning.rawValue
            morning.makeAllDay(on: date(2026, 9, 23))
            try require(morning.reminderAt.map { Dates.sameDay($0, date(2026, 9, 23)) } == true, "A day reminder follows the new day")
            let loose = TaskItem(title: "Loose", scheduledAt: start); loose.hasTime = true; loose.endAt = start.addingTimeInterval(1800)
            try require(loose.clearSchedule() && loose.calendarDate == nil && !loose.hasTime && loose.endAt == nil, "Undated list removes date and time")
            let due = TaskItem(title: "Due", scheduledAt: start); due.dueAt = date(2026, 9, 25)
            let repeating = TaskItem(title: "Repeat", scheduledAt: start); repeating.repeatRule = "weekly"
            try require(!due.clearSchedule() && due.scheduledAt == start && !repeating.clearSchedule() && repeating.scheduledAt == start, "Deadline or repeat keeps its date")
        }
        do {
            // --- Mac week view drag: where the pointer is and what time it means ---
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            // Scrolled 900 points down: the grid shows roughly 12:30–19:25.
            let geometry = WeekDropGeometry(canvas: CGRect(x: 0, y: -800, width: 744, height: 1728),
                                            viewport: CGRect(x: 0, y: 100, width: 744, height: 500),
                                            allDay: CGRect(x: 0, y: 60, width: 744, height: 30),
                                            undated: CGRect(x: 760, y: 40, width: 190, height: 560), layout: layout)
            let wednesday = 44.0 + 2 * 100 + 50
            let sixPM = -800.0 + 18 * 72
            // Picked up 100 points below its top edge: it keeps that spot instead of jumping to the pointer.
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: sixPM + 100), grabOffset: 100, durationMinutes: 120) == .timed(day: 2, minute: 18 * 60),
                        "A dragged task keeps the spot it was grabbed by")
            try require(geometry.minute(pointerY: sixPM + 8, grabOffset: 0, durationMinutes: 60) == 18 * 60
                        && geometry.minute(pointerY: sixPM + 10, grabOffset: 0, durationMinutes: 60) == 18 * 60 + 15,
                        "The start snaps to the nearest quarter hour")
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: 75), grabOffset: 0, durationMinutes: 60) == .allDay(2)
                        && geometry.zone(pointer: CGPoint(x: 20, y: 75), grabOffset: 0, durationMinutes: 60) == .none,
                        "The all-day row takes a day; its label does not")
            try require(geometry.zone(pointer: CGPoint(x: 800, y: 300), grabOffset: 0, durationMinutes: 60) == .undated,
                        "The undated list is a drop target")
            try require(geometry.zone(pointer: CGPoint(x: 10, y: 300), grabOffset: 0, durationMinutes: 60) == .none,
                        "Releasing at the hour gutter never moves a task by a week")
            if case .timed(day: 6, minute: _) = geometry.zone(pointer: CGPoint(x: 734, y: 300), grabOffset: 0, durationMinutes: 60) {
                try require(true, "Sunday right edge remains a same-week drop before dwelling")
            } else { try require(false, "Sunday right edge remains available") }
            var hover = WeekEdgeHover()
            try require(hover.step(direction: 1, now: 0) == 0 && hover.step(direction: 1, now: 0.4) == 0,
                        "Passing an edge does not turn a week")
            try require(hover.step(direction: 1, now: 0.7) == 1 && hover.step(direction: 1, now: 1.0) == 0
                        && hover.step(direction: 1, now: 1.7) == 1, "Dwelling turns weeks with a repeat delay")
            try require(hover.step(direction: 0, now: 1.8) == 0 && hover.step(direction: -1, now: 1.9) == 0
                        && hover.step(direction: -1, now: 2.6) == -1, "Leaving resets edge dwell")
            var edged = geometry; edged.trailing = 20
            try require(edged.edgeDirection(pointer: CGPoint(x: 10, y: 300)) == -1
                        && edged.edgeDirection(pointer: CGPoint(x: 734, y: 300)) == 1,
                        "The hour column and the strip right of Sunday turn weeks")
            try require(edged.edgeDirection(pointer: CGPoint(x: 700, y: 300)) == 0
                        && edged.edgeDirection(pointer: CGPoint(x: 60, y: 300)) == 0
                        && edged.edgeDirection(pointer: CGPoint(x: 734, y: 75)) == 0,
                        "Monday, Sunday and the all-day row are never week edges")
            if case .timed(day: 6, minute: _) = edged.zone(pointer: CGPoint(x: 700, y: 300), grabOffset: 0, durationMinutes: 60) {
                try require(edged.zone(pointer: CGPoint(x: 734, y: 300), grabOffset: 0, durationMinutes: 60) == .none,
                            "Sunday stays a drop target; letting go on the next-week strip does nothing")
            } else { try require(false, "Sunday stays a drop target with the next-week strip beside it") }
            try require(abs(WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 128), viewport: geometry.viewport)) < 1
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 75), viewport: geometry.viewport) == 0,
                        "Near the band's inner edge scrolling is barely moving; the all-day row never scrolls")
            try require(WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 105), viewport: geometry.viewport) < 0
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 595), viewport: geometry.viewport) > 0
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 300), viewport: geometry.viewport) == 0,
                        "Top and bottom edges scroll in opposite directions; center stops")
                        try require(geometry.scrollSpeed(pointer: CGPoint(x: 300, y: 40)) == -10
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 300, y: -200)) == -10
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 300, y: 75)) == 0
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 800, y: 50)) == 0,
                                    "Above the all-day row scrolls up at full speed; the all-day row and the undated list never scroll")
            let monthGrid = MonthDropGeometry(canvas: CGRect(x: 100, y: 100, width: 700, height: 500),
                                              viewport: CGRect(x: 100, y: 100, width: 700, height: 500),
                                              inMonth: Array(repeating: false, count: 2) + Array(repeating: true, count: 31) + Array(repeating: false, count: 2))
            try require(monthGrid.edgeDirection(pointer: CGPoint(x: 40, y: 300)) == -1
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 900, y: 300)) == 1
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 105, y: 300)) == 0
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 795, y: 300)) == 0
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 40, y: 50)) == 0,
                        "Month pages turn only beside the month; Monday and Sunday stay whole")
            try require(monthGrid.zone(pointer: CGPoint(x: 350, y: 150)) == .day(2)
                        && monthGrid.zone(pointer: CGPoint(x: 750, y: 450)) == .day(27)
                        && monthGrid.zone(pointer: CGPoint(x: 150, y: 150)) == .none
                        && monthGrid.zone(pointer: CGPoint(x: 795, y: 595)) == .none
                        && monthGrid.zone(pointer: CGPoint(x: 900, y: 300)) == .none,
                        "A month drop lands on the day under the pointer; blank cells and the edges take nothing")
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: 700), grabOffset: 0, durationMinutes: 60) == .none,
                        "Letting go outside the week changes nothing")
            try require(geometry.minute(pointerY: -850, grabOffset: 0, durationMinutes: 120) == -45
                        && geometry.minute(pointerY: 99999, grabOffset: 0, durationMinutes: 60) == 1425,
                        "A task may start before midnight but always stays partly on the grid")

            #if os(macOS)
            // AppKit pointer sessions are not used by iOS native drag and drop.
            let session = WeekDrag()
            session.canvas = geometry.canvas; session.viewport = geometry.viewport; session.layout = layout
            let dragTask = TaskItem(title: "Edge session", scheduledAt: date(2026, 9, 18))
            let original = TaskSchedule(dragTask)
            var receivedOffset: Int?
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.7)
            try require(session.weekOffset == 1 && TaskSchedule(dragTask) == original, "Hover previews another week without changing a task")
            session.move(to: CGPoint(x: wednesday, y: sixPM))
            session.complete()
            try require(receivedOffset == 1 && session.weekOffset == 0 && !session.isDragging, "Release delivers preview week then clears drag state")
            // Repeat the same source gesture without delivering its old onEnded callback.
            var gestureDrops = 0
            for _ in 0..<3 {
                session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                      point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
                try require(session.isDragging && session.zone != .none, "Same source can start another drag after native completion")
                session.complete()
            }
            try require(gestureDrops == 3, "Consecutive gestures each deliver exactly one drop")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.cancel()
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM - 30)) { _, _ in gestureDrops += 1 }
            try require(session.cancelled && session.zone == .none, "Escape stays cancelled through later gesture samples")
            session.samplePointer(at: CGPoint(x: -100, y: -100), pressed: false)
            try require(session.taskID == nil, "Releasing a cancelled drag outside clears the session")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.complete()
            try require(gestureDrops == 4, "Next gesture recovers after cancellation without a source callback")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in gestureDrops += 1 }
            session.move(to: CGPoint(x: 734, y: 300)); session.tick(now: 0); session.tick(now: 0.7)
            try require(!session.checkPhysicalButton(pressed: false, now: 1), "Missing release stops edge work immediately")
            _ = session.checkPhysicalButton(pressed: false, now: 1.2)
            session.tick(now: 10)
            try require(session.cancelled && session.weekOffset == 0 && session.zone == .none, "Release watchdog cancels and stops recurring page turns")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0, point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.complete()
            try require(gestureDrops == 4 && session.taskID == nil, "Late motion and release never commit an abandoned task")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in gestureDrops += 1 }
            session.move(to: CGPoint(x: wednesday, y: sixPM))
            _ = session.checkPhysicalButton(pressed: false, now: 1)
            try require(session.checkPhysicalButton(pressed: true, now: 1.02) && session.isDragging,
                        "A transient physical-button sample does not cancel a healthy gesture")
            session.complete()
            try require(gestureDrops == 5, "Normal release still commits exactly once after watchdog sampling")
            #endif
            let rowA = UUID(), rowB = UUID()
            let listRows = [rowA: CGRect(x: 0, y: 100, width: 180, height: 28), rowB: CGRect(x: 0, y: 128, width: 180, height: 28)]
            let listHeader = CGRect(x: 0, y: 70, width: 180, height: 24)
            func listTarget(_ y: Double, blocked: UUID? = nil) -> (UUID?, ListTree.Placement)? {
                ListTree.dropTarget(pointer: CGPoint(x: 60, y: y), rows: listRows, header: listHeader, blocked: { $0 == blocked }).map { ($0.list, $0.placement) }
            }
            try require(listTarget(102).map { $0.0 == rowA && $0.1 == .before } == true
                        && listTarget(114).map { $0.0 == rowA && $0.1 == .inside } == true
                        && listTarget(126).map { $0.0 == rowA && $0.1 == .after } == true
                        && listTarget(140).map { $0.0 == rowB && $0.1 == .inside } == true,
                        "A dragged list goes above, into or below the row under the pointer")
            try require(listTarget(80).map { $0.0 == nil && $0.1 == .before } == true && listTarget(114, blocked: rowA) == nil && listTarget(300) == nil,
                        "The header returns a list to the top level; its own rows and empty space take nothing")
            try require(ListTree.dropTarget(pointer: CGPoint(x: 900, y: 114), rows: listRows, header: listHeader, blocked: { _ in false }) == nil
                        && ListTree.dropTarget(pointer: CGPoint(x: -1, y: 80), rows: listRows, header: listHeader, blocked: { _ in false }) == nil,
                        "Dragging a list right of the sidebar or left of its header cannot reorder or reparent it")
            #if os(macOS)
            let sidebarDrag = ListDrag()
            let oldRow = UUID(), newRow = UUID()
            sidebarDrag.report(rowA, owner: oldRow, frame: listRows[rowA]!)
            sidebarDrag.report(rowA, owner: newRow, frame: listRows[rowA]!)
            sidebarDrag.forget(rowA, owner: oldRow)
            try require(sidebarDrag.rows[rowA] != nil, "A replaced sidebar row keeps its place when the old row goes away")
            sidebarDrag.forget(rowA, owner: newRow)
            try require(sidebarDrag.rows[rowA] == nil, "A sidebar row that goes away is no longer a drop target")
            let listsForDrag = (0..<4).map { TaskList(name: "Reflow \($0)") }
            let ids = listsForDrag.map(\.id)
            let stable = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: 0, y: 100 + $0.offset * 32, width: 180, height: 24)) })
            let reflow = ListDrag()
            reflow.sidebar = CGRect(x: 0, y: 0, width: 180, height: 350); reflow.header = listHeader
            for (id, frame) in stable { reflow.report(id, owner: UUID(), frame: frame) }
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            try require(reflow.gap == stable[ids[1]] && reflow.offsets.isEmpty,
                        "Lifting a row marks the slot it came from instead of leaving a hole")
            reflow.move(to: CGPoint(x: 60, y: 185), now: 0)
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .after && reflow.offsets[ids[2]] == -32 && reflow.gap?.minY == 164,
                        "Sidebar reorder lifts the source and opens exactly one row-sized landing slot")
            for _ in 0..<20 { reflow.move(to: CGPoint(x: 60, y: 185), now: 0.2) }
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .after && reflow.offsets[ids[2]] == -32,
                        "Stationary pointer does not chase animated row positions or oscillate")
            reflow.move(to: CGPoint(x: 60, y: 190), now: 0.25)
            try require(reflow.gap != nil && reflow.offsets[ids[2]] == -32, "Crossing native row spacing preserves the reorder slot instead of flashing back")
            reflow.move(to: CGPoint(x: 60, y: 101), now: 0.3)
            try require(reflow.offsets[ids[0]] == 32 && reflow.gap?.minY == 100, "Dragging upward moves the crossed row down into the old gap")
            reflow.move(to: CGPoint(x: 60, y: 169), now: 1)
            reflow.tick(now: 1.39)
            try require(reflow.target?.placement != .inside, "Passing or briefly pausing on a list never immediately nests it")
            reflow.tick(now: 1.41)
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .inside
                        && reflow.gap?.minY == 164 && reflow.gap?.minX == 14
                        && reflow.offsets[ids[2]] == -32 && reflow.offsets[ids[3]] == 0,
                        "A deliberate 400ms middle hover shows an indented slot under that list, not an empty preview")
            reflow.move(to: CGPoint(x: 61, y: 170), now: 1.5)
            try require(reflow.target?.placement == .inside && listsForDrag[1].parentID == nil && listsForDrag[1].sortOrder == 0,
                        "Armed folder remains stable while rows settle; hovering does not change stored hierarchy or order")
            reflow.move(to: CGPoint(x: 60, y: 218), now: 1.6)
            try require(reflow.target?.list == ids[3] && reflow.target?.placement == .after && reflow.gap != nil, "Leaving an armed folder restores normal sorting feedback")
            reflow.cancel()
            try require(reflow.offsets.isEmpty && reflow.gap == nil && reflow.finish() == nil, "Escape removes preview offsets and never returns a drop")
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            try require(!reflow.isDragging, "Cancelled sidebar drag cannot restart from late motion")
            reflow.newPress(); reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            reflow.move(to: CGPoint(x: 60, y: 218), now: 2)
            let accepted = reflow.finish()
            try require(accepted?.list == ids[3] && accepted?.placement == .after && reflow.finish() == nil, "A fresh drag works and can commit at most once")
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] }); reflow.move(to: CGPoint(x: 60, y: 101), now: 3)
            _ = reflow.checkPhysicalButton(pressed: false, now: 3)
            _ = reflow.checkPhysicalButton(pressed: false, now: 3.16)
            try require(!reflow.isDragging && reflow.finish() == nil, "Missing mouse-up cancels sidebar reordering instead of saving later")
            let nestedGap = ListTree.dragPreview(rows: stable, moving: [ids[3]], target: (ids[0], .after), isDescendant: { $0 == $1 || ($1 == ids[0] && $0 == ids[1]) })
            try require(nestedGap.gap?.minY == 164 && nestedGap.offsets[ids[1]] == 0 && nestedGap.offsets[ids[2]] == 32,
                        "An after-group landing slot follows its visible children rather than splitting the group")
            let groupGap = ListTree.dragPreview(rows: stable, moving: [ids[0], ids[1]], target: (ids[3], .after))
            try require(groupGap.gap?.height == 56 && groupGap.offsets[ids[2]] == -64 && groupGap.offsets[ids[3]] == -64,
                        "Dragging an expanded group moves its visible subtree as a block")
            let draggedList = TaskList(name: "Esc test")
            sidebarDrag.begin(draggedList, blocked: { _ in false }); sidebarDrag.cancel()
            sidebarDrag.begin(draggedList, blocked: { _ in false }); sidebarDrag.move(to: .zero)
            try require(!sidebarDrag.isDragging && sidebarDrag.cancelledUntilPress && sidebarDrag.finish() == nil,
                        "Sidebar Escape suppresses restart and drop throughout the same press")
            sidebarDrag.newPress(); sidebarDrag.begin(draggedList, blocked: { _ in false })
            try require(sidebarDrag.isDragging && !sidebarDrag.cancelledUntilPress, "A fresh press can drag a list after Escape")
            _ = sidebarDrag.finish()
            #endif
            #if os(macOS)
            let monthSession = WeekDrag()
            monthSession.monthCanvas = monthGrid.canvas; monthSession.monthViewport = monthGrid.viewport
            var monthLanding: (WeekDropGeometry.Zone, Int)?
            monthSession.begin(dragTask, color: .accentColor, grabOffset: 0, month: date(2026, 9, 18)) { zone, offset in monthLanding = (zone, offset) }
            monthSession.move(to: CGPoint(x: 40, y: 300))
            monthSession.tick(now: 0); monthSession.tick(now: 0.7)
            try require(monthSession.weekOffset == -1 && monthSession.edge == -1, "Resting beside the month previews the previous month")
            monthSession.move(to: CGPoint(x: 350, y: 250))
            monthSession.complete()
            try require(monthLanding.map { $0.1 == -1 && $0.0 != .none } == true && !monthSession.isDragging && TaskSchedule(dragTask) == original,
                        "A month drag hands over the day and the month it was dropped in, and changes nothing by itself")
            receivedOffset = nil
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.5); session.tick(now: 1.3)
            try require(session.weekOffset == 2, "Resting on the edge turns a second week")
            session.complete()
            try require(receivedOffset == nil && session.weekOffset == 0 && !session.isDragging,
                        "Letting go on the edge strip slides back and changes nothing")
            receivedOffset = nil
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.7); session.cancel(); session.complete()
            try require(receivedOffset == nil && session.weekOffset == 0 && TaskSchedule(dragTask) == original,
                        "Cancel restores original week and never commits a task")

            #if os(macOS)
            final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 744, height: 500))
            scroll.documentView = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 744, height: 1728))
            session.scrollView = scroll
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in }
            session.move(to: CGPoint(x: 300, y: 610))
            session.tick(now: 0); session.tick(now: 0.1)
            try require(scroll.contentView.bounds.minY == 0, "Briefly crossing a vertical edge does not scroll")
            for frame in 0..<100 { session.tick(now: 0.3 + Double(frame) * 0.016) }
            let scrolled = scroll.contentView.bounds.minY
            try require(scrolled > 720, "Holding below the grid scrolls more than ten hours without moving the pointer")
            session.move(to: CGPoint(x: 300, y: 300)); session.tick(now: 2.0)
            try require(scroll.contentView.bounds.minY == scrolled, "Leaving edge stops scrolling")
            session.cancel(); session.tick(now: 3.0)
            try require(scroll.contentView.bounds.minY == scrolled, "Cancel stops edge scrolling")
            _ = session.finish()
            #endif

            var landedZone = WeekDropGeometry.Zone.none
            var landedWeek = 0, dropCount = 0
            session.canvas = geometry.canvas; session.viewport = geometry.viewport
            session.undated = geometry.undated; session.allDay = geometry.allDay
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset; dropCount += 1
            }
            session.samplePointer(at: CGPoint(x: 734, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.panelView = nil // Simulate removal of the old page's host/source.
            session.samplePointer(at: CGPoint(x: wednesday, y: sixPM), pressed: true)
            try require(session.isDragging && session.weekOffset == 1 && session.zone == .timed(day: 2, minute: 1080),
                        "After next-week paging a detached source still allows choosing Wednesday at 18:00")
            session.samplePointer(at: CGPoint(x: wednesday + 100, y: sixPM - 72), pressed: false)
            session.samplePointer(at: CGPoint(x: 0, y: 0), pressed: false)
            try require(dropCount == 1 && landedWeek == 1 && landedZone == .timed(day: 3, minute: 1020),
                        "Physical release uses final Thursday 17:00 location exactly once")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset; dropCount += 1
            }
            session.samplePointer(at: CGPoint(x: 10, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.samplePointer(at: CGPoint(x: wednesday, y: 75), pressed: false)
            try require(landedWeek == -1 && landedZone == .allDay(2), "Previous-week paging can land on the all-day row")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, _ in landedZone = zone }
            session.samplePointer(at: CGPoint(x: 734, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.samplePointer(at: CGPoint(x: 800, y: 300), pressed: false)
            try require(landedZone == .undated, "After paging a task can still return to the undated area")

            #if os(macOS)
            // No visible window or generated mouse events: exercise the real AppKit coordinate conversion.
            let testWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1000, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            testWindow.isReleasedWhenClosed = false
            let host = FlippedDocument(frame: CGRect(x: 60, y: 40, width: 744, height: 600))
            testWindow.contentView!.addSubview(host)
            session.panelView = host
            session.canvas = geometry.canvas
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset
            }
            let edgeScreen = testWindow.convertPoint(toScreen: host.convert(CGPoint(x: 734, y: 300), to: nil))
            let finalScreen = testWindow.convertPoint(toScreen: host.convert(CGPoint(x: wednesday, y: sixPM), to: nil))
            session.sampleScreenPointer(at: edgeScreen, pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            host.removeFromSuperview()
            session.sampleScreenPointer(at: finalScreen, pressed: true)
            try require(session.isDragging && session.weekOffset == 1 && session.zone == .timed(day: 2, minute: 1080),
                        "Native screen coordinates still resolve after the old host leaves its window")
            session.sampleScreenPointer(at: finalScreen, pressed: false)
            try require(landedWeek == 1 && landedZone == .timed(day: 2, minute: 1080),
                        "Release commits the new week's location even with no source host")
            testWindow.close()
            #endif

            #endif
            // --- full-day free time, with no presumed sleeping hours ---
            func at(_ hour: Int, _ minute: Int) -> Date { Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date(2026, 9, 18))! }
            try require(PlanBlock.countedSpan(day: date(2026, 9, 17), now: at(14, 10)) == nil, "Past days have no free time left")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(14, 10)).map { $0 == (850, 1440) } == true, "Today includes every remaining minute")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(6, 0)).map { $0 == (360, 1440) } == true, "Early morning is available")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(23, 30)).map { $0 == (1410, 1440) } == true, "Late-night half hour remains available")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 19), now: at(14, 10)).map { $0 == (0, 1440) } == true, "Future days count all 24 hours")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(0, 0)).map { $0 == (0, 1440) } == true, "Midnight starts a full day")
        }
        do {
            let icon = "👨‍👩‍👧‍👦"
            try require(["💼", "🧑🏽‍💻", "🇨🇳", "1️⃣", icon].allSatisfy(TaskList.validEmoji), "List icons accept full composed emoji sequences")
            try require(["", "A", "123", "💼📚"].allSatisfy { !TaskList.validEmoji($0) }, "List icon validation rejects text and multiple emoji")
            let db = try Store.make(url: directory.appendingPathComponent("emoji.store"))
            let list = TaskList(name: "Icons"); list.emoji = icon; db.mainContext.insert(list); try Store.save(db.mainContext)
            let backup = try TaskBackup.capture(db.mainContext)
            let decoded = try TaskBackup.decode(backup.encoded())
            try require(decoded.version == 7 && decoded.lists.first?.emoji == icon, "Emoji survives portable version five backup")
            let destination = try Store.make(url: directory.appendingPathComponent("emoji-restored.store"))
            try decoded.restore(destination.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("emoji-restored.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<TaskList>()).first?.emoji == icon, "Emoji survives restore and database reopen")
            var old = decoded; old.version = 4; old.lists[0].emoji = nil
            try require(try TaskBackup.decode(old.encoded()).lists[0].emoji == nil, "Version four without emoji retains default icon")
            var bad = decoded; bad.lists[0].emoji = "plain text"
            var rejected = false; do { _ = try bad.encoded() } catch { rejected = true }
            try require(rejected, "Backup validates list icon at the trust boundary")
        }
        do {
            let day = Dates.calendar.startOfDay(for: date(2026, 9, 21))
            func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
            let task = TaskItem(title: "Stretch", scheduledAt: at(12)); task.hasTime = true; task.endAt = at(15)
            task.reminderAt = at(11); task.reminderKind = "oneHour"
            let before = TaskSchedule(task)
            let top = TaskResize(task: task, day: day, top: true)!, bottom = TaskResize(task: task, day: day, top: false)!
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            try require(top.minute(at: layout.y(11 * 60 + 8), layout: layout) == 675, "Resize edge snaps to nearest quarter hour")
            try require(top.date(at: top.minute(at: layout.y(16 * 60), layout: layout)) == at(14.75) && bottom.date(at: bottom.minute(at: layout.y(11 * 60), layout: layout)) == at(12.25), "Resize edges cannot cross and retain a fifteen-minute minimum")
            try require(bottom.minute(at: layout.y(1600), layout: layout) == 1440, "Bottom edge can reach midnight without exceeding its day")
            let proposal = TaskMove(task, to: at(11), kind: .resizeStart)
            try require(TaskSchedule(task) == before && proposal.apply(to: task, shiftDeadline: false), "Resize preview is value-only and commits only on request")
            try require(task.scheduledAt == at(11) && task.endAt == at(15) && task.reminderAt == at(10), "Start-edge resize keeps end fixed and follows relative reminder")
            before.restore(task)
            task.dueAt = at(16); task.dueHasTime = true
            let longer = TaskMove(task, to: at(17), kind: .resizeEnd)
            try require(!longer.canKeepDeadline && !longer.apply(to: task, shiftDeadline: false) && task.endAt == at(15), "Extending beyond deadline waits for confirmation")
            try require(longer.apply(to: task, shiftDeadline: true) && task.endAt == at(17) && task.dueAt == at(17) && task.scheduledAt == at(12), "Confirmed bottom resize extends end and deadline only as needed")
            before.restore(task)
            task.endAt = at(30)
            try require(TaskResize(task: task, day: day, top: false) == nil && TaskResize(task: task, day: at(24), top: true) == nil,
                        "Multi-day task handles only appear at the true start and end")
            try require(TaskResize(task: task, day: at(24), top: false) != nil, "Cross-midnight final segment exposes its end handle")
            before.restore(task)
            #if os(macOS)
            let session = WeekDrag()
            session.canvas = CGRect(x: 0, y: 0, width: 700, height: 1800); session.viewport = session.canvas; session.layout = layout
            var drops = 0; var endpoint: Date?
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 100, y: layout.y(960))) { value, _ in endpoint = value; drops += 1 }
            try require(session.zone == .timed(day: 0, minute: 960) && TaskSchedule(task) == before, "Resize session previews candidate without writing task")
            session.tick(now: 0); session.tick(now: 10)
            try require(session.weekOffset == 0, "Resizing within a day does not turn a week")
            session.cancel(); session.complete()
            try require(drops == 0 && TaskSchedule(task) == before, "Esc cancels resize without committing")
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 100, y: layout.y(1020))) { value, _ in endpoint = value; drops += 1 }
            session.complete(); session.complete()
            try require(drops == 1 && endpoint == at(17), "Resize release commits the final endpoint exactly once")
            session.updateResize(task, color: .blue, range: top, point: CGPoint(x: 100, y: layout.y(600))) { _, _ in drops += 1 }
            _ = session.checkPhysicalButton(pressed: false, now: 1); _ = session.checkPhysicalButton(pressed: false, now: 1.2)
            session.complete()
            try require(drops == 1, "Missed mouse-up cancels resize instead of silently changing time")
            #endif
        }
        do {
            let task = TaskItem(title: "Find planning", scheduledAt: date(2027, 1, 5))
            task.notes = "Searchable note"; task.subtasks = [Subtask(title: "Read material")]
            try require(CalendarTaskSearch.matches(task, query: "PLANNING"), "Calendar search finds a future task regardless of visible week or month")
            try require(CalendarTaskSearch.matches(task, query: "material"), "Calendar search finds subtask text")
            task.scheduledAt = date(2025, 1, 5); task.isDone = true
            try require(CalendarTaskSearch.matches(task, query: "note"), "Global calendar search includes completed historical tasks")
            task.deletedAt = date(2026, 9, 21)
            try require(!CalendarTaskSearch.matches(task, query: "note"), "Calendar search excludes recently deleted tasks")
            task.deletedAt = nil; task.scheduledAt = nil
            try require(CalendarTaskSearch.matches(task, query: "planning"), "Global calendar search includes undated tasks")
            let list = TaskList(name: "Searchable category"); task.list = list
            try require(CalendarTaskSearch.matches(task, query: "category"), "Calendar search finds list names without emoji")
            task.deletedAt = date(2026, 9, 21)
            try require(CalendarTaskSearch.matches(task, query: "  CATEGORY  ", includeDeleted: true), "Trash search shares list-name and whitespace matching")
            try require(!CalendarTaskSearch.matches(task, query: "category"), "Shared search still excludes trash outside the trash view")
            try require(!CalendarTaskSearch.matches(task, query: "  ") && !CalendarTaskSearch.matches(task, query: "missing"), "Empty or unrelated search has no result")
        }
        do {
            let day = date(2026, 9, 21)
            let short = TaskItem(title: "Doing something", scheduledAt: day.addingTimeInterval(11 * 3600))
            short.hasTime = true; short.endAt = short.scheduledAt!.addingTimeInterval(900)
            let next = TaskItem(title: "Next", scheduledAt: short.endAt); next.hasTime = true; next.endAt = next.scheduledAt!.addingTimeInterval(900)
            let blocks = PlanBlock.layout([short, next], day: day)
            try require(blocks.allSatisfy { $0.columns == 1 }, "Consecutive fifteen-minute tasks do not split into false overlap lanes")
            for zoom in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5] {
                let layout = TimelineLayout.make(blocks: blocks, fullDay: true, density: PlanBlock.displayScale * zoom)
                let h = layout.intervalHeight(from: blocks[0].start, to: blocks[0].end)
                try require(abs(h / layout.intervalHeight(from: 660, to: 720) - 0.25) < 0.000001, "Fifteen minutes remains exactly one quarter hour at zoom \(zoom)")
                try require(abs(layout.y(blocks[0].start) + h - layout.y(blocks[1].start)) < 0.000001, "Adjacent interval boundaries stay aligned at zoom \(zoom)")
            }
            next.scheduledAt = short.scheduledAt!.addingTimeInterval(300)
            try require(PlanBlock.layout([short, next], day: day).allSatisfy { $0.columns == 2 }, "Genuinely overlapping short intervals still get separate lanes")
        }
        do {
            func moment(_ y: Int, _ m: Int, _ d: Int, _ hour: Int) -> Date { date(y, m, d).addingTimeInterval(Double(hour) * 3600) }
            let task = TaskItem(title: "Optional deadline", scheduledAt: moment(2026, 9, 21, 10))
            task.hasTime = true; task.endAt = moment(2026, 9, 21, 11); task.dueAt = moment(2026, 9, 25, 18); task.dueHasTime = true
            let original = TaskSchedule(task)
            let plan = TaskMove(task, to: moment(2026, 9, 22, 10), kind: .timed)
            try require(plan.canKeepDeadline && plan.apply(to: task, shiftDeadline: false), "Nonconflicting deadline move saves without confirmation")
            let moved = TaskSchedule(task)
            try require(task.dueAt == original.dueAt && plan.deferredDeadline(for: task, after: moved) == moment(2026, 9, 26, 18), "Saved move keeps deadline and offers optional offset-preserving shift")
            task.dueAt = plan.deferredDeadline(for: task, after: moved)
            try require(plan.deferredDeadline(for: task, after: moved) == nil, "Optional deadline shift cannot run twice")
            original.restore(task)
            try require(TaskSchedule(task) == original, "Undo after optional deadline shift restores both original dates")
            _ = plan.apply(to: task, shiftDeadline: false)
            let stale = TaskSchedule(task); task.endAt = moment(2026, 9, 22, 12)
            try require(plan.deferredDeadline(for: task, after: stale) == nil, "Stale optional action cannot overwrite a later schedule edit")
            stale.restore(task); task.deletedAt = Date()
            try require(plan.deferredDeadline(for: task, after: stale) == nil, "Deleted task rejects optional deadline action")
            task.deletedAt = nil; original.restore(task)
            let earlier = TaskMove(task, to: moment(2026, 9, 20, 10), kind: .timed)
            _ = earlier.apply(to: task, shiftDeadline: false)
            try require(earlier.deferredDeadline(for: task, after: TaskSchedule(task)) == moment(2026, 9, 24, 18), "Backward move offers backward deadline shift")
            original.restore(task)
            let resize = TaskMove(task, to: moment(2026, 9, 21, 12), kind: .resizeEnd)
            try require(resize.canKeepDeadline && resize.apply(to: task, shiftDeadline: false) && task.dueAt == original.dueAt && resize.deferredDeadline(for: task, after: TaskSchedule(task)) == nil, "Safe edge adjustment keeps deadline without prompting or a no-op action")
            original.restore(task)
            let conflict = TaskMove(task, to: moment(2026, 9, 26, 10), kind: .timed)
            try require(!conflict.canKeepDeadline && !conflict.apply(to: task, shiftDeadline: false) && TaskSchedule(task) == original, "Conflicting move waits without silently changing either date")
            try require(conflict.apply(to: task, shiftDeadline: true) && task.dueAt == moment(2026, 9, 30, 18), "Confirmed conflict shifts both dates")
            for height in [4.5, 9, 12, 13.5, 18, 24, 27, 72] {
                let edge = TaskResize.handleHeight(for: height)
                try require(edge * 2 <= height / 2 && (height < 12 ? edge == 0 : edge > 0), "Resize edge zones leave central moving space at height \(height)")
            }
            try require(TaskResize.handleHeight(for: 60 * 0.3) == 4.5, "One-hour task at 25 percent zoom has usable top and bottom edges")
        }
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
            copyHistory.undo()
            try require(copied.deletedAt != nil && copyHistory.canRedo && TaskBackup.TaskRecord(next) == sourceRecord,
                        "Undo copy removes only the new task and leaves the source intact")
            copyHistory.redo()
            try require(TaskBackup.TaskRecord(copied) == createdCopy && copyHistory.canUndo,
                        "Redo copy restores the same task ID, subtask IDs and schedule without creating another copy")
            let copySchedule = TaskSchedule(copied)
            copied.schedule(at: date(2031, 1, 8)); try Store.save(context)
            copyHistory.record(copied, before: .schedule(copySchedule), after: .schedule(TaskSchedule(copied)), name: "Move copy")
            copyHistory.undo(); copyHistory.undo()
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
        // Exercise a real SwiftData write rejection, not merely a manual rollback.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-SaveRecovery-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("recovery.store")
            let seed = try Store.make(url: url)
            let baseline = TaskItem(title: "Saved title"), list = TaskList(name: "Saved list")
            seed.mainContext.insert(list); seed.mainContext.insert(baseline); baseline.list = list
            try Store.save(seed.mainContext)
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
            let drafts = EditorDrafts()
            drafts.taskID = baseline.id
            drafts.task = TaskEditor.DraftState(title: "Kept draft", notes: "Notes", pending: "Pending subtask", repeating: "weekly", repeatUntil: date(2032,1,1),
                end: date(2031,1,1).addingTimeInterval(3600), scheduled: date(2031,1,1), due: date(2031,1,2), reminder: date(2031,1,1).addingTimeInterval(-900),
                timed: true, dueTimed: true, preset: .custom, listID: list.id, priority: 2, subtasks: [Subtask(title: "Draft step")])
            let originalDraft = drafts.task
            drafts.listID = list.id
            drafts.list = ListEditor.DraftState(name: "Draft list", colorHex: "#123456", emoji: "📚", parentID: nil)
            let originalListDraft = drafts.list
            var saveCallbacks = 0
            Store.didSave = { _ in saveCallbacks += 1 }
            defer { Store.didSave = nil }
            for operation in ["edit", "insert", "delete", "list", "restore"] {
                let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
                let context = readOnly.mainContext
                context.autosaveEnabled = false
                let current = try context.fetch(FetchDescriptor<TaskItem>()).first!
                let saved = try TaskBackup.capture(context)
                if operation == "edit" { current.title = "Must not leak" }
                if operation == "insert" { context.insert(TaskItem(title: "Uncommitted new task")) }
                if operation == "delete" { context.delete(current) }
                if operation == "list" { current.list?.name = "Must not leak" }
                let previousCallbacks = saveCallbacks, generation = Store.recovery.generation
                var failed = false
                do {
                    if operation == "restore" { try saved.restore(context, replace: true) }
                    else { try Store.save(context) }
                } catch { failed = true }
                try require(failed && Store.recovery.failure != nil, "Actual read-only write suspends saving: " + operation)
                try require(saveCallbacks == previousCallbacks, "Failed writes never announce success or schedule backup: " + operation)
                try require((try? Store.recovery.requireWritable(context)) == nil, "Failed context blocks later edits: " + operation)
                if operation == "edit" {
                    let away = root.appendingPathExtension("away")
                    try FileManager.default.moveItem(at: root, to: away)
                    let recoveredMissingFile = Store.recovery.reload()
                    let recreatedEmptyFile = FileManager.default.fileExists(atPath: url.path)
                    try FileManager.default.moveItem(at: away, to: root)
                    try require(!recoveredMissingFile && Store.recovery.failure != nil && Store.recovery.generation == generation, "Failed reload keeps writes paused and the current UI generation")
                    try require(!recreatedEmptyFile && drafts.task == originalDraft, "Missing store never creates an empty database or discards a draft")
                }
                try require(Store.recovery.reload(), "Reload opens committed data without restarting: " + operation)
                let fresh = Store.recovery.container!.mainContext
                let after = try TaskBackup.capture(fresh)
                try require(after.tasks == saved.tasks && after.lists.first?.name == saved.lists.first?.name, "Recovery leaves failed changes out of disk data: " + operation)
                try require(Store.recovery.generation == generation + 1 && Store.recovery.failure == nil, "Recovery replaces UI model generation: " + operation)
                try require(drafts.task == originalDraft && drafts.list == originalListDraft, "Task/list drafts survive model reload: " + operation)
                try require((try? Store.save(context)) == nil && Store.recovery.failure == nil, "Old context cannot write or relock recovered session: " + operation)
                let recovered = try fresh.fetch(FetchDescriptor<TaskItem>()).first!
                recovered.title = "Saved after " + operation
                try Store.save(fresh)
                let verified = try Store.make(url: url)
                try require(try verified.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == recovered.title, "Fresh context successfully saves after recovery: " + operation)
            }
        }
        if let path = ProcessInfo.processInfo.environment["JIANSHI_MIGRATION_COPY"] {
            let source = URL(fileURLWithPath: path)
            _ = try StoreUpgradeSnapshot.prepare(source)
            let migrated = try Store.make(url: source)
            let before = try TaskBackup.capture(migrated.mainContext)
            @MainActor func checkSyncState(_ context: ModelContext) throws {
                let environment = ProcessInfo.processInfo.environment
                guard let statePath = environment["JIANSHI_MIGRATION_CLOUD_STATE"],
                      let baselinePath = environment["JIANSHI_MIGRATION_CLOUD_BASELINE"] else { return }
                struct ExpectedState: Decodable {
                    let enabled: Bool
                    let account: String
                    let lastSyncMilliseconds: Double
                    let baselineSHA256: String
                }
                let expected = try JSONDecoder().decode(ExpectedState.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
                let baseline = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
                let states = try context.fetch(FetchDescriptor<CloudSyncState>())
                try require(states.count == 1, "Frozen migration preserves exactly one sync state")
                guard let state = states.first else { return }
                let enabled = state.enabled, account = state.account
                let lastSync = state.lastSync, savedBaseline = state.baseline
                try require(enabled == expected.enabled && account == expected.account,
                            "Frozen migration preserves sync consent and account binding")
                try require(lastSync.map { abs($0.timeIntervalSince1970 * 1000 - expected.lastSyncMilliseconds) < 1 } == true,
                            "Frozen migration preserves last successful sync time")
                try require(savedBaseline == baseline && CloudMerge.digest(baseline) == expected.baselineSHA256,
                            "Frozen migration preserves the exact conflict merge baseline")
            }
            try checkSyncState(migrated.mainContext)
            if let expectedPath = ProcessInfo.processInfo.environment["JIANSHI_MIGRATION_EXPECTED"] {
                var expected = try TaskBackup.decode(Data(contentsOf: URL(fileURLWithPath: expectedPath)))
                // Compare saved fields strictly while accepting the current export version and newly added empty table.
                // The old CloudSyncState baseline is checked byte-for-byte above, without normalization.
                expected.version = before.version
                if expected.weekTitles == nil {
                    try require(before.weekTitles?.isEmpty == true, "A schema without week titles migrates to an empty week-title table")
                    expected.weekTitles = []
                }
                try require(try BackupFiles.contentData(before) == BackupFiles.contentData(expected),
                            "Previous-version schema migrates every task/list field, link, subtask and identity unchanged")
            }
            try Store.save(migrated.mainContext)
            let reopened = try Store.make(url: URL(fileURLWithPath: path))
            let after = try TaskBackup.capture(reopened.mainContext)
            try require(try BackupFiles.contentData(before) == BackupFiles.contentData(after),
                        "Frozen migration preserves task, list, week title and finance data after save and reopen")
            try checkSyncState(reopened.mainContext)
            try require(Set(before.tasks.map(\.id)) == Set(after.tasks.map(\.id)) && Set(before.lists.map(\.id)) == Set(after.lists.map(\.id)), "Migration preserves all task and list identities")
            try require(Set(after.lists.compactMap { $0.colorHex?.uppercased() }).count == after.lists.count, "Migrated store has distinct list colors")
        }
        checkCount += try CalendarGridChecks.run()
        checkCount += try EditingChecks.run()
        checkCount += try FinanceChecks.run()
        checkCount += try CloudMerge.check()
        print("PASS: \(checkCount) checks — calendar, boundaries, persistent reload, subtasks, edit, completion, deletion, restore, rollback")
    }
    /// Repeatable release benchmark. Uses its own store; never reads the user's database.
    static func performance() throws {
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
        try measure("lightweight backup capture with 5000 money entries") { _ = try TaskBackup.capture(context, includeFinance: false); _ = try FinanceStore.payload(context) }
        let money = try FinanceStore.read(context)!
        guard money.balance(account.id) == 50000 else { throw TaskBackup.invalid("Performance ledger balance incorrect") }
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
