import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

// MARK: - Week view drag (Mac)

/// Mac week view: a task follows the pointer directly instead of going through system drag and drop.
/// Only the few small views that draw the drag read this object, so moving the pointer never redraws the page.
///
/// Once a drag starts, AppKit's own mouse events drive it (not the SwiftUI gesture), so it keeps working after
/// the page turns and the card it started from is gone. A 60 Hz ticker only handles edge dwell and scrolling.
@MainActor @Observable final class WeekDrag {
    nonisolated static let space = "weekPanel"
    private(set) var taskID: UUID?
    private(set) var title = ""
    private(set) var color = Color.accentColor
    private(set) var durationMinutes = 60.0
    @ObservationIgnored private(set) var resizeRange: TaskResize?
    @ObservationIgnored private var occupied: [DateInterval] = []
    private(set) var overlaps = false
    var resizeInterval: DateInterval? {
        guard isDragging, let range = resizeRange, case .timed(let day, let minute) = zone else { return nil }
        return range.interval(at: minute, dayIndex: day, weekOffset: weekOffset)
    }
    private(set) var pointer = CGPoint.zero
    private(set) var zone = WeekDropGeometry.Zone.none
    /// -1 or 1 while the pointer rests on the previous- or next-week strip.
    private(set) var edge = 0
    private(set) var cancelled = false
    /// Weeks away from the one the drag started in; the page shows that week until the drag ends.
    private(set) var weekOffset = 0
    private(set) var pageForward = true
    /// Frames in the panel's coordinate space, reported as they change. Not observed: nothing redraws for them.
    @ObservationIgnored var canvas = CGRect.zero { didSet { if isDragging { resolve() } } }
    @ObservationIgnored var viewport = CGRect.zero
    @ObservationIgnored var allDay = CGRect.zero
    @ObservationIgnored var undated = CGRect.zero
    @ObservationIgnored var layout: TimelineLayout?
    /// Month view: the cells and their visible part. Set only while the month view is showing.
    @ObservationIgnored var monthCanvas = CGRect.zero { didSet { if isDragging { resolve() } } }
    @ObservationIgnored var monthViewport = CGRect.zero
    /// The month a month-view drag started in; nil while dragging in the week view.
    @ObservationIgnored private(set) var monthAnchor: Date?
    #if os(macOS)
    @ObservationIgnored var trailing = 20.0
    #else
    @ObservationIgnored var trailing = 0.0
    #endif
    @ObservationIgnored weak var scrollView: AnyObject?
    @ObservationIgnored weak var panelView: AnyObject?
    @ObservationIgnored private var grabOffset = 0.0
    @ObservationIgnored private var releasedSince: Double?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var edgeHover = WeekEdgeHover()
    @ObservationIgnored private var verticalSince: Double?
    /// Canvas top minus (viewport top - scroll offset), measured when a drag starts. Lets every sample place the
    /// grid from the scroll view's real offset instead of waiting for a layout report.
    @ObservationIgnored private var canvasBias: CGFloat?
    @ObservationIgnored private var heldScrollY: CGFloat?
    @ObservationIgnored private var holdUntil = 0.0
    @ObservationIgnored private var onDrop: ((WeekDropGeometry.Zone, Int) -> Void)?
    #if os(macOS)
    @ObservationIgnored private weak var trackingWindow: NSWindow?
    @ObservationIgnored private var panelOriginInWindow: CGPoint?
    #endif

    var isDragging: Bool { taskID != nil && !cancelled }

    /// In the month view, pages are months: `weekOffset` then counts months.
    private var monthGeometry: MonthDropGeometry? {
        guard let monthAnchor else { return nil }
        let month = Dates.shiftMonth(monthAnchor, by: weekOffset)
        return MonthDropGeometry(canvas: monthCanvas, viewport: monthViewport,
                                 inMonth: Dates.monthCells(month).map { Dates.calendar.isDate($0, equalTo: month, toGranularity: .month) })
    }

    /// Where the floating chip may go.
    var chipBounds: CGRect { monthAnchor == nil ? viewport : monthViewport }

    private var geometry: WeekDropGeometry? {
        layout.map { WeekDropGeometry(canvas: canvas, viewport: viewport, allDay: allDay, undated: undated, trailing: trailing, layout: $0) }
    }

    func begin(_ task: TaskItem, color: Color, grabOffset: Double, month: Date? = nil, onDrop: @escaping (WeekDropGeometry.Zone, Int) -> Void) {
    reset(animated: false)
    monthAnchor = month
        taskID = task.id; title = task.title; self.color = color
        durationMinutes = (task.duration ?? 3600) / 60
        self.grabOffset = grabOffset
        self.onDrop = onDrop
        canvasBias = month == nil ? scrollOffset().map { canvas.minY - (viewport.minY - $0) } : nil
        #if os(macOS)
        captureTrackingSpace()
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // A new press must never finish an abandoned previous gesture.
                self?.finish(); return event
            },
            NSEvent.addLocalMonitorForEvents(matching: [.appKitDefined, .systemDefined]) { [weak self] event in
                if !NSApp.isActive { self?.cancel() }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
                self?.follow(event); return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.follow(event); self?.complete(); return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sampleScreenPointer(at: NSEvent.mouseLocation, pressed: false)
                    self?.complete()
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.isDragging else { return event }
                self.cancel(); return nil
            }
        ].compactMap { $0 }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.taskID != nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.checkPhysicalButton(pressed: NSEvent.pressedMouseButtons & 1 != 0, now: now) else { return }
                if !NSApp.isActive || NSApp.modalWindow != nil { self.cancel(); return }
                self.tick(now: now)
            }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
        #endif
    }

    /// The session is the sole owner of drag state. A source view may never receive onEnded
    /// when a page turn replaces it, so no per-card "started" flag is retained.
    func updateGesture(_ task: TaskItem, color: Color, grabOffset: Double, point: CGPoint,
                       month: Date? = nil, onDrop: @escaping (WeekDropGeometry.Zone, Int) -> Void) {
        if taskID == nil { begin(task, color: color, grabOffset: grabOffset, month: month, onDrop: onDrop) }
        guard taskID == task.id else { return }
        move(to: point)
    }

    func updateResize(_ task: TaskItem, color: Color, range: TaskResize, point: CGPoint, others: [TaskItem] = [], onDrop: @escaping (Date, Int) -> Void) {
        if taskID == nil {
            begin(task, color: color, grabOffset: 0) { zone, offset in
                if case .timed(let day, let minute) = zone {
                    onDrop(range.date(at: minute, dayIndex: day, weekOffset: offset), offset)
                }
            }
            resizeRange = range
            occupied = PlanBlock.occupied(others, excluding: task.id)
        }
        guard taskID == task.id, resizeRange != nil else { return }
        move(to: point)
    }

    func move(to point: CGPoint) {
        guard isDragging else { return }
        pointer = point
        resolve()
    }

    /// Esc: the task stays where it was; if another week is showing, the page slides back.
    func cancel() {
        guard taskID != nil, !cancelled else { return }
        cancelled = true; zone = .none; edge = 0
        ticker?.invalidate(); ticker = nil
        slideBack()
    }

    /// Where the task would be let go now (nothing if cancelled), then forgets the drag without dropping.
    @discardableResult func finish() -> WeekDropGeometry.Zone {
        let result = cancelled ? .none : zone
        reset(animated: false)
        return result
    }

    /// Release: hands the landing spot to the page exactly once. After a page turn the page already shows the
    /// destination week, so the hand-off happens without a second page animation.
    func complete() {
        guard taskID != nil else { return }
        let result = cancelled ? WeekDropGeometry.Zone.none : zone
        let offset = cancelled ? 0 : weekOffset
        let callback = onDrop
        if result == .none {
            slideBack()
            reset(animated: false)
            return
        }
        if monthAnchor == nil { holdScrollPosition() }
        var quiet = Transaction()
        quiet.disablesAnimations = offset != 0
        withTransaction(quiet) {
            reset(animated: false)
            callback?(result, offset)
        }
    }

    /// A missing release may only cancel; it must never synthesize a drop.
    /// Keep the cancelled session until release/new press so late gesture updates cannot restart it.
    @discardableResult func checkPhysicalButton(pressed: Bool, now: Double) -> Bool {
        guard isDragging else { return false }
        if pressed { releasedSince = nil; return true }
        if let since = releasedSince {
            if now - since >= 0.10 { cancel() }
        } else { releasedSince = now }
        return false // Stop edge paging/scrolling as soon as the physical button is up.
    }

    func tick(now: Double) {
    guard isDragging else { return }
    if let month = monthGeometry {
        let direction = month.edgeDirection(pointer: pointer)
        if direction != edge { edge = direction }
        let step = edgeHover.step(direction: direction, now: now)
        if step != 0 { turnPage(step) }
        return
    }
    syncCanvas()
        guard let geometry else { return }
        let direction = geometry.edgeDirection(pointer: pointer)
        if direction != edge { edge = direction }
        let step = edgeHover.step(direction: direction, now: now)
        if step != 0 { turnPage(step) }
        let speed = direction == 0 ? geometry.scrollSpeed(pointer: pointer) : 0
        // A short pause first, so passing the edge on the way somewhere does not scroll.
        if speed == 0 { verticalSince = nil }
        else if let since = verticalSince { if now - since >= 0.15 { scroll(by: speed) } }
        else { verticalSince = now }
    }

    /// Shared by the event monitor and the checks: move, and let go when the button is up.
    func samplePointer(at point: CGPoint, pressed: Bool) {
        guard taskID != nil else { return }
        move(to: point)
        if !pressed { complete() }
    }

    private func turnPage(_ step: Int) {
        pageForward = step > 0
        weekOffset += step
        zone = .none
        resolve()
    }

    private func slideBack() {
        guard weekOffset != 0 else { return }
        pageForward = weekOffset < 0
        weekOffset = 0
    }

    private func resolve() {
        if let range = resizeRange, let layout, let geometry {
            guard viewport.contains(pointer), geometry.edgeDirection(pointer: pointer) == 0 else {
                zone = .none; overlaps = false; return
            }
            let minute = range.minute(at: Double(pointer.y - canvas.minY), layout: layout)
            let next = WeekDropGeometry.Zone.timed(day: geometry.day(at: Double(pointer.x)), minute: minute)
            if next != zone {
                zone = next
                if let interval = resizeInterval {
                    durationMinutes = interval.duration / 60
                    overlaps = PlanBlock.overlaps(interval, others: occupied)
                }
            }
            return
        }
    if let month = monthGeometry {
        let next: WeekDropGeometry.Zone = undated.contains(pointer) && undated.width > 0 ? .undated : month.zone(pointer: pointer)
        if next != zone { zone = next }
        return
    }
    guard let geometry, canvas.width > 0 else { return }
        let next = geometry.zone(pointer: pointer, grabOffset: grabOffset, durationMinutes: durationMinutes)
        if next != zone { zone = next }
    }

    private func reset(animated: Bool) {
        if taskID != nil { taskID = nil }
        if cancelled { cancelled = false }
        if zone != .none { zone = .none }
        if edge != 0 { edge = 0 }
        if weekOffset != 0 { weekOffset = 0 }
        onDrop = nil
        resizeRange = nil
        occupied = []; overlaps = false
        releasedSince = nil
        monthAnchor = nil
        edgeHover = WeekEdgeHover(); verticalSince = nil; canvasBias = nil
        ticker?.invalidate(); ticker = nil
        #if os(macOS)
        monitors.forEach { NSEvent.removeMonitor($0) }
        #endif
        monitors = []
    }

    #if os(macOS)
    /// The panel's own view converts window points directly; the remembered origin covers a moment
    /// when that view is being replaced.
    private func follow(_ event: NSEvent) {
        guard isDragging else { return }
        syncCanvas()
        if let panel = panelView as? NSView, let window = panel.window, window === event.window {
            move(to: panel.convert(event.locationInWindow, from: nil))
            panelOriginInWindow = panel.convert(CGPoint.zero, to: nil)
            trackingWindow = window
        } else if let window = trackingWindow, let origin = panelOriginInWindow {
            let point = event.window === window ? event.locationInWindow : window.convertPoint(fromScreen: NSEvent.mouseLocation)
            move(to: CGPoint(x: point.x - origin.x, y: origin.y - point.y))
        }
    }

    private func captureTrackingSpace() {
        guard let panel = panelView as? NSView, let window = panel.window else { return }
        trackingWindow = window
        panelOriginInWindow = panel.convert(CGPoint.zero, to: nil)
    }

    /// Screen coordinates to the panel, for checks that have no real mouse events.
    func sampleScreenPointer(at screenPoint: CGPoint, pressed: Bool) {
        captureTrackingSpace()
        guard let window = trackingWindow, let origin = panelOriginInWindow else { return }
        let point = window.convertPoint(fromScreen: screenPoint)
        samplePointer(at: CGPoint(x: point.x - origin.x, y: origin.y - point.y), pressed: pressed)
    }
    #endif

    private func scroll(by delta: Double) {
        #if os(macOS)
        guard let scrollView = scrollView as? NSScrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        let before = origin.y
        let limit = max(0, document.frame.height - clip.bounds.height)
        origin.y = min(limit, max(0, origin.y + CGFloat(document.isFlipped ? delta : -delta)))
        guard origin.y != before else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        // The grid moved under a still pointer: place it from the real offset now, not when layout reports it.
        syncCanvas()
        #endif
        }

        /// How far the grid is scrolled from its top, read from the scroll view itself.
        func scrollOffset() -> CGFloat? {
            #if os(macOS)
            guard let scrollView = scrollView as? NSScrollView, let document = scrollView.documentView else { return nil }
            let bounds = scrollView.contentView.bounds
            return document.isFlipped ? bounds.minY : document.frame.height - bounds.maxY
            #else
            return nil
            #endif
        }

        func setScrollOffset(_ offset: CGFloat) {
            #if os(macOS)
            guard let scrollView = scrollView as? NSScrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let limit = max(0, document.frame.height - clip.bounds.height)
            let top = min(limit, max(0, offset))
            var origin = clip.bounds.origin
            origin.y = document.isFlipped ? top : document.frame.height - clip.bounds.height - top
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            #endif
        }

        private func syncCanvas() {
            guard let bias = canvasBias, let offset = scrollOffset() else { return }
            let top = viewport.minY - offset + bias
            if abs(top - canvas.minY) > 0.5 { canvas.origin.y = top }
        }

        /// After a drop the grid keeps showing the same hours, even if the week view is rebuilt around it
        /// (moving to another week does that) — it no longer jumps to the current time or to 8:00.
        private func holdScrollPosition() {
            guard let offset = scrollOffset() else { return }
            heldScrollY = offset
            holdUntil = ProcessInfo.processInfo.systemUptime + 1.2
            Task { @MainActor [weak self] in
                for delay in [50, 200, 450] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self, let held = self.heldScrollY, !self.isDragging,
                          ProcessInfo.processInfo.systemUptime < self.holdUntil else { return }
                    if let now = self.scrollOffset(), abs(now - held) > 1 { self.setScrollOffset(held) }
                }
            }
        }

        /// Used when the week view appears: true if it should stay on the held hours instead of jumping.
        func restoreHeldScroll() -> Bool {
            guard let held = heldScrollY, ProcessInfo.processInfo.systemUptime < holdUntil else { return false }
            setScrollOffset(held)
            return true
        }
        /// Explicit navigation wins over delayed scroll restoration after a drag.
        func releaseHeldScroll() { heldScrollY = nil; holdUntil = 0 }
        }

/// Picks a task up in the Mac week view. The source stays in place, faded, while the drag is drawn elsewhere.
struct WeekDragSource: ViewModifier {
    let task: TaskItem
    let color: Color
    /// Distance from the task's top edge to where it was grabbed, given the start point in the panel.
    let grabOffset: (CGPoint) -> Double
    /// Cards with buttons inside need the drag to run alongside those buttons.
    var simultaneous = false
    /// Set in the month view: the month on screen when the drag starts.
    var month: Date? = nil
    let drop: (TaskItem, WeekDropGeometry.Zone, Int) -> Void
    @Environment(WeekDrag.self) private var drag
    func body(content: Content) -> some View {
        let gesture = DragGesture(minimumDistance: 4, coordinateSpace: .named(WeekDrag.space))
            .onChanged { value in
                guard task.previewSourceID == nil else { return }
                drag.updateGesture(task, color: color, grabOffset: grabOffset(value.startLocation),
                                   point: value.location, month: month) { zone, offset in
                    if zone != .none { drop(task, zone, offset) }
                }
            }
            .onEnded { _ in
                // Native mouse-up usually finishes first; this is the fallback when it was missed.
                #if os(macOS)
                if drag.taskID == task.id { drag.complete() }
                #endif
            }
        let lifted = drag.taskID == task.id && !drag.cancelled
        return Group {
            if simultaneous { content.simultaneousGesture(gesture) } else { content.gesture(gesture) }
        }
        .opacity(lifted ? 0.35 : 1)
        .animation(.easeOut(duration: 0.12), value: lifted)
    }
}

/// Animate only the week contents. Never replace the scroll view or the drag tracker.
struct WeekPageSlide: ViewModifier {
    @Environment(WeekDrag.self) private var drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content.id(drag.weekOffset)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: drag.pageForward ? .trailing : .leading),
                    removal: .move(edge: drag.pageForward ? .leading : .trailing)))
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: drag.weekOffset)
    }
}

/// Where the task will land on the grid: a copy of the block at the snapped quarter hour, with its new time.
struct WeekDragGhost: View {
    let layout: TimelineLayout
    let column: CGFloat
    let gutter: CGFloat
    let days: [Date]
    @Environment(WeekDrag.self) private var drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if drag.isDragging, case .timed(let day, let minute) = drag.zone {
            let start = drag.resizeInterval?.start ?? Dates.clockTime(on: days[day], minute: minute)
            let end = drag.resizeInterval?.end ?? start.addingTimeInterval(drag.durationMinutes * 60)
            let laneWidth = column / CGFloat(drag.resizeRange?.columns ?? 1)
            let laneOffset = CGFloat(drag.resizeRange?.column ?? 0) * laneWidth
            ForEach(Array(days.enumerated()), id: \.offset) { index, date in
                if let slice = PlanBlock.segment(from: start, to: end, on: date) {
                    let span = Dates.clockSpan(from: slice.start, to: slice.end, on: date)
                    let visualStart = span.start
                    let height = layout.intervalHeight(from: visualStart, to: span.end)
                    RoundedRectangle(cornerRadius: min(5, height / 2)).fill(drag.color.opacity(0.3))
                        .frame(width: max(10, laneWidth - 2), height: height)
                        .overlay(RoundedRectangle(cornerRadius: min(5, height / 2)).strokeBorder(drag.color, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if drag.resizeRange == nil, index == day {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(drag.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(Dates.label(start, pattern: "E HH:mm") + "–" + Dates.label(end, pattern: Dates.sameDay(start, end) ? "HH:mm" : "M月d日 HH:mm"))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(3).background(height < 32 ? Color.appBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .offset(y: height < 32 ? height + 3 : 0)
                            }
                        }
                        .offset(x: gutter + CGFloat(index) * column + laneOffset + 1, y: CGFloat(layout.y(visualStart)))
                }
            }
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.95), value: drag.zone)
        }
    }
}

/// Off the grid (all-day row, undated list, the week edges, or nowhere) a small card follows the pointer.
struct WeekDragChip: View {
    @Environment(WeekDrag.self) private var drag

    var body: some View {
        if drag.isDragging, !isTimed || drag.resizeRange != nil {
            let interval = drag.resizeInterval
            let width: CGFloat = interval == nil ? 170 : 300
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(drag.color).frame(width: 6, height: 6)
                    Text(drag.title).font(.caption.weight(.medium)).lineLimit(1)
                }
                if let interval {
                    Text(Dates.label(interval.start, pattern: "M月d日 E HH:mm") + " → " + Dates.label(interval.end, pattern: Dates.sameDay(interval.start, interval.end) ? "HH:mm" : "M月d日 E HH:mm"))
                        .font(.caption2.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                    Text(Dates.durationLabel(minutes: Int(interval.duration / 60))).font(.caption2).foregroundStyle(.secondary)
                    if drag.overlaps {
                        Label(L("与其他任务重叠", "Overlaps another task"), systemImage: "square.on.square")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8).frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(drag.color.opacity(0.6)))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            .offset(x: min(max(0, drag.pointer.x + 12), max(0, drag.chipBounds.maxX - width - 4)),
                    y: min(max(0, drag.pointer.y + 12), max(0, drag.chipBounds.maxY - (interval == nil ? 36 : 108))))
            .allowsHitTesting(false)
        }
    }

    private var isTimed: Bool {
        if case .timed = drag.zone { return true }
        return false
    }
}

/// Lights up the all-day cell or the undated list while a task is held over it.
struct WeekZoneHighlight: ViewModifier {
    let zone: WeekDropGeometry.Zone
    @Environment(WeekDrag.self) private var drag

    func body(content: Content) -> some View {
        let on = drag.isDragging && drag.zone == zone
        return content
            .background(on ? drag.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay { if on { RoundedRectangle(cornerRadius: 5).strokeBorder(drag.color, lineWidth: 1).allowsHitTesting(false) } }
    }
}

#if os(macOS)
/// One quiet line in the empty part of the navigator row, so the drag gestures can be found at all.
/// While a task is held it says what the pointer will do right now.
struct PlanHint: View {
    @AppStorage("appLanguage") private var language = "system"
    let month: Bool
    @Environment(WeekDrag.self) private var drag

    var body: some View {
        Label(text, systemImage: drag.isDragging ? "hand.draw" : "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .animation(.easeOut(duration: 0.12), value: text)
    }

    private var text: String {
        if month {
            guard drag.isDragging else {
            return L("拖动任务到另一天可改期 · 拖到左右两侧可翻月 · 点日期查看当天任务", "Drag a task to another day to reschedule · Hold at either side to change month · Click a date to see its tasks")
            }
            switch drag.edge {
            case -1: return L("停住会翻到上个月 · 在这里松手不改动", "Hold to go to the previous month · Releasing here changes nothing")
            case 1: return L("停住会翻到下个月 · 在这里松手不改动", "Hold to go to the next month · Releasing here changes nothing")
            default: return L("松手放下 · 停在左右两侧翻月 · 按 Esc 取消", "Release to drop · Hold at either side to change month · Esc to cancel")
            }
        }
        guard drag.isDragging else {
            return L("双击空白新建 · 拖动改期 · 边缘翻周 · 双指缩放", "Double-click a blank slot to add · Drag to reschedule · Hold at edges to change week · Pinch to zoom")
        }
        switch drag.edge {
        case -1: return L("停住会翻到上一周 · 在这里松手不改动", "Hold to go to the previous week · Releasing here changes nothing")
        case 1: return L("停住会翻到下一周 · 在这里松手不改动", "Hold to go to the next week · Releasing here changes nothing")
        default: return L("松手放下 · 停在左右两侧翻周 · 按 Esc 取消", "Release to drop · Hold at either side to change week · Esc to cancel")
        }
    }
}

#endif


#if os(macOS)
/// Hands the grid's NSScrollView to the drag so it can scroll while a task is held near an edge.
private struct WeekPanelProbe: NSViewRepresentable {
    let drag: WeekDrag
    func makeNSView(context: Context) -> Probe { let view = Probe(); drag.panelView = view; return view }
    func updateNSView(_ nsView: Probe, context: Context) { drag.panelView = nsView }
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct EnclosingScrollView: NSViewRepresentable {
    let found: (NSScrollView?) -> Void
    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ nsView: Probe, context: Context) { if nsView.window != nil { found(nsView.enclosingScrollView) } }
    final class Probe: NSView {
        let found: (NSScrollView?) -> Void
        init(found: @escaping (NSScrollView?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        // A week view on its way out must not replace the one that just took its place.
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { found(enclosingScrollView) } }
    }
}
#endif

extension View {
    /// Mac: report this view's frame in the week panel, for working out where a dragged task is.
    @ViewBuilder func reportWeekFrame(_ set: @escaping (CGRect) -> Void) -> some View {
        #if os(macOS)
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WeekDrag.space)) } action: { set($0) }
        #else
        self
        #endif
    }

    @ViewBuilder func weekDragPanel(_ drag: WeekDrag) -> some View {
        #if os(macOS)
        background(WeekPanelProbe(drag: drag))
            .overlay(alignment: .topLeading) { WeekDragChip() }
            .coordinateSpace(.named(WeekDrag.space))
        #else
        self
        #endif
    }

    /// Mac: the grid reports its frame, scroll view and scale to the drag. iPhone keeps system drag and drop.
    @ViewBuilder func weekCanvasDrop<Preview: View>(drag: WeekDrag, layout: TimelineLayout,
                                                    slotAt: @escaping (CGPoint) -> PlanSlot?,
                                                    @ViewBuilder preview: @escaping (PlanSlot) -> Preview,
                                                    receive: @escaping (String, CGPoint) -> Void) -> some View {
        #if os(macOS)
        reportWeekFrame { drag.canvas = $0 }
            .background(EnclosingScrollView { drag.scrollView = $0 })
            .onChange(of: layout, initial: true) { _, value in drag.layout = value }
        #else
        modifier(TimelineHoverDrop(slotAt: slotAt, preview: preview, receive: receive))
        #endif
    }
}
