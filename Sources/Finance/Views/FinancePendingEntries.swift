import SwiftUI

/// One posting choice shared by new-task drafts and entries created from a saved task.
struct MoneyPostingChoice: View {
    @Binding var entry: MoneyEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L("先记为待入账", "Save as pending"), isOn: Binding(
                get: { entry.isPending }, set: { entry.pending = $0 ? true : nil }))
                .accessibilityIdentifier("finance.pendingToggle")
            Text(entry.isPending
                 ? L("先保存计划；到日期后确认，才计入余额和统计。", "Save the plan now; confirm on or after its date to include it in balances and totals.")
                 : L("保存时计入余额和统计。", "Included in balances and totals when saved."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension FinanceHome {
    /// Plans remain visible after their due day, even when the posted-entry date range changes.
    var pendingEntries: [MoneyEntry] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stored pending entries and each recurring bill's next occurrence, computed from its rule.
        return (data.entries + data.recurringPreviews).filter { entry in
            guard entry.isPending && entry.deletedAt == nil,
                  entry.matches(bookID: accountDetailID == nil ? bookFilterID : nil, accountID: accountDetailID ?? accountFilter) else { return false }
            if let categoryFilter, !data.categoryMatches(entry.categoryID, filterID: categoryFilter) { return false }
            if let kindFilter, entry.kind != kindFilter { return false }
            return text.isEmpty || data.searchText(for: entry).localizedCaseInsensitiveContains(text)
        }.sorted { MoneyEntry.newestFirst($1, $0) }
    }
}

/// Local disclosure and clock updates do not rebuild the full ledger or charts.
struct PendingEntriesSection: View {
    let entries: [MoneyEntry]
    let data: FinanceData
    let hidden: Bool
    let open: (MoneyEntry) -> Void
    /// Posts the entry as it is.
    let confirm: (MoneyEntry) -> Void
    /// Opens the full editor to change amounts or the date before posting.
    let confirmWithChanges: (MoneyEntry) -> Void
    let remove: (MoneyEntry) -> Void
    let editBill: (MoneyRecurring) -> Void
    let stopBill: (MoneyRecurring) -> Void
    let restartBill: (MoneyEntry) -> Void
    /// Records a recurring occurrence dated today instead of its scheduled day.
    let postToday: (MoneyEntry) -> Void
    let skip: (MoneyEntry) -> Void
    @State private var showUpcoming = false
    @State private var confirming: MoneyEntry?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !entries.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                let due = entries.filter { $0.isDueForConfirmation(at: clock.date) }
                let upcoming = entries.filter { !$0.isDueForConfirmation(at: clock.date) }
                LazyVStack(alignment: .leading, spacing: 8) {
                    // The count is what needs attention now; later plans are counted on their own row.
                    Label(due.isEmpty ? L("待入账", "Pending") : L("待入账 · \(due.count)", "Pending · \(due.count)"), systemImage: "clock")
                        .font(.headline).padding(.top, 12)
                    Text(due.isEmpty ? L("现在没有到期的账单；确认后才计入余额与统计。", "Nothing is due now. Entries count in balances and totals only after confirmation.")
                                     : L("确认后计入余额与统计。", "Included in balances and totals only after confirmation."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(due) { entry in row(entry, ready: true) }
                    if !upcoming.isEmpty {
                        upcomingToggle(count: upcoming.count)
                        if showUpcoming {
                            LazyVStack(spacing: 8) {
                                ForEach(upcoming) { entry in row(entry, ready: false) }
                            }
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            .confirmationDialog(confirming.map { L("确认入账“\($0.title)”？", "Confirm “\($0.title)”?") } ?? "",
                                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { entry in
                Button(L("确认入账", "Confirm entry")) { confirm(entry); confirming = nil }
                Button(L("修改后确认…", "Change, then confirm…")) { confirmWithChanges(entry); confirming = nil }
                Button(L("取消", "Cancel"), role: .cancel) { confirming = nil }
            } message: { entry in
                Text(confirmationMessage(entry))
            }
        }
    }

    /// The whole row toggles, not only the disclosure arrow, so it is easy to hit with a pointer.
    private func upcomingToggle(count: Int) -> some View {
        Button { showUpcoming.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: showUpcoming ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 14)
                Text(L("之后的计划", "Upcoming"))
                Spacer()
                Text(L("\(count) 笔", "\(count)")).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).padding(.top, 4)
        .accessibilityLabel(L("之后的计划，\(count) 笔", "Upcoming, \(count)"))
        .accessibilityValue(showUpcoming ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
    }

    private func confirmationMessage(_ entry: MoneyEntry) -> String {
        var parts: [String] = [entry.kind.label + " " + Money.display(entry.amount, entry.currency, hidden: hidden)]
        parts.append(Dates.label(entry.date, pattern: "M月d日"))
        if let account = data.account(entry.accountID) { parts.append(account.name) }
        return parts.joined(separator: " · ") + "\n" + L("确认后计入余额和统计。", "It will count in balances and totals.")
    }

    /// Entries in the base currency, or already converted, can post straight away. A missing conversion
    /// would leave the posting out of combined totals, so those open the editor to enter a rate or the bank amount.
    private func startConfirmation(_ entry: MoneyEntry) {
        if entry.currency != data.baseCurrency && entry.baseAmount == nil { confirmWithChanges(entry) } else { confirming = entry }
    }

    /// A recurring bill's occurrence shown from its rule; it is not stored until confirmed.
    private func isPreview(_ entry: MoneyEntry) -> Bool {
        data.recurringBill(entry.recurringID).map { $0.entryID(for: $0.nextDate) == entry.id } == true
            && !data.entries.contains { $0.id == entry.id && $0.deletedAt == nil }
    }
    @ViewBuilder private func status(_ entry: MoneyEntry, ready: Bool) -> some View {
        let today = Dates.calendar.startOfDay(for: Date()), day = Dates.calendar.startOfDay(for: entry.date)
        let (text, tint): (String, Color) = !ready ? (L("即将", "Upcoming"), .secondary)
            : day < today ? (L("已错过", "Missed"), .red) : (L("今天到期", "Due today"), .orange)
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    private func row(_ entry: MoneyEntry, ready: Bool) -> some View {
        let preview = isPreview(entry)
        // A bill whose book, account or category was archived is fixed in the bill, not confirmed as it stands.
        let blockedBill = preview ? data.recurringBill(entry.recurringID).flatMap { bill in data.recurringIssue(bill).map { (bill, $0) } } : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { preview ? confirmWithChanges(entry) : open(entry) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(entry.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(2)
                            if let bill = data.recurringBill(entry.recurringID) { RecurringBadge(bill: bill) }
                            if preview { status(entry, ready: ready) }
                        }
                        Text(Dates.label(entry.date, pattern: "M月d日") + " · " + (data.book(entry.bookID)?.name ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let note = MoneyNote.firstLine(entry.notes) {
                            Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if let (_, issue) = blockedBill {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    if preview {
                        Button(L("今天入账", "Record today")) { postToday(entry) }.disabled(blockedBill != nil)
                        Button(L("跳过这一期", "Skip this one")) { skip(entry) }
                        Divider()
                    } else {
                        Button(L("编辑这一笔", "Edit this entry")) { open(entry) }
                    }
                    if let bill = data.recurringBill(entry.recurringID) {
                        Button(L("修改周期账单…", "Edit recurring bill…")) { editBill(bill) }
                        Button(L("停止重复…", "Stop repeating…")) { stopBill(bill) }
                    } else if entry.kind == .expense || entry.kind == .income {
                        Button(L("设为周期账单…", "Make recurring…")) { restartBill(entry) }
                    }
                    if !preview {
                        Divider()
                        Button(L("删除这一笔", "Delete this entry"), role: .destructive) { remove(entry) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(L("待入账操作：", "Pending entry actions: ") + entry.title)
            }
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))) {
                Text(entry.kind.label + " " + Money.display(entry.amount, entry.currency, hidden: hidden))
                    .font(.callout.weight(.medium)).monospacedDigit()
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if let (bill, _) = blockedBill {
                    Button(L("修改周期账单…", "Edit recurring bill…")) { editBill(bill) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                } else if ready {
                    Button(L("确认入账", "Confirm entry")) { startConfirmation(entry) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("finance.confirmPending")
                } else {
                    Text(L("到日期后可确认", "Confirm when due")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
