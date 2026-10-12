import Foundation

/// A deliberately slow, non-cooperative server callback; cancellation must not block foreground sync.
private actor RetentionInventoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func pause() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

@MainActor private final class RetentionCompletion {
    var finished = false
}

/// Models only server guarantees: immutable bytes and atomic head-tag comparison with deletion.
private actor RetentionCommitStore: CloudCommitStore {
    enum Fault: Sendable { case beforeDelete(Int), afterDelete(Int), cancelled(Int), enumeration }
    private var cursor: CloudCommitProtocol.Cursor
    private var blobs: [String: Data]
    private var serial = 0
    private var fault: Fault?
    private var inventoryGate: RetentionInventoryGate?
    private var publisherAtCollection: CloudCommitProtocol.Plan?
    private var replacementsAtRead: [(plan: CloudCommitProtocol.Plan, retained: [String: Data])] = []
    private(set) var collectionSizes: [Int] = []
    private(set) var removed = Set<String>()
    private(set) var reads = 0
    private(set) var inventories = 0

    init(plan: CloudCommitProtocol.Plan, retained: [String: Data] = [:]) {
        cursor = .init(head: plan.head, tag: Data("0".utf8))
        blobs = retained.merging(plan.blobs) { _, new in new }
    }
    func readHead() -> CloudCommitProtocol.Cursor { cursor }
    func prepareReupload() throws { throw CloudRecordError.changedElsewhere }
    func prepareMigrationRecovery(_ local: TaskBackup) throws -> (CloudCommitProtocol.Cursor, CloudCommitProtocol.Seed) {
        throw CloudRecordError.changedElsewhere
    }
    func migrationSeed(_ cursor: CloudCommitProtocol.Cursor) throws -> CloudCommitProtocol.Seed {
        throw CloudRecordError.changedElsewhere
    }
    func configure(_ fault: Fault?) { self.fault = fault; collectionSizes = []; removed = [] }
    func pauseInventory(with gate: RetentionInventoryGate) { inventoryGate = gate }
    func publishDuringCollection(_ plan: CloudCommitProtocol.Plan) { publisherAtCollection = plan }
    func replaceDuringRead(_ plan: CloudCommitProtocol.Plan, retained: [String: Data]) { replacementsAtRead.append((plan, retained)) }
    func contains(_ names: Set<String>) -> Bool { names.isSubset(of: Set(blobs.keys)) }
    func names() -> Set<String> { Set(blobs.keys) }
    func remove(_ name: String) { blobs[name] = nil }
    func corrupt(_ name: String) { blobs[name] = Data("damaged".utf8) }
    func immutableRecordNames() async throws -> [String] {
        inventories += 1
        if let gate = inventoryGate { inventoryGate = nil; await gate.pause() }
        if case .enumeration = fault { fault = nil; throw URLError(.networkConnectionLost) }
        return blobs.keys.sorted()
    }
    func readBlobs(_ names: [String]) throws -> [String: Data] {
        reads += 1
        if !replacementsAtRead.isEmpty {
            let replacement = replacementsAtRead.removeFirst()
            // Several commits and a collection happened after this reader fetched its head.
            install(replacement.plan)
            blobs = replacement.retained.merging(replacement.plan.blobs) { _, new in new }
        }
        var result: [String: Data] = [:]
        for name in names {
            guard let bytes = blobs[name] else { throw CloudRecordError.missingBlob }
            result[name] = bytes
        }
        return result
    }
    func writeBlobs(_ batch: [String: Data]) throws {
        for (name, bytes) in batch {
            try CloudCommitProtocol.validate(bytes, named: name)
            if let old = blobs[name], old != bytes { throw CloudRecordError.inconsistentCloud("Immutable test overwrite") }
            blobs[name] = bytes
        }
    }
    func publish(_ head: CloudCommitProtocol.Head, replacing expected: CloudCommitProtocol.Cursor) throws -> CloudCommitProtocol.Cursor {
        guard expected == cursor else { throw CloudRecordError.changedElsewhere }
        cursor.head = head; advanceTag()
        return cursor
    }
    func collect(_ names: [String], replacing expected: CloudCommitProtocol.Cursor, finishing: Bool) throws -> CloudCommitProtocol.Cursor {
        if let publisher = publisherAtCollection { publisherAtCollection = nil; install(publisher) }
        guard expected == cursor else { throw CloudRecordError.changedElsewhere }
        guard names.count <= 199 else { throw CloudRecordError.inconsistentCloud("Delete request exceeded atomic record limit") }
        let batch = collectionSizes.count + 1
        if case .beforeDelete(let at) = fault, at == batch { fault = nil; throw URLError(.networkConnectionLost) }
        if case .cancelled(let at) = fault, at == batch { fault = nil; throw CancellationError() }
        try Task.checkCancellation()
        let checkpoint = try CloudRetention.checkpoint(cursor, finishing: finishing)
        for name in names { blobs[name] = nil; removed.insert(name) }
        collectionSizes.append(names.count)
        cursor.head = checkpoint
        advanceTag()
        if case .afterDelete(let at) = fault, at == batch { fault = nil; throw URLError(.networkConnectionLost) }
        return cursor
    }
    private func install(_ plan: CloudCommitProtocol.Plan) {
        blobs.merge(plan.blobs) { _, new in new }
        cursor.head = plan.head; advanceTag()
    }
    private func advanceTag() { serial += 1; cursor.tag = Data(String(serial).utf8) }
}

@MainActor enum CloudRetentionChecks {
    static func run(sample: TaskBackup) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD RETENTION CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ action: () async throws -> Void) async throws {
            do { try await action() } catch { count += 1; return }
            throw TaskBackup.invalid("CLOUD RETENTION CHECK: " + label)
        }
        func eventually(_ condition: () async -> Bool) async throws -> Bool {
            for _ in 0..<1_000 {
                if await condition() { return true }
                try await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        func liveNames(_ head: CloudCommitProtocol.Head, blobs: [String: Data]) throws -> Set<String> {
            var retained = Set<String>()
            for pages in [head.pages] + (head.history ?? []) {
                var version = head; version.pages = pages; version.history = nil
                retained.formUnion(pages)
                retained.formUnion(try CloudCommitProtocol.references(head: version, blobs: blobs).map(\.blob))
            }
            return retained
        }
        func orphanBlobs(_ count: Int) -> [String: Data] {
            Dictionary(uniqueKeysWithValues: (0..<count).map {
                let bytes = Data("unpublished-\($0)".utf8)
                return (CloudCommitProtocol.name(bytes), bytes)
            })
        }
        let items = try CloudRecordCodec.items(sample)
        let tombstone = "task:" + UUID().uuidString
        var source = items; source[tombstone] = CloudItem()
        func history(_ starting: [String: CloudItem], rounds: ClosedRange<Int64>) throws -> (CloudCommitProtocol.Plan, [String: Data]) {
            var latest: CloudCommitProtocol.Plan?, bytes: [String: Data] = [:]
            for round in rounds {
                var snapshot = sample; snapshot.tasks[0].notes = "Retained revision \(round)"
                var changed = starting
                changed["task:" + snapshot.tasks[0].id.uuidString] = try CloudRecordCodec.items(snapshot)["task:" + snapshot.tasks[0].id.uuidString]
                let plan = try CloudCommitProtocol.plan(items: changed, round: round, legacyDigest: nil, previous: latest?.head)
                bytes.merge(plan.blobs) { _, new in new }; latest = plan
            }
            guard let latest else { throw TaskBackup.invalid("Missing retention fixture") }
            return (latest, bytes)
        }

        // Fixed hash buckets prevent an insertion from moving every subsequent directory page.
        var large: [String: CloudItem] = [:]
        for index in 0..<3_000 {
            let key = String(format: "task:00000000-0000-0000-0000-%012d", index)
            large[key] = CloudItem(payload: Data("entry-\(index)".utf8))
        }
        let original = try CloudCommitProtocol.plan(items: large, round: 1, legacyDigest: nil)
        let targetKey = large.keys.sorted()[1_500]
        var edited = large; edited[targetKey]?.payload = Data("changed".utf8)
        let modified = try CloudCommitProtocol.plan(items: edited, round: 2, legacyDigest: nil, previous: original.head)
        let newPages = Set(modified.head.pages).subtracting(original.head.pages)
        let changedDirectoryBytes = newPages.reduce(0) { $0 + (modified.blobs[$1]?.count ?? 0) }
        try check(newPages.count == 1, "3,000-row edit changes one directory page")
        try check(changedDirectoryBytes <= 16 * 1_024, "single edit directory growth stays within 16 KiB")
        try check(Set(original.head.pages).subtracting(modified.head.pages).count == 1, "all other buckets retain content-addressed page names")
        edited[targetKey]?.payload = Data("changed again".utf8)
        let mature = try CloudCommitProtocol.plan(items: edited, round: 3, legacyDigest: nil, previous: modified.head)
        let maturePages = Set(mature.head.pages).subtracting(modified.head.pages)
        let matureDirectoryBytes = maturePages.reduce(0) { $0 + (mature.blobs[$1]?.count ?? 0) }
        let matureHeadBytes = try CloudCommitProtocol.encode(mature.head).count
        try check(mature.head.history?.count == 2 && maturePages.count == 1, "metadata measurement includes the current manifest and two histories")
        try check(matureDirectoryBytes + matureHeadBytes < 128 * 1_024, "single-edit metadata budget includes the overwritten head")
        for inserting in [true, false] {
            var changed = large
            if inserting { changed["task:FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"] = CloudItem(payload: Data("inserted".utf8)) }
            else { changed[targetKey] = nil }
            let plan = try CloudCommitProtocol.plan(items: changed, round: 2, legacyDigest: nil, previous: original.head)
            let before = Set(original.head.pages).subtracting(plan.head.pages)
            let after = Set(plan.head.pages).subtracting(original.head.pages)
            try check(before.count == 1 && after.count == 1, "small insertion/deletion only rewrites its hash bucket")
            let refs = try CloudCommitProtocol.references(head: plan.head, blobs: plan.blobs)
            try check(try CloudCommitProtocol.items(references: refs, blobs: plan.blobs) == changed, "bucket changes retain every row")
        }

        let (plan, versions) = try history(source, rounds: 1...40)
        let keep = try liveNames(plan.head, blobs: versions)
        let orphans = orphanBlobs(610)
        let all = versions.merging(orphans) { _, new in new }
        try check(plan.head.history?.count == 2, "only two historical manifests remain in head")
        try check(Set(all.keys).subtracting(keep).count > 600, "fixture contains old versions and interrupted uploads")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var boundary = plan.head; boundary.round = 19; boundary.collectedRound = nil; boundary.collectedAt = now
        try check(!CloudRetention.isDue(boundary, now: now), "recent collection waits for twenty business commits")
        boundary.round = 20
        try check(CloudRetention.isDue(boundary, now: now), "twentieth commit schedules collection")
        boundary.collectedRound = 20; boundary.round = 39
        try check(!CloudRetention.isDue(boundary, now: now), "maintenance does not repeat before interval")
        boundary.round = 40
        try check(CloudRetention.isDue(boundary, now: now), "completed collection advances the interval")
        boundary.collectedRound = 40
        try check(!CloudRetention.isDue(boundary, now: now.addingTimeInterval(86_399)), "daily maintenance waits for twenty-four hours")
        try check(CloudRetention.isDue(boundary, now: now.addingTimeInterval(86_400)), "daily maintenance does not require new business commits")
        boundary.collectedAt = nil
        try check(CloudRetention.isDue(boundary, now: now), "first maintenance runs without an old timestamp")
        boundary.collectedAt = now.addingTimeInterval(300)
        try check(!CloudRetention.isDue(boundary, now: now), "small clock difference does not trigger extra collection")
        boundary.collectedAt = now.addingTimeInterval(301)
        try check(CloudRetention.isDue(boundary, now: now), "future maintenance timestamp cannot postpone collection indefinitely")
        for repetition in 0..<3 {
            let store = RetentionCommitStore(plan: plan, retained: all), before = await store.readHead()
            let after = try await CloudRetention.collect(store: store, cursor: before, maximumBatches: Int.max)
            try check(await store.names() == keep, "collection retains exactly current and two prior versions \(repetition)")
            try check(after.head.commit == before.head.commit && after.head.round == before.head.round && after.head.pages == before.head.pages, "maintenance does not change business commit")
            try check(after.tag != before.tag && after.head.maintenance != nil && after.head.collectedRound == after.head.round, "collection records completion with a fresh compare-and-swap tag")
            try check(after.head.collectedAt != nil && !CloudRetention.isDue(after.head), "successful collection records time and suppresses an immediate repeat")
            let batches = await store.collectionSizes
            try check(batches.count >= 4 && batches.allSatisfy { $0 <= 199 }, "all deletion batches leave one slot for the head")
            let current = try await CloudCommitTransport(store: store).fetch()
            try check(current.items[tombstone] == CloudItem(), "deletion tombstone remains readable after collection")
            try check(current.items == (try CloudCommitProtocol.items(references: CloudCommitProtocol.references(head: plan.head, blobs: versions), blobs: versions)), "cold reader retains the complete current snapshot")
            for pages in plan.head.history ?? [] {
                var old = plan.head; old.pages = pages; old.history = nil
                let oldBytes = try await store.readBlobs(pages)
                let refs = try CloudCommitProtocol.references(head: old, blobs: oldBytes)
                let records = try await store.readBlobs(refs.map(\.blob))
                try check(try CloudCommitProtocol.items(references: refs, blobs: records).count == source.count, "retained history remains fully readable")
            }
        }

        // Failures before/after an atomic batch and cancellation must be resumable on a fresh cursor.
        for fault in [RetentionCommitStore.Fault.beforeDelete(1), .beforeDelete(2), .afterDelete(1), .afterDelete(2), .cancelled(1), .cancelled(2), .enumeration] {
            let store = RetentionCommitStore(plan: plan, retained: all)
            await store.configure(fault)
            do { _ = try await CloudRetention.collect(store: store, cursor: store.readHead(), maximumBatches: Int.max) } catch { /* The next sync retries maintenance. */ }
            try check(await store.contains(keep), "interrupted collection never removes a retained version")
            await store.configure(nil)
            let result = try await CloudRetention.collect(store: store, cursor: store.readHead(), maximumBatches: Int.max)
            try check(await store.names() == keep && result.head.collectedRound == plan.head.round, "fresh collector finishes after failure or lost response")
        }

        // Missing/corrupted manifest pages fail closed, even when some preceding pages were valid.
        for historical in [false, true] {
            for corrupt in [false, true] {
                let store = RetentionCommitStore(plan: plan, retained: all)
                let page = historical ? plan.head.history![1][0] : plan.head.pages[0]
                if corrupt { await store.corrupt(page) } else { await store.remove(page) }
                try await rejects("incomplete mark must not sweep") { _ = try await CloudRetention.collect(store: store, cursor: store.readHead(), maximumBatches: Int.max) }
                let batches = await store.collectionSizes, removed = await store.removed
                try check(batches.isEmpty && removed.isEmpty, "failed mark issues no deletion requests")
            }
        }
        var migrating = plan; migrating.head = .init(commit: UUID(), round: 0, pages: [], migration: .init(previousRound: 0, hadHead: false, legacyDigest: nil))
        let migrationStore = RetentionCommitStore(plan: migrating, retained: all)
        try check(!CloudRetention.isDue(migrating.head, now: now), "first-run and daily schedules never collect an unfinished migration")
        do { _ = try await CloudRetention.collect(store: migrationStore, cursor: migrationStore.readHead(), maximumBatches: Int.max) } catch { /* Either refusal or no-op is safe. */ }
        try check(await migrationStore.collectionSizes.isEmpty, "incomplete migration never collects")
        let cancellationStore = RetentionCommitStore(plan: plan, retained: all)
        let cancelled = Task { @MainActor in try await CloudRetention.collect(store: cancellationStore, cursor: cancellationStore.readHead(), maximumBatches: Int.max) }
        cancelled.cancel()
        try await rejects("actual task cancellation aborts before any deletion") { _ = try await cancelled.value }
        try check(await cancellationStore.collectionSizes.isEmpty, "cancelled collection sends no mutation")

        // Maintenance is explicitly scheduled after the business result is committed locally.
        let maintenanceData = versions.merging(orphanBlobs(30)) { _, new in new }
        for fault in [RetentionCommitStore.Fault.beforeDelete(1), .afterDelete(1)] {
            let fixture = try history(source, rounds: 1...19)
            var before = fixture.0
            before.head.collectedAt = Date()
            let store = RetentionCommitStore(plan: before, retained: fixture.1.merging(orphanBlobs(30)) { _, new in new })
            let writer = CloudCommitTransport(store: store)
            let current = try await writer.fetch()
            await store.configure(fault)
            let saved = try await writer.save([:], round: 20)
            try check(saved.head?.round == 20 && saved.items == current.items, "business save completes before optional maintenance")
            try check(await store.inventories == 0, "fetch and save do not enumerate cloud history")
            await writer.performMaintenance()
            try check(await store.readHead().head.round == 20, "business head remains committed after failed maintenance")
            let reader = CloudCommitTransport(store: store)
            try check(try await reader.fetch().items == saved.items, "next sync reads committed data after failed maintenance")
            await reader.performMaintenance()
            try check(await store.readHead().head.collectedRound == 20, "maintenance resumes after coordinator recreation")
        }

        // Orphans may grow while every new upload fails: elapsed time must clean them without a new round.
        for firstCollection in [false, true] {
            var dormant = plan
            dormant.head.collectedRound = dormant.head.round
            dormant.head.collectedAt = firstCollection ? nil : Date().addingTimeInterval(-2 * 86_400)
            let store = RetentionCommitStore(plan: dormant, retained: maintenanceData)
            let reader = CloudCommitTransport(store: store)
            let unchanged = try await reader.fetch()
            try check(await store.inventories == 0, "idle fetch leaves history collection to background scheduling")
            await reader.performMaintenance()
            try check(await store.names() == keep, "idle account collects failed-upload orphans without advancing round")
            try check(unchanged.head?.round == dormant.head.round && unchanged.items.count == source.count, "idle collection does not change committed business data")
            let calls = await store.collectionSizes.count
            _ = try await reader.fetch()
            await reader.performMaintenance()
            try check(await store.collectionSizes.count == calls, "unchanged fetch does not repeat recently completed daily cleanup")
            let observed = await store.readHead()
            let inherited = try CloudCommitProtocol.plan(items: unchanged.items, round: observed.head.round + 1, legacyDigest: observed.head.legacyDigest, previous: observed.head)
            try check(inherited.head.collectedAt == observed.head.collectedAt, "next business commit preserves last collection time")
        }
        let deferredStore = RetentionCommitStore(plan: plan, retained: maintenanceData)
        await deferredStore.configure(.enumeration)
        let deferredReader = CloudCommitTransport(store: deferredStore)
        let firstRead = try await deferredReader.fetch()
        await deferredReader.performMaintenance()
        let attempts = await deferredStore.inventories
        let secondRead = try await deferredReader.fetch()
        await deferredReader.performMaintenance()
        try check(await deferredStore.inventories == attempts && attempts == 1, "failed optional inventory backs off within the running process")
        try check(firstRead == secondRead, "maintenance retry delay leaves business data and generation unchanged")
        let restartedReader = CloudCommitTransport(store: deferredStore)
        _ = try await restartedReader.fetch()
        await restartedReader.performMaintenance()
        try check(await deferredStore.names() == keep, "a restarted coordinator can resume maintenance without persistent failure state")

        // A maintenance slice stops after two atomic batches, without falsely marking the sweep complete.
        for repetition in 0..<3 {
            let store = RetentionCommitStore(plan: plan, retained: all)
            let before = await store.readHead()
            let partial = try await CloudRetention.collect(store: store, cursor: before)
            let batches = await store.collectionSizes
            try check(batches.count == 2 && batches.reduce(0, +) == 398, "default collection limits one slice to 398 retired records \(repetition)")
            try check(partial.head.collectedRound == before.head.collectedRound && partial.head.collectedAt == before.head.collectedAt,
                      "partial slice does not claim collection completion")
            try check(await store.contains(keep) && CloudRetention.isDue(partial.head), "partial maintenance retains every current and historical reference")
            let next = try await CloudRetention.collect(store: store, cursor: partial)
            try check(await store.names() == keep && next.head.collectedRound == plan.head.round,
                      "next slice resumes safely with a new cursor and completes remaining records")
        }
        let budgetStore = RetentionCommitStore(plan: plan, retained: all)
        let budgetReader = CloudCommitTransport(store: budgetStore)
        _ = try await budgetReader.fetch()
        await budgetReader.performMaintenance()
        let limitedCalls = await budgetStore.collectionSizes.count
        try check(limitedCalls == 2, "scheduled maintenance uses the bounded collection default")
        await budgetReader.performMaintenance()
        try check(await budgetStore.collectionSizes.count == limitedCalls, "partial collection yields before a later slice")
        let budgetRestart = CloudCommitTransport(store: budgetStore)
        _ = try await budgetRestart.fetch()
        await budgetRestart.performMaintenance()
        try check(await budgetStore.names() == keep, "a new coordinator resumes a partial background collection")

        // A slow inventory never holds up reading or publishing; cancelled work cannot rewrite a newer cursor.
        for repetition in 0..<3 {
            let gate = RetentionInventoryGate()
            let store = RetentionCommitStore(plan: plan, retained: all)
            await store.pauseInventory(with: gate)
            let writer = CloudCommitTransport(store: store)
            let fetchDone = RetentionCompletion()
            let firstFetch = Task { @MainActor in
                defer { fetchDone.finished = true }
                return try await writer.fetch()
            }
            let returned = try await eventually {
                if fetchDone.finished { return true }
                return await gate.entered
            }
            let enteredBeforeScheduling = await gate.entered
            if !returned || enteredBeforeScheduling { await gate.release() }
            let firstState = try await firstFetch.value
            try check(returned && !enteredBeforeScheduling, "fetch returns before requesting any inventory \(repetition)")
            let maintenance = Task { await writer.performMaintenance() }
            let entered = try await eventually { await gate.entered }
            if !entered { await gate.release() }
            try check(entered, "explicit background maintenance reaches the inventory gate")
            let readDone = RetentionCompletion()
            let foregroundRead = Task { @MainActor in
                defer { readDone.finished = true }
                return try await writer.fetch()
            }
            let readReturned = try await eventually { readDone.finished }
            if !readReturned { await gate.release() }
            let read = try await foregroundRead.value
            try check(readReturned && read.items == firstState.items, "foreground fetch completes while inventory is still waiting")
            var changedSnapshot = sample; changedSnapshot.tasks[0].notes = "Foreground during maintenance \(repetition)"
            var changedItems = try CloudRecordCodec.items(changedSnapshot); changedItems[tombstone] = CloudItem()
            let saveDone = RetentionCompletion()
            let foregroundSave = Task { @MainActor in
                defer { saveDone.finished = true }
                return try await writer.save(CloudRecordCodec.changes(from: read.items, to: changedItems), round: 41)
            }
            let saveReturned = try await eventually { saveDone.finished }
            if !saveReturned { await gate.release() }
            let saved = try await foregroundSave.value
            try check(saveReturned && saved.items == changedItems && saved.head?.round == 41,
                      "foreground save publishes without waiting for old inventory")
            await writer.performMaintenance()
            try check(await store.inventories == 1, "a delayed cancelled job cannot start a parallel collector")
            await gate.release()
            await maintenance.value
            try check(await store.collectionSizes.isEmpty, "cancelled stale maintenance never starts deleting")
            try check(try await writer.fetch().items == changedItems, "late maintenance completion cannot replace the newer business cursor")
            _ = try await writer.save([:], round: 42)
            try check(await store.readHead().head.round == 42, "the newer cursor remains usable for the next publication")
        }
        // Normal polling must not starve a slow inventory by cancelling it every time the head is read.
        for repetition in 0..<3 {
            let gate = RetentionInventoryGate()
            let store = RetentionCommitStore(plan: plan, retained: maintenanceData)
            await store.pauseInventory(with: gate)
            let reader = CloudCommitTransport(store: store)
            let originalState = try await reader.fetch()
            let maintenance = Task { await reader.performMaintenance() }
            let entered = try await eventually { await gate.entered }
            if !entered { await gate.release() }
            try check(entered, "slow inventory starts before ordinary polling \(repetition)")
            for poll in 0..<3 {
                let read = try await reader.fetch()
                try check(read == originalState, "unchanged polling returns committed data during inventory \(poll)")
                await reader.performMaintenance()
            }
            try check(await store.inventories == 1, "unchanged polls reuse the existing maintenance job")
            await gate.release()
            await maintenance.value
            let collected = await store.readHead()
            try check(await store.names() == keep && collected.head.collectedRound == plan.head.round,
                      "slow inventory survives repeated fetches and completes its sweep")
            let saved = try await reader.save([:], round: 41)
            try check(saved.head?.round == 41 && saved.items == originalState.items,
                      "finished maintenance hands its fresh cursor to the next publication")
        }
        let cancelGate = RetentionInventoryGate()
        let cancelStore = RetentionCommitStore(plan: plan, retained: all)
        await cancelStore.pauseInventory(with: cancelGate)
        let cancelReader = CloudCommitTransport(store: cancelStore)
        _ = try await cancelReader.fetch()
        let cancelledMaintenance = Task { await cancelReader.performMaintenance() }
        let cancellationEntered = try await eventually { await cancelGate.entered }
        if !cancellationEntered { await cancelGate.release() }
        try check(cancellationEntered, "cancellation fixture reached the suspended inventory")
        cancelledMaintenance.cancel()
        await cancelGate.release()
        await cancelledMaintenance.value
        try check(await cancelStore.collectionSizes.isEmpty, "external maintenance cancellation reaches the child collection job")
        try check(try await cancelReader.fetch().items.count == source.count, "cancelled maintenance leaves committed data immediately readable")

        var nextSnapshot = sample; nextSnapshot.tasks[0].notes = "Concurrent publisher"
        var nextItems = try CloudRecordCodec.items(nextSnapshot); nextItems[tombstone] = CloudItem()
        let next = try CloudCommitProtocol.plan(items: nextItems, round: 41, legacyDigest: nil, previous: plan.head)
        for publisherWins in [true, false] {
            let store = RetentionCommitStore(plan: plan, retained: all), stale = await store.readHead()
            try await store.writeBlobs(next.blobs)
            if publisherWins {
                await store.publishDuringCollection(next)
                do { _ = try await CloudRetention.collect(store: store, cursor: stale, maximumBatches: Int.max) } catch { /* Stale collector must stop. */ }
                try check(await store.contains(Set(next.blobs.keys)), "winning publisher protects staged records from stale collector")
                try check(await store.collectionSizes.isEmpty, "stale collector cannot delete even one atomic batch")
                try check(try await CloudCommitTransport(store: store).fetch().items == nextItems, "published snapshot stays complete after GC loses compare-and-swap")
            } else {
                _ = try await CloudRetention.collect(store: store, cursor: stale, maximumBatches: Int.max)
                try await rejects("publisher fetched before collection cannot publish deleted staged records") { _ = try await store.publish(next.head, replacing: stale) }
                let writer = CloudCommitTransport(store: store)
                let current = try await writer.fetch()
                _ = try await writer.save(CloudRecordCodec.changes(from: current.items, to: nextItems), round: 41)
                try check(try await CloudCommitTransport(store: store).fetch().items == nextItems, "publisher refetches and uploads missing versions after collection wins")
            }
        }

        // A slow reader's head can age out while it downloads pages. Retry only a changed head.
        let (newest, newestVersions) = try history(source, rounds: 41...44)
        let readerStore = RetentionCommitStore(plan: plan, retained: all)
        await readerStore.replaceDuringRead(newest, retained: newestVersions)
        let read = try await CloudCommitTransport(store: readerStore).fetch()
        let newestRefs = try CloudCommitProtocol.references(head: newest.head, blobs: newest.blobs)
        try check(read.items == CloudCommitProtocol.items(references: newestRefs, blobs: newest.blobs) && read.head?.round == 44, "reader retries head when old blobs were collected during download")
        let missingStore = RetentionCommitStore(plan: plan, retained: all)
        await missingStore.remove(plan.head.pages[0])
        try await rejects("missing page with unchanged head remains an error") { _ = try await CloudCommitTransport(store: missingStore).fetch() }
        try check(await missingStore.reads <= 2, "unchanged damaged head is not polled indefinitely")
        let movingStore = RetentionCommitStore(plan: plan, retained: all)
        for first: Int64 in [41, 45, 49] {
            let (replacement, retained) = try history(source, rounds: first...(first + 3))
            await movingStore.replaceDuringRead(replacement, retained: retained)
        }
        try await rejects("continuously moving head defers rather than looping") { _ = try await CloudCommitTransport(store: movingStore).fetch() }
        try check(await movingStore.reads == 3, "reader caps retries at three attempts")
        try check(try await CloudCommitTransport(store: movingStore).fetch().head?.round == 52, "next sync succeeds once concurrent changes settle")
        print("CLOUD RETENTION PASS: \(count) checks; 3000-row single edit adds \(changedDirectoryBytes) directory bytes in \(newPages.count) page")
        print("CLOUD RETENTION METADATA: 3000 rows, 2 retained histories; new directory \(matureDirectoryBytes) bytes + overwritten head \(matureHeadBytes) bytes = \(matureDirectoryBytes + matureHeadBytes) metadata bytes written")
        return count
    }
}
