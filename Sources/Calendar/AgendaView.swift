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
                    if isPhone {
                        planningPicker.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        HStack(spacing: 12) {
                            if planningView != "month" { taskClipboardMenu }
                            Spacer(minLength: 0)
                            filterMenu
                            calendarDisplayMenu
                        }
                    } else {
                        HStack {
                            planningPicker.frame(width: 260)
                            Spacer(minLength: 12)
                            filterMenu
                            calendarDisplayMenu
                        }
                    }
                    if filter.isActive {
                        HStack {
                            Text(filterSummary).font(.caption).foregroundStyle(.secondary).lineLimit(isPhone ? 2 : nil)
                            Button(L("清除", "Clear")) { filter = TaskFilter() }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                if !(isPhone && selection == .calendar), !(selection == .calendar && planningView == "month"), selection != .trash { taskClipboardBar }
                if searchingCalendar && planningView != "list" {
                    calendarSearchResults
                } else if selection == .calendar && !searchingCalendar && planningView != "list" {
                    calendarGrid.padding(.horizontal, isPhone && planningView == "week" ? -8 : 0)
                } else {
                #if os(iOS)
                VStack(spacing: 8) {
                    if isPhone && selection == .calendar && !searchingCalendar {
                        VStack(spacing: 2) { phoneCalendarRows }
                    }
                    iosTaskList
                }
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
            }.padding(.horizontal, geometry.size.width > 600 ? 28 : 16)
                .padding(.vertical, isPhone ? 8 : geometry.size.width > 600 ? 28 : 16)
            .background(Color.appBackground)
        }
        .task(id: locateRequest) {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            locatedTask = nil
        }
        #if os(iOS)
        .modifier(PhoneWorkspaceToolbar(text: $search,
            prompt: selection == .calendar ? L("搜索全部任务", "Search all tasks") : L("搜索当前范围的任务", "Search tasks in this view"), scope: selection,
            settings: { showingSettings = true }, add: addTask, addLabel: L("新建任务", "New task")))
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
            #else
            ToolbarItem(placement: .primaryAction) {
                Button { showingSettings = true } label: { Label(L("设置", "Settings"), systemImage: "gearshape") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: addTask) { Label(L("新建任务", "New task"), systemImage: "plus") }
                    .labelStyle(.titleAndIcon).buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
            #endif
        }
        .onChange(of: selection) { _, scope in
            search = ""; filter = TaskFilter()
            // Opening the calendar is part of assignment; leaving it cancels assignment.
            if scope != .calendar { assigning = nil }
        }
    }

    private var calendarPanel: some View { agendaDatePicker(compact: false) }

    private func agendaDatePicker(compact: Bool) -> some View {
        AgendaDatePicker(tasks: tasks, selectedDate: selectedDate, currentDay: currentDay,
                         weekOnly: weekOnly, isPhone: isPhone, compact: compact, calendarDayHeight: calendarDayHeight,
                         canPaste: copiedTask != nil, showOverdue: !overdueTasks.isEmpty,
                         selectDate: { date in
                             if let id = assigning { assign(id, to: date) } else { selectedDate = date; wholeMonth = false }
                         }, paste: { date, allDay in preparePaste(on: date, allDay: allDay) },
                         move: { task, date in requestMove(task, to: date, kind: .day, revealDate: date) },
                         selectedDateChanged: { search = "" }, navigator: {
                             if compact { dateNavigator.taskDragPage(onStep: stepPeriod) } else { dateNavigator }
                         }, overdue: { overdueSection(overdueTasks) })
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
                        HStack(spacing: 6) {
                            Text(Dates.label(selectedDate, pattern: wholeMonth ? "M月安排" : "M月d日 EEEE"))
                                .font(isPhone ? .headline : .title2.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            if !wholeMonth && Dates.sameDay(selectedDate, currentDay) {
                                Text(L("今天", "Today")).tagStyle(.accentColor)
                            }
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        }.foregroundStyle(Color.primary).frame(minHeight: 44)
                    }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("查看范围", "View range"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(searchingCalendar ? L("搜索结果", "Search results") : selection == .calendar ? Dates.label(selectedDate, pattern: wholeMonth ? "M月安排" : "M月d日 EEEE") : title)
                        .font(.title3.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if selection != .calendar { filterMenu }
                    Text(L("\(visibleTasks.count) 项", "\(visibleTasks.count) \(visibleTasks.count == 1 ? "task" : "tasks")")
                         + (hiddenCompletedCount > 0 ? L(" · 已隐藏 \(hiddenCompletedCount) 项已完成", " · \(hiddenCompletedCount) completed hidden") : ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if selection != .calendar && filter.isActive {
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
    private var phoneCalendarRows: some View { agendaDatePicker(compact: true) }

    private var iosTaskList: some View {
        ScrollViewReader { proxy in
        List {
            if selection == .calendar && !searchingCalendar {
                if !isPhone {
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
                            .listRowInsets(isPhone ? EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0) : EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.date) { group in
                        Text(Dates.groupLabel(group.date, today: currentDay))
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                        ForEach(group.tasks) { task in taskRow(task) }
                    }
                }
            }
            }
            }

    private func taskRow(_ task: TaskItem) -> some View {
        taskRowBody(task)
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

    private var monthAgendaRows: some View {
        MonthAgendaRows(groups: groups, isEmpty: visibleTasks.isEmpty, currentDay: currentDay) { task in
            dayTimelineTask(task, timed: false, showTime: true)
        }
    }

    private var dayTimelineRows: some View {
        DayAgendaRows(items: visibleTasks, occupying: tasks, selectedDate: selectedDate,
                      isPhone: isPhone, showDayFreeTime: showDayFreeTime,
                      dayCompletedExpanded: $dayCompletedExpanded, addTask: addTask) { task, layout in
            dayTimelineTask(task, timed: layout.timed, gap: layout.gap, overlap: layout.overlap)
        }
    }

    private func dayTimelineTask(_ task: TaskItem, timed: Bool, showTime: Bool = false,
                                 gap: Int? = nil, overlap: String? = nil) -> some View {
        AgendaTaskLayout(task: task, selectedDate: selectedDate, timed: timed, dayTimeWidth: dayTimeWidth,
                         accessiblePhone: isPhone && dynamicTypeSize.isAccessibilitySize, gap: gap, overlap: overlap) {
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
                            },
                            money: taskMoney.summary(for: task.id), moneyCurrency: taskMoney.baseCurrency)
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
