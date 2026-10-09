import Foundation
import SwiftData
import CloudKit
import Observation
import OSLog

private let syncLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "CloudSync")

/// Local only. Saving the merge base in the same transaction as imported rows makes retries crash-safe.
@Model final class CloudSyncState {
    var enabled = false
    var account: String = ""
    var baseline: Data?
    var changeHistory: Data?
    var lastSync: Date?
    init() {}
}

/// Device-local feedback only; never part of the cloud payload or conflict decisions.
struct AutomaticSyncSummary: Equatable {
    let count: Int
    let date: Date
    private static let defaultsKey = "lastAutomaticSyncSummary"

    static func load(account: String, defaults: UserDefaults = .standard) -> Self? {
        guard !account.isEmpty, let value = defaults.dictionary(forKey: defaultsKey),
              value["account"] as? String == CloudMerge.digest(Data(account.utf8)),
              let count = value["count"] as? Int, count > 0,
              let date = value["date"] as? Date, date.timeIntervalSince1970.isFinite else { return nil }
        return Self(count: count, date: date)
    }

    static func record(count: Int, date: Date = Date(), account: String, defaults: UserDefaults = .standard) -> Self? {
        // A later routine sync must not hide the most recent automatic resolution.
        guard count > 0, !account.isEmpty, date.timeIntervalSince1970.isFinite else { return load(account: account, defaults: defaults) }
        defaults.set(["account": CloudMerge.digest(Data(account.utf8)), "count": count, "date": date], forKey: defaultsKey)
        return Self(count: count, date: date)
    }
}

@MainActor @Observable final class CloudSync {
    static let shared = CloudSync()
    static let containerID = "iCloud.local.jianshi.personal"
    static let maximumSnapshotBytes = 50 * 1024 * 1024
    private(set) var enabled = false
    private(set) var running = false
    private(set) var detail = ""
    private(set) var lastSync: Date?
    private(set) var conflict = false
    private(set) var automaticSummary: AutomaticSyncSummary?
    private(set) var conflictItems: [CloudMerge.ConflictItem] = []
    private(set) var conflictReviewID = UUID()
    private(set) var conflictWarning: String?
    private(set) var conflictSelections: [String: CloudMerge.Choice] = [:]
    private(set) var accountChanged = false
    private var originalContainer: ModelContainer?
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var applying = false
    private var pendingSave = false
    private var editors = 0
    private var conflictLocal: Data?
    private var conflictCloud: Data?
    private var conflictBaseline: Data?
    /// Keep legacy clock checks stable for the exact data the user reviewed.
    private var conflictEvaluationDate: Date?
    private var observer: NSObjectProtocol?
    private var retryAfter: Date?
    /// Only cache a saved context revision. Recovery replaces the context; every save changes revision.
    struct SnapshotCache {
        let contextID: ObjectIdentifier
        let revision: Int
        let baseline: Data?
        let local: TaskBackup
        let localBytes: Data
        let base: TaskBackup?
        let baselineDigest: String?
        @MainActor func matches(_ context: ModelContext, baseline: Data?) -> Bool {
            contextID == ObjectIdentifier(context) && revision == Store.revision && self.baseline == baseline && !context.hasChanges
        }
    }
    @ObservationIgnored private var snapshotCache: SnapshotCache?
    /// A partial baseline differs from the cloud copy. Reuse its verified payload on unchanged polls.
    private struct RemoteCache {
        let account: String
        let digest: String
        let snapshot: TaskBackup
        let bytes: Data
    }
    @ObservationIgnored private var remoteCache: RemoteCache?
    private var context: ModelContext? { (Store.recovery.container ?? originalContainer)?.mainContext }
    var summary: String {
        if !enabled { return L("仅保存在本机", "Stored on this device") }
        if running { return L("正在同步 iCloud…", "Syncing with iCloud…") }
        if conflict { return L("iCloud · 需要处理同步冲突", "iCloud · Review sync conflicts") }
        if !detail.isEmpty { return L("iCloud · 等待同步", "iCloud · Sync pending") }
        return L("iCloud 同步已开启", "iCloud sync enabled")
    }
    func editing(_ began: Bool) {
        editors = max(0, editors + (began ? 1 : -1))
        if began { generation += 1 }
        else if editors == 0 { localSaved() }
    }
    func attach(_ container: ModelContainer) {
        generation += 1; snapshotCache = nil; remoteCache = nil; automaticSummary = nil; clearReview()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        originalContainer = container
        do {
            if let state = try container.mainContext.fetch(FetchDescriptor<CloudSyncState>()).first {
                enabled = state.enabled; lastSync = state.lastSync
                automaticSummary = AutomaticSyncSummary.load(account: state.account)
            }
        } catch { detail = error.localizedDescription }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.generation += 1; self.snapshotCache = nil; self.remoteCache = nil; self.automaticSummary = nil; self.clearReview()
                self.localSaved()
            }
        }
    }
    private func state(_ context: ModelContext) throws -> CloudSyncState {
        let states = try context.fetch(FetchDescriptor<CloudSyncState>())
        guard states.count <= 1 else { throw TaskBackup.invalid("Multiple sync states") }
        if let state = states.first { return state }
        let state = CloudSyncState(); context.insert(state); return state
    }
    func setEnabled(_ value: Bool) {
        guard let context else { return }
        do {
            try Store.recovery.requireWritable(context)
            let state = try state(context); state.enabled = value
            applying = true; defer { applying = false }
            try Store.save(context)
            enabled = value; generation += 1; snapshotCache = nil; detail = ""; clearReview()
            debounce?.cancel()
            if value { Task { await sync() } }
        } catch { detail = error.localizedDescription }
    }
    func localSaved() {
        guard enabled, !applying else { return }
        if conflict, let snapshotCache, snapshotCache.revision != Store.revision {
            clearReview()
        }
        if running { pendingSave = true; return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }
    private func clearReview() {
        conflict = false; conflictLocal = nil; conflictCloud = nil; conflictBaseline = nil; conflictEvaluationDate = nil
        conflictItems = []; conflictWarning = nil; conflictSelections = [:]
    }
    private func retainReview(_ error: CloudMerge.Conflict, local: Data, cloud: Data, baseline: Data?,
                              evaluatedAt: Date, choices: [String: CloudMerge.Choice]) {
        conflict = true; conflictLocal = local; conflictCloud = cloud; conflictBaseline = baseline; conflictEvaluationDate = evaluatedAt
        conflictItems = error.items; conflictReviewID = UUID(); conflictWarning = error.warning
        let keys = Set(error.items.map(\.id))
        conflictSelections = choices.filter { keys.contains($0.key) }
    }
    private func canContinue(_ ticket: Int, in context: ModelContext) -> Bool {
        !Task.isCancelled && enabled && ticket == generation && editors == 0 && context === self.context &&
            Store.recovery.failure == nil && !context.hasChanges
    }
    func sync(choices: [String: CloudMerge.Choice] = [:], reviewID: UUID? = nil) async {
        guard choices.isEmpty || reviewID != nil else { return }
        let resolvingConflict = reviewID != nil
        if resolvingConflict && (!conflict || reviewID != conflictReviewID) {
            syncLog.notice("Ignored expired conflict review")
            return
        }
        guard enabled, !running, editors == 0, let context, Store.recovery.failure == nil, !context.hasChanges else { return }
        if let retryAfter, Date() < retryAfter { return }
        var resolutionResult = "interrupted"
        if resolvingConflict { syncLog.notice("Conflict resolution started") }
        running = true
        defer {
            if resolvingConflict { syncLog.notice("Conflict resolution \(resolutionResult, privacy: .public)") }
            running = false
            if pendingSave { pendingSave = false; localSaved() }
        }
        let ticket = generation
        do {
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.accountStatus() == .available else {
                throw TaskBackup.invalid(L("请在系统设置登录 iCloud 并允许小记使用 iCloud。本地数据仍可编辑。", "Sign in to iCloud in System Settings and allow Tally to use iCloud. Local editing remains available."))
            }
            let account = try await container.userRecordID().recordName
            guard canContinue(ticket, in: context) else { return }
            let state = try state(context)
            if !state.account.isEmpty && state.account != account {
                snapshotCache = nil
                accountChanged = true; automaticSummary = nil
                throw TaskBackup.invalid(L("iCloud 账户已改变。为避免把原账户数据传给其他人，同步已暂停。切回原账户后可继续。", "The iCloud account changed. Sync is paused to avoid uploading the previous account’s data. Switch back to the original account to continue."))
            }
            accountChanged = false
            automaticSummary = AutomaticSyncSummary.load(account: account)
            // Bind before the first upload, including failed/offline attempts. Never silently rebind accounts.
            if state.account.isEmpty {
                state.account = account
                applying = true
                defer { applying = false }
                try Store.save(context)
            }
            // Join a running startup preparation before copying metadata; normal editing never waits for it.
            try await SyncChanges.prepareHistory(in: context)
            guard canContinue(ticket, in: context) else { return }
            let baseline = state.baseline
            let prepared: SnapshotCache
            if let cached = snapshotCache, cached.matches(context, baseline: baseline) {
                prepared = cached
            } else {
                let local = try TaskBackup.capture(context), revision = Store.revision
                let (base, localBytes, baselineDigest) = try await Task.detached {
                    (try baseline.map { try TaskBackup.decode($0, allowLargeFile: true) },
                     try CloudMerge.bytes(local), baseline.map(CloudMerge.digest))
                }.value
                guard canContinue(ticket, in: context) else { return }
                prepared = SnapshotCache(contextID: ObjectIdentifier(context), revision: revision, baseline: baseline,
                                         local: local, localBytes: localBytes, base: base, baselineDigest: baselineDigest)
                if prepared.matches(context, baseline: state.baseline) { snapshotCache = prepared }
            }
            let local = prepared.local, localBytes = prepared.localBytes, base = prepared.base
            let capturedRevision = prepared.revision, baselineDigest = prepared.baselineDigest
            let database = container.privateCloudDatabase
            let recordID = CKRecord.ID(recordName: "tally-personal-v1")
            var record: CKRecord
            var remote: TaskBackup
            var unchangedRemoteBytes: Data?
            var cloudExists = true
            do {
                let headers = try await database.records(for: [recordID], desiredKeys: ["formatVersion", "digest"])
                guard let header = headers[recordID] else { throw TaskBackup.invalid("Missing CloudKit fetch result") }
                record = try header.get()
                guard (record["formatVersion"] as? Int64) == 1 else {
                    throw TaskBackup.invalid(L("云端格式暂不支持，请更新小记。", "Update Tally to read this cloud format."))
                }
                if let base, let baselineDigest, record["digest"] as? String == baselineDigest {
                    remote = base // Do not download the asset again when nothing changed in the cloud.
                    unchangedRemoteBytes = baseline
                } else if let cached = remoteCache, cached.account == account,
                          record["digest"] as? String == cached.digest {
                    remote = cached.snapshot; unchangedRemoteBytes = cached.bytes
                } else {
                    record = try await database.record(for: recordID)
                    guard (record["formatVersion"] as? Int64) == 1, let url = (record["snapshot"] as? CKAsset)?.fileURL else { throw TaskBackup.invalid("Unsupported cloud snapshot") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= Self.maximumSnapshotBytes else { throw TaskBackup.invalid(L("云端数据超过当前同步上限（50 MB）。本地数据不受影响。", "Cloud data exceeds the current 50 MB sync limit. Local data is unaffected.")) }
                    remote = try await Task.detached {
                        try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true)
                    }.value
                }
            } catch let error as CKError where error.code == .unknownItem {
                guard base == nil else { throw TaskBackup.invalid(L("云端副本已被移除，同步已暂停，未自动重新上传。请先导出本地备份并联系支持。", "The cloud copy was removed. Sync paused without re-uploading it. Export a local backup and contact support.")) }
                record = CKRecord(recordType: "TallySnapshot", recordID: recordID)
                remote = TaskBackup(lists: [], tasks: [])
                cloudExists = false
            }
            let cloud = remote, existingCloud = cloudExists
            let remoteBytes: Data
            if let unchangedRemoteBytes { remoteBytes = unchangedRemoteBytes }
            else { remoteBytes = try await Task.detached { try CloudMerge.bytes(cloud) }.value }
            guard canContinue(ticket, in: context) else { return }
            if unchangedRemoteBytes == nil {
                let remoteDigest = await Task.detached { CloudMerge.digest(remoteBytes) }.value
                if record["digest"] as? String == remoteDigest {
                    remoteCache = RemoteCache(account: account, digest: remoteDigest, snapshot: cloud, bytes: remoteBytes)
                }
            }
            guard canContinue(ticket, in: context) else { return }
            if localBytes == baseline && localBytes == remoteBytes && capturedRevision == Store.revision {
                lastSync = Date(); detail = ""; clearReview()
                resolutionResult = "succeeded"
                return
            }
            // A pending review must still observe another device's progress. Unchanged inputs keep the same sheet token.
            if conflict && !resolvingConflict && conflictLocal == localBytes && conflictCloud == remoteBytes && conflictBaseline == baseline { return }
            if resolvingConflict && (conflictLocal != localBytes || conflictCloud != remoteBytes || conflictBaseline != baseline) {
                clearReview()
                throw TaskBackup.invalid(L("数据已变化，请重新同步后再处理冲突。", "Data changed. Sync again before resolving conflicts."))
            }
            if conflictLocal != localBytes || conflictCloud != remoteBytes || conflictBaseline != baseline { conflictEvaluationDate = nil }
            let evaluatedAt = conflictEvaluationDate ?? Date()
            let plan: PartialSyncMerge.Result
            let localResultBytes: Data, uploadBytes: Data, baselineBytes: Data
            do {
                (plan, localResultBytes, uploadBytes, baselineBytes) = try await Task.detached {
                    let result = try PartialSyncMerge.prepare(local: local, cloud: cloud, base: base,
                        cloudExists: existingCloud, choices: choices, now: evaluatedAt)
                    let bytes = try CloudMerge.bytes(result.localSnapshot)
                    if result.conflict == nil { return (result, bytes, bytes, bytes) }
                    return (result, bytes, try CloudMerge.bytes(result.uploadSnapshot),
                            try CloudMerge.bytes(result.baselineSnapshot))
                }.value
            } catch let error as CloudMerge.Conflict {
                try await protect(localBytes, remoteBytes, recovery: [.manualConflict])
                guard canContinue(ticket, in: context) else { return }
                retainReview(error, local: localBytes, cloud: remoteBytes, baseline: baseline, evaluatedAt: evaluatedAt, choices: choices)
                throw error
            } catch {
                try await protect(localBytes, remoteBytes)
                guard canContinue(ticket, in: context) else { return }
                clearReview()
                throw TaskBackup.invalid(L("两端的关联变化无法安全合并，未覆盖任何数据。请导出双方恢复副本，检查相关账户、退款或清单后重试。", "Related changes cannot be merged safely. No data was overwritten. Export both recovery copies and review the affected accounts, refunds or lists before retrying.") + "\n" + error.localizedDescription)
            }
            guard uploadBytes.count <= Self.maximumSnapshotBytes else { throw TaskBackup.invalid(L("数据超过当前同步上限（50 MB）。请继续使用本地备份。", "Data exceeds the current 50 MB sync limit. Continue using local backups.")) }
            // ponytail: one atomic asset keeps finance relationships consistent, bounded at 50 MB.
            // Use per-entity CloudKit records if measured personal ledgers outgrow snapshot uploads.
            // Always retain both sides before changing either, including before conflict resolution.
            if state.baseline == nil || localResultBytes != localBytes || uploadBytes != remoteBytes || resolvingConflict || plan.conflict != nil {
                try await protect(localBytes, remoteBytes, recovery: BackupFiles.SyncRecoveryKind.required(manualReview: resolvingConflict || plan.conflict != nil, automaticCount: plan.automaticFieldCount))
            }
            guard canContinue(ticket, in: context) else { return }
            if resolvingConflict && capturedRevision != Store.revision {
                clearReview(); pendingSave = true
                throw TaskBackup.invalid(L("处理冲突时数据又有变化，将重新检查。", "Data changed while resolving conflicts. Checking again."))
            }
            if uploadBytes != remoteBytes || record.recordChangeTag == nil {
                // Recheck after awaits. Account changes invalidate every in-flight operation.
                guard try await container.userRecordID().recordName == account, canContinue(ticket, in: context) else { return }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: file) }
                let digest = try await Task.detached {
                    try uploadBytes.write(to: file, options: .atomic)
                    return CloudMerge.digest(uploadBytes)
                }.value
                guard canContinue(ticket, in: context) else { return }
                record["snapshot"] = CKAsset(fileURL: file)
                record["formatVersion"] = Int64(1)
                record["digest"] = digest
                let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                guard let saved = result.saveResults[recordID] else { throw TaskBackup.invalid("Missing CloudKit save result") }
                _ = try saved.get()
                remoteCache = RemoteCache(account: account, digest: digest, snapshot: plan.uploadSnapshot, bytes: uploadBytes)
            }
            guard canContinue(ticket, in: context) else { return }
            // Edits made while the upload was in flight are merged again, never overwritten by its old snapshot.
            let current = try TaskBackup.capture(context)
            let importRevision = Store.revision
            let (final, finalBytes, changed, rebaseCount) = try await Task.detached {
                let result = try CloudMerge.mergeResult(local: current, cloud: plan.localSnapshot, base: local, now: evaluatedAt)
                let bytes = try CloudMerge.bytes(result.snapshot)
                return (result.snapshot, bytes, try bytes != CloudMerge.bytes(current), result.automaticFieldCount)
            }.value
            if rebaseCount > 0 {
                let currentBytes = try await Task.detached { try CloudMerge.bytes(current) }.value
                try await protect(currentBytes, localResultBytes, recovery: [.automaticMerge])
            }
            guard canContinue(ticket, in: context) else { return }
            // A quick edit can save while the worker runs. Discard stale work and retry from fresh data.
            applying = true
            defer { applying = false }
            guard try CloudMerge.commit(final, changed: changed, baseline: baselineBytes, state: state,
                                        revision: importRevision, in: context) else { pendingSave = true; return }
            // A save may normalize list colors. Refill from the actual committed context on the next poll.
            snapshotCache = nil
            lastSync = state.lastSync; detail = ""; clearReview()
            if let review = plan.conflict, finalBytes == localResultBytes {
                retainReview(review, local: finalBytes, cloud: uploadBytes, baseline: baselineBytes, evaluatedAt: evaluatedAt, choices: choices)
                detail = L("相关项目等待核对，其余修改已同步。", "Related items await review; other changes have synced.")
            }
            let automaticTotal = plan.automaticFieldCount + rebaseCount
            automaticSummary = AutomaticSyncSummary.record(count: automaticTotal, account: account)
            syncLog.notice("Sync committed; automatic field decisions: \(automaticTotal, privacy: .public)")
            resolutionResult = "succeeded"
            if finalBytes != localResultBytes { pendingSave = true; detail = L("新修改等待上传。", "New edits are waiting to upload.") }
        } catch is CancellationError {
            // Leaving the scene or replacing its store cancels work; it is not a sync failure.
            resolutionResult = "cancelled"
        } catch {
            // Cloud errors never put the local store into read-only recovery.
            if ticket == generation && !Task.isCancelled {
                resolutionResult = "failed"
                retryAfter = Self.retryDate(error)
                detail = Self.message(error)
                if let retryAfter { detail += "\n" + L("Apple 要求暂缓请求，将在 ", "Apple requested a pause. Retrying after ") + retryAfter.formatted(date: .omitted, time: .standard) }
            }
        }
    }
    static func retryDate(_ error: Error, now: Date = Date()) -> Date? {
        guard let seconds = (error as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber,
              seconds.doubleValue.isFinite, seconds.doubleValue > 0 else { return nil }
        return now.addingTimeInterval(seconds.doubleValue)
    }
    static func recoveryDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiBackups/BeforeSync", isDirectory: true)
    }
    private func protect(_ local: Data, _ cloud: Data, recovery: [BackupFiles.SyncRecoveryKind] = []) async throws {
        let directory = try Self.recoveryDirectory()
        try await Task.detached {
            for kind in recovery { try BackupFiles.protectSyncCopies(local: local, cloud: cloud, directory: directory, kind: kind) }
            // Routine, manual and automatic recovery copies each have independent retention.
            _ = try BackupFiles.save(TaskBackup.decode(local, allowLargeFile: true), directory: directory, owner: "sync-local", force: false)
            _ = try BackupFiles.save(TaskBackup.decode(cloud, allowLargeFile: true), directory: directory, owner: "sync-cloud", force: false)
        }.value
    }
    static func message(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .networkUnavailable, .networkFailure: return L("网络不可用，恢复连接后会自动重试。本地修改已保留。", "Offline. Sync retries when connected. Local changes are retained.")
        case .quotaExceeded: return L("iCloud 空间不足，请释放空间后重试。本地修改已保留。", "iCloud storage is full. Free up space and retry. Local changes are retained.")
        case .serverRecordChanged: return L("另一台设备刚刚更新了数据，稍后会重新合并。", "Another device just updated the data. Sync will merge again shortly.")
        case .notAuthenticated: return L("请登录 iCloud 后重试。本地修改已保留。", "Sign in to iCloud and retry. Local changes are retained.")
        default: return L("iCloud 暂未同步，本地修改已保留。", "iCloud sync is pending. Local changes are retained.") + "\n" + error.localizedDescription
        }
    }
}

#if (os(macOS) && JIANSHI_APP_STORE) || targetEnvironment(simulator)
extension CloudSync {
    static func conflictUIFixture() -> CloudSync {
        let sync = CloudSync()
        sync.enabled = true; sync.conflict = true
        let rows = (1...320).map { index in
            L("任务 \(index)\n本机：核对出行安排 \(index) · 未完成\n云端：核对出行安排 \(index) · 已完成\n差异：完成状态或完成时间、备注", "Task \(index)\nLocal: Review travel plans \(index) · Open\nCloud: Review travel plans \(index) · Completed\nDifferences: completion status/time, notes")
        }
        sync.conflictItems = rows.enumerated().map { CloudMerge.ConflictItem(id: "fixture-\($0.offset)", detail: $0.element) }
        sync.detail = CloudMerge.Conflict(label: rows.joined(separator: "\n\n——\n\n")).localizedDescription
        return sync
    }
}
#endif
