import Foundation
import SwiftData

@MainActor enum FinanceDataChecks {
    static func readCache(context: ModelContext, value: FinanceData, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Cached reads must still observe external writes, deletion and rollback.
        do {
            let record = try context.fetch(FetchDescriptor<FinanceLedger>()).first!
            var draft = try FinanceStore.read(context)!
            draft.entries[0].title = "Unsaved draft"
            try require(try FinanceStore.read(context) == value, "editing a returned value cannot change the read cache")
            record.payload = try JSONEncoder().encode(draft)
            try require(try FinanceStore.read(context) == draft, "changed payload replaces cached ledger")
            context.rollback()
            try require(try FinanceStore.read(context) == value, "rollback invalidates cached staged changes")
            record.payload = Data("invalid JSON".utf8)
            try rejects("cached reads cannot hide a corrupt replacement") { _ = try FinanceStore.read(context) }
            context.rollback()
            draft.entries[0].amount = -1
            record.payload = try JSONEncoder().encode(draft)
            try rejects("replacement payload still receives financial validation") { _ = try FinanceStore.read(context) }
            context.rollback()
            context.insert(FinanceLedger(payload: record.payload))
            try rejects("cache cannot bypass duplicate-ledger protection") { _ = try FinanceStore.read(context) }
            context.rollback()
            context.delete(record)
            try require(try FinanceStore.read(context) == nil, "removed ledger never returns cached data")
            context.rollback()
            try require(try FinanceStore.read(context) == value, "restored ledger remains readable after cache failures")
        }
    }

    static func amountInput(require: (Bool, String) throws -> Void) throws {
        // 0.2.1: keypad amounts, symbols, income categories, colors, account types and budgets.
        try require(Money.evaluate("12.5+8−3", currency: "CNY") == Decimal(string: "17.5") && Money.evaluate("12+", currency: "CNY") == 12, "keypad sums and ignores a trailing operator")
        try require(Money.evaluate("5−8", currency: "CNY") == nil && Money.evaluate("1.234", currency: "CNY") == nil && Money.evaluate("1.5", currency: "JPY") == nil, "keypad rejects negatives and excess decimals")
        try require(Money.evaluate("−20", currency: "CNY", signed: true) == -20 && Money.evaluate("−20", currency: "CNY") == nil, "only balance entry accepts a negative amount")
        try require(Money.format(1234.5, "CNY").hasPrefix("¥") && Money.format(-3, "AUD").hasPrefix("-A$") && Money.format(5, "JPY").hasPrefix("JP¥"), "amounts show symbols, yen distinct from yuan")
    }

    static func legacyDefaults(oldJSON: String, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws -> FinanceData {
        var legacyLedger = try JSONDecoder().decode(FinanceData.self, from: Data(oldJSON.utf8))
        try legacyLedger.validate()
        try require(legacyLedger.categories[0].isIncome && !legacyLedger.categories[1].isIncome && legacyLedger.categories[1].resolvedColor == "coral", "0.2.0 ledgers decode with income and colors inferred")
        try require(legacyLedger.accounts[0].resolvedType == .online && legacyLedger.books[0].budget == nil, "older accounts get a type, books no budget")
        legacyLedger.addMissingDefaults(); let once = legacyLedger.categories; legacyLedger.addMissingDefaults()
        try require(once == legacyLedger.categories && once.count == 2 + FinanceData.addedDefaults.count, "new default categories are added exactly once")
        var elsewhere = try JSONDecoder().decode(FinanceData.self, from: Data(oldJSON.utf8)); elsewhere.addMissingDefaults()
        try require((try? legacyLedger.merging(elsewhere)) == legacyLedger, "two devices adding defaults still merge cleanly")
        try require(FinanceData.initial.categories.filter(\.isIncome).count >= 5 && FinanceData.initial.categories.prefix(8).map(\.name) == ["food", "transport", "shopping", "home", "travel", "health", "salary", "other"], "new ledgers have income categories and keep original order")
        var budgeted = legacyLedger; budgeted.books[0].budget = 3000
        try budgeted.validate()
        try require(budgeted.budget(for: nil) == 3000 && budgeted.budget(for: budgeted.books[0].id) == 3000, "budget is per book and summed for all books")
        budgeted.books[0].budget = 0
        try rejects("zero budget") { try budgeted.validate() }
        let roundTrip = try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(legacyLedger))
        try require(roundTrip == legacyLedger, "new fields survive encoding")
        try require(Money.evaluate(" 1,234.50\n", currency: "CNY") == Decimal(string: "1234.5"), "pasted grouped amounts and a trailing newline are accepted")
        try require(Money.evaluate("12,50", currency: "CNY") == nil && Money.evaluate("1,23,456", currency: "CNY") == nil, "ambiguous and malformed separators cannot silently change an amount")
        return legacyLedger
    }

    static func statisticsBreakdown(require: (Bool, String) throws -> Void) throws {
        // 0.2.2: one statistics rule, exact drill-down ranges, and optional portable icons.
        let report = FinanceData.initial
        let categoryA = report.categories[0].id, categoryB = report.categories[1].id
        func reportEntry(_ kind: MoneyKind, _ amount: Decimal, category: UUID? = nil) -> MoneyEntry {
            var e = MoneyEntry(); e.kind = kind; e.amount = abs(amount); e.baseAmount = abs(amount); e.categoryID = category
            e.bookID = report.books[0].id; return e
        }
        let cost = reportEntry(.expense, 100, category: categoryA)
        let returned = reportEntry(.refund, 30, category: categoryB)
        var feeEntry = reportEntry(.transfer, 100); feeEntry.fee = 2; feeEntry.baseFee = 2; feeEntry.baseAmount = nil
        let uncategorized = reportEntry(.expense, 5)
        let earned = reportEntry(.income, 200, category: categoryA)
        let rows = [cost, returned, feeEntry, uncategorized, earned]
        let breakdown = report.byCategory(rows, income: false)
        let totals = report.totals(rows)
        try require(breakdown.rows.reduce(Decimal(0)) { $0 + $1.total } == totals.expense - totals.refunds && totals.expense - totals.refunds == 77, "category totals equal net spending including negative refunds and transfer fees")
        try require(breakdown.rows.first { $0.id == .category(categoryB) }?.total == -30, "refund-only category remains visible with its negative value")
        try require(breakdown.rows.first { $0.id == .fees }?.total == 2, "fees have their own category")
        try require(rows.compactMap { $0.statisticsAmount(income: false) }.reduce(0, +) == 77, "trend contribution matches the summary without clamping refunds")
        try require(report.byCategory(rows, income: true).rows.reduce(Decimal(0)) { $0 + $1.total } == 200, "income excludes expenses refunds and fees")
        var unconvertedFee = feeEntry; unconvertedFee.baseFee = nil
        var unconvertedExpense = cost; unconvertedExpense.baseAmount = nil
        try require(report.byCategory([unconvertedFee, unconvertedExpense], income: false).missing == 2, "unconverted fees and expenses are counted")
        var removed = cost; removed.deletedAt = Date()
        try require(report.byCategory([removed], income: false).rows.isEmpty, "deleted entries never appear in the breakdown")
        var fullyReturned = returned; fullyReturned.categoryID = categoryA; fullyReturned.amount = 100; fullyReturned.baseAmount = 100
        try require(report.byCategory([cost, fullyReturned], income: false).rows.first?.total == 0, "fully refunded categories stay available for detail inspection")
        let start = Dates.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = Dates.calendar.date(byAdding: .year, value: 1, to: start)!
        let span = DateInterval(start: start, end: end)
        var atStart = cost; atStart.date = start
        var atEnd = cost; atEnd.date = end
        var beforeYear = cost; beforeYear.date = start.addingTimeInterval(-1)
        let drill = MoneyDrilldown(range: span, key: .category(categoryA), income: false)
        try require(drill.matches(atStart) && !drill.matches(atEnd) && !drill.matches(beforeYear), "annual drill-down uses a half-open date range")
        let week = Dates.calendar.dateInterval(of: .weekOfYear, for: end)!
        var inWeek = cost; inWeek.date = week.start.addingTimeInterval(60)
        var outOfWeek = cost; outOfWeek.date = week.end
        let weekDrill = MoneyDrilldown(range: week, key: .category(categoryA), income: false)
        try require(weekDrill.matches(inWeek) && !weekDrill.matches(outOfWeek), "cross-year week drill-down keeps exactly that week")
        try require(MoneyCategoryKey.category(nil).includes(uncategorized, income: false) && !MoneyCategoryKey.category(nil).includes(cost, income: false), "uncategorized drill-down is not all categories")
        try require(MoneyCategoryKey.fees.includes(feeEntry, income: false) && !MoneyCategoryKey.fees.includes(uncategorized, income: false), "fee drill-down only contains fee-bearing transfers")
        try require(!MoneyCategoryKey.category(categoryA).includes(earned, income: false), "spending drill-down excludes income sharing a category")
    }

    static func portableIcons(value: FinanceData, bank: MoneyAccount, fresh: ModelContainer, directory: URL, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        var decorated = value
        decorated.accounts[0].emoji = "💳"; decorated.accounts[0].symbol = "creditcard"
        decorated.books[0].emoji = "🧑🏽‍💻"; decorated.books[0].symbol = "briefcase"
        decorated.categories[0].emoji = "☕"
        try decorated.validate()
        let decoratedBackup = TaskBackup(finance: decorated, lists: [], tasks: [])
        try require(try TaskBackup.decode(decoratedBackup.encoded()).finance == decorated, "all finance icons survive a full backup round trip")
        try decoratedBackup.restore(fresh.mainContext, replace: true)
        let iconReopened = try Store.make(url: directory.appendingPathComponent("Restored.store"))
        try require(try FinanceStore.read(iconReopened.mainContext) == decorated, "finance icons survive restore and database reopen")
        var invalidIcon = decorated; invalidIcon.categories[0].emoji = "abc"
        try rejects("invalid plain text icon") { try invalidIcon.validate() }
        invalidIcon = decorated; invalidIcon.accounts[0].emoji = "💳🏦"
        try rejects("multiple emoji in account icon") { try invalidIcon.validate() }
        try require(decorated.balance(bank.id) == value.balance(bank.id) && decorated.totals(decorated.entries).expense == value.totals(value.entries).expense, "changing icons cannot affect balances or totals")
    }

    static func budgets(require: (Bool, String) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            ledger.books[0].budget = 1000
            let trip = MoneyBook(name: "Archived trip", archived: true, budget: 2000)
            let noBudget = MoneyBook(name: "No budget")
            ledger.books += [trip, noBudget]
            var cost = MoneyEntry(); cost.title = "Trip"; cost.amount = 1500; cost.baseAmount = 1500; cost.bookID = trip.id
            var other = cost; other.id = UUID(); other.amount = 5000; other.baseAmount = 5000; other.bookID = noBudget.id
            var returned = cost; returned.id = UUID(); returned.kind = .refund; returned.refundOf = cost.id; returned.amount = 100; returned.baseAmount = 100
            var removed = cost; removed.id = UUID(); removed.deletedAt = Date()
            ledger.entries = [cost, other, returned, removed]; try ledger.validate()
            try require(ledger.budget(for: nil) == 3000 && ledger.budgetSpending(ledger.entries, for: nil).total == 1400, "all-book budgets and spending both include archived budgeted books")
            try require(ledger.totals(ledger.entries).expense - ledger.totals(ledger.entries).refunds == 6400, "unbudgeted spending remains in total spending without consuming other books' budgets")
            try require(ledger.budget(for: trip.id) == 2000 && ledger.budgetSpending(ledger.entries, for: trip.id).total == 1400, "single-book budget excludes other books and deleted entries")
            ledger.books[1].archived = false
            try require(ledger.budget(for: nil) == 3000 && ledger.budgetSpending(ledger.entries, for: nil).total == 1400, "archiving and unarchiving do not rewrite historical budget comparisons")
        }
    }

    static func categoryHistory(require: (Bool, String) throws -> Void) throws {
        do {
            var ledger = FinanceData.initial
            let bookID = ledger.books[0].id, parent = ledger.categories.first { !$0.isIncome }!
            let child = MoneyCategory(name: "Child", parentID: parent.id)
            ledger.categories.append(child)
            func month(_ number: Int) -> Date { Dates.calendar.date(from: DateComponents(year: 2026, month: number, day: 2, hour: 12))! }
            var current = MoneyEntry(); current.title = "Current"; current.bookID = bookID; current.categoryID = parent.id
            current.amount = 60; current.baseAmount = 60; current.date = month(10)
            var historical = current; historical.id = UUID(); historical.categoryID = child.id; historical.currency = "USD"
            historical.amount = 10; historical.baseAmount = nil; historical.date = month(8)
            var deleted = historical; deleted.id = UUID(); deleted.deletedAt = month(10)
            var outside = historical; outside.id = UUID(); outside.date = month(4)
            ledger.entries = [current, historical, deleted, outside]
            let months = ledger.categoryMonthlyTotals(.category(parent.id), income: false, endingAt: month(10), bookID: bookID, in: "CNY", history: nil)
            try require(months.count == 6 && months[3].summary.missing == 1 && months[5].summary.total == 60, "six-month parent history includes its child and retains missing August conversions")
            try require(months[0].summary.complete && months[0].summary.total == 0, "a genuinely empty month remains an exact zero")
            try require(MoneyStatisticsTotal.average(months.map(\.summary)) == nil, "missing prior months never produce a misleading numeric monthly average")
            let childMonths = ledger.categoryMonthlyTotals(.category(child.id), income: false, endingAt: month(10), bookID: bookID, in: "CNY", history: nil)
            try require(childMonths[3].summary.missing == 1 && childMonths[5].summary.total == 0, "child history remains scoped to the child while retaining missing amounts")
            ledger.entries[1].baseAmount = 70
            let completed = ledger.categoryMonthlyTotals(.category(parent.id), income: false, endingAt: month(10), bookID: bookID, in: "CNY", history: nil)
            try require(MoneyStatisticsTotal.average(completed.map(\.summary)) == Decimal(130) / 6, "completed history computes all six months including exact zeros and saved conversions")
            try require(MoneyStatisticsTotal.average([MoneyStatisticsTotal(total: 30, estimateDates: ["2026-09-30"])]) == nil, "cached estimates do not become a definitive monthly average")
            try require(MoneyStatisticsTotal.average([]) == nil, "an empty history cannot divide by zero")
        }
    }

    static func entityRemoval(require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // 0.2.5: safe entity removal, refreshed estimates, privacy and refund availability.
        do {
            var ledger = FinanceData.initial
            let source = MoneyAccount(name: "Unused", opening: 120), destination = MoneyAccount(name: "Other")
            let book = MoneyBook(name: "Extra", defaultAccountID: source.id)
            let category = MoneyCategory(name: "Custom")
            ledger.accounts = [source, destination]; ledger.books[0].defaultAccountID = source.id
            ledger.books.append(book); ledger.categories.append(category)
            let baseline = ledger
            try ledger.remove(.account, id: source.id, expected: baseline)
            try ledger.validate()
            try require(ledger.accounts == [destination] && ledger.books.allSatisfy { $0.defaultAccountID == nil }, "removing unused account clears defaults in every book")
            try require(ledger.entries == baseline.entries && ledger.balance(destination.id) == baseline.balance(destination.id), "account removal leaves other balances and entries unchanged")
            try ledger.remove(.category, id: category.id, expected: baseline)
            try require(!ledger.categories.contains { $0.id == category.id }, "unused custom category can be deleted")
            let beforeBookRemoval = ledger
            try ledger.remove(.book, id: book.id, expected: beforeBookRemoval)
            try require(ledger.books.count == 1, "unused extra book can be deleted")
            let last = ledger
            try rejects("last usable book cannot be removed") { try ledger.remove(.book, id: ledger.books[0].id, expected: last) }
            try require(ledger == last, "blocked removal changes nothing")
            try rejects("preset category deletion blocked so upgrade cannot resurrect it") { try ledger.remove(.category, id: ledger.categories[0].id, expected: last) }
            var linked = baseline
            var transfer = MoneyEntry(); transfer.kind = .transfer; transfer.title = "Transfer"
            transfer.amount = 10; transfer.accountAmount = 10; transfer.destinationAmount = 10
            transfer.accountID = source.id; transfer.destinationID = destination.id; transfer.bookID = book.id
            transfer.deletedAt = Date(); linked.entries = [transfer]
            try linked.validate()
            try rejects("recently deleted source still prevents account removal") { try linked.remove(.account, id: source.id, expected: baseline) }
            try rejects("recently deleted destination still prevents account removal") { try linked.remove(.account, id: destination.id, expected: baseline) }
            try rejects("recently deleted bill prevents book removal") { try linked.remove(.book, id: book.id, expected: baseline) }
            transfer.kind = .expense; transfer.destinationID = nil; transfer.destinationAmount = 0
            transfer.categoryID = category.id; transfer.baseAmount = 10; linked.entries = [transfer]
            try rejects("recently deleted bill prevents category removal") { try linked.remove(.category, id: category.id, expected: baseline) }
            var changed = baseline; changed.accounts[0].opening = 200
            try rejects("stale account editor cannot delete changed account") { try changed.remove(.account, id: source.id, expected: baseline) }
            changed = baseline; changed.books[1].name = "Renamed"
            try rejects("stale book editor cannot delete changed book") { try changed.remove(.book, id: book.id, expected: baseline) }
            changed = baseline; changed.categories[changed.categories.count - 1].name = "Renamed"
            try rejects("stale category editor cannot delete changed category") { try changed.remove(.category, id: category.id, expected: baseline) }
            try rejects("already removed account cannot be removed twice") { try ledger.remove(.account, id: source.id, expected: baseline) }
            var archived = baseline; archived.accounts[0].archived = true
            try require(archived.balance(source.id) == baseline.balance(source.id), "archiving presentation never erases balance")
            try require(try TaskBackup.decode(TaskBackup(finance: ledger, lists: [], tasks: []).encoded()).finance == ledger, "removed entities and cleared defaults survive backup round trip")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jianshi-removal-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let storage = try Store.make(url: dir.appendingPathComponent("Tasks.store"))
            try FinanceStore.stage(baseline, in: storage.mainContext); try Store.save(storage.mainContext)
            try FinanceStore.update(storage.mainContext) { try $0.remove(.account, id: source.id, expected: baseline) }
            let reopened = try Store.make(url: dir.appendingPathComponent("Tasks.store"))
            try require(try FinanceStore.read(reopened.mainContext)?.accounts == [destination], "account deletion persists after reopen")
        }
    }

    static func sampleCleanup(require: (Bool, String) throws -> Void) throws {
        do {
            var example = FinanceData.initial
            let original = example
            let book = try example.addSamples()
            try require(example.entries.count == 3 && example.accounts.count == 2 && example.books.last?.id == book, "Small sample book has two accounts and three entries")
            try require(example.accounts.map { example.balance($0.id) } == [962, 212], "Sample balances include income and spending")
            try require(example.books.last?.defaultAccountID == example.accounts.last?.id && example.categories.last?.parentID == example.categories.dropLast().last?.id, "Samples demonstrate default USD account and child category")
            let once = example
            try require(try example.addSamples() == book && example == once, "Adding samples twice never duplicates them")
            try require(example.rates == original.rates && example.books.first == original.books.first, "Examples do not change real rates or book defaults")
            let clean = example.removeSamples(); try example.validate()
            try require(clean.entries == 3 && clean.categories == 2 && example == original, "Clearing untouched samples restores the exact original ledger")
            _ = try example.addSamples()
            let retainedCategory = example.categories.last!.id
            var own = MoneyEntry(); own.title = "My real entry"; own.amount = 5; own.currency = "CNY"; own.baseAmount = 5
            own.bookID = original.books[0].id; own.categoryID = retainedCategory
            example.entries.append(own); _ = example.removeSamples(); try example.validate()
            try require(example.entries == [own] && example.categories.contains { $0.id == retainedCategory }, "Clearing examples preserves categories used by a surviving real entry")
        }
    }

    static func bankLabelsAndCategories(oldJSON: String, require: (Bool, String) throws -> Void, rejects: (String, () throws -> Void) throws -> Void) throws {
        // Bank labels and two-level categories retain old backups and preserve historical postings.
        do {
            let old = try JSONDecoder().decode(FinanceData.self, from: Data(oldJSON.utf8))
            try require(old.accounts.allSatisfy { $0.bankName == nil } && old.categories.allSatisfy { $0.parentID == nil }, "old finance data defaults bank and parent to nil")
            var ledger = FinanceData.initial
            let account = MoneyAccount(name: "Daily card", type: "debit", bankName: "招商银行")
            ledger.accounts = [account]
            var parent = MoneyCategory(name: "Household", income: false)
            var child = MoneyCategory(name: "Groceries", income: false, parentID: parent.id)
            try ledger.updateCategory(parent, expected: nil); try ledger.updateCategory(child, expected: nil)
            try ledger.validate()
            try require(ledger.rootCategoryID(child.id) == parent.id && ledger.categoryPath(child.id) == "Household / Groceries", "subcategory paths and root IDs resolve")
            try require(ledger.categoryIDs(including: parent.id) == Set([parent.id, child.id]) && ledger.categoryIDs(including: child.id) == [child.id], "parent filter includes children and child filter stays narrow")
            let good = ledger
            var missing = child; missing.parentID = UUID()
            try rejects("missing parent is rejected") { try ledger.updateCategory(missing, expected: child) }
            var cycle = parent; cycle.parentID = child.id
            try rejects("cycles and parent nesting are rejected") { try ledger.updateCategory(cycle, expected: parent) }
            var wrongType = child; wrongType.income = true
            try rejects("child income type must match parent") { try ledger.updateCategory(wrongType, expected: child) }
            try rejects("third level is rejected") { try ledger.updateCategory(MoneyCategory(name: "Third level", income: false, parentID: child.id), expected: nil) }
            var sameName = child; sameName.id = UUID()
            try rejects("duplicate sibling names rejected") { try ledger.updateCategory(sameName, expected: nil) }
            try require(ledger == good, "invalid category edits are atomic")
            try rejects("parent with children cannot be deleted") { try ledger.remove(.category, id: parent.id, expected: good) }
            var expense = MoneyEntry(); expense.title = "Groceries"; expense.bookID = ledger.books[0].id; expense.categoryID = child.id; expense.amount = 100; expense.baseAmount = 100
            var refund = expense; refund.id = UUID(); refund.kind = .refund; refund.refundOf = expense.id; refund.amount = 20; refund.baseAmount = 20
            ledger.entries = [expense, refund]; try ledger.validate()
            try require(ledger.csv(ledger.entries).contains("Household / Groceries") && ledger.searchText(for: expense).contains("Household"), "CSV and search preserve the full category path")
            try require(ledger.byCategory(ledger.entries, income: false).rows.first?.id == .category(parent.id) && ledger.byCategory(ledger.entries, income: false).rows.first?.total == 80, "parent category aggregates child expense and refund exactly once")
            let drill = MoneyDrilldown(range: DateInterval(start: expense.date.addingTimeInterval(-1), duration: 10), key: .category(parent.id), income: false)
            try require(drill.matches(expense, data: ledger) && drill.matches(refund, data: ledger), "parent drill-down includes child expense and refund")
            var exactRoot = drill; exactRoot.includeSubcategories = false
            try require(!exactRoot.matches(expense, data: ledger) && !exactRoot.matches(refund, data: ledger), "No subcategory drill-down excludes child postings")
            try require(!MoneyCategoryKey.category(nil).includes(expense, income: false, data: ledger) && !MoneyCategoryKey.category(parent.id).includes(refund, income: true, data: ledger), "uncategorized and income filters remain distinct")
            let active = parent; parent.archived = true; try ledger.updateCategory(parent, expected: active)
            try require(ledger.categories.first { $0.id == child.id }?.archived == true && ledger.byCategory(ledger.entries, income: false).rows.first?.total == 80, "parent archival cascades and preserves statistics")
            let archivedChild = ledger.categories.first { $0.id == child.id }!
            try rejects("cannot enable a child under archived parent") { try ledger.updateCategory(child, expected: archivedChild) }
            let archivedParent = parent; parent.archived = false; try ledger.updateCategory(parent, expected: archivedParent)
            try require(ledger.categories.first { $0.id == child.id }?.archived == true, "unarchiving parent never unexpectedly enables children")
            try ledger.updateCategory(child, expected: archivedChild)
            let beforeRename = child; child.name = "Food shopping"; try ledger.updateCategory(child, expected: beforeRename)
            try rejects("stale category editor rejected") { try ledger.updateCategory(beforeRename, expected: beforeRename) }
            let captured = ledger
            try rejects("used child cannot be deleted") { try ledger.remove(.category, id: child.id, expected: captured) }
            try require(try TaskBackup.decode(TaskBackup(finance: ledger, lists: [], tasks: []).encoded()).finance == ledger, "bank label and category hierarchy survive portable backup")
            var invalid = ledger; invalid.accounts[0].bankName = String(repeating: "a", count: 81)
            try rejects("oversized bank label rejected") { try invalid.validate() }
            invalid = ledger; invalid.categories[invalid.categories.firstIndex { $0.id == child.id }!].parentID = child.id
            try rejects("imported cyclic category rejected") { try invalid.validate() }
        }
    }

    static func entryDefaults(require: (Bool, String) throws -> Void) throws {
        // The overview and entry editor share the same account/currency defaults, including old preferences.
        do {
            let keys = ["lastMoneyBook", "lastMoneyAccount"]
            let original = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            defer { for (key, value) in original { UserDefaults.standard.set(value, forKey: key) } }
            var ledger = FinanceData.initial
            let cny = MoneyAccount(name: "CNY"), usd = MoneyAccount(name: "USD", currency: "USD", opening: 10000)
            ledger.accounts = [cny, usd]; ledger.books[0].defaultAccountID = usd.id
            UserDefaults.standard.set(ledger.books[0].id.uuidString, forKey: "lastMoneyBook")
            UserDefaults.standard.set(cny.id.uuidString, forKey: "lastMoneyAccount")
            let defaults = ledger.entryDefaults(preferredBook: ledger.books[0].id)
            let entry = ledger.newEntry(preferredBook: ledger.books[0].id)
            try require(defaults.account?.id == usd.id && defaults.account?.currency == "USD" && entry.currency == "USD" && entry.accountID == usd.id, "book default USD overrides remembered CNY in both overview and entry")
            try require(ledger.entryDefaults(preferredBook: nil, preferredAccount: cny.id).account?.id == cny.id && ledger.newEntry(preferredBook: nil, preferredAccount: cny.id).currency == "CNY", "explicit active account overrides the book default")
            let shown = ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: nil)
            try require(shown?.id == usd.id && shown?.currency == "USD" && ledger.balance(shown!.id) == 10000, "empty book shows the existing asset balance in the account currency")
            try require(ledger.entries.isEmpty && ledger.totals(ledger.entries).income == 0, "showing opening funds never creates income or postings")
            try require(ledger.balanceAccount(bookID: nil, filteredAccountID: nil) == nil, "all-books overview cannot borrow a recent book's account")
            try require(ledger.balanceAccount(bookID: UUID(), filteredAccountID: nil) == nil, "missing book cannot fall back to remembered defaults")
            try require(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: cny.id)?.id == cny.id, "explicit account filter takes precedence over the book's default balance")
            try require(ledger.balanceAccount(bookID: nil, filteredAccountID: usd.id)?.id == usd.id, "all-books account filter shows the selected account")
            try require(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: UUID()) == nil, "stale account filter cannot show another account's balance")
            let otherBook = MoneyBook(name: "Other book", defaultAccountID: usd.id)
            ledger.books.append(otherBook)
            var spend = ledger.newEntry(preferredBook: otherBook.id)
            spend.amount = 50; spend.accountAmount = 50; spend.baseAmount = 350
            ledger.entries = [spend]
            try require(ledger.balance(shown!.id) == 9950 && ledger.entries.filter { $0.bookID == ledger.books[0].id }.isEmpty, "empty book balance reflects shared-account spending in another book")
            ledger.accounts[1].opening = 12000
            try require(ledger.balance(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: nil)!.id) == 11950, "asset opening-balance edits immediately feed the book overview")
            ledger.books[0].defaultAccountID = cny.id
            try require(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: nil)?.id == cny.id && ledger.balance(usd.id) == 11950, "changing a book default selects another balance without moving money")
            ledger.books[0].defaultAccountID = usd.id
            ledger.accounts[1].archived = true
            try require(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: nil) == nil, "archived default is unavailable rather than replaced with a remembered account")
            try require(ledger.balanceAccount(bookID: nil, filteredAccountID: usd.id)?.id == usd.id, "explicit historical account filter retains its archived account balance")
            try require(ledger.entryDefaults(preferredBook: nil).account == nil && ledger.newEntry(preferredBook: nil).accountID == nil, "an archived book default never silently charges the remembered account")
            ledger.books[0].defaultAccountID = nil
            try require(ledger.balanceAccount(bookID: ledger.books[0].id, filteredAccountID: nil) == nil, "book without an explicit default asks to choose one instead of showing a recent account")
            UserDefaults.standard.set("none", forKey: "lastMoneyAccount")
            try require(ledger.entryDefaults(preferredBook: nil).account == nil && ledger.newEntry(preferredBook: nil).currency == ledger.baseCurrency, "deliberate no-account choice retains the base currency")
            UserDefaults.standard.set(cny.id.uuidString, forKey: "lastMoneyAccount")
            try require(ledger.entryDefaults(preferredBook: nil, preferredAccount: usd.id).account?.id == cny.id, "an explicit archived account cannot override an available remembered account")
        }
    }

    static func hiddenPresetCategories(require: (Bool, String) throws -> Void) throws {
        // Removing preset categories from the picker must survive default upgrades and retain old entries.
        do {
            var ledger = FinanceData.initial
            let preset = ledger.categories.first { $0.name == "drinks" }!
            let child = MoneyCategory(name: "Morning coffee", parentID: preset.id)
            try ledger.updateCategory(child, expected: nil)
            var entry = MoneyEntry(); entry.title = "Coffee"; entry.amount = 25; entry.baseAmount = 25
            entry.bookID = ledger.books[0].id; entry.categoryID = child.id
            try ledger.updateEntry(entry, expected: nil, baseCurrency: ledger.baseCurrency)
            var archived = preset; archived.archived = true
            try ledger.updateCategory(archived, expected: preset)
            ledger = try JSONDecoder().decode(FinanceData.self, from: JSONEncoder().encode(ledger))
            ledger.addMissingDefaults()
            try ledger.validate()
            try require(ledger.categories.filter { $0.id == preset.id }.count == 1 && ledger.categories.first { $0.id == preset.id }?.archived == true,
                        "archived preset stays hidden after relaunch/default upgrade without duplication")
            try require(ledger.categories.first { $0.id == child.id }?.archived == true && ledger.entries == [entry],
                        "preset removal hides children while preserving their historical entries")
            try require(ledger.statisticsTotal(ledger.entries, income: false, in: "CNY", history: nil, days: nil).total == 25,
                        "archived preset entries remain included in totals")
            try ledger.updateCategory(preset, expected: archived)
            try require(ledger.categories.first { $0.id == child.id }?.archived == true,
                        "restoring a preset leaves individually archived children under user control")
        }
    }
}
