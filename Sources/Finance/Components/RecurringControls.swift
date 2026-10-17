import SwiftUI

/// Repeat choices for a recurring bill: presets named after its first date, a custom interval, and an end date.
struct RecurringScheduleControls: View {
    @Binding var rule: String
    @Binding var until: Date?
    /// The first occurrence. Weekly, monthly and yearly presets follow its weekday and day.
    let start: Date
    /// New entries offer "Never"; an existing bill always repeats.
    var allowsNone = true
    var repeatTimeZoneID: String? = nil
    @State private var custom = false

    private static let presets = ["daily", "weekly", "monthly", "yearly"]
    private var recurrenceCalendar: Calendar? {
        repeatTimeZoneID == nil ? Dates.calendar : Dates.recurrenceCalendar(timeZoneID: repeatTimeZoneID)
    }
    private var baseWeekday: Int { recurrenceCalendar?.component(.weekday, from: start) ?? 1 }
    private var startDay: Date { recurrenceCalendar?.startOfDay(for: start) ?? start }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                if allowsNone {
                    SelectPill(title: L("不重复", "Never"), selected: rule == "none") { custom = false; rule = "none"; until = nil }
                }
                ForEach(Self.presets, id: \.self) { preset in
                    SelectPill(title: label(for: preset), selected: !custom && rule == preset) { custom = false; rule = preset }
                }
                SelectPill(title: L("自定义", "Custom"), selected: custom) {
                    custom = true
                    if RepeatRule(rule) == nil { rule = RepeatRule(interval: 2, unit: .week, weekdays: [baseWeekday]).text }
                }
            }
            if custom, let parsed = RepeatRule(rule) {
                CustomRepeatControls(rule: parsed, baseWeekday: baseWeekday, pills: true) { rule = $0 }
            }
            if rule != "none" {
                // The preset names stay short; the exact day they mean is spelled out here.
                Label(L("按此规则：", "Repeats: ") + scheduleText, systemImage: "repeat")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(L("结束", "Ends")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    SelectPill(title: L("永不", "Never"), selected: until == nil) { until = nil }
                    SelectPill(title: L("到某天为止", "On a date"), selected: until != nil) {
                        if until == nil { until = recurrenceCalendar?.date(byAdding: .year, value: 1, to: startDay) }
                    }
                }
                if let until, let calendar = recurrenceCalendar {
                    DatePicker(L("最后一次不晚于", "Last time on or before"),
                               selection: Binding(get: { until }, set: { self.until = calendar.startOfDay(for: $0) }),
                               in: startDay..., displayedComponents: .date)
                        .datePickerStyle(.compact).font(.callout)
                        .environment(\.calendar, calendar)
                        .environment(\.timeZone, calendar.timeZone)
                }
            }
        }
        // Forms size rows by their ideal width; without a bound, one long line of pills widens the whole sheet.
        .frame(minWidth: 0, idealWidth: 360, maxWidth: .infinity, alignment: .leading)
        .onAppear { custom = rule != "none" && !Self.presets.contains(rule) }
        // An end before the next occurrence would end the bill before it starts.
        .onChange(of: startDay) { _, day in
            if let calendar = recurrenceCalendar, let until, calendar.startOfDay(for: until) < day { self.until = day }
        }
    }

    private func label(for preset: String) -> String {
        switch preset {
        case "weekly": L("每周", "Weekly")
        case "monthly": L("每月", "Monthly")
        case "yearly": L("每年", "Yearly")
        default: L("每天", "Daily")
        }
    }
    /// "每周五", "每月 9 日", "每年 10月9日" or a custom rule's own wording, from the first occurrence.
    private var scheduleText: String {
        guard let calendar = recurrenceCalendar else { return Dates.repeatLabel(rule) }
        return MoneyRecurring.scheduleLabel(rule: rule, anchorDay: calendar.component(.day, from: start), date: start, calendar: calendar)
    }
}

/// The small "↻ every month on the 1st" tag on entries a recurring bill generated.
struct RecurringBadge: View {
    let bill: MoneyRecurring
    var body: some View {
        Label(bill.scheduleLabel, systemImage: "repeat")
            .tagStyle(.accentColor, weight: .medium)
            .accessibilityLabel(L("周期账单：", "Recurring bill: ") + bill.scheduleLabel)
    }
}

/// Shown when an entry a recurring bill generated is opened: edits here change only this entry,
/// and the bill itself is one click away.
struct RecurringOriginBanner: View {
    let bill: MoneyRecurring
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "repeat").foregroundStyle(Color.accentColor)
            Text(L("这笔来自周期账单“\(bill.title) · \(bill.scheduleLabel)”。这里的修改只影响这一笔。",
                   "This entry comes from the recurring bill “\(bill.title) · \(bill.scheduleLabel)”. Changes here affect only this entry."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("修改周期账单…", "Edit recurring bill…"), action: edit)
                .buttonStyle(.bordered).frame(minHeight: 44)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("finance.recurringOrigin")
    }
}
