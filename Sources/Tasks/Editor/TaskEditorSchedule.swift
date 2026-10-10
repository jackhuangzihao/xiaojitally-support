import SwiftUI
import SwiftData

extension TaskEditor {
    var scheduleRows: some View {
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

    var warnings: [String] {
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

    func toggle(_ panel: Panel) {
        focus = nil; newSubtaskFocused = false
        openPanel = openPanel == panel ? nil : panel
        // Setting the date, time and so on: the typing is done, the suggestions step aside.
        suggestionsClosedFor = title
    }

    private func close(_ panels: Panel...) {
        if let openPanel, panels.contains(openPanel) { self.openPanel = nil }
    }

    /// The moment relative reminders count from: the scheduled date, or the deadline when there is none.
    var reminderBase: Date? {
        if hasDate { return hasTime ? date : Dates.calendar.startOfDay(for: date) }
        guard hasDue else { return nil }
        return dueHasTime ? due : Dates.calendar.startOfDay(for: due)
    }
    var reminderTimed: Bool { hasDate ? hasTime : hasDue && dueHasTime }
    var reminderOptions: [ReminderPreset] { ReminderPreset.options(base: reminderBase, timed: reminderTimed) }
    var reminderLatest: Date? { ReminderPreset.latest(base: reminderBase, timed: reminderTimed) }

    var effectiveReminder: Date? {
        reminderPreset == .custom ? reminder : reminderPreset.date(base: reminderBase, timed: reminderTimed)
    }

    func rememberRelativeReminder() {
        if let value = reminderPreset.date(base: reminderBase, timed: reminderTimed) { lastRelativeReminder = value }
    }

    private var dueCountdown: DeadlineCountdown {
        DeadlineCountdown(due: dueHasTime ? due : Dates.calendar.startOfDay(for: due), timed: dueHasTime, now: clockNow)
    }

    private var dueEarliest: Date? {
        guard hasDate else { return nil }
        return hasTime ? (effectiveEnd ?? date) : Dates.calendar.startOfDay(for: date)
    }

    var deadlineValid: Bool {
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

    static func isCustomRepeat(_ rule: String?) -> Bool {
        guard let rule, rule != "none" else { return false }
        return !repeatPresets.contains(rule)
    }

    /// The task's own day: the first time it happens.
    var repeatStartDay: Date { Dates.calendar.startOfDay(for: reminderBase ?? date) }
    private var baseWeekday: Int { Dates.calendar.component(.weekday, from: repeatStartDay) }

    private var repeatText: String {
        guard repeatRule != "none" else { return L("不重复", "Never") }
        let label = Dates.repeatLabel(repeatRule)
        guard let until = repeatUntil else { return label }
        return label + L("，至 ", ", until ") + Dates.label(until, pattern: "M月d日")
    }

    /// Every n days, weeks, months or years; weekly can also pick the weekdays.
    @ViewBuilder private func customRepeatControls(_ rule: RepeatRule) -> some View {
        CustomRepeatControls(rule: rule, baseWeekday: baseWeekday) { repeatRule = $0 }
    }

    // MARK: Earlier tasks as suggestions (new tasks only)

}
