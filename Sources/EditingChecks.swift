import Foundation
import SwiftData

@MainActor enum EditingChecks {
    static func run() throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Editors: " + label) }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false
            do { try action() } catch { rejected = true }
            try require(rejected, label)
        }
        let container = try ModelContainer(for: TaskItem.self, TaskList.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let list = TaskList(name: "Original list"), other = TaskList(name: "Unrelated list")
        context.insert(list); context.insert(other)
        let task = TaskItem(title: "Original task", list: list)
        task.notes = "Original note"; task.subtasks = [Subtask(title: "Original step")]
        context.insert(task); try context.save()
        let original = TaskBackup.TaskRecord(task), originalList = TaskBackup.ListRecord(list)
        try require(try EditorVersion.task(original, in: context) === task, "Unchanged task can be saved")
        try require(try EditorVersion.list(originalList, in: context) === list, "Unchanged list can be saved")
        try require(try EditorVersion.task(nil, in: context) == nil && EditorVersion.list(nil, in: context) == nil,
                    "New records do not need an existing target")
        other.name = "Changed elsewhere"; try context.save()
        try require(try EditorVersion.task(original, in: context) === task && EditorVersion.list(originalList, in: context) === list,
                    "Unrelated edits do not block this task or list")

        // Window A holds its opening snapshot. Window B commits while A still has unsaved text.
        let draft = TaskEditor.DraftState(title: "Window A title", notes: original.notes, pending: "Unsubmitted step",
            repeating: "none", repeatUntil: nil, end: nil, scheduled: nil, due: nil, reminder: nil,
            timed: false, dueTimed: false, preset: .none, listID: list.id, priority: 0,
            subtasks: original.subtasks, original: original)
        task.notes = "Window B note"; task.subtasks[0].isDone = true; try context.save()
        try rejects("Stale task editor is rejected before any mutation") {
            let target = try EditorVersion.task(draft.original, in: context)
            target?.title = draft.title; target?.notes = draft.notes; target?.subtasks = draft.subtasks
        }
        try require(task.title == "Original task" && task.notes == "Window B note" && task.subtasks[0].isDone,
                    "A failed save preserves B's note and completed subtask")
        try require(draft.title == "Window A title" && draft.pending == "Unsubmitted step" && draft.original == original,
                    "Recovery draft retains unsaved text and the opening version")
        var refreshed = TaskBackup.TaskRecord(task)
        task.isDone = true; task.completedAt = Date(); try context.save()
        try rejects("Completion from another window is not overwritten") { _ = try EditorVersion.task(refreshed, in: context) }
        refreshed = TaskBackup.TaskRecord(task)
        // The editor checks again after notification authorization, which is an async suspension.
        _ = try EditorVersion.task(refreshed, in: context)
        task.priority = 2; try context.save()
        try rejects("Second check catches changes after the first check") { _ = try EditorVersion.task(refreshed, in: context) }
        refreshed = TaskBackup.TaskRecord(task)
        task.deletedAt = Date(); try context.save()
        try rejects("Deletion during editing cannot accidentally restore a task") { _ = try EditorVersion.task(refreshed, in: context) }
        let deleted = TaskBackup.TaskRecord(task)
        let restorable = try EditorVersion.task(deleted, in: context)
        try require(restorable === task, "An editor intentionally opened from Recently deleted may restore the unchanged task")
        restorable?.deletedAt = nil; try context.save()
        try rejects("Another window restoring a task invalidates a stale trash editor") { _ = try EditorVersion.task(deleted, in: context) }

        let listDraft = ListEditor.DraftState(name: "Window A list", colorHex: nil, emoji: "📚", parentID: nil, original: originalList)
        list.emoji = "🏠"; list.name = "Window B list"; try context.save()
        try rejects("Stale list editor is rejected before changing its fields") {
            let target = try EditorVersion.list(listDraft.original, in: context)
            target?.name = listDraft.name; target?.emoji = listDraft.emoji
        }
        try require(list.name == "Window B list" && list.emoji == "🏠" && listDraft.original == originalList,
                    "List edit conflict preserves saved data and recovery baseline")
        let moved = TaskBackup.ListRecord(list)
        list.parentID = other.id; try context.save()
        try rejects("A move in another window cannot be overwritten") { _ = try EditorVersion.list(moved, in: context) }
        let finalTask = TaskBackup.TaskRecord(task), finalList = TaskBackup.ListRecord(list), listID = list.id
        context.delete(task); context.delete(list); try context.save()
        try rejects("Permanently deleted tasks are not silently recreated by old drafts") { _ = try EditorVersion.task(finalTask, in: context) }
        try rejects("Permanently deleted lists are not silently recreated by old drafts") { _ = try EditorVersion.list(finalList, in: context) }
        try rejects("Deleted task list or parent selection cannot create a dangling relationship") { _ = try EditorVersion.selectedList(listID, in: context) }
        try require(try EditorVersion.selectedList(nil, in: context) == nil, "An explicitly unfiled task or top-level list remains valid")
        try require(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty && context.fetch(FetchDescriptor<TaskList>()).count == 1,
                    "Rejected saves do not insert replacement records")
        print("Editor checks passed: \(checks)")
        return checks
    }
}
