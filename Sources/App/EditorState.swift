import Foundation
import SwiftData
import Observation
import OSLog

@MainActor @Observable final class EditorDrafts {
    var financeEntity: FinanceEntityDraft?
    var finance: FinanceDraft?
    // Presentation state expires when recovery replaces the window; value-only drafts remain separate.
    var financePresentationGeneration: Int?
    var financePresentationActive: Bool { financePresentationGeneration == Store.recovery.generation }
    var reminder = ReminderNavigation()
    var taskID: UUID?
    var task: TaskEditor.DraftState?
    var listID: UUID?
    var list: ListEditor.DraftState?
}

/// Editors retain value snapshots, including across store recovery, rather than a live model reference.
@MainActor enum EditorVersion {
    static func task(_ expected: TaskBackup.TaskRecord?, in context: ModelContext) throws -> TaskItem? {
        guard let expected else { return nil }
        let id = expected.id
        var query = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let current = try context.fetch(query)
        guard current.count == 1, TaskBackup.TaskRecord(current[0]) == expected else {
            throw TaskBackup.invalid(L("任务已在其他窗口修改或删除，未覆盖最新内容。此页面的输入仍保留，请先复制需要的内容，再关闭并重新打开任务核对。", "This task changed or was deleted in another window. Nothing was overwritten and your input remains here. Copy anything you need before closing and reopening the task to review it."))
        }
        return current[0]
    }

    static func list(_ expected: TaskBackup.ListRecord?, in context: ModelContext) throws -> TaskList? {
        guard let expected else { return nil }
        let current = try selectedList(expected.id, in: context)
        guard let current, TaskBackup.ListRecord(current) == expected else {
            throw TaskBackup.invalid(L("清单已在其他窗口修改，未覆盖最新内容。此页面的输入仍保留，请先复制需要的内容，再关闭并重新打开清单核对。", "This list changed in another window. Nothing was overwritten and your input remains here. Copy anything you need before closing and reopening the list to review it."))
        }
        return current
    }

    static func selectedList(_ id: UUID?, in context: ModelContext) throws -> TaskList? {
        guard let id else { return nil }
        var query = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let current = try context.fetch(query)
        guard current.count == 1 else {
            throw TaskBackup.invalid(L("清单已删除或无法确定，未保存修改。此页面的输入仍保留，请重新选择清单；如果正在编辑此清单，请先复制需要的内容再关闭。", "The list was deleted or cannot be identified. Changes were not saved and your input remains here. Choose another list; if you are editing this list, copy anything you need before closing."))
        }
        return current[0]
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var task: TaskItem?
    var date: Date?
    var listID: UUID?
    var timed = false

}

struct ListRequest: Identifiable {
    let id = UUID()
    var list: TaskList?
    var parentID: UUID?
}

/// Register before scheduling an editor task so normal quit cannot race its first suspension.
@MainActor final class PendingEditorSaves {
    static let shared = PendingEditorSaves()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tally", category: "EditorSave")
    private var active: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var failureCount: UInt64 = 0
    var hasPending: Bool { !active.isEmpty }

    func begin() -> UUID {
        let id = UUID(); active.insert(id)
        return id
    }
    func finish(_ id: UUID, saved: Bool) {
        guard active.remove(id) != nil else { return }
        if !saved { failureCount &+= 1; log.notice("Editor save did not commit; keep the app open if quitting") }
        guard active.isEmpty else { return }
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    func waitForCompletion() async -> Bool {
        let failures = failureCount
        while hasPending { await withCheckedContinuation { waiters.append($0) } }
        return failures == failureCount
    }
}
