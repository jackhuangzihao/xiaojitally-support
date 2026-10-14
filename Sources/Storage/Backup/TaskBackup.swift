import Foundation
import SwiftData
import OSLog

/// Portable, versioned local backup. No settings, credentials or notification permission are imported.
struct TaskBackup: Codable {
    var format = "jianshi-backup"
    // Old clients reject this version before merging, instead of silently removing new metadata.
    var version = 14
    var finance: FinanceData? = nil
    var weekTitles: [WeekTitleRecord]? = nil
    var syncChanges: SyncChanges.Revisions? = nil
    var createdAt = Date()
    var lists: [ListRecord]
    var tasks: [TaskRecord]
    struct WeekTitleRecord: Codable, Equatable {
        var week: String
        var title: String
        var id: UUID { TaskItem.syncIdentity("tally-week-title:" + week) }
    }
    struct ListRecord: Codable, Equatable { var id: UUID; var name: String; var createdAt: Date; var parentID: UUID? = nil; var colorHex: String? = nil; var sortOrder: Double? = nil; var emoji: String? = nil }
    struct TaskRecord: Codable, Equatable {
        var id: UUID; var title: String; var notes: String
        var endAt: Date?
        var scheduledAt: Date?; var hasTime: Bool; var dueAt: Date?; var dueHasTime: Bool
        var priority: Int; var isDone: Bool; var completedAt: Date?; var createdAt: Date
        var reminderAt: Date?; var reminderKind: String; var reminderNeedsAttention: Bool
        var repeatRule: String; var repeatAnchorDay: Int; var nextOccurrenceID: UUID?
        var repeatUntil: Date? = nil
        var repeatTimeZoneID: String? = nil
        var deletedAt: Date?; var subtasks: [Subtask]; var listID: UUID?

        init(_ task: TaskItem) {
            endAt = task.endAt
            id = task.id; title = task.title; notes = task.notes
            scheduledAt = task.scheduledAt; hasTime = task.hasTime; dueAt = task.dueAt; dueHasTime = task.dueHasTime
            priority = task.priority; isDone = task.isDone; completedAt = task.completedAt; createdAt = task.createdAt
            reminderAt = task.reminderAt; reminderKind = task.reminderKind; reminderNeedsAttention = task.reminderNeedsAttention
            repeatRule = task.repeatRule; repeatAnchorDay = task.repeatAnchorDay; nextOccurrenceID = task.nextOccurrenceID
            repeatUntil = task.repeatUntil
            repeatTimeZoneID = task.repeatTimeZoneID
            deletedAt = task.deletedAt; subtasks = task.subtasks; listID = task.list?.id
        }
        func model(list: TaskList?) -> TaskItem {
            let task = TaskItem(title: title, scheduledAt: scheduledAt, list: list)
            apply(to: task, list: list)
            task.reminderNeedsAttention = reminderNeedsAttention || (!isDone && reminderAt.map { $0 <= Date() } == true)
            return task
        }
        func apply(to task: TaskItem, list: TaskList?) {
            task.title = title; task.scheduledAt = scheduledAt; task.list = list
            task.endAt = endAt
            task.id = id; task.notes = notes; task.hasTime = hasTime; task.dueAt = dueAt; task.dueHasTime = dueHasTime
            task.priority = priority; task.isDone = isDone; task.completedAt = completedAt; task.createdAt = createdAt
            task.reminderAt = reminderAt; task.reminderKind = reminderKind
            task.reminderNeedsAttention = reminderNeedsAttention
            task.repeatRule = repeatRule; task.repeatAnchorDay = repeatAnchorDay; task.nextOccurrenceID = nextOccurrenceID
            task.repeatUntil = repeatRule == "none" ? nil : repeatUntil
            task.repeatTimeZoneID = repeatTimeZoneID
            task.deletedAt = deletedAt; task.subtasks = subtasks
        }
        var nextCopyDate: Date? {
            guard let start = scheduledAt ?? dueAt else { return nil }
            if scheduledAt != nil ? hasTime : dueHasTime { return endAt ?? start.addingTimeInterval(3600) }
            return Dates.calendar.date(byAdding: .day, value: 1, to: Dates.calendar.startOfDay(for: start))
        }
        /// A copy is an independent open task, never another branch of the original repeat series.
        func duplicate(at moment: Date, timed: Bool, list: TaskList?) -> TaskItem {
            let task = model(list: nil)
            task.id = UUID(); task.createdAt = Date(); task.isDone = false; task.completedAt = nil; task.deletedAt = nil
            task.subtasks = subtasks.map { Subtask(title: $0.title) }
            task.repeatRule = "none"; task.repeatUntil = nil; task.repeatTimeZoneID = nil; task.nextOccurrenceID = nil
            let originalDate = task.calendarDate
            let sourceTimed = task.clockDate != nil
            let preset = task.resolvedReminderPreset
            _ = TaskMove(task, to: moment, kind: timed ? .timed : .allDay).apply(to: task, shiftDeadline: true)
            if preset == .custom, let reminderAt, let originalDate, let newDate = task.calendarDate {
                if timed && sourceTimed { task.reminderAt = reminderAt.addingTimeInterval(newDate.timeIntervalSince(originalDate)) }
                else {
                    let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: originalDate), to: Dates.calendar.startOfDay(for: newDate)).day ?? 0
                    task.reminderAt = Dates.calendar.date(byAdding: .day, value: days, to: reminderAt)
                }
            }
            task.repeatAnchorDay = 0
            task.reminderNeedsAttention = task.reminderRequiresAttention()
            task.list = list
            return task
        }
    }
    static func invalid(_ message: String) -> NSError { NSError(domain: "Jianshi.Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func validate() throws {
        guard format == "jianshi-backup", (1...14).contains(version) else { throw Self.invalid(L("不是受支持的小记备份版本，请更新 App 后重试。", "Unsupported Tally backup format or version. Update the app and retry.")) }
        guard tasks.allSatisfy({ $0.repeatTimeZoneID == nil || (version >= 14 && Dates.recurrenceCalendar(timeZoneID: $0.repeatTimeZoneID) != nil) }) else {
            throw Self.invalid(L("重复时区无效或数据版本过旧。", "Invalid recurrence time zone or outdated data format."))
        }
        try finance?.validate()
        try SyncChanges.validate(syncChanges)
        if let weekTitles {
            guard Set(weekTitles.map(\.week)).count == weekTitles.count,
                  weekTitles.allSatisfy({ CalendarWeekTitle.validKey($0.week) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 80 }) else {
                throw Self.invalid(L("周标题备份无效。", "Invalid calendar week titles."))
            }
        }
        let listIDs = Set(lists.map(\.id)), taskIDs = Set(tasks.map(\.id))
        guard listIDs.count == lists.count, taskIDs.count == tasks.count else { throw Self.invalid(L("备份含重复的项目编号。", "Backup contains duplicate identifiers.")) }
        try ListTree.validate(Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.parentID) }))
        let dates = [createdAt] + lists.map(\.createdAt) + tasks.flatMap { [$0.endAt, $0.scheduledAt, $0.dueAt, $0.completedAt, $0.createdAt, $0.reminderAt, $0.deletedAt, $0.repeatUntil].compactMap { $0 } }
        guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && (-62135596800...253402300799).contains($0.timeIntervalSince1970) }) else { throw Self.invalid(L("备份含无效日期。", "Backup contains invalid dates.")) }
        guard lists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 && ($0.colorHex.map(TaskList.validColor) ?? true) && ($0.sortOrder?.isFinite ?? true) && ($0.emoji.map(TaskList.validEmoji) ?? true) }),
              tasks.allSatisfy({ task in
                  !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.title.count <= 160 && task.notes.count <= 10000
                  && (task.endAt.map { end in task.hasTime && task.scheduledAt.map { end > $0 } == true } ?? true)
                  && (0...2).contains(task.priority) && (0...31).contains(task.repeatAnchorDay)
                  && RepeatRule.isValid(task.repeatRule)
                  && (task.reminderKind == "legacy" || ReminderPreset(rawValue: task.reminderKind) != nil)
                  && (task.listID.map { listIDs.contains($0) } ?? true) && task.nextOccurrenceID != task.id
                  && task.subtasks.count <= 100 && Set(task.subtasks.map(\.id)).count == task.subtasks.count
                  && task.subtasks.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 160 }
              }) else { throw Self.invalid(L("备份数据无效，未更改任何任务。", "Invalid backup data. No tasks were changed.")) }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return data
    }
    static let largeFileThreshold = 20 * 1024 * 1024
    static func decode(_ data: Data, allowLargeFile: Bool = false) throws -> Self {
        guard allowLargeFile || data.count <= largeFileThreshold else { throw invalid(L("备份较大，请确认后继续读取。", "This is a large backup. Confirm before reading it.")) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var result = try decoder.decode(Self.self, from: data)
        result.finance?.migrateLegacyRecurring()
        try result.validate(); return result
    }
    @MainActor static func capture(_ context: ModelContext, includeFinance: Bool = true) throws -> Self {
        Self(finance: includeFinance ? try FinanceStore.read(context) : nil,
             weekTitles: try context.fetch(FetchDescriptor<CalendarWeekTitle>()).map { WeekTitleRecord(week: $0.week, title: $0.title) },
             syncChanges: try SyncChanges.read(context),
             lists: try context.fetch(FetchDescriptor<TaskList>()).map { ListRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID, colorHex: $0.colorHex, sortOrder: $0.sortOrder, emoji: $0.emoji) },
             tasks: try context.fetch(FetchDescriptor<TaskItem>()).map(TaskRecord.init))
    }
    /// Validate the resulting collection, not just the incoming file, before any mutation.
    func merging(into existing: Self, replace: Bool) throws -> Self {
        try validate()
        var result: Self
        if replace {
            result = self
            if finance == nil { result.finance = existing.finance }
            if weekTitles == nil { result.weekTitles = existing.weekTitles }
        }
        else {
            let listIDs = Set(existing.lists.map(\.id)), taskIDs = Set(existing.tasks.map(\.id))
            result = Self(finance: try existing.finance.map { current in try finance.map { try current.merging($0) } ?? current } ?? finance, lists: existing.lists + lists.filter { !listIDs.contains($0.id) },
                          tasks: existing.tasks + tasks.filter { !taskIDs.contains($0.id) })
            let weeks = Set((existing.weekTitles ?? []).map(\.week))
            result.weekTitles = (existing.weekTitles ?? []) + (weekTitles ?? []).filter { !weeks.contains($0.week) }
        }
        result.syncChanges = try SyncChanges.Resolution(local: existing, cloud: self, base: nil).revisions(for: result)
        result.version = 14
        try result.validate() // Validate the complete merged graph and records before changing live models.
        return result
    }

    /// Save once: a failed write uses the same protective rollback as normal task edits.
    @MainActor func restore(_ context: ModelContext, replace: Bool) throws {
        try Store.recovery.requireWritable(context)
        // Old records are deleted before the ledger and history are staged; a failure there must not leave half a restore.
        try Store.discardingOnFailure(context) { try apply(to: context, replace: replace) }
    }

    @MainActor func restoreKeepingCopy(_ context: ModelContext, replace: Bool, directory: URL) throws -> RestoreBackupFiles.WriteResult {
        try Store.recovery.requireWritable(context)
        let current = try Self.capture(context)
        _ = try merging(into: current, replace: replace)
        let checkpoint: RestoreBackupFiles.WriteResult
        do { checkpoint = try RestoreBackupFiles.write(current.encoded(), directory: directory) }
        catch {
            throw Self.invalid(L("无法保存恢复前副本，未执行恢复：", "Restore was not performed because its safety copy could not be saved: ") + error.localizedDescription)
        }
        try restore(context, replace: replace)
        return checkpoint
    }

    @MainActor private func apply(to context: ModelContext, replace: Bool) throws {
        let original = try Self.capture(context)
        let merged = try merging(into: original, replace: replace)
        let oldTasks = try context.fetch(FetchDescriptor<TaskItem>())
        let oldLists = try context.fetch(FetchDescriptor<TaskList>())
        var listsByID = Dictionary(uniqueKeysWithValues: oldLists.map { ($0.id, $0) })
        var taskIDs = Set(oldTasks.map(\.id))
        var parents = replace ? [:] : Dictionary(uniqueKeysWithValues: oldLists.map { ($0.id, $0.parentID) })
        for record in lists where replace || listsByID[record.id] == nil { parents[record.id] = .some(record.parentID) }
        try ListTree.validate(parents)
        if replace {
            oldTasks.forEach { context.delete($0) }; oldLists.forEach { context.delete($0) }
            listsByID = [:]; taskIDs = []
        }
        for record in lists where listsByID[record.id] == nil {
            let list = TaskList(name: record.name); list.id = record.id; list.createdAt = record.createdAt; list.parentID = record.parentID; list.colorHex = record.colorHex; list.sortOrder = record.sortOrder ?? 0; list.emoji = record.emoji
            context.insert(list); listsByID[list.id] = list
        }
        for record in tasks where !taskIDs.contains(record.id) {
            context.insert(record.model(list: record.listID.flatMap { listsByID[$0] }))
        }
        if let finance = merged.finance { try FinanceStore.stage(finance, in: context, trackSyncChanges: false) }
        if let weekTitles = merged.weekTitles { try CalendarWeekTitle.stage(weekTitles, in: context) }
        // A user-requested restore is a new edit; importing cloud changes is not.
        var restored = try Self.capture(context)
        restored.syncChanges = merged.syncChanges
        try SyncChanges.stage(SyncChanges.restored(restored, replacing: original), in: context)
        try Store.save(context, trackSyncChanges: false)
    }
    @MainActor static func recoveryURL() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("JianshiBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("before-last-restore.json")
    }
}

/// Restore checkpoints never share the hourly automatic-backup retention bucket.
enum RestoreBackupFiles {
    static let retainedCount = 10
    private static let prefix = "before-restore-"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tally", category: "RestoreBackup")
    struct Copy: Identifiable {
        let url: URL
        let date: Date
        let legacy: Bool
        var id: String { url.lastPathComponent }
    }
    struct WriteResult {
        let copy: Copy
        let cleanupFailed: Bool
    }
    static func copies(in directory: URL) throws -> [Copy] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]).compactMap { url -> Copy? in
            let name = url.lastPathComponent
            guard name == "before-last-restore.json" || name.hasPrefix(prefix) && url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            if name == "before-last-restore.json" {
                return Copy(url: url, date: values.contentModificationDate ?? .distantPast, legacy: true)
            }
            let suffix = String(name.dropFirst(prefix.count).dropLast(5))
            guard suffix.count == 57, suffix.dropFirst(20).first == "-",
                  let stamp = Double(suffix.prefix(20)), stamp.isFinite,
                  UUID(uuidString: String(suffix.suffix(36))) != nil else { return nil }
            return Copy(url: url, date: Date(timeIntervalSince1970: stamp / 1000), legacy: false)
        }.sorted {
            if $0.legacy != $1.legacy { return !$0.legacy }
            return $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date
        }
    }
    static func write(_ data: Data, directory: URL, now: Date = Date()) throws -> WriteResult {
        _ = try TaskBackup.decode(data, allowLargeFile: true)
        let fm = FileManager.default
        let existing = try copies(in: directory).filter { !$0.legacy }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A backwards clock must not make a new checkpoint the first to be pruned.
        let milliseconds = max((now.timeIntervalSince1970 * 1000).rounded(),
                               existing.first.map { ($0.date.timeIntervalSince1970 * 1000).rounded() + 1 } ?? 0)
        let name = prefix + String(format: "%020.0f", milliseconds) + "-" + UUID().uuidString + ".json"
        let completed = directory.appendingPathComponent(name)
        let staging = directory.appendingPathComponent(".restore-partial-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        guard try Data(contentsOf: staging) == data else { throw CocoaError(.fileReadCorruptFile) }
        try fm.moveItem(at: staging, to: completed)
        let cleanupFailed = pruneOlderCopies(existing)
        if cleanupFailed { log.error("Restore checkpoint saved; older checkpoints could not all be pruned") }
        else { log.notice("Verified restore checkpoint saved; retention limit: \(retainedCount, privacy: .public)") }
        return WriteResult(copy: Copy(url: completed, date: Date(timeIntervalSince1970: milliseconds / 1000), legacy: false), cleanupFailed: cleanupFailed)
    }
    /// A failed cleanup keeps extra copies; it must never invalidate the newly verified checkpoint.
    static func pruneOlderCopies(_ existing: [Copy], remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        var failed = false
        for old in existing.filter({ !$0.legacy }).dropFirst(retainedCount - 1) {
            do { try remove(old.url) } catch { failed = true }
        }
        return failed
    }
}
