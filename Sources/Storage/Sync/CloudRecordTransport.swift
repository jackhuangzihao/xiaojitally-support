import Foundation

/// A complete committed snapshot. Unpublished immutable records never appear here.
struct CloudState: Sendable, Equatable {
    var items: [String: CloudItem] = [:]
    var head: CloudHead?
    var generation = 0
    var isEmpty: Bool { head == nil && items.isEmpty }
}

enum CloudRecordError: LocalizedError, Equatable {
    /// Another device saved first. Nothing is lost; the next sync merges its changes and retries.
    case changedElsewhere
    case migrationIncomplete
    case migrationReview
    case cloudRemoved
    /// Finished rounds that do not form a valid whole; usually another device's retry repairs it.
    case inconsistentCloud(String)
    case itemTooLarge(String)
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .migrationIncomplete:
            L("旧版云端上传尚未完成，已暂停迁移并保留本地数据。请先保留各设备备份并联系支持，不要清空数据。", "An old cloud upload is incomplete. Migration paused and local data is retained. Keep backups from each device and contact support; do not erase data.")
        case .migrationReview:
            L("新旧云端副本存在差异，已保留迁移恢复副本，未覆盖任何一方。请在下方导出两份副本并联系支持。", "The old and new cloud copies differ. Migration recovery copies are retained; neither was overwritten. Export both copies below and contact support.")
        case .cloudRemoved:
            L("已迁移的云端数据被移除，同步已暂停。本地数据已保留；请先备份并联系支持。", "Migrated cloud data was removed. Sync paused and local data is retained. Back up your data and contact support.")
        case .changedElsewhere:
            L("另一台设备刚刚更新了数据，稍后会重新合并。", "Another device just updated the data. Sync will merge again shortly.")
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
/// tested with the same coordinator and a fault-injecting store without an account or network.
protocol CloudRecordTransport: Sendable {
    /// Downloads what changed since the last fetch and returns the complete cloud state.
    func fetch() async throws -> CloudState
    /// Called only after the user confirms replacing a removed cloud copy with this device's data.
    func allowReupload() async throws
    /// Prepares immutable versions, then conditionally publishes their complete manifest.
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
