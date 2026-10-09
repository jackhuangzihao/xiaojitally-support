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
                     "actions": MemoryLayout<SyncConflictActions.Body>.size]
        print("Sync view sizes (bytes): \(sizes)")
        guard sizes.values.allSatisfy({ $0 < 16_384 }) else {
            throw TaskBackup.invalid("Sync view exceeds the 16 KB per-component stack budget: \(sizes)")
        }
        return sizes.count
    }
    @Environment(\.locale) private var locale
    @State private var confirmEnable = false
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
                Text(L("两端修改了相同内容，或存在删除、重复任务及关联账目的冲突。请核对要保留的版本；本机数据仍可使用。", "Both devices changed the same content, or their changes conflict over deletions, repeating tasks or related financial records. Review which version to keep. Your local data remains available."))
                    .font(.callout)
                Button(L("核对并处理冲突…", "Review and resolve conflicts…")) { resolve = true }
                    .disabled(sync.running)
                    // A Section distributes presentation modifiers to its rows in Form.
                    // One concrete trigger must own the sheet to avoid competing presenters.
                    .sheet(isPresented: $resolve) {
                        SyncConflictReview(detail: sync.detail, canResolve: sync.enabled && sync.conflict && !sync.running,
                                           choose: { choice in
                            resolve = false
                            Task { await sync.sync(choice: choice) }
                        }, cancel: { resolve = false })
                    }
            }
            Text(L("互不冲突的修改自动合并；可能覆盖内容时请你核对。使用同一 Apple 账户，打开 App 后同步；离线仍可编辑。", "Independent changes merge automatically; changes that could overwrite content need review. Sync uses the same Apple Account while the app is open. Offline editing remains available."))
                .font(.caption).foregroundStyle(.secondary)
            if let date = sync.lastSync { Text(L("上次完成：", "Last completed: ") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))).font(.caption).foregroundStyle(.secondary) }
            if !sync.detail.isEmpty && !sync.conflict { Text(sync.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if sync.enabled {
                Button(L("立即同步", "Sync now")) { Task { await sync.sync() } }.disabled(sync.running || sync.conflict)
            }
            Menu(L("导出同步恢复副本", "Export sync recovery copy")) {
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

/// Keep the presented view independent of the settings Form's value tree. Conflict
/// reports can be long, so paragraphs are laid out lazily instead of in one huge Text.
private struct SyncConflictReview: View {
    let sections: [String]
    let canResolve: Bool
    let choose: (CloudMerge.Choice) -> Void
    let cancel: () -> Void
    @State private var resolving = false

    init(detail: String, canResolve: Bool, choose: @escaping (CloudMerge.Choice) -> Void,
         cancel: @escaping () -> Void) {
        sections = CloudMerge.Conflict.reportSections(detail)
        self.canResolve = canResolve; self.choose = choose; self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(L("下面的选择适用于本次列出的所有冲突。重复任务分叉或结构变化时按整条序列选择；账户币种与关联流水一起选择；本位币冲突按整本账目选择。其他独立修改继续合并。合并前已保存双方恢复副本。", "Your choice applies to all listed conflicts. When repeating tasks branch or change structure, the whole chain is selected; account currencies stay with their related postings; base-currency conflicts affect the entire ledger. Other independent changes are merged. Recovery copies of both sides are saved first."))
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if !canResolve {
                        Text(L("同步状态已变化，请返回后重新检查。", "Sync status changed. Go back and review it again."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SyncConflictActions(enabled: canResolve) { choice in
                    resolving = true
                    choose(choice)
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
        .onDisappear {
            if !resolving { syncLog.notice("Conflict review cancelled") }
        }
        #if os(macOS)
        .frame(width: 560, height: 560)
        #endif
    }
}

private struct SyncConflictActions: View {
    let enabled: Bool
    let choose: (CloudMerge.Choice) -> Void
    var body: some View {
        VStack(spacing: 8) {
            Divider()
            Button { choose(.local) } label: {
                Text(L("所有冲突保留本机修改", "Keep local changes for all conflicts"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Button { choose(.cloud) } label: {
                Text(L("所有冲突保留云端修改", "Keep cloud changes for all conflicts"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .buttonStyle(.bordered).controlSize(.regular).multilineTextAlignment(.center)
        .disabled(!enabled).padding(.horizontal).padding(.bottom, 8)
        .background(Color.appBackground)
    }
}
