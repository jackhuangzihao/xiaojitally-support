import Foundation
import SwiftData
import CryptoKit
import OSLog

private let recurrenceLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "TaskRecurrence")

extension TaskItem {
    var recurrenceCalendar: Calendar? {
        // Legacy rules retain their old behavior until their timezone is explicitly confirmed.
        guard let repeatTimeZoneID else { return Dates.calendar }
        return Dates.recurrenceCalendar(timeZoneID: repeatTimeZoneID)
    }

    func nextRepeat(after now: Date) -> Date? {
        guard let base = calendarDate, let calendar = recurrenceCalendar else { return nil }
        return Dates.nextRepeat(base, rule: repeatRule, anchorDay: repeatAnchorDay,
                                after: now, until: repeatUntil, calendar: calendar)
    }

    func repeatAnchor(for base: Date, rule: String, calendar: Calendar? = nil) -> Int {
        guard let calendar = calendar ?? recurrenceCalendar else { return repeatAnchorDay }
        if rule == repeatRule, let original = calendarDate, calendar.isDate(original, inSameDayAs: base), repeatAnchorDay > 0 { return repeatAnchorDay }
        return calendar.component(.day, from: base)
    }

    @MainActor func toggleCompletion(in context: ModelContext, now: Date = Date()) {
        guard isDone || repeatRule == "none" || recurrenceCalendar != nil else {
            recurrenceLog.error("Refused completion with an invalid recurrence timezone")
            return
        }
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
        guard isDone, deletedAt == nil, repeatRule != "none",
              let nextDate = nextRepeat(after: now) else { return }
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
        let calendar = repeatTimeZoneID == nil ? calendar : (recurrenceCalendar ?? calendar)
        let base = calendarDate!
        // Preview objects never join a persisted list relationship.
        let next = TaskItem(title: title, scheduledAt: scheduledAt == nil ? nil : nextDate, list: preview ? nil : list)
        let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: nextDate)).day ?? 0
        next.endAt = duration.map { nextDate.addingTimeInterval($0) }
        next.notes = notes; next.hasTime = hasTime; next.dueHasTime = dueHasTime; next.priority = priority
        next.dueAt = dueAt.flatMap { calendar.date(byAdding: .day, value: dayOffset, to: $0) }
        next.repeatRule = repeatRule; next.repeatUntil = repeatUntil; next.repeatTimeZoneID = repeatTimeZoneID
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
        guard let calendar = repeatTimeZoneID == nil ? calendar : recurrenceCalendar else { return nil }
        if resolvedReminderPreset == .custom {
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: nextDate)).day ?? 0
            return calendar.date(byAdding: .day, value: dayOffset, to: reminderAt)
        }
        return resolvedReminderPreset.date(base: nextDate, timed: scheduledAt != nil ? hasTime : dueHasTime, calendar: calendar)
    }

}
