import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

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
struct CalendarTaskPopover<Detail: View>: ViewModifier {
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

struct CalendarDayPopover<Detail: View>: ViewModifier {
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
