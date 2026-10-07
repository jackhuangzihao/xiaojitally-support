import SwiftUI
import SwiftData
import Observation
import UserNotifications

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
        center.setNotificationCategories(ReminderAction.categories)
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
        #else
        await MainActor.run { ReminderInbox.shared.receive(id) }
        #endif
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
