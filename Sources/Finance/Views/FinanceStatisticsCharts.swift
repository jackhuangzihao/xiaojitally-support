import SwiftUI
import Charts

/// Chart hover remains in MoneyChartHover; navigation stays with FinanceHome.
struct FinanceTrendChart: View {
    @AppStorage("appLanguage") private var language = "system"
    let points: [FinanceHome.TrendPoint]
    let hovered: Binding<Date?>
    let statsUnit: Calendar.Component
    let period: MoneyPeriod
    let statsIncome: Bool
    let hidden: Bool
    let statsCurrency: String
    let display: (Decimal, String?) -> String
    let pointDisplay: (FinanceHome.TrendPoint) -> String
    let open: (Date, Calendar.Component) -> Void

    var body: some View {
        let unit = statsUnit
        let elapsed = points.filter { $0.date <= Date() }
        let average = elapsed.isEmpty ? 0 : elapsed.map(\.amount).reduce(0, +) / Decimal(elapsed.count)
        let selected = hovered.wrappedValue.flatMap { date in points.first { $0.date == date } }
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value(L("日期", "Date"), point.date, unit: unit), y: .value(L("金额", "Amount"), point.value))
                    .foregroundStyle(point.value < 0 || statsIncome ? Color.green.gradient : Color.accentColor.gradient)
                    .opacity(selected == nil || selected?.date == point.date ? 1 : 0.35)
                    .cornerRadius(2)
                    .accessibilityLabel(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日"))
                    .accessibilityValue(pointDisplay(point))
            }
            if average > 0 && !hidden && !points.contains(where: { $0.missing > 0 }) {
                RuleMark(y: .value(L("平均", "Average"), double(average)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.secondary.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        Text((unit == .month ? L("月均 ", "Monthly avg ") : L("日均 ", "Daily avg ")) + display(Money.round(average, currency: statsCurrency), statsCurrency))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartYAxis(hidden ? .hidden : .automatic)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    // One invisible column per day (per month in a year), laid out side by side under the bars:
                    // hover areas follow layout, so they must be placed by layout rather than moved by an offset.
                    let columns = trendColumns(points, unit: unit, proxy: proxy)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: columns.lead)
                        ForEach(points) { point in
                            Rectangle().fill(Color.primary.opacity(hovered.wrappedValue == point.date ? 0.06 : 0)).contentShape(Rectangle())
                                .frame(width: columns.widths[point.date] ?? 0)
                                .onHover { inside in
                                    if inside { hovered.wrappedValue = point.date } else if hovered.wrappedValue == point.date { hovered.wrappedValue = nil }
                                }
                                .onTapGesture { open(point.date, unit) }
                        }
                    }
                    .frame(height: max(1, plot.height))
                    .padding(.leading, plot.minX).padding(.top, plot.minY)
                    if let selected, let end = Dates.calendar.date(byAdding: unit, value: 1, to: selected.date),
                       let x = proxy.position(forX: selected.date.addingTimeInterval(end.timeIntervalSince(selected.date) / 2)) {
                        trendTip(selected, unit: unit)
                            .position(x: min(max(plot.minX + x, plot.minX + 70), plot.maxX - 70), y: plot.minY + 24)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: 200)
        .onChange(of: period) { _, _ in hovered.wrappedValue = nil }
    }
    private func trendColumns(_ points: [FinanceHome.TrendPoint], unit: Calendar.Component, proxy: ChartProxy) -> (lead: CGFloat, widths: [Date: CGFloat]) {
        var widths: [Date: CGFloat] = [:], lead: CGFloat = 0
        for (i, point) in points.enumerated() {
            guard let x0 = proxy.position(forX: point.date), let next = Dates.calendar.date(byAdding: unit, value: 1, to: point.date),
                  let x1 = proxy.position(forX: next) else { continue }
            if i == 0 { lead = max(0, x0) }
            widths[point.date] = max(0, x1 - x0)
        }
        return (lead, widths)
    }
    private func trendTip(_ point: FinanceHome.TrendPoint, unit: Calendar.Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日 EEEE")).font(.caption).foregroundStyle(.secondary)
            Text(pointDisplay(point)).font(.headline).monospacedDigit()
            if point.missing > 0 { Text(L("\(point.missing) 笔待折算", "\(point.missing) unconverted")).font(.caption2).foregroundStyle(.orange) }
            Text(point.count + point.missing == 0 ? L("没有账单", "No entries") : L("\(point.count + point.missing) 笔 · 点击查看", "\(point.count + point.missing) entries · click to open")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        .fixedSize()
    }
}

struct FinanceStatisticsCalendar: View {
    @AppStorage("appLanguage") private var language = "system"
    let points: [FinanceHome.TrendPoint]
    let hovered: Binding<Date?>
    let statsUnit: Calendar.Component
    let statsIncome: Bool
    let hidden: Bool
    let statsCurrency: String
    let compact: Bool
    let statsSelectedDate: Date?
    let display: (Decimal, String?) -> String
    let pointDisplay: (FinanceHome.TrendPoint) -> String
    let selectStatsDate: (Date) -> Void

    var body: some View {
        let unit = statsUnit
        let top = points.map { abs($0.value) }.max() ?? 0
        let lead = unit == .day ? (Dates.calendar.component(.weekday, from: points.first?.date ?? Date()) + 5) % 7 : 0
        let selected = hovered.wrappedValue.flatMap { date in points.first { $0.date == date } }
        let tint = statsIncome ? Color.green : Color.accentColor
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let selected {
                    Text(Dates.label(selected.date, pattern: unit == .month ? "yyyy年M月" : "M月d日 EEEE") + " · " + pointDisplay(selected)
                         + " · " + (selected.count + selected.missing == 0 ? L("没有账单", "No entries") : L("\(selected.count + selected.missing) 笔", "\(selected.count + selected.missing) entries")))
                } else {
                    Text(L("按日期查看汇总", "Select a date for its summary"))
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 4 : 6), count: unit == .day ? 7 : 4), spacing: compact ? 4 : 6) {
                if unit == .day {
                    ForEach([L("一", "Mon"), L("二", "Tue"), L("三", "Wed"), L("四", "Thu"), L("五", "Fri"), L("六", "Sat"), L("日", "Sun")], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 40) }
                }
                ForEach(points) { point in
                    let strength = top > 0 ? min(1, abs(point.value) / top) : 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Dates.label(point.date, pattern: unit == .month ? "M月" : "d日")).font(.caption)
                        if point.missing > 0 {
                            Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
                        } else if point.count > 0 && !hidden {
                            Text(display(point.amount, statsCurrency)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .padding(5).frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(point.count > 0 ? 0.12 + 0.6 * strength : 0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(statsSelectedDate == point.date ? 1 : hovered.wrappedValue == point.date ? 0.4 : 0), lineWidth: 1.5))
                    .opacity(point.date > Date() ? 0.4 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered.wrappedValue = point.date } else if hovered.wrappedValue == point.date { hovered.wrappedValue = nil }
                    }
                    .onTapGesture { selectStatsDate(point.date) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Dates.label(point.date, pattern: unit == .month ? "yyyy年M月" : "M月d日"))
                    .accessibilityValue(pointDisplay(point))
                    .accessibilityAddTraits(statsSelectedDate == point.date ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction { selectStatsDate(point.date) }
                }
            }
        }
    }
}
