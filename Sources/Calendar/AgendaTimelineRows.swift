import SwiftUI

struct DayAgendaRowLayout {
    let timed: Bool
    var gap: Int? = nil
    var overlap: String? = nil
}

/// The window owns mutations; these rows only arrange the supplied tasks and callbacks.
struct DayAgendaRows<Row: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let items: [TaskItem]
    let occupying: [TaskItem]
    let selectedDate: Date
    let isPhone: Bool
    let showDayFreeTime: Bool
    @Binding var dayCompletedExpanded: Bool
    let addTask: () -> Void
    @ViewBuilder let row: (TaskItem, DayAgendaRowLayout) -> Row

    /// Individual rows are retained by iOS List and Mac LazyVStack. Detail expansion belongs
    /// to DayTimelineCard, so opening notes does not recompute the calendar or schedule.
    var body: some View {
        let active = items.filter { !$0.isDone }
        let pending = active.filter { $0.clockDate == nil }
        let completed = items.filter(\.isDone)
        let schedule = DaySchedule(active, day: selectedDate, occupying: occupying)
        let timed = schedule.clusters.flatMap { $0 }
        let gaps = Dictionary(uniqueKeysWithValues: schedule.clusters.enumerated().compactMap { index, cluster -> (UUID, Int)? in
            guard let first = cluster.first, let gap = schedule.gaps[index] else { return nil }
            return (first.id, gap)
        })
        let overlaps = Dictionary(uniqueKeysWithValues: schedule.clusters.compactMap { cluster -> (UUID, String)? in
            guard cluster.count > 1, let first = cluster.first else { return nil }
            return (first.id, overlapLabel(cluster, day: selectedDate))
        })
        return Group {
            ForEach(timed) { task in
                row(task, DayAgendaRowLayout(timed: true,
                                             gap: showDayFreeTime ? gaps[task.id] : nil, overlap: overlaps[task.id]))
            }
            if !pending.isEmpty {
                Text(L("时间待定 · \(pending.count)", "Time to be set · \(pending.count)"))
                    .font(.caption).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 10)
                ForEach(pending) { task in row(task, DayAgendaRowLayout(timed: false)) }
            }
            if active.isEmpty {
                ContentUnavailableView {
                    Label(items.isEmpty ? L("留给你安排", "Room for your plans") : L("当天任务已完成", "All done for this day"),
                          systemImage: items.isEmpty ? "sun.max" : "checkmark.circle")
                } description: {
                    Text(items.isEmpty ? L("添加一件想做的事，慢慢完成。", "Add something you want to do.") : L("已完成的任务收在下方，随时可以查看。", "You can review completed tasks below."))
                } actions: {
                    if isPhone && items.isEmpty && occupying.isEmpty {
                        Button(action: addTask) {
                            Label(L("添加第一个任务", "Add your first task"), systemImage: "plus").frame(minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if !completed.isEmpty {
                DisclosureGroup(isExpanded: $dayCompletedExpanded) {
                    ForEach(completed) { task in row(task, DayAgendaRowLayout(timed: task.clockDate != nil)) }
                } label: {
                    Label(L("已完成 · \(completed.count)", "Completed · \(completed.count)"), systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary).frame(minHeight: 44)
                }.padding(.top, 6)
            }
            if !isPhone {
                Button(action: addTask) {
                    Label(L("添加任务", "Add task"), systemImage: "plus").frame(minHeight: 44)
                }.buttonStyle(.borderless)
            }
        }
    }

    private func overlapLabel(_ items: [TaskItem], day: Date) -> String {
        let title = L("\(items.count) 项时间重叠", "\(items.count) overlap")
        guard let span = DaySchedule.span(items, day: day) else { return title }
        let end = span.end == 1440 ? "24:00" : CalendarGridStyle.clockLabel(span.end)
        let range = CalendarGridStyle.clockLabel(span.start) + "–" + end
        let duration = Dates.durationLabel(minutes: span.end - span.start)
        return title + " · " + range + L(" · 共占用 \(duration)", " · \(duration) total")
    }
}

struct MonthAgendaRows<Row: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let groups: [(date: Date, tasks: [TaskItem])]
    let isEmpty: Bool
    let currentDay: Date
    @ViewBuilder let row: (TaskItem) -> Row

    @ViewBuilder var body: some View {
        if isEmpty {
            ContentUnavailableView(L("本月暂无安排", "No plans this month"), systemImage: "calendar")
        }
        ForEach(groups, id: \.date) { group in
            Section {
                ForEach(group.tasks) { task in row(task) }
            } header: {
                HStack {
                    Text(Dates.groupLabel(group.date, today: currentDay))
                    Spacer()
                    Text(L("\(group.tasks.count) 项", "\(group.tasks.count) tasks"))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
    }
}

/// A single List row contains its time rail, gap/overlap labels and task card.
struct AgendaTaskLayout<Content: View>: View {
    @AppStorage("appLanguage") private var language = "system"
    let task: TaskItem
    let selectedDate: Date
    let timed: Bool
    let dayTimeWidth: CGFloat
    let accessiblePhone: Bool
    let gap: Int?
    let overlap: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = accessiblePhone
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        // Exactly one List row per task, even when free-time/overlap labels are shown.
        // Variable row counts make List eagerly construct offscreen task content.
        return VStack(alignment: .leading, spacing: 10) {
            if let gap { freeRow(gap) }
            if let overlap {
                Label(overlap, systemImage: "arrow.triangle.merge")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, min(dayTimeWidth, 78) + 16)
            }
            layout {
                if timed, let clock = task.clockDate {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Dates.sameDay(clock, selectedDate) ? Dates.label(clock, pattern: "HH:mm") : "00:00")
                            .font(.callout.weight(.medium))
                        if let end = task.endAt {
                            Text(Dates.sameDay(end, selectedDate) ? Dates.label(end, pattern: "HH:mm") : "24:00")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(task.scheduledAt == nil ? L("截止", "Due") : L("开始", "Start"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !Dates.sameDay(clock, selectedDate) {
                            Text(L("续前日", "Continued")).font(.caption2).foregroundStyle(.secondary)
                        } else if let end = task.endAt, !Dates.sameDay(end, selectedDate), Dates.calendar.startOfDay(for: end) < end {
                            Text(L("跨日", "Overnight")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: accessiblePhone ? nil : min(dayTimeWidth, 78), alignment: .trailing)
                        .padding(.top, accessiblePhone ? 0 : 14)
                        .accessibilityElement(children: .ignore).accessibilityLabel(task.timeLabel)
                }
                content()
            }
        }
    }

    /// Align free-time summaries with the cards rather than the time rail.
    private func freeRow(_ minutes: Int) -> some View {
        Text(L("空闲 ", "Free ") + Dates.durationLabel(minutes: minutes)).font(.caption).foregroundStyle(.tertiary)
            .padding(.leading, min(dayTimeWidth, 78) + 16).padding(.vertical, 4)
    }
}
