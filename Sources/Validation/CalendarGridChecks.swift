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
        let boundaryDrag = WeekDrag()
        boundaryDrag.canvas = CGRect(x: 0, y: 100, width: 744, height: 1440)
        boundaryDrag.viewport = CGRect(x: 0, y: 100, width: 744, height: 500)
        boundaryDrag.allDay = CGRect(x: 0, y: 50, width: 744, height: 44)
        boundaryDrag.layout = layout
        boundaryDrag.begin(timed, color: .accentColor, grabOffset: 0) { _, _ in }
        try require(boundaryDrag.trailing == 0, "Default week drawing and drag geometry leave the full width to seven day columns")
        // A 744-point canvas draws a 44-point gutter and seven 100-point columns.
        for index in 0..<7 {
            for inset in [1.0, 99.0] {
                let x = 44 + Double(index) * 100 + inset
                boundaryDrag.move(to: CGPoint(x: x, y: 300))
                try require(boundaryDrag.zone == .timed(day: index, minute: 195) && boundaryDrag.edge == 0,
                            "Both drawn edges of day \(index) stay in that day without triggering navigation")
                boundaryDrag.move(to: CGPoint(x: x, y: 70))
                try require(boundaryDrag.zone == .allDay(index), "All-day drawing and timed drag columns stay aligned")
            }
        }
        boundaryDrag.cancel(); boundaryDrag.complete()
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
        let allDayTask = TaskItem(title: "All-day pickup", scheduledAt: first, list: list)
        var converted = false
        drag.begin(allDayTask, color: .accentColor, grabOffset: 12) { zone, _ in
            if case .timed(let day, let minute) = zone {
                converted = TaskMove(allDayTask, to: Dates.clockTime(on: Dates.weekCells(first)[day], minute: minute), kind: .timed)
                    .apply(to: allDayTask, shiftDeadline: false)
            }
        }
        drag.move(to: CGPoint(x: 100, y: 70))
        try require(drag.zone == .allDay(1), "An all-day pickup initially stays in its all-day cell")
        drag.move(to: CGPoint(x: 100, y: 412)); drag.complete()
        try require(converted && allDayTask.hasTime && Dates.clockMinute(allDayTask.clockDate!) == 600,
                    "Dragging all-day into the grid commits a timed schedule")
        let overnight = TaskItem(title: "Continuation", scheduledAt: Dates.clockTime(on: first, minute: 1380), list: list)
        overnight.hasTime = true; overnight.endAt = overnight.scheduledAt!.addingTimeInterval(7200)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: first)!
        let grab = drag.pickupOffset(for: overnight, on: tomorrow, at: CGPoint(x: 100, y: mobileGeometry.canvas.minY + 30))
        try require(grab == 90, "Both platforms preserve the pickup offset on a cross-midnight continuation")
        overnight.reminderKind = ReminderPreset.tenMinutes.rawValue
        overnight.reminderAt = overnight.scheduledAt!.addingTimeInterval(-600)
        drag.canvas = CGRect(x: 0, y: 100, width: 374, height: 1440)
        var movedContinuation = false
        drag.begin(overnight, color: .accentColor, grabOffset: grab) { zone, _ in
            if case .timed(let day, let minute) = zone {
                let destination = Dates.clockTime(on: Dates.weekCells(first)[day], minute: minute, reference: overnight.clockDate)
                movedContinuation = TaskMove(overnight, to: destination, kind: .timed).apply(to: overnight, shiftDeadline: false)
            }
        }
        drag.move(to: CGPoint(x: 34 + 3.5 * mobileGeometry.column, y: 130))
        try require(drag.zone == .timed(day: 3, minute: -60), "Continuation drop retains the previous day's signed start minute")
        drag.complete()
        let movedStartDay = calendar.date(byAdding: .day, value: 2, to: first)!
        let movedStart = Dates.clockTime(on: movedStartDay, minute: 1380)
        try require(movedContinuation && overnight.scheduledAt == movedStart
                    && overnight.endAt == movedStart.addingTimeInterval(7200)
                    && overnight.reminderAt == movedStart.addingTimeInterval(-600),
                    "Saving a dragged continuation preserves 23:00 start, two-hour duration and relative reminder")
        #if os(iOS)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let panel = UIView(frame: window.bounds); window.addSubview(panel); window.isHidden = false
        defer { window.isHidden = true }
        let clipped = UIView(frame: CGRect(x: 0, y: 100, width: 390, height: 200)); clipped.clipsToBounds = true
        panel.addSubview(clipped)
        let card = UIView(frame: CGRect(x: 40, y: -20, width: 60, height: 60)); clipped.addSubview(card)
        try require(MobileCalendarDragSource.contains(CGPoint(x: 60, y: 120), in: panel, source: card),
                    "Touch pickup accepts the visible part of a calendar card")
        try require(!MobileCalendarDragSource.contains(CGPoint(x: 60, y: 90), in: panel, source: card),
                    "A clipped offscreen card cannot steal a toolbar touch")
        clipped.isHidden = true
        try require(!MobileCalendarDragSource.contains(CGPoint(x: 60, y: 120), in: panel, source: card),
                    "A retained hidden calendar cannot begin a touch drag")
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
        #if os(iOS)
        checks += try hostedTouchChecks()
        #endif
        print("CALENDAR GRID PASS: \(checks) checks")
        return checks
    }
    #if os(iOS)
    /// UIKit must see the actual SwiftUI background probes and button host, not just
    /// hand-built rectangles. This catches source registration and gesture gating regressions.
    private static func hostedTouchChecks() throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Hosted calendar drag: " + label) }
            checks += 1
        }
        let drag = WeekDrag(), feedback = DragFeedback()
        let task = TaskItem(title: "Hosted pickup", scheduledAt: Date())
        let root = VStack {
            Button("Task") {}.frame(width: 100, height: 44)
                .modifier(WeekDragSource(task: task, color: .blue, grabOffset: { _ in 12 }, drop: { _, _, _ in }))
            ScrollView { Color.clear.frame(height: 900) }.frame(height: 300)
        }.frame(width: 390, height: 500)
            .background(MobileCalendarDrag(drag: drag, feedback: feedback, enabled: true))
            .environment(drag)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        guard let press = window.gestureRecognizers?.first(where: { $0.name == "Calendar task drag" }),
              let coordinator = press.delegate as? MobileCalendarDrag.Coordinator,
              let panel = coordinator.view,
              let card = drag.mobileSources.allObjects.first as? MobileCalendarDragSource.Probe else {
            throw TaskBackup.invalid("Hosted calendar drag did not install its recognizer and source")
        }
        try require(card.bounds.width == 100 && card.bounds.height == 44 && panel.window === window,
                    "A SwiftUI button registers its full bounds in the active window")
        let point = card.convert(CGPoint(x: 50, y: 22), to: panel)
        let windowPoint = panel.convert(point, to: window)
        guard let touched = window.hitTest(windowPoint, with: nil) else {
            throw TaskBackup.invalid("Hosted calendar task cannot receive touches")
        }
        try require(coordinator.prepare(at: point, touching: touched) && coordinator.gestureRecognizerShouldBegin(press),
                    "The real SwiftUI hosting hit target can begin an all-day pickup")
        let pan = UIPanGestureRecognizer(), tap = UITapGestureRecognizer()
        touched.addGestureRecognizer(pan); touched.addGestureRecognizer(tap)
        try require(coordinator.gestureRecognizer(press, shouldBeRequiredToFailBy: pan)
                    && coordinator.gestureRecognizer(press, shouldBeRequiredToFailBy: tap),
                    "Pending task pickup has priority over card taps and calendar pans")
        let systemGate = UIGestureRecognizer(); window.addGestureRecognizer(systemGate)
        try require(!coordinator.gestureRecognizer(press, shouldBeRequiredToFailBy: systemGate),
                    "Window-level system gestures never wait for calendar pickup")
        let cover = UIView(frame: window.bounds); window.addSubview(cover)
        try require(!coordinator.prepare(at: point, touching: cover), "An overlay cannot pick up a task behind it")
        cover.removeFromSuperview()
        try require(!coordinator.prepare(at: CGPoint(x: -10, y: -10), touching: touched)
                    && !coordinator.gestureRecognizer(press, shouldBeRequiredToFailBy: pan),
                    "Outside a task, calendar dragging never delays navigation or scrolling")
        coordinator.source = MobileCalendarDrag(drag: drag, feedback: feedback, enabled: false)
        coordinator.attach()
        try require(!press.isEnabled && !coordinator.prepare(at: point, touching: touched),
                    "Presenting an editor disables pickup")
        coordinator.source = MobileCalendarDrag(drag: drag, feedback: feedback, enabled: true)
        coordinator.attach(); coordinator.attach()
        try require(press.isEnabled && window.gestureRecognizers?.filter { $0.name == "Calendar task drag" }.count == 1,
                    "Dismissal and repeated layout updates re-enable exactly one recognizer")
        coordinator.detach()
        try require(!(window.gestureRecognizers ?? []).contains(press), "Leaving the calendar removes its window recognizer")
        return checks
    }
    #endif
}
