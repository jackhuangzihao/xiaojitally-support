import SwiftUI

#if os(macOS)
/// Sidebar presentation receives only navigation bindings and existing task/list operations.
struct MacWorkspaceSidebar: View {
    let tasks: [TaskItem]
    let lists: [TaskList]
    let language: String
    let listDrag: ListDrag
    @Binding var financeMode: Bool
    @Binding var financeSelection: String
    @Binding var selection: TaskScope
    @Binding var expandedLists: Set<UUID>
    let sidebarFocus: FocusState<Bool>.Binding
    let createList: (UUID?) -> Void
    let editList: (TaskList) -> Void
    let deleteList: (TaskList) -> Void
    let moveTask: ([String], UUID) -> Bool
    let dropList: (UUID, (list: UUID?, placement: ListTree.Placement)) -> Void
    let configureDrag: () -> Void

    private var selectedListID: UUID? {
        if case .list(let id) = selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionPicker(finance: $financeMode)
            if financeMode { FinanceSidebar(selection: $financeSelection) } else {
            List(selection: Binding<TaskScope?>(get: { selection }, set: { if let value = $0 { selection = value } })) {
                ForEach(TaskScope.standard, id: \.self) { scope in
                    Label(scope.localizedTitle(language), systemImage: scope.icon).tag(scope)
                }
                Section {
                        // One custom stack, not one native row per list: native sidebar rows clip anything moved
                        // outside their own bounds, so rows making way for a drag simply vanished.
                        SidebarListTree(nodes: ListNode.roots(lists), expanded: $expandedLists, drag: listDrag, selected: selectedListID) { node in
                            AnyView(
                                ColoredListLabel(name: node.list.name, id: node.id, colorHex: node.list.colorHex, emoji: node.list.emoji, isGroup: node.children != nil)
                                    .modifier(SidebarListRow(list: node.list, isGroup: node.children != nil, drag: listDrag, select: { selection = .list(node.id); sidebarFocus.wrappedValue = true },
                                                             blocked: { ListTree.contains($0, in: node.id, lists: lists) },
                                                             drop: { target in dropList(node.id, target) }))
                                    .modifier(TaskDropHighlight(tint: ListColor.color(node.id, hex: node.list.colorHex),
                                        accepts: { id in tasks.contains { $0.id == id && $0.deletedAt == nil && $0.list?.id != node.id } },
                                        perform: { moveTask($0, node.id) }))
                                    .overlay(SidebarRowMenu(items: [
                                        .init(title: L("新建子清单", "New child list")) { createList(node.id) },
                                        .init(title: L("编辑清单", "Edit list")) { editList(node.list) },
                                        .init(title: L("删除清单", "Delete list"), destructive: true) { deleteList(node.list) }
                                    ]))
                            )
                        }
                } header: {
                    HStack(spacing: 4) {
                        Text(L("我的清单", "My lists")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button { createList(nil) } label: {
                            Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("新建清单或分组", "New list or group"))
                        .accessibilityLabel(L("新建清单或分组", "New list or group"))
                    }
                    .modifier(SidebarListHeader(drag: listDrag))
                }
            }
            .focused(sidebarFocus)
            .background(SidebarKeyboardNavigation { direction in
                guard !listDrag.isDragging else { return false }
                selection = selection.adjacentSidebarScope(direction: direction, lists: lists, expanded: expandedLists)
                return true
            })
            }
            SidebarSyncStatus(sync: CloudSync.shared).padding(.horizontal, 10).padding(.bottom, 12)
            }.padding(.top, 20)
                .overlay(alignment: .topLeading) { ListDragFloatingRow(drag: listDrag) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listDrag.sidebar = $0 }
                .onAppear(perform: configureDrag)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }
}
/// Where the data lives, as a small block: a coloured dot for the state and one line of detail.
private struct SidebarSyncStatus: View {
    let sync: CloudSync
    @Environment(\.locale) private var locale

    private var tint: Color {
        if !sync.enabled { return .secondary }
        if sync.conflict || !sync.detail.isEmpty { return .orange }
        return sync.running ? .accentColor : .green
    }
    private var detail: String? {
        if !sync.enabled { return L("可在设置里开启 iCloud 同步", "Turn on iCloud sync in Settings") }
        if sync.running || sync.conflict || !sync.detail.isEmpty { return nil }
        return sync.lastSync.map { L("最近同步 ", "Last synced ") + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(sync.summary).font(.caption).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
#endif
