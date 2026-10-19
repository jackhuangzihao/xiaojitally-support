import Foundation
import SwiftData

@MainActor enum FinanceStore {
    // One validated snapshot, shared by readers. Always compare the stored bytes:
    // another window, sync, restore or a rollback can replace the ledger at any time.
    private static var cached: (payload: Data, value: FinanceData)?

    static func payload(_ context: ModelContext) throws -> Data? {
        let records = try context.fetch(FetchDescriptor<FinanceLedger>())
        guard records.count <= 1 else { throw TaskBackup.invalid(L("发现多份记账数据，请从备份恢复。", "Multiple ledgers found. Restore a backup.")) }
        return records.first?.payload
    }
    static func read(_ context: ModelContext) throws -> FinanceData? {
        guard let bytes = try payload(context) else { return nil }
        return try decode(bytes)
    }
    static func decode(_ bytes: Data) throws -> FinanceData {
        if let cached, cached.payload == bytes { return cached.value }
        var value = try JSONDecoder().decode(FinanceData.self, from: bytes)
        value.migrateLegacyRecurring() // Saved with the next change; until then every read migrates the same way.
        try value.validate()
        cached = (bytes, value)
        return value
    }
    static func stage(_ value: FinanceData, in context: ModelContext, trackSyncChanges: Bool = true) throws {
        try value.validate()
        var normalized = value
        normalized.version = 4
        for i in normalized.entries.indices {
            let date = MoneyEntry.timestamp(normalized.entries[i].date)
            let deletedAt = normalized.entries[i].deletedAt.map(MoneyEntry.timestamp)
            // Avoid copying the full entries array when its timestamps are already normalized.
            if normalized.entries[i].date != date { normalized.entries[i].date = date }
            if normalized.entries[i].deletedAt != deletedAt { normalized.entries[i].deletedAt = deletedAt }
        }
        for i in normalized.rates.indices { normalized.rates[i].fetchedAt = MoneyEntry.timestamp(normalized.rates[i].fetchedAt) }
        if normalized.recurring?.isEmpty == true { normalized.recurring = nil }
        for i in normalized.recurring?.indices ?? 0..<0 {
            normalized.recurring![i].nextDate = MoneyEntry.timestamp(normalized.recurring![i].nextDate)
            normalized.recurring![i].until = normalized.recurring![i].until.map(MoneyEntry.timestamp)
        }
        if trackSyncChanges { try SyncChanges.trackFinance(from: read(context), to: normalized, in: context) }
        let data = try JSONEncoder().encode(normalized)
        let existing = try context.fetch(FetchDescriptor<FinanceLedger>())
        guard existing.count <= 1 else { throw TaskBackup.invalid("Multiple ledgers") }
        if let record = existing.first { record.payload = data } else { context.insert(FinanceLedger(payload: data)) }
        cached = (data, normalized)
    }
    static func update(_ context: ModelContext, _ change: (inout FinanceData) throws -> Void) throws {
        try Store.recovery.requireWritable(context)
        var value = try read(context) ?? .initial
        let original = value
        try change(&value)
        if original.baseCurrency != value.baseCurrency {
            var check = original
            try check.changeBaseCurrency(to: value.baseCurrency, expected: original.baseCurrency)
        }
        try stage(value, in: context); try Store.save(context)
    }
    static func put(_ entry: MoneyEntry, expected: MoneyEntry?, baseCurrency: String, in context: ModelContext) throws {
        try update(context) { try $0.updateEntry(entry, expected: expected, baseCurrency: baseCurrency) }
    }
}
