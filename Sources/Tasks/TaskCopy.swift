import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

struct TaskCopyRequest: Identifiable {
    let id = UUID()
    let record: TaskBackup.TaskRecord
    let moment: Date
    let timed: Bool

    init(record: TaskBackup.TaskRecord, on day: Date, minute: Int? = nil, allDay: Bool = false) {
        self.record = record
        let sourceTimed = record.scheduledAt != nil ? record.hasTime : record.dueHasTime
        timed = !allDay && (minute != nil || sourceTimed)
        let source = record.scheduledAt ?? record.dueAt
        let targetMinute = minute ?? source.map { Int(Dates.clockMinute($0)) } ?? 540
        moment = timed ? Dates.clockTime(on: day, minute: targetMinute, reference: source) : Dates.calendar.startOfDay(for: day)
    }
}

struct TaskCopySheet: View {
    let record: TaskBackup.TaskRecord
    let copy: (Date, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @State private var moment: Date
    @State private var timed: Bool
    @State private var didCopy = false

    init(record: TaskBackup.TaskRecord, moment: Date, timed: Bool, copy: @escaping (Date, Bool) -> Bool) {
        self.record = record; self.copy = copy
        _moment = State(initialValue: moment)
        _timed = State(initialValue: timed)
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
                    Text(L("保留备注、清单和子任务，完成状态重置；不复制重复规则或关联账单。指定时间时保留原时长，全天任务不保留时段。原任务不变。", "Keeps notes, list and subtasks; resets completion. Repeat rules and linked entries are not copied. Timed copies keep the duration; all-day copies have no time interval. The original is unchanged."))
                }
            }.formStyle(.grouped)
                .navigationTitle(L("粘贴任务", "Paste task"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("创建副本", "Create copy")) {
                            guard !didCopy else { return }
                            didCopy = true
                            if copy(moment, timed) { dismiss() }
                            else { didCopy = false }
                        }
                        .disabled(didCopy)
                        .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .onAppear { CloudSync.shared.editing(true) }
        .onDisappear { CloudSync.shared.editing(false) }
        .modifier(SaveRecoveryGuard())
        #if os(macOS)
        .frame(width: 420, height: 430)
        #endif
    }
}

#if os(iOS)
/// Location-aware long press on empty space. No timer or per-frame state lives in the calendar.
struct CalendarSlotInteraction: ViewModifier {
    let tap: (CGPoint) -> Void
    let pasteAt: (CGPoint) -> (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onTapGesture(coordinateSpace: .local, perform: tap)
                .gesture(SlotPastePress(actionAt: pasteAt))
        } else {
            content.gesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .exclusively(before: SpatialTapGesture())
                .onEnded { value in
                    switch value {
                    case .first(.second(true, let drag?)): pasteAt(drag.startLocation)?()
                    case .second(let event): tap(event.location)
                    default: break
                    }
                })
        }
    }
}

@available(iOS 18, *)
private struct SlotPastePress: UIGestureRecognizerRepresentable {
    let actionAt: (CGPoint) -> (() -> Void)?
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, actionAt: actionAt)
    }
    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let gesture = UILongPressGestureRecognizer()
        gesture.minimumPressDuration = 0.45
        gesture.allowableMovement = 10
        gesture.delegate = context.coordinator
        return gesture
    }
    func updateUIGestureRecognizer(_ gesture: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.actionAt = actionAt
    }
    func handleUIGestureRecognizerAction(_ gesture: UILongPressGestureRecognizer, context: Context) {
        guard gesture.state == .began else { return }
        actionAt(context.converter.localLocation)?()
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var actionAt: (CGPoint) -> (() -> Void)?
        init(converter: CoordinateSpaceConverter, actionAt: @escaping (CGPoint) -> (() -> Void)?) {
            self.converter = converter; self.actionAt = actionAt
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Reject task cards and the time gutter, preserving their own menus and drag recognizers.
            actionAt(converter.localLocation) != nil
        }
    }
}
#endif
