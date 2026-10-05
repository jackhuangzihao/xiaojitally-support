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
        weekDrag.releaseHeldScroll()
        search = ""; presentation.taskKey = nil
        locatedTask = task.id; locateRequest = UUID()
        if task.isDone { showPlanningCompleted = true }
        if let date = task.calendarDate {
            let currentDays = planningView == "month" ? Dates.monthCells(selectedDate).filter { Dates.calendar.isDate($0, equalTo: selectedDate, toGranularity: .month) } : Dates.weekCells(selectedDate)
            selectedDate = currentDays.first(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) ?? date
        } else { editor = EditorRequest(task: task) }
    }
    func locatedMinute(days: [Date]) -> Int? {
        guard let id = locatedTask, let task = tasks.first(where: { $0.id == id }), let clock = task.clockDate,
              days.contains(where: { task.appearsInCalendar(on: $0, wholeMonth: false) }) else { return nil }
        let minute = Dates.sameDay(clock, selectedDate) ? minuteOfDay(clock) : 0
        return max(0, min(1380, minute / 60 * 60 - 60))
    }
    func visiblePlanItems(_ items: [TaskItem], count: Int) -> [TaskItem] {
        var shown = Array(items.prefix(count))
        if count > 0, let target = items.first(where: { $0.id == locatedTask }), !shown.contains(where: { $0.id == target.id }) {
            shown[shown.count - 1] = target
        }
        return shown
    }

    func detailID(_ task: TaskItem, day: Date, allDay: Bool = false) -> String {
        "\(task.id.uuidString)|\(Int(Dates.calendar.startOfDay(for: day).timeIntervalSince1970))|\(allDay)"
    }

    /// Closes the card first; a sheet can't be presented while a popover is still going away.
    func afterDetail(_ action: @escaping () -> Void) {
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

    @ViewBuilder func taskDetail(_ task: TaskItem) -> some View {
        if task.previewSourceID != nil { repeatPreviewDetail(task) }
        else { savedTaskDetail(task) }
    }

    func repeatPreviewDetail(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("重复安排预览", "Repeat preview"), systemImage: "repeat").font(.caption).foregroundStyle(.secondary)
            Text(task.title).font(.headline)
            Text(task.calendarDate.map { Dates.label($0) } ?? "").font(.caption)
            taskMetadata(task)
            Text(L("完成当前任务后才会生成下一次；预览不会单独提醒。", "The next task is created when the current one is completed. Previews don't send notifications.")).font(.caption).foregroundStyle(.secondary)
            Button(L("查看原任务", "Open original task")) {
                presentation.day = nil
                if let original = tasks.first(where: { $0.id == task.previewSourceID }) {
                    afterDetail { editor = EditorRequest(task: original) }
                }
            }.buttonStyle(.borderless)
        }.padding(16)
        #if os(macOS)
        .frame(width: 290)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    private func savedTaskDetail(_ task: TaskItem) -> some View {
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title).font(.headline).strikethrough(task.isDone)
                        taskMetadata(task)
                    }
                }
                if !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.subtasks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
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
                if !(selection == .calendar && planningView == "month") {
                    Button { afterDetail { copyTask(task) } } label: {
                        Label(L("复制", "Copy"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 16) {
                    if presentation.inlineDelete == task.id {
                        Text(L("删除这项任务？", "Delete this task?")).font(.callout.weight(.medium))
                        Spacer()
                        Button(L("取消", "Cancel")) { presentation.inlineDelete = nil }.keyboardShortcut(.cancelAction)
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = nil; presentation.taskKey = nil; deleteTask(task) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("编辑", "Edit")) { afterDetail { editor = EditorRequest(task: task) } }
                            .frame(minHeight: 44)
                        Spacer()
                        #if os(iOS)
                        Button(L("删除", "Delete"), role: .destructive) { afterDetail { confirmingDelete = task.id } }.frame(minHeight: 44)
                        #else
                        Button(L("删除", "Delete"), role: .destructive) { presentation.inlineDelete = task.id }
                        #endif
                    }
                }.buttonStyle(.borderless)
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

    // MARK: Month

}

extension ContentView {
    func savedDayTaskRow(_ task: TaskItem) -> some View {
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
                            Text(task.title).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary)
                                .multilineTextAlignment(.leading)
                            let meta = [task.timeLabel, task.subtasks.isEmpty ? "" : L("子任务 \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)", "Subtasks \(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)"), note.isEmpty ? "" : L("有备注", "Note")].filter { !$0.isEmpty }
                            if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityHint(expanded ? L("收起详情", "Hide details") : L("展开备注和子任务", "Show note and subtasks"))
            }
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
                    Button(L("编辑", "Edit")) { presentation.day = nil; afterDetail { editor = EditorRequest(task: task) } }
                        .buttonStyle(.borderless)
                    if planningView != "month" {
                        Button { afterDetail { copyTask(task) } } label: {
                            Label(L("复制", "Copy"), systemImage: "doc.on.doc").frame(minHeight: 44)
                        }.buttonStyle(.borderless)
                    }
                }.padding(.leading, 42).padding(.bottom, 8)
            }
        }
    }

    /// Mac chips open the task card; on a phone the whole cell opens that week instead.
    @ViewBuilder func monthChip(_ task: TaskItem, day: Date, height: CGFloat) -> some View {
        let color = planColor(task)
        #if os(macOS)
        let prefix = task.clockDate.map { Dates.sameDay($0, day) ? Dates.label($0, pattern: "HH:mm") + " " : L("续 ", "↳ ") } ?? ""
        #else
        let prefix = ""
        #endif
        let chip = HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2)
            Text(prefix + (task.previewSourceID == nil ? "" : "↻ ") + task.title).font(.caption2.weight(task.priority == 2 && !task.isDone ? .bold : .regular)).lineLimit(1).strikethrough(task.isDone)
            Spacer(minLength: 0)
            CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
        }.frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(task.isDone ? 0.05 : 0.14), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
        #if os(macOS)
        let key = detailID(task, day: day, allDay: true)
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .help([task.title, task.calendarList.map { ListTree.path($0, lists: lists) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(prefix + task.title + (task.priority == 2 ? L("，高优先级", ", high priority") : task.priority == 1 ? L("，中优先级", ", medium priority") : ""))
            .accessibilityAction { presentation.showTask(key) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { taskDetail(task) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 0 }, month: selectedDate, drop: monthDrop))
        #else
        chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .overlay { if locatedTask == task.id { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .allowsHitTesting(false)
        #endif
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
