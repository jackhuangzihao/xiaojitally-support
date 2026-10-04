import WidgetKit
import SwiftUI
import AppIntents

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var source = "today"
    var showCompleted = true
    var page = 0
    var failedTaskID: UUID? = nil
    static func make(date: Date, snapshot: WidgetSnapshot?, source: String = "today", showCompleted: Bool = true, family: WidgetFamily, preview: Bool = false) -> Self {
        let count = snapshot?.rows(source: source, date: date, showCompleted: showCompleted).count ?? 0
        let key = WidgetPaging.key(source: source, large: family == .systemLarge, compact: family == .systemSmall, showCompleted: showCompleted)
        return Self(date: date, snapshot: snapshot, source: source, showCompleted: showCompleted,
            page: preview ? 0 : WidgetPaging.read(key, count: count, limit: family == .systemLarge ? 8 : 3), failedTaskID: preview ? nil : WidgetActionFailure.taskID)
    }
}
struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { TodayEntry(date: Date(), snapshot: .sample) }
    func snapshot(for configuration: TaskWidgetConfiguration, in context: Context) async -> TodayEntry {
        .make(date: Date(), snapshot: context.isPreview ? .sample : WidgetSnapshot.read(), source: configuration.source?.id ?? "today",
              showCompleted: configuration.showCompleted, family: context.family, preview: context.isPreview)
    }
    func timeline(for configuration: TaskWidgetConfiguration, in context: Context) async -> Timeline<TodayEntry> {
        let now = Date(), calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let snapshot = WidgetSnapshot.read(), source = configuration.source?.id ?? "today"
        let entry = TodayEntry.make(date: now, snapshot: snapshot, source: source, showCompleted: configuration.showCompleted, family: context.family)
        // Future entries must not mutate today's page state while being prepared.
        let tomorrow = TodayEntry(date: midnight, snapshot: snapshot, source: source, showCompleted: configuration.showCompleted, page: entry.page)
        return Timeline(entries: [entry, tomorrow], policy: .after(now.addingTimeInterval(1800)))
    }
}
struct WidgetContent: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        TodayWidgetCard(snapshot: entry.snapshot, date: entry.date, compact: family == .systemSmall, large: family == .systemLarge, source: entry.source,
            showCompleted: entry.showCompleted, requestedPage: entry.page, failedTaskID: entry.failedTaskID)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            .widgetURL(WidgetSnapshot.sourceURL(entry.source))
    }
}
struct JianshiTasksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "JianshiTasks", intent: TaskWidgetConfiguration.self, provider: TodayProvider()) { WidgetContent(entry: $0) }
            .configurationDisplayName("清单待办")
            .description("单列翻页，点圆圈完成。可选择任务范围及是否显示已完成。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main struct JianshiWidgets: WidgetBundle {
    var body: some Widget {
        JianshiTasksWidget()
    }
}
