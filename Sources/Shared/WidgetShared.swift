#if os(macOS)
import SwiftUI
import WidgetKit
#if JIANSHI_WIDGETS
import AppIntents
#endif

struct WidgetTask: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let start: Date?
    let end: Date?
    let timed: Bool
    let priority: Int
    let list: String
    let color: String
    var listID: UUID? = nil
    var completed: Bool? = nil
    var completedAt: Date? = nil
    var isDone: Bool { completed == true }
    func isToday(_ day: Date, calendar: Calendar) -> Bool {
        guard let start else { return false }
        let beginning = calendar.startOfDay(for: day)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: beginning)!
        return start < tomorrow && (end.map { $0 > beginning } ?? (start >= beginning))
    }
    func isEarlier(_ day: Date, calendar: Calendar = .current) -> Bool {
        guard let start else { return false }
        return start < calendar.startOfDay(for: day) && !isToday(day, calendar: calendar)
    }
    var url: URL { URL(string: "jianshi://task/" + id.uuidString)! }
}
struct WidgetList: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let parentID: UUID?
}
struct WidgetSnapshot: Codable, Equatable {
    var tasks: [WidgetTask] = []
    var english = false
    var lists: [WidgetList]? = nil // Optional so existing snapshots remain readable during an update.
    /// The app's resolved locale (region-aware for English); absent in snapshots from older builds.
    var localeIdentifier: String? = nil
    func text(_ zh: String, _ en: String) -> String { english ? en : zh }
    var locale: Locale { Locale(identifier: localeIdentifier ?? (english ? "en_US" : "zh_CN")) }
    private func sorted(_ values: [WidgetTask], calendar: Calendar) -> [WidgetTask] {
        values.sorted {
            if $0.isDone != $1.isDone { return !$0.isDone }
            if $0.isDone, $0.completedAt != $1.completedAt { return ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            let a = $0.start.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            let b = $1.start.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            if a != b { return a < b }
            if $0.timed != $1.timed { return $0.timed }
            if $0.start != $1.start { return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func today(_ date: Date, calendar: Calendar = .current) -> [WidgetTask] {
        sorted(tasks.filter { !$0.isDone && $0.isToday(date, calendar: calendar) }, calendar: calendar)
    }
    func overdue(_ date: Date, calendar: Calendar = .current) -> Int {
        tasks.filter { !$0.isDone && $0.isEarlier(date, calendar: calendar) }.count
    }
    func rows(source: String, date: Date, showCompleted: Bool = true, calendar: Calendar = .current) -> [WidgetTask] {
        let visible = tasks.filter { showCompleted || !$0.isDone }
        if source == "today" {
            let earlier = visible.filter { !$0.isDone && $0.isEarlier(date, calendar: calendar) }
            let current = visible.filter {
                $0.isToday(date, calendar: calendar)
                || ($0.isDone && $0.completedAt.map { calendar.isDate($0, inSameDayAs: date) } == true)
            }
            return sorted(earlier, calendar: calendar) + sorted(current, calendar: calendar)
        }
        if source == "all" { return sorted(visible, calendar: calendar) }
        guard let id = UUID(uuidString: source), (lists ?? []).contains(where: { $0.id == id }) else { return [] }
        let parents = Dictionary(uniqueKeysWithValues: (lists ?? []).map { ($0.id, $0.parentID) })
        return sorted(visible.filter { task in
            var current = task.listID, visited = Set<UUID>()
            while let value = current, visited.insert(value).inserted {
                if value == id { return true }
                current = parents[value] ?? nil
            }
            return false
        }, calendar: calendar)
    }
    func sourceTitle(_ source: String) -> String {
        if source == "today" { return text("今天", "Today") }
        if source == "all" { return text("全部任务", "All tasks") }
        return (lists ?? []).first { $0.id.uuidString == source }?.name ?? text("清单已移除", "List removed")
    }
    static func sourceURL(_ source: String) -> URL {
        if source == "today" || source == "all" { return URL(string: "jianshi://" + source)! }
        if let id = UUID(uuidString: source) { return URL(string: "jianshi://list/" + id.uuidString)! }
        return URL(string: "jianshi://today")!
    }
    static let group = "JY659LHUCS.local.jianshi.widgets"
    static func fileURL() throws -> URL {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw NSError(domain: "Jianshi.Widget", code: 1, userInfo: [NSLocalizedDescriptionKey: "小组件共享空间不可用，请检查应用签名。"])
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("today.json")
    }
    static func read() -> Self? { try? JSONDecoder().decode(Self.self, from: Data(contentsOf: fileURL())) }
    static func taskID(from url: URL) -> UUID? { identifier(from: url, host: "task") }
    static func identifier(from url: URL, host: String) -> UUID? {
        guard url.scheme == "jianshi", url.host == host, url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    static var sample: Self {
        let day = Calendar.current.startOfDay(for: Date())
        let work = UUID(), life = UUID(), study = UUID()
        let titles = ["确认设计稿", "整理本周计划", "读几页书", "午后散步", "准备明天的会议", "整理书桌", "学习一个新知识", "给家人打电话", "预约周末活动", "想读的书"]
        let hours = [-6, 9, 10, 12, 14, 16, 18, 20, 34]
        let tasks = titles.enumerated().map { index, title in
            let id = [work,work,study,life,work,life,study,life,life,study][index]
            return WidgetTask(id: UUID(), title: title, start: index < hours.count ? day.addingTimeInterval(Double(hours[index]) * 3600) : nil,
                end: nil, timed: index < hours.count, priority: index == 1 ? 2 : 0,
                list: id == work ? "工作" : id == life ? "生活" : "学习", color: id == work ? "799B80" : id == life ? "D88951" : "5287CE", listID: id, completed: index == 7, completedAt: index == 7 ? day.addingTimeInterval(72000) : nil)
        }
        return Self(tasks: tasks, lists: [WidgetList(id: work, name: "工作", parentID: nil), WidgetList(id: life, name: "生活", parentID: nil), WidgetList(id: study, name: "学习", parentID: nil)])
    }
}

#if JIANSHI_WIDGETS
// One native setting combines built-in scopes and the user's lists.
struct WidgetSource: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "任务范围"
    static let defaultQuery = WidgetSourceQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static func choices(_ snapshot: WidgetSnapshot) -> [Self] {
        [Self(id: "today", name: snapshot.text("今天与此前未完成", "Today and earlier")), Self(id: "all", name: snapshot.text("全部任务", "All tasks"))]
        + (snapshot.lists ?? []).map { Self(id: $0.id.uuidString, name: $0.name) }
    }
}
struct WidgetSourceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSource] {
        let options = WidgetSource.choices(WidgetSnapshot.read() ?? WidgetSnapshot())
        return identifiers.map { id in options.first { $0.id == id } ?? WidgetSource(id: id, name: "清单已移除") }
    }
    func suggestedEntities() async throws -> [WidgetSource] { WidgetSource.choices(WidgetSnapshot.read() ?? WidgetSnapshot()) }
    func defaultResult() async -> WidgetSource? { WidgetSource.choices(WidgetSnapshot.read() ?? WidgetSnapshot()).first }
}
struct TaskWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "待办小组件"
    @Parameter(title: "任务范围") var source: WidgetSource?
    @Parameter(title: "显示已完成", default: true) var showCompleted: Bool
}

/// The host app owns all writes; an extension never opens the live database.
struct CompleteWidgetTask: AppIntent {
    static let title: LocalizedStringResource = "完成小记任务"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    @Parameter(title: "任务编号") var taskID: String
    init() {}
    init(id: UUID) { taskID = id.uuidString }
    @MainActor static var complete: ((UUID) async throws -> Void)?
    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { throw CocoaError(.validationMissingMandatoryProperty) }
        do {
            guard let complete = Self.complete else {
                throw NSError(domain: "Jianshi.Widget", code: 2, userInfo: [NSLocalizedDescriptionKey: "请打开小记检查数据后重试。"])
            }
            try await complete(id)
            WidgetActionFailure.clear()
        } catch {
            WidgetActionFailure.record(id)
            WidgetCenter.shared.reloadAllTimelines()
            throw error
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

#endif

// Page state is presentation-only; task writes always go through the host app.
// ponytail: identical scope/size/settings share a page; add an explicit widget identity only if independent copies are needed.
enum WidgetPaging {
    static func page(_ requested: Int, count: Int, limit: Int) -> Int {
        min(max(0, requested), max(0, (count - 1) / max(1, limit)))
    }
    static func key(source: String, large: Bool, compact: Bool, showCompleted: Bool) -> String {
        "page.\(source).\(large ? "large" : compact ? "small" : "medium").\(showCompleted)"
    }
    #if JIANSHI_WIDGETS
    static func read(_ key: String, count: Int, limit: Int) -> Int {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.group)
        let requested = defaults?.integer(forKey: key) ?? 0
        let result = page(requested, count: count, limit: limit)
        if requested != result { defaults?.set(result, forKey: key) }
        return result
    }
    #endif
}
#if JIANSHI_WIDGETS
struct WidgetPageIntent: AppIntent {
    static let title: LocalizedStringResource = "小组件翻页"
    static let openAppWhenRun = false
    static let isDiscoverable = false
    @Parameter(title: "范围") var source: String
    @Parameter(title: "大号") var large: Bool
    @Parameter(title: "小号") var compact: Bool
    @Parameter(title: "显示已完成") var showCompleted: Bool
    @Parameter(title: "页码") var page: Int
    init() {}
    init(source: String, large: Bool, compact: Bool, showCompleted: Bool, page: Int) {
        self.source = source; self.large = large; self.compact = compact; self.showCompleted = showCompleted; self.page = page
    }
    func perform() async throws -> some IntentResult {
        guard source == "today" || source == "all" || UUID(uuidString: source) != nil else { return .result() }
        let count = WidgetSnapshot.read()?.rows(source: source, date: Date(), showCompleted: showCompleted).count ?? 0
        UserDefaults(suiteName: WidgetSnapshot.group)?.set(WidgetPaging.page(page, count: count, limit: large ? 8 : 3),
            forKey: WidgetPaging.key(source: source, large: large, compact: compact, showCompleted: showCompleted))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
// The most recent failed action is enough to show a retry hint without changing saved task state.
enum WidgetActionFailure {
    static var url: URL? { try? WidgetSnapshot.fileURL().deletingLastPathComponent().appendingPathComponent("action-failure.txt") }
    static var taskID: UUID? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }
    static func record(_ id: UUID) { if let url { try? id.uuidString.write(to: url, atomically: true, encoding: .utf8) } }
    static func clear() { if let url { try? FileManager.default.removeItem(at: url) } }
}

struct TodayWidgetCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let snapshot: WidgetSnapshot?
    var date = Date()
    var compact = false
    var large = false
    var preview = false
    var source = "today"
    var showCompleted = true
    var requestedPage = 0
    var failedTaskID: UUID? = nil
    var onPreviewPage: ((Int) -> Void)? = nil
    var onPreviewComplete: ((UUID) -> Void)? = nil
    private var data: WidgetSnapshot { snapshot ?? WidgetSnapshot() }
    private var rows: [WidgetTask] { data.rows(source: source, date: date, showCompleted: showCompleted) }
    private var limit: Int { large ? 8 : 3 }
    private var page: Int { WidgetPaging.page(requestedPage, count: rows.count, limit: limit) }
    private var pages: Int { max(1, (rows.count + limit - 1) / limit) }
    private var hasFailure: Bool { failedTaskID.map { id in rows.contains { $0.id == id } } ?? false }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.65, green: 0.78, blue: 0.68) : Color(red: 0.31, green: 0.48, blue: 0.36) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(data.sourceTitle(source)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(date, format: .dateTime.month(.defaultDigits).day()).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if snapshot == nil {
                Spacer(minLength: 0)
                Text(data.text("打开小记开始使用", "Open Tally to start")).font(.callout)
                Spacer(minLength: 0)
            } else if rows.isEmpty {
                Spacer(minLength: 0)
                Text(data.text("暂无任务", "No tasks")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(rows.dropFirst(page * limit).prefix(limit))) { task in row(task) }
                Spacer(minLength: 0)
            }
            footer
        }
        .environment(\.locale, data.locale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var footer: some View {
        HStack(spacing: 2) {
            if pages > 1 {
                pageButton(-1)
                Text("\(page + 1)/\(pages)").monospacedDigit().accessibilityLabel(data.text("第 \(page + 1) 页，共 \(pages) 页", "Page \(page + 1) of \(pages)"))
                pageButton(1)
            } else {
                let remaining = rows.filter { !$0.isDone }.count
                Text(data.text("\(remaining) 项待办", "\(remaining) left"))
            }
            Spacer(minLength: 2)
            if preview { allLabel }
            else { Link(destination: WidgetSnapshot.sourceURL(source)) { allLabel }.buttonStyle(.plain) }
        }.font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 22)
    }
    private var allLabel: some View {
        HStack(spacing: 3) {
            Text(hasFailure ? data.text("更新失败", "Update failed") : compact ? data.text("全部", "All") : data.text("查看全部", "View all"))
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
        }.foregroundStyle(hasFailure ? .red : accent)
            .help(hasFailure ? data.text("任务状态未更新，请打开小记检查后重试。", "Task update failed. Open Tally and retry.") : data.text("在小记中查看全部", "View all in Tally"))
    }
    private func pageButton(_ offset: Int) -> some View {
        Group {
            if preview { Button { onPreviewPage?(page + offset) } label: { pageIcon(offset) } }
            else {
                Button(intent: WidgetPageIntent(source: source, large: large, compact: compact, showCompleted: showCompleted, page: page + offset)) { pageIcon(offset) }
            }
        }.buttonStyle(.plain).disabled(page + offset < 0 || page + offset >= pages)
            .accessibilityLabel(offset < 0 ? data.text("上一页", "Previous page") : data.text("下一页", "Next page"))
    }
    private func pageIcon(_ offset: Int) -> some View {
        Image(systemName: offset < 0 ? "chevron.left" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
    }
    private func row(_ task: WidgetTask) -> some View {
        HStack(spacing: 6) {
            if task.isDone { completionIcon(task) }
            else if preview { Button { onPreviewComplete?(task.id) } label: { completionIcon(task) }.buttonStyle(.plain) }
            else {
                Button(intent: CompleteWidgetTask(id: task.id)) { completionIcon(task) }.buttonStyle(.plain)
                    .accessibilityLabel(data.text("完成：", "Complete: ") + task.title)
            }
            if preview { details(task) }
            else { Link(destination: task.url) { details(task) }.buttonStyle(.plain) }
        }.frame(height: large ? 31 : 27)
    }
    private func completionIcon(_ task: WidgetTask) -> some View {
        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16)).foregroundStyle(task.isDone ? accent : .secondary)
            .frame(width: 20, height: 27).accessibilityLabel(task.isDone ? data.text("已完成", "Completed") : data.text("未完成", "Unfinished"))
    }
    private func details(_ task: WidgetTask) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.title).font(.system(size: compact ? 12 : 13, weight: task.priority == 2 ? .semibold : .regular))
                    .foregroundStyle(task.isDone ? .secondary : .primary).strikethrough(task.isDone).lineLimit(1)
                if !compact {
                    Spacer(minLength: 0)
                    Text(timeLabel(task)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
            HStack(spacing: 4) {
                Circle().fill(color(task.color)).frame(width: 4, height: 4)
                if compact { Text(timeLabel(task)).lineLimit(1) }
                else { Text(task.list.isEmpty ? data.text("无清单", "No list") : task.list).lineLimit(1) }
                if !task.isDone && task.priority == 2 { Text(data.text("高优先级", "High priority")).foregroundStyle(accent).lineLimit(1) }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func timeLabel(_ task: WidgetTask) -> String {
        guard let start = task.start else { return data.text("无日期", "No date") }
        let locale = data.locale
        let time = start.formatted(.dateTime.hour().minute().locale(locale))
        if Calendar.current.isDate(start, inSameDayAs: date) { return task.timed ? time : data.text("全天", "All day") }
        let day = start.formatted(.dateTime.month(.defaultDigits).day().locale(locale))
        if task.isEarlier(date) && !task.isDone { return day + data.text(" 未完成", " unfinished") }
        return day + (task.timed ? " " + time : "")
    }
    private func color(_ hex: String) -> Color {
        let n = UInt64(hex, radix: 16) ?? 0x799B80
        return Color(red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255)
    }
}
#endif
#endif
