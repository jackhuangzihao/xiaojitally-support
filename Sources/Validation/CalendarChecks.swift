import Foundation
import SwiftData
import UserNotifications
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor enum CalendarChecks {
    static func clockAndPhoneSlots(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func popoverIdentity(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func daylightSavingTimeline(require: (Bool, String) throws -> Void) throws {
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
    }

    static func calendarBuckets(require: (Bool, String) throws -> Void) throws {
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
    }

    static func dayScheduleGaps(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func dateRulesAndReminders(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws -> Date {
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
        return today
    }

    static func timelineLayoutAndFiltering(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func calendarSearch(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func shortTaskIntervals(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
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
    }

    static func emptyPlanSlots(require: (Bool, String) throws -> Void) throws {
        let layout = TimelineLayout.make(blocks: [], fullDay: true, density: 0.5, nowMinute: nil)
        let occupied = [CGRect(x: 144, y: layout.y(600), width: 98, height: layout.intervalHeight(from: 600, to: 660))]
        try require(PlanSlot.emptyPoint(CGPoint(x: 150, y: layout.y(720)), column: 100, gutter: 44, layout: layout, occupied: occupied) == PlanSlot(day: 1, minute: 720), "double click maps to clicked day and quarter hour")
        try require(PlanSlot.emptyPoint(CGPoint(x: 150, y: layout.y(620)), column: 100, gutter: 44, layout: layout, occupied: occupied) == nil, "double click on an existing card never creates another task")
        try require(PlanSlot.emptyPoint(CGPoint(x: 20, y: 100), column: 100, gutter: 44, layout: layout, occupied: []) == nil, "time labels are not creation targets")
        try require(PlanSlot.emptyPoint(CGPoint(x: 750, y: 100), column: 100, gutter: 44, layout: layout, occupied: []) == nil, "trailing week navigation is not a creation target")
    }
}
