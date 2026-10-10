import Foundation
import Security
#if os(macOS)
import IOKit
#endif

/// A hybrid logical clock reading: wall-clock milliseconds plus a counter for edits that share or precede them.
/// Every stamp a device issues is later than everything that device has seen, even if its clock runs slow.
struct SyncStamp: Codable, Comparable, Hashable, Sendable {
    var millis: Int64
    var counter: UInt16

    static let millisRange: ClosedRange<Int64> = -62135596800000...253402300799999
    /// Edits stamped further ahead than this cannot be ordered by time (the same allowance as Actual Budget).
    static let maximumDrift: Int64 = 5 * 60 * 1000

    init(millis: Int64, counter: UInt16) { self.millis = millis; self.counter = counter }
    init?(_ date: Date) {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, Double(Self.millisRange.lowerBound)...Double(Self.millisRange.upperBound) ~= value else { return nil }
        self.init(millis: Int64(value), counter: 0)
    }
    var isValid: Bool { Self.millisRange.contains(millis) }
    /// The next reading after this one, advancing the millisecond only when the counter is exhausted.
    var successor: SyncStamp {
        counter < .max ? SyncStamp(millis: millis, counter: counter + 1) : SyncStamp(millis: min(millis + 1, Self.millisRange.upperBound), counter: 0)
    }
    func isAhead(of now: Date) -> Bool {
        guard let current = SyncStamp(now) else { return true }
        return millis > current.millis + Self.maximumDrift
    }
    static func < (left: SyncStamp, right: SyncStamp) -> Bool {
        left.millis == right.millis ? left.counter < right.counter : left.millis < right.millis
    }

    // Compact JSON: [milliseconds, counter].
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        millis = try container.decode(Int64.self); counter = try container.decode(UInt16.self)
        guard container.isAtEnd else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Extra stamp values") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(millis); try container.encode(counter)
    }
}

/// A saved edit's causal history: the latest hybrid-clock stamp seen from each device, and the edit that produced the value.
/// One version contains another when it has seen it; otherwise the edits are concurrent and the later stamp wins.
struct SyncVersion: Codable, Equatable, Sendable {
    struct Dot: Codable, Equatable, Sendable {
        var actor: String
        var stamp: SyncStamp
    }
    var clock: [String: SyncStamp]
    var winner: Dot

    /// Versions written before hybrid clocks (counter vectors) are not trusted; their fields fall back to dated history.
    struct LegacyCounterFormat: Error {}

    static let deviceID: UUID = DeviceIdentity.current

    var isValid: Bool {
        !clock.isEmpty && clock.count <= 2048 && clock.allSatisfy { actor, stamp in
            UUID(uuidString: actor)?.uuidString == actor && stamp.isValid
        } && winner.stamp.isValid && clock[winner.actor].map { winner.stamp <= $0 } == true
    }
    func contains(_ other: SyncVersion) -> Bool {
        other.clock.allSatisfy { actor, stamp in clock[actor].map { $0 >= stamp } ?? false }
    }
    func dominates(_ other: SyncVersion) -> Bool { contains(other) && clock != other.clock }
    func joined(with other: SyncVersion) -> SyncVersion {
        var result = self
        for (actor, stamp) in other.clock { result.clock[actor] = max(result.clock[actor] ?? stamp, stamp) }
        return result
    }
    /// Orders concurrent edits: the later stamp wins, and the device identity only breaks exact ties.
    static func precedes(_ left: Dot, _ right: Dot) -> Bool {
        left.stamp == right.stamp ? left.actor < right.actor : left.stamp < right.stamp
    }
    /// A new edit after `previous`. With `now`, the stamp follows the wall clock but never falls behind what was seen.
    /// Without it (a confirmation), the stamp is derived only from the history, so devices confirming the same
    /// conflict produce identical stamps and a disagreement between them is still detected.
    static func next(after previous: SyncVersion?, actor: UUID, now: Date? = nil) -> SyncVersion {
        var clock = previous?.clock ?? [:]
        let seen = clock.values.max()
        let physical = now.flatMap(SyncStamp.init)
        let stamp: SyncStamp
        if let seen {
            stamp = physical.map { $0.millis > seen.millis ? $0 : seen.successor } ?? seen.successor
        } else {
            stamp = physical ?? SyncStamp(millis: 0, counter: 1)
        }
        clock[actor.uuidString] = stamp
        return SyncVersion(clock: clock, winner: Dot(actor: actor.uuidString, stamp: stamp))
    }
    static func observed(key: String, fingerprint: String?) -> SyncVersion {
        let identity = TaskItem.syncIdentity("sync-observed-legacy:" + key + ":" + (fingerprint ?? "deleted")).uuidString
        let stamp = SyncStamp(millis: 0, counter: 1)
        return SyncVersion(clock: [identity: stamp], winner: Dot(actor: identity, stamp: stamp))
    }
    static func legacy(key: String, fingerprint: String?, date: Date?) -> SyncVersion? {
        guard let date, let stamp = SyncStamp(date) else { return nil }
        // The timestamp identifies the old edit and orders it among concurrent edits like any other stamp.
        let identity = TaskItem.syncIdentity("sync-legacy:" + key + ":" + (fingerprint ?? "deleted") + ":" + String(stamp.millis)).uuidString
        return SyncVersion(clock: [identity: stamp], winner: Dot(actor: identity, stamp: stamp))
    }

    init(clock: [String: SyncStamp], winner: Dot) { self.clock = clock; self.winner = winner }
    private enum CodingKeys: String, CodingKey { case clock, winner }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let counters = try? container.decode([String: UInt64].self, forKey: .clock), !counters.isEmpty { throw LegacyCounterFormat() }
        clock = try container.decode([String: SyncStamp].self, forKey: .clock)
        winner = try container.decode(Dot.self, forKey: .winner)
    }
}

extension KeyedDecodingContainer {
    /// Drops a pre-hybrid counter version instead of failing the whole history; anything else malformed still throws.
    func decodeSyncVersion(forKey key: Key) throws -> SyncVersion? {
        do { return try decodeIfPresent(SyncVersion.self, forKey: key) } catch is SyncVersion.LegacyCounterFormat { return nil }
    }
}

/// A device's identity must not travel with backups or migrations: two devices sharing one would each look
/// as if it had already seen the other's edits.
private enum DeviceIdentity {
    static let current: UUID = {
        let key = "sync.causalActor.v1"
        let stored: UUID
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { stored = id }
        else { stored = UUID(); UserDefaults.standard.set(stored.uuidString, forKey: key) }
        guard let hardware = hardwareIdentifier() else { return stored }
        return TaskItem.syncIdentity("sync-device:" + stored.uuidString + ":" + hardware)
    }()

    #if os(macOS)
    /// Migration Assistant and Time Machine copy preferences to a new Mac, but not its platform UUID.
    private static func hardwareIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
    #else
    /// A this-device-only keychain item is never restored onto a different iPhone or iPad.
    private static func hardwareIdentifier() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "local.jianshi.sync-device",
                                    kSecAttrAccount as String: "identity"]
        var result: CFTypeRef?
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let value = String(data: data, encoding: .utf8) { return value }
        let value = UUID().uuidString
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? value : nil
    }
    #endif
}
