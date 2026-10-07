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
        if CommandLine.arguments.contains("--sync-conflict-ui-fixture") {
            do { try SyncConflictUIFixture.requireSandbox() }
            catch { print("SYNC UI FIXTURE FAILED: \(error)"); exit(1) }
            // This review fixture must return before attaching storage or CloudSync.
            storage = .failure(TaskBackup.invalid("Synthetic sync review"))
            return
        }
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
            #if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
            if CommandLine.arguments.contains("--sync-conflict-ui-fixture") {
                SyncConflictUIFixture()
                    .tint(.accentColor)
                    .preferredColorScheme(UISettings.colorScheme(appearance))
                    .environment(\.locale, UISettings.locale(for: language, preferredLanguages: systemLanguages))
            } else { normalWindow }
            #else
            normalWindow
            #endif
        }
        #if os(macOS)
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1120, height: 790)
        .commands { TaskHistoryCommands() }
        #endif
    }

    @ViewBuilder private var normalWindow: some View {
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
