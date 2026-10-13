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
            let version = SyncVersion.next(after: nil, actor: UUID(), now: date)
            var recordVersionOnly = revisions; recordVersionOnly[first]?.version = version
            try SyncChanges.stage(recordVersionOnly, in: context)
            try check(try state.changeHistory == encoder.encode(recordVersionOnly) && SyncChanges.read(context) == recordVersionOnly,
                      "record-version-only updates invalidate cached bytes without changing content hashes or dates")
            context.rollback()
            try check(try SyncChanges.read(context) == revisions, "rollback removes the staged record version from the cache")
            var fieldVersionOnly = revisions; fieldVersionOnly[first]?.fields?["title"]?.version = version
            try SyncChanges.stage(fieldVersionOnly, in: context)
            try check(try state.changeHistory == encoder.encode(fieldVersionOnly) && SyncChanges.read(context) == fieldVersionOnly,
                      "field-version-only updates invalidate cached bytes without changing content hashes or dates")
            context.rollback()
            try check(try SyncChanges.read(context) == revisions, "rollback removes the staged field version from the cache")
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
            invalid = revisions; invalid[first]?.version = SyncVersion(clock: [:], winner: version.winner)
            try rejects("a record-version-only edit cannot bypass validation in a warm cache") { try SyncChanges.stage(invalid, in: context) }
            var invalidFieldVersion = version; invalidFieldVersion.winner.stamp = version.winner.stamp.successor
            invalid = revisions; invalid[first]?.fields?["title"]?.version = invalidFieldVersion
            try rejects("a field-version-only edit cannot bypass validation in a warm cache") { try SyncChanges.stage(invalid, in: context) }
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

    /// Actual actor hops use disposable stores; preparation may never change a transaction or commit it.
    static func backgroundPreparation() async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("BACKGROUND HISTORY CHECK: " + label) }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-HistoryPreparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SyncChanges.cancelHistoryPreparation(); try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = try SyncChanges.fingerprint("Original"), editedHash = try SyncChanges.fingerprint("Edited")
        for round in 0..<3 {
            let store = try Store.make(url: root.appendingPathComponent("source-\(round).store")), context = store.mainContext
            let other = try Store.make(url: root.appendingPathComponent("other-\(round).store"))
            let date = Date(timeIntervalSince1970: 1_800_000_000.123 + Double(round))
            let revisions = Dictionary(uniqueKeysWithValues: (0..<2000).map { _ in
                (SyncChanges.key("task", UUID()), SyncChanges.Revision(date: date, fingerprint: hash,
                    fields: ["title": .init(date: date, fingerprint: hash), "notes": .init(date: nil, fingerprint: hash)]))
            })
            let key = revisions.keys.sorted().first!
            var edited = revisions; edited[key]?.fingerprint = editedHash
            edited[key]?.fields?["title"] = .init(date: date.addingTimeInterval(1), fingerprint: editedHash)
            edited[key]?.date = date.addingTimeInterval(1)
            try SyncChanges.stage(revisions, in: context); try Store.save(context, trackSyncChanges: false)
            let state = try context.fetch(FetchDescriptor<CloudSyncState>()).first!, committed = state.changeHistory
            func evict() throws {
                try SyncChanges.stage([SyncChanges.key("task", UUID()): .init(date: date, fingerprint: hash)], in: other.mainContext)
                try Store.save(other.mainContext, trackSyncChanges: false)
            }
            try evict()
            try check(try await SyncChanges.prepareHistory(in: context), "cold history prepares its record fragments")
            try check(try SyncChanges.read(context) == revisions && state.changeHistory == committed && !context.hasChanges,
                      "background preparation changes no stored data or pending transaction")
            try check(try await !SyncChanges.prepareHistory(in: context), "already prepared bytes need no second worker")

            try evict()
            let first = Task { @MainActor in try await SyncChanges.prepareHistory(in: context) }
            let second = Task { @MainActor in try await SyncChanges.prepareHistory(in: context) }
            let shared = try await [first.value, second.value]
            try check(shared.filter { $0 }.count == 1, "simultaneous callers share one preparation and installation")
            try check(try SyncChanges.read(context) == revisions, "shared preparation preserves all field provenance")

            try evict()
            let closingWindow = Task { @MainActor in try await SyncChanges.prepareHistory(in: context) }
            let remainingWindow = Task { @MainActor in try await SyncChanges.prepareHistory(in: context) }
            await Task.yield(); closingWindow.cancel()
            do { _ = try await closingWindow.value } catch is CancellationError { }
            _ = try await remainingWindow.value
            try check(try await !SyncChanges.prepareHistory(in: context), "closing one window leaves the other caller's prepared cache available")

            try evict()
            let preparing = Task { try await SyncChanges.prepareHistory(in: context) }
            await Task.yield()
            try SyncChanges.stage(edited, in: context)
            _ = try await preparing.value
            try check(try SyncChanges.read(context) == edited && state.changeHistory == encoder.encode(edited) && context.hasChanges,
                      "an edit racing preparation keeps its current unsaved metadata")
            context.rollback()
            try check(try SyncChanges.read(context) == revisions && state.changeHistory == committed,
                      "rollback after the racing edit restores only committed metadata")

            try evict()
            let rollingBack = Task { try await SyncChanges.prepareHistory(in: context) }
            await Task.yield()
            try SyncChanges.stage(edited, in: context); context.rollback()
            _ = try await rollingBack.value
            try check(try SyncChanges.read(context) == revisions && !context.hasChanges,
                      "preparation remains correct when staged changes are rolled back while it runs")

            try evict()
            let superseded = Task { try await SyncChanges.prepareHistory(in: context) }
            await Task.yield()
            _ = try await SyncChanges.prepareHistory(in: other.mainContext)
            do { _ = try await superseded.value } catch is CancellationError { }
            try check(try SyncChanges.read(context) == revisions, "switching contexts discards a superseded worker safely")

            try evict()
            let cancelled = Task { try await SyncChanges.prepareHistory(in: context) }; cancelled.cancel()
            var cancellationObserved = false
            do { _ = try await cancelled.value } catch is CancellationError { cancellationObserved = true }
            try check(cancellationObserved && state.changeHistory == committed && !context.hasChanges,
                      "cancelling a caller never stages or saves metadata")

            var invalid = revisions; invalid[key]?.fields?["title"]?.fingerprint = "invalid"
            for corrupted in [Data("{".utf8), try encoder.encode(invalid)] {
                state.changeHistory = corrupted
                var failed = false
                do { _ = try await SyncChanges.prepareHistory(in: context) } catch { failed = true }
                try check(failed && state.changeHistory == corrupted, "corrupt history fails preparation without rewriting it")
                context.rollback()
                try check(try SyncChanges.read(context) == revisions, "a failed worker cannot poison the committed cache")
            }
            let object = try JSONSerialization.jsonObject(with: committed!)
            state.changeHistory = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            let legacy = state.changeHistory
            try check(try await SyncChanges.prepareHistory(in: context), "legacy whitespace prepares without a migration")
            try check(state.changeHistory == legacy && context.hasChanges, "preparation leaves pre-existing unsaved data untouched")
            try SyncChanges.stage(edited, in: context)
            try check(try state.changeHistory == encoder.encode(edited), "prepared legacy fragments encode the next edit correctly")
            context.rollback()

            try evict()
            var saves = 0
            let returned = try await SyncChanges.withPreparedHistory(in: context) {
                saves += 1
                try SyncChanges.stage(edited, in: context)
                try Store.save(context, trackSyncChanges: false)
                return "committed"
            }
            try check(saves == 1 && returned == "committed" && !context.hasChanges && SyncChanges.read(context) == edited,
                      "a cold user save prepares off actor and commits once with the same history")

            try evict()
            let cancelledSave = Task { try await SyncChanges.withPreparedHistory(in: context) { saves += 1 } }
            cancelledSave.cancel()
            do { try await cancelledSave.value } catch is CancellationError { }
            try check(saves == 1 && SyncChanges.read(context) == edited, "cancelling a pending save never runs its commit")

            try evict()
            var beganSaving = false
            let dismissedSave = Task {
                beganSaving = true
                try await SyncChanges.withPreparedHistory(in: context) { saves += 1 }
            }
            while !beganSaving { await Task.yield() }
            dismissedSave.cancel()
            do { try await dismissedSave.value } catch is CancellationError { }
            try check(saves == 1 && SyncChanges.read(context) == edited,
                      "dismissal while cold preparation is running cannot commit later")

            try evict()
            let saving = Task {
                try await SyncChanges.withPreparedHistory(in: context) {
                    let latest = try SyncChanges.read(context)
                    try check(latest == revisions, "a concurrent change is rechecked before committing")
                    saves += 1
                }
            }
            await Task.yield()
            try SyncChanges.stage(revisions, in: context); try Store.save(context, trackSyncChanges: false)
            try await saving.value
            try check(saves == 2 && SyncChanges.read(context) == revisions, "a stale preparation cannot overwrite a newer transaction")

            try evict()
            var saveFailed = false
            do {
                try await SyncChanges.withPreparedHistory(in: context) { throw TaskBackup.invalid("Injected commit failure") }
            } catch { saveFailed = true }
            try check(saveFailed && !context.hasChanges && SyncChanges.read(context) == revisions,
                      "commit errors propagate without the preparation committing anything")

            state.changeHistory = Data("{".utf8)
            var corruptSaveFailed = false
            do { try await SyncChanges.withPreparedHistory(in: context) { saves += 1 } }
            catch { corruptSaveFailed = true }
            try check(corruptSaveFailed && saves == 2, "corrupt history blocks a prepared save before its first mutation")
            context.rollback()

            var ledger = FinanceData.initial
            var entry = ledger.newEntry(preferredBook: nil)
            entry.title = "Original"; entry.amount = 10; entry.baseAmount = 10; entry.bookID = ledger.books[0].id
            ledger.entries = [entry]
            try FinanceStore.stage(ledger, in: context); try Store.save(context)
            try evict()
            var beganEditing = false
            var proposed = entry; proposed.title = "Old editor"
            let staleEditor = Task {
                beganEditing = true
                try await SyncChanges.withPreparedHistory(in: context) {
                    try FinanceStore.put(proposed, expected: entry, baseCurrency: ledger.baseCurrency, in: context)
                }
            }
            while !beganEditing { await Task.yield() }
            try FinanceStore.update(context) { $0.entries[0].title = "Other window" }
            var staleRejected = false
            do { try await staleEditor.value } catch { staleRejected = true }
            try check(staleRejected && FinanceStore.read(context)?.entries[0].title == "Other window" && !context.hasChanges,
                      "a finance editor rechecks its original entry after waiting and preserves the other window's edit")

            try evict()
            var beganRecoverySave = false
            let oldEditor = Task {
                beganRecoverySave = true
                try await SyncChanges.withPreparedHistory(in: context) { saves += 1 }
            }
            while !beganRecoverySave { await Task.yield() }
            Store.recovery.failed(TaskBackup.invalid("Injected recovery while preparing"), in: context)
            try check(Store.recovery.reload(), "the isolated store reopens after the injected failure")
            var oldEditorRejected = false
            do { try await oldEditor.value } catch { oldEditorRejected = true }
            try check(oldEditorRejected && saves == 2, "recovery retires the waiting editor before it can commit")
            try await SyncChanges.withPreparedHistory(in: Store.recovery.container!.mainContext) { saves += 1 }
            try check(saves == 3, "the replacement context remains writable after recovery")
        }
        let empty = try Store.make(url: root.appendingPathComponent("empty.store"))
        try check(try await !SyncChanges.prepareHistory(in: empty.mainContext), "an empty store needs no preparation")
        try check(try empty.mainContext.fetch(FetchDescriptor<CloudSyncState>()).isEmpty && !empty.mainContext.hasChanges,
                  "preparation does not create a sync state in an empty store")
        print("BACKGROUND HISTORY PASS: \(count) checks")
        return count
    }
}
