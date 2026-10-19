import Foundation
import SwiftData
import UserNotifications
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor enum StorageChecks {
    static func weekTitleBackup(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let week = CalendarWeekTitle.key(for: date(2027, 1, 1))
            try require(week == "2026-12-28" && CalendarWeekTitle.validKey(week), "Week title key uses the Monday across year boundaries")
            try require(!CalendarWeekTitle.validKey("2026-12-29") && !CalendarWeekTitle.validKey("2026-02-30"), "Week-title import rejects non-Mondays and impossible dates")
            for zone in ["Australia/Sydney", "America/New_York", "Asia/Shanghai"] {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
                let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
                try require(CalendarWeekTitle.key(for: sunday, calendar: calendar) == "2026-09-28", "Civil week key survives DST: " + zone)
            }
            let db = try Store.make(url: directory.appendingPathComponent("week-titles.store"))
            db.mainContext.insert(CalendarWeekTitle(week: week, title: "Week 11")); try Store.save(db.mainContext)
            let snapshot = try TaskBackup.capture(db.mainContext)
            try require(snapshot.version == 15 && snapshot.weekTitles == [.init(week: week, title: "Week 11")], "Full backup contains week titles and protects old clients with a new version")
            let copied = try TaskBackup.decode(snapshot.encoded())
            let restored = try Store.make(url: directory.appendingPathComponent("week-titles-restored.store"))
            try copied.restore(restored.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("week-titles-restored.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<CalendarWeekTitle>()).first?.title == "Week 11", "Week title survives import and database reopen")
            var legacyJSON = try JSONSerialization.jsonObject(with: snapshot.encoded()) as! [String: Any]
            legacyJSON["version"] = 6; legacyJSON.removeValue(forKey: "weekTitles")
            let legacy = try TaskBackup.decode(JSONSerialization.data(withJSONObject: legacyJSON))
            try require(legacy.weekTitles == nil && (try legacy.merging(into: snapshot, replace: true)).weekTitles == snapshot.weekTitles,
                        "Restoring a v52 backup preserves week titles absent from its older format")
            var cleared = snapshot; cleared.weekTitles = []
            try cleared.restore(restored.mainContext, replace: true)
            try require(try restored.mainContext.fetchCount(FetchDescriptor<CalendarWeekTitle>()) == 0, "New backups explicitly restore an empty title collection")
            // A multi-step update that fails after deleting must leave nothing for a later save to commit.
            let interrupted = try Store.make(url: directory.appendingPathComponent("interrupted-update.store")), context = interrupted.mainContext
            context.insert(TaskItem(title: "Survives a failed restore")); try Store.save(context)
            do {
                try Store.discardingOnFailure(context) {
                    for task in try context.fetch(FetchDescriptor<TaskItem>()) { context.delete(task) }
                    context.insert(TaskItem(title: "Half of a restore"))
                    throw TaskBackup.invalid("Injected staging failure")
                }
                try require(false, "An injected staging failure is reported")
            } catch let error as NSError where error.localizedDescription == "Injected staging failure" {}
            try Store.save(context)
            let survivors = try context.fetch(FetchDescriptor<TaskItem>()).map(\.title)
            try require(!context.hasChanges && survivors == ["Survives a failed restore"],
                        "A failed multi-step update is discarded, so the next save cannot commit half of it")
        }
    }

    #if os(macOS)
    static func widgetSnapshot(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let db = try Store.make(url: directory.appendingPathComponent("widget.store")), context = db.mainContext
            let today = Dates.calendar.startOfDay(for: date(2030, 9, 23))
            let list = TaskList(name: "Widget list"); context.insert(list)
            let timed = TaskItem(title: "Timed", scheduledAt: today.addingTimeInterval(36000), list: list); timed.hasTime = true
            let allDay = TaskItem(title: "All day", scheduledAt: today)
            let overdue = TaskItem(title: "Earlier", scheduledAt: today.addingTimeInterval(-86400))
            let ongoing = TaskItem(title: "Overnight", scheduledAt: today.addingTimeInterval(-3600)); ongoing.hasTime = true; ongoing.endAt = today.addingTimeInterval(3600)
            let midnight = TaskItem(title: "Ends at midnight", scheduledAt: today.addingTimeInterval(-7200)); midnight.hasTime = true; midnight.endAt = today
            let tomorrow = TaskItem(title: "Tomorrow", scheduledAt: today.addingTimeInterval(86400))
            let done = TaskItem(title: "Done", scheduledAt: today); done.isDone = true
            let trash = TaskItem(title: "Trash", scheduledAt: today); trash.deletedAt = today
            let undated = TaskItem(title: "No date")
            for task in [timed,allDay,overdue,ongoing,midnight,tomorrow,done,trash,undated] { context.insert(task) }
            try Store.save(context)
            if !WidgetBridge.isEnabled {
                let pending = WidgetBridge.pendingWrites
                WidgetBridge.publish(context)
                try require(WidgetBridge.pendingWrites == pending, "Disabled widgets never enqueue a publish, including direct callers")
            }
            let data = try WidgetBridge.snapshot(context)
            try require(data.today(today, calendar: Dates.calendar).map(\.id) == [ongoing.id,timed.id,allDay.id], "Widget uses today's real unfinished tasks, timed first, with continuing intervals")
            try require(data.overdue(today, calendar: Dates.calendar) == 2, "Widget counts earlier work without counting ongoing tasks twice")
            try require(data.today(today.addingTimeInterval(86400), calendar: Dates.calendar).map(\.id) == [tomorrow.id], "Widget date rollover uses saved future tasks even if app is closed")
            try require(!data.tasks.contains { $0.id == trash.id } && data.tasks.contains { $0.id == done.id && $0.isDone } && data.tasks.contains { $0.id == undated.id }, "Widget snapshot preserves completion state and undated work but excludes deleted tasks")
            try require(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(data)) == data, "Shared widget snapshot round trips without changing identifiers or dates")
            try require(WidgetSnapshot.taskID(from: URL(string: "jianshi://task/" + timed.id.uuidString)!) == timed.id,
                        "Widget task links resolve the exact stored identity")
            try require(["https://task/"+timed.id.uuidString,"jianshi://task/not-an-id","jianshi://task/"+timed.id.uuidString+"/extra","jianshi://today"].allSatisfy { WidgetSnapshot.taskID(from: URL(string: $0)!) == nil }, "Widget ignores malformed and unrelated task links")
            try require(data.rows(source: "today", date: today, showCompleted: false, calendar: Dates.calendar).map(\.id) == [midnight.id,overdue.id,ongoing.id,timed.id,allDay.id], "Today widget pins earlier unfinished work without duplicates")
            try require(data.rows(source: "all", date: today, showCompleted: false, calendar: Dates.calendar).last?.id == undated.id, "All widget includes undated work after dated tasks")
            try require(data.rows(source: list.id.uuidString, date: today).map(\.id) == [timed.id], "List widget filters by stable ID")
            try require(data.rows(source: UUID().uuidString, date: today).isEmpty, "Removed widget lists do not silently show every task")
            let child = TaskList(name: "Child"); child.parentID = list.id; context.insert(child); undated.list = child
            let nested = try WidgetBridge.snapshot(context)
            try require(Set(nested.rows(source: list.id.uuidString, date: today).map(\.id)) == Set([timed.id,undated.id]), "Widget parent lists include nested lists and undated tasks")
            try require(WidgetSnapshot.identifier(from: WidgetSnapshot.sourceURL(list.id.uuidString), host: "list") == list.id, "View all links preserve the configured list")
            try require(WidgetSnapshot.sourceURL("all").host == "all" && WidgetSnapshot.sourceURL("today").host == "today", "View all links preserve built-in scopes")
            let legacy = Data("{\"tasks\":[],\"english\":false}".utf8)
            try require(try JSONDecoder().decode(WidgetSnapshot.self, from: legacy).lists == nil, "Previous widget snapshot format stays readable")
            try require(data.rows(source: "today", date: today, calendar: Dates.calendar).last?.id == done.id, "Completed tasks remain visible after unfinished tasks by default")
            overdue.isDone = true; overdue.completedAt = today
            let finishedEarlier = try WidgetBridge.snapshot(context)
            try require(finishedEarlier.rows(source: "today", date: today, calendar: Dates.calendar).contains { $0.id == overdue.id }, "Earlier task completed today stays on today's widget")
            try require(!finishedEarlier.rows(source: "today", date: today, showCompleted: false, calendar: Dates.calendar).contains { $0.id == overdue.id }, "Hiding completed tasks removes them only after completion is saved")
            try require(!finishedEarlier.rows(source: "today", date: today.addingTimeInterval(86400), calendar: Dates.calendar).contains { $0.id == overdue.id }, "Yesterday's completed earlier task leaves today's scope at midnight")
            let noFlags = Data("{\"id\":\"\(UUID().uuidString)\",\"title\":\"Legacy\",\"timed\":false,\"priority\":0,\"list\":\"\",\"color\":\"799B80\"}".utf8)
            try require(try !JSONDecoder().decode(WidgetTask.self, from: noFlags).isDone, "Old widget rows without completion fields decode as unfinished")
            try require(WidgetPaging.page(99, count: 0, limit: 3) == 0 && WidgetPaging.page(-1, count: 8, limit: 3) == 0, "Empty and negative widget pages clamp safely")
            try require(WidgetPaging.page(2, count: 6, limit: 3) == 1 && WidgetPaging.page(1, count: 5, limit: 3) == 1, "An empty last page falls back, but a nonempty current page stays selected")
            let paged = data.rows(source: "all", date: today, calendar: Dates.calendar)
            let reunited = stride(from: 0, to: paged.count, by: 3).flatMap { Array(paged.dropFirst($0).prefix(3)) }
            try require(reunited.map(\.id) == paged.map(\.id), "Widget pagination reaches every task once, including completed and undated tasks")
            try require(WidgetPaging.key(source: "today", large: false, compact: false, showCompleted: true) != WidgetPaging.key(source: "all", large: false, compact: false, showCompleted: true), "Widget page selection stays scoped to its task range")
            timed.repeatRule = "daily"; try Store.save(context)
            try WidgetBridge.complete(timed.id, in: context)
            let count = try context.fetchCount(FetchDescriptor<TaskItem>())
            try WidgetBridge.complete(timed.id, in: context)
            try require(timed.isDone && timed.nextOccurrenceID != nil && (try context.fetchCount(FetchDescriptor<TaskItem>())) == count, "Repeated widget completion is idempotent and generates only one next occurrence")
            try WidgetBridge.complete(trash.id, in: context)
            try WidgetBridge.complete(UUID(), in: context)
            try require(!trash.isDone && trash.deletedAt != nil, "Stale widget actions never revive or complete deleted tasks")
            let reopened = try Store.make(url: directory.appendingPathComponent("widget.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<TaskItem>()).first(where: { $0.id == timed.id })?.isDone == true, "Widget completion persists to the app's own database")
        }
    }
    #endif

    static func failedCopyIsAtomic(directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
            let relationships = schema.entities.flatMap(\.relationships)
            try require(!relationships.isEmpty && relationships.allSatisfy { $0.isOptional && !$0.isUnique && $0.deleteRule != .deny },
                        "Cloud preparation: relationships are optional, non-unique and never deny deletion")
            let attributes = schema.entities.flatMap(\.attributes).filter { !$0.isTransient }
            try require(attributes.allSatisfy { !$0.isUnique && ($0.isOptional || $0.defaultValue != nil) },
                        "Cloud preparation: persisted attributes have defaults or allow nil, with no unique constraints")
            let url = directory.appendingPathComponent("cloud-schema.store")
            let container = try Store.make(url: url), context = container.mainContext
            let list = TaskList(name: "Optional relationship"); list.tasks = nil; context.insert(list)
            let item = TaskItem(title: "Preserved task", list: list)
            item.notes = "Snapshot includes committed WAL records"; item.subtasks = [Subtask(title: "Step", isDone: true)]
            context.insert(item); try Store.save(context)
            let expected = try BackupFiles.contentData(TaskBackup.capture(context))
            let snapshot = try StoreUpgradeSnapshot.prepare(url)!
            let copy = try Store.make(url: snapshot)
            try require(try BackupFiles.contentData(TaskBackup.capture(copy.mainContext)) == expected,
                        "Pre-upgrade snapshot includes committed data while source connection is open")
            try require(try copy.mainContext.fetch(FetchDescriptor<TaskList>()).first?.tasks?.count == 1,
                        "Optional inverse relationship survives persistence and snapshot")
            let originalSnapshot = try Data(contentsOf: snapshot)
            item.title = "Later edit"; try Store.save(context)
            try require(try StoreUpgradeSnapshot.prepare(url) == snapshot && Data(contentsOf: snapshot) == originalSnapshot,
                        "Subsequent opens retain the original pre-upgrade copy")
            let nextSnapshot = try StoreUpgradeSnapshot.prepare(url, generation: "schema-next-check")!
            let nextCopy = try Store.make(url: nextSnapshot)
            try require(try nextCopy.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == "Later edit",
                        "A new schema generation captures the most recently committed data")
            try require(nextSnapshot != snapshot && (try Data(contentsOf: snapshot)) == originalSnapshot,
                        "New schema snapshots preserve earlier generations for recovery")
            context.delete(list); try Store.save(context)
            let reopened = try Store.make(url: url)
            let retained = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(retained.count == 1 && retained[0].list == nil && retained[0].subtasks == item.subtasks,
                        "Deleting an optional list preserves its task and subtasks")
            let absent = directory.appendingPathComponent("not-created.store")
            try require(try StoreUpgradeSnapshot.prepare(absent) == nil && !FileManager.default.fileExists(atPath: absent.path),
                        "Snapshot preparation never creates a missing source database")
            let corrupt = directory.appendingPathComponent("corrupt.store")
            try Data("not a database".utf8).write(to: corrupt)
            var rejected = false
            do { _ = try StoreUpgradeSnapshot.prepare(corrupt) } catch { rejected = true }
            try require(rejected && (try Data(contentsOf: corrupt)) == Data("not a database".utf8),
                        "Invalid source fails safely without modifying original bytes")
            try require(try FileManager.default.contentsOfDirectory(atPath: snapshot.deletingLastPathComponent().path).allSatisfy { !$0.contains(".partial") },
                        "Failed snapshot leaves no incomplete copy")
        }
    }

    static func largeBackup(directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let container = try Store.make(url: directory.appendingPathComponent("large-backup.store"))
            let currentList = TaskList(name: "Existing")
            container.mainContext.insert(currentList); try Store.save(container.mainContext)
            let largeLists = (0..<1000).map { TaskBackup.ListRecord(id: UUID(), name: "List \($0)", createdAt: Date()) }
            let incoming = TaskBackup(lists: largeLists, tasks: [])
            try incoming.restore(container.mainContext, replace: false)
            try require(try TaskBackup.decode(TaskBackup.capture(container.mainContext).encoded()).lists.count == 1001,
                        "More than one thousand lists can merge, save and round-trip through backup")
            let prototype = TaskBackup.TaskRecord(TaskItem(title: "Boundary"))
            var many = (0..<10000).map { _ -> TaskBackup.TaskRecord in var record = prototype; record.id = UUID(); return record }
            let merged = try TaskBackup(lists: [], tasks: many).merging(into: TaskBackup(lists: [], tasks: [prototype]), replace: false)
            let decoded = try TaskBackup.decode(merged.encoded())
            try require(decoded.tasks.count == 10001, "More than ten thousand tasks round-trip through backup")
            let taskContainer = try Store.make(url: directory.appendingPathComponent("many-tasks.store"))
            try decoded.restore(taskContainer.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("many-tasks.store"))
            try require(try TaskBackup.capture(reopened.mainContext).tasks.count == 10001, "Large backup restores and survives database reload")
            many[0] = prototype
            try require(try TaskBackup(lists: [], tasks: many).merging(into: TaskBackup(lists: [], tasks: [prototype]), replace: false).tasks.count == 10000,
                        "Merge still deduplicates existing task identities")
            let longNote = String(repeating: "中", count: 9500)
            let bigRecords = (0..<800).map { _ -> TaskBackup.TaskRecord in var record = prototype; record.id = UUID(); record.notes = longNote; return record }
            let big = try TaskBackup(lists: [], tasks: Array(bigRecords.prefix(400))).merging(into: TaskBackup(lists: [], tasks: Array(bigRecords.suffix(400))), replace: false)
            let data = try big.encoded()
            try require(data.count > TaskBackup.largeFileThreshold, "Export is not blocked by the external large-file confirmation threshold")
            var rejected = false
            do { _ = try TaskBackup.decode(data) } catch { rejected = true }
            try require(rejected, "Unconfirmed large external files remain bounded")
            try require(try TaskBackup.decode(data, allowLargeFile: true).tasks.count == 800, "Confirmed large files decode without dropping records")
            let largeContainer = try Store.make(url: directory.appendingPathComponent("large-file-restore.store"))
            try big.restore(largeContainer.mainContext, replace: true)
            let roundTrip = try TaskBackup.capture(largeContainer.mainContext).encoded()
            try require(try TaskBackup.decode(roundTrip, allowLargeFile: true).tasks.allSatisfy { $0.notes == longNote }, "Large-file restore and re-export preserve all notes")
            let url = try BackupFiles.write(data, directory: directory.appendingPathComponent("large-automatic"), owner: "test")
            try require(try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true).tasks.count == 800, "Automatic backup accepts and verifies a file over twenty MB")
            var invalid = prototype; invalid.title = ""
            rejected = false
            do { _ = try TaskBackup(lists: [], tasks: [invalid]).merging(into: big, replace: false) } catch { rejected = true }
            try require(rejected, "Larger capacity still validates incoming records before merge")
        }
    }

    static func listTreeBackup(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let a = TaskList(name: "A"), b = TaskList(name: "B"), c = TaskList(name: "C")
            a.createdAt = Date(timeIntervalSince1970: 1); b.createdAt = Date(timeIntervalSince1970: 2)
            a.colorHex = "12abcf"; b.colorHex = "12ABCF"; c.colorHex = ListColor.presets[0].hex
            let items = [a, b, c]
            ListColor.normalize(items)
            try require(a.colorHex == "12abcf" && c.colorHex == ListColor.presets[0].hex && b.colorHex != nil, "Existing distinct colors remain; duplicate color reassigned")
            try require(Set(items.compactMap { $0.colorHex?.uppercased() }).count == 3, "Colors unique ignoring letter case")
            let colors = items.map(\.colorHex); ListColor.normalize(items)
            try require(items.map(\.colorHex) == colors, "Color normalization is stable")
            let many = (0..<60).map { TaskList(name: "List \($0)") }; ListColor.normalize(many)
            try require(Set(many.compactMap(\.colorHex)).count == 60, "Color allocation continues beyond the palette")
            try ListTree.move(c, to: a, placement: .before, lists: items)
            try require(ListNode.roots(items).map(\.id) == [c.id, a.id, b.id], "Dragging above reorders siblings")
            try ListTree.move(c, to: b, placement: .after, lists: items)
            try require(ListNode.roots(items).map(\.id) == [a.id, b.id, c.id], "Dragging below reorders siblings")
            try ListTree.move(b, to: a, placement: .inside, lists: items)
            try ListTree.move(c, to: b, placement: .inside, lists: items)
            try require(c.parentID == b.id && ListTree.path(c, lists: items) == "A / B / C", "Dragging into lists supports nested groups")
            var rejected = false
            do { try ListTree.move(a, to: c, placement: .inside, lists: items) } catch { rejected = true }
            try require(rejected && a.parentID == nil, "Cycle drop rejected without changing data")
            try ListTree.move(c, to: nil, placement: .inside, lists: items)
            try require(c.parentID == nil, "Dragging to header returns list to top level")
            c.name = "B"; rejected = false
            do { try ListTree.move(c, to: a, placement: .inside, lists: items) } catch { rejected = true }
            try require(rejected && c.parentID == nil, "Duplicate destination name rejected before mutation")
            let listURL = directory.appendingPathComponent("ordered.store")
            let container = try Store.make(url: listURL)
            items.forEach { container.mainContext.insert($0) }
            try Store.save(container.mainContext)
            let reopened = try Store.make(url: listURL)
            let persisted = try reopened.mainContext.fetch(FetchDescriptor<TaskList>())
            try require(ListNode.roots(persisted).map(\.id) == [a.id, c.id] && persisted.first { $0.id == b.id }?.parentID == a.id, "Order and hierarchy survive reopening")
            let backup = try TaskBackup.decode(TaskBackup.capture(reopened.mainContext).encoded())
            let restored = try Store.make(url: directory.appendingPathComponent("ordered-restored.store"))
            try backup.restore(restored.mainContext, replace: true)
            let copied = try restored.mainContext.fetch(FetchDescriptor<TaskList>())
            try require(ListNode.roots(copied).map(\.id) == [a.id, c.id] && copied.allSatisfy { item in persisted.first { $0.id == item.id }?.colorHex == item.colorHex }, "Backup restores ordering and distinct colors")
            let start = date(2026, 9, 20)
            let first = TaskItem(title: "Short A", scheduledAt: start); first.hasTime = true; first.endAt = start.addingTimeInterval(300)
            let second = TaskItem(title: "Short B", scheduledAt: start.addingTimeInterval(3600)); second.hasTime = true; second.endAt = start.addingTimeInterval(3900)
            try require(PlanBlock.layout([first, second], day: start).allSatisfy { $0.columns == 1 }, "Separated short tasks do not invent overlap to fit text")
            try require(PlanBlock.layout([first, second], day: start).allSatisfy { $0.end - $0.start == 5 }, "Short task layout retains actual duration")
        }
    }

    static func persistentTaskLifecycle(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        let url = directory.appendingPathComponent("check.store")
        let taskID: UUID
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let list = TaskList(name: "测试清单")
            context.insert(list)
            let task = TaskItem(title: "查看23号的工作", scheduledAt: date(2026, 9, 23), list: list)
            task.subtasks = [Subtask(title: "准备资料")]
            task.notes = "第一行备注\n第二行备注"
            taskID = task.id
            context.insert(task)
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let task = try context.fetch(FetchDescriptor<TaskItem>()).first!
            try require(task.id == taskID && task.title == "查看23号的工作", "Persistent reload")
            try require(task.list?.name == "测试清单" && task.subtasks.first?.title == "准备资料", "Relationships and subtasks reload")
            try require(task.notes == "第一行备注\n第二行备注", "Multiline notes persist")
            task.title = "已编辑"
            task.isDone = true
            task.completedAt = Date()
            task.subtasks[0].isDone = true
            task.deletedAt = Date()
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let task = try context.fetch(FetchDescriptor<TaskItem>()).first!
            try require(task.title == "已编辑" && task.isDone && task.deletedAt != nil && task.subtasks[0].isDone, "Edit, completion, soft-delete persist")
            task.deletedAt = nil
            task.isDone = false
            context.delete(task.list!)
            try Store.save(context)
        }
        do {
            let container = try Store.make(url: url)
            let context = container.mainContext
            let tasks = try context.fetch(FetchDescriptor<TaskItem>())
            try require(tasks.count == 1 && tasks[0].list == nil && tasks[0].deletedAt == nil && !tasks[0].isDone, "Restore and deleting list preserves tasks")
            tasks[0].title = "未保存的修改"
            context.processPendingChanges()
            context.rollback()
        }
        do {
            let container = try Store.make(url: url)
            let restored = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(restored[0].title == "已编辑", "Discarded changes do not overwrite stored data")
        }
    }

    static func recurrenceAndBackup(today: Date, date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        try restoreCheckpoints(directory: directory, require: require)
        try damagedLedgerRecovery(directory: directory, require: require)
        let january = date(2026, 1, 31)
        let february = Dates.nextRepeat(january, rule: "monthly", anchorDay: 31, after: january)!
        try require(Dates.sameDay(february, date(2026, 2, 28)), "Monthly clamps short month")
        try require(Dates.sameDay(Dates.nextRepeat(february, rule: "monthly", anchorDay: 31, after: february)!, date(2026, 3, 31)), "Monthly restores original day")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19))!, date(2026, 9, 22)), "Weekly skips missed occurrences")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "daily", anchorDay: 1, after: today)!, date(2026, 9, 20)), "Daily skips backlog")
        try require(RepeatRule("weekly")?.text == "weekly" && RepeatRule("every:2:w:4,2")?.text == "every:2:w:2,4"
                    && RepeatRule.workdays.text == "every:1:w:2,3,4,5,6" && RepeatRule("every:1:d")?.text == "daily",
                    "Repeat rules read and write old and new forms")
        try require(RepeatRule("every:0:d") == nil && RepeatRule("every:2:m:1") == nil && RepeatRule("every:1:w:") == nil
                    && RepeatRule.isValid("none") && !RepeatRule.isValid("hourly"),
                    "Malformed repeat rules are refused")
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date { Dates.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
        let friday = at(2026, 9, 18, 9)
        try require(Dates.nextRepeat(friday, rule: RepeatRule.workdays.text, anchorDay: 18, after: friday.addingTimeInterval(3600)) == at(2026, 9, 21, 9),
                    "Weekdays skip the weekend and keep the time")
        let monday = at(2026, 9, 14, 9), everyOther = "every:2:w:2,4"
        try require(Dates.nextRepeat(monday, rule: everyOther, anchorDay: 14, after: monday.addingTimeInterval(3600)) == at(2026, 9, 16, 9)
                    && Dates.nextRepeat(monday, rule: everyOther, anchorDay: 14, after: at(2026, 9, 16, 10)) == at(2026, 9, 28, 9),
                    "Every other week on Monday and Wednesday skips the week between")
        try require(Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "every:3:d", anchorDay: 1, after: date(2026, 9, 19))!, date(2026, 9, 22))
                    && Dates.sameDay(Dates.nextRepeat(january, rule: "every:2:m", anchorDay: 31, after: january)!, date(2026, 3, 31))
                    && Dates.sameDay(Dates.nextRepeat(date(2024, 2, 29), rule: "yearly", anchorDay: 29, after: date(2024, 2, 29))!, date(2025, 2, 28)),
                    "Every n days, every n months and yearly land on the right days")
        try require(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19), until: date(2026, 9, 20)) == nil
                    && Dates.sameDay(Dates.nextRepeat(date(2026, 9, 1), rule: "weekly", anchorDay: 1, after: date(2026, 9, 19), until: date(2026, 9, 22))!, date(2026, 9, 22)),
                    "A repeat stops after its last day, which itself still counts")
        do {
            let container = try Store.make(url: directory.appendingPathComponent("until.store"))
            let context = container.mainContext
            let first = TaskItem(title: "Until", scheduledAt: date(2026, 9, 18))
            first.repeatRule = "daily"; first.repeatUntil = date(2026, 9, 19)
            context.insert(first)
            first.toggleCompletion(in: context, now: date(2026, 9, 18))
            let second = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == first.nextOccurrenceID }
            try require(second.map { Dates.sameDay($0.scheduledAt!, date(2026, 9, 19)) && $0.repeatUntil == first.repeatUntil } == true,
                        "The next time carries the end day")
            second?.toggleCompletion(in: context, now: date(2026, 9, 19))
            try require(second?.nextOccurrenceID == nil && (try context.fetchCount(FetchDescriptor<TaskItem>())) == 2, "Nothing is created past the end day")
            try Store.save(context)
            let reopened = try Store.make(url: directory.appendingPathComponent("until.store"))
            let reread = try reopened.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(reread.allSatisfy { $0.repeatUntil.map { Dates.sameDay($0, date(2026, 9, 19)) } == true }, "The end day is saved")
            first.repeatRule = everyOther
            let backup = try TaskBackup.decode(try TaskBackup(lists: [], tasks: [TaskBackup.TaskRecord(first)]).encoded())
            try require(backup.tasks.first.map { $0.repeatRule == everyOther && $0.repeatUntil == first.repeatUntil } == true, "Backups keep custom repeats and end days")

            let work = TaskList(name: "Work"), home = TaskList(name: "Home")
            context.insert(work); context.insert(home)
            func add(_ title: String, _ day: Date, _ list: TaskList?, deleted: Bool = false) {
                let task = TaskItem(title: title, scheduledAt: day, list: list)
                if deleted { task.deletedAt = day }
                context.insert(task)
            }
            add("Group Meeting", date(2026, 9, 10), work)
            add("group meeting", date(2026, 9, 17), home)
            add("Meeting", date(2026, 9, 18), work)
            add("Lecture notes", date(2026, 9, 18), work, deleted: true)
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let found = TaskSuggestions.find("meet", in: all, preferredList: work.id).map(\.title)
            try require(found == ["Meeting", "group meeting"], "Suggestions keep the latest of each title, this list first")
            try require(TaskSuggestions.find("MEETING", in: all, preferredList: nil).first?.title == "Meeting"
                        && TaskSuggestions.find("lecture", in: all, preferredList: nil).isEmpty
                        && TaskSuggestions.find("  ", in: all, preferredList: nil).isEmpty,
                        "Suggestions ignore case and leave out deleted tasks")
        }
        do {
            let container = try Store.make(url: directory.appendingPathComponent("repeat.store"))
            let context = container.mainContext
            let task = TaskItem(title: "Recurring", scheduledAt: january)
            task.repeatRule = "monthly"; task.repeatAnchorDay = 31
            task.reminderAt = january.addingTimeInterval(-3600)
            task.hasTime = true; task.reminderKind = ReminderPreset.oneHour.rawValue
            task.dueAt = january.addingTimeInterval(3600); task.dueHasTime = true
            task.subtasks = [Subtask(title: "Step", isDone: true)]
            context.insert(task)
            task.toggleCompletion(in: context, now: january)
            try Store.save(context)
            let next = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == task.nextOccurrenceID }!
            try require(next.subtasks.count == 1 && !next.subtasks[0].isDone && next.repeatRule == "monthly", "Next occurrence copies and resets subtasks")
            try require(Dates.sameDay(next.reminderAt!, february) && Dates.calendar.component(.hour, from: next.reminderAt!) == 11, "Recurring reminder shifts with schedule")
            try require(next.dueHasTime && Dates.sameDay(next.dueAt!, february) && Dates.calendar.component(.hour, from: next.dueAt!) == Dates.calendar.component(.hour, from: task.dueAt!), "Deadline time persists and repeats")
            task.toggleCompletion(in: context, now: january)
            task.toggleCompletion(in: context, now: january)
            try Store.save(context)
            let count = try context.fetchCount(FetchDescriptor<TaskItem>())
            try require(count == 2, "Re-completion does not duplicate next occurrence")
            next.reschedule(to: date(2026, 3, 5), extendingDeadline: true)
            try require(Dates.sameDay(next.calendarDate!, date(2026, 3, 5)) && Dates.calendar.component(.hour, from: next.calendarDate!) == 12 && Dates.sameDay(next.reminderAt!, date(2026, 3, 5)), "Reschedule preserves time and moves reminder")
            next.deletedAt = today; try Store.save(context)
            next.deletedAt = nil; try Store.save(context)
            let reloaded = try Store.make(url: directory.appendingPathComponent("repeat.store"))
            let saved = try reloaded.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(saved.count == 2 && saved.allSatisfy { $0.deletedAt == nil } && saved.contains { $0.nextOccurrenceID != nil }, "Undo and repeat linkage persist")
        }
        do {
            let c = try Store.make(url: directory.appendingPathComponent("regressions.store"))
            let context = c.mainContext
            let base = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9))!
            let done = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 8, minute: 30))!
            let task = TaskItem(title: "Daily", scheduledAt: base)
            task.hasTime = true; task.repeatRule = "daily"; task.reminderAt = base.addingTimeInterval(-3600); task.reminderKind = "oneHour"
            context.insert(task); task.toggleCompletion(in: context, now: done); try Store.save(context)
            let next = try context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == task.nextOccurrenceID }!
            try require(next.reminderNeedsAttention && next.reminderAt! < done && next.calendarDate! > done, "Past next reminder explicitly requires attention")
            let custom = TaskItem(title: "Custom", scheduledAt: base)
            custom.reminderAt = ReminderPreset.morning.date(base: base, timed: false); custom.reminderKind = "custom"
            context.insert(custom); try Store.save(context)
            let reload = try Store.make(url: directory.appendingPathComponent("regressions.store"))
            let read = try reload.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == custom.id }!
            try require(read.resolvedReminderPreset == .custom, "Custom reminder choice persists even when matching a preset")
            let originalReminder = read.reminderAt
            read.reschedule(to: date(2026, 9, 20))
            try require(read.reminderAt == originalReminder, "Dragging preserves fixed custom reminder")
            let monthly = TaskItem(title: "Month", scheduledAt: february)
            monthly.repeatRule = "monthly"; monthly.repeatAnchorDay = 31
            let preview = Dates.nextRepeat(february, rule: "monthly", anchorDay: monthly.repeatAnchor(for: february, rule: "monthly"), after: february)
            try require(Dates.sameDay(preview!, date(2026, 3, 31)), "Monthly hint uses saved anchor")
            let deadline = Dates.calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 14))!
            try require(DeadlineCountdown(due: deadline, timed: true, now: deadline.addingTimeInterval(-1)).level == .today && DeadlineCountdown(due: deadline, timed: true, now: deadline.addingTimeInterval(1)).level == .overdue, "Deadline transitions without changing task data")
            let nextDue = Dates.nextRepeat(deadline, rule: "daily", anchorDay: 17, after: Dates.calendar.date(byAdding: .hour, value: 20, to: deadline)!)!
            try require(Dates.sameDay(nextDue, date(2026, 9, 18)) && Dates.calendar.component(.hour, from: nextDue) == 14, "Deadline-only recurrence retains time")

            let list = TaskList(name: "Backup list"); list.colorHex = "12ABCF"; context.insert(list)
            task.list = list; task.notes = "Notes\nline two"; task.subtasks = [Subtask(title: "Step", isDone: true)]; task.deletedAt = done
            try Store.save(context)
            let backup = try TaskBackup.capture(context)
            let data = try backup.encoded()
            let automatic = directory.appendingPathComponent("automatic-versions")
            for version in 1...3 {
                var ledger = FinanceData.initial; ledger.version = version
                var snapshot = backup; snapshot.finance = ledger
                let file = try BackupFiles.write(snapshot.encoded(), directory: directory.appendingPathComponent("ledger-format-\(version)"), owner: "test")
                let restored = try TaskBackup.decode(Data(contentsOf: file))
                try require(restored.finance == ledger, "Automatic backup preserves supported ledger format \(version)")
            }
            try FileManager.default.createDirectory(at: automatic, withIntermediateDirectories: true)
            let manual = automatic.appendingPathComponent("manual.json")
            try data.write(to: manual)
            let other = try BackupFiles.write(data, directory: automatic, owner: "another-device")
            var latest: URL?
            for _ in 0..<35 { latest = try BackupFiles.write(data, directory: automatic, owner: "test-device") }
            let owned = try FileManager.default.contentsOfDirectory(at: automatic, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Jianshi-Auto-test-device-") }
            try require(owned.count == 1 && owned.contains { $0.lastPathComponent == latest!.lastPathComponent }, "Rapid saves retain only the latest version in an hour")
            try require(FileManager.default.fileExists(atPath: manual.path) && FileManager.default.fileExists(atPath: other.path),
                        "Automatic retention preserves manual backups and other devices")
            let legacyExtra = automatic.appendingPathComponent(latest!.lastPathComponent.replacingOccurrences(of: ".json", with: "-old.json"))
            try data.write(to: legacyExtra)
            let stableDate = try BackupFiles.save(backup, directory: automatic, owner: "test-device")
            var reordered = backup; reordered.createdAt = Date().addingTimeInterval(100)
            reordered.tasks.reverse(); reordered.lists.reverse()
            let duplicateDate = try BackupFiles.save(reordered, directory: automatic, owner: "test-device")
            try require(stableDate == duplicateDate && (try? BackupFiles.ownedFiles(directory: automatic, owner: "test-device").count) == 1,
                        "Relaunch deduplication ignores capture date and fetch order using the on-disk snapshot")
            latest = try BackupFiles.ownedFiles(directory: automatic, owner: "test-device").first?.url
            let now = Dates.calendar.date(bySettingHour: 23, minute: 50, second: 0, of: date(2026, 9, 20))!
            var history: [(url: URL, date: Date)] = []
            for age in 0..<16 {
                let day = Dates.calendar.date(byAdding: .day, value: -age, to: now)!
                for hour in 0..<24 {
                    for minute in [10, 40] {
                        let stamp = Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
                        history.append((directory.appendingPathComponent("\(age)-\(hour)-\(minute).json"), stamp))
                    }
                }
            }
            let newest = history[47].url
            let keep = BackupFiles.retained(history, now: now, newest: newest, calendar: Dates.calendar)
            let kept = history.filter { keep.contains($0.url.lastPathComponent) }
            try require(kept.count == 23 && kept.filter { Dates.sameDay($0.date, now) }.count == 10,
                        "Time retention keeps ten hourly versions today plus thirteen daily versions")
            try require(Set(kept.map { Dates.calendar.startOfDay(for: $0.date) }).count == 14,
                        "A burst of edits cannot evict the previous thirteen days")
            try require(kept.allSatisfy { $0.date >= Dates.calendar.startOfDay(for: date(2026, 9, 7)) }
                        && kept.allSatisfy { Dates.calendar.component(.minute, from: $0.date) == 40 },
                        "Retention picks the newest version per time bucket and excludes days older than fourteen days")
            let sole = history.last!
            try require(BackupFiles.retained([sole], now: now, newest: sole.url).contains(sole.url.lastPathComponent),
                        "The only known good backup is not discarded after a long inactive period")
            let boundary = date(2027, 1, 1)
            let monthBoundary = [(directory.appendingPathComponent("yesterday.json"), date(2026, 12, 31)),
                                 (directory.appendingPathComponent("today.json"), boundary)]
            try require(BackupFiles.retained(monthBoundary, now: boundary, newest: monthBoundary[1].0).count == 2,
                        "Daily history survives year and month boundaries")
            let automaticDecoded = try TaskBackup.decode(Data(contentsOf: latest!))
            try require(automaticDecoded.tasks.count == backup.tasks.count && automaticDecoded.lists.count == backup.lists.count,
                        "Automatic files use the complete portable restore format")
            let external = directory.appendingPathComponent("external-folder")
            let externalFile = try BackupFiles.write(data, directory: external, owner: "test-device")
            try require(try Data(contentsOf: externalFile) == data, "External copy has exactly the same portable bytes")
            var rejectedAuto = false
            do { _ = try BackupFiles.write(Data("broken".utf8), directory: automatic, owner: "test-device") }
            catch { rejectedAuto = true }
            try require(rejectedAuto && (try? Data(contentsOf: latest!)) == data, "Invalid snapshot never prunes a previous backup")
            var failedExternal = false
            do { _ = try BackupFiles.write(data, directory: manual, owner: "test-device") }
            catch { failedExternal = true }
            try require(failedExternal && (try? Data(contentsOf: latest!)) == data, "External write failure leaves local history readable")

            do {
                let recovery = directory.appendingPathComponent("sync-recovery")
                let originals = recovery.appendingPathComponent("Conflicts")
                var cloud = backup; cloud.tasks[0].title = "Original cloud conflict"
                let cloudData = try cloud.encoded()
                try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true) == nil,
                            "No conflict recovery copy is reported before the first conflict")
                try BackupFiles.protectSyncCopies(local: data, cloud: cloudData, directory: recovery, now: now)
                try BackupFiles.protectSyncCopies(local: data, cloud: cloudData, directory: recovery, now: now)
                try require(try FileManager.default.contentsOfDirectory(atPath: originals.path).count == 1,
                            "Repeated conflict review retains one complete original pair")
                for index in 0..<3 {
                    var routine = backup; routine.tasks[0].title = "Later routine sync \(index)"
                    for owner in ["sync-local", "sync-cloud"] {
                        _ = try BackupFiles.write(routine.encoded(), directory: recovery, owner: owner, now: now.addingTimeInterval(Double(index)))
                    }
                }
                try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true) == data
                            && BackupFiles.syncRecoveryCopy(directory: recovery, local: false) == cloudData,
                            "Hourly routine sync pruning cannot remove either pre-decision conflict original")
                var failed = false
                do { try BackupFiles.protectSyncCopies(local: data, cloud: Data("broken".utf8), directory: recovery) }
                catch { failed = true }
                try require(failed && (try BackupFiles.syncRecoveryCopy(directory: recovery, local: false)) == cloudData
                            && (try FileManager.default.contentsOfDirectory(atPath: originals.path).count) == 1,
                            "An invalid conflict side leaves the previous complete pair untouched")
                var finalLocal = data, finalCloud = cloudData
                for index in 0..<7 {
                    var local = backup; local.tasks[0].title = "Local pair \(index)"
                    cloud.tasks[0].title = "Cloud pair \(index)"
                    finalLocal = try local.encoded(); finalCloud = try cloud.encoded()
                    try BackupFiles.protectSyncCopies(local: finalLocal, cloud: finalCloud, directory: recovery, now: now.addingTimeInterval(-Double(index)))
                }
                let pairs = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)
                try require(pairs.count == 5 && pairs.allSatisfy { $0.lastPathComponent.hasPrefix("Jianshi-Conflict-") },
                            "Conflict protection keeps five complete pairs without partial files or unbounded growth")
                try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true) == finalLocal
                            && BackupFiles.syncRecoveryCopy(directory: recovery, local: false) == finalCloud,
                            "Latest conflict exports remain a matching pair when the device clock moves backwards")
                for pair in pairs {
                    let local = try TaskBackup.decode(Data(contentsOf: pair.appendingPathComponent("local.json")))
                    let cloud = try TaskBackup.decode(Data(contentsOf: pair.appendingPathComponent("cloud.json")))
                    try require(local.tasks[0].title.split(separator: " ").last == cloud.tasks[0].title.split(separator: " ").last,
                                "Retained conflict originals never mix records from different decisions")
                }
                let manualNames = Set(pairs.map(\.lastPathComponent))
                let automaticPairs = recovery.appendingPathComponent("AutomaticMerges")
                try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true, kind: .automaticMerge) == nil,
                            "Existing manual conflict directories are not mislabeled as automatic resolutions")
                var newestAutomaticLocal = data, newestAutomaticCloud = cloudData
                for round in 0..<3 {
                    for index in 0..<8 {
                        var local = backup; local.tasks[0].title = "Automatic local \(round)-\(index)"
                        cloud.tasks[0].title = "Automatic cloud \(round)-\(index)"
                        newestAutomaticLocal = try local.encoded(); newestAutomaticCloud = try cloud.encoded()
                        for _ in 0..<2 {
                            try BackupFiles.protectSyncCopies(local: newestAutomaticLocal, cloud: newestAutomaticCloud,
                                                              directory: recovery, kind: .automaticMerge, now: now.addingTimeInterval(-Double(index)))
                        }
                        try require(try FileManager.default.contentsOfDirectory(atPath: automaticPairs.path).count == (round == 0 && index == 0 ? 1 : 2),
                                    "Automatic resolutions retain at most two pairs and deduplicate repeated inputs")
                    }
                    try require(try Set(FileManager.default.contentsOfDirectory(atPath: originals.path)) == manualNames,
                                "Repeated automatic retention leaves every existing manual conflict pair untouched")
                    try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true) == finalLocal
                                && BackupFiles.syncRecoveryCopy(directory: recovery, local: false) == finalCloud,
                                "Automatic resolutions never replace the manual conflict export")
                }
                try require(try BackupFiles.syncRecoveryCopy(directory: recovery, local: true, kind: .automaticMerge) == newestAutomaticLocal
                            && BackupFiles.syncRecoveryCopy(directory: recovery, local: false, kind: .automaticMerge) == newestAutomaticCloud,
                            "Automatic recovery exports select both originals from their own latest pair")
                let automaticNames = try Set(FileManager.default.contentsOfDirectory(atPath: automaticPairs.path))
                failed = false
                do { try BackupFiles.protectSyncCopies(local: Data("broken".utf8), cloud: cloudData, directory: recovery, kind: .automaticMerge) }
                catch { failed = true }
                try require(failed && (try Set(FileManager.default.contentsOfDirectory(atPath: automaticPairs.path))) == automaticNames,
                            "Invalid automatic inputs do not prune or create a partial recovery pair")
                try require(BackupFiles.SyncRecoveryKind.required(manualReview: true, automaticCount: 2) == [.manualConflict, .automaticMerge]
                            && BackupFiles.SyncRecoveryKind.required(manualReview: false, automaticCount: 2) == [.automaticMerge]
                            && BackupFiles.SyncRecoveryKind.required(manualReview: true, automaticCount: 0) == [.manualConflict]
                            && BackupFiles.SyncRecoveryKind.required(manualReview: false, automaticCount: 0).isEmpty,
                            "Mixed manual and automatic decisions protect both pools; routine sync does not consume either pool")
                // Simulate an older release's directory layout without migration or rewriting its originals.
                let legacyRecovery = directory.appendingPathComponent("legacy-sync-recovery")
                let legacyPair = legacyRecovery.appendingPathComponent("Conflicts/Jianshi-Conflict-00000000000000000001-legacy")
                try FileManager.default.createDirectory(at: legacyPair, withIntermediateDirectories: true)
                try data.write(to: legacyPair.appendingPathComponent("local.json")); try cloudData.write(to: legacyPair.appendingPathComponent("cloud.json"))
                try BackupFiles.protectSyncCopies(local: newestAutomaticLocal, cloud: newestAutomaticCloud, directory: legacyRecovery, kind: .automaticMerge)
                try require(try BackupFiles.syncRecoveryCopy(directory: legacyRecovery, local: true) == data
                            && BackupFiles.syncRecoveryCopy(directory: legacyRecovery, local: false) == cloudData,
                            "Automatic-pool creation preserves and exports the previous release's conflict originals")
            }
            do {
                let suite = "local.jianshi.sync-summary-check-" + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                try require(AutomaticSyncSummary.load(account: "account-a", defaults: defaults) == nil,
                            "Automatic sync feedback starts empty without inventing a previous decision")
                let summary = AutomaticSyncSummary.record(count: 2, date: now, account: "account-a", defaults: defaults)
                let reopenedDefaults = UserDefaults(suiteName: suite)!
                try require(summary == AutomaticSyncSummary(count: 2, date: now)
                            && AutomaticSyncSummary.load(account: "account-a", defaults: reopenedDefaults) == summary,
                            "Latest automatic count and date survive settings recreation")
                try require(AutomaticSyncSummary.record(count: 0, date: now.addingTimeInterval(1), account: "account-a", defaults: defaults) == summary,
                            "A later routine sync does not erase feedback about the last automatic resolution")
                try require(AutomaticSyncSummary.load(account: "account-b", defaults: defaults) == nil
                            && AutomaticSyncSummary.load(account: "", defaults: defaults) == nil,
                            "Account changes and unbound stores never display a previous account's automatic feedback")
                try require(AutomaticSyncSummary.record(count: 0, account: "account-b", defaults: defaults) == nil
                            && AutomaticSyncSummary.load(account: "account-a", defaults: defaults) == summary,
                            "Switching back to the original account restores its feedback without leaking it to another account")
                let newer = AutomaticSyncSummary.record(count: 4, date: now.addingTimeInterval(2), account: "account-a", defaults: defaults)
                try require(newer?.count == 4 && newer?.date == now.addingTimeInterval(2),
                            "The next automatic resolution replaces the count and date together")
                defaults.set(["account": CloudMerge.digest(Data("account-a".utf8)), "count": -1, "date": now], forKey: "lastAutomaticSyncSummary")
                try require(AutomaticSyncSummary.load(account: "account-a", defaults: defaults) == nil,
                            "Malformed persisted automatic feedback is ignored without touching sync data")
            }

            let decoded = try TaskBackup.decode(data)
            try require(decoded.tasks.count == 3 && decoded.lists.count == 1, "Backup roundtrip counts")
            try require(decoded.lists.first?.colorHex == "12ABCF", "Backup captures custom list color")
            var legacyJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var legacyLists = legacyJSON["lists"] as! [[String: Any]]
            legacyLists[0].removeValue(forKey: "colorHex"); legacyJSON["lists"] = legacyLists
            let legacyColor = try TaskBackup.decode(JSONSerialization.data(withJSONObject: legacyJSON))
            try require(legacyColor.lists.first?.colorHex == nil, "Old backups without colors remain compatible")
            var invalidColor = decoded; invalidColor.lists[0].colorHex = "not-rgb"
            var colorRejected = false
            do { try invalidColor.validate() } catch { colorRejected = true }
            try require(colorRejected, "Invalid backup colors rejected before restore")
            let target = try Store.make(url: directory.appendingPathComponent("restored.store"))
            try decoded.restore(target.mainContext, replace: true)
            let restoredContainer = try Store.make(url: directory.appendingPathComponent("restored.store"))
            let restored = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            let restoredTask = restored.first { $0.id == task.id }!
            try require(restoredTask.notes == task.notes && restoredTask.subtasks == task.subtasks && restoredTask.list?.id == list.id && restoredTask.deletedAt != nil && restoredTask.isDone && restoredTask.nextOccurrenceID == next.id, "Full restore retains metadata, relationships, history and trash")
            try require(restored.first { $0.id == custom.id }?.reminderKind == "custom", "Backup retains reminder choice")
            try require(restoredTask.list?.colorHex == "12ABCF", "Custom color survives restore and store reopening")
            restoredTask.title = "Local edit"; try Store.save(restoredContainer.mainContext)
            try decoded.restore(restoredContainer.mainContext, replace: false)
            let merged = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(merged.count == 3 && merged.first { $0.id == task.id }?.title == "Local edit", "Merge is idempotent and keeps local changes")
            let extra = TaskItem(title: "Extra"); restoredContainer.mainContext.insert(extra); try Store.save(restoredContainer.mainContext)
            try decoded.restore(restoredContainer.mainContext, replace: true)
            let replaced = try restoredContainer.mainContext.fetch(FetchDescriptor<TaskItem>())
            try require(replaced.count == 3 && !replaced.contains { $0.id == extra.id }, "Replacement removes extra items")
            var invalid = decoded; invalid.version = 999
            var rejected = false
            do { try invalid.restore(restoredContainer.mainContext, replace: true) } catch { rejected = true }
            try require(rejected, "Unknown version rejected")
            invalid = decoded; invalid.tasks.append(invalid.tasks[0])
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Duplicate identifiers rejected")
            invalid = decoded; invalid.tasks[0].listID = UUID()
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Missing list reference rejected")
            rejected = false
            do { _ = try TaskBackup.decode(Data("{broken".utf8)) } catch { rejected = true }
            try require(rejected, "Malformed JSON rejected")
            invalid = decoded; invalid.tasks[0].createdAt = Date(timeIntervalSince1970: 1e200)
            rejected = false
            do { try invalid.validate() } catch { rejected = true }
            try require(rejected, "Out-of-range dates rejected before rendering")
            let afterInvalid = try restoredContainer.mainContext.fetchCount(FetchDescriptor<TaskItem>())
            try require(afterInvalid == 3, "Rejected imports leave stored data intact")
        }
    }

    static func listTreeValidation(date: (Int, Int, Int) -> Date, directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let root = TaskList(name: "Work"), child = TaskList(name: "Project"), leaf = TaskList(name: "Sprint")
            child.parentID = root.id; leaf.parentID = child.id
            let tree = [root, child, leaf]
            try require(ListTree.contains(leaf.id, in: root.id, lists: tree), "Group includes nested descendants")
            try require(!ListTree.contains(root.id, in: leaf.id, lists: tree), "Group membership is directional")
            try require(ListTree.path(leaf, lists: tree) == "Work / Project / Sprint", "Nested path disambiguates list names")
            try ListTree.validate(Dictionary(uniqueKeysWithValues: tree.map { ($0.id, $0.parentID) }))
            var rejected = false
            do { try ListTree.validate([root.id: child.id, child.id: root.id]) } catch { rejected = true }
            try require(rejected, "Hierarchy cycles rejected")
            rejected = false
            do { try ListTree.validate([root.id: UUID()]) } catch { rejected = true }
            try require(rejected, "Orphan hierarchy rejected")
            let start = date(2026, 9, 20)
            let task = TaskItem(title: "Three hours", scheduledAt: start); task.hasTime = true; task.endAt = start.addingTimeInterval(10800)
            let originalSchedule = TaskSchedule(task)
            task.schedule(at: start.addingTimeInterval(7200))
            task.title = "Edited title"
            originalSchedule.restore(task)
            try require(TaskSchedule(task) == originalSchedule && task.title == "Edited title", "Undo restores schedule without overwriting other task fields")
            task.schedule(at: start.addingTimeInterval(3600))
            try require(task.duration == 10800 && task.endAt == start.addingTimeInterval(14400), "Time drag preserves duration")
            task.reschedule(to: date(2026, 9, 22))
            try require(task.duration == 10800 && Dates.sameDay(task.endAt!, date(2026, 9, 22)), "Date drag preserves duration")
            task.dueAt = task.scheduledAt!.addingTimeInterval(7200); task.dueHasTime = true
            try require(task.timeConflict(at: task.scheduledAt!), "Deadline checks ending, not only start")
            let overnight = TaskItem(title: "Overnight", scheduledAt: Dates.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: start)); overnight.hasTime = true; overnight.endAt = overnight.scheduledAt!.addingTimeInterval(10800)
            let blocks = PlanBlock.layout([overnight], day: date(2026, 9, 21))
            try require(blocks.count == 1 && blocks[0].start == 0 && blocks[0].end == 120, "Overnight clipped onto following day")
            let firstSegment = PlanBlock.layout([overnight], day: start)[0]
            try require(!firstSegment.canResize(on: start) && blocks[0].canResize(on: date(2026, 9, 21)), "Only the real ending segment can resize an overnight task")
            let midnight = Dates.calendar.startOfDay(for: date(2026, 9, 21))
            try require(!overnight.isOverdue(today: midnight.addingTimeInterval(3600)), "An ongoing overnight task is not overdue at 01:00")
            try require(overnight.isOverdue(today: midnight.addingTimeInterval(10800)), "An unfinished overnight task becomes overdue after ending")
            let shortA = TaskItem(title: "Short A", scheduledAt: start); shortA.hasTime = true; shortA.endAt = start.addingTimeInterval(300)
            let shortB = TaskItem(title: "Short B", scheduledAt: start.addingTimeInterval(900)); shortB.hasTime = true; shortB.endAt = start.addingTimeInterval(1200)
            let shortBlocks = PlanBlock.layout([shortA, shortB], day: start)
            try require(shortBlocks.allSatisfy { $0.column == 0 && $0.columns == 1 }, "Nonoverlapping short intervals share a full-width lane")
            let point = TaskItem(title: "A point, not a booked interval", scheduledAt: start); point.hasTime = true
            let pointBlocks = PlanBlock.layout([point], day: start)
            try require(PlanBlock.freeTime(pointBlocks, from: 0, to: 1440).free == 1440, "Start-only tasks do not invent occupied time")
            shortA.isDone = true
            try require(PlanBlock.freeTime(PlanBlock.layout([shortA], day: start), from: 0, to: 1440).free == 1435, "Completing a task retains its booked interval")
            let a = TaskItem(title: "A", scheduledAt: start); a.hasTime = true; a.endAt = start.addingTimeInterval(10800)
            let b = TaskItem(title: "B", scheduledAt: start.addingTimeInterval(3600)); b.hasTime = true; b.endAt = start.addingTimeInterval(7200)
            let overlap = PlanBlock.layout([a,b], day: start)
            try require(overlap.count == 2 && overlap.allSatisfy { $0.columns == 2 } && overlap[0].column != overlap[1].column, "Overlapping blocks have distinct lanes")
            b.scheduledAt = a.endAt; b.endAt = b.scheduledAt!.addingTimeInterval(3600)
            try require(PlanBlock.layout([a,b], day: start).allSatisfy { $0.columns == 1 }, "Touching intervals do not overlap")
            let backup = TaskBackup(lists: tree.map { TaskBackup.ListRecord(id: $0.id, name: $0.name, createdAt: $0.createdAt, parentID: $0.parentID) }, tasks: [TaskBackup.TaskRecord(overnight)])
            let decoded = try TaskBackup.decode(backup.encoded())
            try require(decoded.lists.last?.parentID == child.id && decoded.tasks.first?.endAt == overnight.endAt, "Backup preserves nested lists and intervals")
            let intervalURL = directory.appendingPathComponent("intervals.store")
            let intervalStore = try Store.make(url: intervalURL)
            try decoded.restore(intervalStore.mainContext, replace: true)
            let restoredStore = try Store.make(url: intervalURL)
            let restoredLists = try restoredStore.mainContext.fetch(FetchDescriptor<TaskList>())
            let restoredTask = try restoredStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
            try require(restoredLists.first { $0.id == leaf.id }?.parentID == child.id && restoredTask.duration == 10800, "Restored hierarchy and interval survive reload")
            restoredTask.repeatRule = "daily"; restoredTask.toggleCompletion(in: restoredStore.mainContext, now: restoredTask.scheduledAt!)
            try Store.save(restoredStore.mainContext)
            let next = try restoredStore.mainContext.fetch(FetchDescriptor<TaskItem>()).first { $0.id == restoredTask.nextOccurrenceID }!
            try require(next.duration == 10800, "Repeated task preserves overnight duration")
            var old = backup; old.version = 1; old.lists = []; old.tasks[0].endAt = nil
            let oldDecoded = try TaskBackup.decode(old.encoded())
            try require(oldDecoded.version == 1 && oldDecoded.tasks.first?.endAt == nil, "Legacy backup still accepted")
            var broken = backup; broken.tasks[0].endAt = overnight.scheduledAt
            rejected = false; do { try broken.validate() } catch { rejected = true }
            try require(rejected, "Backup rejects non-positive interval")
        }
    }

    static func emojiPersistence(directory: URL, require: (Bool, String) throws -> Void) throws {
        do {
            let icon = "👨‍👩‍👧‍👦"
            try require(["💼", "🧑🏽‍💻", "🇨🇳", "1️⃣", icon].allSatisfy(TaskList.validEmoji), "List icons accept full composed emoji sequences")
            try require(["", "A", "123", "💼📚"].allSatisfy { !TaskList.validEmoji($0) }, "List icon validation rejects text and multiple emoji")
            let db = try Store.make(url: directory.appendingPathComponent("emoji.store"))
            let list = TaskList(name: "Icons"); list.emoji = icon; db.mainContext.insert(list); try Store.save(db.mainContext)
            let backup = try TaskBackup.capture(db.mainContext)
            let decoded = try TaskBackup.decode(backup.encoded())
            try require(decoded.version == 15 && decoded.lists.first?.emoji == icon, "Emoji survives portable version five backup")
            let destination = try Store.make(url: directory.appendingPathComponent("emoji-restored.store"))
            try decoded.restore(destination.mainContext, replace: true)
            let reopened = try Store.make(url: directory.appendingPathComponent("emoji-restored.store"))
            try require(try reopened.mainContext.fetch(FetchDescriptor<TaskList>()).first?.emoji == icon, "Emoji survives restore and database reopen")
            var old = decoded; old.version = 4; old.lists[0].emoji = nil
            try require(try TaskBackup.decode(old.encoded()).lists[0].emoji == nil, "Version four without emoji retains default icon")
            var bad = decoded; bad.lists[0].emoji = "plain text"
            var rejected = false; do { _ = try bad.encoded() } catch { rejected = true }
            try require(rejected, "Backup validates list icon at the trust boundary")
        }
    }

    static func saveRecovery(date: (Int, Int, Int) -> Date, require: (Bool, String) throws -> Void) throws {
        // Exercise a real SwiftData write rejection, not merely a manual rollback.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Jianshi-SaveRecovery-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("recovery.store")
            let seed = try Store.make(url: url)
            let baseline = TaskItem(title: "Saved title"), list = TaskList(name: "Saved list")
            seed.mainContext.insert(list); seed.mainContext.insert(baseline); baseline.list = list
            try Store.save(seed.mainContext)
            let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
            let drafts = EditorDrafts()
            drafts.taskID = baseline.id
            drafts.task = TaskEditor.DraftState(title: "Kept draft", notes: "Notes", pending: "Pending subtask", repeating: "weekly", repeatUntil: date(2032,1,1),
                end: date(2031,1,1).addingTimeInterval(3600), scheduled: date(2031,1,1), due: date(2031,1,2), reminder: date(2031,1,1).addingTimeInterval(-900),
                timed: true, dueTimed: true, preset: .custom, listID: list.id, priority: 2, subtasks: [Subtask(title: "Draft step")])
            let originalDraft = drafts.task
            drafts.listID = list.id
            drafts.list = ListEditor.DraftState(name: "Draft list", colorHex: "#123456", emoji: "📚", parentID: nil)
            let originalListDraft = drafts.list
            var saveCallbacks = 0
            Store.didSave = { _ in saveCallbacks += 1 }
            defer { Store.didSave = nil }
            for operation in ["edit", "insert", "delete", "list", "restore"] {
                let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
                let context = readOnly.mainContext
                context.autosaveEnabled = false
                let current = try context.fetch(FetchDescriptor<TaskItem>()).first!
                let saved = try TaskBackup.capture(context)
                if operation == "edit" { current.title = "Must not leak" }
                if operation == "insert" { context.insert(TaskItem(title: "Uncommitted new task")) }
                if operation == "delete" { context.delete(current) }
                if operation == "list" { current.list?.name = "Must not leak" }
                let previousCallbacks = saveCallbacks, generation = Store.recovery.generation
                var failed = false
                do {
                    if operation == "restore" { try saved.restore(context, replace: true) }
                    else { try Store.save(context) }
                } catch { failed = true }
                try require(failed && Store.recovery.failure != nil, "Actual read-only write suspends saving: " + operation)
                try require(saveCallbacks == previousCallbacks, "Failed writes never announce success or schedule backup: " + operation)
                try require((try? Store.recovery.requireWritable(context)) == nil, "Failed context blocks later edits: " + operation)
                if operation == "edit" {
                    let away = root.appendingPathExtension("away")
                    try FileManager.default.moveItem(at: root, to: away)
                    let recoveredMissingFile = Store.recovery.reload()
                    let recreatedEmptyFile = FileManager.default.fileExists(atPath: url.path)
                    try FileManager.default.moveItem(at: away, to: root)
                    try require(!recoveredMissingFile && Store.recovery.failure != nil && Store.recovery.generation == generation, "Failed reload keeps writes paused and the current UI generation")
                    try require(!recreatedEmptyFile && drafts.task == originalDraft, "Missing store never creates an empty database or discards a draft")
                }
                try require(Store.recovery.reload(), "Reload opens committed data without restarting: " + operation)
                let fresh = Store.recovery.container!.mainContext
                let after = try TaskBackup.capture(fresh)
                try require(after.tasks == saved.tasks && after.lists.first?.name == saved.lists.first?.name, "Recovery leaves failed changes out of disk data: " + operation)
                try require(Store.recovery.generation == generation + 1 && Store.recovery.failure == nil, "Recovery replaces UI model generation: " + operation)
                try require(drafts.task == originalDraft && drafts.list == originalListDraft, "Task/list drafts survive model reload: " + operation)
                try require((try? Store.save(context)) == nil && Store.recovery.failure == nil, "Old context cannot write or relock recovered session: " + operation)
                let recovered = try fresh.fetch(FetchDescriptor<TaskItem>()).first!
                recovered.title = "Saved after " + operation
                try Store.save(fresh)
                let verified = try Store.make(url: url)
                try require(try verified.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == recovered.title, "Fresh context successfully saves after recovery: " + operation)
            }
        }
    }

    static func frozenMigration(require: (Bool, String) throws -> Void) throws {
        if let path = ProcessInfo.processInfo.environment["JIANSHI_MIGRATION_COPY"] {
            let source = URL(fileURLWithPath: path)
            _ = try StoreUpgradeSnapshot.prepare(source)
            let migrated = try Store.make(url: source)
            let before = try TaskBackup.capture(migrated.mainContext)
            @MainActor func checkSyncState(_ context: ModelContext) throws {
                let environment = ProcessInfo.processInfo.environment
                guard let statePath = environment["JIANSHI_MIGRATION_CLOUD_STATE"],
                      let baselinePath = environment["JIANSHI_MIGRATION_CLOUD_BASELINE"] else { return }
                struct ExpectedState: Decodable {
                    let enabled: Bool
                    let account: String
                    let lastSyncMilliseconds: Double
                    let baselineSHA256: String
                }
                let expected = try JSONDecoder().decode(ExpectedState.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
                let baseline = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
                let states = try context.fetch(FetchDescriptor<CloudSyncState>())
                try require(states.count == 1, "Frozen migration preserves exactly one sync state")
                guard let state = states.first else { return }
                let enabled = state.enabled, account = state.account
                let lastSync = state.lastSync, savedBaseline = state.baseline
                try require(enabled == expected.enabled && account == expected.account,
                            "Frozen migration preserves sync consent and account binding")
                try require(lastSync.map { abs($0.timeIntervalSince1970 * 1000 - expected.lastSyncMilliseconds) < 1 } == true,
                            "Frozen migration preserves last successful sync time")
                try require(savedBaseline == baseline && CloudMerge.digest(baseline) == expected.baselineSHA256,
                            "Frozen migration preserves the exact conflict merge baseline")
            }
            try checkSyncState(migrated.mainContext)
            if let expectedPath = ProcessInfo.processInfo.environment["JIANSHI_MIGRATION_EXPECTED"] {
                var expected = try TaskBackup.decode(Data(contentsOf: URL(fileURLWithPath: expectedPath)))
                // Compare saved fields strictly while accepting the current export version and newly added empty table.
                // The old CloudSyncState baseline is checked byte-for-byte above, without normalization.
                expected.version = before.version
                if expected.weekTitles == nil {
                    try require(before.weekTitles?.isEmpty == true, "A schema without week titles migrates to an empty week-title table")
                    expected.weekTitles = []
                }
                try require(try BackupFiles.contentData(before) == BackupFiles.contentData(expected),
                            "Previous-version schema migrates every task/list field, link, subtask and identity unchanged")
            }
            try Store.save(migrated.mainContext)
            let reopened = try Store.make(url: URL(fileURLWithPath: path))
            let after = try TaskBackup.capture(reopened.mainContext)
            try require(try BackupFiles.contentData(before) == BackupFiles.contentData(after),
                        "Frozen migration preserves task, list, week title and finance data after save and reopen")
            try checkSyncState(reopened.mainContext)
            try require(Set(before.tasks.map(\.id)) == Set(after.tasks.map(\.id)) && Set(before.lists.map(\.id)) == Set(after.lists.map(\.id)), "Migration preserves all task and list identities")
            try require(Set(after.lists.compactMap { $0.colorHex?.uppercased() }).count == after.lists.count, "Migrated store has distinct list colors")
        }
    }
    static func restoreCheckpoints(directory: URL, require: (Bool, String) throws -> Void) throws {
        let fm = FileManager.default
        for round in 0..<3 {
            let folder = directory.appendingPathComponent("restore-checkpoints-\(round)")
            let container = try Store.make(url: directory.appendingPathComponent("restore-checkpoints-\(round).store"))
            let context = container.mainContext
            let originalTask = TaskItem(title: "Original before recovery")
            originalTask.createdAt = Date(timeIntervalSince1970: 1700000000)
            context.insert(originalTask)
            try Store.save(context)
            let original = try TaskBackup.capture(context)
            let originalData = try original.encoded()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let legacy = folder.appendingPathComponent("before-last-restore.json")
            try originalData.write(to: legacy, options: .atomic)
            var wrong = original
            wrong.tasks[0].title = "Restored wrong file"
            let first = try wrong.restoreKeepingCopy(context, replace: true, directory: folder)
            let second = try wrong.restoreKeepingCopy(context, replace: true, directory: folder)
            let firstData = try Data(contentsOf: first.copy.url)
            let firstSnapshot = try TaskBackup.decode(firstData)
            let secondSnapshot = try TaskBackup.decode(Data(contentsOf: second.copy.url))
            try require(firstSnapshot.tasks == original.tasks && secondSnapshot.tasks == wrong.tasks,
                        "two consecutive restores retain both pre-restore states independently")
            try require(first.copy.url != second.copy.url && !first.cleanupFailed && !second.cleanupFailed,
                        "repeated restores have unique verified checkpoints")
            _ = try BackupFiles.write(wrong.encoded(), directory: folder, owner: "test-device")
            _ = try BackupFiles.write(wrong.encoded(), directory: folder, owner: "test-device")
            try require(try Data(contentsOf: first.copy.url) == firstData,
                        "hourly automatic backup pruning cannot remove a pre-restore checkpoint")
            _ = try firstSnapshot.restoreKeepingCopy(context, replace: true, directory: folder)
            try require(try TaskBackup.capture(context).tasks == original.tasks,
                        "original data remains recoverable after two mistaken replacements")
            let beforeFailure = try BackupFiles.contentData(TaskBackup.capture(context))
            let blocker = folder.appendingPathComponent("not-a-directory")
            try Data("file blocks directory creation".utf8).write(to: blocker)
            var failed = false
            do { _ = try wrong.restoreKeepingCopy(context, replace: true, directory: blocker) } catch { failed = true }
            try require(failed && (try BackupFiles.contentData(TaskBackup.capture(context))) == beforeFailure,
                        "checkpoint write failure prevents restore and preserves existing data")
            let count = try RestoreBackupFiles.copies(in: folder).count
            var invalid = wrong; invalid.tasks.append(invalid.tasks[0])
            failed = false
            do { _ = try invalid.restoreKeepingCopy(context, replace: true, directory: folder) } catch { failed = true }
            try require(failed && (try RestoreBackupFiles.copies(in: folder).count) == count,
                        "invalid incoming backups are rejected before consuming checkpoint retention")
            failed = false
            do { _ = try RestoreBackupFiles.write(Data("broken".utf8), directory: folder) } catch { failed = true }
            try require(failed && (try Data(contentsOf: first.copy.url)) == firstData,
                        "invalid checkpoint bytes cannot prune earlier copies")

            // Incomplete staging files and unrelated manual exports never count toward retention.
            let partial = folder.appendingPathComponent(".restore-partial-interrupted")
            let manual = folder.appendingPathComponent("manual.json")
            let lookalike = folder.appendingPathComponent("before-restore-not-ours.json")
            for file in [partial, manual, lookalike] { try originalData.write(to: file) }
            let now = Date()
            var written: [URL] = []
            for index in 0..<15 {
                var snapshot = original; snapshot.tasks[0].title = "Before restore \(index)"
                // Include an identical clock and repeated backward-clock changes.
                let result = try RestoreBackupFiles.write(snapshot.encoded(), directory: folder, now: now.addingTimeInterval(-Double(index)))
                written.append(result.copy.url)
                try require(try RestoreBackupFiles.copies(in: folder).first?.id == result.copy.id,
                            "new restore checkpoint stays first even with a backward clock")
            }
            let copies = try RestoreBackupFiles.copies(in: folder)
            try require(copies.filter { !$0.legacy }.map(\.id) == written.suffix(10).reversed().map(\.lastPathComponent),
                        "restore retention keeps exactly the ten latest successful writes")
            try require(copies.last?.legacy == true && (try Data(contentsOf: legacy)) == originalData,
                        "the old fixed-name recovery file stays readable and is never overwritten or pruned")
            try require([partial, manual, lookalike].allSatisfy { fm.fileExists(atPath: $0.path) },
                        "retention ignores interrupted staging files and unrelated exports")
            let reopened = try Store.make(url: directory.appendingPathComponent("restore-checkpoints-\(round).store"))
            try require(try TaskBackup.capture(reopened.mainContext).tasks == original.tasks,
                        "checkpoint and failed-restore checks preserve stored data after reopening")
            var removed: [URL] = []
            let cleanupFailed = RestoreBackupFiles.pruneOlderCopies(copies) { url in
                removed.append(url); throw CocoaError(.fileWriteNoPermission)
            }
            try require(cleanupFailed && removed == [copies[9].url] && (try RestoreBackupFiles.copies(in: folder).count) == copies.count,
                        "cleanup failure is reported while all recovery copies remain available")
            var retryRemoved: [URL] = []
            let retryFailed = RestoreBackupFiles.pruneOlderCopies(copies) { retryRemoved.append($0) }
            try require(!retryFailed && retryRemoved == removed, "cleanup can retry the same old copies without touching the legacy or recent ones")
        }
        print("RESTORE CHECKPOINT PASS: three isolated restore/retention/failure rounds")
    }

    static func damagedLedgerRecovery(directory: URL, require: (Bool, String) throws -> Void) throws {
        let fm = FileManager.default
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            var rejected = false
            do { try operation() } catch { rejected = true }
            try require(rejected, label)
        }
        for round in 0..<3 {
            for kind in ["json", "currency", "future", "duplicate"] {
                let url = directory.appendingPathComponent("damaged-ledger-\(round)-\(kind).store")
                let folder = directory.appendingPathComponent("damaged-copies-\(round)-\(kind)")
                let db = try Store.make(url: url), context = db.mainContext
                let task = TaskItem(title: "Original task")
                task.createdAt = Date(timeIntervalSince1970: 1700000000)
                context.insert(task)
                var ledger = FinanceData.initial
                let removedBook = MoneyBook(name: "Old book absent from backup")
                ledger.books.append(removedBook)
                try FinanceStore.stage(ledger, in: context)
                try Store.save(context)
                let original = try TaskBackup.capture(context)
                var backup = original
                backup.tasks[0].title = "Restored task"
                backup.finance = .initial
                let row = try context.fetch(FetchDescriptor<FinanceLedger>())[0]
                switch kind {
                case "json": row.payload = Data([0xFF, 0x00, 0x7B])
                case "currency": ledger.baseCurrency = "INVALID"; row.payload = try JSONEncoder().encode(ledger)
                case "future": ledger.version = 999; row.payload = try JSONEncoder().encode(ledger)
                default: context.insert(FinanceLedger(payload: row.payload))
                }
                try Store.save(context, trackSyncChanges: false)
                let raw = try context.fetch(FetchDescriptor<FinanceLedger>()).map(\.payload)
                try require(try DamagedLedgerRecovery.isNeeded(context), "damaged ledger is detected: " + kind)
                try rejects("ordinary restore still refuses unreadable current data") { _ = try backup.restoreKeepingCopy(context, replace: true, directory: folder) }
                var taskOnly = backup; taskOnly.finance = nil
                try rejects("task-only backup cannot erase an unreadable ledger") { _ = try taskOnly.restoreDamagedLedger(context, directory: folder) }
                var invalid = backup; invalid.tasks[0].title = ""
                try rejects("invalid incoming backup cannot begin recovery") { _ = try invalid.restoreDamagedLedger(context, directory: folder) }
                try require(!fm.fileExists(atPath: folder.path), "invalid requests create no raw snapshots")
                task.title = "Unsaved elsewhere"
                try rejects("pending model changes prevent raw recovery") { _ = try backup.restoreDamagedLedger(context, directory: folder) }
                context.rollback()
                let sync = try context.fetch(FetchDescriptor<CloudSyncState>())[0]
                sync.enabled = true; try Store.save(context, trackSyncChanges: false)
                try rejects("enabled sync prevents exceptional recovery") { _ = try backup.restoreDamagedLedger(context, directory: folder) }
                sync.enabled = false; try Store.save(context, trackSyncChanges: false)
                let blocked = directory.appendingPathComponent("blocked-\(round)-\(kind)")
                try Data("file instead of directory".utf8).write(to: blocked)
                try rejects("snapshot write failure stops before modifying data") { _ = try backup.restoreDamagedLedger(context, directory: blocked) }
                try require(try context.fetch(FetchDescriptor<TaskItem>()).first?.title == "Original task" && !context.hasChanges, "failed preservation leaves current tasks untouched")
                try rejects("interruption after staging rolls back replacement") {
                    _ = try backup.restoreDamagedLedger(context, directory: folder) { throw CocoaError(.fileWriteOutOfSpace) }
                }
                try require(!context.hasChanges && (try context.fetch(FetchDescriptor<FinanceLedger>()).map(\.payload)) == raw,
                            "failed restore restores every original ledger byte")
                try require(try context.fetch(FetchDescriptor<TaskItem>()).first?.title == "Original task", "failed restore rolls back tasks too")
                let failedCopies = try DamagedLedgerRecovery.copies(in: folder)
                try require(failedCopies.count == 1, "original survives even a failed restore")
                let readOnly = try ModelContainer(for: db.schema, configurations: [ModelConfiguration(schema: db.schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
                readOnly.mainContext.autosaveEnabled = false
                try rejects("actual write rejection cannot commit a partial recovery") {
                    _ = try backup.restoreDamagedLedger(readOnly.mainContext, directory: folder)
                }
                try require(Store.recovery.failure != nil && Store.recovery.needsLedgerRecovery, "actual persistence failure pauses editing and permits a guarded recovery retry")
                try require((try? Store.recovery.requireWritable(readOnly.mainContext)) == nil, "failed recovery context cannot be reused")
                try require(Store.recovery.reload(), "failed recovery can reload committed original data")
                let afterFailure = Store.recovery.container!.mainContext
                try require(try afterFailure.fetch(FetchDescriptor<FinanceLedger>()).map(\.payload) == raw,
                            "reopening after a disk write rejection preserves every unreadable ledger byte")
                try require(try afterFailure.fetch(FetchDescriptor<TaskItem>()).first?.title == "Original task", "write failure preserves committed task data")
                let savedCopy = try backup.restoreDamagedLedger(afterFailure, directory: folder)
                try require(try DamagedLedgerRecovery.copies(in: folder).count == 3 && savedCopy != failedCopies[0], "retry preserves previous raw copies")
                let preserved = try Store.make(url: savedCopy)
                try require(try preserved.mainContext.fetch(FetchDescriptor<FinanceLedger>()).map(\.payload) == raw, "SQLite copy preserves unreadable payloads including duplicates and committed WAL data")
                try require(try preserved.mainContext.fetch(FetchDescriptor<TaskItem>()).first?.title == "Original task", "raw copy includes original tasks")
                let reopened = try Store.make(url: url)
                let restored = try TaskBackup.capture(reopened.mainContext)
                try require(restored.tasks == backup.tasks && restored.finance == backup.finance, "complete replacement survives reopening")
                try require(try reopened.mainContext.fetch(FetchDescriptor<CloudSyncState>()).allSatisfy { !$0.enabled }, "successful recovery does not enable sync")
                let removed = restored.syncChanges?[SyncChanges.key("book", removedBook.id)]
                try require(removed != nil && removed?.fingerprint == nil && removed?.version != nil, "known removed ledger rows receive causal deletion history")
                let merged = try PartialSyncMerge.prepare(local: restored, cloud: original, base: original, cloudExists: true, choices: [:], now: Date())
                try require(merged.conflict == nil && merged.localSnapshot.finance == backup.finance, "old cloud snapshot cannot resurrect known removed rows after recovery")
                try rejects("recovery does not run again on a healthy ledger") { _ = try backup.restoreDamagedLedger(reopened.mainContext, directory: folder) }
            }
        }
        print("DAMAGED LEDGER RECOVERY PASS: three rounds of four failure types, raw preservation, rollback, retry and offline sync merge")
    }

}
