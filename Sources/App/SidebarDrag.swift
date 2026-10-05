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

/// Native List consumes arrow keys before SwiftUI onKeyPress. Intercept only its sidebar table's arrows.
struct SidebarKeyboardNavigation: NSViewRepresentable {
    let move: (Int) -> Bool
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, let window = view.window,
                  event.window === window, window.attachedSheet == nil,
                  event.keyCode == 125 || event.keyCode == 126,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let table = window.firstResponder as? NSTableView,
                  view.convert(view.bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil)) else { return event }
            return coordinator.move(event.keyCode == 125 ? 1 : -1) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.move = move }
    func makeCoordinator() -> Coordinator { Coordinator(move: move) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var move: (Int) -> Bool
        init(move: @escaping (Int) -> Bool) { self.move = move }
    }
}

/// Flatten only visible rows so each row, including its disclosure arrow, can move independently.
private struct SidebarListEntry: Identifiable {
    let node: ListNode
    let depth: Int
    var id: UUID { node.id }
}
struct SidebarListTree: View {
    let nodes: [ListNode]
    @Binding var expanded: Set<UUID>
    let drag: ListDrag
    let selected: UUID?
    let row: (ListNode) -> AnyView
    private var entries: [SidebarListEntry] {
        func flatten(_ nodes: [ListNode], depth: Int) -> [SidebarListEntry] {
            nodes.flatMap { node in
                [SidebarListEntry(node: node, depth: depth)] + (expanded.contains(node.id) ? flatten(node.children ?? [], depth: depth + 1) : [])
            }
        }
        return flatten(nodes, depth: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                let isSelected = selected == entry.id && !drag.moving.contains(entry.id)
                HStack(spacing: 4) {
                    if entry.node.children != nil {
                        Button {
                            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                        } label: {
                            Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                            .accessibilityLabel((expanded.contains(entry.id) ? L("收起：", "Collapse: ") : L("展开：", "Expand: ")) + entry.node.list.name)
                    }
                    row(entry.node)
                }
                .padding(.leading, CGFloat(entry.depth) * 14)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .foregroundStyle(isSelected ? Color.selectedInk : Color.primary)
                // Drawn like the native sidebar selection, a little wider than the text.
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor).padding(.horizontal, -8) }
                    else if drag.isTarget(entry.id, .inside) {
                        // The list being dropped into stays fully visible: the lifted row moves out of its way.
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .padding(.horizontal, -8)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .modifier(SidebarListMotion(id: entry.id, drag: drag))
            }
        }
    }
}

private struct SidebarListMotion: ViewModifier {
    let id: UUID
    let drag: ListDrag
    @State private var owner = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let offset = drag.offsets[id] ?? 0
        ZStack(alignment: .leading) {
            content
                .opacity(drag.moving.contains(id) ? 0 : 1)
                .offset(y: offset)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: offset)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.report(id, owner: owner, frame: $0) }
        .onDisappear { drag.forget(id, owner: owner) }
    }
}

/// A list row in the sidebar: a click selects it, dragging moves it.
struct SidebarListRow: ViewModifier {
    let list: TaskList
    var isGroup = false
    let drag: ListDrag
    let select: () -> Void
    let blocked: (UUID) -> Bool
    let drop: ((list: UUID?, placement: ListTree.Placement)) -> Void

    func body(content: Content) -> some View {
        return Button(action: select) {
            content
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityLabel(list.name)
            .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                .onChanged { value in
                    if !drag.isDragging { drag.begin(list, blocked: blocked, start: value.startLocation, isGroup: isGroup) }
                    drag.move(to: value.location)
                }
                .onEnded { value in
                    guard drag.isDragging else { return }
                    drag.move(to: value.location)
                    // Replace preview offsets with the saved native row order in one frame.
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let target = drag.finish() { drop(target) }
                    }
                })
    }

}

/// "My lists": dropping a list here puts it back at the top level.
/// "My lists": dropping a list here puts it first at the top level. No highlight of its own:
/// the slot opening at the top of the rows already shows it.
struct SidebarListHeader: ViewModifier {
    let drag: ListDrag
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.header = $0 }
    }
}

/// The lifted row itself, following the pointer up and down where it was grabbed. The rows below make room
/// for it; outside the sidebar it fades, because letting go there changes nothing.
struct ListDragFloatingRow: View {
    let drag: ListDrag
    var body: some View {
        if drag.isDragging, let id = drag.listID, let frame = drag.liftedFrame {
            let parent = drag.target?.placement == .inside ? drag.target?.list : nil
            // Dropping into a list: the lifted row leaves the pointer and settles in the indented slot that opened
            // under that list, so the list itself is never covered and the row already shows where it will land.
            let slot = parent == nil ? nil : drag.gap
            // Indented to the level it would land on: inside a list is one level under it; before or after a list
            // is that list's level; the top and the end of the rows are the top level.
            let depth: Int = {
                guard let target = drag.target, target.list != id else { return drag.depthOf?(id) ?? 0 }
                let level = target.list.flatMap { drag.depthOf?($0) }
                return target.placement == .inside ? (level ?? -1) + 1 : (level ?? 0)
            }()
            HStack(spacing: 6) {
                ColoredListLabel(name: drag.name, id: id, colorHex: drag.colorHex, emoji: drag.emoji, isGroup: drag.isGroup)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if drag.childCount > 0 {
                    Text(L("含 \(drag.childCount) 个子清单", "+\(drag.childCount) inside")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize()
                }
            }
                .padding(.leading, 8 + CGFloat(depth) * 14).padding(.trailing, 8)
                .animation(.easeOut(duration: 0.12), value: depth)
                .frame(width: frame.width + 16, height: frame.height, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(drag.color.opacity(0.55)))
                .shadow(color: .black.opacity(slot == nil ? 0.28 : 0.12), radius: slot == nil ? 8 : 3, y: slot == nil ? 4 : 1)
                .scaleEffect(slot == nil ? 1.03 : 0.98)
                .opacity(slot == nil && !drag.sidebar.contains(drag.pointer) ? 0.45 : 1)
                .offset(x: frame.minX - 8 - drag.sidebar.minX,
                        y: (slot?.minY ?? (drag.pointer.y - drag.grabOffset)) - drag.sidebar.minY)
                .allowsHitTesting(false)
                // Following uses a very short interactive spring (it retargets smoothly on every sample);
                // settling into or leaving a folder's slot uses a fuller spring.
                .animation(slot == nil ? .interactiveSpring(response: 0.14, dampingFraction: 0.86) : .spring(response: 0.28, dampingFraction: 0.85),
                           value: (slot?.minY ?? (drag.pointer.y - drag.grabOffset)))
                .accessibilityHidden(true)
        }
    }
}
#endif
