import Foundation
import CloudKit
import OSLog

/// Immutable writes can be split safely because only the final head makes them visible.
enum CloudBlobUpload {
    typealias Results = [String: Result<Void, Error>]
    typealias Attempt = @Sendable ([String: Data]) async throws -> Results
    static let requestBudget = 1_536 * 1024

    static func estimatedBytes(name: String, data: Data) -> Int {
        // Allow for encoded bytes and record metadata; server limit errors remain authoritative.
        (data.count * 4 + 2) / 3 + name.utf8.count + 1_024
    }

    static func batches(_ blobs: [String: Data]) throws -> [[String: Data]] {
        var result: [[String: Data]] = [], batch: [String: Data] = [:], bytes = 0
        for name in blobs.keys.sorted() {
            guard let data = blobs[name] else { continue }
            guard data.count <= CloudCommitProtocol.maximumBlobBytes else { throw CloudRecordError.itemTooLarge(name) }
            let size = estimatedBytes(name: name, data: data)
            guard size <= requestBudget else { throw CloudRecordError.itemTooLarge(name) }
            if !batch.isEmpty, batch.count == CloudCommitProtocol.batchSize || bytes + size > requestBudget {
                result.append(batch); batch = [:]; bytes = 0
            }
            batch[name] = data; bytes += size
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }

    static func write(_ blobs: [String: Data], attempt: Attempt) async throws {
        var pending = blobs
        // Atomic batches may return batchRequestFailed for peers of an existing immutable record.
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard !pending.isEmpty else { return }
            let attemptedCount = pending.count
            let results: Results
            do { results = try await attempt(pending) }
            catch {
                guard let failure = rootFailure([error]), (failure as? CKError)?.code == .limitExceeded else { throw error }
                try await split(pending, attempt: attempt)
                return
            }
            var failures: [Error] = []
            for name in pending.keys.sorted() {
                guard let result = results[name] else { throw CloudRecordError.inconsistentCloud("Missing save result") }
                switch result {
                case .success: pending[name] = nil
                case .failure(let error): failures.append(error)
                }
            }
            guard let failure = rootFailure(failures) else { return }
            if (failure as? CKError)?.code == .limitExceeded {
                if pending.count == 1, attemptedCount > 1 {
                    // One failed peer has not yet been tested against the limit on its own.
                    try await write(pending, attempt: attempt)
                } else { try await split(pending, attempt: attempt) }
                return
            }
            guard (failure as? CKError)?.code == .batchRequestFailed else { throw failure }
        }
        throw CloudRecordError.changedElsewhere
    }

    static func rootFailure(_ errors: [Error]) -> Error? {
        let failures = errors.flatMap { leaves($0, depth: 0) }
        // A permission/account/network error must not be hidden by a limit error in the same result.
        return failures.first { ($0 as? CKError)?.code != .limitExceeded && ($0 as? CKError)?.code != .batchRequestFailed }
            ?? failures.first { ($0 as? CKError)?.code == .limitExceeded }
            ?? failures.first
    }

    private static func leaves(_ error: Error, depth: Int) -> [Error] {
        guard depth < 8, let cloud = error as? CKError, cloud.code == .partialFailure,
              let children = cloud.partialErrorsByItemID, !children.isEmpty else { return [error] }
        return children.values.flatMap { leaves($0, depth: depth + 1) }
    }

    private static func split(_ pending: [String: Data], attempt: Attempt) async throws {
        try Task.checkCancellation()
        guard pending.count > 1 else {
            throw CloudRecordError.itemTooLarge(pending.keys.first ?? "immutable record")
        }
        CloudMigration.log.notice("Splitting cloud batch after server size limit; records \(pending.count, privacy: .public)")
        let names = pending.keys.sorted(), middle = names.count / 2
        for names in [names[..<middle], names[middle...]] {
            let batch = Dictionary(uniqueKeysWithValues: names.compactMap { name in pending[name].map { (name, $0) } })
            try await write(batch, attempt: attempt)
        }
    }
}
