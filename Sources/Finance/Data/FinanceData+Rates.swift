import Foundation

extension FinanceData {
    func converted(_ amount: Decimal, from: String, to: String) -> Decimal? {
        if from == to { return amount }
        guard let rate = assetRate(from: from, to: to) else { return nil }
        return Money.round(amount * rate.rate, currency: to)
    }
    /// Use either stored direction; an explicit manual quote takes priority over a cached reference.
    func storedRate(from: String, to: String) -> MoneyRate? {
        let matches = rates.filter { ($0.base == from && $0.quote == to || $0.base == to && $0.quote == from) && MoneyRate.valid($0.rate) }
        guard var selected = matches.sorted(by: {
            if $0.isManual != $1.isManual { return $0.isManual }
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.fetchedAt != $1.fetchedAt { return $0.fetchedAt > $1.fetchedAt }
            return $0.base == from && $1.base != from
        }).first else { return nil }
        if selected.base != from { selected.base = from; selected.quote = to; selected.rate = 1 / selected.rate }
        return selected
    }
    /// Only current assets use crossed quotes. Historical posting/statistics never infer a new rate here.
    func assetRate(from: String, to: String) -> MoneyAssetRate? {
        guard from != to else { return MoneyAssetRate(rate: 1, quotes: []) }
        let direct = storedRate(from: from, to: to).flatMap { MoneyRate.valid($0.rate) ? $0 : nil }
        if let direct, direct.isManual { return MoneyAssetRate(rate: direct.rate, quotes: [direct]) }
        // Existing installations store CNY quotes; the ledger currency is the only additional bridge.
        for bridge in ["CNY", baseCurrency] where bridge != from && bridge != to {
            guard let first = storedRate(from: from, to: bridge), let second = storedRate(from: bridge, to: to) else { continue }
            let rate = first.rate * second.rate
            guard MoneyRate.valid(rate) else { continue }
            if direct == nil || first.isManual || second.isManual {
                return MoneyAssetRate(rate: rate, quotes: [first, second])
            }
        }
        return direct.map { MoneyAssetRate(rate: $0.rate, quotes: [$0]) }
    }
    func assetSummary(in currency: String = "CNY", accountBalances: [UUID: Decimal]? = nil, accounts selectedAccounts: [MoneyAccount]? = nil) -> MoneyAssetSummary {
        var result = MoneyAssetSummary()
        let balances = accountBalances ?? self.accountBalances()
        for account in selectedAccounts ?? accounts { result.balances[account.currency, default: 0] += balances[account.id, default: 0] }
        for (original, amount) in result.balances {
            if original == currency { result.convertedSubtotal += amount; continue }
            if amount == 0 { continue }
            guard let quote = assetRate(from: original, to: currency) else { result.missingCurrencies.append(original); continue }
            // Round the total once, not each account; tiny foreign balances must not disappear.
            result.convertedSubtotal += amount * quote.rate
            if quote.isManual { result.manualCurrencies.append(original) }
            result.rateDates.append(contentsOf: quote.referenceDates)
        }
        result.convertedSubtotal = Money.round(result.convertedSubtotal, currency: currency)
        result.missingCurrencies.sort(); result.rateDates = Set(result.rateDates).sorted(); result.manualCurrencies.sort()
        return result
    }
    mutating func setManualRate(from: String, to: String, text: String, at date: Date = Date()) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Money.currencies.contains(from), Money.currencies.contains(to), from != to,
              cleaned.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let rate = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), MoneyRate.valid(rate),
              date.timeIntervalSince1970.isFinite else {
            throw TaskBackup.invalid(L("请输入大于等于 0.000000001 且小于 1000000000 的有效汇率。", "Enter a valid rate from 0.000000001 up to, but not including, 1000000000."))
        }
        rates.removeAll { $0.base == from && $0.quote == to || $0.base == to && $0.quote == from }
        rates.append(MoneyRate(base: from, quote: to, rate: rate, date: ExchangeRates.dayString(date), fetchedAt: MoneyEntry.timestamp(date), source: "Manual"))
    }
    mutating func removeManualRate(from: String, to: String) {
        rates.removeAll { $0.isManual && ($0.base == from && $0.quote == to || $0.base == to && $0.quote == from) }
    }
    mutating func updateAssetRates(to currency: String, values: [String: String], clearingManual: Set<String>, expected: FinanceData) throws {
        let changed = Set(values.keys).union(clearingManual).sorted()
        // Validate the whole snapshot before any write changes a dependent cross rate.
        for source in changed {
            guard assetRate(from: source, to: currency) == expected.assetRate(from: source, to: currency) else {
                throw TaskBackup.invalid(L("汇率已更新，请重新打开后修改。", "Rates have changed. Reopen this editor before changing them."))
            }
        }
        var next = self
        let now = Date()
        for source in changed {
            if clearingManual.contains(source) { next.removeManualRate(from: source, to: currency) }
            else { try next.setManualRate(from: source, to: currency, text: values[source, default: ""], at: now) }
        }
        rates = next.rates
    }
    /// Posting estimates use dated reference quotes only; manual quotes belong to asset valuation.
    func cachedReferenceRates(from base: String, quotes: [String], onOrBefore day: String, including pending: [MoneyRate] = []) -> [MoneyRate] {
        var selected: [String: MoneyRate] = [:]
        for rate in pending + rates where rate.isValidReference && rate.base == base && quotes.contains(rate.quote) && rate.date <= day {
            if let old = selected[rate.quote], old.date > rate.date || old.date == rate.date && old.fetchedAt >= rate.fetchedAt { continue }
            selected[rate.quote] = rate
        }
        return selected.values.sorted { $0.quote < $1.quote }
    }
    mutating func mergeReferenceRates(_ incoming: [MoneyRate], replaceManual: Bool = false) throws {
        var updated = self
        for rate in incoming {
            guard rate.isValidReference else {
                throw TaskBackup.invalid(L("汇率数据无效。", "Invalid exchange rate data."))
            }
            if updated.storedRate(from: rate.base, to: rate.quote)?.isManual == true {
                guard replaceManual else { continue }
                updated.removeManualRate(from: rate.base, to: rate.quote)
            }
            if updated.rates.contains(where: { $0.base == rate.base && $0.quote == rate.quote && $0.date > rate.date }) { continue }
            updated.rates.removeAll { $0.base == rate.base && $0.quote == rate.quote }
            updated.rates.append(rate)
        }
        rates = updated.rates
    }
    var missingConversionEntries: [MoneyEntry] {
        entries.filter { entry in
            guard entry.deletedAt == nil && !entry.isPending else { return false }
            switch entry.kind {
            case .income, .expense, .refund: return entry.baseAmount == nil
            case .transfer: return entry.fee > 0 && entry.baseFee == nil
            case .adjustment: return false
            }
        }
    }
    /// Preview only missing postings. Asset quotes never stand in for a historical transaction quote.
    func missingConversionPreview(history: RateHistory?, now: Date = Date()) -> MoneyConversionPreview {
        let today = ExchangeRates.dayString(now), days = history?.sortedDays
        let coveredThrough = history.map { min(today, ExchangeRates.dayString($0.fetchedAt)) }
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [MoneyConversionChange] = [], unavailable: [MoneyEntry] = [], future: [MoneyEntry] = []
        var currencies: [UUID: String] = [:]
        for entry in missingConversionEntries {
            let day = ExchangeRates.dayString(entry.date)
            guard day <= today else { future.append(entry); continue }
            let account = entry.accountID.flatMap { accountsByID[$0] }
            let currency = account?.currency ?? entry.currency
            let amount = entry.kind == .transfer ? entry.fee : (account == nil ? entry.amount : entry.accountAmount)
            let rate: MoneyRate?
            let converted: Decimal
            let note: String
            if currency == baseCurrency {
                rate = nil; converted = amount
                note = L("折算采用已记录的本币金额", "Conversion uses the recorded reporting-currency amount")
            } else if let history, let coveredThrough, day <= coveredThrough,
                      let quote = history.rate(from: currency, to: baseCurrency, on: day, sorted: days), MoneyRate.valid(quote.rate) {
                rate = MoneyRate(base: currency, quote: baseCurrency, rate: quote.rate, date: quote.day,
                                 fetchedAt: MoneyEntry.timestamp(history.fetchedAt), source: "ECB")
                converted = Money.round(amount * quote.rate, currency: baseCurrency)
                note = "ECB \(quote.day) · 1 \(currency) = \(Money.text(quote.rate)) \(baseCurrency)"
            } else { unavailable.append(entry); continue }
            var updated = entry
            if entry.kind == .transfer { updated.baseFee = converted } else { updated.baseAmount = converted }
            updated.rateNote = [entry.rateNote, note].filter { !$0.isEmpty }.joined(separator: "\n")
            guard Money.valid(converted, currency: baseCurrency), updated.rateNote.count <= 500 else { unavailable.append(entry); continue }
            changes.append(MoneyConversionChange(original: entry, updated: updated, rate: rate))
            if let account { currencies[account.id] = account.currency }
        }
        return MoneyConversionPreview(baseCurrency: baseCurrency, changes: changes, unavailableEntries: unavailable,
                                      futureEntries: future, accountCurrencies: currencies)
    }
    /// Check the entire preview before committing; a concurrent edit must never be overwritten or partially saved.
    mutating func applyMissingConversions(_ preview: MoneyConversionPreview) throws {
        let indices = Dictionary(entries.indices.map { (entries[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        guard baseCurrency == preview.baseCurrency,
              preview.accountCurrencies.allSatisfy({ id, currency in accounts.contains { $0.id == id && $0.currency == currency } }),
              Set(preview.changes.map { $0.original.id }).count == preview.changes.count else {
            throw TaskBackup.invalid(L("账户或统计币种已变化，请重新预览折算。", "Accounts or reporting currency changed. Preview conversions again."))
        }
        var next = self
        for change in preview.changes {
            guard let index = indices[change.original.id], entries[index] == change.original else {
                throw TaskBackup.invalid(L("账单已修改或删除，请重新预览折算。", "An entry changed or was deleted. Preview conversions again."))
            }
            var allowed = change.original
            if allowed.kind == .transfer, allowed.fee > 0, allowed.baseFee == nil { allowed.baseFee = change.updated.baseFee }
            else if [.expense, .income, .refund].contains(allowed.kind), allowed.baseAmount == nil { allowed.baseAmount = change.updated.baseAmount }
            else { throw TaskBackup.invalid(L("账单已有折算金额，请重新预览。", "The entry already has a conversion. Preview again.")) }
            allowed.rateNote = change.updated.rateNote
            guard allowed == change.updated, allowed.deletedAt == nil, !allowed.isPending else { throw TaskBackup.invalid(L("折算预览无效，请重试。", "Invalid conversion preview. Please try again.")) }
            next.entries[index] = allowed
        }
        try next.validate()
        self = next
    }
}
