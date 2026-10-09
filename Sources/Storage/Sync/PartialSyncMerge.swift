import Foundation
import OSLog

private let partialSyncLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "PartialSync")

/// Keep disputed dependency groups on their original sides while unrelated records continue syncing.
/// The merge base deliberately retains the group's old values until a later review resolves it.
enum PartialSyncMerge {
    struct Result {
        let localSnapshot: TaskBackup
        let uploadSnapshot: TaskBackup
        let baselineSnapshot: TaskBackup
        let conflict: CloudMerge.Conflict?
        let automaticFieldCount: Int
    }

    static func prepare(local: TaskBackup, cloud: TaskBackup, base: TaskBackup?, cloudExists: Bool = true,
                        choices: [String: CloudMerge.Choice] = [:], now: Date = Date()) throws -> Result {
        do {
            let merged = try CloudMerge.mergeResult(local: local, cloud: cloud, base: base,
                cloudExists: cloudExists, choices: choices, now: now)
            return Result(localSnapshot: merged.snapshot, uploadSnapshot: merged.snapshot,
                          baselineSnapshot: merged.snapshot, conflict: nil, automaticFieldCount: merged.automaticFieldCount)
        } catch let conflict as CloudMerge.Conflict {
            // A failed validation after explicit choices is not a safely partitionable conflict.
            guard conflict.warning == nil else { throw conflict }
            do {
                let group = try DependencyGroup(local: local, cloud: cloud, base: base, conflict: conflict,
                                                 choices: choices)
                let safe = try CloudMerge.mergeResult(local: group.removing(from: local), cloud: group.removing(from: cloud),
                    base: try base.map(group.removing), cloudExists: cloudExists, choices: choices, now: now)
                let localResult = try group.restoring(from: local, into: safe.snapshot)
                let uploadResult = try group.restoring(from: cloud, into: safe.snapshot)
                let baselineResult = try group.restoring(from: base ?? TaskBackup(lists: [], tasks: []), into: safe.snapshot)
                partialSyncLog.notice("Prepared partial sync; held records: \(group.count, privacy: .public), review groups: \(conflict.items.count, privacy: .public)")
                return Result(localSnapshot: localResult, uploadSnapshot: uploadResult, baselineSnapshot: baselineResult,
                              conflict: conflict, automaticFieldCount: safe.automaticFieldCount)
            } catch {
                // Unknown conflict kinds and invalid dependency combinations must never publish a partial snapshot.
                partialSyncLog.notice("Partial sync retained original review because dependency validation failed")
                throw conflict
            }
        }
    }

    private struct DependencyGroup {
        private let blocked: Set<String>
        var count: Int { blocked.count }
        private static let ledger = "ledger"
        private static let financialKinds: Set<String> = ["account", "book", "category", "entry", "setting", "rate"]
        private static func financeKey(_ key: String) -> Bool {
            financialKinds.contains(String(key.prefix { $0 != ":" }))
        }
        private static func rateKey(_ rate: MoneyRate) -> String {
            "rate:" + [rate.base, rate.quote].sorted().joined(separator: "/")
        }

        init(local: TaskBackup, cloud: TaskBackup, base: TaskBackup?, conflict: CloudMerge.Conflict,
             choices: [String: CloudMerge.Choice]) throws {
            let snapshots = [local, cloud] + (base.map { [$0] } ?? [])
            let hashes = try snapshots.map(SyncChanges.fingerprints)
            let known = Set(hashes.flatMap { $0.keys }).union(snapshots.flatMap { ($0.syncChanges ?? [:]).keys })
            // A shared reference that is identical on all sides is safe to keep outside the held group.
            let varying = Set(known.filter { key in hashes.dropFirst().contains { $0[key] != hashes[0][key] } })
            var links: [String: Set<String>] = [:]
            func connect(_ left: String, _ right: String) {
                links[left, default: []].insert(right); links[right, default: []].insert(left)
            }
            func reference(_ source: String, _ kind: String, _ id: UUID?) {
                guard let id else { return }
                let target = SyncChanges.key(kind, id)
                if varying.contains(target) { connect(source, target) }
            }
            let currencies = snapshots.map { $0.finance?.baseCurrency }
            let ledgerChanges = currencies.dropFirst().contains { $0 != currencies[0] }
            for snapshot in snapshots {
                for row in snapshot.lists { reference(SyncChanges.key("list", row.id), "list", row.parentID) }
                for row in snapshot.tasks {
                    let key = SyncChanges.key("task", row.id)
                    reference(key, "list", row.listID)
                    if let successor = row.nextOccurrenceID { connect(key, SyncChanges.key("task", successor)) }
                }
                guard let finance = snapshot.finance else { continue }
                for rate in finance.rates {
                    let pair = [rate.base, rate.quote].sorted().joined(separator: "/")
                    connect(Self.rateKey(rate), SyncChanges.rateKey(pair))
                }
                for row in finance.books { reference(SyncChanges.key("book", row.id), "account", row.defaultAccountID) }
                for row in finance.categories { reference(SyncChanges.key("category", row.id), "category", row.parentID) }
                for row in finance.entries {
                    let key = SyncChanges.key("entry", row.id)
                    reference(key, "account", row.accountID); reference(key, "account", row.destinationID)
                    reference(key, "book", row.bookID); reference(key, "category", row.categoryID)
                    reference(key, "task", row.taskID)
                    // A refund limit depends on the complete family, including concurrent newly added refunds.
                    if let original = row.refundOf { connect(key, SyncChanges.key("entry", original)) }
                }
                if ledgerChanges {
                    for key in known where Self.financeKey(key) { connect(Self.ledger, key) }
                    for rate in finance.rates { connect(Self.ledger, Self.rateKey(rate)) }
                }
            }
            var pending: [String] = []
            for item in conflict.items where choices[item.id] == nil {
                let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
                guard let conflictKind = parts.first else { throw conflict }
                switch conflictKind {
                case "ledger", "ledger-currency", "base-currency":
                    pending.append(Self.ledger)
                    // A ledger-level conflict always holds the entire ledger, even if currencies match.
                    for key in known where Self.financeKey(key) { connect(Self.ledger, key) }
                    for rate in snapshots.flatMap({ $0.finance?.rates ?? [] }) { connect(Self.ledger, Self.rateKey(rate)) }
                case "rate":
                    guard parts.count == 2 else { throw conflict }
                    pending.append(item.id)
                case "task", "task-chain", "task-lifecycle", "list", "week", "account", "account-postings", "book", "category", "category-family", "entry":
                    guard parts.count == 2 else { throw conflict }
                    let ids = parts[1].split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                    guard !ids.isEmpty && ids.count == parts[1].split(separator: ",").count else { throw conflict }
                    let kind: String
                    switch conflictKind {
                    case "task-chain", "task-lifecycle": kind = "task"
                    case "account-postings": kind = "account"
                    case "category-family": kind = "category"
                    default: kind = conflictKind
                    }
                    pending += ids.map { SyncChanges.key(kind, $0) }
                default: throw conflict
                }
            }
            guard !pending.isEmpty else { throw conflict }
            var held = Set<String>()
            while let key = pending.popLast() {
                guard held.insert(key).inserted else { continue }
                pending.append(contentsOf: links[key] ?? [])
            }
            blocked = held
        }

        func removing(from source: TaskBackup) throws -> TaskBackup {
            var result = source
            result.lists.removeAll { blocked.contains(SyncChanges.key("list", $0.id)) }
            result.tasks.removeAll { blocked.contains(SyncChanges.key("task", $0.id)) }
            result.weekTitles?.removeAll { blocked.contains(SyncChanges.key("week", $0.id)) }
            if blocked.contains(Self.ledger) { result.finance = nil }
            else if result.finance != nil {
                result.finance!.accounts.removeAll { blocked.contains(SyncChanges.key("account", $0.id)) }
                result.finance!.books.removeAll { blocked.contains(SyncChanges.key("book", $0.id)) }
                result.finance!.categories.removeAll { blocked.contains(SyncChanges.key("category", $0.id)) }
                result.finance!.entries.removeAll { blocked.contains(SyncChanges.key("entry", $0.id)) }
                result.finance!.rates.removeAll { blocked.contains(Self.rateKey($0)) }
            }
            result.syncChanges = source.syncChanges?.filter { !blocked.contains($0.key) }
            try result.validate()
            return result
        }

        func restoring(from source: TaskBackup, into merged: TaskBackup) throws -> TaskBackup {
            var result = merged
            func rows<T>(_ merged: [T], _ original: [T], kind: String, id: (T) -> UUID) -> [T] {
                merged.filter { !blocked.contains(SyncChanges.key(kind, id($0))) } +
                    original.filter { blocked.contains(SyncChanges.key(kind, id($0))) }
            }
            result.lists = rows(merged.lists, source.lists, kind: "list", id: { $0.id })
            result.tasks = rows(merged.tasks, source.tasks, kind: "task", id: { $0.id })
            result.weekTitles = rows(merged.weekTitles ?? [], source.weekTitles ?? [], kind: "week", id: { $0.id })
            if blocked.contains(Self.ledger) { result.finance = source.finance }
            else if var finance = result.finance {
                finance.accounts = rows(finance.accounts, source.finance?.accounts ?? [], kind: "account", id: { $0.id })
                finance.books = rows(finance.books, source.finance?.books ?? [], kind: "book", id: { $0.id })
                finance.categories = rows(finance.categories, source.finance?.categories ?? [], kind: "category", id: { $0.id })
                finance.entries = rows(finance.entries, source.finance?.entries ?? [], kind: "entry", id: { $0.id })
                finance.rates = finance.rates.filter { !blocked.contains(Self.rateKey($0)) } +
                    (source.finance?.rates ?? []).filter { blocked.contains(Self.rateKey($0)) }
                result.finance = finance
            }
            var revisions = merged.syncChanges ?? [:]
            for key in blocked { revisions[key] = source.syncChanges?[key] }
            result.syncChanges = revisions.isEmpty ? nil : revisions
            try result.validate()
            return result
        }
    }
}
