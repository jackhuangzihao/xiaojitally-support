import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    private var monthMinCell: CGFloat {
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

    @ViewBuilder private func monthCell(_ day: Date, index: Int, month: Date, items: [TaskItem], height: CGFloat) -> some View {
        if Dates.calendar.isDate(day, equalTo: month, toGranularity: .month) {
            monthDayCell(day, items: items, height: height)
                .modifier(WeekZoneHighlight(zone: .day(index)))
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1) }
                .accessibilityHidden(true)
        }
    }

    private func monthDayCell(_ day: Date, items: [TaskItem], height: CGFloat) -> some View {
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
    private func openPlan(_ day: Date, view: String) {
        presentation.day = nil
        slideForward = true
        selectedDate = day; wholeMonth = false
        planningView = view
    }

    /// A row in the day popover. Tapping it unfolds the note and subtasks in place, so nothing is hidden behind "edit".
    @ViewBuilder private func dayTaskRow(_ task: TaskItem) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task) }
        else { savedDayTaskRow(task) }
    }

}
