import SwiftUI
import SwiftData
import Observation
import UserNotifications

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

/// Reminder choices shown in the editor. Relative choices follow the task's date, so the
/// reminder moves when the schedule changes; `custom` keeps an exact date and time.
enum ReminderPreset: String, CaseIterable, Identifiable {
    case none, atTime, tenMinutes, oneHour, morning, dayBefore, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L("不提醒", "None")
        case .atTime: L("准时", "At time of task")
        case .tenMinutes: L("提前 10 分钟", "10 minutes before")
        case .oneHour: L("提前 1 小时", "1 hour before")
        case .morning: L("当天 9:00", "On the day, 9:00")
        case .dayBefore: L("前一天 9:00", "Day before, 9:00")
        case .custom: L("自定义…", "Custom…")
        }
    }

    /// Menu title with the resulting clock time, e.g. "提前 10 分钟 · 14:50".
    func menuTitle(base: Date?, timed: Bool) -> String {
        guard timed, self != .none, self != .custom, let when = date(base: base, timed: timed) else { return title }
        return title + " · " + Dates.label(when, pattern: "HH:mm")
    }

    /// A reminder may not come after the task: its time, or the end of its day when it has no time.
    static func latest(base: Date?, timed: Bool) -> Date? {
        guard let base else { return nil }
        if timed { return base }
        return Dates.calendar.date(bySettingHour: 23, minute: 59, second: 0, of: base)
    }

    /// `base` is the task's scheduled moment (or its day when `timed` is false).
    static func options(base: Date?, timed: Bool) -> [Self] {
        guard base != nil else { return [.none, .custom] }
        return timed ? [.none, .atTime, .tenMinutes, .oneHour, .custom] : [.none, .morning, .dayBefore, .custom]
    }

    func date(base: Date?, timed: Bool, calendar: Calendar = Dates.calendar) -> Date? {
        guard let base, Self.options(base: base, timed: timed).contains(self) else { return nil }
        let day = calendar.startOfDay(for: base)
        switch self {
        case .atTime: return base
        case .tenMinutes: return base.addingTimeInterval(-600)
        case .oneHour: return base.addingTimeInterval(-3600)
        case .morning: return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        case .dayBefore: return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: -1, to: day)!)
        case .none, .custom: return nil
        }
    }

    static func infer(reminder: Date?, base: Date?, timed: Bool) -> Self {
        guard let reminder else { return .none }
        return options(base: base, timed: timed).first { preset in
            preset.date(base: base, timed: timed).map { abs($0.timeIntervalSince(reminder)) < 1 } ?? false
        } ?? .custom
    }
}

/// iOS delivers notification taps before a window may exist. Keep only the ID until
/// an active window accepts it, then let that window defer navigation during edits.
@MainActor @Observable final class ReminderInbox {
    static let shared = ReminderInbox()
    var navigation = ReminderNavigation()
    func receive(_ id: UUID) { navigation.pendingTaskID = id }
}

/// Value-only pending navigation survives cold startup and model-context recovery with the window drafts.
struct ReminderNavigation {
    var pendingTaskID: UUID?
    static let prefix = "jianshi-reminder-"
    /// A "remind me later" copy. Its own prefix keeps it out of the scheduled-reminder reconciliation.
    static let snoozePrefix = "jianshi-snooze-"
    /// "jianshi-reminder-<task id>", optionally followed by "@<time>" for a later time of a repeating task.
    static func taskID(request: String) -> UUID? {
        for start in [prefix, snoozePrefix] where request.hasPrefix(start) {
            let rest = request.dropFirst(start.count)
            guard rest.count == 36 || rest.dropFirst(36).first == "@" || rest.dropFirst(36).first == "-" else { return nil }
            return UUID(uuidString: String(rest.prefix(36)))
        }
        return nil
    }
    static func url(_ id: UUID) -> URL { URL(string: "jianshi://reminder/" + id.uuidString)! }
    static func taskID(url: URL) -> UUID? {
        guard url.scheme == "jianshi", url.host == "reminder", url.pathComponents.count == 2,
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    mutating func take(blocked: Bool) -> UUID? {
        guard !blocked else { return nil }
        defer { pendingTaskID = nil }
        return pendingTaskID
    }
}
