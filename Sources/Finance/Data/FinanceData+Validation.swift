import Foundation

extension FinanceData {
    func validate() throws {
        func check(_ valid: Bool, _ zh: String, _ en: String) throws { if !valid { throw TaskBackup.invalid(L(zh, en)) } }
        func unique<T: Identifiable>(_ items: [T]) -> Bool where T.ID: Hashable { Set(items.map(\.id)).count == items.count }
        try check(entries.count <= 100_000 && accounts.count <= 1000 && books.count <= 1000 && categories.count <= 1000, "记账数据超过当前支持的大小。", "Ledger exceeds supported size.")
        try check((1...3).contains(version) && Money.currencies.contains(baseCurrency), "记账数据版本或本位币无效。", "Invalid ledger version or base currency.")
        try check(version >= 2 || !entries.contains(where: \.isPending), "待入账账单需要新版记账数据格式。", "Pending entries require the newer ledger format.")
        try check(version >= 3 || !recurringBills.contains { $0.repeatTimeZoneID != nil }, "重复时区需要新版记账数据格式。", "Repeat time zones require the newer ledger format.")
        try check(unique(accounts) && unique(books) && unique(categories) && unique(entries), "记账数据含重复编号。", "Duplicate ledger identifiers.")
        try validateCategoryHierarchy()
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let bookIDs = Set(books.map(\.id)), categoryIDs = Set(categories.map(\.id))
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        func name(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.count <= 80 }
        try check(accounts.allSatisfy { name($0.name) && ($0.bankName.map(name) ?? true) && Money.currencies.contains($0.currency) && Money.valid($0.opening, currency: $0.currency, signed: true) }, "账户名称、银行、币种或期初余额无效。", "Invalid account name, bank, currency or opening balance.")
        try check(books.allSatisfy { name($0.name) && ($0.defaultAccountID == nil || accountMap[$0.defaultAccountID!] != nil) && ($0.budget.map { Money.valid($0, currency: baseCurrency) && $0 > 0 } ?? true) } && categories.allSatisfy { name($0.name) && $0.symbol.count <= 80 && ($0.color?.count ?? 0) <= 20 } && accounts.allSatisfy { ($0.type?.count ?? 0) <= 20 }, "账本或分类无效。", "Invalid book or category.")
        let icons = accounts.map(\.emoji) + books.map(\.emoji) + categories.map(\.emoji)
        try check(icons.allSatisfy { $0.map(TaskList.validEmoji) ?? true }, "请选择一个表情作为图标。", "Choose one emoji for an icon.")
        try check((accounts.map(\.symbol) + books.map(\.symbol)).allSatisfy { $0.map { !$0.isEmpty && $0.count <= 80 } ?? true }, "图标无效。", "Invalid icon.")
        for e in entries {
            let account = e.accountID.flatMap { accountMap[$0] }, destination = e.destinationID.flatMap { accountMap[$0] }
            try check(!e.isPending || e.kind == .expense || e.kind == .income, "只有收入和支出可以设为待入账。", "Only income and expenses can be pending.")
            try check(name(e.title) && e.notes.count <= 10000 && e.tags.count <= 500 && e.rateNote.count <= 500 && e.date.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains(e.date.timeIntervalSince1970) && (e.deletedAt.map { $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970) } ?? true), "账单名称、日期或备注无效。", "Invalid entry title, date or notes.")
            try check(Money.currencies.contains(e.currency) && Money.valid(e.amount, currency: e.currency, signed: e.kind == .adjustment) && (e.amount > 0 || e.kind == .adjustment && e.amount != 0), "账单金额必须有效且非零。", "Entry amount must be valid and nonzero.")
            try check(e.bookID.map { bookIDs.contains($0) } ?? false, "请选择账本。", "Choose a book.")
            try check(e.categoryID.map { categoryIDs.contains($0) } ?? true, "分类不存在。", "Category does not exist.")
            try check((e.accountID == nil || account != nil) && (e.destinationID == nil || destination != nil), "关联账户不存在。", "Linked account is missing.")
            if let account {
                try check(Money.valid(e.accountAmount, currency: account.currency, signed: e.kind == .adjustment) && (e.accountAmount > 0 || e.kind == .adjustment && e.accountAmount != 0), "请输入账户的实际金额。", "Enter the actual account amount.")
                if account.currency == baseCurrency && e.currency != baseCurrency && e.kind != .transfer && e.kind != .adjustment { try check(e.baseAmount == e.accountAmount, "折算金额必须与本币账户实际金额一致。", "Converted amount must match the base-currency account amount.") }
                if e.currency == account.currency { try check(e.amount == e.accountAmount, "同币种的账单和扣款金额必须相同。", "Same-currency entry and account amounts must match.") }
            } else { try check(e.accountAmount == 0 && e.fee == 0, "无账户账单不能改变余额。", "Unassigned entries cannot change balances.") }
            // A positive foreign amount can legitimately round to zero in the reporting currency.
            try check(e.baseAmount.map { Money.valid($0, currency: baseCurrency, signed: e.kind == .adjustment) && (e.kind != .adjustment || $0 != 0) } ?? true, "折算金额无效。", "Invalid converted amount.")
            if e.currency == baseCurrency && e.kind != .transfer && e.kind != .adjustment { try check(e.baseAmount == e.amount, "本币账单的统计金额必须等于原金额。", "Base-currency totals must match the entry amount.") }
            try check(Money.valid(e.fee, currency: account?.currency ?? baseCurrency) && (e.baseFee.map { Money.valid($0, currency: baseCurrency) } ?? true), "手续费无效。", "Invalid fee.")
            if e.kind == .transfer {
                try check(account != nil && destination != nil && e.accountID != e.destinationID && e.currency == account?.currency, "转账需要两个不同的账户。", "Transfers need two different accounts.")
                try check(Money.valid(e.destinationAmount, currency: destination!.currency) && e.destinationAmount > 0, "请输入实际到账金额。", "Enter the amount received.")
                if account?.currency == destination?.currency { try check(e.accountAmount == e.destinationAmount, "同币种转账金额应一致，手续费单独填写。", "Same-currency transfers must match; enter the fee separately.") }
                if e.fee > 0 && account?.currency == baseCurrency { try check(e.baseFee == e.fee, "本币手续费必须计入支出。", "Base-currency fees must be counted as expenses.") }
            } else { try check(e.destinationID == nil && e.destinationAmount == 0 && e.fee == 0 && e.baseFee == nil, "仅转账支持到账账户和手续费。", "Only transfers have a receiving account and fee.") }
            if e.kind == .adjustment { try check(account != nil && e.currency == account?.currency, "余额调整需要同币种账户。", "Adjustments require an account in the same currency.") }
            if e.kind == .refund {
                guard let original = e.refundOf.flatMap({ entryMap[$0] }) else { throw TaskBackup.invalid(L("退款缺少原消费。", "Refund requires the original expense.")) }
                try check(original.kind == .expense && !original.isPending && original.currency == e.currency && original.bookID == e.bookID && original.categoryID == e.categoryID && (e.deletedAt != nil || original.deletedAt == nil), "退款须关联已入账消费，并与原消费的币种、账本和分类一致；请先处理关联退款再删除消费。", "Refunds require a posted expense with the same currency, book and category; handle linked refunds before deleting the expense.")
                try check(e.date >= original.date, "退款日期不能早于原消费。", "Refund date cannot precede the expense.")
            } else { try check(e.refundOf == nil, "非退款账单不能关联原消费。", "Only refunds reference an expense.") }
        }
        var refunded: [UUID: Decimal] = [:]
        for e in entries where e.kind == .refund && e.deletedAt == nil { refunded[e.refundOf!, default: 0] += e.amount }
        try check(refunded.allSatisfy { id, amount in amount <= entryMap[id]!.amount }, "累计退款不能超过原消费金额。", "Total refunds cannot exceed the original expense.")
        try check(recurring.map { !$0.isEmpty && $0.count <= MoneyRecurring.maximumCount && unique($0) } ?? true, "周期账单数据无效。", "Invalid recurring bills.")
        for bill in recurringBills { try bill.validate(in: self) }
        try check(rates.count <= 500 && Set(rates.map { $0.base + $0.quote }).count == rates.count && rates.allSatisfy { Money.currencies.contains($0.base) && Money.currencies.contains($0.quote) && MoneyRate.valid($0.rate) && $0.date.count == 10 && $0.fetchedAt.timeIntervalSince1970.isFinite && $0.source.count <= 80 }, "汇率数据无效。", "Invalid exchange rate data.")
    }
    func merging(_ incoming: Self) throws -> Self {
        // A divergent shared account/transaction needs an explicit full restore, never silent double posting.
        func merge<T: Identifiable & Equatable>(_ existing: [T], _ added: [T]) throws -> [T] where T.ID: Hashable {
            let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for value in added { if let old = byID[value.id], old != value { throw TaskBackup.invalid(L("记账记录存在不同版本，无法安全合并。请先导出当前备份，再选择完整替换恢复。", "Conflicting ledger records cannot be merged safely. Export a current backup, then use full replacement.")) } }
            return existing + added.filter { byID[$0.id] == nil }
        }
        try validate(); try incoming.validate()
        guard baseCurrency == incoming.baseCurrency else { throw TaskBackup.invalid(L("本位币不同，不能合并记账数据。", "Ledgers with different base currencies cannot be merged.")) }
        var result = self
        result.version = max(version, incoming.version)
        result.accounts = try merge(accounts, incoming.accounts); result.books = try merge(books, incoming.books)
        result.categories = try merge(categories, incoming.categories); result.entries = try merge(entries, incoming.entries)
        let bills = try merge(recurringBills, incoming.recurringBills)
        result.recurring = bills.isEmpty ? nil : bills
        for rate in incoming.rates where !result.rates.contains(where: { $0.base == rate.base && $0.quote == rate.quote }) { result.rates.append(rate) }
        try result.validate(); return result
    }
}
