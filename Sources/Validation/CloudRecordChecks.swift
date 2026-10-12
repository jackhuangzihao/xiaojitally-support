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
        coffee.taskID = task.id
        let bill = MoneyRecurring(title: "Coffee plan", amount: 12, currency: "AUD", accountID: account.id,
                                  accountAmount: 12, bookID: coffee.bookID, rule: "monthly", anchorDay: 15, nextDate: now)
        sample.finance!.recurring = [bill]; coffee.recurringID = bill.id
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

        count += try await CloudCommitChecks.run(sample: sample)
        count += try await CloudBatchChecks.run(sample: sample)
        count += try await CloudReuploadChecks.run(sample: sample)
        count += try CloudMigrationChecks.run(sample: sample)
        count += try await CloudCommitChecks.recovery(sample: sample)
        count += try await CloudRetentionChecks.run(sample: sample)

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
