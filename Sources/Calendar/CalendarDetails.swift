import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    var calendarSearchResults: some View {
        let results = TaskItem.ordered(tasks.filter { CalendarTaskSearch.matches($0, query: search) && filter.matches($0, lists: lists, today: currentDay) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("全部任务", "All tasks")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(L("\(results.count) 项", "\(results.count) tasks")).font(.caption).foregroundStyle(.secondary)
            }
            if results.isEmpty { ContentUnavailableView(L("没有找到任务", "No tasks found"), systemImage: "magnifyingglass", description: Text(L("试试其他关键词。", "Try another keyword."))) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { task in
                            Button { locate(task) } label: {
                                HStack(spacing: 10) {
                                    if let list = task.list { Text(list.emoji ?? "").frame(width: list.emoji == nil ? 0 : 22) }
                                    Circle().fill(planColor(task)).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 4) { Text(task.title).fontWeight(task.priority == 2 && !task.isDone ? .bold : .regular).strikethrough(task.isDone); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
                                        Text([task.calendarDate.map { Dates.label($0, pattern: "yyyy年M月d日") } ?? L("无日期", "Undated"), task.timeLabel, task.calendarList.map { ListTree.path($0, lists: lists) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward").foregroundStyle(.secondary)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    func locate(_ task: TaskItem) {
        search = ""
        locatedTask = task.id; locateRequest = UUID()
        if task.isDone { showPlanningCompleted = true }
        if let date = task.calendarDate {
            let currentDays = planningView == "month" ? Dates.monthCells(selectedDate).filter { Dates.calendar.isDate($0, equalTo: selectedDate, toGranularity: .month) } : Dates.weekCells(selectedDate)
            selectedDate = currentDays.first(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) ?? date
        } else { editor = EditorRequest(task: task) }
    }

    /// Closes the card first; a sheet can't be presented while a popover is still going away.
    private func afterDetail(_ presentation: CalendarPresentation, _ action: @escaping () -> Void) {
        presentation.close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            action()
        }
    }

    private func toggleSubtask(_ task: TaskItem, _ id: UUID) {
        _ = commit {
            var updated = task.subtasks
            if let index = updated.firstIndex(where: { $0.id == id }) { updated[index].isDone.toggle(); task.subtasks = updated }
        }
    }

    @ViewBuilder func taskDetail(_ task: TaskItem, presentation: CalendarPresentation) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task, presentation: presentation) }
        else { savedTaskDetail(task, presentation: presentation) }
    }

    private func repeatPreviewDetail(_ task: TaskItem, presentation: CalendarPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("重复安排预览", "Repeat preview"), systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
            Text(task.title).font(.headline)
            Text(task.calendarDate.map { Dates.label($0) } ?? "").font(.caption)
            taskMetadata(task)
            Text(L("完成当前任务后才会生成下一次；预览不会单独提醒。", "The next task is created when the current one is completed. Previews don't send notifications.")).font(.caption).foregroundStyle(.secondary)
            Button(L("查看原任务", "Open original task")) {
                presentation.day = nil
                if let original = tasks.first(where: { $0.id == task.previewSourceID }) {
                    afterDetail(presentation) { editor = EditorRequest(task: original) }
                }
            }.buttonStyle(.borderless)
        }.padding(16)
        #if os(macOS)
        .frame(width: 290)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    private func savedTaskDetail(_ task: TaskItem, presentation: CalendarPresentation) -> some View {
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Button { toggleCompletion(task) } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(task.isDone ? L("恢复为未完成", "Mark incomplete") : L("标记为已完成", "Mark complete"))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(task.title).font(.headline).strikethrough(task.isDone)
                                .foregroundStyle(task.isDone ? .secondary : .primary)
                            Spacer(minLength: 0)
                            PriorityTag(priority: task.priority, isDone: task.isDone)
                        }
                        taskMetadata(task)
                    }.padding(.top, 11)
                }
                if !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Label(L("子任务 \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)",
                                "Subtasks \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)"), systemImage: "checklist")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(task.subtasks) { subtask in
                            Button { toggleSubtask(task, subtask.id) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                                    Text(subtask.title).strikethrough(subtask.isDone).foregroundStyle(subtask.isDone ? .secondary : .primary)
                                        .multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    if presentation.inlineDelete == task.id {
                        Text(L("删除这项任务？", "Delete this task?")).font(.callout.weight(.medium))
                        Spacer()
                        Button(L("取消", "Cancel")) { presentation.inlineDelete = nil }.keyboardShortcut(.cancelAction)
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = nil; presentation.taskKey = nil; deleteTask(task) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("编辑", "Edit")) { afterDetail(presentation) { editor = EditorRequest(task: task) } }
                            .buttonStyle(CardButtonStyle(prominent: true, minHeight: Self.detailButtonHeight))
                        // Copying places the task on a week day, so the month view leaves it out.
                        if !(selection == .calendar && planningView == "month") {
                            Button { afterDetail(presentation) { copyTask(task) } } label: { Label(L("复制", "Copy"), systemImage: "doc.on.doc") }
                        }
                        Spacer()
                        #if os(iOS)
                        Button(L("删除", "Delete"), role: .destructive) { afterDetail(presentation) { confirmingDelete = task.id } }
                        #else
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = task.id }
                        #endif
                    }
                }.buttonStyle(CardButtonStyle(minHeight: Self.detailButtonHeight))
                .onDisappear { if presentation.inlineDelete == task.id { presentation.inlineDelete = nil } }
            }.padding(16)
        }
        #if os(macOS)
        .frame(width: 300).frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }
}

extension ContentView {
    private func savedDayTaskRow(_ task: TaskItem, presentation: CalendarPresentation) -> some View {
        let expanded = presentation.expandedTask == task.id
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { toggleCompletion(task) } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isDone ? Color.accentColor : .secondary).frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel((task.isDone ? L("恢复未完成：", "Reopen: ") : L("完成：", "Complete: ")) + task.title)
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { presentation.expandedTask = expanded ? nil : task.id } } label: {
                    HStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 1).fill(planColor(task)).frame(width: 3, height: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                PriorityTag(priority: task.priority, isDone: task.isDone)
                            }
                            let meta = [task.timeLabel, task.subtasks.isEmpty ? "" : L("子任务 \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)", "Subtasks \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)"), note.isEmpty ? "" : L("有备注", "Note")].filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint(expanded ? L("收起详情", "Hide details") : L("展开备注和子任务", "Show note and subtasks"))
            }
            // Finished tasks step back so the open ones read first.
            .opacity(task.isDone && !expanded ? 0.6 : 1)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !note.isEmpty {
                        Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(task.subtasks) { subtask in
                        Button { toggleSubtask(task, subtask.id) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                                Text(subtask.title).strikethrough(subtask.isDone).foregroundStyle(subtask.isDone ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 8) {
                        Button(L("编辑", "Edit")) { presentation.day = nil; afterDetail(presentation) { editor = EditorRequest(task: task) } }
                            .buttonStyle(CardButtonStyle(prominent: true, minHeight: Self.detailButtonHeight))
                        if planningView != "month" {
                            Button { afterDetail(presentation) { copyTask(task) } } label: { Label(L("复制", "Copy"), systemImage: "doc.on.doc") }
                                .buttonStyle(CardButtonStyle(minHeight: Self.detailButtonHeight))
                        }
                    }
                }.padding(.leading, 42).padding(.bottom, 8)
            }
        }
    }

    /// Mac chips open the task card; on a phone the whole cell opens that week instead.

    /// Buttons in the calendar cards: a comfortable mouse target on Mac, a full touch target on a phone.
    #if os(iOS)
    static let detailButtonHeight: CGFloat = 44
    #else
    static let detailButtonHeight: CGFloat = 28
    #endif
}

/// "高" / "中" beside a title in the calendar cards; nothing for normal priority or finished tasks.
private struct PriorityTag: View {
    let priority: Int
    let isDone: Bool

    var body: some View {
        if priority > 0, !isDone {
            Text(priority == 2 ? L("高", "High") : L("中", "Medium"))
                .tagStyle(priority == 2 ? .red : .orange)
                .accessibilityLabel(priority == 2 ? L("高优先级", "High priority") : L("中优先级", "Medium priority"))
        }
    }
}

struct RepeatPreviewStyle: ViewModifier {
    let isPreview: Bool
    func body(content: Content) -> some View {
        content.opacity(isPreview ? 0.65 : 1)
            .overlay {
                if isPreview { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.7, dash: [3, 2])).allowsHitTesting(false) }
            }
            .accessibilityHint(isPreview ? L("重复安排预览，点击查看原任务", "Repeat preview; open for the original task") : "")
    }
}

extension ContentView {
    func dayTasks(_ day: Date, items all: [TaskItem], presentation: CalendarPresentation) -> some View {
        let range = Dates.calendar.dateInterval(of: .day, for: day)!
        let matching = all.filter { $0.overlaps(range) }
        let items = TaskItem.ordered(matching, incompleteFirst: planningView == "month")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(Dates.label(day)).font(.headline)
                if Dates.sameDay(day, currentDay) { Text(L("今天", "Today")).tagStyle(.accentColor) }
                Text(L("\(items.count) 项", "\(items.count)")).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
                Button { presentation.day = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel(L("关闭", "Close"))
            }
            HStack(spacing: 8) {
                if planningView != "week" {
                    Button(L("查看这一周", "Open this week")) { openPlan(day, presentation: presentation, view: "week") }.frame(minHeight: 44)
                }
                Button(L("在列表中查看", "Open in list")) { openPlan(day, presentation: presentation, view: "list") }
            }.buttonStyle(CardButtonStyle(minHeight: Self.detailButtonHeight))
            // A scroll view keeps whatever height it first got, so unfolding a row used to leave the note and
            // subtasks hidden below the edge. It now takes the rows' own height, up to 360, and scrolls beyond that.
            ScrollView {
                #if os(macOS)
                VStack(spacing: 0) { dayTaskRows(items, presentation: presentation) }
                .onGeometryChange(for: CGFloat.self) { min(360, max(44, ceil($0.size.height))) } action: {
                    presentation.updateRowsHeight($0, for: day)
                }
                #else
                LazyVStack(spacing: 0) { dayTaskRows(items, presentation: presentation) }
                #endif
            }
            #if os(macOS)
            .frame(height: presentation.rowsHeight)
            #else
            .frame(maxHeight: .infinity, alignment: .top)
            #endif
            Button { presentation.day = nil; afterDetail(presentation) { editor = EditorRequest(date: day) } } label: {
                Label(L("添加任务", "Add task"), systemImage: "plus").font(.callout.weight(.semibold)).frame(minHeight: 44)
            }.buttonStyle(.borderless).foregroundStyle(Color.accentColor)
        }.padding(16)
        #if os(macOS)
        .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        #else
        .padding(.top, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    @ViewBuilder private func dayTaskRows(_ items: [TaskItem], presentation: CalendarPresentation) -> some View {
        if items.isEmpty { Text(L("这一天还没有任务", "Nothing on this day")).foregroundStyle(.secondary).padding(.vertical, 12) }
        ForEach(items) { task in
            VStack(spacing: 0) {
                dayTaskRow(task, presentation: presentation)
                Divider().padding(.leading, 50)
            }
        }
    }

    /// Leaves the popover and shows that day in another view; the month stays where it was if the user comes back.
    private func openPlan(_ day: Date, presentation: CalendarPresentation, view: String) {
        presentation.day = nil
        slideForward = true
        selectedDate = day; wholeMonth = false
        planningView = view
    }

    /// A row in the day popover. Tapping it unfolds the note and subtasks in place, so nothing is hidden behind "edit".
    @ViewBuilder private func dayTaskRow(_ task: TaskItem, presentation: CalendarPresentation) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task, presentation: presentation) }
        else { savedDayTaskRow(task, presentation: presentation) }
    }
}
