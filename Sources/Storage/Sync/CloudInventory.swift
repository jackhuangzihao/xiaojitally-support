import Foundation
import CloudKit

/// Fetches metadata only; cleanup must still fence every deletion against the head it inspected.
enum CloudInventory {
    static func immutableRecordNames(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> [String] {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.desiredKeys = []
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration])
        operation.fetchAllChanges = true
        operation.qualityOfService = .utility
        let state = State(zoneID: zoneID)
        operation.recordWasChangedBlock = { state.record($0, result: $1) }
        operation.recordWithIDWasDeletedBlock = { id, _ in state.deleted(id) }
        operation.recordZoneFetchResultBlock = { id, result in
            state.zone(id, result: result.map(\.moreComing))
        }
        operation.fetchRecordZoneChangesResultBlock = { state.complete($0) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                database.add(operation)
            }
        } onCancel: {
            state.cancel()
            operation.cancel()
        }
    }

    // CloudKit callbacks are serial, but task cancellation can arrive on another executor.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let zoneID: CKRecordZone.ID
        private var names = Set<String>()
        private var failure: Error?
        private var zoneComplete = false
        private var continuation: CheckedContinuation<[String], Error>?
        private var result: Result<[String], Error>?

        init(zoneID: CKRecordZone.ID) { self.zoneID = zoneID }

        func install(_ continuation: CheckedContinuation<[String], Error>) {
            let completed = lock.withLock { () -> Result<[String], Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }

        func record(_ id: CKRecord.ID, result: Result<CKRecord, Error>) {
            lock.withLock {
                guard self.result == nil else { return }
                do {
                    let record = try result.get()
                    guard id.zoneID == zoneID, record.recordID == id else {
                        throw CloudRecordError.inconsistentCloud("Unexpected inventory record")
                    }
                    let name = id.recordName
                    if record.recordType == "TallyImmutable", Self.isImmutableName(name) { names.insert(name) }
                } catch { failure = failure ?? error }
            }
        }

        func deleted(_ id: CKRecord.ID) {
            lock.withLock {
                guard result == nil else { return }
                guard id.zoneID == zoneID else {
                    failure = failure ?? CloudRecordError.inconsistentCloud("Unexpected inventory deletion")
                    return
                }
                names.remove(id.recordName)
            }
        }

        func zone(_ id: CKRecordZone.ID, result: Result<Bool, Error>) {
            lock.withLock {
                guard self.result == nil else { return }
                do {
                    guard id == zoneID else { throw CloudRecordError.inconsistentCloud("Unexpected inventory zone") }
                    zoneComplete = try !result.get()
                } catch { failure = failure ?? error }
            }
        }

        func complete(_ operationResult: Result<Void, Error>) {
            finish {
                if let failure { return .failure(failure) }
                if case .failure(let error) = operationResult { return .failure(error) }
                guard zoneComplete else { return .failure(CloudRecordError.inconsistentCloud("Incomplete cloud inventory")) }
                return .success(names.sorted())
            }
        }

        func cancel() { finish { .failure(CancellationError()) } }

        private func finish(_ makeResult: () -> Result<[String], Error>) {
            let completed = lock.withLock { () -> (CheckedContinuation<[String], Error>?, Result<[String], Error>)? in
                guard result == nil else { return nil }
                let value = makeResult()
                result = value
                let pending = continuation
                continuation = nil
                return (pending, value)
            }
            if let (pending, value) = completed { pending?.resume(with: value) }
        }

        private static func isImmutableName(_ name: String) -> Bool {
            name.utf8.count == 68 && name.hasPrefix("v14-") && name.utf8.dropFirst(4).allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
    }
}
