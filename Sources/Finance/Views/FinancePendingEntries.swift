import SwiftUI

/// One posting choice shared by new-task drafts and entries created from a saved task.
struct MoneyPostingChoice: View {
    @Binding var entry: MoneyEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L("待入账", "Pending"), isOn: Binding(
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
        return data.entries.filter { entry in
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
    let confirm: (MoneyEntry) -> Void
    let remove: (MoneyEntry) -> Void
    @State private var showUpcoming = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !entries.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                let due = entries.filter { $0.isDueForConfirmation(at: clock.date) }
                let upcoming = entries.filter { !$0.isDueForConfirmation(at: clock.date) }
                LazyVStack(alignment: .leading, spacing: 8) {
                    Label(L("待入账 · \(entries.count)", "Pending · \(entries.count)"), systemImage: "clock")
                        .font(.headline).padding(.top, 12)
                    Text(L("确认后计入余额与统计；这里显示全部计划日期。", "Included in balances and totals only after confirmation. Plans from all dates appear here."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(due) { entry in row(entry, ready: true) }
                    if !upcoming.isEmpty {
                        DisclosureGroup(L("之后的计划 · \(upcoming.count)", "Upcoming · \(upcoming.count)"), isExpanded: $showUpcoming) {
                            LazyVStack(spacing: 8) {
                                ForEach(upcoming) { entry in row(entry, ready: false) }
                            }
                        }.padding(.vertical, 8)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
    }

    private func row(_ entry: MoneyEntry, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { open(entry) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(Dates.label(entry.date, pattern: "M月d日") + " · " + (data.book(entry.bookID)?.name ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    Button(L("编辑计划", "Edit plan")) { open(entry) }
                    Button(L("删除", "Delete"), role: .destructive) { remove(entry) }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel(L("待入账操作：", "Pending entry actions: ") + entry.title)
            }
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))) {
                Text(entry.kind.label + " " + Money.display(entry.amount, entry.currency, hidden: hidden))
                    .font(.callout.weight(.medium)).monospacedDigit()
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if ready {
                    Button(L("确认入账", "Confirm entry")) { confirm(entry) }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityIdentifier("finance.confirmPending")
                } else {
                    Text(L("到日期后可确认", "Confirm when due")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
