import Foundation
import CloudKit

/// Uses the production coordinator; the store models independent server batches and head compare-and-swap.
actor FaultingCommitStore: CloudCommitStore {
    enum Fault: Sendable { case beforeBatch(Int), afterBatch(Int), beforeHead, afterHead, afterReupload, cancelled, denied }
    private var head = CloudCommitProtocol.Head(commit: UUID(), round: 0, pages: [], migration: .init(previousRound: 0, hadHead: false, legacyDigest: nil))
    private var tag = 0
    private var blobs: [String: Data] = [:]
    private var fault: Fault?
    private var seed = CloudCommitProtocol.Seed(items: [:], exists: false)
    private var headExists = true
    private var legacyDigest: String?
    private(set) var batches = 0
    private(set) var uploaded = 0
    private(set) var publications = 0
    func configure(_ value: Fault?) { fault = value; batches = 0; uploaded = 0 }
    func setSeed(_ value: CloudCommitProtocol.Seed) { seed = value }
    func readHead() -> CloudCommitProtocol.Cursor { .init(head: head, tag: Data(String(tag).utf8)) }
    func prepareReupload() throws {
        let value = try CloudMigration.reuploadHead(existing: headExists ? head : nil, legacyDigest: legacyDigest)
        seed = .init(items: [:], exists: false)
        head = value; headExists = true; tag += 1
        if case .afterReupload = fault { fault = nil; throw URLError(.networkConnectionLost) }
    }
    func migrationSeed(_ cursor: CloudCommitProtocol.Cursor) throws -> CloudCommitProtocol.Seed {
        guard cursor == readHead() else { throw CloudRecordError.changedElsewhere }; return seed
    }
    func readBlobs(_ names: [String]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in names {
            guard let data = blobs[name] else { throw CloudRecordError.inconsistentCloud("Missing test blob") }
            result[name] = data
        }
        return result
    }
    func writeBlobs(_ batch: [String: Data]) throws {
        guard batch.count <= CloudCommitProtocol.batchSize else { throw CloudRecordError.inconsistentCloud("Batch limit") }
        batches += 1
        if case .cancelled = fault { fault = nil; throw CancellationError() }
        if case .denied = fault { fault = nil; throw CKError(.permissionFailure) }
        if case .beforeBatch(let n) = fault, n == batches { fault = nil; throw URLError(.networkConnectionLost) }
        for (name, data) in batch {
            try CloudCommitProtocol.validate(data, named: name)
            if let old = blobs[name], old != data { throw CloudRecordError.inconsistentCloud("Immutable overwrite") }
            blobs[name] = data
        }
        uploaded += batch.count
        if case .afterBatch(let n) = fault, n == batches { fault = nil; throw URLError(.networkConnectionLost) }
    }
    func publish(_ value: CloudCommitProtocol.Head, replacing cursor: CloudCommitProtocol.Cursor) throws -> CloudCommitProtocol.Cursor {
        if case .beforeHead = fault { fault = nil; throw URLError(.networkConnectionLost) }
        guard cursor == readHead() else { throw CloudRecordError.changedElsewhere }
        // The server does not validate references; production must not rely on a stronger test double.
        head = value; tag += 1; publications += 1
        if case .afterHead = fault { fault = nil; throw URLError(.networkConnectionLost) }
        return readHead()
    }
    func removeBlob(_ id: String) { blobs[id] = nil }
    func corruptBlob(_ id: String) { blobs[id] = Data("broken".utf8) }
    func resetCloud(legacyDigest: String? = nil) {
        self.legacyDigest = legacyDigest; headExists = false
        head = .init(commit: UUID(), round: 0, pages: [],
                     migration: .init(previousRound: 0, hadHead: false, legacyDigest: legacyDigest), legacyDigest: legacyDigest)
        blobs = [:]; tag += 1
    }
}

@MainActor enum CloudCommitChecks {
    private static func outcome(_ operation: @Sendable () async throws -> Void) async -> Bool {
        do { try await operation(); return true } catch { return false }
    }
    static func run(sample: TaskBackup) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD COMMIT CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ operation: () async throws -> Void) async throws {
            do { try await operation() } catch { count += 1; return }
            throw TaskBackup.invalid("CLOUD COMMIT CHECK: " + label)
        }
        let items = try CloudRecordCodec.items(sample)
        func expanded(_ size: Int) -> TaskBackup {
            var snapshot = sample
            for i in 0..<size {
                var row = sample.tasks[0]; row.id = UUID(); row.title = "Batch \(i)"; snapshot.tasks.append(row)
            }
            return snapshot
        }
        // Manifest splitting, deterministic version names, tombstones and corrupt inputs.
        let pages = try CloudCommitProtocol.plan(items: items, round: 1, legacyDigest: nil, pageLimit: 260)
        try check(pages.head.pages.count > 1, "manifest splits by encoded size")
        let refs = try CloudCommitProtocol.references(head: pages.head, blobs: pages.blobs)
        try check(try CloudCommitProtocol.items(references: refs, blobs: pages.blobs) == items, "manifest round trip keeps payloads and tombstones")
        let again = try CloudCommitProtocol.plan(items: items, round: 1, legacyDigest: nil, pageLimit: 260)
        try check(again.blobs == pages.blobs && again.head.commit != pages.head.commit, "content deduplicates but commits have unique identities")
        try await rejects("missing manifest is not empty cloud") { _ = try CloudCommitProtocol.references(head: pages.head, blobs: [:]) }
        try await rejects("oversized immutable record refused") {
            _ = try CloudCommitProtocol.plan(items: ["task:x": CloudItem(payload: Data(count: CloudCommitProtocol.maximumBlobBytes))], round: 1, legacyDigest: nil)
        }
        var duplicate = pages.head; duplicate.pages.append(duplicate.pages[0])
        try await rejects("duplicate page refused") { _ = try CloudCommitProtocol.references(head: duplicate, blobs: pages.blobs) }

        for repetition in 0..<3 {
            for size in [0, 1, 249, 250, 251, 500, 5_000] {
                let snapshot = expanded(size), target = try CloudRecordCodec.items(snapshot)
                let store = FaultingCommitStore(), sender = CloudCommitTransport(store: store)
                let empty = try await sender.fetch()
                try check(empty.isEmpty, "new cloud is empty")
                _ = try await sender.save(target, round: 1)
                let reader = CloudCommitTransport(store: store), state = try await reader.fetch()
                try check(state.items == target && state.head?.format == 14, "complete round trip \(repetition)/\(size)")
                let generation = state.generation
                try check(try await reader.fetch().generation == generation, "unchanged fetch preserves cache generation")
                // Editing one item uploads its version and changed manifest pages, not every item again.
                var edited = snapshot; edited.tasks[0].notes = "one edit"
                let changed = try CloudRecordCodec.items(edited)
                await store.configure(nil)
                _ = try await sender.save(CloudRecordCodec.changes(from: target, to: changed), round: 2)
                try check(await store.uploaded <= 3, "single edit uploads at most record + manifest pages")
            }
            for fault in [FaultingCommitStore.Fault.beforeBatch(1), .afterBatch(1), .beforeBatch(2), .afterBatch(2), .beforeBatch(3), .afterBatch(3), .beforeHead, .cancelled, .denied] {
                let store = FaultingCommitStore(), sender = CloudCommitTransport(store: store)
                _ = try await sender.fetch(); _ = try await sender.save(items, round: 1)
                let target = try CloudRecordCodec.items(expanded(500))
                await store.configure(fault)
                try await rejects("failed batches must not publish") { _ = try await sender.save(CloudRecordCodec.changes(from: items, to: target), round: 2) }
                let reader = CloudCommitTransport(store: store)
                try check(try await reader.fetch().items == items, "fresh reader sees old complete commit after failure")
                try check(await store.publications == 1, "no head publication after batch failure")
                let restarted = CloudCommitTransport(store: store)
                _ = try await restarted.fetch(); await store.configure(nil)
                _ = try await restarted.save(CloudRecordCodec.changes(from: items, to: target), round: 2)
                try check(try await reader.fetch().items == target, "restart completes without mixed records")
            }
            // Two devices upload disjoint rows against the same head. Only one conditional publication wins.
            let store = FaultingCommitStore(), mac = CloudCommitTransport(store: store), phone = CloudCommitTransport(store: store)
            _ = try await mac.fetch(); _ = try await mac.save(items, round: 1); _ = try await phone.fetch()
            var left = sample, right = sample; left.tasks[0].notes = "Mac"; right.lists[0].name = "Phone"
            let l = try CloudRecordCodec.items(left), r = try CloudRecordCodec.items(right)
            _ = try await mac.save(CloudRecordCodec.changes(from: items, to: l), round: 2)
            try await rejects("stale publisher rejected even after all blobs succeeded") { _ = try await phone.save(CloudRecordCodec.changes(from: items, to: r), round: 2) }
            try check(try await CloudCommitTransport(store: store).fetch().items == l, "loser cannot change visible records")
            _ = try await phone.fetch()
            let merged = try CloudMerge.merge(local: right, cloud: left, base: sample)
            let joined = try CloudRecordCodec.items(merged)
            _ = try await phone.save(CloudRecordCodec.changes(from: l, to: joined), round: 3)
            try check(try await mac.fetch().items == joined, "retry uses existing merge and preserves both edits")
            await store.configure(.afterHead)
            _ = try await mac.save([:], round: 4)
            try check(try await phone.fetch().head?.round == 4, "lost success response reconciles by exact head identity")
        }
        for _ in 0..<6 {
            let store = FaultingCommitStore(), left = CloudCommitTransport(store: store), right = CloudCommitTransport(store: store)
            _ = try await left.fetch(); _ = try await left.save(items, round: 1); _ = try await right.fetch()
            let l = try CloudRecordCodec.items(expanded(500)), r = try CloudRecordCodec.items(expanded(501))
            async let a = outcome { _ = try await left.save(CloudRecordCodec.changes(from: items, to: l), round: 2) }
            async let b = outcome { _ = try await right.save(CloudRecordCodec.changes(from: items, to: r), round: 2) }
            let (wonA, wonB) = await (a, b)
            try check(wonA != wonB, "interleaved publishers have exactly one winner")
            let visible = try await CloudCommitTransport(store: store).fetch().items
            try check(visible == (wonA ? l : r), "interleaved batches cannot mix either snapshot")
        }
        // Both obsolete clients' compatibility checks already reject these higher formats.
        let legacy = CKRecord(recordType: "TallySnapshot", recordID: CloudMigration.legacyID)
        legacy["formatVersion"] = Int64(1); legacy["snapshot"] = Data("retained asset stand-in".utf8)
        let oldAsset = legacy["snapshot"] as? Data
        try CloudMigration.fence(legacy, digest: "known-digest")
        try check(legacy["formatVersion"] as? Int64 == 2 && legacy["migrationState"] as? String == "sealed", "legacy header trips old format guard")
        try check(legacy["snapshot"] as? Data == oldAsset, "migration fence retains original asset")
        try await rejects("cannot reseal an unexpected format") { try CloudMigration.fence(legacy, digest: nil) }
        try check(CloudCommitProtocol.format > CloudRecordCodec.format, "old per-row client rejects new head independently of backup format")
        let emptyLegacy = CKRecord(recordType: "TallySnapshot", recordID: CloudMigration.legacyID)
        try CloudMigration.fence(emptyLegacy, digest: nil)
        try check(emptyLegacy["formatVersion"] as? Int64 == 2 && emptyLegacy["snapshot"] == nil, "new accounts also fence old writers")
        let frozen = CloudCommitProtocol.Head(commit: UUID(), round: 0, pages: [], migration: .init(previousRound: 8, hadHead: true, legacyDigest: nil))
        try await rejects("inconsistent migration source refused") { try CloudCommitProtocol.validate(frozen) }
        let overflow = CloudCommitProtocol.Head(commit: UUID(), round: Int64.max, pages: [])
        try await rejects("round cannot overflow next save") { try CloudCommitProtocol.validate(overflow) }

        // Damaged cache is discarded, and a recreated reader validates cloud content before use.
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("commit-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = cacheDirectory.appendingPathComponent("mirror.json")
        let cacheStore = FaultingCommitStore(), cached = CloudCommitTransport(store: cacheStore, cacheURL: cache)
        _ = try await cached.fetch(); _ = try await cached.save(items, round: 1)
        try await rejects("explicit reupload cannot replace a cloud that still exists") { try await cached.allowReupload() }
        try check(FileManager.default.fileExists(atPath: cache.path), "versioned cache is persisted")
        try check(try await CloudCommitTransport(store: cacheStore, cacheURL: cache).fetch().items == items, "cache survives process recreation")
        try Data("broken cache".utf8).write(to: cache)
        try check(try await CloudCommitTransport(store: cacheStore, cacheURL: cache).fetch().items == items, "damaged cache refetches without losing data")
        for recreated in [false, true] {
            await cacheStore.resetCloud()
            let uploader = recreated ? CloudCommitTransport(store: cacheStore, cacheURL: cache) : cached
            try await uploader.allowReupload()
            _ = try await uploader.fetch(); _ = try await uploader.save(items, round: 1)
            try check(try await CloudCommitTransport(store: cacheStore).fetch().items == items, "re-upload rebuilds cloud blobs despite old disk or memory cache")
        }
        let replacementStore = FaultingCommitStore(), replacement = CloudCommitTransport(store: replacementStore, cacheURL: cache)
        _ = try await replacement.fetch(); _ = try await replacement.save(items, round: 1)
        try check(try await CloudCommitTransport(store: replacementStore).fetch().items == items, "new cloud cannot use old cache as upload acknowledgement")

        // A missing/corrupted committed blob is an error, never an empty row or a deletion.
        for corrupt in [false, true] {
            let store = FaultingCommitStore(), writer = CloudCommitTransport(store: store)
            _ = try await writer.fetch(); _ = try await writer.save(items, round: 1)
            let head = await store.readHead().head
            if corrupt { await store.corruptBlob(head.pages[0]) } else { await store.removeBlob(head.pages[0]) }
            try await rejects("incomplete committed data fails closed") { _ = try await CloudCommitTransport(store: store).fetch() }
        }
        // Migration retries use the same coordinator and cannot expose staging blobs.
        for fault in [FaultingCommitStore.Fault.afterBatch(1), .beforeHead, .afterHead] {
            let store = FaultingCommitStore(); await store.setSeed(.init(items: items, exists: true)); await store.configure(fault)
            do { _ = try await CloudCommitTransport(store: store).fetch() } catch { /* A staged migration may be retried. */ }
            await store.configure(nil)
            try check(try await CloudCommitTransport(store: store).fetch().items == items, "migration resumes after interruption")
        }
        try check(try CloudMigration.seed(records: sample, legacy: sample).items == items, "identical old sources migrate once")
        try check(try CloudMigration.seed(records: nil, legacy: sample).items == items, "snapshot-only migration preserves all data")
        try check(try CloudMigration.seed(records: nil, legacy: nil).exists == false, "brand new cloud remains distinguishable from deletion")
        var divergent = sample; divergent.tasks[0].notes = "old client wrote after superseded"
        try await rejects("divergent old sources require review") { _ = try CloudMigration.seed(records: sample, legacy: divergent) }
        try await rejects("unfinished old rows cannot migrate") { _ = try CloudMigration.completedRows(items.mapValues { ($0, Int64(2)) }, previousRound: 1, hadHead: true) }
        try await rejects("headless old rows cannot become an empty cloud") { _ = try CloudMigration.completedRows(items.mapValues { ($0, Int64(1)) }, previousRound: 0, hadHead: false) }
        let completed = try CloudMigration.completedRows(items.mapValues { ($0, Int64(1)) }, previousRound: 1, hadHead: true)
        try check(try completed.map { try CloudRecordCodec.items($0) } == items, "complete old record snapshot validates")
        print("CLOUD COMMIT PASS: \(count) checks; repeated batches, publication races, migration, corruption")
        return count
    }
}
