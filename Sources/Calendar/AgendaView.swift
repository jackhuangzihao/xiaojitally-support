import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var mainContent: some View {
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
                }
                if !(selection == .calendar && planningView == "month"), selection != .trash { taskClipboardBar }
                if searchingCalendar && planningView != "list" {
                    calendarSearchResults
                } else if selection == .calendar && !searchingCalendar && planningView != "list" {
                    calendarGrid
                } else {
                #if os(iOS)
                iosTaskList
                #else
                if selection == .calendar && geometry.size.width >= 680 {
                    HStack(alignment: .top, spacing: 24) {
                        ScrollView { calendarPanel }.frame(width: 282)
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView { taskPanel }
                                .task(id: locateRequest) { await revealTask(using: proxy) }
                        }.frame(maxWidth: .infinity)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if selection == .calendar { calendarPanel; Divider() }
                                taskPanel
                            }
                        }.task(id: locateRequest) { await revealTask(using: proxy) }
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
            .contextMenu {
                if copiedTask != nil {
                    Button(L("粘贴到这一天…", "Paste on this day…")) { preparePaste(on: date) }
                    Button(L("粘贴为全天任务…", "Paste as all-day task…")) { preparePaste(on: date, allDay: true) }
                }
            }
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
        ScrollViewReader { proxy in
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
            .task(id: locateRequest) { await revealTask(using: proxy) }
        }
    }
    #endif

    private func revealTask(using proxy: ScrollViewProxy) async {
        guard let id = locatedTask else { return }
        // Allow the saved SwiftData row and a changed date/scope to reach List before locating it.
        do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
        guard locatedTask == id else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
    }

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

}

extension ContentView {
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
                                onCopy: { copyTask(task) },
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
        .id(task.id)
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
        let end = span.end == 1440 ? "24:00" : CalendarGridStyle.clockLabel(span.end)
        let range = CalendarGridStyle.clockLabel(span.start) + "–" + end
        let duration = Dates.durationLabel(minutes: span.end - span.start)
        return title + " · " + range + L(" · 共占用 \(duration)", " · \(duration) total")
    }

    /// Align free-time summaries with the cards rather than the time rail.
    private func freeRow(_ minutes: Int) -> some View {
        Text(L("空闲 ", "Free ") + Dates.durationLabel(minutes: minutes)).font(.caption).foregroundStyle(.tertiary)
            .padding(.leading, min(dayTimeWidth, 78) + 16).padding(.vertical, 4)
    }

}

extension ContentView {
    private var calendarGridData: CalendarGridData {
        CalendarGridData(tasks: tasks, lists: lists, filter: filter, currentDay: currentDay, locatedTask: locatedTask)
    }
    private var calendarGridActions: CalendarGridActions {
        CalendarGridActions(assign: assign, schedule: requestMove, clearDate: clearDate,
                            create: { date, timed in editor = EditorRequest(date: date, timed: timed) },
                            paste: { date, timed in
                                #if os(macOS)
                                if let copiedTask { pasteTask(copiedTask, at: date, timed: timed) }
                                #else
                                preparePaste(on: date, minute: timed ? Int(Dates.clockMinute(date)) : nil, allDay: !timed)
                                #endif
                            }, step: stepPeriod, today: goToToday)
    }
    private var calendarGridDetails: CalendarGridDetails {
        CalendarGridDetails(task: { AnyView(taskDetail($0, presentation: $1)) },
                            day: { AnyView(dayTasks($0, items: $1, presentation: $2)) },
                            copyMenu: { AnyView(taskCopyMenu($0)) })
    }
    private var calendarCovered: Bool { editor != nil || listEditor != nil || showingSettings || copyRequest != nil || confirmingDelete != nil }
    @ViewBuilder var calendarGrid: some View {
        if planningView == "month" {
            MonthCalendarView(data: calendarGridData, selectedDate: $selectedDate, assigning: assigning,
                              locateRequest: locateRequest, revealShift: monthRevealShift, slideForward: slideForward,
                              isPhone: isPhone, covered: calendarCovered, actions: calendarGridActions, details: calendarGridDetails)
        } else {
            WeekCalendarView(data: calendarGridData, selectedDate: $selectedDate, assigning: $assigning,
                             locateRequest: locateRequest, revealShift: revealShift, slideForward: slideForward,
                             isPhone: isPhone, covered: calendarCovered, actions: calendarGridActions, details: calendarGridDetails,
                             weekTitles: weekTitles, canPaste: copiedTask != nil, saveWeekTitle: saveWeekTitle)
        }
    }
}
