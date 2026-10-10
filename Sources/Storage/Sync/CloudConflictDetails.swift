import Foundation

extension CloudMerge {
    struct ConflictItem: Identifiable, Equatable {
        let id: String
        let detail: String
    }

    /// One merge owns this collector. Stable record/group keys never depend on text or language.
    final class ConflictReview {
        let choices: [String: Choice]
        let automatic: AutomaticSyncPolicy?
        private var automaticKeys = Set<String>()
        private(set) var confirmations: [String: Set<String>] = [:]
        func confirm(keys: [String], field: String?) {
            for key in keys { confirmations[key, default: []].insert(field ?? "*") }
        }
        var automaticCount: Int { automaticKeys.count }
        func recordAutomatic(key: String) { automaticKeys.insert(key) }
        private(set) var items: [ConflictItem] = []
        private var seen = Set<String>()
        private let localSnapshot: TaskBackup
        private let cloudSnapshot: TaskBackup
        private let baseSnapshot: TaskBackup?
        private lazy var local = ConflictDetails(localSnapshot)
        private lazy var cloud = ConflictDetails(cloudSnapshot)
        private lazy var base = baseSnapshot.map(ConflictDetails.init)

        init(choices: [String: Choice], local: TaskBackup, cloud: TaskBackup, base: TaskBackup? = nil, automatic: AutomaticSyncPolicy? = nil) {
            self.choices = choices; self.automatic = automatic
            localSnapshot = local; cloudSnapshot = cloud; baseSnapshot = base
        }
        func record(key: String, detail: String) {
            guard seen.insert(key).inserted else { return }
            let comparison = local.comparison(with: cloud, base: base, key: key)
            items.append(ConflictItem(id: key, detail: comparison.isEmpty ? detail :
                String(detail.prefix { $0 != "\n" }) + "\n\n" + comparison))
        }
    }
}

/// Index each snapshot once; format fields only when a conflict needs review, outside the main actor.
private struct ConflictDetails {
    private let tasks: [UUID: TaskBackup.TaskRecord]
    private let lists: [UUID: TaskBackup.ListRecord]
    private let accounts: [UUID: MoneyAccount]
    private let books: [UUID: MoneyBook]
    private let categories: [UUID: MoneyCategory]
    private let entries: [UUID: MoneyEntry]
    private let recurring: [UUID: MoneyRecurring]
    private let rates: [String: [MoneyRate]]
    private let baseCurrency: String?
    private let accountEntries: [UUID: Set<UUID>]
    private let refundLinks: [UUID: Set<UUID>]
    private let categoryChildren: [UUID: Set<UUID>]
    init(_ snapshot: TaskBackup) {
        tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        lists = Dictionary(uniqueKeysWithValues: snapshot.lists.map { ($0.id, $0) })
        accounts = Dictionary(uniqueKeysWithValues: (snapshot.finance?.accounts ?? []).map { ($0.id, $0) })
        books = Dictionary(uniqueKeysWithValues: (snapshot.finance?.books ?? []).map { ($0.id, $0) })
        categories = Dictionary(uniqueKeysWithValues: (snapshot.finance?.categories ?? []).map { ($0.id, $0) })
        entries = Dictionary(uniqueKeysWithValues: (snapshot.finance?.entries ?? []).map { ($0.id, $0) })
        recurring = Dictionary(uniqueKeysWithValues: (snapshot.finance?.recurringBills ?? []).map { ($0.id, $0) })
        rates = Dictionary(grouping: snapshot.finance?.rates ?? [], by: { [$0.base, $0.quote].sorted().joined(separator: "/") })
        baseCurrency = snapshot.finance?.baseCurrency
        var accountEntries: [UUID: Set<UUID>] = [:], refundLinks: [UUID: Set<UUID>] = [:]
        for entry in entries.values {
            for id in [entry.accountID, entry.destinationID].compactMap({ $0 }) { accountEntries[id, default: []].insert(entry.id) }
            if let original = entry.refundOf {
                refundLinks[entry.id, default: []].insert(original); refundLinks[original, default: []].insert(entry.id)
            }
        }
        self.accountEntries = accountEntries; self.refundLinks = refundLinks
        var children: [UUID: Set<UUID>] = [:]
        for category in categories.values {
            if let parent = category.parentID { children[parent, default: []].insert(category.id) }
        }
        categoryChildren = children
    }
    private func name<T>(_ id: UUID?, in rows: [UUID: T], label: (T) -> String) -> String {
        id.flatMap { rows[$0] }.map(label) ?? L("无", "None")
    }
    private func date(_ value: Date?) -> String {
        value?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UISettings.locale)) ?? L("无", "None")
    }
    private func yes(_ value: Bool) -> String { value ? L("是", "Yes") : L("否", "No") }
    private func decimal(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? L("未填写", "Not set") }
    private typealias Fields = [(String, String)]
    private func task(_ row: TaskBackup.TaskRecord) -> Fields {
        [ (L("标题", "Title"), row.title), (L("备注", "Notes"), row.notes),
          (L("安排", "Schedule"), date(row.scheduledAt)), (L("含时间", "Timed"), yes(row.hasTime)),
          (L("结束", "End"), date(row.endAt)), (L("截止", "Deadline"), date(row.dueAt)),
          (L("截止含时间", "Timed deadline"), yes(row.dueHasTime)),
          (L("已完成", "Completed"), yes(row.isDone)), (L("完成时间", "Completion time"), date(row.completedAt)),
          (L("优先级", "Priority"), String(row.priority)), (L("清单", "List"), name(row.listID, in: lists, label: { $0.name })),
          (L("子任务", "Subtasks"), row.subtasks.map { ($0.isDone ? "☑ " : "☐ ") + $0.title }.joined(separator: "\n")),
          (L("提醒时间", "Reminder time"), date(row.reminderAt)), (L("提醒方式", "Reminder"), ReminderPreset(rawValue: row.reminderKind)?.title ?? L("自定义", "Custom")),
          (L("提醒待调整", "Reminder needs attention"), yes(row.reminderNeedsAttention)),
          (L("重复", "Repeat"), Dates.repeatLabel(row.repeatRule)), (L("重复截至", "Repeat until"), date(row.repeatUntil)),
          (L("重复基准日", "Repeat day"), String(row.repeatAnchorDay)),
          (L("后续任务", "Next occurrence"), name(row.nextOccurrenceID, in: tasks, label: { $0.title })), (L("删除时间", "Deleted at"), date(row.deletedAt)) ]
    }
    private func entry(_ row: MoneyEntry) -> Fields {
        [ (L("标题", "Title"), row.title), (L("备注", "Notes"), row.notes), (L("标签", "Tags"), row.tags),
          (L("类型", "Type"), row.kind.label), (L("日期", "Date"), date(row.date)),
          (L("金额", "Amount"), row.currency + " " + decimal(row.amount)),
          (L("账户", "Account"), name(row.accountID, in: accounts, label: { $0.name })), (L("账户金额", "Account amount"), decimal(row.accountAmount)),
          (L("转入账户", "Destination"), name(row.destinationID, in: accounts, label: { $0.name })), (L("转入金额", "Destination amount"), decimal(row.destinationAmount)),
          (L("手续费", "Fee"), decimal(row.fee)), (L("折算金额", "Converted amount"), decimal(row.baseAmount)),
          (L("折算手续费", "Converted fee"), decimal(row.baseFee)), (L("汇率备注", "Rate note"), row.rateNote),
          (L("账本", "Book"), name(row.bookID, in: books, label: { $0.name })), (L("分类", "Category"), name(row.categoryID, in: categories, label: { $0.label })),
          (L("待入账", "Pending"), yes(row.isPending)), (L("关联任务", "Linked task"), name(row.taskID, in: tasks, label: { $0.title })),
          (L("退款原账单", "Refunded entry"), name(row.refundOf, in: entries, label: { $0.title })),
          (L("删除时间", "Deleted at"), date(row.deletedAt)) ]
    }
    private func recurringBill(_ row: MoneyRecurring) -> Fields {
        [ (L("名称", "Name"), row.title), (L("类型", "Type"), row.kind.label),
          (L("金额", "Amount"), row.currency + " " + decimal(row.amount)),
          (L("账户", "Account"), name(row.accountID, in: accounts, label: { $0.name })), (L("账户计划金额", "Planned account amount"), decimal(row.accountAmount)),
          (L("账本", "Book"), name(row.bookID, in: books, label: { $0.name })), (L("分类", "Category"), name(row.categoryID, in: categories, label: { $0.label })),
          (L("重复", "Repeat"), row.scheduleLabel), (L("下一期", "Next"), date(row.nextDate)), (L("重复截至", "Repeat until"), date(row.until)),
          (L("备注", "Notes"), row.notes), (L("标签", "Tags"), row.tags) ]
    }
    private func account(_ row: MoneyAccount) -> Fields {
        [(L("名称", "Name"), row.name), (L("币种", "Currency"), row.currency), (L("期初余额", "Opening balance"), decimal(row.opening)),
         (L("银行", "Bank"), row.bankName ?? ""), (L("类型", "Type"), row.resolvedType.label),
         (L("归档", "Archived"), yes(row.archived)), (L("表情", "Emoji"), row.emoji ?? ""), (L("图标", "Icon"), row.iconSymbol)]
    }
    private func book(_ row: MoneyBook) -> Fields {
        [(L("名称", "Name"), row.name), (L("每月预算", "Monthly budget"), decimal(row.budget)),
         (L("默认账户", "Default account"), name(row.defaultAccountID, in: accounts, label: { $0.name })), (L("归档", "Archived"), yes(row.archived)),
         (L("表情", "Emoji"), row.emoji ?? ""), (L("图标", "Icon"), row.iconSymbol)]
    }
    private func category(_ row: MoneyCategory) -> Fields {
        [(L("名称", "Name"), row.label), (L("类型", "Type"), row.isIncome ? L("收入", "Income") : L("支出", "Expense")),
         (L("上级分类", "Parent category"), name(row.parentID, in: categories, label: { $0.label })), (L("归档", "Archived"), yes(row.archived)),
         (L("表情", "Emoji"), row.emoji ?? ""), (L("图标", "Icon"), row.symbol), (L("颜色", "Color"), row.resolvedColor)]
    }
    private func list(_ row: TaskBackup.ListRecord) -> Fields {
        [(L("名称", "Name"), row.name), (L("上级清单", "Parent list"), name(row.parentID, in: lists, label: { $0.name })),
         (L("颜色", "Color"), row.colorHex ?? ""), (L("表情", "Emoji"), row.emoji ?? ""),
         (L("顺序", "Order"), String(row.sortOrder ?? 0))]
    }
    private func compare<T: Equatable>(_ l: [UUID: T], _ r: [UUID: T], ids: Set<UUID>?,
        describeLeft: (T) -> Fields, describeRight: (T) -> Fields) -> String {
        return (ids ?? Set(l.keys).union(r.keys)).sorted { $0.uuidString < $1.uuidString }.compactMap { id -> String? in
            guard l[id] != r[id] else { return nil }
            let a = l[id].map(describeLeft), b = r[id].map(describeRight)
            let title = a?.first?.1 ?? b?.first?.1 ?? ""
            let localValues = Dictionary(uniqueKeysWithValues: a ?? [])
            let cloudValues = Dictionary(uniqueKeysWithValues: b ?? [])
            let fields = (a ?? b ?? []).map(\.0).filter { localValues[$0] != cloudValues[$0] }
            let deleted = L("不存在 / 已删除", "Absent / deleted")
            let empty = L("空", "Empty")
            let details = fields.map { field in
                let left = localValues[field].map { $0.isEmpty ? empty : $0 } ?? deleted
                let right = cloudValues[field].map { $0.isEmpty ? empty : $0 } ?? deleted
                return field + "\n" + L("本机：", "Local: ") + left + "\n" + L("云端：", "Cloud: ") + right
            }
            return ([title] + details).joined(separator: "\n\n")
        }.joined(separator: "\n\n——\n\n")
    }
    private func rateComparison(with other: Self, pair: String) -> String {
        func describe(_ values: [MoneyRate]) -> String {
            guard !values.isEmpty else { return L("不存在 / 已删除", "Absent / deleted") }
            return values.sorted { $0.base < $1.base }.map {
                "1 " + $0.base + " = " + decimal($0.rate) + " " + $0.quote + " · " +
                ($0.isManual ? L("手动", "Manual") : $0.source) + " · " + $0.date
            }.joined(separator: "\n")
        }
        return L("本机：", "Local: ") + describe(rates[pair] ?? []) + "\n" +
            L("云端：", "Cloud: ") + describe(other.rates[pair] ?? [])
    }
    private func relatedEntries(accounts ids: Set<UUID>, other: Self, base: Self?) -> Set<UUID> {
        let snapshots = [self, other] + (base.map { [$0] } ?? [])
        var pending = ids.flatMap { id in snapshots.flatMap { Array($0.accountEntries[id] ?? []) } }
        var result = Set<UUID>()
        while let id = pending.popLast() {
            guard result.insert(id).inserted else { continue }
            for snapshot in snapshots { pending.append(contentsOf: snapshot.refundLinks[id] ?? []) }
        }
        return result
    }
    func comparison(with other: Self, base: Self?, key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? ""
        let ids = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        switch kind {
        case "task", "task-chain", "task-lifecycle":
            return compare(tasks, other.tasks, ids: ids, describeLeft: task, describeRight: other.task)
        case "list":
            return compare(lists, other.lists, ids: ids, describeLeft: list, describeRight: other.list)
        case "entry": return compare(entries, other.entries, ids: ids, describeLeft: entry, describeRight: other.entry)
        case "account": return compare(accounts, other.accounts, ids: ids, describeLeft: account, describeRight: other.account)
        case "book": return compare(books, other.books, ids: ids, describeLeft: book, describeRight: other.book)
        case "recurring": return compare(recurring, other.recurring, ids: ids, describeLeft: recurringBill, describeRight: other.recurringBill)
        case "category", "category-family":
            let family = kind == "category-family" ? ids.union(ids.flatMap { Array(categoryChildren[$0] ?? []) })
                .union(ids.flatMap { Array(other.categoryChildren[$0] ?? []) }) : ids
            return compare(categories, other.categories, ids: family, describeLeft: category, describeRight: other.category)
        case "account-postings":
            let related = relatedEntries(accounts: ids, other: other, base: base)
            return [compare(accounts, other.accounts, ids: ids, describeLeft: account, describeRight: other.account),
                    compare(entries, other.entries, ids: related, describeLeft: entry, describeRight: other.entry)]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        case "rate": return rateComparison(with: other, pair: parts.count > 1 ? parts[1] : "")
        case "ledger", "ledger-currency":
            let currency = baseCurrency == other.baseCurrency ? "" : L("记账本位币", "Base currency") + "\n" +
                L("本机：", "Local: ") + (baseCurrency ?? L("无", "None")) + "\n" + L("云端：", "Cloud: ") + (other.baseCurrency ?? L("无", "None"))
            let changedRates = Set(rates.keys).union(other.rates.keys).sorted().filter { rates[$0] != other.rates[$0] }
            return [currency,
                    compare(accounts, other.accounts, ids: nil, describeLeft: account, describeRight: other.account),
                    compare(entries, other.entries, ids: nil, describeLeft: entry, describeRight: other.entry),
                    compare(books, other.books, ids: nil, describeLeft: book, describeRight: other.book),
                    compare(recurring, other.recurring, ids: nil, describeLeft: recurringBill, describeRight: other.recurringBill),
                    compare(categories, other.categories, ids: nil, describeLeft: category, describeRight: other.category),
                    changedRates.map { $0 + "\n" + rateComparison(with: other, pair: $0) }.joined(separator: "\n\n")]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        default: return ""
        }
    }
}
