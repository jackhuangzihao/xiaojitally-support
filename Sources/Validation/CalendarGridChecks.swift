import Foundation
import SwiftData

@MainActor enum CalendarGridChecks {
    static func run() throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Calendar grids: " + label) }
            checks += 1
        }
        let calendar = Dates.calendar
        let first = calendar.date(from: DateComponents(year: 2026, month: 12, day: 28))!
        // Several successful edge drops followed by manual navigation must keep distinct identities.
        for offset in [-5, -1, 1, 5] {
            let next = calendar.date(byAdding: .day, value: 7 * offset, to: first)!
            try require(CalendarPageIdentity.week(first, revealed: 0) == CalendarPageIdentity.week(next, revealed: offset),
                        "Cross-year week drops retain the visible scroll container")
            try require(CalendarPageIdentity.week(first, revealed: 0) != CalendarPageIdentity.week(next, revealed: 0),
                        "Manual week navigation replaces the page")
            let month = Dates.shiftMonth(first, by: offset)
            try require(CalendarPageIdentity.month(first, revealed: 0) == CalendarPageIdentity.month(month, revealed: offset),
                        "Cross-year month drops retain the visible page")
            try require(CalendarPageIdentity.month(first, revealed: 0) != CalendarPageIdentity.month(month, revealed: 0),
                        "Manual month navigation replaces the page")
        }
        let list = TaskList(name: "Grid checks")
        let timed = TaskItem(title: "Located", scheduledAt: Dates.clockTime(on: first, minute: 660), list: list)
        timed.hasTime = true
        let done = TaskItem(title: "Completed", scheduledAt: first, list: list); done.isDone = true
        let removed = TaskItem(title: "Deleted", scheduledAt: first, list: list); removed.deletedAt = first
        let source = CalendarGridData(tasks: [timed, done, removed], lists: [list], filter: TaskFilter(), currentDay: first, locatedTask: timed.id)
        let cache = RepeatPreview()
        let week = source.items(on: first, month: false, completed: false, repeats: false, cache: cache)
        let month = source.items(on: first, month: true, completed: false, repeats: false, cache: cache)
        try require(week.map(\.id) == [timed.id] && month.map(\.id) == [timed.id], "Both grids apply completion and deletion filters")
        try require(source.items(on: first, month: true, completed: true, repeats: false, cache: cache).count == 2,
                    "Show completed never resurrects deleted tasks")
        try require(source.visiblePlanItems([done, timed], count: 1).first?.id == timed.id,
                    "Located task remains visible in an overflowing day cell")
        try require(source.locatedMinute(days: Dates.weekCells(first), selectedDate: first) == 600,
                    "Search and reminder navigation retain one hour of headroom")
        try require(source.droppedTask(["jianshi-task:" + timed.id.uuidString])?.id == timed.id
                    && source.droppedTask(["jianshi-task:" + removed.id.uuidString]) == nil
                    && source.droppedTask(["invalid"]) == nil, "Drop input is resolved against live, nondeleted tasks")
        let before = TaskSchedule(timed)
        _ = source.items(on: Dates.shiftMonth(first, by: 1), month: true, completed: true, repeats: true, cache: cache)
        try require(TaskSchedule(timed) == before, "Building a preview in another page never changes the task")
        print("CALENDAR GRID PASS: \(checks) checks")
        return checks
    }
}
