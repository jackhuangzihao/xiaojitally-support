import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Account, book and category editor

struct EntityRequest: Identifiable { var id = UUID(); var kind: FinanceEntityKind; var existingID: UUID?; var income = false; var parentID: UUID? = nil }
struct FinanceEntityDraft {
    var original: FinanceData
    var kind: FinanceEntityKind
    var id: UUID?
    var name: String, currency: String, opening: String, symbol: String
    var archived: Bool
    var accountID: UUID?
    var income = false
    var color = ""
    var type = ""
    var budget = ""
    var emoji = ""
    var bankName = ""
    var assetRate = ""
    var assetCurrency = "CNY"
    var parentID: UUID? = nil
}
struct FinanceEntityEditor: View {
    static let symbols = ["fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "cart", "bag", "basket", "tshirt", "tram", "car", "bus", "fuelpump", "airplane",
                          "house", "bolt", "drop", "iphone", "wifi", "heart", "cross.case", "pills", "figure.run", "gamecontroller", "film", "music.note",
                          "book", "graduationcap", "pawprint", "gift", "scissors", "wrench.and.screwdriver", "creditcard", "banknote", "rosette",
                          "chart.line.uptrend.xyaxis", "briefcase", "envelope", "sparkles", "tag", "plus.circle", "ellipsis.circle"]
    @AppStorage("appLanguage") private var language = "system"
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @State private var ready = false
    @FocusState private var textFocused: Bool
    let kind: FinanceEntityKind
    let id: UUID?
    @State private var original: FinanceData
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var currency: String
    @State private var opening: String
    @State private var archived: Bool
    @State private var accountID: UUID?
    @State private var symbol: String
    @State private var emoji: String
    @State private var showIconPicker = false
    @State private var income: Bool
    @State private var color: String
    @State private var type: String
    @State private var budget: String
    @State private var bankName: String
    @State private var assetRate = ""
    @State private var assetCurrency: String
    @State private var parentID: UUID?
    @State private var confirmRemoval = false
    @State private var correctingOpening = false
    @State private var confirmOpening = false
    @State private var reconciliation: MoneyEntry?
    @State private var error: String?
    init(kind: FinanceEntityKind, id: UUID? = nil, income: Bool = false, parentID: UUID? = nil, data: FinanceData) {
        self.kind = kind; self.id = id; _original = State(initialValue: data)
        let account = data.accounts.first { $0.id == id }, book = data.books.first { $0.id == id }, category = data.categories.first { $0.id == id }
        _name = State(initialValue: kind == .account ? account?.name ?? "" : kind == .book ? book?.name ?? "" : category?.label ?? "")
        let reporting = UserDefaults.standard.string(forKey: "moneyStatsCurrency") ?? ""
        _assetCurrency = State(initialValue: Money.currencies.contains(reporting) ? reporting : data.baseCurrency)
        _currency = State(initialValue: account?.currency ?? data.baseCurrency); _opening = State(initialValue: Money.text(account?.opening ?? 0))
        _archived = State(initialValue: account?.archived ?? book?.archived ?? category?.archived ?? false)
        _accountID = State(initialValue: book?.defaultAccountID)
        _symbol = State(initialValue: kind == .account ? account?.symbol ?? "" : kind == .book ? book?.symbol ?? "" : category?.symbol ?? "")
        _emoji = State(initialValue: kind == .account ? account?.emoji ?? "" : kind == .book ? book?.emoji ?? "" : category?.emoji ?? "")
        _income = State(initialValue: category?.isIncome ?? income)
        _color = State(initialValue: category?.resolvedColor ?? (income ? "green" : "blue"))
        _type = State(initialValue: (account?.resolvedType ?? .debit).rawValue)
        _budget = State(initialValue: book?.budget.map(Money.text) ?? "")
        _bankName = State(initialValue: account?.bankName ?? "")
        _parentID = State(initialValue: category?.parentID ?? parentID)
    }
    private var bankField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("所属银行", "Bank")).font(.subheadline.weight(.medium))
            TextField(L("可不填", "Optional"), text: $bankName).focused($textFocused).accessibilityLabel(L("所属银行", "Bank"))
            Menu {
                ForEach([L("中国工商银行", "ICBC"), L("中国建设银行", "China Construction Bank"), L("中国银行", "Bank of China"),
                         L("中国农业银行", "Agricultural Bank of China"), L("招商银行", "China Merchants Bank"), L("交通银行", "Bank of Communications"),
                         L("中信银行", "CITIC Bank"), L("浦发银行", "SPD Bank"), L("平安银行", "Ping An Bank"),
                         "Commonwealth Bank", "ANZ", "NAB", "Westpac", "HSBC", "Citibank", "Chase", "Bank of America"], id: \.self) { bank in
                    Button(bank) { bankName = bank }
                }
                Divider()
                Button(L("清除银行", "Clear bank")) { bankName = "" }
            } label: { Label(L("选择所属银行", "Choose bank"), systemImage: "building.columns") }
                .frame(minHeight: 44)
        }
    }
    private var accountRateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("资产参考汇率（可不填）", "Asset exchange rate (optional)")).font(.subheadline.weight(.medium))
            HStack {
                Text("1 " + currency + " =")
                TextField(L("汇率（可不填）", "Rate (optional)"), text: $assetRate).focused($textFocused)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .accessibilityLabel("1 " + currency + L("兑换汇率，单位 ", " in ") + assetCurrency)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(assetCurrency).foregroundStyle(.secondary)
            }
            if let rate = original.assetRate(from: currency, to: assetCurrency) {
                let source = rate.isManual ? L("含手动汇率", "Includes manual rates") : rate.referenceDates.joined(separator: " / ")
                let quote = "1 \(currency) = \(assetRateText(rate.rate)) \(assetCurrency) · \(source)"
                Text(L("当前：", "Current: ") + quote).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("留空使用已有汇率或自动参考价。手动汇率仅改变资产估值，不改变历史账单。", "Leave blank to use stored or automatic reference rates. Manual rates change asset estimates, never historical entries."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var fallbackSymbol: String {
        switch kind {
        case .account: return (MoneyAccountType(rawValue: type) ?? .debit).symbol
        case .book: return "book.closed"
        case .category: return income ? "banknote" : "tag"
        }
    }
    private var chosenSymbol: String { symbol.isEmpty ? fallbackSymbol : symbol }
    private var used: Bool { id.map { original.accountHasHistory($0) } ?? false }
    private var categoryUsed: Bool { kind == .category && id.map { id in original.entries.contains { $0.categoryID == id } || original.categories.contains { $0.parentID == id } } == true }
    var body: some View {
        NavigationStack {
            Form {
                if kind == .account {
                    Text(L("账户是钱放在哪里，例如银行卡或现金。所有账本共用账户余额。", "An account is where you keep money, such as a bank account or cash. Its balance is shared across books."))
                        .font(.callout).foregroundStyle(.secondary)
                } else if kind == .book {
                    Text(L("账本用来归类收支，例如日常、旅行。钱仍由账户管理，不用在新账本里重新录入余额。", "A book groups entries for a purpose, such as everyday spending or travel. Money stays in your accounts; you don't need to enter the balance again."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { showIconPicker = true } label: {
                        VStack(spacing: 4) {
                            MoneyIcon(symbol: chosenSymbol, emoji: emoji.isEmpty ? nil : emoji, tint: kind == .category ? MoneyColor.color(color) : .accentColor, size: 44)
                            Text(L("换图标", "Change icon")).font(.caption2)
                        }
                    }.buttonStyle(.plain).help(L("选择系统图标或苹果表情", "Choose a symbol or emoji"))
                        .popover(isPresented: $showIconPicker) { MoneyIconPicker(symbol: $symbol, emoji: $emoji, fallback: fallbackSymbol) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("名称", "Name")).font(.caption).foregroundStyle(.secondary)
                        TextField(L("名称", "Name"), text: $name).focused($textFocused).textFieldStyle(.roundedBorder).font(.title3)
                    }
                }
                if kind == .category {
                    Picker(L("用于", "Used for"), selection: $income) { Text(L("支出", "Spending")).tag(false); Text(L("收入", "Income")).tag(true) }.pickerStyle(.segmented)
                        .disabled(categoryUsed)
                    if categoryUsed { Text(L("此分类已有账单或子分类，不能在支出和收入之间切换。", "This category has entries or subcategories, so it cannot switch between spending and income.")).font(.caption).foregroundStyle(.secondary) }
                    Picker(L("上级分类", "Parent category"), selection: $parentID) {
                        Text(L("无，作为大类", "None — top level")).tag(nil as UUID?)
                        ForEach(original.categories.filter { $0.id != id && $0.parentID == nil && $0.isIncome == income && (!$0.archived || $0.id == parentID) }) {
                            Text($0.label).tag(Optional($0.id))
                        }
                    }.disabled(id.map { id in original.categories.contains { $0.parentID == id } } ?? false)
                    Text(L("支持大类和子分类两层。大类统计包含它的所有子分类。", "Use a main category and its subcategories. Main category totals include every child."))
                        .font(.caption).foregroundStyle(.secondary)
                    Section(L("颜色", "Color")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                            ForEach(MoneyColor.keys, id: \.self) { key in
                                Button { color = key } label: {
                                    Circle().fill(MoneyColor.color(key)).frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(color == key ? 0.9 : 0), lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel(MoneyColor.label(key)).accessibilityAddTraits(color == key ? [.isSelected] : []).help(MoneyColor.label(key))
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if kind == .account {
                    Picker(L("类型", "Type"), selection: $type) { ForEach(MoneyAccountType.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) } }
                    bankField
                    if used {
                        LabeledContent(L("币种", "Currency"), value: Money.name(currency) + " · " + currency)
                        Text(L("此账户已有账单（含最近删除），为保留历史金额，币种不可更改。需要其他币种时请新建账户。", "This account has entries, including any in Recently Deleted. Its currency stays fixed to preserve historical amounts. Create a separate account for another currency."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker(L("币种", "Currency"), selection: Binding(get: { currency }, set: { currency = $0; assetRate = "" })) { CurrencyPickerItems() }
                    }
                    if currency != assetCurrency { accountRateField }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("期初余额", "Opening balance") + " · " + currency).font(.subheadline.weight(.medium))
                        TextField("0", text: $opening).focused($textFocused).disabled(used && !correctingOpening).monospacedDigit()
                            .accessibilityLabel(L("期初余额", "Opening balance") + " · " + currency)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    if used {
                        HStack {
                            Button(L("核对当前余额…", "Check current balance…"), action: reconcile)
                            if !correctingOpening { Button(L("更正期初余额…", "Correct opening balance…")) { correctingOpening = true } }
                        }
                        if correctingOpening {
                            Text(L("仅用于修正最初填错的金额，会同步改变所有历史余额。调整现在的余额请用“核对当前余额”。", "Use this only to correct the original amount; every historical balance changes. To adjust today's balance, use Check current balance.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    else { Text(L("填开始记账时已有的钱，不算新增收入。信用卡欠款填负数，例如 -1200。", "Enter the money you already have when you start tracking; this is not new income. Enter credit card debt as a negative amount, such as -1200.")).font(.caption).foregroundStyle(.secondary) }
                } else if kind == .book {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("每月预算", "Monthly budget") + " · " + original.baseCurrency).font(.subheadline.weight(.medium))
                        TextField(L("可不填", "Optional"), text: $budget).focused($textFocused).monospacedDigit()
                            .accessibilityLabel(L("每月预算", "Monthly budget"))
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Picker(L("默认账户", "Default account"), selection: $accountID) {
                        Text(L("每次选择", "Choose each time")).tag(nil as UUID?)
                        ForEach(original.accounts.filter { !$0.archived || $0.id == accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) }
                    }
                    Text(L("新账单金额和账单合计默认使用此账户的币种。账户由所有账本共用，不会复制余额。", "New entry amounts and entry totals default to this account's currency. Accounts are shared across books without copying balances.")).font(.caption).foregroundStyle(.secondary)
                }
                if let id {
                    Toggle(kind == .category ? L("隐藏此分类（归档）", "Hide this category (archive)") : L("归档", "Archived"), isOn: $archived)
                        .disabled(kind == .book && !archived && original.bookArchiveBlock(id) != nil)
                    Text(kind == .category
                         ? L("预设分类也可以隐藏。保存后新增账单不再显示此分类，历史账目保留；隐藏大类会同时隐藏子分类，可在已归档分类中恢复。", "Preset categories can be hidden too. Save to remove this option from new entries while keeping history. Hiding a main category includes its children; restore it under Archived categories.")
                         : L("归档后保留历史账目，在新增时隐藏。", "Archiving keeps all history and hides this option for new entries.")).font(.caption).foregroundStyle(.secondary)
                }
                if let id {
                    if let reason = original.removalBlock(kind, id: id) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(L("删除", "Delete"), role: .destructive) { confirmRemoval = true }
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind == .account ? L("账户", "Account") : kind == .book ? L("账本", "Book") : L("分类", "Category"))
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L("完成", "Done")) { textFocused = false } }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button(L("保存", "Save")) { save() }.keyboardShortcut("s", modifiers: .command).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: kind == .account ? 520 : 370, idealHeight: kind == .account ? 610 : 450)
        #endif
        .sheet(item: $reconciliation) { entry in FinanceEntryEditor(entry: entry, expected: nil) }
        .confirmationDialog(L("更正期初余额？", "Correct the opening balance?"), isPresented: $confirmOpening, titleVisibility: .visible) {
            Button(L("确认更正", "Confirm correction")) { save(confirmedOpening: true) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            let old = original.accounts.first { $0.id == id }?.opening ?? 0
            let new = (try? Money.parse(opening, currency: currency, signed: true)) ?? old
            Text(L("期初余额：", "Opening balance: ") + Money.format(old, currency) + " → " + Money.format(new, currency)
                 + "\n" + L("这会更改该账户所有历史余额，不计为收入或支出。调整当前余额请使用“核对当前余额”。", "This changes every historical balance for this account, without counting as income or spending. Use Check current balance to adjust today's balance."))
        }
        .confirmationDialog(L("删除这个项目？", "Delete this item?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(L("删除", "Delete"), role: .destructive, action: remove)
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(kind == .account
                 ? L("将删除此空账户及其期初余额，并清除账本的常用账户设置。无法直接撤销，可从备份恢复。", "Deletes this unused account and its opening balance, and clears book defaults. Restore a backup to undo.")
                 : L("此项目没有关联账单。删除后无法直接撤销，可从备份恢复。", "This item has no linked entries. Restore a backup to undo deletion."))
        }
        .onAppear {
            if let kept = drafts.financeEntity, kept.kind == kind, kept.id == id {
                original = kept.original
                name = kept.name; currency = kept.currency; opening = kept.opening; symbol = kept.symbol; archived = kept.archived; accountID = kept.accountID
                emoji = kept.emoji; bankName = kept.bankName; assetRate = kept.assetRate; assetCurrency = kept.assetCurrency; parentID = kept.parentID; income = kept.income; if !kept.color.isEmpty { color = kept.color }; if !kept.type.isEmpty { type = kept.type }; budget = kept.budget
            }
            correctingOpening = used && opening != Money.text(original.accounts.first { $0.id == id }?.opening ?? 0)
            ready = true; keepEntityDraft()
        }
        .onChange(of: [name, currency, opening, symbol, emoji, color, type, budget, bankName, assetRate, parentID?.uuidString ?? "", "\(archived)-\(income)-\(accountID?.uuidString ?? "")"]) { _, _ in if ready { keepEntityDraft() } }
        .onChange(of: income) { _, _ in
            if let parentID, original.category(parentID)?.isIncome != income { self.parentID = nil }
        }
        .onDisappear { if generation == Store.recovery.generation && Store.recovery.failure == nil { drafts.financeEntity = nil } }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }
    private func keepEntityDraft() {
        drafts.financeEntity = FinanceEntityDraft(original: original, kind: kind, id: id, name: name, currency: currency, opening: opening, symbol: symbol, archived: archived, accountID: accountID,
                                                  income: income, color: color, type: type, budget: budget, emoji: emoji, bankName: bankName, assetRate: assetRate, assetCurrency: assetCurrency, parentID: parentID)
    }
    private func remove() {
        guard let id else { return }
        do {
            try FinanceStore.update(context) { try $0.remove(kind, id: id, expected: original) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func reconcile() {
        guard let id else { return }
        do {
            let data = try FinanceStore.read(context) ?? .initial
            reconciliation = data.reconciliationEntry(for: id)
        } catch { self.error = error.localizedDescription }
    }
    private func save(confirmedOpening: Bool = false) {
        do {
            keepEntityDraft()
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard emoji.isEmpty || TaskList.validEmoji(emoji) else { throw TaskBackup.invalid(L("请选择一个表情，或恢复默认图标。", "Choose one emoji or use the default icon.")) }
            let budgetText = budget.trimmingCharacters(in: .whitespacesAndNewlines)
            let budgetValue: Decimal? = budgetText.isEmpty ? nil : try Money.parse(budgetText, currency: original.baseCurrency)
            if let budgetValue, budgetValue <= 0 { throw TaskBackup.invalid(L("预算需要大于 0，不设预算请留空。", "A budget must be above 0; leave it empty for none.")) }
            if kind == .account, used, !confirmedOpening,
               try Money.parse(opening, currency: currency, signed: true) != original.accounts.first(where: { $0.id == id })?.opening {
                confirmOpening = true; return
            }
            try FinanceStore.update(context) { data in
                switch kind {
                case .account:
                    let value = MoneyAccount(id: id ?? UUID(), name: title, currency: currency, opening: try Money.parse(opening, currency: currency, signed: true), archived: archived, emoji: emoji.isEmpty ? nil : emoji, symbol: symbol.isEmpty ? nil : symbol, type: type, bankName: bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bankName.trimmingCharacters(in: .whitespacesAndNewlines))
                    try data.updateAccount(value, expected: original.accounts.first { $0.id == id }, allowOpeningCorrection: confirmedOpening)
                    let rateText = assetRate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currency != assetCurrency, !rateText.isEmpty {
                        guard data.assetRate(from: currency, to: assetCurrency) == original.assetRate(from: currency, to: assetCurrency) else {
                            throw TaskBackup.invalid(L("汇率已更新，请重新打开后修改。", "Rates have changed. Reopen this editor before changing them."))
                        }
                        try data.setManualRate(from: currency, to: assetCurrency, text: rateText)
                    }
                case .book:
                    let value = MoneyBook(id: id ?? UUID(), name: title, defaultAccountID: accountID, archived: archived, budget: budgetValue, emoji: emoji.isEmpty ? nil : emoji, symbol: symbol.isEmpty ? nil : symbol)
                    try data.updateBook(value, expected: original.books.first { $0.id == id }, baseCurrency: original.baseCurrency)
                case .category:
                    let old = original.categories.first { $0.id == id }
                    // Preserve a built-in name's localization while its display label is unchanged.
                    let stored = old.map { $0.label == title ? $0.name : title } ?? title
                    let value = MoneyCategory(id: id ?? UUID(), name: stored, symbol: chosenSymbol, archived: archived, income: income, color: color, emoji: emoji.isEmpty ? nil : emoji, parentID: parentID)
                    try data.updateCategory(value, expected: old)
                }
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
