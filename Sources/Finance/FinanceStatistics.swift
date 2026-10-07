import Foundation

extension MoneyEntry {
    /// What this entry adds to spending (refunds negative, transfer fees included) or income, in its own money:
    /// the original currency, or the paying account's currency for a transfer fee.
    func originalStatistics(income: Bool, feeCurrency: String?) -> (amount: Decimal, currency: String)? {
        guard !isPending else { return nil }
        switch kind {
        case .income where income, .expense where !income: return (amount, currency)
        case .refund where !income: return (-amount, currency)
        case .transfer where !income && fee > 0: return (fee, feeCurrency ?? currency)
        default: return nil
        }
    }
}

struct MoneyStatisticsTotal {
    var total: Decimal = 0
    var missing = 0
    var convertedCount = 0
    var estimateDates: Set<String> = []
    var complete: Bool { missing == 0 && estimateDates.isEmpty }
    static func average(_ totals: [Self]) -> Decimal? {
        guard !totals.isEmpty, totals.allSatisfy(\.complete) else { return nil }
        return totals.reduce(Decimal.zero) { $0 + $1.total } / Decimal(totals.count)
    }
    func change(from previous: Self) -> Decimal? {
        guard complete, previous.complete, previous.total > 0 else { return nil }
        return (total - previous.total) / previous.total
    }
}

extension FinanceData {
    /// Carry the provenance alongside the value, so a cached estimate cannot masquerade as a historical quote.
    func statisticsValue(_ entry: MoneyEntry, income: Bool, in display: String, history: RateHistory?, days: [String]?) -> (amount: Decimal, estimateDate: String?)? {
        let feeCurrency = accounts.first { $0.id == entry.accountID }?.currency
        guard let original = entry.originalStatistics(income: income, feeCurrency: feeCurrency) else { return nil }
        if original.currency == display { return (original.amount, nil) }
        if feeCurrency == display, entry.kind == .expense || entry.kind == .income || entry.kind == .refund {
            return (entry.kind == .refund ? -entry.accountAmount : entry.accountAmount, nil)
        }
        guard let base = entry.statisticsAmount(income: income) else { return nil }
        if display == baseCurrency { return (base, nil) }
        let day = ExchangeRates.dayString(entry.date)
        if let history, let quote = history.rate(from: baseCurrency, to: display, on: day, sorted: days) {
            let estimate = day > ExchangeRates.dayString(history.fetchedAt)
            return (Money.round(base * quote.rate, currency: display), estimate ? quote.day : nil)
        }
        if let quote = storedRate(from: baseCurrency, to: display) {
            return (Money.round(base * quote.rate, currency: display), quote.date)
        }
        return nil
    }
    func statisticsAmount(_ entry: MoneyEntry, income: Bool, in display: String, history: RateHistory?, days: [String]?) -> Decimal? {
        statisticsValue(entry, income: income, in: display, history: history, days: days)?.amount
    }
    func statisticsTotal(_ entries: [MoneyEntry], income: Bool, in display: String, history: RateHistory?, days: [String]?) -> MoneyStatisticsTotal {
        var result = MoneyStatisticsTotal()
        for entry in entries where entry.deletedAt == nil && entry.originalStatistics(income: income, feeCurrency: nil) != nil {
            if let value = statisticsValue(entry, income: income, in: display, history: history, days: days) {
                result.total += value.amount
                result.convertedCount += 1
                if let date = value.estimateDate { result.estimateDates.insert(date) }
            } else { result.missing += 1 }
        }
        return result
    }
    func categoryMonthlyTotals(_ key: MoneyCategoryKey, income: Bool, endingAt anchor: Date, bookID: UUID?, in display: String, history: RateHistory?) -> [(start: Date, summary: MoneyStatisticsTotal)] {
        guard let endMonth = Dates.calendar.dateInterval(of: .month, for: anchor),
              let start = Dates.calendar.date(byAdding: .month, value: -5, to: endMonth.start) else { return [] }
        let selected = entries.filter {
            $0.deletedAt == nil && $0.date >= start && $0.date < endMonth.end
                && (bookID == nil || $0.bookID == bookID) && key.includes($0, income: income, data: self)
        }
        let grouped = Dictionary(grouping: selected) { Dates.calendar.dateInterval(of: .month, for: $0.date)!.start }
        let days = history?.sortedDays
        return (0..<6).compactMap { offset in
            guard let month = Dates.calendar.date(byAdding: .month, value: offset, to: start) else { return nil }
            return (month, statisticsTotal(grouped[month] ?? [], income: income, in: display, history: history, days: days))
        }
    }

}

// One contribution rule for category totals, the trend, and drill-down results.
enum MoneyCategoryKey: Hashable {
    case category(UUID?)
    case fees
    func includes(_ entry: MoneyEntry, income: Bool) -> Bool {
        guard !entry.isPending else { return false }
        switch self {
        case .fees: return !income && entry.kind == .transfer && entry.fee > 0
        case .category(let id):
            return entry.categoryID == id && (income ? entry.kind == .income : entry.kind == .expense || entry.kind == .refund)
        }
    }
    func includes(_ entry: MoneyEntry, income: Bool, data: FinanceData) -> Bool {
        guard !entry.isPending else { return false }
        if case .category(let id?) = self {
            return data.categoryMatches(entry.categoryID, filterID: id) && (income ? entry.kind == .income : entry.kind == .expense || entry.kind == .refund)
        }
        return includes(entry, income: income)
    }
}
struct MoneyCategoryTotal: Identifiable {
    var id: MoneyCategoryKey
    var total: Decimal
    var count: Int
    var missing = 0
    var estimateDates: Set<String> = []
    var summary: MoneyStatisticsTotal { MoneyStatisticsTotal(total: total, missing: missing, convertedCount: count, estimateDates: estimateDates) }
}
struct MoneyDrilldown {
    var range: DateInterval
    var key: MoneyCategoryKey
    var income: Bool
    var includeSubcategories = true
    func matches(_ entry: MoneyEntry) -> Bool {
        entry.deletedAt == nil && entry.date >= range.start && entry.date < range.end && key.includes(entry, income: income)
    }
    func matches(_ entry: MoneyEntry, data: FinanceData) -> Bool {
        entry.deletedAt == nil && entry.date >= range.start && entry.date < range.end
            && (includeSubcategories ? key.includes(entry, income: income, data: data) : key.includes(entry, income: income))
    }
}
extension MoneyEntry {
    func statisticsAmount(income: Bool) -> Decimal? {
        guard !isPending else { return nil }
        switch kind {
        case .income where income, .expense where !income: return baseAmount
        case .refund where !income: return baseAmount.map { -$0 }
        case .transfer where !income && fee > 0: return baseFee
        default: return nil
        }
    }
}
extension FinanceData {
    func byCategory(_ selected: [MoneyEntry], income: Bool) -> (rows: [MoneyCategoryTotal], missing: Int) {
        var sums: [MoneyCategoryKey: (total: Decimal, count: Int)] = [:], missing = 0
        for entry in selected where entry.deletedAt == nil {
            let key: MoneyCategoryKey = entry.kind == .transfer ? .fees : .category(rootCategoryID(entry.categoryID))
            guard key.includes(entry, income: income, data: self) else { continue }
            guard let amount = entry.statisticsAmount(income: income) else { missing += 1; continue }
            var row = sums[key] ?? (0, 0)
            row.total += amount; row.count += 1
            sums[key] = row
        }
        let rows = sums.map { MoneyCategoryTotal(id: $0.key, total: $0.value.total, count: $0.value.count) }
            .sorted { abs($0.total) > abs($1.total) }
        return (rows, missing)
    }
}

/// Actual account-currency movement, distinct from spending/income statistics.
extension MoneyEntry {
    static func newestFirst(_ a: Self, _ b: Self) -> Bool {
        a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
    }
    func matches(bookID: UUID?, accountID: UUID?) -> Bool {
        (bookID == nil || self.bookID == bookID) && (accountID == nil || self.accountID == accountID || destinationID == accountID)
    }
    func accountChange(for id: UUID) -> Decimal {
        guard !isPending else { return 0 }
        var change: Decimal = 0
        if accountID == id {
            switch kind {
            case .expense, .transfer: change -= accountAmount + fee
            case .income, .refund, .adjustment: change += accountAmount
            }
        }
        if kind == .transfer && destinationID == id { change += destinationAmount }
        return change
    }
}

enum MoneyDateRange: String, CaseIterable, Identifiable {
    case day, week, month, year, all, custom
    var id: String { rawValue }
    var component: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all, .custom: nil
        }
    }
    func interval(at anchor: Date, through end: Date, calendar: Calendar = Dates.calendar) -> DateInterval? {
        if let component { return calendar.dateInterval(of: component, for: anchor) }
        guard self == .custom else { return nil }
        let start = calendar.startOfDay(for: min(anchor, end))
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(anchor, end)))!
        return DateInterval(start: start, end: upper)
    }
}
