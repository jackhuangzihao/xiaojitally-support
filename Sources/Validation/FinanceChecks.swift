import Foundation
import SwiftData

@MainActor enum FinanceChecks {
    static func run() throws -> Int {
        var checks = try FinanceHome.checkViewFootprint()
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Finance: " + label) }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false; do { try action() } catch { rejected = true }; try require(rejected, label)
        }
        try FinanceConversionChecks.referenceRates(require: require, rejects: rejects)
        try CalendarChecks.emptyPlanSlots(require: require)
        var value = FinanceData.initial
        let bank = MoneyAccount(name: "Bank", opening: 10000), wallet = MoneyAccount(name: "Wallet"), aud = MoneyAccount(name: "AUD bank", currency: "AUD", opening: 200)
        let travel = MoneyBook(name: "Travel", defaultAccountID: bank.id)
        value.accounts = [bank, wallet, aud]; value.books.append(travel)
        func expense(_ amount: Decimal, book: UUID, account: MoneyAccount = bank) -> MoneyEntry {
            var e = MoneyEntry(); e.title = "Test entry"; e.amount = amount; e.currency = account.currency
            e.accountID = account.id; e.accountAmount = amount; e.bookID = book; e.baseAmount = account.currency == "CNY" ? amount : nil
            return e
        }
        let lunch = expense(50, book: value.books[0].id), hotel = expense(800, book: travel.id)
        value.entries = [lunch, hotel]; try value.validate()
        try require(value.balance(bank.id) == 9150, "shared account debited once across books")
        try require(value.totals(value.entries).expense == 850, "global expenses are not duplicated")
        value.entries[1].bookID = value.books[0].id
        try require(value.balance(bank.id) == 9150, "moving between books never changes balance")
        value.entries[1].amount = 600; value.entries[1].accountAmount = 600; value.entries[1].baseAmount = 600
        try require(value.balance(bank.id) == 9350, "editing amount reverses prior effect")
        value.entries[1].deletedAt = Date()
        try require(value.balance(bank.id) == 9950, "delete reverses impact")
        value.entries[1].deletedAt = nil
        try require(value.balance(bank.id) == 9350, "restore applies once")
        var transfer = expense(100, book: travel.id); transfer.kind = .transfer; transfer.destinationID = wallet.id; transfer.destinationAmount = 100; transfer.fee = 2; transfer.baseFee = 2
        value.entries.append(transfer); try value.validate()
        try require(value.balance(bank.id) == 9248 && value.balance(wallet.id) == 100, "transfer updates both sides with fee")
        try require(value.totals(value.entries).expense == 652 && value.totals(value.entries).income == 0, "only transfer fee is expense")
        var fx = transfer; fx.id = UUID(); fx.destinationID = aud.id; fx.destinationAmount = 20
        value.entries.append(fx); try value.validate()
        try require(value.balance(bank.id) == 9146 && value.balance(aud.id) == 220, "cross currency transfers use actual amounts")
        var foreign = expense(20, book: travel.id); foreign.currency = "AUD"; foreign.accountAmount = Decimal(string: "94.60")!; foreign.baseAmount = foreign.accountAmount
        value.entries.append(foreign); try value.validate()
        try require(value.balance(bank.id) == Decimal(string: "9051.40")!, "foreign spend uses bank settlement amount")
        var refund = foreign; refund.id = UUID(); refund.kind = .refund; refund.refundOf = foreign.id; refund.amount = 5; refund.accountAmount = 24; refund.baseAmount = 24; refund.date = foreign.date.addingTimeInterval(1)
        value.entries.append(refund); try value.validate()
        try require(value.balance(bank.id) == Decimal(string: "9075.40")!, "partial refund credited to account")
        try require(value.totals(value.entries).refunds == 24 && value.totals(value.entries).income == 0, "refund reduces expense, not income")
        let bankFlow = value.accountFlow(bank.id, in: value.entries)
        try require(bankFlow.incoming == 24 && bankFlow.outgoing == Decimal(string: "948.60")!, "account cash flow includes transfer principal and source fees, plus refunds")
        try require(bank.opening + bankFlow.incoming - bankFlow.outgoing == value.balance(bank.id), "opening plus account net movement equals balance across all books")
        try require(value.accountFlow(aud.id, in: value.entries).incoming == 20 && value.accountFlow(aud.id, in: value.entries).outgoing == 0, "destination sees the actual foreign amount without the sender fee")
        try require(fx.accountChange(for: aud.id) == 20 && fx.accountChange(for: bank.id) == -102 && fx.accountChange(for: wallet.id) == 0, "transfer rows show each account's own sign and currency amount")
        try require(foreign.accountChange(for: bank.id) == Decimal(string: "-94.60")!, "foreign purchase account view uses settled amount")
        do {
            var ledger = FinanceData.initial; ledger.accounts = [bank, wallet]
            let cal = Dates.calendar
            func day(_ year: Int, _ month: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: year, month: month, day: day))! }
            let start = day(2026, 9, 1), end = day(2026, 10, 1)
            var before = lunch; before.id = UUID(); before.date = start.addingTimeInterval(-1)
            var inside = transfer; inside.id = UUID(); inside.date = start
            var outside = lunch; outside.id = UUID(); outside.date = end
            var credit = refund; credit.id = UUID(); credit.date = end.addingTimeInterval(-1)
            var removed = lunch; removed.id = UUID(); removed.deletedAt = start; removed.date = start
            var adjust = lunch; adjust.id = UUID(); adjust.kind = .adjustment; adjust.accountAmount = -7; adjust.date = start
            ledger.entries = [before, inside, outside, credit, removed, adjust]
            let selected = ledger.entries.filter { $0.date >= start && $0.date < end }
            let flow = ledger.accountFlow(bank.id, in: selected)
            try require(flow.incoming == 24 && flow.outgoing == 109, "period flow excludes deleted entries and includes negative adjustments")
            try require(ledger.balance(bank.id, before: start) == 9950 && ledger.balance(bank.id, before: end) == 9865, "period balances use exclusive boundaries and include opening funds")
            try require(ledger.balance(bank.id, before: start) + flow.incoming - flow.outgoing == ledger.balance(bank.id, before: end), "period opening and closing reconcile exactly")
            let custom = MoneyDateRange.custom.interval(at: day(2026, 9, 30), through: day(2026, 10, 2), calendar: cal)!
            try require(custom.start == day(2026, 9, 30) && custom.end == day(2026, 10, 3), "custom dates include the entire last day across month boundaries")
            try require(MoneyDateRange.custom.interval(at: day(2026,10,2), through: day(2026,9,30), calendar: cal) == custom, "custom date bounds normalize reversed inputs")
            try require(MoneyDateRange.all.interval(at: start, through: end, calendar: cal) == nil, "all dates has no hidden monthly limit")
            try require(MoneyDateRange.month.interval(at: start, through: end, calendar: cal) == DateInterval(start: start, end: end), "monthly range remains compatible")
            let week = MoneyDateRange.week.interval(at: day(2026,9,30), through: end, calendar: cal)!
            try require(week.start == day(2026,9,28) && week.end == day(2026,10,5), "week range crosses month boundaries")
            try require(MoneyDateRange.year.interval(at: start, through: end, calendar: cal)?.end == day(2027,1,1), "year range includes all months")
            try require(MoneyDateRange.day.interval(at: start, through: end, calendar: cal)?.end == day(2026,9,2), "day range includes one complete local day")
        }
        var bad = value; bad.entries[bad.entries.count-1].amount = 21
        try rejects("excess refunds rejected") { try bad.validate() }
        bad = value; bad.entries[bad.entries.count-2].deletedAt = Date()
        try rejects("expense cannot disappear while refund remains live") { try bad.validate() }
        bad = value; bad.entries[2].destinationID = bank.id
        try rejects("self transfers rejected") { try bad.validate() }
        bad = value; bad.entries[2].destinationAmount = 99
        try rejects("same currency mismatched transfer rejected") { try bad.validate() }
        bad = value; bad.entries[0].accountID = UUID()
        try rejects("missing accounts rejected") { try bad.validate() }
        bad = value; bad.accounts.append(bank)
        try rejects("duplicate account ids rejected") { try bad.validate() }
        try rejects("overprecision rejected") { _ = try Money.parse("0.001", currency: "CNY") }
        try rejects("yen fractions rejected") { _ = try Money.parse("1.5", currency: "JPY") }
        try rejects("scientific or partial parsing rejected") { _ = try Money.parse("10garbage", currency: "CNY") }
        try rejects("nan rejected") { _ = try Money.parse("NaN", currency: "CNY") }
        let tenCents = try Money.parse("0.1", currency: "CNY")
        try require((0..<1000).reduce(Decimal(0)) { n, _ in n + tenCents } == 100, "decimal sums are exact")
        try require(Money.round(Decimal(string: "94.605")!, currency: "CNY") == Decimal(string: "94.61")!, "settlement rounding follows currency precision")
        var unassigned = lunch; unassigned.id = UUID(); unassigned.accountID = nil; unassigned.accountAmount = 0
        value.entries.append(unassigned); try value.validate()
        try require(value.balance(bank.id) == Decimal(string: "9075.40")!, "unassigned expense does not change accounts")
        var missing = expense(20, book: travel.id, account: aud); missing.baseAmount = nil
        value.entries.append(missing); try value.validate()
        try require(value.totals(value.entries).missing == 1, "missing conversion never treated as 1 to 1")
        value.rates = [MoneyRate(base: "AUD", quote: "CNY", rate: Decimal(string: "4.8")!, date: "2026-09-25")]
        let fixed = value.totals(value.entries).expense
        try require(value.converted(10, from: "AUD", to: "CNY") == 48, "reference conversion")
        value.rates[0].rate = 5
        try require(value.totals(value.entries).expense == fixed, "rate refresh cannot change historical totals")
        let encoded = try JSONEncoder().encode(value)
        try require(try JSONDecoder().decode(FinanceData.self, from: encoded) == value, "ledger round trip preserves exact money")
        try require(try value.merging(value) == value, "same backup merge is idempotent")
        bad = value; bad.entries[0].title = "Changed"
        try rejects("conflicting records rejected before merge") { _ = try value.merging(bad) }
        var unsafe = lunch; unsafe.title = "=HYPERLINK(\"url\")"; unsafe.notes = "line1\nline2,comma"; unsafe.tags = "@formula"
        let csv = value.csv([unsafe])
        try require(csv.contains("'=HYPERLINK") && csv.contains("'@formula") && csv.contains("line1\nline2,comma"), "CSV quotes multiline text and protects formulas")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jianshi-finance-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Tasks.store")
        let container = try Store.make(url: url), context = container.mainContext
        let task = TaskItem(title: "Linked task"); context.insert(task)
        value.entries[0].taskID = task.id
        try FinanceStore.stage(value, in: context); try Store.save(context)
        try require(try FinanceStore.read(context) == value, "persistent ledger saved alongside task")
        try FinanceDataChecks.readCache(context: context, value: value, require: require, rejects: rejects)
        var lightweight = try TaskBackup.capture(context, includeFinance: false)
        try require(lightweight.finance == nil, "automatic backup capture does not decode finance on main thread")
        lightweight.finance = try FinanceStore.payload(context).map { try JSONDecoder().decode(FinanceData.self, from: $0) }
        try require(try TaskBackup.decode(lightweight.encoded()).finance == value, "background-decoded ledger joins the full portable backup")
        let before = try TaskBackup.capture(context)
        try require(before.version == 10 && before.finance == value, "full backup contains finance")
        let backup = try TaskBackup.decode(before.encoded())
        try require(backup.finance == value, "portable backup exact round trip")
        let fresh = try Store.make(url: directory.appendingPathComponent("Restored.store"))
        try backup.restore(fresh.mainContext, replace: true)
        try require(try FinanceStore.read(fresh.mainContext) == value, "full restore includes both sides of transfers")
        try backup.restore(fresh.mainContext, replace: false)
        try require(try FinanceStore.read(fresh.mainContext) == value, "repeat import never duplicates transactions")
        var legacy = TaskBackup(lists: [], tasks: []); legacy.version = 5
        try legacy.restore(fresh.mainContext, replace: true)
        try require(try FinanceStore.read(fresh.mainContext) == value, "old task-only replacement preserves finance")
        let reopened = try Store.make(url: url)
        try require(try FinanceStore.read(reopened.mainContext) == value, "balances survive database reopen")
        context.delete(task); try Store.save(context)
        try require(try FinanceStore.read(context) == value, "deleting task cannot cascade to entries")
        let old = value.entries[0]; var edit = old; edit.title = "Edited"
        try FinanceStore.put(edit, expected: old, baseCurrency: "CNY", in: context)
        try rejects("stale editor cannot overwrite newer entry") { try FinanceStore.put(old, expected: old, baseCurrency: "CNY", in: context) }
        let saved = try FinanceStore.read(context)
        try rejects("invalid update leaves stored ledger unchanged") { try FinanceStore.update(context) { $0.entries[0].amount = -100 } }
        try require(try FinanceStore.read(context) == saved, "validation fails before mutation")
        // A transaction with both account effects is encoded in one record and one context save.
        try require(!context.hasChanges, "failed validation leaves no dirty persistent state")
        try rejects("new foreign account rejects an invalid initial rate atomically") {
            try FinanceStore.update(context) { ledger in
                try ledger.updateAccount(MoneyAccount(name: "Invalid rate card", currency: "USD", opening: 100, bankName: "HSBC"), expected: nil)
                try ledger.setManualRate(from: "USD", to: "CNY", text: "0")
            }
        }
        try require(try FinanceStore.read(context) == saved && !context.hasChanges, "failed initial rate leaves no half-created card or balance")
        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
        readOnly.mainContext.autosaveEnabled = false
        try rejects("failed transfer cannot persist one side") {
            try FinanceStore.update(readOnly.mainContext) { ledger in var e = transfer; e.id = UUID(); ledger.entries.append(e) }
        }
        try require(Store.recovery.failure != nil && Store.recovery.reload(), "failed money save can recover without restart")
        try require(try FinanceStore.read(Store.recovery.container!.mainContext) == saved, "failed transfer preserves both balances on disk")
        let legacyURL = directory.appendingPathComponent("Legacy.store")
        try autoreleasepool {
            let oldSchema = Schema([TaskItem.self, TaskList.self])
            let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: legacyURL, cloudKitDatabase: .none)])
            old.mainContext.insert(TaskItem(title: "Before bookkeeping")); try old.mainContext.save()
        }
        let upgraded = try Store.make(url: legacyURL)
        try require(try upgraded.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == "Before bookkeeping", "adding ledger schema preserves preexisting tasks")
        try require(try FinanceStore.read(upgraded.mainContext) == nil, "upgrading creates no fictional transactions")
        try FinanceDataChecks.amountInput(require: require)
        let oldJSON = #"{"version":1,"baseCurrency":"CNY","accounts":[{"id":"00000000-0000-0000-0000-00000000000A","name":"支付宝","currency":"CNY","opening":1000,"archived":false}],"books":[{"id":"00000000-0000-0000-0000-00000000000B","name":"日常","archived":false}],"categories":[{"id":"00000000-0000-0000-0000-00000000000C","name":"salary","symbol":"banknote","archived":false},{"id":"00000000-0000-0000-0000-00000000000D","name":"food","symbol":"fork.knife","archived":false}],"entries":[],"rates":[]}"#
        let legacyLedger = try FinanceDataChecks.legacyDefaults(oldJSON: oldJSON, require: require, rejects: rejects)
        try FinanceDataChecks.statisticsBreakdown(require: require)
        try require(legacyLedger.accounts.allSatisfy { $0.emoji == nil && $0.symbol == nil } && legacyLedger.books.allSatisfy { $0.emoji == nil && $0.symbol == nil }, "old backups decode optional account and book icons")
        try FinanceDataChecks.portableIcons(value: value, bank: bank, fresh: fresh, directory: directory, require: require, rejects: rejects)
        try FinancePostingChecks.reconciliation(require: require, rejects: rejects)
        do {
            var ledger = value
            let moved = ledger.copyEntry(fx, at: Date())
            try require(moved.id != fx.id && moved.accountID == fx.accountID && moved.destinationID == fx.destinationID && moved.amount == fx.amount, "copy keeps transfer identity fields but gets a fresh entry id")
            try require(moved.destinationAmount == 0 && moved.accountAmount == 0 && moved.baseAmount == nil && moved.rateNote.isEmpty, "base-currency to foreign-account copy clears historical conversion amounts")
            let copiedForeign = ledger.copyEntry(foreign)
            try require(copiedForeign.accountAmount == 0 && copiedForeign.baseAmount == nil && copiedForeign.refundOf == nil && copiedForeign.taskID == nil, "foreign expense copy clears locked rates and old associations")
            let copiedSame = ledger.copyEntry(lunch)
            try require(copiedSame.amount == lunch.amount && copiedSame.accountAmount == lunch.accountAmount, "same-currency copy remains convenient")
            let fee4 = Money.rescaledText("10", recorded: 10, previous: nil, from: 2, to: 4, currency: "CNY")
            try require(fee4 == "20", "foreign fee edit follows the recorded exchange rate")
            try require(Money.rescaledText("20", recorded: 10, previous: fee4, from: 2, to: 6, currency: "CNY") == "30", "consecutive fee edits use the original ratio without compounding")
            try require(Money.rescaledText("12", recorded: 10, previous: nil, from: 2, to: 4, currency: "CNY") == nil, "manually overridden fee conversion is preserved")
            try require(Money.rescaledText("10", recorded: 10, previous: nil, from: 0, to: 4, currency: "CNY") == nil, "adding the first fee cannot invent a historical rate")
            try require(Money.rescaledText("10", recorded: 10, previous: nil, from: 2, to: 0, currency: "CNY") == "0", "clearing fees also clears the calculated conversion")
            try require(Money.rescaledText("1", recorded: 1, previous: nil, from: 3, to: 2, currency: "CNY") == "0.67", "recorded scaling respects currency rounding")
            var feeTransfer = fx; feeTransfer.currency = "AUD"; feeTransfer.accountID = aud.id; feeTransfer.destinationID = bank.id; feeTransfer.amount = 10; feeTransfer.accountAmount = 10; feeTransfer.destinationAmount = 50; feeTransfer.fee = 4; feeTransfer.baseFee = Decimal(string: fee4!)!; feeTransfer.baseAmount = nil
            var own = FinanceData.initial; own.accounts = [bank, aud]; feeTransfer.bookID = own.books[0].id; own.entries = [feeTransfer]; try own.validate()
            try require(own.totals(own.entries).expense == 20 && own.balance(aud.id) == 186, "updated fee affects both account and reporting totals")
            ledger.accounts[0].archived = true
            ledger.books[0].defaultAccountID = bank.id
            try require(ledger.defaultAccount(for: ledger.books[0].id) == nil && ledger.defaultAccount(for: travel.id) == nil, "archived defaults cannot seed a new entry in any book")
            try rejects("new entries cannot debit an archived account") { try ledger.checkAccounts(for: lunch, replacing: nil) }
            try ledger.checkAccounts(for: lunch, replacing: lunch)
            try require(ledger.allowsAccount(bank.id, for: lunch, replacing: lunch), "existing archived-account entries remain editable")
            try ledger.checkAccounts(for: refund, replacing: nil)
            try require(ledger.allowsAccount(bank.id, for: refund, replacing: nil), "linked refunds may settle the original archived account")
            let copiedArchived = ledger.copyEntry(lunch)
            try require(copiedArchived.accountID == nil && copiedArchived.accountAmount == 0, "copying an archived-account entry requires account selection")
            ledger.accounts[2].archived = true
            let copiedTransfer = ledger.copyEntry(fx)
            try require(copiedTransfer.accountID == nil && copiedTransfer.destinationID == nil, "copying transfer removes archived accounts on both ends")
            var unrelatedRefund = refund; unrelatedRefund.accountID = aud.id
            try rejects("refunds cannot choose an unrelated archived account") { try ledger.checkAccounts(for: unrelatedRefund, replacing: nil) }
            var searchableTransfer = fx; searchableTransfer.title = "Transfer"; searchableTransfer.notes = ""; searchableTransfer.tags = ""
            try require(ledger.searchText(for: searchableTransfer).contains("AUD bank") && ledger.searchText(for: searchableTransfer).contains("Bank"), "search includes receiving and sending accounts even when absent from the title")
            try require(fx.matches(bookID: travel.id, accountID: bank.id) && fx.matches(bookID: travel.id, accountID: aud.id), "book/account intersection includes both transfer ends")
            try require(!lunch.matches(bookID: travel.id, accountID: bank.id), "selecting an account cannot leak entries from another book")
            try require(lunch.matches(bookID: nil, accountID: bank.id), "asset account detail intentionally includes every book")
            let bankRunning = value.runningBalances(bank.id), audRunning = value.runningBalances(aud.id)
            try require(bankRunning[fx.id] != nil && audRunning[fx.id] != nil, "running balance includes the same transfer on both account sides")
        }
        try FinanceDataChecks.budgets(require: require)
        try FinanceConversionChecks.budgetRates(require: require)
        try FinanceDataChecks.categoryHistory(require: require)
        try FinanceDataChecks.entityRemoval(require: require, rejects: rejects)
        try FinanceConversionChecks.refreshedEstimatesAndRefunds(require: require)
        try FinancePostingChecks.openingBalanceChanges(require: require, rejects: rejects)
        try FinancePostingChecks.refundCurrencies(require: require, rejects: rejects)
        try FinancePostingChecks.expenseDeletionAndBudgets(require: require, rejects: rejects)
        try FinanceDataChecks.sampleCleanup(require: require)
        try FinanceConversionChecks.historicalStatistics(require: require)
        try FinancePostingChecks.deletionBatches(directory: directory, require: require)
        try FinanceConversionChecks.partialRateCoverage(require: require)
        try FinanceDataChecks.bankLabelsAndCategories(oldJSON: oldJSON, require: require, rejects: rejects)
        try FinanceDataChecks.entryDefaults(require: require)
        try FinanceConversionChecks.reportingCurrency(context: context, require: require, rejects: rejects)
        try FinanceConversionChecks.assetDisplayCurrency(require: require, rejects: rejects)
        try FinanceConversionChecks.assetRateEdits(require: require, rejects: rejects)
        try FinanceConversionChecks.netWorth(require: require, rejects: rejects)
        try FinanceConversionChecks.historicalRateFill(require: require, rejects: rejects)
        try FinancePostingChecks.offlineEstimatesAndSaves(require: require, rejects: rejects)
        try FinancePostingChecks.editorActualAmounts(require: require, rejects: rejects)
        try FinanceDataChecks.hiddenPresetCategories(require: require)
        try FinancePostingChecks.postedEntryEdits(require: require, rejects: rejects)
        try FinancePostingChecks.entryCategories(require: require, rejects: rejects)
        try FinancePostingChecks.accountActions(require: require, rejects: rejects)
        try FinancePostingChecks.pendingEntries(directory: directory, require: require, rejects: rejects)
        print("FINANCE PASS: \(checks) checks — accounts, books, transfers, refunds, FX, backup and persistence")
        return checks
    }
}
