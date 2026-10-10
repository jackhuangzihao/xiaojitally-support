import Foundation

/// The cloud as this device last saw it: every item with the round that wrote it, and the finished-round marker.
struct CloudState: Sendable, Equatable {
    var items: [String: CloudItem] = [:]
    var rounds: [String: Int64] = [:]
    var head: CloudHead?
    /// Changes whenever items or the head change, so callers can cache work derived from this state.
    var generation = 0
    /// Which device wrote each row (`CloudWriter.current` of that device), and when.
    var writers: [String: String] = [:]
    var writtenAt: [String: Date] = [:]
    /// For rows an unfinished round overwrote: the version from the last finished round. An empty item means the
    /// row did not exist then. Missing when this device never saw that version (e.g. a fresh install).
    var previous: [String: CloudItem] = [:]

    /// After this long without a write, an unfinished round is treated as abandoned and another device completes it.
    static let abandonedAfter: TimeInterval = 10 * 60

    var isEmpty: Bool { head == nil && items.isEmpty }
    /// Items from a round that has not written its head yet: a device is uploading, or was interrupted.
    var hasUnfinishedRound: Bool { !unfinishedKeys.isEmpty }
    var unfinishedKeys: [String] {
        let finished = head?.round ?? 0
        return rounds.filter { $0.value > finished }.map(\.key)
    }

    /// Whether `writer` may complete the unfinished round: always its own, or another device's once abandoned.
    /// Otherwise merging now could mistake rows still to come for missing ones.
    func canResume(as writer: String, now: Date) -> Bool {
        let keys = unfinishedKeys
        guard !keys.isEmpty else { return true }
        if keys.allSatisfy({ writers[$0] == writer }) { return true }
        guard let latest = keys.compactMap({ writtenAt[$0] }).max() else { return false }
        return now.timeIntervalSince(latest) > Self.abandonedAfter
    }

    /// The cloud as of the last finished round, or nil if a version it overwrote was never seen here.
    var finishedItems: [String: CloudItem]? {
        var result = items
        for key in unfinishedKeys {
            guard let version = previous[key] else { return nil }
            result[key] = version
        }
        return result
    }

    /// The last finished version of a row about to hold `round`, carried over from what this device knew of it.
    /// `complete` says this device has fetched the whole zone, so a row it never saw did not exist.
    static func finishedVersion(of old: (item: CloudItem, round: Int64, previous: CloudItem?)?, newRound: Int64,
                                headRound: Int64, complete: Bool) -> CloudItem? {
        guard newRound > headRound else { return nil }
        guard let old else { return complete ? CloudItem() : nil }
        return old.round <= headRound ? old.item : old.previous
    }
}

/// This device's identity on cloud rows: a digest of its sync identity, so the raw identifier is never uploaded.
enum CloudWriter {
    static let current = String(CloudMerge.digest(Data(SyncVersion.deviceID.uuidString.utf8)).prefix(32))
}

enum CloudRecordError: LocalizedError, Equatable {
    /// Another device saved first. Nothing is lost; the next sync merges its changes and retries.
    case changedElsewhere
    /// Another device is in the middle of an upload. Merging now could mistake missing rows for deletions.
    case unfinishedRound
    /// Finished rounds that do not form a valid whole; usually another device's retry repairs it.
    case inconsistentCloud(String)
    case itemTooLarge(String)
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            L("另一台设备刚刚更新了数据，稍后会重新合并。", "Another device just updated the data. Sync will merge again shortly.")
        case .unfinishedRound:
            L("另一台设备正在上传，稍后会自动同步。若它 10 分钟内没有完成，会由本机接着完成。本地修改已保留。",
              "Another device is uploading. Sync will continue shortly; if it does not finish within 10 minutes, this device completes it. Local changes are retained.")
        case .inconsistentCloud(let reason):
            L("云端数据暂不完整，未合并任何内容，稍后会重试。如果一直出现，请先导出本地备份。", "Cloud data is incomplete. Nothing was merged; sync will retry. If this persists, export a local backup first.") + "\n" + reason
        case .itemTooLarge(let key):
            L("有一条记录超过 iCloud 单条上限，未上传。", "A record exceeds the iCloud size limit and was not uploaded.") + " " + key
        case .unsupportedFormat(let format):
            L("云端数据来自更新版本的小记（格式 \(format)），请更新后再同步。", "The cloud data comes from a newer version of Tally (format \(format)). Update before syncing.")
        }
    }
}

/// Moves cloud items between this device and iCloud. The merge logic only sees `CloudState`, so it can be
/// tested with `InMemoryRecordTransport` without an account or network.
protocol CloudRecordTransport: Sendable {
    /// Downloads what changed since the last fetch and returns the complete cloud state.
    func fetch() async throws -> CloudState
    /// Writes `changes` stamped with `round`, then the head for that round, and returns the new state.
    /// Throws `CloudRecordError.changedElsewhere` if another device saved any of these records, or the head, first.
    func save(_ changes: [String: CloudItem], round: Int64) async throws -> CloudState
}

enum CloudRecordLimits {
    /// CloudKit rejects records over 1 MB; leave room for the revision and system fields.
    static let maximumItemBytes = 900 * 1024

    static func validate(_ changes: [String: CloudItem]) throws {
        for (key, item) in changes where (item.payload?.count ?? 0) + (item.revision?.count ?? 0) > maximumItemBytes {
            throw CloudRecordError.itemTooLarge(key)
        }
    }
}

// MARK: - In-memory cloud for self-checks

/// A shared stand-in for the CloudKit zone. Change tags reject stale writes the way `.ifServerRecordUnchanged` does.
actor InMemoryCloud {
    struct Stored: Sendable { var item: CloudItem; var round: Int64; var tag: Int; var writer: String; var writtenAt: Date }
    private(set) var items: [String: Stored] = [:]
    private(set) var head: (value: CloudHead, tag: Int)?
    private var nextTag = 1
    /// Simulates an interrupted upload: after this many item writes the next save stops before its head.
    var interruptAfter: Int?

    func setInterrupt(after count: Int?) { interruptAfter = count }
    func snapshot() -> (items: [String: Stored], head: (value: CloudHead, tag: Int)?) { (items, head) }

    func write(_ changes: [String: CloudItem], round: Int64, knownTags: [String: Int], knownHeadTag: Int?,
               writer: String, at date: Date) throws {
        // Check every tag before writing anything, like an atomic zone batch.
        for key in changes.keys where items[key]?.tag != knownTags[key] { throw CloudRecordError.changedElsewhere }
        guard head?.tag == knownHeadTag else { throw CloudRecordError.changedElsewhere }
        for (index, key) in changes.keys.sorted().enumerated() {
            if let limit = interruptAfter, index >= limit { interruptAfter = nil; throw URLError(.networkConnectionLost) }
            items[key] = Stored(item: changes[key]!, round: round, tag: nextTag, writer: writer, writtenAt: date); nextTag += 1
        }
        head = (CloudHead(round: round, format: CloudRecordCodec.format), nextTag); nextTag += 1
    }
}

/// One device's view of `InMemoryCloud`, with its own mirror of what it fetched.
actor InMemoryRecordTransport: CloudRecordTransport {
    private let cloud: InMemoryCloud
    nonisolated let writer: String
    private var state = CloudState()
    private var fetched = false
    private var tags: [String: Int] = [:]
    private var headTag: Int?
    /// Write time for the next save; tests move it to simulate an abandoned upload.
    private var clock = Date()

    init(cloud: InMemoryCloud, writer: String = UUID().uuidString) { self.cloud = cloud; self.writer = writer }

    func setClock(_ date: Date) { clock = date }

    func fetch() async throws -> CloudState {
        let remote = await cloud.snapshot()
        let items = remote.items.mapValues(\.item), rounds = remote.items.mapValues(\.round)
        if items != state.items || rounds != state.rounds || remote.head?.value != state.head {
            let headRound = remote.head?.value.round ?? 0
            var previous: [String: CloudItem] = [:]
            for (key, round) in rounds {
                let old = state.items[key].map { (item: $0, round: state.rounds[key] ?? 0, previous: state.previous[key]) }
                previous[key] = CloudState.finishedVersion(of: old, newRound: round, headRound: headRound, complete: fetched)
            }
            state = CloudState(items: items, rounds: rounds, head: remote.head?.value, generation: state.generation + 1,
                               writers: remote.items.mapValues(\.writer), writtenAt: remote.items.mapValues(\.writtenAt),
                               previous: previous)
        }
        fetched = true
        tags = remote.items.mapValues(\.tag); headTag = remote.head?.tag
        return state
    }

    func save(_ changes: [String: CloudItem], round: Int64) async throws -> CloudState {
        try CloudRecordLimits.validate(changes)
        try await cloud.write(changes, round: round, knownTags: tags, knownHeadTag: headTag, writer: writer, at: clock)
        return try await fetch()
    }
}
