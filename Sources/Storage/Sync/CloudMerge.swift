import Foundation
import SwiftData
import CryptoKit
import OSLog

private let syncLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "CloudSync")

enum CloudMerge {
    static func digest(_ data: Data) -> String {
        let hexadecimal = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(hexadecimal[Int(byte >> 4)]); bytes.append(hexadecimal[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    enum Choice: String { case local, cloud }
    struct Conflict: LocalizedError {
        let label: String
        var items: [ConflictItem] = []
        var warning: String? = nil
        var errorDescription: String? {
            L("以下内容在两端都有变化，请核对后选择：\n\n", "These items changed on both devices. Review before choosing:\n\n") + label
        }
        static func reportSections(_ detail: String) -> [String] {
            detail.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        }
    }
    static func value<T: Equatable>(_ local: T, _ cloud: T, _ base: T, label: @autoclosure () -> String,
                                    choice: Choice?, decision: @autoclosure () -> SyncChanges.Decision? = nil,
                                    report: ((String) -> Void)? = nil, review: ConflictReview? = nil, key: String = "",
                                    field: String? = nil, causalKeys: [String]? = nil) throws -> T {
        if local == cloud { return local }
        let keys = causalKeys ?? [key]
        let causality = review?.automatic?.revisions
        // A previously confirmed value has already observed the other side, even without a shared baseline.
        if let selected = causality?.causalChoice(keys: keys, field: field) {
            return selected == .local ? local : cloud
        }
        // A first-sync deletion requires review even when both records carry timestamps.
        let decisionResult = decision()
        if decisionResult?.needsReview != true {
            if cloud == base && (causality?.unchanged(.cloud, keys: keys, field: field) ?? true) { return local }
            if local == base && (causality?.unchanged(.local, keys: keys, field: field) ?? true) { return cloud }
        }
        // A record-level review choice applies only to differences that still need review.
        if decisionResult?.needsReview != true, let field,
           let selected = review?.automatic?.choice(record: key, field: field) {
            review?.recordAutomatic(key: key + ":" + field)
            return selected == .local ? local : cloud
        }
        if let review { review.record(key: key, detail: label()) }
        let manual = review?.choices[key] ?? choice
        switch manual {
        case .local:
            review?.confirm(keys: keys, field: field); return local
        case .cloud:
            review?.confirm(keys: keys, field: field); return cloud
        case nil:
            let detail = label()
            if let report { report(detail); return local } // Collect all conflicts; merge never returns this provisional result.
            throw Conflict(label: label())
        }
    }
    static func rows<T: Equatable>(_ local: [T], _ cloud: [T], _ base: [T], id: (T) -> UUID, label: String,
                                   describe: (T) -> String, choice: Choice?, kind: String = "",
                                   decision: (([String]) -> SyncChanges.Decision)? = nil, mergeFields: ((T, T, T) throws -> T)? = nil, report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> [T] {
        let l = Dictionary(uniqueKeysWithValues: local.map { (id($0), $0) })
        let r = Dictionary(uniqueKeysWithValues: cloud.map { (id($0), $0) })
        let b = Dictionary(uniqueKeysWithValues: base.map { (id($0), $0) })
        return try Set(l.keys).union(r.keys).union(b.keys).sorted { $0.uuidString < $1.uuidString }.compactMap {
            if let left = l[$0], let right = r[$0], let original = b[$0],
               left != right, let mergeFields {
                return try mergeFields(left, right, original)
            }
            return try value(l[$0], r[$0], b[$0], label: label + "\n" +
                      L("本机：", "Local: ") + (l[$0].map(describe) ?? L("已删除", "Deleted")) + "\n" +
                      L("云端：", "Cloud: ") + (r[$0].map(describe) ?? L("已删除", "Deleted")), choice: choice,
                      decision: decision?([SyncChanges.key(kind, $0)]), report: report, review: review, key: SyncChanges.key(kind, $0))
        }
    }

    static func taskDescription(_ task: TaskBackup.TaskRecord?) -> String {
        guard let task else { return L("不存在 / 已彻底删除", "Absent / permanently deleted") }
        let date = task.scheduledAt ?? task.dueAt
        let status = task.deletedAt != nil ? L("最近删除", "Recently deleted") : (task.isDone ? L("已完成", "Completed") : L("未完成", "Open"))
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(UISettings.locale)
        let schedule = date.map { " · " + L("安排：", "Scheduled: ") + $0.formatted(format) } ?? ""
        let completed = task.isDone ? (task.completedAt.map { " · " + L("完成于：", "Completed at: ") + $0.formatted(format) } ?? "") : ""
        return "“" + task.title + "” · " + status + schedule + completed
    }
    static func taskDifference(_ local: TaskBackup.TaskRecord?, _ cloud: TaskBackup.TaskRecord?) -> String {
        var fields: [String] = []
        if let l = local, let r = cloud {
            if l.title != r.title { fields.append(L("标题", "title")) }
            if l.notes != r.notes { fields.append(L("备注", "notes")) }
            if l.scheduledAt != r.scheduledAt || l.hasTime != r.hasTime || l.endAt != r.endAt { fields.append(L("安排时间", "schedule")) }
            if l.dueAt != r.dueAt || l.dueHasTime != r.dueHasTime { fields.append(L("截止时间", "deadline")) }
            if l.isDone != r.isDone || l.completedAt != r.completedAt { fields.append(L("完成状态或完成时间", "completion status/time")) }
            if l.priority != r.priority { fields.append(L("优先级", "priority")) }
            if l.subtasks != r.subtasks { fields.append(L("子任务", "subtasks")) }
            if l.listID != r.listID { fields.append(L("所属清单", "list")) }
            if l.deletedAt != r.deletedAt { fields.append(L("删除状态", "deletion")) }
            if l.reminderAt != r.reminderAt || l.reminderKind != r.reminderKind || l.reminderNeedsAttention != r.reminderNeedsAttention { fields.append(L("提醒", "reminder")) }
            if l.repeatRule != r.repeatRule || l.repeatUntil != r.repeatUntil || l.repeatAnchorDay != r.repeatAnchorDay || l.repeatTimeZoneID != r.repeatTimeZoneID || l.nextOccurrenceID != r.nextOccurrenceID { fields.append(L("重复设置或后续任务", "recurrence/successor")) }
        }
        return L("本机：", "Local: ") + taskDescription(local) + "\n" + L("云端：", "Cloud: ") + taskDescription(cloud) +
            (fields.isEmpty ? "" : "\n" + L("差异：", "Differences: ") + fields.joined(separator: "、"))
    }

    /// Structural repeat edits stay atomic: unioning independently created successors forks the series.
    /// Include base links too, so deleting or unlinking a parent cannot orphan a competing branch.
    static func taskRows(_ local: [TaskBackup.TaskRecord], _ cloud: [TaskBackup.TaskRecord], _ base: [TaskBackup.TaskRecord],
                         choice: Choice?, decision: (([String]) -> SyncChanges.Decision)? = nil,
                         report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> [TaskBackup.TaskRecord] {
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let ids = Set(l.keys).union(r.keys).union(b.keys)
        var links: [UUID: Set<UUID>] = [:]
        for row in local + cloud + base {
            if let next = row.nextOccurrenceID, ids.contains(next) {
                links[row.id, default: []].insert(next); links[next, default: []].insert(row.id)
            }
        }
        var visited = Set<UUID>(), result: [TaskBackup.TaskRecord] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where !visited.contains(id) {
            var pending = [id], component: [UUID] = []
            while let next = pending.popLast() {
                guard visited.insert(next).inserted else { continue }
                component.append(next); pending.append(contentsOf: links[next] ?? [])
            }
            component.sort { $0.uuidString < $1.uuidString }
            let left = component.compactMap { l[$0] }, right = component.compactMap { r[$0] }, original = component.compactMap { b[$0] }
            // Only unchanged membership, links and deletion state permit merging individual occurrences.
            if left != right,
               taskStructureMatches(left, original), taskStructureMatches(right, original) {
                let standalone = component.count == 1 && (left + right + original).allSatisfy {
                    $0.repeatRule == "none" && $0.nextOccurrenceID == nil
                }
                let lifecycle: [TaskBackup.TaskRecord]
                if standalone {
                    lifecycle = [try ordinaryTaskLifecycle(left[0], right[0], original[0], choice: choice, report: report, review: review)]
                } else {
                    lifecycle = try value(zip(left, original).map { taskLifecycle($0, base: $1) },
                                          zip(right, original).map { taskLifecycle($0, base: $1) }, original,
                    label: L("任务时间、提醒与重复状态", "Task schedule, reminders and recurrence") + "\n" +
                        component.filter { l[$0] != r[$0] }.map { taskDifference(l[$0], r[$0]) }.joined(separator: "\n\n"),
                    choice: choice, report: report, review: review, key: "task-lifecycle:" + component.map(\.uuidString).joined(separator: ","), field: "lifecycle",
                    causalKeys: component.map { SyncChanges.key("task", $0) })
                }
                for index in original.indices {
                    result.append(try taskFields(left[index], right[index], original[index], lifecycle: lifecycle[index],
                                                 choice: choice, report: report, review: review))
                }
                continue
            }
            result += try value(left, right, original, label:
                (component.count > 1 ? L("重复任务（选择将用于整条序列，含后续任务）", "Repeating tasks (choice applies to the entire chain, including successors)") : L("任务", "Task")) + "\n" +
                component.filter { l[$0] != r[$0] }.map { taskDifference(l[$0], r[$0]) }.joined(separator: "\n\n"), choice: choice,
                decision: decision?(component.map { SyncChanges.key("task", $0) }), report: report, review: review, key: "task-chain:" + component.map(\.uuidString).joined(separator: ","),
                causalKeys: component.map { SyncChanges.key("task", $0) })
        }
        return result
    }

    /// Recognize only the exact, unused defaults made by this app. Used/customized lists remain user data.
    static func unusedDefaultIDs(_ snapshot: TaskBackup) -> Set<UUID> {
        let referenced = Set(snapshot.tasks.compactMap(\.listID)).union(snapshot.lists.compactMap(\.parentID))
        let names = [["工作", "Work"], ["生活", "Personal"], ["学习", "Study"]]
        return Set(snapshot.lists.compactMap { list -> UUID? in
            guard snapshot.syncChanges?[SyncChanges.key("list", list.id)] == nil,
                !referenced.contains(list.id), let index = names.indices.first(where: {
                list.id == TaskItem.syncIdentity("tally-default-list-\($0)")
            }), names[index].contains(list.name), list.createdAt == Date(timeIntervalSince1970: Double(index)),
                list.parentID == nil, list.emoji == nil, (list.sortOrder ?? 0) == 0,
                list.colorHex == nil || list.colorHex == ListColor.presets[index].hex else { return nil }
            return list.id
        })
    }
    static func isInitialFinance(_ finance: FinanceData?) -> Bool {
        guard var finance, finance.books.count == 1, ["日常", "Daily"].contains(finance.books[0].name) else { return false }
        let initial = FinanceData.initial
        finance.books[0].name = initial.books[0].name
        // Snapshot canonicalization sorts these arrays; display order is local-only.
        finance.categories.sort { $0.id.uuidString < $1.id.uuidString }
        var expected = initial; expected.categories.sort { $0.id.uuidString < $1.id.uuidString }
        return finance == expected
    }
    static func isUntouchedInitialFinance(_ snapshot: TaskBackup) -> Bool {
        // Returning to an empty ledger after deletion is still a user edit, not a fresh seed.
        !(snapshot.syncChanges ?? [:]).keys.contains(where: SyncChanges.isFinanceKey) && isInitialFinance(snapshot.finance)
    }

    /// Manual quotes are user data; group both directions so a reset or inverse edit cannot resurrect one.
    static func rateRows(_ local: [MoneyRate], _ cloud: [MoneyRate], _ base: [MoneyRate],
                         choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> [MoneyRate] {
        func grouped(_ rates: [MoneyRate]) -> [String: [MoneyRate]] {
            Dictionary(grouping: rates, by: { [$0.base, $0.quote].sorted().joined(separator: "/") })
                .mapValues { $0.sorted { $0.base < $1.base } }
        }
        let l = grouped(local), r = grouped(cloud), b = grouped(base)
        return try Set(l.keys).union(r.keys).union(b.keys).sorted().flatMap { pair -> [MoneyRate] in
            let left = l[pair] ?? [], right = r[pair] ?? [], original = b[pair] ?? []
            if left == right { return left }
            let keys = [SyncChanges.rateKey(pair)], causality = review?.automatic?.revisions
            if let selected = causality?.causalChoice(keys: keys) { return selected == .local ? left : right }
            let leftManual = left.contains(where: \.isManual), rightManual = right.contains(where: \.isManual)
            if leftManual || rightManual || original.contains(where: \.isManual) {
                if right == original && (causality?.unchanged(.cloud, keys: keys) ?? true) { return left }
                if left == original && (causality?.unchanged(.local, keys: keys) ?? true) { return right }
            }
            if leftManual || rightManual {
                if !original.contains(where: \.isManual), leftManual != rightManual { return leftManual ? left : right }
                return try value(left, right, original, label: L("手动汇率：", "Manual exchange rate: ") + pair,
                                 choice: choice, report: report, review: review, key: "rate:" + pair, causalKeys: [SyncChanges.rateKey(pair)])
            }
            // Provider rates are a cache. Transactions keep their posted rate unchanged.
            var newest = Dictionary(uniqueKeysWithValues: left.map { ($0.base, $0) })
            for rate in right where newest[rate.base].map({ $0.date < rate.date || $0.date == rate.date && $0.fetchedAt < rate.fetchedAt }) ?? true { newest[rate.base] = rate }
            return newest.values.sorted { $0.base < $1.base }
        }
    }

    static func categoryRows(_ local: [MoneyCategory], _ cloud: [MoneyCategory], _ base: [MoneyCategory],
                             choice: Choice?, decision: (([String]) -> SyncChanges.Decision)? = nil,
                             report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> [MoneyCategory] {
        var result = try rows(local, cloud, base, id: { $0.id }, label: L("财务分类", "Finance category"), describe: { $0.label }, choice: choice,
                              kind: "category", decision: decision, report: report, review: review)
        let parents = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        // A parent deleted on one device while the other adds a child is one explicit family conflict.
        let conflictingParents = Set(result.compactMap { child -> UUID? in
            guard let id = child.parentID else { return nil }
            guard let parent = parents[id], parent.parentID == nil, parent.isIncome == child.isIncome else { return id }
            return nil
        })
        for parent in conflictingParents.sorted(by: { $0.uuidString < $1.uuidString }) {
            func family(_ values: [MoneyCategory]) -> [MoneyCategory] {
                values.filter { $0.id == parent || $0.parentID == parent }.sorted { $0.id.uuidString < $1.id.uuidString }
            }
            let left = family(local), right = family(cloud), original = family(base)
            let chosen = try value(left, right, original, label: L("分类与子分类：", "Category and subcategories: ") +
                                   (left + right).map(\.label).joined(separator: ", "), choice: choice, report: report, review: review, key: "category-family:" + parent.uuidString,
                causalKeys: Set((left + right + original).map { SyncChanges.key("category", $0.id) }).sorted())
            result.removeAll { $0.id == parent || $0.parentID == parent }
            result += chosen
        }
        let archivedParents = Set(result.filter(\.archived).map(\.id))
        for index in result.indices where result[index].parentID.map(archivedParents.contains) == true { result[index].archived = true }
        return result
    }
    private struct AccountPostings: Equatable {
        var accounts: [MoneyAccount]
        var entries: [MoneyEntry]
    }
    /// Amounts and transfer fees are denominated by their accounts. Never merge a currency change
    /// separately from its postings; linked refunds and transfers must follow the same choice.
    static func accountPostingRows(_ local: FinanceData, _ cloud: FinanceData, _ base: FinanceData?,
                                   choice: Choice?, decision: (([String]) -> SyncChanges.Decision)? = nil,
                                   report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> (accounts: [MoneyAccount], entries: [MoneyEntry]) {
        let cloudAccounts = Dictionary(uniqueKeysWithValues: cloud.accounts.map { ($0.id, $0) })
        let differing = Set(local.accounts.compactMap { account -> UUID? in
            guard let other = cloudAccounts[account.id], other.currency != account.currency else { return nil }
            return account.id
        })
        var accountEntries: [UUID: Set<UUID>] = [:], entryAccounts: [UUID: Set<UUID>] = [:], refunds: [UUID: Set<UUID>] = [:]
        if !differing.isEmpty {
            for entry in local.entries + cloud.entries + (base?.entries ?? []) {
                for id in [entry.accountID, entry.destinationID].compactMap({ $0 }) where differing.contains(id) {
                    accountEntries[id, default: []].insert(entry.id); entryAccounts[entry.id, default: []].insert(id)
                }
                if let original = entry.refundOf {
                    refunds[entry.id, default: []].insert(original); refunds[original, default: []].insert(entry.id)
                }
            }
        }
        var handledAccounts = Set<UUID>(), handledEntries = Set<UUID>()
        var chosenAccounts: [MoneyAccount] = [], chosenEntries: [MoneyEntry] = []
        for id in differing.sorted(by: { $0.uuidString < $1.uuidString }) where !handledAccounts.contains(id) {
            var accounts: Set<UUID> = [id], entries = Set<UUID>(), pending = Array(accountEntries[id] ?? [])
            while let entry = pending.popLast() {
                guard entries.insert(entry).inserted else { continue }
                pending.append(contentsOf: refunds[entry] ?? [])
                for account in entryAccounts[entry] ?? [] where accounts.insert(account).inserted {
                    pending.append(contentsOf: accountEntries[account] ?? [])
                }
            }
            func family(_ finance: FinanceData?) -> AccountPostings {
                AccountPostings(accounts: (finance?.accounts ?? []).filter { accounts.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString },
                                entries: (finance?.entries ?? []).filter { entries.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString })
            }
            let left = family(local), right = family(cloud)
            let chosen = try value(left, right, family(base), label:
                L("账户币种与关联流水（选择将用于这些账户、转账、手续费及关联退款）", "Account currencies and postings (choice includes these accounts, transfers, fees and linked refunds)") + "\n" +
                left.accounts.map { $0.name + " · " + $0.currency + " / " + cloudAccounts[$0.id]!.currency }.joined(separator: "\n"), choice: choice, report: report, review: review, key: "account-postings:" + accounts.map(\.uuidString).sorted().joined(separator: ","),
                causalKeys: accounts.map { SyncChanges.key("account", $0) } + entries.map { SyncChanges.key("entry", $0) })
            handledAccounts.formUnion(accounts); handledEntries.formUnion(entries)
            chosenAccounts += chosen.accounts; chosenEntries += chosen.entries
        }
        let accounts = try rows(local.accounts.filter { !handledAccounts.contains($0.id) }, cloud.accounts.filter { !handledAccounts.contains($0.id) },
                                (base?.accounts ?? []).filter { !handledAccounts.contains($0.id) }, id: { $0.id }, label: L("记账账户", "Account"), describe: { $0.name }, choice: choice,
                                kind: "account", decision: decision, report: report, review: review)
        let entries = try rows(local.entries.filter { !handledEntries.contains($0.id) }, cloud.entries.filter { !handledEntries.contains($0.id) },
                               (base?.entries ?? []).filter { !handledEntries.contains($0.id) }, id: { $0.id }, label: L("账单", "Entry"), describe: { $0.title + " · " + $0.currency + " " + NSDecimalNumber(decimal: $0.amount).stringValue }, choice: choice,
                               kind: "entry", decision: decision,
                               mergeFields: { try entryFields($0, $1, $2, choice: choice, report: report, review: review) }, report: report, review: review)
        return ((accounts + chosenAccounts).sorted { $0.id.uuidString < $1.id.uuidString },
                (entries + chosenEntries).sorted { $0.id.uuidString < $1.id.uuidString })
    }
    struct MergeResult {
        let snapshot: TaskBackup
        let automaticFieldCount: Int
    }
    static func merge(local: TaskBackup, cloud: TaskBackup, base: TaskBackup?, choice: Choice? = nil,
                      cloudExists: Bool = true, choices: [String: Choice] = [:], now: Date = Date()) throws -> TaskBackup {
        try mergeResult(local: local, cloud: cloud, base: base, choice: choice,
                        cloudExists: cloudExists, choices: choices, now: now).snapshot
    }
    static func mergeResult(local rawLocal: TaskBackup, cloud rawCloud: TaskBackup, base rawBase: TaskBackup?, choice: Choice? = nil,
                            cloudExists: Bool = true, choices: [String: Choice] = [:], now: Date = Date()) throws -> MergeResult {
        var local = try TaskBackup.decode(bytes(rawLocal), allowLargeFile: true)
        var cloud = try TaskBackup.decode(bytes(rawCloud), allowLargeFile: true)
        let base = try rawBase.map { try TaskBackup.decode(bytes($0), allowLargeFile: true) }
        if base == nil && cloudExists {
            let localDefaults = unusedDefaultIDs(local), cloudDefaults = unusedDefaultIDs(cloud)
            let originals = Dictionary(uniqueKeysWithValues: local.lists.map { ($0.id, $0) })
            let remote = Dictionary(uniqueKeysWithValues: cloud.lists.map { ($0.id, $0) })
            local.lists = local.lists.compactMap { localDefaults.contains($0.id) ? remote[$0.id] : $0 }
            cloud.lists = cloud.lists.map { cloudDefaults.contains($0.id) && !localDefaults.contains($0.id) ? (originals[$0.id] ?? $0) : $0 }
            if isUntouchedInitialFinance(local) { local.finance = cloud.finance }
            else if isUntouchedInitialFinance(cloud), local.finance != nil { cloud.finance = local.finance }
        }
        let resolution = try SyncChanges.Resolution(local: local, cloud: cloud, base: base)
        let review = ConflictReview(choices: choices, local: local, cloud: cloud, base: base,
                                    automatic: AutomaticSyncPolicy(revisions: resolution, now: now))
        var conflicts: [String] = []
        var reported = Set<String>()
        let report: (String) -> Void = { if reported.insert($0).inserted { conflicts.append($0) } }
        let decision = resolution.decision
        var result = TaskBackup(lists: [], tasks: [])
        result.lists = try rows(local.lists, cloud.lists, base?.lists ?? [], id: { $0.id }, label: L("清单（名称、颜色、顺序或层级存在差异）", "List (name, color, order or hierarchy differs)"), describe: { $0.name }, choice: choice, kind: "list", decision: decision,
                                mergeFields: { try listFields($0, $1, $2, choice: choice, report: report, review: review) }, report: report, review: review)
        result.tasks = try taskRows(local.tasks, cloud.tasks, base?.tasks ?? [], choice: choice, decision: decision, report: report, review: review)
        result.weekTitles = try rows(local.weekTitles ?? [], cloud.weekTitles ?? [], base?.weekTitles ?? [], id: { $0.id }, label: L("周标题", "Week title"), describe: { $0.week + " · " + $0.title }, choice: choice, kind: "week", decision: decision,
                                     mergeFields: { try weekFields($0, $1, $2, choice: choice, report: report, review: review) }, report: report, review: review)
        if let l = local.finance, let r = cloud.finance {
            let b = base?.finance
            // Changing base currency revalues every posting. A concurrent posting cannot be mixed into it.
            if l.baseCurrency != r.baseCurrency {
                result.finance = try value(Optional(l), Optional(r), b, label: L("本位币不同的整本账目", "Ledger with different base currencies") + " · " + l.baseCurrency + " / " + r.baseCurrency, choice: choice, report: report, review: review, key: "ledger-currency", causalKeys: resolution.financeKeys)
            } else {
                var finance = l
                finance.baseCurrency = try value(l.baseCurrency, r.baseCurrency, b?.baseCurrency ?? "CNY", label: L("记账本位币", "Base currency"), choice: choice, report: report, review: review, key: "base-currency", causalKeys: [SyncChanges.currencyKey])
                (finance.accounts, finance.entries) = try accountPostingRows(l, r, b, choice: choice, decision: decision, report: report, review: review)
                finance.books = try rows(l.books, r.books, b?.books ?? [], id: { $0.id }, label: L("账本", "Book"), describe: { $0.name }, choice: choice, kind: "book", decision: decision, report: report, review: review)
                finance.categories = try categoryRows(l.categories, r.categories, b?.categories ?? [], choice: choice, decision: decision, report: report, review: review)
                finance.rates = try rateRows(l.rates, r.rates, b?.rates ?? [], choice: choice, report: report, review: review)
                // A bill is reviewed as a whole: its amount, account and schedule decide future postings together.
                let bills = try rows(l.recurringBills, r.recurringBills, b?.recurringBills ?? [], id: { $0.id }, label: L("周期账单", "Recurring bill"),
                                     describe: { $0.title + " · " + $0.currency + " " + NSDecimalNumber(decimal: $0.amount).stringValue + " · " + $0.scheduleLabel },
                                     choice: choice, kind: "recurring", decision: decision,
                                     mergeFields: { try recurringFields($0, $1, $2, choice: choice, report: report, review: review) },
                                     report: report, review: review)
                // Merged end and next dates can leave a bill past its end; it has ended, as after its last occurrence.
                let running = bills.filter { !$0.hasEnded }
                if running.count < bills.count { syncLog.notice("Removed \(bills.count - running.count, privacy: .public) recurring bills that ended in a merge") }
                finance.recurring = running.isEmpty ? nil : running
                result.finance = finance
            }
        } else {
            result.finance = try value(local.finance, cloud.finance, base?.finance, label: L("记账数据", "Ledger"), choice: choice, report: report, review: review, key: "ledger", causalKeys: resolution.financeKeys)
        }
        if !conflicts.isEmpty { throw Conflict(label: conflicts.joined(separator: "\n\n——\n\n"), items: review.items) }
        result.syncChanges = try resolution.revisions(for: result, acknowledging: !review.confirmations.isEmpty, confirmations: review.confirmations)
        // Validate combined references; never silently discard a posting or its account.
        do { try result.validate() }
        catch {
            // Mixed choices may break references or refund limits. Keep review open, never commit a partial merge.
            if !choices.isEmpty && !review.items.isEmpty {
                throw Conflict(label: conflicts.joined(separator: "\n\n"), items: review.items,
                    warning: L("这些选择存在关联，请重新核对相关组：", "These choices affect related records. Review the related groups: ") + error.localizedDescription)
            }
            throw error
        }
        syncLog.debug("Automatically resolved \(review.automaticCount, privacy: .public) field conflicts")
        syncLog.debug("Validated sync merge; manual conflict choice: \(choice != nil || !choices.isEmpty, privacy: .public)")
        return MergeResult(snapshot: result, automaticFieldCount: review.automaticCount)
    }
    static func bytes(_ snapshot: TaskBackup, legacyMigrationFormat: Bool = false) throws -> Data {
        var stable = snapshot
        // Sealed migration assets keep the canonical digest written before recurrence time zones existed.
        stable.version = legacyMigrationFormat ? 13 : 14
        stable.finance?.version = legacyMigrationFormat ? 2 : 3
        stable.createdAt = Date(timeIntervalSince1970: 0)
        stable.lists.sort { $0.id.uuidString < $1.id.uuidString }
        stable.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        stable.weekTitles = (stable.weekTitles ?? []).sorted { $0.week < $1.week }
        if stable.finance != nil {
            stable.finance!.accounts.sort { $0.id.uuidString < $1.id.uuidString }
            stable.finance!.books.sort { $0.id.uuidString < $1.id.uuidString }
            stable.finance!.categories.sort { $0.id.uuidString < $1.id.uuidString }
            stable.finance!.entries.sort { $0.id.uuidString < $1.id.uuidString }
            stable.finance!.rates.sort { $0.base + $0.quote < $1.base + $1.quote }
            stable.finance!.recurring = stable.finance!.recurring?.sorted { $0.id.uuidString < $1.id.uuidString }
            if stable.finance!.recurring?.isEmpty == true { stable.finance!.recurring = nil }
        }
        try stable.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return try encoder.encode(stable)
    }

    /// The worker result and its baseline may commit only against the revision it read.
    @MainActor static func commit(_ snapshot: TaskBackup, changed: Bool, baseline: Data, state: CloudSyncState,
                                  revision: Int, in context: ModelContext) throws -> Bool {
        guard revision == Store.revision, !context.hasChanges else { return false }
        try Store.recovery.requireWritable(context)
        do {
            if changed { try stage(snapshot, in: context) }
            state.baseline = baseline; state.lastSync = Date()
            try Store.save(context, trackSyncChanges: false)
            return true
        } catch { context.rollback(); throw error }
    }

    /// Update existing objects in place so open editors, selections and task references stay valid.
    static func preservingOrder<T>(_ incoming: [T], previous: [T], id: (T) -> UUID) -> [T] {
        let values = Dictionary(uniqueKeysWithValues: incoming.map { (id($0), $0) })
        let previousIDs = Set(previous.map(id))
        return previous.compactMap { values[id($0)] } + incoming.filter { !previousIDs.contains(id($0)) }
    }
    @MainActor static func stage(_ snapshot: TaskBackup, in context: ModelContext) throws {
        try snapshot.validate()
        let oldLists = try context.fetch(FetchDescriptor<TaskList>())
        let oldTasks = try context.fetch(FetchDescriptor<TaskItem>())
        var lists = Dictionary(uniqueKeysWithValues: oldLists.map { ($0.id, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: oldTasks.map { ($0.id, $0) })
        for r in snapshot.lists {
            let list = lists[r.id] ?? TaskList(name: r.name)
            if lists[r.id] == nil { context.insert(list); lists[r.id] = list }
            list.id = r.id; list.name = r.name; list.createdAt = r.createdAt; list.parentID = r.parentID
            list.colorHex = r.colorHex; list.sortOrder = r.sortOrder ?? 0; list.emoji = r.emoji
        }
        for r in snapshot.tasks {
            let task = tasks[r.id] ?? TaskItem(title: r.title)
            if tasks[r.id] == nil { context.insert(task) }
            r.apply(to: task, list: r.listID.flatMap { lists[$0] })
        }
        let taskIDs = Set(snapshot.tasks.map(\.id)), listIDs = Set(snapshot.lists.map(\.id))
        for task in oldTasks where !taskIDs.contains(task.id) { context.delete(task) }
        for list in oldLists where !listIDs.contains(list.id) { context.delete(list) }
        if let titles = snapshot.weekTitles { try CalendarWeekTitle.stage(titles, in: context) }
        if var finance = snapshot.finance {
            if let previous = try FinanceStore.read(context) {
                finance.accounts = preservingOrder(finance.accounts, previous: previous.accounts, id: { $0.id })
                finance.books = preservingOrder(finance.books, previous: previous.books, id: { $0.id })
                finance.categories = preservingOrder(finance.categories, previous: previous.categories, id: { $0.id })
            }
            try FinanceStore.stage(finance, in: context, trackSyncChanges: false)
        }
        else { for ledger in try context.fetch(FetchDescriptor<FinanceLedger>()) { context.delete(ledger) } }
        try SyncChanges.stage(snapshot.syncChanges, in: context)
    }
}
