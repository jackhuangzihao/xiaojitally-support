import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Entry sheet

struct EntryRequest: Identifiable {
    var entry: MoneyEntry
    var expected: MoneyEntry?
    var id: UUID { entry.id }
}

struct FinanceDraft {
    var ledger: FinanceData
    var entry: MoneyEntry
    var expected: MoneyEntry?
    var amount: String, actual: String, received: String, fee: String, converted: String, convertedFee: String
    var balance: Decimal
    var expression: String? = nil
}

/// Native amount editing, with an optional calculator and contextual advanced fields.
struct FinanceEntryEditor: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Field: Hashable { case amount, title, actual, received, fee, converted, convertedFee, notes, tags }
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("hideMoney") private var hidden = false
    let expected: MoneyEntry?
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var tasks: [TaskItem]
    @Query private var records: [FinanceLedger]
    @State private var draft: MoneyEntry
    @State private var ledger = FinanceData.initial
    @State private var accountBalances: [UUID: Decimal] = [:]
    @State private var expression: String
    @State private var amount: String
    @State private var actual: String
    @State private var received: String
    @State private var fee: String
    @State private var converted: String
    @State private var convertedFee: String
    @State private var error: String?
    @State private var notice: String?
    @State private var rates: [MoneyRate] = []
    @AppStorage("moneyAutoRates") private var automaticRates = true
    @State private var filledValues: [String: String] = [:]
    @State private var scaledValues: [String: String] = [:]
    @State private var gettingRates = false
    @State private var entity: EntityRequest?
    @State private var showCalculator = false
    @State private var showMore = false
    @State private var showDate = false
    @State private var initialBalance: Decimal = 0
    @State private var loaded = false
    @State private var confirmDiscard = false
    @State private var initialFingerprint = ""
    @State private var restoringDraft = false
    @FocusState private var focus: Field?
    init(entry: MoneyEntry, expected: MoneyEntry?) {
        self.expected = expected; _draft = State(initialValue: entry)
        let text = entry.amount == 0 ? "" : Money.text(entry.amount)
        _amount = State(initialValue: text)
        _expression = State(initialValue: text.replacingOccurrences(of: "-", with: "−"))
        _actual = State(initialValue: entry.accountAmount == 0 ? "" : Money.text(entry.accountAmount))
        _received = State(initialValue: entry.destinationAmount == 0 ? "" : Money.text(entry.destinationAmount))
        _fee = State(initialValue: entry.fee == 0 ? "" : Money.text(entry.fee))
        _converted = State(initialValue: entry.baseAmount.map(Money.text) ?? "")
        _convertedFee = State(initialValue: entry.baseFee.map(Money.text) ?? "")
        _showMore = State(initialValue: !entry.notes.isEmpty || !entry.tags.isEmpty || entry.taskID != nil)
    }
    private var account: MoneyAccount? { ledger.accounts.first { $0.id == draft.accountID } }
    private var destination: MoneyAccount? { ledger.accounts.first { $0.id == draft.destinationID } }
    private var fingerprint: String { String(describing: draft) + [expression, amount, actual, received, fee, converted, convertedFee].joined(separator: "|") }
    private var dirty: Bool { loaded && fingerprint != initialFingerprint }
    private var rateQuery: String { "\(loaded)-\(automaticRates)-\(draft.currency)-\(draft.accountID?.uuidString ?? "")-\(draft.destinationID?.uuidString ?? "")-\(Dates.calendar.startOfDay(for: draft.date).timeIntervalSince1970)" }
    private var foreign: Bool { draft.currency != ledger.baseCurrency }
    private var desiredAmountFocus: Field? {
        #if os(iOS)
        return showCalculator ? nil : .amount
        #else
        return .amount
        #endif
    }
    private var simpleKind: Bool { draft.kind == .expense || draft.kind == .income || draft.kind == .transfer }
    private var signedAmount: Bool { draft.kind == .adjustment }
    private var activeAccounts: [MoneyAccount] { ledger.accounts.filter { ledger.allowsAccount($0.id, for: draft, replacing: expected) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if compact { Text(expected == nil ? L("新增账单", "New entry") : L("编辑已有账单", "Edit existing entry")).font(.caption).foregroundStyle(.secondary) }
            if !compact {
                amountRow.padding(.horizontal, 18).padding(.vertical, 12)
                chips.padding(.horizontal, 18).padding(.bottom, 8)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if compact { amountRow; chips; Divider() }
                    if showMore { moreFields }
                    switch draft.kind {
                    case .expense, .income: categoryGrid
                    case .transfer: transferFields
                    case .refund: refundInfo
                    case .adjustment: adjustmentInfo
                    }
                    if needsRate { rateFields }
                    if draft.deletedAt != nil { Text(L("此账单已删除，请先在最近删除中恢复。", "Restore this entry from Recently deleted before editing.")).foregroundStyle(.secondary) }
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }.scrollDismissesKeyboard(.interactively)
            Divider()
            bottomPanel
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 540, minHeight: showCalculator ? 730 : 540, idealHeight: showCalculator ? 750 : 560)
        #endif
        .background(Color.appBackground)
        #if os(macOS)
        .defaultFocus($focus, .amount)
        #endif
        .interactiveDismissDisabled(dirty)
        .confirmationDialog(L("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L("放弃修改", "Discard changes"), role: .destructive) { dismiss() }
            Button(L("继续编辑", "Keep editing"), role: .cancel) {}
        }
        .task {
            if !loaded, let kept = drafts.finance, kept.entry.id == draft.id {
                ledger = kept.ledger; accountBalances = kept.ledger.accountBalances(); restoringDraft = true
            }
            reload()
            if !loaded {
                if let kept = drafts.finance, kept.entry.id == draft.id {
                    restoringDraft = true
                    draft = kept.entry; amount = kept.amount; actual = kept.actual; received = kept.received
                    fee = kept.fee; converted = kept.converted; convertedFee = kept.convertedFee; initialBalance = kept.balance
                    expression = kept.expression ?? kept.amount.replacingOccurrences(of: "-", with: "−")
                } else {
                    initialBalance = draft.accountID.map { ledger.balance($0, at: draft.date) } ?? 0
                    if draft.kind == .adjustment && expected == nil { amount = Money.text(initialBalance); expression = amount.replacingOccurrences(of: "-", with: "−") }
                }
                initialFingerprint = restoringDraft ? "restored-unsaved" : fingerprint; loaded = true
                keepDraft()
                focus = desiredAmountFocus
            }
        }
        .onChange(of: records.first?.payload) { _, _ in reload() }
        .onChange(of: fingerprint) { _, _ in if loaded { keepDraft() } }
        .onDisappear { if generation == Store.recovery.generation && Store.recovery.failure == nil { drafts.finance = nil } }
        .task(id: rateQuery) {
            if loaded && expected == nil && needsRate && automaticRates { await fetchAndFillRates() }
        }
        #if os(iOS)
        .onChange(of: focus) { _, focusedField in
            // The system keyboard and the calculator must not consume the sheet together.
            if focusedField != nil && showCalculator { showCalculator = false }
        }
        #endif
        .onChange(of: expression) { _, value in
            error = nil; if !value.isEmpty { notice = nil }
            let next = Money.evaluate(value, currency: draft.currency, signed: signedAmount).map(Money.text) ?? ""
            if next != amount { amount = next }
        }
        .onChange(of: amount) { _, _ in
            clearEstimates()
            rescaleRecorded()
            if !rates.isEmpty { applyRates(rates) }
        }
        .onChange(of: draft.bookID) { _, id in
            if expected == nil && draft.kind != .refund, ledger.books.first(where: { $0.id == id })?.defaultAccountID != nil { draft.accountID = ledger.defaultAccount(for: id) }
        }
        .onChange(of: draft.accountID) { old, _ in
            // Reassigning a posting does not change its original currency or historical reporting amount.
            if ledger.accounts.first(where: { $0.id == old })?.currency != account?.currency {
                actual = ""; filledValues["actual"] = nil; scaledValues["actual"] = nil
            }
            // A blank new entry follows its account. Typed amounts and historical entries keep their currency.
            if let account, draft.kind == .transfer || (expected == nil && expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (draft.kind == .expense || draft.kind == .income)) {
                draft.currency = account.currency
            }
        }
        .onChange(of: draft.kind) { _, kind in
            if kind == .transfer, let account { draft.currency = account.currency }
            if kind != .transfer { draft.destinationID = nil; received = ""; fee = ""; convertedFee = "" }
            if kind == .expense || kind == .income, ledger.category(draft.categoryID)?.isIncome != (kind == .income) {
                draft.categoryID = ledger.defaultCategory(income: kind == .income)
            }
            focus = desiredAmountFocus
        }
        .onChange(of: draft.destinationID) { _, _ in received = "" }
        .onChange(of: draft.currency) { _, _ in
            actual = ""; received = ""; converted = ""; convertedFee = ""; rates = []; filledValues = [:]; draft.rateNote = ""
            amount = Money.evaluate(expression, currency: draft.currency, signed: signedAmount).map(Money.text) ?? ""
        }
        .onChange(of: draft.date) { old, new in
            if draft.kind == .adjustment && expected == nil, let id = draft.accountID {
                let untouched = Money.evaluate(expression, currency: draft.currency, signed: true) == initialBalance
                initialBalance = ledger.balance(id, at: new)
                if untouched { expression = Money.text(initialBalance); amount = expression }
            }
            if !Dates.calendar.isDate(old, inSameDayAs: new) { clearEstimates(); rates = []; draft.rateNote = "" }
        }
        .onChange(of: fee) { _, _ in
            if convertedFee == filledValues["fee"] { convertedFee = ""; filledValues["fee"] = nil }
            if let original = expected, original.currency == draft.currency, foreign,
               let value = try? Money.parse(fee, currency: draft.currency),
               let next = Money.rescaledText(convertedFee, recorded: original.baseFee, previous: scaledValues["fee"], from: original.fee, to: value, currency: ledger.baseCurrency) {
                convertedFee = next; scaledValues["fee"] = next
            }
            if !rates.isEmpty { applyRates(rates) }
        }
        .sheet(item: $entity, onDismiss: reload) { item in FinanceEntityEditor(kind: item.kind, id: item.existingID, income: item.income, parentID: item.parentID, data: ledger) }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }

    // MARK: Layout

    private var topBar: some View {
        HStack(spacing: 12) {
            if simpleKind {
                Picker(L("类型", "Type"), selection: $draft.kind) {
                    ForEach([MoneyKind.expense, .income, .transfer]) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 230).disabled(expected != nil)
            } else { Text(draft.kind.label).font(.headline) }
            Spacer()
            if !compact { Text(expected == nil ? L("新增账单", "New entry") : L("编辑已有账单", "Edit existing entry")).font(.subheadline).foregroundStyle(.secondary) }
            Button { if dirty { confirmDiscard = true } else { dismiss() } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: compact ? 44 : 26, height: compact ? 44 : 26).background(Circle().fill(Color.primary.opacity(0.07)))
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("关闭", "Close")).help(L("关闭（Esc）", "Close (Esc)"))
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
    }
    private var categoryGrid: some View {
        let income = draft.kind == .income
        let selectedRoot = ledger.rootCategoryID(draft.categoryID)
        let roots = ledger.categories.filter { $0.parentID == nil && (($0.isIncome == income && !$0.archived) || $0.id == selectedRoot) }
        let children = ledger.categories.filter { selectedRoot != nil && $0.parentID == selectedRoot && (($0.isIncome == income && !$0.archived) || $0.id == draft.categoryID) }
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                ForEach(roots) { category in categoryButton(category, selected: category.id == selectedRoot) }
                addCategoryButton(income: income, parentID: nil)
            }
            if let parent = ledger.category(selectedRoot), !children.isEmpty {
                Divider()
                HStack {
                    Text(parent.label + L(" · 子分类", " · subcategories")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L("不细分", "No subcategory")) { draft.categoryID = parent.id }.font(.caption).frame(minHeight: 44)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? (dynamicTypeSize.isAccessibilitySize ? 2 : 4) : 6), spacing: 8) {
                    ForEach(children) { category in categoryButton(category, selected: category.id == draft.categoryID) }
                    if !parent.archived { addCategoryButton(income: income, parentID: parent.id) }
                }
            } else if let parent = ledger.category(selectedRoot), !parent.archived {
                Button { entity = EntityRequest(kind: .category, income: income, parentID: parent.id) } label: {
                    Label(L("为“\(parent.label)”添加子分类", "Add a subcategory to \(parent.label)"), systemImage: "plus")
                }.font(.callout).frame(minHeight: 44)
            }
        }
    }
    private func categoryButton(_ category: MoneyCategory, selected: Bool) -> some View {
        let tint = MoneyColor.color(category.resolvedColor)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) { draft.categoryID = category.id }
            focus = desiredAmountFocus
        } label: {
            VStack(spacing: 5) {
                MoneyIcon(symbol: category.symbol, emoji: category.emoji, tint: selected ? .white : tint, size: 40)
                    .background(Circle().fill(selected ? tint : .clear))
                Text(category.label).font(.caption).lineLimit(2).foregroundStyle(selected ? .primary : .secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.1) : .clear)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(ledger.categoryPath(category.id)).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func addCategoryButton(income: Bool, parentID: UUID?) -> some View {
        Button { entity = EntityRequest(kind: .category, income: income, parentID: parentID) } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 40, height: 40).overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text(L("新增", "Add")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 60).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(parentID == nil ? L("新增大类", "New main category") : L("新增子分类", "New subcategory"))
    }
    private var transferFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))) {
                accountPicker(L("从", "From"), selection: $draft.accountID, excluding: nil)
                Button {
                    let from = draft.accountID; draft.accountID = draft.destinationID; draft.destinationID = from
                } label: { Label(L("对调账户", "Swap accounts"), systemImage: "arrow.left.arrow.right").frame(minHeight: compact ? 44 : nil) }
                    .buttonStyle(.borderless).help(L("对调转出和转入账户", "Swap the two accounts")).accessibilityLabel(L("对调转出和转入账户", "Swap the two accounts"))
                    .disabled(draft.accountID == nil && draft.destinationID == nil)
                accountPicker(L("转到", "To"), selection: $draft.destinationID, excluding: draft.accountID)
            }
            if let from = account, let to = destination {
                Text(L("钱从“\(from.name)”转出，进入“\(to.name)”", "Money leaves “\(from.name)” and arrives in “\(to.name)”"))
                    .font(.callout.weight(.medium))
            }
            if let destination, destination.currency != draft.currency {
                amountField(L("实际到账", "Amount received"), currency: destination.currency, text: $received, field: .received)
            }
            amountField(L("手续费（可不填）", "Fee (optional)"), currency: draft.currency, text: $fee, field: .fee)
            transferBalancePreview
            Text(L("转账只在两个账户之间挪钱，不算收入或支出；手续费计入支出。", "Transfers move money between accounts and are not income or spending; the fee counts as spending.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    @ViewBuilder private var transferBalancePreview: some View {
        if expected != nil {
            Text(L("正在修改原转账，保存后会替换旧记录。新增转账请关闭后点“记一笔”。", "This replaces the original transfer. To add a transfer, close this editor and choose New entry."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let entry = try? preparedEntry(), entry.accountID != entry.destinationID {
            let ids = [entry.accountID, entry.destinationID, expected?.accountID, expected?.destinationID].compactMap { $0 }
            Divider()
            Text(L("保存后的账户余额", "Account balances after saving")).font(.caption).foregroundStyle(.secondary)
            ForEach(ledger.accounts.filter { ids.contains($0.id) }) { account in
                HStack {
                    Text(account.name).lineLimit(1)
                    Spacer()
                    let after = ledger.balanceAfterSaving(entry, for: account.id, accountBalances: accountBalances)
                    Text(Money.display(accountBalances[account.id, default: 0], account.currency, hidden: hidden)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(Money.display(after, account.currency, hidden: hidden)).foregroundStyle(after < 0 ? Color.red : .primary)
                }.font(.caption).monospacedDigit()
            }
        }
    }
    private func accountPicker(_ label: String, selection: Binding<UUID?>, excluding: UUID?) -> some View {
        Picker(label, selection: selection) {
            Text(L("选择账户", "Choose account")).tag(nil as UUID?)
            ForEach(activeAccounts.filter { $0.id != excluding }) { a in Text(a.name + " · " + Money.display(accountBalances[a.id, default: 0], a.currency, hidden: hidden)).tag(Optional(a.id)) }
        }.pickerStyle(.menu).frame(maxWidth: .infinity)
    }
    private var refundInfo: some View {
        let original = ledger.entries.first { $0.id == draft.refundOf }
        let category = ledger.category(draft.categoryID)
        return HStack(spacing: 12) {
            MoneyIcon(symbol: category?.symbol ?? "arrow.uturn.backward", emoji: category?.emoji, tint: ledger.tint(category), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("退款会从“\(category?.label ?? L("未分类", "Uncategorized"))”的支出中扣除，不算新收入。", "The refund reduces \(category?.label ?? "uncategorized") spending and is not new income."))
                if let original { Text(L("原消费：", "Original: ") + original.title + " · " + Money.display(original.amount, original.currency, hidden: hidden)).font(.caption).foregroundStyle(.secondary) }
                if let original {
                    Text(L("还可退款：", "Available to refund: ") + Money.display(ledger.remainingRefund(for: original.id, excluding: expected?.id), original.currency, hidden: hidden))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    private var adjustmentInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((account?.name ?? "") + L(" 核对时刻账面余额 ", " balance at the selected time ") + Money.display(initialBalance, draft.currency, hidden: hidden)).font(.headline)
            Text(expected == nil ? L("在上方输入该时刻的实际余额。差额记为调整，不计入收支；更晚的流水不会参与本次核对。", "Enter the actual balance at the selected time above. The difference is an adjustment, not income or spending; later entries are excluded.")
                 : L("这是一次余额调整，金额为调整的差额。", "This is a balance adjustment; the amount is the difference.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
    private var needsRate: Bool { draft.kind != .adjustment && (foreign || account.map { $0.currency != draft.currency } == true || destination.map { $0.currency != draft.currency } == true) }
    private var rateFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("外币换算", "Currency conversion"), systemImage: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold))
            if let account, account.currency != draft.currency, draft.kind != .transfer {
                amountField(account.name + ((draft.kind == .expense) ? L(" 实际扣款", " charged") : L(" 实际入账", " received")), currency: account.currency, text: $actual, field: .actual)
            }
            if foreign && draft.kind != .transfer && draft.kind != .adjustment && account?.currency != ledger.baseCurrency {
                amountField(L("计入统计", "Counts in totals as"), currency: ledger.baseCurrency, text: $converted, field: .converted)
            }
            if draft.kind == .transfer && foreign && !fee.isEmpty { amountField(L("手续费折合", "Fee in base currency"), currency: ledger.baseCurrency, text: $convertedFee, field: .convertedFee) }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text(draft.rateNote.isEmpty ? L("还没有参考汇率", "No reference rate yet") : draft.rateNote).font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(gettingRates ? L("获取中…", "Fetching…") : L("按参考汇率填入", "Fill with reference rate")) { fillRates() }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil).disabled(gettingRates || amount.isEmpty)
            }
            Toggle(L("自动获取参考汇率", "Fetch reference rates automatically"), isOn: $automaticRates).font(.caption)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            Text(L("以银行实际扣款为准：改成实际金额后不会被覆盖；历史账单不随汇率变化。", "Use what your bank actually charged; amounts you enter are never overwritten, and history never changes with rates.")).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }
    private func amountField(_ label: String, currency: String, text: Binding<String>, field: Field) -> some View {
        (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
            Text(label).font(.callout)
            HStack(spacing: 8) {
                if !compact { Spacer() }
                Text(currency).font(.caption).foregroundStyle(.secondary)
                TextField("0", text: text).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(maxWidth: compact ? .infinity : 120, minHeight: compact ? 44 : nil).focused($focus, equals: field)
                    .accessibilityLabel(label + " · " + currency)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        }
    }
    private var moreFields: some View {
        let recent = recentTags
        return VStack(alignment: .leading, spacing: 10) {
            fieldTitle(L("详细说明", "Details"), L("写不下的细节，比如买了什么、和谁一起、发票号。", "Anything longer: what you bought, who with, an invoice number."))
            TextField(L("可不填", "Optional"), text: $draft.notes, axis: .vertical).focused($focus, equals: .notes).lineLimit(2...5).textFieldStyle(.roundedBorder)
            fieldTitle(L("标签", "Tags"), L("给账单打记号，方便以后搜索，比如“报销”“出差”。多个用逗号分开。", "Marks for finding entries later, such as “reimburse” or “work trip”. Separate with commas."))
            TextField(L("可不填", "Optional"), text: $draft.tags).focused($focus, equals: .tags).textFieldStyle(.roundedBorder)
            if !recent.isEmpty {
                ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text(L("常用：", "Recent: ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(recent, id: \.self) { tag in
                        Button(tag) { addTag(tag) }.buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.07)))
                            .frame(minHeight: compact ? 44 : nil)
                    }
                }
                }.scrollIndicators(.hidden)
            }
            fieldTitle(L("关联任务", "Linked task"), L("这笔钱对应待办里的哪件事，可在任务里看到相关花费。", "Which task this money belongs to; the task shows its entries."))
            Picker(L("关联任务", "Linked task"), selection: $draft.taskID) {
                Text(L("不关联", "None")).tag(nil as UUID?)
                ForEach(tasks.filter { $0.deletedAt == nil || $0.id == draft.taskID }.sorted { $0.createdAt > $1.createdAt }) { Text($0.title).tag(Optional($0.id)) }
                if let id = draft.taskID, !tasks.contains(where: { $0.id == id }) { Text(L("原任务已删除", "Original task removed")).tag(Optional(id)) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func fieldTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
    private static func splitTags(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// The tags used most, not already on this entry.
    private var recentTags: [String] {
        let current = Set(Self.splitTags(draft.tags))
        let counts = ledger.entries.filter { $0.deletedAt == nil }.flatMap { Self.splitTags($0.tags) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.filter { !current.contains($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map(\.key)
    }
    private func addTag(_ tag: String) {
        draft.tags = (Self.splitTags(draft.tags) + [tag]).joined(separator: L("，", ", "))
    }
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            statusLine
            if showCalculator { keypad }
            HStack(spacing: 12) {
                Button {
                    showCalculator.toggle()
                    focus = desiredAmountFocus
                } label: {
                    Label(L("计算器", "Calculator"), systemImage: "plus.forwardslash.minus")
                }.buttonStyle(.borderless).foregroundStyle(showCalculator ? Color.accentColor : .secondary)
                    .labelStyle(.iconOnly).frame(minWidth: compact ? 44 : nil, minHeight: compact ? 44 : nil)
                    .accessibilityAddTraits(showCalculator ? [.isSelected] : [])
                Spacer()
                #if os(iOS)
                Button {
                    focus = nil
                } label: {
                    Label(L("收起键盘", "Dismiss keyboard"), systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                #endif
                if expected == nil && simpleKind && !compact {
                    Button(L("保存并继续", "Save + new")) { save(again: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L("保存并继续下一笔（⌘↩）", "Save and start another (⌘↩)"))
                        .disabled(!loaded || gettingRates || draft.deletedAt != nil)
                }
                Button(compact ? L("保存", "Save") : expected == nil ? L("保存新账单", "Save new entry") : L("保存修改", "Save changes")) { save() }.buttonStyle(.borderedProminent)
                    .controlSize(compact ? .large : .regular)
                    .frame(maxWidth: compact ? .infinity : nil, minHeight: compact ? 44 : nil)
                    .keyboardShortcut(.defaultAction).disabled(!loaded || gettingRates || draft.deletedAt != nil)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
    private var amountRow: some View {
        let value = Money.evaluate(expression, currency: draft.currency, signed: signedAmount)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("金额", "Amount")).foregroundStyle(.secondary)
                Menu {
                    CurrencyChoices { draft.currency = $0 }
                } label: { Text(Money.symbol(draft.currency)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(draft.kind == .refund || draft.kind == .adjustment || draft.kind == .transfer)
                    .help(L("币种", "Currency"))
                TextField("0.00", text: $expression)
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .textFieldStyle(.plain).focused($focus, equals: .amount)
                    .accessibilityLabel(L("金额，可输入加减算式", "Amount, addition and subtraction supported"))
                    #if os(iOS)
                    .keyboardType(signedAmount ? .numbersAndPunctuation : .decimalPad)
                    #endif
                if expression.contains(where: { $0 == "+" || $0 == "−" || $0 == "-" }) && expression.count > 1, let value {
                    Text("= " + Money.format(value, draft.currency)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("备注", "Note")).font(.caption).foregroundStyle(.secondary)
                TextField(L("可不填", "Optional"), text: $draft.title)
                    .textFieldStyle(.plain).focused($focus, equals: .title).frame(minHeight: compact ? 44 : nil)
                    .accessibilityLabel(L("备注", "Note"))
            }
        }
    }
    private var chips: some View {
        // Every required choice stays visible on a phone. Large text uses one column.
        Group {
        if compact {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 8) {
                dateChip; accountChip; bookChip; moreChip
            }
        } else {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateChip; accountChip; bookChip; moreChip; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { dateChip; accountChip; Spacer(minLength: 0) }
                HStack(spacing: 8) { bookChip; moreChip; Spacer(minLength: 0) }
            }
        }
        }
        }.labelStyle(.titleAndIcon)
    }
    private var dateChip: some View {
        Button { showDate = true } label: {
            entryChipLabel(L("日期", "Date"), value: dateText, symbol: "calendar", desktopTitle: dateText)
        }
            .buttonStyle(.plain).fixedSize(horizontal: !compact, vertical: false)
            .popover(isPresented: $showDate, arrowEdge: .bottom) { datePopover }
    }
    @ViewBuilder private var accountChip: some View {
        if draft.kind == .expense || draft.kind == .income || draft.kind == .refund {
            Menu {
                Picker(L("账户", "Account"), selection: $draft.accountID) {
                    Text(L("不计入账户（只记收支）", "No account (totals only)")).tag(nil as UUID?)
                    ForEach(activeAccounts) { a in Text(a.name + " · " + Money.display(accountBalances[a.id, default: 0], a.currency, hidden: hidden)).tag(Optional(a.id)) }
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                Button(L("新增账户…", "New account…")) { entity = EntityRequest(kind: .account) }
            } label: {
                entryChipLabel(L("账户", "Account"), value: account?.name ?? L("不计入账户", "No account"), symbol: account?.iconSymbol ?? "wallet.pass", emoji: account?.emoji)
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: !compact, vertical: false)
                .help(L("从哪个账户扣款或入账", "Which account this uses"))
        }
    }
    private var bookChip: some View {
        Menu {
            Picker(L("账本", "Book"), selection: $draft.bookID) {
                ForEach(ledger.books.filter { !$0.archived || $0.id == draft.bookID }) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.inline).labelsHidden()
            Divider()
            Button(L("新建账本…", "New book…")) { entity = EntityRequest(kind: .book) }
        } label: {
            entryChipLabel(L("账本", "Book"), value: ledger.book(draft.bookID)?.name ?? L("选择账本", "Choose a book"), symbol: ledger.book(draft.bookID)?.iconSymbol ?? "book.closed", emoji: ledger.book(draft.bookID)?.emoji)
        }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: !compact, vertical: false)
            .disabled(draft.kind == .refund)
    }
    private var moreChip: some View {
        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showMore.toggle() } } label: {
            entryChipLabel(showMore ? L("收起", "Less") : L("更多", "More"), value: L("标签与关联任务", "Tags & linked task"), symbol: showMore ? "chevron.up" : "ellipsis", desktopTitle: showMore ? L("收起", "Less") : L("更多", "More"))
        }.buttonStyle(.plain).fixedSize(horizontal: !compact, vertical: false).help(L("补充说明、标签、关联任务", "Notes, tags and linked task"))
    }
    @ViewBuilder private func entryChipLabel(_ title: String, value: String, symbol: String, emoji: String? = nil, desktopTitle: String? = nil) -> some View {
        // Padding and the full touch shape belong to the native control's label.
        Group {
        if compact {
            HStack(spacing: 8) {
                MoneyGlyph(symbol: symbol, emoji: emoji).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .ignore).accessibilityLabel(title + ": " + value)
        } else {
            MoneyMenuLabel(title: desktopTitle ?? title + ": " + value, symbol: symbol, emoji: emoji)
        }
        }.modifier(MoneyChip(expanded: compact))
    }
    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L("今天", "Today")) { draft.date = MoneyEntry.timestamp(); showDate = false }
                Button(L("昨天", "Yesterday")) { draft.date = MoneyEntry.timestamp(Dates.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()); showDate = false }
            }
            DatePicker("", selection: $draft.date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            DatePicker(L("时间", "Time"), selection: $draft.date, displayedComponents: .hourAndMinute)
        }.padding(14).frame(width: 260)
    }
    private var dateText: String {
        let time = Dates.label(draft.date, pattern: "HH:mm")
        if Dates.calendar.isDateInToday(draft.date) { return L("今天 ", "Today ") + time }
        if Dates.calendar.isDateInYesterday(draft.date) { return L("昨天 ", "Yesterday ") + time }
        return Dates.label(draft.date, pattern: "M月d日 HH:mm")
    }
    @ViewBuilder private var statusLine: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
        } else if draft.kind == .adjustment && expected == nil {
            Text(L("输入核对后的实际余额", "Enter the checked balance")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var keypad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow { key("7"); key("8"); key("9"); iconKey("delete.left", "⌫") }
            GridRow { key("4"); key("5"); key("6"); key("+") }
            GridRow { key("1"); key("2"); key("3"); key("−") }
            GridRow {
                Button(L("清空", "Clear")) { expression = ""; focus = desiredAmountFocus }.buttonStyle(MoneyKeyStyle())
                key("0"); key(".")
                Button("=") {
                    if let value = Money.evaluate(expression, currency: draft.currency, signed: signedAmount) { expression = Money.text(value) }
                    focus = desiredAmountFocus
                }.buttonStyle(MoneyKeyStyle())
            }
        }
    }
    private func key(_ value: String) -> some View {
        Button(value) { input(value) }.buttonStyle(MoneyKeyStyle())
    }
    private func iconKey(_ symbol: String, _ value: String) -> some View {
        Button { input(value) } label: { Image(systemName: symbol) }.buttonStyle(MoneyKeyStyle()).accessibilityLabel(L("删除", "Delete"))
    }

    // MARK: Keypad

    private func input(_ key: String) {
        error = nil; notice = nil
        if focus != .amount { focus = desiredAmountFocus }
        var text = expression
        let scale = Money.scale(draft.currency)
        let last = String(text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "+" || $0 == "−" || $0 == "-" }).last ?? "")
        switch key {
        case "⌫":
            if !text.isEmpty { text.removeLast() }
        case "+", "−":
            if text.isEmpty || text == "−" { text = key == "−" && signedAmount ? "−" : "" }
            else if text.last == "+" || text.last == "−" || text.last == "-" { text.removeLast(); text.append(key) }
            else { text.append(key) }
        case ".":
            guard scale > 0, !last.contains(".") else { return }
            text += last.isEmpty ? "0." : "."
        default:
            if let dot = last.firstIndex(of: "."), last.distance(from: dot, to: last.endIndex) - 1 >= scale { return }
            guard text.count < 24 else { return }
            if last == "0" { text.removeLast() }
            text += key
        }
        expression = text
    }

    // MARK: Data

    private func reload() {
        do {
            let current = try FinanceStore.read(context) ?? .initial
            // Keep displayed conversion fields in the denomination they were entered in.
            if loaded || restoringDraft { try current.requireEntryCurrencies(draft, from: ledger) }
            ledger = current
            accountBalances = current.accountBalances()
        } catch { self.error = error.localizedDescription }
    }
    private func fillRates() {
        Task { await fetchAndFillRates() }
    }
    private func fetchAndFillRates() async {
        gettingRates = true; error = nil
        let query = rateQuery
        let source = draft.currency, day = draft.date
        let quotes = [account?.currency, destination?.currency, ledger.baseCurrency].compactMap { $0 }
        do {
            defer { gettingRates = false }
            do {
                let result = try await ExchangeRates.fetch(base: source, quotes: quotes, date: day)
                guard !Task.isCancelled && rateQuery == query else { return }
                rates = result
                applyRates(result)
                draft.rateNote = L("欧洲央行 ", "ECB ") + (result.map(\.date).sorted().first ?? "") + L(" 参考汇率", " reference rate") + rateSummary(result)
            } catch {
                guard !Task.isCancelled && rateQuery == query else { return }
                let cached = ledger.cachedReferenceRates(from: source, quotes: quotes, onOrBefore: ExchangeRates.dayString(day), including: rates)
                rates = cached
                if !cached.isEmpty {
                    applyRates(cached)
                    draft.rateNote = L("离线参考汇率：", "Cached reference rates: ") + cached.map(\.date).sorted().joined(separator: ", ")
                }
                self.error = L("暂时无法联网获取汇率。可填写实际金额，或核对缓存换算值后保存。", "Rates are unavailable. Enter actual amounts or review cached values before saving.")
            }
        }
    }
    private func rateSummary(_ values: [MoneyRate]) -> String {
        guard let rate = values.first(where: { $0.quote == (account?.currency != draft.currency ? account?.currency : ledger.baseCurrency) }) ?? values.first else { return "" }
        let shown = NSDecimalNumber(decimal: rate.rate).rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 4, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return " · 1 \(rate.base) = \(shown.stringValue) \(rate.quote)"
    }
    /// Editing a recorded foreign entry keeps the rate it was recorded at: untouched converted amounts follow the new amount.
    private func rescaleRecorded() {
        guard let original = expected, original.amount != 0, draft.currency == original.currency,
              let value = try? Money.parse(amount, currency: draft.currency, signed: signedAmount) else { return }
        func follow(_ key: String, _ recorded: Decimal?, _ currency: String?, _ field: inout String) {
            guard let currency, let next = Money.rescaledText(field, recorded: recorded, previous: scaledValues[key], from: original.amount, to: value, currency: currency) else { return }
            field = next; scaledValues[key] = next
        }
        if original.currency != ledger.baseCurrency { follow("converted", original.baseAmount, ledger.baseCurrency, &converted) }
        if draft.accountID == original.accountID, let account, account.currency != draft.currency { follow("actual", original.accountAmount, account.currency, &actual) }
        if draft.destinationID == original.destinationID, let destination, destination.currency != draft.currency { follow("received", original.destinationAmount, destination.currency, &received) }
    }
    private func clearEstimates() {
        if actual == filledValues["actual"] { actual = "" }
        if received == filledValues["received"] { received = "" }
        if converted == filledValues["converted"] { converted = "" }
        if convertedFee == filledValues["fee"] { convertedFee = "" }
        filledValues = [:]
    }
    private func applyRates(_ values: [MoneyRate]) {
        guard let amount = try? Money.parse(amount, currency: draft.currency) else { return }
        func conversion(_ value: Decimal, _ to: String) -> String? {
            if draft.currency == to { return Money.text(value) }
            return values.first { !$0.isManual && $0.base == draft.currency && $0.quote == to }.map { Money.text(Money.round(value * $0.rate, currency: to)) }
        }
        func fill(_ key: String, _ field: inout String, _ replacement: String?) {
            guard let next = Money.refreshedEstimate(field, previous: filledValues[key], replacement: replacement) else { return }
            field = next; filledValues[key] = next
        }
        if let account { fill("actual", &actual, conversion(amount, account.currency)) }
        if let destination { fill("received", &received, conversion(amount, destination.currency)) }
        fill("converted", &converted, conversion(amount, ledger.baseCurrency))
        if let value = try? Money.parse(fee, currency: draft.currency) {
            fill("fee", &convertedFee, conversion(value, ledger.baseCurrency))
        }
    }
    private func keepDraft() {
        drafts.finance = FinanceDraft(ledger: ledger, entry: draft, expected: expected, amount: amount, actual: actual, received: received, fee: fee, converted: converted, convertedFee: convertedFee, balance: initialBalance, expression: expression)
    }
    private func preparedEntry() throws -> MoneyEntry {
        guard !amount.isEmpty, (try? Money.parse(amount, currency: draft.currency, signed: signedAmount)).map({ $0 != 0 || draft.kind == .adjustment }) == true else {
            throw TaskBackup.invalid(expression.isEmpty ? L("先输入金额", "Enter an amount first") : L("金额需要大于 0，\(draft.currency) 最多 \(Money.scale(draft.currency)) 位小数", "The amount must be above 0 with at most \(Money.scale(draft.currency)) decimals"))
        }
        var e = draft
        e.title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.kind == .transfer { e.categoryID = nil }
        if e.title.isEmpty { e.title = ledger.categories.first { $0.id == e.categoryID }?.label ?? e.kind.label }
        e.amount = try Money.parse(amount, currency: e.currency, signed: e.kind == .adjustment)
        if e.kind == .adjustment && expected == nil {
            let live = try FinanceStore.read(context) ?? .initial
            guard let id = e.accountID else { throw TaskBackup.invalid(L("请选择账户。", "Choose an account.")) }
            e.amount = try live.reconciliationChange(id, at: e.date, checked: e.amount, expected: initialBalance)
            guard e.amount != 0 else { throw TaskBackup.invalid(L("余额没有变化，不需要校准。", "The balance is unchanged; nothing to adjust.")) }
        }
        e.accountAmount = try account.map { account in account.currency == e.currency ? e.amount : try Money.parse(actual, currency: account.currency, signed: e.kind == .adjustment) } ?? 0
        e.destinationAmount = 0; e.fee = 0; e.baseFee = nil
        if e.kind == .transfer {
            guard e.accountID != nil else { throw TaskBackup.invalid(L("请选择转出账户。", "Choose the account to transfer from.")) }
            guard let destination else { throw TaskBackup.invalid(L("请选择转入账户。", "Choose a receiving account.")) }
            e.destinationAmount = destination.currency == e.currency ? e.amount : try Money.parse(received, currency: destination.currency)
            e.fee = fee.isEmpty ? 0 : try Money.parse(fee, currency: e.currency)
            if e.fee > 0 { e.baseFee = e.currency == ledger.baseCurrency ? e.fee : (convertedFee.isEmpty ? nil : try Money.parse(convertedFee, currency: ledger.baseCurrency)) }
        } else { e.destinationID = nil }
        if e.kind == .transfer || e.kind == .adjustment { e.baseAmount = nil }
        else if e.currency == ledger.baseCurrency { e.baseAmount = e.amount }
        else if account?.currency == ledger.baseCurrency { e.baseAmount = e.accountAmount }
        else { e.baseAmount = converted.isEmpty ? nil : try Money.parse(converted, currency: ledger.baseCurrency) }
        return e
    }
    private func save(again: Bool = false) {
        do {
            keepDraft()
            let e = try preparedEntry()
            try FinanceStore.update(context) { value in
                try value.requireEntryCurrencies(e, from: ledger)
                try value.updateEntry(e, expected: expected, baseCurrency: ledger.baseCurrency, referenceRates: rates)
            }
            if let id = e.bookID { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyBook") }
            if e.kind == .expense || e.kind == .income { UserDefaults.standard.set(e.accountID?.uuidString ?? "none", forKey: "lastMoneyAccount") }
            if let id = e.categoryID, e.kind == .expense || e.kind == .income { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyCategory." + (e.kind == .income ? "income" : "expense")) }
            if again { startAnother(after: e) } else { dismiss() }
        } catch { self.error = error.localizedDescription; notice = nil }
    }
    /// Keeps kind, category, account, book, currency and day, so a run of receipts is only amounts.
    private func startAnother(after saved: MoneyEntry) {
        var next = MoneyEntry()
        next.kind = saved.kind; next.categoryID = saved.categoryID; next.accountID = saved.accountID; next.destinationID = saved.destinationID
        next.bookID = saved.bookID; next.currency = saved.currency; next.date = saved.date
        draft = next
        expression = ""; amount = ""; actual = ""; received = ""; fee = ""; converted = ""; convertedFee = ""; filledValues = [:]
        reload()
        initialFingerprint = fingerprint
        error = nil
        notice = L("已记下 ", "Saved ") + saved.title + " " + Money.display(saved.amount, saved.currency, hidden: hidden) + L("，继续下一笔", ". Next one")
        focus = desiredAmountFocus
    }
}

// Association is a UUID on the entry, so deleting a task never cascades into financial records.
