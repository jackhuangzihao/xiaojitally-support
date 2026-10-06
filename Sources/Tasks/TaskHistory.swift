import SwiftUI
import SwiftData

/// Shared system undo stack. Each entry captures only the task affected by that action.
@MainActor @Observable final class TaskHistory {
    enum State: Equatable { case schedule(TaskSchedule), list(UUID?), copy(TaskBackup.TaskRecord) }
    private final class Entry {
        let task: TaskItem
        var before: State
        var after: State
        let name: String
        init(task: TaskItem, before: State, after: State, name: String) {
            self.task = task; self.before = before; self.after = after; self.name = name
        }
    }
    @ObservationIgnored let manager = UndoManager()
    @ObservationIgnored private var last: Entry?
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var savedRevision: Int?
    private(set) var revision = 0
    var outcome: String?
    var canUndo: Bool { _ = revision; return manager.canUndo }
    var canRedo: Bool { _ = revision; return manager.canRedo }
    init() { manager.groupsByEvent = false; manager.levelsOfUndo = 100 }

    func record(_ task: TaskItem, before: State, after: State, name: String, coalesce: Bool = false) {
        guard before != after else { return }
        // An intervening edit/completion must not make Cmd-Z silently skip back to an older drag.
        if let savedRevision, savedRevision != Store.revision - 1 { manager.removeAllActions(); last = nil }
        savedRevision = Store.revision
        if coalesce, let last, last.task.id == task.id, last.before == before {
            last.after = after; revision += 1; return
        }
        let entry = Entry(task: task, before: before, after: after, name: name)
        last = entry
        manager.beginUndoGrouping()
        register(entry, reverse: false)
        manager.endUndoGrouping()
        revision += 1
    }
    func recordCopy(_ task: TaskItem) {
        let created = TaskBackup.TaskRecord(task)
        var removed = created
        removed.deletedAt = Date()
        record(task, before: .copy(removed), after: .copy(created), name: L("复制任务", "Copy task"))
    }
    private func register(_ entry: Entry, reverse: Bool) {
        manager.registerUndo(withTarget: self) { history in history.apply(entry, reverse: reverse) }
        manager.setActionName(entry.name)
    }
    private func apply(_ entry: Entry, reverse: Bool) {
        let task = entry.task, expected = reverse ? entry.before : entry.after, destination = reverse ? entry.after : entry.before
        guard savedRevision == Store.revision, let context = task.modelContext,
              (try? Store.recovery.requireWritable(context)) != nil else { stale(); return }
        let current: State
        switch expected {
        case .copy: current = .copy(TaskBackup.TaskRecord(task))
        case .schedule:
            guard task.deletedAt == nil else { stale(); return }
            current = .schedule(TaskSchedule(task))
        case .list:
            guard task.deletedAt == nil else { stale(); return }
            current = .list(task.list?.id)
        }
        guard current == expected else { stale(); return }
        do {
            switch destination {
            case .copy(let snapshot):
                // Keep a deletion record for sync and redo, dated when Undo actually runs.
                task.deletedAt = reverse ? snapshot.deletedAt : Date()
            case .schedule(let snapshot): snapshot.restore(task); task.reminderNeedsAttention = task.reminderRequiresAttention()
            case .list(let id):
                let lists = try context.fetch(FetchDescriptor<TaskList>())
                let list = lists.first { $0.id == id }
                guard id == nil || list != nil else { stale(); return }
                task.list = list
            }
            try Store.save(context)
            if case .copy = destination, !reverse { entry.before = .copy(TaskBackup.TaskRecord(task)) }
            savedRevision = Store.revision
            ReminderScheduler.shared.refresh(context)
            register(entry, reverse: !reverse)
            last = nil; revision += 1
            outcome = (reverse ? L("已重做：", "Redone: ") : L("已撤销：", "Undone: ")) + entry.name
        } catch {
            invalidated = true; last = nil; revision += 1
            outcome = Store.failureMessage(error)
        }
    }
    private func stale() {
        invalidated = true; last = nil; revision += 1
        outcome = L("任务已再次修改，未覆盖新内容；请在编辑中调整。", "The task changed again. Newer content was preserved; adjust it in the editor.")
    }
    private func clearInvalidated() {
        if invalidated { manager.removeAllActions(); invalidated = false; revision += 1 }
    }
    func undo() { outcome = nil; manager.undo(); clearInvalidated() }
    func redo() { outcome = nil; manager.redo(); clearInvalidated() }
}

#if os(macOS)
private struct TaskHistoryKey: FocusedValueKey { typealias Value = TaskHistory }
extension FocusedValues {
    var taskHistory: TaskHistory? {
        get { self[TaskHistoryKey.self] }
        set { self[TaskHistoryKey.self] = newValue }
    }
}
struct TaskHistoryCommands: Commands {
    @AppStorage("appLanguage") private var language = "system"
    @FocusedValue(\.taskHistory) private var history
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L("撤销", "Undo")) { perform(redo: false) }.keyboardShortcut("z", modifiers: .command)
            Button(L("重做", "Redo")) { perform(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
    private func perform(redo: Bool) {
        // Text editing retains its own native undo stack and never changes a saved task behind the editor.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            if redo { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
        } else if NSApp.keyWindow?.attachedSheet == nil && NSApp.keyWindow?.sheetParent == nil {
            if redo { history?.redo() } else { history?.undo() }
        }
    }
}
#endif
