import Foundation
import SwiftData
import Observation
import SQLite3
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
        repeatAnchorDay = Dates.calendar.component(.day, from: moment)
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
        repeatAnchorDay = Dates.calendar.component(.day, from: day)
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
    fileprivate func keepReminder(_ preset: ReminderPreset) {
        defer { reminderNeedsAttention = reminderRequiresAttention() }
        guard reminderAt != nil, preset != .custom else { return }
        let timed = scheduledAt != nil ? hasTime : dueHasTime
        if let moved = preset.date(base: calendarDate, timed: timed) { reminderAt = moved }
        else { reminderKind = ReminderPreset.custom.rawValue }
    }
    func reminderRequiresAttention(now: Date = Date()) -> Bool {
        guard !isDone, let reminderAt else { return false }
        if reminderAt <= now { return true }
        guard let day = calendarDate else { return false }
        let latest = clockDate ?? Dates.calendar.date(byAdding: .day, value: 1, to: Dates.calendar.startOfDay(for: day))!.addingTimeInterval(-1)
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
    func repeatAnchor(for base: Date, rule: String) -> Int {
        if rule == repeatRule, let original = calendarDate, Dates.sameDay(original, base), repeatAnchorDay > 0 { return repeatAnchorDay }
        return Dates.calendar.component(.day, from: base)
    }

    @MainActor func toggleCompletion(in context: ModelContext, now: Date = Date()) {
        isDone.toggle(); completedAt = isDone ? now : nil
        ensureNextOccurrence(in: context, now: now)
    }

    /// A moved occurrence cannot keep a successor that is now before it. Missing/deleted successors
    /// retain the link, so deleting a future task does not silently restart a stopped series.
    func repeatLinkIsStale(_ next: TaskItem?) -> Bool {
        guard let next, next.deletedAt == nil, let base = calendarDate, let following = next.calendarDate else { return false }
        return following <= base
    }

    @MainActor func ensureNextOccurrence(in context: ModelContext, now: Date = Date()) {
        guard isDone, deletedAt == nil, repeatRule != "none", let base = calendarDate,
              let nextDate = Dates.nextRepeat(base, rule: repeatRule, anchorDay: repeatAnchorDay, after: now, until: repeatUntil) else { return }
        if let nextID = nextOccurrenceID {
            var query = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == nextID })
            query.fetchLimit = 1
            guard let matches = try? context.fetch(query), repeatLinkIsStale(matches.first) else { return }
        }
        let nextID = Self.syncIdentity(id.uuidString + ":" + String(Int64(nextDate.timeIntervalSince1970.rounded())))
        let existing = (try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == nextID })))?.first
        if existing != nil { nextOccurrenceID = nextID; return }
        let next = occurrence(at: nextDate)
        next.reminderNeedsAttention = next.reminderRequiresAttention(now: now)
        nextOccurrenceID = next.id
        context.insert(next)
    }

    static func syncIdentity(_ key: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return hash.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    /// Both the calendar preview and completion use the same recurrence fields and date rules.
    func occurrence(at nextDate: Date, preview: Bool = false, calendar: Calendar = Dates.calendar) -> TaskItem {
        let base = calendarDate!
        // Preview objects never join a persisted list relationship.
        let next = TaskItem(title: title, scheduledAt: scheduledAt == nil ? nil : nextDate, list: preview ? nil : list)
        let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: nextDate)).day ?? 0
        next.endAt = duration.map { nextDate.addingTimeInterval($0) }
        next.notes = notes; next.hasTime = hasTime; next.dueHasTime = dueHasTime; next.priority = priority
        next.dueAt = dueAt.flatMap { calendar.date(byAdding: .day, value: dayOffset, to: $0) }
        next.repeatRule = repeatRule; next.repeatUntil = repeatUntil
        next.repeatAnchorDay = repeatAnchorDay > 0 ? repeatAnchorDay : calendar.component(.day, from: base)
        if preview {
            next.previewSourceID = id; next.previewList = list
            var uuid = id.uuid
            var stamp = nextDate.timeIntervalSince1970.bitPattern.bigEndian
            withUnsafeBytes(of: &stamp) { time in
                withUnsafeMutableBytes(of: &uuid) { bytes in
                    for index in 0..<8 { bytes[index + 8] ^= time[index] }
                }
            }
            next.id = UUID(uuid: uuid)
        } else {
            // The same repeat completed offline on two devices must produce the same next task.
            let key = id.uuidString + ":" + String(Int64(nextDate.timeIntervalSince1970.rounded()))
            next.id = Self.syncIdentity(key)
            next.createdAt = nextDate
            next.reminderKind = reminderKind
            next.reminderAt = reminderDate(forOccurrenceAt: nextDate, calendar: calendar)
            next.subtasks = subtasks.map { Subtask(id: Self.syncIdentity(key + ":" + $0.id.uuidString), title: $0.title) }
        }
        return next
    }

    /// The reminder a later time of this repeating task gets: the same relative choice counted from that time,
    /// or a custom moment moved by whole days (so it keeps its local clock time).
    func reminderDate(forOccurrenceAt nextDate: Date, calendar: Calendar = Dates.calendar) -> Date? {
        guard let reminderAt, let base = calendarDate else { return nil }
        if resolvedReminderPreset == .custom {
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: nextDate)).day ?? 0
            return calendar.date(byAdding: .day, value: dayOffset, to: reminderAt)
        }
        return resolvedReminderPreset.date(base: nextDate, timed: scheduledAt != nil ? hasTime : dueHasTime, calendar: calendar)
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
        repeatAnchorDay = Dates.calendar.component(.day, from: day)
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

/// Reminder choices shown in the editor. Relative choices follow the task's date, so the
/// reminder moves when the schedule changes; `custom` keeps an exact date and time.
enum ReminderPreset: String, CaseIterable, Identifiable {
    case none, atTime, tenMinutes, oneHour, morning, dayBefore, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L("不提醒", "None")
        case .atTime: L("准时", "At time of task")
        case .tenMinutes: L("提前 10 分钟", "10 minutes before")
        case .oneHour: L("提前 1 小时", "1 hour before")
        case .morning: L("当天 9:00", "On the day, 9:00")
        case .dayBefore: L("前一天 9:00", "Day before, 9:00")
        case .custom: L("自定义…", "Custom…")
        }
    }

    /// Menu title with the resulting clock time, e.g. "提前 10 分钟 · 14:50".
    func menuTitle(base: Date?, timed: Bool) -> String {
        guard timed, self != .none, self != .custom, let when = date(base: base, timed: timed) else { return title }
        return title + " · " + Dates.label(when, pattern: "HH:mm")
    }

    /// A reminder may not come after the task: its time, or the end of its day when it has no time.
    static func latest(base: Date?, timed: Bool) -> Date? {
        guard let base else { return nil }
        if timed { return base }
        return Dates.calendar.date(bySettingHour: 23, minute: 59, second: 0, of: base)
    }

    /// `base` is the task's scheduled moment (or its day when `timed` is false).
    static func options(base: Date?, timed: Bool) -> [Self] {
        guard base != nil else { return [.none, .custom] }
        return timed ? [.none, .atTime, .tenMinutes, .oneHour, .custom] : [.none, .morning, .dayBefore, .custom]
    }

    func date(base: Date?, timed: Bool, calendar: Calendar = Dates.calendar) -> Date? {
        guard let base, Self.options(base: base, timed: timed).contains(self) else { return nil }
        let day = calendar.startOfDay(for: base)
        switch self {
        case .atTime: return base
        case .tenMinutes: return base.addingTimeInterval(-600)
        case .oneHour: return base.addingTimeInterval(-3600)
        case .morning: return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        case .dayBefore: return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: -1, to: day)!)
        case .none, .custom: return nil
        }
    }

    static func infer(reminder: Date?, base: Date?, timed: Bool) -> Self {
        guard let reminder else { return .none }
        return options(base: base, timed: timed).first { preset in
            preset.date(base: base, timed: timed).map { abs($0.timeIntervalSince(reminder)) < 1 } ?? false
        } ?? .custom
    }
}

/// iOS delivers notification taps before a window may exist. Keep only the ID until
/// an active window accepts it, then let that window defer navigation during edits.
@MainActor @Observable final class ReminderInbox {
    static let shared = ReminderInbox()
    var navigation = ReminderNavigation()
    func receive(_ id: UUID) { navigation.pendingTaskID = id }
}

/// Value-only pending navigation survives cold startup and model-context recovery with the window drafts.
struct ReminderNavigation {
    var pendingTaskID: UUID?
    static let prefix = "jianshi-reminder-"
    /// A "remind me later" copy. Its own prefix keeps it out of the scheduled-reminder reconciliation.
    static let snoozePrefix = "jianshi-snooze-"
    /// "jianshi-reminder-<task id>", optionally followed by "@<time>" for a later time of a repeating task.
    static func taskID(request: String) -> UUID? {
        for start in [prefix, snoozePrefix] where request.hasPrefix(start) {
            let rest = request.dropFirst(start.count)
            guard rest.count == 36 || rest.dropFirst(36).first == "@" || rest.dropFirst(36).first == "-" else { return nil }
            return UUID(uuidString: String(rest.prefix(36)))
        }
        return nil
    }
    static func url(_ id: UUID) -> URL { URL(string: "jianshi://reminder/" + id.uuidString)! }
    static func taskID(url: URL) -> UUID? {
        guard url.scheme == "jianshi", url.host == "reminder", url.pathComponents.count == 2,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    mutating func take(blocked: Bool) -> UUID? {
        guard !blocked else { return nil }
        defer { pendingTaskID = nil }
        return pendingTaskID
    }
}

enum UISettings {
    static func resolvedLanguage(_ preference: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if preference == "zh" || preference == "en" { return preference! }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first
            if code == "zh" { return "zh" }
            if code == "en" { return "en" }
        }
        return "en"
    }
    static var language: String { resolvedLanguage(UserDefaults.standard.string(forKey: "appLanguage")) }
    static var locale: Locale { locale(for: UserDefaults.standard.string(forKey: "appLanguage")) }
    static func locale(for preference: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        Locale(identifier: resolvedLanguage(preference, preferredLanguages: preferredLanguages) == "en" ? "en_US" : "zh_CN")
    }

    static func backupFailure(_ stored: String, language: String? = nil) -> String {
        guard !stored.isEmpty else { return "" }
        var detail = stored
        for prefix in ["自动备份未完成：", "Automatic backup failed: "] where detail.hasPrefix(prefix) {
            detail.removeFirst(prefix.count)
        }
        return L("自动备份未完成：", "Automatic backup failed: ", language: language) + detail
    }
}

func L(_ chinese: String, _ english: String, language: String? = nil) -> String {
    UISettings.resolvedLanguage(language ?? UISettings.language) == "en" ? english : chinese
}

enum Dates {
    /// Calendar canvases use wall-clock minutes, not elapsed time since midnight (DST days are 23/25 hours).
    static func clockMinute(_ date: Date, calendar: Calendar = Dates.calendar) -> Double {
        let p = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((p.hour ?? 0) * 60 + (p.minute ?? 0)) + Double(p.second ?? 0) / 60
    }
    static func clockTime(on day: Date, minute: Int, reference: Date? = nil, calendar: Calendar = Dates.calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        if minute >= 1440 { return calendar.date(byAdding: .day, value: 1, to: start)! }
        let m = max(0, minute)
        func resolve(_ policy: Calendar.RepeatedTimePolicy) -> Date {
            calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(hour: m / 60, minute: m % 60, second: 0),
                              matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: policy)!
        }
        let first = resolve(.first)
        // Keep the existing occurrence of an ambiguous autumn hour when editing that same day.
        if let reference, calendar.isDate(reference, inSameDayAs: day) {
            let last = resolve(.last)
            if calendar.timeZone.secondsFromGMT(for: last) == calendar.timeZone.secondsFromGMT(for: reference) { return last }
        }
        return first
    }
    static func clockSpan(from start: Date, to end: Date, on day: Date, calendar: Calendar = Dates.calendar) -> (start: Double, end: Double) {
        let midnight = calendar.startOfDay(for: day), next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        let lower = max(start, midnight), upper = min(end, next)
        let a = lower <= midnight ? 0 : clockMinute(lower, calendar: calendar)
        let b = upper >= next ? 1440 : clockMinute(upper, calendar: calendar)
        // A repeated hour can end at an earlier clock reading. Keep that interval visible, never negative.
        return (a, b > a ? b : min(1440, a + max(0, upper.timeIntervalSince(lower) / 60)))
    }

    static func changingEndClock(_ value: Date, start: Date, end: Date) -> Date {
        var candidate = replacingDay(of: value, with: end)
        if candidate <= start {
            candidate = replacingDay(of: value, with: start)
            if candidate <= start { candidate = calendar.date(byAdding: .day, value: 1, to: candidate)! }
        }
        return candidate
    }

    /// The next time a repeating task comes back after `now`, or nil once that would be past `until` (a whole day).
    /// Missed occurrences are skipped rather than piled up.
    static func nextRepeat(_ base: Date, rule text: String, anchorDay: Int, after now: Date, until: Date? = nil) -> Date? {
        guard let rule = RepeatRule(text), let next = nextOccurrence(base, rule: rule, anchorDay: anchorDay, after: now) else { return nil }
        if let until, calendar.startOfDay(for: next) > calendar.startOfDay(for: until) { return nil }
        return next
    }

    private static func nextOccurrence(_ base: Date, rule: RepeatRule, anchorDay: Int, after now: Date) -> Date? {
        let cal = calendar, n = rule.interval
        switch rule.unit {
        case .day, .week:
            if rule.unit == .week, !rule.weekdays.isEmpty {
                // Chosen weekdays, in every n-th week counted from the task's own week.
                guard let baseWeek = cal.dateInterval(of: .weekOfYear, for: base)?.start else { return nil }
                var day = cal.startOfDay(for: max(base, now))
                for _ in 0..<(7 * n + 14) {
                    if let week = cal.dateInterval(of: .weekOfYear, for: day)?.start {
                        let weeks = (cal.dateComponents([.day], from: baseWeek, to: week).day ?? 0) / 7
                        let candidate = replacingDay(of: base, with: day)
                        if weeks >= 0, weeks % n == 0, rule.weekdays.contains(cal.component(.weekday, from: day)), candidate > now, candidate > base {
                            return candidate
                        }
                    }
                    guard let following = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
                    day = following
                }
                return nil
            }
            let step = rule.unit == .day ? n : 7 * n
            let elapsed = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: base), to: cal.startOfDay(for: now)).day ?? 0)
            let steps = max(1, elapsed / step)
            guard let candidate = cal.date(byAdding: .day, value: steps * step, to: base) else { return nil }
            return candidate > now ? candidate : cal.date(byAdding: .day, value: step, to: candidate)
        case .month:
            let months = max(n, (cal.dateComponents([.month], from: monthStart(base), to: monthStart(now)).month ?? n) / n * n)
            func candidate(_ offset: Int) -> Date? {
                let month = shiftMonth(base, by: offset)
                let last = cal.range(of: .day, in: .month, for: month)!.count
                var parts = cal.dateComponents([.year, .month], from: month)
                parts.day = min(max(1, anchorDay > 0 ? anchorDay : cal.component(.day, from: base)), last)
                parts.hour = cal.component(.hour, from: base); parts.minute = cal.component(.minute, from: base)
                return cal.date(from: parts)
            }
            guard let date = candidate(months) else { return nil }
            return date > now ? date : candidate(months + n)
        case .year:
            let years = max(n, (cal.dateComponents([.year], from: base, to: now).year ?? n) / n * n)
            func candidate(_ offset: Int) -> Date? {
                guard let year = cal.date(byAdding: .year, value: offset, to: base),
                      let days = cal.range(of: .day, in: .month, for: year) else { return nil }
                var parts = cal.dateComponents([.year, .month, .hour, .minute, .second], from: year)
                parts.day = min(max(1, anchorDay > 0 ? anchorDay : cal.component(.day, from: base)), days.count)
                return cal.date(from: parts)
            }
            guard let date = candidate(years) else { return nil }
            return date > now ? date : candidate(years + n)
        }
    }

    /// "3 小时 30 分" / "45 分钟"
    static func durationLabel(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("\(rest) 分钟", "\(rest) min") }
        if rest == 0 { return L("\(hours) 小时", "\(hours) h") }
        return L("\(hours) 小时 \(rest) 分", "\(hours) h \(rest) min")
    }

    static func repeatLabel(_ rule: String) -> String {
        RepeatRule(rule)?.label ?? L("不重复", "Never")
    }

    /// A deadline may not come before the scheduled moment. Without times, whole days are compared.
    static func deadlineAllowed(due: Date, dueTimed: Bool, scheduled: Date?, scheduledTimed: Bool) -> Bool {
        guard let scheduled else { return true }
        if dueTimed && scheduledTimed { return due >= scheduled }
        return calendar.startOfDay(for: due) >= calendar.startOfDay(for: scheduled)
    }

    static func selectionAfterDayChange(_ selected: Date, previousToday: Date, now: Date) -> Date {
        sameDay(selected, previousToday) ? now : selected
    }

    static func groupLabel(_ date: Date, today: Date) -> String {
        if date == .distantFuture { return L("无日期", "No date") }
        if sameDay(date, today) { return L("今天", "Today") }
        return label(date, pattern: calendar.isDate(date, equalTo: today, toGranularity: .year) ? "M月d日" : "yyyy年M月d日")
    }

    static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = UISettings.locale
        return formatter.monthSymbols[month - 1]
    }
    static var weekdays: [String] {
        UISettings.language == "en" ? ["M", "T", "W", "T", "F", "S", "S"] : ["一", "二", "三", "四", "五", "六", "日"]
    }
    static func formatPattern(_ pattern: String, language: String) -> String {
        guard language == "en" else { return pattern }
        return ["M月d日 EEEE": "MMM d, EEEE", "yyyy年M月": "MMMM yyyy", "M月安排": "MMMM", "yyyy年M月d日": "MMM d, yyyy", "M月d日 E": "MMM d, E", "M月d日": "MMM d", "M月d日 HH:mm": "MMM d, HH:mm", "M月d日 E HH:mm": "MMM d, E HH:mm", "d日": "d", "yyyy年": "yyyy"][pattern] ?? pattern
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = UISettings.locale
        calendar.firstWeekday = 2
        return calendar
    }

    static func monthStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)!.start
    }

    static func monthCells(_ date: Date) -> [Date] {
        let start = monthStart(date)
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        let days = calendar.range(of: .day, in: .month, for: date)!.count
        let count = ((offset + days + 6) / 7) * 7
        return (0..<count).map { calendar.date(byAdding: .day, value: $0 - offset, to: start)! }
    }

    static func shiftMonth(_ date: Date, by amount: Int) -> Date {
        calendar.date(byAdding: .month, value: amount, to: monthStart(date))!
    }

    static func weekCells(_ date: Date) -> [Date] {
        let offset = (calendar.component(.weekday, from: date) + 5) % 7
        let start = calendar.startOfDay(for: date)
        return (0..<7).map { calendar.date(byAdding: .day, value: $0 - offset, to: start)! }
    }

    static func replacingDay(of date: Date, with day: Date) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: date)
        parts.hour = time.hour; parts.minute = time.minute
        return calendar.date(from: parts) ?? day
    }

    static func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    static func label(_ date: Date, pattern: String = "M月d日 EEEE") -> String {
        let cal = calendar, locale = UISettings.locale
        let format = formatPattern(pattern, language: UISettings.language)
        let key = locale.identifier + "|" + cal.timeZone.identifier + "|" + format
        // Native formatters are expensive to create on every calendar card. Keep a small per-thread cache.
        let storage = Thread.current.threadDictionary
        var cache = storage["Tally.dateFormatters"] as? [String: DateFormatter] ?? [:]
        if let formatter = cache[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.calendar = cal; formatter.locale = locale; formatter.dateFormat = format
        if cache.count >= 32 { cache.removeAll() }
        cache[key] = formatter; storage["Tally.dateFormatters"] = cache
        return formatter.string(from: date)
    }

    static func matches(_ date: Date?, selected: Date, wholeMonth: Bool) -> Bool {
        guard let date else { return false }
        return wholeMonth ? calendar.isDate(date, equalTo: selected, toGranularity: .month) : sameDay(date, selected)
    }
}

/// A failed context is never reused. Recovery opens the last committed store;
/// editor drafts live outside this context and are applied only after another Save.
@MainActor @Observable final class StoreRecovery {
    private(set) var failure: String?
    private(set) var container: ModelContainer?
    private(set) var generation = 0
    @ObservationIgnored private var url: URL?
    // ModelContainer is Equatable, not Hashable; retire the exact instance without invoking its hash.
    @ObservationIgnored private let retired = NSHashTable<ModelContainer>(options: [.weakMemory, .objectPointerPersonality])

    func requireWritable(_ context: ModelContext) throws {
        guard failure == nil, !retired.contains(context.container) else {
            throw TaskBackup.invalid(L("保存已暂停，请先重新载入数据。", "Saving is paused. Reload your data first."))
        }
    }
    func failed(_ error: Error, in context: ModelContext) {
        retired.add(context.container)
        url = context.container.configurations.first?.url
        failure = error.localizedDescription
    }
    @discardableResult func reload() -> Bool {
        guard failure != nil, let url else { return false }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TaskBackup.invalid(L("找不到原数据文件，请恢复文件位置后重试。未创建空数据库。", "The original data file is missing. Restore its location and retry. No empty database was created."))
            }
            let fresh = try Store.make(url: url)
            // Do not enable editing until both model collections can be read.
            _ = try fresh.mainContext.fetch(FetchDescriptor<TaskItem>())
            _ = try fresh.mainContext.fetch(FetchDescriptor<TaskList>())
            _ = try FinanceStore.read(fresh.mainContext)
            container = fresh
            Store.invalidateHistory()
            generation += 1
            failure = nil
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}

@MainActor enum Store {
    static let recovery = StoreRecovery()
    static var didSave: ((ModelContext) -> Void)?
    private(set) static var revision = 0
    static func make(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            #if os(macOS) && JIANSHI_APP_STORE
            // Older development builds may have left a stale Jianshi.store in this container.
            // Use a distinct location and explicitly import a current portable backup.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Jianshi", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema,
                url: directory.appendingPathComponent("Tasks.store"), cloudKitDatabase: .none)
            #else
            configuration = ModelConfiguration("Jianshi", schema: schema, cloudKitDatabase: .none)
            #endif
        }
        // Only protect the user store here. Tests and explicit file tools choose their own snapshots.
        if url == nil { _ = try StoreUpgradeSnapshot.prepare(configuration.url) }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    static func invalidateHistory() { revision += 1 }
    static func failureMessage(_ error: Error) -> String {
        L("修改未保存。请使用“重新载入数据”恢复操作；编辑草稿会保留，载入后请检查并再次保存。", "Changes were not saved. Reload data to continue; editor drafts are kept. Review and save them after reloading.") + "\n" + error.localizedDescription
    }
    static func save(_ context: ModelContext) throws {
        try recovery.requireWritable(context)
        do {
            ListColor.normalize(try context.fetch(FetchDescriptor<TaskList>()))
            let changed = context.hasChanges
            try context.save()
            if changed { revision += 1 }
        }
        catch {
            context.processPendingChanges()
            context.rollback()
            recovery.failed(error, in: context)
            throw error
        }
        didSave?(context)
    }
}

/// A consistent SQLite snapshot before opening each new schema generation.
/// SQLite's backup API includes committed WAL data even while another connection is open.
/// This is a local rollback artifact, not a sync queue or a replacement for portable JSON backups.
enum StoreUpgradeSnapshot {
    // Bump for a persisted-schema change, not for every app build. Keep prior generations.
    static let generation = "schema-v1"
    static func prepare(_ source: URL, generation: String = StoreUpgradeSnapshot.generation) throws -> URL? {
        guard !generation.isEmpty, generation.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return nil }
        let directory = source.deletingLastPathComponent().appendingPathComponent("SchemaBackups", isDirectory: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent + ".before-" + generation + ".sqlite")
        if files.fileExists(atPath: destination.path) { return destination }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
            defer {
                for suffix in ["", "-wal", "-shm", "-journal"] { try? files.removeItem(atPath: temporary.path + suffix) }
            }
            try snapshot(source, to: temporary)
            try files.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            throw NSError(domain: "Jianshi.StoreUpgrade", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("升级前的数据副本未能保存，已停止打开数据库。请检查磁盘空间和文件权限后重试。", "Could not save the pre-upgrade copy. Opening the database was stopped. Check disk space and file permissions, then retry.") + "\n" + error.localizedDescription])
        }
    }

    private static func snapshot(_ source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        func failure(_ db: OpaquePointer?) -> NSError {
            NSError(domain: "Jianshi.SQLiteSnapshot", code: Int(sqlite3_errcode(db)),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure(output) }
        sqlite3_busy_timeout(input, 1500); sqlite3_busy_timeout(output, 1500)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw failure(output) }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw failure(output) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(output, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else { throw failure(output) }
    }
}

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

/// Portable, versioned local backup. No settings, credentials or notification permission are imported.
struct TaskBackup: Codable {
    var format = "jianshi-backup"
    // Old clients reject this version before merging, instead of silently removing new metadata.
    var version = 7
    var finance: FinanceData? = nil
    var weekTitles: [WeekTitleRecord]? = nil
    var createdAt = Date()
    var lists: [ListRecord]
    var tasks: [TaskRecord]
    struct WeekTitleRecord: Codable, Equatable {
        var week: String
        var title: String
        var id: UUID { TaskItem.syncIdentity("tally-week-title:" + week) }
    }
    struct ListRecord: Codable, Equatable { var id: UUID; var name: String; var createdAt: Date; var parentID: UUID? = nil; var colorHex: String? = nil; var sortOrder: Double? = nil; var emoji: String? = nil }
    struct TaskRecord: Codable, Equatable {
        var id: UUID; var title: String; var notes: String
        var endAt: Date?
        var scheduledAt: Date?; var hasTime: Bool; var dueAt: Date?; var dueHasTime: Bool
        var priority: Int; var isDone: Bool; var completedAt: Date?; var createdAt: Date
        var reminderAt: Date?; var reminderKind: String; var reminderNeedsAttention: Bool
        var repeatRule: String; var repeatAnchorDay: Int; var nextOccurrenceID: UUID?
        var repeatUntil: Date? = nil
        var deletedAt: Date?; var subtasks: [Subtask]; var listID: UUID?

        init(_ task: TaskItem) {
            endAt = task.endAt
            id = task.id; title = task.title; notes = task.notes
            scheduledAt = task.scheduledAt; hasTime = task.hasTime; dueAt = task.dueAt; dueHasTime = task.dueHasTime
            priority = task.priority; isDone = task.isDone; completedAt = task.completedAt; createdAt = task.createdAt
            reminderAt = task.reminderAt; reminderKind = task.reminderKind; reminderNeedsAttention = task.reminderNeedsAttention
            repeatRule = task.repeatRule; repeatAnchorDay = task.repeatAnchorDay; nextOccurrenceID = task.nextOccurrenceID
            repeatUntil = task.repeatUntil
            deletedAt = task.deletedAt; subtasks = task.subtasks; listID = task.list?.id
        }
        func model(list: TaskList?) -> TaskItem {
            let task = TaskItem(title: title, scheduledAt: scheduledAt, list: list)
            apply(to: task, list: list)
            task.reminderNeedsAttention = reminderNeedsAttention || (!isDone && reminderAt.map { $0 <= Date() } == true)
            return task
        }
        func apply(to task: TaskItem, list: TaskList?) {
            task.title = title; task.scheduledAt = scheduledAt; task.list = list
            task.endAt = endAt
            task.id = id; task.notes = notes; task.hasTime = hasTime; task.dueAt = dueAt; task.dueHasTime = dueHasTime
            task.priority = priority; task.isDone = isDone; task.completedAt = completedAt; task.createdAt = createdAt
            task.reminderAt = reminderAt; task.reminderKind = reminderKind
            task.reminderNeedsAttention = reminderNeedsAttention
            task.repeatRule = repeatRule; task.repeatAnchorDay = repeatAnchorDay; task.nextOccurrenceID = nextOccurrenceID
            task.repeatUntil = repeatRule == "none" ? nil : repeatUntil
            task.deletedAt = deletedAt; task.subtasks = subtasks
        }
        var nextCopyDate: Date? {
            guard let start = scheduledAt ?? dueAt else { return nil }
            if scheduledAt != nil ? hasTime : dueHasTime { return endAt ?? start.addingTimeInterval(3600) }
            return Dates.calendar.date(byAdding: .day, value: 1, to: Dates.calendar.startOfDay(for: start))
        }
        /// A copy is an independent open task, never another branch of the original repeat series.
        func duplicate(at moment: Date, timed: Bool, list: TaskList?) -> TaskItem {
            let task = model(list: nil)
            task.id = UUID(); task.createdAt = Date(); task.isDone = false; task.completedAt = nil; task.deletedAt = nil
            task.subtasks = subtasks.map { Subtask(title: $0.title) }
            task.repeatRule = "none"; task.repeatUntil = nil; task.nextOccurrenceID = nil
            let originalDate = task.calendarDate
            let sourceTimed = task.clockDate != nil
            let preset = task.resolvedReminderPreset
            _ = TaskMove(task, to: moment, kind: timed ? .timed : .allDay).apply(to: task, shiftDeadline: true)
            if preset == .custom, let reminderAt, let originalDate, let newDate = task.calendarDate {
                if timed && sourceTimed { task.reminderAt = reminderAt.addingTimeInterval(newDate.timeIntervalSince(originalDate)) }
                else {
                    let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: originalDate), to: Dates.calendar.startOfDay(for: newDate)).day ?? 0
                    task.reminderAt = Dates.calendar.date(byAdding: .day, value: days, to: reminderAt)
                }
            }
            task.repeatAnchorDay = 0
            task.reminderNeedsAttention = task.reminderRequiresAttention()
            task.list = list
            return task
        }
    }
    static func invalid(_ message: String) -> NSError { NSError(domain: "Jianshi.Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func validate() throws {
        guard format == "jianshi-backup", (1...7).contains(version) else { throw Self.invalid(L("不是受支持的小记备份版本，请更新 App 后重试。", "Unsupported Tally backup format or version. Update the app and retry.")) }
        try finance?.validate()
        if let weekTitles {
            guard Set(weekTitles.map(\.week)).count == weekTitles.count,
                  weekTitles.allSatisfy({ CalendarWeekTitle.validKey($0.week) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 80 }) else {
                throw Self.invalid(L("周标题备份无效。", "Invalid calendar week titles."))
            }
        }
        let listIDs = Set(lists.map(\.id)), taskIDs = Set(tasks.map(\.id))
        guard listIDs.count == lists.count, taskIDs.count == tasks.count else { throw Self.invalid(L("备份含重复的项目编号。", "Backup contains duplicate identifiers.")) }
        try ListTree.validate(Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.parentID) }))
        let dates = [createdAt] + lists.map(\.createdAt) + tasks.flatMap { [$0.endAt, $0.scheduledAt, $0.dueAt, $0.completedAt, $0.createdAt, $0.reminderAt, $0.deletedAt, $0.repeatUntil].compactMap { $0 } }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970) }) else { throw Self.invalid(L("备份含无效日期。", "Backup contains invalid dates.")) }
        guard lists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && ($0.colorHex.map(TaskList.validColor) ?? true) && ($0.sortOrder?.isFinite ?? true) && ($0.emoji.map(TaskList.validEmoji) ?? true) }),
              tasks.allSatisfy({ task in
                  !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.title.count <= 160 && task.notes.count <= 10000
                  && (task.endAt.map { end in task.hasTime && task.scheduledAt.map { end > $0 } == true } ?? true)
                  && (0...2).contains(task.priority) && (0...31).contains(task.repeatAnchorDay)
                  && RepeatRule.isValid(task.repeatRule)
                  && (task.reminderKind == "legacy" || ReminderPreset(rawValue: task.reminderKind) != nil)
                  && (task.listID.map { listIDs.contains($0) } ?? true) && task.nextOccurrenceID != task.id
                  && task.subtasks.count <= 100 && Set(task.subtasks.map(\.id)).count == task.subtasks.count
                  && task.subtasks.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 160 }
              }) else { throw Self.invalid(L("备份数据无效，未更改任何任务。", "Invalid backup data. No tasks were changed.")) }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return data
    }
    static let largeFileThreshold = 20 * 1024 * 1024
    static func decode(_ data: Data, allowLargeFile: Bool = false) throws -> Self {
        guard allowLargeFile || data.count <= largeFileThreshold else { throw invalid(L("备份较大，请确认后继续读取。", "This is a large backup. Confirm before reading it.")) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let result = try decoder.decode(Self.self, from: data); try result.validate(); return result
    }
    @MainActor static func capture(_ context: ModelContext, includeFinance: Bool = true) throws -> Self {
        Self(finance: includeFinance ? try FinanceStore.read(context) : nil,
             weekTitles: try context.fetch(FetchDescriptor<CalendarWeekTitle>()).map { WeekTitleRecord(week: $0.week, title: $0.title) },
             lists: try context.fetch(FetchDescriptor<TaskList>()).map { ListRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID, colorHex: $0.colorHex, sortOrder: $0.sortOrder, emoji: $0.emoji) },
             tasks: try context.fetch(FetchDescriptor<TaskItem>()).map(TaskRecord.init))
    }
    /// Validate the resulting collection, not just the incoming file, before any mutation.
    func merging(into existing: Self, replace: Bool) throws -> Self {
        try validate()
        var result: Self
        if replace {
            result = self
            if finance == nil { result.finance = existing.finance }
            if weekTitles == nil { result.weekTitles = existing.weekTitles }
        }
        else {
            let listIDs = Set(existing.lists.map(\.id)), taskIDs = Set(existing.tasks.map(\.id))
            result = Self(finance: try existing.finance.map { current in try finance.map { try current.merging($0) } ?? current } ?? finance, lists: existing.lists + lists.filter { !listIDs.contains($0.id) },
                          tasks: existing.tasks + tasks.filter { !taskIDs.contains($0.id) })
            let weeks = Set((existing.weekTitles ?? []).map(\.week))
            result.weekTitles = (existing.weekTitles ?? []) + (weekTitles ?? []).filter { !weeks.contains($0.week) }
        }
        result.version = 7
        try result.validate() // Validate the complete merged graph and records before changing live models.
        return result
    }

    /// Save once: a failed write uses the same protective rollback as normal task edits.
    @MainActor func restore(_ context: ModelContext, replace: Bool) throws {
        try Store.recovery.requireWritable(context)
        let merged = try merging(into: Self.capture(context), replace: replace)
        let oldTasks = try context.fetch(FetchDescriptor<TaskItem>())
        let oldLists = try context.fetch(FetchDescriptor<TaskList>())
        var listsByID = Dictionary(uniqueKeysWithValues: oldLists.map { ($0.id, $0) })
        var taskIDs = Set(oldTasks.map(\.id))
        var parents = replace ? [:] : Dictionary(uniqueKeysWithValues: oldLists.map { ($0.id, $0.parentID) })
        for record in lists where replace || listsByID[record.id] == nil { parents[record.id] = .some(record.parentID) }
        try ListTree.validate(parents)
        if replace {
            oldTasks.forEach { context.delete($0) }; oldLists.forEach { context.delete($0) }
            listsByID = [:]; taskIDs = []
        }
        for record in lists where listsByID[record.id] == nil {
            let list = TaskList(name: record.name); list.id = record.id; list.createdAt = record.createdAt; list.parentID = record.parentID; list.colorHex = record.colorHex; list.sortOrder = record.sortOrder ?? 0; list.emoji = record.emoji
            context.insert(list); listsByID[list.id] = list
        }
        for record in tasks where !taskIDs.contains(record.id) {
            context.insert(record.model(list: record.listID.flatMap { listsByID[$0] }))
        }
        if let finance = merged.finance { try FinanceStore.stage(finance, in: context) }
        if let weekTitles = merged.weekTitles { try CalendarWeekTitle.stage(weekTitles, in: context) }
        try Store.save(context)
    }
    @MainActor static func recoveryURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("JianshiBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("before-last-restore.json")
    }
}

/// Lists can contain tasks as well as child lists. Parent identifiers keep old stores compatible.
enum ListTree {
    static func before(_ a: TaskList, _ b: TaskList) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    enum Placement: Equatable { case before, inside, after }

    /// Where a dragged list would land. The top quarter of a row puts it above that list, the bottom quarter
    /// below, the middle inside it; the "My lists" header puts it back at the top level (`list` is nil).
    /// Rows of the dragged list and its own children are never targets.
    static func dropTarget(pointer: CGPoint, rows: [UUID: CGRect], header: CGRect, area: CGRect = .zero, blocked: (UUID) -> Bool) -> (list: UUID?, placement: Placement)? {
        if header.height > 0, header.contains(pointer) { return (nil, .before) }
        if area.contains(pointer), header.height > 0 {
            // Everything above the first row, including the space between the header and that row.
            let top = rows.values.map(\.minY).min() ?? header.maxY
            if pointer.y < top { return (nil, .before) }
            let bottom = rows.values.map(\.maxY).max() ?? header.maxY
            if pointer.y > bottom { return (nil, .after) }
        }
        guard let (id, frame) = rows.first(where: { $0.value.contains(pointer) }), !blocked(id) else { return nil }
        let y = pointer.y - frame.minY
        return (id, y < frame.height * 0.25 ? .before : y > frame.height * 0.75 ? .after : .inside)
    }
    /// Pure presentation: take out the moving subtree and leave one gap at its proposed destination.
    /// Frames are measured outside the animated row, so springs never feed back into hit testing.
    static func dragPreview(rows: [UUID: CGRect], moving: Set<UUID>, target: (list: UUID?, placement: Placement)?,
                            isDescendant: (UUID, UUID) -> Bool = { $0 == $1 }) -> (offsets: [UUID: CGFloat], gap: CGRect?) {
        let order = rows.keys.sorted { rows[$0]!.minY < rows[$1]!.minY }
        guard let first = order.firstIndex(where: { moving.contains($0) }),
              let last = order.lastIndex(where: { moving.contains($0) }), let target else { return ([:], nil) }
        let start = rows[order[first]]!, end = rows[order[last]]!
        let spacing = order.count > 1 ? max(0, rows[order[1]]!.minY - rows[order[0]]!.maxY) : 8
        let height = end.maxY - start.minY + spacing
        let remaining = order.filter { !moving.contains($0) }
        let insertion: Int
        // Landing inside a list is shown as the slot after it and its visible children, indented one level,
        // so the placeholder never disappears while the pointer rests on a folder.
        var indent = 0.0
        if let id = target.list, let index = remaining.firstIndex(of: id) {
            let afterSubtree = (remaining.lastIndex { isDescendant($0, id) } ?? index) + 1
            switch target.placement {
            case .before: insertion = index
            case .after: insertion = afterSubtree
            case .inside: insertion = afterSubtree; indent = 14
            }
        } else { insertion = target.placement == .before ? 0 : remaining.count }
        var offsets: [UUID: CGFloat] = [:]
        for (index, id) in remaining.enumerated() {
            offsets[id] = (rows[id]!.minY > end.minY ? -height : 0) + (index >= insertion ? height : 0)
        }
        let edge = insertion < remaining.count ? rows[remaining[insertion]]! : remaining.last.flatMap { rows[$0] }.map { CGRect(x: $0.minX, y: $0.maxY + spacing, width: $0.width, height: $0.height) } ?? start
        let y = edge.minY - (edge.minY > end.minY ? height : 0)
        return (offsets, CGRect(x: edge.minX + indent, y: y, width: max(24, edge.width - indent), height: height - spacing))
    }

    static func move(_ list: TaskList, to target: TaskList?, placement: Placement, lists: [TaskList]) throws {
        guard list.id != target?.id else { return }
        let parent = placement == .inside ? target?.id : target?.parentID
        guard !contains(parent, in: list.id, lists: lists) else { throw TaskBackup.invalid(L("不能移入自己的子清单。", "Cannot move inside a descendant.")) }
        guard !lists.contains(where: { $0.id != list.id && $0.parentID == parent && $0.name.localizedCaseInsensitiveCompare(list.name) == .orderedSame }) else {
            throw TaskBackup.invalid(L("目标分组已有同名清单。", "The destination already has a list with that name."))
        }
        var siblings = lists.filter { $0.parentID == parent && $0.id != list.id }.sorted(by: before)
        let index = target == nil && placement == .before ? 0 : placement == .inside ? siblings.count : (siblings.firstIndex { $0.id == target?.id }.map { $0 + (placement == .after ? 1 : 0) } ?? siblings.count)
        list.parentID = parent
        siblings.insert(list, at: index)
        for (index, sibling) in siblings.enumerated() { sibling.sortOrder = Double(index) }
    }

    /// Preserve each child's identity and tasks when deleting its parent. Resolve names before promotion.
    static func promoteChildren(of parent: TaskList, lists: [TaskList]) {
        var siblings = lists.filter { $0.parentID == parent.parentID && $0.id != parent.id }
        var order = (siblings.map(\.sortOrder).max() ?? -1) + 1
        for child in lists.filter({ $0.parentID == parent.id }).sorted(by: before) {
            let original = child.name
            var name = original, number = 2
            while siblings.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                let suffix = " (\(number))"
                name = String(original.prefix(max(0, 40 - suffix.count))) + suffix
                number += 1
            }
            child.name = name; child.parentID = parent.parentID; child.sortOrder = order
            order += 1; siblings.append(child)
        }
    }

    static func contains(_ child: UUID?, in parent: UUID, lists: [TaskList]) -> Bool {
        var cursor = child, seen = Set<UUID>()
        while let id = cursor, seen.insert(id).inserted {
            if id == parent { return true }
            cursor = lists.first { $0.id == id }?.parentID
        }
        return false
    }
    static func path(_ list: TaskList, lists: [TaskList]) -> String {
        var parts = [list.name], cursor = list.parentID, seen: Set<UUID> = [list.id]
        while let id = cursor, seen.insert(id).inserted, let parent = lists.first(where: { $0.id == id }) {
            parts.insert(parent.name, at: 0); cursor = parent.parentID
        }
        return parts.joined(separator: " / ")
    }
    static func validate(_ parents: [UUID: UUID?]) throws {
        for id in parents.keys {
            var cursor: UUID? = id, seen = Set<UUID>()
            while let current = cursor {
                guard seen.insert(current).inserted, let next = parents[current] else {
                    throw TaskBackup.invalid(L("清单分组存在循环或缺失的上级。", "A list hierarchy contains a cycle or missing parent."))
                }
                cursor = next
            }
        }
    }
}

struct ListNode: Identifiable {
    static func visibleIDs(_ nodes: [Self], expanded: Set<UUID>) -> [UUID] {
        nodes.flatMap { node in
            [node.id] + (expanded.contains(node.id) ? visibleIDs(node.children ?? [], expanded: expanded) : [])
        }
    }
    var list: TaskList
    var children: [ListNode]?
    var id: UUID { list.id }
    static func roots(_ lists: [TaskList], parent: UUID? = nil) -> [ListNode] {
        lists.filter { $0.parentID == parent }.sorted(by: ListTree.before).map { list in
            let children = roots(lists, parent: list.id)
            return ListNode(list: list, children: children.isEmpty ? nil : children)
        }
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
    init(_ task: TaskItem) {
        scheduledAt = task.scheduledAt; hasTime = task.hasTime; endAt = task.endAt; dueAt = task.dueAt; dueHasTime = task.dueHasTime
        reminderAt = task.reminderAt; reminderKind = task.reminderKind
        reminderNeedsAttention = task.reminderNeedsAttention; repeatAnchorDay = task.repeatAnchorDay
    }
    func restore(_ task: TaskItem) {
        task.scheduledAt = scheduledAt; task.hasTime = hasTime; task.endAt = endAt; task.dueAt = dueAt; task.dueHasTime = dueHasTime
        task.reminderAt = reminderAt; task.reminderKind = reminderKind
        task.reminderNeedsAttention = reminderNeedsAttention; task.repeatAnchorDay = repeatAnchorDay
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
            task.scheduledAt = start; task.endAt = end
            task.keepReminder(preset)
            task.repeatAnchorDay = Dates.calendar.component(.day, from: start)
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

enum CalendarTaskSearch {
    static func matches(_ task: TaskItem, query: String, includeDeleted: Bool = false) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (includeDeleted || task.deletedAt == nil) && !query.isEmpty && (task.title.localizedStandardContains(query)
            || task.notes.localizedStandardContains(query)
            || task.subtasks.contains { $0.title.localizedStandardContains(query) }
            || task.list?.name.localizedStandardContains(query) == true)
    }
}

/// List-only groups and gaps between tasks; completion does not erase booked time.
struct DaySchedule {
    var clusters: [[TaskItem]]
    var gaps: [Int: Int]
    init(_ items: [TaskItem], day: Date, occupying: [TaskItem]? = nil) {
        let timed = items.filter { $0.clockDate != nil }.sorted {
            let a = Self.startMinute($0, on: day), b = Self.startMinute($1, on: day)
            if a != b { return a < b }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return TaskItem.plannedBefore($0, $1)
        }
        clusters = []
        var clusterEnd = -1
        for task in timed {
            let start = Self.startMinute(task, on: day), end = Self.endMinute(task, on: day)
            if !clusters.isEmpty, start < clusterEnd {
                clusters[clusters.count - 1].append(task); clusterEnd = max(clusterEnd, end)
            } else { clusters.append([task]); clusterEnd = end }
        }
        gaps = [:]
        // Filtering changes the visible rows, not the time already occupied by hidden tasks.
        let booked = PlanBlock.layout((occupying ?? items).filter { $0.deletedAt == nil && $0.duration != nil }, day: day)
        for index in clusters.indices.dropFirst() {
            // A start-only task has no known finish, so do not invent a gap after it.
            guard let previous = Self.span(clusters[index - 1], day: day),
                  let first = clusters[index].first else { continue }
            let start = Self.startMinute(first, on: day)
            guard start > previous.end else { continue }
            let free = PlanBlock.freeTime(booked, from: previous.end, to: start).free
            if free > 0 { gaps[index] = free }
        }
    }
    /// Clusters contain connected intervals: their outer bounds count overlapping minutes once.
    static func span(_ items: [TaskItem], day: Date) -> (start: Int, end: Int)? {
        let intervals = items.filter { $0.duration != nil }
        guard let start = intervals.map({ startMinute($0, on: day) }).min(),
              let end = intervals.map({ endMinute($0, on: day) }).max(), end > start else { return nil }
        return (start, end)
    }
    private static func startMinute(_ task: TaskItem, on day: Date) -> Int {
        guard let clock = task.clockDate else { return 0 }
        return Dates.sameDay(clock, day) ? Dates.calendar.component(.hour, from: clock) * 60 + Dates.calendar.component(.minute, from: clock) : 0
    }
    private static func endMinute(_ task: TaskItem, on day: Date) -> Int {
        let start = startMinute(task, on: day)
        guard task.hasTime, let end = task.endAt else { return start }
        return Dates.sameDay(end, day) ? max(start, Dates.calendar.component(.hour, from: end) * 60 + Dates.calendar.component(.minute, from: end)) : 1440
    }
}

struct PlanBlock: Identifiable {
    let task: TaskItem
    var start: Double
    var end: Double
    var column = 0
    var columns = 1
    var id: UUID { task.id }
    func canResize(on day: Date) -> Bool {
        guard task.hasTime, let end = task.endAt else { return false }
        let start = Dates.calendar.startOfDay(for: day)
        let next = Dates.calendar.date(byAdding: .day, value: 1, to: start)!
        return end > start && end <= next
    }
    /// The visible slice of a continuous task. A midnight end belongs to the previous day only.
    static func segment(from start: Date, to end: Date, on day: Date) -> DateInterval? {
        let midnight = Dates.calendar.startOfDay(for: day)
        let next = Dates.calendar.date(byAdding: .day, value: 1, to: midnight)!
        let lower = max(start, midnight), upper = min(end, next)
        return lower < upper ? DateInterval(start: lower, end: upper) : nil
    }
    static func occupied(_ tasks: [TaskItem], excluding id: UUID) -> [DateInterval] {
        tasks.compactMap { task in
            guard task.id != id, task.deletedAt == nil, !task.isDone, let start = task.clockDate else { return nil }
            let end = task.endAt ?? start.addingTimeInterval(1800)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
    }
    static func overlaps(_ interval: DateInterval, others: [DateInterval]) -> Bool {
        others.contains { $0.start < interval.end && $0.end > interval.start }
    }
    static let displayScale = 1.2
    /// Overlapping intervals share the available width instead of hiding each other.
    static func layout(_ tasks: [TaskItem], day: Date, calendar: Calendar = Dates.calendar) -> [Self] {
        let start = calendar.startOfDay(for: day)
        let finish = calendar.date(byAdding: .day, value: 1, to: start)!
        var blocks = tasks.compactMap { task -> Self? in
            guard task.overlaps(DateInterval(start: start, end: finish)), let time = task.clockDate else { return nil }
            let end = task.endAt ?? time.addingTimeInterval(1800)
            guard time < finish, end > start else { return nil }
            let span = Dates.clockSpan(from: time, to: end, on: day, calendar: calendar)
            return Self(task: task, start: span.start, end: span.end)
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        var group: [Int] = [], ends: [Double] = []
        func finishGroup() { for i in group { blocks[i].columns = ends.count } }
        for i in blocks.indices {
            if let last = ends.max(), blocks[i].start >= last { finishGroup(); group = []; ends = [] }
            let column = ends.firstIndex { $0 <= blocks[i].start } ?? ends.count
            if column == ends.count { ends.append(blocks[i].end) } else { ends[column] = blocks[i].end }
            blocks[i].column = column; group.append(i)
        }
        finishGroup()
        return blocks
    }
}

/// How a day maps onto the timeline: which span is visible and how tall a minute is.
/// Blocks, drops, the resize handle and the "now" line all go through this one mapping.
struct TimelineLayout: Equatable {
    var startMinute: Int
    var endMinute: Int
    /// Points per minute.
    var scale: Double
    var height: Double { Double(endMinute - startMinute) * scale }
    func y(_ minute: Double) -> Double { (minute - Double(startMinute)) * scale }
    /// Text adapts to the true duration, never enlarges it.
    func intervalHeight(from start: Double, to end: Double) -> Double { max(0, end - start) * scale }
    /// The quarter hour a point on the canvas refers to, kept inside the visible span.
    func snapped(_ y: Double, step: Int = 15) -> Int {
        let raw = Double(startMinute) + y / scale
        let value = Int((raw / Double(step)).rounded(.down)) * step
        return min(endMinute - step, max(startMinute, value))
    }
    /// Whole hours to label, e.g. 6:00 … 23:00.
    var hours: [Int] { stride(from: startMinute / 60 * 60, to: endMinute, by: 60).map { $0 } }

    /// Full day shows 0–24. Otherwise 6:00–22:00, widened to hold every block and the current time,
    /// so a normal day fits on one screen without hiding anything.
    static func make(blocks: [PlanBlock], fullDay: Bool, density: Double, nowMinute: Int? = nil) -> Self {
        let scale = min(4, max(0.3, density))
        guard !fullDay else { return Self(startMinute: 0, endMinute: 1440, scale: scale) }
        var start = 6 * 60, end = 22 * 60
        for block in blocks {
            start = min(start, Int(block.start / 60) * 60)
            // An hour of headroom under the last block, so it can still be dragged longer.
            end = max(end, min(1440, Int((block.end / 60).rounded(.up)) * 60 + 60))
        }
        if let nowMinute {
            start = min(start, nowMinute / 60 * 60)
            end = max(end, min(1440, (nowMinute / 60 + 1) * 60))
        }
        start = max(0, min(start, 1440 - 120))
        return Self(startMinute: start, endMinute: min(1440, max(end, start + 120)), scale: scale)
    }
}

extension PlanBlock {
    /// Minutes left unplanned inside the span, and the longest single gap.
    static func freeTime(_ blocks: [Self], from start: Int, to end: Int) -> (free: Int, longest: (start: Int, end: Int)?) {
        var cursor = Double(start), free = 0
        var longest: (start: Int, end: Int)?
        func consider(_ from: Double, _ to: Double) {
            let length = Int(to - from)
            guard length > 0 else { return }
            free += length
            if length > (longest.map { $0.end - $0.start } ?? 0) { longest = (Int(from), Int(to)) }
        }
        for block in blocks.filter({ $0.task.duration != nil }).sorted(by: { $0.start < $1.start }) {
            consider(cursor, min(block.start, Double(end)))
            cursor = max(cursor, block.end)
        }
        consider(cursor, Double(end))
        return (free, longest)
    }
}

/// Narrows the task list beyond the keyword: by list, priority and time span.
struct TaskFilter: Equatable {
    enum ListChoice: Hashable { case any, unfiled, list(UUID) }
    enum Span: String, CaseIterable, Identifiable {
        case any, today, week, month, overdue, undated
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: L("任何时间", "Any time")
            case .today: L("今天", "Today")
            case .week: L("本周", "This week")
            case .month: L("本月", "This month")
            case .overdue: L("已逾期", "Overdue")
            case .undated: L("无日期", "No date")
            }
        }
    }
    var list: ListChoice = .any
    /// -1 means any priority.
    var priority = -1
    var span: Span = .any

    var count: Int { (list == .any ? 0 : 1) + (priority < 0 ? 0 : 1) + (span == .any ? 0 : 1) }
    var isActive: Bool { count > 0 }

    func matches(_ task: TaskItem, lists: [TaskList], today: Date) -> Bool {
        switch list {
        case .any: break
        case .unfiled: if task.calendarList != nil { return false }
        case .list(let id): if !ListTree.contains(task.calendarList?.id, in: id, lists: lists) { return false }
        }
        if priority >= 0 && task.priority != priority { return false }
        switch span {
        case .any: return true
        case .undated: return task.calendarDate == nil
        case .overdue: return task.isOverdue(today: today)
        case .today: return task.appearsInCalendar(on: today, wholeMonth: false)
        case .month: return task.appearsInCalendar(on: today, wholeMonth: true)
        case .week:
            let week = Dates.weekCells(today)
            let from = Dates.calendar.startOfDay(for: week[0])
            let to = Dates.calendar.date(byAdding: .day, value: 1, to: Dates.calendar.startOfDay(for: week[6]))!
            return task.overlaps(DateInterval(start: from, end: to))
        }
    }
}

/// Where the pointer is while a task is dragged inside the week view (Mac), in the panel's coordinate space.
/// Kept free of UI so the rules can be checked: the task keeps the spot it was grabbed by, lands on a quarter hour,
/// and the all-day row, the undated list and the two edges each mean something different.
struct WeekDropGeometry {
    enum Zone: Equatable {
        case none
        case timed(day: Int, minute: Int)
        case allDay(Int)
        case undated
        /// A day in the month view: an index into that month's cells.
        case day(Int)
        }

    /// The whole time grid; it moves up and down as the grid scrolls.
    var canvas: CGRect
    /// The visible part of the grid.
    var viewport: CGRect
    var allDay: CGRect
    var undated: CGRect
    var gutter: Double = 44
    /// An empty strip right of Sunday. On the Mac it is where "next week" lives, so no day column doubles as an edge.
    var trailing: Double = 0
    var layout: TimelineLayout

    var column: Double { max(1, (Double(canvas.width) - gutter - trailing) / 7) }

    func day(at x: Double) -> Int {
        min(6, max(0, Int((x - Double(canvas.minX) - gutter) / column)))
    }

    /// -1 over the hour column (or further left), 1 right of Sunday, beside the visible grid. The seven day
    /// columns are never an edge, so Monday and Sunday stay as easy to drop on as any other day.
    func edgeDirection(pointer: CGPoint) -> Int {
        guard pointer.y >= viewport.minY, pointer.y <= viewport.maxY else { return 0 }
        if undated.width > 0, undated.contains(pointer) { return 0 }
        let x = Double(pointer.x)
        if x < Double(canvas.minX) + gutter { return -1 }
        if x > Double(canvas.maxX) - trailing { return 1 }
        return 0
    }

    /// Scrolls only within a thin band at the top or bottom of the grid (or below it), slowly at first:
    /// a slot near the edge can still be picked without the grid running away.
    static func scrollSpeed(pointer: CGPoint, viewport: CGRect) -> Double {
        guard pointer.x >= viewport.minX, pointer.x <= viewport.maxX, pointer.y >= viewport.minY else { return 0 }
        let band = 32.0, fastest = 10.0
        let top = Double(pointer.y - viewport.minY), bottom = Double(viewport.maxY - pointer.y)
        if top < band { let depth = (band - top) / band; return -fastest * depth * depth }
        if bottom < band { let depth = min(1, (band - bottom) / band); return fastest * depth * depth }
        return 0
    }



    /// Like the static rule, plus: anything above the all-day row (the date row, the toolbar, off the window)
    /// scrolls up at full speed, the way dragging past the other three sides already works.
    /// The all-day row itself never scrolls, so it stays a drop target.
    func scrollSpeed(pointer: CGPoint) -> Double {
        if undated.width > 0, undated.contains(pointer) { return 0 }
        if allDay.height > 0, pointer.y < allDay.minY, pointer.x >= viewport.minX, pointer.x <= viewport.maxX { return -10 }
        return Self.scrollSpeed(pointer: pointer, viewport: viewport)
    }

    /// `grabOffset` is how far below the task's top edge it was picked up; the task keeps that offset.
    func zone(pointer: CGPoint, grabOffset: Double, durationMinutes: Double) -> Zone {
        let x = Double(pointer.x)
        if undated.width > 0, undated.contains(pointer) { return .undated }
        if allDay.contains(pointer) {
            return x < Double(canvas.minX) + gutter ? .none : .allDay(day(at: x))
        }
        guard viewport.contains(pointer) else { return .none }
        if x < Double(canvas.minX) + gutter { return .none }
        if trailing > 0, x > Double(canvas.maxX) - trailing { return .none }
        return .timed(day: day(at: x), minute: minute(pointerY: Double(pointer.y), grabOffset: grabOffset, durationMinutes: durationMinutes))
    }

    /// The start time the task would get: its top edge follows the pointer, rounded to the nearest quarter hour.
    /// A continuation of last night's task may start before midnight, but some of it always stays on the grid.
    func minute(pointerY: Double, grabOffset: Double, durationMinutes: Double) -> Int {
        let top = pointerY - grabOffset - Double(canvas.minY)
        let raw = Double(layout.startMinute) + top / layout.scale
        let snapped = (raw / 15).rounded() * 15
        let earliest = Double(layout.startMinute) - max(0, durationMinutes - 15)
        let latest = Double(layout.endMinute) - 15
        return Int(min(latest, max(earliest, snapped)))
    }
}

/// Where the pointer is while a task is dragged in the Mac month view, in the same panel coordinates.
/// Past the month's left or right side — the sidebar, the strip right of Sunday, outside the window — is an edge;
/// Monday and Sunday themselves never are, so they stay whole drop targets.
struct MonthDropGeometry {
    /// All the cells, moving with the grid if it scrolls.
    var canvas: CGRect
    /// The visible part of the grid.
    var viewport: CGRect
    /// One flag per cell: is it a day of the month shown (the rest are blank)?
    var inMonth: [Bool]

    var rows: Int { inMonth.count / 7 }

    func edgeDirection(pointer: CGPoint) -> Int {
        guard pointer.y >= viewport.minY, pointer.y <= viewport.maxY else { return 0 }
        if pointer.x < viewport.minX { return -1 }
        if pointer.x > viewport.maxX { return 1 }
        return 0
    }

    func zone(pointer: CGPoint) -> WeekDropGeometry.Zone {
        guard viewport.contains(pointer), rows > 0, canvas.width > 0, canvas.height > 0 else { return .none }
        let column = min(6, max(0, Int((pointer.x - canvas.minX) / (canvas.width / 7))))
        let row = Int(floor((pointer.y - canvas.minY) / (canvas.height / CGFloat(rows))))
        guard row >= 0, row < rows else { return .none }
        let index = row * 7 + column
        return inMonth[index] ? .day(index) : .none
    }
}

extension PlanBlock {
    /// The whole civil day; today counts only what is still ahead. No assumed sleeping hours.
    /// Past days have nothing left to plan.
    static let countedStart = 0
    static let countedEnd = 24 * 60
    static func countedSpan(day: Date, now: Date) -> (start: Int, end: Int)? {
        let target = Dates.calendar.startOfDay(for: day), today = Dates.calendar.startOfDay(for: now)
        if target < today { return nil }
        var start = countedStart
        if target == today {
            let parts = Dates.calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            start = minute
        }
        return (min(start, countedEnd), countedEnd)
    }
}

/// Edge navigation requires a deliberate pause; crossing an edge never changes a task's date.
struct WeekEdgeHover {
    private var direction = 0
    private var since = 0.0
    /// Turns a page after resting on an edge for 0.45 s, then again every 0.8 s while still there.
    mutating func step(direction next: Int, now: Double) -> Int {
        if next != direction { direction = next; since = now; return 0 }
        guard next != 0, now - since >= 0.45 else { return 0 }
        since = now + 0.35
        return next
    }
}

/// Window-local cache: pointer movement must not rebuild projected SwiftData objects.
@MainActor final class RepeatPreview {
    private var records: [TaskBackup.TaskRecord] = []
    private var interval: DateInterval?
    private var minute: Int?
    private var result: [TaskItem] = []

    func items(_ tasks: [TaskItem], in range: DateInterval, now: Date = Date()) -> [TaskItem] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let roots = tasks.filter { task in
            task.deletedAt == nil && task.repeatRule != "none" && task.calendarDate != nil
                && (task.nextOccurrenceID == nil || task.repeatLinkIsStale(task.nextOccurrenceID.flatMap { byID[$0] }))
        }
        let key = roots.map(TaskBackup.TaskRecord.init)
        let tick = Int(now.timeIntervalSince1970 / 60)
        if records == key && interval == range && minute == tick { return result }
        records = key; interval = range; minute = tick
        result = roots.flatMap { task -> [TaskItem] in
            var items: [TaskItem] = []
            var after = max(now, range.start.addingTimeInterval(-(task.duration ?? 0) - 1))
            // ponytail: at most 64 projections per series/window; wider future views can page this later.
            for _ in 0..<64 {
                guard let next = Dates.nextRepeat(task.calendarDate!, rule: task.repeatRule,
                    anchorDay: task.repeatAnchorDay, after: after, until: task.repeatUntil), next < range.end else { break }
                if next <= after { break }
                let item = task.occurrence(at: next, preview: true)
                if item.overlaps(range) { items.append(item) }
                after = next
            }
            return items
        }
        return result
    }
}

/// Bucket once per visible range, instead of scanning the entire archive separately for every day.
enum CalendarIndex {
    static func byDay(_ tasks: [TaskItem], days: [Date], calendar: Calendar = Dates.calendar) -> [Date: [TaskItem]] {
        guard let first = days.first, let last = days.last else { return [:] }
        let lower = calendar.startOfDay(for: first)
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
        var result = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0), [TaskItem]()) })
        for task in tasks where task.deletedAt == nil {
            guard let start = task.calendarDate, start < upper else { continue }
            let end = task.duration != nil ? task.endAt! : start.addingTimeInterval(0.001)
            guard end > lower else { continue }
            var day = calendar.startOfDay(for: max(start, lower))
            while day < upper && day < end {
                if result[day] != nil { result[day]!.append(task) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return result
    }
}
