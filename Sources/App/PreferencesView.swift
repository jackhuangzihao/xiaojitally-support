import SwiftUI
import SwiftData

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
                Section(L("小记 Pro", "TallyNest Pro")) {
                    ProUpgradeButton(title: PurchaseStore.shared.isPro ? L("管理 Pro", "Manage Pro") : L("升级 Pro", "Upgrade to Pro"))
                    Button(L("恢复购买", "Restore purchases")) { Task { await PurchaseStore.shared.restore() } }
                        .disabled(PurchaseStore.shared.busy || PurchaseStore.shared.developerUnlocked)
                    if let message = PurchaseStore.shared.message { Text(message).font(.caption) }
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
