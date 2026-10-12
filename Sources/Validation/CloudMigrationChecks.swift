import Foundation
import CloudKit
import SwiftData

/// Real migration decisions without an account: causal upgrades, old-writer forks and explicit recovery.
@MainActor enum CloudMigrationChecks {
    static func run(sample: TaskBackup) throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD MIGRATION CHECK: " + label) }; count += 1
        }
        func review(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() }
            catch CloudRecordError.migrationReview { count += 1; return }
            throw TaskBackup.invalid("CLOUD MIGRATION CHECK: " + label)
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { count += 1; return }
            throw TaskBackup.invalid("CLOUD MIGRATION CHECK: " + label)
        }
        func payloads(_ snapshot: TaskBackup) throws -> [String: Data] {
            try CloudRecordCodec.items(snapshot).compactMapValues(\.payload)
        }
        func edit(_ original: TaskBackup, actor: UUID, date: Date, _ change: (inout TaskBackup) -> Void) throws -> TaskBackup {
            var result = original; change(&result)
            let old = try SyncChanges.fingerprints(original), new = try SyncChanges.fingerprints(result)
            var changes: [String: String?] = [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] { changes[key] = .some(new[key]) }
            var history = original.syncChanges ?? [:]
            SyncChanges.record(changes, in: &history, now: date, fieldFingerprints: try SyncFields.snapshot(result),
                previousFieldFingerprints: try SyncFields.snapshot(original), createdKeys: Set(new.keys).subtracting(old.keys),
                actor: actor, previousFingerprints: old)
            result.syncChanges = history
            try result.validate()
            return result
        }

        let left = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        let right = UUID(uuidString: "00000000-0000-0000-0000-0000000000AC")!
        let taskKey = SyncChanges.key("task", sample.tasks[0].id)
        for iteration in 0..<6 {
            let date = Date(timeIntervalSince1970: 1_800_100_000 + Double(iteration * 20))
            var oldBackup = sample; oldBackup.version = 7; oldBackup.syncChanges = nil
            let oldSnapshot = try TaskBackup.decode(oldBackup.encoded())
            try check(oldSnapshot.version == 7 && oldSnapshot.syncChanges == nil, "old snapshot really has no causal metadata")
            var firstHistory = try edit(oldSnapshot, actor: left, date: date) { $0.tasks[0].title = "First tracked edit" }
            firstHistory.version = 13
            let oldUpgrade = try CloudRecordCodec.snapshot(CloudMigration.seed(records: firstHistory, legacy: oldSnapshot).items)
            try check(try payloads(oldUpgrade) == payloads(firstHistory), "first protocol 13 edit proves the observed legacy value")
            let laterID = UUID()
            let oldAdded = try edit(firstHistory, actor: left, date: date.addingTimeInterval(1)) {
                $0.lists.append(.init(id: laterID, name: "Added after format 7", createdAt: date))
            }
            try check(try payloads(CloudRecordCodec.snapshot(CloudMigration.seed(records: oldAdded, legacy: oldSnapshot).items)) == payloads(oldAdded),
                "format 7 snapshot followed by protocol 13 edits and additions upgrades intact")
            let updated = try edit(sample, actor: left, date: date) { $0.tasks[0].title = "Updated \(iteration)" }
            let migrated = try CloudRecordCodec.snapshot(CloudMigration.seed(records: updated, legacy: sample).items)
            try check(try payloads(migrated) == payloads(updated), "completed protocol 13 edit upgrades automatically")
            try check(migrated.syncChanges?[taskKey]?.version?.contains(sample.syncChanges![taskKey]!.version!) == true,
                "migration retains the source causal history")
            try check(try CloudMigration.seed(records: migrated, legacy: sample).items == CloudRecordCodec.items(migrated),
                "retry from a sealed head is deterministic")

            let addedID = UUID()
            let added = try edit(updated, actor: left, date: date.addingTimeInterval(1)) {
                $0.lists.append(.init(id: addedID, name: "Later list", createdAt: date))
            }
            let addedSeed = try CloudRecordCodec.snapshot(CloudMigration.seed(records: added, legacy: sample).items)
            try check(addedSeed.lists.contains { $0.id == addedID }, "new rows added after snapshot migration survive")
            let removed = try edit(added, actor: left, date: date.addingTimeInterval(2)) { $0.lists.removeAll { $0.id == addedID } }
            let removedSeed = try CloudRecordCodec.snapshot(CloudMigration.seed(records: removed, legacy: added).items)
            try check(!removedSeed.lists.contains { $0.id == addedID }, "causally proven deletion upgrades")
            try check(removedSeed.syncChanges?[SyncChanges.key("list", addedID)]?.fingerprint == nil,
                "deletion history remains a tombstone")
            let financeEdit = try edit(sample, actor: left, date: date.addingTimeInterval(2)) {
                $0.finance!.entries[0].amount += 3; $0.finance!.entries[0].accountAmount += 3
            }
            let financeSeed = try CloudRecordCodec.snapshot(CloudMigration.seed(records: financeEdit, legacy: sample).items)
            try check(try payloads(financeSeed) == payloads(financeEdit), "posted finance edits preserve their amount and account linkage")

            let fork = try edit(sample, actor: right, date: date.addingTimeInterval(3)) { $0.tasks[0].title = "Old client edit" }
            try review("old snapshot writer's concurrent edit is never discarded") {
                _ = try CloudMigration.seed(records: updated, legacy: fork)
            }
            let laterLegacy = try edit(updated, actor: right, date: date.addingTimeInterval(4)) { $0.tasks[0].notes = "New old-client note" }
            try review("a superseded snapshot can still contain a newer edit") {
                _ = try CloudMigration.seed(records: updated, legacy: laterLegacy)
            }
            var untracked = updated; untracked.syncChanges = nil
            try review("timestamps alone cannot prove an upgrade") { _ = try CloudMigration.seed(records: untracked, legacy: sample) }
            var missing = added; missing.lists.removeAll { $0.id == addedID }; missing.syncChanges?[SyncChanges.key("list", addedID)] = nil
            try review("removal without a tombstone requires review") { _ = try CloudMigration.seed(records: missing, legacy: added) }

            let equivalent = try edit(sample, actor: right, date: date.addingTimeInterval(5)) { $0.tasks[0].title = updated.tasks[0].title }
            let sameValue = try CloudRecordCodec.snapshot(CloudMigration.seed(records: updated, legacy: equivalent).items)
            let sameVersion = sameValue.syncChanges![taskKey]!.version!
            try check(sameVersion.contains(updated.syncChanges![taskKey]!.version!)
                      && sameVersion.contains(equivalent.syncChanges![taskKey]!.version!), "equal contents retain both histories")

            let recovered = try CloudRecordCodec.snapshot(CloudMigration.recoverySeed(local: sample, records: updated, legacy: fork).items)
            try check(try payloads(recovered) == payloads(sample), "explicit recovery keeps exactly the local business contents")
            let recoveryVersion = recovered.syncChanges![taskKey]!.version!
            try check(recoveryVersion.dominates(updated.syncChanges![taskKey]!.version!)
                      && recoveryVersion.dominates(fork.syncChanges![taskKey]!.version!), "confirmation acknowledges both competing histories")
            try check(try CloudMigration.recoverySeed(local: sample, records: updated, legacy: fork).items == CloudRecordCodec.items(recovered),
                "interrupted recovery retries produce the same history")
            for old in [updated, fork] {
                let merged = try CloudMerge.mergeResult(local: old, cloud: recovered, base: nil).snapshot
                try check(try payloads(merged) == payloads(sample), "another device honors the recovered choice")
            }
            let empty = TaskBackup(lists: [], tasks: [])
            let emptied = try CloudRecordCodec.snapshot(CloudMigration.recoverySeed(local: empty, records: added, legacy: sample).items)
            try check(try payloads(emptied).isEmpty, "explicit empty local recovery removes all business rows")
            try check(emptied.syncChanges?[SyncChanges.key("list", addedID)]?.version?.dominates(added.syncChanges![SyncChanges.key("list", addedID)]!.version!) == true,
                "cloud-only rows receive acknowledged tombstones")
        }

        for marker in [Optional<String>.none, "Tally", "Tally-commit14"] {
            let record = CKRecord(recordType: "TallySnapshot", recordID: CloudMigration.legacyID)
            record["formatVersion"] = Int64(1); record["supersededBy"] = marker
            record["snapshot"] = Data("asset remains unchanged".utf8)
            try CloudMigration.fence(record, digest: "retained")
            try check(record["supersededBy"] as? String == marker, "sealing preserves existing supersession evidence")
            try check(record["formatVersion"] as? Int64 == 2 && record["snapshot"] as? Data == Data("asset remains unchanged".utf8),
                "compatibility fence retains the asset")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for iteration in 0..<3 {
            let store = try Store.make(url: directory.appendingPathComponent("copy-\(iteration).store")), context = store.mainContext
            try CloudMerge.stage(sample, in: context); try Store.save(context, trackSyncChanges: false)
            let local = try TaskBackup.capture(context), state = try context.fetch(FetchDescriptor<CloudSyncState>()).first!
            state.baseline = try CloudMerge.bytes(local); try Store.save(context, trackSyncChanges: false)
            let baseline = state.baseline
            let cloud = try edit(local, actor: right, date: Date().addingTimeInterval(120)) { $0.tasks[0].title = "Cloud before recovery" }
            let recovered = try CloudRecordCodec.snapshot(CloudMigration.recoverySeed(local: local, records: cloud, legacy: sample).items)
            let originalRevision = Store.revision
            try CloudSync.prepareMigrationHistory(recovered, matching: local, revision: originalRevision, in: context)
            let persisted = try TaskBackup.capture(ModelContext(store))
            try check(try payloads(persisted) == payloads(local), "pre-upload confirmation changes no business contents")
            try check(persisted.syncChanges == recovered.syncChanges && state.baseline == baseline,
                "confirmation is durable before upload while the previous baseline remains unchanged")
            try rejects("a stale editor cannot stage a previous recovery") {
                try CloudSync.prepareMigrationHistory(recovered, matching: local, revision: originalRevision, in: context)
            }
            var invalid = recovered; invalid.tasks[0].title = "Unexpected mutation"
            try rejects("pre-upload confirmation refuses changed business contents") {
                try CloudSync.prepareMigrationHistory(invalid, matching: local, revision: Store.revision, in: context)
            }
            let task = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == sample.tasks[0].id }!
            task.title = "Edited while uploading \(iteration)"
            try rejects("unsaved editor changes remain untouched") {
                try CloudSync.prepareMigrationHistory(recovered, matching: local, revision: Store.revision, in: context)
            }
            try check(task.title == "Edited while uploading \(iteration)" && context.hasChanges, "refused preparation leaves the editor draft intact")
            try Store.save(context)
            let current = try TaskBackup.capture(context)
            let merged = try CloudMerge.mergeResult(local: current, cloud: recovered, base: local).snapshot
            try check(try payloads(merged) == payloads(current), "new edit wins causally even when the old cloud clock is ahead")
            let financeEdit = try edit(current, actor: left, date: Date()) {
                $0.finance!.entries[0].amount += 7; $0.finance!.entries[0].accountAmount += 7
            }
            let financeMerged = try CloudMerge.mergeResult(local: financeEdit, cloud: recovered, base: local).snapshot
            try check(try payloads(financeMerged) == payloads(financeEdit), "new financial edits after confirmation need no second conflict review")
        }
        print("CLOUD MIGRATION PASS: \(count) checks")
        return count
    }
}
