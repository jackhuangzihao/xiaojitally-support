import Foundation
import SwiftData
import Observation
import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Restore sheets after their host is visible and its previous transition has finished.
struct EditorPresentationReady: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        #if os(iOS)
        content.background(ReadyHost(action: action).frame(width: 0, height: 0))
        #else
        content.onAppear(perform: action)
        #endif
    }

    #if os(iOS)
    private struct ReadyHost: UIViewControllerRepresentable {
        let action: () -> Void
        func makeUIViewController(context: Context) -> Controller { Controller() }
        func updateUIViewController(_ controller: Controller, context: Context) { controller.action = action }
        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.readinessTask?.cancel()
        }
        final class Controller: UIViewController {
            var action: (() -> Void)?
            var readinessTask: Task<Void, Never>?
            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                readinessTask?.cancel()
                readinessTask = Task { @MainActor [weak self] in
                    // Recovery rebuilds the host before UIKit starts dismissing its old sheets.
                    // Wait for actual readiness, rather than guessing a presentation delay.
                    await Task.yield()
                    for _ in 0..<100 {
                        guard !Task.isCancelled, let self, self.view.window != nil else { return }
                        var host: UIViewController = self
                        while let parent = host.parent { host = parent }
                        if host.presentedViewController == nil && host.transitionCoordinator == nil
                            && !host.isBeingDismissed && !host.isBeingPresented {
                            self.action?()
                            return
                        }
                        do { try await Task.sleep(for: .milliseconds(50)) }
                        catch { return }
                    }
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tally", category: "EditorRecovery")
                        .error("Editor host did not become ready; session draft remains retained")
                }
            }
            override func viewDidDisappear(_ animated: Bool) {
                super.viewDidDisappear(animated)
                readinessTask?.cancel()
            }
        }
    }
    #endif
}

/// Only tracks visible editors; drafts and user content never leave their owning view.
@MainActor final class UnsavedEditorChanges {
    @MainActor final class Editor: NSObject {
        var hasChanges: () -> Bool = { false }
    }
    static let shared = UnsavedEditorChanges()
    private let editors = NSHashTable<Editor>.weakObjects()
    var hasChanges: Bool { editors.allObjects.contains { $0.hasChanges() } }
    func track(_ editor: Editor) { editors.add(editor) }
    func remove(_ editor: Editor) { editors.remove(editor) }
}

struct UnsavedEditorGuard: ViewModifier {
    let hasChanges: () -> Bool
    @State private var editor = UnsavedEditorChanges.Editor()
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onAppear {
                // Read live State at quit, including a save that finished before the next render.
                editor.hasChanges = hasChanges
                UnsavedEditorChanges.shared.track(editor)
            }
            .onDisappear {
                UnsavedEditorChanges.shared.remove(editor)
                editor.hasChanges = { false }
            }
        #else
        content
        #endif
    }
}

@MainActor @Observable final class EditorDrafts {
    // Separate the root account editor from any entity opened inside its balance entry.
    private var entityDrafts: [UUID?: FinanceEntityDraft] = [:]
    private var entityOwners: [UUID?: UUID] = [:]
    var financeEntity: FinanceEntityDraft? { entityDrafts[nil] ?? entityDrafts.values.first }
    func entityDraft(parentEntryID: UUID? = nil) -> FinanceEntityDraft? { entityDrafts[parentEntryID] }
    var finance: FinanceDraft?
    var financeRecurring: FinanceRecurringDraft?
    var hasFinanceDraft: Bool { finance != nil || financeEntity != nil || financeRecurring != nil }
    // Presentation state expires when recovery replaces the window; value-only drafts remain separate.
    var financePresentationGeneration: Int?
    var financePresentationActive: Bool { financePresentationGeneration == Store.recovery.generation }
    var financeNavigationBlocked: Bool { hasFinanceDraft || financePresentationActive }

    func beginEntityDraft(owner: UUID, kind: FinanceEntityKind, id: UUID?, parentEntryID: UUID? = nil) -> FinanceEntityDraft? {
        let kept = entityDrafts[parentEntryID]
        guard kept == nil || (kept?.kind == kind && kept?.id == id) else { return nil }
        entityOwners[parentEntryID] = owner
        return kept
    }

    func keepEntityDraft(_ draft: FinanceEntityDraft, owner: UUID, generation: Int, parentEntryID: UUID? = nil) {
        guard entityOwners[parentEntryID] == owner, generation == Store.recovery.generation else { return }
        entityDrafts[parentEntryID] = draft
    }

    func clearEntityDraft(owner: UUID, generation: Int, parentEntryID: UUID? = nil) {
        // A delayed sheet dismissal must not clear a newer editor or a recovery draft.
        guard entityOwners[parentEntryID] == owner, generation == Store.recovery.generation,
              Store.recovery.failure == nil else { return }
        entityDrafts[parentEntryID] = nil
        entityOwners[parentEntryID] = nil
    }

    func clearRecurringDraft(id: UUID, generation: Int) {
        // A disappearing retired editor must not clear the recovered window's draft.
        if generation == Store.recovery.generation && Store.recovery.failure == nil && financeRecurring?.original.id == id {
            financeRecurring = nil
        }
    }
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
