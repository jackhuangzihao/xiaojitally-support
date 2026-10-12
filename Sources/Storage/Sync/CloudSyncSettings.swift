import Foundation
import SwiftUI
import OSLog

private let syncLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "CloudSync")

/// Do not replace a model underneath an unsaved editor draft. Sync resumes when the last editor closes.
struct CloudSyncEditingGuard: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { CloudSync.shared.editing(true) }
            .onDisappear { CloudSync.shared.editing(false) }
    }
}

struct CloudSyncSettings: View {
    static func checkViewFootprint() throws -> Int {
        let sizes = ["preferences": MemoryLayout<PreferencesView.Body>.size,
                     "settings": MemoryLayout<CloudSyncSettings.Body>.size,
                     "review": MemoryLayout<SyncConflictReview.Body>.size,
                     "actions": MemoryLayout<SyncConflictActions.Body>.size,
                     "group": MemoryLayout<SyncConflictGroup.Body>.size]
        print("Sync view sizes (bytes): \(sizes)")
        guard sizes.values.allSatisfy({ $0 < 16_384 }) else {
            throw TaskBackup.invalid("Sync view exceeds the 16 KB per-component stack budget: \(sizes)")
        }
        return sizes.count
    }
    @Environment(\.locale) private var locale
    @State private var confirmEnable = false
    @State private var confirmReupload = false
    @State private var resolve = false
    @State private var export = false
    @State private var document: BackupDocument?
    @State private var exportError: String?
    private let sync: CloudSync
    init(sync: CloudSync = .shared) { self.sync = sync }
    var body: some View {
        Section(L("数据与同步", "Data and sync")) {
            Toggle("iCloud", isOn: Binding(get: { sync.enabled }, set: { if $0 { confirmEnable = true } else { sync.setEnabled(false) } }))
            Text(sync.summary).font(.callout)
                .foregroundStyle(sync.conflict ? Color.orange : .primary)
            if sync.enabled && sync.conflict {
                Text(L("相关项目需要核对。可以安全分离的其他修改会继续同步，本机数据仍可使用。", "Related items need review. Other changes continue syncing when they can be separated safely. Your local data remains available."))
                    .font(.callout)
                Button(L("核对并处理冲突…", "Review and resolve conflicts…")) { resolve = true }
                    .disabled(sync.running)
                    // A Section distributes presentation modifiers to its rows in Form.
                    // One concrete trigger must own the sheet to avoid competing presenters.
                    .sheet(isPresented: $resolve) {
                        let reviewID = sync.conflictReviewID
                        SyncConflictReview(items: sync.conflictItems, warning: sync.conflictWarning, initialChoices: sync.conflictSelections, canResolve: sync.enabled && sync.conflict && !sync.running,
                                           choose: { choices in
                            resolve = false
                            Task { await sync.sync(choices: choices, reviewID: reviewID) }
                        }, cancel: { resolve = false })
                        .id(reviewID)
                    }
            }
            Text(L("独立修改自动合并；同一处两边都改时保留后改的，已同步的处理结果会沿用。删除、金额等重要冲突仍需核对。使用同一 Apple 账户，打开 App 后同步；离线仍可编辑。", "Independent changes merge automatically; when both devices edit the same item, the later edit is kept, and synced decisions are retained. Deletions and important financial conflicts still need review. Use the same Apple Account with the app open; offline editing remains available."))
                .font(.caption).foregroundStyle(.secondary)
            if let summary = sync.automaticSummary {
                Text(L("最近一次自动处理了 \(summary.count) 处修改：", "Most recent automatic resolution: \(summary.count) edits, ")
                     + summary.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let date = sync.lastSync { Text(L("最近同步：", "Last synced: ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))).font(.caption).foregroundStyle(.secondary) }
            if !sync.detail.isEmpty && !sync.conflict { Text(sync.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if sync.enabled {
                Button(L("立即同步", "Sync now")) { Task { await sync.sync() } }.disabled(sync.running)
                if sync.cloudRemoved {
                    Button(L("用本机数据重新上传…", "Re-upload this device’s data…")) { confirmReupload = true }
                        .disabled(sync.running)
                        .confirmationDialog(L("用本机数据重新上传？", "Re-upload this device’s data?"), isPresented: $confirmReupload, titleVisibility: .visible) {
                            Button(L("重新上传", "Re-upload")) { Task { await sync.reuploadLocalData() } }
                        } message: {
                            Text(L("本机的任务、清单与账目会成为新的 iCloud 副本，其他设备之后会与它合并。上传前会先保存一份本机恢复副本，可在“导出同步恢复副本”中找到。", "This device’s tasks, lists and finances become the new iCloud copy, and other devices then merge with it. A local recovery copy is saved first; find it under Export sync recovery copy."))
                        }
                }
            }
            Menu(L("导出同步恢复副本", "Export sync recovery copy")) {
                Button(L("上次冲突处理前的本机副本", "Local copy before last conflict resolution")) { exportConflictCopy(local: true) }
                Button(L("上次冲突处理前的云端副本", "Cloud copy before last conflict resolution")) { exportConflictCopy(local: false) }
                Button(L("上次自动处理前的本机副本", "Local copy before last automatic resolution")) { exportConflictCopy(local: true, kind: .automaticMerge) }
                Button(L("上次自动处理前的云端副本", "Cloud copy before last automatic resolution")) { exportConflictCopy(local: false, kind: .automaticMerge) }
                Divider()
                Button(L("迁移前的旧快照", "Old snapshot before migration")) { exportMigrationCopy(source: "snapshot") }
                Button(L("迁移前的记录副本", "Record copy before migration")) { exportMigrationCopy(source: "records") }
                Button(L("合并前的本机副本", "Local copy before merge")) { exportCopy(owner: "sync-local") }
                Button(L("合并前的云端副本", "Cloud copy before merge")) { exportCopy(owner: "sync-cloud") }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.secondary) }
        }
        .fileExporter(isPresented: $export, document: document, contentType: .json, defaultFilename: "Tally-sync-recovery") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .confirmationDialog(L("开启 iCloud 同步？", "Enable iCloud sync?"), isPresented: $confirmEnable, titleVisibility: .visible) {
            Button(L("开启并合并数据", "Enable and merge data")) { sync.setEnabled(true) }
        } message: {
            Text(L("本机任务、清单与账目将上传到你自己的 iCloud 私有数据库，并与其他设备合并，占用你的 iCloud 空间。关闭同步不会删除已上传的副本。", "Your tasks, lists and finances will be uploaded to your private iCloud database and merged with other devices, using your iCloud storage. Turning sync off does not delete uploaded copies."))
        }
    }

    private func exportConflictCopy(local: Bool, kind: BackupFiles.SyncRecoveryKind = .manualConflict) {
        Task {
            do {
                let directory = try CloudSync.recoveryDirectory()
                let data = try await Task.detached {
                    guard let data = try BackupFiles.syncRecoveryCopy(directory: directory, local: local, kind: kind) else {
                        throw TaskBackup.invalid(kind == .manualConflict ? L("尚无冲突恢复副本。", "No conflict recovery copy yet.") : L("尚无自动处理的恢复副本。", "No automatic resolution recovery copy yet."))
                    }
                    return data
                }.value
                document = BackupDocument(data: data); exportError = nil; export = true
            } catch { exportError = error.localizedDescription }
        }
    }

    private func exportMigrationCopy(source: String) {
        Task {
            do {
                document = BackupDocument(data: try await sync.migrationRecoveryCopy(source: source))
                exportError = nil; export = true
            } catch { exportError = error.localizedDescription }
        }
    }

    private func exportCopy(owner: String) {
        Task {
            do {
                let directory = try CloudSync.recoveryDirectory()
                let data = try await Task.detached {
                    guard let file = try BackupFiles.ownedFiles(directory: directory, owner: owner).first else { throw TaskBackup.invalid(L("尚无同步恢复副本。", "No sync recovery copy yet.")) }
                    return try Data(contentsOf: file.url)
                }.value
                document = BackupDocument(data: data); exportError = nil; export = true
            } catch { exportError = error.localizedDescription }
        }
    }
}

/// Keep the sheet separate from the settings Form; each group owns its lazy detail layout.
private struct SyncConflictReview: View {
    let items: [CloudMerge.ConflictItem]
    let warning: String?
    let canResolve: Bool
    let choose: ([String: CloudMerge.Choice]) -> Void
    let cancel: () -> Void
    @State private var choices: [String: CloudMerge.Choice] = [:]
    @State private var resolving = false

    init(items: [CloudMerge.ConflictItem], warning: String?, initialChoices: [String: CloudMerge.Choice],
         canResolve: Bool, choose: @escaping ([String: CloudMerge.Choice]) -> Void, cancel: @escaping () -> Void) {
        self.items = items; self.warning = warning; self.canResolve = canResolve
        self.choose = choose; self.cancel = cancel
        _choices = State(initialValue: initialChoices)
    }

    private var allChosen: Bool { !items.isEmpty && items.allSatisfy { choices[$0.id] != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text(L("选择只用于仍需核对的差异，已自动合并的字段会保留。重复任务的时间与分支、账户币种与关联流水仍一起处理。冲突前的双方副本会单独保留。", "Your choice applies only to differences still needing review. Automatically merged fields are kept. Repeating schedules and branches, and account currencies with related postings, stay together. Both copies from before the conflict are retained separately."))
                        .font(.callout).foregroundStyle(.secondary)
                    if let warning { Text(warning).font(.callout).foregroundStyle(.orange) }
                    Menu(L("为所有组选择…", "Choose for all groups…")) {
                        Button(L("全部选本机", "Select local for all")) { selectAll(.local) }
                        Button(L("全部选云端", "Select cloud for all")) { selectAll(.cloud) }
                    }.disabled(!canResolve)
                    ForEach(items) { item in
                        SyncConflictGroup(item: item, selection: Binding(get: { choices[item.id] }, set: { choices[item.id] = $0 }))
                            .disabled(!canResolve)
                    }
                    if !canResolve {
                        Text(L("同步状态已变化，请返回后重新检查。", "Sync status changed. Go back and review it again."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SyncConflictActions(selected: items.filter { choices[$0.id] != nil }.count, total: items.count,
                                    enabled: canResolve && allChosen && !resolving) {
                    resolving = true
                    choose(choices)
                }
            }
            .navigationTitle(L("核对同步冲突", "Review sync conflicts"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("暂不处理", "Decide later"), role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { syncLog.notice("Conflict review opened") }
        .onDisappear { if !resolving { syncLog.notice("Conflict review cancelled") } }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 640)
        #endif
    }
    private func selectAll(_ choice: CloudMerge.Choice) {
        choices = Dictionary(uniqueKeysWithValues: items.map { ($0.id, choice) })
    }
}

private struct SyncConflictGroup: View {
    let item: CloudMerge.ConflictItem
    @Binding var selection: CloudMerge.Choice?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(CloudMerge.Conflict.reportSections(item.detail).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph).font(.callout).textSelection(.enabled)
            }
            Picker(L("此组保留", "Keep for this group"), selection: $selection) {
                Text(L("请选择", "Choose…")).tag(Optional<CloudMerge.Choice>.none)
                Text(L("本机", "Local")).tag(Optional(CloudMerge.Choice.local))
                Text(L("云端", "Cloud")).tag(Optional(CloudMerge.Choice.cloud))
            }
            .pickerStyle(.menu).frame(minHeight: 44)
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncConflictActions: View {
    let selected: Int
    let total: Int
    let enabled: Bool
    let confirm: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Divider()
            Text(L("已选择 \(selected) / \(total) 组", "Selected \(selected) of \(total) groups"))
                .font(.caption).foregroundStyle(.secondary)
            Button(action: confirm) {
                Text(L("确认选择并同步", "Confirm choices and sync"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(!enabled)
        }
        .controlSize(.regular).multilineTextAlignment(.center)
        .padding(.horizontal).padding(.bottom, 8).background(Color.appBackground)
    }
}
