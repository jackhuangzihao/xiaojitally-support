import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

// MARK: - Shared calendar drag

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
    @ObservationIgnored var gutter = 44.0
    @ObservationIgnored var touchEdges = false
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
    #if os(iOS)
    @ObservationIgnored let mobileSources = NSHashTable<UIView>.weakObjects()
    #endif
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
                                 inMonth: Dates.monthCells(month).map { Dates.calendar.isDate($0, equalTo: month, toGranularity: .month) },
                                 edgeInset: touchEdges ? 24 : 0)
    }

    /// Where the floating chip may go.
    var chipBounds: CGRect { monthAnchor == nil ? viewport : monthViewport }

    private var geometry: WeekDropGeometry? {
        layout.map { WeekDropGeometry(canvas: canvas, viewport: viewport, allDay: allDay, undated: undated, gutter: gutter, trailing: trailing, layout: $0,
                                    edgeInset: touchEdges ? 24 : 0, scrollBand: touchEdges ? 64 : 32) }
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

    /// Keep the exact pickup point on both platforms, including a continuation from yesterday.
    func pickupOffset(for task: TaskItem, on day: Date, at point: CGPoint) -> Double {
        guard let clock = task.clockDate, let layout else { return 12 }
        let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: day), to: Dates.calendar.startOfDay(for: clock)).day ?? 0
        return Double(point.y - canvas.minY) - layout.y(Double(days * 1440) + Dates.clockMinute(clock))
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
        if direction == 0 { scroll(by: WeekDropGeometry.scrollSpeed(pointer: pointer, viewport: monthViewport, band: touchEdges ? 64 : 32)) }
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
        #else
        guard let scrollView = scrollView as? UIScrollView else { return }
        let before = scrollView.contentOffset.y
        let lower = -scrollView.adjustedContentInset.top
        let upper = max(lower, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let next = min(upper, max(lower, before + delta))
        guard abs(next - before) > 0.01 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
        if monthAnchor != nil { monthCanvas.origin.y -= next - before }
        else { syncCanvas() }
        #endif
        }

        /// How far the grid is scrolled from its top, read from the scroll view itself.
        func scrollOffset() -> CGFloat? {
            #if os(macOS)
            guard let scrollView = scrollView as? NSScrollView, let document = scrollView.documentView else { return nil }
            let bounds = scrollView.contentView.bounds
            return document.isFlipped ? bounds.minY : document.frame.height - bounds.maxY
            #else
            guard let scrollView = scrollView as? UIScrollView else { return nil }
            return scrollView.contentOffset.y + scrollView.adjustedContentInset.top
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
            #else
            guard let scrollView = scrollView as? UIScrollView else { return }
            let lower = -scrollView.adjustedContentInset.top
            let upper = max(lower, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(upper, max(lower, offset + lower))), animated: false)
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
