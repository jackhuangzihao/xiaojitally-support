import Foundation
import OSLog
import CloudKit

/// Thin adapter: both CloudKit and the fault-injecting store run the same commit coordinator.
actor CloudKitRecordTransport: CloudRecordTransport {
    static let zoneID = CKRecordZone.ID(zoneName: "Tally", ownerName: CKCurrentUserDefaultName)
    private let coordinator: CloudCommitTransport
    init(container: CKContainer, account: String) throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiSync", isDirectory: true)
        let cache = directory.appendingPathComponent(CloudMerge.digest(Data(account.utf8)) + "-commit15.json")
        coordinator = CloudCommitTransport(store: CloudKitCommitStore(container: container, account: account), cacheURL: cache)
    }
    func fetch() async throws -> CloudState { try await coordinator.fetch() }
    func allowReupload() async throws { try await coordinator.allowReupload() }
    func recoverMigration(with snapshot: TaskBackup, prepared: @Sendable (TaskBackup) async throws -> Void) async throws -> CloudState {
        try await coordinator.recoverMigration(with: snapshot, prepared: prepared)
    }
    func save(_ changes: [String: CloudItem], round: Int64) async throws -> CloudState { try await coordinator.save(changes, round: round) }
    static func rootFailure(_ failures: [Error]) -> Error? {
        failures.first { ($0 as? CKError)?.code != .batchRequestFailed } ?? failures.first
    }
}

actor CloudKitCommitStore: CloudCommitStore {
    private let container: CKContainer
    private let database: CKDatabase
    private let account: String
    private static let headID = CKRecord.ID(recordName: "head", zoneID: CloudKitRecordTransport.zoneID)
    init(container: CKContainer, account: String) { self.container = container; self.database = container.privateCloudDatabase; self.account = account }

    func readHead() async throws -> CloudCommitProtocol.Cursor {
        try await requireAccount()
        var head = try await record(Self.headID)
        if let head {
            guard let format = head["format"] as? Int64, [Int64(CloudRecordCodec.format), 14, Int64(CloudCommitProtocol.format)].contains(format) else {
                throw CloudRecordError.unsupportedFormat(Int(head["format"] as? Int64 ?? -1))
            }
        }
        // Seal the legacy address even when a new head exists: supersededBy alone never fenced old clients.
        let legacy = try await CloudMigration.sealLegacy(in: database, account: account, authorize: { try await self.requireAccount() })
        if let head, [Int64(14), Int64(CloudCommitProtocol.format)].contains(head["format"] as? Int64 ?? -1) {
            let cursor = try Self.cursor(head)
            guard cursor.head.legacyDigest == legacy.digest else { throw CloudRecordError.inconsistentCloud("Legacy migration marker changed") }
            if head["format"] as? Int64 == 14 {
                // Even an interrupted format-14 migration can upgrade; its seed is checked separately.
                var value = cursor.head; value.maintenance = UUID()
                try await requireAccount()
                let result = try await database.modifyRecords(saving: [try Self.setting(value, on: head)], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let saved = result.saveResults[Self.headID] else { throw CloudRecordError.inconsistentCloud("Missing protocol upgrade result") }
                do { return try Self.cursor(saved.get()) }
                catch let error as CKError where error.code == .serverRecordChanged { throw CloudRecordError.changedElsewhere }
            }
            return cursor
        }
        if let head, head["format"] as? Int64 != Int64(CloudRecordCodec.format) { throw CloudRecordError.unsupportedFormat(Int(head["format"] as? Int64 ?? -1)) }
        if legacy.committed { throw CloudRecordError.cloudRemoved }
        let round = head?["round"] as? Int64 ?? 0
        guard round >= 0, round < Int64.max else { throw CloudRecordError.inconsistentCloud("Invalid legacy round") }
        if head == nil {
            let zone = CKRecordZone(zoneID: CloudKitRecordTransport.zoneID)
            let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let saved = result.saveResults[zone.zoneID] else { throw CloudRecordError.inconsistentCloud("Missing zone result") }
            _ = try saved.get()
        }
        let value = CloudCommitProtocol.Head(commit: UUID(), round: round, pages: [],
            migration: .init(previousRound: round, hadHead: head != nil, legacyDigest: legacy.digest), legacyDigest: legacy.digest)
        head = head ?? CKRecord(recordType: "TallyHead", recordID: Self.headID)
        let frozen = try Self.setting(value, on: head!)
        try await requireAccount()
        let result = try await database.modifyRecords(saving: [frozen], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[Self.headID] else { throw CloudRecordError.inconsistentCloud("Missing migration fence") }
        do {
            let cursor = try Self.cursor(saved.get())
            CloudMigration.log.notice("Cloud migration fence saved")
            return cursor
        } catch let error as CKError where error.code == .serverRecordChanged { throw CloudRecordError.changedElsewhere }
    }

    func migrationSeed(_ cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Seed {
        guard let migration = cursor.head.migration else { throw CloudRecordError.inconsistentCloud("No migration source") }
        try await requireAccount()
        if migration.reupload == true { return .init(items: [:], exists: false) }
        let legacy = try await CloudMigration.legacySnapshot(in: database, expectedDigest: migration.legacyDigest, account: account)
        let rows = try await CloudLegacyReader(database: database).read()
        let current = try CloudMigration.completedRows(rows, previousRound: migration.previousRound, hadHead: migration.hadHead)
        if let current { try await CloudMigration.protect(current, account: account, source: "records") }
        // A writer which raced the fence must never be mistaken for part of the completed source.
        let observed = try await record(Self.headID)
        try await requireAccount()
        guard let observed, try Self.cursor(observed) == cursor else { throw CloudRecordError.changedElsewhere }
        return try CloudMigration.seed(records: current, legacy: legacy)
    }

    func prepareReupload() async throws {
        try await requireAccount()
        let existing = try await record(Self.headID)
        if let existing {
            try CloudMigration.validateReuploadHead(Self.cursor(existing).head)
        } else {
            let zone = CKRecordZone(zoneID: CloudKitRecordTransport.zoneID)
            let result = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let saved = result.saveResults[zone.zoneID] else { throw CloudRecordError.inconsistentCloud("Missing zone result") }
            _ = try saved.get()
        }
        let legacy = try await CloudMigration.sealLegacy(in: database, account: account, authorize: { try await self.requireAccount() })
        let value = try CloudMigration.reuploadHead(existing: existing.map { try Self.cursor($0).head }, legacyDigest: legacy.digest)
        let head = try Self.setting(value, on: existing ?? CKRecord(recordType: "TallyHead", recordID: Self.headID))
        try await requireAccount()
        let result = try await database.modifyRecords(saving: [head], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[Self.headID] else { throw CloudRecordError.inconsistentCloud("Missing re-upload fence") }
        _ = try saved.get()
        try await requireAccount()
        CloudMigration.log.notice("Re-upload checkpoint confirmed; resumed: \(existing != nil, privacy: .public)")
    }

    func prepareMigrationRecovery(_ local: TaskBackup) async throws -> (CloudCommitProtocol.Cursor, CloudCommitProtocol.Seed) {
        let expected = try await readHead()
        guard let migration = expected.head.migration, migration.hadHead, migration.reupload != true else {
            throw CloudRecordError.changedElsewhere
        }
        let legacy = try await CloudMigration.legacySnapshot(in: database, expectedDigest: migration.legacyDigest, account: account)
        let rows = try await CloudLegacyReader(database: database).read()
        guard let records = try CloudMigration.completedRows(rows, previousRound: migration.previousRound, hadHead: true) else {
            throw CloudRecordError.migrationIncomplete
        }
        try await CloudMigration.protect(local, account: account, source: "local")
        try await CloudMigration.protect(records, account: account, source: "records")
        let seed = try CloudMigration.recoverySeed(local: local, records: records, legacy: legacy)
        try await requireAccount()
        guard let observed = try await record(Self.headID), try Self.cursor(observed) == expected else { throw CloudRecordError.changedElsewhere }
        return (expected, seed)
    }

    func immutableRecordNames() async throws -> [String] {
        try await requireAccount()
        let names = try await CloudInventory.immutableRecordNames(in: database, zoneID: CloudKitRecordTransport.zoneID)
        try await requireAccount()
        return names
    }

    func collect(_ names: [String], replacing cursor: CloudCommitProtocol.Cursor, finishing: Bool) async throws -> CloudCommitProtocol.Cursor {
        guard names.count < CloudCommitProtocol.batchSize, Set(names).count == names.count,
              names.allSatisfy(CloudCommitProtocol.validName) else { throw CloudRecordError.inconsistentCloud("Invalid collection batch") }
        let value = try CloudRetention.checkpoint(cursor, finishing: finishing)
        let head = try Self.setting(value, on: Self.restore(cursor.tag))
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: CloudKitRecordTransport.zoneID) }
        try await requireAccount()
        do {
            // The CAS and deletes MUST share one atomic operation; a prior check cannot fence late writers.
            let result = try await database.modifyRecords(saving: [head], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[Self.headID] else { throw CloudRecordError.inconsistentCloud("Missing collection checkpoint") }
            let next = try Self.cursor(saved.get())
            for id in ids {
                guard let deleted = result.deleteResults[id] else { throw CloudRecordError.inconsistentCloud("Missing deletion result") }
                try deleted.get()
            }
            try await requireAccount()
            return next
        } catch let error as CKError where error.code == .serverRecordChanged { throw CloudRecordError.changedElsewhere }
    }

    func readBlobs(_ names: [String]) async throws -> [String: Data] {
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: CloudKitRecordTransport.zoneID) }
        let records = try await database.records(for: ids, desiredKeys: ["bytes"])
        var values: [String: Data] = [:]
        for id in ids {
            guard let result = records[id] else { throw CloudRecordError.inconsistentCloud("Missing fetch result") }
            let record: CKRecord
            do { record = try result.get() }
            catch let error as CKError where error.code == .unknownItem { throw CloudRecordError.missingBlob }
            guard record.recordType == "TallyImmutable", let data = record.encryptedValues["bytes"] as? Data else {
                throw CloudRecordError.inconsistentCloud("Invalid immutable record type")
            }
            try CloudCommitProtocol.validate(data, named: id.recordName); values[id.recordName] = data
        }
        return values
    }

    func writeBlobs(_ blobs: [String: Data]) async throws {
        guard blobs.count <= CloudCommitProtocol.batchSize else { throw CloudRecordError.inconsistentCloud("Oversized batch") }
        try await CloudBlobUpload.write(blobs) { try await self.writeBlobBatch($0) }
    }

    private func writeBlobBatch(_ blobs: [String: Data]) async throws -> CloudBlobUpload.Results {
        try await requireAccount()
        let records = try blobs.map { name, bytes -> CKRecord in
            try CloudCommitProtocol.validate(bytes, named: name)
            let record = CKRecord(recordType: "TallyImmutable", recordID: CKRecord.ID(recordName: name, zoneID: CloudKitRecordTransport.zoneID))
            record.encryptedValues["bytes"] = bytes
            return record
        }
        let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        var outcomes: CloudBlobUpload.Results = [:]
        for record in records {
            guard let saved = result.saveResults[record.recordID] else { throw CloudRecordError.inconsistentCloud("Missing save result") }
            do { _ = try saved.get(); outcomes[record.recordID.recordName] = .success(()) }
            catch let error as CKError where error.code == .serverRecordChanged {
                // A concurrent writer may have created this version. Verify it, never overwrite it.
                guard let server = error.serverRecord, server.recordType == "TallyImmutable",
                      server.recordID == record.recordID, server.encryptedValues["bytes"] as? Data == blobs[record.recordID.recordName] else {
                    throw CloudRecordError.inconsistentCloud("Immutable record collision")
                }
                outcomes[record.recordID.recordName] = .success(())
            } catch { outcomes[record.recordID.recordName] = .failure(error) }
        }
        return outcomes
    }

    func publish(_ value: CloudCommitProtocol.Head, replacing cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Cursor {
        try await requireAccount()
        guard value.migration == nil, value.round == cursor.head.round + 1 else { throw CloudRecordError.inconsistentCloud("Invalid publication") }
        let record = try Self.restore(cursor.tag)
        // Seal completion before publication. If the zone is later removed, the old asset must never resurrect it.
        // A failed head CAS leaves a resumable staging head; this marker does not make staged blobs visible.
        try await CloudMigration.markCommitted(in: database, digest: value.legacyDigest, authorize: { try await self.requireAccount() })
        try await requireAccount()
        let result = try await database.modifyRecords(saving: [try Self.setting(value, on: record)], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let saved = result.saveResults[Self.headID] else { throw CloudRecordError.inconsistentCloud("Missing commit result") }
        do {
            let committed = try Self.cursor(saved.get())
            CloudMigration.log.notice("Published complete cloud commit, round \(value.round, privacy: .public)")
            return committed
        } catch let error as CKError where error.code == .serverRecordChanged { throw CloudRecordError.changedElsewhere }
    }

    private func requireAccount() async throws {
        try Task.checkCancellation()
        guard try await container.userRecordID().recordName == account else {
            throw TaskBackup.invalid(L("iCloud 账户已改变，已停止这次同步。本地数据已保留。", "The iCloud account changed. This sync stopped and local data is retained."))
        }
        try Task.checkCancellation()
    }
    private func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return nil }
    }
    private static func setting(_ value: CloudCommitProtocol.Head, on record: CKRecord) throws -> CKRecord {
        try CloudCommitProtocol.validate(value)
        let bytes = try CloudCommitProtocol.encode(value)
        guard bytes.count <= CloudCommitProtocol.maximumBlobBytes else { throw CloudRecordError.itemTooLarge("manifest root") }
        record["format"] = Int64(CloudCommitProtocol.format); record["round"] = value.round
        record.encryptedValues["commit"] = bytes
        return record
    }
    static func cursor(_ record: CKRecord) throws -> CloudCommitProtocol.Cursor {
        guard record.recordID == headID, record.recordType == "TallyHead", [Int64(14), Int64(CloudCommitProtocol.format)].contains(record["format"] as? Int64 ?? -1),
              let data = record.encryptedValues["commit"] as? Data, data.count <= CloudCommitProtocol.maximumBlobBytes else {
            throw CloudRecordError.inconsistentCloud("Missing commit header")
        }
        let value = try JSONDecoder().decode(CloudCommitProtocol.Head.self, from: data)
        try CloudCommitProtocol.validate(value)
        guard value.round >= 0, value.round < Int64.max, value.round == record["round"] as? Int64 else { throw CloudRecordError.inconsistentCloud("Invalid head round") }
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding()
        return .init(head: value, tag: coder.encodedData)
    }
    private static func restore(_ data: Data) throws -> CKRecord {
        let coder = try NSKeyedUnarchiver(forReadingFrom: data); coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordID == headID else { throw CloudRecordError.inconsistentCloud("Invalid head change tag") }
        return record
    }
}
