import Foundation
import SwiftData
import Observation
import SQLite3
import OSLog

/// A failed context is never reused. Recovery opens the last committed store;
/// editor drafts live outside this context and are applied only after another Save.
@MainActor @Observable final class StoreRecovery {
    private(set) var failure: String?
    private(set) var container: ModelContainer?
    private(set) var generation = 0
    @ObservationIgnored private var url: URL?
    // ModelContainer is Equatable, not Hashable; retire the exact instance without invoking its hash.
    @ObservationIgnored private let retired = NSHashTable<ModelContainer>(options: [.weakMemory, .objectPointerPersonality])

    func requireWritable(_ context: ModelContext) throws {
        guard failure == nil, !retired.contains(context.container) else {
            throw TaskBackup.invalid(L("保存已暂停，请先重新载入数据。", "Saving is paused. Reload your data first."))
        }
    }
    func failed(_ error: Error, in context: ModelContext) {
        retired.add(context.container)
        url = context.container.configurations.first?.url
        failure = error.localizedDescription
    }
    @discardableResult func reload() -> Bool {
        guard failure != nil, let url else { return false }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TaskBackup.invalid(L("找不到原数据文件，请恢复文件位置后重试。未创建空数据库。", "The original data file is missing. Restore its location and retry. No empty database was created."))
            }
            let fresh = try Store.make(url: url)
            // Do not enable editing until both model collections can be read.
            _ = try fresh.mainContext.fetch(FetchDescriptor<TaskItem>())
            _ = try fresh.mainContext.fetch(FetchDescriptor<TaskList>())
            _ = try FinanceStore.read(fresh.mainContext)
            container = fresh
            Store.invalidateHistory()
            generation += 1
            failure = nil
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}

private let storeLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "Store")

@MainActor enum Store {
    static let recovery = StoreRecovery()
    static var didSave: ((ModelContext) -> Void)?
    private(set) static var revision = 0
    static func make(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            #if os(macOS) && JIANSHI_APP_STORE
            // Older development builds may have left a stale Jianshi.store in this container.
            // Use a distinct location and explicitly import a current portable backup.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Jianshi", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema,
                url: directory.appendingPathComponent("Tasks.store"), cloudKitDatabase: .none)
            #else
            configuration = ModelConfiguration("Jianshi", schema: schema, cloudKitDatabase: .none)
            #endif
        }
        // Only protect the user store here. Tests and explicit file tools choose their own snapshots.
        if url == nil { _ = try StoreUpgradeSnapshot.prepare(configuration.url) }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    static func invalidateHistory() { revision += 1 }

    /// Runs several staging steps that end in `Store.save`. If a step throws before the save, the unsaved changes
    /// are undone; otherwise the next unrelated save would commit half of them (and sync waits while they linger).
    /// A failed `Store.save` has already rolled back and paused saving, so it is left as it is.
    static func discardingOnFailure(_ context: ModelContext, _ changes: () throws -> Void) throws {
        do { try changes() }
        catch {
            if recovery.failure == nil, context.hasChanges {
                context.rollback()
                storeLog.notice("Discarded unsaved changes after a failed multi-step update")
            }
            throw error
        }
    }
    static func failureMessage(_ error: Error) -> String {
        L("修改未保存。请使用“重新载入数据”恢复操作；编辑草稿会保留，载入后请检查并再次保存。", "Changes were not saved. Reload data to continue; editor drafts are kept. Review and save them after reloading.") + "\n" + error.localizedDescription
    }
    static func save(_ context: ModelContext, trackSyncChanges: Bool = true) throws {
        try recovery.requireWritable(context)
        do {
            ListColor.normalize(try context.fetch(FetchDescriptor<TaskList>()))
            if trackSyncChanges { try SyncChanges.trackModels(in: context) }
            let changed = context.hasChanges
            try context.save()
            if changed { revision += 1 }
        }
        catch {
            context.processPendingChanges()
            context.rollback()
            recovery.failed(error, in: context)
            throw error
        }
        didSave?(context)
    }
}

/// A consistent SQLite snapshot before opening each new schema generation.
/// SQLite's backup API includes committed WAL data even while another connection is open.
/// This is a local rollback artifact, not a sync queue or a replacement for portable JSON backups.
enum StoreUpgradeSnapshot {
    // Bump for a persisted-schema or stored-format change, not for every app build. Keep prior generations.
    // v3: per-record sync and recurring bills stored as rules (backup/sync format 13).
    static let generation = "schema-v3"
    static func prepare(_ source: URL, generation: String = StoreUpgradeSnapshot.generation) throws -> URL? {
        guard !generation.isEmpty, generation.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return nil }
        let directory = source.deletingLastPathComponent().appendingPathComponent("SchemaBackups", isDirectory: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent + ".before-" + generation + ".sqlite")
        if files.fileExists(atPath: destination.path) { return destination }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
            defer {
                for suffix in ["", "-wal", "-shm", "-journal"] { try? files.removeItem(atPath: temporary.path + suffix) }
            }
            try snapshot(source, to: temporary)
            try files.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            throw NSError(domain: "Jianshi.StoreUpgrade", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("升级前的数据副本未能保存，已停止打开数据库。请检查磁盘空间和文件权限后重试。", "Could not save the pre-upgrade copy. Opening the database was stopped. Check disk space and file permissions, then retry.") + "\n" + error.localizedDescription])
        }
    }

    private static func snapshot(_ source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
        func failure(_ db: OpaquePointer?) -> NSError {
            NSError(domain: "Jianshi.SQLiteSnapshot", code: Int(sqlite3_errcode(db)),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure(output) }
        sqlite3_busy_timeout(input, 1500); sqlite3_busy_timeout(output, 1500)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw failure(output) }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw failure(output) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(output, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else { throw failure(output) }
    }
}
