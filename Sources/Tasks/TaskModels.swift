import Foundation
import SwiftData
import CryptoKit

@Model final class TaskList {
    var id: UUID = UUID()
    var name: String = ""
    var parentID: UUID?
    var sortOrder: Double = 0
    var colorHex: String?
    var emoji: String?
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \TaskItem.list)
    // CloudKit relationships must be optional; existing links migrate in place.
    var tasks: [TaskItem]? = []

    init(name: String) { self.name = name }
    static func validEmoji(_ value: String) -> Bool {
        value.count == 1 && value.utf8.count <= 64
            && value.unicodeScalars.contains { $0.properties.isEmoji }
            && value.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }
    }
    static func validColor(_ hex: String) -> Bool {
        hex.count == 6 && hex.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

struct Subtask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var isDone = false
}

/// A calendar week is identified by its Monday's civil date, so a time-zone change cannot move its title.
@Model final class CalendarWeekTitle {
    var week: String = ""
    var title: String = ""
    init(week: String, title: String) { self.week = week; self.title = title }

    static func key(for day: Date, calendar: Calendar = Dates.calendar) -> String {
        let day = calendar.startOfDay(for: day)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -offset, to: day)!
        let parts = calendar.dateComponents([.year, .month, .day], from: monday)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func validKey(_ key: String) -> Bool {
        let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(pieces[0]), (1...9999).contains(year), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.weekday, from: date) == 2 else { return false }
        return self.key(for: date, calendar: calendar) == key
    }
    @MainActor static func stage(_ records: [TaskBackup.WeekTitleRecord], in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<CalendarWeekTitle>())
        let values = Dictionary(uniqueKeysWithValues: records.map { ($0.week, $0.title) })
        var seen = Set<String>()
        for row in existing {
            if let title = values[row.week], seen.insert(row.week).inserted { row.title = title }
            else { context.delete(row) }
        }
        for row in records where !seen.contains(row.week) { context.insert(CalendarWeekTitle(week: row.week, title: row.title)) }
    }
}

@Model final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""
    var scheduledAt: Date?
    var hasTime: Bool = false
    var endAt: Date?
    var dueAt: Date?
    var dueHasTime: Bool = false
    var priority: Int = 0
    var isDone: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var reminderAt: Date?
    var reminderKind: String = "legacy"
    var reminderNeedsAttention: Bool = false
    var repeatRule: String = "none"
    var repeatAnchorDay: Int = 0
    /// Nil is an older rule awaiting an explicitly approved timezone migration.
    var repeatTimeZoneID: String?
    /// The last day a repeating task may come back; nil repeats without end.
    var repeatUntil: Date?
    var nextOccurrenceID: UUID?
    var deletedAt: Date?
    var subtasks: [Subtask] = []
    var list: TaskList?
    @Transient var previewSourceID: UUID?
    @Transient var previewList: TaskList?
    var calendarList: TaskList? { previewList ?? list }

    init(title: String, scheduledAt: Date? = nil, list: TaskList? = nil) {
        self.title = title
        self.scheduledAt = scheduledAt
        self.list = list
    }

    /// Moving between lists preserves the task's identity, history and schedule.
    @discardableResult func changeList(to destination: TaskList?) -> Bool {
        guard deletedAt == nil, list?.id != destination?.id else { return false }
        list = destination
        return true
    }

    var calendarDate: Date? { scheduledAt ?? dueAt }
    /// Only an explicitly timed schedule (or a timed deadline without a schedule) has a clock position.
    var clockDate: Date? { scheduledAt != nil ? (hasTime ? scheduledAt : nil) : (dueHasTime ? dueAt : nil) }
    var duration: TimeInterval? {
        guard hasTime, let scheduledAt, let endAt, endAt > scheduledAt else { return nil }
        return endAt.timeIntervalSince(scheduledAt)
    }
    var timeLabel: String {
        guard let clockDate else { return "" }
        let crossDay = endAt.map { !Dates.sameDay(clockDate, $0) } ?? false
        return Dates.label(clockDate, pattern: crossDay ? "M月d日 HH:mm" : "HH:mm") + (endAt.map { "–" + Dates.label($0, pattern: crossDay ? "M月d日 HH:mm" : "HH:mm") } ?? "")
    }
    func proposedEnd(at moment: Date) -> Date { moment.addingTimeInterval(duration ?? 3600) }
    static func plannedBefore(_ a: TaskItem, _ b: TaskItem) -> Bool {
        let calendar = Dates.calendar
        let ad = a.calendarDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        let bd = b.calendarDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        if ad != bd { return ad < bd }
        let at = a.clockDate ?? .distantFuture, bt = b.clockDate ?? .distantFuture
        if at != bt { return at < bt }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
    static func incompleteFirst(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.isDone != b.isDone { return !a.isDone }
        return plannedBefore(a, b)
    }
    private func orderKey(calendar: Calendar) -> (Date, Date, Int, Date, String) {
        (calendarDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture,
         clockDate ?? .distantFuture, -priority, createdAt, id.uuidString)
    }
    /// Read SwiftData and calculate civil dates once per task, rather than on every sort comparison.
    static func ordered(_ tasks: [TaskItem], incompleteFirst: Bool = false, calendar: Calendar = Dates.calendar) -> [TaskItem] {
        tasks.map { (task: $0, done: incompleteFirst && $0.isDone, key: $0.orderKey(calendar: calendar)) }
            .sorted { a, b in a.done != b.done ? !a.done : a.key < b.key }
            .map(\.task)
    }
    func timeConflict(at moment: Date) -> Bool {
        dueAt.map { !Dates.deadlineAllowed(due: $0, dueTimed: dueHasTime, scheduled: proposedEnd(at: moment), scheduledTimed: true) } ?? false
    }
    /// Set an exact start time. A deadline remains independent; callers confirm any extension first.
    func schedule(at moment: Date, extendingDeadline: Bool = false) {
        let ending = proposedEnd(at: moment)
        if timeConflict(at: moment) {
            guard extendingDeadline else { return }
            dueAt = dueHasTime ? ending : Dates.calendar.startOfDay(for: ending)
        }
        let preset = resolvedReminderPreset
        scheduledAt = moment; hasTime = true; endAt = ending
        keepReminder(preset)
        repeatAnchorDay = recurrenceCalendar?.component(.day, from: moment) ?? repeatAnchorDay
    }
    /// Drag on a block's lower edge. The deadline still wins: a longer task may not run past it.
    @discardableResult func resize(to newEnd: Date) -> Bool {
        guard hasTime, let scheduledAt, newEnd > scheduledAt else { return false }
        if let dueAt, !Dates.deadlineAllowed(due: dueAt, dueTimed: dueHasTime, scheduled: newEnd, scheduledTimed: true) { return false }
        endAt = newEnd
        return true
    }
    /// Dropped on the all-day row: keep (or move to) that day, drop the clock time and length.
    func makeAllDay(on day: Date) {
        let preset = resolvedReminderPreset
        scheduledAt = Dates.calendar.startOfDay(for: day); hasTime = false; endAt = nil
        keepReminder(preset)
        repeatAnchorDay = calendarDate.flatMap { recurrenceCalendar?.component(.day, from: $0) } ?? repeatAnchorDay
    }
    /// Dropped on the undated list. A deadline or a repeat rule keeps a task on the calendar, so those are refused.
    @discardableResult func clearSchedule() -> Bool {
        guard dueAt == nil, repeatRule == "none" else { return false }
        let preset = resolvedReminderPreset
        scheduledAt = nil; hasTime = false; endAt = nil
        keepReminder(preset)
        return true
    }
    /// A relative reminder follows the new schedule when it still applies; otherwise its moment is kept as a custom time.
    func keepReminder(_ preset: ReminderPreset) {
        defer { reminderNeedsAttention = reminderRequiresAttention() }
        guard reminderAt != nil, preset != .custom else { return }
        let timed = scheduledAt != nil ? hasTime : dueHasTime
        if let calendar = recurrenceCalendar, let moved = preset.date(base: calendarDate, timed: timed, calendar: calendar) { reminderAt = moved }
        else { reminderKind = ReminderPreset.custom.rawValue }
    }
    func reminderRequiresAttention(now: Date = Date()) -> Bool {
        guard !isDone, let reminderAt else { return false }
        if reminderAt <= now { return true }
        guard let day = calendarDate else { return false }
        guard let calendar = recurrenceCalendar else { return true }
        let latest = clockDate ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!.addingTimeInterval(-1)
        return reminderAt > latest
    }
    var reminderWarning: String? {
        guard reminderRequiresAttention() else { return nil }
        return reminderAt! <= Date() ? L("提醒时间已过，请重新安排", "Reminder time has passed; choose a new time")
            : L("提醒晚于任务开始，请检查提醒时间", "Reminder is after the task starts; check its time")
    }
    var completionSortDate: Date { completedAt ?? createdAt }
    var resolvedReminderPreset: ReminderPreset {
        guard reminderAt != nil else { return .none }
        // Older stores have no choice metadata: preserve the exact saved moment.
        return ReminderPreset(rawValue: reminderKind) ?? .custom
    }
    /// Moving the scheduled date to `day` would put it after the deadline.
    func deadlineConflict(movingTo day: Date) -> Bool {
        guard let scheduledAt, let dueAt else { return false }
        return !Dates.deadlineAllowed(due: dueAt, dueTimed: dueHasTime, scheduled: Dates.replacingDay(of: scheduledAt, with: day).addingTimeInterval(duration ?? 0), scheduledTimed: hasTime)
    }

    /// The deadline after moving to `day`, extended only as far as needed: onto the new day,
    /// and no earlier than the scheduled time when both have times.
    func extendedDeadline(movingTo day: Date) -> Date? {
        guard let scheduledAt, let dueAt else { return dueAt }
        let moved = Dates.replacingDay(of: scheduledAt, with: day).addingTimeInterval(duration ?? 0)
        guard !Dates.deadlineAllowed(due: dueAt, dueTimed: dueHasTime, scheduled: moved, scheduledTimed: hasTime) else { return dueAt }
        let due = Dates.replacingDay(of: dueAt, with: moved)
        return dueHasTime && hasTime && due < moved ? moved : due
    }

    func reschedule(to day: Date, extendingDeadline: Bool = false) {
        guard extendingDeadline || !deadlineConflict(movingTo: day) else { return }
        let length = duration
        if extendingDeadline { dueAt = extendedDeadline(movingTo: day) }
        if let scheduledAt { self.scheduledAt = Dates.replacingDay(of: scheduledAt, with: day) }
        else if let dueAt { self.dueAt = Dates.replacingDay(of: dueAt, with: day) }
        else { scheduledAt = Dates.calendar.startOfDay(for: day) }
        if let length, let scheduledAt { endAt = scheduledAt.addingTimeInterval(length) }
        keepReminder(resolvedReminderPreset)
        repeatAnchorDay = calendarDate.flatMap { recurrenceCalendar?.component(.day, from: $0) } ?? repeatAnchorDay
    }

    func appearsInCalendar(on selected: Date, wholeMonth: Bool) -> Bool {
        guard let interval = Dates.calendar.dateInterval(of: wholeMonth ? .month : .day, for: selected) else { return false }
        return overlaps(interval)
    }

    /// End is exclusive: ending at midnight does not occupy the following day.
    func overlaps(_ interval: DateInterval) -> Bool {
        guard deletedAt == nil, let start = calendarDate else { return false }
        if hasTime, scheduledAt != nil, let endAt, endAt > start {
            return start < interval.end && endAt > interval.start
        }
        return start >= interval.start && start < interval.end
    }

    /// Unfinished and its day (scheduled, or deadline when unscheduled) is before today.
    /// These are listed under the calendar instead of on each later day.
    func isOverdue(today: Date = Date()) -> Bool {
        guard deletedAt == nil, !isDone, let calendarDate else { return false }
        if let endAt, endAt > today { return false }
        return calendarDate < Dates.calendar.startOfDay(for: today)
    }

    /// Deadline countdown for unfinished tasks; completed tasks just show the date.
    func deadlineCountdown(now: Date = Date()) -> DeadlineCountdown? {
        guard let dueAt else { return nil }
        return isDone ? nil : DeadlineCountdown(due: dueAt, timed: dueHasTime, now: now)
    }
}

struct DeadlineCountdown: Equatable {
    enum Level { case normal, soon, today, overdue }
    let level: Level
    /// "还剩 3 天", "今天 18:00 截止", "已逾期 2 天"
    let short: String

    /// Days left counts calendar days; 1–3 days left is "soon".
    init(due: Date, timed: Bool, now: Date) {
        let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: now), to: Dates.calendar.startOfDay(for: due)).day ?? 0
        let time = Dates.label(due, pattern: "HH:mm")
        if days < 0 {
            level = .overdue
            short = L("已逾期 \(-days) 天", "Overdue by \(-days) \(-days == 1 ? "day" : "days")")
        } else if days == 0 {
            if timed && due < now {
                level = .overdue; short = L("今天 \(time) 已截止", "Was due today at \(time)")
            } else {
                level = .today; short = timed ? L("今天 \(time) 截止", "Due today at \(time)") : L("今天截止", "Due today")
            }
        } else {
            level = days <= 3 ? .soon : .normal
            short = L("还剩 \(days) 天", "\(days) \(days == 1 ? "day" : "days") left")
        }
    }

    /// Row text: today and overdue speak for themselves; otherwise the date plus days left.
    func text(due: Date, timed: Bool) -> String {
        switch level {
        case .today, .overdue: short
        case .normal, .soon: L("截止 ", "Due ") + Dates.label(due, pattern: timed ? "M月d日 HH:mm" : "M月d日") + " · " + short
        }
    }
}

enum TaskScope: Hashable {
    case calendar, all, unscheduled, completed, trash, list(UUID)

    var title: String { localizedTitle(UISettings.language) }

    func localizedTitle(_ language: String) -> String {
        switch self {
        case .calendar: L("日历", "Calendar", language: language)
        case .all: L("全部任务", "All tasks", language: language)
        case .unscheduled: L("无日期任务", "Undated tasks", language: language)
        case .completed: L("已完成", "Completed", language: language)
        case .trash: L("最近删除", "Recently deleted", language: language)
        case .list: L("清单", "List", language: language)
        }
    }

    var icon: String {
        switch self {
        case .calendar: "calendar"
        case .all: "list.bullet"
        case .unscheduled: "tray"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        case .list: "list.bullet.rectangle"
        }
    }

    static let standard: [Self] = [.calendar, .all, .unscheduled, .completed, .trash]

    /// Native sidebar sections and the custom animated rows share one visible keyboard order.
    func adjacentSidebarScope(direction: Int, lists: [TaskList], expanded: Set<UUID>) -> Self {
        let order = Self.standard + ListNode.visibleIDs(ListNode.roots(lists), expanded: expanded).map(Self.list)
        let index = order.firstIndex(of: self) ?? 0
        return order[min(max(index + direction, 0), order.count - 1)]
    }
}
