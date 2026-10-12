import Foundation
import CloudKit

/// Per-record sync without an account or network: the row codec, minimal uploads, unfinished rounds and
/// two devices saving at once, through the in-memory cloud.
@MainActor enum CloudRecordChecks {
    static func run() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD RECORD CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { count += 1; return }
            throw TaskBackup.invalid("CLOUD RECORD CHECK: " + label)
        }
        func rejectsAsync(_ label: String, matching expected: (Error) -> Bool, _ operation: () async throws -> Void) async throws {
            do { try await operation() } catch where expected(error) { count += 1; return }
            throw TaskBackup.invalid("CLOUD RECORD CHECK: " + label)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actor = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

        // A snapshot with every row kind, sync history and a deletion tombstone.
        let list = TaskList(name: "Home")
        let task = TaskItem(title: "Plan trip", list: list)
        task.notes = "Passport"; task.subtasks = [Subtask(title: "Book flight")]
        var sample = TaskBackup(finance: FinanceData.initial, weekTitles: [.init(week: "2026-10-05", title: "Travel week")],
                                lists: [.init(id: list.id, name: list.name, createdAt: now)], tasks: [.init(task)])
        sample.tasks[0].createdAt = now
        let account = MoneyAccount(name: "Card", currency: "AUD")
        sample.finance!.accounts = [account]
        var coffee = MoneyEntry(); coffee.title = "Coffee"; coffee.date = now; coffee.currency = "AUD"
        coffee.amount = 12; coffee.accountID = account.id; coffee.accountAmount = 12; coffee.bookID = sample.finance!.books[0].id
        sample.finance!.entries = [coffee]
        sample.finance!.rates = [MoneyRate(base: "AUD", quote: "CNY", rate: 4.7, date: "2026-10-08", fetchedAt: now)]
        let deletedKey = SyncChanges.key("task", UUID())
        var revisions: SyncChanges.Revisions = [:]
        var changes: [String: String?] = Dictionary(uniqueKeysWithValues: try SyncChanges.fingerprints(sample).map { ($0.key, .some($0.value)) })
        changes[deletedKey] = .some(nil)
        SyncChanges.record(changes, in: &revisions, now: now, fieldFingerprints: try SyncFields.snapshot(sample),
                           createdKeys: Set(changes.keys), actor: actor)
        sample.syncChanges = revisions
        let sampleBytes = try CloudMerge.bytes(sample)

        // Codec round trips.
        let items = try CloudRecordCodec.items(sample)
        try check(try CloudMerge.bytes(CloudRecordCodec.snapshot(items)) == sampleBytes, "rows and history survive a per-record round trip")
        try check(items[deletedKey]?.payload == nil && items[deletedKey]?.revision != nil, "a deletion travels as a tombstone with its history")
        try check(items[SyncChanges.currencyKey]?.payload != nil, "a ledger always has its base currency record")
        var noLedger = sample; noLedger.finance = nil
        noLedger.syncChanges = sample.syncChanges?.filter { !SyncChanges.isFinanceKey($0.key) }
        try check(try CloudRecordCodec.snapshot(CloudRecordCodec.items(noLedger)).finance == nil, "no ledger stays no ledger")
        var emptyLedger = noLedger; emptyLedger.finance = FinanceData()
        try check(try CloudRecordCodec.snapshot(CloudRecordCodec.items(emptyLedger)).finance == FinanceData(), "an empty ledger stays an empty ledger")
        try check(try CloudRecordCodec.items(sample) == items, "encoding is deterministic")

        // Only differences are uploaded.
        try check(CloudRecordCodec.changes(from: items, to: items).isEmpty, "an unchanged snapshot uploads nothing")
        var edited = sample; edited.tasks[0].title = "Plan holiday"
        let taskKey = SyncChanges.key("task", task.id)
        try check(Set(CloudRecordCodec.changes(from: items, to: try CloudRecordCodec.items(edited)).keys) == [taskKey],
                  "editing one task uploads only that task")
        var removed = sample; removed.weekTitles = []
        let weekKey = SyncChanges.key("week", sample.weekTitles![0].id)
        let removal = CloudRecordCodec.changes(from: items, to: try CloudRecordCodec.items(removed))
        try check(removal[weekKey]?.payload == nil && removal[weekKey]?.revision != nil, "removing a row keeps its history as a tombstone")
        var untracked = items; untracked["task:" + UUID().uuidString] = CloudItem(payload: items[taskKey]!.payload)
        try check(CloudRecordCodec.changes(from: untracked, to: items).values.allSatisfy { $0 == CloudItem() },
                  "a cloud row missing locally without history is cleared")

        // Corrupted or foreign rows are refused instead of being merged.
        try rejects("a row under another row's key is refused") {
            var moved = items; moved["task:" + UUID().uuidString] = items[taskKey]; _ = try CloudRecordCodec.snapshot(moved)
        }
        try rejects("unknown record kinds are refused") {
            var unknown = items; unknown["photo:" + UUID().uuidString] = CloudItem(payload: Data("{}".utf8)); _ = try CloudRecordCodec.snapshot(unknown)
        }
        try rejects("ledger rows without a base currency are refused") {
            var headless = items; headless[SyncChanges.currencyKey] = CloudItem(); _ = try CloudRecordCodec.snapshot(headless)
        }
        try rejects("a dangling reference is refused") {
            var dangling = items; dangling[SyncChanges.key("list", list.id)] = CloudItem(); _ = try CloudRecordCodec.snapshot(dangling)
        }
        try rejects("oversized rows are refused before upload") {
            try CloudRecordLimits.validate(["task:x": CloudItem(payload: Data(count: CloudRecordLimits.maximumItemBytes + 1))])
        }

        // Two devices through the in-memory cloud.
        let cloud = InMemoryCloud()
        let mac = InMemoryRecordTransport(cloud: cloud), phone = InMemoryRecordTransport(cloud: cloud)
        var macState = try await mac.fetch()
        try check(macState.isEmpty && !macState.hasUnfinishedRound, "a new zone is empty")
        macState = try await mac.save(CloudRecordCodec.changes(from: macState.items, to: items), round: 1)
        var phoneState = try await phone.fetch()
        try check(phoneState.head?.round == 1 && !phoneState.hasUnfinishedRound, "the first round finishes with its head")
        try check(try CloudMerge.bytes(CloudRecordCodec.snapshot(phoneState.items)) == sampleBytes, "the other device reads the same snapshot")
        let generation = phoneState.generation
        phoneState = try await phone.fetch()
        try check(phoneState.generation == generation, "an unchanged fetch keeps its generation for caching")

        // An interrupted upload stays invisible until it is completed.
        var bigger = edited; bigger.lists[0].name = "House"; bigger.weekTitles = []
        let pending = CloudRecordCodec.changes(from: macState.items, to: try CloudRecordCodec.items(bigger))
        await cloud.setInterrupt(after: 1)
        try await rejectsAsync("an interrupted upload reports a failure", matching: { $0 is URLError }) {
            _ = try await mac.save(pending, round: 2)
        }
        phoneState = try await phone.fetch()
        try check(phoneState.hasUnfinishedRound, "rows without their head are seen as an unfinished upload")
        try check(!phoneState.canResume(as: phone.writer, now: Date()), "another device waits while an upload may still be running")
        try check(phoneState.canResume(as: phone.writer, now: Date().addingTimeInterval(CloudState.abandonedAfter + 60)),
                  "an abandoned upload can be completed by another device")
        try check(try phoneState.finishedItems.map { try CloudMerge.bytes(CloudRecordCodec.snapshot($0)) } == sampleBytes,
                  "a device that saw the overwritten rows rebuilds the last finished state")
        let fresh = InMemoryRecordTransport(cloud: cloud)
        try check(try await fresh.fetch().finishedItems == nil, "a fresh device cannot rebuild what it never saw")
        macState = try await mac.fetch()
        try check(macState.canResume(as: mac.writer, now: Date()), "a device always completes its own interrupted upload")
        try check(try macState.finishedItems.map { try CloudMerge.bytes(CloudRecordCodec.snapshot($0)) } == sampleBytes,
                  "the interrupted device merges against the last finished state, not the partial rows")
        macState = try await mac.save(CloudRecordCodec.changes(from: macState.items, to: try CloudRecordCodec.items(bigger)), round: (macState.head?.round ?? 0) + 1)
        phoneState = try await phone.fetch()
        try check(!phoneState.hasUnfinishedRound && (try CloudMerge.bytes(CloudRecordCodec.snapshot(phoneState.items))) == CloudMerge.bytes(bigger),
                  "a retried upload completes the round")

        // An interrupted first upload leaves no head; its own device resumes it from an empty cloud.
        let firstCloud = InMemoryCloud(), first = InMemoryRecordTransport(cloud: firstCloud)
        _ = try await first.fetch()
        await firstCloud.setInterrupt(after: 1)
        try await rejectsAsync("an interrupted first upload reports a failure", matching: { $0 is URLError }) {
            _ = try await first.save(CloudRecordCodec.changes(from: [:], to: items), round: 1)
        }
        let firstState = try await first.fetch()
        try check(firstState.head == nil && firstState.canResume(as: first.writer, now: Date())
                  && firstState.finishedItems?.values.allSatisfy { $0 == CloudItem() } == true, "an interrupted first upload resumes from an empty cloud")

        // Both devices save on the same head: the second must merge again instead of overwriting.
        var macEdit = bigger; macEdit.tasks[0].notes = "Passport and visa"
        var phoneEdit = bigger; phoneEdit.lists[0].name = "Apartment"
        let round = (phoneState.head?.round ?? 0) + 1
        _ = try await mac.save(CloudRecordCodec.changes(from: macState.items, to: try CloudRecordCodec.items(macEdit)), round: round)
        try await rejectsAsync("a save on an outdated head is refused", matching: { $0 as? CloudRecordError == .changedElsewhere }) {
            _ = try await phone.save(CloudRecordCodec.changes(from: phoneState.items, to: try CloudRecordCodec.items(phoneEdit)), round: round)
        }
        phoneState = try await phone.fetch()
        try check(try CloudRecordCodec.snapshot(phoneState.items).tasks[0].notes == "Passport and visa"
                  && CloudRecordCodec.snapshot(phoneState.items).lists[0].name == "House", "the refused save changed nothing in the cloud")
        var combined = try CloudRecordCodec.snapshot(phoneState.items); combined.lists[0].name = "Apartment"
        phoneState = try await phone.save(CloudRecordCodec.changes(from: phoneState.items, to: try CloudRecordCodec.items(combined)), round: (phoneState.head?.round ?? 0) + 1)
        macState = try await mac.fetch()
        try check(try CloudMerge.bytes(CloudRecordCodec.snapshot(macState.items)) == CloudMerge.bytes(combined), "after retrying, both devices agree")

        // The mirror file format keeps rows, rounds, head and the engine token together.
        var mirror = CloudMirror()
        mirror.items[taskKey] = .init(item: items[taskKey]!, round: 3, systemFields: Data([1, 2]))
        mirror.head = CloudHead(round: 3, format: CloudRecordCodec.format); mirror.engineState = Data([9])
        let restored = try JSONDecoder().decode(CloudMirror.self, from: JSONEncoder().encode(mirror))
        try check(restored.state == mirror.state && restored.engineState == mirror.engineState && restored.items[taskKey]?.systemFields == Data([1, 2]),
                  "the mirror round-trips with its engine state")
        var cleared = restored; cleared.clearContents()
        try check(cleared.state.isEmpty && cleared.generation > restored.generation && cleared.engineState == restored.engineState,
                  "clearing the zone's rows invalidates cached snapshots")

        // An atomic save rejects every record; the message must name the rejected one, not "batch request failed".
        let batch = CKError(.batchRequestFailed), rejected = CKError(.serverRejectedRequest)
        try check((CloudKitRecordTransport.rootFailure([batch, rejected, batch]) as? CKError)?.code == .serverRejectedRequest
                  && (CloudKitRecordTransport.rootFailure([batch]) as? CKError)?.code == .batchRequestFailed
                  && CloudKitRecordTransport.rootFailure([]) == nil, "a failed upload reports the record that was rejected")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["a": batch, "b": rejected]])
        try check(CloudSync.message(partial) == CloudSync.message(rejected) && CloudSync.message(rejected).contains(L("拒绝", "rejected")),
                  "a server rejection inside a partial failure gets the rejection message")

        print("CLOUD RECORD PASS: \(count) checks")
        return count
    }
}
