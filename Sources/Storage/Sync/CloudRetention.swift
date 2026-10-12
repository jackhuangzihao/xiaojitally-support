import Foundation
import OSLog

/// Each deletion batch changes the head atomically, invalidating every publisher using an older cursor.
enum CloudRetention {
    static let interval: Int64 = 20

    static func isDue(_ head: CloudCommitProtocol.Head, now: Date = Date()) -> Bool {
        guard head.migration == nil else { return false }
        if head.round - (head.collectedRound ?? 0) >= interval { return true }
        guard let date = head.collectedAt else { return true }
        // Time only schedules maintenance; all deletion safety comes from the atomic head comparison.
        return now.timeIntervalSince(date) >= 86_400 || date.timeIntervalSince(now) > 300
    }

    static func collect(store: any CloudCommitStore, cursor: CloudCommitProtocol.Cursor, maximumBatches: Int = 2) async throws -> CloudCommitProtocol.Cursor {
        try CloudCommitProtocol.validate(cursor.head)
        guard cursor.head.migration == nil, maximumBatches > 0 else { throw CloudRecordError.changedElsewhere }
        let roots = [cursor.head.pages] + (cursor.head.history ?? [])
        let pages = Set(roots.flatMap { $0 }).sorted()
        var data: [String: Data] = [:]
        for offset in stride(from: 0, to: pages.count, by: CloudCommitProtocol.batchSize) {
            try Task.checkCancellation()
            let batch = Array(pages.dropFirst(offset).prefix(CloudCommitProtocol.batchSize))
            let received = try await store.readBlobs(batch)
            for name in batch {
                guard let bytes = received[name] else { throw CloudRecordError.missingBlob }
                try CloudCommitProtocol.validate(bytes, named: name)
                data[name] = bytes
            }
        }
        var retained = Set(pages)
        for pages in roots {
            var root = cursor.head; root.pages = pages
            retained.formUnion(try CloudCommitProtocol.references(head: root, blobs: data).map(\.blob))
        }
        // Only complete, validated roots can authorize removal. Inventory never supplies the live set.
        let candidates = Set(try await store.immutableRecordNames())
            .filter { CloudCommitProtocol.validName($0) && !retained.contains($0) }.sorted()
        var expected = cursor
        let batchSize = CloudCommitProtocol.batchSize - 1 // One slot is reserved for the head CAS.
        var removed = 0
        for (batch, offset) in stride(from: 0, to: candidates.count, by: batchSize).enumerated() {
            guard batch < maximumBatches else { break }
            try Task.checkCancellation()
            let names = Array(candidates.dropFirst(offset).prefix(batchSize))
            expected = try await store.collect(names, replacing: expected, finishing: offset + names.count == candidates.count)
            removed += names.count
        }
        if candidates.isEmpty {
            try Task.checkCancellation()
            expected = try await store.collect([], replacing: expected, finishing: true)
        }
        CloudMigration.log.notice("Cloud collection pass; retired records: \(removed, privacy: .public), remaining candidates: \(candidates.count - removed, privacy: .public)")
        return expected
    }

    static func checkpoint(_ cursor: CloudCommitProtocol.Cursor, finishing: Bool) throws -> CloudCommitProtocol.Head {
        try CloudCommitProtocol.validate(cursor.head)
        guard cursor.head.migration == nil else { throw CloudRecordError.changedElsewhere }
        var head = cursor.head
        head.maintenance = UUID()
        if finishing { head.collectedRound = head.round; head.collectedAt = Date() }
        return head
    }
}
