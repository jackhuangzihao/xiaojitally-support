import SwiftUI
import SwiftData
import UserNotifications
import UniformTypeIdentifiers

#if os(macOS)
@MainActor final class BackupTerminationDelegate: NSObject, NSApplicationDelegate {
    private var waitingForTermination = false
    private var presentingQuitPrompt = false
    private let reply: @MainActor (Bool) -> Void
    private let unsaved: UnsavedEditorChanges
    private let confirmDiscard: @MainActor () -> Bool
    override init() {
        reply = { NSApp.reply(toApplicationShouldTerminate: $0) }
        unsaved = .shared
        confirmDiscard = Self.askToDiscard
        super.init()
    }
    init(unsaved: UnsavedEditorChanges? = nil, confirmDiscard: (@MainActor () -> Bool)? = nil,
         reply: @escaping @MainActor (Bool) -> Void) {
        self.unsaved = unsaved ?? .shared
        self.confirmDiscard = confirmDiscard ?? Self.askToDiscard
        self.reply = reply
        super.init()
    }
    private static func askToDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("还有未保存的修改", "You have unsaved changes")
        alert.informativeText = L("退出会丢弃尚未保存的输入。你可以返回编辑页面保存，或明确放弃这些修改后退出。", "Quitting will discard unsaved input. Return to the editors to save, or discard these changes and quit.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("继续编辑", "Keep editing")).keyEquivalent = "\r"
        alert.addButton(withTitle: L("放弃修改并退出", "Discard and quit")).keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func permitsQuit() -> Bool {
        guard unsaved.hasChanges else { return true }
        presentingQuitPrompt = true
        defer { presentingQuitPrompt = false }
        return confirmDiscard()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if presentingQuitPrompt { return .terminateCancel }
        if waitingForTermination { return .terminateLater }
        let saves = PendingEditorSaves.shared
        guard saves.hasPending || AutomaticBackup.shared.pendingWrites > 0 || ReminderScheduler.shared.hasPendingRefresh || WidgetBridge.pendingWrites > 0 else {
            waitingForTermination = true
            defer { waitingForTermination = false }
            return permitsQuit() ? .terminateNow : .terminateCancel
        }
        waitingForTermination = true
        let failures = saves.failureCount
        Task { @MainActor in
            repeat {
                guard await saves.waitForCompletion() else {
                    waitingForTermination = false
                    reply(false)
                    return
                }
                await ReminderScheduler.shared.finishPendingRefresh()
                await WidgetBridge.finishPublish()
            } while saves.hasPending
            // A second editor may have failed while the save's follow-up work was finishing.
            guard saves.failureCount == failures else {
                waitingForTermination = false
                reply(false)
                return
            }
            guard permitsQuit() else {
                waitingForTermination = false
                reply(false)
                return
            }
            if AutomaticBackup.shared.pendingWrites > 0 { AutomaticBackup.shared.finishBeforeQuit() }
            else { waitingForTermination = false; reply(true) }
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
            Task { @MainActor in
                do { try await SelfCheck.performance(); exit(0) }
                catch { print("PERFORMANCE CHECK FAILED: \(error)"); exit(1) }
            }
            RunLoop.main.run(); exit(1)
        }
        if CommandLine.arguments.contains("--self-check") {
            Task { @MainActor in
                do { try SelfCheck.run(); _ = try await CloudRecordChecks.run(); _ = try await SyncHistoryChecks.backgroundPreparation(); exit(0) }
                catch { print("SELF-CHECK FAILED: \(error)"); exit(1) }
            }
            RunLoop.main.run(); exit(1)
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
    @State private var syncSceneID = UUID()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ContentView(drafts: drafts, recoveryGeneration: Store.recovery.generation)
            .modelContainer(Store.recovery.container ?? container)
            .environment(drafts)
            .id(Store.recovery.generation)
            .onChange(of: phase, initial: true) { _, phase in
                CloudSync.shared.setSceneActive(phase == .active, id: syncSceneID)
            }
            .onDisappear { CloudSync.shared.setSceneActive(false, id: syncSceneID) }
            .task(id: Store.recovery.generation) {
                CloudSync.shared.cancelMaintenance()
                let context = (Store.recovery.container ?? container).mainContext
                do { try await SyncChanges.prepareHistory(in: context) }
                catch is CancellationError { return }
                catch { /* Preparation is optional; the next save still validates stored history. */ }
                guard !Task.isCancelled, context === (Store.recovery.container ?? container).mainContext else { return }
                AutomaticBackup.shared.save(context)
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await CloudSync.shared.sync()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}
