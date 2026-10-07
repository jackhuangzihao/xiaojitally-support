import SwiftUI
import SwiftData

/// A value-only entry attached to an unsaved task. It never creates its own save or repeating template.
struct TaskFinanceDraft: Equatable {
    let ledger: FinanceData
    var entry: MoneyEntry
    var amount = ""
    var converted = ""
    private var lastEstimate: String?

    init(ledger: FinanceData, scheduledAt: Date? = nil, now: Date = Date()) {
        self.ledger = ledger
        entry = ledger.newEntry(preferredBook: nil)
        entry.date = MoneyEntry.timestamp(scheduledAt ?? now)
        entry.pending = Dates.calendar.startOfDay(for: entry.date) > Dates.calendar.startOfDay(for: now) ? true : nil
    }

    var referenceRate: MoneyRate? {
        // A future task does not yet have a historical rate for its future posting day.
        guard ExchangeRates.dayString(entry.date) <= ExchangeRates.dayString(Date()) else { return nil }
        return ledger.cachedReferenceRates(from: entry.currency, quotes: [ledger.baseCurrency], onOrBefore: ExchangeRates.dayString(entry.date)).first
    }
    var estimatedConversion: String? {
        guard let rate = referenceRate, let value = try? Money.parse(amount, currency: entry.currency), value > 0 else { return nil }
        return Money.text(Money.round(value * rate.rate, currency: ledger.baseCurrency))
    }
    mutating func refreshConversion() {
        if converted.isEmpty || converted == lastEstimate {
            converted = estimatedConversion ?? ""
            lastEstimate = estimatedConversion
        }
    }
    mutating func followAccountCurrency() {
        let currency = ledger.accounts.first { $0.id == entry.accountID }?.currency ?? ledger.baseCurrency
        guard entry.currency != currency else { return }
        entry.currency = currency
        // Changing denomination must not turn a typed AUD amount into the same number of CNY.
        amount = ""; converted = ""; lastEstimate = nil
    }

    func preparedLedger(taskID: UUID, title: String, current: FinanceData) throws -> FinanceData {
        var value = current
        let reopen = L("移除这笔未保存账单后重新添加，任务内容会保留。", "Remove this unsaved entry and add it again. Your task details will be kept.")
        do { try value.requireEntryCurrencies(entry, from: ledger) }
        catch { throw TaskBackup.invalid(error.localizedDescription + "\n" + reopen) }
        guard entry.kind == .expense || entry.kind == .income,
              value.books.contains(where: { $0.id == entry.bookID && !$0.archived }) else {
            throw TaskBackup.invalid(L("所选账本已归档或不存在。", "The selected book is archived or missing.") + "\n" + reopen)
        }
        if let id = entry.categoryID {
            guard value.categories.contains(where: { $0.id == id && !$0.archived && $0.isIncome == (entry.kind == .income) }) else {
                throw TaskBackup.invalid(L("分类已改变。", "The category changed.") + "\n" + reopen)
            }
        }
        let account = value.accounts.first { $0.id == entry.accountID }
        if entry.accountID != nil, account?.archived != false {
            throw TaskBackup.invalid(L("所选账户已归档或不存在。", "The selected account is archived or missing.") + "\n" + reopen)
        }
        guard entry.currency == (account?.currency ?? ledger.baseCurrency) else {
            throw TaskBackup.invalid(L("账户币种已改变，请重新输入金额。", "The account currency changed. Enter the amount again."))
        }
        var saved = entry
        saved.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        saved.taskID = taskID
        saved.date = MoneyEntry.timestamp(entry.date)
        saved.amount = try Money.parse(amount, currency: saved.currency)
        guard saved.amount > 0 else { throw TaskBackup.invalid(L("请输入大于 0 的账单金额。", "Enter an entry amount greater than 0.")) }
        saved.accountAmount = saved.accountID == nil ? 0 : saved.amount
        saved.baseAmount = saved.currency == ledger.baseCurrency ? saved.amount
            : (converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try Money.parse(converted, currency: ledger.baseCurrency))
        if let rate = referenceRate, converted == estimatedConversion {
            saved.rateNote = "ECB \(rate.date) · 1 \(rate.base) = \(Money.text(rate.rate)) \(rate.quote)"
        }
        try value.updateEntry(saved, expected: nil, baseCurrency: ledger.baseCurrency)
        try value.validate()
        return value
    }
}


struct TaskMoneySection: View {
    @AppStorage("appLanguage") private var language = "system"
    let task: TaskItem
    @Environment(\.modelContext) private var context
    @Query private var records: [FinanceLedger]
    @State private var editor: EntryRequest?
    @AppStorage("hideMoney") private var hidden = false
    @State private var error: String?
    var body: some View {
        // The first financial entry can start from a task as well as Finance.
        switch Result(catching: { try FinanceStore.read(context) ?? .initial }) {
        case .success(let ledger):
            section(ledger)
        case .failure(let failure):
            Label(L("无法读取关联账单：", "Unable to read linked entries: ") + failure.localizedDescription,
                  systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.red)
        }
    }
    private func section(_ ledger: FinanceData) -> some View {
        let linked = ledger.entries.filter { $0.taskID == task.id && $0.deletedAt == nil }
        return DisclosureGroup(L("关联账单", "Linked entries") + (linked.isEmpty ? "" : " · \(linked.count)")) {
            ForEach(linked) { entry in
                Button { editor = EntryRequest(entry: entry, expected: entry) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                            if entry.isPending { Text(L("待入账", "Pending")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(Money.display(entry.amount, entry.currency, hidden: hidden)).monospacedDigit()
                    }
                }.buttonStyle(.borderless).padding(.vertical, 4)
            }
            Button(L("为此任务记一笔", "Record an entry for this task")) {
                do {
                    let data = try FinanceStore.read(context) ?? .initial
                    var e = TaskFinanceDraft(ledger: data, scheduledAt: task.calendarDate).entry
                    e.title = String(task.title.prefix(80)); e.taskID = task.id
                    editor = EntryRequest(entry: e, expected: nil)
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderless).padding(.vertical, 4)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(item: $editor) { request in FinanceEntryEditor(entry: request.entry, expected: request.expected, confirmingPending: request.confirmingPending) }
    }
}
