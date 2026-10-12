import Foundation

@MainActor enum CloudReuploadChecks {
    static func run(sample: TaskBackup) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw TaskBackup.invalid("CLOUD REUPLOAD CHECK: " + label) }; count += 1
        }
        func rejects(_ label: String, _ operation: () async throws -> Void) async throws {
            do { try await operation() } catch { count += 1; return }
            throw TaskBackup.invalid("CLOUD REUPLOAD CHECK: " + label)
        }
        // Exercise the same authorization policy as the CloudKit adapter, including retained old snapshots.
        let digests: [String?] = [nil, "retained-legacy-digest"]
        for digest in digests {
            let authorized = try CloudMigration.reuploadHead(existing: nil, legacyDigest: digest)
            for _ in 0..<3 {
                try check(try CloudMigration.reuploadHead(existing: authorized, legacyDigest: digest) == authorized,
                          "repeated authorization preserves the whole checkpoint")
            }
            try await rejects("a changed legacy source cannot resume an old authorization") {
                _ = try CloudMigration.reuploadHead(existing: authorized, legacyDigest: "another-digest")
            }
            var unapproved = authorized; unapproved.migration?.reupload = nil
            if digest == nil {
                try check(try CloudMigration.reuploadHead(existing: unapproved, legacyDigest: nil).migration?.reupload == true,
                          "a genuinely empty head can be authorized")
                try await rejects("an empty head cannot replace a newly appeared legacy snapshot") {
                    _ = try CloudMigration.reuploadHead(existing: unapproved, legacyDigest: "new-legacy-digest")
                }
            } else {
                try await rejects("an unfinished old migration is not permission to discard its seed") {
                    _ = try CloudMigration.reuploadHead(existing: unapproved, legacyDigest: digest)
                }
            }
            var invalidHeads = [CloudCommitProtocol.Head]()
            var invalid = authorized; invalid.pages = ["unexpected-page"]; invalidHeads.append(invalid)
            invalid = authorized; invalid.migration = nil; invalidHeads.append(invalid)
            invalid = authorized; invalid.migration = .init(previousRound: 0, hadHead: true, legacyDigest: digest); invalidHeads.append(invalid)
            invalid = authorized; invalid.migration = .init(previousRound: 1, hadHead: false, legacyDigest: digest, reupload: true); invalidHeads.append(invalid)
            invalid = authorized; invalid.round = 1; invalid.migration = nil; invalidHeads.append(invalid)
            invalid = authorized; invalid.legacyDigest = "mismatched-inner-digest"; invalidHeads.append(invalid)
            for head in invalidHeads {
                try await rejects("a malformed or published head cannot be re-uploaded over") {
                    _ = try CloudMigration.reuploadHead(existing: head, legacyDigest: digest)
                }
            }
        }

        let items = try CloudRecordCodec.items(sample)
        for repetition in 0..<3 {
            for digest in digests {
                for recreate in [false, true] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reupload-check-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let cache = directory.appendingPathComponent("cache.json")
                    let store = FaultingCommitStore(), original = CloudCommitTransport(store: store, cacheURL: cache)
                    _ = try await original.fetch(); _ = try await original.save(items, round: 1)
                    await store.resetCloud(legacyDigest: digest)
                    await store.configure(.afterReupload)
                    try await rejects("server checkpoint success with a lost response is retryable") { try await original.allowReupload() }
                    let checkpoint = await store.readHead().head
                    try check(checkpoint.migration?.reupload == true && checkpoint.legacyDigest == digest, "failed response retains authorization")
                    let resumed = recreate ? CloudCommitTransport(store: store, cacheURL: cache) : original
                    for _ in 0..<3 {
                        try await resumed.allowReupload()
                        try check(await store.readHead().head == checkpoint, "retry resumes the same checkpoint \(repetition)")
                    }
                    // The app can stop after cloud confirmation but before saving its cleared local baseline.
                    let restarted = CloudCommitTransport(store: store, cacheURL: cache)
                    try await restarted.allowReupload()
                    try check(try await restarted.fetch().isEmpty, "authorized recovery starts from an empty seed")
                    _ = try await restarted.save(items, round: 1)
                    let complete = try await CloudCommitTransport(store: store).fetch()
                    try check(complete.items == items, "re-upload restores every original record despite a stale cache")
                    let published = await store.readHead()
                    try await rejects("another device's complete upload cannot be replaced") { try await resumed.allowReupload() }
                    let retained = try await restarted.fetch()
                    try check(await store.readHead() == published && retained.items == items,
                              "rejected recovery preserves both the committed head and all data")
                }
            }
        }
        print("CLOUD REUPLOAD PASS: \(count) checks; retained snapshots, lost responses, restart, stale cache and existing-cloud protection")
        return count
    }
}
