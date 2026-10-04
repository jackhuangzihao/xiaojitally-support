// Appended only to SelfCheck.swift in the pinned build-68 source copy by generate.py.
// Never included in the shipping target. All records are synthetic.
extension SelfCheck {
    @MainActor static func exportFrozenSchema68(to directory: URL) throws {
        guard Bundle.main.bundleIdentifier == "local.jianshi.sandboxcheck.migration68",
              directory.standardizedFileURL.path.hasPrefix("/private/tmp/tally-migration68-") else {
            throw TaskBackup.invalid("Frozen fixture generation requires its isolated identity and temporary directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("source.store")
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { throw TaskBackup.invalid("Fixture destination is not empty") }
        func id(_ number: Int) -> UUID { UUID(uuidString: String(format: "68000000-0000-4000-8000-%012d", number))! }
        let day = Date(timeIntervalSince1970: 1_791_158_400) // 2026-10-05 00:00 UTC
        let work = TaskList(name: "Fixture · Work"); work.id = id(1); work.colorHex = "AA3344"; work.emoji = "📚"; work.createdAt = day; work.sortOrder = 2
        let child = TaskList(name: "Fixture · Project"); child.id = id(2); child.parentID = work.id; child.colorHex = "33AA66"; child.createdAt = day; child.sortOrder = 3
        let home = TaskList(name: "Fixture · Home"); home.id = id(3); home.colorHex = "4466AA"; home.createdAt = day; home.sortOrder = 4
        let task = TaskItem(title: "Fixture · scheduled repeat", scheduledAt: day.addingTimeInterval(9 * 3600), list: child)
        task.id = id(10); task.createdAt = day; task.notes = "Synthetic 中文 note\nLine two"; task.hasTime = true
        task.endAt = day.addingTimeInterval(10 * 3600); task.dueAt = day.addingTimeInterval(12 * 3600); task.dueHasTime = true
        task.priority = 2; task.isDone = true; task.completedAt = day.addingTimeInterval(10 * 3600)
        task.reminderAt = day.addingTimeInterval(9 * 3600 - 600); task.reminderKind = "tenMinutes"; task.reminderNeedsAttention = false
        task.repeatRule = "daily"; task.repeatAnchorDay = 5; task.repeatUntil = day.addingTimeInterval(7 * 86400)
        task.subtasks = [Subtask(id: id(100), title: "Fixture complete step", isDone: true), Subtask(id: id(101), title: "Fixture open step")]
        let next = task.occurrence(at: day.addingTimeInterval(86400 + 9 * 3600))
        task.nextOccurrenceID = next.id
        let deleted = TaskItem(title: "Fixture · deleted", scheduledAt: day, list: home)
        deleted.id = id(11); deleted.createdAt = day; deleted.deletedAt = day.addingTimeInterval(3600)
        let undated = TaskItem(title: "Fixture · undated", list: work); undated.id = id(12); undated.createdAt = day
        var snapshot = TaskBackup(weekTitles: [.init(week: "2026-10-05", title: "Fixture week")], createdAt: day,
            lists: [work, child, home].map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID, colorHex: $0.colorHex, sortOrder: $0.sortOrder, emoji: $0.emoji) },
            tasks: [task, next, deleted, undated].map(TaskBackup.TaskRecord.init))
        var finance = FinanceData()
        let cny = MoneyAccount(id: id(20), name: "Fixture CNY account", opening: 1000, type: "debit", bankName: "Fixture Bank")
        let usd = MoneyAccount(id: id(21), name: "Fixture USD account", currency: "USD", opening: 100, emoji: "💳", type: "debit", bankName: "Fixture Bank")
        let book = MoneyBook(id: id(30), name: "Fixture book", defaultAccountID: usd.id, budget: 500, emoji: "🏠")
        let food = MoneyCategory(id: id(40), name: "Fixture food", symbol: "fork.knife", income: false, color: "orange")
        let coffee = MoneyCategory(id: id(41), name: "Fixture coffee", symbol: "cup.and.saucer", income: false, parentID: food.id)
        finance.accounts = [cny, usd]; finance.books = [book]; finance.categories = [food, coffee]
        var cost = MoneyEntry(); cost.id = id(50); cost.title = "Fixture purchase"; cost.date = day
        cost.currency = "USD"; cost.amount = 10; cost.accountAmount = 10; cost.baseAmount = 71
        cost.accountID = usd.id; cost.bookID = book.id; cost.categoryID = coffee.id; cost.taskID = task.id
        cost.notes = "Synthetic receipt"; cost.tags = "fixture"; cost.rateNote = "Fixture posted rate"
        var refund = cost; refund.id = id(51); refund.title = "Fixture refund"; refund.kind = .refund
        refund.date = day.addingTimeInterval(3600); refund.amount = 2; refund.accountAmount = 2; refund.baseAmount = Decimal(string: "14.2"); refund.refundOf = cost.id
        var transfer = MoneyEntry(); transfer.id = id(52); transfer.title = "Fixture transfer"; transfer.date = day
        transfer.kind = .transfer; transfer.amount = 71; transfer.accountAmount = 71; transfer.accountID = cny.id; transfer.bookID = book.id
        transfer.destinationID = usd.id; transfer.destinationAmount = 10; transfer.fee = 1; transfer.baseFee = 1
        var pending = cost; pending.id = id(53); pending.title = "Fixture missing conversion"; pending.baseAmount = nil; pending.amount = 5; pending.accountAmount = 5
        var trashed = cost; trashed.id = id(54); trashed.title = "Fixture deleted entry"; trashed.deletedAt = day.addingTimeInterval(7200); trashed.deletionBatchID = id(60)
        finance.entries = [cost, refund, transfer, pending, trashed]
        finance.rates = [MoneyRate(base: "USD", quote: "CNY", rate: Decimal(string: "7.1")!, date: "2026-10-05", fetchedAt: day, source: "Manual")]
        snapshot.finance = finance
        try snapshot.validate()
        let container = try Store.make(url: storeURL), context = container.mainContext
        try CloudMerge.stage(snapshot, in: context)
        let baseline = try CloudMerge.bytes(snapshot)
        let state = CloudSyncState(); state.enabled = true; state.account = "synthetic-migration-account-68"
        state.baseline = baseline; state.lastSync = day.addingTimeInterval(3 * 3600); context.insert(state)
        try Store.save(context)
        var expected = try TaskBackup.capture(context); expected.createdAt = day
        try expected.encoded().write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        try baseline.write(to: directory.appendingPathComponent("cloud-baseline.json"), options: .atomic)
        let cloud: [String: Any] = ["enabled": true, "account": state.account, "lastSyncMilliseconds": 1_791_169_200_000,
                                  "baselineSHA256": CloudMerge.digest(baseline)]
        try JSONSerialization.data(withJSONObject: cloud, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("cloud-state.json"), options: .atomic)
        print("FROZEN FIXTURE CREATED: synthetic build-68 store")
    }
}
