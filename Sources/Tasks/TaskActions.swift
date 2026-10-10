import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

struct PendingMove {
    let proposal: TaskMove
    var revealDate: Date?
    var revealMonth = false
}

extension ContentView {
    var pendingMoveTitle: String {
        guard let plan = pendingMove?.proposal, let due = plan.before.dueAt else { return "" }
        var target = Dates.label(plan.start, pattern: plan.timed ? "M月d日 HH:mm" : "M月d日")
        if plan.timed, let end = plan.end {
            target += " → " + Dates.label(end, pattern: Dates.sameDay(plan.start, end) ? "HH:mm" : "M月d日 HH:mm")
        }
        let old = Dates.label(due, pattern: plan.before.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        return L("安排改为 \(target)\n当前截止：\(old)", "Schedule for \(target)\nCurrent deadline: \(old)")
            + (plan.canKeepDeadline ? "" : L("\n新安排晚于截止，需要一起调整。", "\nThe new schedule is after the deadline; move the deadline too."))
    }

    func refreshDay() {
        let now = Date()
        selectedDate = Dates.selectionAfterDayChange(selectedDate, previousToday: currentDay, now: now)
        currentDay = now
        ReminderScheduler.shared.refresh(context)
    }

    func toggleCompletion(_ task: TaskItem) {
        let completing = !task.isDone
        guard commit({ task.toggleCompletion(in: context) }) else { return }
        if completing { offerSettlement(for: task) }
        else if settlementOffer?.taskID == task.id { settlementOffer = nil }
    }

    /// Rule 1: completing a task with pending entries offers to post them. Without any, completion stays silent.
    private func offerSettlement(for task: TaskItem) {
        guard let money = taskMoney.summary(for: task.id), money.pendingCount > 0 else { return }
        let pending = money.lines.filter(\.pending)
        let hidden = UserDefaults.standard.bool(forKey: "hideMoney")
        // One total only when every pending entry is in the same currency.
        let total = Set(pending.map(\.currency)).count == 1
            ? " " + Money.display(pending.reduce(0) { $0 + $1.amount }, pending[0].currency, hidden: hidden) : ""
        settlementOffer = SettlementOffer(
            taskID: task.id,
            message: L("已完成“\(task.title)” · 有 \(pending.count) 笔待入账", "Completed “\(task.title)” · \(pending.count) pending") + total,
            buttonTitle: pending.count == 1 ? L("确认入账", "Post") : L("确认入账（\(pending.count) 笔）", "Post \(pending.count)"))
    }

    /// Posts the offer's entries as they are now: some may have been posted or changed in Finance meanwhile.
    func confirmSettlement(_ offer: SettlementOffer) {
        settlementOffer = nil
        var outcome = TaskSettlement()
        do { try FinanceStore.update(context) { outcome = $0.settlePendingEntries(ofTask: offer.taskID) } }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil; return }
        if let first = outcome.needsReview.first {
            // Opened as a confirmation; one not due yet is dated today, as in the quick action.
            var draft = first
            if !first.isDueForConfirmation() { draft.date = MoneyEntry.timestamp(Date()) }
            settlementEditor = EntryRequest(entry: draft, expected: first, confirmingPending: true)
        }
        switch (outcome.posted.count, outcome.needsReview.count) {
        case (0, 0): notify(L("这些账单已经入账了", "These entries are already posted"))
        case (0, _): break
        case (let posted, 0): notify(L("已入账 \(posted) 笔", "Posted \(posted)"))
        case (let posted, let review): notify(L("已入账 \(posted) 笔，另有 \(review) 笔需要补充后确认", "Posted \(posted); \(review) need details first"))
        }
    }

    /// Rule 2: purging never deletes money. Linked entries are unlinked in the same save as the purge.
    func purgeTasks(_ ids: Set<UUID>) {
        let doomed = Set(tasks.filter { ids.contains($0.id) && $0.deletedAt != nil }.map(\.id))
        guard !doomed.isEmpty else { return }
        do {
            try Store.recovery.requireWritable(context)
            try FinanceStore.stageUnlinking(doomed, in: context)
        } catch {
            context.rollback()
            errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil
            return
        }
        // Purged tasks can't be undeleted; after a failed save they still exist, so keep their undo.
        guard commit({ for task in tasks where doomed.contains(task.id) { context.delete(task) } }) else { return }
        undoDeletedIDs.removeAll { ids.contains($0) }
    }

    /// " 它关联的 2 笔账单会保留。" for the delete dialogs; empty when no entries are linked.
    func linkedEntriesNote(_ ids: [UUID], purge: Bool) -> String {
        let count = ids.reduce(0) { $0 + (taskMoney.summary(for: $1)?.count ?? 0) }
        guard count > 0 else { return "" }
        return purge ? L("关联的 \(count) 笔账单会保留，只是不再关联任务。", "\(count) linked entries are kept, no longer linked to a task.")
            : L(" 它关联的 \(count) 笔账单会保留。", " Its \(count) linked entries are kept.")
    }

    func remindNow(_ task: TaskItem) {
        Task { @MainActor in
            do {
                guard try await ReminderScheduler.shared.authorize() else {
                    errorMessage = L("请在系统设置中允许通知后再试。", "Allow notifications in system settings, then try again."); return
                }
                guard !task.isDone, task.deletedAt == nil else { return }
                if commit({ task.reminderAt = Date().addingTimeInterval(5); task.reminderKind = ReminderPreset.custom.rawValue; task.reminderNeedsAttention = false }) {
                    notify(L("将在约 5 秒后提醒", "Reminder scheduled in about 5 seconds"))
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    var confirmingDeleteTitle: String {
        confirmingDelete.flatMap { id in tasks.first { $0.id == id }?.title } ?? ""
    }

    func deleteTask(_ task: TaskItem) {
        guard task.deletedAt == nil else { return }
        if commit({ task.deletedAt = Date() }) { undoDeletedIDs.append(task.id) }
    }

    func undoDeletion() {
        let ids = Set(undoDeletedIDs)
        if commit({ for task in tasks where ids.contains(task.id) { task.deletedAt = nil } }) { undoDeletedIDs = [] }
    }

    func addTask() {
        let listID: UUID? = { if case .list(let id) = selection { return id }; return nil }()
        editor = EditorRequest(date: selection == .calendar ? selectedDate : nil, listID: listID)
    }

    /// One date navigator for all three calendar views: the step just follows the view.
    /// It folds onto two rows beside a narrow month grid.
}

extension ContentView {
    func assign(_ id: UUID, to day: Date) {
        assigning = nil
        guard let task = tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        requestMove(task, to: day, kind: .day)
    }

    private func startAssigning(_ task: TaskItem) {
        assigning = task.id
        if selection != .calendar { selection = .calendar }
    }

    @ViewBuilder func taskMenu(_ task: TaskItem) -> some View {
        if selection != .trash {
            Button(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete")) { toggleCompletion(task) }
            Button(L("编辑…", "Edit…")) { editor = EditorRequest(task: task) }
            Button(L("改期到…", "Reschedule…")) { startAssigning(task) }
            taskCopyMenu(task)
            Button(L("删除…", "Delete…"), role: .destructive) { confirmingDelete = task.id }
        } else {
            Button(L("恢复任务", "Restore task")) { _ = commit { task.deletedAt = nil } }
            Button(L("彻底删除", "Delete permanently"), role: .destructive) { purgeIDs = [task.id] }
        }
    }

    @ViewBuilder func taskCopyMenu(_ task: TaskItem) -> some View {
        if !(selection == .calendar && planningView == "month"), task.previewSourceID == nil, task.deletedAt == nil {
            Button { copyTask(task) } label: { Label(L("复制", "Copy"), systemImage: "doc.on.doc") }
            if TaskBackup.TaskRecord(task).nextCopyDate != nil {
                Button { duplicateNext(task) } label: {
                    Label(task.clockDate == nil ? L("复制到下一天", "Duplicate to next day") : L("复制到下一时间段", "Duplicate to next interval"), systemImage: "plus.square.on.square")
                }
            }
        }
    }

    func copyTask(_ task: TaskItem) {
        guard task.previewSourceID == nil, task.deletedAt == nil else { return }
        copiedTask = TaskBackup.TaskRecord(task); assigning = nil
        movedMessage = nil // The clipboard control itself confirms the copy; avoid a second notice.

    }

    /// Both platforms copy the same immutable snapshot. A phone confirms the destination
    /// before saving, since a narrow seven-day column is not a precise pointer target.
    func preparePaste(on day: Date, minute: Int? = nil, allDay: Bool = false) {
        guard let copiedTask else { return }
        copyRequest = TaskCopyRequest(record: copiedTask, on: day, minute: minute, allDay: allDay)
    }

    /// Reuse the calendar's existing controls row on a phone instead of adding another header.
    @ViewBuilder var taskClipboardMenu: some View {
        if let copiedTask {
            Menu {
                Text(copiedTask.title)
                Button(L("粘贴到 ", "Paste on ") + Dates.label(selectedDate, pattern: "M月d日") + "…") { preparePaste(on: selectedDate) }
                Button(L("取消复制", "Cancel copy")) { self.copiedTask = nil }
            } label: {
                Label(L("粘贴", "Paste"), systemImage: "doc.on.clipboard")
                    .font(.callout).frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel(L("粘贴已复制的任务：", "Paste copied task: ") + copiedTask.title)
        }
    }

    @ViewBuilder var taskClipboardBar: some View {
        if let copiedTask {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(copiedTask.title, systemImage: "doc.on.doc")
                        .lineLimit(1)
                        .accessibilityLabel(L("已复制：", "Copied: ") + copiedTask.title)
                    Text(L("粘贴到 ", "Paste on ") + Dates.label(selectedDate, pattern: "M月d日"))
                        .foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Button(L("粘贴…", "Paste…")) { preparePaste(on: selectedDate) }
                    .font(.callout.weight(.medium)).frame(minHeight: 44)
                Button { self.copiedTask = nil } label: {
                    Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44)
                }.accessibilityLabel(L("清除已复制的任务", "Clear copied task"))
            }
            .buttonStyle(.borderless).padding(.leading, 10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func duplicateNext(_ task: TaskItem) {
        let record = TaskBackup.TaskRecord(task)
        guard let next = record.nextCopyDate, task.previewSourceID == nil, task.deletedAt == nil else { return }
        pasteTask(record, at: next, timed: task.clockDate != nil)
    }

    @discardableResult func pasteTask(_ record: TaskBackup.TaskRecord, at moment: Date, timed: Bool = true) -> Bool {
        let list = record.listID.flatMap { id in lists.first { $0.id == id } }
        var duplicate: TaskItem?
        guard commit({
            let task = record.duplicate(at: moment, timed: timed, list: list)
            context.insert(task); duplicate = task
        }), let duplicate else { return false }
        history.recordCopy(duplicate)
        // Only a successful paste consumes its snapshot. Cancellation/failure keeps it available.
        if copiedTask == record { copiedTask = nil }
        // A fresh copy is unfinished and dated: Completed/Unscheduled and old filters can hide it.
        if selection != .calendar || planningView == "month" { planningView = "list" }
        selection = .calendar; search = ""; filter = TaskFilter(); wholeMonth = false
        selectedDate = moment
        locatedTask = duplicate.id; locateRequest = UUID()
        notify(L("已复制到 \(Dates.label(moment, pattern: timed ? "M月d日 HH:mm" : "M月d日"))", "Copied to \(Dates.label(moment, pattern: timed ? "M月d日 HH:mm" : "M月d日"))"))
        undoCopy = true
        return true
    }

    func saveWeekTitle(_ title: String, week: String, original: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 80 else { errorMessage = L("周标题最多 80 个字符。", "Week titles can contain up to 80 characters."); return false }
        let row = weekTitles.first { $0.week == week }
        guard (row?.title ?? "") == original || row?.title == value else {
            errorMessage = L("这周的标题已在另一处更新，请重新打开该周后编辑。你的输入：\(value)", "This week's title changed elsewhere. Reopen the week before editing. Your draft: \(value)")
            return false
        }
        return commit {
            if value.isEmpty { if let row { context.delete(row) } }
            else if let row { row.title = value }
            else { context.insert(CalendarWeekTitle(week: week, title: value)) }
        }
    }

    var filterMenu: some View {
        Menu {
            Picker(L("清单", "List"), selection: $filter.list) {
                Text(L("全部清单", "All lists")).tag(TaskFilter.ListChoice.any)
                Text(L("未分类", "No list")).tag(TaskFilter.ListChoice.unfiled)
                ForEach(lists) { Text(ListTree.path($0, lists: lists)).tag(TaskFilter.ListChoice.list($0.id)) }
            }
            Picker(L("优先级", "Priority"), selection: $filter.priority) {
                Text(L("任何优先级", "Any priority")).tag(-1)
                Text(L("高", "High")).tag(2)
                Text(L("中", "Medium")).tag(1)
                Text(L("普通", "Normal")).tag(0)
            }
            Picker(L("时间", "Time"), selection: $filter.span) {
                ForEach(TaskFilter.Span.allCases) { Text($0.title).tag($0) }
            }
            if filter.isActive { Button(L("清除筛选", "Clear filters")) { filter = TaskFilter() } }
        } label: {
            Label(filter.isActive ? L("筛选 \(filter.count)", "Filters \(filter.count)") : L("筛选", "Filter"),
                  systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(isPhone ? .callout : .caption)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                .padding(.horizontal, isPhone ? 10 : 4)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }.menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("筛选任务", "Filter tasks"))
    }

    var filterSummary: String {
        var parts: [String] = []
        switch filter.list {
        case .any: break
        case .unfiled: parts.append(L("未分类", "No list"))
        case .list(let id): parts.append(lists.first { $0.id == id }.map { ListTree.path($0, lists: lists) } ?? L("已删除的清单", "Deleted list"))
        }
        if filter.priority >= 0 { parts.append([L("普通", "Normal"), L("中", "Medium"), L("高", "High")][filter.priority]) }
        if filter.span != .any { parts.append(filter.span.title) }
        return L("只看：", "Showing: ") + parts.joined(separator: " · ")
    }

    func commit(_ change: () -> Void) -> Bool {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return false }
        undoSchedule = nil; undoListMove = nil; deadlineMove = nil; undoCopy = false
        change()
        do { try Store.save(context); ReminderScheduler.shared.refresh(context); return true }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil; return false }
    }

    /// Saves a schedule change and offers to undo it. Dropping a task where it already was is not a change:
    /// no message and no undo.
    private func commitSchedule(_ task: TaskItem, before: TaskSchedule? = nil, _ change: () -> Void) -> Bool {
        let snapshot = before ?? TaskSchedule(task)
        guard commit(change) else { return false }
        guard TaskSchedule(task) != snapshot else { return false }
        history.record(task, before: .schedule(snapshot), after: .schedule(TaskSchedule(task)), name: L("时间调整", "Schedule change"), coalesce: before != nil)
        undoSchedule = (task.id, snapshot, TaskSchedule(task))
        moveFeedbackID = UUID()
        return true
    }

    /// A message that is not about a schedule change just made, so it never shows that change's undo button.
    func notify(_ message: String) {
        undoSchedule = nil; undoListMove = nil; deadlineMove = nil; undoCopy = false
        moveFeedbackID = UUID()
        movedMessage = message
    }

    func moveTask(_ values: [String], toList id: UUID) -> Bool {
        guard let task = droppedTask(values), let destination = lists.first(where: { $0.id == id }),
              task.list?.id != id else { return false }
        let before = task.list?.id
        guard commit({ task.changeList(to: destination) }) else { return false }
        history.record(task, before: .list(before), after: .list(id), name: L("分类调整", "List change"))
        undoListMove = (task.id, before, id)
        moveFeedbackID = UUID()
        movedMessage = L("已移到 ", "Moved to ") + ListTree.path(destination, lists: lists)
        return true
    }

    func restoreListMove() {
        guard let undo = undoListMove,
              let task = tasks.first(where: { $0.id == undo.id && $0.deletedAt == nil }), task.list?.id == undo.after else {
            notify(L("任务已再次修改，请在编辑中调整", "This task changed again; adjust it in the editor")); return
        }
        let original = lists.first { $0.id == undo.before }
        guard undo.before == nil || original != nil else {
            notify(L("原清单已删除，请在编辑中选择清单", "The original list was deleted; choose a list in the editor")); return
        }
        history.undo()
    }

    func shiftMovedDeadline() {
        guard let plan = deadlineMove, let undo = undoSchedule,
              plan.taskID == undo.id, plan.before == undo.before,
              let task = tasks.first(where: { $0.id == undo.id }),
              let due = plan.deferredDeadline(for: task, after: undo.after) else {
            notify(L("任务已再次修改，请在编辑中调整截止日期", "This task changed again; adjust its deadline in the editor")); return
        }
        // One Undo restores both the original arrangement and its original deadline.
        if commitSchedule(task, before: undo.before, { task.dueAt = due }) {
            movedMessage = L("截止已移到 ", "Deadline moved to ") + Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        }
    }

    func restoreSchedule() {
        guard let undo = undoSchedule, let task = tasks.first(where: { $0.id == undo.id && $0.deletedAt == nil }), TaskSchedule(task) == undo.after else {
            notify(L("任务已再次修改，请在编辑中调整", "This task changed again; adjust it in the editor")); return
        }
        history.undo()
    }
}

extension ContentView {
    func clearDate(_ task: TaskItem) {
        guard task.calendarDate != nil else { return }
        guard task.dueAt == nil, task.repeatRule == "none" else {
            notify(L("有截止日期或重复的任务不能去掉日期", "Tasks with a deadline or repeat keep their date")); return
        }
        if commitSchedule(task, { task.clearSchedule() }) { movedMessage = L("已去掉日期", "Date removed") }
    }

    func dropOnDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = droppedTask(values) else { return false }
        move(task, toDay: day)
        return true
    }

    func move(_ task: TaskItem, toDay day: Date, revealMonth: Bool = false) {
        requestMove(task, to: day, kind: .day, revealDate: revealMonth ? day : nil, revealMonth: revealMonth)
    }

    func droppedTask(_ values: [String]) -> TaskItem? {
        guard values.count == 1, values[0].hasPrefix("jianshi-task:"), let id = UUID(uuidString: String(values[0].dropFirst(13))) else { return nil }
        return tasks.first { $0.id == id && $0.deletedAt == nil }
    }
    private func revealWeek(_ date: Date) {
        let from = Dates.weekCells(selectedDate)[0], to = Dates.weekCells(date)[0]
        revealShift += (Dates.calendar.dateComponents([.day], from: from, to: to).day ?? 0) / 7
        selectedDate = date
    }

    func requestMove(_ task: TaskItem, to day: Date, kind: TaskMove.Kind, revealDate: Date? = nil, revealMonth: Bool = false) {
        let proposal = TaskMove(task, to: day, kind: kind)
        guard proposal.changesSchedule else { return }
        let move = PendingMove(proposal: proposal, revealDate: revealDate, revealMonth: revealMonth)
        if !proposal.canKeepDeadline { pendingMove = move }
        else { finishMove(move, shiftDeadline: false) }
    }

    func finishMove(_ move: PendingMove, shiftDeadline: Bool) {
        let plan = move.proposal
        guard let task = tasks.first(where: { $0.id == plan.taskID && $0.deletedAt == nil }),
              TaskSchedule(task) == plan.before, shiftDeadline || plan.canKeepDeadline else {
            notify(L("任务已更改，请重新拖动", "The task changed. Drag it again.")); return
        }
        guard commitSchedule(task, { plan.apply(to: task, shiftDeadline: shiftDeadline) }) else { return }
        if !shiftDeadline, let undo = undoSchedule, plan.deferredDeadline(for: task, after: undo.after) != nil { deadlineMove = plan }

        // Commit the destination page only after both confirmation and a successful save.
        if let date = move.revealDate {
            if move.revealMonth {
                monthRevealShift += Dates.calendar.dateComponents([.month], from: Dates.monthStart(selectedDate), to: Dates.monthStart(date)).month ?? 0
                selectedDate = date
            } else { revealWeek(date) }
        }
        movedMessage = plan.kind == .resizeStart || plan.kind == .resizeEnd
            ? L("已调整为 ", "Adjusted to ") + task.timeLabel
            : L("已移到 ", "Moved to ") + Dates.label(plan.start, pattern: plan.timed ? "M月d日 HH:mm" : "M月d日")
        if let due = task.dueAt {
            movedMessage! += L(" · 截止 ", " · Due ") + Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
        }
        if plan.timed, let end = task.endAt, PlanBlock.overlaps(DateInterval(start: plan.start, end: end), others: PlanBlock.occupied(tasks, excluding: task.id)) {
            movedMessage! += L(" · 与其他任务重叠", " · overlaps another task")
        }
    }
}
