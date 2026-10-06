import Foundation
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

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
        // The touch grid shares desktop drop semantics, with reachable in-screen edge bands.
        let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1)
        let mobileGeometry = WeekDropGeometry(canvas: CGRect(x: 0, y: -200, width: 374, height: 1440),
            viewport: CGRect(x: 0, y: 100, width: 374, height: 500),
            allDay: CGRect(x: 0, y: 50, width: 374, height: 44), undated: .zero,
            gutter: 34, layout: layout, edgeInset: 24, scrollBand: 64)
        try require(mobileGeometry.edgeDirection(pointer: CGPoint(x: 373, y: 300)) == 1
                    && mobileGeometry.edgeDirection(pointer: CGPoint(x: 390, y: 300)) == 1
                    && mobileGeometry.edgeDirection(pointer: CGPoint(x: -20, y: 300)) == -1,
                    "Phone paging stays active at and beyond either screen edge")
        try require(mobileGeometry.edgeDirection(pointer: CGPoint(x: 370, y: 70)) == 0
                    && mobileGeometry.zone(pointer: CGPoint(x: 370, y: 70), grabOffset: 12, durationMinutes: 60) == .allDay(6)
                    && mobileGeometry.scrollSpeed(pointer: CGPoint(x: 190, y: 70)) == 0,
                    "All-day remains a full drop target without paging or scrolling underneath")
        try require(mobileGeometry.scrollSpeed(pointer: CGPoint(x: 190, y: 550)) > 0
                    && mobileGeometry.scrollSpeed(pointer: CGPoint(x: 190, y: 900)) == 10
                    && mobileGeometry.scrollSpeed(pointer: CGPoint(x: 190, y: -100)) == -10,
                    "Touch autoscroll starts in a wider band and continues beyond top and bottom")
        let monthGeometry = MonthDropGeometry(canvas: CGRect(x: 0, y: 0, width: 374, height: 420),
            viewport: CGRect(x: 0, y: 0, width: 374, height: 420), inMonth: Array(repeating: true, count: 35), edgeInset: 24)
        try require(monthGeometry.edgeDirection(pointer: CGPoint(x: 373, y: 200)) == 1
                    && monthGeometry.edgeDirection(pointer: CGPoint(x: 1, y: 200)) == -1
                    && monthGeometry.zone(pointer: CGPoint(x: 373, y: 200)) == .day(20),
                    "Phone month edges page after dwell but remain immediate day drop targets")
        let drag = WeekDrag()
        drag.canvas = mobileGeometry.canvas; drag.viewport = mobileGeometry.viewport
        drag.allDay = mobileGeometry.allDay; drag.layout = layout; drag.gutter = 34; drag.touchEdges = true
        var drops = 0
        drag.begin(timed, color: .accentColor, grabOffset: 12) { _, _ in drops += 1 }
        drag.move(to: CGPoint(x: 390, y: 300))
        for now in [0.0, 0.5, 1.4] { drag.tick(now: now) }
        try require(drag.weekOffset == 2 && drops == 0, "A stationary phone drag keeps paging without changing the task")
        drag.move(to: CGPoint(x: 100, y: 70)); drag.complete(); drag.complete()
        try require(drops == 1 && !drag.isDragging, "A cross-page all-day drop commits exactly once")
        drag.begin(timed, color: .accentColor, grabOffset: 0, month: first) { _, _ in drops += 1 }
        drag.monthCanvas = monthGeometry.canvas; drag.monthViewport = monthGeometry.viewport
        drag.move(to: CGPoint(x: 390, y: 200)); drag.tick(now: 0); drag.tick(now: 0.5)
        try require(drag.weekOffset == 1, "Month drags use the same stationary edge lifecycle")
        drag.cancel(); drag.tick(now: 2); drag.complete()
        try require(drops == 1 && drag.weekOffset == 0 && !drag.isDragging, "Cancelling a paged drag restores the page without a save")
        #if os(iOS)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 374, height: 500))
        scroll.contentSize = CGSize(width: 374, height: 1440)
        scroll.contentOffset.y = 300
        drag.scrollView = scroll; drag.canvas = mobileGeometry.canvas
        drag.begin(timed, color: .accentColor, grabOffset: 0) { _, _ in drops += 1 }
        drag.move(to: CGPoint(x: 190, y: 590)); drag.tick(now: 0); drag.tick(now: 0.2); drag.tick(now: 0.3)
        try require(scroll.contentOffset.y > 300 && drag.canvas.minY < -200,
                    "Stationary touch autoscroll moves the native scroll view and drop geometry together")
        let position = scroll.contentOffset.y
        drag.move(to: CGPoint(x: 190, y: 70)); drag.tick(now: 0.5); drag.tick(now: 0.8)
        try require(scroll.contentOffset.y == position, "Moving into all-day immediately stops vertical autoscroll")
        _ = drag.finish()
        #endif
        print("CALENDAR GRID PASS: \(checks) checks")
        return checks
    }
}
