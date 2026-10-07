import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
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
    /// Report the frame in the stable calendar panel, shared by native drag tracking on both platforms.
    @ViewBuilder func reportWeekFrame(_ set: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WeekDrag.space)) } action: { set($0) }
    }

    @ViewBuilder func weekDragPanel(_ drag: WeekDrag) -> some View {
        #if os(macOS)
        background(WeekPanelProbe(drag: drag))
            .overlay(alignment: .topLeading) { WeekDragChip() }
            .coordinateSpace(.named(WeekDrag.space))
        #else
        overlay(alignment: .topLeading) { WeekDragChip() }
            .coordinateSpace(.named(WeekDrag.space))
        #endif
    }

    /// Both platforms report the same geometry; native scroll probes keep it current during a drag.
    @ViewBuilder func weekCanvasDrop(drag: WeekDrag, layout: TimelineLayout) -> some View {
        #if os(macOS)
        reportWeekFrame { drag.canvas = $0 }
            .background(EnclosingScrollView { drag.scrollView = $0 })
            .onChange(of: layout, initial: true) { _, value in drag.layout = value }
        #else
        reportWeekFrame { drag.canvas = $0 }
            .background(MobileCalendarScrollProbe { drag.scrollView = $0 })
            .onChange(of: layout, initial: true) { _, value in drag.layout = value }
        #endif
    }
}

#if os(iOS)
/// Resolve only the scroll view containing this grid, not another page's scroll view.
private struct MobileCalendarScrollProbe: UIViewRepresentable {
    let found: (UIScrollView?) -> Void
    final class Probe: UIView {
        var found: ((UIScrollView?) -> Void)?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
        func resolve() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { found?(scroll); return }
                ancestor = view.superview
            }
        }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.found = found; return view }
    func updateUIView(_ view: Probe, context: Context) { view.found = found; view.resolve() }
}

private struct MobileCalendarDragModifier: ViewModifier {
    let drag: WeekDrag
    let enabled: Bool
    @Environment(DragFeedback.self) private var feedback
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.background(MobileCalendarDrag(drag: drag, feedback: feedback, enabled: enabled))
            .onChange(of: phase) { _, value in if value != .active { _ = drag.finish(); feedback.end() } }
    }
}
#endif

extension View {
    @ViewBuilder func mobileCalendarDrag(drag: WeekDrag, enabled: Bool) -> some View {
        #if os(iOS)
        modifier(MobileCalendarDragModifier(drag: drag, enabled: enabled))
        #else
        self
        #endif
    }
    @ViewBuilder func calendarScrollProbe(_ drag: WeekDrag) -> some View {
        #if os(iOS)
        background(MobileCalendarScrollProbe { drag.scrollView = $0 })
        #else
        self
        #endif
    }
}
