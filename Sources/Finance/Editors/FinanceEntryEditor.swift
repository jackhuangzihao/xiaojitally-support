import SwiftUI
import OSLog
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
    var confirmingPending = false
    /// Set when confirming a recurring bill's occurrence, which is not stored until it is confirmed.
    var occurrence: RecurringOccurrence? = nil
    var id: UUID { entry.id }
}

struct FinanceDraft {
    var ledger: FinanceData
    var entry: MoneyEntry
    var expected: MoneyEntry?
    var amount: String, actual: String, received: String, fee: String, converted: String, convertedFee: String
    var balance: Decimal
    var expression: String? = nil
    var confirmingPending = false
    var repeatRule = "none"
    var repeatUntil: Date? = nil
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
    private enum Field: Hashable { case amount, title, actual, received, fee, converted, convertedFee, notes }
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("hideMoney") private var hidden = false
    let expected: MoneyEntry?
    let confirmingPending: Bool
    let occurrence: RecurringOccurrence?
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
    /// Set once a save has gone through and the sheet is closing; a second click in that moment must not save again.
    @State private var didSave = false
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
    @State private var repeatRule = "none"
    @State private var repeatUntil: Date?
    @State private var titleIndex = MoneyTitleIndex()
    /// Fields the user chose in this editor; a typed name never overrides them.
    @State private var chosenByUser: Set<SuggestedField> = []
    private enum SuggestedField { case category, account }
    @FocusState private var focus: Field?
    init(entry: MoneyEntry, expected: MoneyEntry?, confirmingPending: Bool = false, occurrence: RecurringOccurrence? = nil) {
        self.confirmingPending = confirmingPending; self.occurrence = occurrence
        self.expected = expected; _draft = State(initialValue: entry)
        let text = entry.amount == 0 ? "" : Money.text(entry.amount)
        _amount = State(initialValue: text)
        _expression = State(initialValue: text.replacingOccurrences(of: "-", with: "−"))
        _actual = State(initialValue: entry.accountAmount == 0 ? "" : Money.text(entry.accountAmount))
        _received = State(initialValue: entry.destinationAmount == 0 ? "" : Money.text(entry.destinationAmount))
        _fee = State(initialValue: entry.fee == 0 ? "" : Money.text(entry.fee))
        _converted = State(initialValue: entry.baseAmount.map(Money.text) ?? "")
        _convertedFee = State(initialValue: entry.baseFee.map(Money.text) ?? "")
        _showMore = State(initialValue: !entry.notes.isEmpty || entry.taskID != nil)
    }
    private var account: MoneyAccount? { ledger.accounts.first { $0.id == draft.accountID } }
    private var destination: MoneyAccount? { ledger.accounts.first { $0.id == draft.destinationID } }
    private var fingerprint: String { String(describing: draft) + [expression, amount, actual, received, fee, converted, convertedFee, repeatRule, String(describing: repeatUntil)].joined(separator: "|") }
    /// Repeat sits under "pending": only a new, ordinary income or expense saved as pending can start a recurring bill.
    private var canRepeat: Bool {
        expected == nil && !confirmingPending && (draft.kind == .expense || draft.kind == .income) && draft.taskID == nil
            && draft.refundOf == nil && draft.isPending
    }
    private var repeating: Bool { canRepeat && repeatRule != "none" }
    /// Only a new income or expense learns from earlier names.
    private var suggestsFromHistory: Bool { expected == nil && !confirmingPending && (draft.kind == .expense || draft.kind == .income) }
    private var titleSuggestions: [MoneyEntrySuggestion] {
        suggestsFromHistory && focus == .title ? titleIndex.matches(draft.title, kind: draft.kind) : []
    }
    private var dirty: Bool { loaded && fingerprint != initialFingerprint }
    private var rateQuery: String { "\(loaded)-\(automaticRates)-\(draft.currency)-\(draft.accountID?.uuidString ?? "")-\(draft.destinationID?.uuidString ?? "")-\(Dates.calendar.startOfDay(for: draft.date).timeIntervalSince1970)" }
    private static let postingLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tally", category: "FinancePosting")
    private var futurePlan: Bool { draft.isPending && Dates.calendar.startOfDay(for: draft.date) > Dates.calendar.startOfDay(for: Date()) }
    private var foreign: Bool { draft.currency != ledger.baseCurrency }
    private var desiredAmountFocus: Field? {
        #if os(iOS)
        return showCalculator ? nil : .amount
        #else
        return .amount
        #endif
    }
    private var simpleKind: Bool { draft.kind == .expense || draft.kind == .income || draft.kind == .transfer }
    private var kindChangeBlock: String? { expected.flatMap { ledger.entryKindChangeBlock($0) } }
    private var signedAmount: Bool { draft.kind == .adjustment }
    /// A bill's occurrence is not stored yet, but confirming it is not a fresh entry either.
    private var heading: String {
        occurrence != nil ? L("确认周期账单", "Confirm recurring bill")
            : expected == nil ? L("新增账单", "New entry") : L("编辑已有账单", "Edit existing entry")
    }
    private var activeAccounts: [MoneyAccount] { ledger.accounts.filter { ledger.allowsAccount($0.id, for: draft, replacing: expected) } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if compact { Text(heading).font(.caption).foregroundStyle(.secondary) }
            if !compact {
                amountRow.padding(.horizontal, 18).padding(.vertical, 12)
                chips.padding(.horizontal, 18).padding(.bottom, 8)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if compact { amountRow; chips; Divider() }
                    if expected != nil || occurrence != nil, let bill = ledger.recurringBill(draft.recurringID) { RecurringOriginBanner(bill: bill, ledger: ledger) }
                    if draft.accountID == nil && (draft.kind == .expense || draft.kind == .income) {
                        Text(draft.isPending
                             ? L("未选择账户：确认后只计入收支，不改变资产余额。", "No account selected: after confirmation, this counts in totals without changing an account balance.")
                             : L("未选择账户：这笔只计入收支，不改变资产余额。点“账户”可选择或添加账户。", "No account selected: this entry counts in totals but won't change an account balance. Use Account to choose or add one."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Any new income or expense can be saved as pending; repeat options appear under it.
                    if expected == nil && !confirmingPending && (draft.kind == .expense || draft.kind == .income) {
                        // The pending switch and the repeat choices it reveals share one card.
                        VStack(alignment: .leading, spacing: 12) {
                            MoneyPostingChoice(entry: $draft).toggleStyle(.switch)
                            if canRepeat { Divider(); repeatSection }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).cardSurface()
                    } else {
                        if draft.isPending {
                            Label(confirmingPending
                                  ? L("核对金额和日期后确认入账。", "Review the amount and date, then confirm the entry.")
                                  : L("待入账 · 尚未计入余额和统计", "Pending · Excluded from balances and totals"), systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if canRepeat { repeatSection }
                    }
                    if showMore { moreFields }
                    if let kindChangeBlock, expected?.kind == .expense {
                        Text(kindChangeBlock).font(.caption).foregroundStyle(.secondary)
                    }
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
        // A fixed height: the keypad takes room from the scrolling fields instead of resizing the window, which jumps on macOS.
        .frame(minWidth: 520, idealWidth: 540, minHeight: 620, idealHeight: 700)
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
                    repeatRule = kept.repeatRule; repeatUntil = kept.repeatUntil
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
            if loaded && (expected == nil || confirmingPending) && needsRate && automaticRates { await fetchAndFillRates() }
        }
        #if os(iOS)
        .onChange(of: focus) { _, focusedField in
            // The system keyboard and the calculator must not consume the sheet together.
            if focusedField != nil && showCalculator { withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showCalculator = false } }
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
            if kind == .transfer { draft.pending = nil }
            if kind == .transfer, let account { draft.currency = account.currency }
            if kind != .transfer { draft.destinationID = nil; received = ""; fee = ""; convertedFee = "" }
            if kind == .expense || kind == .income, ledger.category(draft.categoryID)?.isIncome != (kind == .income) {
                draft.categoryID = ledger.defaultCategory(income: kind == .income)
            }
            focus = desiredAmountFocus
        }
        .onChange(of: draft.destinationID) { _, _ in received = "" }
        .modifier(EntryDraftObservers(canRepeat: canRepeat, title: draft.title, repeatAllowed: repeatAllowedChanged, titleChanged: titleChanged))
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
                    ForEach(expected == nil ? [MoneyKind.expense, .income, .transfer] : expected?.kind == .transfer ? [.transfer] : [.expense, .income]) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 230).disabled(kindChangeBlock != nil)
            } else { Text(draft.kind.label).font(.headline) }
            Spacer()
            if !compact { Text(heading).font(.subheadline).foregroundStyle(.secondary) }
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
        return FinanceEntryCategories(compact: compact, dynamicTypeSize: dynamicTypeSize,
                                      roots: roots, children: children, parent: ledger.category(selectedRoot),
                                      selectedRoot: selectedRoot, categoryID: $draft.categoryID,
                                      categoryPath: ledger.categoryPath) { id in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) { draft.categoryID = id }
            chosenByUser.insert(.category)
            focus = desiredAmountFocus
        } addCategory: { parentID in
            entity = EntityRequest(kind: .category, income: income, parentID: parentID)
        }
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
                amountField(account.name + (draft.isPending && !confirmingPending ? L(" 计划金额", " planned amount") : (draft.kind == .expense) ? L(" 实际扣款", " charged") : L(" 实际入账", " received")), currency: account.currency, text: $actual, field: .actual)
            }
            if foreign && draft.kind != .transfer && draft.kind != .adjustment && account?.currency != ledger.baseCurrency {
                amountField(draft.isPending && !confirmingPending ? L("计划折算金额", "Planned conversion") : L("计入统计", "Counts in totals as"), currency: ledger.baseCurrency, text: $converted, field: .converted)
            }
            if draft.kind == .transfer && foreign && !fee.isEmpty { amountField(L("手续费折合", "Fee in base currency"), currency: ledger.baseCurrency, text: $convertedFee, field: .convertedFee) }
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))) {
                Text(draft.rateNote.isEmpty ? L("还没有参考汇率", "No reference rate yet") : draft.rateNote).font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(gettingRates ? L("获取中…", "Fetching…") : L("按参考汇率填入", "Fill with reference rate")) { fillRates() }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil).disabled(gettingRates || amount.isEmpty || futurePlan)
            }
            Toggle(L("自动获取参考汇率", "Fetch reference rates automatically"), isOn: $automaticRates).font(.caption)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            Text(draft.isPending
                 ? L("计划金额仅供核对，确认前请填写实际扣款及折算金额。未来日期暂不自动填写参考价。", "Review planned amounts against the actual charge and conversion before confirming. Future dates have no automatic reference rate.")
                 : L("以银行实际扣款为准：改成实际金额后不会被覆盖；历史账单不随汇率变化。", "Use what your bank actually charged; amounts you enter are never overwritten, and history never changes with rates.")).font(.caption).foregroundStyle(.secondary)
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
    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("重复", "Repeat"), systemImage: "repeat").font(.callout.weight(.medium))
            RecurringScheduleControls(rule: $repeatRule, until: $repeatUntil, start: draft.date)
            Text(repeating
                 ? L("保存为周期账单：上面的日期是第一期。每一期到日期后出现在待入账里，确认后才计入余额和统计。",
                     "Saved as a recurring bill with the date above as its first occurrence. Each one appears in Pending when due and counts after you confirm it.")
                 : L("不重复：一次性的待入账，到日期确认后计入。", "Once: a single pending entry, counted after you confirm it on or after its date."))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("finance.repeat")
    }
    private var moreFields: some View {
        FinanceEntryDetails(compact: compact, tasks: tasks, notes: $draft.notes, taskID: $draft.taskID,
                            focus: $focus, notesFocus: Field.notes)
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            statusLine
            if showCalculator { keypad.transition(.move(edge: .bottom).combined(with: .opacity)) }
            HStack(spacing: 12) {
                Spacer()
                #if os(iOS)
                Button {
                    focus = nil
                } label: {
                    Label(L("收起键盘", "Dismiss keyboard"), systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                #endif
                if expected == nil && occurrence == nil && simpleKind && !compact && !repeating {
                    Button { save(again: true) } label: {
                        HStack(spacing: 6) {
                            Text(L("保存并继续", "Save + new"))
                            Text("⌘↩").foregroundStyle(.tertiary)
                        }
                    }
                        .buttonStyle(CardButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L("保存并继续下一笔（⌘↩）", "Save and start another (⌘↩)"))
                        .disabled(!loaded || gettingRates || draft.deletedAt != nil)
                }
                Button(confirmingPending ? L("确认入账", "Confirm entry") : repeating ? L("保存周期账单", "Save recurring bill") : draft.isPending ? L("保存待入账", "Save pending") : compact ? L("保存", "Save") : expected == nil ? L("保存新账单", "Save new entry") : L("保存修改", "Save changes")) { save() }.buttonStyle(.borderedProminent)
                    .controlSize(compact ? .large : .regular)
                    .frame(maxWidth: compact ? .infinity : nil, minHeight: compact ? 44 : nil)
                    .keyboardShortcut(.defaultAction).disabled(!loaded || gettingRates || draft.deletedAt != nil)
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .top) { noticeBar.offset(y: -48) }
    }
    private var amountRow: some View {
        let value = Money.evaluate(expression, currency: draft.currency, signed: signedAmount)
        return FinanceEntryAmount(compact: compact, kind: draft.kind, signedAmount: signedAmount, value: value,
                                  currency: $draft.currency, expression: $expression, title: $draft.title,
                                  focus: $focus, amountFocus: Field.amount, titleFocus: Field.title,
                                  calculatorOn: showCalculator,
                                  toggleCalculator: {
                                      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showCalculator.toggle() }
                                      focus = desiredAmountFocus
                                  },
                                  nameHint: suggestsFromHistory,
                                  suggestions: titleSuggestions,
                                  detail: { [ledger] suggestion in
                                      "· " + [ledger.category(suggestion.categoryID)?.label,
                                              ledger.account(suggestion.accountID)?.name ?? L("不计入账户", "No account")]
                                          .compactMap { $0 }.joined(separator: " · ")
                                  }) { suggestion in
            // Choosing a name is an explicit request for its category and account.
            chosenByUser = []
            draft.title = suggestion.title
            applySuggestion(suggestion)
            focus = desiredAmountFocus
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
                Picker(L("账户", "Account"), selection: Binding(get: { draft.accountID }, set: { draft.accountID = $0; chosenByUser.insert(.account) })) {
                    Text(L("不计入账户（只记收支）", "No account (totals only)")).tag(nil as UUID?)
                    ForEach(activeAccounts) { a in Text(a.name + " · " + Money.display(accountBalances[a.id, default: 0], a.currency, hidden: hidden)).tag(Optional(a.id)) }
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                Button(L("新增账户…", "New account…")) { entity = EntityRequest(kind: .account) }
            } label: {
                entryChipLabel(L("账户", "Account"), value: account?.name ?? L("不计入账户", "No account"), symbol: account?.iconSymbol ?? "wallet.pass", emoji: account?.emoji)
            }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: !compact, vertical: false)
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
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: !compact, vertical: false)
            .disabled(draft.kind == .refund)
    }
    private var moreChip: some View {
        Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showMore.toggle() } } label: {
            entryChipLabel(showMore ? L("收起", "Less") : L("更多", "More"), value: L("备注与关联任务", "Notes & linked task"), symbol: showMore ? "chevron.up" : "ellipsis", desktopTitle: showMore ? L("收起", "Less") : L("更多", "More"))
        }.buttonStyle(.plain).fixedSize(horizontal: !compact, vertical: false).help(L("备注、关联任务", "Notes and linked task"))
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
    /// Confirmations float above the buttons like the to-do notices and fade after a moment; errors stay in place.
    @ViewBuilder private var noticeBar: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle").font(.caption).lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.16)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.horizontal, 18)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { self.notice = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
    @ViewBuilder private var statusLine: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
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
            if expected == nil { titleIndex = MoneyTitleIndex(current) }
        } catch { self.error = error.localizedDescription }
    }
    private func fillRates() {
        Task { await fetchAndFillRates() }
    }
    private func fetchAndFillRates() async {
        guard !futurePlan else { return }
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
    // Observers live in a small modifier so the long body stays within the type checker's budget.
    private func repeatAllowedChanged(_ allowed: Bool) {
        if !allowed { repeatRule = "none"; repeatUntil = nil }
    }
    private func titleChanged(_ title: String) {
        if suggestsFromHistory, let match = titleIndex.exact(title, kind: draft.kind) { applySuggestion(match) }
    }
    /// Takes the category and account an earlier entry with this name used, except where the user already chose.
    /// An account in another currency is skipped once an amount is typed, so the amount never changes meaning.
    private func applySuggestion(_ suggestion: MoneyEntrySuggestion) {
        var applied: [String] = []
        if !chosenByUser.contains(.category), let id = suggestion.categoryID, id != draft.categoryID,
           let category = ledger.category(id), !category.archived, category.isIncome == (draft.kind == .income) {
            draft.categoryID = id; applied.append(L("分类", "category"))
        }
        if !chosenByUser.contains(.account), let id = suggestion.accountID, id != draft.accountID,
           let account = activeAccounts.first(where: { $0.id == id && !$0.archived }),
           expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.currency == draft.currency {
            draft.accountID = id; applied.append(L("账户", "account"))
        }
        error = nil
        if !applied.isEmpty {
            notice = L("已按上次“\(suggestion.title)”选好", "Picked the ") + applied.joined(separator: L("和", " and ")) + L("", " used last time for “\(suggestion.title)”")
        } else if draft.categoryID == suggestion.categoryID && (suggestion.accountID == nil || draft.accountID == suggestion.accountID) {
            // Without this, a match that changes nothing looks as if it was ignored.
            notice = L("分类和账户与上次“\(suggestion.title)”相同", "Category and account already match “\(suggestion.title)”")
        }
    }
    private func keepDraft() {
        drafts.finance = FinanceDraft(ledger: ledger, entry: draft, expected: expected, amount: amount, actual: actual, received: received, fee: fee, converted: converted, convertedFee: convertedFee, balance: initialBalance, expression: expression, confirmingPending: confirmingPending,
                                     repeatRule: repeatRule, repeatUntil: repeatUntil)
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
        guard !didSave else { return }
        do {
            keepDraft()
            let e = try preparedEntry()
            try TaskLinkRule.check(newTaskID: e.taskID, previousTaskID: expected?.taskID) { id in
                tasks.contains { $0.id == id && $0.deletedAt == nil }
            }
            if repeating {
                // Only the rule is saved; its first occurrence (this date) appears in Pending as a preview.
                let bill = MoneyRecurring(repeating: e, rule: repeatRule, until: repeatUntil, in: ledger)
                try FinanceStore.update(context) { value in
                    try value.requireEntryCurrencies(e, from: ledger)
                    try value.addRecurring(bill)
                }
                Self.postingLog.info("Recurring bill created; rule=\(bill.rule, privacy: .public)")
            } else if let occurrence {
                try FinanceStore.update(context) { value in
                    try value.requireEntryCurrencies(e, from: ledger)
                    try value.postOccurrence(of: occurrence.billID, scheduled: occurrence.scheduled, entry: e)
                }
                Self.postingLog.info("Recurring occurrence confirmed with changes")
            } else {
                try FinanceStore.update(context) { value in
                    try value.requireEntryCurrencies(e, from: ledger)
                    try value.updateEntry(e, expected: expected, baseCurrency: ledger.baseCurrency, referenceRates: rates)
                    if confirmingPending { try value.confirmPending(e) }
                }
                Self.postingLog.info("Entry save completed; pending=\(e.isPending && !confirmingPending), confirmation=\(confirmingPending)")
            }
            if let id = e.bookID { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyBook") }
            if e.kind == .expense || e.kind == .income { UserDefaults.standard.set(e.accountID?.uuidString ?? "none", forKey: "lastMoneyAccount") }
            if let id = e.categoryID, e.kind == .expense || e.kind == .income { UserDefaults.standard.set(id.uuidString, forKey: "lastMoneyCategory." + (e.kind == .income ? "income" : "expense")) }
            if again { startAnother(after: e) } else { didSave = true; dismiss() }
        } catch {
            Self.postingLog.error("Entry save failed: \(error.localizedDescription, privacy: .private)")
            self.error = error.localizedDescription; notice = nil
        }
    }
    /// Keeps kind, category, account, book, currency and day, so a run of receipts is only amounts.
    private func startAnother(after saved: MoneyEntry) {
        var next = MoneyEntry()
        next.kind = saved.kind; next.categoryID = saved.categoryID; next.accountID = saved.accountID; next.destinationID = saved.destinationID
        next.bookID = saved.bookID; next.currency = saved.currency; next.date = saved.date; next.pending = saved.pending
        draft = next
        chosenByUser = []
        expression = ""; amount = ""; actual = ""; received = ""; fee = ""; converted = ""; convertedFee = ""; filledValues = [:]
        reload()
        initialFingerprint = fingerprint
        error = nil
        notice = L("已记下 ", "Saved ") + saved.title + " " + Money.display(saved.amount, saved.currency, hidden: hidden) + L("，继续下一笔", ". Next one")
        focus = desiredAmountFocus
    }
}

// Association is a UUID on the entry, so deleting a task never cascades into financial records.

/// Change observers for repeat and name suggestions, kept out of the editor's long modifier chain.
private struct EntryDraftObservers: ViewModifier {
    let canRepeat: Bool
    let title: String
    let repeatAllowed: (Bool) -> Void
    let titleChanged: (String) -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: canRepeat) { _, allowed in repeatAllowed(allowed) }
            .onChange(of: title) { _, value in titleChanged(value) }
    }
}
