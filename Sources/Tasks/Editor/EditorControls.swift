import SwiftUI

/// One line of the schedule: label on the left, the current value (or a grey "无") on the right.
struct SettingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let systemImage: String
    let title: String
    let value: String
    let isSet: Bool
    let isOpen: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    let clear: () -> Void

    #if os(iOS)
    private let height: CGFloat = 48
    #else
    private let height: CGFloat = 36
    #endif

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).foregroundStyle(isOpen ? tint : Color.secondary).frame(width: 22)
                    (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
                    Text(title).foregroundStyle(Color.primary)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    Text(value).foregroundStyle(isSet ? tint : Color.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }.frame(minHeight: height).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(title + "，" + value)
                .accessibilityHint(isOpen ? L("收起", "Collapse") : L("展开设置", "Open"))
            if isSet {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 44, height: height).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L("清除", "Clear ") + title)
            } else {
                Color.clear.frame(width: 44, height: 1) // keeps every row's value lined up
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }
}

struct SelectPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.selectedInk : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(macOS)
/// While the suggestion list is open, catches the arrow keys, Return and Esc before the text field
/// (and before the sheet's own Esc = Cancel). An input method that is still composing gets them as usual.
struct SuggestionKeys: NSViewRepresentable {
    let active: Bool
    let handle: (UInt16) -> Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.active = active; view.handle = handle }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var active = false
        var handle: ((UInt16) -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, LocalEventScope.accepts(window: event.window, in: self),
                      let editor = self.window?.firstResponder as? NSTextView, !editor.hasMarkedText(),
                      self.convert(self.visibleRect, to: nil).intersects(editor.convert(editor.visibleRect, to: nil)),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                return self.handle?(event.keyCode) == true ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
#endif

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// Time picker. iPhone: an hour wheel and a minute wheel in five-minute steps, narrow enough for two side by side
/// (the system wheel is not). macOS has no wheel, so it uses the system time field, which also takes typing.
struct TimeWheel: View {
    @Binding var date: Date
    var body: some View {
        #if os(iOS)
        let parts = Dates.calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        // An existing time that isn't on a five-minute step stays selectable instead of being rounded away.
        let minutes = Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [minute])).sorted()
        HStack(spacing: 0) {
            Picker(L("小时", "Hour"), selection: Binding(get: { hour }, set: { set(hour: $0, minute: minute) })) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
            Text(":").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            Picker(L("分钟", "Minute"), selection: Binding(get: { minute }, set: { set(hour: hour, minute: $0) })) {
                ForEach(minutes, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
        }.frame(maxWidth: .infinity).frame(height: 140)
        #else
        DatePicker(L("时间", "Time"), selection: $date, displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.stepperField).controlSize(.large)
            .frame(maxWidth: .infinity)
        #endif
    }

    private func set(hour: Int, minute: Int) {
        date = Dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

/// Inline month grid used inside the editor. Days outside `earliest`…`latest` can't be chosen.
struct DateGrid: View {
    @Binding var date: Date
    var earliest: Date? = nil
    var latest: Date? = nil
    /// False while nothing is chosen yet, so today's date doesn't look already picked.
    var highlight = true
    var onPick: () -> Void = {}
    @State private var month: Date

    init(date: Binding<Date>, earliest: Date? = nil, latest: Date? = nil, highlight: Bool = true, onPick: @escaping () -> Void = {}) {
        _date = date
        self.earliest = earliest
        self.latest = latest
        self.highlight = highlight
        self.onPick = onPick
        _month = State(initialValue: Dates.monthStart(date.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Dates.label(month, pattern: "yyyy年M月")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { month = Dates.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("上个月", "Previous month"))
                Button { month = Dates.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel(L("下个月", "Next month"))
            }.buttonStyle(.borderless)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, value in Text(value).font(.caption).foregroundStyle(.secondary) }
                ForEach(Dates.monthCells(month), id: \.self) { day in
                    let selected = highlight && Dates.sameDay(date, day)
                    let today = Dates.sameDay(day, Date())
                    let inMonth = Dates.calendar.isDate(day, equalTo: month, toGranularity: .month)
                    let blocked = (earliest.map { Dates.calendar.startOfDay(for: day) < Dates.calendar.startOfDay(for: $0) } ?? false)
                        || (latest.map { Dates.calendar.startOfDay(for: day) > Dates.calendar.startOfDay(for: $0) } ?? false)
                    // Only this month's days are drawn; the grid keeps their places so weekdays line up.
                    if !inMonth { Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true) } else {
                    Button { date = Dates.replacingDay(of: date, with: day); onPick() } label: {
                        Text("\(Dates.calendar.component(.day, from: day))").font(.body.monospacedDigit())
                            .foregroundStyle(selected ? Color.selectedInk : inMonth ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { if today && !selected { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1) } }
                            .opacity(blocked ? 0.3 : 1)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(blocked)
                        .accessibilityLabel(Dates.label(day)).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: date) { _, value in
            if !Dates.calendar.isDate(value, equalTo: month, toGranularity: .month) { month = Dates.monthStart(value) }
        }
    }
}

struct DateChoiceButton: View {
    @AppStorage("appLanguage") private var language = "system"
    let label: String
    @Binding var date: Date
    var onChoose: () -> Void = {}
    @State private var showingCalendar = false
    @State private var browsingDate = Date()

    var body: some View {
        Button { showingCalendar = true } label: {
            HStack(spacing: 6) { Text(label); Image(systemName: "chevron.down").font(.caption2) }.padding(.vertical, 6)
        }.buttonStyle(.borderless).accessibilityLabel(L("\(label)，打开日历选择日期", "\(label), open date picker"))
            .popover(isPresented: $showingCalendar) {
                VStack(spacing: 14) {
                    HStack {
                        Button { browsingDate = Dates.shiftMonth(browsingDate, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 32) }.accessibilityLabel(L("选择器上个月", "Previous month in date picker"))
                        Spacer(minLength: 0)
                        Picker(L("年份", "Year"), selection: Binding(get: { Dates.calendar.component(.year, from: browsingDate) }, set: { year in
                            browsingDate = Dates.calendar.date(from: DateComponents(year: year, month: Dates.calendar.component(.month, from: browsingDate), day: 1))!
                        })) {
                            let year = Dates.calendar.component(.year, from: browsingDate)
                            ForEach(min(1900, year)...max(2100, year), id: \.self) { year in Text(L(String(year) + "年", String(year))).tag(year) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                        Picker(L("月份", "Month"), selection: Binding(get: { Dates.calendar.component(.month, from: browsingDate) }, set: { month in
                            browsingDate = Dates.calendar.date(from: DateComponents(year: Dates.calendar.component(.year, from: browsingDate), month: month, day: 1))!
                        })) {
                            ForEach(1...12, id: \.self) { Text(L("\($0)月", Dates.monthName($0))).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                        Spacer(minLength: 0)
                        Button { browsingDate = Dates.shiftMonth(browsingDate, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 32) }.accessibilityLabel(L("选择器下个月", "Next month in date picker"))
                    }.buttonStyle(.borderless)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                        ForEach(Array(Dates.weekdays.enumerated()), id: \.offset) { _, value in Text(value).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Dates.monthCells(browsingDate), id: \.self) { day in
                            let selected = Dates.sameDay(date, day)
                            let inMonth = Dates.calendar.isDate(day, equalTo: browsingDate, toGranularity: .month)
                            if !inMonth { Color.clear.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true) } else {
                            Button { choose(day) } label: {
                                Text("\(Dates.calendar.component(.day, from: day))").font(.body.monospacedDigit())
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(selected ? Color.selectedInk : Color.primary)
                                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { if Dates.sameDay(day, Date()) && !selected { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1) } }
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(Dates.label(day))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                            }
                            }
                }.padding(18).frame(width: 344).onAppear { browsingDate = date }
                    .environment(\.locale, UISettings.locale)
                    .environment(\.calendar, Dates.calendar)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func choose(_ day: Date) {
        date = Dates.replacingDay(of: date, with: day)
        onChoose(); showingCalendar = false
    }
}

/// Interval, unit and weekdays for a custom `RepeatRule`. Shared by tasks and recurring bills.
/// Its rows sit directly in the caller's stack so spacing matches the surrounding panel.
struct CustomRepeatControls: View {
    let rule: RepeatRule
    /// The weekday a new weekly rule starts with: that of the item's own date.
    let baseWeekday: Int
    /// Pills instead of a stepper and segmented picker. Forms on macOS re-lay those out as label and control
    /// columns, which hides the unit picker; pills stay put anywhere.
    var pills = false
    let change: (String) -> Void

    private static let units: [(RepeatRule.Unit, String, String)] = [(.day, "天", "days"), (.week, "周", "weeks"), (.month, "个月", "months"), (.year, "年", "years")]

    var body: some View {
        if pills { pillControls } else { standardControls }
        if rule.unit == .week { weekdays }
    }

    private var pillControls: some View {
        FlowLayout(spacing: 8) {
            Text(L("每", "Every")).foregroundStyle(.secondary).frame(minHeight: 27)
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).disabled(rule.interval <= 1).accessibilityLabel(L("减少间隔", "Fewer"))
            Text("\(rule.interval)").font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 22, minHeight: 27)
                .accessibilityLabel(L("间隔 \(rule.interval)", "Interval \(rule.interval)"))
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                .buttonStyle(.borderless).disabled(rule.interval >= 99).accessibilityLabel(L("增加间隔", "More"))
            ForEach(Self.units, id: \.0) { unit, zh, en in
                SelectPill(title: L(zh, en), selected: rule.unit == unit) {
                    change(RepeatRule(interval: rule.interval, unit: unit, weekdays: unit == .week ? [baseWeekday] : []).text)
                }
            }
        }
    }
    private func step(_ delta: Int) {
        var next = rule; next.interval = min(99, max(1, rule.interval + delta)); change(next.text)
    }

    @ViewBuilder private var standardControls: some View {
        HStack(spacing: 10) {
            Text(L("每", "Every")).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { rule.interval }, set: { value in
                var next = rule; next.interval = min(99, max(1, value)); change(next.text)
            }), in: 1...99) {
                Text("\(rule.interval)").font(.callout.monospacedDigit().weight(.semibold)).frame(minWidth: 22)
            }.fixedSize()
            Picker(L("单位", "Unit"), selection: Binding(get: { rule.unit }, set: { unit in
                change(RepeatRule(interval: rule.interval, unit: unit, weekdays: unit == .week ? [baseWeekday] : []).text)
            })) {
                Text(L("天", "days")).tag(RepeatRule.Unit.day)
                Text(L("周", "weeks")).tag(RepeatRule.Unit.week)
                Text(L("个月", "months")).tag(RepeatRule.Unit.month)
                Text(L("年", "years")).tag(RepeatRule.Unit.year)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
        }
    }

    @ViewBuilder private var weekdays: some View {
        if rule.unit == .week {
            let chosen = rule.weekdays.isEmpty ? [baseWeekday] : rule.weekdays
            FlowLayout(spacing: 6) {
                ForEach(RepeatRule.weekOrder, id: \.self) { day in
                    SelectPill(title: RepeatRule.weekdayName(day), selected: chosen.contains(day)) {
                        var days = chosen
                        if days.contains(day) { if days.count > 1 { days.remove(day) } } else { days.insert(day) }
                        change(RepeatRule(interval: rule.interval, unit: .week, weekdays: days).text)
                    }
                }
            }
        }
    }
}
