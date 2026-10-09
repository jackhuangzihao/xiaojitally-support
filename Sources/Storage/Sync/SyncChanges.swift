import Foundation
import SwiftData

/// Modification times belong to record contents, never to a snapshot's upload time.
/// Nil fingerprints are deletion tombstones; keep them so an offline device cannot resurrect a row.
enum SyncChanges {
    struct FieldRevision: Codable, Equatable {
        // An old row's first observed value does not reveal when that field last changed.
        var date: Date?
        var fingerprint: String
    }
    struct Revision: Codable, Equatable {
        var date: Date
        var fingerprint: String?
        var fields: [String: FieldRevision]? = nil
    }
    typealias Revisions = [String: Revision]
    struct Decision {
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
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains(date.timeIntervalSince1970)
        }
        func validFingerprint(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let kinds: Set<String> = ["task", "list", "week", "account", "book", "category", "entry"]
        guard revisions.allSatisfy({ key, revision in
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 && kinds.contains(String(parts[0])) && UUID(uuidString: String(parts[1])) != nil,
                  validDate(revision.date), revision.fingerprint.map(validFingerprint) ?? true else { return false }
            guard let fields = revision.fields else { return true }
            let allowed = SyncFields.names(for: String(parts[0]))
            return (revision.fingerprint != nil || fields.isEmpty) && fields.allSatisfy { name, field in
                allowed.contains(name) && validFingerprint(field.fingerprint) && (field.date.map(validDate) ?? true)
            }
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
    static func record(_ fingerprints: [String: String?], in revisions: inout Revisions, now: Date,
                       fieldFingerprints: [String: [String: String]] = [:],
                       previousFieldFingerprints: [String: [String: String]] = [:], createdKeys: Set<String> = []) {
        func timestamp(_ now: Date, after previous: Date?) -> Date {
            let milliseconds = (now.timeIntervalSince1970 * 1000).rounded()
            let minimum = previous.map { ($0.timeIntervalSince1970 * 1000).rounded() + 1 } ?? milliseconds
            return Date(timeIntervalSince1970: max(milliseconds, minimum) / 1000)
        }
        for (key, fingerprint) in fingerprints {
            let old = revisions[key]
            let changed = old?.fingerprint != fingerprint || old == nil
            // Integer milliseconds preserve ordering and survive the backup's epoch-date conversion exactly.
            var date = changed ? timestamp(now, after: old?.date) : old?.date ?? timestamp(now, after: nil)
            var fields = fingerprint == nil ? nil : old?.fields
            if fingerprint != nil, let hashes = fieldFingerprints[key] {
                fields = hashes.mapValues { FieldRevision(date: nil, fingerprint: $0) }
                for (name, hash) in hashes {
                    let stamp = old?.fields?[name]
                    let before = previousFieldFingerprints[key]?[name] ?? stamp?.fingerprint
                    if changed && (createdKeys.contains(key) || before.map { $0 != hash } == true) {
                        let fieldDate = timestamp(date, after: stamp?.date)
                        fields?[name] = FieldRevision(date: fieldDate, fingerprint: hash)
                    } else if stamp?.fingerprint == hash {
                        fields?[name] = stamp
                    }
                }
                date = max(date, fields?.values.compactMap(\.date).max() ?? date)
            }
            revisions[key] = Revision(date: date, fingerprint: fingerprint, fields: fields)
        }
    }
    @MainActor static func trackModels(in context: ModelContext, now: Date = Date()) throws {
        var changes: [String: String?] = [:]
        var fields: [String: [String: String]] = [:]
        var insertedKeys: Set<String> = [], deletedKeys: Set<String> = []
        let deleted = context.deletedModelsArray
        let deletedIDs = Set(deleted.map(\.persistentModelID))
        let insertedIDs = Set(context.insertedModelsArray.map(\.persistentModelID))
        // A replacement may delete and insert the same business ID in one transaction.
        let liveChanges = (context.insertedModelsArray + context.changedModelsArray).filter { !deletedIDs.contains($0.persistentModelID) }
        for model in deleted + liveChanges {
            let key: String, hash: String?
            let isDeleted = deletedIDs.contains(model.persistentModelID)
            if let task = model as? TaskItem {
                key = self.key("task", task.id)
                if isDeleted { hash = nil }
                else {
                    let record = TaskBackup.TaskRecord(task)
                    hash = try fingerprint(record); fields[key] = try SyncFields.hashes(record)
                }
            } else if let list = model as? TaskList {
                key = self.key("list", list.id)
                if isDeleted { hash = nil }
                else {
                    let record = TaskBackup.ListRecord(id: list.id, name: list.name, createdAt: list.createdAt, parentID: list.parentID, colorHex: list.colorHex, sortOrder: list.sortOrder, emoji: list.emoji)
                    hash = try fingerprint(record); fields[key] = try SyncFields.hashes(record)
                }
            } else if let week = model as? CalendarWeekTitle {
                let record = TaskBackup.WeekTitleRecord(week: week.week, title: week.title)
                key = self.key("week", record.id)
                hash = isDeleted ? nil : try fingerprint(record)
                if !isDeleted { fields[key] = try SyncFields.hashes(record) }
            } else { continue }
            changes[key] = .some(hash)
            if isDeleted { deletedKeys.insert(key) }
            else if insertedIDs.contains(model.persistentModelID) { insertedKeys.insert(key) }
        }
        guard !changes.isEmpty else { return }
        var revisions = try read(context) ?? [:]
        let created = insertedKeys.subtracting(deletedKeys).filter { revisions[$0] == nil }
        record(changes, in: &revisions, now: now, fieldFingerprints: fields, createdKeys: Set(created))
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
        let before = try Dictionary(uniqueKeysWithValues: (previous?.entries ?? []).filter { changes[key("entry", $0.id)] != nil }
            .map { (key("entry", $0.id), try SyncFields.hashes($0)) })
        let after = try Dictionary(uniqueKeysWithValues: next.entries.filter { changes[key("entry", $0.id)] != nil }
            .map { (key("entry", $0.id), try SyncFields.hashes($0)) })
        record(changes, in: &revisions, now: now, fieldFingerprints: after, previousFieldFingerprints: before,
               createdKeys: Set(after.keys).subtracting(before.keys))
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
        // Absent rows cannot produce a restore edit, but their imported deletion history must survive.
        for (key, revision) in snapshot.syncChanges ?? [:] where revision.fingerprint == nil && old[key] == nil && new[key] == nil {
            if let existing = revisions[key], existing.fingerprint == nil, existing.date >= revision.date { continue }
            revisions[key] = revision
        }
        record(changes, in: &revisions, now: now, fieldFingerprints: try SyncFields.snapshot(snapshot),
               previousFieldFingerprints: try SyncFields.snapshot(original), createdKeys: Set(new.keys).subtracting(old.keys))
        return revisions.isEmpty ? nil : revisions
    }

    struct Resolution {
        let local: Revisions, cloud: Revisions, baseRevisions: Revisions
        let localValues: [String: String], cloudValues: [String: String], baseValues: [String: String]
        let localFields: [String: [String: String]], cloudFields: [String: [String: String]], baseFields: [String: [String: String]]
        init(local: TaskBackup, cloud: TaskBackup, base: TaskBackup?) throws {
            self.local = local.syncChanges ?? [:]; self.cloud = cloud.syncChanges ?? [:]
            baseRevisions = base?.syncChanges ?? [:]
            localValues = try SyncChanges.fingerprints(local); cloudValues = try SyncChanges.fingerprints(cloud)
            baseValues = try base.map(SyncChanges.fingerprints) ?? [:]
            localFields = try SyncFields.snapshot(local); cloudFields = try SyncFields.snapshot(cloud)
            baseFields = try base.map(SyncFields.snapshot) ?? [:]
        }
        func decision(_ keys: [String]) -> Decision {
            let deletionWithoutBaseline = keys.contains { key in
                guard baseValues[key] == nil else { return false }
                let localDeleted = localValues[key] == nil && local[key] != nil && local[key]?.fingerprint == nil
                let cloudDeleted = cloudValues[key] == nil && cloud[key] != nil && cloud[key]?.fingerprint == nil
                return localDeleted && cloudValues[key] != nil || cloudDeleted && localValues[key] != nil
            }
            // A device clock cannot establish causality between two offline edits.
            return Decision(needsReview: deletionWithoutBaseline)
        }
        func revisions(for result: TaskBackup) throws -> Revisions? {
            let values = try SyncChanges.fingerprints(result)
            let resultFields = try SyncFields.snapshot(result)
            var revisions: Revisions = [:]
            for key in Set(local.keys).union(cloud.keys) {
                let sides = [(local[key], localValues[key], localFields[key]), (cloud[key], cloudValues[key], cloudFields[key])]
                    .filter { $0.0 != nil && $0.0?.fingerprint == $0.1 }
                let candidates = sides.compactMap { $0.0 }.filter { $0.fingerprint == values[key] }
                var revision = candidates.max(by: { $0.date < $1.date })
                if revision == nil, let fingerprint = values[key], baseValues[key] != nil,
                   localValues[key] != nil, cloudValues[key] != nil,
                   let date = sides.compactMap({ $0.0?.date }).max() {
                    // A combined record needs its own fingerprint; retries and device order must agree.
                    revision = Revision(date: date, fingerprint: fingerprint)
                }
                guard var revision else { continue }
                if let hashes = resultFields[key] {
                    var fields: [String: FieldRevision] = [:]
                    for (name, hash) in hashes {
                        let matching = sides.compactMap { candidate, _, actual -> FieldRevision? in
                            guard actual?[name] == hash, let field = candidate?.fields?[name], field.fingerprint == hash else { return nil }
                            return field
                        }
                        fields[name] = matching.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                            ?? FieldRevision(date: nil, fingerprint: hash)
                    }
                    revision.fields = fields
                    revision.date = max(revision.date, fields.values.compactMap(\.date).max() ?? revision.date)
                } else { revision.fields = nil }
                revisions[key] = revision
            }
            return revisions.isEmpty ? nil : revisions
        }
    }
}
