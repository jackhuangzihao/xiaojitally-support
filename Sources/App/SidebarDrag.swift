import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

#if os(macOS)
/// Mac sidebar: a list follows the pointer while it is dragged, instead of going through system drag and drop
/// (which kept clicks from selecting a list). Rows report where they are; the drag works out the landing spot.
@MainActor @Observable final class ListDrag {
    private(set) var listID: UUID?
    private(set) var cancelledUntilPress = false
    @ObservationIgnored private var nextPress: Any?
    private(set) var name = ""
    private(set) var color = Color.accentColor
    /// The lifted row follows the pointer as a copy of itself, held where it was grabbed.
    private(set) var liftedFrame: CGRect?
    private(set) var grabOffset: CGFloat = 12
    private(set) var colorHex: String?
    private(set) var emoji: String?
    private(set) var isGroup = false
    private(set) var pointer = CGPoint.zero
    private(set) var target: (list: UUID?, placement: ListTree.Placement)?
    private(set) var offsets: [UUID: CGFloat] = [:]
    private(set) var gap: CGRect?
    private(set) var moving = Set<UUID>()
    @ObservationIgnored var isDescendant: ((UUID, UUID) -> Bool)?
    @ObservationIgnored var listName: ((UUID) -> String)?
    @ObservationIgnored var depthOf: ((UUID) -> Int)?
    @ObservationIgnored var descendantCount: ((UUID) -> Int)?
    /// Lists inside the lifted one (all levels, open or closed), which move along with it.
    private(set) var childCount = 0
    /// Frames in global coordinates. Not observed: nothing redraws for them.
    /// Each row's frame, with the row view that reported it. A list's row is sometimes replaced (a list that
    /// becomes a group, say): the new row reports before the old one goes away, and only the reporter may erase it.
    @ObservationIgnored private var rowFrames: [UUID: (owner: UUID, frame: CGRect)] = [:]
    var rows: [UUID: CGRect] { rowFrames.mapValues(\.frame) }
    func report(_ id: UUID, owner: UUID, frame: CGRect) {
        let changed = rowFrames[id]?.frame != frame
        rowFrames[id] = (owner, frame)
        if changed && isDragging { refreshLayout() }
    }
    func forget(_ id: UUID, owner: UUID) { if rowFrames[id]?.owner == owner { rowFrames[id] = nil } }
    @ObservationIgnored var header = CGRect.zero
    @ObservationIgnored var sidebar = CGRect.zero
    @ObservationIgnored private var blocked: ((UUID) -> Bool)?
    @ObservationIgnored private var escape: Any?
    /// Which rows are on screen; rows of closed groups keep an old frame and must not be targets.
    @ObservationIgnored var visibleRows: (() -> Set<UUID>)?
    @ObservationIgnored var openGroup: ((UUID) -> Void)?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var insideSince: (id: UUID, time: Double, frame: CGRect)?
    @ObservationIgnored private var releasedSince: Double?

    var isDragging: Bool { listID != nil }

    func begin(_ list: TaskList, blocked: @escaping (UUID) -> Bool, start: CGPoint? = nil, isGroup: Bool = false) {
        guard !cancelledUntilPress, !isDragging else { return }
        visibleCache = nil
        listID = list.id; name = list.name; color = ListColor.color(list.id, hex: list.colorHex)
        colorHex = list.colorHex; emoji = list.emoji; self.isGroup = isGroup
        childCount = descendantCount?(list.id) ?? 0
        liftedFrame = rows[list.id]
        if let frame = liftedFrame { grabOffset = start.map { min(max(0, $0.y - frame.minY), frame.height) } ?? frame.height / 2 }
        self.blocked = blocked
        moving = Set(rows.keys.filter { $0 == list.id || blocked($0) })
        target = (list.id, .before)
        releasedSince = nil
        refreshLayout()
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.isDragging else { return event }
            self.cancel(); return nil
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.checkPhysicalButton(pressed: NSEvent.pressedMouseButtons & 1 != 0, now: now) else { return }
                if !NSApp.isActive || NSApp.modalWindow != nil { self.cancel(); return }
                self.tick(now: now)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Rows on screen, worked out once per drag (and again after a group opens) instead of on every sample.
    @ObservationIgnored private var visibleCache: Set<UUID>?
    private var visibleFrames: [UUID: CGRect] {
        if visibleCache == nil { visibleCache = visibleRows?() ?? Set(rows.keys) }
        let visible = visibleCache ?? []
        return rows.filter { visible.contains($0.key) }
    }

    func move(to point: CGPoint, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isDragging else { return }
        pointer = point
        // Once armed, keep the folder under a stable hover region while the sorting gap closes.
        if target?.placement == .inside, let hover = insideSince,
           hover.frame.insetBy(dx: -4, dy: -4).contains(point), sidebar.contains(point) { return }
        var next = ListTree.dropTarget(pointer: point, rows: visibleFrames, header: header, area: sidebar, blocked: blocked ?? { _ in false })
        if let candidate = next, candidate.placement == .inside, let id = candidate.list, let frame = rows[id] {
            next = (id, point.y < frame.midY ? .before : .after)
        }
        // Moving through the vacated source row keeps the current slot; leaving the sidebar cancels the destination.
        if next == nil, sidebar.contains(point), moving.contains(where: { rows[$0]?.contains(point) == true }) {
            next = target?.placement == .inside ? nil : target
        } else if next == nil, sidebar.contains(point) {
            // Native sidebar rows have small gaps between them; crossing one must not reset the preview.
            let frames = visibleFrames.filter { !moving.contains($0.key) }
            if let nearest = frames.min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }),
               point.y >= (visibleFrames.values.map(\.minY).min() ?? .infinity),
               point.y <= (visibleFrames.values.map(\.maxY).max() ?? -.infinity) {
                next = (nearest.key, point.y < nearest.value.midY ? .before : .after)
            }
        }
        if next?.list != target?.list || next?.placement != target?.placement {
            target = next
            insideSince = nil
            refreshLayout()
        }
        if let hover = insideSince, !hover.frame.contains(point) { insideSince = nil }
        if insideSince == nil, let candidate = folderAtPointer() {
            insideSince = (candidate.id, now, candidate.frame)
        }
    }

    private func refreshLayout() {
        guard let target else { offsets = [:]; gap = nil; return }
        // The source target is just the resting slot, not a reparenting operation. Nothing moves, but the
        // slot the row came from is still marked: a lifted row must never leave an unexplained hole.
        guard target.list != listID else { offsets = [:]; gap = sourceSlot(); return }
        let preview = ListTree.dragPreview(rows: visibleFrames, moving: moving, target: target,
                                          isDescendant: isDescendant ?? { $0 == $1 })
        if offsets != preview.offsets { offsets = preview.offsets }
        if gap != preview.gap { gap = preview.gap }
    }

    /// Where the lifted row (with its children) sits right now.
    private func sourceSlot() -> CGRect? {
        let frames = visibleFrames.filter { moving.contains($0.key) }.values
        guard let top = frames.min(by: { $0.minY < $1.minY }), let bottom = frames.max(by: { $0.maxY < $1.maxY }) else { return nil }
        return CGRect(x: top.minX, y: top.minY, width: top.width, height: bottom.maxY - top.minY)
    }

    private func folderAtPointer() -> (id: UUID, frame: CGRect)? {
        guard sidebar.contains(pointer) else { return nil }
        return visibleFrames.compactMap { id, frame -> (UUID, CGRect)? in
            guard !moving.contains(id), blocked?(id) != true else { return nil }
            let shown = frame.offsetBy(dx: 0, dy: offsets[id] ?? 0)
            let middle = shown.insetBy(dx: 0, dy: shown.height * 0.18)
            return middle.contains(pointer) ? (id, middle) : nil
        }.first
    }

    /// The landing spot, if any; the drag is over either way. Nothing is saved on hover.
    func finish() -> (list: UUID?, placement: ListTree.Placement)? {
        let result = target?.list == listID ? nil : target
        end()
        return result
    }

    func tick(now: Double) {
        guard isDragging else { return }
        if let hover = insideSince, target?.placement == .inside {
            if now - hover.time >= 0.9 { openGroup?(hover.id); visibleCache = nil }
            return
        }
        guard let candidate = folderAtPointer() else { insideSince = nil; return }
        if insideSince?.id != candidate.id { insideSince = (candidate.id, now, candidate.frame); return }
        guard let hover = insideSince, now - hover.time >= 0.4 else { return }
        target = (candidate.id, .inside)
        refreshLayout()
    }

    /// A missed mouse-up can only cancel; never save a drop based on a later unrelated release.
    @discardableResult func checkPhysicalButton(pressed: Bool, now: Double) -> Bool {
        guard isDragging else { return false }
        if pressed { releasedSince = nil; return true }
        if let since = releasedSince, now - since >= 0.15 { cancel() }
        else if releasedSince == nil { releasedSince = now }
        return false
    }

    func cancel() {
        end(); cancelledUntilPress = true
        if nextPress == nil {
            nextPress = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.newPress(); return event
            }
        }
    }

    func newPress() {
        cancelledUntilPress = false
        if let nextPress { NSEvent.removeMonitor(nextPress); self.nextPress = nil }
    }

    private func end() {
        listID = nil; target = nil; blocked = nil; moving = []; offsets = [:]; gap = nil; liftedFrame = nil; visibleCache = nil
        ticker?.invalidate(); ticker = nil; insideSince = nil; releasedSince = nil
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }

    func isTarget(_ id: UUID?, _ placement: ListTree.Placement) -> Bool {
        isDragging && target?.list == id && target?.placement == placement
    }
}

#endif
