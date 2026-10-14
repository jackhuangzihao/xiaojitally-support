import Foundation
import SwiftData

/// Modification times belong to record contents, never to a snapshot's upload time.
/// Nil fingerprints are deletion tombstones; keep them so an offline device cannot resurrect a row.
enum SyncChanges {
    struct FieldRevision: Codable, Equatable, Sendable {
        // An old row's first observed value does not reveal when that field last changed.
        var date: Date?
        var fingerprint: String
        var version: SyncVersion? = nil

        init(date: Date?, fingerprint: String, version: SyncVersion? = nil) {
            self.date = date; self.fingerprint = fingerprint; self.version = version
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decodeIfPresent(Date.self, forKey: .date)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            version = try container.decodeSyncVersion(forKey: .version)
        }
    }
    struct Revision: Codable, Equatable, Sendable {
        var date: Date
        var fingerprint: String?
        var fields: [String: FieldRevision]? = nil
        var version: SyncVersion? = nil

        init(date: Date, fingerprint: String?, fields: [String: FieldRevision]? = nil, version: SyncVersion? = nil) {
            self.date = date; self.fingerprint = fingerprint; self.fields = fields; self.version = version
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(Date.self, forKey: .date)
            fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
            fields = try container.decodeIfPresent([String: FieldRevision].self, forKey: .fields)
            version = try container.decodeSyncVersion(forKey: .version)
        }
    }
    typealias Revisions = [String: Revision]
    struct Decision {
        var needsReview: Bool
    }
    /// Record kinds that belong to the ledger; a base-currency change or ledger-level conflict holds them together.
    static let financeKinds: Set<String> = ["account", "book", "category", "entry", "recurring", "setting", "rate"]
    static func isFinanceKey(_ key: String) -> Bool { financeKinds.contains(String(key.prefix { $0 != ":" })) }
    static let currencyKey = key("setting", TaskItem.syncIdentity("sync-finance-currency"))
    static func rateKey(_ pair: String) -> String { key("rate", TaskItem.syncIdentity("sync-finance-rate:" + pair)) }
    static func financeSettings(_ finance: FinanceData?) throws -> [String: String] {
        guard let finance else { return [:] }
        var result = [currencyKey: try fingerprint(finance.baseCurrency)]
        for (pair, rates) in Dictionary(grouping: finance.rates, by: { [$0.base, $0.quote].sorted().joined(separator: "/") }) {
            result[rateKey(pair)] = try fingerprint(rates.sorted { $0.base < $1.base })
        }
        return result
    }
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
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let kinds = financeKinds.union(["task", "list", "week"])
        guard revisions.allSatisfy({ key, revision in
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 && kinds.contains(String(parts[0])) && UUID(uuidString: String(parts[1])) != nil,
                  validDate(revision.date), revision.fingerprint.map(validFingerprint) ?? true,
                  revision.version?.isValid ?? true else { return false }
            guard let fields = revision.fields else { return true }
            let kind = String(parts[0])
            return (revision.fingerprint != nil || fields.isEmpty) && fields.allSatisfy { name, field in
                SyncFields.allows(name, kind: kind) && validFingerprint(field.fingerprint) && (field.date.map(validDate) ?? true)
                    && (field.version?.isValid ?? true)
            }
        }) else { throw TaskBackup.invalid(L("同步修改记录无效。", "Invalid sync modification records.")) }
    }

    static func record(_ fingerprints: [String: String?], in revisions: inout Revisions, now: Date,
                       fieldFingerprints: [String: [String: String]] = [:],
                       previousFieldFingerprints: [String: [String: String]] = [:], createdKeys: Set<String> = [], actor: UUID? = nil,
                       previousFingerprints: [String: String] = [:]) {
        func timestamp(_ now: Date, after previous: Date?) -> Date {
            let milliseconds = (now.timeIntervalSince1970 * 1000).rounded()
            let minimum = previous.map { ($0.timeIntervalSince1970 * 1000).rounded() + 1 } ?? milliseconds
            return Date(timeIntervalSince1970: max(milliseconds, minimum) / 1000)
        }
        for (key, fingerprint) in fingerprints {
            if actor != nil, revisions[key] == nil, let before = previousFingerprints[key] {
                let fields = previousFieldFingerprints[key]?.mapValues { FieldRevision(date: nil, fingerprint: $0) }
                revisions[key] = Revision(date: Date(timeIntervalSince1970: 0), fingerprint: before, fields: fields,
                    version: SyncVersion.observed(key: key, fingerprint: before))
            }
            let old = revisions[key]
            let changed = old?.fingerprint != fingerprint || old == nil
            let previousVersion = old?.version ?? old.flatMap { SyncVersion.legacy(key: key, fingerprint: $0.fingerprint, date: $0.date) }
            let event = changed ? actor.map { SyncVersion.next(after: previousVersion, actor: $0, now: now) } : old?.version
            // Integer milliseconds preserve ordering and survive the backup's epoch-date conversion exactly.
            var date = changed ? timestamp(now, after: old?.date) : old?.date ?? timestamp(now, after: nil)
            var fields = fingerprint == nil ? nil : old?.fields
            if fingerprint != nil, let rawHashes = fieldFingerprints[key] {
                var hashes = rawHashes
                let absent = try? self.fingerprint(Optional<String>.none)
                for name in old?.fields?.keys ?? [:].keys where name.hasPrefix("subtask:") && hashes[name] == nil {
                    hashes[name] = absent
                }
                fields = hashes.mapValues { FieldRevision(date: nil, fingerprint: $0) }
                for (name, hash) in hashes {
                    let stamp = old?.fields?[name]
                    let before = previousFieldFingerprints[key]?[name] ?? stamp?.fingerprint ?? (name.hasPrefix("subtask:") ? absent : nil)
                    if changed && (createdKeys.contains(key) || before.map { $0 != hash } == true) {
                        let fieldDate = timestamp(date, after: stamp?.date)
                        let version = event.map { event in
                            let ancestor = stamp?.version ?? stamp.flatMap {
                                SyncVersion.legacy(key: key + ":" + name, fingerprint: $0.fingerprint, date: $0.date)
                            } ?? before.map { SyncVersion.observed(key: key + ":" + name, fingerprint: $0) }
                            guard let ancestor, let actor else { return event }
                            // The field may have seen later stamps than the record; its edit must still be the latest of them.
                            let joined = event.joined(with: ancestor)
                            return joined.clock.values.allSatisfy { $0 <= event.winner.stamp } ? joined
                                : SyncVersion.next(after: joined, actor: actor, now: now)
                        }
                        fields?[name] = FieldRevision(date: fieldDate, fingerprint: hash, version: version)
                    } else if stamp?.fingerprint == hash {
                        fields?[name] = stamp
                    }
                }
                date = max(date, fields?.values.compactMap(\.date).max() ?? date)
            }
            revisions[key] = Revision(date: date, fingerprint: fingerprint, fields: fields, version: event)
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
        let created = Set(insertedKeys.subtracting(deletedKeys).filter { revisions[$0] == nil })
        // Old stores have no field history. Read only affected committed rows to distinguish the first real edit.
        let previous = try legacyRecords(for: Set(changes.keys).subtracting(created).filter { revisions[$0] == nil }, in: context)
        record(changes, in: &revisions, now: now, fieldFingerprints: fields,
               previousFieldFingerprints: previous.fields, createdKeys: created, actor: SyncVersion.deviceID,
               previousFingerprints: previous.values)
        try stage(revisions, in: context)
    }
    @MainActor private static func legacyRecords(for keys: Set<String>, in context: ModelContext) throws
        -> (values: [String: String], fields: [String: [String: String]]) {
        guard !keys.isEmpty else { return ([:], [:]) }
        let committed = ModelContext(context.container); committed.autosaveEnabled = false
        var values: [String: String] = [:], fields: [String: [String: String]] = [:]
        for key in keys {
            guard let id = UUID(uuidString: String(key.suffix(36))) else { continue }
            if key.hasPrefix("task:") {
                var fetch = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }); fetch.fetchLimit = 1
                if let task = try committed.fetch(fetch).first {
                    let record = TaskBackup.TaskRecord(task)
                    values[key] = try fingerprint(record); fields[key] = try SyncFields.hashes(record)
                }
            } else if key.hasPrefix("list:") {
                var fetch = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id }); fetch.fetchLimit = 1
                if let list = try committed.fetch(fetch).first {
                    let record = TaskBackup.ListRecord(id: list.id, name: list.name, createdAt: list.createdAt, parentID: list.parentID,
                        colorHex: list.colorHex, sortOrder: list.sortOrder, emoji: list.emoji)
                    values[key] = try fingerprint(record); fields[key] = try SyncFields.hashes(record)
                }
            } else if key.hasPrefix("week:") {
                for week in try committed.fetch(FetchDescriptor<CalendarWeekTitle>()) {
                    let record = TaskBackup.WeekTitleRecord(week: week.week, title: week.title)
                    if record.id == id { values[key] = try fingerprint(record); fields[key] = try SyncFields.hashes(record); break }
                }
            }
        }
        return (values, fields)
    }
    @MainActor static func trackFinance(from previous: FinanceData?, to next: FinanceData, in context: ModelContext, now: Date = Date()) throws {
        var changes: [String: String?] = [:], previousValues: [String: String] = [:]
        @discardableResult
        func collect<T: Encodable & Equatable & Identifiable>(_ before: [T], _ after: [T], kind: String) throws -> Set<UUID> where T.ID == UUID {
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
            for id in changed {
                if let before = old[id] { previousValues[key(kind, id)] = try fingerprint(before) }
                if let value = new[id] { changes[key(kind, id)] = try fingerprint(value) }
                else { changes[key(kind, id)] = .some(nil) }
            }
            return changed
        }
        try collect(previous?.accounts ?? [], next.accounts, kind: "account")
        try collect(previous?.books ?? [], next.books, kind: "book")
        try collect(previous?.categories ?? [], next.categories, kind: "category")
        let changedEntryIDs = try collect(previous?.entries ?? [], next.entries, kind: "entry")
        try collect(previous?.recurringBills ?? [], next.recurringBills, kind: "recurring")
        let oldSettings = try financeSettings(previous), newSettings = try financeSettings(next)
        for key in Set(oldSettings.keys).union(newSettings.keys) where oldSettings[key] != newSettings[key] {
            changes[key] = .some(newSettings[key]); previousValues[key] = oldSettings[key]
        }
        guard !changes.isEmpty else { return }
        var revisions = try read(context) ?? [:]
        // Compare native IDs while scanning; only changed entries need string keys and field hashes.
        let before = try Dictionary(uniqueKeysWithValues: (previous?.entries ?? []).filter { changedEntryIDs.contains($0.id) }
            .map { (key("entry", $0.id), try SyncFields.hashes($0)) })
        let after = try Dictionary(uniqueKeysWithValues: next.entries.filter { changedEntryIDs.contains($0.id) }
            .map { (key("entry", $0.id), try SyncFields.hashes($0)) })
        record(changes, in: &revisions, now: now, fieldFingerprints: after, previousFieldFingerprints: before,
               createdKeys: Set(after.keys).subtracting(before.keys), actor: SyncVersion.deviceID, previousFingerprints: previousValues)
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
            try collect(finance.recurringBills, kind: "recurring", id: { $0.id })
            values.merge(try financeSettings(finance)) { current, _ in current }
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
            if let existing = revisions[key], existing.fingerprint == nil {
                var merged = existing.date >= revision.date ? existing : revision
                if existing.version != nil || revision.version != nil {
                    let left = existing.version ?? (SyncVersion.legacy(key: key, fingerprint: nil, date: existing.date) ?? SyncVersion.observed(key: key, fingerprint: nil))
                    let right = revision.version ?? (SyncVersion.legacy(key: key, fingerprint: nil, date: revision.date) ?? SyncVersion.observed(key: key, fingerprint: nil))
                    let preferred = SyncVersion.precedes(left.winner, right.winner) ? right : left
                    merged.version = preferred.joined(with: left).joined(with: right)
                }
                revisions[key] = merged
            } else { revisions[key] = revision }
        }
        record(changes, in: &revisions, now: now, fieldFingerprints: try SyncFields.snapshot(snapshot),
               previousFieldFingerprints: try SyncFields.snapshot(original), createdKeys: Set(new.keys).subtracting(old.keys), actor: SyncVersion.deviceID, previousFingerprints: old)
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
            let leftFields = try SyncFields.snapshot(local), rightFields = try SyncFields.snapshot(cloud)
            let originalFields = try base.map(SyncFields.snapshot) ?? [:]
            let fieldKeys = Set(leftFields.keys).union(rightFields.keys).union(originalFields.keys)
            func completed(_ source: [String: [String: String]]) throws -> [String: [String: String]] {
                var result = source
                for key in fieldKeys where source[key] != nil {
                    let names = Set(leftFields[key]?.keys ?? [:].keys).union(rightFields[key]?.keys ?? [:].keys)
                        .union(originalFields[key]?.keys ?? [:].keys)
                    result[key] = try SyncFields.complete(source[key]!, retaining: Array(names))
                }
                return result
            }
            localFields = try completed(leftFields); cloudFields = try completed(rightFields); baseFields = try completed(originalFields)
        }
        struct Side {
            let revision: Revision
            let fingerprint: String?
            let version: SyncVersion?
            let genuineVersion: Bool
        }
        func side(_ side: CloudMerge.Choice, key: String, field: String? = nil, base: Bool = false) -> Side? {
            let history = base ? baseRevisions : (side == .local ? local : cloud)
            let values = base ? baseValues : (side == .local ? localValues : cloudValues)
            let fields = base ? baseFields : (side == .local ? localFields : cloudFields)
            let revision: Revision
            if let stored = history[key] {
                guard stored.fingerprint == values[key] else { return nil }; revision = stored
            } else if values[key] != nil || localValues[key] != nil || cloudValues[key] != nil || baseValues[key] != nil {
                revision = Revision(date: Date(timeIntervalSince1970: 0), fingerprint: values[key])
            } else { return nil }
            if let field {
                guard let actual = fields[key]?[field] ?? (field.hasPrefix("subtask:") && values[key] != nil ? (try? SyncChanges.fingerprint(Optional<String>.none)) : nil) else { return nil }
                let item = revision.fields?[field] ?? FieldRevision(date: nil, fingerprint: actual)
                guard item.fingerprint == actual else { return nil }
                return Side(revision: revision, fingerprint: item.fingerprint,
                    version: item.version ?? SyncVersion.legacy(key: key + ":" + field, fingerprint: item.fingerprint, date: item.date)
                        ?? SyncVersion.observed(key: key + ":" + field, fingerprint: item.fingerprint),
                    genuineVersion: item.version != nil)
            }
            return Side(revision: revision, fingerprint: revision.fingerprint,
                version: revision.version ?? (history[key] == nil ? nil : SyncVersion.legacy(key: key, fingerprint: revision.fingerprint, date: revision.date))
                    ?? SyncVersion.observed(key: key, fingerprint: revision.fingerprint),
                genuineVersion: revision.version != nil)
        }
        func causalChoice(keys: [String], field: String? = nil) -> CloudMerge.Choice? {
            var selected: CloudMerge.Choice?
            for key in keys {
                let leftValue = field.map { localFields[key]?[$0] } ?? localValues[key]
                let rightValue = field.map { cloudFields[key]?[$0] } ?? cloudValues[key]
                if leftValue == rightValue { continue }
                guard let left = side(.local, key: key, field: field), let right = side(.cloud, key: key, field: field),
                      left.genuineVersion || right.genuineVersion, let l = left.version, let r = right.version else { return nil }
                let candidate: CloudMerge.Choice
                if l.dominates(r) { candidate = .local }
                else if r.dominates(l) { candidate = .cloud }
                else { return nil }
                if let selected, selected != candidate { return nil }
                selected = candidate
            }
            return selected
        }
        func unchanged(_ side: CloudMerge.Choice, keys: [String], field: String? = nil) -> Bool {
            keys.allSatisfy { key in
                guard let current = self.side(side, key: key, field: field), current.genuineVersion else { return true }
                guard let previous = self.side(side, key: key, field: field, base: true) else { return false }
                return current.version?.clock == previous.version?.clock
            }
        }
        var financeKeys: [String] {
            Set(localValues.keys).union(cloudValues.keys).union(baseValues.keys).filter {
                SyncChanges.isFinanceKey($0)
            }.sorted()
        }
        func decision(_ keys: [String]) -> Decision {
            let deletionWithoutBaseline = keys.contains { key in
                guard baseValues[key] == nil else { return false }
                let localDeleted = localValues[key] == nil && local[key] != nil && local[key]?.fingerprint == nil
                let cloudDeleted = cloudValues[key] == nil && cloud[key] != nil && cloud[key]?.fingerprint == nil
                return localDeleted && cloudValues[key] != nil || cloudDeleted && localValues[key] != nil
            }
            return Decision(needsReview: deletionWithoutBaseline && causalChoice(keys: keys) == nil)
        }
        func revisions(for result: TaskBackup, acknowledging: Bool = false, confirmations: [String: Set<String>] = [:]) throws -> Revisions? {
            let values = try SyncChanges.fingerprints(result)
            let resultFields = try SyncFields.snapshot(result)
            var revisions: Revisions = [:]
            let keys = Set(local.keys).union(cloud.keys).union(acknowledging ? Set(localValues.keys).union(cloudValues.keys) : [])
            for key in keys {
                func observed(_ revision: Revision?, fingerprint: String?, fields: [String: String]?) -> Revision? {
                    if let revision { return revision }
                    guard acknowledging, let fingerprint else { return nil }
                    return Revision(date: Date(timeIntervalSince1970: 0), fingerprint: fingerprint,
                        fields: fields?.mapValues { FieldRevision(date: nil, fingerprint: $0) })
                }
                let sides = [(observed(local[key], fingerprint: localValues[key], fields: localFields[key]), localValues[key], localFields[key]),
                             (observed(cloud[key], fingerprint: cloudValues[key], fields: cloudFields[key]), cloudValues[key], cloudFields[key])]
                    .filter { $0.0 != nil && $0.0?.fingerprint == $0.1 }
                let candidates = sides.compactMap { $0.0 }.filter { $0.fingerprint == values[key] }
                var revision = candidates.max(by: { $0.date < $1.date })
                if revision == nil, let date = sides.compactMap({ $0.0?.date }).max(),
                   (values[key] == nil || localValues[key] != nil && cloudValues[key] != nil) {
                    revision = Revision(date: date, fingerprint: values[key])
                }
                guard var revision else { continue }
                let causal = acknowledging || sides.contains { $0.0?.version != nil }
                if causal {
                    let available = [side(.local, key: key), side(.cloud, key: key)].compactMap { $0?.version }
                    revision.version = joined(available, preferred: candidates.compactMap(\.version))
                    if confirmations[key] != nil, let version = revision.version {
                        revision.version = SyncVersion.next(after: version, actor: TaskItem.syncIdentity("sync-confirmation:" + key))
                    }
                }
                if let raw = resultFields[key] {
                    let names = Set(sides.flatMap { Array($0.0?.fields?.keys ?? [:].keys) })
                    let hashes = try SyncFields.complete(raw, retaining: Array(names))
                    var fields: [String: FieldRevision] = [:]
                    for (name, hash) in hashes {
                        let available = sides.compactMap { candidate, _, actual -> FieldRevision? in
                            guard let hash = actual?[name] else { return nil }
                            let field = candidate?.fields?[name] ?? FieldRevision(date: nil, fingerprint: hash)
                            return field.fingerprint == hash ? field : nil
                        }
                        let matching = available.filter { $0.fingerprint == hash }
                        var field = matching.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
                            ?? FieldRevision(date: available.compactMap(\.date).max(), fingerprint: hash)
                        if causal || available.contains(where: { $0.version != nil }) {
                            let versions = available.compactMap { $0.version ?? SyncVersion.legacy(key: key + ":" + name, fingerprint: $0.fingerprint, date: $0.date)
                                ?? SyncVersion.observed(key: key + ":" + name, fingerprint: $0.fingerprint) }
                            let winners = matching.compactMap { $0.version ?? SyncVersion.legacy(key: key + ":" + name, fingerprint: $0.fingerprint, date: $0.date)
                                ?? SyncVersion.observed(key: key + ":" + name, fingerprint: $0.fingerprint) }
                            field.version = joined(versions, preferred: winners)
                            if confirmations[key]?.contains("*") == true || confirmations[key]?.contains(name) == true,
                               let version = field.version {
                                field.version = SyncVersion.next(after: version, actor: TaskItem.syncIdentity("sync-confirmation:" + key + ":" + name))
                            }
                        }
                        fields[name] = field
                    }
                    revision.fields = fields
                    revision.date = max(revision.date, fields.values.compactMap(\.date).max() ?? revision.date)
                } else { revision.fields = nil }
                revisions[key] = revision
            }
            return revisions.isEmpty ? nil : revisions
        }
        private func joined(_ versions: [SyncVersion], preferred: [SyncVersion]) -> SyncVersion? {
            guard var result = (preferred.isEmpty ? versions : preferred).max(by: { SyncVersion.precedes($0.winner, $1.winner) }) else { return nil }
            for version in versions { result = result.joined(with: version) }
            return result
        }
    }
}
