import Foundation
import SwiftData

@MainActor enum CausalSyncChecks {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CAUSAL SYNC CHECK: " + label) }; count += 1
        }
        func requiresReview(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch is CloudMerge.Conflict { count += 1; return }
            throw TaskBackup.invalid("CAUSAL SYNC CHECK: " + label)
        }
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func edited(_ value: TaskBackup, from original: TaskBackup? = nil, actor: UUID?, date: Date) throws -> TaskBackup {
            var result = value, revisions = original?.syncChanges ?? [:]
            let before = try original.map(SyncChanges.fingerprints) ?? [:], after = try SyncChanges.fingerprints(value)
            var changes: [String: String?] = [:]
            for key in Set(before.keys).union(after.keys) where before[key] != after[key] { changes[key] = .some(after[key]) }
            SyncChanges.record(changes, in: &revisions, now: date, fieldFingerprints: try SyncFields.snapshot(value),
                previousFieldFingerprints: try original.map(SyncFields.snapshot) ?? [:],
                createdKeys: Set(after.keys).subtracting(before.keys), actor: actor, previousFingerprints: before)
            result.syncChanges = revisions
            return result
        }
        func converges(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup?, choices: [String: CloudMerge.Choice] = [:]) throws -> TaskBackup {
            let merged = try CloudMerge.merge(local: local, cloud: cloud, base: base, choices: choices, now: now)
            let inverse = choices.mapValues { $0 == .local ? CloudMerge.Choice.cloud : .local }
            let encoded = try CloudMerge.bytes(merged)
            try check(try CloudMerge.bytes(CloudMerge.merge(local: cloud, cloud: local, base: base, choices: inverse, now: now)) == encoded,
                      "device order does not alter chosen values or causal history")
            for _ in 0..<3 {
                try check(try CloudMerge.bytes(CloudMerge.merge(local: merged, cloud: merged, base: base, now: now)) == encoded,
                          "repeated merges do not create edits or grow causal history")
            }
            return merged
        }
        for round in 0..<3 {
            var task = TaskBackup.TaskRecord(TaskItem(title: "Original"))
            task.createdAt = now; task.subtasks = [Subtask(title: "Original step")]
            let key = SyncChanges.key("task", task.id)
            let base = try edited(TaskBackup(lists: [], tasks: [task]), actor: a, date: now)
            var left = base, right = base
            left.tasks[0].title = "Mac title"; right.tasks[0].title = "Phone title"
            left = try edited(left, from: base, actor: a, date: now.addingTimeInterval(3600 + Double(round)))
            right = try edited(right, from: base, actor: b, date: now.addingTimeInterval(-3600 - Double(round)))
            let titleLeft = left
            let result = try converges(left, right, base)
            let expected = result.tasks[0].title
            var shiftedLeft = left, shiftedRight = right
            shiftedLeft.syncChanges?[key]?.date = now.addingTimeInterval(-7200)
            shiftedLeft.syncChanges?[key]?.fields?["title"]?.date = now.addingTimeInterval(-7200)
            shiftedRight.syncChanges?[key]?.date = now.addingTimeInterval(7200)
            shiftedRight.syncChanges?[key]?.fields?["title"]?.date = now.addingTimeInterval(7200)
            try check(try CloudMerge.merge(local: shiftedLeft, cloud: shiftedRight, base: base, now: now).tasks[0].title == expected,
                      "wall-clock skew does not change a causal concurrent decision")
            var next = result; next.tasks[0].title = "After observing both"
            next = try edited(next, from: result, actor: b, date: now.addingTimeInterval(-9999))
            try check(try converges(left, next, base).tasks[0].title == next.tasks[0].title,
                      "a causally later edit wins even on a slower clock")

            left = base; right = base
            left.tasks[0].subtasks[0].title = "Local step"; right.tasks[0].subtasks[0].title = "Cloud step"
            left.tasks[0].title = "Automatic title A"; right.tasks[0].title = "Automatic title B"
            left = try edited(left, from: base, actor: a, date: now)
            right = try edited(right, from: base, actor: b, date: now)
            try requiresReview("concurrent subtask changes still require confirmation") { _ = try CloudMerge.merge(local: left, cloud: right, base: base) }
            let reviewed = try converges(left, right, base, choices: [key: .local])
            try check(reviewed.tasks[0].subtasks == left.tasks[0].subtasks, "manual review chooses the requested subtask")
            let opposite = try converges(left, right, base, choices: [key: .cloud])
            let reconciled = try converges(reviewed, opposite, base, choices: [key: .local])
            try check(try converges(opposite, reconciled, base).tasks == reconciled.tasks,
                      "a later confirmation resolves contradictory simultaneous confirmations")
            let propagated = try converges(right, reviewed, base)
            try check(propagated.tasks == reviewed.tasks, "the other device does not repeat the same manual question")
            var unrelated = right; unrelated.tasks[0].notes = "A new unrelated note"
            unrelated.tasks[0].subtasks.append(Subtask(title: "A new independent step"))
            unrelated = try edited(unrelated, from: right, actor: b, date: now)
            let combined = try converges(unrelated, reviewed, base)
            try check(combined.tasks[0].subtasks.contains { $0.title == "A new independent step" }
                      && combined.tasks[0].subtasks.contains { $0.title == "Local step" },
                      "new independent steps do not repeat an already resolved step conflict")
            var movedAway = right; movedAway.tasks[0].subtasks[0].title = "Another new intent"
            movedAway = try edited(movedAway, from: right, actor: b, date: now)
            var reverted = movedAway; reverted.tasks[0].subtasks[0].title = right.tasks[0].subtasks[0].title
            reverted = try edited(reverted, from: movedAway, actor: b, date: now)
            try requiresReview("ABA content is a new edit, not an old acknowledged value") {
                _ = try CloudMerge.merge(local: reverted, cloud: reviewed, base: base)
            }
            // A real revert to the baseline is also a new edit, not an unchanged-side shortcut.
            var revertedTitle = next; revertedTitle.tasks[0].title = base.tasks[0].title
            revertedTitle = try edited(revertedTitle, from: next, actor: c, date: now.addingTimeInterval(-10000))
            try check(try converges(titleLeft, revertedTitle, base).tasks[0].title == base.tasks[0].title,
                      "a deliberate baseline-value revert survives content-equality shortcuts")

            for unknownFields in [false, true] {
                var legacyBase = base, legacyLeft = left, legacyRight = right
                if unknownFields {
                    for record in [key] {
                        legacyBase.syncChanges?[record]?.version = nil
                        legacyLeft.syncChanges?[record]?.version = nil; legacyRight.syncChanges?[record]?.version = nil
                        for name in legacyBase.syncChanges?[record]?.fields?.keys ?? [:].keys {
                            legacyBase.syncChanges?[record]?.fields?[name]?.date = nil; legacyBase.syncChanges?[record]?.fields?[name]?.version = nil
                            legacyLeft.syncChanges?[record]?.fields?[name]?.date = nil; legacyLeft.syncChanges?[record]?.fields?[name]?.version = nil
                            legacyRight.syncChanges?[record]?.fields?[name]?.date = nil; legacyRight.syncChanges?[record]?.fields?[name]?.version = nil
                        }
                    }
                } else { legacyBase.syncChanges = nil; legacyLeft.syncChanges = nil; legacyRight.syncChanges = nil }
                let accepted = try converges(legacyLeft, legacyRight, legacyBase, choices: [key: .local])
                try check(try converges(legacyRight, accepted, legacyBase).tasks == accepted.tasks,
                          "explicit review propagates even for old data with missing edit history")
                var changed = legacyRight; changed.tasks[0].subtasks[0].title = "An actual post-upgrade edit"
                changed = try edited(changed, from: legacyRight, actor: b, date: now)
                try requiresReview("old-data acknowledgement cannot suppress a real new edit") {
                    _ = try CloudMerge.merge(local: changed, cloud: accepted, base: legacyBase)
                }
            }
        }
        for round in 0..<3 {
            var task = TaskBackup.TaskRecord(TaskItem(title: "Legacy deletion")); task.createdAt = now
            let base = TaskBackup(lists: [], tasks: [task])
            let deleted = TaskBackup(lists: [], tasks: [])
            var changed = base; changed.tasks[0].notes = "Cloud edit"
            let chain = "task-chain:" + task.id.uuidString
            let accepted = try converges(deleted, changed, base, choices: [chain: .local])
            try check(accepted.tasks.isEmpty, "review can explicitly choose a legacy deletion without a tombstone")
            try check(try converges(changed, accepted, base).tasks.isEmpty,
                      "the confirmed legacy deletion reaches the other device without another question")
            var restored = changed; restored.tasks[0].notes = "New edit after old deletion review \(round)"
            restored = try edited(restored, from: changed, actor: b, date: now)
            try requiresReview("new edit is not erased by the old deletion acknowledgement") {
                _ = try CloudMerge.merge(local: restored, cloud: accepted, base: base)
            }

            var finance = FinanceData.initial
            finance.rates = [MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-01", fetchedAt: now, source: "Manual")]
            let rateBase = try edited(TaskBackup(finance: finance, lists: [], tasks: []), actor: a, date: now)
            var rateLeft = rateBase, rateRight = rateBase
            rateLeft.finance!.rates[0].rate = 8; rateRight.finance!.rates[0].rate = 9
            rateLeft = try edited(rateLeft, from: rateBase, actor: a, date: now)
            rateRight = try edited(rateRight, from: rateBase, actor: b, date: now)
            let selected = try converges(rateLeft, rateRight, rateBase, choices: ["rate:CNY/USD": .local])
            try check(try converges(rateRight, selected, rateBase).finance?.rates == selected.finance?.rates,
                      "a confirmed manual quote does not prompt again on the other device")
            var reset = selected; reset.finance!.rates = []
            reset = try edited(reset, from: selected, actor: a, date: now)
            try check(!CloudMerge.isUntouchedInitialFinance(reset), "a reset quote remains a real financial edit")
            try check(try converges(rateRight, reset, nil).finance?.rates.isEmpty == true,
                      "a causal quote reset survives first-sync default handling")
        }
        do {
            var task = TaskBackup.TaskRecord(TaskItem(title: "Deleted on both devices")); task.createdAt = now
            let base = try edited(TaskBackup(lists: [], tasks: [task]), actor: a, date: now)
            let first = try edited(TaskBackup(lists: [], tasks: []), from: base, actor: a, date: now.addingTimeInterval(900))
            let second = try edited(TaskBackup(lists: [], tasks: []), from: base, actor: b, date: now.addingTimeInterval(-900))
            let key = SyncChanges.key("task", task.id)
            var imported = first; imported.syncChanges = try SyncChanges.restored(second, replacing: first, now: now)
            let version = imported.syncChanges?[key]?.version
            try check(version?.contains(first.syncChanges![key]!.version!) == true
                      && version?.contains(second.syncChanges![key]!.version!) == true,
                      "restoring equivalent deletions retains both causal histories despite opposite clocks")
            try check(try SyncChanges.restored(first, replacing: second, now: now) == imported.syncChanges,
                      "equivalent deletion restoration does not depend on which backup arrived first")
            try check(try SyncChanges.restored(second, replacing: imported, now: now) == imported.syncChanges,
                      "restoring the same deletion again never grows its version")
            try check(try converges(base, imported, nil).tasks.isEmpty,
                      "restored deletion history still suppresses only its known older live value")
        }
        do {
            let valid = SyncVersion.next(after: nil, actor: a)
            let hash = try SyncChanges.fingerprint("Validated")
            let key = SyncChanges.key("task", UUID())
            var malformed: [SyncVersion] = []
            var value = valid; value.clock = ["not-a-device": 1]; malformed.append(value)
            value = valid; value.clock[a.uuidString] = 0; malformed.append(value)
            value = valid; value.clock[a.uuidString] = 9_007_199_254_740_992; malformed.append(value)
            value = valid; value.winner.actor = b.uuidString; malformed.append(value)
            value = valid; value.winner.counter = 2; malformed.append(value)
            value = valid; value.clock = Dictionary(uniqueKeysWithValues: (0..<2049).map { _ in (UUID().uuidString, UInt64(1)) }); malformed.append(value)
            for candidate in malformed {
                for field in [false, true] {
                    var revision = SyncChanges.Revision(date: now, fingerprint: hash, version: field ? valid : candidate)
                    if field { revision.fields = ["title": .init(date: now, fingerprint: hash, version: candidate)] }
                    var rejected = false
                    do { try SyncChanges.validate([key: revision]) } catch { rejected = true }
                    try check(rejected, "malformed record and field causal versions are rejected at the persistence boundary")
                }
            }
            let maximum: UInt64 = 9_007_199_254_740_991
            let exhausted = SyncVersion(clock: [a.uuidString: maximum], winner: .init(actor: a.uuidString, counter: maximum))
            let advanced = SyncVersion.next(after: exhausted, actor: a)
            try check(advanced.isValid && advanced.dominates(exhausted) && advanced.winner.counter > 0,
                      "counter exhaustion keeps prior history and never wraps to zero")
            let encoded = try JSONEncoder().encode(advanced)
            try check(try JSONDecoder().decode(SyncVersion.self, from: encoded) == advanced,
                      "large valid counters survive an exact serialization round trip")
        }
        // The review session's reference time must remain fixed across a delayed user confirmation.
        var original = TaskBackup.TaskRecord(TaskItem(title: "Legacy original")); original.createdAt = now
        let legacyBase = try edited(TaskBackup(lists: [], tasks: [original]), actor: nil, date: now.addingTimeInterval(-100))
        var legacyLeft = legacyBase, legacyRight = legacyBase
        legacyLeft.tasks[0].title = "Local answer"; legacyRight.tasks[0].title = "Future answer"
        legacyLeft = try edited(legacyLeft, from: legacyBase, actor: nil, date: now)
        legacyRight = try edited(legacyRight, from: legacyBase, actor: nil, date: now.addingTimeInterval(360))
        let key = SyncChanges.key("task", original.id)
        try requiresReview("an out-of-range legacy clock initially requires review") {
            _ = try CloudMerge.merge(local: legacyLeft, cloud: legacyRight, base: legacyBase, now: now)
        }
        try check(try CloudMerge.merge(local: legacyLeft, cloud: legacyRight, base: legacyBase, choices: [key: .local], now: now).tasks[0].title == "Local answer",
                  "fixed evaluation time honors the decision displayed in the review session")
        print("CAUSAL SYNC PASS: \(count) checks")
        return count
    }
}
