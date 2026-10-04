import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

struct CalendarPriorityMark: View {
    @Environment(\.locale) private var locale
    let priority: Int
    var isDone = false
    var body: some View {
        if priority > 0 {
            Text(priority == 2 ? L("高", "H") : L("中", "M"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 3).frame(height: 14)
                .foregroundStyle(isDone ? Color.secondary : (priority == 2 ? Color.white : Color.primary))
                .background(isDone ? Color.secondary.opacity(0.10) : (priority == 2 ? Color.red : Color.orange.opacity(0.22)), in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .accessibilityLabel(priority == 2 ? L("高优先级", "High priority") : L("中优先级", "Medium priority"))
        }
    }
}

// One palette for calendar blocks, sidebar icons and list selectors.
enum ListColor {
    static let presets: [(hex: String, zh: String, en: String)] = [
        ("799B80", "鼠尾草绿", "Sage"), ("409870", "森林绿", "Forest"), ("39A99B", "薄荷绿", "Mint"),
        ("3F9FBF", "湖蓝", "Lake"), ("5287CE", "蓝色", "Blue"), ("6571C5", "靛蓝", "Indigo"),
        ("9373C5", "紫色", "Purple"), ("B17AC3", "薰衣草紫", "Lavender"), ("C578AC", "玫瑰紫", "Rose"),
        ("D77690", "粉色", "Pink"), ("D46B65", "珊瑚红", "Coral"), ("BE565C", "红色", "Red"),
        ("D88951", "橙色", "Orange"), ("BD943F", "琥珀色", "Amber"), ("B5A44C", "金黄色", "Gold"),
        ("8C9C51", "橄榄绿", "Olive"), ("A0826E", "棕色", "Brown"), ("7C8C9C", "蓝灰色", "Slate"),
        ("28786A", "扩展色 1", "Extended 1"),
        ("21689B", "扩展色 2", "Extended 2"),
        ("334BA1", "扩展色 3", "Extended 3"),
        ("6646A5", "扩展色 4", "Extended 4"),
        ("953E92", "扩展色 5", "Extended 5"),
        ("AE4770", "扩展色 6", "Extended 6"),
        ("A74432", "扩展色 7", "Extended 7"),
        ("A56829", "扩展色 8", "Extended 8"),
        ("837A27", "扩展色 9", "Extended 9"),
        ("557C36", "扩展色 10", "Extended 10"),
        ("476D55", "扩展色 11", "Extended 11"),
        ("55636D", "扩展色 12", "Extended 12"),
        ("50B89C", "扩展色 13", "Extended 13"),
        ("57B6CF", "扩展色 14", "Extended 14"),
        ("779BE0", "扩展色 15", "Extended 15"),
        ("8C83D7", "扩展色 16", "Extended 16"),
        ("B493D8", "扩展色 17", "Extended 17"),
        ("D897BD", "扩展色 18", "Extended 18"),
        ("E5A07D", "扩展色 19", "Extended 19"),
        ("DDB869", "扩展色 20", "Extended 20"),
        ("B8C66E", "扩展色 21", "Extended 21"),
        ("87B4A4", "扩展色 22", "Extended 22"),
        ("A5AFBF", "扩展色 23", "Extended 23"),
        ("A9A0BB", "扩展色 24", "Extended 24"),
        ("3E5650", "扩展色 25", "Extended 25"),
        ("354E69", "扩展色 26", "Extended 26"),
        ("514467", "扩展色 27", "Extended 27"),
        ("764B62", "扩展色 28", "Extended 28"),
        ("775345", "扩展色 29", "Extended 29"),
        ("746C4A", "扩展色 30", "Extended 30")
    ]
    static func available(used: Set<String>) -> String {
        if let first = presets.first(where: { !used.contains($0.hex) }) { return first.hex }
        // Additional deterministic colors keep allocation possible after the fixed palette is used up.
        for index in 0...0xFFFFFF {
            let value = String(format: "%06X", (index &* 7919 &+ 0x527F96) & 0xFFFFFF)
            if !used.contains(value) { return value }
        }
        return "799B80"
    }
    static func normalize(_ lists: [TaskList]) {
        var reserved = Set(lists.compactMap { $0.colorHex?.uppercased() }.filter(TaskList.validColor))
        var seen = Set<String>()
        for list in lists.sorted(by: { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }) {
            if let color = list.colorHex?.uppercased(), TaskList.validColor(color), seen.insert(color).inserted { continue }
            let color = available(used: reserved)
            list.colorHex = color; reserved.insert(color); seen.insert(color)
        }
    }

    static func color(_ id: UUID?, hex: String? = nil) -> Color {
        if let hex, TaskList.validColor(hex), let rgb = UInt32(hex, radix: 16) {
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
        guard let id else { return .secondary }
        let palette: [Color] = [.accentColor, .blue, .purple, .orange, .teal, .pink]
        let index = id.uuidString.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }
}

struct ColoredListLabel: View {
    let name: String
    let id: UUID
    var colorHex: String? = nil
    var emoji: String? = nil
    var isGroup = false
    var body: some View {
        Label {
            Text(name)
        } icon: {
            if let emoji { Text(emoji) }
            else { Image(systemName: isGroup ? "folder.fill" : "list.bullet.rectangle").foregroundStyle(ListColor.color(id, hex: colorHex)) }
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var task: TaskItem?
    var date: Date?
    var listID: UUID?
    var timed = false

}

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

extension View {
    /// Mac only: accept a dragged task on a day.
    @ViewBuilder func dayDrop(tint: Color = .accentColor, warn: ((UUID) -> Bool)? = nil, _ perform: @escaping ([String]) -> Bool) -> some View {
        #if os(macOS)
        modifier(TaskDropHighlight(tint: tint, warn: warn, perform: perform))
        #else
        self
        #endif
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



extension DeadlineCountdown {
    var color: Color {
        switch level {
        case .normal: .secondary
        case .soon, .today: .orange
        case .overdue: .red
        }
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
        if task.previewSourceID != nil { content }
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

struct PendingMove {
    let proposal: TaskMove
    var revealDate: Date?
    var revealMonth = false
}

struct ListRequest: Identifiable {
    let id = UUID()
    var list: TaskList?
    var parentID: UUID?
}

private struct TaskCopyRequest: Identifiable {
    let id = UUID()
    let record: TaskBackup.TaskRecord
}

private struct TaskCopySheet: View {
    let record: TaskBackup.TaskRecord
    let copy: (Date, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @State private var moment: Date
    @State private var timed: Bool

    init(record: TaskBackup.TaskRecord, copy: @escaping (Date, Bool) -> Bool) {
        self.record = record; self.copy = copy
        _moment = State(initialValue: record.nextCopyDate ?? Date())
        _timed = State(initialValue: record.scheduledAt != nil ? record.hasTime : record.dueHasTime)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(record.title).font(.headline)
                    DatePicker(L("日期", "Date"), selection: $moment, displayedComponents: .date)
                    Toggle(L("指定时间", "Set a time"), isOn: $timed)
                    if timed { DatePicker(L("开始时间", "Start time"), selection: $moment, displayedComponents: .hourAndMinute) }
                    if timed, let start = record.scheduledAt ?? record.dueAt, let end = record.endAt, end > start {
                        LabeledContent(L("结束时间", "End time"), value: Dates.label(moment.addingTimeInterval(end.timeIntervalSince(start)), pattern: "M月d日 HH:mm"))
                    }
                } footer: {
                    Text(L("创建一项独立任务，保留时长、备注和子任务；原任务不变。", "Creates an independent task with the same duration, notes and subtasks. The original stays in place."))
                }
            }.formStyle(.grouped)
                .navigationTitle(L("复制任务", "Copy task"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("创建副本", "Create copy")) { if copy(moment, timed) { dismiss() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .onAppear { CloudSync.shared.editing(true) }
        .onDisappear { CloudSync.shared.editing(false) }
        .modifier(SaveRecoveryGuard())
        #if os(macOS)
        .frame(width: 420, height: 360)
        #endif
    }
}

/// Presentation changes belong to the popover subtree, not the calendar's layout calculation.
@MainActor @Observable final class CalendarPresentation {
    var taskKey: String?
    var day: Date?
    var expandedTask: UUID?
    var rowsHeight: CGFloat = 44
    var inlineDelete: UUID?

    func showTask(_ key: String) {
        if taskKey != key { inlineDelete = nil }
        day = nil
        taskKey = key
    }

    func dismissTask(_ key: String) {
        guard taskKey == key else { return }
        taskKey = nil; inlineDelete = nil
    }

    func isDay(_ value: Date) -> Bool { day.map { Dates.sameDay($0, value) } ?? false }

    func showDay(_ value: Date) {
        if !isDay(value) { expandedTask = nil; rowsHeight = 44 }
        taskKey = nil; inlineDelete = nil
        day = Dates.calendar.startOfDay(for: value)
    }

    func dismissDay(_ value: Date) {
        guard isDay(value) else { return }
        day = nil
    }

    func updateRowsHeight(_ height: CGFloat, for value: Date) {
        guard isDay(value), height.isFinite else { return }
        let bounded = min(360, max(44, ceil(height)))
        if rowsHeight != bounded { rowsHeight = bounded }
    }

    func close() {
        taskKey = nil; day = nil; inlineDelete = nil
    }
}

/// Keep both the binding's observation and the detail builder out of ContentView.body.
private struct CalendarTaskPopover<Detail: View>: ViewModifier {
    let presentation: CalendarPresentation
    let key: String
    @ViewBuilder let detail: () -> Detail

    func body(content: Content) -> some View {
        let showing = presentation.taskKey == key
        #if os(iOS)
        content.sheet(isPresented: Binding(get: { showing }, set: { if !$0 { presentation.dismissTask(key) } })) {
            NavigationStack {
                CalendarPopoverContent(build: detail)
                    .navigationTitle(L("任务详情", "Task details"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("关闭", "Close")) { presentation.dismissTask(key) } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        #else
        content.popover(isPresented: Binding(get: { showing }, set: { if !$0 { presentation.dismissTask(key) } })) {
            CalendarPopoverContent(build: detail)
        }
        #endif
    }
}

private struct CalendarDayPopover<Detail: View>: ViewModifier {
    let presentation: CalendarPresentation
    let day: Date
    @ViewBuilder let detail: () -> Detail

    func body(content: Content) -> some View {
        let showing = presentation.isDay(day)
        #if os(iOS)
        content.sheet(isPresented: Binding(get: { showing }, set: { if !$0 { presentation.dismissDay(day) } })) {
            CalendarPopoverContent(build: detail)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        #else
        content.popover(isPresented: Binding(get: { showing }, set: { if !$0 { presentation.dismissDay(day) } })) {
            CalendarPopoverContent(build: detail)
        }
        #endif
    }
}

#if os(iOS)
struct PhoneSearchToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.searchToolbarBehavior(.minimize)
        } else { content }
    }
}
#endif

private struct CalendarPopoverContent<Detail: View>: View {
    @ViewBuilder let build: () -> Detail
    var body: some View { build() }
}

/// Rebuild calendar layouts only when the day or a task's time-dependent state changes.
/// The minute hand and countdown labels have their own TimelineViews.
enum CalendarClock {
    static func needsRefresh(from old: Date, to now: Date, tasks: [TaskItem]) -> Bool {
        if now < old || !Dates.sameDay(old, now) { return true }
        return tasks.contains { task in
            guard task.deletedAt == nil, !task.isDone else { return false }
            if let reminder = task.reminderAt, old < reminder, reminder <= now { return true }
            return task.isOverdue(today: old) != task.isOverdue(today: now)
        }
    }
}

struct ContentView: View {
    let drafts: EditorDrafts
    let recoveryGeneration: Int
    @State private var financeMode = false
    @State private var financeSelection = "all"
    @State private var windowReady = false
    @State private var dragFeedback = DragFeedback()
    @AppStorage("appLanguage") private var language = "system"
    @State private var presentation = CalendarPresentation()
    @State private var slideForward = true
    @AppStorage("planningView") private var planningView = "list"
    @AppStorage("showPlanningCompleted") private var showPlanningCompleted = true
    @AppStorage("showDayFreeTime") private var showDayFreeTime = false
    @State private var dayCompletedExpanded = false
    @ScaledMetric(relativeTo: .caption) private var dayTimeWidth: CGFloat = 54
    @State private var assigning: UUID?

    @State private var filter = TaskFilter()
    @State private var repeatPreview = RepeatPreview()
    @State private var history = TaskHistory()
    @AppStorage("showRepeatPreviews") private var showRepeatPreviews = true
    @State private var showingSettings = false
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.createdAt) private var tasks: [TaskItem]
    @Query(sort: \TaskList.createdAt) private var lists: [TaskList]
    @Query(sort: \CalendarWeekTitle.week) private var weekTitles: [CalendarWeekTitle]
    @State private var copyRequest: TaskCopyRequest?
    @State private var copiedTask: TaskBackup.TaskRecord?
    @AppStorage("weekZoom") private var weekZoom = 1.0
    @AppStorage("initialListsCreated") private var initialListsCreated = false
    @State private var selection: TaskScope = .calendar
    @FocusState private var sidebarFocused: Bool
    @State private var selectedDate = Date()
    /// Weeks moved by dropping a task into another week. That week is already on screen, so the panel keeps its
    /// identity: no rebuild, no transition, and the grid stays at the same hours.
    @State private var revealShift = 0

    /// A task waiting for "delete?" to be confirmed.
    @State private var confirmingDelete: UUID?
    /// Months moved by dropping a task into another month, so the month panel is not rebuilt (see `revealShift`).
    @State private var monthRevealShift = 0
    #if os(macOS)
    @State private var listDrag = ListDrag()
    /// Groups open in the sidebar. Kept here (not inside an outline) so a drag knows which rows are on screen.
    @State private var expandedLists: Set<UUID> = []
    #endif
    /// The zoom while two fingers are pinching the week view; saved to `weekZoom` when they lift.
    @State private var pinchZoom: Double?
    @State private var pinchBase = 1.0
    @State private var pinchAnchorY: Double?
    @ScaledMetric(relativeTo: .body) private var calendarDayHeight: CGFloat = 48
    @State private var wholeMonth = false
    #if os(iOS)
    @State private var weekOnly = true
    #else
    @State private var weekOnly = false
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentDay = Date()
    @State private var showAllEarlier = false
    @State private var phoneOverdueExpanded = true
    @State private var undoDeletedIDs: [UUID] = []
    @State private var search = ""
    @State private var locatedTask: UUID?
    @State private var locateRequest = UUID()
    @State private var editor: EditorRequest?
    @State private var listEditor: ListRequest?
    @State private var movedMessage: String?
    @State private var moveFeedbackID = UUID()
    @State private var undoSchedule: (id: UUID, before: TaskSchedule, after: TaskSchedule)?
    @State private var undoListMove: (id: UUID, before: UUID?, after: UUID)?
    @State private var weekDrag = WeekDrag()
    @AppStorage("overdueExpanded") private var overdueExpanded = true
    @State private var pendingMove: PendingMove?
    @State private var deadlineMove: TaskMove?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deletingList: TaskList?
    @AppStorage("hideCompletedInAll") private var hideCompletedInAll = false
    @State private var purgeIDs: Set<UUID>?
    @State private var errorMessage: String?

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var overdueTasks: [TaskItem] {
        tasks.filter { $0.deletedAt == nil && $0.isOverdue(today: currentDay) }
            .sorted { ($0.calendarDate ?? .distantPast) < ($1.calendarDate ?? .distantPast) }
    }

    private var title: String {
        if case .list(let id) = selection { return lists.first { $0.id == id }?.name ?? L("清单", "List") }
        return selection.title
    }

    // ponytail: filter personal task collections in memory; move filtering into FetchDescriptor for large archives.
    private var visibleTasks: [TaskItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = Dates.calendar.dateInterval(of: wholeMonth ? .month : .day, for: selectedDate)!
        let matching = tasks.filter { task in
            guard (selection == .trash) == (task.deletedAt != nil) else { return false }
            let matches: Bool
            switch selection {
            case .calendar:
                // Searching from the calendar looks through every task, not only the selected day.
                matches = !needle.isEmpty || task.overlaps(range)
            case .all: matches = !(hideCompletedInAll && task.isDone && needle.isEmpty)
            case .trash: matches = true
            case .unscheduled: matches = task.calendarDate == nil
            case .completed: matches = task.isDone
            case .list(let id): matches = ListTree.contains(task.list?.id, in: id, lists: lists)
            }
            guard matches && (needle.isEmpty || CalendarTaskSearch.matches(task, query: needle, includeDeleted: selection == .trash)) else { return false }
            return filter.matches(task, lists: lists, today: currentDay)
        }
        if selection == .completed {
            return matching.sorted {
                if $0.completionSortDate != $1.completionSortDate { return $0.completionSortDate > $1.completionSortDate }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return TaskItem.ordered(matching)
    }

    private var searchingCalendar: Bool {
        selection == .calendar && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hiddenCompletedCount: Int {
        guard selection == .all, hideCompletedInAll, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        return tasks.filter { $0.deletedAt == nil && $0.isDone }.count
    }

    private var groups: [(date: Date, tasks: [TaskItem])] {
        Dictionary(grouping: visibleTasks) { task in
            if selection == .calendar && !wholeMonth && !searchingCalendar {
                return Dates.calendar.startOfDay(for: selectedDate)
            }
            return (selection == .completed ? task.completionSortDate : task.calendarDate).map { Dates.calendar.startOfDay(for: $0) } ?? .distantFuture
        }.map { (date: $0.key, tasks: $0.value) }.sorted { selection == .completed ? $0.date > $1.date : $0.date < $1.date }
    }

    var body: some View {
        editingContent
            .alert(L("操作未能保存", "Changes could not be saved"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L("知道了", "OK"), role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog(L("删除清单？任务会保留，子清单会移到上一级；重名时自动加序号。", "Delete this list? Tasks remain, and child lists move up one level. Duplicate names receive a number."), isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }), titleVisibility: .visible) {
                Button(L("删除清单，保留任务", "Delete list, keep tasks"), role: .destructive) {
                    guard let list = deletingList else { return }
                    let id = list.id
                    if commit({ ListTree.promoteChildren(of: list, lists: lists); context.delete(list) }), selection == .list(id) { selection = .all }
                    deletingList = nil
                }
            }
            .confirmationDialog(L("删除“\(confirmingDeleteTitle)”？", "Delete “\(confirmingDeleteTitle)”?"), isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
                Button(L("删除", "Delete"), role: .destructive) {
                    if let id = confirmingDelete, let task = tasks.first(where: { $0.id == id }) { deleteTask(task) }
                    confirmingDelete = nil
                }
                Button(L("取消", "Cancel"), role: .cancel) { confirmingDelete = nil }
            } message: { Text(L("删除后可以在“最近删除”中找回。", "You can bring it back from Recently deleted.")) }
            .confirmationDialog(purgeIDs?.count == 1 ? L("彻底删除这项任务？删除后无法恢复。", "Permanently delete this task? This can't be undone.") : L("彻底删除最近删除中的 \(purgeIDs?.count ?? 0) 项任务？删除后无法恢复。", "Permanently delete \(purgeIDs?.count ?? 0) tasks from Recently deleted? This can't be undone."), isPresented: Binding(get: { purgeIDs != nil }, set: { if !$0 { purgeIDs = nil } }), titleVisibility: .visible) {
                Button(L("彻底删除", "Delete permanently"), role: .destructive) {
                    guard let ids = purgeIDs else { return }
                    _ = commit { for task in tasks where ids.contains(task.id) && task.deletedAt != nil { context.delete(task) } }
                    undoDeletedIDs.removeAll { ids.contains($0) }
                    purgeIDs = nil
                }
            }
            .task { initializeWindow() }
            .onOpenURL { url in
                if let id = ReminderNavigation.taskID(url: url) {
                    drafts.reminder.pendingTaskID = id
                    openReminderIfReady()
                    return
                }
                #if os(macOS)
                guard url.scheme == "jianshi", Store.recovery.failure == nil else { return }
                guard editor == nil, listEditor == nil else { notify(L("请先完成当前编辑，再打开小组件中的任务。", "Finish the current edit before opening a widget task.")); return }
                if url.host == "today" {
                    showingSettings = false
                    selection = .calendar; planningView = "list"; selectedDate = Date(); wholeMonth = false; search = ""; filter = TaskFilter()
                } else if url.host == "all" {
                    showingSettings = false; selection = .all; hideCompletedInAll = true; search = ""; filter = TaskFilter()
                } else if let id = WidgetSnapshot.identifier(from: url, host: "list"), lists.contains(where: { $0.id == id }) {
                    showingSettings = false; selection = .list(id); search = ""; filter = TaskFilter()
                } else if let id = WidgetSnapshot.taskID(from: url), let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) {
                    showingSettings = false
                    selection = .calendar; search = ""; filter = TaskFilter(); locate(task)
                    editor = EditorRequest(task: task)
                }
                #endif
            }
            #if os(iOS)
            .onChange(of: ReminderInbox.shared.navigation.pendingTaskID, initial: true) { _, _ in receiveReminder() }
            #endif
            .onChange(of: language) { _, _ in
                #if os(macOS)
                if WidgetBridge.isEnabled { WidgetBridge.publish(context) }
                #endif
                ReminderScheduler.shared.refresh(context)
            }
            .modifier(SaveRecoveryGuard(active: editor == nil && listEditor == nil && copyRequest == nil && !showingSettings))
    }

    private var editingContent: some View {
        navigation
            #if os(macOS)
            .focusedSceneValue(\.taskHistory, financeMode ? nil : history)
            #endif
            .onChange(of: history.outcome) { _, value in if let value { notify(value) } }
            .environment(dragFeedback)
            .environment(weekDrag)
            .onDisappear { dragFeedback.end(); _ = weekDrag.finish() }


            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshDay() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in refreshDay() }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
                guard scenePhase == .active, CalendarClock.needsRefresh(from: currentDay, to: now, tasks: tasks) else { return }
                if !Dates.sameDay(currentDay, now) { selectedDate = Dates.selectionAfterDayChange(selectedDate, previousToday: currentDay, now: now) }
                currentDay = now
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDay(); receiveReminder() }
            }
            .safeAreaInset(edge: .bottom) {
                BackupStatusNotice { showingSettings = true }
                if let id = assigning, let task = tasks.first(where: { $0.id == id }) {
                    HStack {
                        Label(L("改期：\(task.title)", "Reschedule: \(task.title)"), systemImage: "calendar.badge.clock").lineLimit(1)
                        Spacer()
                        Text(L("点一个日期或时间段", "Tap a date or a time slot")).font(.caption).foregroundStyle(.secondary)
                        Button(L("取消", "Cancel")) { assigning = nil }.fontWeight(.semibold)
                    }.padding(.horizontal, 16).padding(.vertical, 6).background(.regularMaterial)
                } else if !undoDeletedIDs.isEmpty {
                    HStack {
                        Text(L("已删除 \(undoDeletedIDs.count) 项", "Deleted \(undoDeletedIDs.count) tasks"))
                        Spacer()
                        Button(L("撤销", "Undo"), action: undoDeletion).fontWeight(.semibold)
                        Button { undoDeletedIDs = [] } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.accessibilityLabel(L("关闭提示", "Dismiss message"))
                    }.padding(.horizontal, 16).padding(.vertical, 6).background(.regularMaterial)
                    .task(id: undoDeletedIDs) {
                        do { try await Task.sleep(for: .seconds(8)); undoDeletedIDs = [] } catch {}
                    }

                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let movedMessage, assigning == nil, undoDeletedIDs.isEmpty {
                    MoveFeedback(message: movedMessage, canUndo: undoSchedule != nil || undoListMove != nil,
                                 canShiftDeadline: deadlineMove != nil && undoSchedule != nil, shiftDeadline: shiftMovedDeadline,
                                 undo: { if undoListMove != nil { restoreListMove() } else { restoreSchedule() } },
                                 dismiss: { self.movedMessage = nil; undoSchedule = nil; undoListMove = nil; deadlineMove = nil })
                        .id(moveFeedbackID).padding(10)
                }
            }
            .confirmationDialog(pendingMoveTitle, isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible, presenting: pendingMove) { move in
                let plan = move.proposal
                if plan.canKeepDeadline, let due = plan.before.dueAt {
                    Button(L("截止仍为 \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))", "Keep deadline: \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))")) {
                        finishMove(move, shiftDeadline: false)
                        pendingMove = nil
                    }
                }
                if let due = plan.shiftedDeadline, due != plan.before.dueAt || !plan.canKeepDeadline {
                    Button(L("截止一起移到 \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))", "Move deadline to \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))")) {
                        finishMove(move, shiftDeadline: true)
                        pendingMove = nil
                    }
                }
                Button(L("取消", "Cancel"), role: .cancel) { pendingMove = nil }
            }

            .onChange(of: editor?.id) { _, value in if value == nil, recoveryGeneration == Store.recovery.generation { drafts.task = nil; drafts.taskID = nil } }
            .onChange(of: listEditor?.id) { _, value in if value == nil, recoveryGeneration == Store.recovery.generation { drafts.list = nil; drafts.listID = nil } }
            .onChange(of: Store.recovery.failure) { _, failure in
                guard failure != nil else { openReminderIfReady(); return }
                dragFeedback.end(); _ = weekDrag.finish()
                #if os(macOS)
                listDrag.cancel()
                #endif
                pendingMove = nil; confirmingDelete = nil; deletingList = nil; purgeIDs = nil
            }
            .onChange(of: reminderAlertActive) { _, active in if !active { openReminderIfReady() } }
            .onChange(of: drafts.finance == nil && drafts.financeEntity == nil && !drafts.financePresentationActive) { _, finished in
                if finished { openReminderIfReady() }
            }
            .sheet(isPresented: $showingSettings, onDismiss: openReminderIfReady) { PreferencesView() }
            .sheet(item: $copyRequest, onDismiss: openReminderIfReady) { request in
                TaskCopySheet(record: request.record) { moment, timed in pasteTask(request.record, at: moment, timed: timed) }
            }
            .sheet(item: $editor, onDismiss: openReminderIfReady) { request in
                TaskEditor(request: request, draft: drafts.task)
            }
            .sheet(item: $listEditor, onDismiss: openReminderIfReady) { request in ListEditor(list: request.list, parentID: request.parentID, draft: drafts.list) }
    }

    private var reminderAlertActive: Bool {
        pendingMove != nil || confirmingDelete != nil || deletingList != nil || purgeIDs != nil || errorMessage != nil
    }

    private func receiveReminder() {
        #if os(iOS)
        guard let id = ReminderInbox.shared.navigation.take(blocked: scenePhase != .active) else { return }
        drafts.reminder.pendingTaskID = id
        openReminderIfReady()
        #endif
    }

    private func openReminderIfReady() {
        let blocked = !windowReady || editor != nil || listEditor != nil || copyRequest != nil || showingSettings || reminderAlertActive
            || drafts.finance != nil || drafts.financeEntity != nil || drafts.financePresentationActive
            || Store.recovery.failure != nil || recoveryGeneration != Store.recovery.generation
        guard let id = drafts.reminder.take(blocked: blocked) else { return }
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else {
            notify(L("这项任务已删除或不在当前设备上。", "This task was deleted or is not on this device."))
            return
        }
        financeMode = false
        assigning = nil; copyRequest = nil; presentation.close()
        selection = .calendar; wholeMonth = false; search = ""; filter = TaskFilter()
        locate(task)
        editor = EditorRequest(task: task)
    }

    private func initializeWindow() {
        defer { windowReady = true; receiveReminder(); openReminderIfReady() }
        // The timeline and the multiweek overview became the week and month views.
        if planningView == "timeline" { planningView = "week" } else if planningView == "weeks" { planningView = "month" }
        restoreEditorDraft()
        do { try Store.save(context) } catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil }
        guard Store.recovery.failure == nil else { return }
        ReminderScheduler.shared.refresh(context)
        guard !initialListsCreated else { return }
        if lists.isEmpty {
            if commit({ [L("工作", "Work"), L("生活", "Personal"), L("学习", "Study")].enumerated().forEach { index, name in
                let list = TaskList(name: name)
                list.id = TaskItem.syncIdentity("tally-default-list-\(index)")
                list.createdAt = Date(timeIntervalSince1970: Double(index))
                context.insert(list)
            } }) {
                initialListsCreated = true
            }
        } else { initialListsCreated = true }
    }

    private func restoreEditorDraft() {
        if drafts.finance != nil || drafts.financeEntity != nil { financeMode = true; return }
        if drafts.task != nil {
            let task = tasks.first { $0.id == drafts.taskID }
            editor = EditorRequest(task: task)
        } else if let draft = drafts.list {
            let list = lists.first { $0.id == drafts.listID }
            listEditor = ListRequest(list: list, parentID: draft.parentID)
        }
    }

    private var selectedListID: UUID? {
        if case .list(let id) = selection { return id }
        return nil
    }

    @ViewBuilder private var navigation: some View {
        #if os(macOS)
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                AppSectionPicker(finance: $financeMode)
                if financeMode { FinanceSidebar(selection: $financeSelection) } else {
                List(selection: Binding<TaskScope?>(get: { selection }, set: { if let value = $0 { selection = value } })) {
                    ForEach(TaskScope.standard, id: \.self) { scope in
                        Label(scope.localizedTitle(language), systemImage: scope.icon).tag(scope)
                    }
                    Section {
                            // One custom stack, not one native row per list: native sidebar rows clip anything moved
                            // outside their own bounds, so rows making way for a drag simply vanished.
                            SidebarListTree(nodes: ListNode.roots(lists), expanded: $expandedLists, drag: listDrag, selected: selectedListID) { node in
                                AnyView(
                                    ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji, isGroup: node.children != nil)
                                        .modifier(SidebarListRow(list: node.list, isGroup: node.children != nil, drag: listDrag, select: { selection = .list(node.id); sidebarFocused = true },
                                                                 blocked: { ListTree.contains($0, in: node.id, lists: lists) },
                                                                 drop: { target in dropList(node.id, on: target) }))
                                        .modifier(TaskDropHighlight(tint: ListColor.color(node.id, hex: node.list.colorHex),
                                            accepts: { id in tasks.contains { $0.id == id && $0.deletedAt == nil && $0.list?.id != node.id } },
                                            perform: { moveTask($0, toList: node.id) }))
                                        .contextMenu {
                                            Button(L("新建子清单", "New child list")) { listEditor = ListRequest(parentID: node.id) }
                                            Button(L("编辑清单", "Edit list")) { listEditor = ListRequest(list: node.list) }
                                            Button(L("删除清单", "Delete list"), role: .destructive) { deletingList = node.list }
                                        }
                                )
                            }
                    } header: {
                        HStack(spacing: 4) {
                            Text(L("我的清单", "My lists"))
                            Spacer(minLength: 0)
                            Button { listEditor = ListRequest() } label: {
                                Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help(L("新建清单或分组", "New list or group"))
                            .accessibilityLabel(L("新建清单或分组", "New list or group"))
                        }
                        .modifier(SidebarListHeader(drag: listDrag))
                    }
                }
                .focused($sidebarFocused)
                .background(SidebarKeyboardNavigation { direction in
                    guard !listDrag.isDragging else { return false }
                    selection = selection.adjacentSidebarScope(direction: direction, lists: lists, expanded: expandedLists)
                    return true
                })
                }
                Label(CloudSync.shared.summary, systemImage: CloudSync.shared.enabled ? "icloud" : "internaldrive").font(.caption).foregroundStyle(.secondary).padding(16)
                }.padding(.top, 20)
                    .overlay(alignment: .topLeading) { ListDragFloatingRow(drag: listDrag) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listDrag.sidebar = $0 }
                    .onAppear {
                        listDrag.visibleRows = { visibleListIDs() }
                        listDrag.isDescendant = { child, parent in ListTree.contains(child, in: parent, lists: lists) }
                        listDrag.listName = { id in lists.first { $0.id == id }?.name ?? "" }
                        listDrag.descendantCount = { id in lists.filter { $0.id != id && ListTree.contains($0.id, in: id, lists: lists) }.count }
                        listDrag.depthOf = { id in
                            var depth = 0, parent = lists.first { $0.id == id }?.parentID
                            while let current = parent, depth < 64 { depth += 1; parent = lists.first { $0.id == current }?.parentID }
                            return depth
                        }
                        // Resting on a closed group while dragging opens it, so a list can go next to one of its children.
                        listDrag.openGroup = { id in
                            guard !expandedLists.contains(id), lists.contains(where: { $0.parentID == id }) else { return }
                            withAnimation(.easeOut(duration: 0.15)) { _ = expandedLists.insert(id) }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if financeMode {
                financeContent
            } else { mainContent }
        }
        #else
        TabView(selection: $financeMode) {
            NavigationStack { mainContent }
                .tabItem { Label(L("待办", "Tasks"), systemImage: "checklist") }.tag(false)
            NavigationStack { financeContent }
                .tabItem { Label(L("财务", "Finance"), systemImage: "wallet.pass") }.tag(true)
        }
        #endif
    }

    private var financeContent: some View {
        FinanceHome(selection: $financeSelection, openTask: { id in
            guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { notify(L("关联任务已删除或不在本机。", "Linked task was deleted or is unavailable.")); return }
            financeMode = false; editor = EditorRequest(task: task)
        }, settings: { showingSettings = true })
    }

    #if os(macOS)
    /// A list dropped into a group goes in; the group stays as it was, open or closed.
    private func dropList(_ id: UUID, on target: (list: UUID?, placement: ListTree.Placement)) {
        moveList(id, to: target.list.flatMap { id in lists.first { $0.id == id } }, placement: target.placement)
    }

    /// Rows on screen now: top-level lists, and the children of open groups.
    private func visibleListIDs() -> Set<UUID> {
        Set(ListNode.visibleIDs(ListNode.roots(lists), expanded: expandedLists))
    }
    #endif

    private func moveList(_ id: UUID, to target: TaskList?, placement: ListTree.Placement) {
        guard let list = lists.first(where: { $0.id == id }) else { return }
        do {
            try ListTree.move(list, to: target, placement: placement, lists: lists)
            _ = commit {}
        } catch { errorMessage = error.localizedDescription }
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                if selection == .calendar {
                    if isPhone && dynamicTypeSize.isAccessibilitySize {
                        planningPicker.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        if planningView != "list" {
                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                filterMenu.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                calendarDisplayMenu.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            }
                        }
                    } else {
                        HStack {
                            planningPicker
                            if planningView != "list" {
                                if isPhone {
                                    filterMenu.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                    calendarDisplayMenu.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                } else { filterMenu; calendarDisplayMenu }
                            }
                        }
                    }
                    if planningView != "list", filter.isActive {
                        HStack {
                            Text(filterSummary).font(.caption).foregroundStyle(.secondary).lineLimit(isPhone ? 2 : nil)
                            Button(L("清除", "Clear")) { filter = TaskFilter() }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    if planningView != "list" && !searchingCalendar { dateNavigator }
                }
                if searchingCalendar && planningView != "list" {
                    calendarSearchResults
                } else if selection == .calendar && !searchingCalendar && planningView != "list" {
                    ZStack {
                        if planningView == "month" {
                            monthPanel.id(Dates.shiftMonth(Dates.monthStart(selectedDate), by: -monthRevealShift)).transition(pageTransition)
                                #if os(iOS)
                                .modifier(PageSwipe { stepPeriod($0) })
                                #endif
                        } else {
                            weekPanel.id(Dates.calendar.date(byAdding: .day, value: -7 * revealShift, to: Dates.weekCells(selectedDate)[0])!).transition(pageTransition)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                        #if os(macOS)
                        .modifier(PageSwipe { stepPeriod($0) })
                        #endif
                    } else {
                #if os(iOS)
                iosTaskList
                #else
                if selection == .calendar && geometry.size.width >= 680 {
                    HStack(alignment: .top, spacing: 24) {
                        ScrollView { calendarPanel }.frame(width: 282)
                        Divider()
                        ScrollView { taskPanel }.frame(maxWidth: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if selection == .calendar { calendarPanel; Divider() }
                            taskPanel
                        }
                    }
                }
                #endif
                }
            }.padding(.horizontal, isPhone && selection == .calendar && planningView == "week" ? 8 : geometry.size.width > 600 ? 28 : 16)
                .padding(.vertical, isPhone ? 8 : geometry.size.width > 600 ? 28 : 16)
            .background(Color.appBackground)
        }
        .task(id: locateRequest) {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            locatedTask = nil
        }
        #if os(iOS)
        .searchable(text: $search, placement: .toolbar, prompt: selection == .calendar ? L("搜索全部任务", "Search all tasks") : L("搜索当前范围的任务", "Search tasks in this view"))
        .modifier(PhoneSearchToolbar())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        #else
        .searchable(text: $search, prompt: selection == .calendar ? L("搜索全部任务", "Search all tasks") : L("搜索当前范围的任务", "Search tasks in this view"))
        .navigationTitle(L("小记", "Tally"))
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker(L("查看", "View"), selection: $selection) {
                        ForEach(TaskScope.standard, id: \.self) { scope in Label(scope.localizedTitle(language), systemImage: scope.icon).tag(scope) }
                    }
                    Menu(L("我的清单", "My lists")) {
                        ListTreeMenu(nodes: ListNode.roots(lists)) { selection = .list($0) }
                    }
                    Button(L("新建清单", "New list"), systemImage: "plus") { listEditor = ListRequest() }
                    if case .list(let id) = selection, let list = lists.first(where: { $0.id == id }) {
                        Button(L("编辑清单", "Edit list")) { listEditor = ListRequest(list: list) }
                        Button(L("删除清单", "Delete list"), role: .destructive) { deletingList = list }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(title).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 44)
                }.accessibilityLabel(L("查看：", "View: ") + title)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button { showingSettings = true } label: { Label(L("设置", "Settings"), systemImage: "gearshape") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: addTask) { Label(L("新建任务", "New task"), systemImage: "plus") }.keyboardShortcut("n", modifiers: .command)
            }
        }
        .onChange(of: selection) { _, scope in
            search = ""; filter = TaskFilter()
            // Opening the calendar is part of assignment; leaving it cancels assignment.
            if scope != .calendar { assigning = nil }
        }
    }

    private var calendarPanel: some View {
        let active = tasks.filter { $0.deletedAt == nil }
        // The dot counts what is still to do; a day whose tasks are all finished keeps a hollow dot.
        let days = weekOnly ? Dates.weekCells(selectedDate) : Dates.monthCells(selectedDate)
        let byDay = CalendarIndex.byDay(active, days: days)
        let counts = byDay.mapValues { $0.filter { !$0.isDone }.count }
        let planned = Set(byDay.filter { !$0.value.isEmpty }.keys)
        return VStack(alignment: .leading, spacing: 12) {
            dateNavigator
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 8)
                }
                ForEach(days, id: \.self) { date in
                    dayCell(date, count: counts[date] ?? 0, planned: planned.contains(date))
                }
            }
            if !isPhone || !weekOnly {
                let range = Dates.calendar.dateInterval(of: .month, for: selectedDate)!
                let monthTasks = active.filter { $0.overlaps(range) }
                Text(L("本月 \(monthTasks.count) 项 · 已完成 \(monthTasks.filter(\.isDone).count) 项", "This month: \(monthTasks.count) · Completed: \(monthTasks.filter(\.isDone).count)"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            if !isPhone && !overdueTasks.isEmpty { overdueSection(overdueTasks) }
        }.onChange(of: selectedDate) { _, _ in search = "" }
    }

    private func dayCell(_ date: Date, count: Int, planned: Bool) -> some View {
        let selected = Dates.sameDay(date, selectedDate)
        let today = Dates.sameDay(date, currentDay)

        let inMonth = Dates.calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        if !isPhone && !weekOnly && !inMonth { return AnyView(Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true)) }
        return AnyView(Button {
            if let id = assigning { assign(id, to: date) } else { selectedDate = date; wholeMonth = false }
        } label: {
            // Style each piece directly: inside an iOS List row the container's style is not inherited.
            let ink = selected ? Color.selectedInk : inMonth ? Color.primary : Color.secondary
            VStack(spacing: 4) {
                Text("\(Dates.calendar.component(.day, from: date))").font(.body.monospacedDigit()).foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 3) {
                    if count > 0 {
                        Circle().fill(ink).frame(width: 4, height: 4)
                        Text("\(count)").font(.caption2).foregroundStyle(ink)
                    } else {
                        Circle().strokeBorder(ink, lineWidth: 1).frame(width: 4, height: 4).opacity(0.7)
                    }
                }.opacity(count > 0 || planned ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: isPhone ? min(60, max(48, calendarDayHeight)) : 44)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay { if today { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(L("\(Dates.label(date))，\(count)项未完成\(count == 0 && planned ? "，全部已完成" : "")\(today ? "，今天" : "")", "\(Dates.label(date)), \(count) unfinished\(count == 0 && planned ? ", all done" : "")\(today ? ", today" : "")"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(L("实心圆点是未完成的任务，空心代表当天已全部完成；描边代表今天。可拖动任务到这里改期。", "A solid dot counts unfinished tasks, a hollow one means all done; the outline marks Today. Drop a task here to reschedule."))
            #if os(macOS)
            .dayDrop(warn: { id in tasks.first { $0.id == id }?.deadlineConflict(movingTo: date) == true }) { values in
                guard values.count == 1, values[0].hasPrefix("jianshi-task:"), let id = UUID(uuidString: String(values[0].dropFirst(13))),
                      let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
                requestMove(task, to: date, kind: .day)
                return true
            }
            #endif
        )
    }

    private var taskHeader: some View {
        let layout = isPhone && dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: isPhone ? .center : .firstTextBaseline))
        return VStack(alignment: .leading, spacing: 10) {
            layout {
                if selection == .calendar && !searchingCalendar {
                    Menu {
                        Picker(L("查看范围", "View range"), selection: $wholeMonth) {
                            Text(L("所选日期", "Selected day")).tag(false)
                            Text(L("整月安排", "Whole month")).tag(true)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(Dates.label(selectedDate, pattern: wholeMonth ? "M月安排" : "M月d日 EEEE"))
                                .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.down").font(.caption2)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }.font(isPhone ? .subheadline.weight(.semibold) : .title3.weight(.medium)).foregroundStyle(Color.primary).frame(minHeight: 44)
                    }.menuIndicator(.hidden).accessibilityLabel(L("查看范围", "View range"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(searchingCalendar ? L("搜索结果", "Search results") : selection == .calendar ? Dates.label(selectedDate, pattern: wholeMonth ? "M月安排" : "M月d日 EEEE") : title)
                        .font(.title3.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    filterMenu
                    Text(L("\(visibleTasks.count) 项", "\(visibleTasks.count) \(visibleTasks.count == 1 ? "task" : "tasks")")
                         + (hiddenCompletedCount > 0 ? L(" · 已隐藏 \(hiddenCompletedCount) 项已完成", " · \(hiddenCompletedCount) completed hidden") : ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if filter.isActive {
                HStack(spacing: 6) {
                    Text(filterSummary).font(.caption).foregroundStyle(.secondary)
                    Button(L("清除筛选", "Clear")) { filter = TaskFilter() }.font(.caption).buttonStyle(.borderless)
                }
            }
            if searchingCalendar {
                Label(L("正在搜索全部任务（不含最近删除）", "Searching all tasks (except Recently deleted)"), systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selection == .all {
                Toggle(L("隐藏已完成", "Hide completed"), isOn: $hideCompletedInAll)
                    .toggleStyle(.switch).controlSize(.small).font(.callout)
            }
            if selection == .trash {
                HStack {
                    Text(L("删除的任务会保留在这里，可以恢复或彻底删除。", "Deleted tasks stay here until you restore or permanently delete them.")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !visibleTasks.isEmpty {
                        Button(L("清空", "Empty"), role: .destructive) { purgeIDs = Set(tasks.filter { $0.deletedAt != nil }.map(\.id)) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    #if os(iOS)
    private var phoneCalendarRows: some View {
        let active = tasks.filter { $0.deletedAt == nil }
        let days = Dates.monthCells(selectedDate)
        let byDay = CalendarIndex.byDay(active, days: days)
        let selectedWeek = Dates.weekCells(selectedDate)[0]
        let weeks = stride(from: 0, to: days.count, by: 7).map { days[$0] }
        return Group {
            dateNavigator
            HStack(spacing: 0) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.top, 6)
            // Let List insert/remove native rows, so dates and tasks animate together.
            // The selected week keeps its identity when surrounding weeks are revealed.
            ForEach(weekOnly ? weeks.filter { $0 == selectedWeek } : weeks, id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(Dates.weekCells(start), id: \.self) { date in
                        let items = byDay[date] ?? []
                        dayCell(date, count: items.filter { !$0.isDone }.count, planned: !items.isEmpty)
                    }
                }.padding(.vertical, 1)
            }
            if !weekOnly {
                let range = Dates.calendar.dateInterval(of: .month, for: selectedDate)!
                let items = active.filter { $0.overlaps(range) }
                Text(L("本月 \(items.count) 项 · 已完成 \(items.filter(\.isDone).count) 项", "This month: \(items.count) · Completed: \(items.filter(\.isDone).count)"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .onChange(of: selectedDate) { _, _ in search = "" }
    }

    private var iosTaskList: some View {
        List {
            if selection == .calendar && !searchingCalendar {
                if isPhone { phoneCalendarRows }
                else {
                    calendarPanel.listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            if isPhone && selection == .calendar && !searchingCalendar {
                phoneOverdueRows
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            }
            taskHeader.listRowSeparator(.hidden)
                .listRowInsets(isPhone ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0) : EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if isDayTimeline {
                dayTimelineRows
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowSeparator(.hidden)
            } else if isMonthAgenda {
                monthAgendaRows
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowSeparator(.hidden)
            } else {
            if visibleTasks.isEmpty {
                ContentUnavailableView(search.isEmpty ? L("留给你安排", "Room for your plans") : L("没有找到任务", "No tasks found"), systemImage: search.isEmpty ? "sun.max" : "magnifyingglass", description: Text(search.isEmpty ? L("添加一件想做的事，慢慢完成。", "Add something you want to do.") : L("试试其他关键词或查看范围。", "Try another search or view.")))
                    .listRowSeparator(.hidden)
            }
            ForEach(groups, id: \.date) { group in
                Section {
                    ForEach(group.tasks) { task in
                        taskRow(task)
                            .listRowInsets(isPhone ? EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0) : EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if selection != .trash {
                                    Button { toggleCompletion(task) } label: { Label(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete"), systemImage: "checkmark") }.tint(.accentColor)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if selection != .trash {
                                    Button(role: .destructive) { confirmingDelete = task.id } label: { Label(L("删除", "Delete"), systemImage: "trash") }
                                } else {
                                    Button(role: .destructive) { purgeIDs = [task.id] } label: { Label(L("彻底删除", "Delete permanently"), systemImage: "trash") }
                                    Button { _ = commit { task.deletedAt = nil } } label: { Label(L("恢复任务", "Restore task"), systemImage: "arrow.uturn.backward") }.tint(.accentColor)
                                }
                            }
                    }
                } header: {
                    if !isPhone || selection != .calendar || wholeMonth || searchingCalendar {
                        Text(Dates.groupLabel(group.date, today: currentDay))
                    }
                }
            }

            }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 1)
    }
    #endif

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            taskHeader

            if isDayTimeline {
                LazyVStack(alignment: .leading, spacing: 12) { dayTimelineRows }
            } else if isMonthAgenda {
                LazyVStack(alignment: .leading, spacing: 12) { monthAgendaRows }
            } else if visibleTasks.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? L("留给你安排", "Room for your plans") : L("没有找到任务", "No tasks found"), systemImage: search.isEmpty ? "sun.max" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty ? L("添加一件想做的事，慢慢完成。", "Add something you want to do. Take it one step at a time.") : L("试试其他关键词或查看范围。", "Try another search or view."))
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.date) { group in
                        Text(Dates.groupLabel(group.date, today: currentDay))
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(group.tasks) { task in taskRow(task) }
                    }
                }
            }
            }
            }

            /// The row keeps its own hover state (for the delete button), so the pointer sliding over rows during a
            /// scroll only redraws those rows — not the whole window, calendar included, once per row it crosses.
            private func taskRow(_ task: TaskItem) -> some View {
        RowHover { hovered in taskRowBody(task, hovered: hovered) }
        .contextMenu { taskMenu(task) }
        .modifier(TaskDragSource(task: task))
    }

    private func taskRowBody(_ task: TaskItem, hovered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            if selection != .trash {
                Button {
                    toggleCompletion(task)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(task.isDone ? Color.accentColor : .secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("\(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete"))：\(task.title)")
            }
            Button { editor = EditorRequest(task: task) } label: {
                VStack(alignment: .leading, spacing: isPhone ? 4 : 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(task.title).fontWeight(task.priority == 2 && !task.isDone ? .semibold : .regular)
                            .strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary).multilineTextAlignment(.leading)
                        CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
                    }
                    taskMetadata(task)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, isPhone ? 4 : 9).contentShape(Rectangle())
            }.buttonStyle(.plain)
            #if os(macOS)
            // The pointer reveals the actions; the context menu is the keyboard and VoiceOver path.
            if selection != .trash {
                Group {
                    if hovered {
                        Button(role: .destructive) { confirmingDelete = task.id } label: { Image(systemName: "trash").frame(width: 30, height: 30) }
                            .buttonStyle(.borderless).accessibilityLabel(L("删除任务", "Delete task") + ": " + task.title)
                    }
                }.frame(width: 30)
            } else {
                Button { _ = commit { task.deletedAt = nil } } label: { Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34) }
                    .buttonStyle(.borderless).help(L("恢复任务", "Restore task")).accessibilityLabel(L("恢复任务", "Restore task") + ": " + task.title)
                Button(role: .destructive) { purgeIDs = [task.id] } label: { Image(systemName: "xmark.bin").frame(width: 34, height: 34) }
                    .buttonStyle(.borderless).help(L("彻底删除", "Delete permanently")).accessibilityLabel(L("彻底删除", "Delete permanently") + ": " + task.title)
            }
            #endif
          }
          if task.reminderWarning != nil, selection != .trash {
              VStack(alignment: .leading, spacing: 4) {
                  HStack {
                      Button(L("现在提醒", "Remind now")) { remindNow(task) }
                      Button(L("调整时间", "Adjust time")) { editor = EditorRequest(task: task) }
                  }.buttonStyle(.borderless).frame(minHeight: 44)
              }.font(.caption).padding(.leading, 44)
          }
          if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              ExpandableNotes(notes: task.notes).padding(.leading, 44)
          }
          if !task.subtasks.isEmpty {
              RegularTaskSubtasks(task: task, disabled: selection == .trash) { id in
                  _ = commit {
                      var updated = task.subtasks
                      if let index = updated.firstIndex(where: { $0.id == id }) {
                          updated[index].isDone.toggle(); task.subtasks = updated
                      }
                  }
              }.padding(.leading, 44)
          }
        }.padding(.vertical, isPhone ? 4 : 10).padding(.bottom, isPhone ? 2 : 6).overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func taskMetadata(_ task: TaskItem) -> some View {
        TimelineView(.everyMinute) { clock in taskMetadata(task, now: clock.date) }
    }

    private func taskMetadata(_ task: TaskItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            if task.clockDate != nil { Text(task.timeLabel) }
            if let list = task.calendarList {
                ColoredListLabel(name: list.name, id: list.id, colorHex: list.colorHex, emoji: list.emoji).labelStyle(CompactTagLabelStyle())
                    .foregroundStyle(ListColor.color(list.id, hex: list.colorHex))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(ListColor.color(list.id, hex: list.colorHex).opacity(0.12), in: Capsule())
            }
            if task.isDone { Text(L("已完成", "Completed")) }
          }
          if task.repeatRule != "none" { Label(Dates.repeatLabel(task.repeatRule), systemImage: "repeat") }
          if let warning = task.reminderWarning { Label(warning, systemImage: "bell.badge").foregroundStyle(.orange) }
          if let reminder = task.reminderAt, !task.isDone, task.reminderWarning == nil { Label(Dates.label(reminder, pattern: "M月d日 HH:mm"), systemImage: "bell") }
          if let due = task.dueAt {
              if let countdown = task.deadlineCountdown(now: now) {
                  Label(countdown.text(due: due, timed: task.dueHasTime), systemImage: "hourglass").foregroundStyle(countdown.color)
              } else {
                  let when = Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
                  Text(L("截止 \(when)", "Due \(when)"))
              }
          }
        }.font(.caption).foregroundStyle(.secondary)
    }

    /// The task being dragged. There is no callback when a drag is cancelled, so an old record
    /// (over a minute) is ignored rather than colouring a later, unrelated drop.
    private var draggingTask: TaskItem? {
        guard let id = dragFeedback.draggedID else { return nil }
        return tasks.first { $0.id == id }
    }

    private func overdueSection(_ items: [TaskItem]) -> some View {
        DisclosureGroup(isExpanded: isPhone ? $phoneOverdueExpanded : $overdueExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAllEarlier ? items : Array(items.prefix(3))) { task in overdueRow(task) }
                if items.count > 3 {
                    Button(showAllEarlier ? L("收起", "Show less") : L("查看其余 \(items.count - 3) 项", "Show \(items.count - 3) more")) { showAllEarlier.toggle() }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                }
            }.padding(.top, 4)
        } label: {
            Label(L("此前未完成 · \(items.count) 项", "Earlier unfinished · \(items.count)"), systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    #if os(iOS)
    /// Separate native rows animate their insertion without resizing one large list cell.
    @ViewBuilder private var phoneOverdueRows: some View {
        let items = overdueTasks
        if !items.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { phoneOverdueExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(L("此前未完成 · \(items.count) 项", "Earlier unfinished · \(items.count)"), systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(phoneOverdueExpanded ? 90 : 0))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }.foregroundStyle(Color.accentColor).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(phoneOverdueExpanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
            if phoneOverdueExpanded {
                ForEach(showAllEarlier ? items : Array(items.prefix(3))) { task in overdueRow(task) }
                if items.count > 3 {
                    Button(showAllEarlier ? L("收起", "Show less") : L("查看其余 \(items.count - 3) 项", "Show \(items.count - 3) more")) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { showAllEarlier.toggle() }
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
        }
    }
    #endif

    private func overdueRow(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { toggleCompletion(task) } label: {
                Image(systemName: "circle").foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(L("完成", "Complete") + "：" + task.title)
            Button { editor = EditorRequest(task: task) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                    TimelineView(.everyMinute) { clock in overdueDetail(task, now: clock.date).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(L("移到今天", "Move to today")) { requestMove(task, to: currentDay, kind: .day) }
                .buttonStyle(.borderless).font(.caption).padding(.top, 9)
            }
            .modifier(TaskDragSource(task: task))
    }

    /// "原定 9月10日 · 已逾期 7 天", or with a future deadline "原定 9月10日 · 截止 9月30日 · 还剩 13 天".
    private func overdueDetail(_ task: TaskItem, now: Date) -> Text {
        var parts: [String] = []
        if let scheduled = task.scheduledAt { parts.append(L("原定 ", "Planned ") + Dates.label(scheduled, pattern: "M月d日")) }
        if let due = task.dueAt, let countdown = task.deadlineCountdown(now: now) {
            parts.append(countdown.text(due: due, timed: task.dueHasTime))
            return Text(parts.joined(separator: " · ")).foregroundStyle(countdown.color)
        }
        if let day = task.calendarDate {
            let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: day), to: Dates.calendar.startOfDay(for: currentDay)).day ?? 0
            parts.append(L("逾期 \(days) 天", "\(days) \(days == 1 ? "day" : "days") overdue"))
        }
        return Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
    }

    // MARK: Day timeline

    private var isDayTimeline: Bool {
        selection == .calendar && !wholeMonth && !searchingCalendar
    }

    private var isMonthAgenda: Bool {
        selection == .calendar && wholeMonth && !searchingCalendar
    }

    @ViewBuilder private var monthAgendaRows: some View {
        if visibleTasks.isEmpty {
            ContentUnavailableView(L("本月暂无安排", "No plans this month"), systemImage: "calendar")
        }
        ForEach(groups, id: \.date) { group in
            Section {
                ForEach(group.tasks) { task in dayTimelineTask(task, timed: false, showTime: true) }
            } header: {
                HStack {
                    Text(Dates.groupLabel(group.date, today: currentDay))
                    Spacer()
                    Text(L("\(group.tasks.count) 项", "\(group.tasks.count) tasks"))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }

    /// Individual rows are retained by iOS List and Mac LazyVStack. Detail expansion belongs
    /// to DayTimelineCard, so opening notes does not recompute the calendar or schedule.
    private var dayTimelineRows: some View {
        let items = visibleTasks
        let active = items.filter { !$0.isDone }
        let pending = active.filter { $0.clockDate == nil }
        let completed = items.filter(\.isDone)
        let schedule = DaySchedule(active, day: selectedDate, occupying: tasks)
        let timed = schedule.clusters.flatMap { $0 }
        let gaps = Dictionary(uniqueKeysWithValues: schedule.clusters.enumerated().compactMap { index, cluster -> (UUID, Int)? in
            guard let first = cluster.first, let gap = schedule.gaps[index] else { return nil }
            return (first.id, gap)
        })
        let overlaps = Dictionary(uniqueKeysWithValues: schedule.clusters.compactMap { cluster -> (UUID, String)? in
            guard cluster.count > 1, let first = cluster.first else { return nil }
            return (first.id, overlapLabel(cluster, day: selectedDate))
        })
        return Group {
            Toggle(L("显示空闲时段", "Show free time"), isOn: $showDayFreeTime)
                .toggleStyle(.switch).controlSize(.small).font(.caption).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, 4)
            ForEach(timed) { task in
                dayTimelineTask(task, timed: true,
                                gap: showDayFreeTime ? gaps[task.id] : nil, overlap: overlaps[task.id])
            }
            if !pending.isEmpty {
                Text(L("时间待定 · \(pending.count)", "Time to be set · \(pending.count)"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 10)
                ForEach(pending) { task in dayTimelineTask(task, timed: false) }
            }
            if active.isEmpty {
                ContentUnavailableView {
                    Label(items.isEmpty ? L("留给你安排", "Room for your plans") : L("当天任务已完成", "All done for this day"),
                          systemImage: items.isEmpty ? "sun.max" : "checkmark.circle")
                } description: {
                    Text(items.isEmpty ? L("添加一件想做的事，慢慢完成。", "Add something you want to do.") : L("已完成的任务收在下方，随时可以查看。", "You can review completed tasks below."))
                }
            }
            if !completed.isEmpty {
                DisclosureGroup(isExpanded: $dayCompletedExpanded) {
                    ForEach(completed) { task in dayTimelineTask(task, timed: task.clockDate != nil) }
                } label: {
                    Label(L("已完成 · \(completed.count)", "Completed · \(completed.count)"), systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
                }.padding(.top, 6)
            }
            if !isPhone {
                Button(action: addTask) {
                    Label(L("添加任务", "Add task"), systemImage: "plus").frame(minHeight: 44)
                }.buttonStyle(.borderless)
            }
        }
    }

    private func dayTimelineTask(_ task: TaskItem, timed: Bool, showTime: Bool = false,
                                 gap: Int? = nil, overlap: String? = nil) -> some View {
        let accessiblePhone = isPhone && dynamicTypeSize.isAccessibilitySize
        let layout = accessiblePhone
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        // Exactly one List row per task, even when free-time/overlap labels are shown.
        // Variable row counts make List eagerly construct offscreen task content.
        return VStack(alignment: .leading, spacing: 10) {
            if let gap { freeRow(gap) }
            if let overlap {
                Label(overlap, systemImage: "arrow.triangle.merge")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, min(dayTimeWidth, 78) + 16)
            }
            layout {
                if timed, let clock = task.clockDate {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Dates.sameDay(clock, selectedDate) ? Dates.label(clock, pattern: "HH:mm") : "00:00")
                            .font(.callout.weight(.medium))
                        if let end = task.endAt {
                            Text(Dates.sameDay(end, selectedDate) ? Dates.label(end, pattern: "HH:mm") : "24:00")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(task.scheduledAt == nil ? L("截止", "Due") : L("开始", "Start"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !Dates.sameDay(clock, selectedDate) {
                            Text(L("续前日", "Continued")).font(.caption2).foregroundStyle(.secondary)
                        } else if let end = task.endAt, !Dates.sameDay(end, selectedDate), Dates.calendar.startOfDay(for: end) < end {
                            Text(L("跨日", "Overnight")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: accessiblePhone ? nil : min(dayTimeWidth, 78), alignment: .trailing)
                        .padding(.top, accessiblePhone ? 0 : 14)
                        .accessibilityElement(children: .ignore).accessibilityLabel(task.timeLabel)
                }
                DayTimelineCard(task: task, compact: isPhone, showTime: showTime,
                                onComplete: { toggleCompletion(task) },
                                onEdit: { editor = EditorRequest(task: task) },
                                onDelete: { confirmingDelete = task.id },
                                onRemindNow: { remindNow(task) },
                                onToggleSubtask: { id in
                                    _ = commit {
                                        var updated = task.subtasks
                                        if let index = updated.firstIndex(where: { $0.id == id }) {
                                            updated[index].isDone.toggle(); task.subtasks = updated
                                        }
                                    }
                                })
            }
        }
        .contextMenu { taskMenu(task) }
        .modifier(TaskDragSource(task: task))
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { toggleCompletion(task) } label: {
                Label(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete"), systemImage: "checkmark")
            }.tint(.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { confirmingDelete = task.id } label: { Label(L("删除", "Delete"), systemImage: "trash") }
        }
        #endif
    }

    private func overlapLabel(_ items: [TaskItem], day: Date) -> String {
        let title = L("\(items.count) 项时间重叠", "\(items.count) overlap")
        guard let span = DaySchedule.span(items, day: day) else { return title }
        let end = span.end == 1440 ? "24:00" : clockLabel(span.end)
        let range = clockLabel(span.start) + "–" + end
        let duration = Dates.durationLabel(minutes: span.end - span.start)
        return title + " · " + range + L(" · 共占用 \(duration)", " · \(duration) total")
    }

    /// Align free-time summaries with the cards rather than the time rail.
    private func freeRow(_ minutes: Int) -> some View {
        Text(L("空闲 ", "Free ") + Dates.durationLabel(minutes: minutes)).font(.caption).foregroundStyle(.tertiary)
            .padding(.leading, min(dayTimeWidth, 78) + 16).padding(.vertical, 4)
    }

    private var pendingMoveTitle: String {
        guard let plan = pendingMove?.proposal, let due = plan.before.dueAt else { return "" }
        var target = Dates.label(plan.start, pattern: plan.timed ? "M月d日 HH:mm" : "M月d日")
        if plan.timed, let end = plan.end {
            target += " → " + Dates.label(end, pattern: Dates.sameDay(plan.start, end) ? "HH:mm" : "M月d日 HH:mm")
        }
        let old = Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        return L("安排改为 \(target)\n当前截止：\(old)", "Schedule for \(target)\nCurrent deadline: \(old)")
            + (plan.canKeepDeadline ? "" : L("\n新安排晚于截止，需要一起调整。", "\nThe new schedule is after the deadline; move the deadline too."))
    }

    private func refreshDay() {
        let now = Date()
        selectedDate = Dates.selectionAfterDayChange(selectedDate, previousToday: currentDay, now: now)
        currentDay = now
        ReminderScheduler.shared.refresh(context)
    }

    private func toggleCompletion(_ task: TaskItem) {
        _ = commit { task.toggleCompletion(in: context) }
    }

    private func remindNow(_ task: TaskItem) {
        Task { @MainActor in
            do {
                guard try await ReminderScheduler.shared.authorize() else {
                    errorMessage = L("请在系统设置中允许通知后再试。", "Allow notifications in system settings, then try again."); return
                }
                guard !task.isDone, task.deletedAt == nil else { return }
                if commit({ task.reminderAt = Date().addingTimeInterval(5); task.reminderKind = ReminderPreset.custom.rawValue; task.reminderNeedsAttention = false }) {
                    notify(L("将在约 5 秒后提醒", "Reminder scheduled in about 5 seconds"))
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var confirmingDeleteTitle: String {
        confirmingDelete.flatMap { id in tasks.first { $0.id == id }?.title } ?? ""
    }

    private func deleteTask(_ task: TaskItem) {
        guard task.deletedAt == nil else { return }
        if commit({ task.deletedAt = Date() }) { undoDeletedIDs.append(task.id) }
    }

    private func undoDeletion() {
        let ids = Set(undoDeletedIDs)
        if commit({ for task in tasks where ids.contains(task.id) { task.deletedAt = nil } }) { undoDeletedIDs = [] }
    }

    private func addTask() {
        let listID: UUID? = { if case .list(let id) = selection { return id }; return nil }()
        editor = EditorRequest(date: selection == .calendar ? selectedDate : nil, listID: listID)
    }

    /// One date navigator for all three calendar views: the step just follows the view.
    /// It folds onto two rows beside a narrow month grid.
    private var dateNavigator: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                navigatorSteps
                Spacer(minLength: 10)
                #if os(macOS)
                if planningView != "list" { PlanHint(month: planningView == "month").layoutPriority(-1); Spacer(minLength: 10) }
                #endif
                navigatorOptions
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) { navigatorSteps; Spacer(minLength: 0) }
                HStack(spacing: 2) { navigatorOptions; Spacer(minLength: 0) }
            }
        }.buttonStyle(.borderless)
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
    }

    @ViewBuilder private var navigatorSteps: some View {
        Button { stepPeriod(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel(previousLabel)
        if planningView == "list" { DateChoiceButton(label: navigatorLabel, date: $selectedDate) }
        else { PeriodChoiceButton(label: navigatorLabel, date: $selectedDate, week: planningView == "week") }
        Button { stepPeriod(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel(nextLabel)
    }

    @ViewBuilder private var navigatorOptions: some View {
        Button(L("今天", "Today")) { goToToday() }.frame(minHeight: 44)

        if planningView == "week" {
            Menu {
                ForEach([25, 50, 75, 100, 125, 150], id: \.self) { percent in
                    Button { weekZoom = Double(percent) / 100 } label: {
                        if Int((zoomLevel * 100).rounded()) == percent {
                            Label("\(percent)%", systemImage: "checkmark")
                        } else { Text("\(percent)%") }
                    }
                }
            } label: { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44) }
                .fixedSize()
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .help(L("时间表缩放", "Timeline zoom"))
                .accessibilityLabel(L("时间表缩放", "Timeline zoom"))
                .disabled(weekDrag.isDragging)
        }
        if planningView == "list" {
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { weekOnly.toggle() } } label: {
                Image(systemName: "chevron.down.circle").rotationEffect(.degrees(weekOnly ? 0 : 180)).frame(width: 44, height: 44)
            }.help(weekOnly ? L("展开整月", "Show the whole month") : L("收起为一周", "Show one week"))
                .accessibilityLabel(weekOnly ? L("展开整月", "Show the whole month") : L("收起为一周", "Show one week"))
        }
    }

    private var navigatorLabel: String {
        guard planningView == "week" else { return Dates.label(planningView == "month" ? previewMonthDate : selectedDate, pattern: "yyyy年M月") }
        let days = Dates.weekCells(previewWeekDate)
        if isPhone { return Dates.label(days[0], pattern: "M/d") + " – " + Dates.label(days[6], pattern: "M/d") }
        let sameMonth = Dates.calendar.isDate(days[0], equalTo: days[6], toGranularity: .month)
        return Dates.label(days[0], pattern: "M月d日") + " – " + Dates.label(days[6], pattern: sameMonth ? "d日" : "M月d日")
    }

    private var periodName: (previous: String, next: String) {
        switch planningView {
        case "week": (L("上一周", "Previous week"), L("下一周", "Next week"))
        case "month": (L("上个月", "Previous month"), L("下个月", "Next month"))
        default: weekOnly ? (L("上一周", "Previous week"), L("下一周", "Next week")) : (L("上个月", "Previous month"), L("下个月", "Next month"))
        }
    }
    private var previousLabel: String { periodName.previous }
    private var nextLabel: String { periodName.next }

    private func stepPeriod(_ amount: Int) {
        slideForward = amount > 0
        weekDrag.releaseHeldScroll()
        presentation.close()
        let next: Date
        switch planningView {
        case "week": next = Dates.calendar.date(byAdding: .day, value: amount * 7, to: selectedDate)!
        case "month": next = Dates.shiftMonth(selectedDate, by: amount)
        default: next = weekOnly ? Dates.calendar.date(byAdding: .day, value: amount * 7, to: selectedDate)! : Dates.shiftMonth(selectedDate, by: amount)
        }
        withAnimation(reduceMotion || planningView == "list" ? nil : .easeInOut(duration: 0.28)) { selectedDate = next }
    }



    private func goToToday() {
        let now = Date()
        weekDrag.releaseHeldScroll()
        presentation.close(); locatedTask = nil
        slideForward = now > selectedDate
        withAnimation(reduceMotion || planningView == "list" ? nil : .easeInOut(duration: 0.28)) { selectedDate = now }
        wholeMonth = false; search = ""; locateRequest = UUID()
    }

    /// Tap a task, then tap a day or a time slot. This is how a phone reschedules without dragging.
    private func assign(_ id: UUID, to day: Date) {
        assigning = nil
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        requestMove(task, to: day, kind: .day)
    }

    private func startAssigning(_ task: TaskItem) {
        assigning = task.id
        if selection != .calendar { selection = .calendar }
    }

    @ViewBuilder private func taskMenu(_ task: TaskItem) -> some View {
        if selection != .trash {
            Button(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete")) { toggleCompletion(task) }
            Button(L("编辑…", "Edit…")) { editor = EditorRequest(task: task) }
            Button(L("改期到…", "Reschedule…")) { startAssigning(task) }
            taskCopyMenu(task)
            Button(L("删除…", "Delete…"), role: .destructive) { confirmingDelete = task.id }
        } else {
            Button(L("恢复任务", "Restore task")) { _ = commit { task.deletedAt = nil } }
            Button(L("彻底删除", "Delete permanently"), role: .destructive) { purgeIDs = [task.id] }
        }
    }

    @ViewBuilder private func taskCopyMenu(_ task: TaskItem) -> some View {
        if !(selection == .calendar && planningView == "month"), task.previewSourceID == nil, task.deletedAt == nil {
            Button { copyTask(task) } label: { Label(L("复制", "Copy"), systemImage: "doc.on.doc") }
            if TaskBackup.TaskRecord(task).nextCopyDate != nil {
                Button { duplicateNext(task) } label: {
                    Label(task.clockDate == nil ? L("复制到下一天", "Duplicate to next day") : L("复制到下一时间段", "Duplicate to next interval"), systemImage: "plus.square.on.square")
                }
            }
        }
    }

    private func copyTask(_ task: TaskItem) {
        guard task.previewSourceID == nil, task.deletedAt == nil else { return }
        #if os(macOS)
        copiedTask = TaskBackup.TaskRecord(task); assigning = nil; presentation.taskKey = nil
        notify(L("已复制，在周历空白处右键粘贴", "Copied. Right-click an empty week-calendar slot to paste."))
        #else
        copyRequest = TaskCopyRequest(record: TaskBackup.TaskRecord(task)); assigning = nil; presentation.taskKey = nil
        #endif
    }

    private func duplicateNext(_ task: TaskItem) {
        let record = TaskBackup.TaskRecord(task)
        guard let next = record.nextCopyDate, task.previewSourceID == nil, task.deletedAt == nil else { return }
        pasteTask(record, at: next, timed: task.clockDate != nil)
    }

    @discardableResult private func pasteTask(_ record: TaskBackup.TaskRecord, at moment: Date, timed: Bool = true) -> Bool {
        let list = record.listID.flatMap { id in lists.first { $0.id == id } }
        var duplicate: TaskItem?
        guard commit({
            let task = record.duplicate(at: moment, timed: timed, list: list)
            context.insert(task); duplicate = task
        }), let duplicate else { return false }
        presentation.taskKey = nil; selectedDate = moment
        locatedTask = duplicate.id; locateRequest = UUID()
        notify(L("已复制到 \(Dates.label(moment, pattern: timed ? "M月d日 HH:mm" : "M月d日"))", "Copied to \(Dates.label(moment, pattern: timed ? "M月d日 HH:mm" : "M月d日"))"))
        return true
    }

    private func saveWeekTitle(_ title: String, week: String, original: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 80 else { errorMessage = L("周标题最多 80 个字符。", "Week titles can contain up to 80 characters."); return false }
        let row = weekTitles.first { $0.week == week }
        guard (row?.title ?? "") == original || row?.title == value else {
            errorMessage = L("这周的标题已在另一处更新，请重新打开该周后编辑。你的输入：\(value)", "This week's title changed elsewhere. Reopen the week before editing. Your draft: \(value)")
            return false
        }
        return commit {
            if value.isEmpty { if let row { context.delete(row) } }
            else if let row { row.title = value }
            else { context.insert(CalendarWeekTitle(week: week, title: value)) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(L("清单", "List"), selection: $filter.list) {
                Text(L("全部清单", "All lists")).tag(TaskFilter.ListChoice.any)
                Text(L("未分类", "No list")).tag(TaskFilter.ListChoice.unfiled)
                ForEach(lists) { Text(ListTree.path($0, lists: lists)).tag(TaskFilter.ListChoice.list($0.id)) }
            }
            Picker(L("优先级", "Priority"), selection: $filter.priority) {
                Text(L("任何优先级", "Any priority")).tag(-1)
                Text(L("高", "High")).tag(2)
                Text(L("中", "Medium")).tag(1)
                Text(L("普通", "Normal")).tag(0)
            }
            Picker(L("时间", "Time"), selection: $filter.span) {
                ForEach(TaskFilter.Span.allCases) { Text($0.title).tag($0) }
            }
            if filter.isActive { Button(L("清除筛选", "Clear filters")) { filter = TaskFilter() } }
        } label: {
            Label(filter.isActive ? L("筛选 \(filter.count)", "Filters \(filter.count)") : L("筛选", "Filter"),
                  systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.caption)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
        }.menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("筛选任务", "Filter tasks"))
    }

    private var filterSummary: String {
        var parts: [String] = []
        switch filter.list {
        case .any: break
        case .unfiled: parts.append(L("未分类", "No list"))
        case .list(let id): parts.append(lists.first { $0.id == id }.map { ListTree.path($0, lists: lists) } ?? L("已删除的清单", "Deleted list"))
        }
        if filter.priority >= 0 { parts.append([L("普通", "Normal"), L("中", "Medium"), L("高", "High")][filter.priority]) }
        if filter.span != .any { parts.append(filter.span.title) }
        return L("只看：", "Showing: ") + parts.joined(separator: " · ")
    }

    private func commit(_ change: () -> Void) -> Bool {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return false }
        undoSchedule = nil; undoListMove = nil; deadlineMove = nil
        change()
        do { try Store.save(context); ReminderScheduler.shared.refresh(context); return true }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil; return false }
    }

    /// Saves a schedule change and offers to undo it. Dropping a task where it already was is not a change:
    /// no message and no undo.
    private func commitSchedule(_ task: TaskItem, before: TaskSchedule? = nil, _ change: () -> Void) -> Bool {
        let snapshot = before ?? TaskSchedule(task)
        guard commit(change) else { return false }
        guard TaskSchedule(task) != snapshot else { return false }
        history.record(task, before: .schedule(snapshot), after: .schedule(TaskSchedule(task)), name: L("时间调整", "Schedule change"), coalesce: before != nil)
        undoSchedule = (task.id, snapshot, TaskSchedule(task))
        moveFeedbackID = UUID()
        return true
    }

    /// A message that is not about a schedule change just made, so it never shows that change's undo button.
    private func notify(_ message: String) {
        undoSchedule = nil; undoListMove = nil; deadlineMove = nil
        moveFeedbackID = UUID()
        movedMessage = message
    }

    private func moveTask(_ values: [String], toList id: UUID) -> Bool {
        guard let task = droppedTask(values), let destination = lists.first(where: { $0.id == id }),
              task.list?.id != id else { return false }
        let before = task.list?.id
        guard commit({ task.changeList(to: destination) }) else { return false }
        history.record(task, before: .list(before), after: .list(id), name: L("分类调整", "List change"))
        undoListMove = (task.id, before, id)
        moveFeedbackID = UUID()
        movedMessage = L("已移到 ", "Moved to ") + ListTree.path(destination, lists: lists)
        return true
    }

    private func restoreListMove() {
        guard let undo = undoListMove,
              let task = tasks.first(where: { $0.id == undo.id && $0.deletedAt == nil }), task.list?.id == undo.after else {
            notify(L("任务已再次修改，请在编辑中调整", "This task changed again; adjust it in the editor")); return
        }
        let original = lists.first { $0.id == undo.before }
        guard undo.before == nil || original != nil else {
            notify(L("原清单已删除，请在编辑中选择清单", "The original list was deleted; choose a list in the editor")); return
        }
        history.undo()
    }

    private func shiftMovedDeadline() {
        guard let plan = deadlineMove, let undo = undoSchedule,
              plan.taskID == undo.id, plan.before == undo.before,
              let task = tasks.first(where: { $0.id == undo.id }),
              let due = plan.deferredDeadline(for: task, after: undo.after) else {
            notify(L("任务已再次修改，请在编辑中调整截止日期", "This task changed again; adjust its deadline in the editor")); return
        }
        // One Undo restores both the original arrangement and its original deadline.
        if commitSchedule(task, before: undo.before, { task.dueAt = due }) {
            movedMessage = L("截止已移到 ", "Deadline moved to ") + Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        }
    }

    private func restoreSchedule() {
        guard let undo = undoSchedule, let task = tasks.first(where: { $0.id == undo.id && $0.deletedAt == nil }), TaskSchedule(task) == undo.after else {
            notify(L("任务已再次修改，请在编辑中调整", "This task changed again; adjust it in the editor")); return
        }
        history.undo()
    }
}

extension Color {
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static let selectedInk = Color("SelectedInk")
}


/// Hover state kept inside one row.
private struct RowHover<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        content(hovering).onHover { inside in if inside != hovering { hovering = inside } }
    }
}

private struct CalendarWeekTitleField: View {
    @AppStorage("appLanguage") private var language = "system"
    let value: String
    let compact: Bool
    let save: (String, String) -> Bool
    @State private var draft: String
    @State private var original: String
    @State private var syncPaused = false
    @FocusState private var focused: Bool

    init(value: String, compact: Bool = false, save: @escaping (String, String) -> Bool) {
        self.value = value; self.compact = compact; self.save = save
        _draft = State(initialValue: value); _original = State(initialValue: value)
    }
    private func commit() {
        guard draft != original else { return }
        if save(draft, original) { draft = draft.trimmingCharacters(in: .whitespacesAndNewlines); original = draft }
    }
    var body: some View {
        TextField(L("周标题", "Week title"), text: $draft)
            .textFieldStyle(.plain).font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold)).focused($focused)
            .multilineTextAlignment(.center)
            .accessibilityLabel(L("本周标题", "Title for this week"))
            .onSubmit { commit(); focused = false }
            .padding(.horizontal, 48).frame(minHeight: 44)
            .background(focused ? Color.secondary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .trailing) {
                if draft != original {
                    Button { commit(); focused = false } label: { Image(systemName: "checkmark").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel(L("保存周标题", "Save week title"))
                }
            }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
                if focused != syncPaused { syncPaused = focused; CloudSync.shared.editing(focused) }
            }
            .onChange(of: value) { _, value in if !focused && draft == original { draft = value; original = value } }
            .onDisappear { commit(); if syncPaused { syncPaused = false; CloudSync.shared.editing(false) } }
    }
}

/// Expanding one row must not invalidate the root task query, groups or calendar.
private struct RegularTaskSubtasks: View {
    let task: TaskItem
    let disabled: Bool
    let toggle: (UUID) -> Void
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { expanded = value }
        })) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(task.subtasks) { subtask in
                    Button { toggle(subtask.id) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                            Text(subtask.title).strikethrough(subtask.isDone).multilineTextAlignment(.leading)
                                .foregroundStyle(subtask.isDone ? .secondary : .primary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(disabled)
                        .accessibilityLabel("\(subtask.isDone ? L("取消完成子任务", "Mark subtask incomplete") : L("完成子任务", "Complete subtask"))：\(subtask.title)")
                }
            }.padding(.top, 4)
        } label: {
            Text(L("子任务 \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)", "Subtasks \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ExpandableNotes: View {
    let notes: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shortHeight: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notes).font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack(alignment: .topLeading) {
                        measure(lines: nil, height: $fullHeight)
                        measure(lines: 3, height: $shortHeight)
                    }.hidden().accessibilityHidden(true)
                }
            if fullHeight > shortHeight + 1 {
                Button(expanded ? L("收起备注", "Collapse notes") : L("展开备注", "Expand notes")) { expanded.toggle() }
                    .font(.caption).buttonStyle(.borderless)
            }
        }.onChange(of: notes) { _, _ in expanded = false }
    }
    private func measure(lines: Int?, height: Binding<CGFloat>) -> some View {
        Text(notes).font(.callout).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { height.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, value in height.wrappedValue = value }
            })
    }
}

private struct CompactTagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

private extension ContentView {
    var planningPicker: some View {
        Picker(L("日历视图", "Calendar view"), selection: $planningView) {
            Text(L("日", "Day")).tag("list")
            Text(L("周", "Week")).tag("week")
            Text(L("月", "Month")).tag("month")
        }.pickerStyle(.segmented)
            .onChange(of: planningView) { _, _ in wholeMonth = false; presentation.close() }
    }
    var planningTasks: [TaskItem] {
        let cells = planningView == "month" ? Dates.monthCells(previewMonthDate) : Dates.weekCells(previewWeekDate)
        let range = DateInterval(start: cells[0], end: Dates.calendar.date(byAdding: .day, value: 1, to: cells.last!)!)
        let previews = showRepeatPreviews ? repeatPreview.items(tasks, in: range) : []
        return (tasks + previews).filter {
            $0.deletedAt == nil && (showPlanningCompleted || !$0.isDone) && filter.matches($0, lists: lists, today: currentDay)
        }
    }
    var calendarDisplayMenu: some View {
        Menu {
            Toggle(L("显示已完成", "Show completed"), isOn: $showPlanningCompleted)
            Toggle(L("预览重复安排", "Preview repeats"), isOn: $showRepeatPreviews)
        } label: {
            Label(L("显示", "Display"), systemImage: "slider.horizontal.3").font(.caption).frame(minHeight: 44)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
        }
            .menuIndicator(.hidden).fixedSize()
    }
    func planColor(_ task: TaskItem) -> Color {
        ListColor.color(task.calendarList?.id, hex: task.calendarList?.colorHex)
    }
    var zoomLevel: Double { min(1.5, max(0.25, pinchZoom ?? weekZoom)) }
    var planScale: Double { PlanBlock.displayScale * zoomLevel }
    var planGutter: CGFloat { isPhone ? 34 : 44 }
    // Week navigation uses the page margin, leaving all seven day columns the same width.
    var planTrailing: CGFloat { 0 }



    var pageTransition: AnyTransition { .push(from: slideForward ? .trailing : .leading) }

    func minuteOfDay(_ date: Date) -> Int {
        Int(Dates.clockMinute(date))
    }

    func clockLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    var assigningTask: TaskItem? { assigning.flatMap { id in tasks.first { $0.id == id && $0.deletedAt == nil } } }

    /// Counts the full day, or the remaining minutes today; never assumes sleeping hours.
    func freeTimeLine(_ blocks: [PlanBlock]) -> some View {
        TimelineView(.everyMinute) { clock in freeTimeLine(blocks, now: clock.date) }
    }

    func freeTimeLine(_ blocks: [PlanBlock], now: Date) -> some View {
        let planned = blocks.filter { $0.task.duration != nil }
        let day = Dates.label(selectedDate, pattern: "M月d日")
        var text: String
        if let span = PlanBlock.countedSpan(day: selectedDate, now: now) {
            if span.start >= span.end {
                text = L("\(day) 今天已没有可安排的时段", "\(day): nothing left to plan today")
            } else {
                let result = PlanBlock.freeTime(planned, from: span.start, to: span.end)
                let range = clockLabel(span.start) + "–" + clockLabel(span.end)
                text = L("\(day) \(range) 未安排 \(Dates.durationLabel(minutes: result.free))", "\(day): \(Dates.durationLabel(minutes: result.free)) unplanned, \(range)")
                #if os(macOS)
                if let longest = result.longest, longest.end - longest.start >= 30, result.free != span.end - span.start {
                    text += L(" · 最长 \(clockLabel(longest.start))–\(clockLabel(longest.end))", " · longest \(clockLabel(longest.start))–\(clockLabel(longest.end))")
                }
                #endif
            }
        } else {
            let total = 1440 - PlanBlock.freeTime(planned, from: 0, to: 1440).free
            text = total > 0 ? L("\(day) 已安排 \(Dates.durationLabel(minutes: total))", "\(day): \(Dates.durationLabel(minutes: total)) planned")
                             : L("\(day) 已过去", "\(day) has passed")
        }
        if planned.contains(where: { $0.task.previewSourceID != nil }) { text += L(" · 含重复预览", " · includes repeat previews") }
        return Label(text, systemImage: "hourglass.bottomhalf.filled").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Week

    /// The month on screen: while a task drag rests beside the month, the one it has turned to.
    private var previewMonthDate: Date { Dates.shiftMonth(selectedDate, by: weekDrag.weekOffset) }

    private var previewWeekDate: Date {
        Dates.calendar.date(byAdding: .day, value: weekDrag.weekOffset * 7, to: selectedDate)!
    }

    var weekPanel: some View {
        let days = Dates.weekCells(previewWeekDate)
        let items = planningTasks
        let indexed = CalendarIndex.byDay(items, days: days)
        let perDay = days.map { PlanBlock.layout(indexed[$0] ?? [], day: $0) }
        let todayIndex = days.firstIndex { Dates.sameDay($0, currentDay) }
        let layout = TimelineLayout.make(blocks: perDay.flatMap { $0 }, fullDay: true, density: planScale,
                                         nowMinute: todayIndex == nil ? nil : minuteOfDay(Date()))
        let selectedIndex = days.firstIndex { Dates.sameDay($0, selectedDate) } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            if !isPhone || !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    freeTimeLine(perDay[selectedIndex])
                    Spacer(minLength: 0)
                    #if os(macOS)
                    completedSwitch
                    #endif
                }
            }
            weekGrid(days, perDay: perDay, layout: layout, todayIndex: todayIndex, items: indexed)
        }.weekDragPanel(weekDrag)
    }

    func weekGrid(_ days: [Date], perDay: [[PlanBlock]], layout: TimelineLayout, todayIndex: Int?, items: [Date: [TaskItem]]) -> some View {
        let key = CalendarWeekTitle.key(for: days[0])
        let title = weekTitles.first { $0.week == key }?.title ?? ""
        return VStack(spacing: 0) {
            CalendarWeekTitleField(value: title, compact: isPhone) { draft, original in saveWeekTitle(draft, week: key, original: original) }
                .id(key).padding(.bottom, isPhone ? 0 : 8)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                .disabled(weekDrag.isDragging)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: planGutter, height: 1)
                    ForEach(days, id: \.self) { weekHeader($0) }
                    Color.clear.frame(width: planTrailing, height: 1)
                }.modifier(WeekPageSlide())
                HStack(alignment: .top, spacing: 0) {
                    Text(L("全天", "All-day")).font(.caption2).foregroundStyle(.secondary).frame(width: planGutter).padding(.top, 3)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in allDayCell(day, index: index, items: items[day] ?? []) }
                    Color.clear.frame(width: planTrailing, height: 1)
                }.padding(.bottom, 4)
                    .modifier(WeekPageSlide())
                    .reportWeekFrame { weekDrag.allDay = $0 }
                Rectangle().fill(.separator).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geometry in
                            weekCanvas(days, perDay: perDay, layout: layout, todayIndex: todayIndex, width: geometry.size.width)
                        }.frame(height: CGFloat(layout.height))
                    }
                    .reportWeekFrame { weekDrag.viewport = $0 }
                    // Two fingers on the trackpad zoom the hours; the time under the fingers stays put.
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { value in
                            guard !weekDrag.isDragging else { return }
                            if pinchZoom == nil { pinchBase = zoomLevel; pinchAnchorY = value.startLocation.y }
                            pinchZoom = min(1.5, max(0.25, pinchBase * value.magnification))
                        }
                        .onEnded { _ in
                            guard let zoom = pinchZoom else { return }
                            weekZoom = abs(zoom - 1) < 0.05 ? 1 : (zoom * 100).rounded() / 100
                            pinchZoom = nil
                            pinchAnchorY = nil
                        })
                    .overlay(alignment: .top) {
                        if let zoom = pinchZoom {
                            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 8).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: zoomLevel) { old, new in
                        #if os(macOS)
                        guard old > 0, let offset = weekDrag.scrollOffset() else { return }
                        let anchor = CGFloat(pinchAnchorY ?? Double(weekDrag.viewport.height) / 2)
                        let adjusted = (offset + anchor) * CGFloat(new / old) - anchor
                        DispatchQueue.main.async { weekDrag.setScrollOffset(adjusted) }
                        #endif
                    }
                    .task(id: locateRequest) {
                        do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                        if let minute = locatedMinute(days: days) { proxy.scrollTo(minute, anchor: .top) }
                    }
                    .onChange(of: locateRequest) { _, _ in
                        let now = Date()
                        guard locatedTask == nil, Dates.sameDay(selectedDate, now), days.contains(where: { Dates.sameDay($0, now) }) else { return }
                        proxy.scrollTo(anchorHour(layout, now: minuteOfDay(now)), anchor: .top)
                    }
                    .task(id: days[0]) {
                        guard !weekDrag.isDragging else { return }
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                        guard !weekDrag.isDragging else { return }
                        if let minute = locatedMinute(days: days) { proxy.scrollTo(minute, anchor: .top); return }
                        guard !weekDrag.restoreHeldScroll() else { return }
                        proxy.scrollTo(anchorHour(layout, now: todayIndex == nil ? nil : minuteOfDay(Date())), anchor: .top)
                    }
                }
            }
            #if os(iOS)
            .contentShape(Rectangle())
            .modifier(PageSwipe { if !weekDrag.isDragging { stepPeriod($0) } })
            #endif
        }
    }

    func weekHeader(_ day: Date) -> some View {
        let today = Dates.sameDay(day, currentDay)
        let selected = Dates.sameDay(day, selectedDate)
        return Button {
            if let id = assigning { assign(id, to: day) } else {
                selectedDate = day
                if isPhone { presentation.showDay(day) }
            }
        } label: {
            VStack(spacing: 2) {
                Text(Dates.label(day, pattern: "E")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(Dates.calendar.component(.day, from: day))").font(.callout.monospacedDigit().weight(selected || today ? .semibold : .regular))
                    .foregroundStyle(today ? Color.selectedInk : selected ? Color.accentColor : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(today ? Color.accentColor : .clear, in: Circle())
                    .overlay { if selected && !today { Circle().stroke(Color.accentColor, lineWidth: 1) } }
            }.frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
        }.buttonStyle(.plain)
            .accessibilityLabel(Dates.label(day) + (today ? L("，今天", ", today") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(isPhone ? L("查看当天全部任务", "Show all tasks for this day") : "")
            .dayDrop { dropOnDay($0, day) }
    }

    func allDayCell(_ day: Date, index: Int, items all: [TaskItem]) -> some View {
        let items = TaskItem.ordered(all.filter { $0.clockDate == nil })
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(visiblePlanItems(items, count: 2)) { allDayChip($0, day: day) }
            if items.count > 2 {
                Button("+\(items.count - 2)") { presentation.showDay(day) }
                    .font(.caption2).buttonStyle(.borderless)
                    .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                    .accessibilityLabel(L("查看当天全部任务", "Show all tasks for this day"))
            }
        }.padding(.horizontal, 1).frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            .contentShape(Rectangle())
            .modifier(WeekZoneHighlight(zone: .allDay(index)))
            .dayDrop { dropAllDay($0, day) }
            .contextMenu {
                #if os(macOS)
                if let copiedTask { Button(L("粘贴为全天任务", "Paste as all-day task")) { pasteTask(copiedTask, at: day, timed: false) } }
                #endif
            }
            .modifier(CalendarDayPopover(presentation: presentation, day: day) { dayTasks(day) })
    }

    func calendarCategory(_ list: TaskList, color: Color, isDone: Bool = false) -> some View {
        Text((list.emoji.map { $0 + " " } ?? "") + list.name)
            #if os(iOS)
            .font(.caption2.weight(.medium)).lineLimit(1)
            #else
            .font(.system(size: 10, weight: .medium)).lineLimit(1)
            #endif
            .padding(.horizontal, 3)
            .foregroundStyle(isDone ? Color.secondary : Color.primary)
            .background(color.opacity(isDone ? 0.08 : 0.22), in: RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(isDone ? 0.18 : 0.45), lineWidth: 0.5) }
    }

    func allDayChip(_ task: TaskItem, day: Date) -> some View {
        let key = detailID(task, day: day, allDay: true)
        let color = planColor(task)
        let chip = VStack(alignment: .leading, spacing: 1) {
            Text((task.previewSourceID == nil ? "" : "↻ ") + task.title).font(.caption2.weight(task.priority == 2 && !task.isDone ? .bold : .regular)).lineLimit(1).strikethrough(task.isDone)
            if !isPhone {
                HStack(spacing: 3) { if let list = task.calendarList { calendarCategory(list, color: color, isDone: task.isDone) }; Spacer(minLength: 0); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
            }
        }
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(task.isDone ? 0.06 : 0.2), in: RoundedRectangle(cornerRadius: 4))
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
        #if os(macOS)
        return chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { presentation.showTask(key) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 12 }, drop: weekDrop))
            .contextMenu { taskCopyMenu(task) }
        #else
        return Button { presentation.showTask(key) } label: { chip }.buttonStyle(.plain)
            .modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(TaskDragSource(task: task, showPreview: false))
            .contextMenu { taskCopyMenu(task) }
        #endif
    }

    func weekCanvas(_ days: [Date], perDay: [[PlanBlock]], layout: TimelineLayout, todayIndex: Int?, width: CGFloat) -> some View {
        let column = max(1, (width - planGutter - planTrailing) / CGFloat(days.count))
        return ZStack(alignment: .topLeading) {
            TimelineView(.everyMinute) { clock in
            let nowMinute = minuteOfDay(clock.date)
            VStack(spacing: 0) {
                ForEach(layout.hours, id: \.self) { minute in
                    HStack(alignment: .top, spacing: 4) {
                        Text(clockLabel(minute)).font(isPhone ? .system(size: 9).monospacedDigit() : .caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: planGutter - 6, alignment: .trailing)
                            .opacity(todayIndex != nil && abs(nowMinute - minute) < 20 ? 0 : 1)
                        Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
                    }.frame(height: CGFloat(60 * layout.scale), alignment: .top).id(minute)
                }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
            ZStack(alignment: .topLeading) {
            ForEach(days.indices, id: \.self) { index in
                Rectangle().fill(index == todayIndex ? Color.accentColor.opacity(0.05) : Color.clear)
                    .frame(width: column, height: CGFloat(layout.height))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1) }
                    .offset(x: planGutter + CGFloat(index) * column)
                    .allowsHitTesting(false)
            }
            ForEach(days.indices, id: \.self) { index in
                ForEach(perDay[index]) { block in
                    let end = block.end
                    timelineBlock(block, day: days[index], layout: layout, end: end)
                        .frame(width: max(10, column / CGFloat(block.columns) - 2), height: CGFloat(layout.intervalHeight(from: block.start, to: end)), alignment: .topLeading)
                        .offset(x: planGutter + CGFloat(index) * column + CGFloat(block.column) * column / CGFloat(block.columns) + 1, y: CGFloat(layout.y(block.start)))
                }
            }
            if let todayIndex { nowMarker(layout: layout, column: column, todayIndex: todayIndex, width: width) }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
                .modifier(WeekPageSlide())
            #if os(macOS)
            WeekDragGhost(layout: layout, column: column, gutter: planGutter, days: days)
            #endif
            }
            .frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
        .contentShape(Rectangle())
        #if os(macOS)
        .background {
            if let copiedTask {
                CalendarPasteMenu { point in
                    guard !weekDrag.isDragging,
                          let slot = PlanSlot.emptyPoint(point, column: column, gutter: planGutter, layout: layout,
                                                        occupied: weekTaskFrames(perDay, column: column, layout: layout)) else { return nil }
                    let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute)
                    return (L("粘贴到这里 · ", "Paste here · ") + Dates.label(moment, pattern: "M月d日 HH:mm"),
                            { pasteTask(copiedTask, at: moment) })
                }
            }
        }
        .simultaneousGesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1)).onEnded { event in
            switch event {
            case .first(let tap):
                guard editor == nil, assigningTask == nil, !weekDrag.isDragging else { return }
                let occupied = weekTaskFrames(perDay, column: column, layout: layout)
                guard let slot = PlanSlot.emptyPoint(tap.location, column: column, gutter: planGutter, layout: layout, occupied: occupied, dayCount: days.count) else { return }
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute)
                selectedDate = days[slot.day]; editor = EditorRequest(date: moment, timed: true)
            case .second(let tap):
                guard let slot = planSlot(tap.location, column: column, layout: layout, dayCount: days.count) else { return }
                guard let task = assigningTask else { return }
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute, reference: task.clockDate)
                assigning = nil; arrange(task, at: moment)
            }
        })
        #else
        // A standard tap yields to a vertical pan; no exclusive single/double recognizer on iOS.
        .onTapGesture(coordinateSpace: .local) { point in
            guard editor == nil, let slot = planSlot(point, column: column, layout: layout, dayCount: days.count) else { return }
            if let task = assigningTask {
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute, reference: task.clockDate)
                assigning = nil; arrange(task, at: moment)
            } else {
                guard PlanSlot.emptyPoint(point, column: column, gutter: planGutter, layout: layout,
                                          occupied: weekTaskFrames(perDay, column: column, layout: layout), dayCount: days.count) != nil else { return }
                selectedDate = days[slot.day]
                editor = EditorRequest(date: Dates.clockTime(on: days[slot.day], minute: slot.minute), timed: true)
            }
        }
        #endif
        .weekCanvasDrop(
            drag: weekDrag, layout: layout,
            slotAt: { planSlot($0, column: column, layout: layout, dayCount: days.count) },
            preview: { slot in
                if let task = draggingTask { dropPreview(task, slot: slot, layout: layout, column: column, day: days[slot.day]) }
            },
            receive: { value, point in
                if let slot = planSlot(point, column: column, layout: layout, dayCount: days.count), let task = droppedTask([value]) {
                    arrange(task, at: Dates.clockTime(on: days[slot.day], minute: slot.minute, reference: task.clockDate))
                }
            })
        }

    func weekTaskFrames(_ perDay: [[PlanBlock]], column: CGFloat, layout: TimelineLayout) -> [CGRect] {
        var frames: [CGRect] = []
        for (index, blocks) in perDay.enumerated() {
            for block in blocks {
                let width = column / CGFloat(block.columns)
                let x = planGutter + CGFloat(index) * column + CGFloat(block.column) * width + 1
                frames.append(CGRect(x: x, y: CGFloat(layout.y(block.start)), width: max(10, width - 2),
                                     height: CGFloat(layout.intervalHeight(from: block.start, to: block.end))))
            }
        }
        return frames
    }

    func planSlot(_ point: CGPoint, column: CGFloat, layout: TimelineLayout, dayCount: Int = 7) -> PlanSlot? {
        guard dayCount > 0, point.x >= planGutter, point.x < planGutter + CGFloat(dayCount) * column else { return nil }
        return PlanSlot(day: min(dayCount - 1, max(0, Int((point.x - planGutter) / column))), minute: layout.snapped(Double(point.y)))
    }

    func dropPreview(_ task: TaskItem, slot: PlanSlot, layout: TimelineLayout, column: CGFloat, day: Date) -> some View {
        let start = Dates.clockTime(on: day, minute: slot.minute, reference: task.clockDate)
        let end = task.proposedEnd(at: start)
        let span = Dates.clockSpan(from: start, to: end, on: start)
        let height = layout.intervalHeight(from: span.start, to: span.end)
        return RoundedRectangle(cornerRadius: min(5, height / 2)).fill(Color.accentColor.opacity(0.12))
            .frame(width: max(10, column - 2), height: height)
            .overlay(RoundedRectangle(cornerRadius: min(5, height / 2)).strokeBorder(Color.accentColor, lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                Text(Dates.label(start, pattern: "HH:mm") + "–" + Dates.label(end, pattern: Dates.sameDay(start, end) ? "HH:mm" : "M月d日 HH:mm"))
                    .font(.caption2.monospacedDigit()).padding(3).background(Color.appBackground, in: RoundedRectangle(cornerRadius: 3))
                    .offset(y: height < 28 ? -height - 2 : 0)
            }
            .offset(x: planGutter + CGFloat(slot.day) * column + 1, y: CGFloat(layout.y(span.start)))
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .linear(duration: 0.06), value: slot)
    }

    @ViewBuilder func nowMarker(layout: TimelineLayout, column: CGFloat, todayIndex: Int, width: CGFloat) -> some View {
        TimelineView(.everyMinute) { clock in
            let minute = minuteOfDay(clock.date)
            // TimelineView supplies one layout child; keep every marker anchored to the canvas origin.
            ZStack(alignment: .topLeading) {
                if minute >= layout.startMinute && minute <= layout.endMinute {
                    let y = CGFloat(layout.y(Double(minute)))
                    Rectangle().fill(Color.red.opacity(0.3)).frame(width: max(0, width - planGutter), height: 1)
                        .offset(x: planGutter, y: y - 0.5).accessibilityHidden(true)
                    Rectangle().fill(Color.red).frame(width: column, height: 2)
                        .offset(x: planGutter + CGFloat(todayIndex) * column, y: y - 1).accessibilityHidden(true)
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                        .offset(x: planGutter + CGFloat(todayIndex) * column - 3.5, y: y - 3.5).accessibilityHidden(true)
                    Text(Dates.label(clock.date, pattern: "HH:mm"))
                        .font(isPhone ? .system(size: 9, weight: .semibold).monospacedDigit() : .caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1).background(Color.red, in: Capsule())
                        .frame(width: planGutter - 2)
                        .position(x: (planGutter - 2) / 2, y: y)
                        .accessibilityLabel(L("现在 \(Dates.label(clock.date, pattern: "HH:mm"))", "Now \(Dates.label(clock.date, pattern: "HH:mm"))"))
                }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
        }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading).allowsHitTesting(false)
    }

    /// Open on the current hour when this week holds today; any other week opens at 8:00, not midnight.
    func anchorHour(_ layout: TimelineLayout, now: Int?) -> Int {
        guard let now else { return min(max(layout.startMinute, 8 * 60), max(layout.startMinute, layout.endMinute - 60)) }
        return min(max(layout.startMinute, now / 60 * 60 - 60), max(layout.startMinute, layout.endMinute - 60))
    }

    /// The shape represents the interval; text appears only when it fits.
    func timelineBlock(_ block: PlanBlock, day: Date, layout: TimelineLayout, end: Double) -> some View {
        let task = block.task
        let height = layout.intervalHeight(from: block.start, to: end)
        let edgeHeight = task.previewSourceID == nil ? TaskResize.handleHeight(for: height) : 0
        let key = detailID(task, day: day)
        let time = task.timeLabel
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let midnight = Dates.calendar.startOfDay(for: day)
        let nextDay = Dates.calendar.date(byAdding: .day, value: 1, to: midnight)!
        let fromPrevious = task.clockDate.map { $0 < midnight } ?? false
        let toNext = task.endAt.map { $0 > nextDay } ?? false
        let card = RoundedRectangle(cornerRadius: min(5, height / 2))
            .fill(planColor(task).opacity(task.isDone ? 0.09 : 0.22))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(planColor(task)).frame(width: 3) }
            .overlay(alignment: .topLeading) {
                if height >= 14 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text((task.previewSourceID == nil ? "" : "↻ ") + task.title)
                                #if os(iOS)
                                .font(.caption.weight(task.priority == 2 && !task.isDone ? .bold : .medium))
                                #else
                                .font(.system(size: 11, weight: task.priority == 2 && !task.isDone ? .bold : .regular))
                                #endif
                                .strikethrough(task.isDone).lineLimit(isPhone ? (height >= 76 ? 4 : height >= 48 ? 2 : 1) : height >= 76 ? 2 : 1)
                            if !isPhone && height < 30 { Spacer(minLength: 0); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
                        }
                        if !isPhone && height >= 30 {
                            HStack(spacing: 3) {
                                if let list = task.calendarList { calendarCategory(list, color: planColor(task), isDone: task.isDone) }
                                Spacer(minLength: 0)
                                CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
                            }
                        }
                        if !isPhone && height >= 48 { Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.horizontal, 4).padding(.trailing, fromPrevious || toNext ? 10 : 0)
                        .padding(.vertical, height >= 30 ? 1 : 0)
                }
            }
            .overlay(alignment: .topTrailing) {
                if fromPrevious { Image(systemName: "arrow.left").font(.system(size: 8, weight: .semibold)).padding(2).accessibilityHidden(true).allowsHitTesting(false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if toNext { Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).padding(2).accessibilityHidden(true).allowsHitTesting(false) }
            }
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
            .clipped()
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
        let help = [task.title, task.timeLabel, task.calendarList.map { ListTree.path($0, lists: lists) } ?? "", note].filter { !$0.isEmpty }.joined(separator: "\n")
        #if os(macOS)
        return card.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel([task.title, task.timeLabel, task.calendarList?.name ?? "", task.priority == 2 ? L("高优先级", "High priority") : task.priority == 1 ? L("中优先级", "Medium priority") : ""].filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityAction { presentation.showTask(key) }
            .help(help)
            .contextMenu { taskCopyMenu(task) }
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(WeekDragSource(task: task, color: planColor(task), grabOffset: { start in
                // How far below the task's own start the pointer went down, so the task keeps that spot while moving.
                guard let clock = task.clockDate else { return 12 }
                let offset = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: day), to: Dates.calendar.startOfDay(for: clock)).day ?? 0
                let minute = Double(offset * 1440) + Dates.clockMinute(clock)
                return Double(start.y) - (Double(weekDrag.canvas.minY) + layout.y(minute))
            }, drop: weekDrop))
            .overlay(alignment: .top) { if edgeHeight > 0, let range = TaskResize(task: task, day: day, top: true, column: block.column, columns: block.columns) { resizeHandle(task, range: range, height: edgeHeight) } }
            .overlay(alignment: .bottom) { if edgeHeight > 0, let range = TaskResize(task: task, day: day, top: false, column: block.column, columns: block.columns) { resizeHandle(task, range: range, height: edgeHeight) } }
        #else
        return Button { presentation.showTask(key) } label: { card }.buttonStyle(.plain)
            .accessibilityLabel(help)
            .modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .help(help)
            .contextMenu { taskCopyMenu(task) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(TaskDragSource(task: task, showPreview: false))
        #endif
    }

    #if os(macOS)
    func resizeHandle(_ task: TaskItem, range: TaskResize, height: Double) -> some View {
        Color.clear.frame(height: height).contentShape(Rectangle())
            .help(range.top ? L("拖动调整开始时间，左右可跨天", "Drag to adjust start; move sideways to change day") : L("拖动调整结束时间，左右可跨天", "Drag to adjust end; move sideways to change day"))
            .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(WeekDrag.space))
                .onChanged { value in
                    weekDrag.updateResize(task, color: planColor(task), range: range, point: value.location, others: tasks) { endpoint, offset in
                        let destination = Dates.calendar.date(byAdding: .day, value: offset * 7, to: range.day)!
                        requestMove(task, to: endpoint, kind: range.top ? .resizeStart : .resizeEnd, revealDate: offset == 0 ? nil : destination)
                    }
                }
                .onEnded { _ in if weekDrag.taskID == task.id { weekDrag.complete() } })
            .accessibilityElement().accessibilityLabel(range.top ? L("调整开始时间", "Adjust start time") : L("调整结束时间", "Adjust end time"))
    }
    #endif

    var calendarSearchResults: some View {
        let results = TaskItem.ordered(tasks.filter { CalendarTaskSearch.matches($0, query: search) && filter.matches($0, lists: lists, today: currentDay) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("全部任务", "All tasks")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(L("\(results.count) 项", "\(results.count) tasks")).font(.caption).foregroundStyle(.secondary)
            }
            if results.isEmpty { ContentUnavailableView(L("没有找到任务", "No tasks found"), systemImage: "magnifyingglass", description: Text(L("试试其他关键词。", "Try another keyword."))) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { task in
                            Button { locate(task) } label: {
                                HStack(spacing: 10) {
                                    if let list = task.list { Text(list.emoji ?? "").frame(width: list.emoji == nil ? 0 : 22) }
                                    Circle().fill(planColor(task)).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 4) { Text(task.title).fontWeight(task.priority == 2 && !task.isDone ? .bold : .regular).strikethrough(task.isDone); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
                                        Text([task.calendarDate.map { Dates.label($0, pattern: "yyyy年M月d日") } ?? L("无日期", "Undated"), task.timeLabel, task.calendarList.map { ListTree.path($0, lists: lists) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward").foregroundStyle(.secondary)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    func locate(_ task: TaskItem) {
        weekDrag.releaseHeldScroll()
        search = ""; presentation.taskKey = nil
        locatedTask = task.id; locateRequest = UUID()
        if task.isDone { showPlanningCompleted = true }
        if let date = task.calendarDate {
            let currentDays = planningView == "month" ? Dates.monthCells(selectedDate).filter { Dates.calendar.isDate($0, equalTo: selectedDate, toGranularity: .month) } : Dates.weekCells(selectedDate)
            selectedDate = currentDays.first(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) ?? date
        } else { editor = EditorRequest(task: task) }
    }
    func locatedMinute(days: [Date]) -> Int? {
        guard let id = locatedTask, let task = tasks.first(where: { $0.id == id }), let clock = task.clockDate,
              days.contains(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) else { return nil }
        let minute = Dates.sameDay(clock, selectedDate) ? minuteOfDay(clock) : 0
        return max(0, min(1380, minute / 60 * 60 - 60))
    }
    func visiblePlanItems(_ items: [TaskItem], count: Int) -> [TaskItem] {
        var shown = Array(items.prefix(count))
        if count > 0, let target = items.first(where: { $0.id == locatedTask }), !shown.contains(where: { $0.id == target.id }) {
            shown[shown.count - 1] = target
        }
        return shown
    }

    func detailID(_ task: TaskItem, day: Date, allDay: Bool = false) -> String {
        "\(task.id.uuidString)|\(Int(Dates.calendar.startOfDay(for: day).timeIntervalSince1970))|\(allDay)"
    }

    /// Closes the card first; a sheet can't be presented while a popover is still going away.
    func afterDetail(_ action: @escaping () -> Void) {
        presentation.close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            action()
        }
    }

    func toggleSubtask(_ task: TaskItem, _ id: UUID) {
        _ = commit {
            var updated = task.subtasks
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].isDone.toggle(); task.subtasks = updated }
        }
    }

    @ViewBuilder func taskDetail(_ task: TaskItem) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task) }
        else { savedTaskDetail(task) }
    }

    func repeatPreviewDetail(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("重复安排预览", "Repeat preview"), systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
            Text(task.title).font(.headline)
            Text(task.calendarDate.map { Dates.label($0) } ?? "").font(.caption)
            taskMetadata(task)
            Text(L("完成当前任务后才会生成下一次；预览不会单独提醒。", "The next task is created when the current one is completed. Previews don't send notifications.")).font(.caption).foregroundStyle(.secondary)
            Button(L("查看原任务", "Open original task")) {
                presentation.day = nil
                if let original = tasks.first(where: { $0.id == task.previewSourceID }) {
                    afterDetail { editor = EditorRequest(task: original) }
                }
            }.buttonStyle(.borderless)
        }.padding(16)
        #if os(macOS)
        .frame(width: 290)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    func savedTaskDetail(_ task: TaskItem) -> some View {
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Button { toggleCompletion(task) } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("标记为已完成", "Mark complete"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).font(.headline).strikethrough(task.isDone)
                        taskMetadata(task)
                    }
                }
                if !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(task.subtasks) { subtask in
                            Button { toggleSubtask(task, subtask.id) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                                    Text(subtask.title).strikethrough(subtask.isDone).foregroundStyle(subtask.isDone ? .secondary : .primary)
                                        .multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                if !(selection == .calendar && planningView == "month") {
                    Button { afterDetail { copyTask(task) } } label: {
                        Label(L("复制", "Copy"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 16) {
                    if presentation.inlineDelete == task.id {
                        Text(L("删除这项任务？", "Delete this task?")).font(.callout.weight(.medium))
                        Spacer()
                        Button(L("取消", "Cancel")) { presentation.inlineDelete = nil }.keyboardShortcut(.cancelAction)
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = nil; presentation.taskKey = nil; deleteTask(task) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("编辑", "Edit")) { afterDetail { editor = EditorRequest(task: task) } }
                            .frame(minHeight: 44)
                        Spacer()
                        #if os(iOS)
                        Button(L("删除", "Delete"), role: .destructive) { afterDetail { confirmingDelete = task.id } }.frame(minHeight: 44)
                        #else
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = task.id }
                        #endif
                    }
                }.buttonStyle(.borderless)
                .onDisappear { if presentation.inlineDelete == task.id { presentation.inlineDelete = nil } }
            }.padding(16)
        }
        #if os(macOS)
        .frame(width: 300).frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    // MARK: Month

    var monthMinCell: CGFloat {
        #if os(macOS)
        86
        #else
        64
        #endif
    }

    /// Written out in full: an icon alone did not say what it switched.
    var completedSwitch: some View {
        Toggle(L("显示已完成", "Show completed"), isOn: $showPlanningCompleted)
            .toggleStyle(.switch).controlSize(.mini).font(.caption).foregroundStyle(.secondary)
            .fixedSize()
    }

    var monthPanel: some View {
        let month = previewMonthDate
        let cells = Dates.monthCells(month)
        let rows = max(1, cells.count / 7)
        let items = planningTasks
        let calendar = Dates.calendar
        let byDay = CalendarIndex.byDay(items, days: cells, calendar: calendar).mapValues { TaskItem.ordered($0, incompleteFirst: true, calendar: calendar) }
        let range = calendar.dateInterval(of: .month, for: month)!
        let inMonth = items.filter { $0.overlaps(range) }
        let monthTasks = inMonth.filter { $0.previewSourceID == nil }
        let previewCount = inMonth.count - monthTasks.count
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("本月 \(monthTasks.count) 项 · 已完成 \(monthTasks.filter(\.isDone).count) 项", "This month: \(monthTasks.count) · Completed: \(monthTasks.filter(\.isDone).count)") + (previewCount > 0 ? L(" · 预览 \(previewCount) 项", " · \(previewCount) previews") : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                #if os(macOS)
                completedSwitch
                #endif
            }.padding(.bottom, 8)
            HStack(spacing: 0) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.bottom, 6).padding(.trailing, planTrailing)
            GeometryReader { geometry in
                let height = max(monthMinCell, floor(geometry.size.height / CGFloat(rows)))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                        ForEach(Array(cells.enumerated()), id: \.element) { index, day in
                            monthCell(day, index: index, month: month, items: byDay[Dates.calendar.startOfDay(for: day)] ?? [], height: height)
                        }
                    }
                    .modifier(WeekPageSlide())
                    .reportWeekFrame { weekDrag.monthCanvas = $0 }
                }
                .scrollDisabled(height * CGFloat(rows) <= geometry.size.height + 1)
                .reportWeekFrame { weekDrag.monthViewport = $0 }
            }
            // The strip right of Sunday is where "next month" starts, like in the week view.
            .padding(.trailing, planTrailing)
        }
        .weekDragPanel(weekDrag)
    }

    @ViewBuilder func monthCell(_ day: Date, index: Int, month: Date, items: [TaskItem], height: CGFloat) -> some View {
        if Dates.calendar.isDate(day, equalTo: month, toGranularity: .month) {
            monthDayCell(day, items: items, height: height)
                .modifier(WeekZoneHighlight(zone: .day(index)))
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1) }
                .accessibilityHidden(true)
        }
    }

    func monthDayCell(_ day: Date, items: [TaskItem], height: CGFloat) -> some View {
        let today = Dates.sameDay(day, currentDay)
        let selected = Dates.sameDay(day, selectedDate)
        let inMonth = Dates.calendar.isDate(day, equalTo: previewMonthDate, toGranularity: .month)
        let line: CGFloat = 16
        let capacity = max(0, Int((height - 26) / line))
        let shown = items.count > capacity ? max(0, capacity - 1) : items.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(Dates.calendar.component(.day, from: day))").font(.caption.monospacedDigit().weight(today ? .bold : .medium))
                    .foregroundStyle(today ? Color.selectedInk : inMonth ? Color.primary : Color.secondary)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(today ? Color.accentColor : .clear, in: Circle())
                Spacer(minLength: 0)
            }
            ForEach(visiblePlanItems(items, count: shown)) { monthChip($0, day: day, height: line - 2) }
            if items.count > shown {
                Button("+\(items.count - shown)") { selectedDate = day; presentation.showDay(day) }.font(.caption2).buttonStyle(.plain)
                    .accessibilityLabel(L("查看当天全部任务", "Show all tasks for this day"))
            }
            Spacer(minLength: 0)
        }.padding(3)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear)
            .overlay { if locatedTask != nil && items.contains(where: { $0.id == locatedTask }) { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1) }
            .opacity(inMonth ? 1 : 0.55)
            .contentShape(Rectangle())
            .onTapGesture {
                if let id = assigning { assign(id, to: day) }
                else { selectedDate = day; presentation.showDay(day) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("\(Dates.label(day))，\(items.count) 项", "\(Dates.label(day)), \(items.count)"))
            .accessibilityAddTraits(.isButton)
            .dayDrop { dropOnDay($0, day) }
            .modifier(CalendarDayPopover(presentation: presentation, day: day) { dayTasks(day) })
    }

    func dayTasks(_ day: Date) -> some View {
        let range = Dates.calendar.dateInterval(of: .day, for: day)!
        let matching = planningTasks.filter { $0.overlaps(range) }
        let items = TaskItem.ordered(matching, incompleteFirst: planningView == "month")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Dates.label(day)).font(.headline)
                Spacer()
                Button { presentation.day = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel(L("关闭", "Close"))
            }
            HStack(spacing: 8) {
                if planningView != "week" {
                    Button(L("查看这一周", "Open this week")) { openPlan(day, view: "week") }.frame(minHeight: 44)
                }
                Button(L("在列表中查看", "Open in list")) { openPlan(day, view: "list") }.frame(minHeight: 44)
            }.buttonStyle(.bordered).controlSize(.small)
            // A scroll view keeps whatever height it first got, so unfolding a row used to leave the note and
            // subtasks hidden below the edge. It now takes the rows' own height, up to 360, and scrolls beyond that.
            ScrollView {
                #if os(macOS)
                VStack(spacing: 0) { dayTaskRows(items) }
                .onGeometryChange(for: CGFloat.self) { min(360, max(44, ceil($0.size.height))) } action: {
                    presentation.updateRowsHeight($0, for: day)
                }
                #else
                LazyVStack(spacing: 0) { dayTaskRows(items) }
                #endif
            }
            #if os(macOS)
            .frame(height: presentation.rowsHeight)
            #else
            .frame(maxHeight: .infinity, alignment: .top)
            #endif
            Button { presentation.day = nil; afterDetail { editor = EditorRequest(date: day) } } label: {
                Label(L("添加任务", "Add task"), systemImage: "plus").frame(minHeight: 44)
            }.buttonStyle(.borderless)
        }.padding(16)
        #if os(macOS)
        .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        #else
        .padding(.top, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    @ViewBuilder private func dayTaskRows(_ items: [TaskItem]) -> some View {
        if items.isEmpty { Text(L("这一天还没有任务", "Nothing on this day")).foregroundStyle(.secondary).padding(.vertical, 12) }
        ForEach(items) { task in
            VStack(spacing: 0) {
                dayTaskRow(task)
                Divider()
            }
        }
    }

    /// Leaves the popover and shows that day in another view; the month stays where it was if the user comes back.
    func openPlan(_ day: Date, view: String) {
        presentation.day = nil
        slideForward = true
        selectedDate = day; wholeMonth = false
        planningView = view
    }

    /// A row in the day popover. Tapping it unfolds the note and subtasks in place, so nothing is hidden behind "edit".
    @ViewBuilder func dayTaskRow(_ task: TaskItem) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task) }
        else { savedDayTaskRow(task) }
    }

    func savedDayTaskRow(_ task: TaskItem) -> some View {
        let expanded = presentation.expandedTask == task.id
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMore = !note.isEmpty || !task.subtasks.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { toggleCompletion(task) } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isDone ? Color.accentColor : .secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel((task.isDone ? L("恢复未完成：", "Reopen: ") : L("完成：", "Complete: ")) + task.title)
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { presentation.expandedTask = expanded ? nil : task.id } } label: {
                    HStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 1).fill(planColor(task)).frame(width: 3, height: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            let meta = [task.timeLabel, task.subtasks.isEmpty ? "" : L("子任务 \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)", "Subtasks \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)"), note.isEmpty ? "" : L("有备注", "Note")].filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if hasMore { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary).padding(.top, 3) }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint(expanded ? L("收起详情", "Hide details") : L("展开备注和子任务", "Show note and subtasks"))
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !note.isEmpty {
                        Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(task.subtasks) { subtask in
                        Button { toggleSubtask(task, subtask.id) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                                Text(subtask.title).strikethrough(subtask.isDone).foregroundStyle(subtask.isDone ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Button(L("编辑", "Edit")) { presentation.day = nil; afterDetail { editor = EditorRequest(task: task) } }
                        .buttonStyle(.borderless)
                }.padding(.leading, 42).padding(.bottom, 8)
            }
        }
    }

    /// Mac chips open the task card; on a phone the whole cell opens that week instead.
    @ViewBuilder func monthChip(_ task: TaskItem, day: Date, height: CGFloat) -> some View {
        let color = planColor(task)
        #if os(macOS)
        let prefix = task.clockDate.map { Dates.sameDay($0, day) ? Dates.label($0, pattern: "HH:mm") + " " : L("续 ", "↳ ") } ?? ""
        #else
        let prefix = ""
        #endif
        let chip = HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2)
            Text(prefix + (task.previewSourceID == nil ? "" : "↻ ") + task.title).font(.caption2.weight(task.priority == 2 && !task.isDone ? .bold : .regular)).lineLimit(1).strikethrough(task.isDone)
            Spacer(minLength: 0)
            CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
        }.frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(task.isDone ? 0.05 : 0.14), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
        #if os(macOS)
        let key = detailID(task, day: day, allDay: true)
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .help([task.title, task.calendarList.map { ListTree.path($0, lists: lists) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(prefix + task.title + (task.priority == 2 ? L("，高优先级", ", high priority") : task.priority == 1 ? L("，中优先级", ", medium priority") : ""))
            .accessibilityAction { presentation.showTask(key) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 0 }, month: selectedDate, drop: monthDrop))
        #else
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .allowsHitTesting(false)
        #endif
    }

    func dropAllDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = droppedTask(values) else { return false }
        makeAllDay(task, on: day)
        return true
    }

    /// Dragging out of the timeline onto the all-day row keeps the day and removes the time.
    func makeAllDay(_ task: TaskItem, on day: Date, revealDate: Date? = nil) {
        requestMove(task, to: day, kind: .allDay, revealDate: revealDate)
    }

    func clearDate(_ task: TaskItem) {
        guard task.calendarDate != nil else { return }
        guard task.dueAt == nil, task.repeatRule == "none" else {
            notify(L("有截止日期或重复的任务不能去掉日期", "Tasks with a deadline or repeat keep their date")); return
        }
        if commitSchedule(task, { task.clearSchedule() }) { movedMessage = L("已去掉日期", "Date removed") }
    }

    func dropOnDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = droppedTask(values) else { return false }
        move(task, toDay: day)
        return true
    }

    func move(_ task: TaskItem, toDay day: Date, revealMonth: Bool = false) {
        requestMove(task, to: day, kind: .day, revealDate: revealMonth ? day : nil, revealMonth: revealMonth)
    }

    /// Where a task dragged inside the Mac week view was let go.
    func weekDrop(_ task: TaskItem, _ zone: WeekDropGeometry.Zone, _ weekOffset: Int) {
        let destination = Dates.calendar.date(byAdding: .day, value: weekOffset * 7, to: selectedDate)!
        let days = Dates.weekCells(destination)
        switch zone {
        case .none: break
        case .timed(let day, let minute):
            // Same week: the block glides to its new place. Another week is already on screen, so no extra animation.
            withAnimation(weekOffset == 0 && !reduceMotion ? .spring(response: 0.3, dampingFraction: 0.86) : nil) {
                arrange(task, at: Dates.clockTime(on: days[day], minute: minute, reference: task.clockDate), revealDate: weekOffset == 0 ? nil : destination)
            }
        case .allDay(let day):
            makeAllDay(task, on: days[day], revealDate: weekOffset == 0 ? nil : destination)
        case .undated: clearDate(task)
        case .day: break
        }
        }

        /// Where a task dragged in the Mac month view was let go. A drop in another month stays in that month.
        func monthDrop(_ task: TaskItem, _ zone: WeekDropGeometry.Zone, _ monthOffset: Int) {
            if zone == .undated { clearDate(task); return }
            guard case .day(let index) = zone else { return }
            let cells = Dates.monthCells(Dates.shiftMonth(selectedDate, by: monthOffset))
            guard cells.indices.contains(index) else { return }
            let day = cells[index]
            move(task, toDay: day, revealMonth: monthOffset != 0)
        }

    func droppedTask(_ values: [String]) -> TaskItem? {
        guard values.count == 1, values[0].hasPrefix("jianshi-task:"), let id = UUID(uuidString: String(values[0].dropFirst(13))) else { return nil }
        return tasks.first { $0.id == id && $0.deletedAt == nil }
    }
    func revealWeek(_ date: Date) {
        let from = Dates.weekCells(selectedDate)[0], to = Dates.weekCells(date)[0]
        revealShift += (Dates.calendar.dateComponents([.day], from: from, to: to).day ?? 0) / 7
        selectedDate = date
    }

    func arrange(_ task: TaskItem, at moment: Date, revealDate: Date? = nil) {
        requestMove(task, to: moment, kind: .timed, revealDate: revealDate)
    }

    func requestMove(_ task: TaskItem, to day: Date, kind: TaskMove.Kind, revealDate: Date? = nil, revealMonth: Bool = false) {
        let proposal = TaskMove(task, to: day, kind: kind)
        guard proposal.changesSchedule else { return }
        let move = PendingMove(proposal: proposal, revealDate: revealDate, revealMonth: revealMonth)
        if !proposal.canKeepDeadline { pendingMove = move }
        else { finishMove(move, shiftDeadline: false) }
    }

    func finishMove(_ move: PendingMove, shiftDeadline: Bool) {
        let plan = move.proposal
        guard let task = tasks.first(where: { $0.id == plan.taskID && $0.deletedAt == nil }),
              TaskSchedule(task) == plan.before, shiftDeadline || plan.canKeepDeadline else {
            notify(L("任务已更改，请重新拖动", "The task changed. Drag it again.")); return
        }
        guard commitSchedule(task, { plan.apply(to: task, shiftDeadline: shiftDeadline) }) else { return }
        if !shiftDeadline, let undo = undoSchedule, plan.deferredDeadline(for: task, after: undo.after) != nil { deadlineMove = plan }

        // Commit the destination page only after both confirmation and a successful save.
        if let date = move.revealDate {
            if move.revealMonth {
                monthRevealShift += Dates.calendar.dateComponents([.month], from: Dates.monthStart(selectedDate), to: Dates.monthStart(date)).month ?? 0
                selectedDate = date
            } else { revealWeek(date) }
        }
        movedMessage = plan.kind == .resizeStart || plan.kind == .resizeEnd
            ? L("已调整为 ", "Adjusted to ") + task.timeLabel
            : L("已移到 ", "Moved to ") + Dates.label(plan.start, pattern: plan.timed ? "M月d日 HH:mm" : "M月d日")
        if let due = task.dueAt {
            movedMessage! += L(" · 截止 ", " · Due ") + Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        }
        if plan.timed, let end = task.endAt, PlanBlock.overlaps(DateInterval(start: plan.start, end: end), others: PlanBlock.occupied(tasks, excluding: task.id)) {
            movedMessage! += L(" · 与其他任务重叠", " · overlaps another task")
        }
    }

}


private struct PeriodChoiceButton: View {
    let label: String
    @Binding var date: Date
    let week: Bool
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 5) { Text(label); Image(systemName: "chevron.down").font(.caption) }.frame(minHeight: 44)
        }.popover(isPresented: $showing) {
            PeriodPicker(date: $date, week: week)
        }
    }
}

private struct PeriodPicker: View {
    @Binding var date: Date
    let week: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int

    init(date: Binding<Date>, week: Bool) {
        _date = date; self.week = week
        _year = State(initialValue: Dates.calendar.component(.year, from: date.wrappedValue))
        _month = State(initialValue: Dates.calendar.component(.month, from: date.wrappedValue))
    }

    var body: some View {
            VStack(spacing: 12) {
                HStack {
                    Button { year = max(1, year - 1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel(L("上一年", "Previous year"))
                    Text(String(year)).font(.headline).frame(maxWidth: .infinity)
                    Button { year = min(9998, year + 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel(L("下一年", "Next year"))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(1...12, id: \.self) { value in
                        let target = Dates.calendar.date(from: DateComponents(year: year, month: value, day: 1))!
                        Button(Dates.label(target, pattern: "MMM")) {
                            month = value
                            if !week { date = target; dismiss() }
                        }.frame(maxWidth: .infinity, minHeight: 44)
                            .background(month == value ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if week {
                    Divider()
                    let first = Dates.calendar.date(from: DateComponents(year: year, month: month, day: 1))!
                    let cells = Dates.monthCells(first)
                    ForEach(Array(stride(from: 0, to: cells.count, by: 7)), id: \.self) { index in
                        Button(Dates.label(cells[index], pattern: "M月d日") + " – " + Dates.label(cells[index + 6], pattern: "M月d日")) {
                            date = cells[index]; dismiss()
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }.buttonStyle(.plain).padding(12).frame(width: 290)
                .presentationCompactAdaptation(.popover)
    }
}

private struct ListTreeMenu: View {
    let nodes: [ListNode]
    let select: (UUID) -> Void
    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                Menu {
                    Button(L("查看此组全部任务", "View all tasks in group")) { select(node.id) }
                    ListTreeMenu(nodes: children, select: select)
                } label: {
                    ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji, isGroup: true)
                }
            } else {
                Button { select(node.id) } label: { ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji) }
            }
        }
    }
}

/// Hover state belongs to the overlay, so moving the pointer does not rebuild the task list.
private struct TimelineHoverDrop<Preview: View>: ViewModifier {
    let slotAt: (CGPoint) -> PlanSlot?
    @ViewBuilder var preview: (PlanSlot) -> Preview
    let receive: (String, CGPoint) -> Void
    @State private var slot: PlanSlot?
    @State private var targetID = UUID()
    @Environment(DragFeedback.self) private var feedback

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if feedback.target == targetID, let slot { preview(slot).allowsHitTesting(false) }
        }
        .onDrop(of: [UTType.text], delegate: TimelineDrop(
            update: { point in
                feedback.enter(targetID)
                let next = slotAt(point)
                if next != slot { slot = next }
            },
            exit: { slot = nil; feedback.leave(targetID) },
            receive: { value, point in feedback.end(); slot = nil; receive(value, point) },
            localValue: { feedback.payload }))
    }
}

private struct MoveFeedback: View {
    let message: String
    let canUndo: Bool
    let canShiftDeadline: Bool
    let shiftDeadline: () -> Void
    let undo: () -> Void
    let dismiss: () -> Void
    @State private var brief = true

    var body: some View {
        HStack(spacing: 10) {
            if brief { Text(message).lineLimit(2) }
            if canShiftDeadline { Button(L("截止也一起移", "Move deadline too"), action: shiftDeadline).buttonStyle(.borderless).fixedSize() }
            if canUndo { Button(L("撤销", "Undo"), action: undo).buttonStyle(.borderless) }
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).accessibilityLabel(L("关闭提示", "Dismiss message"))
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .task(id: message) {
                brief = true
                do {
                    try await Task.sleep(for: .seconds(2))
                    if canUndo {
                        brief = false
                        try await Task.sleep(for: .seconds(6))
                    }
                    dismiss()
                } catch {}
            }
    }
}

private struct TaskDropHighlight: ViewModifier {
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
private struct WeekPageSlide: ViewModifier {
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
/// Resolve the clicked slot once. Mouse movement does not publish state or rebuild the calendar.
private struct CalendarPasteMenu: NSViewRepresentable {
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

#if os(macOS)
/// Mac sidebar: a list follows the pointer while it is dragged, instead of going through system drag and drop
/// (which kept clicks from selecting a list). Rows report where they are; the drag works out the landing spot.
@MainActor @Observable final class ListDrag {
    private(set) var listID: UUID?
    private(set) var cancelledUntilPress = false
    @ObservationIgnored private var nextPress: Any?
    private(set) var name = ""
    private(set) var color = Color.accentColor
    /// The lifted row follows the pointer as a copy of itself, held where it was grabbed.
    private(set) var liftedFrame: CGRect?
    private(set) var grabOffset: CGFloat = 12
    private(set) var colorHex: String?
    private(set) var emoji: String?
    private(set) var isGroup = false
    private(set) var pointer = CGPoint.zero
    private(set) var target: (list: UUID?, placement: ListTree.Placement)?
    private(set) var offsets: [UUID: CGFloat] = [:]
    private(set) var gap: CGRect?
    private(set) var moving = Set<UUID>()
    @ObservationIgnored var isDescendant: ((UUID, UUID) -> Bool)?
    @ObservationIgnored var listName: ((UUID) -> String)?
    @ObservationIgnored var depthOf: ((UUID) -> Int)?
    @ObservationIgnored var descendantCount: ((UUID) -> Int)?
    /// Lists inside the lifted one (all levels, open or closed), which move along with it.
    private(set) var childCount = 0
    /// Frames in global coordinates. Not observed: nothing redraws for them.
    /// Each row's frame, with the row view that reported it. A list's row is sometimes replaced (a list that
    /// becomes a group, say): the new row reports before the old one goes away, and only the reporter may erase it.
    @ObservationIgnored private var rowFrames: [UUID: (owner: UUID, frame: CGRect)] = [:]
    var rows: [UUID: CGRect] { rowFrames.mapValues(\.frame) }
    func report(_ id: UUID, owner: UUID, frame: CGRect) {
        let changed = rowFrames[id]?.frame != frame
        rowFrames[id] = (owner, frame)
        if changed && isDragging { refreshLayout() }
    }
    func forget(_ id: UUID, owner: UUID) { if rowFrames[id]?.owner == owner { rowFrames[id] = nil } }
    @ObservationIgnored var header = CGRect.zero
    @ObservationIgnored var sidebar = CGRect.zero
    @ObservationIgnored private var blocked: ((UUID) -> Bool)?
    @ObservationIgnored private var escape: Any?
    /// Which rows are on screen; rows of closed groups keep an old frame and must not be targets.
    @ObservationIgnored var visibleRows: (() -> Set<UUID>)?
    @ObservationIgnored var openGroup: ((UUID) -> Void)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var insideSince: (id: UUID, time: Double, frame: CGRect)?
    @ObservationIgnored private var releasedSince: Double?

    var isDragging: Bool { listID != nil }

    func begin(_ list: TaskList, blocked: @escaping (UUID) -> Bool, start: CGPoint? = nil, isGroup: Bool = false) {
        guard !cancelledUntilPress, !isDragging else { return }
        visibleCache = nil
        listID = list.id; name = list.name; color = ListColor.color(list.id, hex: list.colorHex)
        colorHex = list.colorHex; emoji = list.emoji; self.isGroup = isGroup
        childCount = descendantCount?(list.id) ?? 0
        liftedFrame = rows[list.id]
        if let frame = liftedFrame { grabOffset = start.map { min(max(0, $0.y - frame.minY), frame.height) } ?? frame.height / 2 }
        self.blocked = blocked
        moving = Set(rows.keys.filter { $0 == list.id || blocked($0) })
        target = (list.id, .before)
        releasedSince = nil
        refreshLayout()
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isDragging else { return event }
            self.cancel(); return nil
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.checkPhysicalButton(pressed: NSEvent.pressedMouseButtons & 1 != 0, now: now) else { return }
                if !NSApp.isActive || NSApp.modalWindow != nil { self.cancel(); return }
                self.tick(now: now)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Rows on screen, worked out once per drag (and again after a group opens) instead of on every sample.
    @ObservationIgnored private var visibleCache: Set<UUID>?
    private var visibleFrames: [UUID: CGRect] {
        if visibleCache == nil { visibleCache = visibleRows?() ?? Set(rows.keys) }
        let visible = visibleCache ?? []
        return rows.filter { visible.contains($0.key) }
    }

    func move(to point: CGPoint, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isDragging else { return }
        pointer = point
        // Once armed, keep the folder under a stable hover region while the sorting gap closes.
        if target?.placement == .inside, let hover = insideSince,
           hover.frame.insetBy(dx: -4, dy: -4).contains(point), sidebar.contains(point) { return }
        var next = ListTree.dropTarget(pointer: point, rows: visibleFrames, header: header, area: sidebar, blocked: blocked ?? { _ in false })
        if let candidate = next, candidate.placement == .inside, let id = candidate.list, let frame = rows[id] {
            next = (id, point.y < frame.midY ? .before : .after)
        }
        // Moving through the vacated source row keeps the current slot; leaving the sidebar cancels the destination.
        if next == nil, sidebar.contains(point), moving.contains(where: { rows[$0]?.contains(point) == true }) {
            next = target?.placement == .inside ? nil : target
        } else if next == nil, sidebar.contains(point) {
            // Native sidebar rows have small gaps between them; crossing one must not reset the preview.
            let frames = visibleFrames.filter { !moving.contains($0.key) }
            if let nearest = frames.min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }),
               point.y >= (visibleFrames.values.map(\.minY).min() ?? .infinity),
               point.y <= (visibleFrames.values.map(\.maxY).max() ?? -.infinity) {
                next = (nearest.key, point.y < nearest.value.midY ? .before : .after)
            }
        }
        if next?.list != target?.list || next?.placement != target?.placement {
            target = next
            insideSince = nil
            refreshLayout()
        }
        if let hover = insideSince, !hover.frame.contains(point) { insideSince = nil }
        if insideSince == nil, let candidate = folderAtPointer() {
            insideSince = (candidate.id, now, candidate.frame)
        }
    }

    private func refreshLayout() {
        guard let target else { offsets = [:]; gap = nil; return }
        // The source target is just the resting slot, not a reparenting operation. Nothing moves, but the
        // slot the row came from is still marked: a lifted row must never leave an unexplained hole.
        guard target.list != listID else { offsets = [:]; gap = sourceSlot(); return }
        let preview = ListTree.dragPreview(rows: visibleFrames, moving: moving, target: target,
                                          isDescendant: isDescendant ?? { $0 == $1 })
        if offsets != preview.offsets { offsets = preview.offsets }
        if gap != preview.gap { gap = preview.gap }
    }

    /// Where the lifted row (with its children) sits right now.
    private func sourceSlot() -> CGRect? {
        let frames = visibleFrames.filter { moving.contains($0.key) }.values
        guard let top = frames.min(by: { $0.minY < $1.minY }), let bottom = frames.max(by: { $0.maxY < $1.maxY }) else { return nil }
        return CGRect(x: top.minX, y: top.minY, width: top.width, height: bottom.maxY - top.minY)
    }

    private func folderAtPointer() -> (id: UUID, frame: CGRect)? {
        guard sidebar.contains(pointer) else { return nil }
        return visibleFrames.compactMap { id, frame -> (UUID, CGRect)? in
            guard !moving.contains(id), blocked?(id) != true else { return nil }
            let shown = frame.offsetBy(dx: 0, dy: offsets[id] ?? 0)
            let middle = shown.insetBy(dx: 0, dy: shown.height * 0.18)
            return middle.contains(pointer) ? (id, middle) : nil
        }.first
    }

    /// The landing spot, if any; the drag is over either way. Nothing is saved on hover.
    func finish() -> (list: UUID?, placement: ListTree.Placement)? {
        let result = target?.list == listID ? nil : target
        end()
        return result
    }

    func tick(now: Double) {
        guard isDragging else { return }
        if let hover = insideSince, target?.placement == .inside {
            if now - hover.time >= 0.9 { openGroup?(hover.id); visibleCache = nil }
            return
        }
        guard let candidate = folderAtPointer() else { insideSince = nil; return }
        if insideSince?.id != candidate.id { insideSince = (candidate.id, now, candidate.frame); return }
        guard let hover = insideSince, now - hover.time >= 0.4 else { return }
        target = (candidate.id, .inside)
        refreshLayout()
    }

    /// A missed mouse-up can only cancel; never save a drop based on a later unrelated release.
    @discardableResult func checkPhysicalButton(pressed: Bool, now: Double) -> Bool {
        guard isDragging else { return false }
        if pressed { releasedSince = nil; return true }
        if let since = releasedSince, now - since >= 0.15 { cancel() }
        else if releasedSince == nil { releasedSince = now }
        return false
    }

    func cancel() {
        end(); cancelledUntilPress = true
        if nextPress == nil {
            nextPress = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.newPress(); return event
            }
        }
    }

    func newPress() {
        cancelledUntilPress = false
        if let nextPress { NSEvent.removeMonitor(nextPress); self.nextPress = nil }
    }

    private func end() {
        listID = nil; target = nil; blocked = nil; moving = []; offsets = [:]; gap = nil; liftedFrame = nil; visibleCache = nil
        ticker?.invalidate(); ticker = nil; insideSince = nil; releasedSince = nil
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    func isTarget(_ id: UUID?, _ placement: ListTree.Placement) -> Bool {
        isDragging && target?.list == id && target?.placement == placement
    }
}

/// Native List consumes arrow keys before SwiftUI onKeyPress. Intercept only its sidebar table's arrows.
private struct SidebarKeyboardNavigation: NSViewRepresentable {
    let move: (Int) -> Bool
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, let window = view.window,
                  event.window === window, window.attachedSheet == nil,
                  event.keyCode == 125 || event.keyCode == 126,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let table = window.firstResponder as? NSTableView,
                  view.convert(view.bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil)) else { return event }
            return coordinator.move(event.keyCode == 125 ? 1 : -1) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.move = move }
    func makeCoordinator() -> Coordinator { Coordinator(move: move) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var move: (Int) -> Bool
        init(move: @escaping (Int) -> Bool) { self.move = move }
    }
}

/// Flatten only visible rows so each row, including its disclosure arrow, can move independently.
private struct SidebarListEntry: Identifiable {
    let node: ListNode
    let depth: Int
    var id: UUID { node.id }
}
private struct SidebarListTree: View {
    let nodes: [ListNode]
    @Binding var expanded: Set<UUID>
    let drag: ListDrag
    let selected: UUID?
    let row: (ListNode) -> AnyView
    private var entries: [SidebarListEntry] {
        func flatten(_ nodes: [ListNode], depth: Int) -> [SidebarListEntry] {
            nodes.flatMap { node in
                [SidebarListEntry(node: node, depth: depth)] + (expanded.contains(node.id) ? flatten(node.children ?? [], depth: depth + 1) : [])
            }
        }
        return flatten(nodes, depth: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                let isSelected = selected == entry.id && !drag.moving.contains(entry.id)
                HStack(spacing: 4) {
                    if entry.node.children != nil {
                        Button {
                            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                        } label: {
                            Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                            .accessibilityLabel((expanded.contains(entry.id) ? L("收起：", "Collapse: ") : L("展开：", "Expand: ")) + entry.node.list.name)
                    }
                    row(entry.node)
                }
                .padding(.leading, CGFloat(entry.depth) * 14)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .foregroundStyle(isSelected ? Color.selectedInk : Color.primary)
                // Drawn like the native sidebar selection, a little wider than the text.
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor).padding(.horizontal, -8) }
                    else if drag.isTarget(entry.id, .inside) {
                        // The list being dropped into stays fully visible: the lifted row moves out of its way.
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .padding(.horizontal, -8)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .modifier(SidebarListMotion(id: entry.id, drag: drag))
            }
        }
    }
}

private struct SidebarListMotion: ViewModifier {
    let id: UUID
    let drag: ListDrag
    @State private var owner = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let offset = drag.offsets[id] ?? 0
        ZStack(alignment: .leading) {
            content
                .opacity(drag.moving.contains(id) ? 0 : 1)
                .offset(y: offset)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: offset)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.report(id, owner: owner, frame: $0) }
        .onDisappear { drag.forget(id, owner: owner) }
    }
}

/// A list row in the sidebar: a click selects it, dragging moves it.
private struct SidebarListRow: ViewModifier {
    let list: TaskList
    var isGroup = false
    let drag: ListDrag
    let select: () -> Void
    let blocked: (UUID) -> Bool
    let drop: ((list: UUID?, placement: ListTree.Placement)) -> Void

    func body(content: Content) -> some View {
        return Button(action: select) {
            content
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityLabel(list.name)
            .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { value in
                    if !drag.isDragging { drag.begin(list, blocked: blocked, start: value.startLocation, isGroup: isGroup) }
                    drag.move(to: value.location)
                }
                .onEnded { value in
                    guard drag.isDragging else { return }
                    drag.move(to: value.location)
                    // Replace preview offsets with the saved native row order in one frame.
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let target = drag.finish() { drop(target) }
                    }
                })
    }

}

/// "My lists": dropping a list here puts it back at the top level.
/// "My lists": dropping a list here puts it first at the top level. No highlight of its own:
/// the slot opening at the top of the rows already shows it.
private struct SidebarListHeader: ViewModifier {
    let drag: ListDrag
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.header = $0 }
    }
}

/// The lifted row itself, following the pointer up and down where it was grabbed. The rows below make room
/// for it; outside the sidebar it fades, because letting go there changes nothing.
private struct ListDragFloatingRow: View {
    let drag: ListDrag
    var body: some View {
        if drag.isDragging, let id = drag.listID, let frame = drag.liftedFrame {
            let parent = drag.target?.placement == .inside ? drag.target?.list : nil
            // Dropping into a list: the lifted row leaves the pointer and settles in the indented slot that opened
            // under that list, so the list itself is never covered and the row already shows where it will land.
            let slot = parent == nil ? nil : drag.gap
            // Indented to the level it would land on: inside a list is one level under it; before or after a list
            // is that list's level; the top and the end of the rows are the top level.
            let depth: Int = {
                guard let target = drag.target, target.list != id else { return drag.depthOf?(id) ?? 0 }
                let level = target.list.flatMap { drag.depthOf?($0) }
                return target.placement == .inside ? (level ?? -1) + 1 : (level ?? 0)
            }()
            HStack(spacing: 6) {
                ColoredListLabel(name: drag.name, id: id, colorHex: drag.colorHex, emoji: drag.emoji, isGroup: drag.isGroup)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if drag.childCount > 0 {
                    Text(L("含 \(drag.childCount) 个子清单", "+\(drag.childCount) inside")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize()
                }
            }
                .padding(.leading, 8 + CGFloat(depth) * 14).padding(.trailing, 8)
                .animation(.easeOut(duration: 0.12), value: depth)
                .frame(width: frame.width + 16, height: frame.height, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(drag.color.opacity(0.55)))
                .shadow(color: .black.opacity(slot == nil ? 0.28 : 0.12), radius: slot == nil ? 8 : 3, y: slot == nil ? 4 : 1)
                .scaleEffect(slot == nil ? 1.03 : 0.98)
                .opacity(slot == nil && !drag.sidebar.contains(drag.pointer) ? 0.45 : 1)
                .offset(x: frame.minX - 8 - drag.sidebar.minX,
                        y: (slot?.minY ?? (drag.pointer.y - drag.grabOffset)) - drag.sidebar.minY)
                .allowsHitTesting(false)
                // Following uses a very short interactive spring (it retargets smoothly on every sample);
                // settling into or leaving a folder's slot uses a fuller spring.
                .animation(slot == nil ? .interactiveSpring(response: 0.14, dampingFraction: 0.86) : .spring(response: 0.28, dampingFraction: 0.85),
                           value: (slot?.minY ?? (drag.pointer.y - drag.grabOffset)))
                .accessibilityHidden(true)
        }
    }
}
#endif

private struct RepeatPreviewStyle: ViewModifier {
    let isPreview: Bool
    func body(content: Content) -> some View {
        content.opacity(isPreview ? 0.65 : 1)
            .overlay {
                if isPreview { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.7, dash: [3, 2])).allowsHitTesting(false) }
            }
            .accessibilityHint(isPreview ? L("重复安排预览，点击查看原任务", "Repeat preview; open for the original task") : "")
    }
}
