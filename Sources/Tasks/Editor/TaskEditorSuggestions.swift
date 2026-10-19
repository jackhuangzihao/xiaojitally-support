import SwiftUI
import SwiftData

extension TaskEditor {
    var suggestions: [TaskItem] {
        guard request.task == nil else { return [] }
        return TaskSuggestions.find(title, in: allTasks, preferredList: listID)
    }

    var showSuggestions: Bool {
        // Not tied to the title having focus: pressing on a suggestion takes focus away from the title before the
        // click completes, which removed the list under the pointer. It goes as soon as the note or subtask field
        // has focus (by click or Tab, so Return and the arrows there are never taken), when a setting is opened,
        // a suggestion is picked or Esc closes it.
        request.task == nil && focus != .notes && !newSubtaskFocused && suggestionsClosedFor != title && !suggestions.isEmpty
    }

    var suggestionList: some View {
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
            startClockIntent = ClockIntent(newDate)
        }
        if !keepDue, let copiedDue = template.due,
           Dates.deadlineAllowed(due: copiedDue, dueTimed: template.dueTimed, scheduled: hasDate ? (effectiveEnd ?? date) : nil, scheduledTimed: hasTime) {
            hasDue = true; due = copiedDue; dueHasTime = template.dueTimed
            dueClockIntent = ClockIntent(copiedDue)
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
    func suggestionKey(_ key: UInt16) -> Bool {
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

}
