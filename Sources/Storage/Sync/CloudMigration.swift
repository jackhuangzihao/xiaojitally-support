import Foundation
import CloudKit
import OSLog

/// Fences old writers before copying anything. Recovery files are never rotated with ordinary backups.
enum CloudMigration {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "CloudMigration")
    static let legacyID = CKRecord.ID(recordName: "tally-personal-v1")
    struct LegacyState: Sendable { let digest: String?; let committed: Bool }

    static func validateReuploadHead(_ head: CloudCommitProtocol.Head) throws {
        try CloudCommitProtocol.validate(head)
        guard head.round == 0, let migration = head.migration, !migration.hadHead,
              migration.reupload == true || head.legacyDigest == nil else {
            throw CloudRecordError.changedElsewhere
        }
    }

    static func reuploadHead(existing: CloudCommitProtocol.Head?, legacyDigest: String?) throws -> CloudCommitProtocol.Head {
        if let existing {
            try validateReuploadHead(existing)
            guard existing.legacyDigest == legacyDigest else { throw CloudRecordError.changedElsewhere }
            // A lost response must resume the same authorized checkpoint, not start another migration.
            if existing.migration?.reupload == true { return existing }
        }
        return .init(commit: UUID(), round: 0, pages: [],
                     migration: .init(previousRound: 0, hadHead: false, legacyDigest: legacyDigest, reupload: true),
                     legacyDigest: legacyDigest)
    }

    static func sealLegacy(in database: CKDatabase, account: String, authorize: @Sendable () async throws -> Void) async throws -> LegacyState {
        let header: CKRecord?
        do {
            let result = try await database.records(for: [legacyID], desiredKeys: ["formatVersion", "digest", "migrationState", "supersededBy"])
            guard let value = result[legacyID] else { throw CloudRecordError.inconsistentCloud("Missing legacy header") }
            header = try value.get()
        } catch let error as CKError where error.code == .unknownItem { header = nil }
        if let header, header["formatVersion"] as? Int64 == 2 {
            guard let status = header["migrationState"] as? String, ["sealed", "committed"].contains(status) else {
                throw CloudRecordError.inconsistentCloud("Unrecognized legacy migration marker")
            }
            return LegacyState(digest: header["digest"] as? String, committed: status == "committed")
        }
        if let header, header["formatVersion"] as? Int64 != 1 { throw CloudRecordError.unsupportedFormat(Int(header["formatVersion"] as? Int64 ?? -1)) }
        let record: CKRecord
        let digest: String?
        if header != nil {
            record = try await database.record(for: legacyID)
            guard record["formatVersion"] as? Int64 == 1 else { throw CloudRecordError.changedElsewhere }
            let snapshot = try await decode(record)
            digest = try await protect(snapshot, account: account, source: "snapshot")
            // The digest protects the retained asset; old clients are blocked by the existing formatVersion check.
            record["digest"] = digest
        } else {
            record = CKRecord(recordType: "TallySnapshot", recordID: legacyID); digest = nil
        }
        try fence(record, digest: digest)
        try await authorize()
        let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let result = saved.saveResults[legacyID] else { throw CloudRecordError.inconsistentCloud("Missing legacy fence result") }
        do { _ = try result.get() }
        catch let error as CKError where error.code == .serverRecordChanged { throw CloudRecordError.changedElsewhere }
        log.notice("Legacy cloud address sealed; retained snapshot: \(digest != nil, privacy: .public)")
        return LegacyState(digest: digest, committed: false)
    }

    /// Mutates only the compatibility header. The retained asset and its business data are untouched.
    static func fence(_ record: CKRecord, digest: String?) throws {
        guard record.recordID == legacyID, record["formatVersion"] == nil || record["formatVersion"] as? Int64 == 1 else {
            throw CloudRecordError.changedElsewhere
        }
        record["formatVersion"] = Int64(2); record["migrationState"] = "sealed"
        record["supersededBy"] = "Tally-commit14"; record["digest"] = digest
    }

    static func legacySnapshot(in database: CKDatabase, expectedDigest: String?, account: String) async throws -> TaskBackup? {
        let record = try await database.record(for: legacyID)
        guard record["formatVersion"] as? Int64 == 2, record["digest"] as? String == expectedDigest else { throw CloudRecordError.changedElsewhere }
        guard let expectedDigest else {
            guard record["snapshot"] == nil else { throw CloudRecordError.inconsistentCloud("Unexpected legacy asset") }
            return nil
        }
        let snapshot = try await decode(record)
        let actual = try await protect(snapshot, account: account, source: "snapshot")
        guard actual == expectedDigest else { throw CloudRecordError.inconsistentCloud("Legacy snapshot digest mismatch") }
        return snapshot
    }

    static func markCommitted(in database: CKDatabase, digest: String?, authorize: @Sendable () async throws -> Void) async throws {
        let result = try await database.records(for: [legacyID], desiredKeys: ["formatVersion", "digest", "migrationState"])
        guard let value = result[legacyID] else { throw CloudRecordError.inconsistentCloud("Missing legacy completion marker") }
        let record = try value.get()
        guard record["formatVersion"] as? Int64 == 2, record["digest"] as? String == digest else { throw CloudRecordError.changedElsewhere }
        if record["migrationState"] as? String == "committed" { return }
        record["migrationState"] = "committed"
        try await authorize()
        let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let outcome = saved.saveResults[legacyID] else { throw CloudRecordError.inconsistentCloud("Missing completion result") }
        _ = try outcome.get()
    }

    static func completedRows(_ rows: [String: (CloudItem, Int64)], previousRound: Int64, hadHead: Bool) throws -> TaskBackup? {
        guard rows.values.allSatisfy({ $0.1 > 0 && $0.1 <= previousRound }), hadHead || rows.isEmpty else {
            throw CloudRecordError.migrationIncomplete
        }
        guard hadHead else { return nil }
        return try CloudRecordCodec.snapshot(rows.mapValues { $0.0 })
    }
    static func seed(records: TaskBackup?, legacy: TaskBackup?) throws -> CloudCommitProtocol.Seed {
        if let records, let legacy {
            let current = try CloudRecordCodec.items(records), previous = try CloudRecordCodec.items(legacy)
            // No shared migration baseline was stored by the old protocol. Do not guess which difference is newer.
            guard current == previous else { throw CloudRecordError.migrationReview }
            return .init(items: current, exists: true)
        }
        if let snapshot = records ?? legacy { return .init(items: try CloudRecordCodec.items(snapshot), exists: true) }
        return .init(items: [:], exists: false)
    }
    private static func decode(_ record: CKRecord) async throws -> TaskBackup {
        guard let url = (record["snapshot"] as? CKAsset)?.fileURL else { throw CloudRecordError.inconsistentCloud("Missing legacy snapshot asset") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CloudSync.maximumSnapshotBytes else { throw CloudRecordError.itemTooLarge("legacy snapshot") }
        return try await Task.detached { try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true) }.value
    }
    static func directory(account: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiBackups/BeforeSync/Migrations/" + CloudMerge.digest(Data(account.utf8)), isDirectory: true)
    }
    @discardableResult static func protect(_ snapshot: TaskBackup, account: String, source: String) async throws -> String {
        let directory = try directory(account: account)
        return try await Task.detached {
            let bytes = try CloudMerge.bytes(snapshot), digest = CloudMerge.digest(bytes)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(source + "-" + digest + ".json")
            if !FileManager.default.fileExists(atPath: file.path) { try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            // Verify even an existing recovery file; never proceed on an unreadable or corrupt backup.
            guard try Data(contentsOf: file) == bytes else { throw CloudRecordError.inconsistentCloud("Migration recovery copy mismatch") }
            return digest
        }.value
    }
    static func recoveryCopy(account: String, source: String) throws -> Data {
        let directory = try directory(account: account)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix(source + "-") && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let file = files.first else { throw TaskBackup.invalid(L("尚无迁移恢复副本。", "No migration recovery copy yet.")) }
        let data = try Data(contentsOf: file); _ = try TaskBackup.decode(data, allowLargeFile: true)
        return data
    }
}
