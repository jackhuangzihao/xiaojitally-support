import SwiftUI

struct WeekAllDayTaskAppearance: View {
    let task: TaskItem
    let color: Color
    let isPhone: Bool
    let isLocated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text((task.previewSourceID == nil ? "" : "↻ ") + task.title).font(.caption2.weight(task.priority == 2 && !task.isDone ? .bold : .medium)).lineLimit(1).strikethrough(task.isDone)
            if !isPhone {
                HStack(spacing: 3) { if let list = task.calendarList { WeekTaskCategory(list: list, color: color, isDone: task.isDone) }; Spacer(minLength: 0); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
            }
        }
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
            .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same as a timed block: rounder, with the list's colour as a bar on the left.
            .background(color.opacity(task.isDone ? 0.07 : 0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(task.isDone ? 0.4 : 1)).frame(width: 3).padding(.vertical, 2) }
            .overlay { if isLocated { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
    }
}

struct WeekTimelineTaskAppearance: View {
    let task: TaskItem
    let isPhone: Bool
    let height: Double
    let time: String
    let fromPrevious: Bool
    let toNext: Bool

    var body: some View {
        // A small card: rounder corners, a faint shadow, the list's colour as its left bar.
        RoundedRectangle(cornerRadius: min(9, height / 2), style: .continuous)
            .fill(CalendarGridStyle.color(task).opacity(task.isDone ? 0.09 : 0.24))
            .shadow(color: .black.opacity(task.isDone ? 0 : 0.12), radius: 1.5, y: 1)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(CalendarGridStyle.color(task).opacity(task.isDone ? 0.4 : 1)).frame(width: 3).padding(.vertical, min(3, height / 4)) }
            .overlay(alignment: .topLeading) {
                if height >= 14 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text((task.previewSourceID == nil ? "" : "↻ ") + task.title)
                                #if os(iOS)
                                .font(.caption.weight(task.priority == 2 && !task.isDone ? .bold : .medium))
                                #else
                                .font(.system(size: 11, weight: task.priority == 2 && !task.isDone ? .bold : .medium))
                                #endif
                                .strikethrough(task.isDone).lineLimit(isPhone ? (height >= 76 ? 4 : height >= 48 ? 2 : 1) : height >= 76 ? 2 : 1)
                            if !isPhone && height < 30 { Spacer(minLength: 0); CalendarPriorityMark(priority: task.priority, isDone: task.isDone) }
                        }
                        if !isPhone && height >= 30 {
                            HStack(spacing: 3) {
                                if let list = task.calendarList { WeekTaskCategory(list: list, color: CalendarGridStyle.color(task), isDone: task.isDone) }
                                Spacer(minLength: 0)
                                CalendarPriorityMark(priority: task.priority, isDone: task.isDone)
                            }
                        }
                        if !isPhone && height >= 48 { Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.leading, 7).padding(.trailing, 4).padding(.trailing, fromPrevious || toNext ? 10 : 0)
                        .padding(.vertical, height >= 30 ? 1 : 0)
                }
            }
            .overlay(alignment: .topTrailing) {
                if fromPrevious { Image(systemName: "arrow.left").font(.system(size: 8, weight: .semibold)).padding(2).accessibilityHidden(true).allowsHitTesting(false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if toNext { Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).padding(2).accessibilityHidden(true).allowsHitTesting(false) }
            }
            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
            .clipped()
            .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
    }
}

private struct WeekTaskCategory: View {
    let list: TaskList
    let color: Color
    let isDone: Bool

    var body: some View {
        Text((list.emoji.map { $0 + " " } ?? "") + list.name)
            #if os(iOS)
            .font(.caption2.weight(.medium)).lineLimit(1)
            #else
            .font(.system(size: 10, weight: .medium)).lineLimit(1)
            #endif
            // The list's name in its own colour, without a box of its own.
            .foregroundStyle(isDone ? Color.secondary : color)
    }
}
