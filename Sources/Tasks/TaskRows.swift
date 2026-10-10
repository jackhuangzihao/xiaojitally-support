import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

extension ContentView {
    func taskRowBody(_ task: TaskItem) -> some View {
        DayTimelineCard(task: task, compact: isPhone, showTime: true,
                        onRestore: selection == .trash ? { _ = commit { task.deletedAt = nil } } : nil,
                        onComplete: { toggleCompletion(task) },
                        onEdit: { editor = EditorRequest(task: task) },
                        onCopy: { copyTask(task) },
                        onDelete: {
                            if selection == .trash { purgeIDs = [task.id] }
                            else { confirmingDelete = task.id }
                        },
                        onRemindNow: { remindNow(task) },
                        onToggleSubtask: { id in
                            _ = commit {
                                var updated = task.subtasks
                                if let index = updated.firstIndex(where: { $0.id == id }) {
                                    updated[index].isDone.toggle(); task.subtasks = updated
                                }
                            }
                        },
                        money: taskMoney.summary(for: task.id), moneyCurrency: taskMoney.baseCurrency)
    }

    func taskMetadata(_ task: TaskItem) -> some View {
        TimelineView(.everyMinute) { clock in taskMetadata(task, now: clock.date) }
    }

    func taskMetadata(_ task: TaskItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            if task.clockDate != nil { Text(task.timeLabel) }
            if let list = task.calendarList {
                ColoredListLabel(name: list.name, id: list.id, colorHex: list.colorHex, emoji: list.emoji).labelStyle(CompactTagLabelStyle())
                    .foregroundStyle(ListColor.color(list.id, hex: list.colorHex))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(ListColor.color(list.id, hex: list.colorHex).opacity(0.12), in: Capsule())
            }
            if task.isDone { Text(L("已完成", "Completed")) }
          }
          if task.repeatRule != "none" { Label(Dates.repeatLabel(task.repeatRule), systemImage: "repeat") }
          if let warning = task.reminderWarning { Label(warning, systemImage: "bell.badge").foregroundStyle(.orange) }
          if let reminder = task.reminderAt, !task.isDone, task.reminderWarning == nil { Label(Dates.label(reminder, pattern: "M月d日 HH:mm"), systemImage: "bell") }
          if let due = task.dueAt {
              if let countdown = task.deadlineCountdown(now: now) {
                  Label(countdown.text(due: due, timed: task.dueHasTime), systemImage: "hourglass").foregroundStyle(countdown.color)
              } else {
                  let when = Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日")
                  Text(L("截止 \(when)", "Due \(when)"))
              }
          }
        }.font(.caption).foregroundStyle(.secondary)
    }

    /// The task being dragged. There is no callback when a drag is cancelled, so an old record
    /// (over a minute) is ignored rather than colouring a later, unrelated drop.
    var draggingTask: TaskItem? {
        guard let id = dragFeedback.draggedID else { return nil }
        return tasks.first { $0.id == id }
    }

    func overdueSection(_ items: [TaskItem]) -> some View {
        DisclosureGroup(isExpanded: isPhone ? $phoneOverdueExpanded : $overdueExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAllEarlier ? items : Array(items.prefix(3))) { task in overdueRow(task) }
                if items.count > 3 {
                    Button(showAllEarlier ? L("收起", "Show less") : L("查看其余 \(items.count - 3) 项", "Show \(items.count - 3) more")) { showAllEarlier.toggle() }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                }
            }.padding(.top, 4)
        } label: {
            Label(L("此前未完成 · \(items.count) 项", "Earlier unfinished · \(items.count)"), systemImage: "exclamationmark.circle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    #if os(iOS)
    /// Separate native rows animate their insertion without resizing one large list cell.
    @ViewBuilder var phoneOverdueRows: some View {
        let items = overdueTasks
        if !items.isEmpty {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { phoneOverdueExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(L("此前未完成 · \(items.count) 项", "Earlier unfinished · \(items.count)"), systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(phoneOverdueExpanded ? 90 : 0))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }.foregroundStyle(Color.accentColor).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(phoneOverdueExpanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
            if phoneOverdueExpanded {
                ForEach(showAllEarlier ? items : Array(items.prefix(3))) { task in overdueRow(task) }
                if items.count > 3 {
                    Button(showAllEarlier ? L("收起", "Show less") : L("查看其余 \(items.count - 3) 项", "Show \(items.count - 3) more")) {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { showAllEarlier.toggle() }
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
        }
    }
    #endif

    private func overdueRow(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { toggleCompletion(task) } label: {
                Image(systemName: "circle").foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(L("完成", "Complete") + "：" + task.title)
            Button { editor = EditorRequest(task: task) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(Color.primary)
                    TimelineView(.everyMinute) { clock in overdueDetail(task, now: clock.date).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(L("移到今天", "Move to today")) { requestMove(task, to: currentDay, kind: .day) }
                .buttonStyle(.borderless).font(.caption).padding(.top, 9)
            }
            .modifier(TaskDragSource(task: task))
    }

    /// "原定 9月10日 · 已逾期 7 天", or with a future deadline "原定 9月10日 · 截止 9月30日 · 还剩 13 天".
    private func overdueDetail(_ task: TaskItem, now: Date) -> Text {
        var parts: [String] = []
        if let scheduled = task.scheduledAt { parts.append(L("原定 ", "Planned ") + Dates.label(scheduled, pattern: "M月d日")) }
        if let due = task.dueAt, let countdown = task.deadlineCountdown(now: now) {
            parts.append(countdown.text(due: due, timed: task.dueHasTime))
            return Text(parts.joined(separator: " · ")).foregroundStyle(countdown.color)
        }
        if let day = task.calendarDate {
            let days = Dates.calendar.dateComponents([.day], from: Dates.calendar.startOfDay(for: day), to: Dates.calendar.startOfDay(for: currentDay)).day ?? 0
            parts.append(L("逾期 \(days) 天", "\(days) \(days == 1 ? "day" : "days") overdue"))
        }
        return Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
    }

    // MARK: Day timeline

}

private struct CompactTagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
