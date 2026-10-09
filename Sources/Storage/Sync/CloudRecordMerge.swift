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
        func field<T: Equatable>(_ path: WritableKeyPath<TaskBackup.TaskRecord, T>) throws {
            result[keyPath: path] = try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                                             label: label, choice: choice, report: report, review: review, key: SyncChanges.key("task", local.id))
        }
        try field(\.title); try field(\.notes); try field(\.priority)
        try field(\.listID); try field(\.subtasks)
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
        if local == cloud || local == base || cloud == base || local.deletedAt != base.deletedAt || cloud.deletedAt != base.deletedAt {
            return try value(local, cloud, base, label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id))
        }
        var left = local, right = cloud
        func field<T: Equatable>(_ path: WritableKeyPath<MoneyEntry, T>) throws -> T {
            left[keyPath: path] = base[keyPath: path]; right[keyPath: path] = base[keyPath: path]
            return try value(local[keyPath: path], cloud[keyPath: path], base[keyPath: path],
                             label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id))
        }
        let title = try field(\.title), notes = try field(\.notes), tags = try field(\.tags)
        var result = try value(left, right, base, label: label, choice: choice, report: report, review: review, key: SyncChanges.key("entry", local.id))
        result.title = title; result.notes = notes; result.tags = tags
        return result
    }
}
