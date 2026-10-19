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

    /// The local time each occurrence is placed on. A rule with a time zone keeps its intended time (an all-day one,
    /// midnight); a rule saved before the intended time existed starts from its current time. Rules without a time
    /// zone keep carrying the previous time forward, as they always have.
    var effectiveRepeatClock: Int? {
        guard repeatTimeZoneID != nil, let calendar = recurrenceCalendar else { return nil }
        guard let clockDate else { return 0 }
        if let repeatClock, Dates.validClock(repeatClock) { return repeatClock }
        return Dates.clock(of: clockDate, calendar: calendar)
    }

    /// This occurrence's actual local time in the rule's calendar; on a day skipped by daylight saving, the moved time.
    var actualRepeatClock: Int? {
        guard let calendar = recurrenceCalendar, let clockDate else { return nil }
        return Dates.clock(of: clockDate, calendar: calendar)
    }

    /// Call after the user sets this task's time, reminder or rule: records the intended time and a custom reminder's
    /// distance from it, so later occurrences keep both.
    func refreshRepeatClock() {
        guard repeatRule != "none", repeatTimeZoneID != nil, let calendar = recurrenceCalendar, let clockDate else {
            repeatClock = nil; repeatReminderOffset = nil; return
        }
        repeatClock = Dates.clock(of: clockDate, calendar: calendar)
        repeatReminderOffset = currentReminderOffset()
    }

    /// After a move. Moving only to another day keeps the intended time (and the reminder's distance), wherever the
    /// daylight-saving gap of either day puts that time; a time the user chose is recorded, even 03:30 on a gap day,
    /// unless it is the same local time as before (an occurrence shown at 03:30 dropped at 03:30 on another day).
    func updateRepeatClock(previousClock: Int?, dateOnly: Bool = false) {
        if let previousClock, repeatRule != "none", repeatTimeZoneID != nil, clockDate != nil,
           dateOnly || actualRepeatClock == previousClock {
            // A rule saved before the intended time existed locks in the time it had before this move.
            if repeatClock == nil { repeatClock = previousClock; repeatReminderOffset = currentReminderOffset() }
            return
        }
        refreshRepeatClock()
    }

    /// Call when only the reminder changed.
    func refreshRepeatReminderOffset() {
        repeatReminderOffset = repeatClock == nil ? nil : currentReminderOffset()
    }

    /// A custom reminder's distance from this occurrence on the wall clock: whole days plus local time, so a reminder
    /// at 02:15 for a 02:30 task is −900 whatever the daylight-saving state of either day.
    func currentReminderOffset() -> Int? {
        guard repeatRule != "none", repeatTimeZoneID != nil, resolvedReminderPreset == .custom,
              let calendar = recurrenceCalendar, let clockDate, let reminderAt else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: clockDate), to: calendar.startOfDay(for: reminderAt)).day ?? 0
        guard abs(days) <= 366 else { return nil }
        let offset = days * 86_400 + Dates.clock(of: reminderAt, calendar: calendar) - Dates.clock(of: clockDate, calendar: calendar)
        // A reminder further away than backups accept keeps the earlier whole-day rule instead of an unsavable value.
        return Dates.validReminderOffset(offset) ? offset : nil
    }

    var effectiveReminderOffset: Int? {
        if let repeatReminderOffset, Dates.validReminderOffset(repeatReminderOffset), resolvedReminderPreset == .custom { return repeatReminderOffset }
        return currentReminderOffset()
    }

    func nextRepeat(after now: Date) -> Date? {
        guard let base = calendarDate, let calendar = recurrenceCalendar else { return nil }
        return Dates.nextRepeat(base, rule: repeatRule, anchorDay: repeatAnchorDay,
                                after: now, until: repeatUntil, calendar: calendar, clock: effectiveRepeatClock)
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
        // An unscheduled timed deadline is the occurrence itself; counting days from it would carry a shifted time.
        next.dueAt = scheduledAt == nil && repeatTimeZoneID != nil && dueAt != nil
            ? nextDate : dueAt.flatMap { calendar.date(byAdding: .day, value: dayOffset, to: $0) }
        next.repeatRule = repeatRule; next.repeatUntil = repeatUntil; next.repeatTimeZoneID = repeatTimeZoneID
        // Carry the intended time, recording it now for a rule saved before it existed (taken before any shifted day).
        next.repeatClock = clockDate == nil ? nil : effectiveRepeatClock
        next.repeatReminderOffset = next.repeatClock == nil ? nil : effectiveReminderOffset
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
            // From the occurrence's intended time, not the previous reminder: a reminder moved by a daylight-saving gap
            // moves only that day and can never drift past its task.
            if clockDate != nil, let clock = effectiveRepeatClock, let offset = effectiveReminderOffset {
                let target = clock + offset
                let days = Int((Double(target) / 86_400).rounded(.down)), local = target - days * 86_400
                guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: nextDate)),
                      let placed = Dates.placing(clock: local, onDayOf: day, calendar: calendar) else { return nil }
                // A reminder time skipped by daylight saving is counted back from the occurrence instead of moving
                // forward with the gap, which could put it after the task (03:10 task, 02:50 → 03:50).
                if Dates.clock(of: placed, calendar: calendar) != local { return nextDate.addingTimeInterval(TimeInterval(offset)) }
                return placed
            }
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: nextDate)).day ?? 0
            return calendar.date(byAdding: .day, value: dayOffset, to: reminderAt)
        }
        return resolvedReminderPreset.date(base: nextDate, timed: scheduledAt != nil ? hasTime : dueHasTime, calendar: calendar)
    }

}
