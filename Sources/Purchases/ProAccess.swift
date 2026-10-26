import Foundation

/// Value-only purchase facts. Never encoded into the user's task/finance data or cloud snapshots.
struct ProGrant: Equatable, Sendable {
    let product: ProProduct
    let expires: Date?
    var revoked = false
    var active: Bool { active(at: Date()) }
    func active(at date: Date) -> Bool {
        !revoked && (product == .lifetime || expires.map { $0 > date } == true)
    }
}

enum ProQuota: CaseIterable, Sendable {
    case lists, accounts, books, recurringBills, budgets
    var limit: Int {
        switch self { case .lists, .accounts: 5; case .books: 2; case .recurringBills: 3; case .budgets: 1 }
    }
    var label: String {
        switch self {
        case .lists: L("清单", "lists")
        case .accounts: L("未归档账户", "active accounts")
        case .books: L("未归档账本", "active books")
        case .recurringBills: L("未结束周期账单", "ongoing recurring bills")
        case .budgets: L("设有预算的账本", "books with a budget")
        }
    }
}

struct ProLimitError: LocalizedError {
    let quota: ProQuota
    /// For budgets: the books already using the free slot, so an archived one is not a hidden reason.
    var holders: String? = nil
    var errorDescription: String? {
        if quota == .budgets {
            let using = holders.map { L("目前已由\($0)使用。", "Currently used by \($0). ") } ?? ""
            return L("免费版可为 1 个账本设置预算。", "The free plan includes a budget for one book. ") + using
                + L("清除那个账本的预算即可改用到其他账本，已归档的账本也计算在内；升级 Pro 可为更多账本添加预算。输入已保留。",
                    "Clear that book's budget to use it elsewhere; archived books count too. Upgrade to Pro to add budgets to more books. Your input is kept.")
        }
        return L("免费版可新建至 \(quota.limit) 个\(quota.label)。现有项目仍可正常使用；升级 Pro 可继续新建。输入已保留。",
          "The free plan allows \(quota.limit) \(quota.label). Existing items still work. Upgrade to Pro to create more. Your input is kept.")
    }
}

/// Over-limit creation before this launch has verified the App Store rights: never an upgrade prompt.
struct ProStatusUnconfirmedError: LocalizedError {
    let failed: Bool
    var errorDescription: String? {
        failed ? L("暂时无法确认购买状态，未新建超出免费额度的项目。请检查网络后重试；输入已保留。",
                   "Purchase status could not be confirmed, so nothing beyond the free limit was created. Check your connection and retry. Your input is kept.")
            : L("正在确认购买状态，请稍后再保存。输入已保留。", "Confirming purchase status. Save again in a moment. Your input is kept.")
    }
}

enum ProAccess {
    enum CreationDecision: Equatable { case allowed, limit, unconfirmed }
    /// Existing budgets remain editable after expiry, including those on archived books.
    static func budgetCreationCount(for bookID: UUID?, budgetedBookIDs: Set<UUID>) -> Int? {
        if let bookID, budgetedBookIDs.contains(bookID) { return nil }
        return budgetedBookIDs.count
    }
    static func permitsCreation(_ quota: ProQuota, count: Int, isPro: Bool) -> Bool {
        isPro || count < quota.limit
    }
    /// Within the free limit nothing waits. Beyond it, only verified rights (Pro or free) decide.
    static func creationDecision(_ quota: ProQuota, count: Int, isPro: Bool, confirmed: Bool) -> CreationDecision {
        if permitsCreation(quota, count: count, isPro: isPro) { return .allowed }
        return confirmed ? .limit : .unconfirmed
    }
    /// Only user-initiated creation calls this. Import, sync, undo and recovery must never call it.
    static func requireCreation(_ quota: ProQuota, count: Int, isPro: Bool) throws {
        if !permitsCreation(quota, count: count, isPro: isPro) { throw ProLimitError(quota: quota) }
    }
    static func hasPro(_ grants: [ProGrant], at date: Date) -> Bool { grants.contains { $0.active(at: date) } }
    /// Free statistics cover this month and the one before; older and future months are Pro.
    static func freeStatisticsMonths(now: Date, calendar: Calendar) -> (previous: DateInterval, current: DateInterval) {
        let current = calendar.dateInterval(of: .month, for: now)!
        // The day before this month's first instant is always inside the previous month, whatever its length or DST.
        let previous = calendar.dateInterval(of: .month, for: current.start.addingTimeInterval(-1))!
        return (previous, current)
    }
    /// The month a free plan shows for the shared selected date: that month when allowed, otherwise this month.
    static func freeStatisticsMonth(for selected: Date, now: Date, calendar: Calendar) -> DateInterval {
        let months = freeStatisticsMonths(now: now, calendar: calendar)
        return months.previous.contains(selected) && selected < months.previous.end ? months.previous : months.current
    }
}
