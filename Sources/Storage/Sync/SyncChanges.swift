import Foundation
import SwiftData

/// Modification times belong to record contents, never to a snapshot's upload time.
/// Nil fingerprints are deletion tombstones; keep them so an offline device cannot resurrect a row.
enum SyncChanges {
    struct Revision: Codable, Equatable {
        var date: Date
        var fingerprint: String?
    }
    typealias Revisions = [String: Revision]
    struct Decision {
        var choice: CloudMerge.Choice?
        var needsReview: Bool
    }
    @MainActor private static var cached: (data: Data, value: Revisions)?

    static func key(_ kind: String, _ id: UUID) -> String { kind + ":" + id.uuidString }
    static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, (-62135596800000...253402300799000).contains(milliseconds) else {
                throw TaskBackup.invalid(L("同步记录含无效日期。", "A sync record contains an invalid date."))
            }
            try value.encode(Int64(milliseconds))
        }
        return CloudMerge.digest(try encoder.encode(value))
    }
    static func validate(_ revisions: Revisions?) throws {
        guard let revisions else { return }
        let kinds: Set<String> = ["task", "list", "week", "account", "book", "category", "entry"]
        guard revisions.allSatisfy({ key, revision in
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count == 2 && kinds.contains(String(parts[0])) && UUID(uuidString: String(parts[1])) != nil
                && revision.date.timeIntervalSince1970.isFinite
                && (-62135596800...253402300799).contains(revision.date.timeIntervalSince1970)
                && (revision.fingerprint.map { $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? true)
        }) else { throw TaskBackup.invalid(L("同步修改记录无效。", "Invalid sync modification records.")) }
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
        guard let data = try state(context, create: false)?.changeHistory else { return nil }
        if let cached, cached.data == data { return cached.value }
        let result = try JSONDecoder().decode(Revisions.self, from: data)
        try validate(result)
        cached = (data, result)
        return result
    }
    @MainActor static func stage(_ revisions: Revisions?, in context: ModelContext) throws {
        try validate(revisions)
        guard let row = try state(context, create: revisions?.isEmpty == false) else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try revisions.flatMap { $0.isEmpty ? nil : try encoder.encode($0) }
        if row.changeHistory != data { row.changeHistory = data }
        if let data, let revisions { cached = (data, revisions) }
    }
    static func record(_ fingerprints: [String: String?], in revisions: inout Revisions, now: Date) {
        for (key, fingerprint) in fingerprints where revisions[key]?.fingerprint != fingerprint || revisions[key] == nil {
            // Preserve ordering on this device if its clock moves backwards or two saves share a millisecond.
            let previous = revisions[key]?.date.addingTimeInterval(0.001) ?? now
            let milliseconds = (now.timeIntervalSince1970 * 1000).rounded() / 1000
            revisions[key] = Revision(date: max(Date(timeIntervalSince1970: milliseconds), previous), fingerprint: fingerprint)
        }
    }
    @MainActor static func trackModels(in context: ModelContext, now: Date = Date()) throws {
        var changes: [String: String?] = [:]
        let deleted = context.deletedModelsArray
        let deletedIDs = Set(deleted.map(\.persistentModelID))
        // A replacement may delete and insert the same business ID in one transaction.
        let liveChanges = (context.insertedModelsArray + context.changedModelsArray).filter { !deletedIDs.contains($0.persistentModelID) }
        for model in deleted + liveChanges {
            let key: String, hash: String?
            if let task = model as? TaskItem {
                key = self.key("task", task.id)
                hash = deletedIDs.contains(task.persistentModelID) ? nil : try fingerprint(TaskBackup.TaskRecord(task))
            } else if let list = model as? TaskList {
                key = self.key("list", list.id)
                hash = deletedIDs.contains(list.persistentModelID) ? nil : try fingerprint(TaskBackup.ListRecord(id: list.id, name: list.name, createdAt: list.createdAt, parentID: list.parentID, colorHex: list.colorHex, sortOrder: list.sortOrder, emoji: list.emoji))
            } else if let week = model as? CalendarWeekTitle {
                let record = TaskBackup.WeekTitleRecord(week: week.week, title: week.title)
                key = self.key("week", record.id)
                hash = deletedIDs.contains(week.persistentModelID) ? nil : try fingerprint(record)
            } else { continue }
            changes[key] = .some(hash)
        }
        guard !changes.isEmpty else { return }
        var revisions = try read(context) ?? [:]
        record(changes, in: &revisions, now: now)
        try stage(revisions, in: context)
    }
    @MainActor static func trackFinance(from previous: FinanceData?, to next: FinanceData, in context: ModelContext, now: Date = Date()) throws {
        var changes: [String: String?] = [:]
        func collect<T: Encodable & Equatable & Identifiable>(_ before: [T], _ after: [T], kind: String) throws where T.ID == UUID {
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
                if let value = new[id] { changes[key(kind, id)] = try fingerprint(value) }
                else { changes[key(kind, id)] = .some(nil) }
            }
        }
        try collect(previous?.accounts ?? [], next.accounts, kind: "account")
        try collect(previous?.books ?? [], next.books, kind: "book")
        try collect(previous?.categories ?? [], next.categories, kind: "category")
        try collect(previous?.entries ?? [], next.entries, kind: "entry")
        guard !changes.isEmpty else { return }
        var revisions = try read(context) ?? [:]
        record(changes, in: &revisions, now: now)
        try stage(revisions, in: context)
    }

    static func fingerprints(_ snapshot: TaskBackup) throws -> [String: String] {
        var values: [String: String] = [:]
        func collect<T: Encodable>(_ rows: [T], kind: String, id: (T) -> UUID) throws {
            for row in rows { values[key(kind, id(row))] = try fingerprint(row) }
        }
        try collect(snapshot.tasks, kind: "task", id: { $0.id })
        try collect(snapshot.lists, kind: "list", id: { $0.id })
        try collect(snapshot.weekTitles ?? [], kind: "week", id: { $0.id })
        if let finance = snapshot.finance {
            try collect(finance.accounts, kind: "account", id: { $0.id })
            try collect(finance.books, kind: "book", id: { $0.id })
            try collect(finance.categories, kind: "category", id: { $0.id })
            try collect(finance.entries, kind: "entry", id: { $0.id })
        }
        return values
    }
    static func restored(_ snapshot: TaskBackup, replacing original: TaskBackup, now: Date = Date()) throws -> Revisions? {
        let old = try fingerprints(original), new = try fingerprints(snapshot)
        var changes: [String: String?] = [:]
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] { changes[key] = .some(new[key]) }
        var revisions = original.syncChanges ?? [:]
        record(changes, in: &revisions, now: now)
        return revisions.isEmpty ? nil : revisions
    }

    struct Resolution {
        let local: Revisions, cloud: Revisions, base: Revisions
        let localValues: [String: String], cloudValues: [String: String], baseValues: [String: String]
        init(local: TaskBackup, cloud: TaskBackup, base: TaskBackup?) throws {
            self.local = local.syncChanges ?? [:]; self.cloud = cloud.syncChanges ?? [:]
            self.base = base?.syncChanges ?? [:]
            localValues = try SyncChanges.fingerprints(local); cloudValues = try SyncChanges.fingerprints(cloud)
            baseValues = try base.map(SyncChanges.fingerprints) ?? [:]
        }
        func decision(_ keys: [String]) -> Decision {
            let deletionWithoutBaseline = keys.contains { key in
                guard baseValues[key] == nil else { return false }
                let localDeleted = localValues[key] == nil && local[key] != nil && local[key]?.fingerprint == nil
                let cloudDeleted = cloudValues[key] == nil && cloud[key] != nil && cloud[key]?.fingerprint == nil
                return localDeleted && cloudValues[key] != nil || cloudDeleted && localValues[key] != nil
            }
            return Decision(choice: newest(keys), needsReview: deletionWithoutBaseline)
        }
        func newest(_ keys: [String]) -> CloudMerge.Choice? {
            func lastChange(_ revisions: Revisions, _ values: [String: String]) -> Date? {
                let changed = keys.filter { values[$0] != baseValues[$0] || revisions[$0] != base[$0] }
                guard !changed.isEmpty else { return nil }
                var newest: Date?
                for key in changed {
                    guard let revision = revisions[key], revision.fingerprint == values[key],
                          revision.date <= Date().addingTimeInterval(300) else { return nil }
                    newest = max(newest ?? revision.date, revision.date)
                }
                return newest
            }
            guard let left = lastChange(local, localValues), let right = lastChange(cloud, cloudValues), left != right else { return nil }
            return left > right ? .local : .cloud
        }
        func revisions(for result: TaskBackup) throws -> Revisions? {
            let values = try SyncChanges.fingerprints(result)
            var revisions: Revisions = [:]
            for key in Set(local.keys).union(cloud.keys) {
                let candidates = [local[key], cloud[key]].compactMap { $0 }.filter { $0.fingerprint == values[key] }
                if let revision = candidates.max(by: { $0.date < $1.date }) { revisions[key] = revision }
            }
            return revisions.isEmpty ? nil : revisions
        }
    }
}
