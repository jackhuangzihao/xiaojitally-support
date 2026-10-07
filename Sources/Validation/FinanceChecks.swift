import Foundation
import SwiftData

@MainActor enum FinanceChecks {
    #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
    static func seedUI() throws {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("local.jianshi.sandboxcheck.finance") else { throw TaskBackup.invalid("UI fixture requires a disposable sandbox identity") }
        #if os(macOS)
        guard NSHomeDirectory().contains("/Containers/" + id + "/Data") else { throw TaskBackup.invalid("UI fixture requires a disposable Mac sandbox") }
        #else
        guard NSHomeDirectory().contains("/CoreSimulator/Devices/"), NSHomeDirectory().contains("/Containers/Data/Application/") else { throw TaskBackup.invalid("UI fixture requires a disposable iOS simulator sandbox") }
        #endif
        let container = try Store.make(), context = container.mainContext
        guard try FinanceStore.read(context) == nil, try context.fetch(FetchDescriptor<TaskItem>()).isEmpty else { throw TaskBackup.invalid("Fixture requires an empty store") }
        var ledger = FinanceData.initial
        let bank = MoneyAccount(name: "日常银行卡", opening: 10000, type: "debit", bankName: "招商银行"), aud = MoneyAccount(name: "commonwealth", currency: "AUD", opening: 4000, type: "debit", bankName: "Commonwealth Bank")
        let travel = MoneyBook(name: "澳洲旅行", defaultAccountID: bank.id)
        ledger.books[0].budget = 1000; ledger.books[0].emoji = "🏠"
        ledger.accounts = [bank, aud]; ledger.books.append(travel)
        var lunch = MoneyEntry(); lunch.title = "午餐"; lunch.amount = 50; lunch.accountAmount = 50; lunch.baseAmount = 50; lunch.accountID = bank.id; lunch.bookID = ledger.books[0].id; lunch.categoryID = ledger.categories[0].id
        var hotel = lunch; hotel.id = UUID(); hotel.title = "预订酒店"; hotel.amount = 800; hotel.accountAmount = 800; hotel.baseAmount = 800; hotel.bookID = travel.id; hotel.categoryID = ledger.categories[4].id
        var transfer = lunch; transfer.id = UUID(); transfer.title = "转入澳元账户"; transfer.kind = .transfer
        transfer.amount = 100; transfer.accountAmount = 100; transfer.baseAmount = 100; transfer.destinationID = aud.id; transfer.destinationAmount = 20; transfer.fee = 2; transfer.baseFee = 2; transfer.categoryID = nil
        var income = lunch; income.id = UUID(); income.title = "上月收入"; income.kind = .income; income.amount = 500; income.accountAmount = 500; income.baseAmount = 500
        income.date = Dates.calendar.date(byAdding: .month, value: -1, to: Date())!
        ledger.entries = [lunch, hotel, transfer, income]
        var foreignFee = transfer; foreignFee.id = UUID(); foreignFee.title = "验收：外币手续费"; foreignFee.currency = "AUD"
        foreignFee.accountID = aud.id; foreignFee.destinationID = bank.id; foreignFee.amount = 10; foreignFee.accountAmount = 10
        foreignFee.destinationAmount = 50; foreignFee.fee = 2; foreignFee.baseFee = 10; foreignFee.baseAmount = nil
        ledger.entries.append(foreignFee)

        let empty = MoneyAccount(name: "验收：空账户", opening: 10)
        ledger.accounts += [empty, MoneyAccount(name: "验收：已归档账户", opening: 30, archived: true)]
        ledger.books.append(MoneyBook(name: "验收：空账本", defaultAccountID: empty.id))
        ledger.categories.append(MoneyCategory(name: "验收：自建分类"))
        var fullRefund = lunch; fullRefund.id = UUID(); fullRefund.kind = .refund; fullRefund.title = "验收：全额退款"; fullRefund.refundOf = lunch.id
        ledger.entries.append(fullRefund)
        let secondAUD = MoneyAccount(name: "验收：第二澳元账户", currency: "AUD", opening: 1000)
        ledger.accounts.append(secondAUD)
        var historicalAUD = lunch; historicalAUD.id = UUID(); historicalAUD.title = "验收：历史澳元支出"
        historicalAUD.currency = "AUD"; historicalAUD.amount = 100; historicalAUD.accountAmount = 100
        historicalAUD.accountID = aud.id; historicalAUD.baseAmount = 500
        ledger.entries.append(historicalAUD)
        let usd = MoneyAccount(name: "美元账户", currency: "USD", opening: 500, type: "debit", bankName: "HSBC")
        ledger.accounts.append(usd)
        var sampleCoffee = lunch; sampleCoffee.id = UUID(); sampleCoffee.title = "示例 · 咖啡"; sampleCoffee.currency = "USD"
        sampleCoffee.date = MoneyEntry.timestamp(Date()); sampleCoffee.amount = 10; sampleCoffee.accountAmount = 10
        sampleCoffee.accountID = usd.id; sampleCoffee.baseAmount = nil
        var sampleIncome = sampleCoffee; sampleIncome.id = UUID(); sampleIncome.title = "示例 · 收入"; sampleIncome.kind = .income
        sampleIncome.amount = 120; sampleIncome.accountAmount = 120; sampleIncome.categoryID = nil
        var oldCoffee = sampleCoffee; oldCoffee.id = UUID(); oldCoffee.title = "验收：历史未折算支出"
        oldCoffee.date = Dates.calendar.date(byAdding: .month, value: -2, to: sampleCoffee.date)!
        ledger.entries += [sampleCoffee, sampleIncome, oldCoffee]
        let groceries = MoneyCategory(name: "超市买菜", symbol: "basket", income: false, parentID: ledger.categories[0].id)
        ledger.categories.append(groceries); ledger.entries[0].categoryID = groceries.id
        for i in ledger.entries.indices where ledger.entries[i].refundOf == lunch.id { ledger.entries[i].categoryID = groceries.id }
        ledger.books[0].defaultAccountID = usd.id
        try ledger.setManualRate(from: "USD", to: "CNY", text: "7.1")
        try ledger.mergeReferenceRates([MoneyRate(base: "AUD", quote: "CNY", rate: Decimal(string: "4.7")!, date: ExchangeRates.dayString(Date()))])
        UserDefaults.standard.set(false, forKey: "moneyAutoRates")
        try FinanceStore.stage(ledger, in: context)
        let day = Dates.calendar.startOfDay(for: Date())
        let task = TaskItem(title: "验收：已有任务", scheduledAt: day.addingTimeInterval(15 * 3600)); task.hasTime = true; task.endAt = day.addingTimeInterval(16 * 3600)
        context.insert(task)
        let thursday = Dates.calendar.date(byAdding: .day, value: 3, to: Dates.calendar.dateInterval(of: .weekOfYear, for: Date())!.start)!
        let repeated = TaskItem(title: "验收：每日重复", scheduledAt: thursday.addingTimeInterval(13.5 * 3600))
        repeated.hasTime = true; repeated.endAt = thursday.addingTimeInterval(17.5 * 3600); repeated.isDone = true; repeated.completedAt = Date(); repeated.repeatRule = "daily"
        let stale = TaskItem(title: "验收：旧的独立记录", scheduledAt: Dates.calendar.date(byAdding: .day, value: -15, to: thursday)!)
        repeated.nextOccurrenceID = stale.id; context.insert(repeated); context.insert(stale)
        try Store.save(context)
        print("UI fixture created in disposable sandbox")
    }
    #endif

    static func run() throws -> Int {
        var checks = try FinanceHome.checkViewFootprint()
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("Finance: " + label) }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var rejected = false; do { try action() } catch { rejected = true }; try require(rejected, label)
        }
        let xml = Data("<Cube><Cube time='2026-09-25'><Cube currency='AUD' rate='1.6'/><Cube currency='CNY' rate='8'/></Cube><Cube time='2026-09-24'><Cube currency='AUD' rate='2'/><Cube currency='CNY' rate='8'/></Cube></Cube>".utf8)
        let reference = try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY", "EUR"], onOrBefore: "2026-09-27")
        try require(reference.first { $0.quote == "CNY" }?.rate == 5 && reference.first?.date == "2026-09-25", "weekend rates use most recent published day, cross rates exact")
        try require(try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY"], onOrBefore: "2026-09-24").first?.rate == 4, "historical conversion never uses a later rate")
        try rejects("missing historical rates are not fabricated") { _ = try ExchangeRates.parse(xml, base: "AUD", quotes: ["CNY"], onOrBefore: "2026-01-01") }
        try rejects("unsupported rate is not 1 to 1") { _ = try ExchangeRates.parse(xml, base: "AUD", quotes: ["USD"], onOrBefore: "2026-09-25") }
        do {
            let instant = ISO8601DateFormatter().date(from: "2026-10-01T00:30:00Z")!
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "2026-10-01", "rate day uses the local calendar date")
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-09-30", "cached rate formatter follows time zone changes across midnight")
            try require(ExchangeRates.dayString(instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "2026-10-01", "returning to an earlier time zone cannot retain a stale rate day")
        }
        let layout = TimelineLayout.make(blocks: [], fullDay: true, density: 0.5, nowMinute: nil)
        let occupied = [CGRect(x: 144, y: layout.y(600), width: 98, height: layout.intervalHeight(from: 600, to: 660))]
        try require(PlanSlot.emptyPoint(CGPoint(x: 150, y: layout.y(720)), column: 100, gutter: 44, layout: layout, occupied: occupied) == PlanSlot(day: 1, minute: 720), "double click maps to clicked day and quarter hour")
        try require(PlanSlot.emptyPoint(CGPoint(x: 150, y: layout.y(620)), column: 100, gutter: 44, layout: layout, occupied: occupied) == nil, "double click on an existing card never creates another task")
        try require(PlanSlot.emptyPoint(CGPoint(x: 20, y: 100), column: 100, gutter: 44, layout: layout, occupied: []) == nil, "time labels are not creation targets")
        try require(PlanSlot.emptyPoint(CGPoint(x: 750, y: 100), column: 100, gutter: 44, layout: layout, occupied: []) == nil, "trailing week navigation is not a creation target")
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
        var lightweight = try TaskBackup.capture(context, includeFinance: false)
        try require(lightweight.finance == nil, "automatic backup capture does not decode finance on main thread")
        lightweight.finance = try FinanceStore.payload(context).map { try JSONDecoder().decode(FinanceData.self, from: $0) }
        try require(try TaskBackup.decode(lightweight.encoded()).finance == value, "background-decoded ledger joins the full portable backup")
        let before = try TaskBackup.capture(context)
        try require(before.version == 7 && before.finance == value, "full backup contains finance")
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
        // 0.2.1: keypad amounts, symbols, income categories, colors, account types and budgets.
        try require(Money.evaluate("12.5+8−3", currency: "CNY") == Decimal(string: "17.5") && Money.evaluate("12+", currency: "CNY") == 12, "keypad sums and ignores a trailing operator")
        try require(Money.evaluate("5−8", currency: "CNY") == nil && Money.evaluate("1.234", currency: "CNY") == nil && Money.evaluate("1.5", currency: "JPY") == nil, "keypad rejects negatives and excess decimals")
        try require(Money.evaluate("−20", currency: "CNY", signed: true) == -20 && Money.evaluate("−20", currency: "CNY") == nil, "only balance entry accepts a negative amount")
        try require(Money.format(1234.5, "CNY").hasPrefix("¥") && Money.format(-3, "AUD").hasPrefix("-A$") && Money.format(5, "JPY").hasPrefix("JP¥"), "amounts show symbols, yen distinct from yuan")
        let oldJSON = #"{"version":1,"baseCurrency":"CNY","accounts":[{"id":"00000000-0000-0000-0000-00000000000A","name":"支付宝","currency":"CNY","opening":1000,"archived":false}],"books":[{"id":"00000000-0000-0000-0000-00000000000B","name":"日常","archived":false}],"categories":[{"id":"00000000-0000-0000-0000-00000000000C","name":"salary","symbol":"banknote","archived":false},{"id":"00000000-0000-0000-0000-00000000000D","name":"food","symbol":"fork.knife","archived":false}],"entries":[],"rates":[]}"#
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
        try require(legacyLedger.accounts.allSatisfy { $0.emoji == nil && $0.symbol == nil } && legacyLedger.books.allSatisfy { $0.emoji == nil && $0.symbol == nil }, "old backups decode optional account and book icons")
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
        print("FINANCE PASS: \(checks) checks — accounts, books, transfers, refunds, FX, backup and persistence")
        return checks
    }
    /// Compare the actual old asset-page scans with the shared snapshot. Never opens user data.
    static func performance() throws {
        var ledger = FinanceData.initial
        ledger.accounts = (0..<100).map { MoneyAccount(name: "Account \($0)", opening: Decimal($0 * 100), archived: $0 % 9 == 0) }
        ledger.entries = (0..<5000).map { index in
            var entry = MoneyEntry(); entry.amount = 10; entry.accountAmount = 10; entry.baseAmount = 10
            entry.accountID = ledger.accounts[index % 100].id
            switch index % 5 {
            case 0: entry.kind = .transfer; entry.destinationID = ledger.accounts[(index + 1) % 100].id; entry.destinationAmount = 10; entry.fee = 1
            case 1: entry.kind = .income
            case 2: entry.kind = .refund
            case 3: entry.kind = .adjustment; entry.accountAmount = -10
            default: break
            }
            if index % 7 == 0 { entry.deletedAt = Date() }
            return entry
        }
        let start = ProcessInfo.processInfo.systemUptime
        let expected = Dictionary(uniqueKeysWithValues: ledger.accounts.map { ($0.id, ledger.balance($0.id)) })
        let scanned = ProcessInfo.processInfo.systemUptime
        let balances = ledger.accountBalances()
        let aggregated = ProcessInfo.processInfo.systemUptime
        guard balances == expected else { throw TaskBackup.invalid("Asset aggregation differs from account history") }
        print(String(format: "PERF assets 100 accounts / 5000 entries: repeated scans %.1f ms; one pass %.1f ms", (scanned - start) * 1000, (aggregated - scanned) * 1000))
    }

}
