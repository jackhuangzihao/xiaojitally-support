import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

/// Window navigation and shared save/undo coordination. Week and month grids own their UI state.
struct ContentView: View {
    let drafts: EditorDrafts
    let recoveryGeneration: Int
    @State private var financeMode = false
    @State private var financeSelection = "all"
    @State private var windowReady = false
    @State var dragFeedback = DragFeedback()
    @AppStorage("appLanguage") var language = "system"
    @State var slideForward = true
    @AppStorage("planningView") var planningView = "list"
    @AppStorage("showPlanningCompleted") var showPlanningCompleted = true
    @AppStorage("showDayFreeTime") var showDayFreeTime = false
    @State var dayCompletedExpanded = false
    @ScaledMetric(relativeTo: .caption) var dayTimeWidth: CGFloat = 54
    @State var assigning: UUID?

    @State var filter = TaskFilter()
    @State private var repeatPreview = RepeatPreview()
    @State var history = TaskHistory()
    @AppStorage("showRepeatPreviews") var showRepeatPreviews = true
    @State var showingSettings = false
    @Environment(\.modelContext) var context
    @Query(sort: \TaskItem.createdAt) var tasks: [TaskItem]
    @Query(sort: \TaskList.createdAt) var lists: [TaskList]
    @Query(sort: \CalendarWeekTitle.week) var weekTitles: [CalendarWeekTitle]
    @State var undoCopy = false
    @State var copyRequest: TaskCopyRequest?
    @State var copiedTask: TaskBackup.TaskRecord?
    @AppStorage("initialListsCreated") private var initialListsCreated = false
    @State var selection: TaskScope = .calendar
    @FocusState private var sidebarFocused: Bool
    @State var selectedDate = Date()
    /// Weeks moved by dropping a task into another week. That week is already on screen, so the panel keeps its
    /// identity: no rebuild, no transition, and the grid stays at the same hours.
    @State var revealShift = 0

    /// A task waiting for "delete?" to be confirmed.
    @State var confirmingDelete: UUID?
    /// Months moved by dropping a task into another month, so the month panel is not rebuilt (see `revealShift`).
    @State var monthRevealShift = 0
    #if os(macOS)
    @State private var listDrag = ListDrag()
    /// Groups open in the sidebar. Kept here (not inside an outline) so a drag knows which rows are on screen.
    @State private var expandedLists: Set<UUID> = []
    #endif
    @ScaledMetric(relativeTo: .body) var calendarDayHeight: CGFloat = 48
    @State var wholeMonth = false
    #if os(iOS)
    @State var weekOnly = true
    #else
    @State var weekOnly = false
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State var currentDay = Date()
    @State var showAllEarlier = false
    @State var phoneOverdueExpanded = true
    @State var undoDeletedIDs: [UUID] = []
    @State var search = ""
    @State var locatedTask: UUID?
    @State var locateRequest = UUID()
    @State var editor: EditorRequest?
    @State var listEditor: ListRequest?
    @State var movedMessage: String?
    @State var moveFeedbackID = UUID()
    @State var undoSchedule: (id: UUID, before: TaskSchedule, after: TaskSchedule)?
    @State var undoListMove: (id: UUID, before: UUID?, after: UUID)?
    @AppStorage("overdueExpanded") var overdueExpanded = true
    @State var pendingMove: PendingMove?
    @State var deadlineMove: TaskMove?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var deletingList: TaskList?
    @AppStorage("hideCompletedInAll") var hideCompletedInAll = false
    @State var purgeIDs: Set<UUID>?
    @State var errorMessage: String?

    var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var overdueTasks: [TaskItem] {
        tasks.filter { $0.deletedAt == nil && $0.isOverdue(today: currentDay) }
            .sorted { ($0.calendarDate ?? .distantPast) < ($1.calendarDate ?? .distantPast) }
    }

    var title: String {
        if case .list(let id) = selection { return lists.first { $0.id == id }?.name ?? L("清单", "List") }
        return selection.title
    }

    // ponytail: filter personal task collections in memory; move filtering into FetchDescriptor for large archives.
    var visibleTasks: [TaskItem] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = Dates.calendar.dateInterval(of: wholeMonth ? .month : .day, for: selectedDate)!
        let matching = tasks.filter { task in
            guard (selection == .trash) == (task.deletedAt != nil) else { return false }
            let matches: Bool
            switch selection {
            case .calendar:
                // Searching from the calendar looks through every task, not only the selected day.
                matches = !needle.isEmpty || task.overlaps(range)
            case .all: matches = !(hideCompletedInAll && task.isDone && needle.isEmpty)
            case .trash: matches = true
            case .unscheduled: matches = task.calendarDate == nil
            case .completed: matches = task.isDone
            case .list(let id): matches = ListTree.contains(task.list?.id, in: id, lists: lists)
            }
            guard matches && (needle.isEmpty || CalendarTaskSearch.matches(task, query: needle, includeDeleted: selection == .trash)) else { return false }
            return filter.matches(task, lists: lists, today: currentDay)
        }
        if selection == .completed {
            return matching.sorted {
                if $0.completionSortDate != $1.completionSortDate { return $0.completionSortDate > $1.completionSortDate }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return TaskItem.ordered(matching)
    }

    var searchingCalendar: Bool {
        selection == .calendar && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hiddenCompletedCount: Int {
        guard selection == .all, hideCompletedInAll, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        return tasks.filter { $0.deletedAt == nil && $0.isDone }.count
    }

    var groups: [(date: Date, tasks: [TaskItem])] {
        Dictionary(grouping: visibleTasks) { task in
            if selection == .calendar && !wholeMonth && !searchingCalendar {
                return Dates.calendar.startOfDay(for: selectedDate)
            }
            return (selection == .completed ? task.completionSortDate : task.calendarDate).map { Dates.calendar.startOfDay(for: $0) } ?? .distantFuture
        }.map { (date: $0.key, tasks: $0.value) }.sorted { selection == .completed ? $0.date > $1.date : $0.date < $1.date }
    }

    var body: some View {
        editingContent
            .alert(L("操作未能保存", "Changes could not be saved"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L("知道了", "OK"), role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog(L("删除清单？任务会保留，子清单会移到上一级；重名时自动加序号。", "Delete this list? Tasks remain, and child lists move up one level. Duplicate names receive a number."), isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }), titleVisibility: .visible) {
                Button(L("删除清单，保留任务", "Delete list, keep tasks"), role: .destructive) {
                    guard let list = deletingList else { return }
                    let id = list.id
                    if commit({ ListTree.promoteChildren(of: list, lists: lists); context.delete(list) }), selection == .list(id) { selection = .all }
                    deletingList = nil
                }
            }
            .confirmationDialog(L("删除“\(confirmingDeleteTitle)”？", "Delete “\(confirmingDeleteTitle)”?"), isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
                Button(L("删除", "Delete"), role: .destructive) {
                    if let id = confirmingDelete, let task = tasks.first(where: { $0.id == id }) { deleteTask(task) }
                    confirmingDelete = nil
                }
                Button(L("取消", "Cancel"), role: .cancel) { confirmingDelete = nil }
            } message: { Text(L("删除后可以在“最近删除”中找回。", "You can bring it back from Recently deleted.")) }
            .confirmationDialog(purgeIDs?.count == 1 ? L("彻底删除这项任务？删除后无法恢复。", "Permanently delete this task? This can't be undone.") : L("彻底删除最近删除中的 \(purgeIDs?.count ?? 0) 项任务？删除后无法恢复。", "Permanently delete \(purgeIDs?.count ?? 0) tasks from Recently deleted? This can't be undone."), isPresented: Binding(get: { purgeIDs != nil }, set: { if !$0 { purgeIDs = nil } }), titleVisibility: .visible) {
                Button(L("彻底删除", "Delete permanently"), role: .destructive) {
                    guard let ids = purgeIDs else { return }
                    _ = commit { for task in tasks where ids.contains(task.id) && task.deletedAt != nil { context.delete(task) } }
                    undoDeletedIDs.removeAll { ids.contains($0) }
                    purgeIDs = nil
                }
            }
            .task { initializeWindow() }
            .onOpenURL { url in
                if let id = ReminderNavigation.taskID(url: url) {
                    drafts.reminder.pendingTaskID = id
                    openReminderIfReady()
                    return
                }
                #if os(macOS)
                guard url.scheme == "jianshi", Store.recovery.failure == nil else { return }
                guard editor == nil, listEditor == nil else { notify(L("请先完成当前编辑，再打开小组件中的任务。", "Finish the current edit before opening a widget task.")); return }
                if url.host == "today" {
                    showingSettings = false
                    selection = .calendar; planningView = "list"; selectedDate = Date(); wholeMonth = false; search = ""; filter = TaskFilter()
                } else if url.host == "all" {
                    showingSettings = false; selection = .all; hideCompletedInAll = true; search = ""; filter = TaskFilter()
                } else if let id = WidgetSnapshot.identifier(from: url, host: "list"), lists.contains(where: { $0.id == id }) {
                    showingSettings = false; selection = .list(id); search = ""; filter = TaskFilter()
                } else if let id = WidgetSnapshot.taskID(from: url), let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) {
                    showingSettings = false
                    selection = .calendar; search = ""; filter = TaskFilter(); locate(task)
                    editor = EditorRequest(task: task)
                }
                #endif
            }
            #if os(iOS)
            .onChange(of: ReminderInbox.shared.navigation.pendingTaskID, initial: true) { _, _ in receiveReminder() }
            #endif
            .onChange(of: language) { _, _ in
                #if os(macOS)
                if WidgetBridge.isEnabled { WidgetBridge.publish(context) }
                #endif
                ReminderScheduler.shared.refresh(context)
            }
            .modifier(SaveRecoveryGuard(active: editor == nil && listEditor == nil && copyRequest == nil && !showingSettings))
    }

    private var dragNavigation: some View {
        navigation
            .environment(dragFeedback)
            .onDisappear { dragFeedback.end() }
            // Plain lists have no native drop-session observer. Leaving their navigation scope
            // must clear a cancelled drag too; date changes stay excluded for edge paging.
            .onChange(of: selection) { _, _ in dragFeedback.end() }
            .onChange(of: planningView) { _, _ in dragFeedback.end() }
            .onChange(of: financeMode) { _, _ in dragFeedback.end() }
            .onChange(of: searchingCalendar) { _, _ in dragFeedback.end() }
            .onChange(of: wholeMonth) { _, _ in dragFeedback.end() }
    }

    private var editingContent: some View {
        dragNavigation
            #if os(macOS)
            .focusedSceneValue(\.taskHistory, financeMode ? nil : history)
            #endif
            .onChange(of: history.outcome) { _, value in if let value { notify(value) } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in refreshDay() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: RunLoop.main)) { _ in refreshDay() }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
                guard scenePhase == .active, CalendarClock.needsRefresh(from: currentDay, to: now, tasks: tasks) else { return }
                if !Dates.sameDay(currentDay, now) { selectedDate = Dates.selectionAfterDayChange(selectedDate, previousToday: currentDay, now: now) }
                currentDay = now
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshDay(); receiveReminder() }
                else { dragFeedback.end() }
            }
            .confirmationDialog(pendingMoveTitle, isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }), titleVisibility: .visible, presenting: pendingMove) { move in
                let plan = move.proposal
                if plan.canKeepDeadline, let due = plan.before.dueAt {
                    Button(L("截止仍为 \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))", "Keep deadline: \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))")) {
                        finishMove(move, shiftDeadline: false)
                        pendingMove = nil
                    }
                }
                if let due = plan.shiftedDeadline, due != plan.before.dueAt || !plan.canKeepDeadline {
                    Button(L("截止一起移到 \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))", "Move deadline to \(Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日"))")) {
                        finishMove(move, shiftDeadline: true)
                        pendingMove = nil
                    }
                }
                Button(L("取消", "Cancel"), role: .cancel) { pendingMove = nil }
            }

            .onChange(of: editor?.id) { _, value in if value == nil, recoveryGeneration == Store.recovery.generation { drafts.task = nil; drafts.taskID = nil } }
            .onChange(of: listEditor?.id) { _, value in if value == nil, recoveryGeneration == Store.recovery.generation { drafts.list = nil; drafts.listID = nil } }
            .onChange(of: Store.recovery.failure) { _, failure in
                guard failure != nil else { openReminderIfReady(); return }
                dragFeedback.end()
                #if os(macOS)
                listDrag.cancel()
                #endif
                pendingMove = nil; confirmingDelete = nil; deletingList = nil; purgeIDs = nil
            }
            .onChange(of: reminderAlertActive) { _, active in if !active { openReminderIfReady() } }
            .onChange(of: drafts.finance == nil && drafts.financeEntity == nil && !drafts.financePresentationActive) { _, finished in
                if finished { openReminderIfReady() }
            }
            .sheet(isPresented: $showingSettings, onDismiss: openReminderIfReady) { PreferencesView() }
            .sheet(item: $copyRequest, onDismiss: openReminderIfReady) { request in
                TaskCopySheet(record: request.record, moment: request.moment, timed: request.timed) { moment, timed in
                    pasteTask(request.record, at: moment, timed: timed)
                }
            }
            .sheet(item: $editor, onDismiss: openReminderIfReady) { request in
                TaskEditor(request: request, draft: drafts.task)
            }
            .sheet(item: $listEditor, onDismiss: openReminderIfReady) { request in ListEditor(list: request.list, parentID: request.parentID, draft: drafts.list) }
    }

    private var reminderAlertActive: Bool {
        pendingMove != nil || confirmingDelete != nil || deletingList != nil || purgeIDs != nil || errorMessage != nil
    }

    private func receiveReminder() {
        #if os(iOS)
        guard let id = ReminderInbox.shared.navigation.take(blocked: scenePhase != .active) else { return }
        drafts.reminder.pendingTaskID = id
        openReminderIfReady()
        #endif
    }

    private func openReminderIfReady() {
        let blocked = !windowReady || editor != nil || listEditor != nil || copyRequest != nil || showingSettings || reminderAlertActive
            || drafts.finance != nil || drafts.financeEntity != nil || drafts.financePresentationActive
            || Store.recovery.failure != nil || recoveryGeneration != Store.recovery.generation
        guard let id = drafts.reminder.take(blocked: blocked) else { return }
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else {
            errorMessage = L("这项任务已删除或不在当前设备上。", "This task was deleted or is not on this device.")
            return
        }
        financeMode = false
        assigning = nil; copyRequest = nil
        selection = .calendar; wholeMonth = false; search = ""; filter = TaskFilter()
        locate(task)
        editor = EditorRequest(task: task)
    }

    private func initializeWindow() {
        defer { windowReady = true; receiveReminder(); openReminderIfReady() }
        // The timeline and the multiweek overview became the week and month views.
        if planningView == "timeline" { planningView = "week" } else if planningView == "weeks" { planningView = "month" }
        restoreEditorDraft()
        do { try Store.save(context) } catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil }
        guard Store.recovery.failure == nil else { return }
        ReminderScheduler.shared.refresh(context)
        guard !initialListsCreated else { return }
        if lists.isEmpty {
            if commit({ [L("工作", "Work"), L("生活", "Personal"), L("学习", "Study")].enumerated().forEach { index, name in
                let list = TaskList(name: name)
                list.id = TaskItem.syncIdentity("tally-default-list-\(index)")
                list.createdAt = Date(timeIntervalSince1970: Double(index))
                context.insert(list)
            } }) {
                initialListsCreated = true
            }
        } else { initialListsCreated = true }
    }

    private func restoreEditorDraft() {
        if drafts.finance != nil || drafts.financeEntity != nil { financeMode = true; return }
        if drafts.task != nil {
            let task = tasks.first { $0.id == drafts.taskID }
            editor = EditorRequest(task: task)
        } else if let draft = drafts.list {
            let list = lists.first { $0.id == drafts.listID }
            listEditor = ListRequest(list: list, parentID: draft.parentID)
        }
    }

    private var selectedListID: UUID? {
        if case .list(let id) = selection { return id }
        return nil
    }

    @ViewBuilder var navigation: some View {
        #if os(macOS)
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                AppSectionPicker(finance: $financeMode)
                if financeMode { FinanceSidebar(selection: $financeSelection) } else {
                List(selection: Binding<TaskScope?>(get: { selection }, set: { if let value = $0 { selection = value } })) {
                    ForEach(TaskScope.standard, id: \.self) { scope in
                        Label(scope.localizedTitle(language), systemImage: scope.icon).tag(scope)
                    }
                    Section {
                            // One custom stack, not one native row per list: native sidebar rows clip anything moved
                            // outside their own bounds, so rows making way for a drag simply vanished.
                            SidebarListTree(nodes: ListNode.roots(lists), expanded: $expandedLists, drag: listDrag, selected: selectedListID) { node in
                                AnyView(
                                    ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji, isGroup: node.children != nil)
                                        .modifier(SidebarListRow(list: node.list, isGroup: node.children != nil, drag: listDrag, select: { selection = .list(node.id); sidebarFocused = true },
                                                                 blocked: { ListTree.contains($0, in: node.id, lists: lists) },
                                                                 drop: { target in dropList(node.id, on: target) }))
                                        .modifier(TaskDropHighlight(tint: ListColor.color(node.id, hex: node.list.colorHex),
                                            accepts: { id in tasks.contains { $0.id == id && $0.deletedAt == nil && $0.list?.id != node.id } },
                                            perform: { moveTask($0, toList: node.id) }))
                                        .contextMenu {
                                            Button(L("新建子清单", "New child list")) { listEditor = ListRequest(parentID: node.id) }
                                            Button(L("编辑清单", "Edit list")) { listEditor = ListRequest(list: node.list) }
                                            Button(L("删除清单", "Delete list"), role: .destructive) { deletingList = node.list }
                                        }
                                )
                            }
                    } header: {
                        HStack(spacing: 4) {
                            Text(L("我的清单", "My lists"))
                            Spacer(minLength: 0)
                            Button { listEditor = ListRequest() } label: {
                                Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .help(L("新建清单或分组", "New list or group"))
                            .accessibilityLabel(L("新建清单或分组", "New list or group"))
                        }
                        .modifier(SidebarListHeader(drag: listDrag))
                    }
                }
                .focused($sidebarFocused)
                .background(SidebarKeyboardNavigation { direction in
                    guard !listDrag.isDragging else { return false }
                    selection = selection.adjacentSidebarScope(direction: direction, lists: lists, expanded: expandedLists)
                    return true
                })
                }
                Label(CloudSync.shared.summary, systemImage: CloudSync.shared.enabled ? "icloud" : "internaldrive").font(.caption).foregroundStyle(.secondary).padding(16)
                }.padding(.top, 20)
                    .overlay(alignment: .topLeading) { ListDragFloatingRow(drag: listDrag) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listDrag.sidebar = $0 }
                    .onAppear {
                        listDrag.visibleRows = { visibleListIDs() }
                        listDrag.isDescendant = { child, parent in ListTree.contains(child, in: parent, lists: lists) }
                        listDrag.listName = { id in lists.first { $0.id == id }?.name ?? "" }
                        listDrag.descendantCount = { id in lists.filter { $0.id != id && ListTree.contains($0.id, in: id, lists: lists) }.count }
                        listDrag.depthOf = { id in
                            var depth = 0, parent = lists.first { $0.id == id }?.parentID
                            while let current = parent, depth < 64 { depth += 1; parent = lists.first { $0.id == current }?.parentID }
                            return depth
                        }
                        // Resting on a closed group while dragging opens it, so a list can go next to one of its children.
                        listDrag.openGroup = { id in
                            guard !expandedLists.contains(id), lists.contains(where: { $0.parentID == id }) else { return }
                            withAnimation(.easeOut(duration: 0.15)) { _ = expandedLists.insert(id) }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if financeMode {
                financeContent
            } else { taskContent }
        }
        #else
        TabView(selection: $financeMode) {
            NavigationStack { taskContent }
                .tabItem { Label(L("待办", "Tasks"), systemImage: "checklist") }.tag(false)
            NavigationStack { financeContent }
                .tabItem { Label(L("财务", "Finance"), systemImage: "wallet.pass") }.tag(true)
        }
        #endif
    }

    // A transient message floats inside the page, above its tab bar. Reserving a
    // safe-area strip for it would resize the calendar and move a drag's target.
    private var taskContent: some View {
        mainContent
            .overlay(alignment: .bottom) { taskNotice.padding(.bottom, 8) }
            .safeAreaInset(edge: .bottom, spacing: 0) { BackupStatusNotice { showingSettings = true } }
    }

    @ViewBuilder private var taskNotice: some View {
        if let id = assigning, let task = tasks.first(where: { $0.id == id }) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L("改期：\(task.title)", "Reschedule: \(task.title)"), systemImage: "calendar.badge.clock").lineLimit(1)
                    Text(L("点一个日期或时间段", "Tap a date or a time slot")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { assigning = nil } label: { Text(L("取消", "Cancel")).frame(minHeight: 44) }.fontWeight(.semibold)
            }.padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
                .frame(maxWidth: 480).padding(.horizontal, 12)
        } else if !undoDeletedIDs.isEmpty {
            MoveFeedback(message: L("已删除 \(undoDeletedIDs.count) 项", "Deleted \(undoDeletedIDs.count) tasks"),
                         canUndo: true, canShiftDeadline: false, shiftDeadline: {},
                         undo: undoDeletion, dismiss: { undoDeletedIDs = [] })
                .id(undoDeletedIDs).frame(maxWidth: 480).padding(.horizontal, 12)
        } else if let movedMessage {
            MoveFeedback(message: movedMessage, canUndo: undoSchedule != nil || undoListMove != nil || (undoCopy && history.canUndo),
                         canShiftDeadline: deadlineMove != nil && undoSchedule != nil, shiftDeadline: shiftMovedDeadline,
                         undo: { if undoCopy { history.undo() } else if undoListMove != nil { restoreListMove() } else { restoreSchedule() } },
                         dismiss: { self.movedMessage = nil; undoSchedule = nil; undoListMove = nil; deadlineMove = nil; undoCopy = false })
                .id(moveFeedbackID).frame(maxWidth: isPhone ? .infinity : 480)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: isPhone ? .center : .trailing)
        }
    }

    private var financeContent: some View {
        FinanceHome(selection: $financeSelection, openTask: { id in
            guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { errorMessage = L("关联任务已删除或不在本机。", "Linked task was deleted or is unavailable."); return }
            financeMode = false; editor = EditorRequest(task: task)
        }, settings: { showingSettings = true })
            .safeAreaInset(edge: .bottom, spacing: 0) { BackupStatusNotice { showingSettings = true } }
    }

    #if os(macOS)
    /// A list dropped into a group goes in; the group stays as it was, open or closed.
    private func dropList(_ id: UUID, on target: (list: UUID?, placement: ListTree.Placement)) {
        moveList(id, to: target.list.flatMap { id in lists.first { $0.id == id } }, placement: target.placement)
    }

    /// Rows on screen now: top-level lists, and the children of open groups.
    private func visibleListIDs() -> Set<UUID> {
        Set(ListNode.visibleIDs(ListNode.roots(lists), expanded: expandedLists))
    }
    #endif

    private func moveList(_ id: UUID, to target: TaskList?, placement: ListTree.Placement) {
        guard let list = lists.first(where: { $0.id == id }) else { return }
        do {
            try ListTree.move(list, to: target, placement: placement, lists: lists)
            _ = commit {}
        } catch { errorMessage = error.localizedDescription }
    }


}
