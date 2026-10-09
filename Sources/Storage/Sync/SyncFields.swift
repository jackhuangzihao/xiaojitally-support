import Foundation

/// Only independent, ordinary fields receive automatic per-field conflict resolution.
enum SyncFields {
    struct Timing: Codable, Equatable {
        var scheduledAt: Date?
        var hasTime: Bool
        var endAt: Date?
        var dueAt: Date?
        var dueHasTime: Bool
        var reminderAt: Date?
        var reminderKind: String
        var reminderNeedsAttention: Bool
        var repeatAnchorDay: Int

        init(_ task: TaskBackup.TaskRecord) {
            scheduledAt = task.scheduledAt; hasTime = task.hasTime; endAt = task.endAt
            dueAt = task.dueAt; dueHasTime = task.dueHasTime; reminderAt = task.reminderAt
            reminderKind = task.reminderKind; reminderNeedsAttention = task.reminderNeedsAttention
            repeatAnchorDay = task.repeatAnchorDay
        }
        func apply(to task: inout TaskBackup.TaskRecord) {
            task.scheduledAt = scheduledAt; task.hasTime = hasTime; task.endAt = endAt
            task.dueAt = dueAt; task.dueHasTime = dueHasTime; task.reminderAt = reminderAt
            task.reminderKind = reminderKind; task.reminderNeedsAttention = reminderNeedsAttention
            task.repeatAnchorDay = repeatAnchorDay
        }
    }

    struct Completion: Codable, Equatable {
        var isDone: Bool
        var completedAt: Date?

        init(_ task: TaskBackup.TaskRecord) {
            isDone = task.isDone; completedAt = task.completedAt
        }
        func apply(to task: inout TaskBackup.TaskRecord) {
            task.isDone = isDone; task.completedAt = completedAt
        }
    }

    static func names(for kind: String) -> Set<String> {
        switch kind {
        case "task": ["title", "notes", "priority", "listID", "timing", "completion"]
        case "list": ["name", "colorHex", "emoji", "sortOrder"]
        case "week": ["title"]
        case "entry": ["title", "notes", "tags"]
        default: []
        }
    }

    static func hashes(_ task: TaskBackup.TaskRecord) throws -> [String: String] {
        try ["title": SyncChanges.fingerprint(task.title), "notes": SyncChanges.fingerprint(task.notes),
             "priority": SyncChanges.fingerprint(task.priority), "listID": SyncChanges.fingerprint(task.listID),
             "timing": SyncChanges.fingerprint(Timing(task)), "completion": SyncChanges.fingerprint(Completion(task))]
    }
    static func hashes(_ list: TaskBackup.ListRecord) throws -> [String: String] {
        try ["name": SyncChanges.fingerprint(list.name), "colorHex": SyncChanges.fingerprint(list.colorHex),
             "emoji": SyncChanges.fingerprint(list.emoji), "sortOrder": SyncChanges.fingerprint(list.sortOrder)]
    }
    static func hashes(_ week: TaskBackup.WeekTitleRecord) throws -> [String: String] {
        try ["title": SyncChanges.fingerprint(week.title)]
    }
    static func hashes(_ entry: MoneyEntry) throws -> [String: String] {
        try ["title": SyncChanges.fingerprint(entry.title), "notes": SyncChanges.fingerprint(entry.notes),
             "tags": SyncChanges.fingerprint(entry.tags)]
    }

    static func snapshot(_ snapshot: TaskBackup) throws -> [String: [String: String]] {
        var fields: [String: [String: String]] = [:]
        for task in snapshot.tasks { fields[SyncChanges.key("task", task.id)] = try hashes(task) }
        for list in snapshot.lists { fields[SyncChanges.key("list", list.id)] = try hashes(list) }
        for week in snapshot.weekTitles ?? [] { fields[SyncChanges.key("week", week.id)] = try hashes(week) }
        for entry in snapshot.finance?.entries ?? [] { fields[SyncChanges.key("entry", entry.id)] = try hashes(entry) }
        return fields
    }
}
