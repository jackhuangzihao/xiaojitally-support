import Foundation

enum CalendarTaskSearch {
    static func matches(_ task: TaskItem, query: String, includeDeleted: Bool = false) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (includeDeleted || task.deletedAt == nil) && !query.isEmpty && (task.title.localizedStandardContains(query)
            || task.notes.localizedStandardContains(query)
            || task.subtasks.contains { $0.title.localizedStandardContains(query) }
            || task.list?.name.localizedStandardContains(query) == true)
    }
}

/// List-only groups and gaps between tasks; completion does not erase booked time.
struct DaySchedule {
    var clusters: [[TaskItem]]
    var gaps: [Int: Int]
    init(_ items: [TaskItem], day: Date, occupying: [TaskItem]? = nil) {
        let timed = items.filter { $0.clockDate != nil }.sorted {
            let a = Self.startMinute($0, on: day), b = Self.startMinute($1, on: day)
            if a != b { return a < b }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return TaskItem.plannedBefore($0, $1)
        }
        clusters = []
        var clusterEnd = -1
        for task in timed {
            let start = Self.startMinute(task, on: day), end = Self.endMinute(task, on: day)
            if !clusters.isEmpty, start < clusterEnd {
                clusters[clusters.count - 1].append(task); clusterEnd = max(clusterEnd, end)
            } else { clusters.append([task]); clusterEnd = end }
        }
        gaps = [:]
        // Filtering changes the visible rows, not the time already occupied by hidden tasks.
        let booked = PlanBlock.layout((occupying ?? items).filter { $0.deletedAt == nil && $0.duration != nil }, day: day)
        for index in clusters.indices.dropFirst() {
            // A start-only task has no known finish, so do not invent a gap after it.
            guard let previous = Self.span(clusters[index - 1], day: day),
                  let first = clusters[index].first else { continue }
            let start = Self.startMinute(first, on: day)
            guard start > previous.end else { continue }
            let free = PlanBlock.freeTime(booked, from: previous.end, to: start).free
            if free > 0 { gaps[index] = free }
        }
    }
    /// Clusters contain connected intervals: their outer bounds count overlapping minutes once.
    static func span(_ items: [TaskItem], day: Date) -> (start: Int, end: Int)? {
        let intervals = items.filter { $0.duration != nil }
        guard let start = intervals.map({ startMinute($0, on: day) }).min(),
              let end = intervals.map({ endMinute($0, on: day) }).max(), end > start else { return nil }
        return (start, end)
    }
    private static func startMinute(_ task: TaskItem, on day: Date) -> Int {
        guard let clock = task.clockDate else { return 0 }
        return Dates.sameDay(clock, day) ? Dates.calendar.component(.hour, from: clock) * 60 + Dates.calendar.component(.minute, from: clock) : 0
    }
    private static func endMinute(_ task: TaskItem, on day: Date) -> Int {
        let start = startMinute(task, on: day)
        guard task.hasTime, let end = task.endAt else { return start }
        return Dates.sameDay(end, day) ? max(start, Dates.calendar.component(.hour, from: end) * 60 + Dates.calendar.component(.minute, from: end)) : 1440
    }
}

struct PlanBlock: Identifiable {
    let task: TaskItem
    var start: Double
    var end: Double
    var column = 0
    var columns = 1
    var id: UUID { task.id }
    func canResize(on day: Date) -> Bool {
        guard task.hasTime, let end = task.endAt else { return false }
        let start = Dates.calendar.startOfDay(for: day)
        let next = Dates.calendar.date(byAdding: .day, value: 1, to: start)!
        return end > start && end <= next
    }
    /// The visible slice of a continuous task. A midnight end belongs to the previous day only.
    static func segment(from start: Date, to end: Date, on day: Date) -> DateInterval? {
        let midnight = Dates.calendar.startOfDay(for: day)
        let next = Dates.calendar.date(byAdding: .day, value: 1, to: midnight)!
        let lower = max(start, midnight), upper = min(end, next)
        return lower < upper ? DateInterval(start: lower, end: upper) : nil
    }
    static func occupied(_ tasks: [TaskItem], excluding id: UUID) -> [DateInterval] {
        tasks.compactMap { task in
            guard task.id != id, task.deletedAt == nil, !task.isDone, let start = task.clockDate else { return nil }
            let end = task.endAt ?? start.addingTimeInterval(1800)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
    }
    static func overlaps(_ interval: DateInterval, others: [DateInterval]) -> Bool {
        others.contains { $0.start < interval.end && $0.end > interval.start }
    }
    static let displayScale = 1.2
    /// Overlapping intervals share the available width instead of hiding each other.
    static func layout(_ tasks: [TaskItem], day: Date, calendar: Calendar = Dates.calendar) -> [Self] {
        let start = calendar.startOfDay(for: day)
        let finish = calendar.date(byAdding: .day, value: 1, to: start)!
        var blocks = tasks.compactMap { task -> Self? in
            guard task.overlaps(DateInterval(start: start, end: finish)), let time = task.clockDate else { return nil }
            let end = task.endAt ?? time.addingTimeInterval(1800)
            guard time < finish, end > start else { return nil }
            let span = Dates.clockSpan(from: time, to: end, on: day, calendar: calendar)
            return Self(task: task, start: span.start, end: span.end)
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        var group: [Int] = [], ends: [Double] = []
        func finishGroup() { for i in group { blocks[i].columns = ends.count } }
        for i in blocks.indices {
            if let last = ends.max(), blocks[i].start >= last { finishGroup(); group = []; ends = [] }
            let column = ends.firstIndex { $0 <= blocks[i].start } ?? ends.count
            if column == ends.count { ends.append(blocks[i].end) } else { ends[column] = blocks[i].end }
            blocks[i].column = column; group.append(i)
        }
        finishGroup()
        return blocks
    }
}

/// How a day maps onto the timeline: which span is visible and how tall a minute is.
/// Blocks, drops, the resize handle and the "now" line all go through this one mapping.
struct TimelineLayout: Equatable {
    var startMinute: Int
    var endMinute: Int
    /// Points per minute.
    var scale: Double
    var height: Double { Double(endMinute - startMinute) * scale }
    func y(_ minute: Double) -> Double { (minute - Double(startMinute)) * scale }
    /// Text adapts to the true duration, never enlarges it.
    func intervalHeight(from start: Double, to end: Double) -> Double { max(0, end - start) * scale }
    /// The quarter hour a point on the canvas refers to, kept inside the visible span.
    func snapped(_ y: Double, step: Int = 15) -> Int {
        let raw = Double(startMinute) + y / scale
        let value = Int((raw / Double(step)).rounded(.down)) * step
        return min(endMinute - step, max(startMinute, value))
    }
    /// Whole hours to label, e.g. 6:00 … 23:00.
    var hours: [Int] { stride(from: startMinute / 60 * 60, to: endMinute, by: 60).map { $0 } }

    /// Full day shows 0–24. Otherwise 6:00–22:00, widened to hold every block and the current time,
    /// so a normal day fits on one screen without hiding anything.
    static func make(blocks: [PlanBlock], fullDay: Bool, density: Double, nowMinute: Int? = nil) -> Self {
        let scale = min(4, max(0.3, density))
        guard !fullDay else { return Self(startMinute: 0, endMinute: 1440, scale: scale) }
        var start = 6 * 60, end = 22 * 60
        for block in blocks {
            start = min(start, Int(block.start / 60) * 60)
            // An hour of headroom under the last block, so it can still be dragged longer.
            end = max(end, min(1440, Int((block.end / 60).rounded(.up)) * 60 + 60))
        }
        if let nowMinute {
            start = min(start, nowMinute / 60 * 60)
            end = max(end, min(1440, (nowMinute / 60 + 1) * 60))
        }
        start = max(0, min(start, 1440 - 120))
        return Self(startMinute: start, endMinute: min(1440, max(end, start + 120)), scale: scale)
    }
}

extension PlanBlock {
    /// Minutes left unplanned inside the span, and the longest single gap.
    static func freeTime(_ blocks: [Self], from start: Int, to end: Int) -> (free: Int, longest: (start: Int, end: Int)?) {
        var cursor = Double(start), free = 0
        var longest: (start: Int, end: Int)?
        func consider(_ from: Double, _ to: Double) {
            let length = Int(to - from)
            guard length > 0 else { return }
            free += length
            if length > (longest.map { $0.end - $0.start } ?? 0) { longest = (Int(from), Int(to)) }
        }
        for block in blocks.filter({ $0.task.duration != nil }).sorted(by: { $0.start < $1.start }) {
            consider(cursor, min(block.start, Double(end)))
            cursor = max(cursor, block.end)
        }
        consider(cursor, Double(end))
        return (free, longest)
    }
}

/// Narrows the task list beyond the keyword: by list, priority and time span.
struct TaskFilter: Equatable {
    enum ListChoice: Hashable { case any, unfiled, list(UUID) }
    enum Span: String, CaseIterable, Identifiable {
        case any, today, week, month, overdue, undated
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: L("任何时间", "Any time")
            case .today: L("今天", "Today")
            case .week: L("本周", "This week")
            case .month: L("本月", "This month")
            case .overdue: L("已逾期", "Overdue")
            case .undated: L("无日期", "No date")
            }
        }
    }
    var list: ListChoice = .any
    /// -1 means any priority.
    var priority = -1
    var span: Span = .any

    var count: Int { (list == .any ? 0 : 1) + (priority < 0 ? 0 : 1) + (span == .any ? 0 : 1) }
    var isActive: Bool { count > 0 }

    func matches(_ task: TaskItem, lists: [TaskList], today: Date) -> Bool {
        switch list {
        case .any: break
        case .unfiled: if task.calendarList != nil { return false }
        case .list(let id): if !ListTree.contains(task.calendarList?.id, in: id, lists: lists) { return false }
        }
        if priority >= 0 && task.priority != priority { return false }
        switch span {
        case .any: return true
        case .undated: return task.calendarDate == nil
        case .overdue: return task.isOverdue(today: today)
        case .today: return task.appearsInCalendar(on: today, wholeMonth: false)
        case .month: return task.appearsInCalendar(on: today, wholeMonth: true)
        case .week:
            let week = Dates.weekCells(today)
            let from = Dates.calendar.startOfDay(for: week[0])
            let to = Dates.calendar.date(byAdding: .day, value: 1, to: Dates.calendar.startOfDay(for: week[6]))!
            return task.overlaps(DateInterval(start: from, end: to))
        }
    }
}

extension PlanBlock {
    /// The whole civil day; today counts only what is still ahead. No assumed sleeping hours.
    /// Past days have nothing left to plan.
    static let countedStart = 0
    static let countedEnd = 24 * 60
    static func countedSpan(day: Date, now: Date) -> (start: Int, end: Int)? {
        let target = Dates.calendar.startOfDay(for: day), today = Dates.calendar.startOfDay(for: now)
        if target < today { return nil }
        var start = countedStart
        if target == today {
            let parts = Dates.calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            start = minute
        }
        return (min(start, countedEnd), countedEnd)
    }
}

/// Window-local cache: pointer movement must not rebuild projected SwiftData objects.
@MainActor final class RepeatPreview {
    private var records: [TaskBackup.TaskRecord] = []
    private var interval: DateInterval?
    private var minute: Int?
    private var result: [TaskItem] = []

    func items(_ tasks: [TaskItem], in range: DateInterval, now: Date = Date()) -> [TaskItem] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let roots = tasks.filter { task in
            task.deletedAt == nil && task.repeatRule != "none" && task.calendarDate != nil
                && (task.nextOccurrenceID == nil || task.repeatLinkIsStale(task.nextOccurrenceID.flatMap { byID[$0] }))
        }
        let key = roots.map(TaskBackup.TaskRecord.init)
        let tick = Int(now.timeIntervalSince1970 / 60)
        if records == key && interval == range && minute == tick { return result }
        records = key; interval = range; minute = tick
        result = roots.flatMap { task -> [TaskItem] in
            var items: [TaskItem] = []
            var after = max(now, range.start.addingTimeInterval(-(task.duration ?? 0) - 1))
            // ponytail: at most 64 projections per series/window; wider future views can page this later.
            for _ in 0..<64 {
                guard let next = Dates.nextRepeat(task.calendarDate!, rule: task.repeatRule,
                    anchorDay: task.repeatAnchorDay, after: after, until: task.repeatUntil), next < range.end else { break }
                if next <= after { break }
                let item = task.occurrence(at: next, preview: true)
                if item.overlaps(range) { items.append(item) }
                after = next
            }
            return items
        }
        return result
    }
}

/// Bucket once per visible range, instead of scanning the entire archive separately for every day.
enum CalendarIndex {
    static func byDay(_ tasks: [TaskItem], days: [Date], calendar: Calendar = Dates.calendar) -> [Date: [TaskItem]] {
        guard let first = days.first, let last = days.last else { return [:] }
        let lower = calendar.startOfDay(for: first)
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))!
        var result = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0), [TaskItem]()) })
        for task in tasks where task.deletedAt == nil {
            guard let start = task.calendarDate, start < upper else { continue }
            let end = task.duration != nil ? task.endAt! : start.addingTimeInterval(0.001)
            guard end > lower else { continue }
            var day = calendar.startOfDay(for: max(start, lower))
            while day < upper && day < end {
                if result[day] != nil { result[day]!.append(task) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return result
    }
}
