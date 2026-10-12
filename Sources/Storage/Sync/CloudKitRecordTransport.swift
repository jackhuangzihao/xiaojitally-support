import Foundation
import CloudKit
import OSLog

private let engineLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "CloudSyncEngine")

/// What this device last fetched from the zone, plus the sync engine's own state, saved together in one file
/// so a crash can never leave the engine's change token ahead of the rows it stands for.
struct CloudMirror: Codable {
    struct Entry: Codable {
        var item: CloudItem
        var round: Int64
        var systemFields: Data?
        var writer: String?
        var modified: Date?
        /// See `CloudState.previous`.
        var previous: CloudItem?
    }
    var items: [String: Entry] = [:]
    var head: CloudHead?
    var headSystemFields: Data?
    var engineState: Data?
    var zoneReady = false
    var generation = 0
    /// Set once a fetch has completed, so a row missing from the mirror is known not to exist.
    var complete: Bool?

    var state: CloudState {
        CloudState(items: items.mapValues(\.item), rounds: items.mapValues(\.round), head: head, generation: generation,
                   writers: items.compactMapValues(\.writer), writtenAt: items.compactMapValues(\.modified),
                   previous: items.compactMapValues(\.previous))
    }
    mutating func clearContents() {
        items = [:]; head = nil; headSystemFields = nil; zoneReady = false; complete = nil; generation += 1
    }
}

/// CKSyncEngine transport. Zone layout: one `TallyItem` record per row, keyed by its sync key, with the payload and
/// revision in encrypted fields; and one `TallyHead` record written after each upload round.
/// Fetching and sending only run when `CloudSync` asks, so its debounce, editing pauses and review flow stay in control.
actor CloudKitRecordTransport: CloudRecordTransport, CKSyncEngineDelegate {
    static let zoneID = CKRecordZone.ID(zoneName: "Tally", ownerName: CKCurrentUserDefaultName)
    private static let headID = CKRecord.ID(recordName: "head", zoneID: zoneID)
    private enum RecordType { static let item = "TallyItem", head = "TallyHead" }
    private enum Field { static let payload = "payload", revision = "revision", round = "round", format = "format", writer = "writer" }

    private let database: CKDatabase
    private let file: URL
    private var engine: CKSyncEngine?
    private var mirror: CloudMirror?
    private var mirrorChanged = false
    /// Records of the save in progress; the batch provider reads from here.
    private var outgoing: [CKRecord.ID: CKRecord] = [:]
    private var conflicted = false
    private var sendFailures: [Error] = []

    /// `account` only names the mirror file (hashed), so two iCloud accounts never share a cache.
    init(database: CKDatabase, account: String) throws {
        self.database = database
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiSync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent(String(CloudMerge.digest(Data(account.utf8)).prefix(32)) + ".json")
    }

    func fetch() async throws -> CloudState {
        let engine = try engineInstance()
        try await engine.fetchChanges()
        if mirror?.complete != true { mirror?.complete = true; mirrorChanged = true }
        try persist()
        let state = loadedMirror().state
        engineLog.debug("Fetched zone: \(state.items.count, privacy: .public) items, head round \(state.head?.round ?? 0, privacy: .public)")
        return state
    }

    func save(_ changes: [String: CloudItem], round: Int64) async throws -> CloudState {
        try CloudRecordLimits.validate(changes)
        let engine = try engineInstance()
        var current = loadedMirror()
        // Drop anything left from an interrupted save; it is rebuilt from fresh data each time.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        outgoing = [:]; conflicted = false; sendFailures = []
        for (key, item) in changes {
            let id = CKRecord.ID(recordName: key, zoneID: Self.zoneID)
            let record = Self.record(from: current.items[key]?.systemFields) ?? CKRecord(recordType: RecordType.item, recordID: id)
            record.encryptedValues[Field.payload] = item.payload
            record.encryptedValues[Field.revision] = item.revision
            record[Field.round] = round
            record[Field.writer] = CloudWriter.current
            outgoing[id] = record
        }
        let head = Self.record(from: current.headSystemFields) ?? CKRecord(recordType: RecordType.head, recordID: Self.headID)
        head[Field.round] = round
        head[Field.format] = Int64(CloudRecordCodec.format)
        outgoing[Self.headID] = head
        if !current.zoneReady { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]) }
        engine.state.add(pendingRecordZoneChanges: outgoing.keys.sorted { $0.recordName < $1.recordName }.map { .saveRecord($0) })
        engineLog.notice("Sending round \(round, privacy: .public): \(changes.count, privacy: .public) items")

        try await engine.sendChanges()
        try persist()
        current = loadedMirror()
        let unsent = outgoing.count
        outgoing = [:]
        if conflicted { engineLog.notice("Round \(round, privacy: .public) met newer cloud changes"); throw CloudRecordError.changedElsewhere }
        if let failure = Self.rootFailure(sendFailures) {
            let codes = Set(sendFailures.compactMap { ($0 as? CKError)?.code.rawValue }).sorted().map(String.init).joined(separator: ",")
            engineLog.error("Round \(round, privacy: .public) failed: \(self.sendFailures.count, privacy: .public) records, CKError codes [\(codes, privacy: .public)]")
            throw failure
        }
        // Retryable failures stay unsent; the next sync rebuilds them from fresh data.
        guard unsent == 0, current.head?.round == round else {
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
            throw TaskBackup.invalid(L("部分修改尚未上传，稍后会自动重试。", "Some changes have not uploaded yet. Sync will retry shortly."))
        }
        engineLog.notice("Round \(round, privacy: .public) finished")
        return current.state
    }

    /// An atomic zone save fails every record when one is rejected; the others only say "batch request failed".
    /// Report the record that caused it, so the message names the real reason.
    static func rootFailure(_ failures: [Error]) -> Error? {
        failures.first { ($0 as? CKError)?.code != .batchRequestFailed } ?? failures.first
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        var mirror = loadedMirror()
        switch event {
        case .stateUpdate(let update):
            mirror.engineState = try? JSONEncoder().encode(update.stateSerialization)
            mirrorChanged = true
        case .accountChange(let change):
            // `CloudSync` refuses to sync a different account; the cache of the old one must not survive either way.
            engineLog.notice("Account change event: \(String(describing: change.changeType), privacy: .public)")
            mirror.clearContents(); mirror.engineState = nil; mirrorChanged = true
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                engineLog.notice("Sync zone was deleted in iCloud")
                mirror.clearContents(); mirrorChanged = true
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications { apply(modification.record, to: &mirror) }
            for deletion in changes.deletions where deletion.recordID.zoneID == Self.zoneID {
                if deletion.recordID == Self.headID { mirror.head = nil; mirror.headSystemFields = nil }
                else { mirror.items[deletion.recordID.recordName] = nil }
                mirror.generation += 1; mirrorChanged = true
            }
        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == Self.zoneID }) { mirror.zoneReady = true; mirrorChanged = true }
            sendFailures += sent.failedZoneSaves.map(\.error)
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                apply(record, to: &mirror); outgoing[record.recordID] = nil
            }
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                outgoing[id] = nil
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord { apply(server, to: &mirror) }
                    conflicted = true
                case .zoneNotFound:
                    mirror.zoneReady = false; mirrorChanged = true; conflicted = true
                case .unknownItem:
                    // Deleted on the server since we fetched it: forget its change tag so a retry creates it again.
                    if id == Self.headID { mirror.headSystemFields = nil } else { mirror.items[id.recordName]?.systemFields = nil }
                    mirrorChanged = true; conflicted = true
                default:
                    sendFailures.append(failure.error)
                }
            }
        default:
            break
        }
        self.mirror = mirror
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // The head goes last. A reader treats rows from a round without its head as an unfinished upload.
        let ordered = pending.filter { $0 != .saveRecord(Self.headID) } + pending.filter { $0 == .saveRecord(Self.headID) }
        let records = outgoing
        var batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: ordered) { records[$0] }
        batch?.atomicByZone = true
        return batch
    }

    // MARK: Private

    private func engineInstance() throws -> CKSyncEngine {
        if let engine { return engine }
        let saved = loadedMirror().engineState.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        return engine
    }

    /// Loaded on first use, off the main actor. A missing or unreadable file starts a full fetch.
    private func loadedMirror() -> CloudMirror {
        if let mirror { return mirror }
        var loaded = CloudMirror()
        if let data = try? Data(contentsOf: file) {
            do { loaded = try JSONDecoder().decode(CloudMirror.self, from: data) }
            catch { engineLog.error("Discarded unreadable sync mirror; refetching: \(error.localizedDescription, privacy: .public)") }
        }
        mirror = loaded
        return loaded
    }

    private func persist() throws {
        guard mirrorChanged, let mirror else { return }
        try JSONEncoder().encode(mirror).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        mirrorChanged = false
    }

    private func apply(_ record: CKRecord, to mirror: inout CloudMirror) {
        guard record.recordID.zoneID == Self.zoneID else { return }
        let fields = Self.systemFields(of: record)
        if record.recordID == Self.headID {
            let head = CloudHead(round: record[Field.round] as? Int64 ?? 0, format: Int(record[Field.format] as? Int64 ?? 0))
            if mirror.head != head { mirror.head = head; mirror.generation += 1 }
            mirror.headSystemFields = fields
        } else if record.recordType == RecordType.item {
            let round = record[Field.round] as? Int64 ?? 0
            let old = mirror.items[record.recordID.recordName]
            // Keep the last finished version of a row an unfinished round overwrote, so that round can be completed.
            let finished = CloudState.finishedVersion(of: old.map { ($0.item, $0.round, $0.previous) }, newRound: round,
                                                      headRound: mirror.head?.round ?? 0, complete: mirror.complete == true)
            let entry = CloudMirror.Entry(item: CloudItem(payload: record.encryptedValues[Field.payload] as? Data,
                                                          revision: record.encryptedValues[Field.revision] as? Data),
                                          round: round, systemFields: fields, writer: record[Field.writer] as? String,
                                          modified: record.modificationDate, previous: finished)
            if old?.item != entry.item || old?.round != entry.round { mirror.generation += 1 }
            mirror.items[record.recordID.recordName] = entry
        }
        mirrorChanged = true
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private static func record(from systemFields: Data?) -> CKRecord? {
        guard let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

/// The single-asset snapshot used before per-record sync. Read once to migrate, then marked as superseded so a
/// later deletion of the zone can never bring its stale contents back as if they were the cloud copy.
enum LegacySnapshotRecord {
    static let recordID = CKRecord.ID(recordName: "tally-personal-v1")
    private static let supersededField = "supersededBy"

    static func fetch(from database: CKDatabase) async throws -> (snapshot: TaskBackup, record: CKRecord)? {
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        if record[supersededField] != nil { return nil }
        guard (record["formatVersion"] as? Int64) == 1, let url = (record["snapshot"] as? CKAsset)?.fileURL else {
            throw TaskBackup.invalid("Unsupported cloud snapshot")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CloudSync.maximumSnapshotBytes else {
            throw TaskBackup.invalid(L("云端数据超过当前同步上限（50 MB）。本地数据不受影响。", "Cloud data exceeds the current 50 MB sync limit. Local data is unaffected."))
        }
        let snapshot = try await Task.detached { try TaskBackup.decode(Data(contentsOf: url), allowLargeFile: true) }.value
        return (snapshot, record)
    }

    /// Keeps the old record (nothing is deleted) but stops it from being read again.
    static func markSuperseded(_ record: CKRecord, in database: CKDatabase) async throws {
        record[supersededField] = CloudKitRecordTransport.zoneID.zoneName
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: false)
        _ = try result.saveResults[recordID]?.get()
    }
}
