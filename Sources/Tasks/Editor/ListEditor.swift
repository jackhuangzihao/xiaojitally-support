import SwiftUI
import SwiftData

struct ListEditor: View {
    struct DraftState: Equatable {
        let name: String
        let colorHex: String?
        let emoji: String
        let parentID: UUID?
        var original: TaskBackup.ListRecord? = nil
    }
    @Environment(EditorDrafts.self) private var drafts
    private var draftState: DraftState { DraftState(name: name, colorHex: colorHex, emoji: emoji, parentID: parentID, original: original) }
    private func keepDraft() {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        drafts.listID = original?.id; drafts.list = draftState
    }
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var lists: [TaskList]
    let list: TaskList?
    @State private var original: TaskBackup.ListRecord?
    @State private var name: String
    @State private var colorHex: String?
    @State private var emoji: String
    @FocusState private var emojiFocused: Bool
    @State private var errorMessage: String?
    @State private var initialDraft: DraftState?
    @State private var didSave = false
    private let restoredDraft: Bool

    @State private var parentID: UUID?
    init(list: TaskList?, parentID: UUID? = nil, draft: DraftState? = nil) {
        restoredDraft = draft != nil
        self.list = list; _name = State(initialValue: list?.name ?? "")
        _original = State(initialValue: draft?.original ?? list.map(TaskBackup.ListRecord.init))
        _colorHex = State(initialValue: list?.colorHex)
        _emoji = State(initialValue: list?.emoji ?? "")
        _parentID = State(initialValue: list?.parentID ?? parentID)
        if let draft {
            _name = State(initialValue: draft.name); _colorHex = State(initialValue: draft.colorHex)
            _emoji = State(initialValue: draft.emoji); _parentID = State(initialValue: draft.parentID)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(L("清单名称", "List name"), text: $name).onSubmit(save)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L("清单图标", "List icon"))
                        // The icon the list will show: the default list symbol in its colour, or the chosen emoji.
                        Group {
                            if emoji.isEmpty {
                                Image(systemName: "list.bullet.rectangle").foregroundStyle(ListColor.color(list?.id, hex: colorHex))
                            } else { Text(emoji) }
                        }
                        .font(.title3).frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Design.Radius.small))
                        .accessibilityLabel(emoji.isEmpty ? L("默认图标", "Default icon") : emoji)
                        Button { emoji = "" } label: {
                            Label(L("默认", "Default"), systemImage: emoji.isEmpty ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless)
                        TextField("", text: $emoji, prompt: Text(L("输入表情", "Type emoji"))).frame(width: 80).focused($emojiFocused)
                            .accessibilityLabel(L("清单 emoji", "List emoji"))
                            .onChange(of: emoji) { _, value in if value.count > 1 { emoji = String(value.last!) } }
                        #if os(macOS)
                        Button(L("更多表情…", "More emoji…")) { emojiFocused = true; DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) } }
                        #endif
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(["💼", "📚", "🏠", "💪", "💡", "🌱", "🎯", "🎨"], id: \.self) { icon in
                            Button { emoji = icon } label: { Text(icon).font(.title3).frame(width: 44, height: 44).background(emoji == icon ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6)) }
                                .buttonStyle(.plain).accessibilityLabel(icon)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("清单颜色", "List color")).font(.callout)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(ListColor.presets, id: \.hex) { preset in
                            colorSwatch(preset.hex, title: L(preset.zh, preset.en))
                        }
                    }
                    HStack {
                        Button { colorHex = nil } label: {
                            Label(L("自动配色", "Automatic"), systemImage: colorHex == nil ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).font(.caption)
                        if let colorHex, !ListColor.presets.contains(where: { $0.hex == colorHex.uppercased() }) {
                            Spacer()
                            colorSwatch(colorHex, title: L("原有颜色", "Previous color"))
                        }
                    }
                }
                Picker(L("上级分组", "Parent group"), selection: $parentID) {
                    Text(L("无 · 顶层", "None · Top level")).tag(nil as UUID?)
                    ForEach(lists.filter { candidate in list.map { !ListTree.contains(candidate.id, in: $0.id, lists: lists) } ?? true }) { candidate in
                        Text(ListTree.path(candidate, lists: lists)).tag(Optional(candidate.id))
                    }
                }
                Text(L("清单可包含任务和子清单；选择上级即可建立组中组。", "Lists can contain tasks and child lists. Choose a parent to nest them.")).font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.formStyle(.grouped).navigationTitle(original == nil ? L("新建清单", "New list") : L("编辑清单", "Edit list"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L("保存", "Save"), action: save) }
                }
        }
        #if os(macOS)
        .frame(width: 440, height: 650)
        #endif
        .onAppear { if initialDraft == nil { initialDraft = draftState }; keepDraft() }
        .onChange(of: draftState) { _, _ in keepDraft() }
        .modifier(UnsavedEditorGuard(hasChanges: { !didSave && (restoredDraft || initialDraft.map { $0 != draftState } == true) }))
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
    }

    private func colorSwatch(_ hex: String, title: String) -> some View {
        let selected = colorHex?.uppercased() == hex.uppercased()
        let occupied = lists.contains { $0.id != list?.id && $0.colorHex?.uppercased() == hex.uppercased() }
        return Button { colorHex = hex } label: {
            Circle().fill(ListColor.color(list?.id, hex: hex)).frame(width: 27, height: 27)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 1)
                    }
                }
                .overlay { Circle().strokeBorder(Color.primary.opacity(selected ? 0.65 : 0.12), lineWidth: selected ? 2 : 1) }
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(occupied).opacity(occupied ? 0.25 : 1)
            .help(occupied ? L("已被其他清单使用", "Used by another list") : title).accessibilityLabel(title + (occupied ? L("，已占用", ", in use") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        keepDraft()
        let existing: TaskList?, currentLists: [TaskList]
        do {
            existing = try EditorVersion.list(original, in: context)
            _ = try EditorVersion.selectedList(parentID, in: context)
            currentLists = try context.fetch(FetchDescriptor<TaskList>())
        } catch { errorMessage = error.localizedDescription; return }
        guard emoji.isEmpty || TaskList.validEmoji(emoji) else { errorMessage = L("请选择一个 emoji 作为图标，或恢复默认图标。", "Choose one emoji or use the default icon."); return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40 else { errorMessage = L("清单名称需为1–40个字。", "List names must contain 1–40 characters."); return }
        guard !currentLists.contains(where: { $0.id != original?.id && $0.parentID == parentID && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) else {
            errorMessage = L("已存在同名清单。", "A list with this name already exists."); return
        }
        if let existing, ListTree.contains(parentID, in: existing.id, lists: currentLists) { errorMessage = L("不能移入自己的子清单。", "Cannot move inside a descendant."); return }
        if let colorHex, currentLists.contains(where: { $0.id != original?.id && $0.colorHex?.uppercased() == colorHex.uppercased() }) {
            errorMessage = L("这个颜色已被其他清单使用，请选择其他颜色。", "This color is already used. Choose another color."); return
        }
        let target = existing ?? TaskList(name: value)
        if existing == nil { target.sortOrder = (currentLists.filter { $0.parentID == parentID }.map(\.sortOrder).max() ?? -1) + 1 }
        if existing == nil { context.insert(target) }
        target.name = value; target.parentID = parentID; target.colorHex = colorHex; target.emoji = emoji.isEmpty ? nil : emoji
        do { try Store.save(context); didSave = true; ReminderScheduler.shared.refresh(context); dismiss() }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil }
    }
}


extension TaskBackup.ListRecord {
    init(_ list: TaskList) {
        self.init(id: list.id, name: list.name, createdAt: list.createdAt, parentID: list.parentID,
                  colorHex: list.colorHex, sortOrder: list.sortOrder, emoji: list.emoji)
    }
}
