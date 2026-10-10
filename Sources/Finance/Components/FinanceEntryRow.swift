import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

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
    /// The task this entry belongs to, shown after its details; tapping it opens the task.
    var task: TaskLink? = nil
    var openTask: (() -> Void)? = nil
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State var hovering = false
    var body: some View {
        HStack(spacing: 0) {
            if restore == nil {
                // A tap gesture rather than a button, so the task name inside stays its own button.
                entryContent
                    .onTapGesture(perform: open)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, open)
                    .accessibilityActions {
                        if let openTask, task?.deleted == false { Button(L("打开关联任务", "Open linked task"), action: openTask) }
                    }
            } else { entryContent }
            if let restore {
                Button(L("恢复", "Restore"), action: restore).controlSize(.small)
                    .frame(minHeight: 44)
            } else {
                Menu { actions() } label: {
                    Label(L("账单操作", "Entry actions"), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(L("账单操作：", "Entry actions: ") + entry.title)
            }
        }
        .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
        .contextMenu(menuItems: actions)
        .accessibilityElement(children: .contain)
    }
    private var entryContent: some View {
        let icon = data.icon(entry)
        return HStack(spacing: 12) {
            MoneyIcon(symbol: icon.symbol, emoji: icon.emoji, tint: icon.tint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    // The note joins the details, fainter, so a row stays two lines.
                    (Text(detail) + Text(note.map { " · " + $0 } ?? "").foregroundStyle(.tertiary))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    taskChip
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amount).font(.rowAmount).lineLimit(1).minimumScaleFactor(0.8).foregroundStyle((accountID.map { entry.accountChange(for: $0) > 0 } ?? (entry.kind == .income || entry.kind == .refund)) ? Color.green : .primary)
                if let secondary { Text(secondary).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                if let balanceAfter, let account = data.account(accountID) {
                    Text(L("余额 ", "Balance ") + (hidden ? "••••" : Money.format(balanceAfter, account.currency)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(L("这笔之后的账户账面余额，包含未显示的其他流水。相同时间按列表顺序计算。", "Account balance after this entry, including other hidden entries. Equal timestamps follow list order."))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
    /// The linked task: a button while it exists, grey while it is in Recently deleted.
    @ViewBuilder private var taskChip: some View {
        if let task {
            let label = Label(task.title + (task.deleted ? L("（已删除）", " (deleted)") : ""), systemImage: task.deleted ? "trash" : "checklist")
            if let openTask, !task.deleted {
                Button(action: openTask) { label.tagStyle(.accentColor, weight: .medium) }
                .buttonStyle(.borderless).layoutPriority(1)
                .help(L("打开任务", "Open task"))
                .accessibilityLabel(L("关联任务：", "Linked task: ") + task.title)
            } else {
                label.tagStyle(.secondary, weight: .medium)
                    .layoutPriority(1)
                    .help(L("任务在最近删除中", "The task is in Recently deleted"))
            }
        }
    }
    /// The first line of the entry's notes, so they are visible without opening it.
    var note: String? { MoneyNote.firstLine(entry.notes) }
    var detail: String {
        var parts = [Dates.label(entry.date, pattern: "HH:mm")]
        if entry.isPending { parts.append(L("待入账", "Pending")) }
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

/// Notes are shown as their first line under an entry or bill name, so a long note never grows a row.
enum MoneyNote {
    static func firstLine(_ notes: String) -> String? {
        let line = notes.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }
}
