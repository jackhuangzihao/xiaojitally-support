import Foundation
import SwiftData
import UserNotifications
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor enum CalendarDragChecks {
    static func unscheduleDrag(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            // --- dragging a task out of the timeline ---
            let day = date(2026, 9, 21)
            let start = Dates.calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day)!
            let timed = TaskItem(title: "Timed", scheduledAt: start); timed.hasTime = true; timed.endAt = start.addingTimeInterval(3600)
            timed.reminderAt = start.addingTimeInterval(-600); timed.reminderKind = ReminderPreset.tenMinutes.rawValue
            timed.makeAllDay(on: date(2026, 9, 22))
            try require(!timed.hasTime && timed.endAt == nil && timed.clockDate == nil && Dates.sameDay(timed.scheduledAt!, date(2026, 9, 22)), "All-day row keeps the day and removes the time")
            try require(timed.reminderAt == start.addingTimeInterval(-600) && timed.resolvedReminderPreset == .custom, "A reminder that no longer fits is kept as a custom time")
            let morning = TaskItem(title: "Morning", scheduledAt: start); morning.hasTime = true
            morning.reminderAt = Dates.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day); morning.reminderKind = ReminderPreset.morning.rawValue
            morning.makeAllDay(on: date(2026, 9, 23))
            try require(morning.reminderAt.map { Dates.sameDay($0, date(2026, 9, 23)) } == true, "A day reminder follows the new day")
            let loose = TaskItem(title: "Loose", scheduledAt: start); loose.hasTime = true; loose.endAt = start.addingTimeInterval(1800)
            try require(loose.clearSchedule() && loose.calendarDate == nil && !loose.hasTime && loose.endAt == nil, "Undated list removes date and time")
            let due = TaskItem(title: "Due", scheduledAt: start); due.dueAt = date(2026, 9, 25)
            let repeating = TaskItem(title: "Repeat", scheduledAt: start); repeating.repeatRule = "weekly"
            try require(!due.clearSchedule() && due.scheduledAt == start && !repeating.clearSchedule() && repeating.scheduledAt == start, "Deadline or repeat keeps its date")
        }
    }

    static func nativeWeekDrag(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            // --- Mac week view drag: where the pointer is and what time it means ---
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            // Scrolled 900 points down: the grid shows roughly 12:30–19:25.
            let geometry = WeekDropGeometry(canvas: CGRect(x: 0, y: -800, width: 744, height: 1728),
                                            viewport: CGRect(x: 0, y: 100, width: 744, height: 500),
                                            allDay: CGRect(x: 0, y: 60, width: 744, height: 30),
                                            undated: CGRect(x: 760, y: 40, width: 190, height: 560), layout: layout)
            let wednesday = 44.0 + 2 * 100 + 50
            let sixPM = -800.0 + 18 * 72
            // Picked up 100 points below its top edge: it keeps that spot instead of jumping to the pointer.
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: sixPM + 100), grabOffset: 100, durationMinutes: 120) == .timed(day: 2, minute: 18 * 60),
                        "A dragged task keeps the spot it was grabbed by")
            try require(geometry.minute(pointerY: sixPM + 8, grabOffset: 0, durationMinutes: 60) == 18 * 60
                        && geometry.minute(pointerY: sixPM + 10, grabOffset: 0, durationMinutes: 60) == 18 * 60 + 15,
                        "The start snaps to the nearest quarter hour")
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: 75), grabOffset: 0, durationMinutes: 60) == .allDay(2)
                        && geometry.zone(pointer: CGPoint(x: 20, y: 75), grabOffset: 0, durationMinutes: 60) == .none,
                        "The all-day row takes a day; its label does not")
            try require(geometry.zone(pointer: CGPoint(x: 800, y: 300), grabOffset: 0, durationMinutes: 60) == .undated,
                        "The undated list is a drop target")
            try require(geometry.zone(pointer: CGPoint(x: 10, y: 300), grabOffset: 0, durationMinutes: 60) == .none,
                        "Releasing at the hour gutter never moves a task by a week")
            if case .timed(day: 6, minute: _) = geometry.zone(pointer: CGPoint(x: 734, y: 300), grabOffset: 0, durationMinutes: 60) {
                try require(true, "Sunday right edge remains a same-week drop before dwelling")
            } else { try require(false, "Sunday right edge remains available") }
            var hover = WeekEdgeHover()
            try require(hover.step(direction: 1, now: 0) == 0 && hover.step(direction: 1, now: 0.4) == 0,
                        "Passing an edge does not turn a week")
            try require(hover.step(direction: 1, now: 0.7) == 1 && hover.step(direction: 1, now: 1.0) == 0
                        && hover.step(direction: 1, now: 1.7) == 1, "Dwelling turns weeks with a repeat delay")
            try require(hover.step(direction: 0, now: 1.8) == 0 && hover.step(direction: -1, now: 1.9) == 0
                        && hover.step(direction: -1, now: 2.6) == -1, "Leaving resets edge dwell")
            var edged = geometry; edged.trailing = 20
            try require(edged.edgeDirection(pointer: CGPoint(x: 10, y: 300)) == -1
                        && edged.edgeDirection(pointer: CGPoint(x: 734, y: 300)) == 1,
                        "The hour column and the strip right of Sunday turn weeks")
            try require(edged.edgeDirection(pointer: CGPoint(x: 700, y: 300)) == 0
                        && edged.edgeDirection(pointer: CGPoint(x: 60, y: 300)) == 0
                        && edged.edgeDirection(pointer: CGPoint(x: 734, y: 75)) == 0,
                        "Monday, Sunday and the all-day row are never week edges")
            if case .timed(day: 6, minute: _) = edged.zone(pointer: CGPoint(x: 700, y: 300), grabOffset: 0, durationMinutes: 60) {
                try require(edged.zone(pointer: CGPoint(x: 734, y: 300), grabOffset: 0, durationMinutes: 60) == .none,
                            "Sunday stays a drop target; letting go on the next-week strip does nothing")
            } else { try require(false, "Sunday stays a drop target with the next-week strip beside it") }
            try require(abs(WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 128), viewport: geometry.viewport)) < 1
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 75), viewport: geometry.viewport) == 0,
                        "Near the band's inner edge scrolling is barely moving; the all-day row never scrolls")
            try require(WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 105), viewport: geometry.viewport) < 0
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 595), viewport: geometry.viewport) > 0
                        && WeekDropGeometry.scrollSpeed(pointer: CGPoint(x: 300, y: 300), viewport: geometry.viewport) == 0,
                        "Top and bottom edges scroll in opposite directions; center stops")
                        try require(geometry.scrollSpeed(pointer: CGPoint(x: 300, y: 40)) == -10
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 300, y: -200)) == -10
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 300, y: 75)) == 0
                                    && geometry.scrollSpeed(pointer: CGPoint(x: 800, y: 50)) == 0,
                                    "Above the all-day row scrolls up at full speed; the all-day row and the undated list never scroll")
            let monthGrid = MonthDropGeometry(canvas: CGRect(x: 100, y: 100, width: 700, height: 500),
                                              viewport: CGRect(x: 100, y: 100, width: 700, height: 500),
                                              inMonth: Array(repeating: false, count: 2) + Array(repeating: true, count: 31) + Array(repeating: false, count: 2))
            try require(monthGrid.edgeDirection(pointer: CGPoint(x: 40, y: 300)) == -1
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 900, y: 300)) == 1
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 105, y: 300)) == 0
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 795, y: 300)) == 0
                        && monthGrid.edgeDirection(pointer: CGPoint(x: 40, y: 50)) == 0,
                        "Month pages turn only beside the month; Monday and Sunday stay whole")
            try require(monthGrid.zone(pointer: CGPoint(x: 350, y: 150)) == .day(2)
                        && monthGrid.zone(pointer: CGPoint(x: 750, y: 450)) == .day(27)
                        && monthGrid.zone(pointer: CGPoint(x: 150, y: 150)) == .none
                        && monthGrid.zone(pointer: CGPoint(x: 795, y: 595)) == .none
                        && monthGrid.zone(pointer: CGPoint(x: 900, y: 300)) == .none,
                        "A month drop lands on the day under the pointer; blank cells and the edges take nothing")
            try require(geometry.zone(pointer: CGPoint(x: wednesday, y: 700), grabOffset: 0, durationMinutes: 60) == .none,
                        "Letting go outside the week changes nothing")
            try require(geometry.minute(pointerY: -850, grabOffset: 0, durationMinutes: 120) == -45
                        && geometry.minute(pointerY: 99999, grabOffset: 0, durationMinutes: 60) == 1425,
                        "A task may start before midnight but always stays partly on the grid")

            #if os(macOS)
            // AppKit pointer sessions are not used by iOS native drag and drop.
            let session = WeekDrag()
            session.canvas = geometry.canvas; session.viewport = geometry.viewport; session.layout = layout
            let dragTask = TaskItem(title: "Edge session", scheduledAt: date(2026, 9, 18))
            let original = TaskSchedule(dragTask)
            var receivedOffset: Int?
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.7)
            try require(session.weekOffset == 1 && TaskSchedule(dragTask) == original, "Hover previews another week without changing a task")
            session.move(to: CGPoint(x: wednesday, y: sixPM))
            session.complete()
            try require(receivedOffset == 1 && session.weekOffset == 0 && !session.isDragging, "Release delivers preview week then clears drag state")
            // Repeat the same source gesture without delivering its old onEnded callback.
            var gestureDrops = 0
            for _ in 0..<3 {
                session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                      point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
                try require(session.isDragging && session.zone != .none, "Same source can start another drag after native completion")
                session.complete()
            }
            try require(gestureDrops == 3, "Consecutive gestures each deliver exactly one drop")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.cancel()
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM - 30)) { _, _ in gestureDrops += 1 }
            try require(session.cancelled && session.zone == .none, "Escape stays cancelled through later gesture samples")
            session.samplePointer(at: CGPoint(x: -100, y: -100), pressed: false)
            try require(session.taskID == nil, "Releasing a cancelled drag outside clears the session")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0,
                                  point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.complete()
            try require(gestureDrops == 4, "Next gesture recovers after cancellation without a source callback")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in gestureDrops += 1 }
            session.move(to: CGPoint(x: 734, y: 300)); session.tick(now: 0); session.tick(now: 0.7)
            try require(!session.checkPhysicalButton(pressed: false, now: 1), "Missing release stops edge work immediately")
            _ = session.checkPhysicalButton(pressed: false, now: 1.2)
            session.tick(now: 10)
            try require(session.cancelled && session.weekOffset == 0 && session.zone == .none, "Release watchdog cancels and stops recurring page turns")
            session.updateGesture(dragTask, color: .accentColor, grabOffset: 0, point: CGPoint(x: wednesday, y: sixPM)) { _, _ in gestureDrops += 1 }
            session.complete()
            try require(gestureDrops == 4 && session.taskID == nil, "Late motion and release never commit an abandoned task")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in gestureDrops += 1 }
            session.move(to: CGPoint(x: wednesday, y: sixPM))
            _ = session.checkPhysicalButton(pressed: false, now: 1)
            try require(session.checkPhysicalButton(pressed: true, now: 1.02) && session.isDragging,
                        "A transient physical-button sample does not cancel a healthy gesture")
            session.complete()
            try require(gestureDrops == 5, "Normal release still commits exactly once after watchdog sampling")
            #endif
            let rowA = UUID(), rowB = UUID()
            let listRows = [rowA: CGRect(x: 0, y: 100, width: 180, height: 28), rowB: CGRect(x: 0, y: 128, width: 180, height: 28)]
            let listHeader = CGRect(x: 0, y: 70, width: 180, height: 24)
            func listTarget(_ y: Double, blocked: UUID? = nil) -> (UUID?, ListTree.Placement)? {
                ListTree.dropTarget(pointer: CGPoint(x: 60, y: y), rows: listRows, header: listHeader, blocked: { $0 == blocked }).map { ($0.list, $0.placement) }
            }
            try require(listTarget(102).map { $0.0 == rowA && $0.1 == .before } == true
                        && listTarget(114).map { $0.0 == rowA && $0.1 == .inside } == true
                        && listTarget(126).map { $0.0 == rowA && $0.1 == .after } == true
                        && listTarget(140).map { $0.0 == rowB && $0.1 == .inside } == true,
                        "A dragged list goes above, into or below the row under the pointer")
            try require(listTarget(80).map { $0.0 == nil && $0.1 == .before } == true && listTarget(114, blocked: rowA) == nil && listTarget(300) == nil,
                        "The header returns a list to the top level; its own rows and empty space take nothing")
            try require(ListTree.dropTarget(pointer: CGPoint(x: 900, y: 114), rows: listRows, header: listHeader, blocked: { _ in false }) == nil
                        && ListTree.dropTarget(pointer: CGPoint(x: -1, y: 80), rows: listRows, header: listHeader, blocked: { _ in false }) == nil,
                        "Dragging a list right of the sidebar or left of its header cannot reorder or reparent it")
            #if os(macOS)
            let sidebarDrag = ListDrag()
            let oldRow = UUID(), newRow = UUID()
            sidebarDrag.report(rowA, owner: oldRow, frame: listRows[rowA]!)
            sidebarDrag.report(rowA, owner: newRow, frame: listRows[rowA]!)
            sidebarDrag.forget(rowA, owner: oldRow)
            try require(sidebarDrag.rows[rowA] != nil, "A replaced sidebar row keeps its place when the old row goes away")
            sidebarDrag.forget(rowA, owner: newRow)
            try require(sidebarDrag.rows[rowA] == nil, "A sidebar row that goes away is no longer a drop target")
            let listsForDrag = (0..<4).map { TaskList(name: "Reflow \($0)") }
            let ids = listsForDrag.map(\.id)
            let stable = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, CGRect(x: 0, y: 100 + $0.offset * 32, width: 180, height: 24)) })
            let reflow = ListDrag()
            reflow.sidebar = CGRect(x: 0, y: 0, width: 180, height: 350); reflow.header = listHeader
            for (id, frame) in stable { reflow.report(id, owner: UUID(), frame: frame) }
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            try require(reflow.gap == stable[ids[1]] && reflow.offsets.isEmpty,
                        "Lifting a row marks the slot it came from instead of leaving a hole")
            reflow.move(to: CGPoint(x: 60, y: 185), now: 0)
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .after && reflow.offsets[ids[2]] == -32 && reflow.gap?.minY == 164,
                        "Sidebar reorder lifts the source and opens exactly one row-sized landing slot")
            for _ in 0..<20 { reflow.move(to: CGPoint(x: 60, y: 185), now: 0.2) }
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .after && reflow.offsets[ids[2]] == -32,
                        "Stationary pointer does not chase animated row positions or oscillate")
            reflow.move(to: CGPoint(x: 60, y: 190), now: 0.25)
            try require(reflow.gap != nil && reflow.offsets[ids[2]] == -32, "Crossing native row spacing preserves the reorder slot instead of flashing back")
            reflow.move(to: CGPoint(x: 60, y: 101), now: 0.3)
            try require(reflow.offsets[ids[0]] == 32 && reflow.gap?.minY == 100, "Dragging upward moves the crossed row down into the old gap")
            reflow.move(to: CGPoint(x: 60, y: 169), now: 1)
            reflow.tick(now: 1.39)
            try require(reflow.target?.placement != .inside, "Passing or briefly pausing on a list never immediately nests it")
            reflow.tick(now: 1.41)
            try require(reflow.target?.list == ids[2] && reflow.target?.placement == .inside
                        && reflow.gap?.minY == 164 && reflow.gap?.minX == 14
                        && reflow.offsets[ids[2]] == -32 && reflow.offsets[ids[3]] == 0,
                        "A deliberate 400ms middle hover shows an indented slot under that list, not an empty preview")
            reflow.move(to: CGPoint(x: 61, y: 170), now: 1.5)
            try require(reflow.target?.placement == .inside && listsForDrag[1].parentID == nil && listsForDrag[1].sortOrder == 0,
                        "Armed folder remains stable while rows settle; hovering does not change stored hierarchy or order")
            reflow.move(to: CGPoint(x: 60, y: 218), now: 1.6)
            try require(reflow.target?.list == ids[3] && reflow.target?.placement == .after && reflow.gap != nil, "Leaving an armed folder restores normal sorting feedback")
            reflow.cancel()
            try require(reflow.offsets.isEmpty && reflow.gap == nil && reflow.finish() == nil, "Escape removes preview offsets and never returns a drop")
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            try require(!reflow.isDragging, "Cancelled sidebar drag cannot restart from late motion")
            reflow.newPress(); reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] })
            reflow.move(to: CGPoint(x: 60, y: 218), now: 2)
            let accepted = reflow.finish()
            try require(accepted?.list == ids[3] && accepted?.placement == .after && reflow.finish() == nil, "A fresh drag works and can commit at most once")
            reflow.begin(listsForDrag[1], blocked: { $0 == ids[1] }); reflow.move(to: CGPoint(x: 60, y: 101), now: 3)
            _ = reflow.checkPhysicalButton(pressed: false, now: 3)
            _ = reflow.checkPhysicalButton(pressed: false, now: 3.16)
            try require(!reflow.isDragging && reflow.finish() == nil, "Missing mouse-up cancels sidebar reordering instead of saving later")
            let nestedGap = ListTree.dragPreview(rows: stable, moving: [ids[3]], target: (ids[0], .after), isDescendant: { $0 == $1 || ($1 == ids[0] && $0 == ids[1]) })
            try require(nestedGap.gap?.minY == 164 && nestedGap.offsets[ids[1]] == 0 && nestedGap.offsets[ids[2]] == 32,
                        "An after-group landing slot follows its visible children rather than splitting the group")
            let groupGap = ListTree.dragPreview(rows: stable, moving: [ids[0], ids[1]], target: (ids[3], .after))
            try require(groupGap.gap?.height == 56 && groupGap.offsets[ids[2]] == -64 && groupGap.offsets[ids[3]] == -64,
                        "Dragging an expanded group moves its visible subtree as a block")
            let draggedList = TaskList(name: "Esc test")
            sidebarDrag.begin(draggedList, blocked: { _ in false }); sidebarDrag.cancel()
            sidebarDrag.begin(draggedList, blocked: { _ in false }); sidebarDrag.move(to: .zero)
            try require(!sidebarDrag.isDragging && sidebarDrag.cancelledUntilPress && sidebarDrag.finish() == nil,
                        "Sidebar Escape suppresses restart and drop throughout the same press")
            sidebarDrag.newPress(); sidebarDrag.begin(draggedList, blocked: { _ in false })
            try require(sidebarDrag.isDragging && !sidebarDrag.cancelledUntilPress, "A fresh press can drag a list after Escape")
            _ = sidebarDrag.finish()
            #endif
            #if os(macOS)
            let monthSession = WeekDrag()
            monthSession.monthCanvas = monthGrid.canvas; monthSession.monthViewport = monthGrid.viewport
            var monthLanding: (WeekDropGeometry.Zone, Int)?
            monthSession.begin(dragTask, color: .accentColor, grabOffset: 0, month: date(2026, 9, 18)) { zone, offset in monthLanding = (zone, offset) }
            monthSession.move(to: CGPoint(x: 40, y: 300))
            monthSession.tick(now: 0); monthSession.tick(now: 0.7)
            try require(monthSession.weekOffset == -1 && monthSession.edge == -1, "Resting beside the month previews the previous month")
            monthSession.move(to: CGPoint(x: 350, y: 250))
            monthSession.complete()
            try require(monthLanding.map { $0.1 == -1 && $0.0 != .none } == true && !monthSession.isDragging && TaskSchedule(dragTask) == original,
                        "A month drag hands over the day and the month it was dropped in, and changes nothing by itself")
            receivedOffset = nil
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.5); session.tick(now: 1.3)
            try require(session.weekOffset == 2, "Resting on the edge turns a second week")
            session.complete()
            try require(receivedOffset == nil && session.weekOffset == 0 && !session.isDragging,
                        "Letting go on the edge strip slides back and changes nothing")
            receivedOffset = nil
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, offset in receivedOffset = offset }
            session.move(to: CGPoint(x: 734, y: 300))
            session.tick(now: 0); session.tick(now: 0.7); session.cancel(); session.complete()
            try require(receivedOffset == nil && session.weekOffset == 0 && TaskSchedule(dragTask) == original,
                        "Cancel restores original week and never commits a task")

            #if os(macOS)
            final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 744, height: 500))
            scroll.documentView = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 744, height: 1728))
            session.scrollView = scroll
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { _, _ in }
            session.move(to: CGPoint(x: 300, y: 610))
            session.tick(now: 0); session.tick(now: 0.1)
            try require(scroll.contentView.bounds.minY == 0, "Briefly crossing a vertical edge does not scroll")
            for frame in 0..<100 { session.tick(now: 0.3 + Double(frame) * 0.016) }
            let scrolled = scroll.contentView.bounds.minY
            try require(scrolled > 720, "Holding below the grid scrolls more than ten hours without moving the pointer")
            session.move(to: CGPoint(x: 300, y: 300)); session.tick(now: 2.0)
            try require(scroll.contentView.bounds.minY == scrolled, "Leaving edge stops scrolling")
            session.cancel(); session.tick(now: 3.0)
            try require(scroll.contentView.bounds.minY == scrolled, "Cancel stops edge scrolling")
            _ = session.finish()
            #endif

            var landedZone = WeekDropGeometry.Zone.none
            var landedWeek = 0, dropCount = 0
            session.canvas = geometry.canvas; session.viewport = geometry.viewport
            session.undated = geometry.undated; session.allDay = geometry.allDay
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset; dropCount += 1
            }
            session.samplePointer(at: CGPoint(x: 734, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.panelView = nil // Simulate removal of the old page's host/source.
            session.samplePointer(at: CGPoint(x: wednesday, y: sixPM), pressed: true)
            try require(session.isDragging && session.weekOffset == 1 && session.zone == .timed(day: 2, minute: 1080),
                        "After next-week paging a detached source still allows choosing Wednesday at 18:00")
            session.samplePointer(at: CGPoint(x: wednesday + 100, y: sixPM - 72), pressed: false)
            session.samplePointer(at: CGPoint(x: 0, y: 0), pressed: false)
            try require(dropCount == 1 && landedWeek == 1 && landedZone == .timed(day: 3, minute: 1020),
                        "Physical release uses final Thursday 17:00 location exactly once")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset; dropCount += 1
            }
            session.samplePointer(at: CGPoint(x: 10, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.samplePointer(at: CGPoint(x: wednesday, y: 75), pressed: false)
            try require(landedWeek == -1 && landedZone == .allDay(2), "Previous-week paging can land on the all-day row")
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, _ in landedZone = zone }
            session.samplePointer(at: CGPoint(x: 734, y: 300), pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            session.samplePointer(at: CGPoint(x: 800, y: 300), pressed: false)
            try require(landedZone == .undated, "After paging a task can still return to the undated area")

            #if os(macOS)
            // No visible window or generated mouse events: exercise the real AppKit coordinate conversion.
            let testWindow = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1000, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
            testWindow.isReleasedWhenClosed = false
            let host = FlippedDocument(frame: CGRect(x: 60, y: 40, width: 744, height: 600))
            testWindow.contentView!.addSubview(host)
            session.panelView = host
            session.canvas = geometry.canvas
            session.begin(dragTask, color: .accentColor, grabOffset: 0) { zone, offset in
                landedZone = zone; landedWeek = offset
            }
            let edgeScreen = testWindow.convertPoint(toScreen: host.convert(CGPoint(x: 734, y: 300), to: nil))
            let finalScreen = testWindow.convertPoint(toScreen: host.convert(CGPoint(x: wednesday, y: sixPM), to: nil))
            session.sampleScreenPointer(at: edgeScreen, pressed: true)
            session.tick(now: 0); session.tick(now: 0.7)
            host.removeFromSuperview()
            session.sampleScreenPointer(at: finalScreen, pressed: true)
            try require(session.isDragging && session.weekOffset == 1 && session.zone == .timed(day: 2, minute: 1080),
                        "Native screen coordinates still resolve after the old host leaves its window")
            session.sampleScreenPointer(at: finalScreen, pressed: false)
            try require(landedWeek == 1 && landedZone == .timed(day: 2, minute: 1080),
                        "Release commits the new week's location even with no source host")
            testWindow.close()
            #endif

            #endif
            // --- full-day free time, with no presumed sleeping hours ---
            func at(_ hour: Int, _ minute: Int) -> Date { Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date(2026, 9, 18))! }
            try require(PlanBlock.countedSpan(day: date(2026, 9, 17), now: at(14, 10)) == nil, "Past days have no free time left")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(14, 10)).map { $0 == (850, 1440) } == true, "Today includes every remaining minute")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(6, 0)).map { $0 == (360, 1440) } == true, "Early morning is available")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(23, 30)).map { $0 == (1410, 1440) } == true, "Late-night half hour remains available")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 19), now: at(14, 10)).map { $0 == (0, 1440) } == true, "Future days count all 24 hours")
            try require(PlanBlock.countedSpan(day: date(2026, 9, 18), now: at(0, 0)).map { $0 == (0, 1440) } == true, "Midnight starts a full day")
        }
    }

    static func continuationGeometry(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            let day = Dates.calendar.startOfDay(for: date(2026, 9, 21))
            func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
            let task = TaskItem(title: "Stretch", scheduledAt: at(12)); task.hasTime = true; task.endAt = at(15)
            task.reminderAt = at(11); task.reminderKind = "oneHour"
            let before = TaskSchedule(task)
            let top = TaskResize(task: task, day: day, top: true)!, bottom = TaskResize(task: task, day: day, top: false)!
            let layout = TimelineLayout(startMinute: 0, endMinute: 1440, scale: 1.2)
            try require(top.minute(at: layout.y(11 * 60 + 8), layout: layout) == 675, "Resize edge snaps to nearest quarter hour")
            try require(top.date(at: top.minute(at: layout.y(16 * 60), layout: layout)) == at(14.75) && bottom.date(at: bottom.minute(at: layout.y(11 * 60), layout: layout)) == at(12.25), "Resize edges cannot cross and retain a fifteen-minute minimum")
            try require(bottom.minute(at: layout.y(1600), layout: layout) == 1440, "Bottom edge can reach midnight without exceeding its day")
            let proposal = TaskMove(task, to: at(11), kind: .resizeStart)
            try require(TaskSchedule(task) == before && proposal.apply(to: task, shiftDeadline: false), "Resize preview is value-only and commits only on request")
            try require(task.scheduledAt == at(11) && task.endAt == at(15) && task.reminderAt == at(10), "Start-edge resize keeps end fixed and follows relative reminder")
            before.restore(task)
            task.dueAt = at(16); task.dueHasTime = true
            let longer = TaskMove(task, to: at(17), kind: .resizeEnd)
            try require(!longer.canKeepDeadline && !longer.apply(to: task, shiftDeadline: false) && task.endAt == at(15), "Extending beyond deadline waits for confirmation")
            try require(longer.apply(to: task, shiftDeadline: true) && task.endAt == at(17) && task.dueAt == at(17) && task.scheduledAt == at(12), "Confirmed bottom resize extends end and deadline only as needed")
            before.restore(task)
            task.endAt = at(30)
            try require(TaskResize(task: task, day: day, top: false) == nil && TaskResize(task: task, day: at(24), top: true) == nil,
                        "Multi-day task handles only appear at the true start and end")
            try require(TaskResize(task: task, day: at(24), top: false) != nil, "Cross-midnight final segment exposes its end handle")
            before.restore(task)
            #if os(macOS)
            let session = WeekDrag()
            session.canvas = CGRect(x: 0, y: 0, width: 700, height: 1800); session.viewport = session.canvas; session.layout = layout
            var drops = 0; var endpoint: Date?
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 100, y: layout.y(960))) { value, _ in endpoint = value; drops += 1 }
            try require(session.zone == .timed(day: 0, minute: 960) && TaskSchedule(task) == before, "Resize session previews candidate without writing task")
            session.tick(now: 0); session.tick(now: 10)
            try require(session.weekOffset == 0, "Resizing within a day does not turn a week")
            session.cancel(); session.complete()
            try require(drops == 0 && TaskSchedule(task) == before, "Esc cancels resize without committing")
            session.updateResize(task, color: .blue, range: bottom, point: CGPoint(x: 100, y: layout.y(1020))) { value, _ in endpoint = value; drops += 1 }
            session.complete(); session.complete()
            try require(drops == 1 && endpoint == at(17), "Resize release commits the final endpoint exactly once")
            session.updateResize(task, color: .blue, range: top, point: CGPoint(x: 100, y: layout.y(600))) { _, _ in drops += 1 }
            _ = session.checkPhysicalButton(pressed: false, now: 1); _ = session.checkPhysicalButton(pressed: false, now: 1.2)
            session.complete()
            try require(drops == 1, "Missed mouse-up cancels resize instead of silently changing time")
            #endif
        }
    }

    static func resizeUnits(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        do {
            func moment(_ y: Int, _ m: Int, _ d: Int, _ hour: Int) -> Date { date(y, m, d).addingTimeInterval(Double(hour) * 3600) }
            let task = TaskItem(title: "Optional deadline", scheduledAt: moment(2026, 9, 21, 10))
            task.hasTime = true; task.endAt = moment(2026, 9, 21, 11); task.dueAt = moment(2026, 9, 25, 18); task.dueHasTime = true
            let original = TaskSchedule(task)
            let plan = TaskMove(task, to: moment(2026, 9, 22, 10), kind: .timed)
            try require(plan.canKeepDeadline && plan.apply(to: task, shiftDeadline: false), "Nonconflicting deadline move saves without confirmation")
            let moved = TaskSchedule(task)
            try require(task.dueAt == original.dueAt && plan.deferredDeadline(for: task, after: moved) == moment(2026, 9, 26, 18), "Saved move keeps deadline and offers optional offset-preserving shift")
            task.dueAt = plan.deferredDeadline(for: task, after: moved)
            try require(plan.deferredDeadline(for: task, after: moved) == nil, "Optional deadline shift cannot run twice")
            original.restore(task)
            try require(TaskSchedule(task) == original, "Undo after optional deadline shift restores both original dates")
            _ = plan.apply(to: task, shiftDeadline: false)
            let stale = TaskSchedule(task); task.endAt = moment(2026, 9, 22, 12)
            try require(plan.deferredDeadline(for: task, after: stale) == nil, "Stale optional action cannot overwrite a later schedule edit")
            stale.restore(task); task.deletedAt = Date()
            try require(plan.deferredDeadline(for: task, after: stale) == nil, "Deleted task rejects optional deadline action")
            task.deletedAt = nil; original.restore(task)
            let earlier = TaskMove(task, to: moment(2026, 9, 20, 10), kind: .timed)
            _ = earlier.apply(to: task, shiftDeadline: false)
            try require(earlier.deferredDeadline(for: task, after: TaskSchedule(task)) == moment(2026, 9, 24, 18), "Backward move offers backward deadline shift")
            original.restore(task)
            let resize = TaskMove(task, to: moment(2026, 9, 21, 12), kind: .resizeEnd)
            try require(resize.canKeepDeadline && resize.apply(to: task, shiftDeadline: false) && task.dueAt == original.dueAt && resize.deferredDeadline(for: task, after: TaskSchedule(task)) == nil, "Safe edge adjustment keeps deadline without prompting or a no-op action")
            original.restore(task)
            let conflict = TaskMove(task, to: moment(2026, 9, 26, 10), kind: .timed)
            try require(!conflict.canKeepDeadline && !conflict.apply(to: task, shiftDeadline: false) && TaskSchedule(task) == original, "Conflicting move waits without silently changing either date")
            try require(conflict.apply(to: task, shiftDeadline: true) && task.dueAt == moment(2026, 9, 30, 18), "Confirmed conflict shifts both dates")
            for height in [4.5, 9, 12, 13.5, 18, 24, 27, 72] {
                let edge = TaskResize.handleHeight(for: height)
                try require(edge * 2 <= height / 2 && (height < 12 ? edge == 0 : edge > 0), "Resize edge zones leave central moving space at height \(height)")
            }
            try require(TaskResize.handleHeight(for: 60 * 0.3) == 4.5, "One-hour task at 25 percent zoom has usable top and bottom edges")
        }
    }
}
