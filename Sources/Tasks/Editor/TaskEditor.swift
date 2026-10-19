import SwiftUI
import SwiftData

/// One draft and one save path; sibling extensions provide scheduling, finance and suggestions.
struct TaskEditor: View {
    enum Panel { case date, time, deadline, reminder, repeating }

    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Query(sort: \TaskList.createdAt) var lists: [TaskList]
    @Query var allTasks: [TaskItem]
    @Environment(EditorDrafts.self) var drafts
    let request: EditorRequest
    @State var recoveredDraft: Bool
    @State var original: TaskBackup.TaskRecord?

    @State var title: String
    @State var notes: String
    @State var hasDate: Bool
    @State var date: Date
    @State var restoredScheduledDate: AllDayDraftDate?
    @State var hasEnd: Bool

    @State var end: Date
    @State var hasTime: Bool
    @State var startClockIntent: ClockIntent?
    @State var dueClockIntent: ClockIntent?
    @State var hasDue: Bool
    @State var due: Date
    @State var restoredDueDate: AllDayDraftDate?
    @State var dueHasTime: Bool
    @State var priority: Int
    @State var reminderPreset: ReminderPreset
    @State var reminder: Date
    @State var lastRelativeReminder: Date?
    @State var repeatRule: String
    @State var repeatTimeZoneID: String?
    /// The last day a repeating task comes back; nil repeats without end.
    @State var repeatUntil: Date?
    /// Showing the custom repeat controls (every n days/weeks/months/years, chosen weekdays).
    @State var customRepeat: Bool
    /// New tasks: the highlighted earlier task, and the title for which the list was closed or used.
    @State var suggestionIndex = 0
    @State var templateReminder: Date?
    /// The template title whose reminder had already passed and was left out; the note shows while it is the title.
    @State var reminderDroppedFor: String?
    @State var suggestionsClosedFor: String?
    @State var openPanel: Panel?
    @State var isSaving = false
    @State var saveTask: Task<Void, Never>?
    @State var didFinishSaving = false
    @State var clockNow = Date()
    @State private var discardPrompt = false
    @State var initialDraft: DraftState?
    @State var listID: UUID?
    @State var subtasks: [Subtask]
    @State var newSubtask = ""
    @State var linkedFinance: TaskFinanceDraft?
    @State var financeCurrencyChanged = false
    @State var errorMessage: String?
    @FocusState var newSubtaskFocused: Bool
    enum Focus: Hashable { case title, notes, sheet, financeAmount, financeConverted }
    @FocusState var focus: Focus?

    init(request: EditorRequest, draft: DraftState? = nil) {
        self.request = request
        _recoveredDraft = State(initialValue: draft != nil)
        _openPanel = State(initialValue: request.timed ? .time : nil)
        let task = request.task
        let original = draft?.original ?? task.map(TaskBackup.TaskRecord.init)
        _original = State(initialValue: original)
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _hasDate = State(initialValue: (task?.scheduledAt ?? request.date) != nil)
        _date = State(initialValue: task?.scheduledAt ?? request.date ?? Date())
        _hasEnd = State(initialValue: task?.endAt != nil || (task == nil && request.timed))
        _end = State(initialValue: task?.endAt ?? (task?.scheduledAt ?? request.date ?? Date()).addingTimeInterval(3600))
        _hasTime = State(initialValue: task?.hasTime ?? request.timed)
        _startClockIntent = State(initialValue: ClockIntent.opening(task?.scheduledAt ?? request.date, original: original, usesStart: true))
        _dueClockIntent = State(initialValue: ClockIntent.opening(task?.dueAt, original: original, usesStart: false))
        _hasDue = State(initialValue: task?.dueAt != nil)
        _due = State(initialValue: task?.dueAt ?? task?.scheduledAt ?? request.date ?? Date())
        _dueHasTime = State(initialValue: task?.dueHasTime ?? false)
        _priority = State(initialValue: task?.priority ?? 0)
        _reminderPreset = State(initialValue: task?.resolvedReminderPreset ?? .none)
        _reminder = State(initialValue: task?.reminderAt ?? TaskEditor.defaultCustomReminder(for: task?.scheduledAt ?? request.date))
        _repeatRule = State(initialValue: task?.repeatRule ?? "none")
        _repeatTimeZoneID = State(initialValue: task == nil || task?.repeatRule == "none"
            ? Dates.calendar.timeZone.identifier : task?.repeatTimeZoneID)
        _repeatUntil = State(initialValue: task?.repeatUntil)
        _customRepeat = State(initialValue: Self.isCustomRepeat(task?.repeatRule))
        _listID = State(initialValue: task?.list?.id ?? request.listID)
        _subtasks = State(initialValue: task?.subtasks ?? [])
        if let draft {
            _title = State(initialValue: draft.title); _notes = State(initialValue: draft.notes)
            _newSubtask = State(initialValue: draft.pending); _subtasks = State(initialValue: draft.subtasks)
            _hasDate = State(initialValue: draft.scheduled != nil); _date = State(initialValue: draft.scheduled ?? Date())
            _hasTime = State(initialValue: draft.timed); _hasEnd = State(initialValue: draft.end != nil)
            _end = State(initialValue: draft.end ?? (draft.scheduled ?? Date()).addingTimeInterval(3600))
            _hasDue = State(initialValue: draft.due != nil); _due = State(initialValue: draft.due ?? Date())
            _dueHasTime = State(initialValue: draft.dueTimed); _priority = State(initialValue: draft.priority)
            _startClockIntent = State(initialValue: draft.startClockIntent ?? ClockIntent.opening(draft.scheduled, original: original, usesStart: true))
            _dueClockIntent = State(initialValue: draft.dueClockIntent ?? ClockIntent.opening(draft.due, original: original, usesStart: false))
            _restoredScheduledDate = State(initialValue: AllDayDraftDate(input: draft.scheduled,
                normalized: draft.normalizedScheduledDate, timed: draft.timed))
            _restoredDueDate = State(initialValue: AllDayDraftDate(input: draft.due,
                normalized: draft.normalizedDueDate, timed: draft.dueTimed))
            _listID = State(initialValue: draft.listID); _repeatRule = State(initialValue: draft.repeating)
            _repeatUntil = State(initialValue: draft.repeatUntil)
            _repeatTimeZoneID = State(initialValue: draft.repeatTimeZoneID)
            _customRepeat = State(initialValue: Self.isCustomRepeat(draft.repeating))
            _reminderPreset = State(initialValue: draft.preset)
            _reminder = State(initialValue: draft.reminder ?? Self.defaultCustomReminder(for: draft.scheduled))
            _linkedFinance = State(initialValue: draft.finance)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("", text: $title, prompt: Text(L("要做什么？", "What needs doing?")), axis: .vertical)
                            .font(.title2.weight(.semibold)).lineLimit(1...4).textFieldStyle(.plain)
                            .focused($focus, equals: .title)
                            .accessibilityLabel(L("任务名称", "Task title"))
                            #if os(macOS)
                            .background(SuggestionKeys(active: showSuggestions && focus == .title, handle: suggestionKey))
                            #endif
                        if showSuggestions { suggestionList }
                        if request.task == nil && allTasks.isEmpty {
                            Text(L("填写任务名称即可保存，日期和提醒按需设置。", "A title is enough to save. Add a date or reminder if you need one."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("", text: $notes, prompt: Text(L("写点备注…", "Add a note…")), axis: .vertical)
                            .lineLimit(1...10).textFieldStyle(.plain).foregroundStyle(.secondary)
                            .focused($focus, equals: .notes)
                            .accessibilityLabel(L("任务备注，多行输入", "Task notes, multiple lines"))
                    }
                    .editorCard(vertical: 14)

                    scheduleRows.editorCard()
                    ForEach(warnings, id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if reminderDroppedFor == title, reminderPreset == .none {
                        Label(L("旧任务的提醒时间对这次来说已经过去，所以没有带上提醒。", "The earlier task's reminder time has already passed for this one, so no reminder was added."),
                              systemImage: "bell.slash").font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 12) {
                        HStack {
                            HStack(spacing: 10) { EditorRowIcon(systemImage: "folder"); Text(L("清单", "List")) }
                            Spacer()
                            Picker(L("清单", "List"), selection: $listID) {
                                Text(L("未分类", "No list")).tag(nil as UUID?)
                                ForEach(lists) { list in
                                    ColoredListLabel(name: ListTree.path(list, lists: lists), id: list.id, colorHex: list.colorHex, emoji: list.emoji)
                                        .tag(Optional(list.id))
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 220)
                        }
                        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                            HStack(spacing: 10) { EditorRowIcon(systemImage: "flag"); Text(L("优先级", "Priority")) }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            FlowLayout(spacing: 6) {
                            ForEach([(0, L("普通", "Normal")), (1, L("中", "Medium")), (2, L("高", "High"))], id: \.0) { value, name in
                                SelectPill(title: name, selected: priority == value, tint: Self.priorityTint(value)) { priority = value }
                            }
                            }
                        }
                    }
                    .editorCard(vertical: 12)

                    if original == nil { newTaskFinance.editorCard(vertical: linkedFinance == nil ? 2 : 12) }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionCountHeader(title: L("子任务", "Subtasks"), count: subtasks.count).padding(.top, 8)
                        ForEach($subtasks) { $subtask in
                            HStack(spacing: 8) {
                                Button { subtask.isDone.toggle() } label: {
                                    Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary).frame(width: 44, height: 44)
                                }.buttonStyle(.plain).accessibilityLabel("\(subtask.isDone ? L("取消完成子任务", "Mark subtask incomplete") : L("完成子任务", "Complete subtask"))：\(subtask.title)")
                                TextField(L("子任务名称", "Subtask title"), text: $subtask.title, axis: .vertical).lineLimit(1...4).textFieldStyle(.plain)
                                    .strikethrough(subtask.isDone).foregroundStyle(subtask.isDone ? .secondary : .primary)
                                Button { subtasks.removeAll { $0.id == subtask.id } } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                                    .buttonStyle(.plain).accessibilityLabel(L("移除子任务：\(subtask.title)", "Remove subtask: \(subtask.title)"))
                            }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "plus").foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                            TextField(L("添加子任务，回车继续", "Add a subtask, press Return for another"), text: $newSubtask).textFieldStyle(.plain)
                                .onSubmit(addSubtask).focused($newSubtaskFocused)
                                .submitLabel(.next)
                        }
                    }
                    .editorCard()

                    if let task = request.task, task.deletedAt == nil { TaskMoneySection(task: task).editorCard(vertical: 12) }

                    if original?.deletedAt != nil {
                        Text(L("保存时会将这项任务从最近删除中恢复。", "Saving will restore this task from Recently deleted.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: openPanel)
                #if os(macOS)
                // macOS gives the first text field focus and selects its text; park focus here instead for existing tasks.
                .focusable().focused($focus, equals: .sheet).focusEffectDisabled()
                #endif
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .disabled(isSaving)
            .background(Color.appBackground)
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { clockNow = $0 }
            .onChange(of: reminderOptions) { _, options in
                // A relative reminder that no longer applies (e.g. the time was removed) keeps its last moment as a custom time.
                if !options.contains(reminderPreset) { reminderPreset = .custom }
            }
            .onChange(of: reminderPreset) { old, new in
                guard new == .custom else { templateReminder = nil; return }
                if let copied = templateReminder { reminder = copied; templateReminder = nil; return }
                if let previous = old.date(base: reminderBase, timed: reminderTimed, calendar: repeatCalendar ?? Dates.calendar) ?? lastRelativeReminder { reminder = previous }
                if let reminderLatest, reminder > reminderLatest { reminder = reminderLatest }
            }
            .onChange(of: draftState) { old, new in draftChanged(from: old, to: new) }
            .onChange(of: title) { _, _ in suggestionIndex = 0 }
            .onChange(of: notes) { _, _ in suggestionsClosedFor = title }
            .onChange(of: newSubtask) { _, _ in suggestionsClosedFor = title }
            .onChange(of: reminderBase) { _, _ in rememberRelativeReminder() }
            .onAppear {
                rememberRelativeReminder()
                if initialDraft == nil { initialDraft = draftState }
                keepDraft()
            }
            .defaultFocus($focus, request.task == nil ? .title : .sheet)
            .task {
                // New tasks start typing in the title; existing ones open without a selected title that a keystroke could replace.
                try? await Task.sleep(for: .milliseconds(80))
                focus = request.task == nil ? TaskEditor.Focus.title : TaskEditor.Focus.sheet
            }
            .interactiveDismissDisabled(isSaving || hasChanges)
            .navigationTitle(original == nil ? L("新建任务", "New task") : L("任务详情", "Task details"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("完成输入", "Done typing")) { focus = nil; newSubtaskFocused = false }
                }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { if hasChanges { discardPrompt = true } else { dismiss() } }.disabled(isSaving).keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存", "Save"), action: save).disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .confirmationDialog(L("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $discardPrompt, titleVisibility: .visible) {
                Button(L("放弃修改", "Discard changes"), role: .destructive) { dismiss() }
                Button(L("继续编辑", "Keep editing"), role: .cancel) {}
            }
            .alert(L("无法保存", "Unable to save"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(L("知道了", "OK"), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .overlay { if isSaving { ProgressView(L("正在保存…", "Saving…")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .onDisappear { saveTask?.cancel() }
        .modifier(UnsavedEditorGuard(hasChanges: { hasChanges && !didFinishSaving }))
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
        .environment(\.locale, UISettings.locale)
        .environment(\.calendar, Dates.calendar)
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
    }

    /// Medium priority is orange and high is red, matching the tags in lists and calendars; normal keeps the accent.
    static func priorityTint(_ priority: Int) -> Color? {
        switch priority {
        case 1: .orange
        case 2: .red
        default: nil
        }
    }

}

private extension View {
    /// One group of the editor on its own card. Type-erased so the editor's body stays within the
    /// self-check's per-component stack budget; there are only a handful of cards, so the cost is negligible.
    func editorCard(vertical: CGFloat = 4) -> AnyView {
        AnyView(padding(.horizontal, 14).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface())
    }
}
