import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

#if os(macOS)
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

/// A right-click menu for one list row. The whole list tree sits inside a single native List row, so a SwiftUI
/// contextMenu there belongs to that row: right-clicking highlighted every list and acted on the first one.
/// This view answers right-clicks and Control-clicks for its own row only; every other click passes through.
struct SidebarRowMenu: NSViewRepresentable {
    struct Item {
        let title: String
        var destructive = false
        let action: () -> Void
    }
    let items: [Item]

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.items = items }

    final class MenuView: NSView {
        var items: [Item] = []

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { showMenu(for: event) } else { super.mouseDown(with: event) }
        }
        private func showMenu(for event: NSEvent) {
            let menu = NSMenu()
            for item in items {
                let entry = NSMenuItem(title: item.title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(item.action)
                entry.target = target; entry.representedObject = target // the menu item keeps its target alive
                if item.destructive {
                    entry.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(entry)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    final class MenuAction: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
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
