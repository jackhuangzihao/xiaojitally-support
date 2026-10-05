import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var dateNavigator: some View {
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

    func stepPeriod(_ amount: Int) {
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
}

extension ContentView {
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
    var previewMonthDate: Date { Dates.shiftMonth(selectedDate, by: weekDrag.weekOffset) }

    var previewWeekDate: Date {
        Dates.calendar.date(byAdding: .day, value: weekDrag.weekOffset * 7, to: selectedDate)!
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
    @Environment(\.dismiss) var dismiss
    @State private var year: Int
    @State var month: Int

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
