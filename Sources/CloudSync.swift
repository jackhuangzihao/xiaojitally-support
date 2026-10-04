import SwiftUI
import SwiftData
import CloudKit
import CryptoKit

/// Local only. Saving the merge base in the same transaction as imported rows makes retries crash-safe.
@Model final class CloudSyncState {
    var enabled = false
    var account: String = ""
    var baseline: Data?
    var lastSync: Date?
    init() {}
}

enum CloudMerge {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum Choice { case local, cloud }
    struct Conflict: LocalizedError {
        let label: String
        var errorDescription: String? {
            L("以下内容在两端都有变化，请核对后选择：\n\n", "These items changed on both devices. Review before choosing:\n\n") + label
        }
    }
    static func value<T: Equatable>(_ local: T, _ cloud: T, _ base: T, label: @autoclosure () -> String,
                                    choice: Choice?, report: ((String) -> Void)? = nil) throws -> T {
        if local == cloud || cloud == base { return local }
        if local == base { return cloud }
        switch choice {
        case .local: return local
        case .cloud: return cloud
        case nil:
            if let report { report(label()); return local } // Collect all conflicts; merge never returns this provisional result.
            throw Conflict(label: label())
        }
    }
    static func rows<T: Equatable>(_ local: [T], _ cloud: [T], _ base: [T], id: (T) -> UUID, label: String,
                                   describe: (T) -> String, choice: Choice?, report: @escaping (String) -> Void) throws -> [T] {
        let l = Dictionary(uniqueKeysWithValues: local.map { (id($0), $0) })
        let r = Dictionary(uniqueKeysWithValues: cloud.map { (id($0), $0) })
        let b = Dictionary(uniqueKeysWithValues: base.map { (id($0), $0) })
        return try Set(l.keys).union(r.keys).union(b.keys).sorted { $0.uuidString < $1.uuidString }.compactMap {
            try value(l[$0], r[$0], b[$0], label: label + "\n" +
                      L("本机：", "Local: ") + (l[$0].map(describe) ?? L("已删除", "Deleted")) + "\n" +
                      L("云端：", "Cloud: ") + (r[$0].map(describe) ?? L("已删除", "Deleted")), choice: choice, report: report)
        }
    }

    static func taskDescription(_ task: TaskBackup.TaskRecord?) -> String {
        guard let task else { return L("不存在 / 已彻底删除", "Absent / permanently deleted") }
        let date = task.scheduledAt ?? task.dueAt
        let status = task.deletedAt != nil ? L("最近删除", "Recently deleted") : (task.isDone ? L("已完成", "Completed") : L("未完成", "Open"))
        return "“" + task.title + "” · " + status + (date.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
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
            if l.repeatRule != r.repeatRule || l.repeatUntil != r.repeatUntil || l.repeatAnchorDay != r.repeatAnchorDay || l.nextOccurrenceID != r.nextOccurrenceID { fields.append(L("重复设置或后续任务", "recurrence/successor")) }
        }
        return L("本机：", "Local: ") + taskDescription(local) + "\n" + L("云端：", "Cloud: ") + taskDescription(cloud) +
            (fields.isEmpty ? "" : "\n" + L("差异：", "Differences: ") + fields.joined(separator: "、"))
    }

    /// A repeat chain is one merge unit. Unioning its independently created successors forks the series.
    /// Include base links too, so deleting or unlinking a parent cannot orphan a competing branch.
    static func taskRows(_ local: [TaskBackup.TaskRecord], _ cloud: [TaskBackup.TaskRecord], _ base: [TaskBackup.TaskRecord],
                         choice: Choice?, report: @escaping (String) -> Void) throws -> [TaskBackup.TaskRecord] {
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
            result += try value(left, right, original, label:
                (component.count > 1 ? L("重复任务（选择将用于整条序列，含后续任务）", "Repeating tasks (choice applies to the entire chain, including successors)") : L("任务", "Task")) + "\n" +
                component.filter { l[$0] != r[$0] }.map { taskDifference(l[$0], r[$0]) }.joined(separator: "\n\n"), choice: choice, report: report)
        }
        return result
    }

    /// Recognize only the exact, unused defaults made by this app. Used/customized lists remain user data.
    static func unusedDefaultIDs(_ snapshot: TaskBackup) -> Set<UUID> {
        let referenced = Set(snapshot.tasks.compactMap(\.listID)).union(snapshot.lists.compactMap(\.parentID))
        let names = [["工作", "Work"], ["生活", "Personal"], ["学习", "Study"]]
        return Set(snapshot.lists.compactMap { list -> UUID? in
            guard !referenced.contains(list.id), let index = names.indices.first(where: {
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

    /// Manual quotes are user data; group both directions so a reset or inverse edit cannot resurrect one.
    static func rateRows(_ local: [MoneyRate], _ cloud: [MoneyRate], _ base: [MoneyRate],
                         choice: Choice?, report: @escaping (String) -> Void) throws -> [MoneyRate] {
        func grouped(_ rates: [MoneyRate]) -> [String: [MoneyRate]] {
            Dictionary(grouping: rates, by: { [$0.base, $0.quote].sorted().joined(separator: "/") })
                .mapValues { $0.sorted { $0.base < $1.base } }
        }
        let l = grouped(local), r = grouped(cloud), b = grouped(base)
        return try Set(l.keys).union(r.keys).union(b.keys).sorted().flatMap { pair -> [MoneyRate] in
            let left = l[pair] ?? [], right = r[pair] ?? [], original = b[pair] ?? []
            if left == right { return left }
            let leftManual = left.contains(where: \.isManual), rightManual = right.contains(where: \.isManual)
            if leftManual || rightManual || original.contains(where: \.isManual) {
                if right == original { return left }
                if left == original { return right }
            }
            if leftManual || rightManual {
                if !original.contains(where: \.isManual), leftManual != rightManual { return leftManual ? left : right }
                return try value(left, right, original, label: L("手动汇率：", "Manual exchange rate: ") + pair,
                                 choice: choice, report: report)
            }
            // Provider rates are a cache. Transactions keep their posted rate unchanged.
            var newest = Dictionary(uniqueKeysWithValues: left.map { ($0.base, $0) })
            for rate in right where newest[rate.base].map({ $0.date < rate.date || $0.date == rate.date && $0.fetchedAt < rate.fetchedAt }) ?? true { newest[rate.base] = rate }
            return newest.values.sorted { $0.base < $1.base }
        }
    }

    static func categoryRows(_ local: [MoneyCategory], _ cloud: [MoneyCategory], _ base: [MoneyCategory],
                             choice: Choice?, report: @escaping (String) -> Void) throws -> [MoneyCategory] {
        var result = try rows(local, cloud, base, id: { $0.id }, label: L("财务分类", "Finance category"), describe: { $0.label }, choice: choice, report: report)
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
                                   (left + right).map(\.label).joined(separator: ", "), choice: choice, report: report)
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
                                   choice: Choice?, report: @escaping (String) -> Void) throws -> (accounts: [MoneyAccount], entries: [MoneyEntry]) {
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
                left.accounts.map { $0.name + " · " + $0.currency + " / " + cloudAccounts[$0.id]!.currency }.joined(separator: "\n"), choice: choice, report: report)
            handledAccounts.formUnion(accounts); handledEntries.formUnion(entries)
            chosenAccounts += chosen.accounts; chosenEntries += chosen.entries
        }
        let accounts = try rows(local.accounts.filter { !handledAccounts.contains($0.id) }, cloud.accounts.filter { !handledAccounts.contains($0.id) },
                                (base?.accounts ?? []).filter { !handledAccounts.contains($0.id) }, id: { $0.id }, label: L("记账账户", "Account"), describe: { $0.name }, choice: choice, report: report)
        let entries = try rows(local.entries.filter { !handledEntries.contains($0.id) }, cloud.entries.filter { !handledEntries.contains($0.id) },
                               (base?.entries ?? []).filter { !handledEntries.contains($0.id) }, id: { $0.id }, label: L("账单", "Entry"), describe: { $0.title + " · " + $0.currency + " " + NSDecimalNumber(decimal: $0.amount).stringValue }, choice: choice, report: report)
        return ((accounts + chosenAccounts).sorted { $0.id.uuidString < $1.id.uuidString },
                (entries + chosenEntries).sorted { $0.id.uuidString < $1.id.uuidString })
    }
    static func merge(local rawLocal: TaskBackup, cloud rawCloud: TaskBackup, base rawBase: TaskBackup?, choice: Choice? = nil,
                      cloudExists: Bool = true) throws -> TaskBackup {
        var local = try TaskBackup.decode(bytes(rawLocal), allowLargeFile: true)
        var cloud = try TaskBackup.decode(bytes(rawCloud), allowLargeFile: true)
        let base = try rawBase.map { try TaskBackup.decode(bytes($0), allowLargeFile: true) }
        if base == nil && cloudExists {
            let localDefaults = unusedDefaultIDs(local), cloudDefaults = unusedDefaultIDs(cloud)
            let originals = Dictionary(uniqueKeysWithValues: local.lists.map { ($0.id, $0) })
            let remote = Dictionary(uniqueKeysWithValues: cloud.lists.map { ($0.id, $0) })
            local.lists = local.lists.compactMap { localDefaults.contains($0.id) ? remote[$0.id] : $0 }
            cloud.lists = cloud.lists.map { cloudDefaults.contains($0.id) && !localDefaults.contains($0.id) ? (originals[$0.id] ?? $0) : $0 }
            if isInitialFinance(local.finance) { local.finance = cloud.finance }
            else if isInitialFinance(cloud.finance), local.finance != nil { cloud.finance = local.finance }
        }
        var conflicts: [String] = []
        let report: (String) -> Void = { conflicts.append($0) }
        var result = TaskBackup(lists: [], tasks: [])
        result.lists = try rows(local.lists, cloud.lists, base?.lists ?? [], id: { $0.id }, label: L("清单（名称、颜色、顺序或层级存在差异）", "List (name, color, order or hierarchy differs)"), describe: { $0.name }, choice: choice, report: report)
        result.tasks = try taskRows(local.tasks, cloud.tasks, base?.tasks ?? [], choice: choice, report: report)
        result.weekTitles = try rows(local.weekTitles ?? [], cloud.weekTitles ?? [], base?.weekTitles ?? [], id: { $0.id }, label: L("周标题", "Week title"), describe: { $0.week + " · " + $0.title }, choice: choice, report: report)
        if let l = local.finance, let r = cloud.finance {
            let b = base?.finance
            // Changing base currency revalues every posting. A concurrent posting cannot be mixed into it.
            if l.baseCurrency != r.baseCurrency {
                result.finance = try value(Optional(l), Optional(r), b, label: L("本位币不同的整本账目", "Ledger with different base currencies") + " · " + l.baseCurrency + " / " + r.baseCurrency, choice: choice, report: report)
            } else {
                var finance = l
                finance.baseCurrency = try value(l.baseCurrency, r.baseCurrency, b?.baseCurrency ?? "CNY", label: L("记账本位币", "Base currency"), choice: choice, report: report)
                (finance.accounts, finance.entries) = try accountPostingRows(l, r, b, choice: choice, report: report)
                finance.books = try rows(l.books, r.books, b?.books ?? [], id: { $0.id }, label: L("账本", "Book"), describe: { $0.name }, choice: choice, report: report)
                finance.categories = try categoryRows(l.categories, r.categories, b?.categories ?? [], choice: choice, report: report)
                finance.rates = try rateRows(l.rates, r.rates, b?.rates ?? [], choice: choice, report: report)
                result.finance = finance
            }
        } else {
            result.finance = try value(local.finance, cloud.finance, base?.finance, label: L("记账数据", "Ledger"), choice: choice, report: report)
        }
        if !conflicts.isEmpty { throw Conflict(label: conflicts.joined(separator: "\n\n——\n\n")) }
        // Validate combined references; never silently discard a posting or its account.
        try result.validate()
        return result
    }
    static func bytes(_ snapshot: TaskBackup) throws -> Data {
        var stable = snapshot
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
            try Store.save(context)
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
            try FinanceStore.stage(finance, in: context)
        }
        else { for ledger in try context.fetch(FetchDescriptor<FinanceLedger>()) { context.delete(ledger) } }
    }
}

@MainActor @Observable final class CloudSync {
    static let shared = CloudSync()
    static let containerID = "iCloud.local.jianshi.personal"
    #if os(macOS)
    /// Isolated synthetic record; never reads the user's snapshot or opens their local store.
    static func connectivityCheck() async throws {
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else { throw TaskBackup.invalid("iCloud account unavailable") }
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "tally-connectivity-check-" + UUID().uuidString)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = TaskBackup(lists: [], tasks: [.init(TaskItem(title: "Temporary sync verification"))])
        let bytes = try CloudMerge.bytes(snapshot)
        try bytes.write(to: file)
        let record = CKRecord(recordType: "TallySnapshot", recordID: id)
        record["snapshot"] = CKAsset(fileURL: file); record["formatVersion"] = Int64(1); record["digest"] = CloudMerge.digest(bytes)
        do {
            let saved = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            _ = try saved.saveResults[id]!.get()
            let fetched = try await database.record(for: id)
            guard let url = (fetched["snapshot"] as? CKAsset)?.fileURL, try Data(contentsOf: url) == bytes else { throw TaskBackup.invalid("Cloud round trip differs") }
            let stale = try await database.record(for: id)
            fetched["digest"] = "new-revision"
            _ = try await database.modifyRecords(saving: [fetched], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults[id]!.get()
            stale["digest"] = "stale-revision"
            var rejected = false
            do { _ = try await database.modifyRecords(saving: [stale], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults[id]!.get() }
            catch let error as CKError where error.code == .serverRecordChanged { rejected = true }
            guard rejected else { throw TaskBackup.invalid("Cloud conflict was not rejected") }
            _ = try await database.deleteRecord(withID: id)
            print("CLOUD PASS: private asset upload, download, optimistic conflict rejection, cleanup")
        } catch {
            do { _ = try await database.deleteRecord(withID: id) }
            catch let cleanup as CKError where cleanup.code == .unknownItem { /* Nothing was created. */ }
            catch { print("CLOUD CLEANUP: verify temporary record \(id.recordName) in the development console") }
            print("CLOUD DIAGNOSTIC: \(error.localizedDescription)")
            throw error
        }
    }
    #endif
    private(set) var enabled = false
    private(set) var running = false
    private(set) var detail = ""
    private(set) var lastSync: Date?
    private(set) var conflict = false
    private(set) var accountChanged = false
    private var originalContainer: ModelContainer?
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var applying = false
    private var pendingSave = false
    private var editors = 0
    private var conflictLocal: Data?
    private var conflictCloud: Data?
    private var observer: NSObjectProtocol?
    private var retryAfter: Date?
    /// Only cache a saved context revision. Recovery replaces the context; every save changes revision.
    struct SnapshotCache {
        let contextID: ObjectIdentifier
        let revision: Int
        let baseline: Data?
        let local: TaskBackup
        let localBytes: Data
        let base: TaskBackup?
        let baselineDigest: String?
        @MainActor func matches(_ context: ModelContext, baseline: Data?) -> Bool {
            contextID == ObjectIdentifier(context) && revision == Store.revision && self.baseline == baseline && !context.hasChanges
        }
    }
    @ObservationIgnored private var snapshotCache: SnapshotCache?
    private var context: ModelContext? { (Store.recovery.container ?? originalContainer)?.mainContext }
    var summary: String {
        if !enabled { return L("仅保存在本机", "Stored on this device") }
        if running { return L("正在同步 iCloud…", "Syncing with iCloud…") }
        if !detail.isEmpty { return L("iCloud · 等待同步", "iCloud · Sync pending") }
        return L("iCloud 同步已开启", "iCloud sync enabled")
    }
    func editing(_ began: Bool) {
        editors = max(0, editors + (began ? 1 : -1))
        if began { generation += 1 }
        else if editors == 0 { localSaved() }
    }
    func attach(_ container: ModelContainer) {
        generation += 1; snapshotCache = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        originalContainer = container
        do {
            if let state = try container.mainContext.fetch(FetchDescriptor<CloudSyncState>()).first {
                enabled = state.enabled; lastSync = state.lastSync
            }
        } catch { detail = error.localizedDescription }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.generation += 1; self.snapshotCache = nil
                self.localSaved()
            }
        }
    }
    private func state(_ context: ModelContext) throws -> CloudSyncState {
        let states = try context.fetch(FetchDescriptor<CloudSyncState>())
        guard states.count <= 1 else { throw TaskBackup.invalid("Multiple sync states") }
        if let state = states.first { return state }
        let state = CloudSyncState(); context.insert(state); return state
    }
    func setEnabled(_ value: Bool) {
        guard let context else { return }
        do {
            try Store.recovery.requireWritable(context)
            let state = try state(context); state.enabled = value
            applying = true; defer { applying = false }
            try Store.save(context)
            enabled = value; generation += 1; snapshotCache = nil; detail = ""; conflict = false
            debounce?.cancel()
            if value { Task { await sync() } }
        } catch { detail = error.localizedDescription }
    }
    func localSaved() {
        guard enabled, !applying else { return }
        if running { pendingSave = true; return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }
    private func canContinue(_ ticket: Int, in context: ModelContext) -> Bool {
        enabled && ticket == generation && editors == 0 && context === self.context &&
            Store.recovery.failure == nil && !context.hasChanges
    }
    func sync(choice: CloudMerge.Choice? = nil) async {
        guard enabled, !running, editors == 0, let context, Store.recovery.failure == nil, !context.hasChanges else { return }
        if let retryAfter, Date() < retryAfter { return }
        if conflict && choice == nil { return }
        running = true
        defer {
            running = false
            if pendingSave { pendingSave = false; localSaved() }
        }
        let ticket = generation
        do {
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.accountStatus() == .available else {
                throw TaskBackup.invalid(L("请在系统设置登录 iCloud 并允许小记使用 iCloud。本地数据仍可编辑。", "Sign in to iCloud in System Settings and allow Tally to use iCloud. Local editing remains available."))
            }
            let account = try await container.userRecordID().recordName
            guard canContinue(ticket, in: context) else { return }
            let state = try state(context)
            if !state.account.isEmpty && state.account != account {
                snapshotCache = nil
                accountChanged = true
                throw TaskBackup.invalid(L("iCloud 账户已改变。为避免把原账户数据传给其他人，同步已暂停。切回原账户后可继续。", "The iCloud account changed. Sync is paused to avoid uploading the previous account’s data. Switch back to the original account to continue."))
            }
            accountChanged = false
            // Bind before the first upload, including failed/offline attempts. Never silently rebind accounts.
            if state.account.isEmpty {
                state.account = account
                applying = true
                defer { applying = false }
                try Store.save(context)
            }
            let baseline = state.baseline
            let prepared: SnapshotCache
            if let cached = snapshotCache, cached.matches(context, baseline: baseline) {
                prepared = cached
            } else {
                let local = try TaskBackup.capture(context), revision = Store.revision
                let (base, localBytes, baselineDigest) = try await Task.detached {
                    (try baseline.map { try TaskBackup.decode($0, allowLargeFile: true) },
                     try CloudMerge.bytes(local), baseline.map(CloudMerge.digest))
                }.value
                guard canContinue(ticket, in: context) else { return }
                prepared = SnapshotCache(contextID: ObjectIdentifier(context), revision: revision, baseline: baseline,
                                         local: local, localBytes: localBytes, base: base, baselineDigest: baselineDigest)
                if prepared.matches(context, baseline: state.baseline) { snapshotCache = prepared }
            }
            let local = prepared.local, localBytes = prepared.localBytes, base = prepared.base
            let capturedRevision = prepared.revision, baselineDigest = prepared.baselineDigest
            let database = container.privateCloudDatabase
            let recordID = CKRecord.ID(recordName: "tally-personal-v1")
            var record: CKRecord
            var remote: TaskBackup
            var unchangedRemoteBytes: Data?
            var cloudExists = true
            do {
                let headers = try await database.records(for: [recordID], desiredKeys: ["formatVersion", "digest"])
                guard let header = headers[recordID] else { throw TaskBackup.invalid("Missing CloudKit fetch result") }
                record = try header.get()
                guard (record["formatVersion"] as? Int64) == 1 else {
                    throw TaskBackup.invalid(L("云端格式暂不支持，请更新小记。", "Update Tally to read this cloud format."))
                }
                if let base, let baselineDigest, record["digest"] as? String == baselineDigest {
                    remote = base // Do not download the asset again when nothing changed in the cloud.
                    unchangedRemoteBytes = baseline
                } else {
                    record = try await database.record(for: recordID)
                    guard (record["formatVersion"] as? Int64) == 1, let url = (record["snapshot"] as? CKAsset)?.fileURL else { throw TaskBackup.invalid("Unsupported cloud snapshot") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 50 * 1024 * 1024 else { throw TaskBackup.invalid(L("云端数据超过当前同步上限（50 MB）。本地数据不受影响。", "Cloud data exceeds the current 50 MB sync limit. Local data is unaffected.")) }
                    remote = try await Task.detached {
                        try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true)
                    }.value
                }
            } catch let error as CKError where error.code == .unknownItem {
                guard base == nil else { throw TaskBackup.invalid(L("云端副本已被移除，同步已暂停，未自动重新上传。请先导出本地备份并联系支持。", "The cloud copy was removed. Sync paused without re-uploading it. Export a local backup and contact support.")) }
                record = CKRecord(recordType: "TallySnapshot", recordID: recordID)
                remote = TaskBackup(lists: [], tasks: [])
                cloudExists = false
            }
            let cloud = remote, existingCloud = cloudExists
            let remoteBytes: Data
            if let unchangedRemoteBytes { remoteBytes = unchangedRemoteBytes }
            else { remoteBytes = try await Task.detached { try CloudMerge.bytes(cloud) }.value }
            guard canContinue(ticket, in: context) else { return }
            if localBytes == baseline && localBytes == remoteBytes && capturedRevision == Store.revision {
                lastSync = Date(); detail = ""; conflict = false
                return
            }
            if choice != nil && (conflictLocal != localBytes || conflictCloud != remoteBytes) {
                conflict = false; conflictLocal = nil; conflictCloud = nil
                throw TaskBackup.invalid(L("数据已变化，请重新同步后再处理冲突。", "Data changed. Sync again before resolving conflicts."))
            }
            let merged: TaskBackup, mergedBytes: Data
            do {
                (merged, mergedBytes) = try await Task.detached {
                    let merged = try CloudMerge.merge(local: local, cloud: cloud, base: base, choice: choice, cloudExists: existingCloud)
                    return (merged, try CloudMerge.bytes(merged))
                }.value
            }
            catch let error as CloudMerge.Conflict {
                try await protect(localBytes, remoteBytes)
                guard canContinue(ticket, in: context) else { return }
                conflict = true; conflictLocal = localBytes; conflictCloud = remoteBytes
                throw error
            } catch {
                try await protect(localBytes, remoteBytes)
                guard canContinue(ticket, in: context) else { return }
                conflict = false
                throw TaskBackup.invalid(L("两端的关联变化无法安全合并，未覆盖任何数据。请导出双方恢复副本，检查相关账户、退款或清单后重试。", "Related changes cannot be merged safely. No data was overwritten. Export both recovery copies and review the affected accounts, refunds or lists before retrying.") + "\n" + error.localizedDescription)
            }
            guard mergedBytes.count <= 50 * 1024 * 1024 else { throw TaskBackup.invalid(L("数据超过当前同步上限（50 MB）。请继续使用本地备份。", "Data exceeds the current 50 MB sync limit. Continue using local backups.")) }
            // ponytail: one atomic asset keeps finance relationships consistent, bounded at 50 MB.
            // Use per-entity CloudKit records if measured personal ledgers outgrow snapshot uploads.
            // Always retain both sides before changing either, including before conflict resolution.
            if state.baseline == nil || mergedBytes != localBytes || choice != nil { try await protect(localBytes, remoteBytes) }
            guard canContinue(ticket, in: context) else { return }
            if choice != nil && capturedRevision != Store.revision {
                conflict = false; conflictLocal = nil; conflictCloud = nil; pendingSave = true
                throw TaskBackup.invalid(L("处理冲突时数据又有变化，将重新检查。", "Data changed while resolving conflicts. Checking again."))
            }
            if mergedBytes != remoteBytes || record.recordChangeTag == nil {
                // Recheck after awaits. Account changes invalidate every in-flight operation.
                guard try await container.userRecordID().recordName == account, canContinue(ticket, in: context) else { return }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: file) }
                let digest = try await Task.detached {
                    try mergedBytes.write(to: file, options: .atomic)
                    return CloudMerge.digest(mergedBytes)
                }.value
                guard canContinue(ticket, in: context) else { return }
                record["snapshot"] = CKAsset(fileURL: file)
                record["formatVersion"] = Int64(1)
                record["digest"] = digest
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                guard let saved = result.saveResults[recordID] else { throw TaskBackup.invalid("Missing CloudKit save result") }
                _ = try saved.get()
            }
            guard canContinue(ticket, in: context) else { return }
            // Edits made while the upload was in flight are merged again, never overwritten by its old snapshot.
            let current = try TaskBackup.capture(context)
            let importRevision = Store.revision
            let (final, finalBytes, changed) = try await Task.detached {
                let final = try CloudMerge.merge(local: current, cloud: merged, base: local)
                let bytes = try CloudMerge.bytes(final)
                return (final, bytes, try bytes != CloudMerge.bytes(current))
            }.value
            guard canContinue(ticket, in: context) else { return }
            // A quick edit can save while the worker runs. Discard stale work and retry from fresh data.
            applying = true
            defer { applying = false }
            guard try CloudMerge.commit(final, changed: changed, baseline: mergedBytes, state: state,
                                        revision: importRevision, in: context) else { pendingSave = true; return }
            // A save may normalize list colors. Refill from the actual committed context on the next poll.
            snapshotCache = nil
            lastSync = state.lastSync; detail = ""; conflict = false; conflictLocal = nil; conflictCloud = nil
            if finalBytes != mergedBytes { pendingSave = true; detail = L("新修改等待上传。", "New edits are waiting to upload.") }
        } catch {
            // Cloud errors never put the local store into read-only recovery.
            if ticket == generation {
                retryAfter = Self.retryDate(error)
                detail = Self.message(error)
                if let retryAfter { detail += "\n" + L("Apple 要求暂缓请求，将在 ", "Apple requested a pause. Retrying after ") + retryAfter.formatted(date: .omitted, time: .standard) }
            }
        }
    }
    static func retryDate(_ error: Error, now: Date = Date()) -> Date? {
        guard let seconds = (error as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber,
              seconds.doubleValue.isFinite, seconds.doubleValue > 0 else { return nil }
        return now.addingTimeInterval(seconds.doubleValue)
    }
    static func recoveryDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiBackups/BeforeSync", isDirectory: true)
    }
    private func protect(_ local: Data, _ cloud: Data) async throws {
        let directory = try Self.recoveryDirectory()
        try await Task.detached {
            // Reuse the existing hourly/daily retention policy instead of unbounded copies per edit.
            _ = try BackupFiles.save(TaskBackup.decode(local, allowLargeFile: true), directory: directory, owner: "sync-local", force: false)
            _ = try BackupFiles.save(TaskBackup.decode(cloud, allowLargeFile: true), directory: directory, owner: "sync-cloud", force: false)
        }.value
    }
    static func message(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .networkUnavailable, .networkFailure: return L("网络不可用，恢复连接后会自动重试。本地修改已保留。", "Offline. Sync retries when connected. Local changes are retained.")
        case .quotaExceeded: return L("iCloud 空间不足，请释放空间后重试。本地修改已保留。", "iCloud storage is full. Free up space and retry. Local changes are retained.")
        case .serverRecordChanged: return L("另一台设备刚刚更新了数据，稍后会重新合并。", "Another device just updated the data. Sync will merge again shortly.")
        case .notAuthenticated: return L("请登录 iCloud 后重试。本地修改已保留。", "Sign in to iCloud and retry. Local changes are retained.")
        default: return L("iCloud 暂未同步，本地修改已保留。", "iCloud sync is pending. Local changes are retained.") + "\n" + error.localizedDescription
        }
    }
}

/// Do not replace a model underneath an unsaved editor draft. Sync resumes when the last editor closes.
struct CloudSyncEditingGuard: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { CloudSync.shared.editing(true) }
            .onDisappear { CloudSync.shared.editing(false) }
    }
}

struct CloudSyncSettings: View {
    @Environment(\.locale) private var locale
    @State private var confirmEnable = false
    @State private var resolve = false
    @State private var export = false
    @State private var document: BackupDocument?
    @State private var exportError: String?
    private var sync: CloudSync { .shared }
    var body: some View {
        Section(L("数据与同步", "Data and sync")) {
            Toggle("iCloud", isOn: Binding(get: { sync.enabled }, set: { if $0 { confirmEnable = true } else { sync.setEnabled(false) } }))
            Text(sync.summary).font(.callout)
            Text(L("开启后，任务、清单和账目会在同一 Apple 账户的设备间自动同步。应用打开时同步；离线仍可编辑。同步不代替备份。", "Sync tasks, lists and finances across devices using the same Apple Account while the app is open. Offline editing remains available. Sync does not replace backups."))
                .font(.caption).foregroundStyle(.secondary)
            if let date = sync.lastSync { Text(L("上次完成：", "Last completed: ") + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            if !sync.detail.isEmpty { Text(sync.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if sync.enabled {
                Button(L("立即同步", "Sync now")) { Task { await sync.sync() } }.disabled(sync.running || sync.conflict)
                if sync.conflict { Button(L("处理同步冲突…", "Resolve sync conflicts…")) { resolve = true }.disabled(sync.running) }
            }
            Menu(L("导出同步恢复副本", "Export sync recovery copy")) {
                Button(L("合并前的本机副本", "Local copy before merge")) { exportCopy(owner: "sync-local") }
                Button(L("合并前的云端副本", "Cloud copy before merge")) { exportCopy(owner: "sync-cloud") }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.secondary) }
        }
        .fileExporter(isPresented: $export, document: document, contentType: .json, defaultFilename: "Tally-sync-recovery") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .confirmationDialog(L("开启 iCloud 同步？", "Enable iCloud sync?"), isPresented: $confirmEnable, titleVisibility: .visible) {
            Button(L("开启并合并数据", "Enable and merge data")) { sync.setEnabled(true) }
        } message: {
            Text(L("本机任务、清单与账目将上传到你自己的 iCloud 私有数据库，并与其他设备合并，占用你的 iCloud 空间。关闭同步不会删除已上传的副本。", "Your tasks, lists and finances will be uploaded to your private iCloud database and merged with other devices, using your iCloud storage. Turning sync off does not delete uploaded copies."))
        }
        .sheet(isPresented: $resolve) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("核对同步冲突", "Review sync conflicts")).font(.headline)
                ScrollView {
                    Text(sync.detail).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                Text(L("下面的选择适用于本次列出的所有冲突。重复任务按整条序列选择；账户币种与关联流水一起选择；本位币冲突按整本账目选择。其他项目继续合并。合并前已保存双方恢复副本。", "Your choice applies to all listed conflicts. Repeating tasks are kept as a whole chain; account currencies stay with their related postings; base-currency conflicts affect the entire ledger. Other items are merged. Recovery copies of both sides are saved first."))
                    .font(.callout).foregroundStyle(.secondary)
                Button(L("所有冲突保留本机修改", "Keep local changes for all conflicts")) { resolve = false; Task { await sync.sync(choice: .local) } }
                    .buttonStyle(.bordered).controlSize(.large)
                Button(L("所有冲突保留云端修改", "Keep cloud changes for all conflicts")) { resolve = false; Task { await sync.sync(choice: .cloud) } }
                    .buttonStyle(.bordered).controlSize(.large)
                Button(L("暂不处理", "Decide later"), role: .cancel) { resolve = false }.keyboardShortcut(.cancelAction)
            }
            .padding()
            #if os(macOS)
            .frame(width: 560, height: 560)
            #endif
        }
    }
    private func exportCopy(owner: String) {
        Task {
            do {
                let directory = try CloudSync.recoveryDirectory()
                let data = try await Task.detached {
                    guard let file = try BackupFiles.ownedFiles(directory: directory, owner: owner).first else { throw TaskBackup.invalid(L("尚无同步恢复副本。", "No sync recovery copy yet.")) }
                    return try Data(contentsOf: file.url)
                }.value
                document = BackupDocument(data: data); exportError = nil; export = true
            } catch { exportError = error.localizedDescription }
        }
    }
}

extension CloudMerge {
    @MainActor static func check() throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("SYNC CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var failed = false; do { try action() } catch { failed = true }
            try check(failed, label)
        }
        do {
            var base = TaskBackup(weekTitles: [.init(week: "2026-09-28", title: "Week 11")], lists: [], tasks: [])
            var local = base, remote = base
            local.weekTitles![0].title = "Work week"
            remote.weekTitles!.append(.init(week: "2026-10-05", title: "Holiday"))
            let merged = try merge(local: local, cloud: remote, base: base)
            try check(merged.weekTitles?.count == 2 && merged.weekTitles?.first { $0.week == "2026-09-28" }?.title == "Work week", "independent week titles merge across devices")
            remote = base; remote.weekTitles![0].title = "Personal week"
            try rejects("same week's simultaneous title edits need a choice") { _ = try merge(local: local, cloud: remote, base: base) }
            try check(try merge(local: local, cloud: remote, base: base, choice: .cloud).weekTitles?[0].title == "Personal week", "week-title conflict honors explicit choice")
            remote = base; remote.weekTitles = []
            try rejects("title removal versus title edit cannot silently discard either") { _ = try merge(local: local, cloud: remote, base: base) }
            try check(try merge(local: base, cloud: remote, base: base).weekTitles?.isEmpty == true, "cleared week title stays cleared")
            var reversed = merged; reversed.weekTitles?.reverse()
            try check(try bytes(reversed) == bytes(merged) && BackupFiles.contentData(reversed) == BackupFiles.contentData(merged), "week-title ordering cannot create extra sync or backup revisions")
            base.weekTitles = nil
            try check(try merge(local: merged, cloud: base, base: nil).weekTitles == merged.weekTitles, "first sync with a legacy snapshot retains new week titles")
        }
        do {
            let manual = MoneyRate(base: "USD", quote: "CNY", rate: 7, date: "2026-10-01", fetchedAt: Date(timeIntervalSince1970: 1), source: "Manual")
            let fresh = MoneyRate(base: "USD", quote: "CNY", rate: 8, date: "2026-10-02", fetchedAt: Date(timeIntervalSince1970: 2), source: "ECB")
            var conflicts: [String] = []
            let report: (String) -> Void = { conflicts.append($0) }
            try check(try rateRows([], [manual], [manual], choice: nil, report: report).isEmpty, "reset manual rate does not resurrect the unchanged cloud quote")
            try check(try rateRows([manual], [fresh], [], choice: nil, report: report) == [manual], "concurrent provider update does not replace a manual quote")
            var historical = fresh; historical.date = "2026-09-01"; historical.fetchedAt = fresh.fetchedAt.addingTimeInterval(3600)
            try check(try rateRows([fresh], [historical], [], choice: nil, report: report) == [fresh], "a historical rate fetched later cannot replace a newer quote date")
            try check(try rateRows([fresh], [historical], [fresh], choice: nil, report: report) == [fresh], "an unchanged newer local quote survives an older historical cloud refresh")
            let inverse = MoneyRate(base: "CNY", quote: "USD", rate: Decimal(string: "0.15")!, date: "2026-10-02", source: "Manual")
            try check(try rateRows([inverse], [manual], [manual], choice: nil, report: report) == [inverse], "changing manual direction replaces both sides as one currency pair")
            _ = try rateRows([], [inverse], [manual], choice: nil, report: report)
            try check(conflicts.count == 1, "manual reset versus a concurrent manual edit prompts before data loss")
            let parent = MoneyCategory(name: "Travel")
            let child = MoneyCategory(name: "Flights", parentID: parent.id)
            var archived = parent; archived.archived = true
            let categories = try categoryRows([archived], [parent, child], [parent], choice: nil, report: report)
            try check(categories.count == 2 && categories.allSatisfy(\.archived), "archiving a parent retains and archives a concurrently added child")
            conflicts = []
            _ = try categoryRows([], [parent, child], [parent], choice: nil, report: report)
            try check(conflicts.count == 1, "parent deletion versus new child gives a resolvable family conflict")
            try check(try categoryRows([], [parent, child], [parent], choice: .cloud, report: report).count == 2, "choosing cloud restores the complete category family")
        }
        let item = TaskItem(title: "Original", scheduledAt: Date(timeIntervalSince1970: 1_800_000_000))
        var base = TaskBackup(lists: [], tasks: [.init(item)])
        var local = base, remote = base
        local.tasks[0].title = "Mac edit"
        remote.tasks.append(.init(TaskItem(title: "iPhone new task")))
        var merged = try merge(local: local, cloud: remote, base: base)
        try check(merged.tasks.count == 2 && merged.tasks.contains { $0.title == "Mac edit" }, "independent edits survive")
        let retry = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue, userInfo: [CKErrorRetryAfterKey: 337])
        let now = Date(timeIntervalSince1970: 1000)
        try check(CloudSync.retryDate(retry, now: now) == now.addingTimeInterval(337), "server retry delay is respected")
        remote = base; remote.tasks[0].title = "iPhone edit"
        try rejects("same task conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        merged = try merge(local: local, cloud: remote, base: base, choice: .cloud)
        try check(merged.tasks[0].title == "iPhone edit", "explicit conflict choice")
        remote = base; remote.tasks = []
        try rejects("delete versus edit conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        try check(try merge(local: base, cloud: remote, base: base).tasks.isEmpty, "deletion propagates without resurrection")
        try check(try bytes(merge(local: local, cloud: local, base: base)) == bytes(local), "retry after upload before local commit is idempotent")
        let roundTrip = try TaskBackup.decode(bytes(local), allowLargeFile: true)
        try check(try bytes(local) == bytes(roundTrip), "date precision is stable across JSON")
        var ledger = FinanceData.initial
        let account = MoneyAccount(name: "AUD", currency: "AUD", opening: 1600)
        let destination = MoneyAccount(name: "Study", currency: "AUD")
        ledger.accounts = [account, destination]
        base.finance = ledger; local = base; remote = base
        var transfer = MoneyEntry(); transfer.title = "Transfer"; transfer.kind = .transfer; transfer.currency = "AUD"
        transfer.amount = 1500; transfer.accountAmount = 1500; transfer.accountID = account.id
        transfer.destinationID = destination.id; transfer.destinationAmount = 1500; transfer.bookID = ledger.books[0].id
        local.finance!.entries.append(transfer)
        var expense = MoneyEntry(); expense.title = "Expense"; expense.kind = .expense; expense.currency = "AUD"
        expense.amount = 20; expense.accountAmount = 20; expense.accountID = account.id; expense.bookID = ledger.books[0].id
        remote.finance!.entries.append(expense)
        merged = try merge(local: local, cloud: remote, base: base)
        try check(merged.finance!.balance(account.id) == 80 && merged.finance!.balance(destination.id) == 1500, "two-device posting and transfer balance")
        try check(try merge(local: merged, cloud: merged, base: base).finance!.entries.count == 2, "retries never double post")
        remote = base; remote.finance!.accounts.removeAll { $0.id == account.id }
        try rejects("delete account versus concurrent posting is blocked") { _ = try merge(local: local, cloud: remote, base: base) }
        remote = base; remote.finance!.baseCurrency = "AUD"
        try rejects("base currency conversion versus concurrent posting conflicts") { _ = try merge(local: local, cloud: remote, base: base) }
        remote = base; remote.finance!.entries = [transfer]; remote.finance!.entries[0].accountAmount = 1499
        try rejects("same posting does not silently win") { _ = try merge(local: local, cloud: remote, base: base) }
        do {
            var money = FinanceData.initial
            let wallet = MoneyAccount(name: "Travel wallet", currency: "USD", opening: 100)
            let sender = MoneyAccount(name: "CNY sender", currency: "CNY", opening: 1000)
            let spare = MoneyAccount(name: "Spare", currency: "GBP", opening: 50)
            money.accounts = [wallet, sender, spare]
            let original = TaskBackup(finance: money, lists: [], tasks: [])
            var converted = original, changed = wallet; changed.currency = "EUR"
            try converted.finance!.updateAccount(changed, expected: wallet)
            var debit = MoneyEntry(); debit.title = "USD coffee"; debit.currency = "USD"; debit.amount = 10
            debit.accountID = wallet.id; debit.accountAmount = 10; debit.bookID = money.books[0].id; debit.baseAmount = 70
            var credit = debit; credit.id = UUID(); credit.kind = .income; credit.title = "USD income"
            var incoming = debit; incoming.id = UUID(); incoming.kind = .transfer; incoming.title = "Incoming transfer"
            incoming.currency = "CNY"; incoming.amount = 70; incoming.accountID = sender.id; incoming.accountAmount = 70
            incoming.destinationID = wallet.id; incoming.destinationAmount = 10; incoming.fee = 2; incoming.baseFee = 2; incoming.baseAmount = nil
            var outgoing = debit; outgoing.id = UUID(); outgoing.kind = .transfer; outgoing.title = "Outgoing transfer"
            outgoing.destinationID = sender.id; outgoing.destinationAmount = 70; outgoing.fee = 1; outgoing.baseFee = 7; outgoing.baseAmount = nil
            var adjustment = debit; adjustment.id = UUID(); adjustment.kind = .adjustment; adjustment.title = "USD correction"
            adjustment.amount = -10; adjustment.accountAmount = -10; adjustment.baseAmount = nil
            var unrelated = debit; unrelated.id = UUID(); unrelated.title = "Independent GBP posting"
            unrelated.currency = "GBP"; unrelated.accountID = spare.id; unrelated.baseAmount = 90
            for posting in [debit, credit, incoming, outgoing, adjustment] {
                var posted = original
                try posted.finance!.updateEntry(posting, expected: nil, baseCurrency: "CNY")
                try posted.finance!.updateEntry(unrelated, expected: nil, baseCurrency: "CNY")
                for reverse in [false, true] {
                    let left = reverse ? posted : converted, right = reverse ? converted : posted
                    do {
                        _ = try merge(local: left, cloud: right, base: original)
                        throw TaskBackup.invalid("Currency and concurrent posting must require an explicit choice")
                    } catch let conflict as Conflict {
                        try check(conflict.label.contains(wallet.name) && conflict.label.contains("USD") && conflict.label.contains("EUR"), "currency conflict identifies account and both denominations: \(posting.title)")
                    }
                    for choice in [Choice.local, .cloud] {
                        let selected = choice == .local ? left : right
                        let resolved = try merge(local: left, cloud: right, base: original, choice: choice)
                        try check(resolved.finance!.accounts.first { $0.id == wallet.id } == selected.finance!.accounts.first { $0.id == wallet.id } &&
                                  resolved.finance!.entries.first { $0.id == posting.id } == selected.finance!.entries.first { $0.id == posting.id }, "currency choice retains complete account and posting amounts/fees: \(posting.title)")
                        try check(resolved.finance!.entries.contains(unrelated), "currency choice preserves independent postings")
                        try check(try bytes(merge(local: resolved, cloud: resolved, base: original)) == bytes(resolved), "currency resolution retries are idempotent")
                    }
                }
            }
            // A refund to another account still depends on the selected original expense.
            var refunded = original, refund = debit; refund.id = UUID(); refund.kind = .refund; refund.refundOf = debit.id
            refund.title = "Refund to spare"; refund.accountID = spare.id; refund.accountAmount = 8
            refunded.finance!.entries = [debit, refund, unrelated]
            let keepCurrency = try merge(local: converted, cloud: refunded, base: original, choice: .local)
            let keepRefund = try merge(local: converted, cloud: refunded, base: original, choice: .cloud)
            try check(keepCurrency.finance!.entries == [unrelated] && keepRefund.finance!.entries.count == 3, "currency resolution keeps or removes expense and linked refund together")
            // Two accounts connected by a transfer must use one choice even if both currencies differ.
            var bothConverted = converted, convertedSender = sender; convertedSender.currency = "AUD"
            try bothConverted.finance!.updateAccount(convertedSender, expected: sender)
            var transferred = original; transferred.finance!.entries = [incoming, unrelated]
            for choice in [Choice.local, .cloud] {
                let resolved = try merge(local: bothConverted, cloud: transferred, base: original, choice: choice)
                try check(resolved.finance!.entries.count == (choice == .local ? 1 : 2), "connected currency changes resolve transfer exactly once")
                try check(resolved.finance!.accounts.first { $0.id == sender.id }?.currency == (choice == .local ? "AUD" : "CNY"), "connected currency changes keep both account denominations")
            }
            var independent = original; independent.finance!.entries = [unrelated]
            try check(try merge(local: converted, cloud: independent, base: original).finance!.entries == [unrelated], "currency edit merges with unrelated posting without conflict")
            var separate = original, changedSpare = spare; changedSpare.currency = "JPY"
            try separate.finance!.updateAccount(changedSpare, expected: spare)
            let separateResult = try merge(local: converted, cloud: separate, base: original)
            try check(separateResult.finance!.accounts.first { $0.id == wallet.id }?.currency == "EUR" && separateResult.finance!.accounts.first { $0.id == spare.id }?.currency == "JPY", "independent account currency edits merge without a false conflict")
            var oneSided = converted, newCurrencyDebit = debit; newCurrencyDebit.currency = "EUR"
            oneSided.finance!.entries = [newCurrencyDebit]
            try check(try bytes(merge(local: oneSided, cloud: original, base: original)) == bytes(oneSided), "one-sided currency edit and subsequent posting merge together")
            var renamed = original; renamed.finance!.accounts[0].name = "Renamed wallet"
            var ordinary = original; ordinary.finance!.entries = [debit]
            let ordinaryResult = try merge(local: renamed, cloud: ordinary, base: original)
            try check(ordinaryResult.finance!.entries == [debit] && ordinaryResult.finance!.accounts.first { $0.id == wallet.id }?.name == "Renamed wallet", "account rename and concurrent posting remain independent")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let container = try Store.make(url: url), context = container.mainContext
        try stage(base, in: context); try context.save()
        let existing = try context.fetch(FetchDescriptor<TaskItem>()).first!
        let state = CloudSyncState(); state.enabled = true; state.account = "fixture-account"; context.insert(state)
        try stage(merged, in: context); state.baseline = try bytes(merged); try context.save()
        try check(try FinanceStore.read(context)!.accounts.map(\.id) == base.finance!.accounts.map(\.id), "sync retains account display order")
        try check(try context.fetch(FetchDescriptor<TaskItem>()).first === existing, "remote import retains live object identity")
        let reopened = try Store.make(url: url)
        let savedState = try reopened.mainContext.fetch(FetchDescriptor<CloudSyncState>()).first!
        try check(try savedState.baseline == bytes(TaskBackup.capture(reopened.mainContext)), "merge base commits atomically with data")
        try check(savedState.account == "fixture-account" && savedState.enabled, "account binding survives restart")
        do {
            let cacheStore = try Store.make(url: directory.appendingPathComponent("cache.store")), cacheContext = cacheStore.mainContext
            try stage(base, in: cacheContext); try Store.save(cacheContext)
            let captured = try TaskBackup.capture(cacheContext), encoded = try bytes(captured)
            let cached = CloudSync.SnapshotCache(contextID: ObjectIdentifier(cacheContext), revision: Store.revision, baseline: encoded,
                                                local: captured, localBytes: encoded, base: try TaskBackup.decode(encoded), baselineDigest: digest(encoded))
            try check(cached.matches(cacheContext, baseline: encoded) && cached.matches(cacheContext, baseline: encoded), "unchanged sync polls reuse the same saved revision")
            try check(try cached.localBytes == bytes(TaskBackup.capture(cacheContext)) && bytes(cached.base!) == encoded && cached.baselineDigest == digest(encoded), "cached local snapshot and merge base equal fresh captures and encoding")
            try check(!cached.matches(reopened.mainContext, baseline: encoded), "reloaded or attached context cannot reuse another context's sync cache")
            try check(!cached.matches(cacheContext, baseline: nil) && !cached.matches(cacheContext, baseline: Data("different baseline".utf8)), "baseline reset or replacement invalidates sync cache")
            let cachedTask = try cacheContext.fetch(FetchDescriptor<TaskItem>()).first!
            cachedTask.notes = "Unsaved editor draft"
            try check(!cached.matches(cacheContext, baseline: encoded), "unsaved drafts cannot reuse sync snapshot cache")
            cacheContext.rollback()
            try check(cached.matches(cacheContext, baseline: encoded), "rolled back draft retains the unchanged saved snapshot")
            cachedTask.notes = "Saved after snapshot preparation"; try Store.save(cacheContext)
            try check(!cached.matches(cacheContext, baseline: encoded) && cached.localBytes != bytes(TaskBackup.capture(cacheContext)), "saved edits reject an older prepared snapshot even when baseline is unchanged")
            let fresh = try TaskBackup.capture(cacheContext), freshBytes = try bytes(fresh)
            let reset = CloudSync.SnapshotCache(contextID: ObjectIdentifier(cacheContext), revision: Store.revision, baseline: nil,
                                               local: fresh, localBytes: freshBytes, base: nil, baselineDigest: nil)
            Store.invalidateHistory()
            try check(!reset.matches(cacheContext, baseline: nil), "explicit store invalidation expires first-sync cache without a baseline")
        }
        let backup = try TaskBackup.capture(context).encoded()
        try check(!String(decoding: backup, as: UTF8.self).contains("fixture-account"), "portable exports exclude sync credentials and baseline")
        let oldURL = directory.appendingPathComponent("previous.store")
        try autoreleasepool {
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: oldURL, cloudKitDatabase: .none)])
            var legacy = merged; legacy.weekTitles = nil
            try stage(legacy, in: old.mainContext); try old.mainContext.save()
        }
        let migrated = try Store.make(url: oldURL)
        try check(try bytes(TaskBackup.capture(migrated.mainContext)) == bytes(merged), "previous task/finance store migrates without data changes")
        try check(try migrated.mainContext.fetch(FetchDescriptor<CloudSyncState>()).isEmpty, "migration never enables upload without consent")
        item.repeatRule = "daily"; item.subtasks = [Subtask(title: "Repeat step", isDone: true)]
        let tomorrow = item.scheduledAt!.addingTimeInterval(86400)
        let a = item.occurrence(at: tomorrow), b = item.occurrence(at: tomorrow)
        try check(a.id == b.id && a.subtasks == b.subtasks && a.subtasks[0].id != item.subtasks[0].id, "offline completion creates stable next-task and fresh stable subtask IDs")
        let next = TaskBackup(lists: [], tasks: [.init(a)])
        try check(try merge(local: next, cloud: TaskBackup(lists: [], tasks: [.init(b)]), base: nil).tasks.count == 1, "simultaneous repeat completion never inserts duplicate next tasks")

        // First sync must not treat empty, automatically created lists as edits made by the user.
        let defaultList = TaskBackup.ListRecord(id: TaskItem.syncIdentity("tally-default-list-0"), name: "工作",
            createdAt: Date(timeIntervalSince1970: 0), colorHex: ListColor.presets[0].hex, sortOrder: 0)
        let fresh = TaskBackup(lists: [defaultList], tasks: [])
        var customized = fresh; customized.lists[0].name = "My renamed work"
        let empty = TaskBackup(lists: [], tasks: [])
        try check(try merge(local: fresh, cloud: customized, base: nil).lists[0].name == "My renamed work", "fresh device accepts a renamed cloud default")
        var english = fresh; english.lists[0].name = "Work"
        try check(try merge(local: english, cloud: fresh, base: nil).lists[0].name == "工作", "default list localization does not conflict")
        try check(try merge(local: fresh, cloud: empty, base: nil).lists.isEmpty, "fresh device cannot resurrect deleted cloud defaults")
        try check(try merge(local: fresh, cloud: empty, base: nil, cloudExists: false).lists.count == 1, "first upload retains defaults when no cloud record exists")
        try check(try merge(local: customized, cloud: fresh, base: nil).lists[0].name == "My renamed work", "customized local default wins over unused remote seed")
        try check(try merge(local: customized, cloud: empty, base: nil).lists.count == 1, "locally renamed default is retained")
        var used = fresh; var usedTask = TaskBackup.TaskRecord(TaskItem(title: "Task using default")); usedTask.listID = defaultList.id; used.tasks = [usedTask]
        try check(try merge(local: used, cloud: empty, base: nil).lists.count == 1, "a used default and its task are retained")
        try rejects("used default vs renamed cloud default needs a choice") { _ = try merge(local: used, cloud: customized, base: nil) }
        var parent = fresh; parent.lists.append(.init(id: UUID(), name: "Child", createdAt: Date(), parentID: defaultList.id))
        try check(try merge(local: parent, cloud: empty, base: nil).lists.count == 2, "default with child list is retained")
        for field in 0..<3 {
            var edited = fresh
            if field == 0 { edited.lists[0].colorHex = "123456" }
            if field == 1 { edited.lists[0].sortOrder = 2 }
            if field == 2 { edited.lists[0].emoji = "⭐️" }
            try check(try merge(local: edited, cloud: empty, base: nil).lists.count == 1, "custom default appearance/order is retained \(field)")
        }
        var legacy = fresh; legacy.lists[0].id = UUID()
        try check(try merge(local: legacy, cloud: empty, base: nil).lists.count == 1, "legacy user list named Work is not treated as a seed")
        try check(try merge(local: fresh, cloud: empty, base: fresh).lists.isEmpty, "established sync propagates default deletion normally")
        var initialLedger = empty; initialLedger.finance = .initial
        var englishLedger = initialLedger; englishLedger.finance!.books[0].name = "Daily"
        try check(try bytes(merge(local: englishLedger, cloud: initialLedger, base: nil)) == bytes(initialLedger), "empty default book localization does not conflict")
        try check(try merge(local: initialLedger, cloud: empty, base: nil).finance == nil, "untouched default ledger does not reappear on first sync")
        try check(try merge(local: initialLedger, cloud: empty, base: nil, cloudExists: false).finance != nil, "first cloud upload retains the initial ledger")
        var editedLedger = initialLedger; editedLedger.finance!.books[0].name = "Household"
        try check(try merge(local: initialLedger, cloud: editedLedger, base: nil).finance!.books[0].name == "Household", "fresh ledger accepts customized cloud book")

        // Reproduce real offline completion on separate temporary stores, with different completion days.
        let day = Dates.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_553_600))
        let recurring = TaskItem(title: "Daily offline", scheduledAt: day.addingTimeInterval(9 * 3600))
        recurring.hasTime = true; recurring.repeatRule = "daily"
        let repeatBase = TaskBackup(lists: [], tasks: [.init(recurring)])
        let deviceA = try Store.make(url: directory.appendingPathComponent("device-a.store"))
        let deviceB = try Store.make(url: directory.appendingPathComponent("device-b.store"))
        try stage(repeatBase, in: deviceA.mainContext); try deviceA.mainContext.save()
        try stage(repeatBase, in: deviceB.mainContext); try deviceB.mainContext.save()
        let taskA = try deviceA.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        let taskB = try deviceB.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        taskA.toggleCompletion(in: deviceA.mainContext, now: day.addingTimeInterval(10 * 3600)); try deviceA.mainContext.save()
        taskB.toggleCompletion(in: deviceB.mainContext, now: day.addingTimeInterval(34 * 3600)); try deviceB.mainContext.save()
        let left = try TaskBackup.capture(deviceA.mainContext), right = try TaskBackup.capture(deviceB.mainContext)
        try check(taskA.nextOccurrenceID != taskB.nextOccurrenceID, "fixture has divergent successors from actual offline completions")
        try rejects("divergent recurrence requires whole-series choice") { _ = try merge(local: left, cloud: right, base: repeatBase) }
        for choice in [Choice.local, .cloud] {
            let resolved = try merge(local: left, cloud: right, base: repeatBase, choice: choice)
            let selected = choice == .local ? left : right
            try check(try bytes(resolved) == bytes(selected), "recurrence choice keeps only the selected complete chain")
            try check(resolved.tasks.filter { !$0.isDone && $0.deletedAt == nil }.count == 1, "resolved recurrence has one active successor")
            try check(try bytes(merge(local: resolved, cloud: resolved, base: repeatBase)) == bytes(resolved), "resolved recurrence retry is idempotent")
            let resultStore = try Store.make(url: directory.appendingPathComponent(UUID().uuidString + ".store"))
            try stage(resolved, in: resultStore.mainContext); try resultStore.mainContext.save()
            let nextTask = try resultStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first { !$0.isDone }!
            nextTask.toggleCompletion(in: resultStore.mainContext, now: day.addingTimeInterval(58 * 3600)); try resultStore.mainContext.save()
            let nextGeneration = try TaskBackup.capture(resultStore.mainContext)
            try check(nextGeneration.tasks.filter { !$0.isDone }.count == 1, "further completion cannot fork into two daily tasks")
        }
        let nextB = try deviceB.mainContext.fetch(FetchDescriptor<TaskItem>()).first { !$0.isDone }!
        nextB.title = "Edited successor on phone"
        nextB.toggleCompletion(in: deviceB.mainContext, now: day.addingTimeInterval(58 * 3600)); try deviceB.mainContext.save()
        var longerRight = try TaskBackup.capture(deviceB.mainContext)
        let independent = TaskBackup.TaskRecord(TaskItem(title: "Unrelated phone task")); longerRight.tasks.append(independent)
        let keepLeft = try merge(local: left, cloud: longerRight, base: repeatBase, choice: .local)
        try check(keepLeft.tasks.count == left.tasks.count + 1 && keepLeft.tasks.contains { $0.id == independent.id }, "losing branch descendants removed, unrelated phone task retained")
        let keepRight = try merge(local: left, cloud: longerRight, base: repeatBase, choice: .cloud)
        try check(try bytes(keepRight) == bytes(longerRight), "selected later branch retains edits and completed history")
        var deletedLeft = left; deletedLeft.tasks.removeAll()
        try rejects("deleting repeat history vs changed successor conflicts") { _ = try merge(local: deletedLeft, cloud: keepRight, base: left) }
        try check(try merge(local: deletedLeft, cloud: keepRight, base: left, choice: .local).tasks.map(\.id) == [independent.id], "base links preserve whole-chain deletion without orphan descendants")
        // Independent quick edits during a cloud upload are rebased rather than overwritten.
        var inFlightLocal = empty; inFlightLocal.tasks = [usedTask]
        inFlightLocal.lists = fresh.lists
        var cloudUpdate = inFlightLocal; cloudUpdate.tasks.append(independent)
        var newerLocal = inFlightLocal; newerLocal.tasks[0].notes = "Typed while upload was running"
        let rebased = try merge(local: newerLocal, cloud: cloudUpdate, base: inFlightLocal)
        try check(rebased.tasks.contains { $0.notes == "Typed while upload was running" } && rebased.tasks.contains { $0.id == independent.id }, "in-flight local edit and independent cloud addition both survive")
        var multiLeft = fresh, multiRight = fresh
        multiLeft.lists[0].name = "Mac list"; multiRight.lists[0].name = "Phone list"
        multiLeft.tasks = [.init(TaskItem(title: "Same task"))]; multiRight.tasks = multiLeft.tasks
        multiLeft.tasks[0].notes = "Mac note"; multiRight.tasks[0].notes = "Phone note"
        var multiBase = fresh; multiBase.tasks = multiLeft.tasks; multiBase.tasks[0].notes = "Original note"
        do {
            _ = try merge(local: multiLeft, cloud: multiRight, base: multiBase)
            throw TaskBackup.invalid("Expected conflict details")
        } catch let conflict as Conflict {
            try check(conflict.label.contains("Mac list") && conflict.label.contains("Phone list") && conflict.label.contains("Same task"), "all collections contribute named conflict details")
            try check(conflict.label.contains(L("备注", "notes")), "conflict details identify changed task fields")
        }


        let raceStore = try Store.make(url: directory.appendingPathComponent("background-edit.store"))
        try stage(inFlightLocal, in: raceStore.mainContext)
        let raceState = CloudSyncState(); raceStore.mainContext.insert(raceState)
        try Store.save(raceStore.mainContext)
        let workerRevision = Store.revision
        let liveTask = try raceStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        liveTask.notes = "Saved after worker captured its input"; try Store.save(raceStore.mainContext)
        let workerBytes = try bytes(cloudUpdate)
        try check(try !commit(cloudUpdate, changed: true, baseline: workerBytes, state: raceState,
                              revision: workerRevision, in: raceStore.mainContext), "stale background result cannot commit over a newer saved edit")
        try check(liveTask.notes == "Saved after worker captured its input" && raceState.baseline == nil,
                  "rejected background result changes neither user data nor sync baseline")
        let draftRevision = Store.revision
        liveTask.notes = "Unsaved draft"
        try check(try !commit(cloudUpdate, changed: true, baseline: workerBytes, state: raceState,
                              revision: draftRevision, in: raceStore.mainContext), "background result cannot commit over an unsaved edit")
        try check(liveTask.notes == "Unsaved draft", "rejected background result leaves unsaved text intact")
        raceStore.mainContext.rollback()
        let currentSnapshot = try TaskBackup.capture(raceStore.mainContext)
        let refreshed = try merge(local: currentSnapshot, cloud: cloudUpdate, base: inFlightLocal)
        try check(try commit(refreshed, changed: true, baseline: workerBytes, state: raceState,
                             revision: Store.revision, in: raceStore.mainContext), "fresh rebase commits after retry")
        try check(liveTask.notes == "Saved after worker captured its input" && raceState.baseline == workerBytes &&
                  (try raceStore.mainContext.fetchCount(FetchDescriptor<TaskItem>())) == 2, "successful retry preserves new local edit, remote task and uploaded baseline")

        print("SYNC PASS: \(count) merge and storage checks")
        return count
    }
}

extension CloudSync {
    /// Called only with the performance check's disposable store; no CloudKit or user data access.
    @MainActor static func snapshotPerformance(in context: ModelContext) throws {
        let local = try TaskBackup.capture(context), baseline = try CloudMerge.bytes(local), digest = CloudMerge.digest(baseline)
        let cached = SnapshotCache(contextID: ObjectIdentifier(context), revision: Store.revision, baseline: baseline,
                                   local: local, localBytes: baseline, base: try TaskBackup.decode(baseline, allowLargeFile: true), baselineDigest: digest)
        var uncached: [Double] = [], reused: [Double] = []
        for _ in 0..<3 {
            var start = ProcessInfo.processInfo.systemUptime
            let captured = try TaskBackup.capture(context), encoded = try CloudMerge.bytes(captured)
            let base = try TaskBackup.decode(baseline, allowLargeFile: true), baselineDigest = CloudMerge.digest(baseline)
            uncached.append(ProcessInfo.processInfo.systemUptime - start)
            guard encoded == cached.localBytes, try CloudMerge.bytes(base) == baseline, baselineDigest == cached.baselineDigest else {
                throw TaskBackup.invalid("Sync cache differs from uncached preparation")
            }
            start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1000 {
                guard cached.matches(context, baseline: baseline), cached.localBytes == baseline, cached.baselineDigest == digest else {
                    throw TaskBackup.invalid("Unchanged sync poll did not reuse its prepared snapshot")
                }
            }
            reused.append((ProcessInfo.processInfo.systemUptime - start) / 1000)
        }
        print(String(format: "PERF unchanged sync snapshot, %d tasks/%d entries: uncached %.3f ms/poll, cached %.6f ms/poll (median of 3)",
                     local.tasks.count, local.finance?.entries.count ?? 0, uncached.sorted()[1] * 1000, reused.sorted()[1] * 1000))
    }
}
