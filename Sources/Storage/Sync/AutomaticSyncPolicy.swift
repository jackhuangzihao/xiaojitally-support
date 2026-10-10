import Foundation

/// An edit that saw the other side wins. Concurrent ordinary edits keep the later hybrid-clock stamp; a stamp
/// more than five minutes ahead of this device cannot be ordered and needs review. Recovery copies are kept either way.
struct AutomaticSyncPolicy {
    let revisions: SyncChanges.Resolution
    let now: Date

    func choice(record: String, field: String) -> CloudMerge.Choice? {
        let ordinary: Set<String>
        switch record.prefix(while: { $0 != ":" }) {
        case "task": ordinary = ["title", "notes", "priority", "listID", "timing", "completion"]
        case "list": ordinary = ["name", "colorHex", "emoji", "sortOrder"]
        case "week": ordinary = ["title"]
        case "entry": ordinary = ["title", "notes", "tags"]
        default: ordinary = []
        }
        guard ordinary.contains(field), revisions.baseValues[record] != nil,
              let leftSide = revisions.side(.local, key: record, field: field),
              let rightSide = revisions.side(.cloud, key: record, field: field) else { return nil }
        if leftSide.genuineVersion || rightSide.genuineVersion {
            guard let left = leftSide.version, let right = rightSide.version else { return nil }
            if left.dominates(right) { return .local }
            if right.dominates(left) { return .cloud }
            // Equal histories with different contents are inconsistent, not an ordinary concurrent edit.
            guard left.clock != right.clock, left.winner != right.winner,
                  !left.winner.stamp.isAhead(of: now), !right.winner.stamp.isAhead(of: now) else { return nil }
            return SyncVersion.precedes(left.winner, right.winner) ? .cloud : .local
        }
        // Old snapshots have no causal history. Keep the conservative legacy rule until a real edit or review.
        guard let local = revisions.local[record], let cloud = revisions.cloud[record],
              let left = local.fields?[field], let right = cloud.fields?[field],
              let leftDate = left.date, let rightDate = right.date, leftDate != rightDate,
              leftDate <= now.addingTimeInterval(300), rightDate <= now.addingTimeInterval(300),
              leftDate <= local.date, rightDate <= cloud.date else { return nil }
        if let ancestor = revisions.baseRevisions[record]?.fields?[field],
           ancestor.fingerprint == revisions.baseFields[record]?[field], let date = ancestor.date,
           leftDate <= date || rightDate <= date { return nil }
        return leftDate > rightDate ? .local : .cloud
    }
}
