import SwiftUI
import SwiftData

extension TaskEditor {
    struct DraftState: Equatable {
        let title: String, notes: String, pending: String, repeating: String
        let repeatUntil: Date?
        let end: Date?
        let scheduled: Date?, due: Date?, reminder: Date?
        let timed: Bool, dueTimed: Bool
        let preset: ReminderPreset
        let listID: UUID?
        let priority: Int
        let subtasks: [Subtask]
        var original: TaskBackup.TaskRecord? = nil
        var finance: TaskFinanceDraft? = nil
    }
    var draftState: DraftState {
        DraftState(title: title, notes: notes, pending: newSubtask, repeating: repeatRule, repeatUntil: repeatRule == "none" ? nil : repeatUntil,
                   end: effectiveEnd, scheduled: hasDate ? date : nil, due: hasDue ? due : nil, reminder: effectiveReminder,
                   timed: hasTime, dueTimed: dueHasTime, preset: reminderPreset, listID: listID, priority: priority, subtasks: subtasks, original: original,
                   finance: linkedFinance)
    }
    var effectiveEnd: Date? { hasDate && hasTime && hasEnd ? end : nil }
    var hasChanges: Bool { recoveredDraft || (initialDraft.map { $0 != draftState } ?? false) }
    func keepDraft() {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        drafts.taskID = original?.id
        drafts.task = draftState
    }

}

extension TaskEditor {
    static func defaultCustomReminder(for day: Date?) -> Date {
        let now = Date()
        guard let day, !Dates.sameDay(day, now), day > now else {
            return Dates.calendar.dateInterval(of: .hour, for: now)!.end
        }
        return Dates.calendar.date(byAdding: .hour, value: 9, to: Dates.calendar.startOfDay(for: day))!
    }

    /// First time shown when a time is switched on: the next full hour today, otherwise 9:00 —
    /// but never before `after` (the scheduled time, for a same-day deadline).
    static func defaultTime(on day: Date, after: Date? = nil) -> Date {
        let now = Date()
        var result = Dates.sameDay(day, now)
            ? Dates.calendar.dateInterval(of: .hour, for: now)!.end
            : Dates.calendar.date(byAdding: .hour, value: 9, to: Dates.calendar.startOfDay(for: day))!
        if !Dates.sameDay(result, day) { result = Dates.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)! }
        if let after, result < after {
            // An hour after the scheduled time, but never spilling into the next day.
            let endOfDay = Dates.calendar.date(bySettingHour: 23, minute: 59, second: 0, of: after)!
            result = min(Dates.calendar.date(byAdding: .hour, value: 1, to: after)!, max(endOfDay, after))
        }
        return result
    }

    func addSubtask() {
        let value = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.count <= 160, subtasks.count < 100 else { errorMessage = L("最多100个子任务，每项最多160个字。", "Up to 100 subtasks, with at most 160 characters each."); return }
        subtasks.append(Subtask(title: value)); newSubtask = ""
        newSubtaskFocused = true
    }

    func save() {
        guard !isSaving, !didFinishSaving else { return }
        isSaving = true
        saveTask = Task { await persist(); if !didFinishSaving { isSaving = false }; saveTask = nil }
    }

    @MainActor private func persist() async {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        keepDraft()
        do { _ = try EditorVersion.task(original, in: context) }
        catch { errorMessage = error.localizedDescription; return }
        if let end = effectiveEnd, end <= date { errorMessage = L("结束时间必须晚于开始时间。", "End must be after start."); return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 160, notes.count <= 10000 else {
            errorMessage = L("任务名称需为1–160个字，备注最多10000个字。", "Use 1–160 characters for the title and up to 10,000 for notes."); return
        }
        let pendingSubtask = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanSubtasks = subtasks.map { Subtask(id: $0.id, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), isDone: $0.isDone) }
        if !pendingSubtask.isEmpty { cleanSubtasks.append(Subtask(title: pendingSubtask)) }
        guard cleanSubtasks.count <= 100, cleanSubtasks.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 160 }) else {
            errorMessage = L("最多100个子任务，每项需为1–160个字。", "Up to 100 subtasks, with 1–160 characters each."); return
        }
        guard repeatRule == "none" || hasDate || hasDue else {
            errorMessage = L("重复任务需要安排日期或截止日期。", "A repeating task needs a scheduled date or deadline."); return
        }
        if repeatRule != "none", let until = repeatUntil, until < repeatStartDay {
            errorMessage = L("重复的结束日期不能早于开始日期。", "The repeat can't end before it starts."); return
        }
        guard deadlineValid else {
            errorMessage = L("截止不能早于安排的时间，请调整截止日期或时间。", "The deadline can't be before the scheduled time. Adjust the deadline."); return
        }
        let reminderAt = effectiveReminder
        if reminderPreset != .none {
            guard let reminderAt else { errorMessage = L("请选择提醒时间。", "Choose a reminder time."); return }
            if let reminderLatest, reminderAt > reminderLatest, reminderAt != original?.reminderAt {
                errorMessage = L("提醒不能晚于任务时间，请调整提醒。", "The reminder can't be after the task. Adjust the reminder."); return
            }
            if reminderAt <= Date() && reminderAt != original?.reminderAt {
                errorMessage = L("提醒时间 \(Dates.label(reminderAt, pattern: "M月d日 HH:mm")) 已经过去，请换一个提醒选项。", "The reminder time \(Dates.label(reminderAt, pattern: "M月d日 HH:mm")) has passed. Choose another option."); return
            }
            do {
                guard try await ReminderScheduler.shared.authorize() else {
                    errorMessage = L("通知未获允许。请在系统设置中开启通知，或关闭此任务的提醒后保存。", "Notifications are not allowed. Enable them in system settings, or turn off this reminder to save."); return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        do {
            try await SyncChanges.withPreparedHistory(in: context) {
                commit(cleanTitle: cleanTitle, cleanSubtasks: cleanSubtasks, reminderAt: reminderAt)
            }
        } catch is CancellationError {
            // Recovery or dismissal cancels the pending edit.
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func commit(cleanTitle: String, cleanSubtasks: [Subtask], reminderAt: Date?) {
        // Authorizing notifications can suspend this editor while another window saves.
        // Recheck immediately before the first mutation, without an await between check and save.
        let existing: TaskItem?, selectedList: TaskList?
        do {
            existing = try EditorVersion.task(original, in: context)
            selectedList = try EditorVersion.selectedList(listID, in: context)
        } catch { errorMessage = error.localizedDescription; return }
        let oldBase = existing?.calendarDate
        let oldRule = existing?.repeatRule
        let task = existing ?? TaskItem(title: cleanTitle)
        let preparedFinance: FinanceData?
        do {
            preparedFinance = try linkedFinance.map {
                try $0.preparedLedger(taskID: task.id, title: cleanTitle, current: FinanceStore.read(context) ?? .initial)
            }
        } catch { errorMessage = error.localizedDescription; return }
        do {
            if existing == nil { context.insert(task) }
            task.title = cleanTitle; task.notes = notes
            task.scheduledAt = hasDate ? (hasTime ? date : Dates.calendar.startOfDay(for: date)) : nil
            task.hasTime = hasDate && hasTime
            task.endAt = effectiveEnd
            task.dueAt = hasDue ? (dueHasTime ? due : Dates.calendar.startOfDay(for: due)) : nil
            task.dueHasTime = hasDue && dueHasTime
            task.priority = priority
            task.reminderAt = reminderAt
            task.reminderKind = reminderPreset.rawValue
            task.reminderNeedsAttention = task.reminderRequiresAttention()
            task.repeatRule = repeatRule
            task.repeatUntil = repeatRule == "none" ? nil : repeatUntil.map { Dates.calendar.startOfDay(for: $0) }
            if let base = task.calendarDate, task.repeatAnchorDay == 0 || oldRule != repeatRule || oldBase.map({ !Dates.sameDay($0, base) }) == true { task.repeatAnchorDay = Dates.calendar.component(.day, from: base) }
            task.list = selectedList
            task.subtasks = cleanSubtasks
            task.deletedAt = nil
            task.ensureNextOccurrence(in: context)
            if let preparedFinance { try FinanceStore.stage(preparedFinance, in: context) }
            try Store.save(context)
            didFinishSaving = true
            ReminderScheduler.shared.refresh(context); dismiss()
        } catch {
            // Store.save rolls back a failed disk commit; staging can fail before reaching it.
            if Store.recovery.failure == nil { context.rollback(); errorMessage = error.localizedDescription }
        }
    }
}
