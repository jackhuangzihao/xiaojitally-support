import SwiftUI
import SwiftData
import OSLog

private let linkLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "TaskMoney")

// MARK: - Task ↔ entry links
//
// An entry belongs to at most one task (`MoneyEntry.taskID`); a task can have any number of entries. The link is
// stored only on the entry, so the task side is always derived and two devices can never disagree about it.
// Three rules, and no others:
// 1. Completing a task offers to post its pending entries; they can always be posted from Finance instead.
// 2. Deleting a task never deletes money. In Recently deleted its entries stay linked; purging it unlinks them.
// 3. A task in Recently deleted takes no new entries. Restoring it allows them again.

/// What a task row shows about its entries.
struct TaskMoneySummary: Equatable {
    struct Line: Equatable {
        var title: String
        var amount: Decimal
        var currency: String
        var pending: Bool
        var date: Date
    }
    /// Newest first.
    var lines: [Line] = []
    var pendingCount = 0
    /// Income minus spending in the base currency, or nil while an entry still needs its conversion.
    var net: Decimal? = 0

    var count: Int { lines.count }

    /// "¥3,200 · 待入账", "¥5,180 · 2 笔", "+¥300 · 1 笔待入账".
    func label(baseCurrency: String, hidden: Bool) -> String {
        let amount: String? = net.flatMap { value in
            value == 0 ? nil : (value > 0 ? "+" : "") + Money.display(abs(value), baseCurrency, hidden: hidden)
        }
        let status = pendingCount == count ? L("待入账", "Pending")
            : pendingCount > 0 ? L("\(pendingCount) 笔待入账", "\(pendingCount) pending")
            : L("\(count) 笔", count == 1 ? "1 entry" : "\(count) entries")
        return [amount, status].compactMap { $0 }.joined(separator: " · ")
    }
    /// One line per entry, for the pointer tooltip and the expanded card.
    func detail(hidden: Bool) -> String {
        lines.map { line in
            line.title + " · " + (line.pending ? L("待入账", "Pending") : L("已入账", "Posted")) + "  " + Money.display(line.amount, line.currency, hidden: hidden)
        }.joined(separator: "\n")
    }
}

/// Every task's linked entries, built once per ledger so task rows never scan the entries themselves.
struct TaskMoneyIndex: Equatable {
    private(set) var baseCurrency = "CNY"
    private var summaries: [UUID: TaskMoneySummary] = [:]

    init() {}
    init(_ ledger: FinanceData) {
        baseCurrency = ledger.baseCurrency
        for entry in ledger.entries where entry.deletedAt == nil {
            guard let id = entry.taskID else { continue }
            var summary = summaries[id] ?? TaskMoneySummary()
            summary.lines.append(.init(title: entry.title, amount: entry.amount, currency: entry.currency, pending: entry.isPending, date: entry.date))
            if entry.isPending { summary.pendingCount += 1 }
            let sign: Decimal? = entry.kind == .income || entry.kind == .refund ? 1 : entry.kind == .expense ? -1 : nil
            if let sign { summary.net = entry.baseAmount.flatMap { base in summary.net.map { $0 + sign * base } } }
            summaries[id] = summary
        }
        for id in summaries.keys { summaries[id]!.lines.sort { $0.date > $1.date } }
    }

    func summary(for taskID: UUID) -> TaskMoneySummary? { summaries[taskID] }
}

/// Rule 3: an entry may keep a link to a task in Recently deleted, but not gain one.
enum TaskLinkRule {
    static func check(newTaskID: UUID?, previousTaskID: UUID?, taskIsAvailable: (UUID) -> Bool) throws {
        guard let id = newTaskID, id != previousTaskID, !taskIsAvailable(id) else { return }
        throw TaskBackup.invalid(L("这个任务已删除，不能再关联新的账单。恢复任务后可以再关联。", "This task was deleted and cannot take new entries. Restore it to link entries again."))
    }
}

/// The outcome of posting a task's pending entries in one step.
struct TaskSettlement: Equatable {
    var posted: [MoneyEntry] = []
    /// Entries that cannot be posted as they stand (a missing conversion, an archived book…); they open in the editor.
    var needsReview: [MoneyEntry] = []
}

extension FinanceData {
    /// Rule 1. Posts every pending entry of a task: one already due keeps its planned date, one not due yet is
    /// posted today. Each entry is posted on its own, so one that needs attention never blocks the others.
    mutating func settlePendingEntries(ofTask taskID: UUID, now: Date = Date()) -> TaskSettlement {
        var result = TaskSettlement()
        for original in entries where original.taskID == taskID && original.isPending && original.deletedAt == nil {
            // A foreign amount without its conversion would leave the totals incomplete.
            if original.currency != baseCurrency && original.baseAmount == nil { result.needsReview.append(original); continue }
            var next = self
            do {
                var entry = original
                if !entry.isDueForConfirmation(at: now) {
                    entry.date = MoneyEntry.timestamp(now)
                    try next.updateEntry(entry, expected: original, baseCurrency: baseCurrency)
                }
                try next.confirmPending(entry, now: now)
                self = next
                result.posted.append(entry)
            } catch {
                result.needsReview.append(original)
            }
        }
        return result
    }

    /// Rule 2. Entries of permanently deleted tasks stay, without a link to a task that no longer exists.
    @discardableResult mutating func unlinkTasks(_ ids: Set<UUID>) -> Int {
        var count = 0
        for index in entries.indices where entries[index].taskID.map(ids.contains) == true {
            entries[index].taskID = nil; count += 1
        }
        return count
    }
}

extension FinanceStore {
    /// Stages the unlinking of purged tasks' entries, to be saved with the purge itself.
    static func stageUnlinking(_ ids: Set<UUID>, in context: ModelContext) throws {
        guard !ids.isEmpty, var ledger = try read(context) else { return }
        let count = ledger.unlinkTasks(ids)
        guard count > 0 else { return }
        try stage(ledger, in: context)
        linkLog.notice("Unlinked \(count, privacy: .public) entries from purged tasks")
    }
}

/// The prompt after completing a task with pending entries.
struct SettlementOffer: Identifiable, Equatable {
    let id = UUID()
    let taskID: UUID
    let message: String
    let buttonTitle: String
}

/// What an entry row shows about its task.
struct TaskLink: Equatable {
    var title: String
    var deleted: Bool
}

/// Keeps the task views' `TaskMoneyIndex` in step with the ledger, rebuilding it only when the ledger changes.
struct TaskMoneyLoader: View {
    @Binding var index: TaskMoneyIndex
    @Query private var records: [FinanceLedger]

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .task(id: records.first?.payload) { refresh() }
    }

    private func refresh() {
        guard let payload = records.first?.payload else { index = TaskMoneyIndex(); return }
        do { index = TaskMoneyIndex(try FinanceStore.decode(payload)) }
        catch {
            // Task views stay usable without money tags; Finance reports the ledger problem itself.
            linkLog.error("Linked entries unavailable: \(error.localizedDescription, privacy: .public)")
            index = TaskMoneyIndex()
        }
    }
}

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
