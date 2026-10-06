import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Charts
#if os(iOS)
import UIKit
#endif

// MARK: - Shared pieces

/// Only the ranking reads this observable property during rendering. Opening a row
/// doesn't recompute FinanceHome's charts, filtered entries or asset summaries.
@Observable final class MoneyRankingExpansion { var key: MoneyCategoryKey? }
private struct MoneyRanking<Row: View, Detail: View>: View {
    let rows: [MoneyCategoryTotal]
    let expansion: MoneyRankingExpansion
    @ViewBuilder var row: (MoneyCategoryTotal) -> Row
    @ViewBuilder var detail: (MoneyCategoryTotal) -> Detail
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("点一个分类，看它每个月的变化", "Click a category to see it month by month")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            ForEach(rows) { item in
                let open = expansion.key == item.id
                MoneyHover { hovering in
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansion.key = open ? nil : item.id }
                    } label: {
                        HStack(spacing: 12) {
                            row(item)
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 10).fill(hovering || open ? Color.primary.opacity(0.05) : .clear))
                    }.buttonStyle(.plain)
                }
                if open { detail(item) }
            }
        }.background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
    }
}


/// A thin colored bar; the system progress bar ignores category colors on the Mac.
struct MoneyBar: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let value: Double
    let tint: Color
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value))) }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}


extension FinanceHome {
    private var statsCurrency: String { Money.currencies.contains(statsCurrencyRaw) ? statsCurrencyRaw : data.baseCurrency }
    func statsEntries(_ span: DateInterval) -> [MoneyEntry] {
        data.entries.filter { $0.deletedAt == nil && $0.date >= span.start && $0.date < span.end && (bookFilterID == nil || $0.bookID == bookFilterID) }
    }
    private func statsValue(_ entry: MoneyEntry, income: Bool, days: [String]?) -> Decimal? {
        data.statisticsAmount(entry, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private func statsSum(_ entries: [MoneyEntry], income: Bool, days: [String]?) -> MoneyStatisticsTotal {
        data.statisticsTotal(entries, income: income, in: statsCurrency, history: rateHistory, days: days)
    }
    private var selectedStatsRange: DateInterval? {
        guard statsCalendar, let date = statsSelectedDate, date >= range.start, date < range.end else { return nil }
        return Dates.calendar.dateInterval(of: statsUnit, for: date)
    }
    private var categoryStatsRange: DateInterval { selectedStatsRange ?? range }
    private var categoryRangeLabel: String {
        let span = categoryStatsRange
        if selectedStatsRange != nil { return Dates.label(span.start, pattern: statsUnit == .month ? "yyyy年M月" : "M月d日") }
        if period != .week { return Dates.label(span.start, pattern: period == .year ? "yyyy年" : "yyyy年M月") }
        return Dates.label(span.start, pattern: "M月d日") + " – " + Dates.label(span.end.addingTimeInterval(-1), pattern: "M月d日")
    }
    var statisticsPage: some View {
        let span = range, days = rateHistory?.sortedDays
        let entries = statsEntries(span)
        let spent = statsSum(entries, income: false, days: days), earned = statsSum(entries, income: true, days: days)
        let previousAnchor = Dates.calendar.date(byAdding: period.component, value: -1, to: anchor) ?? anchor
        let before = statsSum(statsEntries(Dates.calendar.dateInterval(of: period.component, for: previousAnchor)!), income: false, days: days)
        let value: (MoneyEntry) -> Decimal? = { statsValue($0, income: statsIncome, days: days) }
        let rows = categoryRows(selectedStatsRange.map { statsEntries($0) } ?? entries)
        let earliest = data.entries.filter { $0.deletedAt == nil }.map(\.date).min() ?? Date()
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                periodHeader
                VStack(alignment: .leading, spacing: 12) {
                    (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(spacing: 32))) {
                        VStack(alignment: .leading, spacing: 6) {
                            metric(totalLabel(L("支出", "Spending"), spent), totalDisplay(spent, currency: statsCurrency), size: compact ? 24 : 30)
                            change(now: spent, before: before)
                        }
                        if !compact { Spacer(minLength: 0) }
                        metricPair((totalLabel(L("收入", "Income"), earned), totalDisplay(earned, currency: statsCurrency)),
                                   (L("本期结余", "Period net"), balanceDisplay(spent: spent, earned: earned, currency: statsCurrency)))
                    }
                    Text(L("本期结余为所选范围的收入减支出，不含账户初始余额。", "Period net is income minus spending in this view; it excludes opening balances."))
                        .font(.caption).foregroundStyle(.secondary)
                    originalSplit(entries)
                    rateNote(entries, estimates: spent.estimateDates.union(earned.estimateDates))
                }.padding(18).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                missingAmounts(spent.missing + earned.missing)
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    Picker(L("方向", "Direction"), selection: $statsIncome) {
                        Text(L("支出", "Spending")).tag(false)
                        Text(L("收入", "Income")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 150)
                    Picker(L("视图", "View"), selection: $statsCalendar) {
                        Text(L("趋势", "Trend")).tag(false)
                        Text(L("日历", "Calendar")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: compact ? .infinity : 130)
                    if !compact { Spacer() }
                }
                let selectedTotal = statsIncome ? earned : spent
                if selectedTotal.missing > 0 {
                    Text(L("图表和分类仅显示已折算部分，空白不代表零收支。", "Charts and categories show converted amounts only; gaps do not mean zero activity."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if !statsCalendar && rows.isEmpty {
                    Text(selectedTotal.missing > 0 ? L("本期账单尚待折算，补全后显示图表。", "Complete the pending conversions to see this period’s charts.") : statsIncome ? L("这段时间没有可统计的收入。", "No income in this period.") : L("这段时间没有可统计的支出或退款。", "No spending or refunds in this period."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let points = buckets(entries, span: span, value: value)
                    MoneyChartHover { hovered in
                        if statsCalendar { calendarGrid(points, hovered: hovered) } else { trend(points, hovered: hovered) }
                    }.id(span.start)
                    if let selectedSpan = selectedStatsRange { AnyView(statsBucketSummary(selectedSpan)) }
                    Text(categoryRangeLabel + L(" · 分类汇总", " · Category totals")).font(.subheadline.weight(.semibold))
                    if rows.isEmpty {
                        Text(statsIncome ? L("所选日期没有收入。", "No income for the selected date.") : L("所选日期没有支出或退款。", "No spending or refunds for the selected date."))
                            .foregroundStyle(.secondary)
                    } else { ranking(rows) }
                }
                if !statsIncome {
                    Text(L("支出包含手续费，并扣除退款；负数表示本期退款多于消费。", "Spending includes fees minus refunds. Negative amounts mean refunds exceeded spending in this period."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(compact ? 16 : 24)
        }
        .onChange(of: span.start) { _, _ in statsSelectedDate = nil; rankingExpansion.key = nil }
        .onChange(of: period) { _, _ in statsSelectedDate = nil; rankingExpansion.key = nil }
        .task(id: "\(statsCurrency)-\(data.baseCurrency)-\(Int(earliest.timeIntervalSince1970 / 86400))") { await loadRates(since: earliest) }
    }
    func loadRates(since: Date, currency: String? = nil) async {
        guard (currency ?? statsCurrency) != data.baseCurrency else { return }
        if rateHistory == nil { rateHistory = await RateHistoryStore.cached }
        loadingRates = true
        if let history = try? await RateHistoryStore.load(since: since) { rateHistory = history }
        loadingRates = false
    }
    var entriesCurrencyMenu: some View {
        Menu {
            Button(L("跟随常用账户：", "Follow default account: ") + defaultEntriesCurrency) { entriesCurrencyRaw = "" }
            Divider()
            CurrencyChoices { entriesCurrencyRaw = $0 }
        } label: { Label(entriesCurrency + (entriesCurrencyRaw.isEmpty ? L(" · 自动", " · Auto") : ""), systemImage: "banknote") }
            .fixedSize().help(L("默认跟随账户币种；临时切换只改变合计显示，不改变原始金额", "Follows the default account; a temporary override changes totals, never original amounts"))
    }
    var statsCurrencyMenu: some View {
        Menu {
            Button(L("本位币：", "Base currency: ") + Money.name(data.baseCurrency)) { statsCurrencyRaw = "" }
            Divider()
            CurrencyChoices { statsCurrencyRaw = $0 == data.baseCurrency ? "" : $0 }
        } label: { Label(Money.name(statsCurrency), systemImage: "banknote") }
            .fixedSize().help(L("统计币种：所有合计换算成这种货币显示", "Show every total in this currency"))
    }
    /// “¥1,860 + A$1,250”: what was actually spent in each currency, before any conversion.
    @ViewBuilder private func originalSplit(_ entries: [MoneyEntry]) -> some View {
        let sums = entries.reduce(into: [String: Decimal]()) { result, e in
            if let o = e.originalStatistics(income: statsIncome, feeCurrency: data.account(e.accountID)?.currency) { result[o.currency, default: 0] += o.amount }
        }.filter { $0.value != 0 }.sorted { $0.key == statsCurrency ? true : $1.key == statsCurrency ? false : $0.key < $1.key }
        if sums.count > 1 || sums.first.map({ $0.key != statsCurrency }) == true {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(statsIncome ? L("各币种实际收入", "Received in each currency") : L("各币种实际支出", "Spent in each currency"))
                    .font(.caption).foregroundStyle(.secondary)
                (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                    ForEach(sums, id: \.key) { item in
                        HStack(spacing: 6) {
                            Text(display(item.value, item.key)).font(.body.weight(.semibold)).monospacedDigit()
                            Text(Money.name(item.key)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
        }
    }
    @ViewBuilder private func rateNote(_ entries: [MoneyEntry], estimates: Set<String>) -> some View {
        let foreign = entries.contains { $0.currency != statsCurrency || ($0.fee > 0 && data.account($0.accountID)?.currency != statsCurrency) }
        if !estimates.isEmpty {
            let dates = estimates.sorted()
            let range = dates.count == 1 ? dates[0] : dates.first! + " – " + dates.last!
            Text(L("部分金额为估算，参考汇率日期：\(range)。", "Some amounts are estimates. Reference rate date: \(range)."))
                .font(.caption).foregroundStyle(.orange)
        } else if statsCurrency != data.baseCurrency && foreign {
            Text(loadingRates && rateHistory == nil ? L("正在下载每日参考汇率…", "Downloading daily reference rates…")
                 : L("可折算的金额按账单日期的参考汇率计算，原始金额不变。", "Convertible amounts use reference rates for each entry's date; original amounts don't change."))
                .font(.caption).foregroundStyle(.secondary)
        } else if foreign {
            Text(L("外币按记账时的折算金额计入。可在右上角切换统计币种。", "Foreign amounts count at the value recorded with each entry. Switch the currency at the top right."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// "比上月 ↑12%": spending up reads as a warning, down as good news.
    @ViewBuilder func change(now: MoneyStatisticsTotal, before: MoneyStatisticsTotal) -> some View {
        if let value = now.change(from: before), !hidden {
            let ratio = double(value)
            let name: String = { switch period { case .week: L("比上周", "vs last week"); case .month: L("比上月", "vs last month"); case .year: L("比去年", "vs last year") } }()
            let text = abs(ratio) < 0.005 ? L("持平", "flat") : (ratio > 0 ? "↑" : "↓") + "\(Int((abs(ratio) * 100).rounded()))%"
            Text(name + " " + text).font(.caption).foregroundStyle(abs(ratio) < 0.005 ? Color.secondary : ratio > 0 ? Color.orange : Color.green)
                .help(L("上一段支出 ", "Previous period ") + display(before.total, statsCurrency))
        } else if !hidden && (!now.complete || !before.complete) {
            Text(L("数据未完整折算，暂不比较涨跌", "Comparison unavailable: some amounts are missing or estimated"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var statsUnit: Calendar.Component { period == .year ? .month : .day }
    private func buckets(_ entries: [MoneyEntry], span: DateInterval, value: (MoneyEntry) -> Decimal?) -> [TrendPoint] {
        let unit = statsUnit
        var result: [Date: (amount: Decimal, count: Int, missing: Int)] = [:]
        var cursor = span.start
        while cursor < span.end { result[cursor] = (0, 0, 0); cursor = Dates.calendar.date(byAdding: unit, value: 1, to: cursor) ?? span.end }
        for e in entries {
            guard e.originalStatistics(income: statsIncome, feeCurrency: data.account(e.accountID)?.currency) != nil else { continue }
            let key = Dates.calendar.dateInterval(of: unit, for: e.date)?.start ?? e.date
            var bucket = result[key] ?? (0, 0, 0)
            if let amount = value(e) { bucket.amount += amount; bucket.count += 1 }
            else { bucket.missing += 1 }
            result[key] = bucket
        }
        return result.map { TrendPoint(date: $0.key, amount: $0.value.amount, count: $0.value.count, missing: $0.value.missing) }.sorted { $0.date < $1.date }
    }
    /// Bars per day (per month for a year). Hovering shows the exact amount; clicking opens that day's or month's entries.
    private func trend(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
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
                                .onTapGesture { openBucket(point.date, unit: unit) }
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
    private func trendColumns(_ points: [TrendPoint], unit: Calendar.Component, proxy: ChartProxy) -> (lead: CGFloat, widths: [Date: CGFloat]) {
        var widths: [Date: CGFloat] = [:], lead: CGFloat = 0
        for (i, point) in points.enumerated() {
            guard let x0 = proxy.position(forX: point.date), let next = Dates.calendar.date(byAdding: unit, value: 1, to: point.date),
                  let x1 = proxy.position(forX: next) else { continue }
            if i == 0 { lead = max(0, x0) }
            widths[point.date] = max(0, x1 - x0)
        }
        return (lead, widths)
    }
    private func trendTip(_ point: TrendPoint, unit: Calendar.Component) -> some View {
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
    private func pointDisplay(_ point: TrendPoint) -> String {
        if hidden { return "••••" }
        if point.missing > 0 && point.count == 0 { return L("待折算", "Unconverted") }
        return display(point.amount, statsCurrency) + (point.missing > 0 ? L(" · 小计", " · subtotal") : "")
    }
    /// Days of the month as a calendar (months of the year as a grid), shaded by amount.
    private func calendarGrid(_ points: [TrendPoint], hovered: Binding<Date?>) -> some View {
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
                    Text(L("颜色越深金额越大，选择日期查看下方汇总。", "Darker means more. Select a date to see its summary below."))
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
    private func selectStatsDate(_ date: Date) {
        statsSelectedDate = date
        rankingExpansion.key = nil
    }
    private func statsBucketSummary(_ span: DateInterval) -> some View {
        let entries = statsEntries(span), days = rateHistory?.sortedDays
        let spent = statsSum(entries, income: false, days: days), earned = statsSum(entries, income: true, days: days)
        return VStack(alignment: .leading, spacing: 12) {
            Text(Dates.label(span.start, pattern: statsUnit == .month ? "yyyy年M月" : "M月d日 EEEE")).font(.headline)
            metricPair((totalLabel(L("支出", "Spending"), spent), totalDisplay(spent, currency: statsCurrency)),
                       (totalLabel(L("收入", "Income"), earned), totalDisplay(earned, currency: statsCurrency)))
            Text(L("结余：", "Net: ") + balanceDisplay(spent: spent, earned: earned, currency: statsCurrency)).font(.subheadline).monospacedDigit()
            missingAmounts(spent.missing + earned.missing)
            rateNote(entries, estimates: spent.estimateDates.union(earned.estimateDates))
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 16))) {
                Button(statsUnit == .month ? L("查看这个月的账单", "View this month’s entries") : L("查看当天账单", "View this day’s entries")) { openBucket(span.start, unit: statsUnit) }
                    .frame(minHeight: 44)
                Button(L("返回整期汇总", "Show the full period")) { statsSelectedDate = nil; rankingExpansion.key = nil }.frame(minHeight: 44)
            }
        }.padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
    }
    private func rememberStats() {
        statsReturn = StatsPlace(anchor: anchor, period: period, income: statsIncome, expanded: rankingExpansion.key, selectedDate: statsSelectedDate, billRange: dateRange)
    }
    func backToStats(_ place: StatsPlace) {
        drilldown = nil; dateRange = place.billRange
        anchor = place.anchor; period = place.period; statsIncome = place.income; rankingExpansion.key = place.expanded; statsSelectedDate = place.selectedDate
        selection = "stats"
    }
    private func openBucket(_ date: Date, unit: Calendar.Component) {
        rememberStats()
        drilldown = nil; categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""
        anchor = date; dateRange = unit == .month ? .month : .day
        selection = "all"
    }
    func breakdownLabel(_ key: MoneyCategoryKey) -> String {
        switch key {
        case .fees: return L("转账手续费", "Transfer fees")
        case .category(let id): return data.categoryPath(id)
        }
    }
    private func categoryRows(_ entries: [MoneyEntry]) -> [MoneyCategoryTotal] {
        let grouped = Dictionary(grouping: entries.filter { $0.originalStatistics(income: statsIncome, feeCurrency: nil) != nil }) {
            $0.kind == .transfer ? MoneyCategoryKey.fees : .category(data.rootCategoryID($0.categoryID))
        }
        let days = rateHistory?.sortedDays
        return grouped.map { key, entries in
            let total = statsSum(entries, income: statsIncome, days: days)
            return MoneyCategoryTotal(id: key, total: total.total, count: total.convertedCount, missing: total.missing, estimateDates: total.estimateDates)
        }.sorted { abs($0.total) > abs($1.total) }
    }
    private func ranking(_ rows: [MoneyCategoryTotal]) -> some View {
        let top = rows.map { abs($0.total) }.max() ?? 1
        let sum = rows.map(\.total).filter { $0 > 0 }.reduce(0, +)
        let complete = rows.allSatisfy { $0.summary.complete }
        return MoneyRanking(rows: rows, expansion: rankingExpansion) { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return data.category(id) }; return nil }()
            let tint = data.tint(category)
            HStack(spacing: 12) {
                MoneyIcon(symbol: category?.symbol ?? (row.id == .fees ? "arrow.left.arrow.right" : "tag"), emoji: category?.emoji, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(breakdownLabel(row.id))
                        if complete && sum > 0 && row.total > 0 && !hidden { Text("\(Int((double(row.total / sum) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary) }
                        Text(L("\(row.count + row.missing) 笔", "\(row.count + row.missing)")).font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Text(totalDisplay(row.summary, currency: statsCurrency, subtotal: true)).monospacedDigit().foregroundStyle(row.missing > 0 ? Color.orange : row.total < 0 ? .green : .primary)
                    }
                    if row.missing > 0 {
                        Text(L("\(row.missing) 笔待折算", "\(row.missing) unconverted")).font(.caption).foregroundStyle(.orange)
                    } else {
                        MoneyBar(value: top > 0 ? double(abs(row.total) / top) : 0, tint: row.total < 0 ? .green : tint)
                    }
                }
            }
        } detail: { row in
            let category: MoneyCategory? = { if case .category(let id) = row.id { return data.category(id) }; return nil }()
            subcategoryRanking(row.id)
            categoryHistory(row.id, tint: data.tint(category))
        }
    }
    @ViewBuilder private func subcategoryRanking(_ key: MoneyCategoryKey) -> some View {
        if case .category(let id) = key, let id {
            let children = data.categories.filter { $0.parentID == id }
            if !children.isEmpty {
                let periodEntries = statsEntries(categoryStatsRange)
                let days = rateHistory?.sortedDays
                VStack(spacing: 0) {
                    ForEach([data.category(id)].compactMap { $0 } + children) { category in
                        let entries = periodEntries.filter { MoneyCategoryKey.category(category.id).includes($0, income: statsIncome) }
                        let total = statsSum(entries, income: statsIncome, days: days)
                        if !entries.isEmpty {
                            Button { drill(.category(category.id), includeSubcategories: category.id != id) } label: {
                                HStack {
                                    Text(category.id == id ? L("未细分", "No subcategory") : category.label)
                                    Spacer()
                                    Text(totalDisplay(total, currency: statsCurrency, subtotal: true)).monospacedDigit()
                                        .foregroundStyle(total.missing > 0 ? Color.orange : .primary)
                                }.font(.callout).padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.leading, compact ? 16 : 54).padding(.trailing, 12)
            }
        }
    }
    /// Missing conversions remain gaps; an average is only meaningful when every month is complete.
    private func categoryHistory(_ key: MoneyCategoryKey, tint: Color) -> some View {
        let months = data.categoryMonthlyTotals(key, income: statsIncome, endingAt: anchor, bookID: bookFilterID, in: statsCurrency, history: rateHistory)
        let summaries = months.map(\.summary)
        let top = summaries.map { abs($0.total) }.max() ?? 0
        let average = MoneyStatisticsTotal.average(summaries)
        let missing = summaries.reduce(0) { $0 + $1.missing }
        let estimates = summaries.reduce(into: Set<String>()) { $0.formUnion($1.estimateDates) }
        return VStack(alignment: .leading, spacing: 10) {
            (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())) {
                Text(breakdownLabel(key) + L(" · 近 6 个月", " · last 6 months"))
                    .font(.caption).foregroundStyle(.secondary)
                if !compact { Spacer() }
                Button(L("查看此分类账单 · ", "View category entries · ") + categoryRangeLabel) { drill(key) }
                    .controlSize(.small).frame(minHeight: compact ? 44 : nil)
            }
            Text(L("月均：", "Monthly average: ") + (average.map { display(Money.round($0, currency: statsCurrency), statsCurrency) }
                ?? (missing > 0 ? L("待补全折算", "Pending conversions") : L("待历史汇率确认", "Pending historical rates"))))
                .font(.caption).foregroundStyle(average == nil ? Color.orange : .secondary)
            if dynamicTypeSize.isAccessibilitySize {
                ForEach(months, id: \.start) { month in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Dates.label(month.start, pattern: "yyyy年M月")).font(.caption)
                        Text(totalDisplay(month.summary, currency: statsCurrency, subtotal: true)).monospacedDigit()
                        if month.summary.missing > 0 { Text(L("\(month.summary.missing) 笔待折算", "\(month.summary.missing) unconverted")).font(.caption).foregroundStyle(.orange) }
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(months, id: \.start) { month in
                        MoneyHover { hovering in
                            VStack(spacing: 4) {
                                Text(hovering || month.start == months.last?.start ? totalDisplay(month.summary, currency: statsCurrency, subtotal: true) : " ")
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                                if month.summary.missing > 0 {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).frame(height: 64)
                                } else {
                                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(month.start == months.last?.start ? 1 : hovering ? 0.8 : 0.5))
                                        .frame(height: max(2, top > 0 ? 64 * CGFloat(double(abs(month.summary.total) / top)) : 2))
                                }
                                Text(Dates.label(month.start, pattern: "M月")).font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Dates.label(month.start, pattern: "yyyy年M月") + " · " + totalDisplay(month.summary, currency: statsCurrency, subtotal: true))
                        }
                    }
                }.frame(minHeight: 100, alignment: .bottom)
            }
            if missing > 0 {
                Text(L("近 6 个月有 \(missing) 笔金额待折算，暂不计算月均；标记月份并非零支出。", "\(missing) amounts in these six months need conversion. The average is withheld; marked months do not mean zero activity."))
                    .font(.caption).foregroundStyle(.orange)
                Button(L("补全这 6 个月的折算…", "Complete these six months’ conversions…")) {
                    guard let first = months.first?.start, let end = Dates.calendar.dateInterval(of: .month, for: anchor)?.end else { return }
                    prepareConversion(data.entries.filter {
                        $0.deletedAt == nil && $0.date >= first && $0.date < end && (bookFilterID == nil || $0.bookID == bookFilterID)
                            && key.includes($0, income: statsIncome, data: data)
                    })
                }.buttonStyle(.borderless).font(.callout).frame(minHeight: compact ? 44 : nil)
            }
            if !estimates.isEmpty {
                Text(L("部分月份使用缓存参考汇率，月均暂不显示。参考日期：", "Some months use cached reference rates, so the average is withheld. Rate dates: ") + estimates.sorted().joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .padding(.leading, compact ? 12 : 54).padding(.trailing, 10).padding(.bottom, 8)
    }
    private func drill(_ key: MoneyCategoryKey, includeSubcategories: Bool = true) {
        rememberStats()
        drilldown = MoneyDrilldown(range: categoryStatsRange, key: key, income: statsIncome, includeSubcategories: includeSubcategories)
        categoryFilter = nil; kindFilter = nil; accountFilter = nil; accountDetailID = nil; search = ""; dateRange = .month
        selection = "all"
    }

    // MARK: Assets

}

extension FinanceHome {
    private struct TrendPoint: Identifiable { var date: Date; var amount: Decimal; var count: Int; var missing: Int; var value: Double { double(amount) }; var id: Date { date } }
}
