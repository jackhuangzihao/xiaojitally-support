import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Observation
#if os(iOS)
import UIKit
#endif

private struct CalendarWeekTitleField: View {
    @AppStorage("appLanguage") private var language = "system"
    let value: String
    let compact: Bool
    let save: (String, String) -> Bool
    @State private var draft: String
    @State private var original: String
    @State private var syncPaused = false
    @FocusState private var focused: Bool

    init(value: String, compact: Bool = false, save: @escaping (String, String) -> Bool) {
        self.value = value; self.compact = compact; self.save = save
        _draft = State(initialValue: value); _original = State(initialValue: value)
    }
    private func commit() {
        guard draft != original else { return }
        if save(draft, original) { draft = draft.trimmingCharacters(in: .whitespacesAndNewlines); original = draft }
    }
    var body: some View {
        TextField(L("周标题", "Week title"), text: $draft)
            .textFieldStyle(.plain).font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold)).focused($focused)
            .multilineTextAlignment(.center)
            .accessibilityLabel(L("本周标题", "Title for this week"))
            .onSubmit { commit(); focused = false }
            .padding(.horizontal, 48).frame(minHeight: 44)
            .background(focused ? Color.secondary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .trailing) {
                if draft != original {
                    Button { commit(); focused = false } label: { Image(systemName: "checkmark").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel(L("保存周标题", "Save week title"))
                }
            }
            .onChange(of: focused) { _, focused in
                if !focused { commit() }
                if focused != syncPaused { syncPaused = focused; CloudSync.shared.editing(focused) }
            }
            .onChange(of: value) { _, value in if !focused && draft == original { draft = value; original = value } }
            .modifier(UnsavedEditorGuard(hasChanges: { draft != original }))
            .onDisappear { commit(); if syncPaused { syncPaused = false; CloudSync.shared.editing(false) } }
    }
}

struct WeekCalendarView: View {
    let data: CalendarGridData
    @Binding var selectedDate: Date
    @Binding var assigning: UUID?
    let locateRequest: UUID
    let revealShift: Int
    let slideForward: Bool
    let isPhone: Bool
    let covered: Bool
    let actions: CalendarGridActions
    let details: CalendarGridDetails
    @State private var presentation = CalendarPresentation()
    @State private var weekDrag = WeekDrag()
    @State private var repeatPreview = RepeatPreview()
    @AppStorage("showPlanningCompleted") private var showPlanningCompleted = true
    @AppStorage("showRepeatPreviews") private var showRepeatPreviews = true
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func stepPeriod(_ amount: Int) {
        weekDrag.releaseHeldScroll(); presentation.close(); actions.step(amount)
    }
    private func today() {
        weekDrag.releaseHeldScroll(); presentation.close(); actions.today()
    }
    private var pageTransition: AnyTransition { .push(from: slideForward ? .trailing : .leading) }
    private var planTrailing: CGFloat { CGFloat(weekDrag.trailing) }
    let weekTitles: [CalendarWeekTitle]
    let canPaste: Bool
    let saveWeekTitle: (String, String, String) -> Bool
    @AppStorage("weekZoom") private var weekZoom = 1.0
    @State private var pinchZoom: Double?
    @State private var pinchBase = 1.0
    @State private var pinchAnchorY: Double?
    private var zoomLevel: Double { min(1.5, max(0.25, pinchZoom ?? weekZoom)) }
    private var planScale: Double { PlanBlock.displayScale * zoomLevel }
    private var planGutter: CGFloat { isPhone ? 34 : 44 }
    private var previewWeekDate: Date { Dates.calendar.date(byAdding: .day, value: weekDrag.weekOffset * 7, to: selectedDate)! }
    private var planningTasks: [TaskItem] {
        data.items(on: previewWeekDate, month: false, completed: showPlanningCompleted, repeats: showRepeatPreviews, cache: repeatPreview)
    }
    private var assigningTask: TaskItem? { assigning.flatMap { id in data.tasks.first { $0.id == id && $0.deletedAt == nil } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalendarPeriodNavigator(date: $selectedDate, displayedDate: previewWeekDate, week: true, isPhone: isPhone,
                                    zoom: $weekZoom, zoomLevel: zoomLevel, dragging: weekDrag.isDragging, step: stepPeriod, today: today)
            ZStack {
                weekPanel.id(CalendarPageIdentity.week(selectedDate, revealed: revealShift)).transition(pageTransition)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                #if os(macOS)
                .modifier(PageSwipe { if !weekDrag.isDragging { stepPeriod($0) } })
                #endif
        }.modifier(CalendarGridLifecycle(drag: weekDrag, presentation: presentation, locateRequest: locateRequest, covered: covered))
    }


    private var weekPanel: some View {
        let days = Dates.weekCells(previewWeekDate)
        let items = planningTasks
        let indexed = CalendarIndex.byDay(items, days: days)
        let perDay = days.map { PlanBlock.layout(indexed[$0] ?? [], day: $0) }
        let todayIndex = days.firstIndex { Dates.sameDay($0, data.currentDay) }
        let layout = TimelineLayout.make(blocks: perDay.flatMap { $0 }, fullDay: true, density: planScale,
                                         nowMinute: todayIndex == nil ? nil : Int(Dates.clockMinute(Date())))
        let selectedIndex = days.firstIndex { Dates.sameDay($0, selectedDate) } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            if !isPhone || !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 12) {
                    CalendarFreeTimeSummary(blocks: perDay[selectedIndex], selectedDate: selectedDate)
                    Spacer(minLength: 0)
                    #if os(macOS)
                    CalendarCompletedSwitch()
                    #endif
                }
            }
            weekGrid(days, perDay: perDay, layout: layout, todayIndex: todayIndex, items: indexed)
        }.weekDragPanel(weekDrag)
            .mobileCalendarDrag(drag: weekDrag, enabled: !covered && presentation.taskKey == nil && presentation.day == nil)
            .onAppear { weekDrag.gutter = Double(planGutter); weekDrag.touchEdges = isPhone }
    }

    private func weekGrid(_ days: [Date], perDay: [[PlanBlock]], layout: TimelineLayout, todayIndex: Int?, items: [Date: [TaskItem]]) -> some View {
        let key = CalendarWeekTitle.key(for: days[0])
        let title = weekTitles.first { $0.week == key }?.title ?? ""
        return VStack(spacing: 0) {
            CalendarWeekTitleField(value: title, compact: isPhone) { draft, original in saveWeekTitle(draft, key, original) }
                .id(key).padding(.bottom, isPhone ? 0 : 8)
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                .disabled(weekDrag.isDragging)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: planGutter, height: 1)
                    ForEach(days, id: \.self) { weekHeader($0) }
                    Color.clear.frame(width: planTrailing, height: 1)
                }.modifier(WeekPageSlide())
                HStack(alignment: .top, spacing: 0) {
                    Text(L("全天", "All-day")).font(.caption2).foregroundStyle(.secondary).frame(width: planGutter).padding(.top, 3)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in allDayCell(day, index: index, items: items[day] ?? []) }
                    Color.clear.frame(width: planTrailing, height: 1)
                }.padding(.bottom, 4)
                    .modifier(WeekPageSlide())
                    .reportWeekFrame { weekDrag.allDay = $0 }
                Rectangle().fill(.separator).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geometry in
                            weekCanvas(days, perDay: perDay, layout: layout, todayIndex: todayIndex, width: geometry.size.width)
                        }.frame(height: CGFloat(layout.height))
                    }
                    .reportWeekFrame { weekDrag.viewport = $0 }
                    // Two fingers on the trackpad zoom the hours; the time under the fingers stays put.
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { value in
                            guard !weekDrag.isDragging else { return }
                            if pinchZoom == nil { pinchBase = zoomLevel; pinchAnchorY = value.startLocation.y }
                            pinchZoom = min(1.5, max(0.25, pinchBase * value.magnification))
                        }
                        .onEnded { _ in
                            guard let zoom = pinchZoom else { return }
                            weekZoom = abs(zoom - 1) < 0.05 ? 1 : (zoom * 100).rounded() / 100
                            pinchZoom = nil
                            pinchAnchorY = nil
                        })
                    .overlay(alignment: .top) {
                        if let zoom = pinchZoom {
                            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 8).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: zoomLevel) { old, new in
                        #if os(macOS)
                        guard old > 0, let offset = weekDrag.scrollOffset() else { return }
                        let anchor = CGFloat(pinchAnchorY ?? Double(weekDrag.viewport.height) / 2)
                        let adjusted = (offset + anchor) * CGFloat(new / old) - anchor
                        DispatchQueue.main.async { weekDrag.setScrollOffset(adjusted) }
                        #endif
                    }
                    .task(id: locateRequest) {
                        do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                        if let minute = data.locatedMinute(days: days, selectedDate: selectedDate) { proxy.scrollTo(minute, anchor: .top) }
                    }
                    .onChange(of: locateRequest) { _, _ in
                        let now = Date()
                        guard data.locatedTask == nil, Dates.sameDay(selectedDate, now), days.contains(where: { Dates.sameDay($0, now) }) else { return }
                        proxy.scrollTo(anchorHour(layout, now: Int(Dates.clockMinute(now))), anchor: .top)
                    }
                    .task(id: days[0]) {
                        guard !weekDrag.isDragging else { return }
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                        guard !weekDrag.isDragging else { return }
                        if let minute = data.locatedMinute(days: days, selectedDate: selectedDate) { proxy.scrollTo(minute, anchor: .top); return }
                        guard !weekDrag.restoreHeldScroll() else { return }
                        proxy.scrollTo(anchorHour(layout, now: todayIndex == nil ? nil : Int(Dates.clockMinute(Date()))), anchor: .top)
                    }
                }
            }
            #if os(iOS)
            .contentShape(Rectangle())
            .modifier(PageSwipe { if !weekDrag.isDragging { stepPeriod($0) } })
            #endif
        }
    }

    private func weekHeader(_ day: Date) -> some View {
        let today = Dates.sameDay(day, data.currentDay)
        let selected = Dates.sameDay(day, selectedDate)
        return Button {
            if let id = assigning { actions.assign(id, day) } else {
                selectedDate = day
                if isPhone { presentation.showDay(day) }
            }
        } label: {
            VStack(spacing: 2) {
                Text(Dates.label(day, pattern: "E")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Text("\(Dates.calendar.component(.day, from: day))").font(.callout.monospacedDigit().weight(selected || today ? .bold : .regular))
                    .foregroundStyle(today ? Color.selectedInk : selected ? Color.accentColor : Dates.calendar.isDateInWeekend(day) ? Color.secondary : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(today ? Color.accentColor : .clear, in: Circle())
                    .overlay { if selected && !today { Circle().stroke(Color.accentColor, lineWidth: 1) } }
            }.frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
                .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
        }.buttonStyle(.plain)
            .accessibilityLabel(Dates.label(day) + (today ? L("，今天", ", today") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(isPhone ? L("查看当天全部任务", "Show all tasks for this day") : "")
            #if os(macOS)
            .dayDrop { dropOnDay($0, day) }
            #endif
    }

    private func allDayCell(_ day: Date, index: Int, items all: [TaskItem]) -> some View {
        let items = TaskItem.ordered(all.filter { $0.clockDate == nil })
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(data.visiblePlanItems(items, count: 2)) { allDayChip($0, day: day) }
            if items.count > 2 {
                Button("+\(items.count - 2)") { presentation.showDay(day) }
                    .font(.caption2).buttonStyle(.borderless)
                    .dynamicTypeSize(...(isPhone ? DynamicTypeSize.xxxLarge : .accessibility5))
                    .accessibilityLabel(L("查看当天全部任务", "Show all tasks for this day"))
            }
        }.padding(.horizontal, 1).frame(maxWidth: .infinity, minHeight: isPhone ? 44 : 22, alignment: .topLeading)
            .contentShape(Rectangle())
            .modifier(WeekZoneHighlight(zone: .allDay(index)))
            #if os(macOS)
            .dayDrop { dropAllDay($0, day) }
            #endif
            .contextMenu {
                if canPaste {
                    Button(L("粘贴为全天任务", "Paste as all-day task")) { actions.paste(day, false) }
                }
            }
            .modifier(CalendarDayPopover(presentation: presentation, day: day) { details.day(day, planningTasks, presentation) })
    }

    private func allDayChip(_ task: TaskItem, day: Date) -> some View {
        let key = CalendarGridStyle.detailID(task, day: day, allDay: true)
        let color = CalendarGridStyle.color(task)
        let chip = WeekAllDayTaskAppearance(task: task, color: color, isPhone: isPhone,
                                            isLocated: data.locatedTask == task.id)
        #if os(macOS)
        return chip.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
            .accessibilityAction { presentation.showTask(key) }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { details.task(task, presentation) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 12 }, drop: weekDrop))
            .contextMenu { details.copyMenu(task) }
        #else
        return Button { presentation.showTask(key) } label: { chip }.buttonStyle(.plain)
            .modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { details.task(task, presentation) })
            .modifier(WeekDragSource(task: task, color: color, grabOffset: { _ in 12 }, drop: weekDrop))
        #endif
    }

    private func weekCanvas(_ days: [Date], perDay: [[PlanBlock]], layout: TimelineLayout, todayIndex: Int?, width: CGFloat) -> some View {
        let column = max(1, (width - planGutter - planTrailing) / CGFloat(days.count))
        return ZStack(alignment: .topLeading) {
            TimelineView(.everyMinute) { clock in
            let nowMinute = Int(Dates.clockMinute(clock.date))
            VStack(spacing: 0) {
                ForEach(layout.hours, id: \.self) { minute in
                    HStack(alignment: .top, spacing: 4) {
                        Text(CalendarGridStyle.clockLabel(minute)).font(isPhone ? .system(size: 9).monospacedDigit() : .caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: planGutter - 6, alignment: .trailing)
                            .opacity(todayIndex != nil && abs(nowMinute - minute) < 20 ? 0 : 1)
                        Rectangle().fill(Color.secondary.opacity(0.11)).frame(height: 1)
                    }.frame(height: CGFloat(60 * layout.scale), alignment: .top).id(minute)
                }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
            ZStack(alignment: .topLeading) {
            ForEach(days.indices, id: \.self) { index in
                // Today faintly tinted, weekends faintly shaded, so the week reads at a glance.
                Rectangle().fill(index == todayIndex ? Color.accentColor.opacity(0.07)
                                 : Dates.calendar.isDateInWeekend(days[index]) ? Color.primary.opacity(0.025) : Color.clear)
                    .frame(width: column, height: CGFloat(layout.height))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.09)).frame(width: 1) }
                    .offset(x: planGutter + CGFloat(index) * column)
                    .allowsHitTesting(false)
            }
            ForEach(days.indices, id: \.self) { index in
                ForEach(perDay[index]) { block in
                    let end = block.end
                    timelineBlock(block, day: days[index], layout: layout, end: end)
                        .frame(width: max(10, column / CGFloat(block.columns) - 2), height: CGFloat(layout.intervalHeight(from: block.start, to: end)), alignment: .topLeading)
                        .offset(x: planGutter + CGFloat(index) * column + CGFloat(block.column) * column / CGFloat(block.columns) + 1, y: CGFloat(layout.y(block.start)))
                }
            }
            if let todayIndex { nowMarker(layout: layout, column: column, todayIndex: todayIndex, width: width) }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
                .modifier(WeekPageSlide())
            WeekDragGhost(layout: layout, column: column, gutter: planGutter, days: days)
            }
            .frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
        .contentShape(Rectangle())
        #if os(macOS)
        .background {
            if canPaste {
                CalendarPasteMenu { point in
                    guard !weekDrag.isDragging,
                          let slot = PlanSlot.emptyPoint(point, column: column, gutter: planGutter, layout: layout,
                                                        occupied: weekTaskFrames(perDay, column: column, layout: layout)) else { return nil }
                    let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute)
                    return (L("粘贴到这里 · ", "Paste here · ") + Dates.label(moment, pattern: "M月d日 HH:mm"),
                            { actions.paste(moment, true) })
                }
            }
        }
        .simultaneousGesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1)).onEnded { event in
            switch event {
            case .first(let tap):
                guard !covered, assigningTask == nil, !weekDrag.isDragging else { return }
                let occupied = weekTaskFrames(perDay, column: column, layout: layout)
                guard let slot = PlanSlot.emptyPoint(tap.location, column: column, gutter: planGutter, layout: layout, occupied: occupied, dayCount: days.count) else { return }
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute)
                selectedDate = days[slot.day]; actions.create(moment, true)
            case .second(let tap):
                guard let slot = planSlot(tap.location, column: column, layout: layout, dayCount: days.count) else { return }
                guard let task = assigningTask else { return }
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute, reference: task.clockDate)
                assigning = nil; arrange(task, at: moment)
            }
        })
        #else
        // Tapping always creates; copying never silently changes the normal tap action.
        .modifier(CalendarSlotInteraction(tap: { point in
            guard !covered, let slot = planSlot(point, column: column, layout: layout, dayCount: days.count) else { return }
            if let task = assigningTask {
                let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute, reference: task.clockDate)
                assigning = nil; arrange(task, at: moment)
            } else {
                guard PlanSlot.emptyPoint(point, column: column, gutter: planGutter, layout: layout,
                                          occupied: weekTaskFrames(perDay, column: column, layout: layout), dayCount: days.count) != nil else { return }
                selectedDate = days[slot.day]
                actions.create(Dates.clockTime(on: days[slot.day], minute: slot.minute), true)
            }
        }, pasteAt: { point in
            guard canPaste, !covered, assigningTask == nil, !weekDrag.isDragging,
                  let slot = PlanSlot.emptyPoint(point, column: column, gutter: planGutter, layout: layout,
                                                occupied: weekTaskFrames(perDay, column: column, layout: layout), dayCount: days.count) else { return nil }
            let moment = Dates.clockTime(on: days[slot.day], minute: slot.minute)
            return { actions.paste(moment, true) }
        }))
        #endif
        .weekCanvasDrop(drag: weekDrag, layout: layout)
        }

    private func weekTaskFrames(_ perDay: [[PlanBlock]], column: CGFloat, layout: TimelineLayout) -> [CGRect] {
        var frames: [CGRect] = []
        for (index, blocks) in perDay.enumerated() {
            for block in blocks {
                let width = column / CGFloat(block.columns)
                let x = planGutter + CGFloat(index) * column + CGFloat(block.column) * width + 1
                frames.append(CGRect(x: x, y: CGFloat(layout.y(block.start)), width: max(10, width - 2),
                                     height: CGFloat(layout.intervalHeight(from: block.start, to: block.end))))
            }
        }
        return frames
    }

    private func planSlot(_ point: CGPoint, column: CGFloat, layout: TimelineLayout, dayCount: Int = 7) -> PlanSlot? {
        guard dayCount > 0, point.x >= planGutter, point.x < planGutter + CGFloat(dayCount) * column else { return nil }
        return PlanSlot(day: min(dayCount - 1, max(0, Int((point.x - planGutter) / column))), minute: layout.snapped(Double(point.y)))
    }

    @ViewBuilder private func nowMarker(layout: TimelineLayout, column: CGFloat, todayIndex: Int, width: CGFloat) -> some View {
        TimelineView(.everyMinute) { clock in
            let minute = Int(Dates.clockMinute(clock.date))
            // TimelineView supplies one layout child; keep every marker anchored to the canvas origin.
            ZStack(alignment: .topLeading) {
                if minute >= layout.startMinute && minute <= layout.endMinute {
                    let y = CGFloat(layout.y(Double(minute)))
                    Rectangle().fill(Color.red.opacity(0.3)).frame(width: max(0, width - planGutter), height: 1)
                        .offset(x: planGutter, y: y - 0.5).accessibilityHidden(true)
                    Rectangle().fill(Color.red).frame(width: column, height: 2.5)
                        .offset(x: planGutter + CGFloat(todayIndex) * column, y: y - 1.25).accessibilityHidden(true)
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                        .offset(x: planGutter + CGFloat(todayIndex) * column - 3.5, y: y - 3.5).accessibilityHidden(true)
                    Text(Dates.label(clock.date, pattern: "HH:mm"))
                        .font(isPhone ? .system(size: 9, weight: .semibold).monospacedDigit() : .caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1).background(Color.red, in: Capsule())
                        .frame(width: planGutter - 2)
                        .position(x: (planGutter - 2) / 2, y: y)
                        .accessibilityLabel(L("现在 \(Dates.label(clock.date, pattern: "HH:mm"))", "Now \(Dates.label(clock.date, pattern: "HH:mm"))"))
                }
            }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading)
        }.frame(width: width, height: CGFloat(layout.height), alignment: .topLeading).allowsHitTesting(false)
    }

    /// Open on the current hour when this week holds today; any other week opens at 8:00, not midnight.
    private func anchorHour(_ layout: TimelineLayout, now: Int?) -> Int {
        guard let now else { return min(max(layout.startMinute, 8 * 60), max(layout.startMinute, layout.endMinute - 60)) }
        return min(max(layout.startMinute, now / 60 * 60 - 60), max(layout.startMinute, layout.endMinute - 60))
    }

    /// The shape represents the interval; text appears only when it fits.
    private func timelineBlock(_ block: PlanBlock, day: Date, layout: TimelineLayout, end: Double) -> some View {
        let task = block.task
        let height = layout.intervalHeight(from: block.start, to: end)
        let edgeHeight = task.previewSourceID == nil ? TaskResize.handleHeight(for: height) : 0
        let key = CalendarGridStyle.detailID(task, day: day)
        let time = task.timeLabel
        let note = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let midnight = Dates.calendar.startOfDay(for: day)
        let nextDay = Dates.calendar.date(byAdding: .day, value: 1, to: midnight)!
        let fromPrevious = task.clockDate.map { $0 < midnight } ?? false
        let toNext = task.endAt.map { $0 > nextDay } ?? false
        let card = WeekTimelineTaskAppearance(task: task, isPhone: isPhone, height: height, time: time,
                                              fromPrevious: fromPrevious, toNext: toNext)
        let help = [task.title, task.timeLabel, task.calendarList.map { ListTree.path($0, lists: data.lists) } ?? "", note].filter { !$0.isEmpty }.joined(separator: "\n")
        #if os(macOS)
        return card.modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil)).contentShape(Rectangle())
            .onTapGesture { presentation.showTask(key) }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel([task.title, task.timeLabel, task.calendarList?.name ?? "", task.priority == 2 ? L("高优先级", "High priority") : task.priority == 1 ? L("中优先级", "Medium priority") : ""].filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityAction { presentation.showTask(key) }
            .help(help)
            .contextMenu { details.copyMenu(task) }
            .overlay { if data.locatedTask == task.id { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { details.task(task, presentation) })
            .modifier(WeekDragSource(task: task, color: CalendarGridStyle.color(task), grabOffset: { start in
                weekDrag.pickupOffset(for: task, on: day, at: start)
            }, drop: weekDrop))
            .overlay(alignment: .top) { if edgeHeight > 0, let range = TaskResize(task: task, day: day, top: true, column: block.column, columns: block.columns) { resizeHandle(task, range: range, height: edgeHeight) } }
            .overlay(alignment: .bottom) { if edgeHeight > 0, let range = TaskResize(task: task, day: day, top: false, column: block.column, columns: block.columns) { resizeHandle(task, range: range, height: edgeHeight) } }
        #else
        return Button { presentation.showTask(key) } label: { card }.buttonStyle(.plain)
            .accessibilityLabel(help)
            .modifier(RepeatPreviewStyle(isPreview: task.previewSourceID != nil))
            .overlay { if data.locatedTask == task.id { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) } }
            .help(help)
            .modifier(CalendarTaskPopover(presentation: presentation, key: key) { details.task(task, presentation) })
            .modifier(WeekDragSource(task: task, color: CalendarGridStyle.color(task),
                grabOffset: { weekDrag.pickupOffset(for: task, on: day, at: $0) }, drop: weekDrop))
        #endif
    }

    #if os(macOS)
    private func resizeHandle(_ task: TaskItem, range: TaskResize, height: Double) -> some View {
        Color.clear.frame(height: height).contentShape(Rectangle())
            .help(range.top ? L("拖动调整开始时间，左右可跨天", "Drag to adjust start; move sideways to change day") : L("拖动调整结束时间，左右可跨天", "Drag to adjust end; move sideways to change day"))
            .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(WeekDrag.space))
                .onChanged { value in
                    weekDrag.updateResize(task, color: CalendarGridStyle.color(task), range: range, point: value.location, others: data.tasks) { endpoint, offset in
                        let destination = Dates.calendar.date(byAdding: .day, value: offset * 7, to: range.day)!
                        actions.schedule(task, endpoint, range.top ? .resizeStart : .resizeEnd, offset == 0 ? nil : destination, false)
                    }
                }
                .onEnded { _ in if weekDrag.taskID == task.id { weekDrag.complete() } })
            .accessibilityElement().accessibilityLabel(range.top ? L("调整开始时间", "Adjust start time") : L("调整结束时间", "Adjust end time"))
    }
    #endif

    private func weekDrop(_ task: TaskItem, _ zone: WeekDropGeometry.Zone, _ weekOffset: Int) {
        let destination = Dates.calendar.date(byAdding: .day, value: weekOffset * 7, to: selectedDate)!
        let days = Dates.weekCells(destination)
        switch zone {
        case .none: break
        case .timed(let day, let minute):
            // Same week: the block glides to its new place. Another week is already on screen, so no extra animation.
            withAnimation(weekOffset == 0 && !reduceMotion ? .spring(response: 0.3, dampingFraction: 0.86) : nil) {
                arrange(task, at: Dates.clockTime(on: days[day], minute: minute, reference: task.clockDate), revealDate: weekOffset == 0 ? nil : destination)
            }
        case .allDay(let day):
            makeAllDay(task, on: days[day], revealDate: weekOffset == 0 ? nil : destination)
        case .undated: actions.clearDate(task)
        case .day: break
        }
    }
    private func arrange(_ task: TaskItem, at date: Date, revealDate: Date? = nil) {
        actions.schedule(task, date, .timed, revealDate, false)
    }
    private func makeAllDay(_ task: TaskItem, on date: Date, revealDate: Date? = nil) {
        actions.schedule(task, date, .allDay, revealDate, false)
    }
    private func dropAllDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = data.droppedTask(values) else { return false }
        makeAllDay(task, on: day); return true
    }
    private func dropOnDay(_ values: [String], _ day: Date) -> Bool {
        guard let task = data.droppedTask(values) else { return false }
        actions.schedule(task, day, .day, nil, false); return true
    }

}
