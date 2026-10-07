import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

/// Picks a task up in the Mac week view. The source stays in place, faded, while the drag is drawn elsewhere.
struct WeekDragSource: ViewModifier {
    let task: TaskItem
    let color: Color
    /// Distance from the task's top edge to where it was grabbed, given the start point in the panel.
    let grabOffset: (CGPoint) -> Double
    /// Cards with buttons inside need the drag to run alongside those buttons.
    var simultaneous = false
    /// Set in the month view: the month on screen when the drag starts.
    var month: Date? = nil
    let drop: (TaskItem, WeekDropGeometry.Zone, Int) -> Void
    @Environment(WeekDrag.self) private var drag
    func body(content: Content) -> some View {
        #if os(macOS)
        let gesture = DragGesture(minimumDistance: 4, coordinateSpace: .named(WeekDrag.space))
            .onChanged { value in
                guard task.previewSourceID == nil else { return }
                drag.updateGesture(task, color: color, grabOffset: grabOffset(value.startLocation),
                                   point: value.location, month: month) { zone, offset in
                    if zone != .none { drop(task, zone, offset) }
                }
            }
            .onEnded { _ in
                // Native mouse-up usually finishes first; this is the fallback when it was missed.
                #if os(macOS)
                if drag.taskID == task.id { drag.complete() }
                #endif
            }
        let lifted = drag.taskID == task.id && !drag.cancelled
        return Group {
            if simultaneous { content.simultaneousGesture(gesture) } else { content.gesture(gesture) }
        }
        .opacity(lifted ? 0.35 : 1)
        .animation(.easeOut(duration: 0.12), value: lifted)
        #else
        content.background {
            if task.previewSourceID == nil && task.deletedAt == nil {
                MobileCalendarDragSource(drag: drag) { point in
                    drag.begin(task, color: color, grabOffset: grabOffset(point), month: month) { zone, offset in
                        if zone != .none { drop(task, zone, offset) }
                    }
                }
            }
        }.opacity(drag.taskID == task.id && !drag.cancelled ? 0.35 : 1)
        #endif
    }
}

/// Animate only the week contents. Never replace the scroll view or the drag tracker.
struct WeekPageSlide: ViewModifier {
    @Environment(WeekDrag.self) private var drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content.id(drag.weekOffset)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: drag.pageForward ? .trailing : .leading),
                    removal: .move(edge: drag.pageForward ? .leading : .trailing)))
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: drag.weekOffset)
    }
}

/// Where the task will land on the grid: a copy of the block at the snapped quarter hour, with its new time.
struct WeekDragGhost: View {
    let layout: TimelineLayout
    let column: CGFloat
    let gutter: CGFloat
    let days: [Date]
    @Environment(WeekDrag.self) private var drag
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if drag.isDragging, case .timed(let day, let minute) = drag.zone {
            let start = drag.resizeInterval?.start ?? Dates.clockTime(on: days[day], minute: minute)
            let end = drag.resizeInterval?.end ?? start.addingTimeInterval(drag.durationMinutes * 60)
            let laneWidth = column / CGFloat(drag.resizeRange?.columns ?? 1)
            let laneOffset = CGFloat(drag.resizeRange?.column ?? 0) * laneWidth
            ForEach(Array(days.enumerated()), id: \.offset) { index, date in
                if let slice = PlanBlock.segment(from: start, to: end, on: date) {
                    let span = Dates.clockSpan(from: slice.start, to: slice.end, on: date)
                    let visualStart = span.start
                    let height = layout.intervalHeight(from: visualStart, to: span.end)
                    RoundedRectangle(cornerRadius: min(5, height / 2)).fill(drag.color.opacity(0.3))
                        .frame(width: max(10, laneWidth - 2), height: height)
                        .overlay(RoundedRectangle(cornerRadius: min(5, height / 2)).strokeBorder(drag.color, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if drag.resizeRange == nil, index == day {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(drag.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(Dates.label(start, pattern: "E HH:mm") + "–" + Dates.label(end, pattern: Dates.sameDay(start, end) ? "HH:mm" : "M月d日 HH:mm"))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(3).background(height < 32 ? Color.appBackground : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .offset(y: height < 32 ? height + 3 : 0)
                            }
                        }
                        .offset(x: gutter + CGFloat(index) * column + laneOffset + 1, y: CGFloat(layout.y(visualStart)))
                }
            }
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.95), value: drag.zone)
        }
    }
}

/// Off the grid (all-day row, undated list, the week edges, or nowhere) a small card follows the pointer.
struct WeekDragChip: View {
    @Environment(WeekDrag.self) private var drag

    var body: some View {
        if drag.isDragging, !isTimed || drag.resizeRange != nil {
            let interval = drag.resizeInterval
            let width: CGFloat = interval == nil ? 170 : 300
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(drag.color).frame(width: 6, height: 6)
                    Text(drag.title).font(.caption.weight(.medium)).lineLimit(1)
                }
                if let interval {
                    Text(Dates.label(interval.start, pattern: "M月d日 E HH:mm") + " → " + Dates.label(interval.end, pattern: Dates.sameDay(interval.start, interval.end) ? "HH:mm" : "M月d日 E HH:mm"))
                        .font(.caption2.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                    Text(Dates.durationLabel(minutes: Int(interval.duration / 60))).font(.caption2).foregroundStyle(.secondary)
                    if drag.overlaps {
                        Label(L("与其他任务重叠", "Overlaps another task"), systemImage: "square.on.square")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8).frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(drag.color.opacity(0.6)))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            .offset(x: min(max(0, drag.pointer.x + 12), max(0, drag.chipBounds.maxX - width - 4)),
                    y: min(max(0, drag.pointer.y + 12), max(0, drag.chipBounds.maxY - (interval == nil ? 36 : 108))))
            .allowsHitTesting(false)
        }
    }

    private var isTimed: Bool {
        if case .timed = drag.zone { return true }
        return false
    }
}

/// Lights up the all-day cell or the undated list while a task is held over it.
struct WeekZoneHighlight: ViewModifier {
    let zone: WeekDropGeometry.Zone
    @Environment(WeekDrag.self) private var drag

    func body(content: Content) -> some View {
        let on = drag.isDragging && drag.zone == zone
        return content
            .background(on ? drag.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay { if on { RoundedRectangle(cornerRadius: 5).strokeBorder(drag.color, lineWidth: 1).allowsHitTesting(false) } }
    }
}

#if os(macOS)
/// One quiet line in the empty part of the navigator row, so the drag gestures can be found at all.
/// While a task is held it says what the pointer will do right now.
struct PlanHint: View {
    @AppStorage("appLanguage") private var language = "system"
    let month: Bool
    @Environment(WeekDrag.self) private var drag

    var body: some View {
        Label(text, systemImage: drag.isDragging ? "hand.draw" : "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .animation(.easeOut(duration: 0.12), value: text)
    }

    private var text: String {
        if month {
            guard drag.isDragging else {
            return L("拖动任务到另一天可改期 · 拖到左右两侧可翻月 · 点日期查看当天任务", "Drag a task to another day to reschedule · Hold at either side to change month · Click a date to see its tasks")
            }
            switch drag.edge {
            case -1: return L("停住会翻到上个月 · 在这里松手不改动", "Hold to go to the previous month · Releasing here changes nothing")
            case 1: return L("停住会翻到下个月 · 在这里松手不改动", "Hold to go to the next month · Releasing here changes nothing")
            default: return L("松手放下 · 停在左右两侧翻月 · 按 Esc 取消", "Release to drop · Hold at either side to change month · Esc to cancel")
            }
        }
        guard drag.isDragging else {
            return L("双击空白新建 · 拖动改期 · 边缘翻周 · 双指缩放", "Double-click a blank slot to add · Drag to reschedule · Hold at edges to change week · Pinch to zoom")
        }
        switch drag.edge {
        case -1: return L("停住会翻到上一周 · 在这里松手不改动", "Hold to go to the previous week · Releasing here changes nothing")
        case 1: return L("停住会翻到下一周 · 在这里松手不改动", "Hold to go to the next week · Releasing here changes nothing")
        default: return L("松手放下 · 停在左右两侧翻周 · 按 Esc 取消", "Release to drop · Hold at either side to change week · Esc to cancel")
        }
    }
}

#endif
