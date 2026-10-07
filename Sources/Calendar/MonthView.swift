import SwiftUI

struct MonthCalendarView: View {
    let data: CalendarGridData
    @Binding var selectedDate: Date
    let assigning: UUID?
    let locateRequest: UUID
    let revealShift: Int
    let slideForward: Bool
    let isPhone: Bool
    let covered: Bool
    let actions: CalendarGridActions
    let details: CalendarGridDetails
    @State private var presentation = CalendarPresentation()
    @State private var weekDrag = WeekDrag()
    @State private var repeatPreview = RepeatPreview()
    @AppStorage("showPlanningCompleted") private var showPlanningCompleted = true
    @AppStorage("showRepeatPreviews") private var showRepeatPreviews = true
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func stepPeriod(_ amount: Int) {
        weekDrag.releaseHeldScroll(); presentation.close(); actions.step(amount)
    }
    private func today() {
        weekDrag.releaseHeldScroll(); presentation.close(); actions.today()
    }
    private var pageTransition: AnyTransition { .push(from: slideForward ? .trailing : .leading) }
    private var planTrailing: CGFloat { 0 }
    private var previewMonthDate: Date { Dates.shiftMonth(selectedDate, by: weekDrag.weekOffset) }
    private var planningTasks: [TaskItem] {
        data.items(on: previewMonthDate, month: true, completed: showPlanningCompleted, repeats: showRepeatPreviews, cache: repeatPreview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalendarPeriodNavigator(date: $selectedDate, displayedDate: previewMonthDate, week: false, isPhone: isPhone,
                                    step: stepPeriod, today: today)
            ZStack {
                monthPanel.id(CalendarPageIdentity.month(selectedDate, revealed: revealShift)).transition(pageTransition)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                .modifier(PageSwipe { if !weekDrag.isDragging { stepPeriod($0) } })
        }.modifier(CalendarGridLifecycle(drag: weekDrag, presentation: presentation, locateRequest: locateRequest, covered: covered))
    }
    private func dropOnDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = data.droppedTask(values) else { return false }
        actions.schedule(task, day, .day, nil, false); return true
    }
    private func monthDrop(_ task: TaskItem, _ zone: WeekDropGeometry.Zone, _ offset: Int) {
        if zone == .undated { actions.clearDate(task); return }
        guard case .day(let index) = zone else { return }
        let cells = Dates.monthCells(Dates.shiftMonth(selectedDate, by: offset))
        guard cells.indices.contains(index) else { return }
        actions.schedule(task, cells[index], .day, offset == 0 ? nil : cells[index], offset != 0)
    }

    private var monthMinCell: CGFloat {
        #if os(macOS)
        86
        #else
        64
        #endif
    }

    /// Written out in full: an icon alone did not say what it switched.


    private var monthPanel: some View {
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
                CalendarCompletedSwitch()
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
                    .calendarScrollProbe(weekDrag)
                }
                .scrollDisabled(height * CGFloat(rows) <= geometry.size.height + 1)
                .reportWeekFrame { weekDrag.monthViewport = $0 }
            }
            // The strip right of Sunday is where "next month" starts, like in the week view.
            .padding(.trailing, planTrailing)
        }
        .weekDragPanel(weekDrag)
        .mobileCalendarDrag(drag: weekDrag, enabled: !covered && presentation.taskKey == nil && presentation.day == nil)
        .onAppear { weekDrag.touchEdges = isPhone }
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
        let today = Dates.sameDay(day, data.currentDay)
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
            ForEach(data.visiblePlanItems(items, count: shown)) { monthChip($0, day: day, height: line - 2) }
            if items.count > shown {
                Button("+\(items.count - shown)") { selectedDate = day; presentation.showDay(day) }.font(.caption2).buttonStyle(.plain)
                    .accessibilityLabel(L("查看当天全部任务", "Show all tasks for this day"))
            }
            Spacer(minLength: 0)
        }.padding(3)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear)
            .overlay { if data.locatedTask != nil && items.contains(where: { $0.id == data.locatedTask }) { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1) }
            .opacity(inMonth ? 1 : 0.55)
            .contentShape(Rectangle())
            .onTapGesture {
                if let id = assigning { actions.assign(id, day) }
                else { selectedDate = day; presentation.showDay(day) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("\(Dates.label(day))，\(items.count) 项", "\(Dates.label(day)), \(items.count)"))
            .accessibilityAddTraits(.isButton)
            #if os(macOS)
            .dayDrop { dropOnDay($0, day) }
            #endif
            .modifier(CalendarDayPopover(presentation: presentation, day: day) { details.day(day, planningTasks, presentation) })
    }

    @ViewBuilder private func monthChip(_ task: TaskItem, day: Date, height: CGFloat) -> some View {
        let color = CalendarGridStyle.color(task)
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
        let key = CalendarGridStyle.detailID(task, day: day, allDay: true)
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .overlay { if data.locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .help([task.title, task.calendarList.map { ListTree.path($0, lists: data.lists) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(prefix + task.title + (task.priority == 2 ? L("，高优先级", ", high priority") : task.priority == 1 ? L("，中优先级", ", medium priority") : ""))
            .accessibilityAction { presentation.showTask(key) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { details.task(task, presentation) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 0 }, month: selectedDate, drop: monthDrop))
        #else
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .overlay { if data.locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .contentShape(Rectangle())
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 0 }, month: selectedDate, drop: monthDrop))
        #endif
    }
}
