import Foundation
import SwiftData

@MainActor enum FinanceConversionChecks {
    static func referenceRates(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        let xml = Data("<Cube><Cube time='2026-09-25'><Cube currency='AUD' rate='1.6'/><Cube currency='CNY' rate='8'/></Cube><Cube time='2026-09-24'><Cube currency='AUD' rate='2'/><Cube currency='CNY' rate='8'/></Cube></Cube>".utf8)
        let reference = try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY", "EUR"], onOrBefore: "2026-09-27")
        try require(reference.first { $0.quote == "CNY" }?.rate == 5 && reference.first?.date == "2026-09-25", "weekend rates use most recent published day, cross rates exact")
        try require(try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY"], onOrBefore: "2026-09-24").first?.rate == 4, "historical conversion never uses a later rate")
        let today = Dates.calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15))!
        func day(_ offset: Int) -> Date { Dates.calendar.date(byAdding: .day, value: offset, to: today)! }
        let mixed = UnconvertedBreakdown(missingDates: [day(-2), day(0), day(50), day(20)], today: today)
        try require(mixed.future == 2 && mixed.actionable == 2 && mixed.firstFutureDate == day(20),
                    "a subtotal note separates future-dated amounts from ones that can be converted now")
        try require(UnconvertedBreakdown(missingDates: [day(0)], today: today).actionable == 1
                    && UnconvertedBreakdown(missingDates: [], today: today) == UnconvertedBreakdown(missingDates: [], today: today.addingTimeInterval(86400)),
                    "today's amounts can be converted now, and a complete total has no note")
        // The notes count exactly the entries the total left out, not every entry lacking a recorded conversion.
        let ledger = FinanceData.initial
        var foreign = MoneyEntry(); foreign.kind = .expense; foreign.amount = 10; foreign.date = day(30)
        foreign.currency = ledger.baseCurrency == "EUR" ? "JPY" : "EUR"
        var local = MoneyEntry(); local.kind = .expense; local.amount = 5; local.currency = ledger.baseCurrency; local.baseAmount = 5; local.date = day(-1)
        let subtotal = ledger.statisticsTotal([foreign, local], income: false, in: ledger.baseCurrency, history: nil, days: nil)
        try require(subtotal.missing == 1 && subtotal.missingDates == [day(30)] && subtotal.convertedCount == 1
                    && UnconvertedBreakdown(missingDates: subtotal.missingDates, today: today).future == 1,
                    "a total records which entries it left out, and a future one is classed as future")
        try rejects("missing historical rates are not fabricated") { _ = try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY"], onOrBefore: "2026-01-01") }
        try rejects("unsupported rate is not 1 to 1") { _ = try ExchangeRates.parse(xml, base: "AUD", quotes: ["USD"], onOrBefore: "2026-09-25") }
        do {
            let instant = ISO8601DateFormatter().date(from: "2026-10-01T00:30:00Z")!
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "2026-10-01", "rate day uses the local calendar date")
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-09-30", "cached rate formatter follows time zone changes across midnight")
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "2026-10-01", "returning to an earlier time zone cannot retain a stale rate day")
        }
    }

    static func budgetRates(require: (Bool, String) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            let bookID = ledger.books[0].id
            ledger.books[0].budget = 1000
            let otherBook = MoneyBook(name: "Unbudgeted"), archived = MoneyBook(name: "Past trip", archived: true, budget: 2000)
            ledger.books += [otherBook, archived]
            let usd = MoneyAccount(name: "USD", currency: "USD"), cny = MoneyAccount(name: "CNY")
            ledger.accounts = [usd, cny]
            var paid = MoneyEntry(); paid.title = "CNY purchase"; paid.bookID = bookID; paid.amount = 100; paid.baseAmount = 100
            var raw = paid; raw.id = UUID(); raw.title = "USD purchase"; raw.currency = "USD"; raw.amount = 10; raw.baseAmount = nil
            raw.accountID = usd.id; raw.accountAmount = 10
            var refund = raw; refund.id = UUID(); refund.kind = .refund; refund.refundOf = raw.id; refund.amount = 2; refund.accountAmount = 2
            var fee = raw; fee.id = UUID(); fee.kind = .transfer; fee.destinationID = cny.id; fee.destinationAmount = 70; fee.fee = 1; fee.baseFee = nil
            var income = raw; income.id = UUID(); income.kind = .income
            var outside = raw; outside.id = UUID(); outside.bookID = otherBook.id
            var deleted = raw; deleted.id = UUID(); deleted.deletedAt = Date()
            ledger.entries = [paid, raw, refund, fee, income, outside, deleted]
            try ledger.validate()
            let pending = ledger.budgetSpending(ledger.entries, for: nil)
            try require(pending.total == 100 && pending.missing == 3 && !pending.complete, "budget carries pending foreign purchases, refunds and fees without treating them as zero")
            try require(ledger.budgetSpending(ledger.entries, for: bookID).missing == 3, "single-book budget uses the same completeness rule")
            try require(ledger.budgetBooks(for: nil, in: ledger.entries).map(\.id) == [bookID] && ledger.budget(for: nil, in: ledger.entries) == 1000, "budget names and values exclude an unused archived book")
            var tripCost = paid; tripCost.id = UUID(); tripCost.bookID = archived.id
            let withTrip = ledger.entries + [tripCost]
            try require(ledger.budgetBooks(for: nil, in: withTrip).map(\.id) == [bookID, archived.id] && ledger.budget(for: nil, in: withTrip) == 3000, "a historical archived-book budget uses the same name and amount scope")
            try ledger.setManualRate(from: "USD", to: "CNY", text: "7")
            try require(ledger.budgetSpending(ledger.entries, for: nil).missing == 3, "today's asset rate never silently fills a historical budget conversion")
            ledger.entries[1].baseAmount = 70; ledger.entries[2].baseAmount = 14; ledger.entries[3].baseFee = 7
            let complete = ledger.budgetSpending(ledger.entries, for: nil)
            try require(complete.complete && complete.total == 163, "budget becomes complete using saved purchase, refund and fee conversions only")
            try require(ledger.entries[4].baseAmount == nil && ledger.entries[5].baseAmount == nil, "irrelevant income and unbudgeted conversions are not rewritten")
        }
    }

    static func refreshedEstimatesAndRefunds(require: (Bool, String) throws -> Void) throws {
        do {
            try require(Money.refreshedEstimate("500", previous: "500", replacement: "400") == "400", "fresh rate updates an untouched automatic amount")
            try require(Money.refreshedEstimate("480", previous: "500", replacement: "400") == nil, "fresh rate preserves manually changed amount")
            try require(Money.refreshedEstimate("500", previous: nil, replacement: "400") == nil, "opening historical entry does not rewrite recorded amount")
            try require(Money.refreshedEstimate("", previous: nil, replacement: "400") == "400", "empty conversion can be filled")
            try require(Money.refreshedEstimate("500", previous: "500", replacement: nil) == nil, "missing quote cannot erase prior value")
            try require(Money.refreshedEstimate("10", previous: "10", replacement: "8") == "8", "converted fee follows refreshed rate too")
            try require(Money.display(-123, "CNY", hidden: true) == "••••" && Money.display(100, "AUD", hidden: true) == "••••", "account picker display hides all currencies and debt")
            try require(Money.display(123, "CNY", hidden: false) == Money.format(123, "CNY"), "visible amounts retain normal formatting")
            var ledger = FinanceData.initial
            var purchase = MoneyEntry(); purchase.kind = .expense; purchase.title = "Purchase"; purchase.amount = 100
            purchase.baseAmount = 100; purchase.bookID = ledger.books[0].id
            var returned = purchase; returned.id = UUID(); returned.kind = .refund; returned.refundOf = purchase.id; returned.amount = 40; returned.baseAmount = 40
            ledger.entries = [purchase, returned]
            try ledger.validate()
            try require(ledger.remainingRefund(for: purchase.id) == 60, "partial refund exposes exact remaining amount")
            try require(ledger.remainingRefund(for: purchase.id, excluding: returned.id) == 100, "editing refund excludes itself from available amount")
            ledger.entries[1].amount = 100; ledger.entries[1].baseAmount = 100
            try require(ledger.remainingRefund(for: purchase.id) == 0, "fully refunded entry disables further refund")
            ledger.entries[1].deletedAt = Date()
            try require(ledger.remainingRefund(for: purchase.id) == 100, "deleting refund restores availability")
            ledger.entries[0].deletedAt = Date()
            try require(ledger.remainingRefund(for: purchase.id) == 0 && ledger.remainingRefund(for: UUID()) == 0, "deleted or missing purchase cannot start a refund")
        }
    }

    static func historicalStatistics(require: (Bool, String) throws -> Void) throws {
        // 0.2.8: statistics in any currency, each entry at the rate of its own day.
        do {
            let xml = Data(#"<Cube><Cube time="2026-09-25"><Cube currency="CNY" rate="8"/><Cube currency="AUD" rate="2"/></Cube><Cube time="2026-09-18"><Cube currency="CNY" rate="7"/><Cube currency="AUD" rate="1.75"/></Cube><Cube time="2026-09-10"><Cube currency="CNY" rate="6"/><Cube currency="AUD" rate="1.5"/></Cube></Cube>"#.utf8)
            let history = try RateHistory.parse(xml, since: "2026-09-20")
            try require(history.sortedDays == ["2026-09-18", "2026-09-25"], "daily history keeps the day before the requested start")
            try require(history.rate(from: "CNY", to: "AUD", on: "2026-09-27")?.rate == Decimal(string: "0.25") && history.rate(from: "CNY", to: "AUD", on: "2026-09-27")?.day == "2026-09-25", "weekend dates use the latest earlier publication")
            try require(history.rate(from: "AUD", to: "CNY", on: "2026-09-20")?.rate == 4 && history.rate(from: "CNY", to: "AUD", on: "2026-09-01") == nil, "rates never come from a later day")
            var ledger = FinanceData.initial
            let aud = MoneyAccount(name: "AUD", currency: "AUD", opening: 100)
            ledger.accounts = [aud]
            let day = ISO8601DateFormatter().date(from: "2026-09-21T04:00:00Z")!
            var meal = MoneyEntry(); meal.title = "Meal"; meal.date = day; meal.amount = 400; meal.baseAmount = 400; meal.bookID = ledger.books[0].id
            var lunch = meal; lunch.id = UUID(); lunch.currency = "AUD"; lunch.amount = 10; lunch.accountID = aud.id; lunch.accountAmount = 10; lunch.baseAmount = 45
            var raw = lunch; raw.id = UUID(); raw.baseAmount = nil
            let days = history.sortedDays
            try require(ledger.statisticsAmount(meal, income: false, in: "CNY", history: nil, days: nil) == 400, "base currency uses the recorded amount")
            try require(ledger.statisticsAmount(meal, income: false, in: "AUD", history: history, days: days) == 100, "base amounts convert at their own day's rate")
            try require(ledger.statisticsAmount(lunch, income: false, in: "AUD", history: history, days: days) == 10 && ledger.statisticsAmount(raw, income: false, in: "AUD", history: nil, days: nil) == 10, "money already in the display currency is used as spent")
            try require(ledger.statisticsAmount(raw, income: false, in: "CNY", history: history, days: days) == nil && ledger.statisticsAmount(meal, income: true, in: "CNY", history: nil, days: nil) == nil, "unconverted or other-direction entries are left out")
            try require(ledger.statisticsAmount(meal, income: false, in: "USD", history: history, days: days) == nil, "a currency without a rate is reported missing, never guessed")
            ledger.rates = [MoneyRate(base: "AUD", quote: "CNY", rate: 5, date: "2026-09-28")]
            try require(ledger.statisticsAmount(meal, income: false, in: "AUD", history: nil, days: nil) == 80, "offline estimate falls back to the latest stored rate, inverted if needed")
            var refund = meal; refund.id = UUID(); refund.kind = .refund; refund.amount = 40; refund.baseAmount = 40; refund.refundOf = meal.id
            try require(refund.originalStatistics(income: false, feeCurrency: nil)?.amount == -40 && ledger.statisticsAmount(refund, income: false, in: "AUD", history: history, days: days) == -10, "refunds reduce spending in every currency")
        }
    }

    static func partialRateCoverage(require: (Bool, String) throws -> Void) throws {
        // Partial/stale rate coverage is visible and never produces an authoritative period comparison.
        do {
            var ledger = FinanceData.initial
            let calendar = Calendar(identifier: .gregorian)
            let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12))!
            let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
            var e = MoneyEntry(); e.title = "CNY spending"; e.amount = 100; e.baseAmount = 100; e.date = january
            let history = RateHistory(days: ["2026-09-25": ["EUR": 1, "CNY": 8, "AUD": 2]], fetchedAt: september)
            ledger.rates = [MoneyRate(base: "CNY", quote: "AUD", rate: Decimal(string: "0.2")!, date: "2026-09-25")]
            let fallback = ledger.statisticsValue(e, income: false, in: "AUD", history: history, days: history.sortedDays)
            try require(fallback?.amount == 20 && fallback?.estimateDate == "2026-09-25", "Partial history marks fallback as an estimate with the actual quote date")
            ledger.rates = [MoneyRate(base: "AUD", quote: "CNY", rate: 5, date: "2026-09-24")]
            try require(ledger.statisticsValue(e, income: false, in: "AUD", history: nil, days: nil)?.estimateDate == "2026-09-24", "Inverse fallback also carries its quote date")
            e.date = september
            try require(ledger.statisticsValue(e, income: false, in: "AUD", history: history, days: history.sortedDays)?.estimateDate == nil, "A covered weekend correctly uses Friday's published quote")
            e.date = september.addingTimeInterval(10 * 86400)
            try require(ledger.statisticsValue(e, income: false, in: "AUD", history: history, days: history.sortedDays)?.estimateDate == "2026-09-25", "A cached history predating the entry is an estimate")
            var raw = e; raw.id = UUID(); raw.currency = "USD"; raw.baseAmount = nil
            let previous = ledger.statisticsTotal([e, raw], income: false, in: "CNY", history: nil, days: nil)
            var twice = e; twice.amount = 200; twice.baseAmount = 200
            let current = ledger.statisticsTotal([twice], income: false, in: "CNY", history: nil, days: nil)
            try require(previous.total == 100 && previous.missing == 1 && current.change(from: previous) == nil, "Missing previous-period amounts suppress the misleading 100% change")
            try require(previous.change(from: current) == nil, "Missing current-period amounts suppress comparison too")
            let exact = ledger.statisticsTotal([e], income: false, in: "CNY", history: nil, days: nil)
            try require(current.change(from: exact) == 1 && exact.change(from: current) == Decimal(string: "-0.5"), "Complete totals retain correct increases and decreases")
            let estimated = ledger.statisticsTotal([e], income: false, in: "AUD", history: history, days: history.sortedDays)
            try require(!estimated.complete && estimated.estimateDates == ["2026-09-25"] && estimated.change(from: estimated) == nil, "Estimated totals visibly retain quote dates and suppress comparisons")
            try require(current.change(from: MoneyStatisticsTotal()) == nil, "Zero previous total never divides by zero")
            raw.currency = "AUD"
            try require(ledger.statisticsValue(raw, income: false, in: "AUD", history: nil, days: nil)?.estimateDate == nil, "Original-currency amounts never need an estimated conversion")
        }
    }

    static func reportingCurrency(context: ModelContext, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Reporting-currency changes must not reinterpret posted amounts or saved budgets.
        do {
            var ledger = FinanceData.initial
            try ledger.changeBaseCurrency(to: "USD", expected: "CNY")
            try require(ledger.baseCurrency == "USD", "empty ledger permits reporting-currency change")
            try rejects("stale currency picker cannot overwrite a newer selection") { try ledger.changeBaseCurrency(to: "AUD", expected: "CNY") }
            let draft = MoneyBook(name: "Stale CNY budget", budget: 1000)
            try rejects("stale new budget cannot become a USD budget") { try ledger.updateBook(draft, expected: nil, baseCurrency: "CNY") }
            try require(!ledger.books.contains { $0.id == draft.id }, "rejected stale budget leaves books untouched")
            var entry = MoneyEntry(); entry.title = "Stale posting"; entry.amount = 10; entry.baseAmount = 10
            try rejects("stale entry cannot reinterpret its converted amount") { try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY") }
            try require(ledger.entries.isEmpty, "rejected stale posting leaves entries untouched")
            try ledger.updateBook(draft, expected: nil, baseCurrency: "USD")
            let budgetLedger = ledger
            try rejects("budget locks base currency even with no entries") { try ledger.changeBaseCurrency(to: "CNY", expected: "USD") }
            try require(ledger == budgetLedger && ledger.books.last?.budget == 1000, "blocked currency change preserves budget denomination")
            ledger.books[ledger.books.count - 1].archived = true
            try require(!ledger.canChangeBaseCurrency, "archived budgets retain their reporting currency")
            ledger.books[ledger.books.count - 1].budget = nil
            try ledger.changeBaseCurrency(to: "CNY", expected: "USD")
            try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY")
            ledger.entries[0].deletedAt = Date()
            try rejects("deleted entries still lock currency for safe restoration") { try ledger.changeBaseCurrency(to: "USD", expected: "CNY") }
            var source = FinanceData.initial
            source.accounts = [MoneyAccount(name: "USD", currency: "USD")]
            entry.accountID = source.accounts[0].id
            var updated = source; updated.accounts[0].currency = "AUD"
            try rejects("external account currency change cannot reinterpret a draft's actual amount") { try updated.requireEntryCurrencies(entry, from: source) }
            updated = source; updated.accounts[0].name = "Renamed"
            try updated.requireEntryCurrencies(entry, from: source)
            try require(updated.accounts[0].name == "Renamed", "unrelated account rename keeps draft amounts valid")
            let before = try FinanceStore.read(context)
            try rejects("shared update cannot bypass currency safety") { try FinanceStore.update(context) { $0.baseCurrency = "USD" } }
            try require(try FinanceStore.read(context) == before, "rejected currency switch never changes stored bytes")
        }
    }

    static func assetDisplayCurrency(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Changing the asset display currency values the same balances, never re-denominates history.
        do {
            var ledger = FinanceData.initial
            let cny = MoneyAccount(name: "Yuan", opening: 70)
            let usd = MoneyAccount(name: "Dollar", currency: "USD", opening: 10)
            let aud = MoneyAccount(name: "Australian dollar", currency: "AUD", opening: 20)
            ledger.accounts = [cny, usd, aud]
            ledger.rates = [MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-05"),
                            MoneyRate(base: "AUD", quote: "CNY", rate: Decimal(string: "4.9")!, date: "2026-10-06")]
            let original = ledger
            try require(ledger.assetSummary(in: "USD").total == 34, "USD net worth includes CNY, USD and crossed AUD balances")
            try require(ledger.assetSummary(in: "AUD").total == Decimal(string: "48.57"), "AUD net worth rounds only after aggregating all currencies")
            try require(ledger.assetRate(from: "USD", to: "AUD")?.referenceDates == ["2026-10-05", "2026-10-06"], "crossed asset quotes retain both reference dates")
            try require(ledger.assetSummary(in: "EUR").total == nil && ledger.assetSummary(in: "EUR").missingCurrencies == ["AUD", "CNY", "USD"], "unsupported display conversion stays incomplete rather than showing zero")
            try require(ledger == original, "display conversions never mutate account balances, rates or posted entries")
            ledger.rates.append(MoneyRate(base: "USD", quote: "AUD", rate: Decimal(string: "1.4")!, date: "2026-10-06"))
            try require(ledger.assetRate(from: "USD", to: "AUD")?.rate == Decimal(string: "1.4") && ledger.assetRate(from: "USD", to: "AUD")?.referenceDates == ["2026-10-06"], "direct reference wins over an older crossed reference")
            try ledger.setManualRate(from: "USD", to: "CNY", text: "7.7")
            let crossed = ledger.assetRate(from: "USD", to: "AUD")
            try require(crossed?.isManual == true && ledger.converted(10, from: "USD", to: "AUD") == Decimal(string: "15.71"), "manual valuation remains effective after changing asset display currency")
            try require(crossed?.referenceDates == ["2026-10-06"], "mixed manual and reference quotes retain reference provenance")
            try ledger.setManualRate(from: "USD", to: "AUD", text: "2")
            try require(ledger.converted(10, from: "USD", to: "AUD") == 20, "explicit manual pair takes precedence over a crossed quote")
            try require(ledger.storedRate(from: "AUD", to: "CNY")?.rate == Decimal(string: "4.9"), "manual display override does not rewrite other stored pairs")
            ledger.removeManualRate(from: "USD", to: "AUD")
            try require(ledger.storedRate(from: "USD", to: "AUD") == nil
                        && ledger.storedRate(from: "USD", to: "CNY")?.isManual == true
                        && ledger.assetRate(from: "USD", to: "AUD")?.isManual == true
                        && ledger.converted(10, from: "USD", to: "AUD") == Decimal(string: "15.71"),
                        "clearing one manual pair preserves other manual quotes and labels their crossed estimate")
            let unused = MoneyAccount(name: "Unused")
            ledger.accounts.append(unused)
            try require(!ledger.accountHasHistory(unused.id), "new account currency remains editable")
            var transfer = MoneyEntry(); transfer.kind = .transfer; transfer.accountID = cny.id; transfer.destinationID = unused.id; transfer.deletedAt = Date()
            ledger.entries = [transfer]
            try require(ledger.accountHasHistory(unused.id), "incoming transfer in trash protects the account denomination")
            var changed = unused; changed.currency = "USD"
            try rejects("currency editing cannot bypass archived incoming history") { try ledger.updateAccount(changed, expected: unused) }
        }
    }

    static func assetRateEdits(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        var ledger = FinanceData.initial
        ledger.rates = [MoneyRate(base: "CNY", quote: "AUD", rate: Decimal(string: "0.2")!, date: "2026-10-08"),
                        MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-08")]
        let opened = ledger
        try require(ledger.assetRate(from: "USD", to: "AUD")?.rate == Decimal(string: "1.4"), "rate editor starts with a crossed USD quote")
        try ledger.updateAssetRates(to: "AUD", values: ["CNY": "0.25", "USD": "1.5"], clearingManual: [], expected: opened)
        try require(ledger.assetRate(from: "CNY", to: "AUD")?.rate == Decimal(string: "0.25")
                    && ledger.assetRate(from: "USD", to: "AUD")?.rate == Decimal(string: "1.5"),
                    "editing a bridge and its dependent quote together saves both requested rates")
        try require(ledger.storedRate(from: "USD", to: "CNY") == opened.storedRate(from: "USD", to: "CNY"), "rate batch preserves unrelated stored pairs")
        let saved = ledger
        try rejects("a genuinely stale batch cannot overwrite another editor's rates") {
            try ledger.updateAssetRates(to: "AUD", values: ["CNY": "0.3", "USD": "1.6"], clearingManual: [], expected: opened)
        }
        try require(ledger == saved, "stale rate batch leaves every quote unchanged")
        try rejects("an invalid later rate rejects the complete batch") {
            try ledger.updateAssetRates(to: "AUD", values: ["CNY": "0.3", "USD": "0"], clearingManual: [], expected: saved)
        }
        try require(ledger == saved, "invalid later rate cannot retain an earlier valid write")
        try ledger.updateAssetRates(to: "AUD", values: ["USD": "1.6"], clearingManual: ["CNY"], expected: saved)
        try require(ledger.storedRate(from: "CNY", to: "AUD") == nil
                    && ledger.assetRate(from: "USD", to: "AUD")?.rate == Decimal(string: "1.6"),
                    "clearing a bridge and editing its dependent quote uses the same pre-write snapshot")
        try ledger.validate()
    }

    static func netWorth(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Net worth aggregates each original currency before conversion, and never hides missing quotes.
        do {
            var ledger = FinanceData.initial
            let cash = MoneyAccount(name: "Cash", opening: 100), debt = MoneyAccount(name: "Closed card", opening: -10, archived: true)
            let won1 = MoneyAccount(name: "Won 1", currency: "KRW", opening: 1), won2 = MoneyAccount(name: "Won 2", currency: "KRW", opening: 1)
            let dollar = MoneyAccount(name: "USD", currency: "USD", opening: 10)
            ledger.accounts = [cash, debt, won1, won2, dollar]
            ledger.rates = [MoneyRate(base: "KRW", quote: "CNY", rate: Decimal(string: "0.004")!, date: "2026-09-30")]
            let missing = ledger.assetSummary()
            try require(missing.total == nil && missing.missingCurrencies == ["USD"] && missing.convertedSubtotal == Decimal(string: "90.01"), "partial total is marked incomplete; small accounts aggregate before rounding")
            try require(missing.balances["CNY"] == 90 && missing.balances["KRW"] == 2 && missing.balances["USD"] == 10, "original balances retain foreign amounts and archived debt")
            let at = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
            try ledger.setManualRate(from: "USD", to: "CNY", text: "7.2", at: at)
            try require(ledger.assetSummary().total == Decimal(string: "162.01") && ledger.assetSummary().manualCurrencies == ["USD"], "manual rate completes net worth with quote provenance")
            try require(ledger.assetSummary().rateDates == ["2026-09-30"], "reference dates never include manual quote dates")
            try require(ledger.converted(72, from: "CNY", to: "USD") == 10, "manual quote supports inverse conversion")
            let saved = ledger
            for invalid in ["0", "-1", "nan", "inf", "1e999", "1000000000", "0.0000000001", "7,2"] {
                try rejects("invalid manual rate \(invalid)") { try ledger.setManualRate(from: "USD", to: "CNY", text: invalid, at: at) }
            }
            try require(ledger == saved, "invalid manual rates never mutate saved data")
            let reference = MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-01")
            try ledger.mergeReferenceRates([reference])
            try require(ledger.assetSummary().total == Decimal(string: "162.01"), "automatic refresh does not replace manual rate")
            ledger.removeManualRate(from: "CNY", to: "USD"); try ledger.mergeReferenceRates([reference])
            try require(ledger.assetSummary().total == Decimal(string: "160.01") && ledger.assetSummary().manualCurrencies.isEmpty, "reset removes inverse manual override and restores reference rate")
            var transfer = MoneyEntry(); transfer.title = "Exchange"; transfer.kind = .transfer; transfer.bookID = ledger.books[0].id
            transfer.currency = "USD"; transfer.accountID = dollar.id; transfer.amount = 1; transfer.accountAmount = 1; transfer.fee = Decimal(string: "0.1")!; transfer.baseFee = Decimal(string: "0.7")!
            transfer.destinationID = cash.id; transfer.destinationAmount = 7; ledger.entries = [transfer]; try ledger.validate()
            let balances = ledger.accountBalances()
            try require(ledger.accounts.allSatisfy { balances[$0.id] == ledger.balance($0.id) }, "one-pass asset balances match per-account history including transfers")
            try require(ledger.assetSummary(accountBalances: balances).total == ledger.assetSummary().total, "shared balances preserve currency aggregation and rounding")
            let selected = [cash, dollar]
            var subset = ledger; subset.accounts = selected
            try require(ledger.assetSummary(accountBalances: balances, accounts: selected).total == subset.assetSummary().total, "group subtotal uses shared balances without excluding transfer counterparts")
            try require(ledger.assetSummary().total == Decimal(string: "159.31") && ledger.assetSummary().balances["USD"] == Decimal(string: "8.9"), "asset balances include both transfer sides and source fee exactly once")
            ledger.entries[0].deletedAt = at
            try require(ledger.assetSummary().total == Decimal(string: "160.01"), "deleted transfer is excluded from both asset sides")
            ledger.accounts = [MoneyAccount(name: "Zero dollars", currency: "USD")]; ledger.entries = []; ledger.rates = []
            try require(ledger.assetSummary().total == 0 && ledger.assetSummary().missingCurrencies.isEmpty, "zero foreign balances do not need a quote")
            try require(try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(saved)) == saved, "manual rates survive encode and decode")
            ledger.accounts = [dollar]
            var expense = MoneyEntry(); expense.title = "Euro purchase"; expense.kind = .expense; expense.currency = "EUR"; expense.amount = 10; expense.accountID = dollar.id; expense.accountAmount = 11; expense.baseAmount = 78; expense.bookID = ledger.books[0].id
            var refund = expense; refund.id = UUID(); refund.kind = .refund; refund.refundOf = expense.id; refund.amount = 2; refund.accountAmount = Decimal(string: "2.2")!; refund.baseAmount = Decimal(string: "15.6")!
            ledger.entries = [expense, refund]; try ledger.validate()
            let paid = ledger.statisticsTotal(ledger.entries, income: false, in: "USD", history: nil, days: nil)
            try require(paid.total == Decimal(string: "8.8") && paid.complete, "default account currency totals use actual charged amount and actual refund without estimated FX")
        }
    }

    static func historicalRateFill(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Partial reference feeds preserve usable currencies; historical fill is explicit, atomic and never reprices a posting.
        do {
            let xml = Data(#"<Cube><Cube time="2026-09-25"><Cube currency="USD" rate="2"/><Cube currency="CNY" rate="14"/></Cube></Cube>"#.utf8)
            let partial = try ExchangeRates.parseAvailable(xml, base: "CNY", quotes: ["BGN", "USD", "USD", "CNY"], onOrBefore: "2026-09-27")
            try require(partial.rates.count == 1 && partial.rates[0].quote == "USD" && partial.missingCurrencies == ["BGN"], "retired BGN cannot block USD in a partial asset refresh")
            let unavailable = try ExchangeRates.parseAvailable(xml, base: "BGN", quotes: ["USD", "CNY"], onOrBefore: "2026-09-27")
            try require(unavailable.rates.isEmpty && unavailable.missingCurrencies == ["CNY", "USD"], "missing base currency is returned as unavailable rather than guessed")
            try rejects("malformed reference feed still fails") { _ = try ExchangeRates.parseAvailable(Data("broken".utf8), base: "CNY", quotes: ["USD"], onOrBefore: "2026-09-27") }
            try rejects("entry editor retains strict all-requested conversion") { _ = try ExchangeRates.parse(xml, base: "CNY", quotes: ["USD", "BGN"], onOrBefore: "2026-09-27") }
            let calendar = Calendar(identifier: .gregorian)
            func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))! }
            let now = date(27)
            let history = RateHistory(days: ["2026-09-25": ["EUR": 1, "USD": 2, "CNY": 14], "2026-09-28": ["EUR": 1, "USD": 2, "CNY": 18]], fetchedAt: now)
            let narrow = RateHistory(days: ["2026-09-28": ["EUR": 1, "USD": 2, "CNY": 20]], fetchedAt: now.addingTimeInterval(60))
            let merged = history.merging(narrow)
            try require(merged.days["2026-09-25"] == history.days["2026-09-25"] && merged.days["2026-09-28"]?["CNY"] == 20, "short-range refresh keeps earlier rate coverage and replaces newer quotes")
            try require(merged.merging(history) == merged, "late stale history cannot replace newer quote or freshness")
            try require(history.merging(narrow) == narrow.merging(history), "concurrent history completion order has the same merged result")
            var lateCache = history
            lateCache.fetchedAt = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: date(26))!
            let afterMidnight = calendar.date(bySettingHour: 0, minute: 10, second: 0, of: now)!
            try require(lateCache.isFresh(since: "2026-09-26", at: lateCache.fetchedAt.addingTimeInterval(600)), "same-day history remains reusable within six hours")
            try require(!lateCache.isFresh(since: "2026-09-27", at: afterMidnight), "crossing midnight refreshes coverage so today's conversions are not blocked by yesterday's cache")
            try require(!history.isFresh(since: "2026-09-24", at: now), "cache must cover the earliest requested historical day")
            try require(!history.isFresh(since: "2026-09-26", at: now.addingTimeInterval(6 * 3600)), "same-day history expires at six hours")
            try require(!history.isFresh(since: "2026-09-26", at: now.addingTimeInterval(-1)), "a clock rollback cannot make a future-dated cache look fresh")
            var ledger = FinanceData.initial
            let usd = MoneyAccount(name: "USD", currency: "USD", opening: 500), cny = MoneyAccount(name: "CNY", opening: 100)
            ledger.accounts = [usd, cny]
            func entry(_ title: String, amount: Decimal = 10, kind: MoneyKind = .expense) -> MoneyEntry {
                var e = MoneyEntry(); e.title = title; e.date = date(26); e.currency = "USD"; e.amount = amount
                e.accountID = usd.id; e.accountAmount = amount; e.bookID = ledger.books[0].id; e.kind = kind
                return e
            }
            let coffee = entry("Coffee"), income = entry("Income", amount: 120, kind: .income)
            var bankConversion = entry("EUR charged in USD", amount: 10); bankConversion.currency = "EUR"; bankConversion.accountAmount = 12
            var transfer = entry("Transfer", amount: 5, kind: .transfer); transfer.destinationID = cny.id; transfer.destinationAmount = 35; transfer.fee = 2
            var refund = entry("Refund", amount: 2, kind: .refund); refund.refundOf = coffee.id; refund.date = coffee.date.addingTimeInterval(60)
            var locked = entry("Bank actual", amount: 10); locked.baseAmount = 69; locked.rateNote = "My actual charge"
            var future = entry("Future"); future.date = date(28)
            var retired = entry("Retired rate"); retired.currency = "BGN"; retired.accountID = nil; retired.accountAmount = 0
            var unassigned = entry("No account", amount: 3); unassigned.accountID = nil; unassigned.accountAmount = 0
            var deleted = coffee; deleted.id = UUID(); deleted.deletedAt = now
            var adjustment = entry("Adjustment", amount: 1, kind: .adjustment)
            adjustment.date = date(25)
            ledger.entries = [coffee, income, bankConversion, transfer, refund, locked, future, retired, unassigned, deleted, adjustment]
            try ledger.setManualRate(from: "USD", to: "CNY", text: "99", at: now)
            try ledger.validate()
            let original = ledger, preview = ledger.missingConversionPreview(history: history, now: now)
            try require(ledger == original && preview.changes.count == 6 && ledger.missingConversionEntries.count == 8, "conversion preview leaves the ledger unchanged and ignores locked, deleted and adjustment rows")
            try require(preview.futureEntries.map(\.id) == [future.id] && preview.unavailableEntries.map(\.id) == [retired.id], "future entries and missing reference currencies are explained separately")
            try require(preview.changes.first { $0.original.id == coffee.id }?.updated.baseAmount == 70 && preview.changes.first { $0.original.id == income.id }?.updated.baseAmount == 840, "USD coffee and income get their historical CNY amount")
            try require(preview.changes.first { $0.original.id == bankConversion.id }?.updated.baseAmount == 84, "conversion uses the account's actual charged currency and amount")
            try require(preview.changes.first { $0.original.id == transfer.id }?.updated.baseFee == 14 && preview.changes.first { $0.original.id == transfer.id }?.updated.baseAmount == nil, "transfer fill converts only the fee, never counts transferred principal")
            try require(preview.changes.first { $0.original.id == unassigned.id }?.updated.baseAmount == 21, "an unassigned entry uses its original currency")
            try require(preview.changes.allSatisfy { $0.rate?.date == "2026-09-25" && $0.updated.rateNote.contains("2026-09-25") }, "weekend fills record the prior published quote, ignoring current manual asset quotes")
            var oldCache = history; oldCache.fetchedAt = date(24)
            try require(ledger.missingConversionPreview(history: oldCache, now: now).changes.isEmpty && ledger.missingConversionPreview(history: nil, now: now).changes.isEmpty, "old or absent history never masquerades as a quote covering the entry date")
            let pending = ledger.statisticsTotal([income], income: true, in: "CNY", history: nil, days: nil)
            try require(pending.missing == 1 && pending.convertedCount == 0, "all-unconverted income can display pending instead of a misleading zero")
            let beforeBalance = ledger.balance(usd.id)
            try ledger.applyMissingConversions(preview)
            try require(ledger.balance(usd.id) == beforeBalance && ledger.rates == original.rates, "filling statistical amounts never changes account balances or manual asset rates")
            try require(ledger.entries.first { $0.id == locked.id } == locked, "existing bank amount and provenance remain untouched")
            let earned = ledger.statisticsTotal([ledger.entries[1]], income: true, in: "CNY", history: nil, days: nil)
            try require(earned.total == 840 && earned.missing == 0 && earned.convertedCount == 1, "converted income is immediately included in CNY statistics")
            try require(ledger.statisticsTotal([ledger.entries[0], ledger.entries[4]], income: false, in: "CNY", history: nil, days: nil).total == 56, "a filled refund reduces spending at its own saved conversion")
            try require(ledger.missingConversionPreview(history: history, now: now).changes.isEmpty, "completed conversions are not repriced by a later bulk fill")
            try require(try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(ledger)) == ledger, "completed conversions retain the unchanged backup format")
            var changed = original; changed.entries[1].title = "Edited elsewhere"
            let concurrent = changed
            try rejects("stale preview is rejected") { try changed.applyMissingConversions(preview) }
            try require(changed == concurrent && changed.entries[0].baseAmount == nil, "a late conflict cannot leave earlier conversions partially applied")
            changed = original; changed.entries[0].baseAmount = 71
            try rejects("manual conversion entered after preview is preserved") { try changed.applyMissingConversions(preview) }
            try require(changed.entries[0].baseAmount == 71, "stale fill does not replace a newly entered manual amount")
            changed = original; changed.accounts[0].currency = "AUD"
            try rejects("account currency change invalidates preview") { try changed.applyMissingConversions(preview) }
            changed = original; changed.baseCurrency = "AUD"
            try rejects("reporting currency change invalidates preview") { try changed.applyMissingConversions(preview) }
            changed = original; changed.entries[0].deletedAt = now
            try rejects("deleted entry invalidates preview") { try changed.applyMissingConversions(preview) }
            changed = original
            var unrelated = locked; unrelated.id = UUID(); unrelated.title = "Added elsewhere"
            changed.entries.append(unrelated); try changed.applyMissingConversions(preview)
            try require(changed.entries.last == unrelated && changed.entries.count == original.entries.count + 1, "unrelated concurrent additions survive batch commit")
            var direct = original; direct.entries = [coffee]; direct.entries[0].accountID = cny.id; direct.entries[0].accountAmount = 66
            let directPreview = direct.missingConversionPreview(history: nil, now: now)
            try require(directPreview.changes.first?.updated.baseAmount == 66 && directPreview.changes.first?.rate == nil, "recorded base-account amount needs no network or estimated rate")
            try direct.applyMissingConversions(directPreview)
            var refreshed = original
            try refreshed.mergeReferenceRates(partial.rates)
            try require(refreshed.storedRate(from: "USD", to: "CNY")?.rate == 99, "partial automatic refresh still respects a manual inverse quote")
        }
    }
}
