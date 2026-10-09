import Foundation

/// Wall-clock ordering is used only for allowlisted fields with matching saved content and a shared base.
struct AutomaticSyncPolicy {
    let revisions: SyncChanges.Resolution
    let now: Date

    func choice(record: String, field: String) -> CloudMerge.Choice? {
        guard revisions.baseValues[record] != nil,
              let local = revisions.local[record], let cloud = revisions.cloud[record],
              local.fingerprint == revisions.localValues[record],
              cloud.fingerprint == revisions.cloudValues[record],
              let left = local.fields?[field], let right = cloud.fields?[field],
              left.fingerprint == revisions.localFields[record]?[field],
              right.fingerprint == revisions.cloudFields[record]?[field],
              let leftDate = left.date, let rightDate = right.date,
              leftDate != rightDate,
              leftDate <= now.addingTimeInterval(300), rightDate <= now.addingTimeInterval(300),
              leftDate <= local.date, rightDate <= cloud.date else { return nil }
        // Reject edits dated before an observed ancestor; arrival time is never a field's edit time.
        if let ancestor = revisions.baseRevisions[record]?.fields?[field],
           ancestor.fingerprint == revisions.baseFields[record]?[field], let date = ancestor.date,
           leftDate <= date || rightDate <= date { return nil }
        return leftDate > rightDate ? .local : .cloud
    }
}
