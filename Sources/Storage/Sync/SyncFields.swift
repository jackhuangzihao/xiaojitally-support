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
        var repeatTimeZoneID: String?

        init(_ task: TaskBackup.TaskRecord) {
            scheduledAt = task.scheduledAt; hasTime = task.hasTime; endAt = task.endAt
            dueAt = task.dueAt; dueHasTime = task.dueHasTime; reminderAt = task.reminderAt
            reminderKind = task.reminderKind; reminderNeedsAttention = task.reminderNeedsAttention
            repeatAnchorDay = task.repeatAnchorDay
            repeatTimeZoneID = task.repeatTimeZoneID
        }
        func apply(to task: inout TaskBackup.TaskRecord) {
            task.scheduledAt = scheduledAt; task.hasTime = hasTime; task.endAt = endAt
            task.dueAt = dueAt; task.dueHasTime = dueHasTime; task.reminderAt = reminderAt
            task.reminderKind = reminderKind; task.reminderNeedsAttention = reminderNeedsAttention
            task.repeatAnchorDay = repeatAnchorDay
            task.repeatTimeZoneID = repeatTimeZoneID
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
        case "task": ["title", "notes", "priority", "listID", "timing", "completion", "structure", "lifecycle", "subtasks", "subtaskOrder"]
        case "list": ["name", "colorHex", "emoji", "sortOrder", "parentID", "createdAt"]
        case "week": ["title"]
        case "entry": ["title", "notes", "tags", "financial"]
        default: []
        }
    }

    static func allows(_ field: String, kind: String) -> Bool {
        if names(for: kind).contains(field) { return true }
        guard kind == "task" else { return false }
        let parts = field.split(separator: ":", omittingEmptySubsequences: false)
        return (parts.count == 2 || parts.count == 3) && parts.first == "subtask"
            && UUID(uuidString: String(parts[1])) != nil
            && (parts.count == 2 || ["title", "done"].contains(String(parts[2])))
    }
    static func complete(_ hashes: [String: String], retaining names: [String]) throws -> [String: String] {
        var result = hashes
        let absent = try SyncChanges.fingerprint(Optional<String>.none)
        for name in names where name.hasPrefix("subtask:") && result[name] == nil { result[name] = absent }
        return result
    }
    private struct Structure: Codable {
        let createdAt: Date
        let repeatRule: String
        let repeatUntil: Date?
        let nextOccurrenceID: UUID?
        let deletedAt: Date?
        init(_ task: TaskBackup.TaskRecord) {
            createdAt = task.createdAt; repeatRule = task.repeatRule; repeatUntil = task.repeatUntil
            nextOccurrenceID = task.nextOccurrenceID; deletedAt = task.deletedAt
        }
    }
    private struct Lifecycle: Codable {
        let timing: Timing
        let completion: Completion
        let structure: Structure
        init(_ task: TaskBackup.TaskRecord) {
            timing = Timing(task); completion = Completion(task); structure = Structure(task)
        }
    }
    static func hashes(_ task: TaskBackup.TaskRecord) throws -> [String: String] {
        var result = try ["title": SyncChanges.fingerprint(task.title), "notes": SyncChanges.fingerprint(task.notes),
             "priority": SyncChanges.fingerprint(task.priority), "listID": SyncChanges.fingerprint(task.listID),
             "timing": SyncChanges.fingerprint(Timing(task)), "completion": SyncChanges.fingerprint(Completion(task)),
             "structure": SyncChanges.fingerprint(Structure(task)), "lifecycle": SyncChanges.fingerprint(Lifecycle(task)),
             "subtasks": SyncChanges.fingerprint(task.subtasks), "subtaskOrder": SyncChanges.fingerprint(task.subtasks.map(\.id))]
        for step in task.subtasks {
            let key = "subtask:" + step.id.uuidString
            result[key] = try SyncChanges.fingerprint(step)
            result[key + ":title"] = try SyncChanges.fingerprint(step.title)
            result[key + ":done"] = try SyncChanges.fingerprint(step.isDone)
        }
        return result
    }
    static func hashes(_ list: TaskBackup.ListRecord) throws -> [String: String] {
        try ["name": SyncChanges.fingerprint(list.name), "colorHex": SyncChanges.fingerprint(list.colorHex),
             "emoji": SyncChanges.fingerprint(list.emoji), "sortOrder": SyncChanges.fingerprint(list.sortOrder),
             "parentID": SyncChanges.fingerprint(list.parentID), "createdAt": SyncChanges.fingerprint(list.createdAt)]
    }
    static func hashes(_ week: TaskBackup.WeekTitleRecord) throws -> [String: String] {
        try ["title": SyncChanges.fingerprint(week.title)]
    }
    static func hashes(_ entry: MoneyEntry) throws -> [String: String] {
        var financial = entry; financial.title = ""; financial.notes = ""; financial.tags = ""
        return try ["title": SyncChanges.fingerprint(entry.title), "notes": SyncChanges.fingerprint(entry.notes),
             "tags": SyncChanges.fingerprint(entry.tags), "financial": SyncChanges.fingerprint(financial)]
    }

    static func snapshot(_ snapshot: TaskBackup) throws -> [String: [String: String]] {
        var fields: [String: [String: String]] = [:]
        for task in snapshot.tasks {
            let key = SyncChanges.key("task", task.id)
            fields[key] = try complete(hashes(task), retaining: Array(snapshot.syncChanges?[key]?.fields?.keys ?? [:].keys))
        }
        for list in snapshot.lists { fields[SyncChanges.key("list", list.id)] = try hashes(list) }
        for week in snapshot.weekTitles ?? [] { fields[SyncChanges.key("week", week.id)] = try hashes(week) }
        for entry in snapshot.finance?.entries ?? [] { fields[SyncChanges.key("entry", entry.id)] = try hashes(entry) }
        return fields
    }
}
