import Foundation
import SwiftData

@MainActor enum FinancePostingChecks {
    static func reconciliation(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // 0.2.4: exact-time reconciliation, FX edits/copies, archive boundaries and account navigation.
        do {
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "Reconcile", opening: 1000)
            ledger.accounts = [account]
            let day1 = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))!
            let day20 = Dates.calendar.date(byAdding: .day, value: 19, to: day1)!
            var spent = MoneyEntry(); spent.title = "Later spending"; spent.date = day20; spent.amount = 100; spent.accountAmount = 100; spent.baseAmount = 100
            spent.accountID = account.id; spent.bookID = ledger.books[0].id
            ledger.entries = [spent]; try ledger.validate()
            try require(ledger.balance(account.id, at: day1) == 1000 && ledger.balance(account.id) == 900, "reconciliation excludes later spending but current balance includes it")
            try require(try ledger.reconciliationChange(account.id, at: day1, checked: 1000, expected: 1000) == 0, "backdated matching balance cannot create a false credit")
            let change = try ledger.reconciliationChange(account.id, at: day1, checked: 1050, expected: 1000)
            var adjust = spent; adjust.id = UUID(); adjust.kind = .adjustment; adjust.date = day1; adjust.amount = change; adjust.accountAmount = change; adjust.baseAmount = nil
            ledger.entries.append(adjust); try ledger.validate()
            try require(ledger.balance(account.id, at: day1) == 1050 && ledger.balance(account.id) == 950, "backdated adjustment preserves later spending")
            try require(ledger.balance(account.id, at: day20.addingTimeInterval(-1)) == 1050 && ledger.balance(account.id, at: day20) == 950, "reconciliation includes the selected second but not the next second")
            try rejects("stale reconciliation cannot overwrite changes at its selected time") { _ = try ledger.reconciliationChange(account.id, at: day1, checked: 1050, expected: 1000) }
            try require(try ledger.reconciliationChange(account.id, at: day1, checked: -10, expected: 1050) == -1060, "reconciliation accepts debts and negative balances")
            let balances = ledger.runningBalances(account.id)
            try require(balances[adjust.id] == 1050 && balances[spent.id] == 950, "running balances include earlier entries outside a displayed period")
            var sameTime = spent; sameTime.id = UUID(); sameTime.amount = 10; sameTime.accountAmount = 10; sameTime.baseAmount = 10
            var removed = spent; removed.id = UUID(); removed.deletedAt = Date()
            ledger.entries += [sameTime, removed]
            let running = ledger.runningBalances(account.id)
            let order = ledger.entries.filter { $0.deletedAt == nil }.sorted(by: MoneyEntry.newestFirst)
            try require(running[order[0].id] == ledger.balance(account.id) && running[removed.id] == nil, "equal-time running balances match reverse displayed order and exclude deleted entries")
            try require(running[order[1].id]! + order[0].accountChange(for: account.id) == running[order[0].id]!, "adjacent equal-time rows have exactly their own balance movement")
        }
    }

    static func openingBalanceChanges(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            let source = MoneyAccount(name: "Source AUD", currency: "AUD", opening: 100)
            let destination = MoneyAccount(name: "Study AUD", currency: "AUD", opening: 100)
            let funding = MoneyAccount(name: "Funding", opening: 10000)
            ledger.accounts = [source, destination, funding]
            var incoming = MoneyEntry(); incoming.title = "Incoming"; incoming.kind = .transfer
            incoming.amount = 7500; incoming.accountAmount = 7500; incoming.currency = "CNY"; incoming.accountID = funding.id
            incoming.destinationID = source.id; incoming.destinationAmount = 1500; incoming.bookID = ledger.books[0].id
            ledger.entries = [incoming]; try ledger.validate()
            var outgoing = incoming; outgoing.id = UUID(); outgoing.title = "Outgoing"; outgoing.currency = "AUD"
            outgoing.accountID = source.id; outgoing.destinationID = destination.id; outgoing.amount = 1500; outgoing.accountAmount = 1500
            try require(ledger.balance(source.id) == 1600 && ledger.balanceAfterSaving(outgoing, for: source.id) == 100, "new transfer preview subtracts 1500 only once from 1600")
            try require(ledger.balanceAfterSaving(outgoing, for: destination.id) == 1600, "new transfer preview credits destination")
            outgoing.id = incoming.id
            try require(ledger.balanceAfterSaving(outgoing, for: source.id) == -1400, "editing an incoming transfer previews reversal AND new outgoing")
            try require(ledger.balanceAfterSaving(outgoing, for: funding.id) == 10000, "edit preview includes account removed from the new transfer")
            var posted = ledger; posted.entries = [outgoing]; try posted.validate()
            for account in ledger.accounts { try require(ledger.balanceAfterSaving(outgoing, for: account.id) == posted.balance(account.id), "preview equals actual replacement for every affected account") }
            let cachedBalances = ledger.accountBalances()
            for account in ledger.accounts { try require(ledger.balanceAfterSaving(outgoing, for: account.id, accountBalances: cachedBalances) == posted.balance(account.id), "cached editor balances preserve replacement preview for every affected account") }
            outgoing.fee = 2; outgoing.baseFee = 10
            try require(ledger.balanceAfterSaving(outgoing, for: source.id) == -1402, "preview includes source fee")
            outgoing.deletedAt = Date()
            try require(ledger.balanceAfterSaving(outgoing, for: source.id) == 100, "deleted replacement removes old contribution only")
            ledger.entries[0].deletedAt = Date(); outgoing.deletedAt = nil
            try require(ledger.balanceAfterSaving(outgoing, for: source.id) == -1402, "restoring a deleted transfer does not reverse it twice")
            let before = ledger
            var corrected = source; corrected.opening = 200
            try rejects("used account opening correction requires explicit approval") { try ledger.updateAccount(corrected, expected: source) }
            try require(ledger == before, "rejected correction leaves ledger unchanged")
            try ledger.updateAccount(corrected, expected: source, allowOpeningCorrection: true)
            try require(ledger.balance(source.id) == 200 && ledger.entries == before.entries, "opening correction changes balances without creating or changing transactions")
            try require(ledger.totals(ledger.entries).income == 0 && ledger.totals(ledger.entries).expense == 0, "opening correction is not income or spending")
            try rejects("stale account editor cannot overwrite corrected opening") { try ledger.updateAccount(source, expected: source, allowOpeningCorrection: true) }
            var recurrency = corrected; recurrency.currency = "CNY"
            try rejects("deleted incoming transfer still locks account currency") { try ledger.updateAccount(recurrency, expected: corrected, allowOpeningCorrection: true) }
            var unused = MoneyAccount(name: "Unused")
            try ledger.updateAccount(unused, expected: nil); let originalUnused = unused; unused.currency = "AUD"; unused.opening = 50
            try ledger.updateAccount(unused, expected: originalUnused)
            try require(ledger.accounts.last == unused, "unused account currency and opening remain editable")
            unused.name = source.name
            try rejects("duplicate account names remain blocked") { try ledger.updateAccount(unused, expected: ledger.accounts.last) }
            let adjustment = ledger.reconciliationEntry(for: source.id)
            try require(adjustment.kind == .adjustment && adjustment.accountID == source.id && adjustment.currency == "AUD" && adjustment.bookID == ledger.books[0].id, "account settings and asset page share correct reconciliation defaults")
            ledger.entries[0].deletedAt = nil
            try require(try ledger.reconciliationChange(source.id, at: incoming.date, checked: 1800, expected: 1700) == 100, "current balance reconciliation stays separate from corrected opening")
            try require(try TaskBackup.decode(TaskBackup(finance: ledger, lists: [], tasks: []).encoded()).finance == ledger, "corrected opening survives portable backup")
        }
    }

    static func refundCurrencies(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            let won = MoneyAccount(name: "Won", currency: "KRW", opening: 100)
            ledger.accounts = [won]
            var tiny = MoneyEntry(); tiny.kind = .expense; tiny.title = "Small foreign expense"; tiny.currency = "KRW"
            tiny.amount = 1; tiny.accountAmount = 1; tiny.accountID = won.id; tiny.bookID = ledger.books[0].id
            tiny.baseAmount = Money.round(Decimal(string: "0.004")!, currency: "CNY")
            ledger.entries = [tiny]; try ledger.validate()
            try require(ledger.balance(won.id) == 99 && ledger.totals(ledger.entries).expense == 0 && ledger.totals(ledger.entries).missing == 0, "rounded-zero foreign spending posts actual original amount and counts as converted")
            var returned = tiny; returned.id = UUID(); returned.kind = .refund; returned.refundOf = tiny.id
            ledger.entries.append(returned); try ledger.validate()
            try require(ledger.balance(won.id) == 100 && ledger.remainingRefund(for: tiny.id) == 0, "rounded-zero foreign refund credits full original amount")
            var income = tiny; income.id = UUID(); income.kind = .income; ledger.entries.append(income); try ledger.validate()
            try require(ledger.balance(won.id) == 101 && ledger.totals(ledger.entries).missing == 0, "rounded-zero foreign income remains valid")
            try require(try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(ledger)) == ledger, "zero converted values survive encoding distinctly from missing values")
            ledger.entries[0].baseAmount = -1
            try rejects("negative reporting amount remains invalid for expense") { try ledger.validate() }
            ledger.entries[0] = tiny; ledger.entries[0].amount = 0; ledger.entries[0].accountAmount = 0
            try rejects("zero original expense remains invalid") { try ledger.validate() }
            ledger.entries = [tiny]; ledger.entries[0].currency = "CNY"; ledger.entries[0].amount = 1
            try rejects("base-currency expense cannot be falsely reported as zero") { try ledger.validate() }
        }
    }

    static func expenseDeletionAndBudgets(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // 0.2.7: deleting with refunds, period-aware budgets, example cleanup and more currencies.
        do {
            var ledger = FinanceData.initial
            let card = MoneyAccount(name: "Card", opening: 1000)
            ledger.accounts = [card]
            var coat = MoneyEntry(); coat.title = "Coat"; coat.amount = 300; coat.accountAmount = 300; coat.baseAmount = 300; coat.accountID = card.id; coat.bookID = ledger.books[0].id
            var back = coat; back.id = UUID(); back.kind = .refund; back.refundOf = coat.id; back.amount = 100; back.accountAmount = 100; back.baseAmount = 100; back.date = coat.date.addingTimeInterval(60)
            ledger.entries = [coat, back]; try ledger.validate()
            try ledger.trash(coat, at: Date()); try ledger.validate()
            try require(ledger.entries.allSatisfy { $0.deletedAt != nil } && ledger.balance(card.id) == 1000, "deleting a purchase moves its refunds to the trash with it")
            let deletedRefund = ledger.entries.first { $0.id == back.id }!
            try ledger.restore(deletedRefund); try ledger.validate()
            try require(ledger.entries.allSatisfy { $0.deletedAt == nil } && ledger.balance(card.id) == 800, "restoring a refund brings back its purchase")
            try ledger.trash(ledger.entries.first { $0.id == coat.id }!); try ledger.restore(ledger.entries.first { $0.id == coat.id }!)
            try require(ledger.entries.allSatisfy { $0.deletedAt == nil }, "restoring a purchase brings back refunds deleted with it")
            var edited = ledger; edited.entries[edited.entries.firstIndex { $0.id == coat.id }!].title = "Coat, edited elsewhere"
            try rejects("stale trash") { try edited.trash(coat) }

            let trip = MoneyBook(name: "Old trip", archived: true, budget: 5000)
            ledger.books[0].budget = 2000; ledger.books.append(trip)
            try require(ledger.budget(for: nil, in: ledger.entries) == 2000, "an archived book's budget stays out of periods it was not used in")
            var tripCost = coat; tripCost.id = UUID(); tripCost.bookID = trip.id; tripCost.accountID = nil; tripCost.accountAmount = 0
            try require(ledger.budget(for: nil, in: [tripCost]) == 7000 && ledger.budget(for: nil) == 7000, "an archived book counts in periods it was used, and without a period")

            var sample = FinanceData.initial
            let real = MoneyAccount(name: "学习", currency: "AUD", opening: 100), fake = MoneyAccount(name: "示例 · 澳元账户", currency: "AUD", opening: 200)
            let fakeBook = MoneyBook(name: "示例 · 澳洲旅行", budget: 5000)
            sample.accounts = [real, fake]; sample.books.append(fakeBook); sample.books[0].defaultAccountID = fake.id
            var own = MoneyEntry(); own.title = "购物"; own.currency = "AUD"; own.amount = 20; own.accountAmount = 20; own.baseAmount = 100; own.accountID = real.id; own.bookID = fakeBook.id
            var moved = own; moved.id = UUID(); moved.title = "示例 · 换汇"; moved.kind = .transfer; moved.destinationID = fake.id; moved.destinationAmount = 20; moved.baseAmount = nil
            var mine = own; mine.id = UUID(); mine.title = "余额校准"; mine.kind = .adjustment; mine.accountID = fake.id; mine.baseAmount = nil; mine.bookID = sample.books[0].id
            var example = own; example.id = UUID(); example.title = "示例 · 纪念品"; example.accountID = nil; example.accountAmount = 0
            sample.entries = [own, moved, mine, example]; try sample.validate()
            try require(sample.sampleCleanup == FinanceData.SampleCleanup(entries: 3, ownEntries: 1, accounts: 1, books: 1, moved: 1), "example cleanup preview counts what will change")
            sample.removeSamples(); try sample.validate()
            try require(sample.accounts.map(\.name) == ["学习"] && sample.entries.map(\.id) == [own.id] && sample.entries[0].bookID == sample.books[0].id, "example cleanup keeps own entries and moves them to a real book")
            try require(sample.books[0].defaultAccountID == nil && sample.balance(real.id) == 80 && sample.sampleCleanup == nil, "example cleanup clears defaults and leaves real balances right")

            try require(Money.currencies.count == 31 && Set(Money.currencies).count == 31 && Money.scale("ISK") == 0 && Money.format(1000, "THB").hasPrefix("฿"), "all reference-rate currencies are available")
            let xml = Data(#"<Cube><Cube time="2026-09-25"><Cube currency="THB" rate="38"/><Cube currency="CNY" rate="7.6"/></Cube></Cube>"#.utf8)
            try require(try ExchangeRates.parse(xml, base: "THB", quotes: ["CNY"], onOrBefore: "2026-09-26").first?.rate == Decimal(string: "0.2"), "newly added currencies convert with reference rates")
        }
    }

    static func deletionBatches(directory: URL, require: (Bool, String) throws -> Void) throws {
        // 0.2.11: exact deletion batches survive persistence and portable backups.
        do {
            var ledger = FinanceData.initial
            let card = MoneyAccount(name: "Card", opening: 1000); ledger.accounts = [card]
            var purchase = MoneyEntry(); purchase.title = "Purchase"; purchase.amount = 100; purchase.accountAmount = 100; purchase.baseAmount = 100; purchase.accountID = card.id; purchase.bookID = ledger.books[0].id
            var refund = purchase; refund.id = UUID(); refund.kind = .refund; refund.refundOf = purchase.id; refund.title = "Refund"; refund.amount = 20; refund.accountAmount = 20; refund.baseAmount = 20
            let stamp = MoneyEntry.timestamp()
            ledger.entries = [purchase, refund]
            try ledger.trash(refund, at: stamp.addingTimeInterval(0.1))
            try ledger.trash(purchase, at: stamp.addingTimeInterval(0.7))
            try require(ledger.entries[0].deletedAt == ledger.entries[1].deletedAt && ledger.entries[0].deletionBatchID != ledger.entries[1].deletionBatchID,
                        "Independent deletions in the same second have distinct batches")
            ledger = try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(ledger))
            try ledger.restore(ledger.entries[0]); try ledger.validate()
            try require(ledger.entries[1].deletedAt != nil && ledger.balance(card.id) == 900, "Restore does not resurrect a separately deleted refund or inflate balance")
            try ledger.restore(ledger.entries[1]); try ledger.validate()
            try require(ledger.balance(card.id) == 920 && ledger.entries.allSatisfy { $0.deletionBatchID == nil }, "Explicit refund restore clears batch metadata")
            try ledger.trash(ledger.entries[0], at: stamp)
            let batch = ledger.entries[0].deletionBatchID
            try require(batch != nil && ledger.entries[1].deletionBatchID == batch, "Purchase and its live refund share a deletion batch")
            let container = try Store.make(url: directory.appendingPathComponent("batch.store"))
            try FinanceStore.stage(ledger, in: container.mainContext); try Store.save(container.mainContext)
            let backup = try TaskBackup.capture(container.mainContext)
            let restored = try Store.make(url: directory.appendingPathComponent("batch-restored.store"))
            try TaskBackup.decode(backup.encoded()).restore(restored.mainContext, replace: true)
            var roundTrip = try FinanceStore.read(restored.mainContext)!
            try require(roundTrip == ledger, "Full backup and restore preserve deletion batches")
            try roundTrip.restore(roundTrip.entries[0]); try roundTrip.validate()
            try require(roundTrip.entries.allSatisfy { $0.deletedAt == nil } && roundTrip.balance(card.id) == 920, "Purchase restoration restores precisely its grouped refunds")
            // Old backups remain readable; ambiguous old deletions are restored individually.
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! [String: Any]
            var rows = json["entries"] as! [[String: Any]]
            for i in rows.indices { rows[i].removeValue(forKey: "deletionBatchID") }
            json["entries"] = rows
            var legacy = try JSONDecoder().decode(FinanceData.self, from: JSONSerialization.data(withJSONObject: json))
            try legacy.restore(legacy.entries[0]); try legacy.validate()
            try require(legacy.entries[1].deletedAt != nil && legacy.balance(card.id) == 900, "Legacy deletion timestamps never guess which refunds to restore")
            try legacy.restore(legacy.entries[1]); try legacy.validate()
            try require(legacy.balance(card.id) == 920, "Legacy refunds remain individually recoverable")
        }
    }

    static func offlineEstimatesAndSaves(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Offline entry estimates and saves share these production paths; asset-only quotes never become posting rates.
        do {
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "CNY bank", opening: 1000)
            ledger.accounts = [account]
            let day = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
            try ledger.setManualRate(from: "USD", to: "CNY", text: "99", at: day)
            let manual = ledger.rates[0]
            try require(ledger.cachedReferenceRates(from: "USD", quotes: ["CNY"], onOrBefore: "2026-10-01").isEmpty, "manual asset quote cannot autofill an offline entry")
            let euros = MoneyRate(base: "USD", quote: "EUR", rate: Decimal(string: "0.8")!, date: "2026-09-29")
            ledger.rates += [euros, MoneyRate(base: "EUR", quote: "CNY", rate: 8, date: "2026-09-30")]
            let reference = MoneyRate(base: "USD", quote: "CNY", rate: Decimal(string: "7.1")!, date: "2026-09-30")
            var staleEuros = euros; staleEuros.date = "2026-09-28"; staleEuros.rate = Decimal(string: "0.7")!
            var future = reference; future.date = "2026-10-02"; future.rate = 8
            var invalid = reference; invalid.rate = 0
            var badDate = reference; badDate.date = "2026"
            var badSource = reference; badSource.source = String(repeating: "x", count: 81)
            var unrelated = reference; unrelated.quote = "GBP"
            let cached = ledger.cachedReferenceRates(from: "USD", quotes: ["CNY", "EUR"], onOrBefore: "2026-10-01", including: [manual, future, invalid, badDate, badSource, unrelated, staleEuros, reference])
            try require(cached == [reference, euros], "offline estimates choose usable earlier references and exclude manual, future, invalid and unrelated quotes")
            try require(ledger.cachedReferenceRates(from: "USD", quotes: ["CNY"], onOrBefore: "2026-09-28", including: cached).isEmpty, "backdated entry cannot use later cached quotes")
            var entry = MoneyEntry(); entry.title = "Offline purchase"; entry.date = day; entry.bookID = ledger.books[0].id
            entry.currency = "USD"; entry.amount = 10; entry.accountID = account.id
            entry.accountAmount = Money.round(entry.amount * cached[0].rate, currency: account.currency); entry.baseAmount = entry.accountAmount
            try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY", referenceRates: cached); try ledger.validate()
            try require(ledger.entries == [entry] && ledger.balance(account.id) == 929, "reference fallback saves the real posting offline")
            try require(ledger.storedRate(from: "USD", to: "CNY") == manual, "saving an entry preserves the separate manual asset valuation")
            let previous = entry; entry.accountAmount = 72; entry.baseAmount = 72
            try ledger.updateEntry(entry, expected: previous, baseCurrency: "CNY", referenceRates: [manual, reference]); try ledger.validate()
            try require(ledger.entries == [entry] && ledger.balance(account.id) == 928 && ledger.storedRate(from: "USD", to: "CNY") == manual, "older editor state containing a manual quote still saves the entered actual amount without rewriting asset rates")
            let reviewed = entry; entry.accountAmount = 73; entry.baseAmount = 73
            try ledger.updateEntry(entry, expected: reviewed, baseCurrency: "CNY"); try ledger.validate()
            try require(ledger.entries == [entry] && ledger.balance(account.id) == 927, "explicit actual amounts save without any reference rate or network")
            let saved = ledger
            try rejects("invalid reference quote still rejects the entry atomically") { try ledger.updateEntry(previous, expected: entry, baseCurrency: "CNY", referenceRates: [invalid]) }
            try require(ledger == saved, "failed reference validation preserves entries and rates")
        }
    }

    static func editorActualAmounts(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            let onlyBook = ledger.books[0]
            ledger.books.append(MoneyBook(name: "Past trip", archived: true))
            var archived = onlyBook; archived.archived = true
            let original = ledger
            try require(ledger.bookArchiveBlock(onlyBook.id) != nil, "archive toggle explains why the last available book must remain active")
            try rejects("last available book cannot be archived") { try ledger.updateBook(archived, expected: onlyBook, baseCurrency: ledger.baseCurrency) }
            try require(ledger == original, "blocked archival keeps the book and historical references unchanged")
            let second = MoneyBook(name: "Other active book")
            try ledger.updateBook(second, expected: nil, baseCurrency: ledger.baseCurrency)
            try ledger.updateBook(archived, expected: onlyBook, baseCurrency: ledger.baseCurrency)
            try require(ledger.books.first { $0.id == onlyBook.id }?.archived == true && ledger.bookArchiveBlock(second.id) != nil, "another active book allows archival and becomes protected immediately")
            try ledger.updateBook(onlyBook, expected: archived, baseCurrency: ledger.baseCurrency)
            try require(ledger.bookArchiveBlock(second.id) == nil, "restoring an archived book makes the other book archivable")
            ledger.books = [archived]
            var renamed = archived; renamed.name = "Renamed old archive"
            try ledger.updateBook(renamed, expected: archived, baseCurrency: ledger.baseCurrency)
            try require(ledger.books == [renamed], "legacy all-archived books remain editable without an archival transition")
            try rejects("a new archived book cannot leave an all-archived ledger without an available book") {
                try ledger.updateBook(MoneyBook(name: "Another archive", archived: true), expected: nil, baseCurrency: ledger.baseCurrency)
            }
        }
    }

    static func postedEntryEdits(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Editing a posted income/expense reverses its old effect without duplicating money.
        do {
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "Posting account", currency: "AUD", opening: 1000)
            ledger.accounts = [account]
            var expense = MoneyEntry(); expense.title = "Corrected entry"; expense.kind = .expense
            expense.currency = "USD"; expense.amount = 10; expense.accountAmount = 15; expense.baseAmount = 70
            expense.accountID = account.id; expense.bookID = ledger.books[0].id
            try ledger.updateEntry(expense, expected: nil, baseCurrency: "CNY")
            try require(ledger.balance(account.id) == 985 && ledger.entryKindChangeBlock(expense) == nil, "ordinary posted expenses can change type")
            var income = expense; income.kind = .income
            try ledger.updateEntry(income, expected: expense, baseCurrency: "CNY"); try ledger.validate()
            try require(ledger.entries == [income] && ledger.balance(account.id) == 1015, "expense to income replaces the posting instead of appending another one")
            try require(ledger.statisticsTotal(ledger.entries, income: true, in: "CNY", history: nil, days: nil).total == 70 && ledger.statisticsTotal(ledger.entries, income: false, in: "CNY", history: nil, days: nil).total == 0, "type change updates both statistics directions and preserves recorded FX")
            try ledger.updateEntry(expense, expected: income, baseCurrency: "CNY"); try ledger.validate()
            try require(ledger.balance(account.id) == 985 && ledger.entries == [expense], "income can change back without changing original or account currency amounts")
            var refund = expense; refund.id = UUID(); refund.kind = .refund; refund.refundOf = expense.id
            try ledger.updateEntry(refund, expected: nil, baseCurrency: "CNY")
            let withRefund = ledger
            try rejects("a refund arriving after the editor opened blocks changing its purchase to income") { try ledger.updateEntry(income, expected: expense, baseCurrency: "CNY") }
            try require(ledger == withRefund, "blocked kind change leaves all postings untouched")
            try ledger.trash(refund)
            try require(ledger.entryKindChangeBlock(expense) != nil, "a deleted refund still protects its restorable purchase")
            try rejects("deleted refund references also prevent kind changes at save time") { try ledger.updateEntry(income, expected: expense, baseCurrency: "CNY") }
            ledger.entries = [expense]
            var transfer = expense; transfer.kind = .transfer
            try rejects("existing income/expense cannot become a transfer") { try ledger.updateEntry(transfer, expected: expense, baseCurrency: "CNY") }
            ledger.entries = [transfer]
            try rejects("existing transfer cannot become ordinary income") { try ledger.updateEntry(income, expected: transfer, baseCurrency: "CNY") }
            ledger.entries = [expense]
            var changed = expense; changed.title = "Newer edit"
            ledger.entries = [changed]
            try rejects("type change cannot overwrite a concurrent entry edit") { try ledger.updateEntry(income, expected: expense, baseCurrency: "CNY") }
        }
    }

    static func entryCategories(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        var ledger = FinanceData.initial
        let category = MoneyCategory(name: "Draft category", income: false)
        try ledger.updateCategory(category, expected: nil)
        var entry = MoneyEntry(); entry.title = "Open expense draft"; entry.amount = 10; entry.baseAmount = 10
        entry.bookID = ledger.books[0].id; entry.categoryID = category.id
        var incomeCategory = category; incomeCategory.income = true
        try ledger.updateCategory(incomeCategory, expected: category)
        let changed = ledger
        try rejects("category type changed in another window rejects the stale expense draft") {
            try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY")
        }
        try require(ledger == changed, "category race rejects before changing the ledger")
        try ledger.updateCategory(category, expected: incomeCategory)
        try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY")
        var archived = category; archived.archived = true
        try ledger.updateCategory(archived, expected: category)
        var edited = entry; edited.notes = "Historical detail correction"
        try ledger.updateEntry(edited, expected: entry, baseCurrency: "CNY")
        try require(ledger.entries == [edited], "existing archived category links survive ordinary historical edits")
        let historical = ledger
        var copy = edited; copy.id = UUID()
        try rejects("a new copy cannot silently post to an archived category") { try ledger.updateEntry(copy, expected: nil, baseCurrency: "CNY") }
        var income = edited; income.kind = .income
        try rejects("changing kind cannot retain an archived expense category") { try ledger.updateEntry(income, expected: edited, baseCurrency: "CNY") }
        copy.categoryID = UUID()
        try rejects("a category deleted after the editor opened cannot be saved") { try ledger.updateEntry(copy, expected: nil, baseCurrency: "CNY") }
        try require(ledger == historical, "rejected category selections preserve existing history")
        income.categoryID = ledger.categories.first { $0.isIncome && !$0.archived }!.id
        try ledger.updateEntry(income, expected: edited, baseCurrency: "CNY")
        try require(ledger.entries == [income], "a corrected type change saves with an available matching category")
        var active = income; active.categoryID = archived.id
        try rejects("switching an existing entry to an archived category is rejected") { try ledger.updateEntry(active, expected: income, baseCurrency: "CNY") }
        copy.categoryID = nil
        try ledger.updateEntry(copy, expected: nil, baseCurrency: "CNY")
        try ledger.validate()
        try require(ledger.entries.contains(copy), "uncategorized entries remain supported")
    }

    static func accountActions(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // The visible account actions retain the same history and concurrent-edit protections as the editor.
        do {
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "Unused account", opening: 200)
            ledger.accounts = [account]; ledger.books[0].defaultAccountID = account.id
            let original = ledger
            try ledger.remove(.account, id: account.id, expected: original)
            try require(ledger.accounts.isEmpty && ledger.books[0].defaultAccountID == nil, "deleting an unused account clears its default-account references")
            ledger = original
            var changed = account; changed.opening = 300
            try ledger.updateAccount(changed, expected: account)
            try rejects("account deletion confirmation cannot discard a newer balance edit") { try ledger.remove(.account, id: account.id, expected: original) }
            ledger = original
            var entry = MoneyEntry(); entry.title = "New posting"; entry.amount = 20; entry.accountAmount = 20; entry.baseAmount = 20
            entry.accountID = account.id; entry.bookID = ledger.books[0].id
            try ledger.updateEntry(entry, expected: nil, baseCurrency: "CNY")
            try rejects("a posting arriving during account deletion confirmation blocks removal") { try ledger.remove(.account, id: account.id, expected: original) }
            var archived = account; archived.archived = true
            try ledger.updateAccount(archived, expected: account)
            try require(ledger.balance(account.id) == 180 && ledger.entries == [entry], "archiving a used account keeps its balance and entries")
            try ledger.trash(entry)
            try require(ledger.removalBlock(.account, id: account.id) != nil, "Recently deleted entries still protect their account")
            ledger.entries = [entry]; ledger.entries[0].accountID = nil; ledger.entries[0].destinationID = account.id
            try require(ledger.removalBlock(.account, id: account.id) != nil, "incoming transfers protect their destination account")
        }
    }

    static func pendingEntries(directory: URL, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Planned entries retain their identity and affect money only after an explicit, guarded confirmation.
        do {
            var ledger = FinanceData.initial
            let card = MoneyAccount(name: "Pending card", currency: "USD", opening: 100)
            ledger.accounts = [card]; ledger.books[0].budget = 1000
            let today = Dates.calendar.startOfDay(for: Date()), tomorrow = Dates.calendar.date(byAdding: .day, value: 1, to: today)!
            var planned = MoneyEntry(); planned.title = "Planned expense"; planned.currency = "USD"; planned.amount = 10
            planned.accountID = card.id; planned.accountAmount = 10; planned.bookID = ledger.books[0].id
            planned.categoryID = ledger.categories.first { !$0.isIncome }!.id
            planned.date = tomorrow; planned.pending = true
            try ledger.updateEntry(planned, expected: nil, baseCurrency: "CNY"); try ledger.validate()
            let original = ledger
            try require(!planned.isDueForConfirmation(at: today) && planned.isDueForConfirmation(at: tomorrow), "confirmation starts on the planned calendar day")
            try rejects("future pending entry cannot post early") { try ledger.confirmPending(planned, now: today) }
            try require(ledger == original, "failed confirmation is atomic")
            var midnightCalendar = Calendar(identifier: .gregorian); midnightCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            let evening = midnightCalendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23))!
            var timed = planned; timed.date = evening
            try require(timed.isDueForConfirmation(at: midnightCalendar.startOfDay(for: evening), calendar: midnightCalendar), "timed plans can be confirmed earlier on their own local day")
            timed.date = Date(timeIntervalSince1970: .infinity)
            try require(!timed.isDueForConfirmation(at: today), "invalid planned dates never reach calendar calculations")
            try require(ledger.balance(card.id) == 100 && ledger.accountBalances()[card.id] == 100 && ledger.balanceAfterSaving(planned, for: card.id) == 100, "planned amounts do not change account balances or editor previews")
            try require(ledger.accountFlow(card.id, in: ledger.entries).outgoing == 0 && ledger.runningBalances(card.id).isEmpty, "pending rows are excluded from account flows and running balances")
            let totals = ledger.totals(ledger.entries), pendingStats = ledger.statisticsTotal(ledger.entries, income: false, in: "CNY", history: nil, days: nil)
            try require(totals.expense == 0 && totals.income == 0 && totals.missing == 0 && pendingStats.total == 0 && pendingStats.missing == 0 && pendingStats.convertedCount == 0, "pending FX never counts as spending or missing conversions")
            try require(ledger.statisticsTotal(ledger.entries, income: false, in: "USD", history: nil, days: nil).total == 0 && planned.statisticsAmount(income: false) == nil, "original-currency and base statistics both exclude pending amounts")
            try require(ledger.budgetSpending(ledger.entries, for: nil).total == 0 && ledger.budgetSpending(ledger.entries, for: nil).missing == 0, "pending spending does not consume the budget")
            try require(ledger.byCategory(ledger.entries, income: false).rows.isEmpty && ledger.remainingRefund(for: planned.id) == 0, "pending spending has no category contribution or refundable balance")
            let drilldown = MoneyDrilldown(range: DateInterval(start: today, end: tomorrow.addingTimeInterval(86400)), key: .category(planned.categoryID), income: false)
            try require(!drilldown.matches(planned) && !drilldown.matches(planned, data: ledger), "statistical drill-downs exclude unposted plans")
            try require(ledger.missingConversionEntries.isEmpty && ledger.missingConversionPreview(history: nil).changes.isEmpty, "bulk conversion never changes unposted plans")
            try require(ledger.csv(ledger.entries).contains("\"Status\"") && ledger.csv(ledger.entries).contains("\"pending\""), "CSV marks planned amounts explicitly")
            var revised = planned; revised.amount = 12; revised.accountAmount = 12
            try ledger.updateEntry(revised, expected: planned, baseCurrency: "CNY")
            try rejects("stale confirmation cannot post a newer amount") { try ledger.confirmPending(planned, now: tomorrow) }
            try require(ledger.balance(card.id) == 100 && ledger.entries == [revised], "editing pending keeps it unposted with the same identity")
            var bypass = revised; bypass.pending = false
            try rejects("normal save cannot silently post a pending entry") { try ledger.updateEntry(bypass, expected: revised, baseCurrency: "CNY") }
            ledger = original
            ledger.accounts[0].archived = true
            try rejects("archived account blocks confirmation") { try ledger.confirmPending(planned, now: tomorrow) }
            ledger = original; ledger.books[0].archived = true
            try rejects("archived book blocks confirmation") { try ledger.confirmPending(planned, now: tomorrow) }
            ledger = original; ledger.categories[0].archived = true
            try rejects("archived category blocks confirmation") { try ledger.confirmPending(planned, now: tomorrow) }
            ledger = original; ledger.categories[0].income = true
            try rejects("mismatched category blocks confirmation") { try ledger.confirmPending(planned, now: tomorrow) }
            ledger = original; ledger.entries[0].bookID = UUID()
            try rejects("missing book blocks confirmation") { try ledger.confirmPending(ledger.entries[0], now: tomorrow) }
            ledger = original; ledger.entries[0].accountAmount = 20
            let invalid = ledger
            try rejects("invalid amounts are revalidated before confirmation") { try ledger.confirmPending(ledger.entries[0], now: tomorrow) }
            try require(ledger == invalid, "validation failure does not partially post a plan")
            ledger = original; try ledger.trash(planned)
            try rejects("deleted plan cannot be confirmed") { try ledger.confirmPending(ledger.entries[0], now: tomorrow) }
            try ledger.restore(ledger.entries[0])
            try require(ledger.entries == [planned] && ledger.balance(card.id) == 100, "restoring a pending entry does not post it")
            var refund = planned; refund.id = UUID(); refund.pending = nil; refund.kind = .refund; refund.refundOf = planned.id
            ledger.entries.append(refund)
            try rejects("refunds cannot reference unposted expenses") { try ledger.validate() }
            for kind in [MoneyKind.transfer, .refund, .adjustment] {
                var unsupported = planned; unsupported.kind = kind
                var check = original; check.entries = [unsupported]
                try rejects("only income or expense supports pending: \(kind.rawValue)") { try check.validate() }
            }
            ledger = original
            try ledger.setManualRate(from: "USD", to: "CNY", text: "7")
            try ledger.confirmPending(planned, now: tomorrow)
            let posted = ledger.entries[0]
            try require(ledger.entries.count == 1 && posted.id == planned.id && !posted.isPending && posted.date == planned.date && posted.baseAmount == nil, "confirmation preserves identity, date and missing FX rather than applying today's asset quote")
            try require(ledger.balance(card.id) == 90 && ledger.statisticsTotal(ledger.entries, income: false, in: "USD", history: nil, days: nil).total == 10 && ledger.missingConversionEntries == [posted], "confirmation debits once and exposes genuine missing conversion")
            try rejects("repeating confirmation cannot double-post") { try ledger.confirmPending(planned, now: tomorrow) }
            try rejects("already-posted current row cannot be confirmed again") { try ledger.confirmPending(posted, now: tomorrow) }
            try rejects("posted entries cannot become pending through editing") { try ledger.updateEntry(planned, expected: posted, baseCurrency: "CNY") }
            try require(ledger.balance(card.id) == 90 && ledger.csv(ledger.entries).contains("\"posted\""), "rejected status transitions preserve the posted amount")
            var income = planned; income.id = UUID(); income.kind = .income; income.categoryID = ledger.categories.first { $0.isIncome }!.id
            try ledger.updateEntry(income, expected: nil, baseCurrency: "CNY")
            try require(ledger.statisticsTotal(ledger.entries, income: true, in: "USD", history: nil, days: nil).total == 0, "planned income is not counted early")
            try ledger.confirmPending(income, now: tomorrow)
            try require(ledger.balance(card.id) == 100 && ledger.statisticsTotal(ledger.entries, income: true, in: "USD", history: nil, days: nil).total == 10, "confirmed income credits exactly once")
            var legacy = original; legacy.version = 1; legacy.entries = []
            try legacy.validate()
            var oldEntry = planned; oldEntry.pending = nil
            legacy.entries = [oldEntry]; try legacy.validate()
            let legacyJSON = try JSONEncoder().encode(legacy)
            let decoded = try JSONDecoder().decode(FinanceData.self, from: legacyJSON)
            try require(!decoded.entries[0].isPending && decoded.balance(card.id) == 90 && !String(decoding: legacyJSON, as: UTF8.self).contains("pending"), "older entries without a status remain posted")
            legacy.entries = [planned]
            try rejects("old ledger version cannot hide pending data from older clients") { try legacy.validate() }
            legacy.entries = []
            try require(try legacy.merging(original).version == 2, "merging a pending ledger upgrades its format")
            try legacy.updateEntry(planned, expected: nil, baseCurrency: "CNY"); try legacy.validate()
            try require(legacy.version == 2, "saving the first plan upgrades an older ledger")
            let pendingStore = try Store.make(url: directory.appendingPathComponent("Pending.store"))
            try FinanceStore.stage(original, in: pendingStore.mainContext); try Store.save(pendingStore.mainContext)
            let pendingBackup = try TaskBackup.capture(pendingStore.mainContext)
            let pendingRoundTrip = try TaskBackup.decode(pendingBackup.encoded())
            try require(pendingRoundTrip.version == 10 && pendingRoundTrip.finance == original, "pending survives storage and portable backup without entering balances")
        }
    }
}
