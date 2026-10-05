import SwiftUI

/// Inputs shared by the two calendar grids. Each grid owns its interaction state.
@MainActor struct CalendarGridData {
    let tasks: [TaskItem]
    let lists: [TaskList]
    let filter: TaskFilter
    let currentDay: Date
    let locatedTask: UUID?

    func items(on date: Date, month: Bool, completed: Bool, repeats: Bool, cache: RepeatPreview) -> [TaskItem] {
        let cells = month ? Dates.monthCells(date) : Dates.weekCells(date)
        let range = DateInterval(start: cells[0], end: Dates.calendar.date(byAdding: .day, value: 1, to: cells.last!)!)
        let previews = repeats ? cache.items(tasks, in: range) : []
        return (tasks + previews).filter {
            $0.deletedAt == nil && (completed || !$0.isDone) && filter.matches($0, lists: lists, today: currentDay)
        }
    }

    func visiblePlanItems(_ items: [TaskItem], count: Int) -> [TaskItem] {
        var shown = Array(items.prefix(count))
        if count > 0, let target = items.first(where: { $0.id == locatedTask }), !shown.contains(where: { $0.id == target.id }) {
            shown[shown.count - 1] = target
        }
        return shown
    }
    func droppedTask(_ values: [String]) -> TaskItem? {
        guard values.count == 1, values[0].hasPrefix("jianshi-task:"), let id = UUID(uuidString: String(values[0].dropFirst(13))) else { return nil }
        return tasks.first { $0.id == id && $0.deletedAt == nil }
    }
    func locatedMinute(days: [Date], selectedDate: Date) -> Int? {
        guard let id = locatedTask, let task = tasks.first(where: { $0.id == id }), let clock = task.clockDate,
              days.contains(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) else { return nil }
        let minute = Dates.sameDay(clock, selectedDate) ? Int(Dates.clockMinute(clock)) : 0
        return max(0, min(1380, minute / 60 * 60 - 60))
    }
}

/// All mutations return to the window's existing save/undo/conflict-validation path.
struct CalendarGridActions {
    let assign: (UUID, Date) -> Void
    let schedule: (TaskItem, Date, TaskMove.Kind, Date?, Bool) -> Void
    let clearDate: (TaskItem) -> Void
    let create: (Date, Bool) -> Void
    let paste: (Date, Bool) -> Void
    let step: (Int) -> Void
    let today: () -> Void
}

/// Type erasure is limited to popup/menu boundaries, keeping large detail trees out of grid values.
struct CalendarGridDetails {
    let task: (TaskItem, CalendarPresentation) -> AnyView
    let day: (Date, [TaskItem], CalendarPresentation) -> AnyView
    let copyMenu: (TaskItem) -> AnyView
}

enum CalendarGridStyle {
    static func color(_ task: TaskItem) -> Color {
        ListColor.color(task.calendarList?.id, hex: task.calendarList?.colorHex)
    }
    static func detailID(_ task: TaskItem, day: Date, allDay: Bool = false) -> String {
        "\(task.id.uuidString)|\(Int(Dates.calendar.startOfDay(for: day).timeIntervalSince1970))|\(allDay)"
    }
    static func clockLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

struct CalendarCompletedSwitch: View {
    @AppStorage("showPlanningCompleted") private var completed = true
    var body: some View {
        Toggle(L("显示已完成", "Show completed"), isOn: $completed)
            .toggleStyle(.switch).controlSize(.mini).font(.caption).foregroundStyle(.secondary).fixedSize()
    }
}

/// Observe presentation events outside layout calculation. Teardown also removes native drag monitors.
struct CalendarGridLifecycle: ViewModifier {
    let drag: WeekDrag
    let presentation: CalendarPresentation
    let locateRequest: UUID
    let covered: Bool

    func body(content: Content) -> some View {
        content.environment(drag)
            .onDisappear { presentation.close(); _ = drag.finish() }
            .onChange(of: locateRequest) { _, _ in presentation.close(); drag.releaseHeldScroll() }
            .onChange(of: covered) { _, value in if value { presentation.close(); _ = drag.finish() } }
            .onChange(of: Store.recovery.failure) { _, value in
                if value != nil { presentation.close(); _ = drag.finish() }
            }
    }
}

struct CalendarFreeTimeSummary: View {
    let blocks: [PlanBlock]
    let selectedDate: Date
    var body: some View { TimelineView(.everyMinute) { clock in summary(now: clock.date) } }
    private func summary(now: Date) -> some View {
        let planned = blocks.filter { $0.task.duration != nil }
        let day = Dates.label(selectedDate, pattern: "M月d日")
        var text: String
        if let span = PlanBlock.countedSpan(day: selectedDate, now: now) {
            if span.start >= span.end {
                text = L("\(day) 今天已没有可安排的时段", "\(day): nothing left to plan today")
            } else {
                let result = PlanBlock.freeTime(planned, from: span.start, to: span.end)
                let range = CalendarGridStyle.clockLabel(span.start) + "–" + CalendarGridStyle.clockLabel(span.end)
                text = L("\(day) \(range) 未安排 \(Dates.durationLabel(minutes: result.free))", "\(day): \(Dates.durationLabel(minutes: result.free)) unplanned, \(range)")
                #if os(macOS)
                if let longest = result.longest, longest.end - longest.start >= 30, result.free != span.end - span.start {
                    text += L(" · 最长 \(CalendarGridStyle.clockLabel(longest.start))–\(CalendarGridStyle.clockLabel(longest.end))", " · longest \(CalendarGridStyle.clockLabel(longest.start))–\(CalendarGridStyle.clockLabel(longest.end))")
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
}

/// A successful cross-page drop is already showing its destination; preserve scroll identity.
enum CalendarPageIdentity {
    static func week(_ date: Date, revealed: Int) -> Date {
        Dates.calendar.date(byAdding: .day, value: -7 * revealed, to: Dates.weekCells(date)[0])!
    }
    static func month(_ date: Date, revealed: Int) -> Date {
        Dates.shiftMonth(Dates.monthStart(date), by: -revealed)
    }
}
