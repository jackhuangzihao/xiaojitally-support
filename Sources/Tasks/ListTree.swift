import Foundation
import SwiftData

/// Lists can contain tasks as well as child lists. Parent identifiers keep old stores compatible.
enum ListTree {
    static func before(_ a: TaskList, _ b: TaskList) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    enum Placement: Equatable { case before, inside, after }

    /// Where a dragged list would land. The top quarter of a row puts it above that list, the bottom quarter
    /// below, the middle inside it; the "My lists" header puts it back at the top level (`list` is nil).
    /// Rows of the dragged list and its own children are never targets.
    static func dropTarget(pointer: CGPoint, rows: [UUID: CGRect], header: CGRect, area: CGRect = .zero, blocked: (UUID) -> Bool) -> (list: UUID?, placement: Placement)? {
        if header.height > 0, header.contains(pointer) { return (nil, .before) }
        if area.contains(pointer), header.height > 0 {
            // Everything above the first row, including the space between the header and that row.
            let top = rows.values.map(\.minY).min() ?? header.maxY
            if pointer.y < top { return (nil, .before) }
            let bottom = rows.values.map(\.maxY).max() ?? header.maxY
            if pointer.y > bottom { return (nil, .after) }
        }
        guard let (id, frame) = rows.first(where: { $0.value.contains(pointer) }), !blocked(id) else { return nil }
        let y = pointer.y - frame.minY
        return (id, y < frame.height * 0.25 ? .before : y > frame.height * 0.75 ? .after : .inside)
    }
    /// Pure presentation: take out the moving subtree and leave one gap at its proposed destination.
    /// Frames are measured outside the animated row, so springs never feed back into hit testing.
    static func dragPreview(rows: [UUID: CGRect], moving: Set<UUID>, target: (list: UUID?, placement: Placement)?,
                            isDescendant: (UUID, UUID) -> Bool = { $0 == $1 }) -> (offsets: [UUID: CGFloat], gap: CGRect?) {
        let order = rows.keys.sorted { rows[$0]!.minY < rows[$1]!.minY }
        guard let first = order.firstIndex(where: { moving.contains($0) }),
              let last = order.lastIndex(where: { moving.contains($0) }), let target else { return ([:], nil) }
        let start = rows[order[first]]!, end = rows[order[last]]!
        let spacing = order.count > 1 ? max(0, rows[order[1]]!.minY - rows[order[0]]!.maxY) : 8
        let height = end.maxY - start.minY + spacing
        let remaining = order.filter { !moving.contains($0) }
        let insertion: Int
        // Landing inside a list is shown as the slot after it and its visible children, indented one level,
        // so the placeholder never disappears while the pointer rests on a folder.
        var indent = 0.0
        if let id = target.list, let index = remaining.firstIndex(of: id) {
            let afterSubtree = (remaining.lastIndex { isDescendant($0, id) } ?? index) + 1
            switch target.placement {
            case .before: insertion = index
            case .after: insertion = afterSubtree
            case .inside: insertion = afterSubtree; indent = 14
            }
        } else { insertion = target.placement == .before ? 0 : remaining.count }
        var offsets: [UUID: CGFloat] = [:]
        for (index, id) in remaining.enumerated() {
            offsets[id] = (rows[id]!.minY > end.minY ? -height : 0) + (index >= insertion ? height : 0)
        }
        let edge = insertion < remaining.count ? rows[remaining[insertion]]! : remaining.last.flatMap { rows[$0] }.map { CGRect(x: $0.minX, y: $0.maxY + spacing, width: $0.width, height: $0.height) } ?? start
        let y = edge.minY - (edge.minY > end.minY ? height : 0)
        return (offsets, CGRect(x: edge.minX + indent, y: y, width: max(24, edge.width - indent), height: height - spacing))
    }

    static func move(_ list: TaskList, to target: TaskList?, placement: Placement, lists: [TaskList]) throws {
        guard list.id != target?.id else { return }
        let parent = placement == .inside ? target?.id : target?.parentID
        guard !contains(parent, in: list.id, lists: lists) else { throw TaskBackup.invalid(L("不能移入自己的子清单。", "Cannot move inside a descendant.")) }
        guard !lists.contains(where: { $0.id != list.id && $0.parentID == parent && $0.name.localizedCaseInsensitiveCompare(list.name) == .orderedSame }) else {
            throw TaskBackup.invalid(L("目标分组已有同名清单。", "The destination already has a list with that name."))
        }
        var siblings = lists.filter { $0.parentID == parent && $0.id != list.id }.sorted(by: before)
        let index = target == nil && placement == .before ? 0 : placement == .inside ? siblings.count : (siblings.firstIndex { $0.id == target?.id }.map { $0 + (placement == .after ? 1 : 0) } ?? siblings.count)
        list.parentID = parent
        siblings.insert(list, at: index)
        for (index, sibling) in siblings.enumerated() { sibling.sortOrder = Double(index) }
    }

    /// Preserve each child's identity and tasks when deleting its parent. Resolve names before promotion.
    static func promoteChildren(of parent: TaskList, lists: [TaskList]) {
        var siblings = lists.filter { $0.parentID == parent.parentID && $0.id != parent.id }
        var order = (siblings.map(\.sortOrder).max() ?? -1) + 1
        for child in lists.filter({ $0.parentID == parent.id }).sorted(by: before) {
            let original = child.name
            var name = original, number = 2
            while siblings.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                let suffix = " (\(number))"
                name = String(original.prefix(max(0, 40 - suffix.count))) + suffix
                number += 1
            }
            child.name = name; child.parentID = parent.parentID; child.sortOrder = order
            order += 1; siblings.append(child)
        }
    }

    static func contains(_ child: UUID?, in parent: UUID, lists: [TaskList]) -> Bool {
        var cursor = child, seen = Set<UUID>()
        while let id = cursor, seen.insert(id).inserted {
            if id == parent { return true }
            cursor = lists.first { $0.id == id }?.parentID
        }
        return false
    }
    static func path(_ list: TaskList, lists: [TaskList]) -> String {
        var parts = [list.name], cursor = list.parentID, seen: Set<UUID> = [list.id]
        while let id = cursor, seen.insert(id).inserted, let parent = lists.first(where: { $0.id == id }) {
            parts.insert(parent.name, at: 0); cursor = parent.parentID
        }
        return parts.joined(separator: " / ")
    }
    static func validate(_ parents: [UUID: UUID?]) throws {
        for id in parents.keys {
            var cursor: UUID? = id, seen = Set<UUID>()
            while let current = cursor {
                guard seen.insert(current).inserted, let next = parents[current] else {
                    throw TaskBackup.invalid(L("清单分组存在循环或缺失的上级。", "A list hierarchy contains a cycle or missing parent."))
                }
                cursor = next
            }
        }
    }
}

struct ListNode: Identifiable {
    static func visibleIDs(_ nodes: [Self], expanded: Set<UUID>) -> [UUID] {
        nodes.flatMap { node in
            [node.id] + (expanded.contains(node.id) ? visibleIDs(node.children ?? [], expanded: expanded) : [])
        }
    }
    var list: TaskList
    var children: [ListNode]?
    var id: UUID { list.id }
    static func roots(_ lists: [TaskList], parent: UUID? = nil) -> [ListNode] {
        lists.filter { $0.parentID == parent }.sorted(by: ListTree.before).map { list in
            let children = roots(lists, parent: list.id)
            return ListNode(list: list, children: children.isEmpty ? nil : children)
        }
    }
}
