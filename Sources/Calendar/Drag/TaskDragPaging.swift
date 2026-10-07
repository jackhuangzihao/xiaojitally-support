import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Observe the native session on the window: header paging must also stop when a cancelled
/// drag ends without a SwiftUI drop-exit callback. Date cells keep their own drop targets.
private struct TaskDragPage: ViewModifier {
    let step: (Int) -> Void
    @Environment(DragFeedback.self) private var feedback
    func body(content: Content) -> some View {
        content.background(TaskDatePageTracker(feedback: feedback, step: step))
    }
}
private struct TaskDatePageTracker: UIViewRepresentable {
    let feedback: DragFeedback
    let step: (Int) -> Void
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
    @MainActor final class Coordinator: NSObject, UIDropInteractionDelegate {
        var source: TaskDatePageTracker
        weak var view: Probe?
        weak var window: UIWindow?
        private var interaction: UIDropInteraction?
        private var session: UIDropSession?
        private var token: UUID?
        private var ticker: Timer?
        private var hover = WeekEdgeHover()
        init(_ source: TaskDatePageTracker) { self.source = source }
        func attach() {
            guard let next = view?.window else { detach(); return }
            guard next !== window else { return }
            detach()
            let interaction = UIDropInteraction(delegate: self)
            next.addInteraction(interaction); self.interaction = interaction; window = next
        }
        func detach() {
            stop()
            if let interaction { window?.removeInteraction(interaction) }
            interaction = nil; window = nil
        }
        private func stop() {
            ticker?.invalidate(); ticker = nil; session = nil; hover = WeekEdgeHover()
            if let token { source.feedback.end(session: token) }; token = nil
        }
        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.localDragSession != nil && source.feedback.payload != nil
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) { track(session) }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            track(session)
            return UIDropProposal(operation: .cancel) // Paging is navigation; only date cells perform moves.
        }
        private func track(_ next: UIDropSession) {
            guard session !== next else { return }
            stop(); session = next; token = source.feedback.sessionID
            let ticker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.ticker = ticker; RunLoop.main.add(ticker, forMode: .common)
        }
        private func tick() {
            guard let session, let view, view.window != nil, source.feedback.sessionID == token,
                  UIApplication.shared.applicationState == .active else { stop(); return }
            let point = session.location(in: view)
            let vertical = point.y >= 0 && point.y <= view.bounds.height
            let direction = vertical ? (point.x < 44 ? -1 : point.x >= view.bounds.width - 44 ? 1 : 0) : 0
            let amount = hover.step(direction: direction, now: ProcessInfo.processInfo.systemUptime)
            if amount != 0 { source.step(amount) }
        }
        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            if self.session === session { stop() }
        }
    }
}
#endif

extension View {
    @ViewBuilder func taskDragPage(onStep: @escaping (Int) -> Void) -> some View {
        #if os(iOS)
        modifier(TaskDragPage(step: onStep))
        #else
        self
        #endif
    }
}
