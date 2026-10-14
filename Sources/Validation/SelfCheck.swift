import Foundation
import SwiftData
import UserNotifications
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor enum SelfCheck {
    /// Large concrete SwiftUI trees can exhaust the smaller device stack during presentation.
    private static func checkInterfaceFootprints() throws -> Int {
        func size<V: View, Content: View>(_: V.Type, _ body: (V) -> Content) -> Int { MemoryLayout<Content>.size }
        let sizes = ["workspace": size(ContentView.self) { $0.body },
                     "day card": size(DayTimelineCard.self) { $0.body },
                     "task editor": size(TaskEditor.self) { $0.body },
                     "list editor": size(ListEditor.self) { $0.body }]
        print("Interface view sizes (bytes): \(sizes)")
        guard sizes.values.allSatisfy({ $0 < 16_384 }) else {
            throw TaskBackup.invalid("Interface exceeds the 16 KB per-component stack budget: \(sizes)")
        }
        return sizes.count
    }
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
        try CalendarChecks.clockAndPhoneSlots(date: date, require: require)
        // A disappearing popover must not close the different card/day just opened by the user.
        try CalendarChecks.popoverIdentity(date: date, require: require)
        // A wall-clock timeline stays 0–24 even on a 23/25-hour day.
        try CalendarChecks.daylightSavingTimeline(require: require)
        try TaskLifecycleChecks.notificationPlans(date: date, require: require)
        try TaskLifecycleChecks.reminderNavigation(require: require)
        try TaskLifecycleChecks.suggestionTemplates(date: date, require: require)
        try TaskLifecycleChecks.taskOrdering(date: date, require: require)
        try CalendarChecks.calendarBuckets(require: require)
        try CalendarChecks.dayScheduleGaps(date: date, require: require)
        try TaskLifecycleChecks.sidebarOrdering(require: require)
        let today = try CalendarChecks.dateRulesAndReminders(date: date, require: require)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try StorageChecks.weekTitleBackup(date: date, directory: directory, require: require)
        try TaskLifecycleChecks.taskCopies(date: date, require: require)
        #if os(macOS)
        try StorageChecks.widgetSnapshot(date: date, directory: directory, require: require)
        #endif
        try StorageChecks.failedCopyIsAtomic(directory: directory, require: require)
        try TaskLifecycleChecks.listMoveUndo(date: date, directory: directory, require: require)
        try StorageChecks.largeBackup(directory: directory, require: require)
        try TaskLifecycleChecks.deletedListChildren(directory: directory, require: require)
        try TaskLifecycleChecks.moveDeadlineProposals(date: date, require: require)
        try StorageChecks.listTreeBackup(date: date, directory: directory, require: require)
        try StorageChecks.persistentTaskLifecycle(date: date, directory: directory, require: require)
        try StorageChecks.recurrenceAndBackup(today: today, date: date, directory: directory, require: require)
        // Planning views use the same ordering and scheduling rules as task lists.
        try TaskLifecycleChecks.planningOrder(date: date, require: require)
        try StorageChecks.listTreeValidation(date: date, directory: directory, require: require)
        try CalendarChecks.timelineLayoutAndFiltering(date: date, require: require)
        try CalendarDragChecks.unscheduleDrag(date: date, require: require)
        try CalendarDragChecks.nativeWeekDrag(date: date, require: require)
        try StorageChecks.emojiPersistence(directory: directory, require: require)
        try CalendarDragChecks.continuationGeometry(date: date, require: require)
        try CalendarChecks.calendarSearch(date: date, require: require)
        try CalendarChecks.shortTaskIntervals(date: date, require: require)
        try CalendarDragChecks.resizeUnits(date: date, require: require)
        try TaskLifecycleChecks.resizeUndo(date: date, require: require)
        try TaskLifecycleChecks.leapRepeatAndListMoves(date: date, require: require)
        try TaskLifecycleChecks.repeatPreviewAndHistory(date: date, require: require)
        try StorageChecks.saveRecovery(date: date, require: require)
        try StorageChecks.frozenMigration(require: require)
        checkCount += try checkInterfaceFootprints()
        checkCount += try CalendarGridChecks.run()
        checkCount += try EditingChecks.run()
        checkCount += try FinanceChecks.run()
        checkCount += try RecurrenceTimeZoneChecks.run()
        checkCount += try CloudMerge.check()
        print("PASS: \(checkCount) checks — calendar, boundaries, persistent reload, subtasks, edit, completion, deletion, restore, rollback")
    }
}
