import Foundation
import CloudKit

/// Used only during the one-time migration; never writes old mutable rows.
actor CloudLegacyReader: CKSyncEngineDelegate {
    private let database: CKDatabase
    private var rows: [String: (CloudItem, Int64)] = [:]
    init(database: CKDatabase) { self.database = database }
    func read() async throws -> [String: (CloudItem, Int64)] {
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: nil, delegate: self)
        config.automaticallySync = false
        let engine = CKSyncEngine(config)
        try await engine.fetchChanges()
        return rows
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard case .fetchedRecordZoneChanges(let changes) = event else { return }
        for change in changes.modifications {
            let r = change.record
            guard r.recordID.zoneID == CloudKitRecordTransport.zoneID, r.recordType == "TallyItem" else { continue }
            rows[r.recordID.recordName] = (CloudItem(payload: r.encryptedValues["payload"] as? Data,
                revision: r.encryptedValues["revision"] as? Data), r["round"] as? Int64 ?? -1)
        }
        for deletion in changes.deletions where deletion.recordID.zoneID == CloudKitRecordTransport.zoneID {
            rows[deletion.recordID.recordName] = nil
        }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
}
