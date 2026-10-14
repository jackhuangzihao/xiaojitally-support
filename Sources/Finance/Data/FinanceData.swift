import Foundation

struct FinanceData: Codable, Equatable {
    var version = 3
    var baseCurrency = "CNY"
    var accounts: [MoneyAccount] = []
    var books: [MoneyBook] = []
    var categories: [MoneyCategory] = []
    var entries: [MoneyEntry] = []
    var rates: [MoneyRate] = []
    /// Optional so ledgers written before recurring bills decode unchanged; nil when there are none.
    var recurring: [MoneyRecurring]?
    static var initial: Self {
        var result = Self()
        result.books = [MoneyBook(id: UUID(uuidString: "E837FC77-248C-4DE3-AF81-000000000001")!, name: L("日常", "Daily"))]
        result.categories = zip(["food", "transport", "shopping", "home", "travel", "health", "salary", "other"],
                                ["fork.knife", "tram", "bag", "house", "airplane", "heart", "banknote", "ellipsis.circle"]).enumerated().map { i, pair in
            MoneyCategory(id: UUID(uuidString: String(format: "E837FC77-248C-4DE3-AF81-%012d", i + 100))!, name: pair.0, symbol: pair.1)
        } + Self.addedDefaults
        return result
    }
    /// Categories added in 0.2.1. Fixed IDs, so two devices that each add them still merge cleanly.
    static let addedDefaults: [MoneyCategory] = [
        ("drinks", "cup.and.saucer", false), ("fun", "gamecontroller", false), ("daily", "basket", false), ("phone", "iphone", false),
        ("study", "book", false), ("sports", "figure.run", false), ("gifts", "gift", false),
        ("bonus", "rosette", true), ("invest", "chart.line.uptrend.xyaxis", true), ("parttime", "briefcase", true),
        ("redpacket", "envelope", true), ("otherincome", "plus.circle", true)
    ].enumerated().map { i, item in
        MoneyCategory(id: UUID(uuidString: String(format: "E837FC77-248C-4DE3-AF81-%012d", i + 200))!, name: item.0, symbol: item.1, income: item.2)
    }
    /// Adds the 0.2.1 defaults an older ledger lacks, skipping any whose name the user already has.
    mutating func addMissingDefaults() {
        for category in Self.addedDefaults where !categories.contains(where: { $0.id == category.id || $0.name == category.name || $0.label == category.label }) {
            categories.append(category)
        }
    }
    func remainingRefund(for id: UUID, excluding refundID: UUID? = nil) -> Decimal {
        guard let original = entries.first(where: { $0.id == id && $0.kind == .expense && $0.deletedAt == nil && !$0.isPending }) else { return 0 }
        return max(0, original.amount - entries.filter { $0.refundOf == id && $0.deletedAt == nil && $0.id != refundID }.reduce(0) { $0 + $1.amount })
    }
    func categoryIDs(including id: UUID) -> Set<UUID> {
        Set([id] + categories.filter { $0.parentID == id }.map(\.id))
    }
    func categoryMatches(_ entryCategoryID: UUID?, filterID: UUID) -> Bool {
        entryCategoryID.map { categoryIDs(including: filterID).contains($0) } ?? false
    }
    func rootCategoryID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.parentID ?? id
    }
    func categoryPath(_ id: UUID?) -> String {
        guard let category = categories.first(where: { $0.id == id }) else { return "" }
        guard let parent = categories.first(where: { $0.id == category.parentID }) else { return category.label }
        return parent.label + " / " + category.label
    }
    /// An invalid incoming hierarchy is rejected before it can replace the working ledger.
    func validateCategoryHierarchy() throws {
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for category in categories {
            guard let parentID = category.parentID else { continue }
            guard parentID != category.id, let parent = byID[parentID], parent.parentID == nil,
                  parent.isIncome == category.isIncome, !parent.archived || category.archived else {
                throw TaskBackup.invalid(L("子分类必须属于同类型的一级分类；已归档的父分类下不能启用子分类。", "A subcategory needs a top-level parent of the same type; an archived parent cannot have active children."))
            }
        }
    }
    mutating func updateCategory(_ category: MoneyCategory, expected: MoneyCategory?) throws {
        guard categories.first(where: { $0.id == category.id }) == expected else {
            throw TaskBackup.invalid(L("分类已改变，请重新打开。", "Category changed. Reopen it."))
        }
        guard !categories.contains(where: { $0.id != category.id && $0.parentID == category.parentID && $0.isIncome == category.isIncome && $0.label.caseInsensitiveCompare(category.label) == .orderedSame }) else {
            throw TaskBackup.invalid(L("此分组内的分类名称已存在。", "A category with this name already exists in this group."))
        }
        if let expected, expected.isIncome != category.isIncome,
           entries.contains(where: { $0.categoryID == category.id }) || categories.contains(where: { $0.parentID == category.id }) {
            throw TaskBackup.invalid(L("已有账单或子分类，不能切换收支类型。", "A category with entries or subcategories cannot change between income and spending."))
        }
        var changed = self
        if let index = changed.categories.firstIndex(where: { $0.id == category.id }) { changed.categories[index] = category }
        else { changed.categories.append(category) }
        if category.archived {
            for i in changed.categories.indices where changed.categories[i].parentID == category.id { changed.categories[i].archived = true }
        }
        try changed.validateCategoryHierarchy()
        categories = changed.categories
    }
    func removalBlock(_ kind: FinanceEntityKind, id: UUID) -> String? {
        let referenced: Bool
        switch kind {
        case .account: referenced = entries.contains { $0.accountID == id || $0.destinationID == id } || recurringBills.contains { $0.accountID == id }
        case .book:
            if books.count <= 1 || (books.first { $0.id == id }?.archived == false && !books.contains { $0.id != id && !$0.archived }) {
                return L("请至少保留一个可用账本。", "Keep at least one available book.")
            }
            referenced = entries.contains { $0.bookID == id } || recurringBills.contains { $0.bookID == id }
        case .category:
            if categories.contains(where: { $0.parentID == id }) {
                return L("请先移走或删除子分类；归档父分类会同时归档子分类并保留全部历史。", "Move or remove subcategories first. Archiving the parent also archives its children and keeps all history.")
            }
            if Self.initial.categories.contains(where: { $0.id == id }) {
                return L("系统预设分类可归档；自建的空分类可删除。", "Archive preset categories; unused custom categories can be deleted.")
            }
            referenced = entries.contains { $0.categoryID == id } || recurringBills.contains { $0.categoryID == id }
        }
        return referenced ? L("有关联账单（含最近删除），请使用归档以保留历史。", "Linked entries exist, including Recently deleted. Archive this item to keep its history.") : nil
    }
    mutating func remove(_ kind: FinanceEntityKind, id: UUID, expected: Self) throws {
        let unchanged: Bool
        switch kind {
        case .account: unchanged = accounts.contains { $0.id == id } && accounts.first { $0.id == id } == expected.accounts.first { $0.id == id }
        case .book: unchanged = books.contains { $0.id == id } && books.first { $0.id == id } == expected.books.first { $0.id == id }
        case .category: unchanged = categories.contains { $0.id == id } && categories.first { $0.id == id } == expected.categories.first { $0.id == id }
        }
        guard unchanged else { throw TaskBackup.invalid(L("项目已改变，请重新打开。", "This item changed. Reopen it.")) }
        if let reason = removalBlock(kind, id: id) { throw TaskBackup.invalid(reason) }
        switch kind {
        case .account:
            accounts.removeAll { $0.id == id }
            for i in books.indices where books[i].defaultAccountID == id { books[i].defaultAccountID = nil }
        case .book: books.removeAll { $0.id == id }
        case .category: categories.removeAll { $0.id == id }
        }
    }
    /// With `selected` (the entries of the viewed period), an archived book's budget counts only in periods it was used,
    /// so a finished trip keeps its history without inflating every later month.
    func budgetBooks(for bookID: UUID?, in selected: [MoneyEntry]? = nil) -> [MoneyBook] {
        let used = selected.map { Set($0.filter { $0.deletedAt == nil && !$0.isPending }.compactMap(\.bookID)) }
        return books.filter { book in
            book.budget != nil && (bookID.map { book.id == $0 } ?? (!book.archived || used?.contains(book.id) ?? true))
        }
    }
    func budget(for bookID: UUID?, in selected: [MoneyEntry]? = nil) -> Decimal? {
        let values = budgetBooks(for: bookID, in: selected).compactMap(\.budget)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    /// Deleting a purchase takes its refunds along, so no refund is left pointing at a deleted purchase.
    mutating func trash(_ entry: MoneyEntry, at date: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index] == entry, entry.deletedAt == nil else {
            throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再操作。", "This entry changed in another window. Reopen it first."))
        }
        let stamp = MoneyEntry.timestamp(date), batch = UUID()
        entries[index].deletedAt = stamp; entries[index].deletionBatchID = batch
        if entry.kind == .expense {
            for i in entries.indices where entries[i].refundOf == entry.id && entries[i].deletedAt == nil {
                entries[i].deletedAt = stamp; entries[i].deletionBatchID = batch
            }
        }
    }
    /// Restores what was deleted together: a purchase brings back its refunds, a refund brings back its purchase.
    mutating func restore(_ entry: MoneyEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index] == entry, entry.deletedAt != nil else {
            throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再操作。", "This entry changed in another window. Reopen it first."))
        }
        entries[index].deletedAt = nil; entries[index].deletionBatchID = nil
        // Legacy records have no batch. Restore those refunds individually rather than guessing by timestamp.
        if entry.kind == .expense, let batch = entry.deletionBatchID {
            for i in entries.indices where entries[i].refundOf == entry.id && entries[i].deletedAt != nil && entries[i].deletionBatchID == batch {
                entries[i].deletedAt = nil; entries[i].deletionBatchID = nil
            }
        }
        if entry.kind == .refund, let original = entries.firstIndex(where: { $0.id == entry.refundOf }), entries[original].deletedAt != nil {
            entries[original].deletedAt = nil; entries[original].deletionBatchID = nil
        }
    }
    func liveRefunds(of id: UUID) -> [MoneyEntry] { entries.filter { $0.refundOf == id && $0.deletedAt == nil } }

    func budgetSpending(_ selected: [MoneyEntry], for bookID: UUID?) -> MoneyStatisticsTotal {
        let ids = Set(budgetBooks(for: bookID, in: selected).map(\.id))
        let entries = selected.filter { $0.deletedAt == nil && $0.bookID.map(ids.contains) == true }
        return statisticsTotal(entries, income: false, in: baseCurrency, history: nil, days: nil)
    }
    var canChangeBaseCurrency: Bool { entries.isEmpty && books.allSatisfy { $0.budget == nil } && recurringBills.isEmpty }
    func requireBaseCurrency(_ expected: String) throws {
        guard baseCurrency == expected else {
            throw TaskBackup.invalid(L("记账本位币已在其他窗口改变，请重新打开后编辑。", "The recorded base currency changed in another window. Reopen this editor."))
        }
    }
    mutating func changeBaseCurrency(to currency: String, expected: String) throws {
        try requireBaseCurrency(expected)
        guard currency != baseCurrency else { return }
        guard Money.currencies.contains(currency), canChangeBaseCurrency else {
            throw TaskBackup.invalid(L("已有账单或预算时不能直接更改记账本位币。查看其他币种，请切换统计显示币种。", "The recorded base currency cannot change while entries or budgets exist. Choose a reporting display currency to view other currencies."))
        }
        baseCurrency = currency
    }
    mutating func updateBook(_ book: MoneyBook, expected: MoneyBook?, baseCurrency: String) throws {
        try requireBaseCurrency(baseCurrency)
        guard books.first(where: { $0.id == book.id }) == expected else { throw TaskBackup.invalid(L("账本已改变，请重新打开。", "Book changed. Reopen it.")) }
        guard !books.contains(where: { $0.id != book.id && $0.name.caseInsensitiveCompare(book.name) == .orderedSame }) else { throw TaskBackup.invalid(L("账本名称已存在。", "Book name already exists.")) }
        if book.archived && expected?.archived != true, let reason = bookArchiveBlock(book.id) { throw TaskBackup.invalid(reason) }
        books.upsert(book)
    }
    func bookArchiveBlock(_ id: UUID) -> String? {
        books.contains { $0.id != id && !$0.archived } ? nil : L("请至少保留一个可用账本。", "Keep at least one available book.")
    }
    func requireEntryCurrencies(_ entry: MoneyEntry, from original: FinanceData) throws {
        try requireBaseCurrency(original.baseCurrency)
        for id in [entry.accountID, entry.destinationID].compactMap({ $0 }) {
            guard accounts.first(where: { $0.id == id })?.currency == original.accounts.first(where: { $0.id == id })?.currency else {
                throw TaskBackup.invalid(L("账户币种已改变，请重新打开账单后输入金额。", "An account currency changed. Reopen the entry before entering its amounts."))
            }
        }
    }
    func entryKindChangeBlock(_ entry: MoneyEntry) -> String? {
        guard entry.kind == .expense || entry.kind == .income else {
            return L("转账、退款和余额调整不能改为普通收支。", "Transfers, refunds and balance adjustments cannot change to income or spending.")
        }
        if entries.contains(where: { $0.refundOf == entry.id }) {
            return L("此支出有关联退款（含最近删除），不能改为收入；金额和其他信息仍可编辑。", "This expense has linked refunds, including Recently deleted, so it cannot become income. You can still edit its amount and other details.")
        }
        return nil
    }
    mutating func updateEntry(_ entry: MoneyEntry, expected: MoneyEntry?, baseCurrency: String, referenceRates: [MoneyRate] = []) throws {
        try requireBaseCurrency(baseCurrency)
        guard entries.first(where: { $0.id == entry.id }) == expected else { throw TaskBackup.invalid(L("账单已在其他窗口修改。请重新打开再编辑。", "This entry changed in another window. Reopen it before editing.")) }
        if let expected, expected.isPending != entry.isPending {
            throw TaskBackup.invalid(L("已入账账单不能改为待入账；待入账账单请使用确认入账。", "Posted entries cannot become pending. Use Confirm entry to post a pending entry."))
        }
        if entry.isPending {
            guard entry.kind == .expense || entry.kind == .income else {
                throw TaskBackup.invalid(L("只有收入和支出可以设为待入账。", "Only income and expenses can be pending."))
            }
        }
        if let expected, expected.kind != entry.kind {
            if let reason = entryKindChangeBlock(expected) { throw TaskBackup.invalid(reason) }
            guard entry.kind == .expense || entry.kind == .income else {
                throw TaskBackup.invalid(L("已有收支账单只能在收入和支出之间切换。", "An existing income or expense can only switch between income and spending."))
            }
        }
        // Existing historical links remain editable after their category is archived.
        if let id = entry.categoryID, entry.kind == .expense || entry.kind == .income,
           expected == nil || expected?.kind != entry.kind || expected?.categoryID != id {
            guard let category = categories.first(where: { $0.id == id }), !category.archived,
                  category.isIncome == (entry.kind == .income),
                  category.parentID.map({ parent in categories.contains { $0.id == parent && !$0.archived } }) ?? true else {
                throw TaskBackup.invalid(L("所选分类已改变，请选择相应收支类型的可用分类。", "The selected category changed. Choose an available category matching the entry’s income or expense type."))
            }
        }
        try checkAccounts(for: entry, replacing: expected)
        // Older editor state can contain asset quotes; actual posting amounts remain authoritative.
        try mergeReferenceRates(referenceRates.filter { !$0.isManual })
        if entry.isPending { version = max(version, 2) }
        entries.removeAll { $0.id == entry.id }; entries.append(entry)
        if entry.kind == .expense {
            for i in entries.indices where entries[i].refundOf == entry.id { entries[i].bookID = entry.bookID; entries[i].categoryID = entry.categoryID }
        }
    }
    /// Posting keeps the planned date and recorded amounts. Missing historical FX stays visible until filled.
    mutating func confirmPending(_ expected: MoneyEntry, now: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == expected.id }), entries[index] == expected,
              expected.isPending, expected.deletedAt == nil else {
            throw TaskBackup.invalid(L("账单已修改、删除或入账，请刷新后重试。", "This entry changed, was deleted or is already posted. Refresh and try again."))
        }
        guard expected.isDueForConfirmation(at: now) else {
            throw TaskBackup.invalid(L("计划日期尚未到达，请在当天或之后确认入账。", "Confirm this entry on or after its planned date."))
        }
        guard expected.kind == .expense || expected.kind == .income,
              books.contains(where: { $0.id == expected.bookID && !$0.archived }) else {
            throw TaskBackup.invalid(L("请选择可用账本后再确认入账。", "Choose an available book before confirming this entry."))
        }
        if let id = expected.categoryID {
            guard let category = categories.first(where: { $0.id == id }), !category.archived,
                  category.isIncome == (expected.kind == .income),
                  category.parentID.map({ parent in categories.contains { $0.id == parent && !$0.archived } }) ?? true else {
                throw TaskBackup.invalid(L("请选择相应收支类型的可用分类后再确认入账。", "Choose an available category of the matching income or expense type before confirming."))
            }
        }
        try checkAccounts(for: expected, replacing: nil)
        var next = self
        next.entries[index].pending = false
        try next.validate()
        self = next
    }
    /// One pass for an entire asset page, including archived accounts and both transfer sides.
    func accountBalances() -> [UUID: Decimal] {
        var balances = Dictionary(accounts.map { ($0.id, $0.opening) }, uniquingKeysWith: { first, _ in first })
        for entry in entries where entry.deletedAt == nil {
            if let id = entry.accountID, balances[id] != nil { balances[id, default: 0] += entry.accountChange(for: id) }
            if let id = entry.destinationID, id != entry.accountID, balances[id] != nil { balances[id, default: 0] += entry.accountChange(for: id) }
        }
        return balances
    }
    func balance(_ id: UUID, before date: Date? = nil) -> Decimal {
        guard let account = accounts.first(where: { $0.id == id }) else { return 0 }
        return entries.filter { $0.deletedAt == nil && (date == nil || $0.date < date!) }
            .reduce(account.opening) { $0 + $1.accountChange(for: id) }
    }
    /// Stored entry dates have second precision; reconciliation includes entries at the selected instant.
    func balance(_ id: UUID, at date: Date) -> Decimal {
        balance(id, before: MoneyEntry.timestamp(date).addingTimeInterval(1))
    }
    /// Editing replaces the old posting; a new UUID adds a separate posting.
    func balanceAfterSaving(_ entry: MoneyEntry, for id: UUID, accountBalances: [UUID: Decimal]? = nil) -> Decimal {
        let old = entries.first { $0.id == entry.id && $0.deletedAt == nil }
        return (accountBalances?[id] ?? balance(id)) - (old?.accountChange(for: id) ?? 0)
            + (entry.deletedAt == nil ? entry.accountChange(for: id) : 0)
    }
    func reconciliationEntry(for id: UUID, bookID: UUID? = nil) -> MoneyEntry {
        var entry = MoneyEntry(); entry.kind = .adjustment; entry.title = L("余额校准", "Balance adjustment")
        entry.accountID = id; entry.currency = accounts.first { $0.id == id }?.currency ?? baseCurrency
        entry.bookID = books.first { $0.id == bookID }?.id ?? books.first { !$0.archived }?.id ?? books.first?.id
        return entry
    }
    /// Include trash and incoming transfers: restoring either must preserve the account's denomination.
    func accountHasHistory(_ id: UUID) -> Bool {
        entries.contains { $0.accountID == id || $0.destinationID == id }
    }
    mutating func updateAccount(_ account: MoneyAccount, expected: MoneyAccount?, allowOpeningCorrection: Bool = false) throws {
        guard accounts.first(where: { $0.id == account.id }) == expected else {
            throw TaskBackup.invalid(L("账户已改变，请重新打开。", "Account changed. Reopen it."))
        }
        guard !accounts.contains(where: { $0.id != account.id && $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) else {
            throw TaskBackup.invalid(L("账户名称已存在。", "Account name already exists."))
        }
        if let expected, accountHasHistory(account.id) {
            guard expected.currency == account.currency else {
                throw TaskBackup.invalid(L("账户已有流水，不能直接更换币种。请新建对应币种的账户。", "An account with entries cannot change currency. Create an account in the required currency."))
            }
            guard expected.opening == account.opening || allowOpeningCorrection else {
                throw TaskBackup.invalid(L("更正期初余额会影响所有历史余额，请先确认。", "Correcting the opening balance changes all historical balances. Confirm first."))
            }
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account }
        else { accounts.append(account) }
    }
    func reconciliationChange(_ id: UUID, at date: Date, checked: Decimal, expected: Decimal) throws -> Decimal {
        guard let account = accounts.first(where: { $0.id == id }), Money.valid(checked, currency: account.currency, signed: true) else {
            throw TaskBackup.invalid(L("请输入有效的账户余额。", "Enter a valid account balance."))
        }
        let current = balance(id, at: date)
        guard current == expected else { throw TaskBackup.invalid(L("这个时刻的账面余额已变化，请重新打开核对。", "The balance at this time changed. Reopen reconciliation.")) }
        return checked - current
    }
    /// Compute once for the entire account, so date/category filters cannot change balances beside a row.
    func runningBalances(_ id: UUID) -> [UUID: Decimal] {
        guard let account = accounts.first(where: { $0.id == id }) else { return [:] }
        var balance = account.opening, result: [UUID: Decimal] = [:]
        for e in entries.filter({ $0.deletedAt == nil && !$0.isPending && $0.matches(bookID: nil, accountID: id) }).sorted(by: { MoneyEntry.newestFirst($1, $0) }) {
            balance += e.accountChange(for: id); result[e.id] = balance
        }
        return result
    }
    func defaultAccount(for bookID: UUID?) -> UUID? {
        guard let id = books.first(where: { $0.id == bookID })?.defaultAccountID else { return nil }
        return accounts.first { $0.id == id && !$0.archived }?.id
    }
    func allowsAccount(_ id: UUID, for entry: MoneyEntry, replacing original: MoneyEntry?) -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        if !account.archived || original?.accountID == id || original?.destinationID == id { return true }
        // Historical refunds and explicit reconciliation can still settle a closed account.
        if entry.kind == .refund, entries.first(where: { $0.id == entry.refundOf })?.accountID == id { return true }
        return entry.kind == .adjustment && entry.accountID == id
    }
    func checkAccounts(for entry: MoneyEntry, replacing original: MoneyEntry?) throws {
        for id in [entry.accountID, entry.destinationID].compactMap({ $0 }) where !allowsAccount(id, for: entry, replacing: original) {
            throw TaskBackup.invalid(L("所选账户已归档或不存在，请选择可用账户。", "The selected account is archived or missing. Choose an available account."))
        }
    }
    func copyEntry(_ original: MoneyEntry, preferredBookID: UUID? = nil, at date: Date = Date()) -> MoneyEntry {
        var entry = original
        entry.id = UUID(); entry.date = MoneyEntry.timestamp(date); entry.deletedAt = nil; entry.deletionBatchID = nil; entry.refundOf = nil; entry.taskID = nil; entry.rateNote = ""
        entry.recurringID = nil // A copy is a one-off entry, not another occurrence of the bill.
        let source = accounts.first { $0.id == entry.accountID }, destination = accounts.first { $0.id == entry.destinationID }
        if entry.currency != baseCurrency || source.map({ $0.currency != entry.currency }) == true || destination.map({ $0.currency != entry.currency }) == true {
            entry.accountAmount = 0; entry.destinationAmount = 0; entry.baseAmount = nil; entry.baseFee = nil
        }
        if source?.archived == true { entry.accountID = nil; entry.accountAmount = 0 }
        if destination?.archived == true { entry.destinationID = nil; entry.destinationAmount = 0 }
        if books.first(where: { $0.id == entry.bookID })?.archived != false {
            entry.bookID = books.first { $0.id == preferredBookID && !$0.archived }?.id ?? books.first { !$0.archived }?.id
        }
        return entry
    }
    func searchText(for entry: MoneyEntry) -> String {
        [entry.title, entry.notes, entry.tags, books.first { $0.id == entry.bookID }?.name ?? "",
         accounts.first { $0.id == entry.accountID }?.name ?? "", accounts.first { $0.id == entry.destinationID }?.name ?? "",
         categoryPath(entry.categoryID)].joined(separator: " ")
    }
    func accountFlow(_ id: UUID, in selected: [MoneyEntry]) -> (incoming: Decimal, outgoing: Decimal) {
        var incoming: Decimal = 0, outgoing: Decimal = 0
        for entry in selected where entry.deletedAt == nil {
            let change = entry.accountChange(for: id)
            if change > 0 { incoming += change } else { outgoing -= change }
        }
        return (incoming, outgoing)
    }
    func totals(_ selected: [MoneyEntry]) -> (income: Decimal, expense: Decimal, refunds: Decimal, missing: Int) {
        var income: Decimal = 0, expense: Decimal = 0, refunds: Decimal = 0, missing = 0
        for e in selected where e.deletedAt == nil && !e.isPending {
            if e.kind != .transfer && e.kind != .adjustment {
                if let amount = e.baseAmount {
                    switch e.kind { case .income: income += amount; case .expense: expense += amount; case .refund: refunds += amount; default: break }
                } else { missing += 1 }
            }
            if e.fee > 0 { if let fee = e.baseFee { expense += fee } else { missing += 1 } }
        }
        return (income, expense, refunds, missing)
    }
    func csv(_ selected: [MoneyEntry]) -> String {
        func cell(_ text: String, numeric: Bool) -> String {
            // Formula-safe export for text, including user-authored labels beginning with spreadsheet operators.
            // Amounts are generated digits; a leading "-" there is a negative number and must stay summable.
            let safe = !numeric && ["=", "+", "-", "@", "\t", "\r"].contains(String(text.prefix(1))) ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let numericColumns: Set<String> = ["Amount", "Account amount", "Received", "Fee", "Base amount", "Base fee"]
        let header = ["ID", "Date", "Type", "Title", "Currency", "Amount", "Account", "Account currency", "Account amount", "Destination", "Destination currency", "Received", "Fee", "Base currency", "Base amount", "Base fee", "Book", "Category", "Tags", "Notes", "Task ID", "Refund of", "Rate note", "Status"]
        let rows = selected.map { e -> [String] in
            let a = accounts.first { $0.id == e.accountID }, d = accounts.first { $0.id == e.destinationID }
            return [e.id.uuidString, e.date.ISO8601Format(), e.kind.rawValue, e.title, e.currency, Money.text(e.amount), a?.name ?? "", a?.currency ?? "", Money.text(e.accountAmount), d?.name ?? "", d?.currency ?? "", Money.text(e.destinationAmount), Money.text(e.fee), baseCurrency, e.baseAmount.map(Money.text) ?? "", e.baseFee.map(Money.text) ?? "", books.first { $0.id == e.bookID }?.name ?? "", categoryPath(e.categoryID), e.tags, e.notes, e.taskID?.uuidString ?? "", e.refundOf?.uuidString ?? "", e.rateNote, e.isPending ? "pending" : "posted"]
        }
        let lines = [header.map { cell($0, numeric: false) }]
            + rows.map { row in zip(header, row).map { cell($1, numeric: numericColumns.contains($0)) } }
        return "\u{FEFF}" + lines.map { $0.joined(separator: ",") }.joined(separator: "\r\n")
    }
}
