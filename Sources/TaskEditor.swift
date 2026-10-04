import SwiftUI
import SwiftData
import Observation

@MainActor @Observable final class EditorDrafts {
    var financeEntity: FinanceEntityDraft?
    var finance: FinanceDraft?
    var reminder = ReminderNavigation()
    var taskID: UUID?
    var task: TaskEditor.DraftState?
    var listID: UUID?
    var list: ListEditor.DraftState?
}

struct TaskEditor: View {
    private enum Panel { case date, time, deadline, reminder, repeating }

    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \TaskList.createdAt) private var lists: [TaskList]
    @Query private var allTasks: [TaskItem]
    @Environment(EditorDrafts.self) private var drafts
    let request: EditorRequest
    @State private var recoveredDraft: Bool

    @State private var title: String
    @State private var notes: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var hasEnd: Bool

    @State private var end: Date
    @State private var hasTime: Bool
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var dueHasTime: Bool
    @State private var priority: Int
    @State private var reminderPreset: ReminderPreset
    @State private var reminder: Date
    @State private var lastRelativeReminder: Date?
    @State private var repeatRule: String
    /// The last day a repeating task comes back; nil repeats without end.
    @State private var repeatUntil: Date?
    /// Showing the custom repeat controls (every n days/weeks/months/years, chosen weekdays).
    @State private var customRepeat: Bool
    /// New tasks: the highlighted earlier task, and the title for which the list was closed or used.
    @State private var suggestionIndex = 0
    @State private var templateReminder: Date?
    /// The template title whose reminder had already passed and was left out; the note shows while it is the title.
    @State private var reminderDroppedFor: String?
    @State private var suggestionsClosedFor: String?
    @State private var openPanel: Panel?
    @State private var isSaving = false
    @State private var clockNow = Date()
    @State private var discardPrompt = false
    @State private var initialDraft: DraftState?
    @State private var listID: UUID?
    @State private var subtasks: [Subtask]
    @State private var newSubtask = ""
    @State private var errorMessage: String?
    @FocusState private var newSubtaskFocused: Bool
    private enum Focus: Hashable { case title, notes, sheet }
    @FocusState private var focus: Focus?

    init(request: EditorRequest, draft: DraftState? = nil) {
        self.request = request
        _recoveredDraft = State(initialValue: draft != nil)
        _openPanel = State(initialValue: request.timed ? .time : nil)
        let task = request.task
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _hasDate = State(initialValue: (task?.scheduledAt ?? request.date) != nil)
        _date = State(initialValue: task?.scheduledAt ?? request.date ?? Date())
        _hasEnd = State(initialValue: task?.endAt != nil || (task == nil && request.timed))
        _end = State(initialValue: task?.endAt ?? (task?.scheduledAt ?? request.date ?? Date()).addingTimeInterval(3600))
        _hasTime = State(initialValue: task?.hasTime ?? request.timed)
        _hasDue = State(initialValue: task?.dueAt != nil)
        _due = State(initialValue: task?.dueAt ?? task?.scheduledAt ?? request.date ?? Date())
        _dueHasTime = State(initialValue: task?.dueHasTime ?? false)
        _priority = State(initialValue: task?.priority ?? 0)
        _reminderPreset = State(initialValue: task?.resolvedReminderPreset ?? .none)
        _reminder = State(initialValue: task?.reminderAt ?? TaskEditor.defaultCustomReminder(for: task?.scheduledAt ?? request.date))
        _repeatRule = State(initialValue: task?.repeatRule ?? "none")
        _repeatUntil = State(initialValue: task?.repeatUntil)
        _customRepeat = State(initialValue: !TaskEditor.repeatPresets.contains(task?.repeatRule ?? "none") && task?.repeatRule != "none")
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
            _listID = State(initialValue: draft.listID); _repeatRule = State(initialValue: draft.repeating)
            _repeatUntil = State(initialValue: draft.repeatUntil)
            _customRepeat = State(initialValue: !Self.repeatPresets.contains(draft.repeating) && draft.repeating != "none")
            _reminderPreset = State(initialValue: draft.preset)
            _reminder = State(initialValue: draft.reminder ?? Self.defaultCustomReminder(for: draft.scheduled))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("", text: $title, prompt: Text(L("要做什么？", "What needs doing?")), axis: .vertical)
                            .font(.title2.weight(.semibold)).lineLimit(1...4).textFieldStyle(.plain)
                            .focused($focus, equals: .title)
                            .accessibilityLabel(L("任务名称", "Task title"))
                            #if os(macOS)
                            .modifier(SuggestionKeys(active: showSuggestions, handle: suggestionKey))
                            #endif
                        if showSuggestions { suggestionList }
                        TextField("", text: $notes, prompt: Text(L("写点备注…", "Add a note…")), axis: .vertical)
                            .lineLimit(1...10).textFieldStyle(.plain).foregroundStyle(.secondary)
                            .focused($focus, equals: .notes)
                            .accessibilityLabel(L("任务备注，多行输入", "Task notes, multiple lines"))
                    }

                    scheduleRows
                    ForEach(warnings, id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if reminderDroppedFor == title, reminderPreset == .none {
                        Label(L("旧任务的提醒时间对这次来说已经过去，所以没有带上提醒。", "The earlier task's reminder time has already passed for this one, so no reminder was added."),
                              systemImage: "bell.slash").font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()
                    VStack(spacing: 12) {
                        HStack {
                            Label(L("清单", "List"), systemImage: "folder").foregroundStyle(.secondary)
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
                            Label(L("优先级", "Priority"), systemImage: "flag").foregroundStyle(.secondary)
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            FlowLayout(spacing: 6) {
                            ForEach([(0, L("普通", "Normal")), (1, L("中", "Medium")), (2, L("高", "High"))], id: \.0) { value, name in
                                SelectPill(title: name, selected: priority == value) { priority = value }
                            }
                            }
                        }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("子任务", "Subtasks")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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

                    if let task = request.task, task.deletedAt == nil { Divider(); TaskMoneySection(task: task) }

                    if request.task?.deletedAt != nil {
                        Text(L("保存时会将这项任务从最近删除中恢复。", "Saving will restore this task from Recently deleted.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
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
                if let previous = old.date(base: reminderBase, timed: reminderTimed) ?? lastRelativeReminder { reminder = previous }
                if let reminderLatest, reminder > reminderLatest { reminder = reminderLatest }
            }
            .onChange(of: draftState) { _, _ in keepDraft() }
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
                focus = request.task == nil ? .title : .sheet
            }
            .interactiveDismissDisabled(isSaving || hasChanges)
            .navigationTitle(request.task == nil ? L("新建任务", "New task") : L("任务详情", "Task details"))
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
        .modifier(SaveRecoveryGuard())
        .modifier(CloudSyncEditingGuard())
        .environment(\.locale, UISettings.locale)
        .environment(\.calendar, Dates.calendar)
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
    }

    struct DraftState: Equatable {
        let title: String, notes: String, pending: String, repeating: String
        let repeatUntil: Date?
        let end: Date?
        let scheduled: Date?, due: Date?, reminder: Date?
        let timed: Bool, dueTimed: Bool
        let preset: ReminderPreset
        let listID: UUID?
        let priority: Int
        let subtasks: [Subtask]
    }
    private var draftState: DraftState {
        DraftState(title: title, notes: notes, pending: newSubtask, repeating: repeatRule, repeatUntil: repeatRule == "none" ? nil : repeatUntil,
                   end: effectiveEnd, scheduled: hasDate ? date : nil, due: hasDue ? due : nil, reminder: effectiveReminder,
                   timed: hasTime, dueTimed: dueHasTime, preset: reminderPreset, listID: listID, priority: priority, subtasks: subtasks)
    }
    private var effectiveEnd: Date? { hasDate && hasTime && hasEnd ? end : nil }
    private var hasChanges: Bool { recoveredDraft || (initialDraft.map { $0 != draftState } ?? false) }
    private func keepDraft() {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        drafts.taskID = request.task?.id
        drafts.task = draftState
    }

    // MARK: Schedule — five rows that are always shown; tapping one opens it right underneath

    private var scheduleRows: some View {
        VStack(spacing: 0) {
            SettingRow(systemImage: "calendar", title: L("日期", "Date"),
                       value: hasDate ? Dates.label(date, pattern: "M月d日 EEEE") : L("无日期", "No date"),
                       isSet: hasDate, isOpen: openPanel == .date, action: { toggle(.date) },
                       clear: { hasDate = false; hasTime = false; hasEnd = false; close(.date, .time) })
            if openPanel == .date { panel(.date) }
            SettingRow(systemImage: "clock", title: L("时间", "Time"), value: timeText,
                       isSet: hasDate && hasTime, isOpen: openPanel == .time, action: openTime,
                       clear: { hasTime = false; hasEnd = false; close(.time) })
            if openPanel == .time { panel(.time) }
            SettingRow(systemImage: "hourglass", title: L("截止", "Deadline"), value: hasDue ? deadlineText : L("无", "None"),
                       isSet: hasDue, isOpen: openPanel == .deadline,
                       tint: hasDue && dueCountdown.level != .normal ? dueCountdown.color : .accentColor,
                       action: {
                           if !hasDue, let earliest = dueEarliest, due < earliest { due = earliest }
                           toggle(.deadline)
                       },
                       clear: { hasDue = false; dueHasTime = false; close(.deadline) })
            if openPanel == .deadline { panel(.deadline) }
            SettingRow(systemImage: "bell", title: L("提醒", "Reminder"), value: reminderPreset == .none ? L("不提醒", "None") : reminderChipText,
                       isSet: reminderPreset != .none, isOpen: openPanel == .reminder, action: { toggle(.reminder) },
                       clear: { reminderPreset = .none; close(.reminder) })
            if openPanel == .reminder { panel(.reminder) }
            SettingRow(systemImage: "repeat", title: L("重复", "Repeat"), value: repeatText,
                       isSet: repeatRule != "none", isOpen: openPanel == .repeating, action: { toggle(.repeating) },
                       clear: { repeatRule = "none"; repeatUntil = nil; customRepeat = false; close(.repeating) })
            if openPanel == .repeating { panel(.repeating) }
        }
    }

    /// "15:00 – 16:00", with the day when it ends after midnight; "全天" when there is no time.
    private var timeText: String {
        guard hasDate, hasTime else { return L("全天", "All day") }
        var text = Dates.label(date, pattern: "HH:mm")
        if hasEnd {
            text += " – " + Dates.label(end, pattern: "HH:mm")
            let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: date), to: Dates.calendar.startOfDay(for: end)).day ?? 0
            if days == 1 { text += L("（次日）", " (next day)") }
            else if days > 1 { text += "（" + Dates.label(end, pattern: "M月d日") + "）" }
        }
        return text
    }

    private var deadlineText: String {
        Dates.label(due, pattern: dueHasTime ? "M月d日 HH:mm" : "M月d日") + " · " + dueCountdown.short
    }

    /// Opening the time row gives the task a time straight away — the next hour, lasting an hour.
    /// Without a date yet, it takes the day the editor was opened for (or today).
    private func openTime() {
        if !(hasDate && hasTime) {
            hasDate = true
            let start = TaskEditor.defaultTime(on: date)
            end = start.addingTimeInterval(3600)
            date = start
            hasTime = true; hasEnd = true
        }
        toggle(.time)
    }

    /// Clock edits preserve the selected end day; an invalid earlier time rolls forward.
    private var startDate: Binding<Date> {
        Binding(get: { date }, set: { value in
            end = end.addingTimeInterval(value.timeIntervalSince(date))
            date = value
        })
    }

    private var endClock: Binding<Date> {
        Binding(get: { end }, set: { value in
            end = Dates.changingEndClock(value, start: date, end: end)
        })
    }

    private var reminderChipText: String {
        switch reminderPreset {
        case .none: L("不提醒", "None")
        case .custom: Dates.label(reminder, pattern: "M月d日 HH:mm")
        default: reminderPreset.menuTitle(base: reminderBase, timed: reminderTimed)
        }
    }

    @ViewBuilder private func panel(_ panel: Panel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch panel {
            case .date:
                DateGrid(date: startDate, highlight: hasDate) { hasDate = true; close(.date) }
            case .time:
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))) {
                    VStack(spacing: 4) {
                        Text(L("开始", "Start")).font(.caption).foregroundStyle(.secondary)
                        TimeWheel(date: startDate)
                    }
                    VStack(spacing: 4) {
                        Text(L("结束", "End")).font(.caption).foregroundStyle(.secondary)
                        if hasEnd {
                            TimeWheel(date: endClock)
                        } else {
                            Button(L("添加结束时间", "Add end time")) { end = date.addingTimeInterval(3600); hasEnd = true }
                                .buttonStyle(.borderless).frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                HStack {
                    if hasEnd {
                        DatePicker(L("结束日期", "End date"), selection: $end,
                                   in: Dates.calendar.startOfDay(for: date)..., displayedComponents: .date)
                            .datePickerStyle(.compact).fixedSize().font(.caption)
                    }
                    Spacer()
                    Button(L("改回全天", "Make all day")) { hasTime = false; hasEnd = false; close(.time) }.buttonStyle(.borderless).font(.callout)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if hasEnd {
                        DatePicker(L("结束日期", "End date"), selection: $end,
                                   in: Dates.calendar.startOfDay(for: date)..., displayedComponents: .date).datePickerStyle(.compact)
                    }
                    Button(L("改回全天", "Make all day")) { hasTime = false; hasEnd = false; close(.time) }.buttonStyle(.borderless).frame(minHeight: 44)
                }
                }
            case .deadline:
                DateGrid(date: $due, earliest: dueEarliest, highlight: hasDue) { hasDue = true }
                HStack {
                    if dueHasTime {
                        TimeWheel(date: $due)
                    } else {
                        Text(L("截止到这一天结束", "Due by the end of the day")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(dueHasTime ? L("改回全天", "Make all day") : L("设定具体时间", "Set a time")) {
                        if dueHasTime { dueHasTime = false }
                        else {
                            hasDue = true
                            due = TaskEditor.defaultTime(on: due, after: hasTime && Dates.sameDay(date, due) ? (effectiveEnd ?? date) : nil)
                            dueHasTime = true
                        }
                    }.buttonStyle(.borderless).font(.callout)
                }
            case .reminder:
                FlowLayout(spacing: 8) {
                    ForEach(reminderOptions.filter { $0 != .none }) { option in
                        SelectPill(title: option.menuTitle(base: reminderBase, timed: reminderTimed), selected: reminderPreset == option) {
                            reminderPreset = option
                            if option != .custom { close(.reminder) }
                        }
                    }
                }
                if reminderPreset == .custom {
                    Divider()
                    DateGrid(date: $reminder, earliest: Date(), latest: reminderLatest)
                    Text(reminderRangeHint).font(.caption).foregroundStyle(.secondary)
                    TimeWheel(date: $reminder)
                }
            case .repeating:
                if reminderBase == nil && repeatRule == "none" {
                    Text(L("先设日期或截止日期，才能定期重复。", "Set a date or deadline first to repeat this task."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(TaskEditor.repeatPresets, id: \.self) { rule in
                            SelectPill(title: Dates.repeatLabel(rule), selected: !customRepeat && repeatRule == rule) { customRepeat = false; repeatRule = rule }
                        }
                        SelectPill(title: L("自定义", "Custom"), selected: customRepeat) {
                            customRepeat = true
                            if repeatRule == "none" { repeatRule = RepeatRule(interval: 1, unit: .week, weekdays: [baseWeekday]).text }
                        }
                    }
                    if customRepeat, let rule = RepeatRule(repeatRule) { customRepeatControls(rule) }
                    if repeatRule != "none" {
                        Divider()
                        HStack(spacing: 8) {
                            Text(L("结束", "Ends")).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            SelectPill(title: L("永不", "Never"), selected: repeatUntil == nil) { repeatUntil = nil }
                            SelectPill(title: L("到某天为止", "On a date"), selected: repeatUntil != nil) {
                                if repeatUntil == nil { repeatUntil = Dates.calendar.date(byAdding: .month, value: 3, to: repeatStartDay) }
                            }
                        }
                        if let until = repeatUntil {
                            DatePicker(L("最后一次不晚于", "Last time on or before"),
                                       selection: Binding(get: { until }, set: { repeatUntil = Dates.calendar.startOfDay(for: $0) }),
                                       in: repeatStartDay..., displayedComponents: .date)
                                .datePickerStyle(.compact).font(.callout)
                        }
                    }
                    Text(repeatHint ?? L("适合每天吃药、每周交周报这类定期要做的事。", "For things you do regularly, like weekly reports."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 8)
    }

    /// Why some days in the reminder calendar are greyed out.
    private var reminderRangeHint: String {
        guard let latest = reminderLatest else {
            return L("没有日期的任务，可以选今天以后的任意时间。", "Without a date, any future time can be chosen.")
        }
        let now = Date()
        if latest < now { return L("任务时间已经过去，不能再设提前提醒。", "The task time has passed, so no earlier reminder can be set.") }
        if Dates.sameDay(latest, now) { return L("任务就在今天，提醒只能选今天。", "The task is today, so the reminder must be today.") }
        return L("提醒不能晚于任务，可选今天到 \(Dates.label(latest, pattern: "M月d日"))。", "Reminders can't be after the task: today to \(Dates.label(latest, pattern: "M月d日")).")
    }

    private var warnings: [String] {
        var result: [String] = []
        if let end = effectiveEnd, end <= date { result.append(L("结束时间必须晚于开始时间。", "End must be after start.")) }
        if let end = effectiveEnd, end > date, allTasks.contains(where: { other in
            guard other.id != request.task?.id, other.deletedAt == nil, !other.isDone, let start = other.clockDate else { return false }
            return start < end && (other.endAt ?? start.addingTimeInterval(1800)) > date
        }) { result.append(L("与其他任务时间重叠，仍可保存。", "Overlaps another task; you can still save.")) }
        if let reminderLatest, reminderPreset == .custom, reminder > reminderLatest {
            result.append(L("提醒不能晚于任务时间（\(Dates.label(reminderLatest, pattern: reminderTimed ? "M月d日 HH:mm" : "M月d日"))）", "The reminder can't be after the task (\(Dates.label(reminderLatest, pattern: reminderTimed ? "M月d日 HH:mm" : "M月d日")))"))
        }
        if !deadlineValid, let earliest = dueEarliest {
            result.append(L("截止不能早于安排的时间（\(Dates.label(earliest, pattern: hasTime ? "M月d日 HH:mm" : "M月d日"))）", "The deadline can't be before the scheduled time (\(Dates.label(earliest, pattern: hasTime ? "M月d日 HH:mm" : "M月d日")))"))
        }
        return result
    }

    private func toggle(_ panel: Panel) {
        focus = nil; newSubtaskFocused = false
        openPanel = openPanel == panel ? nil : panel
        // Setting the date, time and so on: the typing is done, the suggestions step aside.
        suggestionsClosedFor = title
    }

    private func close(_ panels: Panel...) {
        if let openPanel, panels.contains(openPanel) { self.openPanel = nil }
    }

    /// The moment relative reminders count from: the scheduled date, or the deadline when there is none.
    private var reminderBase: Date? {
        if hasDate { return hasTime ? date : Dates.calendar.startOfDay(for: date) }
        guard hasDue else { return nil }
        return dueHasTime ? due : Dates.calendar.startOfDay(for: due)
    }
    private var reminderTimed: Bool { hasDate ? hasTime : hasDue && dueHasTime }
    private var reminderOptions: [ReminderPreset] { ReminderPreset.options(base: reminderBase, timed: reminderTimed) }
    private var reminderLatest: Date? { ReminderPreset.latest(base: reminderBase, timed: reminderTimed) }

    private var effectiveReminder: Date? {
        reminderPreset == .custom ? reminder : reminderPreset.date(base: reminderBase, timed: reminderTimed)
    }

    private func rememberRelativeReminder() {
        if let value = reminderPreset.date(base: reminderBase, timed: reminderTimed) { lastRelativeReminder = value }
    }

    private var dueCountdown: DeadlineCountdown {
        DeadlineCountdown(due: dueHasTime ? due : Dates.calendar.startOfDay(for: due), timed: dueHasTime, now: clockNow)
    }

    private var dueEarliest: Date? {
        guard hasDate else { return nil }
        return hasTime ? (effectiveEnd ?? date) : Dates.calendar.startOfDay(for: date)
    }

    private var deadlineValid: Bool {
        !hasDue || Dates.deadlineAllowed(due: due, dueTimed: dueHasTime, scheduled: hasDate ? (effectiveEnd ?? date) : nil, scheduledTimed: hasTime)
    }

    /// Explains repeating in terms of this task: what gets created, and when.
    private var repeatHint: String? {
        guard repeatRule != "none" else { return nil }
        guard let base = reminderBase else {
            return L("先设置日期，才能定期重复。", "Set a date first to repeat this task.")
        }
        let anchor = request.task?.repeatAnchor(for: base, rule: repeatRule) ?? Dates.calendar.component(.day, from: base)
        let start = L("从 \(Dates.label(base, pattern: "M月d日")) 开始。", "Starts \(Dates.label(base, pattern: "MMM d")). ")
        guard let next = Dates.nextRepeat(base, rule: repeatRule, anchorDay: anchor, after: max(Date(), base), until: repeatUntil) else {
            return start + L("结束日期之前不会再有下一次。", "There is no next time before the end date.")
        }
        let when = Dates.label(next, pattern: "M月d日 E")
        return start + (reminderPreset == .none
            ? L("勾选完成后，会自动在 \(when) 新建下一次。", "When you complete it, the next one is created for \(when).")
            : L("勾选完成后，会自动在 \(when) 新建下一次，提醒也按同样的提前量设好。", "When you complete it, the next one is created for \(when) with the same reminder."))
    }

    // MARK: Repeat

    static let repeatPresets = ["daily", RepeatRule.workdays.text, "weekly", "monthly", "yearly"]

    /// The task's own day: the first time it happens.
    private var repeatStartDay: Date { Dates.calendar.startOfDay(for: reminderBase ?? date) }
    private var baseWeekday: Int { Dates.calendar.component(.weekday, from: repeatStartDay) }

    private var repeatText: String {
        guard repeatRule != "none" else { return L("不重复", "Never") }
        let label = Dates.repeatLabel(repeatRule)
        guard let until = repeatUntil else { return label }
        return label + L("，至 ", ", until ") + Dates.label(until, pattern: "M月d日")
    }

    /// Every n days, weeks, months or years; weekly can also pick the weekdays.
    @ViewBuilder private func customRepeatControls(_ rule: RepeatRule) -> some View {
        HStack(spacing: 10) {
            Text(L("每", "Every")).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { rule.interval }, set: { value in
                var next = rule; next.interval = min(99, max(1, value)); repeatRule = next.text
            }), in: 1...99) {
                Text("\(rule.interval)").font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 22)
            }.fixedSize()
            Picker(L("单位", "Unit"), selection: Binding(get: { rule.unit }, set: { unit in
                repeatRule = RepeatRule(interval: rule.interval, unit: unit, weekdays: unit == .week ? [baseWeekday] : []).text
            })) {
                Text(L("天", "days")).tag(RepeatRule.Unit.day)
                Text(L("周", "weeks")).tag(RepeatRule.Unit.week)
                Text(L("个月", "months")).tag(RepeatRule.Unit.month)
                Text(L("年", "years")).tag(RepeatRule.Unit.year)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
        }
        if rule.unit == .week {
            let chosen = rule.weekdays.isEmpty ? [baseWeekday] : rule.weekdays
            HStack(spacing: 6) {
                ForEach(RepeatRule.weekOrder, id: \.self) { day in
                    SelectPill(title: RepeatRule.weekdayName(day), selected: chosen.contains(day)) {
                        var days = chosen
                        if days.contains(day) { if days.count > 1 { days.remove(day) } } else { days.insert(day) }
                        repeatRule = RepeatRule(interval: rule.interval, unit: .week, weekdays: days).text
                    }
                }
            }
        }
    }

    // MARK: Earlier tasks as suggestions (new tasks only)

    private var suggestions: [TaskItem] {
        guard request.task == nil else { return [] }
        return TaskSuggestions.find(title, in: allTasks, preferredList: listID)
    }

    private var showSuggestions: Bool {
        // Not tied to the title having focus: pressing on a suggestion takes focus away from the title before the
        // click completes, which removed the list under the pointer. It goes as soon as the note or subtask field
        // has focus (by click or Tab, so Return and the arrows there are never taken), when a setting is opened,
        // a suggestion is picked or Esc closes it.
        request.task == nil && focus != .notes && !newSubtaskFocused && suggestionsClosedFor != title && !suggestions.isEmpty
    }

    private var suggestionList: some View {
        let items = suggestions
        return VStack(alignment: .leading, spacing: 2) {
            Text(L("用旧任务作模板，填入后可修改", "Use an earlier task as a template; edit before saving"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
                Button { applySuggestion(task) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(ListColor.color(task.list?.id, hex: task.list?.colorHex)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text(suggestionDetail(task)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let day = task.calendarDate {
                            Text(L("上次 ", "Last ") + Dates.label(day, pattern: "M月d日")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == min(suggestionIndex, items.count - 1) ? Color.accentColor.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { suggestionIndex = index } }
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "08:30–16:30 · 学习 / Major Research"
    private func suggestionDetail(_ task: TaskItem) -> String {
        var parts = [task.hasTime ? task.timeLabel : (task.calendarDate == nil ? L("无日期", "No date") : L("全天", "All day"))]
        if let list = task.list { parts.append(ListTree.path(list, lists: lists)) }
        return parts.joined(separator: " · ")
    }

    /// Start a new draft from an earlier task; saved history is never modified.
    /// What was already set in this draft (a time, a deadline, a reminder, a priority, notes, subtasks, a repeat)
    /// is kept; the template fills in the rest. The day stays the one being planned.
    private func applySuggestion(_ source: TaskItem) {
        let keepTime = hasDate && hasTime, keepDue = hasDue, keepReminder = reminderPreset != .none
        let keepPriority = priority != (initialDraft?.priority ?? 0)
        let template = TaskSuggestions.Template(source, day: date, scheduled: hasDate)
        title = template.title
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notes = template.notes }
        if subtasks.isEmpty { subtasks = template.subtasks }
        if let list = template.listID { listID = list }
        if !keepPriority { priority = template.priority }
        if !keepTime {
            let newDate = template.start ?? date
            // Validate the final range, with no observer applying a second time shift.
            end = template.end ?? newDate.addingTimeInterval(3600)
            date = newDate; hasDate = template.start != nil; hasTime = template.timed; hasEnd = template.end != nil
        }
        if !keepDue, let copiedDue = template.due,
           Dates.deadlineAllowed(due: copiedDue, dueTimed: template.dueTimed, scheduled: hasDate ? (effectiveEnd ?? date) : nil, scheduledTimed: hasTime) {
            hasDue = true; due = copiedDue; dueHasTime = template.dueTimed
        }
        if !keepReminder, template.reminderPreset != .none {
            // Avoid the preset observer replacing a copied custom reminder with the previous draft's reminder.
            templateReminder = template.reminderPreset == .custom ? template.reminder : nil
            reminderPreset = template.reminderPreset
            reminder = template.reminder ?? Self.defaultCustomReminder(for: template.start ?? template.due)
            // Counted from this task's own time; a moment already gone could never be saved, so it is left out.
            if let moment = effectiveReminder, moment <= Date() {
                reminderPreset = .none; templateReminder = nil
                reminderDroppedFor = template.title
            }
        }
        openPanel = nil; suggestionsClosedFor = template.title
    }

    /// Arrow keys move through the list, Return picks, Esc closes it. Anything else keeps typing.
    private func suggestionKey(_ key: UInt16) -> Bool {
        let items = suggestions
        guard !items.isEmpty else { return false }
        switch key {
        case 125: suggestionIndex = min(items.count - 1, suggestionIndex + 1)
        case 126: suggestionIndex = max(0, suggestionIndex - 1)
        case 36, 76: applySuggestion(items[min(suggestionIndex, items.count - 1)])
        case 53: suggestionsClosedFor = title
        default: return false
        }
        return true
    }

    static func defaultCustomReminder(for day: Date?) -> Date {
        let now = Date()
        guard let day, !Dates.sameDay(day, now), day > now else {
            return Dates.calendar.dateInterval(of: .hour, for: now)!.end
        }
        return Dates.calendar.date(byAdding: .hour, value: 9, to: Dates.calendar.startOfDay(for: day))!
    }

    /// First time shown when a time is switched on: the next full hour today, otherwise 9:00 —
    /// but never before `after` (the scheduled time, for a same-day deadline).
    static func defaultTime(on day: Date, after: Date? = nil) -> Date {
        let now = Date()
        var result = Dates.sameDay(day, now)
            ? Dates.calendar.dateInterval(of: .hour, for: now)!.end
            : Dates.calendar.date(byAdding: .hour, value: 9, to: Dates.calendar.startOfDay(for: day))!
        if !Dates.sameDay(result, day) { result = Dates.calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)! }
        if let after, result < after {
            // An hour after the scheduled time, but never spilling into the next day.
            let endOfDay = Dates.calendar.date(bySettingHour: 23, minute: 59, second: 0, of: after)!
            result = min(Dates.calendar.date(byAdding: .hour, value: 1, to: after)!, max(endOfDay, after))
        }
        return result
    }

    private func addSubtask() {
        let value = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.count <= 160, subtasks.count < 100 else { errorMessage = L("最多100个子任务，每项最多160个字。", "Up to 100 subtasks, with at most 160 characters each."); return }
        subtasks.append(Subtask(title: value)); newSubtask = ""
        newSubtaskFocused = true
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task { await persist(); isSaving = false }
    }

    @MainActor private func persist() async {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        keepDraft()
        if let end = effectiveEnd, end <= date { errorMessage = L("结束时间必须晚于开始时间。", "End must be after start."); return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 160, notes.count <= 10000 else {
            errorMessage = L("任务名称需为1–160个字，备注最多10000个字。", "Use 1–160 characters for the title and up to 10,000 for notes."); return
        }
        let pendingSubtask = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanSubtasks = subtasks.map { Subtask(id: $0.id, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), isDone: $0.isDone) }
        if !pendingSubtask.isEmpty { cleanSubtasks.append(Subtask(title: pendingSubtask)) }
        guard cleanSubtasks.count <= 100, cleanSubtasks.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 160 }) else {
            errorMessage = L("最多100个子任务，每项需为1–160个字。", "Up to 100 subtasks, with 1–160 characters each."); return
        }
        guard repeatRule == "none" || hasDate || hasDue else {
            errorMessage = L("重复任务需要安排日期或截止日期。", "A repeating task needs a scheduled date or deadline."); return
        }
        if repeatRule != "none", let until = repeatUntil, until < repeatStartDay {
            errorMessage = L("重复的结束日期不能早于开始日期。", "The repeat can't end before it starts."); return
        }
        guard deadlineValid else {
            errorMessage = L("截止不能早于安排的时间，请调整截止日期或时间。", "The deadline can't be before the scheduled time. Adjust the deadline."); return
        }
        let reminderAt = effectiveReminder
        if reminderPreset != .none {
            guard let reminderAt else { errorMessage = L("请选择提醒时间。", "Choose a reminder time."); return }
            if let reminderLatest, reminderAt > reminderLatest, reminderAt != request.task?.reminderAt {
                errorMessage = L("提醒不能晚于任务时间，请调整提醒。", "The reminder can't be after the task. Adjust the reminder."); return
            }
            if reminderAt <= Date() && reminderAt != request.task?.reminderAt {
                errorMessage = L("提醒时间 \(Dates.label(reminderAt, pattern: "M月d日 HH:mm")) 已经过去，请换一个提醒选项。", "The reminder time \(Dates.label(reminderAt, pattern: "M月d日 HH:mm")) has passed. Choose another option."); return
            }
            do {
                guard try await ReminderScheduler.shared.authorize() else {
                    errorMessage = L("通知未获允许。请在系统设置中开启通知，或关闭此任务的提醒后保存。", "Notifications are not allowed. Enable them in system settings, or turn off this reminder to save."); return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        let oldBase = request.task?.calendarDate
        let oldRule = request.task?.repeatRule
        let task = request.task ?? TaskItem(title: cleanTitle)
        if request.task == nil { context.insert(task) }
        task.title = cleanTitle; task.notes = notes
        task.scheduledAt = hasDate ? (hasTime ? date : Dates.calendar.startOfDay(for: date)) : nil
        task.hasTime = hasDate && hasTime
        task.endAt = effectiveEnd
        task.dueAt = hasDue ? (dueHasTime ? due : Dates.calendar.startOfDay(for: due)) : nil
        task.dueHasTime = hasDue && dueHasTime
        task.priority = priority
        task.reminderAt = reminderAt
        task.reminderKind = reminderPreset.rawValue
        task.reminderNeedsAttention = task.reminderRequiresAttention()
        task.repeatRule = repeatRule
        task.repeatUntil = repeatRule == "none" ? nil : repeatUntil.map { Dates.calendar.startOfDay(for: $0) }
        if let base = task.calendarDate, task.repeatAnchorDay == 0 || oldRule != repeatRule || oldBase.map({ !Dates.sameDay($0, base) }) == true { task.repeatAnchorDay = Dates.calendar.component(.day, from: base) }
        task.list = lists.first { $0.id == listID }
        task.subtasks = cleanSubtasks
        task.deletedAt = nil
        task.ensureNextOccurrence(in: context)
        do { try Store.save(context); ReminderScheduler.shared.refresh(context); dismiss() }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil }
    }
}

/// One line of the schedule: label on the left, the current value (or a grey "无") on the right.
private struct SettingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let systemImage: String
    let title: String
    let value: String
    let isSet: Bool
    let isOpen: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    let clear: () -> Void

    #if os(iOS)
    private let height: CGFloat = 48
    #else
    private let height: CGFloat = 36
    #endif

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).foregroundStyle(isOpen ? tint : Color.secondary).frame(width: 22)
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
                    Text(title).foregroundStyle(Color.primary)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(value).foregroundStyle(isSet ? tint : Color.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }.frame(minHeight: height).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(title + "，" + value)
                .accessibilityHint(isOpen ? L("收起", "Collapse") : L("展开设置", "Open"))
            if isSet {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 44, height: height).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L("清除", "Clear ") + title)
            } else {
                Color.clear.frame(width: 44, height: 1) // keeps every row's value lined up
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }
}

private struct SelectPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.selectedInk : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(macOS)
/// While the suggestion list is open, catches the arrow keys, Return and Esc before the text field
/// (and before the sheet's own Esc = Cancel). An input method that is still composing gets them as usual.
private struct SuggestionKeys: ViewModifier {
    let active: Bool
    let handle: (UInt16) -> Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, on in
                if on, monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                        return handle(event.keyCode) ? nil : event
                    }
                } else if !on, let installed = monitor {
                    NSEvent.removeMonitor(installed); monitor = nil
                }
            }
            .onDisappear { if let installed = monitor { NSEvent.removeMonitor(installed); monitor = nil } }
    }
}
#endif

/// Lays children out left to right, wrapping onto new rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// Time picker. iPhone: an hour wheel and a minute wheel in five-minute steps, narrow enough for two side by side
/// (the system wheel is not). macOS has no wheel, so it uses the system time field, which also takes typing.
private struct TimeWheel: View {
    @Binding var date: Date
    var body: some View {
        #if os(iOS)
        let parts = Dates.calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        // An existing time that isn't on a five-minute step stays selectable instead of being rounded away.
        let minutes = Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [minute])).sorted()
        HStack(spacing: 0) {
            Picker(L("小时", "Hour"), selection: Binding(get: { hour }, set: { set(hour: $0, minute: minute) })) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
            Text(":").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Picker(L("分钟", "Minute"), selection: Binding(get: { minute }, set: { set(hour: hour, minute: $0) })) {
                ForEach(minutes, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
        }.frame(maxWidth: .infinity).frame(height: 140)
        #else
        DatePicker(L("时间", "Time"), selection: $date, displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.stepperField).controlSize(.large)
            .frame(maxWidth: .infinity)
        #endif
    }

    private func set(hour: Int, minute: Int) {
        date = Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

/// Inline month grid used inside the editor. Days outside `earliest`…`latest` can't be chosen.
private struct DateGrid: View {
    @Binding var date: Date
    var earliest: Date? = nil
    var latest: Date? = nil
    /// False while nothing is chosen yet, so today's date doesn't look already picked.
    var highlight = true
    var onPick: () -> Void = {}
    @State private var month: Date

    init(date: Binding<Date>, earliest: Date? = nil, latest: Date? = nil, highlight: Bool = true, onPick: @escaping () -> Void = {}) {
        _date = date
        self.earliest = earliest
        self.latest = latest
        self.highlight = highlight
        self.onPick = onPick
        _month = State(initialValue: Dates.monthStart(date.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Dates.label(month, pattern: "yyyy年M月")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { month = Dates.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("上个月", "Previous month"))
                Button { month = Dates.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("下个月", "Next month"))
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, value in Text(value).font(.caption).foregroundStyle(.secondary) }
                ForEach(Dates.monthCells(month), id: \.self) { day in
                    let selected = highlight && Dates.sameDay(date, day)
                    let today = Dates.sameDay(day, Date())
                    let inMonth = Dates.calendar.isDate(day, equalTo: month, toGranularity: .month)
                    let blocked = (earliest.map { Dates.calendar.startOfDay(for: day) < Dates.calendar.startOfDay(for: $0) } ?? false)
                        || (latest.map { Dates.calendar.startOfDay(for: day) > Dates.calendar.startOfDay(for: $0) } ?? false)
                    // Only this month's days are drawn; the grid keeps their places so weekdays line up.
                    if !inMonth { Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true) } else {
                    Button { date = Dates.replacingDay(of: date, with: day); onPick() } label: {
                        Text("\(Dates.calendar.component(.day, from: day))").font(.body.monospacedDigit())
                            .foregroundStyle(selected ? Color.selectedInk : inMonth ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { if today && !selected { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1) } }
                            .opacity(blocked ? 0.3 : 1)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(blocked)
                        .accessibilityLabel(Dates.label(day)).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: date) { _, value in
            if !Dates.calendar.isDate(value, equalTo: month, toGranularity: .month) { month = Dates.monthStart(value) }
        }
    }
}

struct DateChoiceButton: View {
    @AppStorage("appLanguage") private var language = "system"
    let label: String
    @Binding var date: Date
    var onChoose: () -> Void = {}
    @State private var showingCalendar = false
    @State private var browsingDate = Date()

    var body: some View {
        Button { showingCalendar = true } label: {
            HStack(spacing: 6) { Text(label); Image(systemName: "chevron.down").font(.caption2) }.padding(.vertical, 6)
        }.buttonStyle(.borderless).accessibilityLabel(L("\(label)，打开日历选择日期", "\(label), open date picker"))
            .popover(isPresented: $showingCalendar) {
                VStack(spacing: 14) {
                    HStack {
                        Button { browsingDate = Dates.shiftMonth(browsingDate, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 32) }.accessibilityLabel(L("选择器上个月", "Previous month in date picker"))
                        Spacer(minLength: 0)
                        Picker(L("年份", "Year"), selection: Binding(get: { Dates.calendar.component(.year, from: browsingDate) }, set: { year in
                            browsingDate = Dates.calendar.date(from: DateComponents(year: year, month: Dates.calendar.component(.month, from: browsingDate), day: 1))!
                        })) {
                            let year = Dates.calendar.component(.year, from: browsingDate)
                            ForEach(min(1900, year)...max(2100, year), id: \.self) { year in Text(L(String(year) + "年", String(year))).tag(year) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                        Picker(L("月份", "Month"), selection: Binding(get: { Dates.calendar.component(.month, from: browsingDate) }, set: { month in
                            browsingDate = Dates.calendar.date(from: DateComponents(year: Dates.calendar.component(.year, from: browsingDate), month: month, day: 1))!
                        })) {
                            ForEach(1...12, id: \.self) { Text(L("\($0)月", Dates.monthName($0))).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                        Spacer(minLength: 0)
                        Button { browsingDate = Dates.shiftMonth(browsingDate, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 32) }.accessibilityLabel(L("选择器下个月", "Next month in date picker"))
                    }.buttonStyle(.borderless)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                        ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, value in Text(value).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Dates.monthCells(browsingDate), id: \.self) { day in
                            let selected = Dates.sameDay(date, day)
                            let inMonth = Dates.calendar.isDate(day, equalTo: browsingDate, toGranularity: .month)
                            if !inMonth { Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true) } else {
                            Button { choose(day) } label: {
                                Text("\(Dates.calendar.component(.day, from: day))").font(.body.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(selected ? Color.selectedInk : Color.primary)
                                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { if Dates.sameDay(day, Date()) && !selected { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1) } }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(Dates.label(day))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                            }
                            }
                }.padding(18).frame(width: 344).onAppear { browsingDate = date }
                    .environment(\.locale, UISettings.locale)
                    .environment(\.calendar, Dates.calendar)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func choose(_ day: Date) {
        date = Dates.replacingDay(of: date, with: day)
        onChoose(); showingCalendar = false
    }
}

struct ListEditor: View {
    struct DraftState: Equatable {
        let name: String
        let colorHex: String?
        let emoji: String
        let parentID: UUID?
    }
    @Environment(EditorDrafts.self) private var drafts
    private var draftState: DraftState { DraftState(name: name, colorHex: colorHex, emoji: emoji, parentID: parentID) }
    private func keepDraft() {
        guard (try? Store.recovery.requireWritable(context)) != nil else { return }
        drafts.listID = list?.id; drafts.list = draftState
    }
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var lists: [TaskList]
    let list: TaskList?
    @State private var name: String
    @State private var colorHex: String?
    @State private var emoji: String
    @FocusState private var emojiFocused: Bool
    @State private var errorMessage: String?

    @State private var parentID: UUID?
    init(list: TaskList?, parentID: UUID? = nil, draft: DraftState? = nil) {
        self.list = list; _name = State(initialValue: list?.name ?? "")
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
                    HStack {
                        Text(L("清单图标", "List icon"))
                        TextField("", text: $emoji, prompt: Text("🙂")).frame(width: 50).focused($emojiFocused)
                            .accessibilityLabel(L("清单 emoji", "List emoji"))
                            .onChange(of: emoji) { _, value in if value.count > 1 { emoji = String(value.last!) } }
                        #if os(macOS)
                        Button(L("更多表情…", "More emoji…")) { emojiFocused = true; DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) } }
                        #endif
                        if !emoji.isEmpty { Button(L("默认", "Default")) { emoji = "" } }
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
            }.formStyle(.grouped).navigationTitle(list == nil ? L("新建清单", "New list") : L("编辑清单", "Edit list"))
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
        .onAppear { keepDraft() }
        .onChange(of: draftState) { _, _ in keepDraft() }
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
        guard emoji.isEmpty || TaskList.validEmoji(emoji) else { errorMessage = L("请选择一个 emoji 作为图标，或恢复默认图标。", "Choose one emoji or use the default icon."); return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40 else { errorMessage = L("清单名称需为1–40个字。", "List names must contain 1–40 characters."); return }
        guard !lists.contains(where: { $0.id != list?.id && $0.parentID == parentID && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) else {
            errorMessage = L("已存在同名清单。", "A list with this name already exists."); return
        }
        if let list, ListTree.contains(parentID, in: list.id, lists: lists) { errorMessage = L("不能移入自己的子清单。", "Cannot move inside a descendant."); return }
        if let colorHex, lists.contains(where: { $0.id != list?.id && $0.colorHex?.uppercased() == colorHex.uppercased() }) {
            errorMessage = L("这个颜色已被其他清单使用，请选择其他颜色。", "This color is already used. Choose another color."); return
        }
        let target = list ?? TaskList(name: value)
        if list == nil { target.sortOrder = (lists.filter { $0.parentID == parentID }.map(\.sortOrder).max() ?? -1) + 1 }
        if list == nil { context.insert(target) }
        target.name = value; target.parentID = parentID; target.colorHex = colorHex; target.emoji = emoji.isEmpty ? nil : emoji
        do { try Store.save(context); ReminderScheduler.shared.refresh(context); dismiss() }
        catch { errorMessage = Store.recovery.failure == nil ? error.localizedDescription : nil }
    }
}
