import Foundation
import CloudKit

private actor LimitedCommitStore: CloudCommitStore {
    enum Response: Sendable { case whole, nested, results }
    let backing = FaultingCommitStore()
    private var limit = Int.max
    private var response = Response.whole
    private var failureAt: Int?
    private(set) var requests = 0
    private(set) var splitRequests = 0
    private(set) var maximumBytes = 0
    func configure(limit: Int, response: Response = .whole, failureAt: Int? = nil) {
        self.limit = limit; self.response = response; self.failureAt = failureAt
        requests = 0; splitRequests = 0; maximumBytes = 0
    }
    func readHead() async throws -> CloudCommitProtocol.Cursor { await backing.readHead() }
    func prepareReupload() async throws { try await backing.prepareReupload() }
    func migrationSeed(_ cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Seed { try await backing.migrationSeed(cursor) }
    func prepareMigrationRecovery(_ local: TaskBackup) async throws -> (CloudCommitProtocol.Cursor, CloudCommitProtocol.Seed) { try await backing.prepareMigrationRecovery(local) }
    func immutableRecordNames() async throws -> [String] { await backing.immutableRecordNames() }
    func collect(_ names: [String], replacing cursor: CloudCommitProtocol.Cursor, finishing: Bool) async throws -> CloudCommitProtocol.Cursor {
        try await backing.collect(names, replacing: cursor, finishing: finishing)
    }
    func readBlobs(_ names: [String]) async throws -> [String: Data] { try await backing.readBlobs(names) }
    func publish(_ value: CloudCommitProtocol.Head, replacing cursor: CloudCommitProtocol.Cursor) async throws -> CloudCommitProtocol.Cursor {
        try await backing.publish(value, replacing: cursor)
    }
    func writeBlobs(_ blobs: [String: Data]) async throws {
        try await CloudBlobUpload.write(blobs) { try await self.attempt($0) }
    }
    private func attempt(_ blobs: [String: Data]) async throws -> CloudBlobUpload.Results {
        requests += 1
        let bytes = blobs.reduce(0) { $0 + CloudBlobUpload.estimatedBytes(name: $1.key, data: $1.value) }
        maximumBytes = max(maximumBytes, bytes)
        if requests == failureAt { throw URLError(.networkConnectionLost) }
        if bytes > limit {
            splitRequests += 1
            let limit = CKError(.limitExceeded), batch = CKError(.batchRequestFailed)
            switch response {
            case .whole: throw limit
            case .nested:
                let inner = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["limit": limit, "peer": batch]])
                throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["nested": inner]])
            case .results:
                return Dictionary(uniqueKeysWithValues: blobs.keys.sorted().enumerated().map {
                    ($0.element, .failure($0.offset == 0 ? limit : batch))
                })
            }
        }
        try await backing.writeBlobs(blobs)
        return blobs.mapValues { _ in .success(()) }
    }
}

private actor BatchAttemptProbe {
    enum Mode: Sendable { case single, denied, cancelled, network, mixed, missing, atomicPeers, partialSuccess, onePending }
    let mode: Mode
    private(set) var calls = 0
    private(set) var repeatedSuccess = false
    private var acknowledged: String?
    init(_ mode: Mode) { self.mode = mode }
    func attempt(_ blobs: [String: Data]) throws -> CloudBlobUpload.Results {
        calls += 1
        let limit = CKError(.limitExceeded)
        switch mode {
        case .single: throw limit
        case .denied: throw CKError(.permissionFailure)
        case .cancelled: throw CancellationError()
        case .network: throw URLError(.networkConnectionLost)
        case .mixed:
            throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["limit": limit, "permission": CKError(.permissionFailure)]])
        case .missing: return [:]
        case .atomicPeers:
            return blobs.mapValues { _ in calls == 1 ? .failure(CKError(.batchRequestFailed)) : .success(()) }
        case .partialSuccess:
            if calls == 1 {
                acknowledged = blobs.keys.sorted().first
                return Dictionary(uniqueKeysWithValues: blobs.keys.map { ($0, $0 == acknowledged ? .success(()) : .failure(limit)) })
            }
            if let acknowledged, blobs[acknowledged] != nil { repeatedSuccess = true }
            return blobs.mapValues { _ in .success(()) }
        case .onePending:
            if calls == 1 {
                let rejected = blobs.keys.sorted().last
                return Dictionary(uniqueKeysWithValues: blobs.keys.map { ($0, $0 == rejected ? .failure(limit) : .success(())) })
            }
            return blobs.mapValues { _ in .success(()) }
        }
    }
}

@MainActor enum CloudBatchChecks {
    static func run(sample: TaskBackup) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD BATCH CHECK: " + label) }; count += 1
        }
        func rejection(_ operation: () async throws -> Void) async throws -> Error {
            do { try await operation() } catch { count += 1; return error }
            throw TaskBackup.invalid("CLOUD BATCH CHECK: expected rejection")
        }
        let items = try CloudRecordCodec.items(sample)
        var large = sample
        for index in 0..<100 {
            var task = sample.tasks[0]; task.id = UUID(); task.title = "Long note \(index)"
            task.notes = String(repeating: "字", count: 10_000); large.tasks.append(task)
        }
        let target = try CloudRecordCodec.items(large)
        let plan = try CloudCommitProtocol.plan(items: target, round: 2, legacyDigest: nil)
        let batches = try CloudBlobUpload.batches(plan.blobs)
        try check(plan.blobs.values.reduce(0) { $0 + $1.count } > 2 * 1_024 * 1_024, "valid long notes reproduce the old oversized request")
        try check(batches.count > 1 && batches.allSatisfy { $0.count <= 200 && $0.reduce(0) { $0 + CloudBlobUpload.estimatedBytes(name: $1.key, data: $1.value) } <= CloudBlobUpload.requestBudget }, "count and encoded byte budget both apply")
        try check(batches.reduce(into: [:]) { $0.merge($1) { a, _ in a } } == plan.blobs, "every immutable version is retained")
        try check(try CloudBlobUpload.batches([:]).isEmpty, "empty input makes no requests")
        let smallRecords = Dictionary(uniqueKeysWithValues: (0..<401).map { let data = Data("small-\($0)".utf8); return (CloudCommitProtocol.name(data), data) })
        try check(try CloudBlobUpload.batches(smallRecords).map(\.count) == [200, 200, 1], "small records still obey the record count limit")
        let largest = Data(count: CloudCommitProtocol.maximumBlobBytes)
        try check(try CloudBlobUpload.batches([CloudCommitProtocol.name(largest): largest]).count == 1, "largest permitted blob fits the conservative budget")

        for repetition in 0..<3 {
            for response in [LimitedCommitStore.Response.whole, .nested, .results] {
                let store = LimitedCommitStore(), writer = CloudCommitTransport(store: store)
                _ = try await writer.fetch(); _ = try await writer.save(items, round: 1)
                await store.configure(limit: 300 * 1_024, response: response)
                _ = try await writer.save(CloudRecordCodec.changes(from: items, to: target), round: 2)
                try check(try await CloudCommitTransport(store: store).fetch().items == target, "smaller server limit preserves complete snapshot \(repetition)/\(response)")
                let splitRequests = await store.splitRequests, maximumBytes = await store.maximumBytes
                try check(splitRequests > 0 && maximumBytes <= CloudBlobUpload.requestBudget, "actual limit recursively splits already budgeted requests")
            }
        }
        let store = LimitedCommitStore(), writer = CloudCommitTransport(store: store)
        _ = try await writer.fetch(); _ = try await writer.save(items, round: 1)
        await store.configure(limit: 2 * 1_024 * 1_024)
        _ = try await writer.save(CloudRecordCodec.changes(from: items, to: target), round: 2)
        try check(await store.splitRequests == 0, "normal server limit accepts pre-sized long-note batches")

        // Interrupted subdivision must leave the last complete head untouched and be safely repeatable.
        for _ in 0..<3 {
            let store = LimitedCommitStore(), writer = CloudCommitTransport(store: store)
            _ = try await writer.fetch(); _ = try await writer.save(items, round: 1)
            await store.configure(limit: 300 * 1_024, failureAt: 5)
            _ = try await rejection { _ = try await writer.save(CloudRecordCodec.changes(from: items, to: target), round: 2) }
            try check(try await CloudCommitTransport(store: store).fetch().items == items, "mid-split interruption leaves previous snapshot intact")
            try check(await store.backing.publications == 1, "interrupted blobs never publish a partial head")
            await store.configure(limit: 300 * 1_024)
            _ = try await writer.save(CloudRecordCodec.changes(from: items, to: target), round: 2)
            try check(try await CloudCommitTransport(store: store).fetch().items == target, "split retry completes without dropping any old data")
        }

        let tiny = Dictionary(uniqueKeysWithValues: (0..<4).map { let data = Data("record-\($0)".utf8); return (CloudCommitProtocol.name(data), data) })
        for mode in [BatchAttemptProbe.Mode.denied, .cancelled, .network, .mixed, .missing] {
            let probe = BatchAttemptProbe(mode)
            let error = try await rejection { try await CloudBlobUpload.write(tiny) { try await probe.attempt($0) } }
            try check(await probe.calls == 1, "non-limit failures never trigger split retries \(mode)")
            if case .mixed = mode { try check((error as? CKError)?.code == .partialFailure, "mixed permission failure is retained") }
        }
        let singleton = Dictionary(uniqueKeysWithValues: tiny.prefix(1).map { ($0.key, $0.value) }), single = BatchAttemptProbe(.single)
        let oversized = try await rejection { try await CloudBlobUpload.write(singleton) { try await single.attempt($0) } }
        let singleCalls = await single.calls
        try check(oversized as? CloudRecordError == .itemTooLarge(singleton.keys.first!) && singleCalls == 1, "single-record limit stops with explicit error")
        let partial = BatchAttemptProbe(.partialSuccess)
        try await CloudBlobUpload.write(tiny) { try await partial.attempt($0) }
        let partialCalls = await partial.calls, repeatedSuccess = await partial.repeatedSuccess
        try check(partialCalls == 3 && !repeatedSuccess, "per-record successes are excluded from recursive retry")
        let atomic = BatchAttemptProbe(.atomicPeers)
        try await CloudBlobUpload.write(tiny) { try await atomic.attempt($0) }
        try check(await atomic.calls == 2, "atomic peer failure can retry after immutable deduplication")
        let remaining = BatchAttemptProbe(.onePending)
        try await CloudBlobUpload.write(tiny) { try await remaining.attempt($0) }
        try check(await remaining.calls == 2, "one failed peer gets a standalone attempt before being declared oversized")
        let cancelled = BatchAttemptProbe(.atomicPeers)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await CloudBlobUpload.write(tiny) { try await cancelled.attempt($0) }
        }
        let cancellation = try await rejection { try await task.value }
        let cancelledCalls = await cancelled.calls
        try check(cancellation is CancellationError && cancelledCalls == 0, "cancelled task never reaches the server")
        print("CLOUD BATCH PASS: \(count) checks; byte budgets, server limits, partial results, interruptions")
        return count
    }
}
