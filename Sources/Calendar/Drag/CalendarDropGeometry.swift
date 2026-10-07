import Foundation

/// A day column and quarter hour in the week view.
struct PlanSlot: Equatable {
    var day: Int
    var minute: Int
    static func emptyPoint(_ point: CGPoint, column: CGFloat, gutter: CGFloat, layout: TimelineLayout, occupied: [CGRect], dayCount: Int = 7) -> Self? {
        guard dayCount > 0, column > 0, point.x >= gutter, point.x < gutter + column * CGFloat(dayCount), point.y >= 0, point.y < layout.height,
              !occupied.contains(where: { $0.contains(point) }) else { return nil }
        return Self(day: Int((point.x - gutter) / column), minute: layout.snapped(Double(point.y)))
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
    /// Touch screens need an edge band inside the display; desktop keeps the full day columns.
    var edgeInset: Double = 0
    var scrollBand: Double = 32

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
        if x >= Double(canvas.maxX) - max(trailing, edgeInset) { return 1 }
        return 0
    }

    /// Scrolls only within a thin band at the top or bottom of the grid (or below it), slowly at first:
    /// a slot near the edge can still be picked without the grid running away.
    static func scrollSpeed(pointer: CGPoint, viewport: CGRect, band: Double = 32) -> Double {
        guard pointer.x >= viewport.minX, pointer.x <= viewport.maxX, pointer.y >= viewport.minY else { return 0 }
        let fastest = 10.0
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
        return Self.scrollSpeed(pointer: pointer, viewport: viewport, band: scrollBand)
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
    var edgeInset: Double = 0

    var rows: Int { inMonth.count / 7 }

    func edgeDirection(pointer: CGPoint) -> Int {
        guard pointer.y >= viewport.minY, pointer.y <= viewport.maxY else { return 0 }
        if pointer.x < viewport.minX + edgeInset { return -1 }
        if pointer.x >= viewport.maxX - edgeInset { return 1 }
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
