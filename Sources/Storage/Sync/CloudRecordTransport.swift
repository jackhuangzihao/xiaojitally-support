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
    case missingBlob
    /// Finished rounds that do not form a valid whole; usually another device's retry repairs it.
    case inconsistentCloud(String)
    case itemTooLarge(String)
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .migrationIncomplete:
            L("旧版云端上传尚未完成，已暂停迁移并保留本地数据。请先保留各设备备份并联系支持，不要清空数据。", "An old cloud upload is incomplete. Migration paused and local data is retained. Keep backups from each device and contact support; do not erase data.")
        case .migrationReview:
            L("新旧云端副本存在无法自动确认的差异，双方已保留。可先导出迁移副本核对；确认本机内容完整后，可在下方用本机副本完成升级。", "The cloud copies differ in ways that cannot be resolved automatically. Both are retained. Export the migration copies to review them; if this device has the complete data, use its copy below to finish the upgrade.")
        case .cloudRemoved:
            L("无法确认当前云端副本，已暂停自动恢复。本地数据已保留；请先备份并核对本机内容，再用下方“用本机数据重新上传”恢复。", "The current cloud copy could not be confirmed, so automatic recovery is paused. Local data is retained. Back up and review this device’s contents, then use Re-upload local data below.")
        case .missingBlob:
            L("云端版本已变化，稍后会重新读取。未合并不完整数据，本机内容已保留。", "The cloud version changed and will be fetched again shortly. No incomplete data was merged; local data is retained.")
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
    /// Optional bounded upkeep; callers schedule it only after the local sync transaction completes.
    func performMaintenance() async
    /// Called only after the user confirms replacing a removed cloud copy with this device's data.
    func allowReupload() async throws
    /// Only after explicit confirmation: replace a protected, unresolved migration with this device's contents.
    func recoverMigration(with snapshot: TaskBackup, prepared: @Sendable (TaskBackup) async throws -> Void) async throws -> CloudState
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
