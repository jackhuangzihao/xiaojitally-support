import Foundation
import OSLog

/// Wire format is independent of business data. Format 15 fences publishers unaware of cloud collection.
enum CloudCommitProtocol {
    static let format = 15
    static let maximumBlobBytes = 900 * 1024
    static let manifestPageBytes = 16 * 1024
    static let batchSize = 200 // Includes headroom below CloudKit's per-request limit.

    struct Reference: Codable, Equatable, Sendable {
        let key: String
        let blob: String
    }
    struct Migration: Codable, Equatable, Sendable {
        let previousRound: Int64
        let hadHead: Bool
        let legacyDigest: String?
        var reupload: Bool? = nil
    }
    struct Head: Codable, Equatable, Sendable {
        var commit: UUID
        var round: Int64
        var pages: [String]
        var migration: Migration?
        var legacyDigest: String?
        var history: [[String]]? = nil
        var maintenance: UUID? = nil
        var collectedRound: Int64? = nil
        var collectedAt: Date? = nil
    }
    struct Cursor: Equatable, Sendable {
        var head: Head
        /// Opaque server system fields; memory tests use their own change tag encoding.
        var tag: Data
    }
    struct Seed: Sendable {
        var items: [String: CloudItem]
        var exists: Bool
    }
    struct Plan: Sendable {
        var head: Head
        var blobs: [String: Data]
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func name(_ data: Data) -> String { "v14-" + CloudMerge.digest(data) }
    static func validate(_ data: Data, named name: String) throws {
        guard data.count <= maximumBlobBytes, self.name(data) == name else {
            throw CloudRecordError.inconsistentCloud("Invalid immutable record")
        }
    }
    static func plan(items: [String: CloudItem], round: Int64, legacyDigest: String?, pageLimit: Int = manifestPageBytes, previous: Head? = nil) throws -> Plan {
        guard round > 0, round < Int64.max, pageLimit > 100, pageLimit <= maximumBlobBytes else { throw CloudRecordError.inconsistentCloud("Invalid commit bounds") }
        var blobs: [String: Data] = [:], pages: [String] = [], page: [Reference] = []
        var pageBytes = 2
        func appendPage() throws {
            guard !page.isEmpty else { return }
            let bytes = try encode(page)
            guard bytes.count <= pageLimit else { throw CloudRecordError.itemTooLarge("manifest") }
            let id = name(bytes); blobs[id] = bytes; pages.append(id); page = []; pageBytes = 2
        }
        // Stable buckets prevent an insertion from shifting every subsequent page.
        let buckets = Dictionary(grouping: items.keys, by: { String(CloudMerge.digest(Data($0.utf8)).prefix(2)) })
        for bucket in buckets.keys.sorted() {
            for key in buckets[bucket]!.sorted() {
                let bytes = try encode(items[key]!)
                guard bytes.count <= maximumBlobBytes else { throw CloudRecordError.itemTooLarge(key) }
                let id = name(bytes); blobs[id] = bytes
                let reference = Reference(key: key, blob: id), size = try encode(reference).count + 1
                if pageBytes + size > pageLimit { try appendPage() }
                guard size + 2 <= pageLimit else { throw CloudRecordError.itemTooLarge("manifest key") }
                page.append(reference); pageBytes += size
            }
            try appendPage()
        }
        var head = Head(commit: UUID(), round: round, pages: pages, legacyDigest: legacyDigest)
        if let previous {
            try validate(previous)
            guard round == previous.round + 1, legacyDigest == previous.legacyDigest else { throw CloudRecordError.changedElsewhere }
            if previous.migration == nil { head.history = Array(([previous.pages] + (previous.history ?? [])).prefix(2)) }
            head.collectedRound = previous.collectedRound
            head.collectedAt = previous.collectedAt
        }
        try validate(head)
        guard try encode(head).count <= maximumBlobBytes else { throw CloudRecordError.itemTooLarge("manifest root") }
        return Plan(head: head, blobs: blobs)
    }
    static func validate(_ head: Head) throws {
        guard head.round >= 0, head.round < Int64.max else { throw CloudRecordError.inconsistentCloud("Invalid head round") }
        guard (head.history?.count ?? 0) <= 2,
              (head.collectedRound ?? 0) >= 0, (head.collectedRound ?? 0) <= head.round,
              head.collectedAt?.timeIntervalSince1970.isFinite ?? true,
              ([head.pages] + (head.history ?? [])).allSatisfy({ Set($0).count == $0.count && $0.allSatisfy(validName) }) else {
            throw CloudRecordError.inconsistentCloud("Invalid retained manifests")
        }
        if let migration = head.migration {
            guard head.pages.isEmpty, (head.history ?? []).isEmpty, migration.previousRound == head.round, migration.legacyDigest == head.legacyDigest,
                  migration.hadHead || head.round == 0 else { throw CloudRecordError.inconsistentCloud("Invalid migration head") }
            if migration.reupload == true, migration.hadHead || head.round != 0 {
                throw CloudRecordError.inconsistentCloud("Invalid re-upload head")
            }
        } else if head.round == 0 { throw CloudRecordError.inconsistentCloud("Uncommitted head") }
    }
    static func validName(_ name: String) -> Bool {
        name.utf8.count == 68 && name.hasPrefix("v14-") && name.utf8.dropFirst(4).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
    static func references(head: Head, blobs: [String: Data]) throws -> [Reference] {
        guard head.migration == nil, head.round > 0, Set(head.pages).count == head.pages.count else {
            throw CloudRecordError.inconsistentCloud("Incomplete commit")
        }
        var result: [Reference] = [], keys = Set<String>()
        for id in head.pages {
            guard let data = blobs[id] else { throw CloudRecordError.missingBlob }
            try validate(data, named: id)
            for ref in try JSONDecoder().decode([Reference].self, from: data) {
                guard keys.insert(ref.key).inserted, validName(ref.blob) else {
                    throw CloudRecordError.inconsistentCloud("Duplicate or invalid manifest reference")
                }
                result.append(ref)
            }
        }
        return result
    }
    static func items(references: [Reference], blobs: [String: Data]) throws -> [String: CloudItem] {
        var result: [String: CloudItem] = [:]
        for ref in references {
            guard let bytes = blobs[ref.blob] else { throw CloudRecordError.missingBlob }
            try validate(bytes, named: ref.blob)
            result[ref.key] = try JSONDecoder().decode(CloudItem.self, from: bytes)
        }
        return result
    }
}

/// Immutable batches may succeed independently. Only publish changes what readers can see.
protocol CloudCommitStore: Sendable {
    func readHead() async throws -> CloudCommitProtocol.Cursor
    func prepareReupload() async throws
    func migrationSeed(_ cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Seed
    func prepareMigrationRecovery(_ local: TaskBackup) async throws -> (CloudCommitProtocol.Cursor, CloudCommitProtocol.Seed)
    func readBlobs(_ names: [String]) async throws -> [String: Data]
    func writeBlobs(_ blobs: [String: Data]) async throws
    func publish(_ head: CloudCommitProtocol.Head, replacing cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Cursor
    func immutableRecordNames() async throws -> [String]
    func collect(_ names: [String], replacing cursor: CloudCommitProtocol.Cursor, finishing: Bool) async throws -> CloudCommitProtocol.Cursor
}

/// The same commit coordinator is used by CloudKit and fault-injecting tests.
actor CloudCommitTransport: CloudRecordTransport {
    private let store: any CloudCommitStore
    private let cacheURL: URL?
    private var cursor: CloudCommitProtocol.Cursor?
    private var state = CloudState()
    private var busy = false
    private var cacheLoaded = false
    private var blobs: [String: Data] = [:]
    private var nextMaintenanceAttempt: ContinuousClock.Instant?
    private struct Cache: Codable { let format: Int; let blobs: [String: Data] }

    init(store: any CloudCommitStore, cacheURL: URL? = nil) { self.store = store; self.cacheURL = cacheURL }

    func allowReupload() async throws {
        guard !busy else { throw CloudRecordError.changedElsewhere }
        busy = true; defer { busy = false }
        try await store.prepareReupload()
        cursor = nil; state = CloudState(generation: state.generation + 1); blobs = [:]; cacheLoaded = true
        persistCache()
    }

    func recoverMigration(with local: TaskBackup, prepared: @Sendable (TaskBackup) async throws -> Void) async throws -> CloudState {
        guard !busy else { throw CloudRecordError.changedElsewhere }
        busy = true; defer { busy = false }
        let (expected, seed) = try await store.prepareMigrationRecovery(local)
        guard expected.head.migration != nil else { throw CloudRecordError.changedElsewhere }
        let snapshot = try CloudRecordCodec.snapshot(seed.items)
        try await prepared(snapshot)
        blobs = [:]; cursor = nil
        let plan = try CloudCommitProtocol.plan(items: seed.items, round: expected.head.round + 1,
                                               legacyDigest: expected.head.legacyDigest, previous: expected.head)
        let saved = try await upload(plan, replacing: expected)
        state = CloudState(items: seed.items, head: CloudHead(round: saved.head.round, format: CloudCommitProtocol.format), generation: state.generation + 1)
        cursor = saved; blobs = plan.blobs; cacheLoaded = true; persistCache()
        return state
    }

    func fetch() async throws -> CloudState {
        guard !busy else { throw CloudRecordError.changedElsewhere }
        busy = true; defer { busy = false }
        loadCache()
        var next = try await store.readHead()
        for attempt in 0..<3 {
            do { return try await read(next) }
            catch CloudRecordError.missingBlob {
                let latest = try await store.readHead()
                guard latest != next else { throw CloudRecordError.missingBlob }
                guard attempt < 2 else { throw CloudRecordError.changedElsewhere }
                next = latest
            }
        }
        throw CloudRecordError.changedElsewhere
    }

    private func read(_ initial: CloudCommitProtocol.Cursor) async throws -> CloudState {
        var next = initial
        try CloudCommitProtocol.validate(next.head)
        if next.head.migration != nil {
            // A cache proves byte integrity, not existence in a newly created or restored cloud zone.
            blobs = [:]
            let seed = try await store.migrationSeed(next)
            if seed.exists {
                _ = try CloudRecordCodec.snapshot(seed.items)
                guard next.head.round < Int64.max else { throw CloudRecordError.inconsistentCloud("Round overflow") }
                let plan = try CloudCommitProtocol.plan(items: seed.items, round: max(1, next.head.round + 1), legacyDigest: next.head.legacyDigest, previous: next.head)
                next = try await upload(plan, replacing: next)
            } else {
                cursor = next
                if !state.isEmpty { state = CloudState(generation: state.generation + 1) }
                return state
            }
        }
        if cursor?.head == next.head, state.head != nil {
            cursor = next
            await maintainCloud()
            return state
        }
        try await load(next.head.pages)
        let references = try CloudCommitProtocol.references(head: next.head, blobs: blobs)
        try await load(references.map(\.blob))
        let items = try CloudCommitProtocol.items(references: references, blobs: blobs)
        // Validate the whole graph before making even an otherwise valid partial ledger visible.
        if cursor?.head.commit != next.head.commit { _ = try CloudRecordCodec.snapshot(items) }
        if state.items != items || cursor?.head.commit != next.head.commit {
            state = CloudState(items: items, head: CloudHead(round: next.head.round, format: CloudCommitProtocol.format), generation: state.generation + 1)
        }
        cursor = next
        let retained = Set(next.head.pages).union(references.map(\.blob))
        blobs = blobs.filter { retained.contains($0.key) }
        persistCache()
        await maintainCloud()
        return state
    }

    func save(_ changes: [String: CloudItem], round: Int64) async throws -> CloudState {
        guard !busy, let expected = cursor else { throw CloudRecordError.changedElsewhere }
        busy = true; defer { busy = false }
        guard expected.head.round < Int64.max, round == expected.head.round + 1 else { throw CloudRecordError.changedElsewhere }
        var target = state.items
        for (key, value) in changes { target[key] = value }
        _ = try CloudRecordCodec.snapshot(target)
        let plan = try CloudCommitProtocol.plan(items: target, round: round, legacyDigest: expected.head.legacyDigest, previous: expected.head)
        let saved = try await upload(plan, replacing: expected)
        cursor = saved
        state = CloudState(items: target, head: CloudHead(round: round, format: CloudCommitProtocol.format), generation: state.generation + 1)
        blobs = plan.blobs; persistCache()
        await maintainCloud()
        return state
    }

    private func maintainCloud() async {
        let now = Date()
        let retryClock = ContinuousClock().now
        guard let expected = cursor, CloudRetention.isDue(expected.head, now: now),
              nextMaintenanceAttempt.map({ retryClock >= $0 }) ?? true else { return }
        nextMaintenanceAttempt = retryClock.advanced(by: .seconds(300))
        do {
            cursor = try await CloudRetention.collect(store: store, cursor: expected)
            nextMaintenanceAttempt = nil
        }
        catch { // A published business save stays successful even if optional maintenance fails.
            CloudMigration.log.notice("Cloud collection deferred; local and committed data retained")
        }
    }

    private func upload(_ plan: CloudCommitProtocol.Plan, replacing expected: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Cursor {
        let missing = plan.blobs.filter { blobs[$0.key] != $0.value }
        for batch in try CloudBlobUpload.batches(missing) {
            try Task.checkCancellation()
            try await store.writeBlobs(batch)
        }
        try Task.checkCancellation()
        do { return try await store.publish(plan.head, replacing: expected) }
        catch {
            // Collection may change only maintenance metadata after a successful publication.
            if let observed = try? await store.readHead(), observed.head.commit == plan.head.commit,
               observed.head.round == plan.head.round, observed.head.pages == plan.head.pages,
               observed.head.migration == nil, observed.head.legacyDigest == plan.head.legacyDigest { return observed }
            throw error
        }
    }
    private func load(_ ids: [String]) async throws {
        let missing = Set(ids).filter { blobs[$0] == nil }.sorted()
        for offset in stride(from: 0, to: missing.count, by: CloudCommitProtocol.batchSize) {
            try Task.checkCancellation()
            let batch = Array(missing.dropFirst(offset).prefix(CloudCommitProtocol.batchSize))
            let received = try await store.readBlobs(batch)
            for id in batch {
                guard let bytes = received[id] else { throw CloudRecordError.missingBlob }
                try CloudCommitProtocol.validate(bytes, named: id); blobs[id] = bytes
            }
        }
    }
    private func loadCache() {
        guard !cacheLoaded else { return }; cacheLoaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.format == CloudCommitProtocol.format else { return }
        // The cache is expendable. Corrupted bytes never become authoritative.
        blobs = cache.blobs.filter { (try? CloudCommitProtocol.validate($0.value, named: $0.key)) != nil }
    }
    private func persistCache() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CloudCommitProtocol.encode(Cache(format: CloudCommitProtocol.format, blobs: blobs)).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { CloudMigration.log.error("Cloud cache write failed; it can be refetched: \(error.localizedDescription, privacy: .private)") }
    }
}
