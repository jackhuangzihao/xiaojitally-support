import SwiftUI
import SwiftData
import UserNotifications
import UniformTypeIdentifiers

#if os(macOS)
final class BackupTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AutomaticBackup.shared.pendingWrites > 0 || ReminderScheduler.shared.hasPendingRefresh || WidgetBridge.pendingWrites > 0 else { return .terminateNow }
        Task { @MainActor in
            await ReminderScheduler.shared.finishPendingRefresh()
            await WidgetBridge.finishPublish()
            if AutomaticBackup.shared.pendingWrites > 0 { AutomaticBackup.shared.finishBeforeQuit() }
            else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
#endif

@main struct JianshiApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(BackupTerminationDelegate.self) private var backupTermination
    #endif
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("appAppearance") private var appearance = "system"
    @State private var systemLanguages = Locale.preferredLanguages
    private let storage: Result<ModelContainer, Error>

    init() {
        #if os(macOS)
        if CommandLine.arguments.contains("--cloud-connectivity-check") {
            Task { @MainActor in
                do { try await CloudSync.connectivityCheck(); exit(0) }
                catch { print("CLOUD CHECK FAILED: \(error)"); exit(1) }
            }
            RunLoop.main.run(); exit(1)
        }
        #endif
        #if os(macOS) && JIANSHI_WIDGETS
        if let output = ProcessInfo.processInfo.environment["JIANSHI_WIDGET_PREVIEW"] {
            do { try WidgetPreview.renderSamples(to: URL(fileURLWithPath: output)); exit(0) }
            catch { print(error); exit(1) }
        }
        #endif
        #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
        if CommandLine.arguments.contains("--day-ui-fixture") {
            do { try SelfCheck.seedDayTimelineUI(); exit(0) }
            catch { print("DAY FIXTURE FAILED: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--finance-ui-fixture") {
            do { try FinanceChecks.seedUI(); exit(0) }
            catch { print("FINANCE FIXTURE FAILED: \(error)"); exit(1) }
        }
        #endif
        #if os(macOS) && JIANSHI_APP_STORE
        if CommandLine.arguments.contains("--sandbox-check") {
            do { try SelfCheck.sandbox(); exit(0) }
            catch { print("SANDBOX CHECK FAILED: \(error)"); exit(1) }
        }
        #endif
        if CommandLine.arguments.contains("--performance-check") {
            do { try SelfCheck.performance(); exit(0) }
            catch { print("PERFORMANCE CHECK FAILED: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--self-check") {
            do { try SelfCheck.run(); exit(0) }
            catch { print("SELF-CHECK FAILED: \(error)"); exit(1) }
        }
        #if os(macOS)
        if CommandLine.arguments.contains("--reminder-audit") {
            ReminderScheduler.audit(delivery: CommandLine.arguments.contains("--test-delivery"))
            RunLoop.main.run()
            exit(1)
        }
        #endif
        _ = ReminderScheduler.shared
        storage = Result { try Store.make() }
        Store.didSave = {
            ReminderScheduler.shared.refresh($0)
            AutomaticBackup.shared.save($0)
            CloudSync.shared.localSaved()
            #if os(macOS)
            if WidgetBridge.isEnabled { WidgetBridge.publish($0) }
            #endif
        }
        #if os(macOS) && JIANSHI_WIDGETS
        if WidgetBridge.isEnabled, case .success(let container) = storage {
            WidgetBridge.publish(container.mainContext)
            CompleteWidgetTask.complete = { id in
                let context = (Store.recovery.container ?? container).mainContext
                try WidgetBridge.complete(id, in: context)
                ReminderScheduler.shared.refresh(context)
                WidgetBridge.publish(context)
                await WidgetBridge.finishPublish()
                guard let snapshot = WidgetSnapshot.read(), snapshot.tasks.first(where: { $0.id == id })?.isDone != false else {
                    throw NSError(domain: "Jianshi.Widget", code: 3, userInfo: [NSLocalizedDescriptionKey: "任务已保存，但小组件暂未更新。请重试。"])
                }
            }
        }
        #endif
        if case .success(let container) = storage {
            AutomaticBackup.shared.save(container.mainContext)
            CloudSync.shared.attach(container)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let container):
                StoreWindow(container: container)
                    .tint(.accentColor)
                    .preferredColorScheme(UISettings.colorScheme(appearance))
                    .environment(\.locale, UISettings.locale(for: language, preferredLanguages: systemLanguages))
                    .environment(\.calendar, Dates.calendar)
                    .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                        systemLanguages = Locale.preferredLanguages
                    }
                    #if os(macOS)
                    .frame(minWidth: 820, minHeight: 600)
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                    #endif
            case .failure(let error):
                ContentUnavailableView {
                    Label(L("无法打开任务数据", "Unable to open task data"), systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(L("现有数据未被清除。请关闭应用后重试。", "Your existing data has not been removed. Quit and reopen the app to try again.") + "\n\(error.localizedDescription)")
                        .textSelection(.enabled)
                }
            }
        }
        #if os(macOS)
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1120, height: 790)
        .commands { TaskHistoryCommands() }
        #endif
    }
}


/// Each window keeps value-only drafts while its old model graph is replaced.
private struct StoreWindow: View {
    let container: ModelContainer
    @State private var drafts = EditorDrafts()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ContentView(drafts: drafts, recoveryGeneration: Store.recovery.generation)
            .modelContainer(Store.recovery.container ?? container)
            .environment(drafts)
            .id(Store.recovery.generation)
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await CloudSync.shared.sync()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}


/// Used on the main window and every editor/settings sheet so a modal cannot hide recovery.
struct SaveRecoveryGuard: ViewModifier {
    @AppStorage("appLanguage") private var language = "system"
    var active = true
    func body(content: Content) -> some View {
        content.disabled(active && Store.recovery.failure != nil)
            .safeAreaInset(edge: .bottom) {
                if active, let failure = Store.recovery.failure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("修改未保存，编辑已暂停", "Changes not saved; editing paused"), systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.semibold))
                        Text(L("编辑草稿暂存于本次会话。重新载入已保存的数据后，请检查草稿再保存；刚才的拖动、删除等操作需重新执行。", "Editor drafts are kept for this session. Reload saved data, then review and save your draft. Repeat any failed move or deletion."))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        Button(L("重新载入数据", "Reload data")) { _ = Store.recovery.reload() }
                            .buttonStyle(.borderedProminent).disabled(false)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
    }
}


extension UISettings {
    static func colorScheme(_ value: String) -> ColorScheme? {
        switch value { case "light": .light; case "dark": .dark; default: nil }
    }
}

struct PreferencesView: View {
    #if os(macOS) && JIANSHI_WIDGETS
    @State private var widgetPreview = false
    #endif
    @ObservedObject private var reminders = ReminderScheduler.shared
    @State private var testingReminder = false
    @State private var testReminderSent = false
    @State private var testReminderError: String?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("appAppearance") private var appearance = "system"
    var body: some View {
        NavigationStack {
            Form {
                Section(L("显示", "Display")) {
                Picker(L("语言", "Language"), selection: $language) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Picker(L("外观", "Appearance"), selection: $appearance) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text(L("浅色", "Light")).tag("light")
                    Text(L("深色", "Dark")).tag("dark")
                }
                }
                CloudSyncSettings()
                #if os(macOS) && JIANSHI_WIDGETS
                if WidgetBridge.isEnabled {
                    Section(L("桌面小组件", "Desktop widgets")) {
                        Button(L("预览小组件与添加方法", "Preview widgets and installation")) { widgetPreview = true }
                    }
                }
                #endif
                Section(L("提醒通知", "Notifications")) {
                    Text(reminders.permissionSummary).font(.callout)
                    if !reminders.status.isEmpty { Text(reminders.status).font(.caption).foregroundStyle(.secondary) }
                    Button(L("发送测试通知", "Send test notification")) {
                        testingReminder = true; testReminderSent = false; testReminderError = nil
                        Task {
                            defer { testingReminder = false }
                            do { try await reminders.sendTest(); testReminderSent = true }
                            catch { testReminderError = error.localizedDescription }
                        }
                    }.disabled(testingReminder)
                    if testReminderSent { Text(L("测试通知将在约 5 秒后出现，不会修改任务。", "A test notification is scheduled in about 5 seconds. Your tasks are unchanged.")).font(.caption).foregroundStyle(.secondary) }
                    if let testReminderError { Text(testReminderError).font(.caption).foregroundStyle(.secondary) }
                }
                AutomaticBackupSettings()
                BackupSettings()
                Text(L("语言只改变界面，不会翻译你写下的任务、备注和清单名称。", "Language changes the interface only. Your tasks, notes and list names stay as written."))
                    .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            .navigationTitle(L("设置", "Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成", "Done")) { dismiss() } } }
        }
        #if os(macOS) && JIANSHI_WIDGETS
        .sheet(isPresented: $widgetPreview) { WidgetPreview() }
        #endif
        .task(id: language) { reminders.refresh(context) }
        .modifier(SaveRecoveryGuard())
        .environment(\.locale, UISettings.locale(for: language))
        .preferredColorScheme(UISettings.colorScheme(appearance))
        #if os(macOS)
        .frame(width: 520, height: 570)
        #endif
    }
}


/// An immutable plan prevents edits during an async notification call from mixing old and new fields.
/// The buttons on a reminder. An early reminder (before the task starts) offers "Got it"; one at or after the
/// start offers "Mark as completed" — spelled out, since a bare "Done" reads as "dismiss" on Apple systems.
/// Both offer "Remind me later" (10 minutes).
enum ReminderAction {
    static let dueCategory = "jianshi-reminder-due"
    static let earlyCategory = "jianshi-reminder-early"
    static let complete = "jianshi-complete"
    static let acknowledge = "jianshi-acknowledge"
    static let snooze = "jianshi-snooze"
    static let snoozeDelay: TimeInterval = 600
    static var categories: Set<UNNotificationCategory> {
        let later = UNNotificationAction(identifier: snooze, title: L("稍后提醒", "Remind me later"), options: [])
        return [
            UNNotificationCategory(identifier: dueCategory, actions: [UNNotificationAction(identifier: complete, title: L("标记为已完成", "Mark as completed"), options: []), later], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: earlyCategory, actions: [UNNotificationAction(identifier: acknowledge, title: L("收到", "Got it"), options: []), later], intentIdentifiers: [], options: []),
        ]
    }
}

struct ReminderEntry: Equatable {
    let id: UUID
    let title: String
    let date: Date
    /// Set for a later time of a repeating task: it is reminded on schedule even if an earlier time is still unticked.
    var occurrence: Date? = nil
    /// Before the task starts (a heads-up), rather than when it is due.
    var early = false
    var identifier: String {
        ReminderNavigation.prefix + id.uuidString + (occurrence.map { "@" + String(Int($0.timeIntervalSince1970)) } ?? "")
    }

    static func upcoming(_ tasks: [TaskItem], now: Date) -> [Self] {
        var entries: [Self] = []
        for task in tasks where !task.isDone && task.deletedAt == nil && task.previewSourceID == nil {
            if let date = task.reminderAt, date > now {
                entries.append(Self(id: task.id, title: task.title, date: date, early: isEarly(date, for: task.calendarDate, timed: task.clockDate != nil)))
            }
            entries += later(task, now: now)
        }
        return entries.sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }
    }

    /// Later times of a repeating task, within the next 60 days (at most 30 of them). Only the newest instance of a
    /// series projects; ticking it off hands the reminders over to the instance it creates, so none is doubled.
    static func later(_ task: TaskItem, now: Date, limit: Int = 30) -> [Self] {
        guard task.repeatRule != "none", task.nextOccurrenceID == nil, task.reminderAt != nil, let base = task.calendarDate else { return [] }
        let horizon = now.addingTimeInterval(60 * 86_400)
        // Start a month back, so a long-missed series still reaches today without walking years of dates.
        var after = max(base, now.addingTimeInterval(-30 * 86_400))
        var result: [Self] = []
        for _ in 0..<500 {
            guard result.count < limit, let next = Dates.nextRepeat(base, rule: task.repeatRule, anchorDay: task.repeatAnchorDay,
                                                                     after: after, until: task.repeatUntil), next > after else { break }
            after = next
            guard let date = task.reminderDate(forOccurrenceAt: next) else { break }
            if date > horizon { break }
            if date > now {
                result.append(Self(id: task.id, title: task.title, date: date, occurrence: next,
                                   early: isEarly(date, for: next, timed: task.clockDate != nil)))
            }
        }
        return result
    }

    /// A timed task: before its start. An all-day task: before its day.
    static func isEarly(_ date: Date, for start: Date?, timed: Bool) -> Bool {
        guard let start else { return false }
        return date < (timed ? start : Dates.calendar.startOfDay(for: start))
    }

    var request: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = early ? L("提前提醒：这件事快到了。", "Coming up soon.") : L("该做这件事了。", "Time for this task."); content.sound = .default
        content.categoryIdentifier = early ? ReminderAction.earlyCategory : ReminderAction.dueCategory
        // An absolute saved instant must not become the other 01:30 when daylight saving ends.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rounded = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
    func matches(_ old: UNNotificationRequest, desired: UNNotificationRequest) -> Bool {
        old.identifier == identifier && old.content.title == desired.content.title && old.content.body == desired.content.body
            && old.content.categoryIdentifier == desired.content.categoryIdentifier
            && (old.trigger as? UNCalendarNotificationTrigger)?.dateComponents == (desired.trigger as? UNCalendarNotificationTrigger)?.dateComponents
    }
}

@MainActor final class ReminderScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderScheduler()
    @Published var status = ""
    @Published private(set) var permissionSummary = L("正在检查通知权限…", "Checking notification permission…")
    private var queue: Task<Void, Never>?
    private var refill: Timer?
    private var revision = 0
    private weak var latestContext: ModelContext?
    private let center = UNUserNotificationCenter.current()
    private var pendingCompletions: [UUID] = []
    private override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories(ReminderAction.categories)
    }

    func authorize() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func sendTest() async throws {
        guard try await authorize() else {
            throw TaskBackup.invalid(L("通知未获允许，请在系统设置的“通知”中允许小记发送通知。", "Allow Tally notifications in System Settings."))
        }
        try await center.add(Self.testRequest())
        if let latestContext { refresh(latestContext) }
    }
    nonisolated static func testRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = L("小记 · 提醒测试", "Tally · Notification test")
        content.body = L("如果你看到这条通知，说明系统已送达本次测试提醒。", "If you see this, the system delivered this test notification.")
        content.sound = .default
        let trigger = ReminderEntry(id: UUID(), title: content.title, date: Date().addingTimeInterval(5)).request.trigger
        return UNNotificationRequest(identifier: "jianshi-notification-test", content: content, trigger: trigger)
    }
    var hasPendingRefresh: Bool { queue != nil }
    func finishPendingRefresh() async { await queue?.value }

    func refresh(_ context: ModelContext) {
        revision += 1
        latestContext = context
        // "Done" pressed before the store was ready (the app was launched by the notification).
        if !pendingCompletions.isEmpty {
            let ids = pendingCompletions; pendingCompletions = []
            ids.forEach(complete)
        }
        refill?.invalidate(); refill = nil
        guard queue == nil else { return }
        queue = Task {
            while true {
                let version = revision
                try? await Task.sleep(for: .milliseconds(150))
                guard version == revision else { continue }
                await reconcile(version: version)
                if version == revision { break }
            }
            queue = nil
        }
    }
    private func refreshLater(at date: Date) {
        refill?.invalidate()
        let timer = Timer(fire: max(date, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let context = self.latestContext else { return }
                self.refresh(context)
            }
        }
        refill = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func reconcile(version: Int) async {
        guard let context = latestContext, (try? Store.recovery.requireWritable(context)) != nil else { return }
        do {
            let all = try context.fetch(FetchDescriptor<TaskItem>())
            let items = ReminderEntry.upcoming(all, now: Date())
            let settings = await center.notificationSettings()
            let requests = await center.pendingNotificationRequests()
            let pending = requests.filter { $0.identifier.hasPrefix(ReminderNavigation.prefix) }
            // A "remind me later" copy goes once its task is done, deleted or gone.
            let open = Set(all.filter { !$0.isDone && $0.deletedAt == nil }.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: requests.filter {
                $0.identifier.hasPrefix(ReminderNavigation.snoozePrefix) && !(ReminderNavigation.taskID(request: $0.identifier).map(open.contains) ?? false)
            }.map(\.identifier))
            guard version == revision, (try? Store.recovery.requireWritable(context)) != nil else { return }
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if !allowed {
                permissionSummary = L("通知未开启，请在系统设置的“通知”中允许小记发送通知。", "Notifications are off. Allow Tally in System Settings → Notifications.")
            } else if settings.alertSetting != .enabled || settings.alertStyle == .none {
                permissionSummary = L("通知已允许，但横幅已关闭；请检查系统通知样式。", "Notifications are allowed, but banners are off. Check the system notification style.")
            } else if settings.soundSetting != .enabled {
                permissionSummary = L("通知已开启，声音已关闭。", "Notifications are on; sound is off.")
            } else {
                permissionSummary = L("通知与声音已开启。专注模式或系统设置仍可能将通知静音或延后。", "Notifications and sound are on. Focus or system settings may still silence or delay delivery.")
            }
            let wanted = allowed ? Array(items.prefix(60)) : []
            let ids = Set(wanted.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !ids.contains($0.identifier) }.map(\.identifier))
            guard allowed else {
                status = items.isEmpty ? "" : L("系统通知未开启，提醒暂不能送达。", "System notifications are disabled; reminders cannot be delivered.")
                return
            }
            let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
            var failures = 0
            for item in wanted {
                guard version == revision else { return }
                guard item.date > Date() else { continue }
                let request = item.request
                if let old = existing[item.identifier], item.matches(old, desired: request) { continue }
                do { try await center.add(request) }
                catch {
                    failures += 1
                    // A failed replacement must not leave the old, now incorrect reminder time active.
                    center.removePendingNotificationRequests(withIdentifiers: [item.identifier])
                }
            }
            guard version == revision else { return }
            let confirmed = await center.pendingNotificationRequests()
            guard version == revision else { return }
            let confirmedByID = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.identifier, $0) })
            let received = wanted.filter { item in
                guard item.date > Date(), let actual = confirmedByID[item.identifier] else { return false }
                return item.matches(actual, desired: item.request)
            }
            // A successful API call is not enough; confirm the system retained each future request.
            failures = max(failures, wanted.filter { $0.date > Date() }.count - received.count)
            var messages: [String] = []
            if let next = received.first {
                messages.append(L("系统已接收 \(received.count) 条提醒，最近一次：", "The system has \(received.count) reminders. Next: ") + Dates.label(next.date, pattern: "M月d日 HH:mm"))
            } else if items.isEmpty { messages.append(L("当前没有待发送的提醒。", "No upcoming reminders.")) }
            if items.count > 60 { messages.append(L("已按提醒时间安排最近 60 条；应用运行时会自动补充，其余请定期打开应用更新。", "The next 60 reminders are scheduled by reminder time. More are added while the app runs; reopen it periodically to refill the queue.")) }
            if failures > 0 { messages.append(L("\(failures) 条提醒暂未成功安排，将在一分钟内重试。", "\(failures) reminders could not be scheduled. Retrying within a minute.")) }
            status = messages.joined(separator: "\n")
            // Refill even if the app stays open without edits or another foreground transition.
            if let first = items.first {
                refreshLater(at: failures > 0 ? min(first.date.addingTimeInterval(1), Date().addingTimeInterval(60)) : first.date.addingTimeInterval(1))
            }
        } catch {
            status = L("提醒更新失败，将在一分钟内重试：", "Reminder refresh failed; retrying within a minute: ") + error.localizedDescription
            refreshLater(at: Date().addingTimeInterval(60))
        }
    }

    #if os(macOS)
    /// Read-only by default. The optional delivery probe uses its own ID and never changes a task.
    nonisolated static func audit(delivery: Bool) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            print("NOTIFICATION SETTINGS authorization=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) style=\(settings.alertStyle.rawValue) sound=\(settings.soundSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue) scheduledDelivery=\(settings.scheduledDeliverySetting.rawValue)")
            let canDeliver = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                for request in requests.filter({ $0.identifier.hasPrefix(ReminderNavigation.prefix) }).sorted(by: { $0.identifier < $1.identifier }) {
                    print("PENDING \(request.identifier) next=\(String(describing: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()))")
                }
                guard delivery, canDeliver else { exit(0) }
                let probe = testRequest()
                let identifier = probe.identifier
                UNUserNotificationCenter.current().add(probe) { error in
                    if let error { print("DELIVERY CHECK FAILED: \(error)"); exit(1) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                            let found = notifications.contains { $0.request.identifier == identifier }
                            print(found ? "DELIVERY CHECK PASSED: system reports delivered" : "DELIVERY CHECK: not found in delivered notifications; check system settings or Focus")
                            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
                            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
                            exit(found ? 0 : 2)
                        }
                    }
                }
            }
        }
    }
    #endif

    /// "Done" on a reminder: tick the task off as if in the app (a repeating task gets its next time).
    func complete(_ id: UUID) {
        guard let context = latestContext else { pendingCompletions.append(id); return }
        do {
            try Store.recovery.requireWritable(context)
            let target = id
            guard let task = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == target })).first,
                  !task.isDone, task.deletedAt == nil else { refresh(context); return }
            task.toggleCompletion(in: context)
            try Store.save(context)
        } catch {
            status = L("无法从通知完成任务：", "Could not complete the task from the notification: ") + error.localizedDescription
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard let id = ReminderNavigation.taskID(request: request.identifier) else { return }
        switch response.actionIdentifier {
        case ReminderAction.complete:
            await MainActor.run { self.complete(id) }
        case ReminderAction.snooze:
            guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return }
            let again = UNNotificationRequest(identifier: ReminderNavigation.snoozePrefix + id.uuidString + "-" + String(Int(Date().timeIntervalSince1970)),
                                              content: content,
                                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: ReminderAction.snoozeDelay, repeats: false))
            try? await center.add(again)
        case UNNotificationDefaultActionIdentifier:
            await open(id)
        default:
            break   // "Got it" or closing the notification: nothing to change.
        }
    }

    nonisolated private func open(_ id: UUID) async {
        #if os(macOS)
        do {
            // Address this installed bundle, not whichever old copy last registered the URL scheme.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.open([ReminderNavigation.url(id)], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            await MainActor.run { self.status = L("无法打开提醒中的任务：", "Could not open the reminder task: ") + error.localizedDescription }
        }
        #endif
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw TaskBackup.invalid(L("无法读取文件。", "Unable to read file.")) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupSettings: View {
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.modelContext) private var context
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: TaskBackup?
    @State private var confirming = false
    @State private var message: String?
    @State private var existingCount = 0
    @State private var missingCount = 0
    @State private var busy = false
    @State private var hasRecovery = false
    @State private var largeImportURL: URL?
    var body: some View {
        Section(L("备份与恢复", "Backup and restore")) {
            Button(L("导出完整备份", "Export full backup")) { exportCurrent() }
            Button(L("从备份恢复…", "Restore from backup…")) { importing = true }
            if busy { ProgressView(L("正在处理备份…", "Processing backup…")).controlSize(.small) }
            if hasRecovery {
                Button(L("导出上次恢复前的副本", "Export copy from before last restore")) {
                    do { document = BackupDocument(data: try Data(contentsOf: TaskBackup.recoveryURL())); exporting = true }
                    catch { message = error.localizedDescription }
                }
            }
            Text(L("包含全部任务与记账数据（账户、账本、账单、汇率）。文件为明文，请妥善保存。", "Includes all tasks and ledger data (accounts, books, entries and rates). Keep this unencrypted file safe."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("旧版备份不含记账数据，恢复时会保留当前账目。新版完整替换会替换任务与记账数据。", "Legacy task-only backups preserve your ledger. Full replacement from a new backup replaces both tasks and ledger.")).font(.caption).foregroundStyle(.secondary)
            Text(L("恢复前还会单独保留上次恢复前的副本。重要数据建议定期手动导出，另存一份。", "A separate pre-restore copy is also kept. Export important data periodically and keep another copy."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .onAppear { hasRecovery = (try? TaskBackup.recoveryURL()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Tally-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size > TaskBackup.largeFileThreshold { largeImportURL = url }
                else { readBackup(url, allowLargeFile: false) }
            } catch { message = L("无法读取备份：", "Unable to read backup: ") + error.localizedDescription }
        }
        .alert(L("读取较大的备份？", "Read a large backup?"), isPresented: Binding(get: { largeImportURL != nil }, set: { if !$0 { largeImportURL = nil } }), presenting: largeImportURL) { url in
            Button(L("继续读取", "Continue")) { largeImportURL = nil; readBackup(url, allowLargeFile: true) }
            Button(L("取消", "Cancel"), role: .cancel) { largeImportURL = nil }
        } message: { _ in
            Text(L("文件超过 20 MB，读取和恢复可能需要较长时间。继续读取不会更改任务；检查文件后仍需选择恢复方式。", "This file exceeds 20 MB and may take longer to read and restore. Reading changes no tasks; you will choose how to restore after it is checked."))
        }
        .confirmationDialog((pending?.finance.map { L("含 \($0.entries.count) 笔账单。", "Includes \($0.entries.count) ledger entries. ") } ?? L("此备份不含记账数据，现有账目会保留。", "This backup has no ledger; current entries will be kept. ")) + L("备份含 \(pending?.tasks.count ?? 0) 项任务、\(pending?.lists.count ?? 0) 个清单。本机有 \(existingCount) 项任务。", "Backup: \(pending?.tasks.count ?? 0) tasks, \(pending?.lists.count ?? 0) lists. This device: \(existingCount) tasks."), isPresented: $confirming, titleVisibility: .visible) {
            Button(L("合并缺失项目（任务与记账）", "Merge missing tasks and ledger records")) { restore(replace: false) }
            Button(pending?.finance == nil ? L("替换任务和清单，保留当前记账", "Replace tasks and lists; keep ledger") : L("替换全部任务、清单和记账数据", "Replace all tasks, lists and ledger"), role: .destructive) { restore(replace: true) }
            Button(L("取消", "Cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(CloudSync.shared.enabled ? L("iCloud 同步已开启：恢复、替换和删除也会同步到其他设备。", "iCloud sync is enabled: restored data, replacements and deletions also sync to your other devices.") : "")
        }
        .alert(L("备份与恢复", "Backup and restore"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("知道了", "OK"), role: .cancel) {}
        } message: { Text(message ?? "") }
    }
    private func readBackup(_ url: URL, allowLargeFile: Bool) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let backup = try await Task.detached(priority: .utility) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard allowLargeFile || size <= TaskBackup.largeFileThreshold else {
                        throw TaskBackup.invalid(L("文件大小已变化，请重新选择并确认读取。", "The file size changed. Select it again and confirm reading."))
                    }
                    return try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: allowLargeFile)
                }.value
                let existing = try context.fetch(FetchDescriptor<TaskItem>())
                existingCount = existing.count
                let ids = Set(existing.map(\.id)); missingCount = backup.tasks.filter { !ids.contains($0.id) }.count
                pending = backup; confirming = true
            } catch { message = L("无法读取备份：", "Unable to read backup: ") + error.localizedDescription }
        }
    }
    private func exportCurrent() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let snapshot = try TaskBackup.capture(context)
                let data = try await Task.detached(priority: .utility) { try snapshot.encoded() }.value
                document = BackupDocument(data: data); exporting = true
            } catch { message = error.localizedDescription }
        }
    }
    private func restore(replace: Bool) {
        guard let pending else { return }
        busy = true; defer { busy = false; self.pending = nil }
        do {
            try Store.recovery.requireWritable(context)
            let current = try TaskBackup.capture(context)
            _ = try pending.merging(into: current, replace: replace)
            let before = try current.encoded()
            try before.write(to: TaskBackup.recoveryURL(), options: .atomic); hasRecovery = true
            try pending.restore(context, replace: replace)
            ReminderScheduler.shared.refresh(context)
            message = L("恢复完成。已过时的提醒会标记为需要调整；未来提醒仍受本机通知权限控制。", "Restore complete. Past reminders are marked for adjustment; future reminders use this device's notification permission.")
        } catch {
            message = Store.recovery.failure == nil ? error.localizedDescription : nil
        }
    }
}

/// Portable JSON files, retained by time rather than by number of edits.
enum BackupFiles {
    static func ownedFiles(directory: URL, owner: String) throws -> [(url: URL, date: Date)] {
        let prefix = "Jianshi-Auto-\(owner)-"
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix(prefix),
                  let milliseconds = Double(url.lastPathComponent.dropFirst(prefix.count).prefix(20)), milliseconds.isFinite else { return nil }
            return (url, Date(timeIntervalSince1970: milliseconds / 1000))
        }.sorted { $0.date > $1.date }
    }

    static func retained(_ files: [(url: URL, date: Date)], now: Date, newest: URL, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -13, to: today)!
        var result: Set<String> = [newest.lastPathComponent]
        var hours = Set<Date>(), days = Set<Date>()
        var todayCount = 0
        // The newly verified file wins ties, including clocks adjusted backwards within an hour.
        let ordered = files.filter { $0.url.lastPathComponent == newest.lastPathComponent }
            + files.filter { $0.url.lastPathComponent != newest.lastPathComponent }.sorted { $0.date > $1.date }
        for file in ordered {
            let day = calendar.startOfDay(for: file.date)
            guard day >= cutoff else { continue }
            if day >= today {
                let hour = calendar.dateInterval(of: .hour, for: file.date)!.start
                if todayCount < 10 && hours.insert(hour).inserted {
                    result.insert(file.url.lastPathComponent); todayCount += 1
                }
            } else if days.insert(day).inserted { result.insert(file.url.lastPathComponent) }
        }
        return result
    }

    static func write(_ data: Data, directory: URL, owner: String, now: Date = Date()) throws -> URL {
        _ = try TaskBackup.decode(data, allowLargeFile: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(format: "%020.0f", now.timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("Jianshi-Auto-\(owner)-" + stamp + "-" + UUID().uuidString + ".json")
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileReadCorruptFile) }
        try prune(directory: directory, owner: owner, newest: url, now: now)
        return url
    }

    private static func prune(directory: URL, owner: String, newest: URL, now: Date) throws {
        let files = try ownedFiles(directory: directory, owner: owner)
        let keep = retained(files, now: now, newest: newest)
        for file in files where !keep.contains(file.url.lastPathComponent) { try FileManager.default.removeItem(at: file.url) }
    }

    static func contentData(_ value: TaskBackup) throws -> Data {
        var copy = value
        copy.createdAt = Date(timeIntervalSince1970: 0)
        copy.lists.sort { $0.id.uuidString < $1.id.uuidString }
        copy.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        copy.weekTitles?.sort { $0.week < $1.week }
        return try copy.encoded()
    }

    /// Runs on the backup queue: fetch no live SwiftData objects here.
    static func save(_ backup: TaskBackup, directory: URL, owner: String, force: Bool = false) throws -> Date {
        let content = try contentData(backup)
        if !force, let last = try ownedFiles(directory: directory, owner: owner).first,
           let previous = try? TaskBackup.decode(Data(contentsOf: last.url), allowLargeFile: true),
           try contentData(previous) == content {
            // Apply the time policy to older releases' count-based files without creating a duplicate.
            try prune(directory: directory, owner: owner, newest: last.url, now: Date())
            return last.date
        }
        var current = backup; current.createdAt = Date()
        _ = try write(current.encoded(), directory: directory, owner: owner, now: current.createdAt)
        return current.createdAt
    }

    static func localDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiBackups/Automatic", isDirectory: true)
    }
}

@MainActor final class AutomaticBackup: ObservableObject {
    static let shared = AutomaticBackup()
    @Published private(set) var lastSaved = UserDefaults.standard.object(forKey: "autoBackupLastSaved") as? Date
    @Published private var failureDetail = UserDefaults.standard.string(forKey: "autoBackupFailure") ?? ""
    var status: String { UISettings.backupFailure(failureDetail) }
    @Published private(set) var pendingWrites = 0
    private let queue = DispatchQueue(label: "Jianshi.automaticBackup", qos: .utility)
    private let owner: String
    private var debounce: Task<Void, Never>?
    private var pendingContext: ModelContext?
    private var forcePending = false
    private var writing = false
    private var quitting = false

    private init() {
        owner = UserDefaults.standard.string(forKey: "autoBackupOwner") ?? UUID().uuidString
        UserDefaults.standard.set(owner, forKey: "autoBackupOwner")
    }

    func save(_ context: ModelContext, force: Bool = false) {
        if pendingContext == nil { pendingWrites += 1 }
        pendingContext = context; forcePending = forcePending || force
        debounce?.cancel()
        if force { capturePending(); return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.capturePending()
        }
    }

    private func capturePending() {
        guard !writing, let context = pendingContext else { return }
        debounce?.cancel(); debounce = nil
        pendingContext = nil
        let force = forcePending; forcePending = false
        do {
            // Only copy model values on the main actor. Sorting, validation, comparison,
            // JSON encoding, reading and writing all run on the serial utility queue.
            try Store.recovery.requireWritable(context)
            let snapshot = try TaskBackup.capture(context, includeFinance: false)
            let financePayload = try FinanceStore.payload(context)
            let owner = owner
            writing = true
            queue.async { [weak self] in
                let result = Result {
                    var complete = snapshot
                    complete.finance = try financePayload.map { try JSONDecoder().decode(FinanceData.self, from: $0) }
                    return try BackupFiles.save(complete, directory: BackupFiles.localDirectory(), owner: owner, force: force)
                }
                Task { @MainActor [weak self] in self?.finished(result) }
            }
        } catch { finished(.failure(error)) }
    }

    private func finished(_ result: Result<Date, Error>) {
        writing = false; pendingWrites -= 1
        switch result {
        case .success(let date):
            lastSaved = date; failureDetail = ""
            UserDefaults.standard.set(date, forKey: "autoBackupLastSaved")
        case .failure(let error): failureDetail = error.localizedDescription
        }
        UserDefaults.standard.set(failureDetail, forKey: "autoBackupFailure")
        // At most one pending snapshot behind the write in flight; never queue every edit.
        if pendingContext != nil { capturePending(); return }
        #if os(macOS)
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        #endif
    }

    #if os(macOS)
    func finishBeforeQuit() {
        quitting = true
        debounce?.cancel(); debounce = nil
        capturePending()
    }
    func showFiles() {
        do {
            let url = try BackupFiles.localDirectory()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { failureDetail = error.localizedDescription }
    }
    #endif
}

struct BackupStatusNotice: View {
    @AppStorage("appLanguage") private var language = "system"
    @ObservedObject private var backups = AutomaticBackup.shared
    let openSettings: () -> Void
    var body: some View {
        if !backups.status.isEmpty {
            HStack {
                Label(L("自动备份需要检查", "Automatic backup needs attention"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Spacer()
                Button(L("查看原因", "View details"), action: openSettings)
            }.font(.caption).padding(.horizontal, 16).padding(.vertical, 6).background(.regularMaterial)
        }
    }
}

struct AutomaticBackupSettings: View {
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.modelContext) private var context
    @ObservedObject private var backups = AutomaticBackup.shared
    var body: some View {
        Section(L("自动备份", "Automatic backups")) {
            Text(L("自动保留最近 14 天：当天每小时一份、最多 10 份，之前每天一份。内容未变时不重复备份。", "Keeps 14 days: up to 10 hourly versions today, one per earlier day. Unchanged content is not duplicated."))
                .font(.caption).foregroundStyle(.secondary)
            if let date = backups.lastSaved {
                LabeledContent(L("最近本机备份", "Last local backup")) { Text(date, format: .dateTime.month().day().hour().minute()) }
            }
            HStack {
                Button(L("立即备份", "Back up now")) { backups.save(context, force: true) }
                    .disabled(backups.pendingWrites > 0)
                if backups.pendingWrites > 0 { ProgressView().controlSize(.small) }
                #if os(macOS)
                Button(L("查看备份文件", "Show backup files")) { backups.showFiles() }
                #endif
            }
            if !backups.status.isEmpty { Text(backups.status).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}


/// Uses the system undo stack and the existing schedule snapshot; no database-wide copies on each drag.
@MainActor @Observable final class TaskHistory {
    enum State: Equatable { case schedule(TaskSchedule), list(UUID?) }
    private final class Entry {
        let task: TaskItem
        let before: State
        var after: State
        let name: String
        init(task: TaskItem, before: State, after: State, name: String) {
            self.task = task; self.before = before; self.after = after; self.name = name
        }
    }
    @ObservationIgnored let manager = UndoManager()
    @ObservationIgnored private var last: Entry?
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var savedRevision: Int?
    private(set) var revision = 0
    var outcome: String?
    var canUndo: Bool { _ = revision; return manager.canUndo }
    var canRedo: Bool { _ = revision; return manager.canRedo }
    init() { manager.groupsByEvent = false; manager.levelsOfUndo = 100 }

    func record(_ task: TaskItem, before: State, after: State, name: String, coalesce: Bool = false) {
        guard before != after else { return }
        // An intervening edit/completion must not make Cmd-Z silently skip back to an older drag.
        if let savedRevision, savedRevision != Store.revision - 1 { manager.removeAllActions(); last = nil }
        savedRevision = Store.revision
        if coalesce, let last, last.task.id == task.id, last.before == before {
            last.after = after; revision += 1; return
        }
        let entry = Entry(task: task, before: before, after: after, name: name)
        last = entry
        manager.beginUndoGrouping()
        register(entry, reverse: false)
        manager.endUndoGrouping()
        revision += 1
    }
    private func register(_ entry: Entry, reverse: Bool) {
        manager.registerUndo(withTarget: self) { history in history.apply(entry, reverse: reverse) }
        manager.setActionName(entry.name)
    }
    private func apply(_ entry: Entry, reverse: Bool) {
        let task = entry.task, expected = reverse ? entry.before : entry.after, destination = reverse ? entry.after : entry.before
        guard savedRevision == Store.revision, let context = task.modelContext,
              (try? Store.recovery.requireWritable(context)) != nil, task.deletedAt == nil else { stale(); return }
        let current: State = switch expected { case .schedule: .schedule(TaskSchedule(task)); case .list: .list(task.list?.id) }
        guard current == expected else { stale(); return }
        do {
            switch destination {
            case .schedule(let snapshot): snapshot.restore(task); task.reminderNeedsAttention = task.reminderRequiresAttention()
            case .list(let id):
                let lists = try context.fetch(FetchDescriptor<TaskList>())
                let list = lists.first { $0.id == id }
                guard id == nil || list != nil else { stale(); return }
                task.list = list
            }
            try Store.save(context)
            savedRevision = Store.revision
            ReminderScheduler.shared.refresh(context)
            register(entry, reverse: !reverse)
            last = nil; revision += 1
            outcome = (reverse ? L("已重做：", "Redone: ") : L("已撤销：", "Undone: ")) + entry.name
        } catch {
            invalidated = true; last = nil; revision += 1
            outcome = Store.failureMessage(error)
        }
    }
    private func stale() {
        invalidated = true; last = nil; revision += 1
        outcome = L("任务已再次修改，未覆盖新内容；请在编辑中调整。", "The task changed again. Newer content was preserved; adjust it in the editor.")
    }
    private func clearInvalidated() {
        if invalidated { manager.removeAllActions(); invalidated = false; revision += 1 }
    }
    func undo() { outcome = nil; manager.undo(); clearInvalidated() }
    func redo() { outcome = nil; manager.redo(); clearInvalidated() }
}

#if os(macOS)
private struct TaskHistoryKey: FocusedValueKey { typealias Value = TaskHistory }
extension FocusedValues {
    var taskHistory: TaskHistory? {
        get { self[TaskHistoryKey.self] }
        set { self[TaskHistoryKey.self] = newValue }
    }
}
struct TaskHistoryCommands: Commands {
    @AppStorage("appLanguage") private var language = "system"
    @FocusedValue(\.taskHistory) private var history
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(L("撤销", "Undo")) { perform(redo: false) }.keyboardShortcut("z", modifiers: .command)
            Button(L("重做", "Redo")) { perform(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
    private func perform(redo: Bool) {
        // Text editing retains its own native undo stack and never changes a saved task behind the editor.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            if redo { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
        } else if NSApp.keyWindow?.attachedSheet == nil && NSApp.keyWindow?.sheetParent == nil {
            if redo { history?.redo() } else { history?.undo() }
        }
    }
}
#endif
