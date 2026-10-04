#if os(macOS)
import SwiftUI
import SwiftData
import WidgetKit
import Observation
#if JIANSHI_WIDGETS
import AppIntents

// App-only conformance routes completion to the existing database owner without opening its window.
extension CompleteWidgetTask: ForegroundContinuableIntent {}
#endif

@MainActor @Observable final class WidgetHealth {
    static let shared = WidgetHealth()
    var failure: String?
}

@MainActor enum WidgetBridge {
    // Re-enabling requires JIANSHI_WIDGETS on the host and restoring the extension embedding/dependency.
    #if JIANSHI_WIDGETS
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
    static var pendingWrites = 0
    private static let queue = DispatchQueue(label: "Jianshi.WidgetSnapshot", qos: .utility)
    static func snapshot(_ context: ModelContext) throws -> WidgetSnapshot {
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let lists = try context.fetch(FetchDescriptor<TaskList>()).sorted(by: ListTree.before)
        return WidgetSnapshot(tasks: tasks.compactMap { task in
            guard task.deletedAt == nil, task.previewSourceID == nil else { return nil }
            return WidgetTask(id: task.id, title: task.title, start: task.calendarDate, end: task.hasTime ? task.endAt : nil,
                              timed: task.clockDate != nil, priority: task.priority, list: task.list?.name ?? "", color: task.list?.colorHex ?? "799B80", listID: task.list?.id, completed: task.isDone, completedAt: task.completedAt)
        }.sorted { $0.id.uuidString < $1.id.uuidString }, english: UISettings.language == "en",
            lists: lists.map { WidgetList(id: $0.id, name: ListTree.path($0, lists: lists), parentID: $0.parentID) })
    }
    static func publish(_ context: ModelContext) {
        guard isEnabled, Store.recovery.failure == nil else { return }
        let value: WidgetSnapshot
        do { value = try snapshot(context) }
        catch { WidgetHealth.shared.failure = error.localizedDescription; return }
        pendingWrites += 1
        queue.async {
            defer { Task { @MainActor in pendingWrites -= 1 } }
            do {
                let url = try WidgetSnapshot.fileURL(), data = try JSONEncoder().encode(value)
                if (try? Data(contentsOf: url)) == data {
                    Task { @MainActor in WidgetHealth.shared.failure = nil }
                    return
                }
                try data.write(to: url, options: .atomic)
                WidgetCenter.shared.reloadAllTimelines()
                Task { @MainActor in WidgetHealth.shared.failure = nil }
            } catch { Task { @MainActor in WidgetHealth.shared.failure = error.localizedDescription } }
        }
    }
    static func finishPublish() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    static func complete(_ id: UUID, in context: ModelContext) throws {
        try Store.recovery.requireWritable(context)
        let item = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
        guard let item, item.deletedAt == nil, !item.isDone else { return }
        item.toggleCompletion(in: context)
        try Store.save(context)
    }
}

#if JIANSHI_WIDGETS
struct WidgetPreview: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var health = WidgetHealth.shared
    @State private var sample = true
    @State private var snapshot = WidgetSnapshot.sample
    @State private var size = 1
    @State private var source = "today"
    @State private var showCompleted = true
    @State private var page = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L("桌面小组件", "Desktop widgets")).font(.title2.bold()); Spacer(); Button(L("完成", "Done")) { dismiss() } }
            Picker(L("尺寸", "Size"), selection: $size) {
                Text(L("小号", "Small")).tag(0); Text(L("中号", "Medium")).tag(1); Text(L("大号", "Large")).tag(2)
            }.pickerStyle(.segmented)
            Picker(L("任务范围", "Tasks"), selection: $source) {
                ForEach(WidgetSource.choices(snapshot)) { Text($0.name).tag($0.id) }
            }
            Toggle(L("显示已完成", "Show completed"), isOn: $showCompleted)
            TodayWidgetCard(snapshot: snapshot, compact: size == 0, large: size == 2, preview: true, source: source,
                showCompleted: showCompleted, requestedPage: page, onPreviewPage: { page = $0 }, onPreviewComplete: { id in
                    guard sample, let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
                    snapshot.tasks[index].completed = true; snapshot.tasks[index].completedAt = Date()
                    clampPage()
                })
                .padding(16).frame(width: size == 0 ? 170 : 360, height: size == 2 ? 354 : 170)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.06)))
                .frame(maxWidth: .infinity)
            if let failure = health.failure { Text(L("小组件暂未更新：", "Widget update failed: ") + failure).font(.caption).foregroundStyle(.red) }
            Toggle(L("使用示例任务预览", "Preview with sample tasks"), isOn: $sample).onChange(of: sample) { _, _ in reload() }
            Text(L("右键桌面 → 编辑小组件 → 搜索“小记”，选择“清单待办”。右键小组件可设置任务范围与“显示已完成”。", "Right-click the desktop → Edit Widgets → search for Tally → Tasks. Edit its scope and Show Completed setting."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("示例可试点完成和翻页，不会保存到你的任务中。桌面小组件点圆圈后台保存，点标题打开任务；关闭示例时，预览中的完成按钮不修改真实任务。", "Try completing and paging through samples without saving them. Desktop circles save in the background; titles open tasks. Real-data previews cannot modify tasks."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 480).onAppear(perform: reload)
            .onChange(of: size) { _, _ in page = 0 }
            .onChange(of: source) { _, _ in page = 0 }
            .onChange(of: showCompleted) { _, _ in clampPage() }
    }
    private func clampPage() {
        page = WidgetPaging.page(page, count: snapshot.rows(source: source, date: Date(), showCompleted: showCompleted).count, limit: size == 2 ? 8 : 3)
    }
    private func reload() {
        page = 0
        snapshot = sample ? .sample : ((try? WidgetBridge.snapshot(context)) ?? WidgetSnapshot())
        if !WidgetSource.choices(snapshot).contains(where: { $0.id == source }) { source = "today" }
    }
}
extension WidgetPreview {
    @MainActor static func renderSamples(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let snapshot = WidgetSnapshot.sample
            let background = scheme == .dark ? Color(white: 0.14) : .white
            let content = HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("小号 · 3 项").font(.system(size: 12)).foregroundStyle(.secondary)
                    TodayWidgetCard(snapshot: snapshot, compact: true, preview: true)
                        .padding(16).frame(width: 170, height: 170).background(background, in: RoundedRectangle(cornerRadius: 22))
                    Text("中号 · 3 项").font(.system(size: 12)).foregroundStyle(.secondary)
                    TodayWidgetCard(snapshot: snapshot, preview: true)
                        .padding(16).frame(width: 360, height: 170).background(background, in: RoundedRectangle(cornerRadius: 22))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("大号 · 8 项").font(.system(size: 12)).foregroundStyle(.secondary)
                    TodayWidgetCard(snapshot: snapshot, large: true, preview: true)
                        .padding(16).frame(width: 360, height: 354).background(background, in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(28).background(scheme == .dark ? Color(white: 0.08) : Color(red: 0.92, green: 0.94, blue: 0.92))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content); renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: directory.appendingPathComponent("widget-" + name + ".png"))
        }
    }
}
#endif
#endif
