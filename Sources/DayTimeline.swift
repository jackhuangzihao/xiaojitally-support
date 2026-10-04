import SwiftUI

/// Expansion belongs to one card, so opening notes does not rebuild the calendar.
struct DayTimelineCard: View {
    let task: TaskItem
    let compact: Bool
    var showTime = false
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRemindNow: () -> Void
    let onToggleSubtask: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var expanded = false
    @State private var detailsLoaded = false
    @State private var detailHeight: CGFloat = 0

    private var tint: Color {
        ListColor.color(task.calendarList?.id, hex: task.calendarList?.colorHex)
    }
    private var hasNotes: Bool { !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var controlSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Button(action: onComplete) {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((task.isDone ? L("恢复为未完成", "Mark incomplete") : L("完成", "Complete")) + "：" + task.title)

                Button {
                    detailsLoaded = true
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { expanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(task.title)
                                .font(.body.weight(.medium))
                                .strikethrough(task.isDone)
                                .foregroundStyle(task.isDone ? .secondary : .primary)
                                .lineLimit(expanded || dynamicTypeSize.isAccessibilitySize ? nil : 3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .accessibilityHidden(true)
                        }
                        if showTime, task.clockDate != nil {
                            Text(task.timeLabel).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) { category; duration }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { category; duration }
                                VStack(alignment: .leading, spacing: 4) { category; duration }
                            }
                        }
                        if hasNotes || !task.subtasks.isEmpty {
                            Group {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 4) { detailSummary }
                                } else {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 10) { detailSummary }
                                        VStack(alignment: .leading, spacing: 4) { detailSummary }
                                    }
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: controlSize, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
                .accessibilityHint(expanded ? L("收起任务详情", "Collapse task details") : L("展开任务详情", "Expand task details"))
            }

            if task.dueAt != nil || (!task.isDone && task.reminderAt != nil) {
                TimelineView(.everyMinute) { clock in metadata(now: clock.date) }
                    .padding(.leading, compact ? 4 : controlSize + 4)
            }

            // Only the revealed height changes during the animation. Text and subtasks
            // retain their full size, measured again only when their geometry changes.
            DayDetailReveal(height: expanded ? detailHeight : 0, contentHeight: detailHeight) {
                if detailsLoaded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        details.padding(.leading, compact ? 4 : controlSize + 4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { detailHeight = height }
                    }
                }
            }
            .clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .padding(compact ? 10 : 12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color.appBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 12).fill(tint.opacity(task.isDone ? 0.04 : 0.1))
                }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(task.isDone ? Color.secondary.opacity(0.5) : tint)
                .frame(width: 3).padding(.vertical, 10).allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.1))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var category: some View {
        if let list = task.calendarList {
            ColoredListLabel(name: list.name, id: list.id, colorHex: list.colorHex, emoji: list.emoji)
                .font(.caption).foregroundStyle(task.isDone ? Color.secondary : tint)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
    }

    @ViewBuilder private var duration: some View {
        if let duration = task.duration {
            Text((task.scheduledAt.flatMap { start in task.endAt.map { !Dates.sameDay(start, $0) } } == true ? L("共 ", "Total ") : "")
                 + Dates.durationLabel(minutes: max(1, Int((duration / 60).rounded()))))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
        }
    }

    @ViewBuilder private var detailSummary: some View {
        if hasNotes { Label(L("备注", "Notes"), systemImage: "text.alignleft") }
        if !task.subtasks.isEmpty {
            Label("\(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)", systemImage: "checklist")
                .accessibilityLabel(L("子任务已完成 \(task.subtasks.filter(\.isDone).count)，共 \(task.subtasks.count) 项", "\(task.subtasks.filter(\.isDone).count) of \(task.subtasks.count) subtasks complete"))
        }
    }

    private func metadata(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let warning = task.reminderWarning {
                Label(warning, systemImage: "bell.badge").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reminder = task.reminderAt, !task.isDone {
                Label(Dates.label(reminder, pattern: "M月d日 HH:mm"), systemImage: "bell")
            }
            if let due = task.dueAt {
                if let countdown = task.deadlineCountdown(now: now) {
                    Label(countdown.text(due: due, timed: task.dueHasTime), systemImage: "hourglass")
                        .foregroundStyle(countdown.color)
                } else {
                    Label(L("截止 ", "Due ") + Dates.label(due, pattern: task.dueHasTime ? "M月d日 HH:mm" : "M月d日"), systemImage: "hourglass")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasNotes {
                Text(task.notes).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if task.repeatRule != "none" {
                Label(Dates.repeatLabel(task.repeatRule), systemImage: "repeat")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(task.subtasks) { subtask in
                        Button { onToggleSubtask(subtask.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(subtask.isDone ? Color.accentColor : .secondary)
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                Text(subtask.title).strikethrough(subtask.isDone)
                                    .foregroundStyle(subtask.isDone ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: controlSize, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((subtask.isDone ? L("取消完成子任务", "Mark subtask incomplete") : L("完成子任务", "Complete subtask")) + "：" + subtask.title)
                    }
                }
            }
            if task.reminderWarning != nil {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) { reminderActions }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { reminderActions }
                        VStack(alignment: .leading, spacing: 0) { reminderActions }
                    }
                }
            }
            let actionLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout())
            actionLayout {
                Button(action: onEdit) {
                    Label(L("编辑", "Edit"), systemImage: "pencil").frame(minWidth: controlSize, minHeight: controlSize)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
                Button(role: .destructive, action: onDelete) {
                    Label(L("删除", "Delete"), systemImage: "trash").frame(minWidth: controlSize, minHeight: controlSize)
                }
            }
        }
        .font(.callout).buttonStyle(.borderless)
    }

    @ViewBuilder private var reminderActions: some View {
        Button(action: onRemindNow) {
            Text(L("现在提醒", "Remind now")).frame(minWidth: controlSize, minHeight: controlSize)
        }
        Button(action: onEdit) {
            Text(L("调整时间", "Adjust time")).frame(minWidth: controlSize, minHeight: controlSize)
        }
    }
}

/// List needs the intermediate row height to keep its header anchored during expansion.
/// Reuse the content's measured height instead of asking for its ideal size every frame.
private struct DayDetailReveal: Layout {
    var height: CGFloat
    let contentHeight: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: contentHeight))
    }
}
