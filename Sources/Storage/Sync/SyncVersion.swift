import Foundation

/// A saved edit's causal history. Device clocks are display information, never causal ordering.
struct SyncVersion: Codable, Equatable, Sendable {
    struct Dot: Codable, Equatable, Sendable {
        var actor: String
        var counter: UInt64
    }
    var clock: [String: UInt64]
    var winner: Dot
    private static let maximumCounter: UInt64 = 9_007_199_254_740_991

    static let deviceID: UUID = {
        let key = "sync.causalActor.v1"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString, forKey: key); return id
    }()

    var isValid: Bool {
        !clock.isEmpty && clock.count <= 2048 && clock.allSatisfy { actor, counter in
            UUID(uuidString: actor)?.uuidString == actor && counter > 0 && counter <= Self.maximumCounter
        } && winner.counter > 0 && winner.counter <= (clock[winner.actor] ?? 0)
    }
    func contains(_ other: SyncVersion) -> Bool {
        other.clock.allSatisfy { (clock[$0.key] ?? 0) >= $0.value }
    }
    func dominates(_ other: SyncVersion) -> Bool { contains(other) && clock != other.clock }
    func joined(with other: SyncVersion) -> SyncVersion {
        var result = self
        for (actor, counter) in other.clock { result.clock[actor] = max(result.clock[actor] ?? 0, counter) }
        return result
    }
    static func precedes(_ left: Dot, _ right: Dot) -> Bool {
        left.counter == right.counter ? left.actor < right.actor : left.counter < right.counter
    }
    static func next(after previous: SyncVersion?, actor: UUID) -> SyncVersion {
        var clock = previous?.clock ?? [:]
        // Counter exhaustion rotates the local event identity instead of wrapping a causal version.
        var identity = actor.uuidString
        if clock[identity] == maximumCounter { identity = UUID().uuidString }
        let observedMaximum = clock.values.max() ?? 0
        let counter = observedMaximum < maximumCounter ? observedMaximum + 1 : (clock[identity] ?? 0) + 1
        clock[identity] = counter
        return SyncVersion(clock: clock, winner: Dot(actor: identity, counter: counter))
    }
    static func observed(key: String, fingerprint: String?) -> SyncVersion {
        let identity = TaskItem.syncIdentity("sync-observed-legacy:" + key + ":" + (fingerprint ?? "deleted")).uuidString
        return SyncVersion(clock: [identity: 1], winner: Dot(actor: identity, counter: 1))
    }
    static func legacy(key: String, fingerprint: String?, date: Date?) -> SyncVersion? {
        guard let date else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard milliseconds.isFinite, (-62135596800000...253402300799000).contains(milliseconds) else { return nil }
        // The timestamp identifies the old edit; its numerical order never chooses the winner.
        let identity = TaskItem.syncIdentity("sync-legacy:" + key + ":" + (fingerprint ?? "deleted") + ":" + String(Int64(milliseconds))).uuidString
        return SyncVersion(clock: [identity: 1], winner: Dot(actor: identity, counter: 1))
    }
}
