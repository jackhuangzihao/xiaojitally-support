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
    /// The old single-snapshot limit; still bounds the one-time legacy download and the performance check.
    nonisolated static let maximumSnapshotBytes = 50 * 1024 * 1024
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
    /// The cloud copy this device synced with is gone (e.g. deleted in iCloud settings). Sync waits for the user.
    private(set) var cloudRemoved = false
    private(set) var migrationReview = false
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
        @MainActor func matches(_ context: ModelContext, baseline: Data?) -> Bool {
            contextID == ObjectIdentifier(context) && revision == Store.revision && self.baseline == baseline && !context.hasChanges
        }
    }
    @ObservationIgnored private var snapshotCache: SnapshotCache?
    /// The assembled cloud snapshot for one fetched state. Unchanged polls skip rebuilding and re-encoding it.
    private struct RemoteCache {
        let account: String
        let generation: Int
        let snapshot: TaskBackup
        let bytes: Data
    }
    @ObservationIgnored private var remoteCache: RemoteCache?
    /// One transport per iCloud account; its mirror file is keyed by a hash of the account.
    @ObservationIgnored private var transport: (account: String, value: any CloudRecordTransport)?
    private var context: ModelContext? { (Store.recovery.container ?? originalContainer)?.mainContext }
    var summary: String {
        if !enabled { return L("仅保存在本机", "Stored on this device") }
        if running { return L("正在同步 iCloud…", "Syncing with iCloud…") }
        if conflict { return L("iCloud · 需要处理同步冲突", "iCloud · Review sync conflicts") }
        if migrationReview { return L("iCloud · 需要核对升级副本", "iCloud · Review upgrade copies") }
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
            enabled = value; generation += 1; snapshotCache = nil; detail = ""; cloudRemoved = false; clearReview()
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
        migrationReview = false
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
                let (base, localBytes) = try await Task.detached {
                    (try baseline.map { try TaskBackup.decode($0, allowLargeFile: true) }, try CloudMerge.bytes(local))
                }.value
                guard canContinue(ticket, in: context) else { return }
                prepared = SnapshotCache(contextID: ObjectIdentifier(context), revision: revision, baseline: baseline,
                                         local: local, localBytes: localBytes, base: base)
                if prepared.matches(context, baseline: state.baseline) { snapshotCache = prepared }
            }
            let local = prepared.local, localBytes = prepared.localBytes, base = prepared.base
            let capturedRevision = prepared.revision
            let transport = try recordTransport(in: container, account: account)
            let cloudState = try await transport.fetch()
            guard canContinue(ticket, in: context) else { return }
            if let head = cloudState.head, head.format > CloudCommitProtocol.format { throw CloudRecordError.unsupportedFormat(head.format) }
            let remote: TaskBackup, remoteBytes: Data
            var cloudExists = true
            if cloudState.head != nil {
                (remote, remoteBytes) = try await cloudSnapshot(cloudState, account: account)
            } else {
                guard base == nil else {
                    cloudRemoved = true
                    throw TaskBackup.invalid(L("iCloud 中的小记数据已被删除，同步已暂停，未自动重新上传。确认后可在下方用本机数据重新上传。", "Tally’s data was deleted from iCloud. Sync paused without re-uploading. You can re-upload this device’s data below."))
                }
                remote = TaskBackup(lists: [], tasks: [])
                remoteBytes = try await Task.detached { try CloudMerge.bytes(TaskBackup(lists: [], tasks: [])) }.value
                cloudExists = false
            }
            let cloud = remote, existingCloud = cloudExists
            guard canContinue(ticket, in: context) else { return }
            // Only a complete committed cloud snapshot is eligible for the unchanged fast path.
            if cloudState.head != nil && localBytes == baseline && localBytes == remoteBytes && capturedRevision == Store.revision {
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
            // Always retain both sides before changing either, including before conflict resolution.
            if state.baseline == nil || localResultBytes != localBytes || uploadBytes != remoteBytes || resolvingConflict || plan.conflict != nil {
                try await protect(localBytes, remoteBytes, recovery: BackupFiles.SyncRecoveryKind.required(manualReview: resolvingConflict || plan.conflict != nil, automaticCount: plan.automaticFieldCount))
            }
            guard canContinue(ticket, in: context) else { return }
            if resolvingConflict && capturedRevision != Store.revision {
                clearReview(); pendingSave = true
                throw TaskBackup.invalid(L("处理冲突时数据又有变化，将重新检查。", "Data changed while resolving conflicts. Checking again."))
            }
            // Only rows that differ from the cloud are sent; an empty cloud also needs its first head.
            let changes = try await Task.detached {
                CloudRecordCodec.changes(from: cloudState.items, to: try CloudRecordCodec.items(plan.uploadSnapshot))
            }.value
            if !changes.isEmpty || cloudState.head == nil {
                // Recheck after awaits. Account changes invalidate every in-flight operation.
                guard try await container.userRecordID().recordName == account, canContinue(ticket, in: context) else { return }
                _ = try await transport.save(changes, round: (cloudState.head?.round ?? 0) + 1)
                remoteCache = nil
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
            lastSync = state.lastSync; detail = ""; cloudRemoved = false; clearReview()
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
                if error as? CloudRecordError == .cloudRemoved { cloudRemoved = true }
                if error as? CloudRecordError == .migrationReview { migrationReview = true }
                retryAfter = Self.retryDate(error)
                detail = Self.message(error)
                // Another device saved first: merge its changes again soon instead of waiting for the next poll.
                if error as? CloudRecordError == .changedElsewhere { pendingSave = true }
                if let retryAfter { detail += "\n" + L("Apple 要求暂缓请求，将在 ", "Apple requested a pause. Retrying after ") + retryAfter.formatted(date: .omitted, time: .standard) }
            }
        }
    }
    static func retryDate(_ error: Error, now: Date = Date()) -> Date? {
        guard let seconds = (error as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber,
              seconds.doubleValue.isFinite, seconds.doubleValue > 0 else { return nil }
        return now.addingTimeInterval(seconds.doubleValue)
    }
    private func recordTransport(in container: CKContainer, account: String) throws -> any CloudRecordTransport {
        if let transport, transport.account == account { return transport.value }
        let value = try CloudKitRecordTransport(container: container, account: account)
        transport = (account, value); remoteCache = nil
        return value
    }
    /// The transport exposes complete commits only; decoding stays off the main actor.
    private func cloudSnapshot(_ state: CloudState, account: String) async throws -> (TaskBackup, Data) {
        if let remoteCache, remoteCache.account == account, remoteCache.generation == state.generation {
            return (remoteCache.snapshot, remoteCache.bytes)
        }
        let items = state.items
        let (snapshot, bytes): (TaskBackup, Data)
        do {
            (snapshot, bytes) = try await Task.detached {
                let snapshot = try CloudRecordCodec.snapshot(items)
                return (snapshot, try CloudMerge.bytes(snapshot))
            }.value
        } catch {
            syncLog.error("Cloud rows do not form a valid snapshot: \(error.localizedDescription, privacy: .public)")
            throw CloudRecordError.inconsistentCloud(error.localizedDescription)
        }
        remoteCache = RemoteCache(account: account, generation: state.generation, snapshot: snapshot, bytes: bytes)
        return (snapshot, bytes)
    }
    /// After the cloud copy was deleted: keeps a recovery copy of this device's data, forgets the old merge base,
    /// and uploads this device's data as the new cloud copy. Other devices then merge into it as usual.
    func reuploadLocalData() async {
        guard enabled, cloudRemoved, !running, editors == 0, let context, !context.hasChanges else { return }
        let ticket = generation
        do {
            running = true
            defer {
                running = false
                if pendingSave { pendingSave = false; localSaved() }
            }
            try Store.recovery.requireWritable(context)
            let local = try TaskBackup.capture(context)
            let localBytes = try await Task.detached { try CloudMerge.bytes(local) }.value
            let emptyBytes = try await Task.detached { try CloudMerge.bytes(TaskBackup(lists: [], tasks: [])) }.value
            try await protect(localBytes, emptyBytes)
            guard canContinue(ticket, in: context) else { return }
            let account = try state(context).account
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.userRecordID().recordName == account else { throw CloudRecordError.changedElsewhere }
            guard canContinue(ticket, in: context) else { return }
            try await recordTransport(in: container, account: account).allowReupload()
            guard canContinue(ticket, in: context) else { return }
            let state = try state(context)
            guard state.account == account else { throw CloudRecordError.changedElsewhere }
            state.baseline = nil
            applying = true
            defer { applying = false }
            try Store.save(context)
            cloudRemoved = false; detail = ""; snapshotCache = nil; remoteCache = nil; retryAfter = nil
            syncLog.notice("Re-uploading local data after the cloud copy was removed")
        } catch {
            detail = error.localizedDescription
            return
        }
        await sync()
    }
    func migrationRecoveryCopy(source: String) async throws -> Data {
        guard let context, let account = try context.fetch(FetchDescriptor<CloudSyncState>()).first?.account, !account.isEmpty else {
            throw TaskBackup.invalid(L("尚无迁移恢复副本。", "No migration recovery copy yet."))
        }
        return try await Task.detached { try CloudMigration.recoveryCopy(account: account, source: source) }.value
    }
    /// The adapter protects both cloud sources and conditionally publishes against the reviewed migration head.
    func recoverMigrationWithLocalData() async {
        guard enabled, migrationReview, !running, editors == 0, let context, !context.hasChanges else { return }
        let ticket = generation
        running = true
        defer {
            running = false
            if pendingSave { pendingSave = false; localSaved() }
        }
        do {
            try Store.recovery.requireWritable(context)
            try await SyncChanges.prepareHistory(in: context)
            guard canContinue(ticket, in: context) else { return }
            let state = try state(context), account = state.account
            guard !account.isEmpty else { throw CloudRecordError.changedElsewhere }
            let local = try TaskBackup.capture(context), revision = Store.revision, contextID = ObjectIdentifier(context)
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.userRecordID().recordName == account else { throw CloudRecordError.changedElsewhere }
            guard canContinue(ticket, in: context), revision == Store.revision else { return }
            _ = try await recordTransport(in: container, account: account).recoverMigration(with: local) { [weak self] recovered in
                guard let self else { throw CancellationError() }
                try await self.confirmMigrationHistory(recovered, matching: local, ticket: ticket,
                    account: account, revision: revision, contextID: contextID)
            }
            // Later edits already descend from the confirmation. Normal sync advances the baseline without replacing them.
            pendingSave = true
            if context === self.context, state.account == account {
                detail = ""; migrationReview = false; remoteCache = nil; retryAfter = nil
            }
            syncLog.notice("Cloud migration recovered with the confirmed local copy")
        } catch {
            if ticket == generation && !Task.isCancelled {
                detail = Self.message(error)
                if error as? CloudRecordError == .changedElsewhere { pendingSave = true }
            }
        }
    }
    private func confirmMigrationHistory(_ recovered: TaskBackup, matching local: TaskBackup, ticket: Int,
                                         account: String, revision: Int, contextID: ObjectIdentifier) throws {
        guard let context, ObjectIdentifier(context) == contextID, canContinue(ticket, in: context),
              try state(context).account == account else { throw CloudRecordError.changedElsewhere }
        applying = true
        defer { applying = false }
        try Self.prepareMigrationHistory(recovered, matching: local, revision: revision, in: context)
        snapshotCache = nil; remoteCache = nil
    }
    /// Commit the user's choice before upload so subsequent edits inherit it, including after a crash or lost response.
    static func prepareMigrationHistory(_ recovered: TaskBackup, matching local: TaskBackup, revision: Int, in context: ModelContext) throws {
        guard revision == Store.revision, !context.hasChanges else { throw CloudRecordError.changedElsewhere }
        guard try SyncChanges.fingerprints(recovered) == SyncChanges.fingerprints(local) else {
            throw CloudRecordError.inconsistentCloud("Recovery changed local business contents")
        }
        try Store.discardingOnFailure(context) {
            try SyncChanges.stage(recovered.syncChanges, in: context)
            try Store.save(context, trackSyncChanges: false)
        }
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
        guard var error = error as? CKError else { return error.localizedDescription }
        // A partial failure wraps one error per record; the useful one is the record that was rejected.
        if error.code == .partialFailure, let inner = error.partialErrorsByItemID?.values.compactMap({ $0 as? CKError })
            .first(where: { $0.code != .batchRequestFailed }) { error = inner }
        switch error.code {
        case .networkUnavailable, .networkFailure: return L("网络不可用，恢复连接后会自动重试。本地修改已保留。", "Offline. Sync retries when connected. Local changes are retained.")
        case .quotaExceeded: return L("iCloud 空间不足，请释放空间后重试。本地修改已保留。", "iCloud storage is full. Free up space and retry. Local changes are retained.")
        case .serverRecordChanged: return L("另一台设备刚刚更新了数据，稍后会重新合并。", "Another device just updated the data. Sync will merge again shortly.")
        case .notAuthenticated: return L("请登录 iCloud 后重试。本地修改已保留。", "Sign in to iCloud and retry. Local changes are retained.")
        case .serverRejectedRequest, .invalidArguments, .permissionFailure:
            // Also what an iCloud container returns when its server-side structure doesn't match this build yet.
            return L("iCloud 拒绝了这次上传，本地修改已保留。可能是 iCloud 服务器还没有准备好这个版本的数据结构，请联系开发者。", "iCloud rejected this upload. Local changes are retained. Its server-side structure may not be ready for this version yet; please contact the developer.")
                + "\n" + error.localizedDescription
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
