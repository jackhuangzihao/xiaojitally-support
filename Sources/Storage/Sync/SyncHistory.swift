import Foundation
import SwiftData
import OSLog

extension SyncChanges {
    private struct CachedHistory: Sendable {
        let data: Data
        let value: Revisions
        let records: [String: Data]?

        static func encode(_ revisions: Revisions, reusing previous: CachedHistory?, cancellable: Bool = false) throws -> CachedHistory {
            // Only previously validated, identical records can bypass validation and encoding.
            try validate(revisions.filter { previous?.value[$0.key] != $0.value })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var records: [String: Data] = [:]; records.reserveCapacity(revisions.count)
            var byteCount = 2
            for (key, revision) in revisions {
                if cancellable { try Task.checkCancellation() }
                let encoded: Data
                if previous?.value[key] == revision, let existing = previous?.records?[key] { encoded = existing }
                else {
                    var record = try encoder.encode(key); record.append(58)
                    record.append(try encoder.encode(revision)); encoded = record
                }
                records[key] = encoded; byteCount += encoded.count + 1
            }
            var data = Data(); data.reserveCapacity(byteCount); data.append(123)
            for (index, record) in records.sorted(by: { $0.key < $1.key }).enumerated() {
                if index > 0 { data.append(44) }
                data.append(record.value)
            }
            data.append(125)
            return CachedHistory(data: data, value: revisions, records: records)
        }
    }
    private actor HistoryWorker {
        func prepare(_ data: Data) throws -> CachedHistory {
            try Task.checkCancellation()
            let value = try JSONDecoder().decode(Revisions.self, from: data)
            try Task.checkCancellation()
            try validate(value)
            let decoded = CachedHistory(data: data, value: value, records: nil)
            let encoded = try CachedHistory.encode(value, reusing: decoded, cancellable: true)
            // Legacy JSON may use different whitespace; cache matching always uses the actual stored bytes.
            return CachedHistory(data: data, value: value, records: encoded.records)
        }
    }
    private struct HistoryPreparation {
        let id = UUID()
        let contextID: ObjectIdentifier
        let data: Data
        let task: Task<CachedHistory, Error>
        var waiters = 1
    }
    private static let historyWorker = HistoryWorker()
    private static let historyLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "SyncHistory")
    // Keep just one history; switching stores or rolling back requires matching the stored bytes again.
    @MainActor private static var cached: CachedHistory?
    @MainActor private static var preparation: HistoryPreparation?

    @MainActor static func cancelHistoryPreparation() {
        preparation?.task.cancel(); preparation = nil
    }
    @MainActor private static func invalidatePreparation(for context: ModelContext) {
        if let preparation, preparation.contextID != ObjectIdentifier(context) { cancelHistoryPreparation() }
    }

    /// Wait off the main actor for cold decoding, then check and commit without another suspension.
    /// A concurrent edit or recovery must never force a cold synchronous fallback or save stale data.
    @MainActor static func withPreparedHistory<T>(in context: ModelContext, _ save: () throws -> T) async throws -> T {
        for _ in 0..<3 {
            try Task.checkCancellation()
            try Store.recovery.requireWritable(context)
            do { try await prepareHistory(in: context) }
            catch is CancellationError {
                try Task.checkCancellation()
                continue // Another context superseded the optional worker, not this save.
            }
            try Task.checkCancellation()
            try Store.recovery.requireWritable(context)
            if let data = try state(context, create: false)?.changeHistory,
               cached?.data != data || cached?.records == nil { continue }
            return try save()
        }
        historyLog.notice("Save preparation changed repeatedly; kept the unsaved draft")
        throw TaskBackup.invalid(L("数据仍在更新，修改尚未保存，请稍后再试。", "Data is still updating. Your changes have not been saved; try again shortly."))
    }

    /// Only copied bytes cross the actor boundary; startup warming and pending saves share this work.
    @MainActor @discardableResult static func prepareHistory(in context: ModelContext) async throws -> Bool {
        try Task.checkCancellation()
        invalidatePreparation(for: context)
        guard let data = try state(context, create: false)?.changeHistory else { return false }
        if cached?.data == data, cached?.records != nil { return false }
        let pending: HistoryPreparation
        if let existing = preparation, existing.data == data {
            pending = existing; preparation?.waiters += 1
        }
        else {
            cancelHistoryPreparation()
            let task = Task(priority: .utility) { try await historyWorker.prepare(data) }
            pending = HistoryPreparation(contextID: ObjectIdentifier(context), data: data, task: task)
            preparation = pending
        }
        defer {
            if preparation?.id == pending.id {
                preparation?.waiters -= 1
                if preparation?.waiters == 0 { cancelHistoryPreparation() }
            }
        }
        do {
            let ready = try await pending.task.value
            try Task.checkCancellation()
            guard preparation?.id == pending.id else { return false }
            preparation = nil
            guard try state(context, create: false)?.changeHistory == data else { return false }
            cached = ready
            historyLog.debug("Prepared sync history for \(ready.value.count, privacy: .public) records")
            return true
        } catch {
            // Closing one window must not cancel work still awaited by another window or sync.
            if !(error is CancellationError), preparation?.id == pending.id {
                cancelHistoryPreparation()
                historyLog.error("Sync history preparation failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    @MainActor private static func state(_ context: ModelContext, create: Bool) throws -> CloudSyncState? {
        guard context.container.schema.entities.contains(where: { $0.name == "CloudSyncState" }) else { return nil }
        let rows = try context.fetch(FetchDescriptor<CloudSyncState>())
        guard rows.count <= 1 else { throw TaskBackup.invalid("Multiple sync states") }
        if let row = rows.first { return row }
        guard create else { return nil }
        let row = CloudSyncState(); context.insert(row); return row
    }
    @MainActor static func read(_ context: ModelContext) throws -> Revisions? {
        invalidatePreparation(for: context)
        guard let data = try state(context, create: false)?.changeHistory else { return nil }
        if let cached, cached.data == data { return cached.value }
        let result = try JSONDecoder().decode(Revisions.self, from: data)
        try validate(result)
        cached = CachedHistory(data: data, value: result, records: nil)
        return result
    }
    @MainActor static func stage(_ revisions: Revisions?, in context: ModelContext) throws {
        invalidatePreparation(for: context)
        let existing = try state(context, create: false)
        guard let revisions, !revisions.isEmpty else {
            if existing?.changeHistory != nil { existing?.changeHistory = nil }
            cached = nil
            return
        }
        let previous = cached.flatMap { $0.data == existing?.changeHistory ? $0 : nil }
        let next = try CachedHistory.encode(revisions, reusing: previous)
        guard let row = try existing ?? state(context, create: true) else { return }
        // The full JSON remains in the same transaction as the edit; the cache never commits data.
        if row.changeHistory != next.data { row.changeHistory = next.data }
        cached = next
    }
}
