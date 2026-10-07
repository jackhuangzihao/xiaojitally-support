import Foundation
import SwiftData

extension SelfCheck {
    #if os(macOS) && JIANSHI_APP_STORE
    /// Run only from a separately signed, disposable test identity; never the user's app.
    static func sandbox() throws {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasPrefix("local.jianshi.sandboxcheck."),
              NSHomeDirectory().contains("/Containers/" + identifier + "/Data") else {
            throw TaskBackup.invalid("Sandbox check requires a dedicated sandboxcheck app container")
        }
        try run()
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TaskBackup.invalid(message) }
            checks += 1
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let old = try Store.make(url: support.appendingPathComponent("Jianshi.store"))
        let parent = TaskList(name: "Sandbox fixture"); parent.emoji = "📚"
        let child = TaskList(name: "Nested fixture"); child.parentID = parent.id
        old.mainContext.insert(parent); old.mainContext.insert(child)
        let task = TaskItem(title: "Sandbox task", scheduledAt: Date().addingTimeInterval(86400), list: child)
        task.notes = "Portable migration"; task.hasTime = true
        task.endAt = task.scheduledAt!.addingTimeInterval(7200)
        task.priority = 2; task.repeatRule = "weekly"
        task.subtasks = [Subtask(title: "Finished step", isDone: true)]
        old.mainContext.insert(task)
        let completed = TaskItem(title: "Completed fixture"); completed.isDone = true; completed.completedAt = Date()
        old.mainContext.insert(completed)
        let deleted = TaskItem(title: "Deleted fixture"); deleted.deletedAt = Date()
        old.mainContext.insert(deleted)
        try Store.save(old.mainContext)
        let before = try TaskBackup.capture(old.mainContext)
        let encoded = try before.encoded()
        let destination = try Store.make()
        let fresh = try TaskBackup.capture(destination.mainContext)
        try require(fresh.tasks.isEmpty && fresh.lists.isEmpty, "App Store must not open the stale legacy container store")
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let export = documents.appendingPathComponent("sandbox-fixture.json")
        try encoded.write(to: export, options: .atomic)
        let imported = try TaskBackup.decode(Data(contentsOf: export))
        try imported.restore(destination.mainContext, replace: true)
        let after = try TaskBackup.capture(destination.mainContext)
        try require(try BackupFiles.contentData(before) == BackupFiles.contentData(after), "Import must preserve all fields, IDs, nested lists, completion and deletion")
        let reopened = try Store.make()
        try require(try BackupFiles.contentData(TaskBackup.capture(reopened.mainContext)) == BackupFiles.contentData(before), "Sandbox data must survive closing and reopening the store")
        try require(try BackupFiles.contentData(TaskBackup.capture(old.mainContext)) == BackupFiles.contentData(before), "Import must leave the legacy source unchanged")
        let recovery = try TaskBackup.recoveryURL()
        try encoded.write(to: recovery, options: .atomic)
        try require(try TaskBackup.decode(Data(contentsOf: recovery)).tasks.count == 3, "Pre-restore backup remains readable in sandbox")
        let directory = try BackupFiles.localDirectory()
        _ = try BackupFiles.save(before, directory: directory, owner: "sandbox-check", force: true)
        try require(directory.path.hasPrefix(NSHomeDirectory() + "/"), "Automatic backups stay in the sandbox")
        try require(try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Automatic backup actually writes a file")
        var invalid = imported; invalid.tasks.append(invalid.tasks[0])
        var rejected = false
        do { try invalid.restore(destination.mainContext, replace: true) } catch { rejected = true }
        try require(rejected, "Invalid duplicate backup is rejected")
        try require(try BackupFiles.contentData(TaskBackup.capture(destination.mainContext)) == BackupFiles.contentData(before), "Invalid import leaves existing sandbox data unchanged")
        print("SANDBOX PASS: \(checks) storage and migration checks; \(identifier)")
    }
    #endif

}
