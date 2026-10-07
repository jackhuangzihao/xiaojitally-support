import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension View {
    /// Both platforms accept a dragged task on a day without changing its clock time.
    @ViewBuilder func dayDrop(tint: Color = .accentColor, warn: ((UUID) -> Bool)? = nil, _ perform: @escaping ([String]) -> Bool) -> some View {
        modifier(TaskDropHighlight(tint: tint, warn: warn, perform: perform))
    }
}

/// One owner for hover feedback; missing exit callbacks cannot leave multiple cells highlighted.
@MainActor @Observable final class DragFeedback {
    private(set) var target: UUID?
    private(set) var payload: String?
    private(set) var sessionID: UUID?
    private(set) var blockedUntilMouseDown = false
    #if os(macOS)
    @ObservationIgnored private var nextPressMonitor: Any?
    @ObservationIgnored private var cancelMonitor: Any?
    @ObservationIgnored private var deactivateObserver: NSObjectProtocol?
    #endif

    func begin(_ id: UUID) {
        guard !blockedUntilMouseDown else { return }
        end()
        sessionID = UUID()
        payload = "jianshi-task:" + id.uuidString
        #if os(macOS)
        cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
            return event
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        #endif
    }

    func cancel() {
        end()
        blockedUntilMouseDown = true
        #if os(macOS)
        if nextPressMonitor == nil {
            nextPressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.newPress()
                return event
            }
        }
        #endif
    }

    func newPress() {
        blockedUntilMouseDown = false
        #if os(macOS)
        if let nextPressMonitor { NSEvent.removeMonitor(nextPressMonitor); self.nextPressMonitor = nil }
        #endif
    }

    var draggedID: UUID? { payload.flatMap { UUID(uuidString: String($0.dropFirst(13))) } }
    func enter(_ id: UUID) { if payload != nil && target != id { target = id } }
    func leave(_ id: UUID) { if target == id { target = nil } }
    /// Ignore a late native callback belonging to an earlier drag.
    func end(session: UUID) {
        guard sessionID == session else { return }
        end()
    }

    func end() {
        target = nil; payload = nil; sessionID = nil
        #if os(macOS)
        if let cancelMonitor { NSEvent.removeMonitor(cancelMonitor); self.cancelMonitor = nil }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
        #endif
    }
}




/// Native task dragging; virtual repeat previews remain read-only.
struct TaskDragSource: ViewModifier {
    let task: TaskItem
    var showPreview = true
    @Environment(DragFeedback.self) private var feedback

    private var preview: some View {
        HStack(spacing: 5) {
            Circle().fill(ListColor.color(task.calendarList?.id, hex: task.calendarList?.colorHex)).frame(width: 5, height: 5)
            Text(task.title).font(.caption).lineLimit(1)
        }.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: 160)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder func body(content: Content) -> some View {
        if task.previewSourceID != nil || task.deletedAt != nil { content }
        else {
            #if os(macOS)
            content.background(NativeTaskDrag(id: task.id, feedback: feedback, image: {
                let renderer = ImageRenderer(content: preview.fixedSize())
                renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
                return renderer.nsImage ?? NSImage(size: NSSize(width: 160, height: 24))
            }))
            #else
            content.onDrag {
                feedback.begin(task.id)
                guard let payload = feedback.payload else { return NSItemProvider() }
                return NSItemProvider(object: payload as NSString)
            } preview: {
                if showPreview { preview }
                else { Color.accentColor.opacity(0.001).frame(width: 1, height: 1) }
            }
            #endif
        }
    }
}

#if os(macOS)
/// Use AppKit's session-ended callback; physical button state is not a trackpad drag's lifetime.
private struct NativeTaskDrag: NSViewRepresentable {
    let id: UUID
    let feedback: DragFeedback
    let image: () -> NSImage

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak coordinator] event in
            guard let coordinator else { return event }
            return coordinator.handle(event)
        }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { context.coordinator.source = self }
    func makeCoordinator() -> Coordinator { Coordinator(source: self) }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        // AppKit retains the source until its session ends, even if the row disappears on drop.
    }
    @MainActor final class Coordinator: NSObject, NSDraggingSource {
        var source: NativeTaskDrag
        weak var view: Probe?
        var monitor: Any?
        var press: NSEvent?
        var activeSession: UUID?
        var nativeSessions: [Int: UUID] = [:]
        init(source: NativeTaskDrag) { self.source = source }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window else { return event }
            if event.type == .leftMouseDown {
                press = nil
                guard window.attachedSheet == nil, !view.isHiddenOrHasHiddenAncestor,
                      view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                activeSession = nil
                source.feedback.newPress()
                source.feedback.end()
                press = event
            } else if event.type == .leftMouseUp { press = nil }
            else if let press, activeSession == nil {
                guard !source.feedback.blockedUntilMouseDown else { self.press = nil; return event }
                guard hypot(event.locationInWindow.x - press.locationInWindow.x,
                            event.locationInWindow.y - press.locationInWindow.y) >= 5 else { return event }
                self.press = nil
                source.feedback.begin(source.id)
                guard let payload = source.feedback.payload, let session = source.feedback.sessionID else { return event }
                activeSession = session
                let item = NSDraggingItem(pasteboardWriter: payload as NSString)
                let image = source.image()
                let point = view.convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - image.size.height / 2,
                                             width: image.size.width, height: image.size.height), contents: image)
                view.beginDraggingSession(with: [item], event: event, source: self)
                return nil
            }
            return event
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication && source.feedback.sessionID == activeSession ? .move : []
        }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            nativeSessions[session.draggingSequenceNumber] = activeSession
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let token = nativeSessions.removeValue(forKey: session.draggingSequenceNumber) else { return }
            source.feedback.end(session: token)
            if activeSession == token { activeSession = nil; press = nil }
        }
    }
}
#endif

struct TaskDropHighlight: ViewModifier {
    let tint: Color
    /// Orange instead of the tint when this drop would need confirmation (past the deadline).
    var warn: ((UUID) -> Bool)? = nil
    var accepts: ((UUID) -> Bool)? = nil
    let perform: ([String]) -> Bool
    @State private var targetID = UUID()
    @Environment(DragFeedback.self) private var feedback

    func body(content: Content) -> some View {
        let targeted = feedback.target == targetID
        let color = targeted && (feedback.draggedID.map { warn?($0) ?? false } ?? false) ? Color.orange : tint
        return content.background(targeted ? color.opacity(0.10) : .clear)
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.text], delegate: TimelineDrop(
                update: { _ in
                    guard let id = feedback.draggedID, accepts?(id) ?? true else { feedback.leave(targetID); return }
                    feedback.enter(targetID)
                },
                exit: { feedback.leave(targetID) },
                receive: { value, _ in feedback.end(); _ = perform([value]) },
                localValue: {
                    guard let id = feedback.draggedID, accepts?(id) ?? true else { return nil }
                    return feedback.payload
                }))
    }
}

struct TimelineDrop: DropDelegate {
    let update: (CGPoint) -> Void
    let exit: () -> Void
    let receive: (String, CGPoint) -> Void
    var localValue: (() -> String?)? = nil
    func dropEntered(info: DropInfo) { update(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info.location); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { exit() }
    func performDrop(info: DropInfo) -> Bool {
        // All app targets require a live local session. Never revive an Esc-cancelled
        // or expired drag from an old asynchronous pasteboard provider.
        if localValue != nil {
            if acceptLocal(at: info.location) { return true }
            exit()
            return false
        }
        guard let provider = info.itemProviders(for: [UTType.text]).first else { exit(); return false }
        return load(provider, at: info.location)
    }

    /// Internal moves already have a payload; avoid an asynchronous provider roundtrip.
    func acceptLocal(at point: CGPoint) -> Bool {
        guard let value = localValue?() else { return false }
        exit()
        receive(value, point)
        return true
    }

    /// Clear hover immediately, before the asynchronous transfer or any save.
    func load(_ provider: NSItemProvider, at point: CGPoint) -> Bool {
        exit()
        guard provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let value = object as? String
            DispatchQueue.main.async { if let value { receive(value, point) } else { exit() } }
        }
        return true
    }
}

#if os(macOS)
/// Resolve the clicked slot once. Mouse movement does not publish state or rebuild the calendar.
struct CalendarPasteMenu: NSViewRepresentable {
    var actionAt: (CGPoint) -> (String, () -> Void)?
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.actionAt = actionAt }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var actionAt: ((CGPoint) -> (String, () -> Void)?)?
        private var monitor: Any?
        private var paste: (() -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(point), let (title, action) = self.actionAt?(point) else { return event }
                let menu = NSMenu(); menu.autoenablesItems = false
                let item = NSMenuItem(title: title, action: #selector(self.performPaste), keyEquivalent: "")
                item.target = self; menu.addItem(item); self.paste = action
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                self.paste = nil
                return nil
            }
        }
        @objc private func performPaste() { paste?() }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}


#endif
