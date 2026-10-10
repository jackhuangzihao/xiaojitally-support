import Foundation

/// One synced business row as stored in CloudKit, keyed by its sync key (`task:<id>`, `entry:<id>`, `rate:<id>`…).
/// A nil payload is a deletion: the record stays as a tombstone so an offline device cannot bring the row back.
struct CloudItem: Codable, Equatable, Sendable {
    var payload: Data?
    var revision: Data?
}

/// The marker written after every item of an upload round. Readers merge only rounds that finished.
struct CloudHead: Codable, Equatable, Sendable {
    var round: Int64
    var format: Int
}

/// Converts snapshots to per-row cloud items and back. Pure and deterministic, so both directions are testable.
enum CloudRecordCodec {
    /// Rows use the same encoding as snapshots (sorted keys, millisecond dates), so equal rows produce equal bytes.
    static let format = 13

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    /// Every row and every known revision (including tombstones) of a snapshot.
    static func items(_ snapshot: TaskBackup) throws -> [String: CloudItem] {
        let encoder = encoder
        var payloads: [String: Data] = [:]
        func add<T: Encodable>(_ rows: [T], kind: String, id: (T) -> UUID) throws {
            for row in rows { payloads[SyncChanges.key(kind, id(row))] = try encoder.encode(row) }
        }
        try add(snapshot.lists, kind: "list", id: \.id)
        try add(snapshot.tasks, kind: "task", id: \.id)
        try add(snapshot.weekTitles ?? [], kind: "week", id: \.id)
        if let finance = snapshot.finance {
            try add(finance.accounts, kind: "account", id: \.id)
            try add(finance.books, kind: "book", id: \.id)
            try add(finance.categories, kind: "category", id: \.id)
            try add(finance.entries, kind: "entry", id: \.id)
            try add(finance.recurringBills, kind: "recurring", id: \.id)
            // The base currency record also marks that a ledger exists, even an empty one.
            payloads[SyncChanges.currencyKey] = try encoder.encode(finance.baseCurrency)
            for (pair, rates) in Dictionary(grouping: finance.rates, by: { [$0.base, $0.quote].sorted().joined(separator: "/") }) {
                payloads[SyncChanges.rateKey(pair)] = try encoder.encode(rates.sorted { $0.base < $1.base })
            }
        }
        var items: [String: CloudItem] = [:]
        for (key, payload) in payloads { items[key] = CloudItem(payload: payload) }
        for (key, revision) in snapshot.syncChanges ?? [:] {
            items[key, default: CloudItem()].revision = try encoder.encode(revision)
        }
        return items
    }

    /// Rebuilds and validates a snapshot. Throws if the rows do not form a consistent whole.
    static func snapshot(_ items: [String: CloudItem]) throws -> TaskBackup {
        let decoder = decoder
        var lists: [TaskBackup.ListRecord] = [], tasks: [TaskBackup.TaskRecord] = [], weeks: [TaskBackup.WeekTitleRecord] = []
        var finance = FinanceData(), hasFinance = false
        var revisions: SyncChanges.Revisions = [:]
        for (key, item) in items {
            if let revision = item.revision { revisions[key] = try decoder.decode(SyncChanges.Revision.self, from: revision) }
            guard let payload = item.payload else { continue }
            switch key.prefix(while: { $0 != ":" }) {
            case "list": lists.append(try decoder.decode(TaskBackup.ListRecord.self, from: payload))
            case "task": tasks.append(try decoder.decode(TaskBackup.TaskRecord.self, from: payload))
            case "week": weeks.append(try decoder.decode(TaskBackup.WeekTitleRecord.self, from: payload))
            case "account": finance.accounts.append(try decoder.decode(MoneyAccount.self, from: payload))
            case "book": finance.books.append(try decoder.decode(MoneyBook.self, from: payload))
            case "category": finance.categories.append(try decoder.decode(MoneyCategory.self, from: payload))
            case "entry": finance.entries.append(try decoder.decode(MoneyEntry.self, from: payload))
            case "recurring": finance.recurring = (finance.recurring ?? []) + [try decoder.decode(MoneyRecurring.self, from: payload)]
            case "rate": finance.rates += try decoder.decode([MoneyRate].self, from: payload)
            case "setting" where key == SyncChanges.currencyKey:
                finance.baseCurrency = try decoder.decode(String.self, from: payload); hasFinance = true
            default: throw TaskBackup.invalid(L("云端含无法识别的记录。请更新小记。", "The cloud contains an unrecognized record. Update Tally.") + " " + key)
            }
            // The row must sit under its own key; a mismatch means a corrupted or foreign record.
            guard try expectedKey(kind: String(key.prefix { $0 != ":" }), payload: payload, decoder: decoder).map({ $0 == key }) ?? true else {
                throw TaskBackup.invalid(L("云端记录编号不一致。", "A cloud record has a mismatched identifier.") + " " + key)
            }
        }
        let hasFinanceRows = !(finance.accounts.isEmpty && finance.books.isEmpty && finance.categories.isEmpty && finance.entries.isEmpty
                               && finance.rates.isEmpty && finance.recurringBills.isEmpty)
        guard hasFinance || !hasFinanceRows else {
            throw TaskBackup.invalid(L("云端账目缺少本位币记录。", "The cloud ledger is missing its base currency."))
        }
        var snapshot = TaskBackup(finance: hasFinance ? finance : nil, weekTitles: weeks.sorted { $0.week < $1.week },
                                  syncChanges: revisions.isEmpty ? nil : revisions,
                                  lists: lists.sorted { $0.id.uuidString < $1.id.uuidString },
                                  tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString })
        snapshot.createdAt = Date(timeIntervalSince1970: 0)
        if snapshot.finance != nil {
            snapshot.finance!.accounts.sort { $0.id.uuidString < $1.id.uuidString }
            snapshot.finance!.books.sort { $0.id.uuidString < $1.id.uuidString }
            snapshot.finance!.categories.sort { $0.id.uuidString < $1.id.uuidString }
            snapshot.finance!.entries.sort { $0.id.uuidString < $1.id.uuidString }
            snapshot.finance!.rates.sort { $0.base + $0.quote < $1.base + $1.quote }
            snapshot.finance!.recurring = snapshot.finance!.recurring?.sorted { $0.id.uuidString < $1.id.uuidString }
            snapshot.finance!.migrateLegacyRecurring()
        }
        try snapshot.validate()
        return snapshot
    }

    /// The items to write so the cloud matches `target`: new or changed rows, and tombstones for removed ones.
    static func changes(from cloud: [String: CloudItem], to target: [String: CloudItem]) -> [String: CloudItem] {
        var result: [String: CloudItem] = [:]
        for (key, item) in target where cloud[key] != item { result[key] = item }
        for (key, item) in cloud where target[key] == nil && item != CloudItem() { result[key] = CloudItem() }
        return result
    }

    private static func expectedKey(kind: String, payload: Data, decoder: JSONDecoder) throws -> String? {
        struct Identified: Decodable { let id: UUID }
        switch kind {
        case "list", "task", "account", "book", "category", "entry", "recurring":
            return SyncChanges.key(kind, try decoder.decode(Identified.self, from: payload).id)
        case "week": return SyncChanges.key("week", try decoder.decode(TaskBackup.WeekTitleRecord.self, from: payload).id)
        case "rate":
            let pairs = Set(try decoder.decode([MoneyRate].self, from: payload).map { [$0.base, $0.quote].sorted().joined(separator: "/") })
            guard pairs.count == 1, let pair = pairs.first else { return "" } // Empty or mixed pairs never match a key.
            return SyncChanges.rateKey(pair)
        default: return nil // The base currency record is matched by its key in `snapshot`.
        }
    }
}
