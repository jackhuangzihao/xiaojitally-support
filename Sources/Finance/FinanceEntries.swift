import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

extension FinanceHome {
    var billsPage: some View {
        let entries = filtered
        let trash = selection == "trash"
        let days = Dictionary(grouping: entries) { Dates.calendar.startOfDay(for: $0.date) }
        let keys = days.keys.sorted(by: >)
        let showBook = accountDetailID != nil || (bookFilterID == nil && data.books.count > 1)
        let balances: [UUID: Decimal] = !trash && showRunningBalances ? accountDetailID.map { data.runningBalances($0) } ?? [:] : [:]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 14) {
                    if trash {
                        bookSelector
                        Text(L("删除的账单不计入余额和统计，可随时恢复。", "Deleted entries are excluded from balances and totals, and can be restored.")).font(.callout).foregroundStyle(.secondary)
                    } else {
                        if let place = statsReturn, accountDetailID == nil {
                            Button { backToStats(place) } label: { Label(L("返回统计", "Back to Statistics"), systemImage: "chevron.left") }
                                .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command).help(L("回到刚才的统计（⌘[）", "Back to where you were in Statistics (⌘[)"))
                        }
                        if let account = selectedAccount { accountHeading(account) }
                        periodHeader
                    }
                    filterChips
                    if !trash {
                        if let account = selectedAccount { accountOverview(account, entries: entries) }
                        else { overview(entries) }
                    }
                }.padding(.horizontal, compact ? 4 : 24).padding(.top, 18).padding(.bottom, 6)
                if entries.isEmpty { emptyState.padding(.top, 40).frame(maxWidth: .infinity) }
                ForEach(keys, id: \.self) { day in
                    Section {
                        ForEach(days[day] ?? []) { entry in
                            FinanceEntryRow(entry: entry, data: data, showBook: showBook, hidden: hidden, accountID: trash ? nil : accountDetailID, balanceAfter: balances[entry.id],
                                            restore: trash ? { restore(entry) } : nil,
                                            open: { if !trash { editor = EntryRequest(entry: entry, expected: entry) } }) { actions(entry) }
                        }
                    } header: { dayHeader(day, days[day] ?? []) }
                }
            }.padding(.horizontal, compact ? 12 : 14).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: "\(entriesCurrency)-\(data.entries.map(\.date).min()?.timeIntervalSince1970 ?? 0)") {
            await loadRates(since: data.entries.map(\.date).min() ?? Date(), currency: entriesCurrency)
        }
    }
    @ViewBuilder func actions(_ entry: MoneyEntry) -> some View {
        if entry.deletedAt == nil {
            Button(L("编辑", "Edit")) { editor = EntryRequest(entry: entry, expected: entry) }
            if entry.kind == .expense || entry.kind == .income || entry.kind == .transfer { Button(L("再记一笔同样的", "Record another like this")) { duplicate(entry) } }
            if entry.kind == .expense {
                Button(data.remainingRefund(for: entry.id) > 0 ? L("记录退款", "Record refund") : L("已全额退款", "Fully refunded")) { newRefund(entry) }
                    .disabled(data.remainingRefund(for: entry.id) <= 0)
            }
            if let id = entry.taskID { Button(L("查看关联任务", "Open linked task")) { openTask(id) } }
            if let account = data.account(entry.accountID) { Button(L("查看 \(account.name) 的账单", "Show \(account.name) entries")) { showAccount(account.id) } }
            Divider()
            Button(L("删除", "Delete"), role: .destructive) { confirmDelete = entry }
        } else { Button(L("恢复账单", "Restore entry")) { restore(entry) } }
    }
    @ViewBuilder private var emptyState: some View {
        if selection == "trash" {
            ContentUnavailableView(L("没有删除的账单", "No deleted entries"), systemImage: "trash")
        } else if drilldown != nil || accountFilter != nil || categoryFilter != nil || kindFilter != nil || !search.isEmpty {
            ContentUnavailableView { Label(L("没有符合条件的账单", "No matching entries"), systemImage: "line.3.horizontal.decrease.circle") } actions: {
                Button(L("清除筛选", "Clear filters")) { drilldown = nil; accountFilter = nil; categoryFilter = nil; kindFilter = nil; search = "" }
            }
        } else {
            ContentUnavailableView { Label(L("这段时间还没有账单", "No entries yet"), systemImage: "tray") } description: {
                Text(compact ? L("点右上角 ＋ 记一笔，选分类、输金额就好。", "Tap +, pick a category and type the amount.") : L("点右上角 ＋ 或按 ⌘N 记一笔，选分类、输金额就好。", "Press + or ⌘N, pick a category and type the amount."))
            } actions: { Button(L("记一笔", "New entry"), action: newEntry).buttonStyle(.borderedProminent) }
        }
    }
    private func dayHeader(_ day: Date, _ items: [MoneyEntry]) -> some View {
        let spent = entryTotals(items, income: false)
        let earned = entryTotals(items, income: true)
        let flow = accountDetailID.map { data.accountFlow($0, in: items) }
        return (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5)) : AnyLayout(HStackLayout(spacing: 12))) {
            Text(Dates.label(day, pattern: "M月d日 EEEE") + (Dates.calendar.isDateInToday(day) ? L(" · 今天", " · Today") : ""))
            if !compact { Spacer() }
            HStack(spacing: 12) {
            if let flow, let account = selectedAccount {
                if flow.outgoing != 0 { Text(L("出 ", "Out ") + display(flow.outgoing, account.currency)) }
                if flow.incoming != 0 { Text(L("入 ", "In ") + display(flow.incoming, account.currency)) }
            } else {
                if spent.total != 0 || spent.missing > 0 { Text((spent.missing > 0 && spent.convertedCount > 0 ? L("支出小计 ", "Out subtotal ") : L("支 ", "Out ")) + totalDisplay(spent)) }
                if earned.total != 0 || earned.missing > 0 { Text((earned.missing > 0 && earned.convertedCount > 0 ? L("收入小计 ", "In subtotal ") : L("收 ", "In ")) + totalDisplay(earned)) }
            }
            }
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 5)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
    }
    private func accountHeading(_ account: MoneyAccount) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 0) {
            HStack(spacing: 12) {
                Button { selection = "accounts" } label: {
                    Label(L("资产", "Assets"), systemImage: "chevron.left").fixedSize()
                        .frame(minHeight: compact ? 44 : nil)
                }.buttonStyle(.borderless)
                if !compact { Divider().frame(height: 18); accountIdentity(account) }
                Spacer(minLength: 8)
                Menu {
                    Button(L("全部账单", "All entries")) { accountDetailID = nil; accountFilter = nil; scope = ""; search = ""; categoryFilter = nil; kindFilter = nil; drilldown = nil }
                    Button(L("编辑账户", "Edit account")) { entity = EntityRequest(kind: .account, existingID: account.id) }
                    Button(L("核对余额", "Check balance")) { reconcile(account) }
                } label: {
                    if compact {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                            .accessibilityLabel(L("账户设置", "Account settings"))
                    } else { Label(L("账户设置", "Account settings"), systemImage: "ellipsis.circle") }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if compact { accountIdentity(account) }
        }
    }
    private func accountIdentity(_ account: MoneyAccount) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MoneyIcon(symbol: account.iconSymbol, emoji: account.emoji, tint: .accentColor, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.name).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text([account.currency, account.archived ? L("已归档", "Archived") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func accountOverview(_ account: MoneyAccount, entries: [MoneyEntry]) -> some View {
        let flow = data.accountFlow(account.id, in: entries)
        let narrowed = !search.isEmpty || categoryFilter != nil || kindFilter != nil || drilldown != nil
        let span = billRange
        let opening: Decimal = span.map { data.balance(account.id, before: $0.start) } ?? account.opening
        let openingLabel = span == nil ? L("期初余额 ", "Opening balance ") : L("期初 ", "Start ")
        return VStack(alignment: .leading, spacing: 12) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 24))) {
                metric(L("账户余额", "Account balance"), display(data.balance(account.id), account.currency), size: 30)
                    .help(L("全部账本、全部日期的账面余额，含期初余额；不随下面的日期或筛选变化。", "Book balance across all books and dates, including the opening balance. It does not change with filters."))
                if !compact { Spacer() }
                metricPair((narrowed ? L("筛选流入", "Filtered in") : L("资金流入", "Money in"), display(flow.incoming, account.currency)),
                           (narrowed ? L("筛选流出", "Filtered out") : L("资金流出", "Money out"), display(flow.outgoing, account.currency)))
            }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                if !narrowed {
                    Text(openingLabel + display(opening, account.currency))
                    if let span = billRange { Text(L("期末 ", "End ") + display(data.balance(account.id, before: span.end), account.currency)) }
                }
                if !compact { Spacer() }
                Text(L("净变动 ", "Net change ") + display(flow.incoming - flow.outgoing, account.currency))
            }.font(.caption).foregroundStyle(.secondary)
            Text(L("全部账本 · 流入含转入、退款，流出含转出、手续费，余额调整按增减计入。", "All books · Includes transfers, refunds, fees and balance adjustments."))
                .font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit().padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }
    func overview(_ entries: [MoneyEntry]) -> some View {
        let spent = entryTotals(entries, income: false)
        let earned = entryTotals(entries, income: true)
        let balance = MoneyStatisticsTotal(total: earned.total - spent.total, missing: earned.missing + spent.missing, estimateDates: earned.estimateDates.union(spent.estimateDates))
        let isMonth = selection == "stats" ? period == .month : dateRange == .month
        let hasFilters = accountFilter != nil || categoryFilter != nil || kindFilter != nil || drilldown != nil || !search.isEmpty
        let budget: Decimal? = isMonth && !hasFilters ? data.budget(for: bookFilterID, in: entries) : nil
        return VStack(alignment: .leading, spacing: 10) {
            if let account = data.balanceAccount(bookID: bookFilterID, filteredAccountID: accountFilter) {
                bookAccountBalance(account)
                Divider().padding(.vertical, 4)
            } else if let book = data.book(bookFilterID), accountFilter == nil {
                Button { entity = EntityRequest(kind: .book, existingID: book.id) } label: {
                    Label(L("选择默认账户", "Choose a default account"), systemImage: "creditcard")
                        .frame(minHeight: compact ? 44 : nil)
                }.buttonStyle(.borderless)
                Text(data.account(book.defaultAccountID)?.archived == true
                     ? L("原默认账户已归档，请选择其他账户。", "The previous default account is archived. Choose another account.")
                     : L("选定后，这里会显示资产中的账户余额。", "Choose an account to see its balance from Assets here."))
                    .font(.caption).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
            }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 32))) {
                metric(totalLabel(L("支出", "Spending"), spent), totalDisplay(spent), size: compact ? 24 : 30)
                if !compact { Spacer(minLength: 0) }
                metricPair((totalLabel(L("收入", "Income"), earned), totalDisplay(earned)),
                           (L("本期结余", "Period net"), balanceDisplay(spent: spent, earned: earned, currency: entriesCurrency)))
            }
            Text(L("本期结余为所选范围的收入减支出，不含账户初始余额。", "Period net is income minus spending in this view; it excludes opening balances."))
                .font(.caption).foregroundStyle(.secondary)
            if let budget {
                budgetBar(spent: data.budgetSpending(entries, for: bookFilterID), budget: budget,
                          books: data.budgetBooks(for: bookFilterID, in: entries), entries: entries)
            }
            VStack(alignment: .leading, spacing: 6) {
                (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))) {
                    Text(L("合计币种 · ", "Totals currency · ") + entriesCurrency)
                    if !entriesCurrencyRaw.isEmpty {
                        Button(L("恢复自动币种", "Use automatic currency")) { entriesCurrencyRaw = "" }
                            .buttonStyle(.borderless).frame(minHeight: compact ? 44 : nil)
                    }
                }.foregroundStyle(.secondary)
            }.font(.caption)
            if !balance.estimateDates.isEmpty {
                Text(L("部分换算使用缓存参考汇率：", "Some conversions use cached reference rates: ") + balance.estimateDates.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            missingAmounts(balance.missing)
        }
        .padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
    }
    private func bookAccountBalance(_ account: MoneyAccount) -> some View {
        let label = accountFilter == nil ? L("默认账户余额", "Default account balance") : L("账户余额", "Account balance")
        return VStack(alignment: .leading, spacing: 6) {
            Button { showAccount(account.id) } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            MoneyIcon(symbol: account.iconSymbol, emoji: account.emoji, tint: .accentColor, size: 28)
                            Text(account.name + " · " + account.currency)
                                .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        }
                        metric(label, display(data.balance(account.id), account.currency), size: compact ? 24 : 26)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityHint(L("查看这个账户在所有账本中的账单", "View this account's entries across all books"))
            Text(L("与资产页一致 · 含初始余额及所有账本、所有日期的变动。", "Same balance as Assets: opening funds plus activity across all books and dates."))
                .font(.caption).foregroundStyle(.secondary)
            if accountFilter == nil, let book = data.book(bookFilterID) {
                Button(L("更改默认账户", "Change default account")) { entity = EntityRequest(kind: .book, existingID: book.id) }
                    .buttonStyle(.borderless).font(.caption).frame(minHeight: compact ? 44 : nil)
            }
        }
    }
    var sampleMessage: String {
        guard let c = data.sampleCleanup else { return "" }
        var parts = [L("将删除 \(c.entries) 笔示例账单、\(c.accounts) 个示例账户和 \(c.books) 个示例账本。", "Deletes \(c.entries) example entries, \(c.accounts) example accounts and \(c.books) example books.")]
        if c.ownEntries > 0 { parts.append(L("其中 \(c.ownEntries) 笔是你记在示例账户上的账单，账户删除后无法保留，也会一起删除。", "\(c.ownEntries) of them are your own entries on example accounts and go with those accounts.")) }
        if c.moved > 0 {
            var after = data; after.removeSamples()
            let home = after.books.first { !$0.archived }?.name ?? ""
            parts.append(L("你记在示例账本里的 \(c.moved) 笔会移到“\(home)”。", "\(c.moved) of your entries in example books move to “\(home)”."))
        }
        parts.append(L("清除前会先保存一份完整备份。", "A full backup is saved first."))
        return parts.joined(separator: "\n")
    }
    @ViewBuilder func missingAmounts(_ count: Int) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("\(count) 笔金额尚未折算，合计不完整。", "\(count) amounts are unconverted; totals are incomplete."), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                if !conversionScope.missingConversionEntries.isEmpty {
                    Button { conversionRequest = MoneyConversionRequest(ledger: conversionScope) } label: {
                        Label(L("补全折算…", "Complete conversions…"), systemImage: "arrow.triangle.2.circlepath")
                            .frame(minHeight: compact ? 44 : nil)
                    }.buttonStyle(.borderless).font(.callout)
                } else {
                    Text(L("所选显示币种缺少可用报价，可切换币种或稍后重试。账单已有的折算金额保持不变。", "Quotes for this display currency are unavailable. Choose another currency or retry later; recorded conversions stay unchanged."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var conversionScope: FinanceData {
        var snapshot = data
        snapshot.entries = selection == "stats" ? statsEntries(range) : filtered
        return snapshot
    }
    func prepareConversion(_ entries: [MoneyEntry]) {
        var snapshot = data; snapshot.entries = entries
        conversionRequest = MoneyConversionRequest(ledger: snapshot)
    }
    private func budgetBar(spent: MoneyStatisticsTotal, budget: Decimal, books: [MoneyBook], entries: [MoneyEntry]) -> some View {
        let ratio = budget > 0 ? min(1, max(0, double(spent.total / budget))) : 0
        let over = spent.total > budget
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if books.count == 1 { entity = EntityRequest(kind: .book, existingID: books[0].id) }
                else { selection = "manage" }
            } label: {
                Label(L("月预算 · ", "Monthly budget · ") + books.map(\.name).joined(separator: "、"), systemImage: "pencil")
                    .font(.caption.weight(.medium)).multilineTextAlignment(.leading)
                    .frame(minHeight: compact ? 44 : nil, alignment: .leading)
            }.buttonStyle(.borderless).help(L("修改这些账本的预算", "Edit these books’ budgets"))
            if spent.complete { MoneyBar(value: ratio, tint: over ? .red : ratio > 0.8 ? .orange : .accentColor) }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L("预算 ", "Budget ") + display(budget) + " · " + data.baseCurrency).fixedSize()
                    Spacer(minLength: 12)
                    budgetRemaining(spent, budget: budget).fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("预算 ", "Budget ") + display(budget) + " · " + data.baseCurrency)
                    budgetRemaining(spent, budget: budget)
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if spent.missing > 0 {
                Text(L("预算范围内 \(spent.missing) 笔金额待折算，补全后显示进度和剩余额度。", "\(spent.missing) amounts in these books need conversion before budget progress and remaining amounts are shown."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("补全预算折算…", "Complete budget conversions…")) {
                    let ids = Set(books.map(\.id))
                    prepareConversion(entries.filter { $0.deletedAt == nil && $0.bookID.map(ids.contains) == true
                        && $0.originalStatistics(income: false, feeCurrency: nil) != nil })
                }.buttonStyle(.borderless).font(.callout).frame(minHeight: compact ? 44 : nil)
            }
            if bookFilterID == nil {
                Text(L("预算仅包含以上账本；上方收支包含全部账本。", "The budget covers the books above; totals include all books."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func budgetRemaining(_ spent: MoneyStatisticsTotal, budget: Decimal) -> some View {
        Text(!spent.complete ? L("剩余额度待折算", "Remaining amount pending conversion") : spent.total > budget
             ? L("超出 ", "Over by ") + display(spent.total - budget) : L("剩余 ", "Left ") + display(budget - spent.total))
            .foregroundStyle(!spent.complete ? Color.orange : spent.total > budget ? .red : .secondary)
    }

    // MARK: Statistics

    /// The currency statistics are shown in; defaults to the ledger's base currency.
}

/// One entry line. Hover lives here, so moving the pointer never re-renders the whole list.
struct FinanceEntryRow<Actions: View>: View {
    @AppStorage("appLanguage") var language = "system"
    let entry: MoneyEntry
    let data: FinanceData
    let showBook: Bool
    let hidden: Bool
    var accountID: UUID? = nil
    var balanceAfter: Decimal? = nil
    var restore: (() -> Void)?
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State var hovering = false
    var body: some View {
        let icon = data.icon(entry)
        HStack(spacing: 12) {
            MoneyIcon(symbol: icon.symbol, emoji: icon.emoji, tint: icon.tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amount).font(.body.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle((accountID.map { entry.accountChange(for: $0) > 0 } ?? (entry.kind == .income || entry.kind == .refund)) ? Color.green : .primary)
                if let secondary { Text(secondary).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let balanceAfter, let account = data.account(accountID) {
                    Text(L("余额 ", "Balance ") + (hidden ? "••••" : Money.format(balanceAfter, account.currency)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(L("这笔之后的账户账面余额，包含未显示的其他流水。相同时间按列表顺序计算。", "Account balance after this entry, including other hidden entries. Equal timestamps follow list order."))
                }
            }
            if let restore { Button(L("恢复", "Restore"), action: restore).controlSize(.small) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu(menuItems: actions)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(restore == nil ? [.isButton] : [])
        .accessibilityAction { if restore == nil { open() } }
    }
    var detail: String {
        var parts = [Dates.label(entry.date, pattern: "HH:mm")]
        if let category = data.category(entry.categoryID), category.label != entry.title, entry.kind != .transfer { parts.append(data.categoryPath(category.id)) }
        switch entry.kind {
        case .transfer:
            if let accountID { parts.append(accountID == entry.destinationID ? L("转入", "Transfer in") : L("转出", "Transfer out")) }
            parts.append((data.account(entry.accountID)?.name ?? "") + " → " + (data.account(entry.destinationID)?.name ?? ""))
        case .refund: parts.append(L("退款", "Refund")); if accountID == nil, let a = data.account(entry.accountID) { parts.append(a.name) }
        default: if accountID == nil, let a = data.account(entry.accountID) { parts.append(a.name) }
        }
        if showBook, let book = data.book(entry.bookID) { parts.append(book.name) }
        if !entry.tags.isEmpty { parts.append(entry.tags) }
        if entry.kind != .transfer && entry.kind != .adjustment && entry.baseAmount == nil { parts.append(L("待折算", "Unconverted")) }
        return parts.joined(separator: " · ")
    }
    var amount: String {
        guard !hidden else { return "••••" }
        if let id = accountID, let account = data.account(id) {
            let change = entry.accountChange(for: id)
            return (change > 0 ? "+" : "") + Money.format(change, account.currency)
        }
        let text = Money.format(entry.amount, entry.currency)
        switch entry.kind {
        case .expense: return "-" + text
        case .income, .refund: return "+" + text
        case .adjustment: return entry.amount > 0 ? "+" + text : text
        case .transfer: return text
        }
    }
    /// What actually left or reached the account when its currency differs, else the base-currency equivalent.
    var secondary: String? {
        guard !hidden else { return nil }
        if let id = accountID, let viewing = data.account(id) {
            if entry.fee > 0, entry.accountID == id { return L("含手续费 ", "Includes fee ") + Money.format(entry.fee, viewing.currency) }
            if entry.currency != viewing.currency { return L("原金额 ", "Original ") + Money.format(entry.amount, entry.currency) }
            return nil
        }
        let account = data.account(entry.accountID)
        if let account, account.currency != entry.currency, entry.accountAmount != 0 {
            let out = entry.kind == .expense || entry.kind == .transfer
            return (out ? L("实扣 ", "Charged ") : L("实收 ", "Received ")) + Money.format(entry.accountAmount, account.currency)
        }
        if entry.kind == .transfer, let d = data.account(entry.destinationID), d.currency != entry.currency {
            let received = L("到账 ", "Received ") + Money.format(entry.destinationAmount, d.currency)
            return received + (entry.fee > 0 ? " · " + L("手续费 ", "Fee ") + Money.format(entry.fee, account?.currency ?? entry.currency) : "")
        }
        if entry.fee > 0 { return L("手续费 ", "Fee ") + Money.format(entry.fee, account?.currency ?? entry.currency) }
        if entry.currency != data.baseCurrency, let base = entry.baseAmount { return "≈ " + Money.format(base, data.baseCurrency) }
        return nil
    }
}
