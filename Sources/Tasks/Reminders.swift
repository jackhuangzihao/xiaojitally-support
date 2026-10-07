import SwiftUI
import SwiftData
import Observation
import UserNotifications

/// An immutable plan prevents edits during an async notification call from mixing old and new fields.
/// The buttons on a reminder. An early reminder (before the task starts) offers "Got it"; one at or after the
/// start offers "Mark as completed" — spelled out, since a bare "Done" reads as "dismiss" on Apple systems.
/// Both offer "Remind me later" (10 minutes).
enum ReminderAction {
    static let dueCategory = "jianshi-reminder-due"
    static let earlyCategory = "jianshi-reminder-early"
    static let complete = "jianshi-complete"
    static let acknowledge = "jianshi-acknowledge"
    static let snooze = "jianshi-snooze"
    static let snoozeDelay: TimeInterval = 600
    static var categories: Set<UNNotificationCategory> {
        let later = UNNotificationAction(identifier: snooze, title: L("稍后提醒", "Remind me later"), options: [])
        return [
            UNNotificationCategory(identifier: dueCategory, actions: [UNNotificationAction(identifier: complete, title: L("标记为已完成", "Mark as completed"), options: []), later], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: earlyCategory, actions: [UNNotificationAction(identifier: acknowledge, title: L("收到", "Got it"), options: []), later], intentIdentifiers: [], options: []),
        ]
    }
}

struct ReminderEntry: Equatable {
    let id: UUID
    let title: String
    let date: Date
    /// Set for a later time of a repeating task: it is reminded on schedule even if an earlier time is still unticked.
    var occurrence: Date? = nil
    /// Before the task starts (a heads-up), rather than when it is due.
    var early = false
    var identifier: String {
        ReminderNavigation.prefix + id.uuidString + (occurrence.map { "@" + String(Int($0.timeIntervalSince1970)) } ?? "")
    }

    static func upcoming(_ tasks: [TaskItem], now: Date) -> [Self] {
        var entries: [Self] = []
        for task in tasks where !task.isDone && task.deletedAt == nil && task.previewSourceID == nil {
            if let date = task.reminderAt, date > now {
                entries.append(Self(id: task.id, title: task.title, date: date, early: isEarly(date, for: task.calendarDate, timed: task.clockDate != nil)))
            }
            entries += later(task, now: now)
        }
        return entries.sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }
    }

    /// Later times of a repeating task, within the next 60 days (at most 30 of them). Only the newest instance of a
    /// series projects; ticking it off hands the reminders over to the instance it creates, so none is doubled.
    static func later(_ task: TaskItem, now: Date, limit: Int = 30) -> [Self] {
        guard task.repeatRule != "none", task.nextOccurrenceID == nil, task.reminderAt != nil, let base = task.calendarDate else { return [] }
        let horizon = now.addingTimeInterval(60 * 86_400)
        // Start a month back, so a long-missed series still reaches today without walking years of dates.
        var after = max(base, now.addingTimeInterval(-30 * 86_400))
        var result: [Self] = []
        for _ in 0..<500 {
            guard result.count < limit, let next = Dates.nextRepeat(base, rule: task.repeatRule, anchorDay: task.repeatAnchorDay,
                                                                     after: after, until: task.repeatUntil), next > after else { break }
            after = next
            guard let date = task.reminderDate(forOccurrenceAt: next) else { break }
            if date > horizon { break }
            if date > now {
                result.append(Self(id: task.id, title: task.title, date: date, occurrence: next,
                                   early: isEarly(date, for: next, timed: task.clockDate != nil)))
            }
        }
        return result
    }

    /// A timed task: before its start. An all-day task: before its day.
    static func isEarly(_ date: Date, for start: Date?, timed: Bool) -> Bool {
        guard let start else { return false }
        return date < (timed ? start : Dates.calendar.startOfDay(for: start))
    }

    var request: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = early ? L("提前提醒：这件事快到了。", "Coming up soon.") : L("该做这件事了。", "Time for this task."); content.sound = .default
        content.categoryIdentifier = early ? ReminderAction.earlyCategory : ReminderAction.dueCategory
        // An absolute saved instant must not become the other 01:30 when daylight saving ends.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rounded = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
    func matches(_ old: UNNotificationRequest, desired: UNNotificationRequest) -> Bool {
        old.identifier == identifier && old.content.title == desired.content.title && old.content.body == desired.content.body
            && old.content.categoryIdentifier == desired.content.categoryIdentifier
            && (old.trigger as? UNCalendarNotificationTrigger)?.dateComponents == (desired.trigger as? UNCalendarNotificationTrigger)?.dateComponents
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
