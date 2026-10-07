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
                                    .contextMenu {
                                        Button(L("新建子清单", "New child list")) { createList(node.id) }
                                        Button(L("编辑清单", "Edit list")) { editList(node.list) }
                                        Button(L("删除清单", "Delete list"), role: .destructive) { deleteList(node.list) }
                                    }
                            )
                        }
                } header: {
                    HStack(spacing: 4) {
                        Text(L("我的清单", "My lists"))
                        Spacer(minLength: 0)
                        Button { createList(nil) } label: {
                            Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
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
            Label(CloudSync.shared.summary, systemImage: CloudSync.shared.enabled ? "icloud" : "internaldrive").font(.caption).foregroundStyle(.secondary).padding(16)
            }.padding(.top, 20)
                .overlay(alignment: .topLeading) { ListDragFloatingRow(drag: listDrag) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listDrag.sidebar = $0 }
                .onAppear(perform: configureDrag)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
    }
}
#endif
