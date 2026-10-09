import SwiftUI
import SwiftData
import OSLog

/// Portable JSON files, retained by time rather than by number of edits.
enum BackupFiles {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.jianshi.personal", category: "Backup")
    static func ownedFiles(directory: URL, owner: String) throws -> [(url: URL, date: Date)] {
        let prefix = "Jianshi-Auto-\(owner)-"
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix(prefix),
                  let milliseconds = Double(url.lastPathComponent.dropFirst(prefix.count).prefix(20)), milliseconds.isFinite else { return nil }
            return (url, Date(timeIntervalSince1970: milliseconds / 1000))
        }.sorted { $0.date > $1.date }
    }

    static func retained(_ files: [(url: URL, date: Date)], now: Date, newest: URL, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -13, to: today)!
        var result: Set<String> = [newest.lastPathComponent]
        var hours = Set<Date>(), days = Set<Date>()
        var todayCount = 0
        // The newly verified file wins ties, including clocks adjusted backwards within an hour.
        let ordered = files.filter { $0.url.lastPathComponent == newest.lastPathComponent }
            + files.filter { $0.url.lastPathComponent != newest.lastPathComponent }.sorted { $0.date > $1.date }
        for file in ordered {
            let day = calendar.startOfDay(for: file.date)
            guard day >= cutoff else { continue }
            if day >= today {
                let hour = calendar.dateInterval(of: .hour, for: file.date)!.start
                if todayCount < 10 && hours.insert(hour).inserted {
                    result.insert(file.url.lastPathComponent); todayCount += 1
                }
            } else if days.insert(day).inserted { result.insert(file.url.lastPathComponent) }
        }
        return result
    }

    static func write(_ data: Data, directory: URL, owner: String, now: Date = Date()) throws -> URL {
        _ = try TaskBackup.decode(data, allowLargeFile: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(format: "%020.0f", now.timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("Jianshi-Auto-\(owner)-" + stamp + "-" + UUID().uuidString + ".json")
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileReadCorruptFile) }
        try prune(directory: directory, owner: owner, newest: url, now: now)
        return url
    }

    private static func prune(directory: URL, owner: String, newest: URL, now: Date) throws {
        let files = try ownedFiles(directory: directory, owner: owner)
        let keep = retained(files, now: now, newest: newest)
        for file in files where !keep.contains(file.url.lastPathComponent) { try FileManager.default.removeItem(at: file.url) }
    }

    static func contentData(_ value: TaskBackup) throws -> Data {
        var copy = value
        copy.createdAt = Date(timeIntervalSince1970: 0)
        copy.lists.sort { $0.id.uuidString < $1.id.uuidString }
        copy.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        copy.weekTitles?.sort { $0.week < $1.week }
        return try copy.encoded()
    }

    /// Runs on the backup queue: fetch no live SwiftData objects here.
    static func save(_ backup: TaskBackup, directory: URL, owner: String, force: Bool = false) throws -> Date {
        let content = try contentData(backup)
        if !force, let last = try ownedFiles(directory: directory, owner: owner).first,
           let previous = try? TaskBackup.decode(Data(contentsOf: last.url), allowLargeFile: true),
           try contentData(previous) == content {
            // Apply the time policy to older releases' count-based files without creating a duplicate.
            try prune(directory: directory, owner: owner, newest: last.url, now: Date())
            return last.date
        }
        var current = backup; current.createdAt = Date()
        _ = try write(current.encoded(), directory: directory, owner: owner, now: current.createdAt)
        return current.createdAt
    }

    static func localDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("JianshiBackups/Automatic", isDirectory: true)
    }

    enum SyncRecoveryKind: String {
        case manualConflict, automaticMerge
        var directoryName: String { self == .manualConflict ? "Conflicts" : "AutomaticMerges" }
        var prefix: String { self == .manualConflict ? "Jianshi-Conflict-" : "Jianshi-AutomaticMerge-" }
        var retainedPairs: Int { self == .manualConflict ? 5 : 2 }
        static func required(manualReview: Bool, automaticCount: Int) -> [Self] {
            (manualReview ? [.manualConflict] : []) + (automaticCount > 0 ? [.automaticMerge] : [])
        }
    }

    private static func recoveryDirectories(in directory: URL, kind: SyncRecoveryKind) throws -> [(url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = kind.prefix
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, url.lastPathComponent.hasPrefix(prefix),
                  let milliseconds = Double(url.lastPathComponent.dropFirst(prefix.count).prefix(20)), milliseconds.isFinite else { return nil }
            return (url, Date(timeIntervalSince1970: milliseconds / 1000))
        }.sorted { $0.date > $1.date }
    }

    /// Automatic resolutions must never evict originals that needed manual review.
    static func protectSyncCopies(local: Data, cloud: Data, directory: URL,
                                  kind: SyncRecoveryKind = .manualConflict, now: Date = Date()) throws {
        _ = try TaskBackup.decode(local, allowLargeFile: true)
        _ = try TaskBackup.decode(cloud, allowLargeFile: true)
        let fm = FileManager.default, conflicts = directory.appendingPathComponent(kind.directoryName, isDirectory: true)
        let existing = try recoveryDirectories(in: conflicts, kind: kind)
        if let latest = existing.first,
           (try? Data(contentsOf: latest.url.appendingPathComponent("local.json"))) == local,
           (try? Data(contentsOf: latest.url.appendingPathComponent("cloud.json"))) == cloud { return }
        try fm.createDirectory(at: conflicts, withIntermediateDirectories: true)
        let staging = conflicts.appendingPathComponent(".partial-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (name, data) in [("local.json", local), ("cloud.json", cloud)] {
            let file = staging.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            guard try Data(contentsOf: file) == data else { throw CocoaError(.fileReadCorruptFile) }
        }
        // The pair becomes visible only after both originals are verified; backward clocks retain its order.
        let milliseconds = max((now.timeIntervalSince1970 * 1000).rounded(),
                               existing.first.map { ($0.date.timeIntervalSince1970 * 1000).rounded() + 1 } ?? 0)
        let stamp = String(format: "%020.0f", milliseconds)
        let completed = conflicts.appendingPathComponent(kind.prefix + stamp + "-" + UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: staging, to: completed)
        for old in existing.dropFirst(kind.retainedPairs - 1) { try fm.removeItem(at: old.url) }
        log.notice("Protected sync originals (\(kind.rawValue, privacy: .public)); retained pairs: \(min(existing.count + 1, kind.retainedPairs), privacy: .public)")
    }

    static func syncRecoveryCopy(directory: URL, local: Bool, kind: SyncRecoveryKind = .manualConflict) throws -> Data? {
        let conflicts = directory.appendingPathComponent(kind.directoryName, isDirectory: true)
        guard let latest = try recoveryDirectories(in: conflicts, kind: kind).first else { return nil }
        let data = try Data(contentsOf: latest.url.appendingPathComponent(local ? "local.json" : "cloud.json"))
        _ = try TaskBackup.decode(data, allowLargeFile: true)
        return data
    }
}

@MainActor final class AutomaticBackup: ObservableObject {
    static let shared = AutomaticBackup()
    @Published private(set) var lastSaved = UserDefaults.standard.object(forKey: "autoBackupLastSaved") as? Date
    @Published private var failureDetail = UserDefaults.standard.string(forKey: "autoBackupFailure") ?? ""
    var status: String { UISettings.backupFailure(failureDetail) }
    @Published private(set) var pendingWrites = 0
    private let queue = DispatchQueue(label: "Jianshi.automaticBackup", qos: .utility)
    private let owner: String
    private var debounce: Task<Void, Never>?
    private var pendingContext: ModelContext?
    private var forcePending = false
    private var writing = false
    private var quitting = false

    private init() {
        owner = UserDefaults.standard.string(forKey: "autoBackupOwner") ?? UUID().uuidString
        UserDefaults.standard.set(owner, forKey: "autoBackupOwner")
    }

    func save(_ context: ModelContext, force: Bool = false) {
        if pendingContext == nil { pendingWrites += 1 }
        pendingContext = context; forcePending = forcePending || force
        debounce?.cancel()
        if force { capturePending(); return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.capturePending()
        }
    }

    private func capturePending() {
        guard !writing, let context = pendingContext else { return }
        debounce?.cancel(); debounce = nil
        pendingContext = nil
        let force = forcePending; forcePending = false
        do {
            // Only copy model values on the main actor. Sorting, validation, comparison,
            // JSON encoding, reading and writing all run on the serial utility queue.
            try Store.recovery.requireWritable(context)
            let snapshot = try TaskBackup.capture(context, includeFinance: false)
            let financePayload = try FinanceStore.payload(context)
            let owner = owner
            writing = true
            queue.async { [weak self] in
                let result = Result {
                    var complete = snapshot
                    complete.finance = try financePayload.map { try JSONDecoder().decode(FinanceData.self, from: $0) }
                    return try BackupFiles.save(complete, directory: BackupFiles.localDirectory(), owner: owner, force: force)
                }
                Task { @MainActor [weak self] in self?.finished(result) }
            }
        } catch { finished(.failure(error)) }
    }

    private func finished(_ result: Result<Date, Error>) {
        writing = false; pendingWrites -= 1
        switch result {
        case .success(let date):
            lastSaved = date; failureDetail = ""
            UserDefaults.standard.set(date, forKey: "autoBackupLastSaved")
        case .failure(let error): failureDetail = error.localizedDescription
        }
        UserDefaults.standard.set(failureDetail, forKey: "autoBackupFailure")
        // At most one pending snapshot behind the write in flight; never queue every edit.
        if pendingContext != nil { capturePending(); return }
        #if os(macOS)
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
        #endif
    }

    #if os(macOS)
    func finishBeforeQuit() {
        quitting = true
        debounce?.cancel(); debounce = nil
        capturePending()
    }
    func showFiles() {
        do {
            let url = try BackupFiles.localDirectory()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { failureDetail = error.localizedDescription }
    }
    #endif
}
