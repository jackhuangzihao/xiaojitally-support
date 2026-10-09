import Foundation
import SwiftData

extension CloudMerge {
    @MainActor static func checkAutomaticSync() throws -> Int {
        var count = 0
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw TaskBackup.invalid("AUTOMATIC SYNC CHECK: " + label) }; count += 1
        }
        func tracked(_ snapshot: TaskBackup, from previous: TaskBackup? = nil, at date: Date) throws -> TaskBackup {
            var result = snapshot, revisions = previous?.syncChanges ?? [:]
            let old = try previous.map(SyncChanges.fingerprints) ?? [:]
            let new = try SyncChanges.fingerprints(snapshot)
            var changed: [String: String?] = [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] { changed[key] = .some(new[key]) }
            SyncChanges.record(changed, in: &revisions, now: date,
                fieldFingerprints: try SyncFields.snapshot(snapshot),
                previousFieldFingerprints: try previous.map(SyncFields.snapshot) ?? [:],
                createdKeys: Set(new.keys).subtracting(old.keys))
            result.syncChanges = revisions
            return result
        }
        func converges(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup, automatic expected: Int? = nil) throws -> TaskBackup {
            let outcome = try mergeResult(local: local, cloud: cloud, base: base, now: now)
            let result = outcome.snapshot
            if let expected { try check(outcome.automaticFieldCount == expected, "only competing ordinary fields count as automatic decisions") }
            let encoded = try bytes(result)
            try check(try bytes(merge(local: cloud, cloud: local, base: base, now: now)) == encoded,
                      "swapping devices preserves both values and field history")
            for _ in 0..<3 {
                try check(try bytes(merge(local: result, cloud: result, base: base, now: now)) == encoded,
                          "repeated sync keeps identical contents and field history")
            }
            return result
        }
        func requiresReview(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup?, _ label: String) throws {
            for reverse in [false, true] {
                do {
                    _ = try merge(local: reverse ? cloud : local, cloud: reverse ? local : cloud, base: base, now: now)
                } catch is Conflict { try check(true, label); continue }
                throw TaskBackup.invalid("AUTOMATIC SYNC CHECK: " + label)
            }
        }
        func resolved(_ local: TaskBackup, _ cloud: TaskBackup, _ base: TaskBackup,
                      choices: [String: Choice], automatic expected: Int) throws -> TaskBackup {
            let result = try mergeResult(local: local, cloud: cloud, base: base, choices: choices, now: now)
            let encoded = try bytes(result.snapshot)
            let reversed = choices.mapValues { $0 == .local ? Choice.cloud : Choice.local }
            let other = try mergeResult(local: cloud, cloud: local, base: base, choices: reversed, now: now)
            try check(result.automaticFieldCount == expected && other.automaticFieldCount == expected,
                      "manual review does not count unresolved fields as automatic")
            try check(try bytes(other.snapshot) == encoded, "manual decisions and automatic fields survive exchanged device roles")
            for _ in 0..<3 {
                try check(try bytes(merge(local: result.snapshot, cloud: result.snapshot, base: base, now: now)) == encoded,
                          "a resolved merge stays unchanged on later syncs")
            }
            return result.snapshot
        }

        // Repeat with different records and clocks so order cannot accidentally determine a winner.
        for round in 0..<3 {
            let t0 = now.addingTimeInterval(Double(-1000 + round * 100))
            let t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20), t3 = t0.addingTimeInterval(30)
            let lists = (0..<3).map { TaskBackup.ListRecord(id: UUID(), name: "List \($0)", createdAt: t0,
                colorHex: ["123456", "56789A", "ABCDEF"][$0], sortOrder: Double($0), emoji: "📚") }
            var task = TaskBackup.TaskRecord(TaskItem(title: "Original"))
            task.createdAt = t0; task.listID = lists[0].id
            task.scheduledAt = now.addingTimeInterval(86400); task.hasTime = true
            task.endAt = task.scheduledAt!.addingTimeInterval(3600)
            var ledger = FinanceData.initial
            ledger.entries = [MoneyEntry(title: "Purchase", amount: 100, bookID: ledger.books[0].id, baseAmount: 100)]
            ledger.entries[0].date = t0
            let base = try tracked(TaskBackup(finance: ledger, weekTitles: [.init(week: "2026-09-28", title: "Original week")],
                lists: lists, tasks: [task]), at: t0)
            let key = SyncChanges.key("task", task.id)
            var local = base, cloud = base
            local.tasks[0].title = "Earlier title"
            local = try tracked(local, from: base, at: t1)
            let earlyLocal = local
            local.tasks[0].notes = "Later unrelated note"
            local = try tracked(local, from: earlyLocal, at: t3)
            cloud.tasks[0].title = "Newer title"
            cloud = try tracked(cloud, from: base, at: t2)
            let combined = try converges(local, cloud, base, automatic: 1)
            try check(combined.tasks[0].title == "Newer title" && combined.tasks[0].notes == "Later unrelated note",
                      "a later note edit cannot make an older title win")
            try check(combined.syncChanges?[key]?.fields?["title"] == cloud.syncChanges?[key]?.fields?["title"]
                      && combined.syncChanges?[key]?.fields?["notes"] == local.syncChanges?[key]?.fields?["notes"],
                      "combined fields keep their own source dates")
            var third = base; third.tasks[0].title = "Third device title"
            third = try tracked(third, from: base, at: t2.addingTimeInterval(5))
            let thirdResult = try converges(combined, third, base, automatic: 1)
            try check(thirdResult.tasks[0].title == "Third device title" && thirdResult.tasks[0].notes == local.tasks[0].notes,
                      "a third device sees the winning title's age, not the record's later note date")

            local = base; cloud = base
            for side in 0..<2 {
                var value = side == 0 ? local : cloud
                value.tasks[0].title = "Title \(side)"; value.tasks[0].notes = "Notes \(side)"
                value.tasks[0].priority = side + 1; value.tasks[0].listID = lists[side + 1].id
                value.tasks[0].scheduledAt = task.scheduledAt!.addingTimeInterval(Double((side + 1) * 86400))
                value.tasks[0].endAt = value.tasks[0].scheduledAt!.addingTimeInterval(Double((side + 1) * 3600))
                value.tasks[0].isDone = true; value.tasks[0].completedAt = side == 0 ? t1 : t2
                value = try tracked(value, from: base, at: side == 0 ? t1 : t2)
                if side == 0 { local = value } else { cloud = value }
            }
            let ordinary = try converges(local, cloud, base, automatic: 6)
            try check(ordinary.tasks == cloud.tasks, "task title, note, priority, list, timing and completion choose their newer values")
            let manual = try mergeResult(local: local, cloud: cloud, base: base, choice: .local, now: now)
            try check(manual.snapshot.tasks == cloud.tasks && manual.automaticFieldCount == 6,
                      "a manual fallback cannot override fields already resolved automatically")

            var mixedBase = base
            mixedBase.tasks[0].subtasks = [Subtask(title: "Original step")]
            mixedBase = try tracked(mixedBase, from: base, at: t0)
            local = mixedBase; cloud = mixedBase
            local.tasks[0].title = "Earlier title"; cloud.tasks[0].title = "Later title"
            local.tasks[0].subtasks[0].title = "Local step"; cloud.tasks[0].subtasks[0].title = "Cloud step"
            local.lists[0].name = "Earlier list"; cloud.lists[0].name = "Later list"
            local.lists[0].parentID = lists[1].id; cloud.lists[0].parentID = lists[2].id
            local.finance!.entries[0].notes = "Earlier note"; cloud.finance!.entries[0].notes = "Later note"
            local.finance!.entries[0].amount = 120; local.finance!.entries[0].baseAmount = 120
            cloud.finance!.entries[0].amount = 150; cloud.finance!.entries[0].baseAmount = 150
            local = try tracked(local, from: mixedBase, at: t1); cloud = try tracked(cloud, from: mixedBase, at: t2)
            try requiresReview(local, cloud, mixedBase, "subtasks, hierarchy and monetary fields still require review beside automatic text")
            let listKey = SyncChanges.key("list", lists[0].id)
            let entryKey = SyncChanges.key("entry", ledger.entries[0].id)
            for selected in [Choice.local, .cloud] {
                let reviewed = try resolved(local, cloud, mixedBase,
                    choices: [key: selected, listKey: selected, entryKey: selected], automatic: 3)
                let chosen = selected == .local ? local : cloud
                try check(reviewed.tasks[0].title == cloud.tasks[0].title
                          && reviewed.tasks[0].subtasks == chosen.tasks[0].subtasks,
                          "choosing a subtask version keeps the automatically selected newer task title")
                let list = reviewed.lists.first { $0.id == lists[0].id }
                try check(list?.name == cloud.lists[0].name && list?.parentID == chosen.lists[0].parentID,
                          "choosing hierarchy keeps the automatically selected newer list name")
                try check(reviewed.finance?.entries[0].notes == cloud.finance?.entries[0].notes
                          && reviewed.finance?.entries[0].amount == chosen.finance?.entries[0].amount,
                          "choosing monetary fields keeps the automatically selected newer entry note")
                let preserved = reviewed.syncChanges?[key]?.fields?["title"], source = cloud.syncChanges?[key]?.fields?["title"]
                try check(preserved?.date == source?.date && preserved?.fingerprint == source?.fingerprint,
                          "manual review preserves the automatic title's source date and contents while acknowledging both edits")
            }
            local = base; cloud = base
            local.tasks[0].scheduledAt = task.scheduledAt!.addingTimeInterval(86400)
            local.tasks[0].endAt = local.tasks[0].scheduledAt!.addingTimeInterval(7200)
            cloud.tasks[0].isDone = true; cloud.tasks[0].completedAt = t2
            let independent = try converges(try tracked(local, from: base, at: t1), try tracked(cloud, from: base, at: t2), base, automatic: 0)
            try check(independent.tasks[0].scheduledAt == local.tasks[0].scheduledAt && independent.tasks[0].isDone,
                      "a nonrepeating task can merge independent schedule and completion edits")

            let modelList = TaskList(name: lists[0].name); modelList.id = lists[0].id
            let dragged = task.model(list: modelList), scheduled = task.model(list: modelList)
            let earlierDay = Dates.calendar.date(byAdding: .day, value: 2, to: task.scheduledAt!)!
            let laterDay = Dates.calendar.date(byAdding: .day, value: 4, to: task.scheduledAt!)!
            try check(TaskMove(dragged, to: earlierDay, kind: .timed).apply(to: dragged, shiftDeadline: false),
                      "real timeline drag changes the earlier device's task")
            scheduled.schedule(at: laterDay)
            local = base; local.tasks[0] = .init(dragged)
            cloud = base; cloud.tasks[0] = .init(scheduled)
            let moved = try converges(try tracked(local, from: base, at: t1), try tracked(cloud, from: base, at: t2), base, automatic: 1)
            try check(moved.tasks[0] == cloud.tasks[0] && moved.tasks[0].scheduledAt == laterDay
                      && moved.tasks[0].repeatAnchorDay == Dates.calendar.component(.day, from: laterDay)
                      && local.tasks[0].repeatAnchorDay != cloud.tasks[0].repeatAnchorDay,
                      "real drag and scheduling edits select the newer complete timing group, including its day anchor")

            local = base; cloud = base
            local.lists[0].name = "Earlier name"; local.lists[0].colorHex = "112233"
            local.lists[0].emoji = "🏡"; local.lists[0].sortOrder = 4
            cloud.lists[0].name = "Newer name"; cloud.lists[0].colorHex = "445566"
            cloud.lists[0].emoji = "🎯"; cloud.lists[0].sortOrder = 5
            local.weekTitles![0].title = "Earlier week"; cloud.weekTitles![0].title = "Newer week"
            local = try tracked(local, from: base, at: t1); cloud = try tracked(cloud, from: base, at: t2)
            let named = try converges(local, cloud, base, automatic: 5)
            try check(named.lists.first { $0.id == lists[0].id } == cloud.lists[0] && named.weekTitles == cloud.weekTitles,
                      "list appearance, ordering and week titles choose newer fields")
            local = base; cloud = base
            local.lists[0].name = "Independent name"; cloud.lists[0].colorHex = "334455"
            let decorated = try converges(local, cloud, base, automatic: 0)
            try check(decorated.lists.first { $0.id == lists[0].id }?.name == "Independent name"
                      && decorated.lists.first { $0.id == lists[0].id }?.colorHex == "334455",
                      "separate list fields merge even without new stamps")
            local = base; cloud = base
            local.lists[0].parentID = lists[1].id; cloud.lists[0].parentID = lists[2].id
            try requiresReview(try tracked(local, from: base, at: t1), try tracked(cloud, from: base, at: t2), base,
                               "competing list hierarchy edits remain manual")

            local = base; cloud = base
            local.finance!.entries[0].title = "Earlier receipt"; local.finance!.entries[0].notes = "Earlier note"
            local.finance!.entries[0].tags = "earlier"
            cloud.finance!.entries[0].title = "Newer receipt"; cloud.finance!.entries[0].notes = "Newer note"
            cloud.finance!.entries[0].tags = "newer"
            local = try tracked(local, from: base, at: t1); cloud = try tracked(cloud, from: base, at: t2)
            let receipt = try converges(local, cloud, base, automatic: 3)
            try check(receipt.finance?.entries == cloud.finance?.entries, "entry title, notes and tags choose newer text")
            local = base; cloud = base
            local.finance!.entries[0].amount = 120; local.finance!.entries[0].baseAmount = 120
            cloud.finance!.entries[0].notes = "Receipt details"
            let moneyAndNote = try converges(try tracked(local, from: base, at: t1), try tracked(cloud, from: base, at: t2), base, automatic: 0)
            try check(moneyAndNote.finance?.entries[0].amount == 120 && moneyAndNote.finance?.entries[0].notes == "Receipt details",
                      "a monetary edit and an independent note both survive")
            cloud.finance!.entries[0].amount = 150; cloud.finance!.entries[0].baseAmount = 150
            try requiresReview(try tracked(local, from: base, at: t1), try tracked(cloud, from: base, at: t2), base,
                               "competing monetary groups cannot be selected by text timestamps")

            local = earlyLocal; cloud = base
            cloud.tasks[0].title = "Competing title"; cloud = try tracked(cloud, from: base, at: t2)
            for invalid in ["missing history", "missing field", "unknown date", "equal date", "future date", "old date", "ahead of record", "stale field", "stale record"] {
                var suspect = cloud
                switch invalid {
                case "missing history": suspect.syncChanges = nil
                case "missing field": suspect.syncChanges![key]!.fields!.removeValue(forKey: "title")
                case "unknown date": suspect.syncChanges![key]!.fields!["title"]!.date = nil
                case "equal date": suspect.syncChanges![key]!.fields!["title"]!.date = t1
                case "future date":
                    suspect.syncChanges![key]!.date = now.addingTimeInterval(301)
                    suspect.syncChanges![key]!.fields!["title"]!.date = now.addingTimeInterval(301)
                case "old date": suspect.syncChanges![key]!.fields!["title"]!.date = t0
                case "ahead of record": suspect.syncChanges![key]!.fields!["title"]!.date = t3
                case "stale field": suspect.syncChanges![key]!.fields!["title"]!.fingerprint = try SyncChanges.fingerprint("Unrelated")
                default: suspect.syncChanges![key]!.fingerprint = try SyncChanges.fingerprint("Unrelated record")
                }
                try requiresReview(local, suspect, base, invalid + " falls back to review")
            }
            try requiresReview(local, cloud, nil, "matching clocks without a shared record baseline remain manual")
            var legacyBase = base; legacyBase.version = 8; legacyBase.syncChanges = nil
            let upgraded = try converges(local, cloud, legacyBase, automatic: 1)
            try check(upgraded.tasks[0].title == cloud.tasks[0].title, "known new field edits can merge against an older shared baseline")
            var legacyLocal = local, legacyCloud = cloud; legacyLocal.syncChanges = nil; legacyCloud.syncChanges = nil
            try requiresReview(legacyLocal, legacyCloud, legacyBase, "old clients' conflicting values remain reviewable")
            let oldBytes = try legacyBase.encoded()
            try check(try TaskBackup.decode(oldBytes).syncChanges == nil, "legacy snapshots decode without fabricated field history")
            var deleted = base; deleted.tasks.removeAll(); deleted = try tracked(deleted, from: base, at: t3)
            try requiresReview(local, deleted, base, "permanent deletion versus an edit stays manual despite a newer tombstone")
            try requiresReview(local, deleted, nil, "first-sync tombstone versus a live row stays manual")
            var trashed = base; trashed.tasks[0].deletedAt = t3
            try requiresReview(local, try tracked(trashed, from: base, at: t3), base, "soft deletion cannot hide an independently edited task")
            let removed = try converges(base, deleted, base, automatic: 0)
            try check(removed.tasks.isEmpty && removed.syncChanges?[key]?.fingerprint == nil,
                      "one-sided removal preserves deletion history")

            var repeatBase = base; repeatBase.tasks[0].repeatRule = "daily"
            repeatBase = try tracked(repeatBase, from: base, at: t1)
            local = repeatBase; cloud = repeatBase
            var nextA = task, nextB = task
            nextA.id = UUID(); nextB.id = UUID(); nextA.repeatRule = "daily"; nextB.repeatRule = "daily"
            nextA.scheduledAt = task.scheduledAt!.addingTimeInterval(86400); nextA.endAt = nextA.scheduledAt!.addingTimeInterval(3600)
            nextB.scheduledAt = nextA.scheduledAt; nextB.endAt = nextA.endAt
            local.tasks[0].isDone = true; local.tasks[0].completedAt = t2; local.tasks[0].nextOccurrenceID = nextA.id; local.tasks.append(nextA)
            cloud.tasks[0].isDone = true; cloud.tasks[0].completedAt = t3; cloud.tasks[0].nextOccurrenceID = nextB.id; cloud.tasks.append(nextB)
            try requiresReview(try tracked(local, from: repeatBase, at: t2), try tracked(cloud, from: repeatBase, at: t3), repeatBase,
                               "competing repeat successors remain an atomic manual decision")
            local = repeatBase; cloud = repeatBase
            local.tasks[0].scheduledAt = task.scheduledAt!.addingTimeInterval(86400); local.tasks[0].endAt = local.tasks[0].scheduledAt!.addingTimeInterval(3600)
            cloud.tasks[0].scheduledAt = task.scheduledAt!.addingTimeInterval(172800); cloud.tasks[0].endAt = cloud.tasks[0].scheduledAt!.addingTimeInterval(3600)
            try requiresReview(try tracked(local, from: repeatBase, at: t2), try tracked(cloud, from: repeatBase, at: t3), repeatBase,
                               "repeat timing remains a whole lifecycle decision")

            var checklist = base; checklist.tasks[0].subtasks = [Subtask(title: "Existing")]
            local = checklist; cloud = checklist
            local.tasks[0].subtasks[0].title = "Renamed"; cloud.tasks[0].subtasks[0].isDone = true
            let addedA = [Subtask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, title: "A first"),
                          Subtask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "A second")]
            let addedB = [Subtask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "B first"),
                          Subtask(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "B second")]
            local.tasks[0].subtasks.append(contentsOf: addedA); cloud.tasks[0].subtasks.append(contentsOf: addedB)
            let steps = try converges(local, cloud, checklist, automatic: 0)
            try check(Set(steps.tasks[0].subtasks.map(\.id)) == Set([checklist.tasks[0].subtasks[0].id] + (addedA + addedB).map(\.id))
                      && steps.tasks[0].subtasks.first { $0.id == checklist.tasks[0].subtasks[0].id }?.title == "Renamed"
                      && steps.tasks[0].subtasks.first { $0.id == checklist.tasks[0].subtasks[0].id }?.isDone == true,
                      "subtask identity merges additions and separate title/completion edits")
            for additions in [addedA, addedB] {
                let ids = Set(additions.map(\.id))
                try check(steps.tasks[0].subtasks.filter { ids.contains($0.id) }.map(\.id) == additions.map(\.id),
                          "concurrent appends retain each device's chosen order even when UUID order is reversed")
            }
            local = checklist; cloud = checklist
            local.tasks[0].subtasks[0].title = "A title"; cloud.tasks[0].subtasks[0].title = "B title"
            try requiresReview(try tracked(local, from: checklist, at: t1), try tracked(cloud, from: checklist, at: t2), checklist,
                               "a true subtask field conflict remains reviewable")
            local.tasks[0].subtasks.removeAll()
            try requiresReview(local, cloud, checklist, "subtask deletion versus editing stays manual")
            var orderedBase = checklist
            orderedBase.tasks[0].subtasks.append(Subtask(title: "Second existing step"))
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks[0].title = "Retained edited first step"
            cloud.tasks[0].subtasks.removeFirst()
            let retained = try merge(local: local, cloud: cloud, base: orderedBase, choice: .local, now: now)
            try check(retained.tasks[0].subtasks.map(\.id) == orderedBase.tasks[0].subtasks.map(\.id)
                      && retained.tasks[0].subtasks[0].title == "Retained edited first step",
                      "manually retaining an edited subtask also preserves its original position")
            try check(try bytes(merge(local: cloud, cloud: local, base: orderedBase, choice: .cloud, now: now)) == bytes(retained),
                      "manual subtask retention preserves order when device roles are exchanged")

            let a = Subtask(title: "A"), b = Subtask(title: "B"), c = Subtask(title: "C")
            let beginning = Subtask(title: "Beginning"), middle = Subtask(title: "Middle"), end = Subtask(title: "End")
            orderedBase.tasks[0].subtasks = [a, b, c]
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks = [c, a, b]
            for (insertion, expected) in [([beginning, a, b, c], [c, beginning, a, b]),
                                           ([a, middle, b, c], [c, a, middle, b]),
                                           ([a, b, c, end], [c, end, a, b])] {
                cloud.tasks[0].subtasks = insertion
                let inserted = try converges(local, cloud, orderedBase, automatic: 0)
                try check(inserted.tasks[0].subtasks.map(\.id) == expected.map(\.id),
                          "beginning, middle and end insertions retain their adjacent existing step through a concurrent reorder")
            }
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks = [c, b]
            cloud.tasks[0].subtasks = [a, middle, b, c]
            let deletedAnchor = try converges(local, cloud, orderedBase, automatic: 0)
            try check(deletedAnchor.tasks[0].subtasks.map(\.id) == [c, middle, b].map(\.id),
                      "an insertion with a removed predecessor remains before its next surviving step")
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks = [a, middle, b, c]
            cloud.tasks[0].subtasks = [a, b, middle, c]
            try requiresReview(local, cloud, orderedBase, "the same new step inserted at different positions remains reviewable")
            for selected in [Choice.local, .cloud] {
                let position = try resolved(local, cloud, orderedBase, choices: [key: selected], automatic: 0)
                try check(position.tasks[0].subtasks == (selected == .local ? local : cloud).tasks[0].subtasks,
                          "a manual insertion-position choice selects only the disputed position")
            }
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks.insert(contentsOf: addedA, at: 1)
            cloud.tasks[0].subtasks.insert(contentsOf: addedB, at: 1)
            let concurrentInsertions = try converges(local, cloud, orderedBase, automatic: 0)
            try check(concurrentInsertions.tasks[0].subtasks.first?.id == a.id
                      && concurrentInsertions.tasks[0].subtasks.suffix(2).map(\.id) == [b.id, c.id],
                      "independent concurrent insertions share the intended interior slot")
            for additions in [addedA, addedB] {
                let ids = Set(additions.map(\.id))
                try check(concurrentInsertions.tasks[0].subtasks.filter { ids.contains($0.id) }.map(\.id) == additions.map(\.id),
                          "interior insertions preserve each device's ordering")
            }
            local = orderedBase; cloud = orderedBase
            local.tasks[0].subtasks = [beginning, middle]
            cloud.tasks[0].subtasks.append(end)
            let noAnchors = try converges(local, cloud, orderedBase, automatic: 0)
            try check(Set(noAnchors.tasks[0].subtasks.map(\.id)) == Set([beginning.id, middle.id, end.id])
                      && noAnchors.tasks[0].subtasks.filter { $0.id != end.id } == [beginning, middle],
                      "deleting every original anchor preserves new steps and their internal order")
            for crossedAnchors in [false, true] {
                local = orderedBase; cloud = orderedBase
                if crossedAnchors {
                    local.tasks[0].subtasks = [c, a, b]
                    cloud.tasks[0].subtasks = [a, beginning, b, c, end]
                } else {
                    local.tasks[0].subtasks = [a, beginning, end, b, c]
                    cloud.tasks[0].subtasks = [a, end, beginning, b, c]
                }
                try requiresReview(local, cloud, orderedBase, "incompatible insertion order or crossing anchors requires review")
                for selected in [Choice.local, .cloud] {
                    let sorted = try resolved(local, cloud, orderedBase, choices: [key: selected], automatic: 0)
                    let preferred = (selected == .local ? local : cloud).tasks[0].subtasks.map(\.id)
                    let all = Set(local.tasks[0].subtasks.map(\.id)).union(cloud.tasks[0].subtasks.map(\.id))
                    let actual = sorted.tasks[0].subtasks.map(\.id)
                    try check(Set(actual) == all && actual.count == all.count
                              && actual.filter(Set(preferred).contains) == preferred,
                              "an explicit order choice keeps its relative order and every step exactly once")
                }
            }
        }

        for sample in 0..<50 {
            let moment = Date(timeIntervalSince1970: 1_780_000_000 + Double(sample) * 123.456789 + 0.000123)
            var snapshot = TaskBackup(lists: [], tasks: [.init(TaskItem(title: "Fractional-clock fixture"))])
            let key = SyncChanges.key("task", snapshot.tasks[0].id)
            var previous: TaskBackup?
            for edit in 0..<4 {
                if edit > 0 { snapshot.tasks[0].notes = "Saved note \(edit)" }
                snapshot = try tracked(snapshot, from: previous, at: edit == 3 ? moment.addingTimeInterval(-3600) : moment)
                let revisions = snapshot.syncChanges!
                if let previous {
                    try check(revisions[key]?.fields?["title"] == previous.syncChanges?[key]?.fields?["title"]
                              && (revisions[key]?.fields?["notes"]?.date ?? .distantPast)
                              > (previous.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast),
                              "fractional, repeated and backwards clocks preserve untouched fields and advance edited fields")
                }
                for milliseconds in [false, true] {
                    let encoder = JSONEncoder(), decoder = JSONDecoder()
                    encoder.dateEncodingStrategy = milliseconds ? .millisecondsSince1970 : .deferredToDate
                    decoder.dateDecodingStrategy = milliseconds ? .millisecondsSince1970 : .deferredToDate
                    try check(try decoder.decode(SyncChanges.Revisions.self, from: encoder.encode(revisions)) == revisions,
                              "field history survives exact round trips through both stored and portable date formats")
                }
                previous = snapshot
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousCallback = Store.didSave; Store.didSave = nil
        defer { Store.didSave = previousCallback }
        let url = directory.appendingPathComponent("tracked.store")
        let store = try Store.make(url: url), context = store.mainContext
        let task = TaskItem(title: "Saved title"), list = TaskList(name: "Saved list")
        let week = CalendarWeekTitle(week: "2026-09-28", title: "Saved week")
        context.insert(list); context.insert(task); context.insert(week); task.list = list
        var finance = FinanceData.initial
        finance.entries = [MoneyEntry(title: "Saved entry", amount: 50, bookID: finance.books[0].id, baseAmount: 50)]
        try FinanceStore.stage(finance, in: context); try Store.save(context)
        let first = try TaskBackup.capture(context), key = SyncChanges.key("task", task.id)
        let listKey = SyncChanges.key("list", list.id), weekKey = SyncChanges.key("week", first.weekTitles![0].id)
        let entryKey = SyncChanges.key("entry", finance.entries[0].id)
        for recordKey in [key, listKey, weekKey, entryKey] {
            let hashes = try SyncFields.snapshot(first)[recordKey]!
            try check(hashes.allSatisfy { field, hash in first.syncChanges?[recordKey]?.fields?[field]?.fingerprint == hash
                      && first.syncChanges?[recordKey]?.fields?[field]?.date != nil },
                      "new records save matching field fingerprints and known creation dates")
        }
        task.notes = "Only the note changed"; try Store.save(context)
        let edited = try TaskBackup.capture(context)
        try check(edited.syncChanges?[key]?.fields?["title"] == first.syncChanges?[key]?.fields?["title"]
                  && (edited.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast) > (first.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast),
                  "saving a note advances only the changed field")
        let decoded = try TaskBackup.decode(edited.encoded())
        let reopened = try Store.make(url: url)
        try check(decoded.syncChanges == edited.syncChanges && (try SyncChanges.read(reopened.mainContext)) == edited.syncChanges,
                  "portable backups and reopening preserve complete field history")
        task.title = "Rolled back title"; try SyncChanges.trackModels(in: context); context.rollback()
        try check(try SyncChanges.read(context) == edited.syncChanges && TaskBackup.capture(context).tasks == edited.tasks,
                  "task rollback restores data and staged field history together")
        task.notes = "Clock moved backwards"; try SyncChanges.trackModels(in: context, now: now.addingTimeInterval(-10_000_000))
        let firstClockEdit = try SyncChanges.read(context)
        task.notes = "Another edit in the same millisecond"; try SyncChanges.trackModels(in: context, now: now.addingTimeInterval(-10_000_000))
        let secondClockEdit = try SyncChanges.read(context)
        try check((firstClockEdit?[key]?.fields?["notes"]?.date ?? .distantPast) > (edited.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast)
                  && (secondClockEdit?[key]?.fields?["notes"]?.date ?? .distantPast) > (firstClockEdit?[key]?.fields?["notes"]?.date ?? .distantPast)
                  && secondClockEdit?[key]?.fields?["title"] == edited.syncChanges?[key]?.fields?["title"],
                  "backwards and identical clocks still advance only changed fields")
        context.rollback()
        finance.entries[0].notes = "Rolled back receipt"; try FinanceStore.stage(finance, in: context); context.rollback()
        try check(try SyncChanges.read(context) == edited.syncChanges && FinanceStore.read(context)?.entries == edited.finance?.entries,
                  "finance rollback discards cached staged field history and payload")
        try first.restore(context, replace: true)
        let restored = try TaskBackup.capture(context)
        try check(restored.tasks[0].notes == first.tasks[0].notes
                  && restored.syncChanges?[key]?.fields?["title"] == edited.syncChanges?[key]?.fields?["title"]
                  && (restored.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast) > (edited.syncChanges?[key]?.fields?["notes"]?.date ?? .distantPast),
                  "backup restoration stamps only content actually changed by restoring")
        try first.restore(context, replace: false)
        try check(try TaskBackup.capture(context).syncChanges == restored.syncChanges,
                  "merge-missing restoration does not refresh existing field dates")

        let legacyStore = try Store.make(url: directory.appendingPathComponent("legacy.store"))
        let legacyTask = TaskItem(title: "Legacy title")
        legacyStore.mainContext.insert(legacyTask); try legacyStore.mainContext.save()
        legacyTask.notes = "First upgraded edit"; try Store.save(legacyStore.mainContext)
        let legacyKey = SyncChanges.key("task", legacyTask.id)
        let observed = try SyncChanges.read(legacyStore.mainContext)
        try check(observed?[legacyKey]?.fields?["title"]?.date == nil,
                  "first observing an old record cannot invent a recent title edit")
        legacyTask.notes = "Second upgraded edit"; try Store.save(legacyStore.mainContext)
        let known = try SyncChanges.read(legacyStore.mainContext)
        try check(known?[legacyKey]?.fields?["notes"]?.date != nil && known?[legacyKey]?.fields?["title"]?.date == nil,
                  "later known edits become dated while untouched legacy fields remain unknown")

        let schema = Schema([TaskItem.self, TaskList.self, FinanceLedger.self, CloudSyncState.self, CalendarWeekTitle.self])
        let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
        readOnly.mainContext.autosaveEnabled = false
        let committed = try TaskBackup.capture(readOnly.mainContext)
        let failedTask = try readOnly.mainContext.fetch(FetchDescriptor<TaskItem>()).first!
        failedTask.title = "Must not be committed"
        var failed = false
        do { try Store.save(readOnly.mainContext) } catch { failed = true }
        let recovered = Store.recovery.reload()
        try check(failed && recovered, "real save rejection can recover its committed store")
        let afterFailure = try TaskBackup.capture(Store.recovery.container!.mainContext)
        try check(afterFailure.tasks == committed.tasks && afterFailure.syncChanges == committed.syncChanges,
                  "failed writes cannot leak field timestamps into recovered data")
        print("AUTOMATIC SYNC PASS: \(count) checks")
        return count
    }
}
