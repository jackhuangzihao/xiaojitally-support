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
                    Text(L("创建一项独立任务，保留时长、备注和子任务；原任务不变。", "Creates an independent task with the same duration, notes and subtasks. The original stays in place."))
                }
            }.formStyle(.grouped)
                .navigationTitle(L("粘贴任务", "Paste task"))
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
