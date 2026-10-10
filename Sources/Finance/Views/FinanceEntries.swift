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
            // Keep changing summary heights out of the ledger's lazy height estimates during saves.
            VStack(alignment: .leading, spacing: 0) {
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
                        else if !data.accounts.isEmpty || !data.entries.isEmpty || data.books.contains(where: { $0.budget != nil }) { overview(entries) }
                    }
                }.padding(.horizontal, Self.pageInset(compact)).padding(.top, 18).padding(.bottom, 6)
                if !trash && drilldown == nil {
                    PendingEntriesSection(entries: pendingEntries, data: data, hidden: hidden,
                                          open: { editor = EntryRequest(entry: $0, expected: $0) },
                                          confirm: confirmPendingItem,
                                          confirmWithChanges: confirmPendingItemWithChanges,
                                          remove: { confirmDelete = $0 },
                                          editBill: { editingRecurring = RecurringEditRequest(bill: $0) },
                                          stopBill: { stoppingRecurring = $0 },
                                          restartBill: { restartRecurring(from: $0) },
                                          postToday: postOccurrenceToday,
                                          skip: skipOccurrence)
                }
                if entries.isEmpty && (trash || pendingEntries.isEmpty || drilldown != nil) { emptyState.padding(.top, 40).frame(maxWidth: .infinity) }
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(keys, id: \.self) { day in
                        Section {
                            let items = days[day] ?? []
                            // Each day's entries read as one card.
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                                FinanceEntryRow(entry: entry, data: data, showBook: showBook, hidden: hidden, accountID: trash ? nil : accountDetailID, balanceAfter: balances[entry.id],
                                                restore: trash ? { restore(entry) } : nil,
                                                task: entry.taskID.flatMap(taskLink),
                                                openTask: entry.taskID.map { id in { openTask(id) } },
                                                open: { if !trash { editor = EntryRequest(entry: entry, expected: entry) } }) { actions(entry) }
                                    .padding(.horizontal, Design.Spacing.xs).padding(.vertical, 2)
                                    .background(CardRowBackground(first: index == 0, last: index == items.count - 1))
                                    .overlay(alignment: .top) { if index > 0 { Divider().padding(.leading, 58) } }
                                    .padding(.horizontal, Self.pageInset(compact))
                            }
                        } header: { dayHeader(day, days[day] ?? []) }
                    }
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
            if (entry.kind == .expense || entry.kind == .income) && entry.refundOf == nil && data.recurringBill(entry.recurringID) == nil {
                Button(L("设为周期账单…", "Make recurring…")) { restartRecurring(from: entry) }
            }
            if entry.isDueForConfirmation() {
                Button(L("确认入账…", "Confirm entry…")) { editor = EntryRequest(entry: entry, expected: entry, confirmingPending: true) }
            }
            if entry.kind == .expense && !entry.isPending {
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
        } else if data.entries.isEmpty && data.accounts.isEmpty {
            ContentUnavailableView {
                Label(L("记下第一笔收支", "Record your first entry"), systemImage: "square.and.pencil")
            } description: {
                Text(L("直接记一笔，或先添加银行卡、现金等账户来管理余额。账本用于归类这些收支。", "Record an entry now, or add a bank or cash account to track its balance. Books organise your entries."))
            } actions: {
                Button(L("记一笔", "New entry"), action: newEntry).buttonStyle(.borderedProminent)
                Button { entity = EntityRequest(kind: .account) } label: {
                    Label(L("添加账户", "Add account"), systemImage: "plus").frame(minHeight: 44)
                }.buttonStyle(.borderless)
            }
        } else {
            ContentUnavailableView { Label(L("这段时间还没有账单", "No entries yet"), systemImage: "tray") } description: {
                Text(compact ? L("点右上角 ＋ 记一笔，选分类、输金额就好。", "Tap +, pick a category and type the amount.") : L("点右上角 ＋ 或按 ⌘N 记一笔，选分类、输金额就好。", "Press + or ⌘N, pick a category and type the amount."))
            } actions: { Button(L("记一笔", "New entry"), action: newEntry).buttonStyle(.borderedProminent) }
        }
    }
    /// One left and right inset for the summary, pending card and entry list, so their edges line up.
    static func pageInset(_ compact: Bool) -> CGFloat { compact ? Design.Spacing.xs : 10 }
    private func dayHeader(_ day: Date, _ items: [MoneyEntry]) -> some View {
        let spent = entryTotals(items, income: false)
        let earned = entryTotals(items, income: true)
        let flow = accountDetailID.map { data.accountFlow($0, in: items) }
        return (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))) {
            HStack(spacing: 6) {
                Text(Dates.label(day, pattern: "M月d日 EEEE")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if Dates.calendar.isDateInToday(day) { Text(L("今天", "Today")).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
            }
            if !compact { Spacer() }
            HStack(spacing: 12) {
            if let flow, let account = selectedAccount {
                if flow.outgoing != 0 { Text(L("流出 ", "Out ") + display(flow.outgoing, account.currency)) }
                if flow.incoming != 0 { Text(L("流入 ", "In ") + display(flow.incoming, account.currency)) }
            } else {
                if spent.total != 0 || spent.missing > 0 { Text((spent.missing > 0 && spent.convertedCount > 0 ? L("支出小计 ", "Out subtotal ") : L("支出 ", "Out ")) + totalDisplay(spent)) }
                if earned.total != 0 || earned.missing > 0 { Text((earned.missing > 0 && earned.convertedCount > 0 ? L("收入小计 ", "In subtotal ") : L("收入 ", "In ")) + totalDisplay(earned)) }
            }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, Self.pageInset(compact) + 6).padding(.top, 18).padding(.bottom, 6)
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
        }.monospacedDigit().padding(compact ? Design.Spacing.l : 20).cardSurface()
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
            // One number leads; income and net sit beside it. Explanations live behind the info button.
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(totalLabel(L("支出", "Spending"), spent)).font(.caption).foregroundStyle(.secondary)
                        summaryInfo(budgetNote: budget != nil && bookFilterID == nil)
                    }
                    Text(totalDisplay(spent)).font(.heroAmount).lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityLabel(totalLabel(L("支出", "Spending"), spent)).accessibilityValue(totalDisplay(spent))
                }
                if !compact { Spacer(minLength: 0) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { summaryFigures(spent: spent, earned: earned) }
                    VStack(alignment: .leading, spacing: 8) { summaryFigures(spent: spent, earned: earned) }
                }
            }
            if let budget {
                budgetBar(spent: data.budgetSpending(entries, for: bookFilterID), budget: budget,
                          books: data.budgetBooks(for: bookFilterID, in: entries), entries: entries)
                    .padding(.top, 12).overlay(alignment: .top) { Divider() }
            }
            if !entriesCurrencyRaw.isEmpty {
                // A chosen totals currency stays visible with its way back; the automatic one is in the info popover.
                HStack(spacing: 8) {
                    Text(L("合计币种 · ", "Totals currency · ") + entriesCurrency).foregroundStyle(.secondary)
                    Button(L("恢复自动币种", "Use automatic currency")) { entriesCurrencyRaw = "" }
                        .buttonStyle(.borderless).frame(minHeight: compact ? 44 : nil)
                }.font(.caption)
            }
            if !balance.estimateDates.isEmpty {
                Text(L("部分换算使用缓存参考汇率：", "Some conversions use cached reference rates: ") + balance.estimateDates.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
            missingAmounts(balance.missing)
        }
        .padding(compact ? Design.Spacing.l : 20).cardSurface()
    }
    /// Income and period net beside the spending total, each in its own small block.
    @ViewBuilder private func summaryFigures(spent: MoneyStatisticsTotal, earned: MoneyStatisticsTotal) -> some View {
        summaryFigure(totalLabel(L("收入", "Income"), earned), totalDisplay(earned), tint: earned.total > 0 && !hidden ? .green : .primary)
        summaryFigure(L("本期结余", "Period net"), balanceDisplay(spent: spent, earned: earned, currency: entriesCurrency), tint: .primary)
    }
    private func summaryFigure(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.figure).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, Design.Spacing.m).padding(.vertical, Design.Spacing.s)
        .frame(minWidth: compact ? nil : 120, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous))
        .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(value)
    }
    /// What the totals mean, without spending a line of the card on it.
    private func summaryInfo(budgetNote: Bool) -> some View {
        Button { showSummaryInfo = true } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: compact ? 44 : 18, minHeight: compact ? 44 : 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("合计说明", "About these totals"))
        .help(L("合计说明", "About these totals"))
        .popover(isPresented: $showSummaryInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("本期结余为所选范围的收入减支出，不含账户初始余额。", "Period net is income minus spending in this view; it excludes opening balances."))
                Text(L("合计币种 · ", "Totals currency · ") + entriesCurrency + (entriesCurrencyRaw.isEmpty ? L("（自动）", " (automatic)") : ""))
                if budgetNote {
                    Text(L("预算仅包含所列账本；上方收支包含全部账本。", "The budget covers the listed books; totals include all books."))
                }
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .padding(Design.Spacing.l).frame(width: 300, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
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
        let title = Button {
            if books.count == 1 { entity = EntityRequest(kind: .book, existingID: books[0].id) }
            else { selection = "manage" }
        } label: {
            Label(L("月预算 · ", "Monthly budget · ") + books.map(\.name).joined(separator: "、"), systemImage: "pencil")
                .font(.caption.weight(.medium)).multilineTextAlignment(.leading)
                .frame(minHeight: compact ? 44 : nil, alignment: .leading)
        }.buttonStyle(.borderless).help(L("修改这些账本的预算", "Edit these books’ budgets"))
        let amount = Text(display(budget) + " · " + data.baseCurrency).font(.caption.weight(.semibold)).monospacedDigit()
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title.fixedSize(); amount.fixedSize()
                    Spacer(minLength: 12)
                    budgetRemaining(spent, budget: budget).font(.caption).monospacedDigit().fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    title; amount
                    budgetRemaining(spent, budget: budget).font(.caption).monospacedDigit()
                }
            }
            if spent.complete { MoneyBar(value: ratio, tint: over ? .red : ratio > 0.8 ? .orange : .accentColor) }
            if spent.missing > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { budgetConversionNote(spent.missing); budgetConversionButton(books: books, entries: entries) }
                    VStack(alignment: .leading, spacing: 4) { budgetConversionNote(spent.missing); budgetConversionButton(books: books, entries: entries) }
                }
            }
        }
    }
    private func budgetConversionNote(_ count: Int) -> some View {
        Label(L("\(count) 笔金额待折算，补全后显示进度", "\(count) amounts need conversion before progress is shown"), systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
    }
    private func budgetConversionButton(books: [MoneyBook], entries: [MoneyEntry]) -> some View {
        Button(L("补全折算…", "Complete conversions…")) {
            let ids = Set(books.map(\.id))
            prepareConversion(entries.filter { $0.deletedAt == nil && $0.bookID.map(ids.contains) == true
                && $0.originalStatistics(income: false, feeCurrency: nil) != nil })
        }.buttonStyle(.borderless).font(.caption.weight(.semibold)).frame(minHeight: compact ? 44 : nil)
    }
    private func budgetRemaining(_ spent: MoneyStatisticsTotal, budget: Decimal) -> some View {
        Text(!spent.complete ? L("剩余额度待折算", "Remaining amount pending conversion") : spent.total > budget
             ? L("超出 ", "Over by ") + display(spent.total - budget) : L("剩余 ", "Left ") + display(budget - spent.total))
            .foregroundStyle(!spent.complete ? Color.orange : spent.total > budget ? .red : .secondary)
    }

    // MARK: Statistics

    /// The currency statistics are shown in; defaults to the ledger's base currency.
}
