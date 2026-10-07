import SwiftUI

/// Date selection renders the supplied task counts and delegates changes to the window.
struct AgendaDatePicker<Navigator: View, Overdue: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let tasks: [TaskItem]
    let selectedDate: Date
    let currentDay: Date
    let weekOnly: Bool
    let isPhone: Bool
    let compact: Bool
    let calendarDayHeight: CGFloat
    let canPaste: Bool
    let showOverdue: Bool
    let selectDate: (Date) -> Void
    let paste: (Date, Bool) -> Void
    let move: (TaskItem, Date) -> Void
    let selectedDateChanged: () -> Void
    @ViewBuilder let navigator: () -> Navigator
    @ViewBuilder let overdue: () -> Overdue

    var body: some View {
        #if os(iOS)
        if compact { phoneRows } else { panel }
        #else
        panel
        #endif
    }

    private var panel: some View {
        let active = tasks.filter { $0.deletedAt == nil }
        // The dot counts what is still to do; a day whose tasks are all finished keeps a hollow dot.
        let days = weekOnly ? Dates.weekCells(selectedDate) : Dates.monthCells(selectedDate)
        let byDay = CalendarIndex.byDay(active, days: days)
        let counts = byDay.mapValues { $0.filter { !$0.isDone }.count }
        let planned = Set(byDay.filter { !$0.value.isEmpty }.keys)
        return VStack(alignment: .leading, spacing: 12) {
            navigator()
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
            if !isPhone && showOverdue { overdue() }
        }.onChange(of: selectedDate) { _, _ in selectedDateChanged() }
    }

    private func dayCell(_ date: Date, count: Int, planned: Bool) -> some View {
        let selected = Dates.sameDay(date, selectedDate)
        let today = Dates.sameDay(date, currentDay)

        let inMonth = Dates.calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        if !isPhone && !weekOnly && !inMonth { return AnyView(Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true)) }
        return AnyView(Button {
            selectDate(date)
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
            .contextMenu {
                if canPaste {
                    Button(L("粘贴到这一天…", "Paste on this day…")) { paste(date, false) }
                    Button(L("粘贴为全天任务…", "Paste as all-day task…")) { paste(date, true) }
                }
            }
            .accessibilityLabel(L("\(Dates.label(date))，\(count)项未完成\(count == 0 && planned ? "，全部已完成" : "")\(today ? "，今天" : "")", "\(Dates.label(date)), \(count) unfinished\(count == 0 && planned ? ", all done" : "")\(today ? ", today" : "")"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(L("实心圆点是未完成的任务，空心代表当天已全部完成；描边代表今天。可拖动任务到这里改期。", "A solid dot counts unfinished tasks, a hollow one means all done; the outline marks Today. Drop a task here to reschedule."))
            .dayDrop(warn: { id in tasks.first { $0.id == id }?.deadlineConflict(movingTo: date) == true }) { values in
                guard values.count == 1, values[0].hasPrefix("jianshi-task:"), let id = UUID(uuidString: String(values[0].dropFirst(13))),
                      let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
                move(task, date)
                return true
            }
        )
    }

    #if os(iOS)
    private var phoneRows: some View {
        let active = tasks.filter { $0.deletedAt == nil }
        let days = Dates.monthCells(selectedDate)
        let byDay = CalendarIndex.byDay(active, days: days)
        let selectedWeek = Dates.weekCells(selectedDate)[0]
        let weeks = stride(from: 0, to: days.count, by: 7).map { days[$0] }
        return Group {
            navigator()
            HStack(spacing: 0) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.top, 6)
            // Keep date destinations above the task list while dragging. The selected
            // week retains its identity when the month is expanded or collapsed.
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
        .onChange(of: selectedDate) { _, _ in selectedDateChanged() }
    }

    #endif
}
