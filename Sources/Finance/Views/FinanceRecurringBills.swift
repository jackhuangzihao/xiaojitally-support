import SwiftUI
import SwiftData
import OSLog

private let recurringLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tally", category: "FinanceRecurring")

extension FinanceHome {
    /// Recurring bills in Manage: schedule, account and next date at a glance, with edit, pause and stop.
    var recurringSection: some View {
        Section {
            let bills = data.recurringBills.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if bills.isEmpty {
                Text(L("在“记一笔”里把“重复”设为每月等，就会出现在这里。", "Set Repeat when adding an entry, for example Monthly, and the bill appears here."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(bills) { bill in recurringRow(bill) }
        } header: { SectionCountHeader(title: L("周期账单", "Recurring bills"), count: data.recurringBills.count).textCase(nil) } footer: {
            Text(L("到日期自动生成待入账，确认后才计入余额和统计。停止重复后不再生成新的账单，已到期和已入账的保留；想恢复可在它的账单上选“设为周期账单…”。", "Each due date adds a pending entry that counts after you confirm it. Stopping ends new entries and keeps due and posted ones; to restart, choose “Make recurring…” on one of its entries."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recurringRow(_ bill: MoneyRecurring) -> some View {
        let category = data.category(bill.categoryID)
        let detail = [bill.scheduleLabel, data.accounts.first { $0.id == bill.accountID }?.name]
            .compactMap { $0 }.joined(separator: " · ")
        let status = RecurringStatus(next: bill.nextDate, today: Date())
        return HStack(spacing: 10) {
            Button { editingRecurring = RecurringEditRequest(bill: bill) } label: {
                HStack(spacing: 10) {
                    MoneyIcon(symbol: category?.symbol ?? "repeat", emoji: category?.emoji,
                              tint: MoneyColor.color(category?.resolvedColor ?? "blue"), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(bill.title).lineLimit(1)
                            Text(status.label).tagStyle(status.tint, weight: status.needsAttention ? .semibold : .medium)
                        }
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let note = MoneyNote.firstLine(bill.notes) { Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                        if let issue = data.recurringIssue(bill) {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                    Text((bill.kind == .income ? "+" : "") + display(bill.amount, bill.currency)).font(.rowAmount)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(L("编辑", "Edit")) { editingRecurring = RecurringEditRequest(bill: bill) }
                Button(L("停止重复…", "Stop repeating…"), systemImage: "stop.circle", role: .destructive) { stoppingRecurring = bill }
            } label: {
                Label(L("管理周期账单", "Manage recurring bill"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel(L("管理周期账单：", "Manage recurring bill: ") + bill.title)
        }
    }

    func stopRecurring(_ bill: MoneyRecurring) {
        mutate { $0.stopRecurring(bill.id) }
        recurringLog.notice("Recurring bill stopped")
    }
    func stopMessage(_ bill: MoneyRecurring?) -> String {
        L("待入账里不再出现它，已经入账的全部保留。\n以后想恢复，可在它的任意一笔账单的“⋯”里选“设为周期账单…”。",
          "It leaves the pending list; every recorded entry stays.\nTo restart later, choose “Make recurring…” from any of its entries.")
    }
    func confirmPendingItem(_ confirmation: PendingEntryConfirmation) {
        if let occurrence = confirmation.occurrence {
            if mutate({ try $0.postOccurrence(of: occurrence.billID, scheduled: occurrence.scheduled, expected: occurrence.bill) }) {
                recurringLog.notice("Recurring occurrence confirmed")
            }
        } else {
            mutate { try $0.confirmPending(confirmation.entry) }
        }
    }
    func confirmPendingItemWithChanges(_ confirmation: PendingEntryConfirmation) {
        editor = confirmation.request
    }
    func postOccurrenceToday(_ confirmation: PendingEntryConfirmation) {
        guard let occurrence = confirmation.occurrence else { return }
        if mutate({ try $0.postOccurrence(of: occurrence.billID, scheduled: occurrence.scheduled, postedOn: Date(), expected: occurrence.bill) }) {
            recurringLog.notice("Recurring occurrence recorded today")
        }
    }
    func skipOccurrence(_ confirmation: PendingEntryConfirmation) {
        guard let occurrence = confirmation.occurrence else { return }
        if mutate({ try $0.skipOccurrence(of: occurrence.billID, scheduled: occurrence.scheduled, expected: occurrence.bill) }) {
            recurringLog.notice("Recurring occurrence skipped")
        }
    }

    /// Turns `entry` itself into a recurring bill, in the same page used to edit one.
    func restartRecurring(from entry: MoneyEntry) {
        editingRecurring = RecurringEditRequest(bill: data.recurringDraft(from: entry), source: entry)
    }
}

/// A recurring bill's occurrence being confirmed through the entry editor.
struct RecurringOccurrence {
    // In-memory opening snapshot, retained unchanged when the editor's draft is recovered.
    let bill: MoneyRecurring
    let scheduled: Date
    var billID: UUID { bill.id }
}

/// Which bill editor to open: editing a bill, or making one from an existing entry.
struct RecurringEditRequest: Identifiable {
    var bill: MoneyRecurring
    var source: MoneyEntry? = nil
    var id: UUID { bill.id }
}

/// Session-only values survive store recovery; the opening version is never refreshed implicitly.
struct FinanceRecurringDraft: Equatable {
    let original: MoneyRecurring
    let source: MoneyEntry?
    var bill: MoneyRecurring
    var amount: String
    var accountAmount: String

    var request: RecurringEditRequest { RecurringEditRequest(bill: original, source: source) }
    var dirty: Bool {
        source != nil || bill != original || amount != Money.text(original.amount)
            || accountAmount != (original.accountAmount == 0 ? "" : Money.text(original.accountAmount))
    }

    func apply(to ledger: inout FinanceData) throws {
        var next = bill
        let account = ledger.accounts.first { $0.id == next.accountID }
        next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
        next.amount = try Money.parse(amount, currency: next.currency)
        if let account, account.currency != next.currency {
            next.accountAmount = try Money.parse(accountAmount, currency: account.currency)
        } else { next.accountAmount = 0 }
        if next.currency == ledger.baseCurrency || account?.currency == ledger.baseCurrency
            || next.accountID != original.accountID || next.amount != original.amount {
            next.baseAmount = nil
        }
        if let source {
            guard ledger.entries.first(where: { $0.id == source.id }) == source else {
                throw TaskBackup.invalid(L("原账单已修改或删除，未保存周期规则。输入仍保留，请重新打开核对。",
                                          "The original entry changed or was deleted. The rule was not saved. Your input is kept; reopen to review."))
            }
            try ledger.makeRecurring(next, from: source.id)
        } else { try ledger.updateRecurring(next, expected: original) }
    }
}

/// Edits a bill's amount, account, category, book, schedule and notes. Changes apply from today on;
/// entries already generated keep their own values.
struct FinanceRecurringEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorDrafts.self) private var drafts
    @State private var generation = Store.recovery.generation
    let original: MoneyRecurring
    let ledger: FinanceData
    /// Set when turning an existing entry into a bill; that entry becomes its first occurrence.
    let source: MoneyEntry?
    @State private var bill: MoneyRecurring
    @State private var amount: String
    @State private var accountAmount: String
    @State private var error: String?
    @State private var didSave = false
    @State private var confirmDiscard = false
    private var currentDraft: FinanceRecurringDraft {
        FinanceRecurringDraft(original: original, source: source, bill: bill, amount: amount, accountAmount: accountAmount)
    }
    private var dirty: Bool { !didSave && currentDraft.dirty }

    init(bill: MoneyRecurring, ledger: FinanceData, source: MoneyEntry? = nil, draft: FinanceRecurringDraft? = nil) {
        let kept = draft.flatMap { $0.original.id == bill.id ? $0 : nil }
        original = kept?.original ?? bill; self.ledger = ledger; self.source = kept?.source ?? source
        _bill = State(initialValue: kept?.bill ?? bill)
        _amount = State(initialValue: kept?.amount ?? Money.text(bill.amount))
        _accountAmount = State(initialValue: kept?.accountAmount ?? (bill.accountAmount == 0 ? "" : Money.text(bill.accountAmount)))
    }

    private var account: MoneyAccount? { ledger.accounts.first { $0.id == bill.accountID } }
    private var footer: String {
        if let source {
            return L("原来那笔（\(Dates.label(source.date, pattern: "M月d日"))）作为已入账的第一期，不会被复制。下一期日期默认是下个周期，可以改。",
                     "The original entry (\(Dates.label(source.date, pattern: "MMM d"))) becomes the first, recorded occurrence and is not copied. The next date defaults to the following period.")
        }
        return L("修改只改规则，待入账会立刻按新规则显示；已经入账的不受影响。", "Changes edit the rule only. The pending list follows at once; recorded entries are unaffected.")
    }
    /// The next date as a whole day picker; its time of day is kept.
    private var nextDay: Binding<Date> {
        Binding(get: { bill.nextDate }, set: { day in
            guard let calendar = bill.recurrenceCalendar else { return }
            let time = calendar.dateComponents([.hour, .minute], from: bill.nextDate)
            guard let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) else { return }
            bill.reschedule(to: date)
        })
    }
    private var foreignAccount: Bool { account.map { $0.currency != bill.currency } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if let issue = ledger.recurringIssue(bill) {
                    Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                Section {
                    TextField(L("名称", "Name"), text: $bill.title)
                    LabeledContent(L("类型", "Type"), value: bill.kind.label)
                    HStack {
                        TextField(L("金额", "Amount"), text: $amount)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Text(bill.currency).foregroundStyle(.secondary)
                    }
                    Picker(L("账户", "Account"), selection: $bill.accountID) {
                        Text(L("不计入账户（只记收支）", "No account (totals only)")).tag(nil as UUID?)
                        ForEach(ledger.accounts.filter { !$0.archived || $0.id == original.accountID }) { Text($0.name + " · " + $0.currency).tag(Optional($0.id)) }
                    }
                    if let account, foreignAccount {
                        HStack {
                            TextField(L("账户计划金额", "Planned account amount"), text: $accountAmount)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text(account.currency).foregroundStyle(.secondary)
                        }
                    }
                    Picker(L("分类", "Category"), selection: $bill.categoryID) {
                        Text(L("未分类", "Uncategorized")).tag(nil as UUID?)
                        ForEach(ledger.orderedCategories.filter { $0.isIncome == (bill.kind == .income) && (!$0.archived || $0.id == original.categoryID) }) {
                            Text($0.parentID == nil ? $0.label : ledger.categoryPath($0.id)).tag(Optional($0.id))
                        }
                    }
                    Picker(L("账本", "Book"), selection: $bill.bookID) {
                        ForEach(ledger.books.filter { !$0.archived || $0.id == original.bookID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section {
                    DatePicker(L("下一期日期", "Next date"), selection: nextDay, displayedComponents: .date)
                        .environment(\.calendar, bill.recurrenceCalendar ?? Dates.calendar)
                        .environment(\.timeZone, (bill.recurrenceCalendar ?? Dates.calendar).timeZone)
                        .disabled(bill.recurrenceCalendar == nil)
                        .accessibilityHint(L("每月几号、每周几都跟着这一天", "The day of month or week follows this date"))
                    RecurringScheduleControls(rule: $bill.rule, until: $bill.until, start: bill.nextDate, allowsNone: false, repeatTimeZoneID: bill.repeatTimeZoneID)
                } header: { Text(L("重复", "Repeat")) } footer: {
                    Text(footer).font(.caption).foregroundStyle(.secondary)
                }
                Section { TextField(L("备注", "Notes"), text: $bill.notes, axis: .vertical).lineLimit(2...6) }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle(source == nil ? L("修改周期账单", "Edit recurring bill") : L("设为周期账单", "Make recurring"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { if dirty { confirmDiscard = true } else { close() } }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存", "Save"), action: save).keyboardShortcut("s", modifiers: .command)
                        .disabled(bill.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(dirty)
        .modifier(UnsavedEditorGuard(hasChanges: { dirty }))
        .confirmationDialog(L("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(L("放弃修改", "Discard changes"), role: .destructive, action: close)
            Button(L("继续编辑", "Keep editing"), role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 620)
        #endif
        .onAppear { keepDraft() }
        .onChange(of: currentDraft) { _, _ in keepDraft() }
        .onDisappear { drafts.clearRecurringDraft(id: original.id, generation: generation) }
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }

    private func keepDraft() {
        guard !didSave, generation == Store.recovery.generation else { return }
        drafts.financeRecurring = currentDraft
    }
    private func close() {
        drafts.clearRecurringDraft(id: original.id, generation: generation)
        dismiss()
    }
    private func save() {
        guard !didSave else { return }
        keepDraft()
        do {
            try FinanceStore.update(context) { try currentDraft.apply(to: &$0) }
            didSave = true
            recurringLog.notice("Recurring bill updated; rule=\(bill.rule, privacy: .public)")
            close()
        } catch {
            self.error = error.localizedDescription
            recurringLog.error("Recurring bill save failed; session draft retained")
        }
    }
}

/// Where a recurring bill stands today, shown as a tag beside its name: missed, due today, or the next date.
enum RecurringStatus: Equatable {
    case missed(Date)
    case dueToday
    case upcoming(Date)

    init(next: Date, today: Date, calendar: Calendar = Dates.calendar) {
        let day = calendar.startOfDay(for: next), now = calendar.startOfDay(for: today)
        self = day < now ? .missed(next) : day == now ? .dueToday : .upcoming(next)
    }

    var label: String {
        switch self {
        case .missed(let date): L("已错过 ", "Missed ") + Dates.label(date, pattern: "M月d日")
        case .dueToday: L("今天到期", "Due today")
        case .upcoming(let date): L("下次 ", "Next ") + Dates.label(date, pattern: "M月d日")
        }
    }

    var needsAttention: Bool { if case .upcoming = self { false } else { true } }

    var tint: Color {
        switch self {
        case .missed: .red
        case .dueToday: .orange
        case .upcoming: .secondary
        }
    }
}
