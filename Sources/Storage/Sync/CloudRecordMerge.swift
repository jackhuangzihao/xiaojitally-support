import Foundation

extension CloudMerge {
    static func taskStructureMatches(_ rows: [TaskBackup.TaskRecord], _ base: [TaskBackup.TaskRecord]) -> Bool {
        rows.count == base.count && zip(rows, base).allSatisfy {
            $0.id == $1.id && $0.nextOccurrenceID == $1.nextOccurrenceID && $0.deletedAt == $1.deletedAt
        }
    }

    /// Dates, reminders, completion and recurrence stay together across the entire repeat chain.
    static func taskLifecycle(_ task: TaskBackup.TaskRecord, base: TaskBackup.TaskRecord) -> TaskBackup.TaskRecord {
        var result = task
        result.title = base.title; result.notes = base.notes; result.priority = base.priority
        result.listID = base.listID; result.subtasks = base.subtasks
        return result
    }

    /// Add independent fields to the lifecycle already selected for the whole chain.
    static func taskFields(_ local: TaskBackup.TaskRecord, _ cloud: TaskBackup.TaskRecord, _ base: TaskBackup.TaskRecord,
                           lifecycle: TaskBackup.TaskRecord,
                           choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> TaskBackup.TaskRecord {
        let label = L("任务", "Task") + "\n" + taskDifference(local, cloud)
        var result = lifecycle
        func field<T: Equatable>(_ name: String, _ path: WritableKeyPath<TaskBackup.TaskRecord, T>) throws {
            result[keyPath: path] = try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                                             label: label, choice: choice, report: report, review: review, key: SyncChanges.key("task", local.id), field: name)
        }
        try field("title", \.title); try field("notes", \.notes); try field("priority", \.priority)
        try field("listID", \.listID)
        result.subtasks = try subtaskFields(local.subtasks, cloud.subtasks, base.subtasks,
            label: label, key: SyncChanges.key("task", local.id), choice: choice, report: report, review: review)
        return result
    }

    /// Monetary fields, posting status and linked records must not be assembled from competing edits.
    static func entryFields(_ local: MoneyEntry, _ cloud: MoneyEntry, _ base: MoneyEntry,
                            choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview? = nil) throws -> MoneyEntry {
        func describe(_ entry: MoneyEntry) -> String {
            entry.title + " · " + entry.currency + " " + NSDecimalNumber(decimal: entry.amount).stringValue
        }
        let label = L("账单", "Entry") + "\n" + L("本机：", "Local: ") + describe(local) + "\n" +
            L("云端：", "Cloud: ") + describe(cloud)
        if local == cloud || local.deletedAt != base.deletedAt || cloud.deletedAt != base.deletedAt {
            return try value(local, cloud, base, label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id))
        }
        var left = local, right = cloud
        func field<T: Equatable>(_ name: String, _ path: WritableKeyPath<MoneyEntry, T>) throws -> T {
            left[keyPath: path] = base[keyPath: path]; right[keyPath: path] = base[keyPath: path]
            return try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                             label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id), field: name)
        }
        let title = try field("title", \.title), notes = try field("notes", \.notes), tags = try field("tags", \.tags)
        var result = try value(left, right, base, label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id), field: "financial")
        result.title = title; result.notes = notes; result.tags = tags
        return result
    }
}

extension CloudMerge {
    /// Standalone completion and time changes can coexist; repeating-task lifecycle remains atomic.
    static func ordinaryTaskLifecycle(_ local: TaskBackup.TaskRecord, _ cloud: TaskBackup.TaskRecord,
                                      _ base: TaskBackup.TaskRecord, choice: Choice?,
                                      report: @escaping (String) -> Void, review: ConflictReview?) throws -> TaskBackup.TaskRecord {
        let key = SyncChanges.key("task", local.id)
        let label = L("任务时间与完成状态", "Task schedule and completion") + "\n" + taskDifference(local, cloud)
        let timing = try value(SyncFields.Timing(local), SyncFields.Timing(cloud), SyncFields.Timing(base),
            label: label, choice: choice, report: report, review: review, key: key, field: "timing")
        let completion = try value(SyncFields.Completion(local), SyncFields.Completion(cloud), SyncFields.Completion(base),
            label: label, choice: choice, report: report, review: review, key: key, field: "completion")
        var left = taskLifecycle(local, base: base), right = taskLifecycle(cloud, base: base)
        SyncFields.Timing(base).apply(to: &left); SyncFields.Timing(base).apply(to: &right)
        SyncFields.Completion(base).apply(to: &left); SyncFields.Completion(base).apply(to: &right)
        var result = try value(left, right, base, label: label, choice: choice, report: report, review: review, key: key, field: "structure")
        timing.apply(to: &result); completion.apply(to: &result)
        return result
    }

    static func subtaskFields(_ local: [Subtask], _ cloud: [Subtask], _ base: [Subtask], label: String, key: String,
                              choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview?) throws -> [Subtask] {
        if local == cloud { return local }
        let causality = review?.automatic?.revisions
        if let selected = causality?.causalChoice(keys: [key], field: "subtasks") { return selected == .local ? local : cloud }
        if local == base && (causality?.unchanged(.local, keys: [key], field: "subtasks") ?? true) { return cloud }
        if cloud == base && (causality?.unchanged(.cloud, keys: [key], field: "subtasks") ?? true) { return local }
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        var merged: [UUID: Subtask] = [:]
        for id in Set(l.keys).union(r.keys).union(b.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            if let left = l[id], let right = r[id], let original = b[id] {
                var result = original
                let field = "subtask:" + id.uuidString
                result.title = try value(left.title, right.title, original.title, label: label, choice: choice,
                                         report: report, review: review, key: key, field: field + ":title")
                result.isDone = try value(left.isDone, right.isDone, original.isDone, label: label, choice: choice,
                                          report: report, review: review, key: key, field: field + ":done")
                merged[id] = result
            } else {
                merged[id] = try value(l[id], r[id], b[id], label: label, choice: choice, report: report, review: review, key: key, field: "subtask:" + id.uuidString)
            }
        }
        let survivingBase = Set(b.keys).intersection(merged.keys)
        let baseOrder = base.map(\.id).filter(survivingBase.contains)
        func retainedOrder(_ rows: [Subtask]) -> [UUID] {
            var ids = rows.map(\.id).filter(survivingBase.contains)
            for (index, id) in baseOrder.enumerated() where !ids.contains(id) {
                let next = baseOrder.dropFirst(index + 1).first { ids.contains($0) }
                ids.insert(id, at: next.flatMap { ids.firstIndex(of: $0) } ?? ids.count)
            }
            return ids
        }
        // Keeping an edited row after deletion review must also keep its original position.
        let order = try value(retainedOrder(local), retainedOrder(cloud), baseOrder, label: label, choice: choice,
                              report: report, review: review, key: key, field: "subtaskOrder")
        let added = Set(merged.keys).subtracting(order)
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        func insertionSlots(_ rows: [Subtask]) -> [UUID: Int] {
            // Insertions follow their surviving predecessor through a reorder; leading ones precede their next anchor.
            var slot = rows.lazy.compactMap { positions[$0.id] }.first ?? order.count
            var slots: [UUID: Int] = [:]
            for row in rows {
                if let position = positions[row.id] { slot = position + 1 }
                else if added.contains(row.id) { slots[row.id] = slot }
            }
            return slots
        }
        let leftSlots = insertionSlots(local), rightSlots = insertionSlots(cloud)
        var slots: [Int: Set<UUID>] = [:]
        for id in added.sorted(by: { $0.uuidString < $1.uuidString }) {
            let slot = try value(leftSlots[id], rightSlots[id], nil, label: label, choice: choice,
                                 report: report, review: review, key: key, field: "subtaskOrder") ?? order.count
            slots[slot, default: []].insert(id)
        }
        var result: [UUID] = []
        for slot in 0...order.count {
            if let additions = slots[slot] {
                let left = local.map(\.id).filter(additions.contains), right = cloud.map(\.id).filter(additions.contains)
                result += try orderedSubtaskAdditions(additions, local: left, cloud: right) {
                    try value(left, right, [], label: label, choice: choice, report: report, review: review, key: key, field: "subtaskOrder")
                }
            }
            if slot < order.count { result.append(order[slot]) }
        }
        let resultPositions = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($1, $0) })
        let insertedSequences = [local, cloud].map { $0.map(\.id).filter(added.contains) }
        if insertedSequences.contains(where: { sequence in
            let positions = sequence.compactMap { resultPositions[$0] }
            return zip(positions, positions.dropFirst()).contains { $0 > $1 }
        }) {
            // Moving anchors can contradict the order of new steps. Review that order rather than silently reversing it.
            let preferred = try value(local.map(\.id).filter { merged[$0] != nil },
                                      cloud.map(\.id).filter { merged[$0] != nil }, baseOrder,
                                      label: label, choice: choice, report: report, review: review, key: key, field: "subtaskOrder")
            let selected = Set(preferred)
            result = preferred + result.filter { !selected.contains($0) }
        }
        return result.compactMap { merged[$0] }
    }

    private static func orderedSubtaskAdditions(_ added: Set<UUID>, local: [UUID], cloud: [UUID],
                                                resolve: () throws -> [UUID]) rethrows -> [UUID] {
        var edges: [UUID: Set<UUID>] = [:]
        for sequence in [local, cloud] {
            for (before, after) in zip(sequence, sequence.dropFirst()) { edges[after, default: []].insert(before) }
        }
        var remaining = added, additions: [UUID] = []
        while !remaining.isEmpty {
            let available = remaining.filter { (edges[$0] ?? []).isDisjoint(with: remaining) }.sorted { $0.uuidString < $1.uuidString }
            guard let next = available.first else {
                let preferred = try resolve()
                additions = preferred + added.subtracting(preferred).sorted { $0.uuidString < $1.uuidString }
                break
            }
            additions.append(next); remaining.remove(next)
        }
        return additions
    }

    static func listFields(_ local: TaskBackup.ListRecord, _ cloud: TaskBackup.ListRecord, _ base: TaskBackup.ListRecord,
                           choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview?) throws -> TaskBackup.ListRecord {
        let key = SyncChanges.key("list", local.id), label = L("清单：", "List: ") + local.name + " / " + cloud.name
        var result = base
        func field<T: Equatable>(_ name: String?, _ path: WritableKeyPath<TaskBackup.ListRecord, T>) throws {
            result[keyPath: path] = try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                label: label, choice: choice, report: report, review: review, key: key, field: name)
        }
        try field("name", \.name); try field("colorHex", \.colorHex); try field("emoji", \.emoji)
        try field("sortOrder", \.sortOrder); try field("parentID", \.parentID); try field("createdAt", \.createdAt)
        return result
    }

    static func weekFields(_ local: TaskBackup.WeekTitleRecord, _ cloud: TaskBackup.WeekTitleRecord,
                           _ base: TaskBackup.WeekTitleRecord, choice: Choice?, report: @escaping (String) -> Void,
                           review: ConflictReview?) throws -> TaskBackup.WeekTitleRecord {
        var result = base
        result.title = try value(local.title, cloud.title, base.title, label: L("周标题：", "Week title: ") + base.week,
            choice: choice, report: report, review: review, key: SyncChanges.key("week", base.id), field: "title")
        return result
    }
}

extension CloudMerge {
    /// Next date and repeat rules form one schedule. A concurrent reschedule and confirmation must not
    /// splice two schedules together; recorded entries are merged separately and remain recorded.
    static func recurringFields(_ local: MoneyRecurring, _ cloud: MoneyRecurring, _ base: MoneyRecurring,
                                choice: Choice?, report: @escaping (String) -> Void, review: ConflictReview?) throws -> MoneyRecurring {
        let key = SyncChanges.key("recurring", local.id)
        let label = L("周期账单：", "Recurring bill: ") + local.title + " / " + cloud.title
        // Amounts and the account, and the rule and its day, only make sense together; each set merges as one.
        struct Money: Equatable { var kind: MoneyKind, amount: Decimal, currency: String, accountID: UUID?, accountAmount: Decimal, baseAmount: Decimal? }
        struct Schedule: Equatable { var rule: String, anchorDay: Int, until: Date?, repeatTimeZoneID: String?, nextDate: Date }
        func money(_ b: MoneyRecurring) -> Money { Money(kind: b.kind, amount: b.amount, currency: b.currency, accountID: b.accountID, accountAmount: b.accountAmount, baseAmount: b.baseAmount) }
        func schedule(_ b: MoneyRecurring) -> Schedule { Schedule(rule: b.rule, anchorDay: b.anchorDay, until: b.until, repeatTimeZoneID: b.repeatTimeZoneID, nextDate: b.nextDate) }
        var result = base
        func field<T: Equatable>(_ path: WritableKeyPath<MoneyRecurring, T>) throws {
            result[keyPath: path] = try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                                              label: label, choice: choice, report: report, review: review, key: key)
        }
        try field(\.title); try field(\.bookID); try field(\.categoryID); try field(\.notes); try field(\.tags)
        let amounts = try value(money(local), money(cloud), money(base), label: label, choice: choice, report: report, review: review, key: key)
        result.kind = amounts.kind; result.amount = amounts.amount; result.currency = amounts.currency
        result.accountID = amounts.accountID; result.accountAmount = amounts.accountAmount; result.baseAmount = amounts.baseAmount
        let rules = try value(schedule(local), schedule(cloud), schedule(base), label: label, choice: choice, report: report, review: review, key: key)
        result.rule = rules.rule; result.anchorDay = rules.anchorDay; result.until = rules.until; result.repeatTimeZoneID = rules.repeatTimeZoneID
        result.nextDate = rules.nextDate
        return result
    }
}
