import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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
