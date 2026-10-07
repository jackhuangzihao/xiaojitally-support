#if os(iOS)
import SwiftUI
import UIKit
import OSLog

/// A source only registers its visible bounds. The stable panel owns the touch from pickup
/// through release, even when edge paging removes the original card from the hierarchy.
struct MobileCalendarDragSource: UIViewRepresentable {
    let drag: WeekDrag
    let begin: (CGPoint) -> Void

    final class Probe: UIView {
        var begin: ((CGPoint) -> Void)?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.begin = begin
        drag.mobileSources.add(view)
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.begin = begin
        drag.mobileSources.add(view)
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.begin = nil }

    static func contains(_ point: CGPoint, in panel: UIView, source: UIView) -> Bool {
        guard let window = panel.window, source.window === window,
              source.bounds.contains(source.convert(point, from: panel)) else { return false }
        var ancestor: UIView? = source
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            if view.clipsToBounds && !view.bounds.contains(view.convert(point, from: panel)) { return false }
            ancestor = view.superview
        }
        return true
    }
}

/// One continuous long press drives the same WeekDrag engine as the Mac. System item
/// providers/drop proposals are deliberately not involved in moving within this calendar.
struct MobileCalendarDrag: UIViewRepresentable {
    let drag: WeekDrag
    let feedback: DragFeedback
    let enabled: Bool

    final class Probe: UIView {
        var moved: (() -> Void)?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() { super.didMoveToWindow(); moved?() }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); context.coordinator.view = view
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.attach() }
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { context.coordinator.source = self; context.coordinator.attach() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { view.moved = nil; coordinator.detach() }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var source: MobileCalendarDrag
        weak var view: Probe?
        private weak var window: UIWindow?
        private var press: UILongPressGestureRecognizer?
        private var ticker: Timer?
        private var token: UUID?
        private var origin = CGPoint.zero
        private weak var picked: MobileCalendarDragSource.Probe?
        private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Jianshi", category: "CalendarDrag")
        init(_ source: MobileCalendarDrag) { self.source = source }

        func attach() {
            guard let next = view?.window else { detach(); return }
            guard next !== window else {
                if press?.isEnabled != source.enabled { press?.isEnabled = source.enabled }
                return
            }
            detach()
            let press = UILongPressGestureRecognizer(target: self, action: #selector(changed(_:)))
            press.name = "Calendar task drag"
            press.minimumPressDuration = 0.25
            press.allowableMovement = 10
            press.numberOfTouchesRequired = 1
            press.cancelsTouchesInView = true
            press.delegate = self
            press.isEnabled = source.enabled
            next.addGestureRecognizer(press)
            self.press = press; window = next
        }
        func detach() {
            if let press { press.isEnabled = false; window?.removeGestureRecognizer(press) }
            press = nil; window = nil
            finish(commit: false)
        }
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view, let touched = touch.view else { return false }
            return prepare(at: touch.location(in: view), touching: touched)
        }

        /// Keep hit testing independent of UITouch so real hosted hierarchies can be checked.
        func prepare(at point: CGPoint, touching touched: UIView) -> Bool {
            picked = nil
            guard source.enabled, let view, view.window != nil else { return false }
            origin = point
            picked = source.drag.mobileSources.allObjects.compactMap { $0 as? MobileCalendarDragSource.Probe }
                .first { $0.begin != nil && MobileCalendarDragSource.contains(origin, in: view, source: $0) }
            // Presented sheets/popovers must never start a drag in the calendar behind them.
            guard let picked else { return false }
            var parent: UIView? = picked.superview
            while let candidate = parent, candidate !== window {
                if touched === candidate || touched.isDescendant(of: candidate) { return true }
                parent = candidate.superview
            }
            self.picked = nil
            return false
        }
        // A card's SwiftUI button and the calendar pan must wait for this source-scoped
        // long press. A tap or ordinary scroll makes it fail immediately; holding picks up.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            guard source.enabled, picked != nil, gestureRecognizer === press,
                  let otherView = otherGestureRecognizer.view, otherView !== window,
                  !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer),
                  !(otherGestureRecognizer is UIPinchGestureRecognizer) else { return false }
            return true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard source.enabled, let view, let picked else { return false }
            return picked.begin != nil && MobileCalendarDragSource.contains(origin, in: view, source: picked)
        }
        @objc private func changed(_ press: UILongPressGestureRecognizer) {
            guard let view else { finish(commit: false); return }
            switch press.state {
            case .began:
                guard let begin = picked?.begin else { return }
                begin(origin)
                guard let id = source.drag.taskID else { return }
                source.feedback.newPress(); source.feedback.begin(id); token = source.feedback.sessionID
                Self.log.debug("Calendar touch drag began")
                source.drag.move(to: press.location(in: view))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                self.ticker = ticker; RunLoop.main.add(ticker, forMode: .common)
            case .changed:
                guard source.feedback.sessionID == token, source.drag.isDragging else { return }
                source.drag.move(to: press.location(in: view))
            case .ended:
                if source.feedback.sessionID == token { source.drag.move(to: press.location(in: view)) }
                finish(commit: true)
            case .cancelled, .failed: finish(commit: false)
            default: break
            }
        }
        private func tick() {
            guard let press, let view, view.window != nil, source.drag.isDragging,
                  source.feedback.sessionID == token, UIApplication.shared.applicationState == .active else {
                finish(commit: false); return
            }
            source.drag.move(to: press.location(in: view))
            source.drag.tick(now: ProcessInfo.processInfo.systemUptime)
        }
        private func finish(commit: Bool) {
            ticker?.invalidate(); ticker = nil; picked = nil
            guard let token else { return }
            self.token = nil
            Self.log.debug("Calendar touch drag ended; commit: \(commit)")
            if source.feedback.sessionID == token {
                if commit { source.drag.complete() } else { _ = source.drag.finish() }
                source.feedback.end(session: token)
            }
        }
    }
}
#endif
