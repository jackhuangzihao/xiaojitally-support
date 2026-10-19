import Foundation
import SwiftData

/// How a task repeats. Stored as text so older stores and backups keep working: "none", "daily", "weekly",
/// "monthly", "yearly", or "every:<n>:<d|w|m|y>[:<weekdays>]" (weekdays 1 = Sunday … 7 = Saturday).
/// The task's own date is always the first time; later ones follow the rule.
struct RepeatRule: Equatable {
    enum Unit: String, CaseIterable { case day = "d", week = "w", month = "m", year = "y" }
    var interval: Int
    var unit: Unit
    /// Weekly only. Empty means the weekday of the task itself.
    var weekdays: Set<Int>

    init(interval: Int, unit: Unit, weekdays: Set<Int> = []) {
        self.interval = min(99, max(1, interval))
        self.unit = unit
        self.weekdays = unit == .week ? weekdays.filter { (1...7).contains($0) } : []
    }

    init?(_ text: String) {
        switch text {
        case "daily": self.init(interval: 1, unit: .day)
        case "weekly": self.init(interval: 1, unit: .week)
        case "monthly": self.init(interval: 1, unit: .month)
        case "yearly": self.init(interval: 1, unit: .year)
        default:
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (3...4).contains(parts.count), parts[0] == "every", let n = Int(parts[1]), (1...99).contains(n),
                  let unit = Unit(rawValue: parts[2]) else { return nil }
            var days = Set<Int>()
            if parts.count == 4 {
                guard unit == .week else { return nil }
                for part in parts[3].split(separator: ",", omittingEmptySubsequences: false) {
                    guard let day = Int(part), (1...7).contains(day) else { return nil }
                    days.insert(day)
                }
                guard !days.isEmpty else { return nil }
            }
            self.init(interval: n, unit: unit, weekdays: days)
        }
    }

    var text: String {
        if interval == 1 && weekdays.isEmpty {
            switch unit {
            case .day: return "daily"
            case .week: return "weekly"
            case .month: return "monthly"
            case .year: return "yearly"
            }
        }
        return "every:\(interval):\(unit.rawValue)" + (weekdays.isEmpty ? "" : ":" + weekdays.sorted().map(String.init).joined(separator: ","))
    }

    static let workdays = RepeatRule(interval: 1, unit: .week, weekdays: [2, 3, 4, 5, 6])
    static func isValid(_ text: String) -> Bool { text == "none" || RepeatRule(text) != nil }
    /// Monday first, the way the calendar shows weeks.
    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]
    static func weekdayName(_ day: Int) -> String {
        let chinese = ["日", "一", "二", "三", "四", "五", "六"], english = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return L(chinese[(day - 1) % 7], english[(day - 1) % 7])
    }

    var label: String {
        if self == Self.workdays { return L("工作日", "Weekdays") }
        switch unit {
        case .day: return interval == 1 ? L("每天", "Daily") : L("每 \(interval) 天", "Every \(interval) days")
        case .month: return interval == 1 ? L("每月", "Monthly") : L("每 \(interval) 个月", "Every \(interval) months")
        case .year: return interval == 1 ? L("每年", "Yearly") : L("每 \(interval) 年", "Every \(interval) years")
        case .week:
            let every = interval == 1 ? L("每周", "Weekly") : L("每 \(interval) 周", "Every \(interval) weeks")
            guard !weekdays.isEmpty else { return every }
            let days = Self.weekOrder.filter(weekdays.contains).map(Self.weekdayName)
            return every + L("的周", " on ") + days.joined(separator: L("、", ", "))
        }
    }
}

/// Earlier tasks whose titles contain what is being typed, offered when a new task is written: one per title
/// (the latest), those in the list being added to first, then titles starting with the text, then the most recent.
enum TaskSuggestions {
    /// A value-only draft: constructing it never attaches a new task to the saved list.
    struct Template {
        let title: String, notes: String
        let listID: UUID?
        let priority: Int
        let subtasks: [Subtask]
        let start: Date?, end: Date?, due: Date?, reminder: Date?
        let timed: Bool, dueTimed: Bool
        let reminderPreset: ReminderPreset

        init(_ source: TaskItem, day: Date, scheduled: Bool) {
            title = source.title; notes = source.notes; listID = source.list?.id; priority = source.priority
            subtasks = source.subtasks.map { Subtask(title: $0.title) }
            timed = source.hasTime && source.scheduledAt != nil
            start = timed ? Dates.replacingDay(of: source.scheduledAt!, with: day) : (scheduled ? Dates.calendar.startOfDay(for: day) : nil)
            end = start.flatMap { begin in source.duration.map { begin.addingTimeInterval($0) } }
            let anchor = source.calendarDate ?? source.reminderAt ?? day
            let offset = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: anchor), to: Dates.calendar.startOfDay(for: day)).day ?? 0
            due = source.dueAt.flatMap { Dates.calendar.date(byAdding: .day, value: offset, to: $0) }
            dueTimed = source.dueHasTime
            reminderPreset = source.resolvedReminderPreset
            if reminderPreset == .custom {
                reminder = source.reminderAt.flatMap { Dates.calendar.date(byAdding: .day, value: offset, to: $0) }
            } else {
                reminder = reminderPreset.date(base: start ?? due, timed: start != nil ? timed : dueTimed)
            }
        }
    }

    static func find(_ query: String, in tasks: [TaskItem], preferredList: UUID?, limit: Int = 5) -> [TaskItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        func key(_ task: TaskItem) -> String { task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func recency(_ task: TaskItem) -> Date { task.calendarDate ?? task.createdAt }
        var latest: [String: TaskItem] = [:]
        for task in tasks where task.deletedAt == nil && task.title.localizedCaseInsensitiveContains(text) {
            let title = key(task)
            if let kept = latest[title], recency(kept) >= recency(task) { continue }
            latest[title] = task
        }
        let lower = text.lowercased()
        return Array(latest.values.sorted { a, b in
            let aHere = preferredList != nil && a.list?.id == preferredList, bHere = preferredList != nil && b.list?.id == preferredList
            if aHere != bHere { return aHere }
            let aStarts = key(a).hasPrefix(lower), bStarts = key(b).hasPrefix(lower)
            if aStarts != bStarts { return aStarts }
            if recency(a) != recency(b) { return recency(a) > recency(b) }
            return a.title < b.title
        }.prefix(limit))
    }
}

/// A single reschedule can be undone without rolling back later title/subtask edits.
struct TaskSchedule: Equatable {
    let scheduledAt: Date?
    let hasTime: Bool
    let endAt: Date?
    let dueAt: Date?
    let dueHasTime: Bool
    let reminderAt: Date?
    let reminderKind: String
    let reminderNeedsAttention: Bool
    let repeatAnchorDay: Int
    let repeatTimeZoneID: String?
    let repeatClock: Int?
    let repeatReminderOffset: Int?
    init(_ task: TaskItem) {
        scheduledAt = task.scheduledAt; hasTime = task.hasTime; endAt = task.endAt; dueAt = task.dueAt; dueHasTime = task.dueHasTime
        reminderAt = task.reminderAt; reminderKind = task.reminderKind
        reminderNeedsAttention = task.reminderNeedsAttention; repeatAnchorDay = task.repeatAnchorDay
        repeatTimeZoneID = task.repeatTimeZoneID; repeatClock = task.repeatClock
        repeatReminderOffset = task.repeatReminderOffset
    }
    func restore(_ task: TaskItem) {
        task.scheduledAt = scheduledAt; task.hasTime = hasTime; task.endAt = endAt; task.dueAt = dueAt; task.dueHasTime = dueHasTime
        task.reminderAt = reminderAt; task.reminderKind = reminderKind
        task.reminderNeedsAttention = reminderNeedsAttention; task.repeatAnchorDay = repeatAnchorDay
        task.repeatTimeZoneID = repeatTimeZoneID; task.repeatClock = repeatClock
        task.repeatReminderOffset = repeatReminderOffset
    }
}

/// A value-only proposal: showing or cancelling confirmation never mutates the task.
struct TaskMove {
    enum Kind { case day, timed, allDay, resizeStart, resizeEnd }
    let taskID: UUID
    let day: Date
    let kind: Kind
    let before: TaskSchedule
    let start: Date
    let end: Date?
    let timed: Bool

    init(_ task: TaskItem, to day: Date, kind: Kind) {
        taskID = task.id; self.day = day; self.kind = kind; before = TaskSchedule(task)
        switch kind {
        case .day:
            timed = task.scheduledAt != nil ? task.hasTime : task.dueHasTime
            start = task.calendarDate.map { Dates.replacingDay(of: $0, with: day) } ?? Dates.calendar.startOfDay(for: day)
            let destination = start
            end = task.duration.map { destination.addingTimeInterval($0) }
        case .timed:
            start = day; timed = true; end = task.proposedEnd(at: day)
        case .allDay:
            start = Dates.calendar.startOfDay(for: day); timed = false; end = nil
        case .resizeStart:
            start = day; timed = true; end = task.endAt ?? task.clockDate?.addingTimeInterval(1800)
        case .resizeEnd:
            start = task.scheduledAt ?? day; timed = true; end = day
        }
    }
    var changesSchedule: Bool {
        // A date-only drop on an existing deadline's day is also a no-op.
        if kind == .day, before.scheduledAt == nil, let due = before.dueAt, Dates.sameDay(due, start) { return false }
        return start != before.scheduledAt || timed != before.hasTime || end != before.endAt
    }
    var canKeepDeadline: Bool {
        before.dueAt.map { Dates.deadlineAllowed(due: $0, dueTimed: before.dueHasTime, scheduled: end ?? start, scheduledTimed: timed) } ?? true
    }
    var shiftedDeadline: Date? {
        guard let due = before.dueAt else { return nil }
        if kind == .resizeStart || kind == .resizeEnd {
            if canKeepDeadline { return due }
            return before.dueHasTime ? (end ?? start) : Dates.calendar.startOfDay(for: end ?? start)
        }
        let base = before.scheduledAt ?? due
        let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: base), to: Dates.calendar.startOfDay(for: start)).day ?? 0
        let shifted: Date
        if kind == .timed, before.dueHasTime, before.hasTime || before.scheduledAt == nil && before.dueHasTime {
            shifted = due.addingTimeInterval(start.timeIntervalSince(base))
        } else {
            shifted = Dates.calendar.date(byAdding: .day, value: days, to: due) ?? due
        }
        let finish = end ?? start
        if Dates.deadlineAllowed(due: shifted, dueTimed: before.dueHasTime, scheduled: finish, scheduledTimed: timed) { return shifted }
        return before.dueHasTime && timed ? finish : Dates.calendar.startOfDay(for: finish)
    }
    /// Available only for an unchanged move that kept its deadline. Never replay the move itself.
    func deferredDeadline(for task: TaskItem, after snapshot: TaskSchedule) -> Date? {
        guard task.id == taskID, task.deletedAt == nil, TaskSchedule(task) == snapshot,
              canKeepDeadline, task.scheduledAt == start, task.hasTime == timed, task.endAt == end,
              task.dueAt == before.dueAt, task.dueHasTime == before.dueHasTime,
              let due = shiftedDeadline, due != before.dueAt,
              Dates.deadlineAllowed(due: due, dueTimed: task.dueHasTime, scheduled: task.endAt ?? task.scheduledAt, scheduledTimed: task.hasTime) else { return nil }
        return due
    }
    @discardableResult func apply(to task: TaskItem, shiftDeadline: Bool) -> Bool {
        guard task.id == taskID, task.deletedAt == nil, TaskSchedule(task) == before,
              changesSchedule, end.map({ $0 > start }) ?? true,
              (kind != .resizeStart && kind != .resizeEnd) || (before.hasTime && before.scheduledAt != nil),
              shiftDeadline || canKeepDeadline else { return false }
        if shiftDeadline { task.dueAt = shiftedDeadline }
        switch kind {
        case .day:
            // A deadline-only task gains an arrangement so its deadline can remain independent.
            if task.scheduledAt == nil && before.dueAt != nil { task.scheduledAt = start; task.hasTime = timed }
            task.reschedule(to: day)
        case .timed: task.schedule(at: start)
        case .allDay: task.makeAllDay(on: start)
        case .resizeStart:
            guard before.hasTime, before.scheduledAt != nil, end != nil else { return false }
            let preset = task.resolvedReminderPreset
            let previousClock = task.actualRepeatClock
            task.scheduledAt = start; task.endAt = end
            task.keepReminder(preset)
            task.repeatAnchorDay = task.recurrenceCalendar?.component(.day, from: start) ?? task.repeatAnchorDay
            task.updateRepeatClock(previousClock: previousClock)
        case .resizeEnd:
            guard let end else { return false }
            return task.resize(to: end)
        }
        return true
    }
}

struct TaskResize {
    /// Keep at least the central half for moving. Very small strips use the editor or zoom instead.
    static func handleHeight(for height: Double) -> Double { height >= 12 ? min(8, height / 4) : 0 }
    let day: Date
    let dayIndex: Int
    let top: Bool
    let column: Int
    let columns: Int
    let start: Date
    let end: Date
    init?(task: TaskItem, day: Date, top: Bool, column: Int = 0, columns: Int = 1) {
        guard task.hasTime, let start = task.scheduledAt else { return nil }
        self.day = Dates.calendar.startOfDay(for: day); self.top = top
        self.column = column; self.columns = max(1, columns)
        self.start = start; end = task.endAt ?? start.addingTimeInterval(1800)
        dayIndex = Dates.weekCells(day).firstIndex { Dates.sameDay($0, day) } ?? 0
        let next = Dates.calendar.date(byAdding: .day, value: 1, to: self.day)!
        guard top ? (start >= self.day && start < next) : (end > self.day && end <= next) else { return nil }
    }
    func minute(at y: Double, layout: TimelineLayout) -> Int {
        let raw = (Double(layout.startMinute) + y / layout.scale) / 15
        return min(1440, max(0, Int(raw.rounded()) * 15))
    }
    /// The original week remains the anchor even after its source card leaves the screen.
    func date(at minute: Int, dayIndex: Int? = nil, weekOffset: Int = 0) -> Date {
        let base = Dates.weekCells(day)[dayIndex ?? self.dayIndex]
        let targetDay = Dates.calendar.date(byAdding: .day, value: weekOffset * 7, to: base)!
        let candidate = Dates.clockTime(on: targetDay, minute: minute, reference: top ? start : end)
        return top ? min(candidate, end.addingTimeInterval(-900)) : max(candidate, start.addingTimeInterval(900))
    }
    func interval(at minute: Int, dayIndex: Int, weekOffset: Int) -> DateInterval {
        let endpoint = date(at: minute, dayIndex: dayIndex, weekOffset: weekOffset)
        return DateInterval(start: top ? endpoint : start, end: top ? end : endpoint)
    }

}
