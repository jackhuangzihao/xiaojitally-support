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
        DateChoiceButton(label: navigatorLabel, date: $selectedDate)
        Button { stepPeriod(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel(nextLabel)
    }

    @ViewBuilder private var navigatorOptions: some View {
        Button(L("今天", "Today")) { goToToday() }.frame(minHeight: 44)

        if planningView == "list" {
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { weekOnly.toggle() } } label: {
                Image(systemName: "chevron.down.circle").rotationEffect(.degrees(weekOnly ? 0 : 180)).frame(width: 44, height: 44)
            }.help(weekOnly ? L("展开整月", "Show the whole month") : L("收起为一周", "Show one week"))
                .accessibilityLabel(weekOnly ? L("展开整月", "Show the whole month") : L("收起为一周", "Show one week"))
        }
    }

    private var navigatorLabel: String { Dates.label(selectedDate, pattern: "yyyy年M月") }

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
        let next: Date
        switch planningView {
        case "week": next = Dates.calendar.date(byAdding: .day, value: amount * 7, to: selectedDate)!
        case "month": next = Dates.shiftMonth(selectedDate, by: amount)
        default: next = weekOnly ? Dates.calendar.date(byAdding: .day, value: amount * 7, to: selectedDate)! : Dates.shiftMonth(selectedDate, by: amount)
        }
        withAnimation(reduceMotion || planningView == "list" ? nil : .easeInOut(duration: 0.28)) { selectedDate = next }
    }

    func goToToday() {
        let now = Date()
        locatedTask = nil
        slideForward = now > selectedDate
        withAnimation(reduceMotion || planningView == "list" ? nil : .easeInOut(duration: 0.28)) { selectedDate = now }
        wholeMonth = false; search = ""; locateRequest = UUID()
    }
}

extension ContentView {
    var planningPicker: some View {
        Picker(L("日历视图", "Calendar view"), selection: $planningView) {
            Text(L("日", "Day")).tag("list")
            Text(L("周", "Week")).tag("week")
            Text(L("月", "Month")).tag("month")
        }.pickerStyle(.segmented)
            .onChange(of: planningView) { _, _ in wholeMonth = false }
    }

    var calendarDisplayMenu: some View {
        Menu {
            if planningView == "list" {
                Toggle(L("显示空闲时段", "Show free time"), isOn: $showDayFreeTime)
                    .disabled(wholeMonth || searchingCalendar)
            } else {
                Toggle(L("显示已完成", "Show completed"), isOn: $showPlanningCompleted)
                Toggle(L("预览重复安排", "Preview repeats"), isOn: $showRepeatPreviews)
            }
        } label: {
            Label(L("显示", "Display"), systemImage: "slider.horizontal.3")
                .font(isPhone ? .callout : .caption)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                .padding(.horizontal, isPhone ? 10 : 4)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
            .menuIndicator(.hidden).fixedSize()
    }
    func planColor(_ task: TaskItem) -> Color {
        ListColor.color(task.calendarList?.id, hex: task.calendarList?.colorHex)
    }
}

struct CalendarPeriodNavigator: View {
    @Binding var date: Date
    let displayedDate: Date
    let week: Bool
    let isPhone: Bool
    var zoom: Binding<Double>? = nil
    var zoomLevel: Double = 1
    var dragging = false
    let step: (Int) -> Void
    let today: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                steps
                Spacer(minLength: 10)
                #if os(macOS)
                PlanHint(month: !week).layoutPriority(-1)
                Spacer(minLength: 10)
                #endif
                options
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) { steps; Spacer(minLength: 0) }
                HStack(spacing: 2) { options; Spacer(minLength: 0) }
            }
        }.buttonStyle(.borderless)
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
    }
    private var steps: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(week ? L("上一周", "Previous week") : L("上个月", "Previous month"))
            PeriodChoiceButton(label: label, date: $date, week: week)
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel(week ? L("下一周", "Next week") : L("下个月", "Next month"))
        }
    }
    @ViewBuilder private var options: some View {
        Button(L("今天", "Today"), action: today).frame(minHeight: 44)
        if let zoom {
            Menu {
                ForEach([25, 50, 75, 100, 125, 150], id: \.self) { percent in
                    Button { zoom.wrappedValue = Double(percent) / 100 } label: {
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
                .disabled(dragging)
        }

    }
    private var label: String {
        guard week else { return Dates.label(displayedDate, pattern: "yyyy年M月") }
        let days = Dates.weekCells(displayedDate)
        if isPhone { return Dates.label(days[0], pattern: "M/d") + " – " + Dates.label(days[6], pattern: "M/d") }
        let sameMonth = Dates.calendar.isDate(days[0], equalTo: days[6], toGranularity: .month)
        return Dates.label(days[0], pattern: "M月d日") + " – " + Dates.label(days[6], pattern: sameMonth ? "d日" : "M月d日")
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
