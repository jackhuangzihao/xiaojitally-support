import Foundation
import SwiftData
import CryptoKit

@MainActor enum SyncHistoryChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("SYNC HISTORY CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ work: () throws -> Void) throws {
            var failed = false; do { try work() } catch { failed = true }
            try check(failed, label)
        }
        for bytes in [Data(), Data("abc".utf8), Data(0...255)] {
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try check(CloudMerge.digest(bytes) == expected, "optimized hashes preserve all existing fingerprints")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-History-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for round in 0..<3 {
            let url = root.appendingPathComponent("history-\(round).store")
            let store = try Store.make(url: url), context = store.mainContext
            let other = try Store.make(url: root.appendingPathComponent("other-\(round).store"))
            let date = Date(timeIntervalSince1970: 1_800_000_000.123 + Double(round))
            let first = SyncChanges.key("task", UUID()), second = SyncChanges.key("task", UUID())
            let hash = try SyncChanges.fingerprint("Original")
            var revisions: SyncChanges.Revisions = [
                first: .init(date: date, fingerprint: hash, fields: ["title": .init(date: date, fingerprint: hash)]),
                second: .init(date: date, fingerprint: nil)
            ]
            try SyncChanges.stage(revisions, in: context)
            try Store.save(context, trackSyncChanges: false)
            let state = try context.fetch(FetchDescriptor<CloudSyncState>()).first!
            try check(try state.changeHistory == encoder.encode(revisions), "new cached encoding matches legacy sorted JSON byte for byte")
            try check(try SyncChanges.read(context) == revisions, "new history reads without changing timestamps or tombstones")

            let saved = state.changeHistory
            var edited = revisions
            edited[first]?.date = date.addingTimeInterval(1)
            edited[first]?.fields?["title"]?.date = date.addingTimeInterval(1)
            edited[first]?.fields?["title"]?.fingerprint = try SyncChanges.fingerprint("Edited")
            edited[first]?.fingerprint = try SyncChanges.fingerprint("Edited")
            try SyncChanges.stage(edited, in: context)
            try check(try state.changeHistory == encoder.encode(edited), "incremental encoding matches complete encoding")
            context.rollback()
            // SwiftData refreshes a retained Data property when fetched after rollback.
            let rolledBack = try SyncChanges.read(context)
            try check(rolledBack == revisions && state.changeHistory == saved,
                      "rollback reloads committed history instead of staged cache")
            try SyncChanges.stage(edited, in: other.mainContext)
            try Store.save(other.mainContext, trackSyncChanges: false)
            try check(try SyncChanges.read(other.mainContext) == edited && SyncChanges.read(context) == revisions,
                      "switching stores cannot reuse another store's revisions")
            try SyncChanges.stage(edited, in: context)
            try Store.save(context, trackSyncChanges: false)
            revisions = edited
            let reopened = try Store.make(url: url)
            try check(try SyncChanges.read(reopened.mainContext) == edited, "incremental history survives database reopen")

            let legacy = try JSONSerialization.jsonObject(with: encoder.encode(revisions))
            state.changeHistory = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted])
            try Store.save(context, trackSyncChanges: false)
            try check(try SyncChanges.read(context) == revisions, "legacy persisted dictionary remains readable")
            try SyncChanges.stage(revisions, in: context)
            try check(try state.changeHistory == encoder.encode(revisions), "legacy history canonicalizes without a schema migration")
            try Store.save(context, trackSyncChanges: false)

            var invalid = revisions
            invalid[first]?.fields?["title"]?.fingerprint = "invalid"
            try rejects("changed cached fields are still validated") { try SyncChanges.stage(invalid, in: context) }
            invalid = revisions; invalid["unknown:" + UUID().uuidString] = .init(date: date, fingerprint: hash)
            try rejects("new record keys are validated") { try SyncChanges.stage(invalid, in: context) }
            invalid = revisions; invalid[first]?.fields?["unsupported"] = .init(date: date, fingerprint: hash)
            try rejects("new field names are validated") { try SyncChanges.stage(invalid, in: context) }
            try check(try SyncChanges.read(context) == revisions && state.changeHistory == encoder.encode(revisions),
                      "failed staging leaves history and cache untouched")
            for corrupted in [Data("{".utf8), try encoder.encode(invalid)] {
                state.changeHistory = corrupted
                try rejects("a warm cache cannot conceal corrupted stored history") { _ = try SyncChanges.read(context) }
                context.rollback()
                try check(try SyncChanges.read(context) == revisions, "rollback after corruption recovers the committed history")
            }
            revisions.removeValue(forKey: second)
            try SyncChanges.stage(revisions, in: context)
            try check(try state.changeHistory == encoder.encode(revisions), "removed history records do not remain in encoded fragments")
            try SyncChanges.stage(nil, in: context)
            try check(state.changeHistory == nil && (try SyncChanges.read(context)) == nil, "clearing history also clears cached data")
            try SyncChanges.stage([:], in: context)
            try check(state.changeHistory == nil, "empty history preserves the existing nil representation")
            context.rollback()
            try check(try SyncChanges.read(context) == edited, "rollback after clearing restores committed records")
        }
        return count
    }
}
