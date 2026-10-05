import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

/// Left and right swipes turn the page: a finger drag on iPhone, a two-finger trackpad swipe on Mac.
struct PageSwipe: ViewModifier {
    let step: (Int) -> Void
    static func direction(_ translation: CGSize) -> Int? {
        let dx = translation.width, dy = translation.height
        guard abs(dx) > 70, abs(dx) > abs(dy) * 1.6 else { return nil }
        return dx < 0 ? 1 : -1
    }
    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(MacPageSwipe(step: step))
        #else
        if #available(iOS 18, *) {
            content.gesture(HorizontalPageDrag(step: step))
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                if let direction = Self.direction(value.translation) { step(direction) }
            })
        }
        #endif
    }

}

#if os(macOS)
/// Local monitors receive events from every app window, including background editors.
@MainActor enum LocalEventScope {
    static func accepts(window source: NSWindow?, in view: NSView) -> Bool {
        guard let owner = view.window else { return false }
        return source === owner && owner.attachedSheet == nil && !view.isHiddenOrHasHiddenAncestor
    }
}

private struct MacPageSwipe: NSViewRepresentable {
    let step: (Int) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.step = step }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var step: ((Int) -> Void)?
        private var monitor: Any?
        private var total: CGFloat = 0
        private var fired = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, LocalEventScope.accepts(window: event.window, in: self),
                      let window = self.window, window.isKeyWindow || window.isMainWindow,
                      !(window is NSPanel), self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.phase == .began || event.phase == .mayBegin { self.total = 0; self.fired = false }
                guard event.momentumPhase.isEmpty, event.hasPreciseScrollingDeltas else { return event }
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 {
                    self.total += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                    if !self.fired && abs(self.total) > 80 {
                        self.fired = true
                        self.step?(self.total < 0 ? 1 : -1)
                    }
                }
                if event.phase == .ended || event.phase == .cancelled { self.total = 0; self.fired = false }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; total = 0; fired = false
        }
    }
}
#endif

#if os(iOS)
/// Reject vertical pans before recognition, so scrolling keeps its native momentum.
@available(iOS 18, *)
private struct HorizontalPageDrag: UIGestureRecognizerRepresentable {
    let step: (Int) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator
        return gesture
    }
    func handleUIGestureRecognizerAction(_ gesture: UIPanGestureRecognizer, context: Context) {
        guard gesture.state == .ended else { return }
        let delta = gesture.translation(in: gesture.view)
        if let direction = PageSwipe.direction(CGSize(width: delta.x, height: delta.y)) { step(direction) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.6
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
#endif
